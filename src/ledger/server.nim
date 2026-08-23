## Ledger game server: implements the Coworld game contract.
##
## Endpoints:
##   GET /healthz                    - liveness
##   GET /client/global              - spectator page
##   GET /client/player              - player page (view-only; policies are prompts)
##   GET /client/replay              - replay page (replay mode)
##   GET /client/renderer.js         - shared stage renderer
##   GET /client/chrome.css          - shared chrome stylesheet
##   GET /client/assets/<name>       - sprites and fonts
##   WS  /player?slot=N&token=T      - player protocol (prompt delivery)
##   WS  /global                     - spectator snapshots
##   WS  /replay                     - replay payload (replay mode)
##
## Player protocol (ledger.player.v1), all JSON text frames:
##   game -> player: {"type":"welcome","slot":N,"name":"<alias>","rounds":N}
##                   {"type":"state",...} after every round (redacted to the
##                   seat's own tallies: all decisions are simultaneous, so a
##                   seat may not see the round's pairings or moves)
##                   {"type":"final","scores":[...],...}
##   player -> game: {"type":"prompt","prompt":"...",
##                    "scripted":"mirror"|"shark"|""}
##                   (prompt max 4000 characters, cut on a rune boundary)

import
  std/[json, locks, os, sets, strutils, tables, times, unicode],
  bitworld/runtime,
  curly,
  mummy,
  mummy/routers,
  llm,
  sim

const
  MaxPromptLen = 4000
  ReplayVersion = 1

  PlayBudgetFraction* = 0.6
    ## Share of the platform's episode timeout spent playing. The rest covers
    ## container start, player connects, and writing the artifacts — the part
    ## that must never be the thing that runs out of time.

  RoundReserveSeconds* = 70.0
    ## A round is only STARTED when this much of the play budget is left. The
    ## worst realistic round is 30 s (first attempt hits llmTimeoutSeconds) +
    ## a retry pause + 30 s (the retry hits it too) ~= 62 s.
  ScriptedReserveSeconds* = 2.0
    ## With the LLM client disabled a round is instant, so the reserve is
    ## nominal and an offline episode plays every round it can.

  ShutdownGraceSeconds = 20
    ## The certifier pings /global AFTER the player pods start, on a 2 s
    ## deadline, and an offline episode can be over in about two seconds.
    ## Keep answering for a bounded grace once the artifacts are written; the
    ## episode runner waits on process exit anyway (lantern 0.1.3 -> 0.1.4).

type
  GameState = object
    config: GameConfig
    sim: Sim
    prompts: seq[string]
    scripted: seq[ScriptKind]
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    started: bool
    finished: bool

var
  stateLock: Lock
  state: GameState
  gameServer: Server
  runtimeConfigGlobal: RuntimeConfig
  replayPayloadGlobal: string

initLock(stateLock)

proc clientDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      return candidate
  "client"

proc dataDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "data", appDir / ".." / "data", "data"]:
    if dirExists(candidate):
      return candidate
  "data"

proc policyNamesJson(gs: GameState): JsonNode =
  ## Seats play under anonymous aliases; the policy names ride alongside for
  ## the SPECTATOR views only, which render them in place of the aliases.
  result = newJArray()
  for player in gs.config.players:
    result.add(%player.name)

proc snapshotJson(gs: GameState): JsonNode =
  var events = newJArray()
  for event in gs.sim.events:
    events.add(event.eventToJson())
  var connected = newJArray()
  for slot in 0 ..< gs.config.tokens.len:
    connected.add(%gs.playerSockets.hasKey(slot))
  result = gs.sim.tableStateJson()
  result["type"] = %"state"
  result["game"] = %"ledger"
  result["policyNames"] = gs.policyNamesJson()
  result["events"] = events
  result["started"] = %gs.started
  result["done"] = %gs.sim.done
  result["connected"] = connected

proc playerStateJson(gs: GameState, slot: int): JsonNode =
  ## Every decision in Ledger is simultaneous, so a seat may not see this
  ## round's pairings, the moves, or any other seat's memo. It sees only its
  ## own tallies and the round counter. Decisions are server-side, so nothing
  ## is lost: the seat's real view is the observation the server composes for
  ## its call.
  %*{
    "type": "state",
    "slot": slot,
    "name": gs.sim.names[slot],
    "seat": {
      "score": gs.sim.median(slot),
      "mean": gs.sim.meanPay(slot),
      "total": gs.sim.total[slot],
      "meetings": gs.sim.meetingCount(slot),
      "kind": gs.sim.kind[slot],
      "harsh": gs.sim.harsh[slot]
    },
    "round": gs.sim.round,
    "rounds": gs.config.rounds,
    "roundsPlayed": gs.sim.roundsPlayed,
    "started": gs.started,
    "done": gs.sim.done,
    "reason": gs.sim.reason
  }

proc broadcastLocked(gs: GameState) =
  ## Callers hold stateLock. Spectators get the whole table; players get the
  ## redacted per-seat state.
  let payload = $gs.snapshotJson()
  for socket in gs.globalSockets:
    socket.send(payload)
  for slot, socket in gs.playerSockets:
    socket.send($gs.playerStateJson(slot))

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  ## Writes a Coworld artifact, honoring the platform's PUT/POST method hint.
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError, "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc replayPayload(gs: GameState, results: JsonNode): string =
  ## Self-sufficient: aliases, policy names, the whole config INCLUDING the
  ## expanded schedule, every event, and the results. The viewer contacts
  ## nothing but S3 for these bytes.
  var names = newJArray()
  for name in gs.sim.names:
    names.add(%name)
  var events = newJArray()
  for event in gs.sim.events:
    events.add(event.eventToJson())
  $ %*{
    "protocol": "ledger.replay.v" & $ReplayVersion,
    "names": names,
    "policyNames": gs.policyNamesJson(),
    "config": {
      "rounds": gs.config.rounds,
      "seed": gs.config.seed,
      "sampled": true,
      "schedule": gs.sim.scheduleJson()
    },
    "events": events,
    "results": results
  }

proc statesFromEvents(config: GameConfig, events: seq[GameEvent]): JsonNode =
  ## One table-state object per event prefix, for scrubbing replays.
  result = newJArray()
  for frame in replayMatch(config, events):
    result.add(frame.tableStateJson())

proc finishEpisode(runtimeConfig: RuntimeConfig) =
  var results: JsonNode
  var replayData: string
  withLock stateLock:
    if state.finished:
      return
    state.finished = true
    results = state.sim.resultsJson()
    replayData = state.replayPayload(results)

    ## Send final frames to players BEFORE writing artifacts: the hosted
    ## worker tears player pods down as soon as results.json exists, and
    ## writing first would race player log collection.
    ## Results carry POLICY names for the platform, but the final frame goes
    ## to the player sockets — hand them the table aliases instead.
    var aliasNames = newJArray()
    for name in state.sim.names:
      aliasNames.add(%name)
    var final = %*{
      "type": "final",
      "done": true,
      "scores": results["scores"],
      "mean": results["mean"],
      "meetings": results["meetings"],
      "names": aliasNames,
      "rounds": results["rounds"],
      "reason": results["reason"]
    }
    for slot, socket in state.playerSockets:
      final["slot"] = %slot
      socket.send($final)
    state.broadcastLocked()

  sleep(500)
  echo "ledger: writing results and replay"
  writeArtifact(
    runtimeConfig.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD"
  )
  writeArtifact(
    runtimeConfig.replayUri, replayData, "application/octet-stream",
    "COGAME_SAVE_REPLAY_METHOD"
  )
  ## Bounded shutdown grace: /healthz and /global keep answering so a
  ## certifier ping that arrives after a very short episode still gets a Pong.
  echo "ledger: artifacts written; serving for ", ShutdownGraceSeconds,
    "s before exit"
  sleep(ShutdownGraceSeconds * 1000)
  echo "ledger: episode complete, shutting down"
  quit(0)

proc meetingLog(sim: Sim, pair: int): string =
  let meeting = sim.plan.pairs[pair]
  sim.names[meeting.a] & " / " & sim.names[meeting.b] & " " &
    subGameName(meeting.game) & ": " &
    moveText(meeting.game, true, sim.moves[pair][0]) & " / " &
    moveText(meeting.game, false, sim.moves[pair][1]) & " (+" &
    $sim.pays[pair][0] & " / +" & $sim.pays[pair][1] & ")"

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = state.config
    let gameStart = epochTime()
    let connectDeadline = gameStart + config.playerConnectTimeoutSeconds

    while epochTime() < connectDeadline:
      var allConnected = false
      withLock stateLock:
        allConnected = state.playerSockets.len >= config.tokens.len
      if allConnected:
        break
      sleep(200)

    withLock stateLock:
      state.started = true
      echo "ledger: starting with ", state.playerSockets.len, "/",
        config.tokens.len, " players connected"
      state.broadcastLocked()

    let client = newLlmClient(config)

    ## The platform kills the episode at its timeout and keeps nothing. Play
    ## inside a fraction of it so results and the replay are written with
    ## room to spare. The hosted dispatcher hands the timeout only to its own
    ## worker sidecar, NOT to the game container, so when the env is silent
    ## assume the configured platform default rather than playing open-ended.
    let hostedTimeout = getEnv("COWORLD_TIMEOUT_SECONDS", "").strip()
    var timeoutSeconds =
      if hostedTimeout.len > 0:
        try: parseFloat(hostedTimeout) except ValueError: 0.0
      else: 0.0
    if timeoutSeconds <= 0.0:
      timeoutSeconds = config.episodeTimeoutSeconds.float
    let playDeadline =
      if timeoutSeconds > 0.0: gameStart + timeoutSeconds * PlayBudgetFraction
      else: 0.0
    if playDeadline > 0.0:
      echo "ledger: episode timeout ", timeoutSeconds.int, "s (",
        (if hostedTimeout.len > 0: "from env" else: "assumed"),
        "); playing until ", (timeoutSeconds * PlayBudgetFraction).int, "s"

    var seats: seq[int]
    for seat in 0 ..< Seats:
      seats.add(seat)

    while true:
      ## Step 10 of the resolution order, applied before every round: a round
      ## is only started when the whole reserve still fits inside the play
      ## budget, so play always stops with the artifact window intact.
      let reserve =
        if client.disabled: ScriptedReserveSeconds else: RoundReserveSeconds
      withLock stateLock:
        if state.sim.done:
          break
        if playDeadline > 0.0 and epochTime() + reserve > playDeadline:
          echo "ledger: episode deadline reached after ",
            state.sim.roundsPlayed, "/", config.rounds,
            " rounds; ending early"
          state.sim.endEarly()
          state.broadcastLocked()
          break
        ## Step 1: open the round and publish its four pairings.
        state.sim.beginRound()
        echo "ledger: round ", state.sim.round + 1, " of ", config.rounds,
          " at ", (epochTime() - gameStart).int, "s"
        state.broadcastLocked()

      let roundStart = epochTime()
      var simCopy: Sim
      var promptsCopy: seq[string]
      var scriptedCopy: seq[ScriptKind]
      withLock stateLock:
        simCopy = state.sim
        promptsCopy = state.prompts
        scriptedCopy = state.scripted

      var llmSeats = 0
      if not client.disabled:
        for seat in seats:
          if scriptedCopy[seat] == skNone:
            inc llmSeats

      ## Steps 2-3: ONE parallel batch of eight calls, then a single retry
      ## sub-batch, then the scripted fallback. The slow part runs outside
      ## the lock on a snapshot; only this thread mutates the sim, so the
      ## snapshot cannot go stale.
      let decisions = client.decideAll(simCopy, seats, promptsCopy,
        scriptedCopy)

      withLock stateLock:
        var moves: array[Meetings, array[2, int]]
        var flags: array[Meetings, array[2, bool]]
        var notes = newSeq[string](Seats)
        var memos = newSeq[string](Seats)
        for pair in 0 ..< Meetings:
          let meeting = state.sim.plan.pairs[pair]
          moves[pair] = [decisions[meeting.a].move, decisions[meeting.b].move]
          flags[pair] = [decisions[meeting.a].scripted,
            decisions[meeting.b].scripted]
        for seat in 0 ..< Seats:
          notes[seat] = decisions[seat].note
          memos[seat] = decisions[seat].memo
        ## Steps 4-8: one transactional apply.
        try:
          state.sim.applyRound(moves, notes, memos, flags)
        except LedgerError as error:
          echo "ledger: round rejected (", error.msg,
            "); replaying it on the scripted baseline"
          var safeMoves: array[Meetings, array[2, int]]
          var safeFlags: array[Meetings, array[2, bool]]
          for pair in 0 ..< Meetings:
            let meeting = state.sim.plan.pairs[pair]
            safeMoves[pair] = [
              scriptedAction(state.sim, meeting.a, skMirror).move,
              scriptedAction(state.sim, meeting.b, skMirror).move]
            safeFlags[pair] = [true, true]
          state.sim.applyRound(safeMoves, newSeq[string](Seats),
            newSeq[string](Seats), safeFlags)
        for pair in 0 ..< Meetings:
          echo "ledger: round ", state.sim.round + 1, " ",
            meetingLog(state.sim, pair)
        state.broadcastLocked()

      var finished = false
      withLock stateLock:
        finished = state.sim.done
      if finished:
        break

      ## Step 9: the API rate-limit floor. A fully scripted round never
      ## sleeps, so offline certification finishes in seconds.
      if llmSeats > 0 and config.minRoundIntervalMs > 0:
        ## A 429 anywhere in the episode doubles the floor for the rest of it.
        let intervalMs =
          if client.throttled: config.minRoundIntervalMs * 2
          else: config.minRoundIntervalMs
        let elapsedMs = int((epochTime() - roundStart) * 1000.0)
        if elapsedMs < intervalMs:
          sleep(intervalMs - elapsedMs)

    finishEpisode(runtimeConfig)

var gameThread: Thread[RuntimeConfig]

proc serveFile(request: Request, path, contentType: string) =
  if fileExists(path):
    var headers: HttpHeaders
    headers["Content-Type"] = contentType
    request.respond(200, headers, readFile(path))
  else:
    request.respond(404)

proc htmlHandler(name: string): RequestHandler =
  proc handler(request: Request) {.gcsafe.} =
    {.gcsafe.}:
      serveFile(request, clientDir() / name, "text/html; charset=utf-8")
  handler

proc assetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    let contentType =
      if name.endsWith(".png"): "image/png"
      elif name.endsWith(".ttf"): "font/ttf"
      else: "application/octet-stream"
    serveFile(request, dataDir() / name, contentType)

proc rendererHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(
      request, clientDir() / "renderer.js",
      "application/javascript; charset=utf-8"
    )

proc chromeCssHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(request, clientDir() / "chrome.css", "text/css; charset=utf-8")

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    withLock stateLock:
      authorized = slot >= 0 and slot < state.config.tokens.len and
        state.config.tokens[slot] == token
    if not authorized:
      request.respond(401)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.playerSockets[slot] = websocket
      state.socketSlots[websocket] = slot
      echo "ledger: player slot ", slot, " connected (",
        state.playerSockets.len, "/", state.config.tokens.len, ")"
      websocket.send($ %*{
        "type": "welcome",
        "protocol": "ledger.player.v1",
        "slot": slot,
        "name": state.sim.names[slot],
        "rounds": state.config.rounds
      })

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.globalSockets.incl(websocket)
      websocket.send($state.snapshotJson())

proc replayUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    if replayPayloadGlobal.len > 0:
      websocket.send(replayPayloadGlobal)

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application instead of answering them
      ## itself; the platform's certifier pings /global to check the game is
      ## alive, so an unanswered ping fails certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = state.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload{"type"}.getStr() == "prompt":
          var prompt = payload{"prompt"}.getStr()
          ## Rune-safe: a byte slice here would cut a multi-byte character in
          ## half and the prompt would travel into the model call — and into
          ## any error text quoted from it — as invalid UTF-8.
          if prompt.runeLen > MaxPromptLen:
            prompt = prompt.runeSubStr(0, MaxPromptLen)
          let kind = parseScriptKind(payload{"scripted"}.getStr())
          withLock stateLock:
            state.prompts[slot] = prompt
            state.scripted[slot] = kind
          echo "ledger: slot ", slot, " delivered a prompt (", prompt.len,
            " chars", (if kind != skNone: ", scripted " & $kind else: ""), ")"
      except CatchableError as error:
        echo "ledger: ignoring bad player frame: ", error.msg
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in state.socketSlots:
          let slot = state.socketSlots[websocket]
          state.socketSlots.del(websocket)
          if state.playerSockets.getOrDefault(slot) == websocket:
            state.playerSockets.del(slot)
        state.globalSockets.excl(websocket)

proc buildRouter(replayMode: bool): Router =
  result.get("/healthz", healthzHandler)
  result.get("/client/global", htmlHandler("global.html"))
  result.get("/client/player", htmlHandler("player.html"))
  result.get("/client/replay", htmlHandler("replay.html"))
  result.get("/client/renderer.js", rendererHandler)
  result.get("/client/chrome.css", chromeCssHandler)
  result.get("/client/assets/@name", assetHandler)
  result.get("/global", globalUpgradeHandler)
  result.get("/replay", replayUpgradeHandler)
  if not replayMode:
    result.get("/player", playerUpgradeHandler)

proc configFromReplay*(payload: JsonNode): GameConfig =
  result = defaultGameConfig()
  result.rounds = payload["config"]{"rounds"}.getInt(14)
  result.seed = payload["config"]{"seed"}.getInt(0)
  ## The replay carries the episode's fitted cap; never re-fit it. The
  ## schedule it carries is re-derived from the seed and cross-checked.
  result.sampled = true
  for name in payload["names"]:
    result.players.add(PlayerConfig(name: name.getStr()))

proc runReplayServer*(runtimeConfig: RuntimeConfig) =
  ## Replay mode: parse the recorded replay, precompute the scrub states, and
  ## serve the viewer until the platform tears the container down.
  let payload = parseJson(runtimeConfig.replay)
  let config = configFromReplay(payload)
  var events: seq[GameEvent]
  for node in payload["events"]:
    events.add(eventFromJson(node))
  var enriched = %*{
    "type": "replay",
    "protocol": payload{"protocol"}.getStr("ledger.replay.v1"),
    "names": payload["names"],
    "policyNames": payload{"policyNames"},
    "config": payload["config"],
    "events": payload["events"],
    "results": payload{"results"},
    "states": statesFromEvents(config, events)
  }
  replayPayloadGlobal = $enriched

  let router = buildRouter(replayMode = true)
  gameServer = newServer(router, websocketHandler)
  echo "ledger: replay mode on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len != config.players.len:
    raise newException(LedgerError, "tokens and players must align")
  state.config = config
  state.sim = initSim(config)
  state.prompts = newSeq[string](config.players.len)
  state.scripted = newSeq[ScriptKind](config.players.len)
  runtimeConfigGlobal = runtimeConfig

  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler)
  createThread(gameThread, runGame, runtimeConfig)
  echo "ledger: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

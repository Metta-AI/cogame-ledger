## Claude-backed decision making for Ledger. Each seat's policy is just a
## prompt: the game server composes the seat's view (its own record, this
## round's meeting with its full numeric rules, the partner's public history,
## the table, the gossip board, its private memo) plus that seat's prompt and
## asks Claude what it does.
##
## All eight seats decide simultaneously by rule — trust and ultimatum use the
## experimental-economics STRATEGY METHOD, so the second mover commits a
## contingent rule before seeing the first mover's move — which means the
## eight requests go out as ONE parallel batch (curly.makeRequests) per round.
## Invalid replies are retried as a smaller batch with a corrective hint, and
## anything still failing falls back to the `mirror` scripted baseline.
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials every decision falls back to the always-legal scripted
## baseline immediately (no retries, no network waits) so offline
## certification still completes - this fallback is load-bearing. The same
## scripted bots are also fieldable policies: a player that registers as
## scripted plays one deliberately, LLM or not.

import
  std/[json, math, os, random, strutils, unicode],
  bitworld/runtime,
  curly,
  sim

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  ScriptKind* = enum
    skNone = "none"
    skMirror = "mirror"
    skShark = "shark"

  Decision* = object
    move*: int          ## the raw move, already clamped into its legal range
    note*: string       ## "" when the reply carried none
    memo*: string       ## "" when the reply carried none
    scripted*: bool     ## decided by a scripted baseline, not by the model

  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string              ## anthropic transport
    bedrockEndpoint: string     ## bedrock transport: sidecar or public host
    bedrockModels: seq[string]  ## candidates, tried in order on denial
    bedrockModel: int           ## index into bedrockModels
    bedrockToken: string
    model: string
    maxOutputTokens: int
    timeoutSeconds: int
    disabled*: bool   ## true once credentials are known-unavailable
    throttled*: bool  ## true once a 429 has been seen; the server slows down

proc parseScriptKind*(text: string): ScriptKind =
  ## PLAYER_SCRIPTED values: "shark" plays the greedy foil, "" plays no
  ## scripted baseline at all, and ANY other non-empty value means `mirror`
  ## — a seat that registers scripted without naming a baseline gets the
  ## reciprocal one rather than an error.
  let value = text.strip().toLowerAscii()
  if value.len == 0: skNone
  elif value == "shark": skShark
  else: skMirror

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "ledger llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order. BEDROCK_MODEL pins
  ## a single id; without it, fall through this list — model access is a
  ## per-account Marketplace subscription, so an id that works in one account
  ## 403s in another.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  ## Haiku leads: hosted Bedrock capacity is shared account-wide and the
  ## sonnet profiles run out of daily tokens first.
  ## `us.anthropic.claude-sonnet-4-6` is deliberately ABSENT: it times out on
  ## every sidecar call, so one throttle on haiku would cascade into a whole
  ## episode of scripted fallbacks (raid round 2, 2026-08-23).
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "ledger llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds
  )
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION",
      getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "ledger llm: bedrock transport, url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "ledger llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "ledger llm: no LLM credentials; using scripted fallback"

# ---- Scripted baselines -----------------------------------------------------

const
  MirrorSend = 4
  MirrorSendWary = 1
  MirrorReturn = 50
  MirrorReturnWary = 25
  MirrorOffer = 5
  MirrorFloor = 4
  MirrorForgiveChance = 0.20
  SharkOffer = 1
  SharkFloor = 1

proc baselineRng(sim: Sim, seat: int): Rand =
  ## The baselines are pure functions of the sim's public state plus the
  ## seeded RNG, so a scripted episode is deterministic for a given seed.
  initRand(int64(sim.config.seed) * 104729 + int64(sim.round) * 131 +
    int64(seat) * 7 + 5)

proc dilemmaMoveOf(record: MeetingRecord, seat: int): int =
  if record.a == seat: record.moveA else: record.moveB

proc lastDilemmaMove(sim: Sim, partner, versus: int): int =
  ## The partner's most recent public DILEMMA move against `versus`, or -1.
  result = -1
  for record in sim.history:
    if record.game != sgDilemma:
      continue
    let hasPartner = record.a == partner or record.b == partner
    if not hasPartner:
      continue
    if versus >= 0 and record.a != versus and record.b != versus:
      continue
    result = record.dilemmaMoveOf(partner)

proc dilemmaDefections(sim: Sim, seat: int): int =
  for record in sim.history:
    if record.game != sgDilemma:
      continue
    if record.a == seat or record.b == seat:
      if record.dilemmaMoveOf(seat) == MoveDefect:
        inc result

proc hasRecord(sim: Sim, seat: int): bool =
  sim.meetingCount(seat) > 0

proc mirrorMove(sim: Sim, seat, partner: int, game: SubGame,
    first: bool): int =
  if game == sgDilemma:
    ## Tit-for-tat over the PUBLIC record: their last move against this seat
    ## if they have one, else their last against anyone. No record at all
    ## earns the benefit of the doubt.
    var reply = lastDilemmaMove(sim, partner, seat)
    if reply < 0:
      reply = lastDilemmaMove(sim, partner, -1)
    if reply < 0:
      return MoveCooperate
    if reply == MoveDefect and dilemmaDefections(sim, partner) == 1:
      ## Forgive a single lapse some of the time; an unforgiving mirror and
      ## one noisy defection lock into mutual punishment for the episode.
      var rng = baselineRng(sim, seat)
      if rng.rand(1.0) < MirrorForgiveChance:
        return MoveCooperate
    return reply
  if game == sgTrust:
    let trusted = not sim.hasRecord(partner) or sim.halo(partner) >= 0.5
    if first:
      return (if trusted: MirrorSend else: MirrorSendWary)
    return (if trusted: MirrorReturn else: MirrorReturnWary)
  if first: MirrorOffer else: MirrorFloor

proc sharkMove(game: SubGame, first: bool): int =
  case game
  of sgDilemma: MoveDefect
  of sgTrust: 0
  of sgUltimatum: (if first: SharkOffer else: SharkFloor)

proc scriptedAction*(sim: Sim, seat: int, kind: ScriptKind): Decision =
  ## The single scripted entry point. Always legal for every (subgame, role)
  ## combination; never writes a note or a memo.
  let pair = sim.pairIndexOf(sim.round, seat)
  if pair < 0:
    raise newException(LedgerError,
      "seat " & $seat & " has no meeting this round")
  let meeting = sim.plan.pairs[pair]
  let first = meeting.a == seat
  let partner = if first: meeting.b else: meeting.a
  let raw =
    if kind == skShark: sharkMove(meeting.game, first)
    else: mirrorMove(sim, seat, partner, meeting.game, first)
  result.move = clampMove(meeting.game, first, raw)
  result.scripted = true

# ---- Prompt building --------------------------------------------------------

proc coins(value: float): string =
  formatFloat(value, ffDecimal, 1)

proc seatName(sim: Sim, seat: int): string =
  if seat < 0 or seat >= sim.names.len: "(nobody)" else: sim.names[seat]

proc tallyLine(sim: Sim, seat: int): string =
  sim.seatName(seat) & " — median " & coins(sim.median(seat)) & ", " &
    $sim.meetingCount(seat) & " meetings, kind " & $sim.kind[seat] &
    " / harsh " & $sim.harsh[seat]

proc meetingLine(sim: Sim, record: MeetingRecord, viewer: int): string =
  ## `R3 vs Bolt — TRUST as INVESTOR: sent 5 (Gizmo +7, Bolt +2)`
  let isA = record.a == viewer
  let other = if isA: record.b else: record.a
  let move = if isA: record.moveA else: record.moveB
  let payMine = if isA: record.payA else: record.payB
  let payTheirs = if isA: record.payB else: record.payA
  "R" & $(record.round + 1) & " vs " & sim.seatName(other) & " — " &
    subGameName(record.game) & " as " & roleName(record.game, isA) & ": " &
    moveText(record.game, isA, move) & " (" & sim.seatName(viewer) & " +" &
    $payMine & ", " & sim.seatName(other) & " +" & $payTheirs & ")"

proc historyBlock(sim: Sim, seat: int): string =
  let records = sim.recentMeetings(seat)
  if records.len == 0:
    return "(none)"
  var lines: seq[string]
  for record in records:
    lines.add(sim.meetingLine(record, seat))
  lines.join("\n")

proc rulesBlock(sim: Sim, partner: int, game: SubGame, first: bool): string =
  ## The drawn subgame's numbers, spelled out for this seat's role.
  let them = sim.seatName(partner)
  case game
  of sgDilemma:
    "You and " & them & " each choose cooperate or defect at the same " &
      "time. If you both cooperate you get " & $PdReward & " coins each. " &
      "If you both defect you get " & $PdPunishment & " each. If you " &
      "defect while " & them & " cooperates you get " & $PdTemptation &
      " and " & them & " gets " & $PdSucker & "; if you cooperate while " &
      them & " defects you get " & $PdSucker & " and " & them & " gets " &
      $PdTemptation & "."
  of sgTrust:
    if first:
      "You start with " & $InvestorEndowment & " coins and send some " &
        "number s of them (0-" & $InvestorEndowment & ") to " & them &
        ". Whatever is sent DOUBLES on the way: " & them & " receives 2s. " &
        them & " starts with " & $TrusteeEndowment & " coins and has " &
        "already committed a return percentage p (0-100): they will return " &
        "round(2s * p / 100) coins. You end with " & $InvestorEndowment &
        " - s + returned; " & them & " ends with " & $TrusteeEndowment &
        " + 2s - returned."
    else:
      them & " starts with " & $InvestorEndowment & " coins and sends you " &
        "some number s of them (0-" & $InvestorEndowment & "). Whatever is " &
        "sent DOUBLES on the way: you receive 2s. You start with " &
        $TrusteeEndowment & " coins. You commit now to a return percentage " &
        "p (0-100): you will return round(2s * p / 100) coins. " & them &
        " ends with " & $InvestorEndowment & " - s + returned; you end " &
        "with " & $TrusteeEndowment & " + 2s - returned."
  of sgUltimatum:
    if first:
      "There are " & $Pie & " coins on the table. You offer o of them (0-" &
        $Pie & ") to " & them & ". " & them & " has already committed a " &
        "minimum acceptable offer m (0-" & $Pie & "). If o is at least m " &
        "you keep " & $Pie & " - o and " & them & " gets o; if o is below " &
        "m the deal breaks and you both get 0."
    else:
      "There are " & $Pie & " coins on the table. " & them & " offers you " &
        "o of them (0-" & $Pie & "). You commit now to a minimum " &
        "acceptable offer m (0-" & $Pie & "). If o is at least m you get o " &
        "and " & them & " keeps " & $Pie & " - o; if o is below m the deal " &
        "breaks and you both get 0."

proc legalForm*(game: SubGame, first: bool): string =
  ## The one legal form of `move` for this seat's role, in words.
  case game
  of sgDilemma:
    "\"cooperate\" or \"defect\""
  of sgTrust:
    if first: "a whole number 0 to " & $InvestorEndowment &
      ", the coins you send"
    else: "a whole number 0 to 100, the percentage of what arrives that " &
      "you return"
  of sgUltimatum:
    if first: "a whole number 0 to " & $Pie &
      ", the coins you offer out of " & $Pie
    else: "a whole number 0 to " & $Pie &
      ", the smallest offer you will accept"

proc moveExample(game: SubGame, first: bool): string =
  case game
  of sgDilemma: "\"cooperate\""
  of sgTrust: (if first: "4" else: "50")
  of sgUltimatum: (if first: "6" else: "4")

proc systemPrompt*(sim: Sim, seat: int): string =
  "You are " & sim.seatName(seat) & ", one of eight cogs in Ledger. Your " &
    "alias is permanent and public:\neverything you do is on the record " &
    "and every other cog can read it." &
    """

Rules:
- Every round you are paired with one other cog for ONE meeting. Pairings are drawn
  from a fixed rotation: over the episode you meet each of the other seven cogs the
  same number of times, at most twice each in a 14-round game.
- A meeting is one of three games, drawn per pairing: DILEMMA, TRUST, or ULTIMATUM.
  The exact numbers for your meeting are in the message below.
- Everyone decides at the same time, so you never see your partner's move for this
  meeting before you make yours. In TRUST and ULTIMATUM the second mover commits a
  RULE in advance (a return percentage, or a minimum acceptable offer) which is then
  applied to whatever the first mover did.
- Every meeting's moves and payoffs become public immediately, attached to both
  aliases forever.
- You may attach a one-line public review of your PREVIOUS round's partner. Reviews
  are signed with your alias and everyone reads them. They change no payoff.
- YOUR SCORE IS THE MEDIAN OF YOUR PER-MEETING PAYOFFS, not the total and not the
  mean. One huge score against a friend cannot lift a median; being reliably worth
  meeting can. Coins are only ever paid by the game, never transferred between cogs.

OUTPUT FORMAT: reply with ONLY one JSON object, nothing else - no
analysis, no explanation, no markdown fences, no text before or after the
object. Your reply must begin with the character { and end with }."""

proc operatorBlock(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" & prompt & "\n\n"

proc userPrompt*(sim: Sim, seat: int, prompt: string): string =
  let pair = sim.pairIndexOf(sim.round, seat)
  if pair < 0:
    raise newException(LedgerError,
      "seat " & $seat & " has no meeting this round")
  let meeting = sim.plan.pairs[pair]
  let first = meeting.a == seat
  let partner = if first: meeting.b else: meeting.a
  let game = meeting.game

  # 1 — who you are and where you stand.
  result.add("Round " & $(sim.round + 1) & " of " & $sim.config.rounds &
    ". You are " & sim.seatName(seat) & ". Your median so far: " &
    coins(sim.median(seat)) & " coins over " & $sim.meetingCount(seat) &
    " meetings (kind " & $sim.kind[seat] & " / harsh " & $sim.harsh[seat] &
    ").\n\n")

  # 2 — this meeting, the role, and the full numeric rules.
  result.add("THIS MEETING: " & sim.seatName(partner) & " — " &
    subGameName(game) & ".\n")
  result.add("YOUR ROLE: " & roleName(game, first) &
    (if game == sgDilemma: " (you both decide at the same time)."
     elif first: " (first mover)." else: " (second mover).") & "\n")
  result.add("THE RULES OF THIS MEETING: " &
    sim.rulesBlock(partner, game, first) & "\n\n")

  # 3 — the partner's public record.
  result.add("PARTNER RECORD — " & sim.seatName(partner) & ": median " &
    coins(sim.median(partner)) & " coins over " &
    $sim.meetingCount(partner) & " meetings, kind " & $sim.kind[partner] &
    " / harsh " & $sim.harsh[partner] & ".\n")
  result.add("THEIR LAST " & $HistoryWindow & " MEETINGS:\n" &
    sim.historyBlock(partner) & "\n\n")

  # 4 — the whole table.
  var table: seq[string]
  for other in 0 ..< Seats:
    table.add(sim.tallyLine(other))
  result.add("THE TABLE:\n" & table.join("\n") & "\n\n")

  # 5 — this round's four tables (the plaza is public).
  var tables: seq[string]
  for index in 0 ..< Meetings:
    let other = sim.plan.pairs[index]
    tables.add(sim.seatName(other.a) & " & " & sim.seatName(other.b) &
      " — " & subGameName(other.game))
  result.add("THIS ROUND'S TABLES: " & tables.join(" · ") & "\n\n")

  # 6 — your own last meetings.
  result.add("YOUR LAST " & $HistoryWindow & " MEETINGS:\n" &
    sim.historyBlock(seat) & "\n\n")

  # 7 — the public gossip board.
  var notes: seq[string]
  let start = max(0, sim.board.len - GossipWindow)
  for index in start ..< sim.board.len:
    let note = sim.board[index]
    notes.add("R" & $(note.round + 1) & " " & sim.seatName(note.author) &
      " on " & sim.seatName(note.subject) & ": \"" & note.text & "\"")
  result.add("THE GOSSIP BOARD (last " & $GossipWindow & " notes):\n" &
    (if notes.len > 0: notes.join("\n") else: "(none)") & "\n\n")

  # 8 — your private memo, verbatim.
  result.add("YOUR PRIVATE MEMO:\n" &
    (if sim.memos[seat].len > 0: sim.memos[seat] else: "(none)") & "\n\n")

  # 9 — who this round's review is about.
  let target = sim.noteTarget(seat)
  if target >= 0:
    result.add("NOTE TARGET: " & sim.seatName(target) & " (your partner " &
      "last round) — your \"note\" is a public review of " &
      sim.seatName(target) & ".\n\n")
  else:
    result.add("NOTE TARGET: (none this round — any \"note\" you send is " &
      "discarded).\n\n")

  # 10 — the operator's guidance, i.e. the policy.
  result.add(operatorBlock(prompt))

  # 11 — the reply line, naming the one legal form of `move` for this role.
  result.add("Reply with ONLY {\"move\": " & moveExample(game, first) &
    ", \"note\": \"…\", \"memo\": \"…\"} — \"move\" is " &
    legalForm(game, first) & "; note at most " & $MaxNoteLen &
    " characters; memo at most " & $MaxMemoLen & " characters.")

# ---- Anthropic / Bedrock transport ------------------------------------------

proc cleanText*(text: string, limit: int): string =
  ## Text over the cap is cut at a RUNE boundary with the cut marked. Every
  ## string that can reach the replay goes through here; a byte-boundary cut
  ## mid-UTF-8 is what makes replay bytes fail a strict JSON parser.
  result = text.strip()
  if result.runeLen <= limit:
    return
  result = result.runeSubStr(0, limit - 1) & "…"

proc singleLine*(text: string): string =
  ## Newlines become spaces and every other control character is dropped, so
  ## a note stays one line on the board and in the feed.
  for rune in text.runes:
    let value = int32(rune)
    if value == 10 or value == 13 or value == 9:
      result.add(' ')
    elif value < 32 or value == 127:
      discard
    else:
      result.add($rune)

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating fences
  ## and prose before or after the object.
  let start = text.find('{')
  let stop = text.rfind('}')
  if start < 0 or stop <= start:
    ## Quote the head of the reply so a hosted log shows WHAT the model sent
    ## instead of JSON (prose, a refusal, a cut-off analysis...).
    raise newException(LedgerError, "no JSON object in response: " &
      cleanText(text, 160).replace("\n", " "))
  parseJson(text[start .. stop])

proc requestFor(client: LlmClient, system, user: string):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf(client: LlmClient, response: Response, error, url: string):
    string =
  ## The text of one batched reply, or a LedgerError describing why there is
  ## none. Auth failures disable the client; model-access and throttle
  ## failures rotate the Bedrock model for the next batch.
  if error.len > 0:
    raise newException(LedgerError, "llm transport: " & cleanText(error, 300))
  if response.code == 401 or response.code == 403:
    let detail = cleanText(response.body, 400)
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(LedgerError,
        "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(LedgerError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    client.throttled = true
    discard client.tryNextBedrockModel("throttled")
    raise newException(LedgerError,
      "llm throttled (429): " & cleanText(response.body, 300))
  if response.code < 200 or response.code >= 300:
    raise newException(LedgerError, "anthropic error " & $response.code &
      ": " & cleanText(response.body, 300))
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(LedgerError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(LedgerError, "reply cut off at max_tokens before " &
      "any JSON: " & cleanText(result, 160).replace("\n", " "))

# ---- Reply parsing ----------------------------------------------------------

proc parseNumericMove(text: string): int =
  ## Numeric strings, tolerating a trailing percent sign or a coins suffix.
  var body = text.strip()
  for suffix in ["%", "coins", "coin"]:
    if body.toLowerAscii().endsWith(suffix):
      body = body[0 ..< body.len - suffix.len].strip()
  if body.len == 0:
    raise newException(LedgerError, "move is not a number: " & text)
  var value: float
  try:
    value = parseFloat(body)
  except ValueError:
    raise newException(LedgerError, "move is not a number: " & text)
  int(floor(value + 0.5))

proc parseMoveValue*(game: SubGame, first: bool, node: JsonNode): int =
  ## One always-present `move` field for all five role cases. Words are only
  ## legal in the dilemma; every other role wants a number. Anything outside
  ## the legal range is CLAMPED by the caller, not rejected.
  if node.isNil:
    raise newException(LedgerError, "no move in response")
  if node.kind == JInt:
    return node.getInt()
  if node.kind == JFloat:
    return int(floor(node.getFloat() + 0.5))
  if node.kind == JBool:
    if game != sgDilemma:
      raise newException(LedgerError, "move must be a number: " & $node)
    return (if node.getBool(): MoveCooperate else: MoveDefect)
  if node.kind != JString:
    raise newException(LedgerError,
      "move must be a number or a word: " & $node)
  let text = node.getStr().strip()
  if text.len == 0:
    raise newException(LedgerError, "empty move")
  if game == sgDilemma:
    let word = text.toLowerAscii()
    if word == "cooperate" or word == "c" or word == "coop" or
        word == "cooperation":
      return MoveCooperate
    if word == "defect" or word == "d" or word == "defection":
      return MoveDefect
  parseNumericMove(text)

proc parseDecision*(game: SubGame, first: bool, payload: JsonNode): Decision =
  ## Tolerant by design: parse what the model meant, clamp what it
  ## over-reached on, and only reject a reply with no usable move at all.
  result.note = cleanText(singleLine(payload{"note"}.getStr()), MaxNoteLen)
  result.memo = cleanText(payload{"memo"}.getStr(), MaxMemoLen)
  let raw = parseMoveValue(game, first, payload{"move"})
  result.move = clampMove(game, first, raw)
  if result.move != raw:
    echo "ledger llm: move ", raw, " out of range for ",
      subGameName(game), " ", roleName(game, first), "; clamped to ",
      result.move

# ---- The batched decision path ----------------------------------------------

proc seatForBatchPosition*(seats, open: seq[int], position: int): int =
  ## The seat that asked for the reply at batch POSITION `position`.
  ## `curly.makeRequests` aligns its results with the order the requests were
  ## QUEUED, never with the order they came back in, so a reply is matched by
  ## its position in the batch and by nothing else. Mis-indexing here is the
  ## failure mode a batched rewrite invites — seat 3's answer landing on seat
  ## 6 — and it is silent, so it has its own test.
  seats[open[position]]

proc decideAll*(
  client: LlmClient,
  sim: Sim,
  seats: seq[int],
  prompts: seq[string],
  scripted: seq[ScriptKind]
): seq[Decision] =
  ## One decision per seat in `seats`, in order, from ONE parallel batch of
  ## HTTP requests. Never raises: any failure falls back to the scripted
  ## baseline so the episode always advances. `prompts` and `scripted` are
  ## indexed by SEAT.
  result = newSeq[Decision](seats.len)
  var open: seq[int]     ## indexes into `seats` still undecided
  for index, seat in seats:
    let kind = scripted[seat]
    if kind != skNone or client.disabled:
      result[index] = scriptedAction(sim, seat,
        (if kind == skNone: skMirror else: kind))
    else:
      open.add(index)
  for attempt in 0 .. 1:
    if open.len == 0 or client.disabled:
      break
    var batch: RequestBatch
    for index in open:
      let seat = seats[index]
      let pair = sim.pairIndexOf(sim.round, seat)
      let meeting = sim.plan.pairs[pair]
      let first = meeting.a == seat
      var user = sim.userPrompt(seat, prompts[seat])
      if attempt > 0:
        user.add("\nYour previous reply was invalid. Respond with ONLY the " &
          "requested JSON object, with \"move\" " &
          legalForm(meeting.game, first) & ".")
      let request = client.requestFor(systemPrompt(sim, seat), user)
      batch.post(request.url, request.headers, request.body, $index)
    let responses = client.curl.makeRequests(batch, client.timeoutSeconds)
    var stillOpen: seq[int]
    for position, index in open:
      let seat = seatForBatchPosition(seats, open, position)
      let pair = sim.pairIndexOf(sim.round, seat)
      let meeting = sim.plan.pairs[pair]
      let first = meeting.a == seat
      try:
        ## `responses` is indexed by BATCH POSITION, which is the order the
        ## requests were queued in — never the order they came back in.
        let text = client.textOf(responses[position].response,
          responses[position].error, batch[position].url)
        result[index] = parseDecision(meeting.game, first,
          extractJsonObject(text))
      except CatchableError as error:
        echo "ledger llm: seat ", seat, " attempt ", attempt, " failed: ",
          cleanText(error.msg, 300)
        stillOpen.add(index)
    open = stillOpen
  for index in open:
    let seat = seats[index]
    echo "ledger: seat ", seat, " falling back to scripted decision"
    result[index] = scriptedAction(sim, seat, skMirror)

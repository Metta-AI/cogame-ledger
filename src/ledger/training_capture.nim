## Optional central native evidence; never changes Ledger requests or gameplay.
import std/[base64, json, math, options, os, parsejson, streams, strutils, tables, uri]
import crunchy, curly
import bitworld/runtime
import ./decision_trajectory, ./sim
export decision_trajectory, options

const
  MaxRequestBytes = 131072
  MaxResponseBytes = 32768
  MaxHeaderBytes = 4096
  MaxPrivatePayloadBytes = 16777216

type
  CapturedAttempt = ref object
    evidence: DecisionAttempt
    diagnostic: JsonNode
    retainedBytes: int
  CapturedDecision = ref object
    observation, actual: JsonNode
    attempts: seq[CapturedAttempt]
    selected: int
    game: SubGame
    first, scripted: bool
  RuntimeCapture* = ref object
    trajectory: DecisionTrajectory
    rounds: Table[int, seq[CapturedDecision]]
    physical: JsonNode
    retainedBytes: int

proc scalarUtf8(text: string): bool =
  ## RFC 3629: Nim's validateUtf8 alone permits encoded surrogate code points.
  var index = 0
  while index < text.len:
    let first = ord(text[index])
    var size = 1
    if first <= 0x7f: discard
    elif first in 0xc2 .. 0xdf: size = 2
    elif first in 0xe0 .. 0xef: size = 3
    elif first in 0xf0 .. 0xf4: size = 4
    else: return false
    if index + size > text.len: return false
    for offset in 1 ..< size:
      if ord(text[index + offset]) notin 0x80 .. 0xbf: return false
    if size >= 3:
      let second = ord(text[index + 1])
      if first == 0xe0 and second < 0xa0 or first == 0xed and second > 0x9f or
          first == 0xf0 and second < 0x90 or first == 0xf4 and second > 0x8f:
        return false
    index += size
  true

proc scalarJson(node: JsonNode, depth = 0): bool =
  if node == nil or depth > 64: return false
  case node.kind
  of JString: return scalarUtf8(node.getStr())
  of JObject:
    for key, value in node:
      if not scalarUtf8(key) or not scalarJson(value, depth + 1): return false
  of JArray:
    for value in node:
      if not scalarJson(value, depth + 1): return false
  of JFloat:
    if node.getFloat().classify in {fcNan, fcInf, fcNegInf}: return false
  else: discard
  true

proc strictRawObject(text: string): JsonNode =
  ## Independent admission parser: the gameplay decoder remains unchanged.
  if not scalarUtf8(text): raise newException(ValueError, "raw JSON is not Unicode scalar UTF-8")
  let first = text.find('{')
  let last = text.rfind('}')
  if first < 0 or last < first: raise newException(ValueError, "no raw JSON object")
  let source = text[first .. last]
  var quoted = false
  var index = 0
  while index < source.len:
    let character = source[index]
    if quoted:
      if character == '\\':
        inc index
        if index >= source.len or source[index] notin {'"', '\\', '/', 'b', 'f', 'n', 'r', 't', 'u'}:
          raise newException(ValueError, "non-JSON string escape")
        if source[index] == 'u':
          for offset in 1 .. 4:
            if index + offset >= source.len or source[index + offset] notin {'0'..'9', 'a'..'f', 'A'..'F'}:
              raise newException(ValueError, "invalid Unicode escape")
          index += 4
      elif character == '"': quoted = false
      elif ord(character) < 32: raise newException(ValueError, "unescaped control character")
    elif character == '"': quoted = true
    elif ord(character) <= 32 and character notin {' ', '\t', '\r', '\n'}:
      raise newException(ValueError, "non-JSON whitespace/control character")
    elif character == '/': raise newException(ValueError, "JSON comments are forbidden")
    inc index
  if quoted: raise newException(ValueError, "unterminated JSON string")
  var parser: JsonParser
  parser.open(newStringStream(source), "private raw action")
  defer: parser.close()
  discard parser.getTok()
  proc value(parser: var JsonParser, depth: int): JsonNode =
    if depth > 32: raise newException(ValueError, "raw JSON depth bound exceeded")
    case parser.tok
    of tkCurlyLe:
      result = newJObject()
      discard parser.getTok()
      if parser.tok == tkCurlyRi:
        discard parser.getTok()
        return
      while true:
        if parser.tok != tkString: raise newException(ValueError, "JSON object key required")
        let key = parser.a
        if not scalarUtf8(key): raise newException(ValueError, "non-Unicode decoded JSON key")
        if result.hasKey(key): raise newException(ValueError, "duplicate JSON key: " & key)
        discard parser.getTok()
        parser.eat(tkColon)
        result[key] = value(parser, depth + 1)
        if parser.tok == tkCurlyRi:
          discard parser.getTok()
          break
        parser.eat(tkComma)
    of tkBracketLe:
      result = newJArray()
      discard parser.getTok()
      if parser.tok == tkBracketRi:
        discard parser.getTok()
        return
      while true:
        result.add(value(parser, depth + 1))
        if parser.tok == tkBracketRi:
          discard parser.getTok()
          break
        parser.eat(tkComma)
    of tkString:
      if not scalarUtf8(parser.a): raise newException(ValueError, "non-Unicode decoded JSON string")
      result = %parser.a
      discard parser.getTok()
    of tkInt, tkFloat:
      let token = parser.a
      # Enforce JSON number spelling independently of Nim's permissive lexer.
      var cursor = 0
      if token[cursor] == '-': inc cursor
      if cursor >= token.len: raise newException(ValueError, "invalid JSON number")
      if token[cursor] == '0': inc cursor
      elif token[cursor] in {'1'..'9'}:
        while cursor < token.len and token[cursor] in {'0'..'9'}: inc cursor
      else: raise newException(ValueError, "invalid JSON number")
      if cursor < token.len and token[cursor] == '.':
        inc cursor
        let start = cursor
        while cursor < token.len and token[cursor] in {'0'..'9'}: inc cursor
        if cursor == start: raise newException(ValueError, "invalid JSON fraction")
      if cursor < token.len and token[cursor] in {'e', 'E'}:
        inc cursor
        if cursor < token.len and token[cursor] in {'+', '-'}: inc cursor
        let start = cursor
        while cursor < token.len and token[cursor] in {'0'..'9'}: inc cursor
        if cursor == start: raise newException(ValueError, "invalid JSON exponent")
      if cursor != token.len: raise newException(ValueError, "invalid JSON number")
      if parser.tok == tkInt: result = %parseBiggestInt(token)
      else:
        let number = parseFloat(token)
        if number.classify in {fcNan, fcInf, fcNegInf}:
          raise newException(ValueError, "non-finite raw JSON number")
        result = %number
      discard parser.getTok()
    of tkTrue, tkFalse:
      result = %(parser.tok == tkTrue)
      discard parser.getTok()
    of tkNull:
      result = newJNull()
      discard parser.getTok()
    else: raise newException(ValueError, "invalid raw JSON value")
  result = value(parser, 0)
  if parser.tok != tkEof or result.kind != JObject:
    raise newException(ValueError, "one raw JSON object required")

proc rootSchedule*(sim: Sim): JsonNode =
  var config = sim.config
  config.rounds = MaxRounds
  initSim(config).scheduleJson()

proc physicalFamily*(sim: Sim): string =
  "ledger-root-schedule-v1-" & sha256($sim.rootSchedule()).toHex.toLowerAscii()

proc physicalSetup*(sim: Sim): JsonNode =
  %*{"seed": sim.config.seed, "rounds": sim.config.rounds,
    "schedule": sim.scheduleJson(), "aliases": sim.names,
    "investor_endowment": InvestorEndowment, "trustee_endowment": TrusteeEndowment,
    "trust_multiplier": TrustMultiplier, "pie": Pie,
    "dilemma_reward": PdReward, "dilemma_temptation": PdTemptation,
    "dilemma_punishment": PdPunishment, "dilemma_sucker": PdSucker,
    "note_max_runes": MaxNoteLen, "memo_max_runes": MaxMemoLen,
    "min_round_interval_ms": sim.config.minRoundIntervalMs,
    "timeout_seconds": sim.config.llmTimeoutSeconds,
    "episode_timeout_seconds": sim.config.episodeTimeoutSeconds,
    "hosted_timeout_override": getEnv("COWORLD_TIMEOUT_SECONDS")}

proc destinationIdentity(value: string): string =
  if value.len == 0: return ""
  if value.isHttpCogameUri():
    let parsed = parseUri(value)
    # Signed query strings cannot turn the same public upload object private.
    parsed.scheme.toLowerAscii() & "://" & parsed.hostname.toLowerAscii() &
      ":" & (if parsed.port.len > 0: parsed.port
        elif parsed.scheme.toLowerAscii() == "https": "443" else: "80") &
      decodeUrl(parsed.path).normalizedPath()
  else:
    pathFromCogameUri(value, CogameSaveTrajectoryUriEnv).absolutePath().normalizedPath()

proc newRuntimeCapture*(sim: Sim): RuntimeCapture =
  let uri = getEnv(CogameSaveTrajectoryUriEnv)
  if uri.len == 0: return nil
  let destination = destinationIdentity(uri)
  for publicUri in [getEnv("COGAME_RESULTS_URI"), getEnv("COGAME_SAVE_REPLAY_URI")]:
    if publicUri.len > 0 and destination == destinationIdentity(publicUri):
      raise newException(ValueError, "private trajectory URI collides with public artifact")
  for key in ["COWORLD_EPISODE_ID", "COWORLD_GAME_VERSION", "COWORLD_SOURCE_REVISION", "COWORLD_GAME_NAME"]:
    if not scalarUtf8(getEnv(key)):
      raise newException(ValueError, "non-Unicode private identity: " & key)
  let setup = sim.physicalSetup()
  result = RuntimeCapture(trajectory: newDecisionTrajectory(getEnv("COWORLD_EPISODE_ID"),
    sim.physicalFamily(), "ledger", getEnv("COWORLD_GAME_VERSION"),
    getEnv("COWORLD_SOURCE_REVISION")), rounds: initTable[int, seq[CapturedDecision]](),
    physical: %*{"split_group": sim.physicalFamily(), "setup": setup,
      "setup_sha256": sha256($setup).toHex.toLowerAscii(),
      "root_schedule": sim.rootSchedule()})

proc safeDiagnostic*(message: string): string =
  if not scalarUtf8(message): return "diagnostic contains invalid UTF-8; bytes not text"
  if message.len > 512: "capture diagnostic exceeds 512 bytes"
  else: message

proc captureGap*(capture: RuntimeCapture, round, seat: int, reason: string) =
  if capture == nil: return
  echo "ledger capture: ", safeDiagnostic(reason)
  if capture.rounds.hasKey(round) and seat >= 0 and seat < Seats:
    let gaps = capture.rounds[round][seat].observation["capture_gaps"]
    if gaps.len < 8: gaps.add(%safeDiagnostic(reason))

proc beginCaptureRound*(capture: RuntimeCapture, sim: Sim,
    observations: seq[JsonNode], selection: JsonNode) =
  if capture == nil: return
  if sim.round < 0 or sim.round >= MaxRounds or observations.len != Seats:
    raise newException(ValueError, "invalid native capture round")
  var decisions: seq[CapturedDecision]
  for seat in 0 ..< Seats:
    let meeting = sim.plan.pairs[sim.pairIndexOf(sim.round, seat)]
    var view = observations[seat]
    let size = ($view).len + ($capture.physical).len + ($selection).len + 512
    if capture.retainedBytes + size > MaxPrivatePayloadBytes:
      view = newJNull()
    else: capture.retainedBytes += size
    decisions.add(CapturedDecision(selected: -1, game: meeting.game,
      first: meeting.a == seat, actual: newJNull(), observation: %*{
        "view": view, "prompt_selection": selection,
        "physical_family": capture.physical, "capture_gaps": [],
        "attempt_diagnostics": [], "native_events": [],
        "receipt_authority": "external authenticated receipt/source/image/slot joins required",
        "latency_scope": "makeRequests dispatch-to-batch-reader join; per-transfer timing unavailable"}))
    if view.kind == JNull:
      decisions[^1].observation["capture_gaps"].add(%"episode private payload bound exceeded; view unavailable")
  capture.rounds[sim.round] = decisions

proc storeAttempt(capture: RuntimeCapture, entry: CapturedAttempt,
    evidence: DecisionAttempt, diagnostic: JsonNode): bool =
  let size = ($attemptEvidenceJson(evidence)).len + ($diagnostic).len
  if capture.retainedBytes + size - entry.retainedBytes > MaxPrivatePayloadBytes:
    return false
  capture.retainedBytes += size - entry.retainedBytes
  entry.evidence = evidence
  entry.diagnostic = diagnostic
  entry.retainedBytes = size
  true

proc requestedAttempt*(capture: RuntimeCapture, round, seat, index: int, body: string) =
  if capture == nil: return
  let decision = capture.rounds[round][seat]
  if index != decision.attempts.len or index > 1:
    raise newException(ValueError, "native attempt index exceeds actual two-call contract")
  let entry = CapturedAttempt(evidence: newDecisionAttempt($round & "-" & $seat & "-" & $index,
    "socket-player", aoModel), diagnostic: %*{"attempt_index": index,
      "request_body_b64": nil, "request_bytes": body.len,
      "request_slot_header": seat, "capture_error": nil})
  decision.attempts.add(entry)
  if body.len <= MaxRequestBytes:
    entry.diagnostic["request_body_b64"] = %encode(body)
  try:
    if body.len > MaxRequestBytes or not scalarUtf8(body):
      raise newException(ValueError, "request bytes exceed private bound or are not UTF-8")
    var attempt = entry.evidence
    attempt.request = parseJson(body)
    if attempt.request.kind != JObject or attempt.request["system"].kind != JString or
        attempt.request["messages"].kind != JArray:
      raise newException(ValueError, "native request shape unavailable")
    attempt.prompt = %*[{"role": "system", "content": attempt.request["system"]}]
    for message in attempt.request["messages"]: attempt.prompt.add(copy(message))
    attempt.decoder = %*{"max_tokens": attempt.request["max_tokens"]}
    for key in ["temperature", "top_p", "top_k", "output_config"]:
      if attempt.request.hasKey(key): attempt.decoder[key] = copy(attempt.request[key])
    let model = attempt.request{"model"}
    if model != nil and model.kind == JString: attempt.model = some(model.getStr())
    let diagnostic = copy(entry.diagnostic)
    diagnostic["request_body_b64"] = %encode(body)
    if not capture.storeAttempt(entry, attempt, diagnostic):
      raise newException(ValueError, "episode private payload bound exceeded; request unavailable")
  except CatchableError as error:
    entry.diagnostic["capture_error"] = %safeDiagnostic(error.msg)
    capture.captureGap(round, seat, error.msg)

proc receivedAttempt*(capture: RuntimeCapture, round, seat, index: int,
    response: Response, error: string, elapsedMs: float) =
  if capture == nil: return
  let entry = capture.rounds[round][seat].attempts[index]
  var attempt = entry.evidence
  attempt.latencyMs = some(elapsedMs)
  attempt.responseReaderJoined = some(true)
  attempt.responseComplete = some(error.len == 0 and response.code > 0)
  if response.code > 0: attempt.httpStatus = some(response.code)
  var headers = initTable[string, string]()
  var headerBytes = 0
  for (name, value) in response.headers:
    let lower = name.toLowerAscii()
    if lower in ["content-type", "request-id", "x-request-id",
        "x-softmax-llm-call-id", "x-openrouter-generation-id"]:
      headerBytes += name.len + value.len
      if not scalarUtf8(value) or headerBytes > MaxHeaderBytes:
        raise newException(ValueError, "safe response header bytes unavailable")
      headers[lower] = value
  attempt.responseHeaders = some(headers)
  for key in ["x-softmax-llm-call-id", "x-openrouter-generation-id"]:
    if headers.hasKey(key):
      attempt.platformCallId = some(headers[key])
      break
  for key in ["request-id", "x-request-id"]:
    if headers.hasKey(key):
      attempt.providerRequestId = some(headers[key])
      break
  if error.len > 0:
    attempt.rejectionReason = some(safeDiagnostic(error))
  elif response.body.len <= MaxResponseBytes:
    attempt.responseBodyB64 = some(encode(response.body))
    if scalarUtf8(response.body): attempt.rawResponse = %response.body
    else:
      attempt.rejectionReason = some("response bytes are not Unicode scalar UTF-8; exact bytes retained as base64")
    try:
      let payload = parseJson(response.body)
      if payload.kind == JObject:
        for key in ["model", "stop_reason"]:
          let value = payload{key}
          if value != nil and value.kind == JString and scalarUtf8(value.getStr()):
            if key == "model": attempt.model = some(value.getStr())
            else: attempt.stopReason = some(value.getStr())
        let usage = payload{"usage"}
        if usage != nil and usage.kind == JObject:
          for key in ["input_tokens", "output_tokens"]:
            let value = usage{key}
            if value != nil and value.kind == JInt and value.getBiggestInt() >= 0:
              if key == "input_tokens": attempt.inputTokens = some(value.getInt())
              else: attempt.outputTokens = some(value.getInt())
    except CatchableError: discard
  else:
    attempt.rejectionReason = some("response exceeds private byte bound; original bytes unavailable")
    capture.captureGap(round, seat, attempt.rejectionReason.get())
  if not capture.storeAttempt(entry, attempt, entry.diagnostic):
    capture.captureGap(round, seat, "episode private payload bound exceeded; response unavailable")

proc parsedAttempt*(capture: RuntimeCapture, round, seat, index, move: int,
    note, memo: string) =
  if capture == nil: return
  let decision = capture.rounds[round][seat]
  let entry = decision.attempts[index]
  var attempt = entry.evidence
  if not scalarUtf8(note) or not scalarUtf8(memo):
    raise newException(ValueError, "native parsed command contains invalid UTF-8; no text target")
  attempt.parsedAction = %*{"move": move, "note": note, "memo": memo}
  if not capture.storeAttempt(entry, attempt, entry.diagnostic):
    capture.captureGap(round, seat, "episode private payload bound exceeded; model target unavailable")
  decision.selected = index

proc decodedText*(capture: RuntimeCapture, round, seat, index: int, text: string) =
  if capture == nil: return
  let entry = capture.rounds[round][seat].attempts[index]
  var attempt = entry.evidence
  if text.len <= MaxResponseBytes and scalarUtf8(text):
    attempt.response = %text
  else:
    attempt.rejectionReason = some("decoded text exceeds capture bound or is invalid UTF-8; original response bytes are separate")
  if not capture.storeAttempt(entry, attempt, entry.diagnostic):
    capture.captureGap(round, seat, "episode private payload bound exceeded; decoded text unavailable")

proc failedAttempt*(capture: RuntimeCapture, round, seat, index: int, reason: string) =
  if capture == nil: return
  let decision = capture.rounds[round][seat]
  if index < decision.attempts.len:
    decision.attempts[index].evidence.rejectionReason = some(safeDiagnostic(reason))

proc appliedCaptureRound*(capture: RuntimeCapture, sim: Sim,
    committedNotes, committedMemos: seq[string]) =
  if capture == nil: return
  for seat in 0 ..< Seats:
    let decision = capture.rounds[sim.round][seat]
    var move = -1
    var memoAfter = ""
    var gossip = newJNull()
    for event in sim.events:
      if event.round != sim.round: continue
      if event.kind == evMeeting and seat in [event.seat, event.other]:
        let first = event.seat == seat
        move = if first: event.moveA else: event.moveB
        memoAfter = if first: event.memoA else: event.memoB
        decision.scripted = if first: event.scriptedA else: event.scriptedB
        let native = event.eventToJson()
        decision.observation["meeting_event_sha256"] = %sha256($native).toHex.toLowerAscii()
        # The full native replay already holds both memos. Per-seat private
        # evidence retains only its own memo, plus a full-event witness hash.
        let own = copy(native)
        let otherMemo = if first: "memoB" else: "memoA"
        if own.hasKey(otherMemo): own.delete(otherMemo)
        decision.observation["native_events"].add(own)
      elif event.kind == evGossip and event.seat == seat:
        gossip = event.eventToJson()
        decision.observation["native_events"].add(gossip)
    if move < 0: raise newException(ValueError, "actual native meeting missing")
    decision.actual = %*{"move": move, "note": committedNotes[seat], "memo": committedMemos[seat]}
    decision.observation["memo_after"] = %memoAfter
    decision.observation["gossip_event"] = gossip
    decision.observation["note_disposition"] = %(
      if committedNotes[seat].len == 0: "empty command"
      elif sim.noteTarget(seat) < 0: "no note target; native command discarded"
      else: "native gossip committed")

proc strictApplied(decision: CapturedDecision, text: string) =
  let raw = strictRawObject(text)
  for key in raw.keys:
    if key notin ["move", "note", "memo"]:
      raise newException(ValueError, "unknown supplied action field: " & key)
  let value = raw{"move"}
  var move: int
  if value != nil and value.kind == JInt: move = value.getInt()
  elif value != nil and value.kind == JString and decision.game == sgDilemma:
    case value.getStr()
    of "cooperate": move = MoveCooperate
    of "defect": move = MoveDefect
    else: raise newException(ValueError, "native-tolerated alternate move encoding excluded from strict targets")
  else: raise newException(ValueError, "native-tolerated move type/coercion excluded from strict targets")
  let (lo, hi) = legalMoveRange(decision.game, decision.first)
  if move < lo or move > hi or move != decision.actual["move"].getInt():
    raise newException(ValueError, "raw move differs from exact native legal execution")
  for key in ["note", "memo"]:
    if raw.hasKey(key) and (raw[key].kind != JString or raw[key] != decision.actual[key]):
      raise newException(ValueError, "raw supplied " & key & " differs from native committed command")
  let view = decision.observation["view"]
  if view.kind == JNull: raise newException(ValueError, "frozen private view unavailable")
  let memo = decision.actual["memo"].getStr()
  if decision.observation["memo_after"].getStr() != (if memo.len > 0: memo else: view["memo"].getStr()):
    raise newException(ValueError, "native memo KEEP/write effect differs")
  let note = decision.actual["note"].getStr()
  let gossip = decision.observation["gossip_event"]
  if note.len > 0 and view["noteTarget"].kind != JNull:
    if gossip.kind != JObject or gossip["text"].getStr() != note:
      raise newException(ValueError, "native gossip event differs from committed command")
  elif gossip.kind != JNull:
    raise newException(ValueError, "unexpected native gossip for empty/no-target command")

proc finishCapture*(capture: RuntimeCapture, outcome: JsonNode) =
  if capture == nil: return
  for round in 0 ..< MaxRounds:
    if not capture.rounds.hasKey(round): continue
    for seat, decision in capture.rounds[round]:
      var attempts: seq[DecisionAttempt]
      var selected = none(string)
      var status = if decision.actual.kind == JNull: asMissing else: asRejected
      for index, entry in decision.attempts:
        decision.observation["attempt_diagnostics"].add(entry.diagnostic)
        var attempt = entry.evidence
        attempt.accepted = false
        if index == decision.selected and not decision.scripted and decision.actual.kind != JNull and
            attempt.parsedAction == decision.actual and attempt.response.kind == JString and
            attempt.responseComplete == some(true) and attempt.httpStatus.isSome and
            attempt.httpStatus.get() >= 200 and attempt.httpStatus.get() < 300 and
            attempt.responseBodyB64.isSome and attempt.rawResponse.kind == JString and
            entry.diagnostic["request_body_b64"].kind == JString and
            attempt.request.kind == JObject and attempt.prompt.kind == JArray and
            attempt.platformCallId.isSome:
          try:
            decision.strictApplied(attempt.response.getStr())
            attempt.accepted = true
          except CatchableError as error: attempt.rejectionReason = some(safeDiagnostic(error.msg))
        if attempt.accepted:
          selected = some(attempt.attemptId)
          status = asAccepted
        attempts.add(attempt)
      if decision.scripted and decision.actual.kind != JNull:
        var actual = newDecisionAttempt($round & "-" & $seat & "-fallback",
          "engine-scripted-or-fallback", aoFallback)
        actual.parsedAction = copy(decision.actual)
        actual.accepted = true
        attempts.add(actual)
        selected = some(actual.attemptId)
        status = asFallback
      decision.observation["strict_raw_fields_enforced"] = %true
      var originalAttempts = newJArray()
      for attempt in attempts: originalAttempts.add(attemptEvidenceJson(attempt))
      let original = %*{"observation": decision.observation, "attempts": originalAttempts,
        "executed_action": decision.actual, "actual_scripted": decision.scripted}
      var actual = decision.actual
      if not scalarJson(original):
        # Preserve the exact original bytes, including invalid scalar encodings.
        # A rejected action must not poison the entire private JSONL artifact.
        decision.observation = %*{"capture_gaps": [
          "non-Unicode native evidence; original JSON bytes retained as base64; target excluded"],
          "actual_scripted": decision.scripted,
          "invalid_native_evidence_json_b64": encode($original)}
        attempts = @[]
        selected = none(string)
        actual = newJNull()
        if status != asFallback: status = asRejected
      capture.trajectory.recordDecision($round & "-" & $seat, $seat, decision.observation,
        attempts, selected, actual, status,
        fallbackOrigin = (if decision.scripted: some("engine-scripted-or-fallback") else: none(string)))
  var privateOutcome = outcome
  var scores = outcome{"scores"}
  if not scalarJson(outcome):
    privateOutcome = %*{"capture_gaps": ["non-Unicode native outcome; original JSON bytes retained as base64"],
      "invalid_native_outcome_json_b64": encode($outcome)}
    if not scalarJson(scores): scores = newJNull()
  capture.trajectory.finish(if outcome{"reason"}.getStr() == "complete": esCompleted else: esTruncated,
    privateOutcome, scores)
  if capture.trajectory.eventsJsonl().len > MaxPrivatePayloadBytes:
    raise newException(ValueError, "serialized private episode exceeds 16 MiB; publication omitted, no truncation")
  capture.trajectory.writeEventsToUri(getEnv(CogameSaveTrajectoryUriEnv))

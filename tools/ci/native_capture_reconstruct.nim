## Native setup/prefix proof and independent reconstruction of complete runs.
import std/[json, os, strutils, tables]
import ledger/[sim, llm, prompts, server, training_capture]
import crunchy

if paramCount() == 1 and paramStr(1) == "recover":
  var config = defaultGameConfig()
  for seat in 0 ..< Seats: config.players.add(PlayerConfig(name: "component " & $seat))
  var state = initSim(config)
  state.beginRound()
  var safe, invalid: array[Meetings, array[2, int]]
  var flags: array[Meetings, array[2, bool]]
  for pair, meeting in state.plan.pairs:
    safe[pair] = [scriptedAction(state, meeting.a, skMirror).move,
      scriptedAction(state, meeting.b, skMirror).move]
    flags[pair] = [true, true]
  invalid = safe
  let meeting = state.plan.pairs[Meetings - 1]
  invalid[Meetings - 1][1] = legalMoveRange(meeting.game, false)[1] + 1
  let before = $state.tableStateJson()
  var beforeEvents = newJArray()
  for event in state.events: beforeEvents.add(event.eventToJson())
  var rejected = false
  var proposedMemos = newSeq[string](Seats)
  for seat in 0 ..< Seats: proposedMemos[seat] = "must-not-commit-" & $seat
  try: state.applyRound(invalid, newSeq[string](Seats), proposedMemos, flags)
  except LedgerError: rejected = true
  doAssert rejected and $state.tableStateJson() == before
  var afterEvents = newJArray()
  for event in state.events: afterEvents.add(event.eventToJson())
  doAssert afterEvents == beforeEvents
  for memo in state.memos: doAssert memo == ""
  state.applyRound(safe, newSeq[string](Seats), newSeq[string](Seats), flags)
  var meetings = 0
  for event in state.events:
    if event.kind == evMeeting:
      doAssert event.scriptedA and event.scriptedB
      doAssert [event.moveA, event.moveB] == safe[event.pair]
      inc meetings
  doAssert meetings == Meetings and state.roundsPlayed == 1
  echo $(%*{"status": "pass", "actual_native_transaction_rejected_and_state_unchanged": true,
    "actual_native_recovery_scripted_flags_and_moves": true, "HTTP_calls": 0,
    "full_server_games": 0, "qualification": "actual applyRound rejection/recovery component; whole server catch branch not forced"})
  quit(0)

var config = defaultGameConfig()
for seat in 0 ..< Seats: config.players.add(PlayerConfig(name: "fixture " & $seat))
var families = newJArray()
for seed in [0, 1, 11]:
  config.seed = seed
  config.rounds = MaxRounds
  let root = initSim(config)
  let schedule = root.scheduleJson()
  for horizon in [7, 14]:
    config.rounds = horizon
    let shorter = initSim(config)
    let actual = shorter.scheduleJson()
    doAssert actual.len == horizon
    for round in 0 ..< horizon: doAssert actual[round] == schedule[round]
    doAssert shorter.physicalFamily() == root.physicalFamily()
  config.rounds = MaxRounds
  var renamedConfig = config
  for seat in 0 ..< Seats: renamedConfig.players[seat].name = "different policy " & $seat
  let renamed = initSim(renamedConfig)
  doAssert renamed.scheduleJson() == schedule
  doAssert renamed.names == root.names
  families.add(%*{"seed": seed, "split_group": root.physicalFamily(),
    "native_root_schedule": schedule, "seven_fourteen_prefixes_match": true,
    "policy_name_changes_leave_aliases_and_mechanics_unchanged": true})
doAssert families[0]["split_group"] != families[1]["split_group"]
# Different full roots must not conceal an identical requested shorter world.
for horizon in [7, 14]:
  var identical = true
  for round in 0 ..< horizon:
    if families[0]["native_root_schedule"][round] != families[1]["native_root_schedule"][round]:
      identical = false
  doAssert not identical
echo $(%*{"family_proof": families, "prospective_train_seed": 0,
  "prospective_validation_seed": 1,
  "zero_full_games_or_provider_calls": true,
  "qualification": "native initSim and scheduleJson; no model targets"})

if paramCount() == 1:
  let directory = paramStr(1)
  let replay = parseFile(directory / "replay.json")
  let results = parseFile(directory / "results.json")
  var actualConfig = defaultGameConfig()
  actualConfig.update(readFile(directory / "config.json"))
  let selection = promptSelection(parseFile(directory / "config.json"))
  var events: seq[GameEvent]
  for value in replay["events"]: events.add(eventFromJson(value))
  let frames = replayMatch(actualConfig, events)
  doAssert frames[^1].resultsJson() == results
  doAssert replay["results"] == results
  var frozen = initTable[int, int]()
  for index, event in events:
    if event.kind == evRound: frozen[event.round] = index + 1
  var decisions, promptsChecked, projectedActions, safeOwnMemoEvents = 0
  for line in lines(directory / "trajectory.jsonl"):
    let row = parseJson(line)
    if not row.hasKey("action_status"): continue
    let seat = parseInt(row["seat"].getStr())
    let round = parseInt(row["decision_id"].getStr().split('-')[0])
    doAssert row["decision_id"].getStr() == $round & "-" & $seat
    doAssert row["decision_index"].getInt() == round * Seats + seat
    let before = frames[frozen[round]]
    let observation = row["observation"]
    doAssert observation["view"] == observationJson(before, seat)
    doAssert observation["prompt_selection"] == selection.selectionMetadata()
    doAssert observation["physical_family"]["split_group"].getStr() == before.physicalFamily()
    let meeting = before.plan.pairs[before.pairIndexOf(round, seat)]
    var nativeMeeting: GameEvent
    var gossip = newJNull()
    for event in events:
      if event.round != round: continue
      if event.kind == evMeeting and seat in [event.seat, event.other]: nativeMeeting = event
      if event.kind == evGossip and event.seat == seat: gossip = event.eventToJson()
    let first = nativeMeeting.seat == seat
    let native = nativeMeeting.eventToJson()
    doAssert observation["meeting_event_sha256"].getStr() == sha256($native).toHex.toLowerAscii()
    var own = copy(native)
    let otherMemo = if first: "memoB" else: "memoA"
    if own.hasKey(otherMemo): own.delete(otherMemo)
    doAssert observation["native_events"][0] == own
    inc safeOwnMemoEvents
    let memoAfter = if first: nativeMeeting.memoA else: nativeMeeting.memoB
    let move = if first: nativeMeeting.moveA else: nativeMeeting.moveB
    let scripted = if first: nativeMeeting.scriptedA else: nativeMeeting.scriptedB
    doAssert observation["memo_after"].getStr() == memoAfter
    doAssert observation["gossip_event"] == gossip
    let registration = observation{"policy_registration"}
    if registration != nil:
      doAssert registration.kind == JObject
      doAssert registration["registered"].kind == JBool
      doAssert registration["origin"].kind == JString
      let ready = registration["registered"].getBool()
      let origin = registration["origin"].getStr()
      if not ready:
        doAssert origin == "unregistered_fallback"
        doAssert registration["fallback_reason"].getStr() == "unregistered_policy"
        doAssert scripted and row["action_status"].getStr() == "fallback"
        doAssert move == scriptedAction(before, seat, skMirror).move
      else:
        doAssert origin in ["native", "scripted", "external"]
        doAssert registration["fallback_reason"].kind == JNull
      for attempt in row["attempts"]:
        if attempt["origin"].getStr() == "model":
          doAssert ready and origin == "native"
      # Fallback rows legitimately select the existing non-model fallback attempt.
      if row["selected_attempt_id"].kind == JString:
        for attempt in row["attempts"]:
          if attempt["attempt_id"] == row["selected_attempt_id"] and
              attempt["origin"].getStr() == "model":
            doAssert ready and origin == "native"
    let actual = row["executed_action"]
    doAssert actual.kind == JObject and actual["move"].getInt() == move
    if scripted:
      doAssert row["action_status"].getStr() == "fallback"
      doAssert actual["note"].getStr() == "" and actual["memo"].getStr() == ""
    for attemptIndex in 0 ..< row["attempts"].len:
      let attempt = row["attempts"][attemptIndex]
      if attempt["origin"].getStr() != "model": continue
      let request = attempt["request"]
      if request.kind != JObject: continue
      doAssert request["system"].getStr() == systemPrompt(selection, before, seat)
      var operator = "local-ledger-operator-" & $seat
      if fileExists(directory / "operator-map.json"):
        let operators = parseFile(directory / "operator-map.json")
        if operators.hasKey($seat): operator = operators[$seat].getStr()
      var expectedUser = before.userPrompt(seat, operator)
      if attemptIndex > 0:
        expectedUser.add("\nYour previous reply was invalid. Respond with ONLY the " &
          "requested JSON object, with \"move\" " & legalForm(meeting.game, meeting.a == seat) & ".")
      doAssert request["messages"][0]["content"].getStr() == expectedUser
      inc promptsChecked
      if attempt["parsed_action"].kind == JObject:
        let parsed = parseDecision(meeting.game, meeting.a == seat,
          extractJsonObject(attempt["response"].getStr()))
        doAssert attempt["parsed_action"] == %*{"move": parsed.move, "note": parsed.note, "memo": parsed.memo}
        if not scripted:
          doAssert actual == attempt["parsed_action"]
          inc projectedActions
    if actual["memo"].getStr().len == 0:
      doAssert memoAfter == observation["view"]["memo"].getStr()
    else: doAssert memoAfter == actual["memo"].getStr()
    if actual["note"].getStr().len > 0 and before.noteTarget(seat) >= 0:
      doAssert gossip.kind == JObject and gossip["text"] == actual["note"]
    else: doAssert gossip.kind == JNull
    inc decisions
  doAssert decisions == results["rounds"].getInt() * Seats
  echo $(%*{"status": "pass", "native_views_checked": decisions,
    "native_prompts_checked": promptsChecked, "native_parsed_applied_actions": projectedActions,
    "own_memo_native_event_projections": safeOwnMemoEvents,
    "native_outcome_replay_reconstruction": true,
    "qualification": "source-native reconstruction; sentinel fixtures are never teacher data"})

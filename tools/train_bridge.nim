## Persistent JSONL bridge for Metta RL and native Puffer training.
## nim c -d:release --path:src -o:ledger-train-bridge tools/train_bridge.nim

import std/[json, os]
import ledger/[llm, sim]

const OperatorPrompt = "Build a strong reputation while maximizing your cumulative payoff."
const ActionSlots = 101

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc meetingJson(record: MeetingRecord): JsonNode =
  %*{"round": record.round, "a": record.a, "b": record.b,
    "game": $record.game, "move_a": record.moveA,
    "move_b": record.moveB, "pay_a": record.payA, "pay_b": record.payB}

proc decision(game: Sim, id, seat: int): JsonNode =
  let pair = game.pairIndexOf(game.round, seat)
  let meeting = game.plan.pairs[pair]
  let partner = if meeting.a == seat: meeting.b else: meeting.a
  var tables = newJArray()
  for current in game.plan.pairs:
    tables.add(%*{"a": current.a, "b": current.b,
      "game": $current.game})
  var history = newJArray()
  for record in game.history:
    history.add(meetingJson(record))
  %*{
    "kind": "decision", "game": "ledger", "decision_id": id,
    "seat": seat, "engine_seat": seat, "turn": game.round,
    "semantic_view": {
      "seat": seat, "round": game.round,
      "rounds": game.config.rounds, "partner": partner,
      "subgame": $meeting.game, "first": meeting.a == seat,
      "tables": tables, "history": history,
      "own_memo": game.memos[seat]
    },
    "inbox": [],
    "messages": [
      {"role": "system", "content": systemPrompt(game, seat)},
      {"role": "user", "content": userPrompt(game, seat, OperatorPrompt)}
    ],
    "speech_messages": [],
    "action_schema": {"type": "object", "required": ["move"],
      "properties": {"move": {"type": "integer"}}},
    "typed_question": newJNull()
  }

proc encoding(game: Sim, id, seat: int): JsonNode =
  let pair = game.pairIndexOf(game.round, seat)
  let meeting = game.plan.pairs[pair]
  let first = meeting.a == seat
  let partner = if first: meeting.b else: meeting.a
  var values = newJArray()
  for other in 0 ..< Seats:
    values.add(%(if seat == other: 1 else: 0))
  for subgame in SubGame:
    values.add(%(if meeting.game == subgame: 1 else: 0))
  values.add(%(if first: 1 else: 0))
  values.add(%(if first: 0 else: 1))
  for other in 0 ..< Seats:
    values.add(%(if partner == other: 1 else: 0))
  values.add(%game.round)
  values.add(%game.config.rounds)
  for other in 0 ..< Seats:
    values.add(%game.median(other))
    values.add(%game.kind[other])
    values.add(%game.harsh[other])
    values.add(%game.total[other])
    values.add(%game.meetingCount(other))
  for current in game.plan.pairs:
    values.add(%current.a)
    values.add(%current.b)
    values.add(%ord(current.game))
  for subject in [seat, partner]:
    let records = game.recentMeetings(subject)
    for record in records:
      let isA = record.a == subject
      for value in [record.round, ord(record.game),
          (if isA: record.b else: record.a),
          (if isA: record.moveA else: record.moveB),
          (if isA: record.moveB else: record.moveA),
          (if isA: record.payA else: record.payB),
          (if isA: record.payB else: record.payA)]:
        values.add(%value)
    for missing in records.len ..< HistoryWindow:
      for field in 0 ..< 7:
        values.add(%0)
  let (low, high) = legalMoveRange(meeting.game, first)
  var actions = newJArray()
  for move in 0 ..< ActionSlots:
    actions.add(if move >= low and move <= high:
      %*{"move": move} else: newJNull())
  %*{"decision_id": id, "values": values, "actions": actions}

when isMainModule:
  let args = commandLineParams()
  if args.len notin 1 .. 2:
    quit("usage: ledger-train-bridge MANIFEST [standard|quickfire]", 1)
  let variant = if args.len == 2: args[1] else: "standard"
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil, "unknown variant: " & variant
  var game: Sim
  var moves: array[Meetings, array[2, int]]
  var flags: array[Meetings, array[2, bool]]
  var id = 0
  var seat = 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == Seats
      var config = defaultGameConfig()
      let runtimeConfig = copy(variantConfig)
      runtimeConfig["tokens"] = %*["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7"]
      runtimeConfig["seed"] = %seedOf(request["seed"].getStr())
      runtimeConfig["minRoundIntervalMs"] = %0
      config.update($runtimeConfig)
      config = sampleEpisode(config)
      game = initSim(config)
      game.beginRound()
      id = 0
      seat = 0
      response = game.decision(id, seat)
    of "encode":
      doAssert not game.done
      response = game.encoding(id, seat)
    of "teacher":
      doAssert not game.done
      let teacher = scriptedAction(game, seat,
        if seat mod 2 == 0: skMirror else: skShark)
      response = %*{"response": $(%*{"move": teacher.move})}
    of "step":
      doAssert not game.done and request["decision_id"].getInt() == id
      let action = parseJson(request["response"].getStr())
      let pair = game.pairIndexOf(game.round, seat)
      let meeting = game.plan.pairs[pair]
      let first = meeting.a == seat
      let parsed = parseDecision(meeting.game, first, action)
      moves[pair][if first: 0 else: 1] = parsed.move
      flags[pair][if first: 0 else: 1] = false
      inc id
      var observation: JsonNode
      if seat == Seats - 1:
        game.applyRound(moves, newSeq[string](Seats),
          newSeq[string](Seats), flags)
        if game.done:
          let outcome = game.resultsJson()
          var scores = newJObject()
          for slot in 0 ..< Seats:
            scores[$slot] = outcome["scores"][slot]
          observation = %*{"kind": "terminal", "scores": scores}
        else:
          game.beginRound()
          seat = 0
          observation = game.decision(id, seat)
      else:
        inc seat
        observation = game.decision(id, seat)
      response = %*{"kind": "accepted", "action": action,
        "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()

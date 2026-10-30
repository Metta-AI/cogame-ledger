## Bounded partial native client/HTTP/apply/capture proof, not a full game.
import std/[json, os, strutils]
import ledger/[sim, llm, prompts, server, training_capture]

if paramCount() == 1 and paramStr(1) == "uri":
  var config = defaultGameConfig()
  for seat in 0 ..< Seats: config.players.add(PlayerConfig(name: "component " & $seat))
  let state = initSim(config)
  for (privateUri, publicUri) in [
      ("https://EXAMPLE.invalid/private%2Fobject?a=1", "https://example.invalid:443/private/object?a=2"),
      ("http://EXAMPLE.invalid/private/object?x=1", "http://example.invalid:80/private/object?x=2"),
      ("file:///tmp/ledger-proof/../same.json", "file:///tmp/same.json")]:
    putEnv("COGAME_SAVE_TRAJECTORY_URI", privateUri)
    putEnv("COGAME_RESULTS_URI", publicUri)
    var rejected = false
    try: discard newRuntimeCapture(state)
    except ValueError: rejected = true
    doAssert rejected
  putEnv("COGAME_SAVE_TRAJECTORY_URI", "file:///tmp/ledger-only-private.jsonl")
  putEnv("COGAME_RESULTS_URI", "file:///tmp/ledger-only-results.json")
  for key in ["COWORLD_EPISODE_ID", "COWORLD_GAME_VERSION", "COWORLD_SOURCE_REVISION"]:
    putEnv(key, "local-constructor-fixture")
  putEnv("COWORLD_GAME_NAME", "\xed\xb0\x80")
  var nameRejected = false
  try: discard newRuntimeCapture(state)
  except ValueError as error:
    nameRejected = error.msg == "non-Unicode private identity: COWORLD_GAME_NAME"
  doAssert nameRejected
  putEnv("COGAME_SAVE_TRAJECTORY_URI", "")
  doAssert newRuntimeCapture(state) == nil
  echo "native capture normalized URI collisions rejected; disabled capture nil"
  quit(0)

if not getEnv("COWORLD_LLM_ENDPOINT").startsWith("http://127.0.0.1:"):
  raise newException(ValueError, "component requires a literal loopback sentinel")
var config = defaultGameConfig()
config.seed = 1
for seat in 0 ..< Seats: config.players.add(PlayerConfig(name: "component " & $seat))
var state = initSim(config)
let selection = promptSelection(newJObject())
let client = newLlmClient(config, selection)
let capture = newRuntimeCapture(state)
var seats: seq[int]
var operators: seq[string]
var scripted: seq[ScriptKind]
for seat in 0 ..< Seats:
  seats.add(seat)
  operators.add("local-ledger-operator-" & $seat)
  scripted.add(skNone)
var rounds = newJArray()
for index in 0 .. 1:
  state.beginRound()
  var observations: seq[JsonNode]
  for seat in seats: observations.add(observationJson(state, seat))
  capture.beginCaptureRound(state, observations, selection.selectionMetadata())
  let decisions = client.decideAll(state, seats, operators, scripted, capture)
  var moves: array[Meetings, array[2, int]]
  var flags: array[Meetings, array[2, bool]]
  var notes, memos: seq[string]
  for pair, meeting in state.plan.pairs:
    moves[pair] = [decisions[meeting.a].move, decisions[meeting.b].move]
    flags[pair] = [decisions[meeting.a].scripted, decisions[meeting.b].scripted]
  for decision in decisions:
    notes.add(decision.note)
    memos.add(decision.memo)
  state.applyRound(moves, notes, memos, flags)
  capture.appliedCaptureRound(state, notes, memos)
  rounds.add(%*{"round": index, "native_moves": moves, "native_scripted": flags,
    "native_notes": notes, "native_memo_commands": memos, "native_memos_after": state.memos})
state.endEarly()
capture.finishCapture(state.resultsJson())
# These are forensic original bytes; invalid Unicode is expected in native state.
writeFile(paramStr(1), $(%*{"partial_native_rounds": rounds,
  "outcome": state.resultsJson(), "qualification": "partial component; no server pacing or full episode"}))

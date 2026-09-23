## Export complete Ledger games as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT GAMES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, strutils]
import ledger/[llm, sim]

const OperatorPrompt = "Build a strong reputation while maximizing your cumulative payoff."
const Variants = ["standard", "quickfire"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT]", 1)
  let output = args[0]
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len == 4: args[3] else: Variants[0]
  if games < 10 or firstSeed < 1:
    quit("at least ten games and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + games:
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = newJArray()
    for seat in 0 ..< Seats:
      runtimeConfig["tokens"].add(%("t" & $seat))
    runtimeConfig["seed"] = %seed
    runtimeConfig["minRoundIntervalMs"] = %0
    config.update($runtimeConfig)
    config = sampleEpisode(config)
    var sim = initSim(config)
    var rows: seq[string]
    while not sim.done:
      sim.beginRound()
      var moves: array[Meetings, array[2, int]]
      var flags: array[Meetings, array[2, bool]]
      for pair in 0 ..< Meetings:
        let meeting = sim.plan.pairs[pair]
        for side in 0 .. 1:
          let seat = if side == 0: meeting.a else: meeting.b
          let first = side == 0
          let teacher = scriptedAction(sim, seat,
            if seat mod 2 == 0: skMirror else: skShark)
          let completion = %*{"move": teacher.move, "note": teacher.note,
            "memo": teacher.memo}
          let parsed = parseDecision(meeting.game, first, completion)
          doAssert parsed.move == teacher.move and
            parsed.note == teacher.note and parsed.memo == teacher.memo
          rows.add($(%*{
            "episode_id": "ledger-" & variant & "-" & $seed,
            "seed": "ledger-" & variant & "-" & $seed,
            "decision_id": rows.len,
            "prompt": [
              {"role": "system", "content": systemPrompt(sim, seat)},
              {"role": "user", "content": userPrompt(sim, seat,
                OperatorPrompt)}
            ],
            "completion": [{"role": "assistant", "content": $completion}],
            "game": "ledger",
            "action_schema_revision": "ledger-meeting-v1"
          }))
          moves[pair][side] = parsed.move
          flags[pair][side] = true
      sim.applyRound(moves, newSeq[string](Seats), newSeq[string](Seats),
        flags)
    doAssert sim.reason == "complete" and sim.roundsPlayed == config.rounds
    let outcome = sim.resultsJson()
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "scores": outcome["scores"], "rounds_played": sim.roundsPlayed})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "ledger",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-mirror-and-shark",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len

## Export complete Ledger games as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT GAMES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, strutils]
import ledger/[llm, sim, server, evidence]


const Variants = ["standard", "quickfire"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin [2, 3, 4, 6]:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT] [PROMPT_VARIANT PROMPT_SEED]", 1)
  let output = args[0]
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: Variants[0]
  let selection = promptSelection(if args.len == 6:
    %*{"promptVariant": args[4], "promptSeed": parseInt(args[5])} else: newJObject())
  doAssert selection.selectedVariant notin {pvHeldoutBriefing, pvHeldoutReference},
    "held-out wording is evaluation only"
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "commit qualified source before exporting pinned candidates"
  if games < 10 or firstSeed < 1:
    quit("at least ten games and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  setFilePermissions(output, {fpUserRead, fpUserWrite, fpUserExec})
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    records: seq[string]
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
    let family = "ledger-" & $seed
    let episode = family & "-" & variant & "-" & $selection.selectedVariant
    var rows: seq[JsonNode]
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
          doAssert teacher.note.len == 0 and teacher.memo.len == 0
          let completion = %*{"move": teacher.move, "note": teacher.note,
            "memo": teacher.memo}
          let parsed = parseDecision(meeting.game, first, completion)
          doAssert parsed.move == teacher.move and
            parsed.note == teacher.note and parsed.memo == teacher.memo
          let system = systemPrompt(selection, sim, seat)
          let user = userPrompt(sim, seat, TrainingOperatorPrompt)
          let messages = %*[{"role": "system", "content": system},
            {"role": "user", "content": user}]
          let attemptId = $rows.len & "-teacher"
          rows.add(%*{"schema_version": "1", "event_type": "decision",
            "episode_id": episode, "decision_id": $rows.len, "decision_index": rows.len,
            "game": "ledger", "game_version": "source-" & sourceRevision,
            "source_revision": sourceRevision, "seat": $seat, "visibility": "private",
            "observation": {"view": observationJson(sim, seat),
              "prompt_template": selection.promptMetadata(system, user)},
            "prompt": messages, "attempts": [{"attempt_id": attemptId,
              "policy": "scripted-mirror-and-shark", "origin": "teacher",
              "inference_mode": "text_action", "prompt": messages,
              "response": $completion, "parsed_action": completion,
              "accepted": true, "rejection_reason": newJNull(), "request": newJNull(),
              "platform_call_id": newJNull(), "behavior_logprobs": newJNull()}],
            "selected_attempt_id": attemptId, "executed_action": completion,
            "action_status": "accepted", "fallback_origin": newJNull(), "terminal": false})
          moves[pair][side] = parsed.move
          flags[pair][side] = true
      sim.applyRound(moves, newSeq[string](Seats), newSeq[string](Seats),
        flags)
    doAssert sim.reason == "complete" and sim.roundsPlayed == config.rounds
    let outcome = sim.resultsJson()
    let frames = replayMatch(config, sim.events)
    doAssert frames[^1].resultsJson() == outcome, "source replay outcome must rederive"
    doAssert frames[^1].history == sim.history, "source replay meetings must rederive"
    var events = newJArray()
    for event in sim.events: events.add(event.eventToJson())
    var participants = newJObject()
    for seat in 0 ..< Seats: participants[$seat] = %*{"score": outcome["scores"][seat]}
    for index, row in rows:
      row["terminal"] = %(index == rows.high)
      records.add($row)
    let episodeRow = %*{"schema_version": "1", "event_type": "episode",
      "episode_id": episode, "seed_family": family, "game": "ledger",
      "game_version": "source-" & sourceRevision, "source_revision": sourceRevision,
      "status": "completed", "outcome": outcome, "participant_outcomes": participants}
    records.add($episodeRow)
    var gameRecords: seq[string]
    for row in rows: gameRecords.add($row)
    gameRecords.add($episodeRow)
    writePrivate(output / (episode & ".jsonl"), gameRecords.join("\n") & "\n")
    writePrivate(output / (episode & ".replay.json"), $(%*{
      "protocol": "ledger.replay.v1", "names": sim.names,
      "policyNames": newSeq[string](Seats),
      "config": {"rounds": config.rounds, "seed": seed, "sampled": true,
        "schedule": sim.scheduleJson()}, "events": events, "results": outcome}) & "\n")
    runs.add(%*{"seed": seed, "episode_id": episode, "decisions": rows.len,
      "trajectory": episode & ".jsonl", "replay": episode & ".replay.json",
      "scores": outcome["scores"], "rounds_played": sim.roundsPlayed})
  writePrivate(output / "trajectories.jsonl", records.join("\n") & "\n")
  writePrivate(output / "manifest.json", pretty(%*{
    "schema_version": "1", "format": "coworld-private-candidates-v1", "review_required": true,
    "game": "ledger", "variant": variant, "source_revision": sourceRevision,
    "teacher": "scripted-mirror-and-shark", "operator_prompt": TrainingOperatorPrompt,
    "prompt_selection": selection.selectionMetadata(), "runs": runs}) & "\n")
  echo "complete games=", games

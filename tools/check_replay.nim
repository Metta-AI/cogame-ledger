## Re-derive a complete replay through the production simulator.
import std/[json, os]
import ledger/sim

let args = commandLineParams()
doAssert args.len == 1, "usage: check_replay REPLAY"
let replay = parseFile(args[0])
var config = defaultGameConfig()
config.update($replay["config"])
var events: seq[GameEvent]
for event in replay["events"]: events.add(eventFromJson(event))
let frames = replayMatch(config, events)
doAssert frames[^1].resultsJson() == replay["results"]
doAssert frames[^1].events.len == events.len
for index, event in frames[^1].events:
  doAssert event.eventToJson() == events[index].eventToJson()
echo "replay verified"

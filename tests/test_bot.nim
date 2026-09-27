## The scripted baselines must play whole episodes without ever proposing an
## illegal move — they are both the no-credentials fallback (offline
## certification) and fieldable policies, so this is the completion path.
## `mirror` must also actually reciprocate, or reputation means nothing.
##
## Plus the LLM plumbing that can be exercised offline: the no-credential
## path, tolerant reply parsing with clamping, and the batch-position mapping
## a parallel rewrite most easily gets wrong.

import std/[json, monotimes, os, random, sets, strutils, times, unicode,
  unittest]
import ledger/[llm, server, sim]

proc fixture(seed: int, rounds = 14): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.rounds = rounds
  result.sampled = true
  result.minRoundIntervalMs = 0
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("t" & $index)

proc playScripted(config: GameConfig, kinds: seq[ScriptKind]): Sim =
  ## A whole episode on the baselines, through the SAME entry point the
  ## server uses. Every move must be legal as drawn: applyRound raises on
  ## anything else and would fail this test rather than silently clamping.
  result = initSim(config)
  while not result.done:
    result.beginRound()
    var moves: array[Meetings, array[2, int]]
    var flags: array[Meetings, array[2, bool]]
    for pair in 0 ..< Meetings:
      let meeting = result.plan.pairs[pair]
      let a = scriptedAction(result, meeting.a, kinds[meeting.a])
      let b = scriptedAction(result, meeting.b, kinds[meeting.b])
      check a.note.len == 0
      check a.memo.len == 0
      check b.note.len == 0
      check b.memo.len == 0
      check a.scripted
      check b.scripted
      let (loA, hiA) = legalMoveRange(meeting.game, true)
      let (loB, hiB) = legalMoveRange(meeting.game, false)
      check a.move >= loA and a.move <= hiA
      check b.move >= loB and b.move <= hiB
      moves[pair] = [a.move, b.move]
      flags[pair] = [true, true]
    result.applyRound(moves, newSeq[string](Seats), newSeq[string](Seats),
      flags)

proc allOf(kind: ScriptKind): seq[ScriptKind] =
  for _ in 0 ..< Seats:
    result.add(kind)

proc halfAndHalf(): seq[ScriptKind] =
  for seat in 0 ..< Seats:
    result.add(if seat < 4: skMirror else: skShark)

suite "scripted baselines":
  test "every mix plays a full, legal, bounded episode":
    for seed in [1, 7, 42, 1234]:
      for mix in [allOf(skMirror), allOf(skShark), halfAndHalf()]:
        let config = fixture(seed, 14)
        let started = getMonoTime()
        let sim = playScripted(config, mix)
        let elapsed = (getMonoTime() - started).inMilliseconds
        check sim.done
        check sim.reason == "complete"
        check sim.roundsPlayed == config.rounds
        var meetings = 0
        for event in sim.events:
          if event.kind == evMeeting:
            inc meetings
            check event.payA >= 0 and event.payA <= 14
            check event.payB >= 0 and event.payB <= 14
            check event.scriptedA
            check event.scriptedB
        check meetings == config.rounds * Meetings
        for seat in 0 ..< Seats:
          check sim.meetingCount(seat) == config.rounds
          for payoff in sim.payoffs[seat]:
            check payoff >= 0 and payoff <= 14
        let results = sim.resultsJson()
        for seat in 0 ..< Seats:
          check results["scores"][seat].getFloat() >= 0.0
          check results["scores"][seat].getFloat() <= 14.0
        check elapsed < 5000

  test "a scripted episode is deterministic for a seed":
    for seed in [1, 7, 42]:
      let a = playScripted(fixture(seed, 14), halfAndHalf())
      let b = playScripted(fixture(seed, 14), halfAndHalf())
      check $a.resultsJson() == $b.resultsJson()

  test "the baselines are legal for EVERY (subgame, role) combination":
    ## scriptedAction is the single entry point and must never need clamping.
    for seed in 0 ..< 20:
      var sim = initSim(fixture(seed, 21))
      while not sim.done:
        sim.beginRound()
        var moves: array[Meetings, array[2, int]]
        var flags: array[Meetings, array[2, bool]]
        for pair in 0 ..< Meetings:
          let meeting = sim.plan.pairs[pair]
          for kind in [skMirror, skShark, skNone]:
            let effective = if kind == skNone: skMirror else: kind
            let a = scriptedAction(sim, meeting.a, effective)
            let b = scriptedAction(sim, meeting.b, effective)
            check a.move == clampMove(meeting.game, true, a.move)
            check b.move == clampMove(meeting.game, false, b.move)
          moves[pair] = [
            scriptedAction(sim, meeting.a, skMirror).move,
            scriptedAction(sim, meeting.b, skMirror).move]
          flags[pair] = [true, true]
        sim.applyRound(moves, newSeq[string](Seats), newSeq[string](Seats),
          flags)

suite "mirror reciprocates":
  proc dilemmaRate(sim: Sim, seats: HashSet[int], fromRound: int): float =
    var cooperated = 0
    var total = 0
    for record in sim.history:
      if record.game != sgDilemma or record.round < fromRound:
        continue
      if record.a in seats:
        inc total
        if record.moveA == MoveCooperate: inc cooperated
      if record.b in seats:
        inc total
        if record.moveB == MoveCooperate: inc cooperated
    if total == 0: 0.0 else: cooperated.float / total.float

  test "against sharks it stops cooperating; among mirrors it never stops":
    var runs = 0
    for seed in [1, 7, 42, 1234]:
      ## One mirror in a table of sharks: after the first pass every shark's
      ## public record is nothing but defections, so tit-for-tat over the
      ## public record must lock on to defect.
      var mix = allOf(skShark)
      mix[0] = skMirror
      let hostile = playScripted(fixture(seed, 21), mix)
      var lone: HashSet[int]
      lone.incl(0)
      let rate = hostile.dilemmaRate(lone, RoundsPerPass)
      echo "seed ", seed, ": mirror-in-a-shark-tank cooperation after the ",
        "first pass = ", rate
      inc runs
      check rate < 0.25

      let friendly = playScripted(fixture(seed, 21), allOf(skMirror))
      var everyone: HashSet[int]
      for seat in 0 ..< Seats:
        everyone.incl(seat)
      let kindRate = friendly.dilemmaRate(everyone, RoundsPerPass)
      echo "seed ", seed, ": mirror-among-mirrors cooperation = ", kindRate
      check kindRate > 0.9
    check runs == 4

  test "a table of mirrors settles on the fair payoff in all three games":
    let sim = playScripted(fixture(5, 14), allOf(skMirror))
    for record in sim.history:
      case record.game
      of sgDilemma:
        check (record.payA, record.payB) == (PdReward, PdReward)
      of sgTrust:
        ## send 4, return 50%: 6 - 4 + 4 and 2 + 8 - 4.
        check (record.payA, record.payB) == (6, 6)
      of sgUltimatum:
        ## offer 5 clears a floor of 4.
        check record.payA + record.payB == Pie
    for seat in 0 ..< Seats:
      check sim.halo(seat) == 1.0

  test "sharks take everything and their record says so":
    let sim = playScripted(fixture(5, 14), allOf(skShark))
    for record in sim.history:
      case record.game
      of sgDilemma:
        check (record.moveA, record.moveB) == (MoveDefect, MoveDefect)
        check (record.payA, record.payB) == (PdPunishment, PdPunishment)
      of sgTrust:
        ## Nothing sent, nothing returned: the investor keeps its endowment
        ## and the trustee keeps its own, and both moves are harsh.
        check (record.moveA, record.moveB) == (0, 0)
        check (record.payA, record.payB) ==
          (InvestorEndowment, TrusteeEndowment)
        check not isKind(sgTrust, true, record.moveA)
        check not isKind(sgTrust, false, record.moveB)
      of sgUltimatum:
        ## Lowball and accept: the proposer is harsh, and the responder's
        ## floor of 1 counts as kind because it clears almost everything.
        check (record.moveA, record.moveB) == (1, 1)
        check (record.payA, record.payB) == (Pie - 1, 1)
        check not isKind(sgUltimatum, true, record.moveA)
        check isKind(sgUltimatum, false, record.moveB)
    for seat in 0 ..< Seats:
      ## The reputation follows them: mostly harsh, and a halo well under the
      ## 0.5 a cog starts with.
      check sim.harsh[seat] > sim.kind[seat]
      check sim.halo(seat) < 0.5

suite "llm plumbing, offline":
  test "external observation reveals only this seat's memo":
    var sim = initSim(fixture(7, 4))
    sim.memos[0] = "seat zero private memo"
    sim.memos[1] = "seat one private memo"
    sim.beginRound()
    let observation = observationJson(sim, 1)
    check observation["round"].getInt() == 0
    check observation["legal"]["moveMin"].getInt() == 0
    check observation["legal"]["moveMax"].getInt() <= 100
    check observation["memo"].getStr() == "seat one private memo"
    check "seat zero private memo" notin $observation
    check observation["publicSeats"].len == Seats
    check observation["currentPairs"].len == Meetings
    check not observation.hasKey("memos")

  test "with no credentials every seat is scripted, instantly, over no wire":
    putEnv("ANTHROPIC_API_KEY", "")
    putEnv("ANTHROPIC_API_KEY_URI", "")
    putEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "")
    putEnv("AWS_BEARER_TOKEN_BEDROCK", "")
    putEnv("METTA_CAPTURE_URL", "")
    let config = fixture(3, 6)
    let client = newLlmClient(config)
    check client.disabled
    var sim = initSim(config)
    sim.beginRound()
    var seats: seq[int]
    for seat in 0 ..< Seats:
      seats.add(seat)
    let started = getMonoTime()
    let decisions = client.decideAll(sim, seats,
      newSeq[string](Seats), newSeq[ScriptKind](Seats))
    let elapsed = (getMonoTime() - started).inMilliseconds
    check decisions.len == Seats
    for index, decision in decisions:
      check decision.scripted
      let pair = sim.pairIndexOf(sim.round, seats[index])
      let meeting = sim.plan.pairs[pair]
      let first = meeting.a == seats[index]
      check decision.move == clampMove(meeting.game, first, decision.move)
      ## No credentials means no retries and no network waits at all.
      check decision.note.len == 0
    echo "decideAll with no credentials: ", elapsed, " ms"
    check elapsed < 1000

  test "replies parse tolerantly and clamp instead of failing":
    ## DILEMMA words, in any case, plus the integer encodings.
    for text in ["cooperate", "COOPERATE", " Cooperate ", "c", "C"]:
      check parseMoveValue(sgDilemma, true, %text) == MoveCooperate
    for text in ["defect", "DEFECT", " d ", "D"]:
      check parseMoveValue(sgDilemma, true, %text) == MoveDefect
    check parseMoveValue(sgDilemma, true, parseJson("0")) == MoveCooperate
    check parseMoveValue(sgDilemma, true, parseJson("1")) == MoveDefect
    ## Numbers, numeric strings, floats rounded half up, and the suffixes a
    ## model likes to attach.
    check parseMoveValue(sgTrust, true, parseJson("5")) == 5
    check parseMoveValue(sgTrust, true, parseJson("\"5\"")) == 5
    check parseMoveValue(sgTrust, true, parseJson("5.4")) == 5
    check parseMoveValue(sgTrust, true, parseJson("5.5")) == 6
    check parseMoveValue(sgTrust, false, parseJson("\"50%\"")) == 50
    check parseMoveValue(sgTrust, true, parseJson("\"6 coins\"")) == 6
    check parseMoveValue(sgUltimatum, true, parseJson("\"3\"")) == 3
    ## An unrecognised word is a real failure: it goes to the retry.
    expect LedgerError:
      discard parseMoveValue(sgDilemma, true, parseJson("\"maybe\""))
    expect LedgerError:
      discard parseMoveValue(sgTrust, true, parseJson("\"soon\""))
    expect LedgerError:
      discard parseMoveValue(sgTrust, true, parseJson("null"))
    expect LedgerError:
      discard parseDecision(sgTrust, true, parseJson("""{"note":"hi"}"""))
    ## Out of range is CLAMPED and logged, never retried.
    check parseDecision(sgTrust, true, parseJson("""{"move": 9}""")).move ==
      InvestorEndowment
    check parseDecision(sgTrust, false,
      parseJson("""{"move": -20}""")).move == 0
    check parseDecision(sgUltimatum, true,
      parseJson("""{"move": 40}""")).move == Pie

  test "prose around the object still yields the object":
    let payload = extractJsonObject(
      "Let me think about this.\n```json\n{\"move\": \"defect\", " &
      "\"note\": \"took the pot\"}\n```\nThat is my answer.")
    let decision = parseDecision(sgDilemma, true, payload)
    check decision.move == MoveDefect
    check decision.note == "took the pot"
    expect LedgerError:
      discard extractJsonObject("I would rather not answer that.")

  test "note and memo are truncated on rune boundaries and stay one line":
    var long = ""
    for _ in 0 ..< 400:
      long.add("é")
    let decision = parseDecision(sgDilemma, true, %*{
      "move": "cooperate", "note": "line one\nline two", "memo": long
    })
    check decision.note == "line one line two"
    check decision.memo.runeLen == MaxMemoLen
    let clipped = parseDecision(sgDilemma, true, %*{
      "move": "cooperate", "note": long
    })
    check clipped.note.runeLen == MaxNoteLen

  test "a batch reply is matched by POSITION, not by arrival order":
    ## The failure a batched rewrite invites: replies come back in whatever
    ## order the transport finished them, and indexing by anything but the
    ## queued position silently gives seat 3's answer to seat 6.
    var seats: seq[int]
    for seat in 0 ..< Seats:
      seats.add(seat)
    ## Four seats registered scripted, so only these four were queued.
    let open = @[1, 2, 5, 7]
    var arrival: seq[int]
    for position in 0 ..< open.len:
      arrival.add(position)
    var rng = initRand(99)
    rng.shuffle(arrival)
    ## Deliver the replies in the shuffled order and reassemble.
    var assigned = newSeq[int](Seats)
    for seat in 0 ..< Seats:
      assigned[seat] = -1
    for position in arrival:
      let seat = seatForBatchPosition(seats, open, position)
      ## The payload of batch position p was composed for seats[open[p]].
      assigned[seat] = position
    for position in 0 ..< open.len:
      check assigned[seats[open[position]]] == position
    for seat in 0 ..< Seats:
      if seat notin open:
        check assigned[seat] == -1

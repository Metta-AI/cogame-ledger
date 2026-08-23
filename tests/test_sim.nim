## The pure rules: the schedule and its exact-cover guarantees, the three
## payoff kernels, the median that is the only ranked statistic, conduct,
## gossip, ring detection (which must never touch a score), legality, the two
## legal endings, replay re-derivation, and determinism.
##
## Runs in both debug and -d:release: debug catches the range and overflow
## bugs, release catches the codegen ones.

import std/[algorithm, json, sets, strutils, tables, unicode, unittest]
import ledger/[llm, sim]

proc fixture(seed: int, rounds = 14): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.rounds = rounds
  result.sampled = true
  result.minRoundIntervalMs = 0
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("t" & $index)

proc simpleMove(game: SubGame, first: bool, seat, round: int): int =
  ## A deterministic, always-legal move for every (subgame, role); the rules
  ## tests only need traffic, not strategy.
  case game
  of sgDilemma: (seat + round) mod 2
  of sgTrust:
    if first: (seat + round) mod (InvestorEndowment + 1)
    else: (seat * 13 + round * 7) mod 101
  of sgUltimatum: (seat * 5 + round) mod (Pie + 1)

var liveCheckpoints: seq[(int, string)]
  ## Refilled by every `playEpisode` call: `(events.len, tableStateJson)` at
  ## each tick where the LIVE sim publishes a state - the moment each round
  ## opens, and the moment the episode settles. The replay suite checks the
  ## re-derived frames against these, so "frame by frame" is measured against
  ## states the live sim actually passed through, not only against the fold.

proc playEpisode(config: GameConfig, withTalk = true): Sim =
  result = initSim(config)
  liveCheckpoints = @[]
  while not result.done:
    result.beginRound()
    liveCheckpoints.add((result.events.len, $result.tableStateJson()))
    var moves: array[Meetings, array[2, int]]
    var flags: array[Meetings, array[2, bool]]
    var notes = newSeq[string](Seats)
    var memos = newSeq[string](Seats)
    for pair in 0 ..< Meetings:
      let meeting = result.plan.pairs[pair]
      moves[pair] = [
        simpleMove(meeting.game, true, meeting.a, result.round),
        simpleMove(meeting.game, false, meeting.b, result.round)]
      flags[pair] = [false, true]
    if withTalk:
      for seat in 0 ..< Seats:
        notes[seat] = "seat " & $seat & " on round " & $result.round
        memos[seat] = "memo of seat " & $seat & " at round " & $result.round
    result.applyRound(moves, notes, memos, flags)
  liveCheckpoints.add((result.events.len, $result.tableStateJson()))

suite "schedule":
  test "every round is a perfect matching of all eight seats":
    for seed in [1, 7, 42, 1234]:
      for rounds in [4, 7, 14, 28]:
        let sim = initSim(fixture(seed, rounds))
        check sim.schedule.len == rounds
        for plan in sim.schedule:
          var seen: HashSet[int]
          for pair in 0 ..< Meetings:
            let meeting = plan.pairs[pair]
            check meeting.a != meeting.b
            check meeting.a in 0 ..< Seats
            check meeting.b in 0 ..< Seats
            seen.incl(meeting.a)
            seen.incl(meeting.b)
          check seen.len == Seats

  test "fourteen rounds are a perfect DOUBLE round robin":
    for seed in [1, 7, 42, 1234]:
      let sim = initSim(fixture(seed, 14))
      var met = initCountTable[(int, int)]()
      for plan in sim.schedule:
        for pair in 0 ..< Meetings:
          let meeting = plan.pairs[pair]
          met.inc((min(meeting.a, meeting.b), max(meeting.a, meeting.b)))
      check met.len == Seats * (Seats - 1) div 2
      for _, count in met:
        check count == 2

  test "no pair ever meets more than ceil(rounds / 7) times":
    for seed in [1, 7, 42, 1234]:
      for rounds in [4, 7, 14, 28]:
        let sim = initSim(fixture(seed, rounds))
        var met = initCountTable[(int, int)]()
        for plan in sim.schedule:
          for pair in 0 ..< Meetings:
            let meeting = plan.pairs[pair]
            met.inc((min(meeting.a, meeting.b), max(meeting.a, meeting.b)))
        for _, count in met:
          check count <= maxMeetings(rounds)

  test "no pair meets in consecutive rounds":
    for seed in [1, 7, 42, 1234]:
      for rounds in [4, 7, 14, 28]:
        let sim = initSim(fixture(seed, rounds))
        for r in 1 ..< sim.schedule.len:
          var previous: HashSet[(int, int)]
          for pair in 0 ..< Meetings:
            let meeting = sim.schedule[r - 1].pairs[pair]
            previous.incl((min(meeting.a, meeting.b),
              max(meeting.a, meeting.b)))
          for pair in 0 ..< Meetings:
            let meeting = sim.schedule[r].pairs[pair]
            check (min(meeting.a, meeting.b), max(meeting.a, meeting.b)) notin
              previous

  test "the first mover is always the member with fewer turns as first mover":
    ## The rule itself, re-derived from the stored schedule: at every
    ## asymmetric meeting the seat that goes first had no MORE first-mover
    ## assignments than its partner at that point.
    for seed in [1, 7, 42, 1234]:
      for rounds in [4, 7, 14, 28]:
        let sim = initSim(fixture(seed, rounds))
        var firstCount: array[Seats, int]
        var asymmetric: array[Seats, int]
        var total = 0
        for plan in sim.schedule:
          for pair in 0 ..< Meetings:
            let meeting = plan.pairs[pair]
            if meeting.game == sgDilemma:
              ## Symmetric: `a` is only the canonical lower seat id.
              check meeting.a < meeting.b
              continue
            check firstCount[meeting.a] <= firstCount[meeting.b]
            inc firstCount[meeting.a]
            inc asymmetric[meeting.a]
            inc asymmetric[meeting.b]
            inc total
        var sum = 0
        for seat in 0 ..< Seats:
          check firstCount[seat] <= asymmetric[seat]
          sum += firstCount[seat]
        check sum == total

  test "the drawn subgames follow the 50 / 30 / 20 split":
    var counts: array[SubGame, int]
    for seed in 0 ..< 200:
      let sim = initSim(fixture(seed, 28))
      for plan in sim.schedule:
        for pair in 0 ..< Meetings:
          inc counts[plan.pairs[pair].game]
    let total = counts[sgDilemma] + counts[sgTrust] + counts[sgUltimatum]
    check total == 200 * 28 * Meetings
    let pd = counts[sgDilemma].float / total.float
    let trust = counts[sgTrust].float / total.float
    let ult = counts[sgUltimatum].float / total.float
    echo "subgame mix: pd ", pd, " trust ", trust, " ultimatum ", ult
    check abs(pd - 0.50) < 0.03
    check abs(trust - 0.30) < 0.03
    check abs(ult - 0.20) < 0.03

suite "payoff kernels":
  test "the whole dilemma matrix":
    check pdPayoffs(MoveCooperate, MoveCooperate) == (6, 6)
    check pdPayoffs(MoveCooperate, MoveDefect) == (0, 10)
    check pdPayoffs(MoveDefect, MoveCooperate) == (10, 0)
    check pdPayoffs(MoveDefect, MoveDefect) == (2, 2)

  test "trust keeps its coin invariant and never returns more than arrived":
    for sent in 0 .. InvestorEndowment:
      for percent in [0, 25, 33, 50, 66, 75, 100]:
        let (investor, trustee) = trustPayoffs(sent, percent)
        check investor + trustee == 8 + sent
        check investor >= 0
        check trustee >= 0
        check investor <= 14
        check trustee <= 14
        let returned = investor - (InvestorEndowment - sent)
        check returned >= 0
        check returned <= 2 * sent
    ## Landmarks. The pot is 8 + s coins, so 6 / 6 is reachable only at
    ## s = 4, p = 50; sending everything at a fair split pays 6 / 8.
    check trustPayoffs(4, 50) == (6, 6)
    check trustPayoffs(6, 50) == (6, 8)
    check trustPayoffs(6, 0) == (0, 14)
    check trustPayoffs(0, 50) == (6, 2)
    ## Half up: 2*1*25 = 50 -> (50 + 50) div 100 = 1, not 0.
    check trustPayoffs(1, 25) == (6 - 1 + 1, 2 + 2 - 1)

  test "ultimatum accepts at the boundary and breaks below it":
    for offer in 0 .. Pie:
      for floorValue in 0 .. Pie:
        let (proposer, responder) = ultimatumPayoffs(offer, floorValue)
        check proposer + responder in [0, Pie]
        check proposer >= 0 and proposer <= 14
        check responder >= 0 and responder <= 14
        if offer >= floorValue:
          check proposer == Pie - offer
          check responder == offer
        else:
          check proposer == 0
          check responder == 0
    check ultimatumPayoffs(6, 6) == (6, 6)
    check ultimatumPayoffs(6, 7) == (0, 0)
    check ultimatumPayoffs(2, 0) == (10, 2)
    check ultimatumPayoffs(2, 5) == (0, 0)

  test "every payoff any legal move can produce is in 0..14":
    for game in [sgDilemma, sgTrust, sgUltimatum]:
      let (loA, hiA) = legalMoveRange(game, true)
      let (loB, hiB) = legalMoveRange(game, false)
      for moveA in loA .. hiA:
        for moveB in loB .. hiB:
          let (payA, payB) = meetingPayoffs(game, moveA, moveB)
          check payA >= 0 and payA <= 14
          check payB >= 0 and payB <= 14

  test "fair play pays six in all three games":
    check meetingPayoffs(sgDilemma, MoveCooperate, MoveCooperate) == (6, 6)
    check meetingPayoffs(sgTrust, 4, 50) == (6, 6)
    check meetingPayoffs(sgUltimatum, 6, 6) == (6, 6)

  test "clampMove pulls an out-of-range move into its role's range":
    check clampMove(sgTrust, true, 9) == InvestorEndowment
    check clampMove(sgTrust, false, 250) == 100
    check clampMove(sgTrust, false, -4) == 0
    check clampMove(sgUltimatum, true, 30) == Pie
    check clampMove(sgDilemma, true, 7) == MoveDefect

suite "score: the median, and only the median":
  proc scored(values: seq[int]): float =
    var sim = initSim(fixture(3, 14))
    sim.payoffs[0] = values
    sim.median(0)

  test "odd, even, and empty":
    check scored(@[]) == 0.0
    check scored(@[6]) == 6.0
    check scored(@[0, 6, 10]) == 6.0
    check scored(@[0, 10]) == 5.0
    ## An even count can produce a .5.
    check scored(@[0, 2, 6, 10]) == 4.0
    check scored(@[2, 6, 7, 10]) == 6.5

  test "a high mean does not lift a low median":
    ## Two enormous payoffs from a friend, twelve poor ones from strangers.
    var payoffs: seq[int]
    for _ in 0 ..< 12:
      payoffs.add(2)
    payoffs.add(14)
    payoffs.add(14)
    var sim = initSim(fixture(5, 14))
    sim.payoffs[0] = payoffs
    check sim.median(0) == 2.0
    check sim.meanPay(0) > 3.7
    ## The mean is nearly twice the median: this is exactly the ring's
    ## signature, and only the median is ranked.
    check sim.meanPay(0) > sim.median(0) * 1.7

suite "conduct":
  test "each threshold at its boundary":
    check isKind(sgDilemma, true, MoveCooperate)
    check not isKind(sgDilemma, true, MoveDefect)
    check isKind(sgDilemma, false, MoveCooperate)
    check not isKind(sgDilemma, false, MoveDefect)
    check not isKind(sgTrust, true, 2)
    check isKind(sgTrust, true, 3)
    check not isKind(sgTrust, false, 49)
    check isKind(sgTrust, false, 50)
    check not isKind(sgUltimatum, true, 4)
    check isKind(sgUltimatum, true, 5)
    check isKind(sgUltimatum, false, 5)
    check not isKind(sgUltimatum, false, 6)

  test "halo is exactly 0.5 before the first meeting":
    let sim = initSim(fixture(9, 14))
    for seat in 0 ..< Seats:
      check sim.halo(seat) == 0.5
      check sim.meetingCount(seat) == 0
      check sim.median(seat) == 0.0

  test "halo tracks kind over kind plus harsh":
    var sim = initSim(fixture(9, 14))
    sim.kind[0] = 3
    sim.harsh[0] = 1
    check abs(sim.halo(0) - 0.75) < 1e-9

suite "gossip":
  test "a note reviews last round's partner and is discarded in round 1":
    let sim = playEpisode(fixture(21, 8))
    check sim.board.len > 0
    var sawRoundOne = false
    for note in sim.board:
      check note.round >= 1
      if note.round == 0:
        sawRoundOne = true
      check note.subject == sim.partnerIn(note.round - 1, note.author)
    check not sawRoundOne
    ## Insertion order: rounds never go backwards on the board.
    for index in 1 ..< sim.board.len:
      check sim.board[index].round >= sim.board[index - 1].round

  test "an out-of-band subject is rejected":
    var sim = initSim(fixture(21, 8))
    sim.beginRound()
    var moves: array[Meetings, array[2, int]]
    var flags: array[Meetings, array[2, bool]]
    for pair in 0 ..< Meetings:
      let meeting = sim.plan.pairs[pair]
      moves[pair] = [
        simpleMove(meeting.game, true, meeting.a, 0),
        simpleMove(meeting.game, false, meeting.b, 0)]
    sim.applyRound(moves, newSeq[string](Seats), newSeq[string](Seats), flags)
    sim.beginRound()
    let author = 0
    let target = sim.noteTarget(author)
    check target >= 0
    var wrong = (target + 1) mod Seats
    if wrong == author:
      wrong = (target + 2) mod Seats
    expect LedgerError:
      sim.applyGossip(author, wrong, "not your partner")

  test "a long multi-byte note is cut on a RUNE boundary":
    var long = ""
    for _ in 0 ..< 500:
      long.add("é")
    let cut = cleanText(long, MaxNoteLen)
    check cut.runeLen == MaxNoteLen
    check cut.validateUtf8() == -1
    check cut.endsWith("…")
    ## And it survives a strict-UTF-8 JSON round trip, which is the whole
    ## point: a byte-boundary cut makes the replay unparseable.
    check parseJson($ %*{"note": cut})["note"].getStr() == cut

  test "a note becomes one line and a memo is cut at 400 runes":
    check "a\nb\rc" notin singleLine("a\nb\rc")
    check singleLine("a\nb\rc") == "a b c"
    var long = ""
    for _ in 0 ..< 900:
      long.add("日")
    let memo = cleanText(long, MaxMemoLen)
    check memo.runeLen == MaxMemoLen
    check memo.validateUtf8() == -1

suite "rings: measured, published, never scored":
  proc ringFixture(inside: int): Sim =
    ## Seats 1 and 5 meet twice; everybody's other meetings pay 2. `inside` is
    ## what the two of them pay each other.
    result = initSim(fixture(77, 14))
    for r in 0 .. 1:
      result.history.add(MeetingRecord(round: r, pair: 0, a: 1, b: 5,
        game: sgDilemma, moveA: MoveCooperate, moveB: MoveCooperate,
        payA: inside, payB: inside))
      result.payoffs[1].add(inside)
      result.payoffs[5].add(inside)
      result.total[1] += inside
      result.total[5] += inside
    var round = 2
    for repeat in 0 .. 3:
      for pair in [(0, 2), (1, 3), (4, 6), (5, 7)]:
        result.history.add(MeetingRecord(round: round, pair: 0, a: pair[0],
          b: pair[1], game: sgDilemma, moveA: MoveCooperate,
          moveB: MoveCooperate, payA: 2, payB: 2))
        result.payoffs[pair[0]].add(2)
        result.payoffs[pair[1]].add(2)
        result.total[pair[0]] += 2
        result.total[pair[1]] += 2
      inc round
    result.roundsPlayed = round
    result.done = true
    result.reason = "complete"
    result.phase = phDone

  test "a fed pair is flagged and a level table is not":
    let ring = ringFixture(10)
    let threads = ring.ringThreads()
    check threads.len == 1
    check threads[0][0] == 1
    check threads[0][1] == 5
    ## inMean 10.0, outMean 2.0 over the non-mutual meetings of both members.
    check abs(threads[0][2] - 8.0) < 1e-9
    check ring.resultsJson()["ringPairs"].getInt() == threads.len

    ## A table where everyone pays everyone 6 flags nothing: the pairings
    ## alternate so every seat has meetings outside every pair, which is what
    ## makes `outMean` meaningful and the delta zero.
    var uniform = initSim(fixture(77, 14))
    for r in 0 ..< 6:
      let pairs =
        if r mod 2 == 0: [(0, 1), (2, 3), (4, 5), (6, 7)]
        else: [(0, 2), (1, 3), (4, 6), (5, 7)]
      for pair in pairs:
        uniform.history.add(MeetingRecord(round: r, pair: 0, a: pair[0],
          b: pair[1], game: sgDilemma, moveA: MoveCooperate,
          moveB: MoveCooperate, payA: 6, payB: 6))
        uniform.payoffs[pair[0]].add(6)
        uniform.payoffs[pair[1]].add(6)
    check uniform.ringThreads().len == 0
    check uniform.resultsJson()["ringPairs"].getInt() == 0

  test "ring detection NEVER changes a score":
    let ring = ringFixture(10)
    let plain = ringFixture(2)
    check ring.ringThreads().len == 1
    check plain.ringThreads().len == 0
    let ringScores = ring.resultsJson()["scores"]
    let plainScores = plain.resultsJson()["scores"]
    ## The six seats outside the ring have byte-identical payoff histories in
    ## the two fixtures, so their scores must be byte-identical too: being
    ## next to a flagged pair costs nothing.
    for seat in [0, 2, 3, 4, 6, 7]:
      check ringScores[seat].getFloat() == plainScores[seat].getFloat()
    ## And each seat's score is exactly the median of its own payoff list,
    ## with no ring adjustment anywhere.
    for seat in 0 ..< Seats:
      var ordered = ring.payoffs[seat]
      ordered.sort()
      let n = ordered.len
      let expected =
        if n == 0: 0.0
        elif n mod 2 == 1: ordered[n div 2].float
        else: (ordered[n div 2 - 1] + ordered[n div 2]).float / 2.0
      check ringScores[seat].getFloat() == expected
    ## Computing the rings is a pure read: it cannot move a score.
    let before = $ring.resultsJson()["scores"]
    discard ring.ringThreads()
    discard ring.ringComponents()
    check $ring.resultsJson()["scores"] == before

suite "legality":
  test "a player count other than eight is refused":
    var config = fixture(1, 14)
    config.players.setLen(7)
    expect LedgerError:
      discard initSim(config)
    var wide = fixture(1, 14)
    wide.players.add(PlayerConfig(name: "P9"))
    expect LedgerError:
      discard initSim(wide)

  test "rounds below the minimum are refused":
    expect LedgerError:
      discard initSim(fixture(1, MinRounds - 1))
    expect LedgerError:
      discard initSim(fixture(1, MaxRounds + 1))

  test "applying out of phase, twice, or after the end raises":
    var sim = initSim(fixture(1, 4))
    var moves: array[Meetings, array[2, int]]
    var flags: array[Meetings, array[2, bool]]
    ## No round is open yet.
    expect LedgerError:
      sim.applyRound(moves, newSeq[string](Seats), newSeq[string](Seats),
        flags)
    sim.beginRound()
    for pair in 0 ..< Meetings:
      let meeting = sim.plan.pairs[pair]
      moves[pair] = [
        simpleMove(meeting.game, true, meeting.a, 0),
        simpleMove(meeting.game, false, meeting.b, 0)]
    sim.applyRound(moves, newSeq[string](Seats), newSeq[string](Seats), flags)
    ## Applying twice: the round is closed.
    expect LedgerError:
      sim.applyRound(moves, newSeq[string](Seats), newSeq[string](Seats),
        flags)
    expect LedgerError:
      sim.beginRound()
      sim.beginRound()

  test "an unclamped out-of-range move reaching applyRound raises":
    var sim = initSim(fixture(2, 4))
    sim.beginRound()
    var moves: array[Meetings, array[2, int]]
    var flags: array[Meetings, array[2, bool]]
    for pair in 0 ..< Meetings:
      let meeting = sim.plan.pairs[pair]
      moves[pair] = [
        simpleMove(meeting.game, true, meeting.a, 0),
        simpleMove(meeting.game, false, meeting.b, 0)]
    moves[0][0] = 9999
    expect LedgerError:
      sim.applyRound(moves, newSeq[string](Seats), newSeq[string](Seats),
        flags)
    ## The apply is transactional: a rejected round leaves the sim untouched,
    ## so the caller can replay it on the scripted baseline.
    check sim.phase == phDeal
    check sim.roundsPlayed == 0
    for seat in 0 ..< Seats:
      check sim.payoffs[seat].len == 0

suite "endings":
  test "a full run settles complete":
    let sim = playEpisode(fixture(31, 7))
    check sim.done
    check sim.reason == "complete"
    check sim.roundsPlayed == 7
    check sim.resultsJson()["reason"].getStr() == "complete"
    for seat in 0 ..< Seats:
      check sim.meetingCount(seat) == 7

  test "endEarly settles deadline and is idempotent":
    var sim = initSim(fixture(31, 14))
    sim.beginRound()
    var moves: array[Meetings, array[2, int]]
    var flags: array[Meetings, array[2, bool]]
    for pair in 0 ..< Meetings:
      let meeting = sim.plan.pairs[pair]
      moves[pair] = [
        simpleMove(meeting.game, true, meeting.a, 0),
        simpleMove(meeting.game, false, meeting.b, 0)]
    sim.applyRound(moves, newSeq[string](Seats), newSeq[string](Seats), flags)
    sim.endEarly()
    check sim.done
    check sim.reason == "deadline"
    check sim.roundsPlayed == 1
    sim.endEarly()
    check sim.reason == "deadline"
    let results = sim.resultsJson()
    check results["reason"].getStr() in ["complete", "deadline"]
    check results["rounds"].getInt() == 1
    check results["maxRounds"].getInt() == 14

suite "replay":
  test "replayMatch re-derives one frame per event prefix":
    let live = playEpisode(fixture(101, 8))
    let frames = replayMatch(live.config, live.events)
    check frames.len == live.events.len + 1
    check $frames[^1].tableStateJson() == $live.tableStateJson()
    check $frames[^1].resultsJson() == $live.resultsJson()
    ## Mid-replay frames are real states, not repeats of the last one.
    check $frames[1].tableStateJson() != $frames[^1].tableStateJson()

  test "every frame re-derives the prefix it stands for, field by field":
    ## Frame by frame, not just the endpoint. Three checks per tick:
    let live = playEpisode(fixture(101, 8))
    let checkpoints = liveCheckpoints
    let frames = replayMatch(live.config, live.events)
    check frames.len == live.events.len + 1
    var distinctStates: HashSet[string]
    for i in 0 .. live.events.len:
      ## 1. The frame's own event log is the recorded prefix - and every one
      ##    of those events was REBUILT by the rules (beginRound, applyMeeting,
      ##    applyGossip and settle each append their own derived event, which
      ##    replayMatch never overwrites with the recorded one), so this
      ##    compares every field of every event: both payoffs, both moves,
      ##    both memos, both scripted flags, the pairings and the first movers.
      check frames[i].events == live.events[0 ..< i]
      ## 2. Replaying only that prefix lands on exactly that frame: no frame
      ##    borrows state from an event that has not been played yet.
      let prefix = replayMatch(live.config, live.events[0 ..< i])
      check prefix.len == i + 1
      check $prefix[^1].tableStateJson() == $frames[i].tableStateJson()
      distinctStates.incl($frames[i].tableStateJson())
    ## 3. Every tick at which the LIVE sim published a state - each round's
    ##    open and the settlement - is reproduced exactly by the frame with
    ##    that event count. (The round-CLOSE tick is not a shared tick: the
    ##    recorded log has no "round closed" event, so replayMatch keeps the
    ##    round open until the next `round` event arrives, by design -
    ##    src/ledger/sim.nim:861-867.)
    check checkpoints.len == live.config.rounds + 1
    for (count, state) in checkpoints:
      check count <= live.events.len
      check $frames[count].tableStateJson() == state
    ## The timeline actually moves: one distinct state per round open at least.
    check distinctStates.len >= live.config.rounds

  test "a tampered round event is rejected":
    let live = playEpisode(fixture(101, 8))
    var events = live.events
    var index = -1
    for position, event in events:
      if event.kind == evRound:
        index = position
        break
    check index >= 0
    swap(events[index].pairsA[0], events[index].pairsA[1])
    expect LedgerError:
      discard replayMatch(live.config, events)

  test "every event kind round-trips through JSON with every field":
    let live = playEpisode(fixture(101, 8))
    var kinds: HashSet[EventKind]
    for event in live.events:
      kinds.incl(event.kind)
      check eventFromJson(event.eventToJson()) == event
    check kinds.len == 5
    for kind in [evStart, evRound, evMeeting, evGossip, evEnd]:
      check kind in kinds

  test "the replay schedule matches the seeded derivation":
    let live = playEpisode(fixture(101, 8))
    let schedule = live.scheduleJson()
    check schedule.len == live.config.rounds
    for r in 0 ..< live.config.rounds:
      for pair in 0 ..< Meetings:
        let meeting = live.schedule[r].pairs[pair]
        check schedule[r][pair]["a"].getInt() == meeting.a
        check schedule[r][pair]["b"].getInt() == meeting.b
        check schedule[r][pair]["game"].getStr() == $meeting.game
        check schedule[r][pair]["first"].getInt() == meeting.a

suite "determinism":
  test "the same seed yields the same episode":
    for seed in [1, 7, 42, 1234]:
      let a = playEpisode(fixture(seed, 14))
      let b = playEpisode(fixture(seed, 14))
      check a.names == b.names
      check a.schedule == b.schedule
      check $a.tableStateJson() == $b.tableStateJson()
      check $a.resultsJson() == $b.resultsJson()

  test "different seeds differ":
    let a = initSim(fixture(1, 14))
    let b = initSim(fixture(2, 14))
    check a.schedule != b.schedule

  test "aliases come from the CogNames pool and are distinct":
    for seed in [1, 7, 42, 1234]:
      let sim = initSim(fixture(seed, 14))
      var seen: HashSet[string]
      for name in sim.names:
        check name in CogNames
        seen.incl(name)
      check seen.len == Seats

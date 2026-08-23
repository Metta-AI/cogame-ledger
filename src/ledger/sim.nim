## Pure game rules for Ledger. No IO, no networking, no LLM — the server,
## the tests, and the wasm replay viewer all drive this same module.
##
## A `Sim` is one whole episode: the seeded aliases, the precomputed pairing
## schedule with every round's four meetings (their subgame and first mover),
## each seat's payoff list and conduct tallies, the public gossip board, and
## the append-only event log. Everything random is drawn from the seed at
## `initSim`, so a replay re-derives the episode from the recorded meeting /
## gossip events alone.

import std/[algorithm, json, math, random, strutils], types

export types

const
  ## An episode's whole model-call allowance (one call per seat per round).
  ## A hosted episode is killed if it outlives the platform's artifact
  ## timeout, so `rounds` is capped to this at sample time.
  EpisodeCallBudget* = 240
  CallsPerRound* = 8
  Seats* = 8
  Meetings* = 4          ## pairs resolved per round
  RoundsPerPass* = 7     ## rounds in one complete round robin of 8 seats
  MinRounds* = 4
  MaxRounds* = 28

  ## Payoff table constants. Fair play pays 6 in all three subgames,
  ## exploitation pays 10-12, being exploited pays 0.
  InvestorEndowment* = 6
  TrusteeEndowment* = 2
  TrustMultiplier* = 2
  Pie* = 12
  PdReward* = 6
  PdTemptation* = 10
  PdPunishment* = 2
  PdSucker* = 0

  ## Move encodings for the dilemma.
  MoveCooperate* = 0
  MoveDefect* = 1

  ## Conduct thresholds (display statistics, never a score input).
  KindSendMin* = 3       ## TRUST investor: sent >= 3 is kind
  KindReturnMin* = 50    ## TRUST trustee: return percent >= 50 is kind
  KindOfferMin* = 5      ## ULTIMATUM proposer: offer >= 5 is kind
  KindFloorMax* = 5      ## ULTIMATUM responder: floor <= 5 is kind

  GossipWindow* = 12
  HistoryWindow* = 8
  MaxNoteLen* = 120
  MaxMemoLen* = 400

  RingMinMeetings* = 2
  RingInThreshold* = 6.0
  RingDeltaThreshold* = 3.0

  ## Anonymous table aliases; 8 of these 10 are drawn per episode.
  CogNames* = [
    "Sprocket", "Gizmo", "Ratchet", "Widget", "Bolt",
    "Piston", "Flywheel", "Rivet", "Tinker", "Gasket"
  ]

type
  Phase* = enum
    phDeal = "deal"        ## the round is open; all 8 seats are deciding
    phResolve = "resolve"  ## the meetings have landed; icons are showing
    phBetween = "between"
    phDone = "done"

  MeetingPlan* = object
    a*: int      ## first mover for TRUST/ULTIMATUM; the lower seat id for a dilemma
    b*: int      ## second mover / the other seat
    game*: SubGame

  RoundPlan* = object
    pairs*: array[Meetings, MeetingPlan]

  Gossip* = object
    round*: int
    author*: int
    subject*: int
    text*: string

  MeetingRecord* = object
    round*: int
    pair*: int
    a*, b*: int
    game*: SubGame
    moveA*, moveB*: int
    payA*, payB*: int

  Sim* = object
    config*: GameConfig
    names*: seq[string]                  ## anonymous table aliases per seat
    schedule*: seq[RoundPlan]            ## one plan per round, drawn at init
    round*: int                          ## round in progress / last shown; -1 before the first
    phase*: Phase
    moves*: array[Meetings, array[2, int]]        ## live round; int.low = unmade
    scriptedFlags*: array[Meetings, array[2, bool]]
    pays*: array[Meetings, array[2, int]]         ## live round; int.low = unresolved
    payoffs*: array[Seats, seq[int]]     ## every meeting payoff, in round order
    kind*: array[Seats, int]
    harsh*: array[Seats, int]
    total*: array[Seats, int]
    memos*: seq[string]                  ## latest private memo per seat
    board*: seq[Gossip]                  ## the public gossip board, insertion order
    history*: seq[MeetingRecord]         ## every resolved meeting, in order
    roundsPlayed*: int
    done*: bool
    reason*: string                      ## "complete" | "deadline"
    events*: seq[GameEvent]

# ---- Naming and small helpers ----------------------------------------------

proc subGameName*(game: SubGame): string =
  ## Words, never notation: a spectator reads DILEMMA, not "PD".
  case game
  of sgDilemma: "DILEMMA"
  of sgTrust: "TRUST"
  of sgUltimatum: "ULTIMATUM"

proc roleName*(game: SubGame, first: bool): string =
  case game
  of sgDilemma: "EITHER"
  of sgTrust: (if first: "INVESTOR" else: "TRUSTEE")
  of sgUltimatum: (if first: "PROPOSER" else: "RESPONDER")

proc legalMoveRange*(game: SubGame, first: bool): (int, int) =
  ## The inclusive range of legal raw move values for a (subgame, role).
  case game
  of sgDilemma: (0, 1)
  of sgTrust: (if first: (0, InvestorEndowment) else: (0, 100))
  of sgUltimatum: (0, Pie)

proc clampMove*(game: SubGame, first: bool, move: int): int =
  let (lo, hi) = legalMoveRange(game, first)
  max(lo, min(hi, move))

proc moveText*(game: SubGame, first: bool, move: int): string =
  ## How a move reads in the feed and in an observation line.
  case game
  of sgDilemma:
    if move == MoveCooperate: "cooperate" else: "defect"
  of sgTrust:
    if first: "sent " & $move else: "returned " & $move & "%"
  of sgUltimatum:
    if first: "offered " & $move else: "floor " & $move

# ---- Payoff kernels ---------------------------------------------------------

proc pdPayoffs*(moveA, moveB: int): (int, int) =
  ## Both choose cooperate (0) or defect (1), simultaneously.
  if moveA == MoveCooperate and moveB == MoveCooperate:
    (PdReward, PdReward)
  elif moveA == MoveCooperate:
    (PdSucker, PdTemptation)
  elif moveB == MoveCooperate:
    (PdTemptation, PdSucker)
  else:
    (PdPunishment, PdPunishment)

proc trustPayoffs*(sent, percent: int): (int, int) =
  ## Investor sends `sent` of 6; it doubles on the way; the trustee's
  ## committed return percentage is applied to what arrives, rounded half up.
  ## Coin invariant: investor + trustee == 8 + sent.
  let arrived = TrustMultiplier * sent
  var returned = (arrived * percent + 50) div 100
  returned = max(0, min(arrived, returned))
  (InvestorEndowment - sent + returned, TrusteeEndowment + arrived - returned)

proc ultimatumPayoffs*(offer, floorValue: int): (int, int) =
  ## Proposer offers `offer` of a 12-coin pie; the responder's committed
  ## minimum acceptable offer is `floorValue`. Total is 12 or 0.
  if offer >= floorValue:
    (Pie - offer, offer)
  else:
    (0, 0)

proc meetingPayoffs*(game: SubGame, moveA, moveB: int): (int, int) =
  case game
  of sgDilemma: pdPayoffs(moveA, moveB)
  of sgTrust: trustPayoffs(moveA, moveB)
  of sgUltimatum: ultimatumPayoffs(moveA, moveB)

proc isKind*(game: SubGame, first: bool, move: int): bool =
  ## The conduct classification of one seat's move in one meeting.
  case game
  of sgDilemma: move == MoveCooperate
  of sgTrust: (if first: move >= KindSendMin else: move >= KindReturnMin)
  of sgUltimatum: (if first: move >= KindOfferMin else: move <= KindFloorMax)

# ---- Setup ------------------------------------------------------------------

proc tableNames*(players: seq[PlayerConfig], seed: int): seq[string] =
  ## Policy display names never reach the table: every seat plays under an
  ## anonymous cog alias, drawn deterministically from the seed so replays
  ## and the live table agree.
  var rng = initRand(int64(seed) * 6779 + 31)
  var pool = @CogNames
  rng.shuffle(pool)
  for index in 0 ..< players.len:
    if index < pool.len:
      result.add(pool[index])
    else:
      result.add("Cog " & $(index + 1))

proc maxMeetings*(rounds: int): int =
  ## With the circle-method schedule, any two aliases meet at most this many
  ## times over `rounds` rounds. A derived constant, not an enforcement branch.
  (rounds + RoundsPerPass - 1) div RoundsPerPass

proc sampleEpisode*(config: GameConfig): GameConfig =
  ## Fits the round count into one episode's call budget. Idempotent: a
  ## config that already carries the cap (a replay being re-read) is
  ## untouched.
  result = config
  if result.sampled:
    return
  result.rounds = max(
    min(config.rounds, min(EpisodeCallBudget div CallsPerRound, MaxRounds)),
    MinRounds)
  result.sampled = true

proc positionMatching(k: int): array[Meetings, (int, int)] =
  ## The standard circle-method 1-factorization of 8 positions: position 7 is
  ## fixed and 0..6 rotate around it. Across k = 0..6 every unordered pair of
  ## positions occurs exactly once.
  result[0] = (RoundsPerPass, k)
  for i in 1 .. 3:
    result[i] = ((k + i) mod RoundsPerPass, (k - i + RoundsPerPass) mod RoundsPerPass)

proc addEvent(sim: var Sim, event: GameEvent) =
  sim.events.add(event)

proc blankEvent(kind: EventKind): GameEvent =
  GameEvent(kind: kind, round: -1, pair: -1, seat: -1, other: -1,
    game: sgDilemma, moveA: int.low, moveB: int.low,
    payA: int.low, payB: int.low)

proc drawSchedule(rng: var Rand, rounds: int): seq[RoundPlan] =
  ## Positions are relabelled once by a seeded permutation so the partner
  ## sequence looks different every episode while the exact-cover property
  ## survives. Rounds come in passes of 7 (one complete round robin); each
  ## pass shuffles the order of the seven matchings, resampling so no pair
  ## meets in two consecutive rounds across a pass boundary.
  var perm = newSeq[int](Seats)
  for index in 0 ..< Seats:
    perm[index] = index
  rng.shuffle(perm)

  var firstCount: array[Seats, int]
  var previous: seq[int]
  let passes = (rounds + RoundsPerPass - 1) div RoundsPerPass
  var produced = 0
  for pass in 0 ..< passes:
    var order = newSeq[int](RoundsPerPass)
    for index in 0 ..< RoundsPerPass:
      order[index] = index
    rng.shuffle(order)
    if previous.len > 0:
      var attempts = 0
      while order[0] == previous[^1] and attempts < 16:
        rng.shuffle(order)
        inc attempts
    previous = order
    for j in 0 ..< RoundsPerPass:
      if produced >= rounds:
        break
      var plan: RoundPlan
      let matching = positionMatching(order[j])
      for pair in 0 ..< Meetings:
        let (x, y) = matching[pair]
        let seatX = perm[x]
        let seatY = perm[y]
        let draw = rng.rand(99)
        let game =
          if draw < 50: sgDilemma
          elif draw < 80: sgTrust
          else: sgUltimatum
        if game == sgDilemma:
          ## Symmetric: `a` is simply the lower seat id so the record is
          ## canonical.
          plan.pairs[pair] = MeetingPlan(
            a: min(seatX, seatY), b: max(seatX, seatY), game: game)
        else:
          ## The first mover is the pair member with fewer first-mover
          ## assignments so far in the schedule being built; ties break on
          ## the seeded RNG.
          var first = seatX
          var second = seatY
          if firstCount[seatY] < firstCount[seatX]:
            first = seatY
            second = seatX
          elif firstCount[seatX] == firstCount[seatY] and rng.rand(1.0) < 0.5:
            first = seatY
            second = seatX
          inc firstCount[first]
          plan.pairs[pair] = MeetingPlan(a: first, b: second, game: game)
      result.add(plan)
      inc produced

proc initSim*(config: GameConfig): Sim =
  if config.players.len != Seats:
    raise newException(LedgerError,
      "ledger needs exactly " & $Seats & " players")
  if config.rounds < MinRounds:
    raise newException(LedgerError,
      "rounds must be at least " & $MinRounds)
  if config.rounds > MaxRounds:
    raise newException(LedgerError,
      "rounds must be at most " & $MaxRounds)
  result = Sim(config: config, names: tableNames(config.players, config.seed))
  ## One stream for everything the seed decides: the relabelling, the pass
  ## orders, the subgames, and the first-mover assignment.
  var rng = initRand(int64(config.seed) * 7919 + 17)
  result.schedule = rng.drawSchedule(config.rounds)
  result.round = -1
  result.phase = phBetween
  result.memos = newSeq[string](Seats)
  for pair in 0 ..< Meetings:
    result.moves[pair] = [int.low, int.low]
    result.pays[pair] = [int.low, int.low]
  result.addEvent(blankEvent(evStart))

# ---- Queries ----------------------------------------------------------------

proc plan*(sim: Sim): RoundPlan =
  ## The plan of the round in progress (or last shown).
  if sim.round < 0:
    raise newException(LedgerError, "no round has started")
  sim.schedule[sim.round]

proc pairIndexOf*(sim: Sim, roundIndex, seat: int): int =
  ## Which of the four meetings of `roundIndex` this seat is in; -1 if none.
  if roundIndex < 0 or roundIndex >= sim.schedule.len:
    return -1
  for pair in 0 ..< Meetings:
    let meeting = sim.schedule[roundIndex].pairs[pair]
    if meeting.a == seat or meeting.b == seat:
      return pair
  -1

proc partnerIn*(sim: Sim, roundIndex, seat: int): int =
  ## The seat paired with `seat` in `roundIndex`; -1 if there is no such round.
  let pair = sim.pairIndexOf(roundIndex, seat)
  if pair < 0:
    return -1
  let meeting = sim.schedule[roundIndex].pairs[pair]
  if meeting.a == seat: meeting.b else: meeting.a

proc partnerOf*(sim: Sim, seat: int): int =
  ## The seat paired with `seat` in the shown round; -1 before the first.
  sim.partnerIn(sim.round, seat)

proc noteTarget*(sim: Sim, seat: int): int =
  ## The alias a seat may review this round: its partner from the PREVIOUS
  ## round's meeting, the last outcome it has actually seen. -1 in round 1.
  if sim.round <= 0:
    return -1
  sim.partnerIn(sim.round - 1, seat)

proc isFirstMover*(sim: Sim, roundIndex, seat: int): bool =
  let pair = sim.pairIndexOf(roundIndex, seat)
  pair >= 0 and sim.schedule[roundIndex].pairs[pair].a == seat

proc metCount*(sim: Sim, a, b: int): int =
  for record in sim.history:
    if (record.a == a and record.b == b) or (record.a == b and record.b == a):
      inc result

proc median*(sim: Sim, seat: int): float =
  ## THE score: the seat's median per-meeting payoff in coins. A ring can
  ## pump the mean of an alias it feeds; with at most 2 of 14 meetings inside
  ## the ring it cannot move that alias's median.
  let count = sim.payoffs[seat].len
  if count == 0:
    return 0.0
  var ordered = sim.payoffs[seat]
  ordered.sort()
  if count mod 2 == 1:
    ordered[count div 2].float
  else:
    (ordered[count div 2 - 1] + ordered[count div 2]).float / 2.0

proc meanPay*(sim: Sim, seat: int): float =
  if sim.payoffs[seat].len == 0:
    return 0.0
  var sum = 0
  for value in sim.payoffs[seat]:
    sum += value
  sum.float / sim.payoffs[seat].len.float

proc halo*(sim: Sim, seat: int): float =
  ## The reputation ring: kind / (kind + harsh), exactly 0.5 before a seat's
  ## first meeting. A display and observation statistic, never a score input.
  let total = sim.kind[seat] + sim.harsh[seat]
  if total == 0:
    return 0.5
  sim.kind[seat].float / total.float

proc meetingCount*(sim: Sim, seat: int): int =
  sim.payoffs[seat].len

proc payoffOf*(record: MeetingRecord, seat: int): int =
  if record.a == seat: record.payA else: record.payB

proc ringThreads*(sim: Sim): seq[(int, int, float)] =
  ## Published as a finding, never a score input. A pair is flagged when it
  ## met at least twice, the mean payoff INSIDE the pair is at least 6 coins,
  ## and that beats the two members' mean payoff outside the pair by 3.
  for a in 0 ..< Seats:
    for b in a + 1 ..< Seats:
      var inSum = 0.0
      var inCount = 0
      var outSum = 0.0
      var outCount = 0
      for record in sim.history:
        let hasA = record.a == a or record.b == a
        let hasB = record.a == b or record.b == b
        if hasA and hasB:
          inSum += (record.payA + record.payB).float / 2.0
          inc inCount
        elif hasA:
          outSum += record.payoffOf(a).float
          inc outCount
        elif hasB:
          outSum += record.payoffOf(b).float
          inc outCount
      if inCount < RingMinMeetings:
        continue
      let inMean = inSum / inCount.float
      let outMean = if outCount == 0: 0.0 else: outSum / outCount.float
      let delta = inMean - outMean
      if inMean >= RingInThreshold and delta >= RingDeltaThreshold:
        result.add((a, b, math.round(delta * 10.0) / 10.0))

proc ringComponents*(sim: Sim): seq[seq[int]] =
  ## Connected components of size >= 3 in the flagged graph — the cartel as a
  ## picture. Reported for the viewer caption; nothing is ever rescored.
  var adjacency: array[Seats, set[uint8]]
  var touched: set[uint8]
  for thread in sim.ringThreads():
    adjacency[thread[0]].incl(uint8(thread[1]))
    adjacency[thread[1]].incl(uint8(thread[0]))
    touched.incl(uint8(thread[0]))
    touched.incl(uint8(thread[1]))
  var seen: set[uint8]
  for seat in 0 ..< Seats:
    if uint8(seat) notin touched or uint8(seat) in seen:
      continue
    var stack = @[seat]
    var component: seq[int]
    seen.incl(uint8(seat))
    while stack.len > 0:
      let current = stack.pop()
      component.add(current)
      for other in 0 ..< Seats:
        if uint8(other) in adjacency[current] and uint8(other) notin seen:
          seen.incl(uint8(other))
          stack.add(other)
    if component.len >= 3:
      component.sort()
      result.add(component)

proc recentMeetings*(sim: Sim, seat: int, limit = HistoryWindow):
    seq[MeetingRecord] =
  ## The seat's last `limit` meetings, oldest first.
  var mine: seq[MeetingRecord]
  for record in sim.history:
    if record.a == seat or record.b == seat:
      mine.add(record)
  let start = max(0, mine.len - limit)
  for index in start ..< mine.len:
    result.add(mine[index])

# ---- Play -------------------------------------------------------------------

proc settle(sim: var Sim, reason: string) =
  sim.done = true
  sim.reason = reason
  sim.phase = phDone
  var event = blankEvent(evEnd)
  event.round = sim.roundsPlayed
  event.text = reason
  sim.addEvent(event)

proc beginRound*(sim: var Sim) =
  ## Opens the next round: publishes its four pairings, their subgames, and
  ## each pairing's first mover. The plaza is public.
  if sim.done:
    raise newException(LedgerError, "the episode is over")
  if sim.phase != phBetween:
    raise newException(LedgerError, "a round is already in progress")
  sim.round = sim.roundsPlayed
  sim.phase = phDeal
  for pair in 0 ..< Meetings:
    sim.moves[pair] = [int.low, int.low]
    sim.pays[pair] = [int.low, int.low]
    sim.scriptedFlags[pair] = [false, false]
  let plan = sim.plan
  var event = blankEvent(evRound)
  event.round = sim.round
  for pair in 0 ..< Meetings:
    let meeting = plan.pairs[pair]
    event.pairsA.add(meeting.a)
    event.pairsB.add(meeting.b)
    event.pairsGame.add(meeting.game)
    event.pairsFirst.add(meeting.a)
  sim.addEvent(event)

proc setMemo*(sim: var Sim, seat: int, memo: string) =
  ## A memo is overwritten when the reply carried one and kept otherwise.
  if memo.len > 0:
    sim.memos[seat] = memo

proc applyMeeting*(sim: var Sim, pair, moveA, moveB: int,
    scriptedA, scriptedB: bool) =
  ## Resolves one of the round's four meetings: both payoffs, both seats'
  ## conduct counters, and one `meeting` event. Raises on an out-of-range
  ## move — the caller clamps before it gets here, so anything illegal that
  ## reaches this point is a programming error.
  if sim.done:
    raise newException(LedgerError, "the episode is over")
  if sim.phase != phDeal and sim.phase != phResolve:
    raise newException(LedgerError, "no round is open")
  if pair < 0 or pair >= Meetings:
    raise newException(LedgerError, "bad pair index: " & $pair)
  if sim.moves[pair][0] != int.low:
    raise newException(LedgerError, "pair " & $pair & " already resolved")
  let meeting = sim.plan.pairs[pair]
  let (loA, hiA) = legalMoveRange(meeting.game, true)
  let (loB, hiB) = legalMoveRange(meeting.game, false)
  if moveA < loA or moveA > hiA:
    raise newException(LedgerError, "move " & $moveA & " out of range " &
      $loA & ".." & $hiA & " for " & subGameName(meeting.game))
  if moveB < loB or moveB > hiB:
    raise newException(LedgerError, "move " & $moveB & " out of range " &
      $loB & ".." & $hiB & " for " & subGameName(meeting.game))
  let (payA, payB) = meetingPayoffs(meeting.game, moveA, moveB)
  sim.moves[pair] = [moveA, moveB]
  sim.pays[pair] = [payA, payB]
  sim.scriptedFlags[pair] = [scriptedA, scriptedB]
  sim.payoffs[meeting.a].add(payA)
  sim.payoffs[meeting.b].add(payB)
  sim.total[meeting.a] += payA
  sim.total[meeting.b] += payB
  if isKind(meeting.game, true, moveA):
    inc sim.kind[meeting.a]
  else:
    inc sim.harsh[meeting.a]
  if isKind(meeting.game, false, moveB):
    inc sim.kind[meeting.b]
  else:
    inc sim.harsh[meeting.b]
  sim.history.add(MeetingRecord(round: sim.round, pair: pair, a: meeting.a,
    b: meeting.b, game: meeting.game, moveA: moveA, moveB: moveB,
    payA: payA, payB: payB))
  var event = blankEvent(evMeeting)
  event.round = sim.round
  event.pair = pair
  event.seat = meeting.a
  event.other = meeting.b
  event.game = meeting.game
  event.moveA = moveA
  event.moveB = moveB
  event.payA = payA
  event.payB = payB
  event.scriptedA = scriptedA
  event.scriptedB = scriptedB
  event.memoA = sim.memos[meeting.a]
  event.memoB = sim.memos[meeting.b]
  sim.addEvent(event)
  sim.phase = phResolve

proc applyGossip*(sim: var Sim, seat, subject: int, text: string) =
  ## One public review, attributed by alias. Gossip is cheap talk: it never
  ## changes a payoff or a score.
  if sim.done:
    raise newException(LedgerError, "the episode is over")
  if text.len == 0:
    return
  let target = sim.noteTarget(seat)
  if target < 0:
    raise newException(LedgerError,
      "seat " & $seat & " has no note target this round")
  if subject != target:
    raise newException(LedgerError, "a note reviews last round's partner (" &
      $target & "), not seat " & $subject)
  sim.board.add(Gossip(round: sim.round, author: seat, subject: subject,
    text: text))
  var event = blankEvent(evGossip)
  event.round = sim.round
  event.seat = seat
  event.other = subject
  event.text = text
  sim.addEvent(event)

proc closeRound*(sim: var Sim) =
  ## Steps 7-8 of the resolution order: the live medians and the ring
  ## statistics are derived state, so nothing is written here but the round
  ## counter and, at the end, the settlement.
  if sim.done:
    raise newException(LedgerError, "the episode is over")
  if sim.phase != phResolve:
    raise newException(LedgerError, "the round has not resolved")
  inc sim.roundsPlayed
  if sim.roundsPlayed >= sim.config.rounds:
    sim.settle("complete")
  else:
    sim.phase = phBetween

proc applyRound*(sim: var Sim, moves: array[Meetings, array[2, int]],
    notes, memos: seq[string],
    scripted: array[Meetings, array[2, bool]]) =
  ## The single transactional apply: resolution steps 4-8 of one round.
  ## `notes` and `memos` are indexed by SEAT. Transactional means it: the
  ## work happens on a copy and is committed only once every meeting and
  ## every note has been accepted, so a rejected round leaves the sim exactly
  ## as it was and the caller can replay it on the scripted baseline.
  if sim.done:
    raise newException(LedgerError, "the episode is over")
  if sim.phase != phDeal:
    raise newException(LedgerError, "no round is waiting on decisions")
  if notes.len != Seats or memos.len != Seats:
    raise newException(LedgerError,
      "notes and memos must carry one entry per seat")
  var probe = sim
  ## Memos first, so each meeting event carries the memo the seat wrote with
  ## this round's reply.
  for seat in 0 ..< Seats:
    probe.setMemo(seat, memos[seat])
  for pair in 0 ..< Meetings:
    probe.applyMeeting(pair, moves[pair][0], moves[pair][1],
      scripted[pair][0], scripted[pair][1])
  for seat in 0 ..< Seats:
    if notes[seat].len > 0 and probe.noteTarget(seat) >= 0:
      probe.applyGossip(seat, probe.noteTarget(seat), notes[seat])
  probe.closeRound()
  sim = probe

proc endEarly*(sim: var Sim) =
  ## Stop now. The hosted platform kills an episode that outlives its
  ## timeout and keeps NOTHING, so a short honest episode always beats a long
  ## one that never lands. Scores use the rounds actually played.
  if sim.done:
    return
  sim.settle("deadline")

# ---- Results ----------------------------------------------------------------

proc resultsJson*(sim: Sim): JsonNode =
  var names = newJArray()
  var scores = newJArray()
  var means = newJArray()
  var totals = newJArray()
  var meetings = newJArray()
  var kinds = newJArray()
  var harshes = newJArray()
  for seat in 0 ..< Seats:
    ## Results are platform-facing: the league attributes scores by POLICY
    ## name, not by the anonymous alias the seat played under.
    names.add(%sim.config.players[seat].name)
    scores.add(%sim.median(seat))
    means.add(%sim.meanPay(seat))
    totals.add(%sim.total[seat])
    meetings.add(%sim.meetingCount(seat))
    kinds.add(%sim.kind[seat])
    harshes.add(%sim.harsh[seat])
  %*{
    "names": names,
    "scores": scores,
    "mean": means,
    "total": totals,
    "meetings": meetings,
    "kind": kinds,
    "harsh": harshes,
    "rounds": sim.roundsPlayed,
    "maxRounds": sim.config.rounds,
    "ringPairs": sim.ringThreads().len,
    "reason": (if sim.done: sim.reason else: "")
  }

# ---- Viewer state -----------------------------------------------------------

proc pairsJson(sim: Sim): JsonNode =
  ## The round in progress (or the last completed round once done); empty
  ## before the first round.
  result = newJArray()
  if sim.round < 0:
    return
  let plan = sim.plan
  for pair in 0 ..< Meetings:
    let meeting = plan.pairs[pair]
    let resolved = sim.moves[pair][0] != int.low
    result.add(%*{
      "a": meeting.a,
      "b": meeting.b,
      "game": $meeting.game,
      "first": meeting.a,
      "moveA": (if resolved: %sim.moves[pair][0] else: newJNull()),
      "moveB": (if resolved: %sim.moves[pair][1] else: newJNull()),
      "payA": (if resolved: %sim.pays[pair][0] else: newJNull()),
      "payB": (if resolved: %sim.pays[pair][1] else: newJNull()),
      "resolved": resolved
    })

proc tableStateJson*(sim: Sim): JsonNode =
  var seats = newJArray()
  for seat in 0 ..< Seats:
    let pair = sim.pairIndexOf(sim.round, seat)
    let meeting =
      if pair >= 0: sim.plan.pairs[pair]
      else: MeetingPlan(a: -1, b: -1, game: sgDilemma)
    let first = pair >= 0 and meeting.a == seat
    let side = if meeting.a == seat: 0 else: 1
    let resolved = pair >= 0 and sim.moves[pair][0] != int.low
    seats.add(%*{
      "name": sim.names[seat],
      "score": sim.median(seat),
      "mean": sim.meanPay(seat),
      "total": sim.total[seat],
      "meetings": sim.meetingCount(seat),
      "kind": sim.kind[seat],
      "harsh": sim.harsh[seat],
      "halo": sim.halo(seat),
      "partner": (if pair >= 0: %sim.partnerOf(seat) else: newJNull()),
      "game": (if pair >= 0: %($meeting.game) else: newJNull()),
      "role": (if pair >= 0: %(roleName(meeting.game, first).toLowerAscii())
               else: newJNull()),
      "move": (if resolved: %sim.moves[pair][side] else: newJNull()),
      "lastPay": (if resolved: %sim.pays[pair][side] else: newJNull()),
      "memo": %sim.memos[seat],
      "scripted": (if pair >= 0: %sim.scriptedFlags[pair][side] else: %false)
    })
  var gossip = newJArray()
  let start = max(0, sim.board.len - GossipWindow)
  for index in start ..< sim.board.len:
    let note = sim.board[index]
    gossip.add(%*{
      "round": note.round,
      "author": note.author,
      "subject": note.subject,
      "text": note.text
    })
  var rings = newJArray()
  for thread in sim.ringThreads():
    rings.add(%*{"a": thread[0], "b": thread[1], "delta": thread[2]})
  %*{
    "seats": seats,
    "round": sim.round,
    "rounds": sim.config.rounds,
    "roundsPlayed": sim.roundsPlayed,
    "pairs": sim.pairsJson(),
    "gossip": gossip,
    "rings": rings,
    "phase": $sim.phase,
    "gameDone": sim.done,
    "reason": sim.reason
  }

# ---- Event JSON -------------------------------------------------------------

proc eventToJson*(event: GameEvent): JsonNode =
  result = %*{"kind": $event.kind}
  if event.round >= 0:
    result["round"] = %event.round
  case event.kind
  of evStart:
    discard
  of evRound:
    var pairs = newJArray()
    for index in 0 ..< event.pairsA.len:
      pairs.add(%*{
        "a": event.pairsA[index],
        "b": event.pairsB[index],
        "game": $event.pairsGame[index],
        "first": event.pairsFirst[index]
      })
    result["pairs"] = pairs
  of evMeeting:
    result["pair"] = %event.pair
    result["seat"] = %event.seat
    result["other"] = %event.other
    result["game"] = %($event.game)
    result["moveA"] = %event.moveA
    result["moveB"] = %event.moveB
    result["payA"] = %event.payA
    result["payB"] = %event.payB
    result["scriptedA"] = %event.scriptedA
    result["scriptedB"] = %event.scriptedB
    if event.memoA.len > 0:
      result["memoA"] = %event.memoA
    if event.memoB.len > 0:
      result["memoB"] = %event.memoB
  of evGossip:
    result["seat"] = %event.seat
    result["other"] = %event.other
  of evEnd:
    discard
  if event.text.len > 0:
    result["text"] = %event.text

proc eventFromJson*(node: JsonNode): GameEvent =
  result = GameEvent(
    kind: parseEnum[EventKind](node["kind"].getStr()),
    round: node{"round"}.getInt(-1),
    pair: node{"pair"}.getInt(-1),
    seat: node{"seat"}.getInt(-1),
    other: node{"other"}.getInt(-1),
    game: parseEnum[SubGame](node{"game"}.getStr("pd")),
    moveA: node{"moveA"}.getInt(int.low),
    moveB: node{"moveB"}.getInt(int.low),
    payA: node{"payA"}.getInt(int.low),
    payB: node{"payB"}.getInt(int.low),
    scriptedA: node{"scriptedA"}.getBool(false),
    scriptedB: node{"scriptedB"}.getBool(false),
    memoA: node{"memoA"}.getStr(""),
    memoB: node{"memoB"}.getStr(""),
    text: node{"text"}.getStr("")
  )
  if node.hasKey("pairs"):
    for pair in node["pairs"]:
      result.pairsA.add(pair["a"].getInt())
      result.pairsB.add(pair["b"].getInt())
      result.pairsGame.add(parseEnum[SubGame](pair["game"].getStr()))
      result.pairsFirst.add(pair{"first"}.getInt(pair["a"].getInt()))

proc scheduleJson*(sim: Sim): JsonNode =
  ## The fully expanded pairing / subgame / first-mover schedule. It is
  ## derivable from the seed and written anyway, so the viewer never has to
  ## trust a re-derivation to draw the plaza; `replayMatch` cross-checks it.
  result = newJArray()
  for plan in sim.schedule:
    var pairs = newJArray()
    for pair in 0 ..< Meetings:
      let meeting = plan.pairs[pair]
      pairs.add(%*{
        "a": meeting.a,
        "b": meeting.b,
        "game": $meeting.game,
        "first": meeting.a
      })
    result.add(pairs)

# ---- Replay -----------------------------------------------------------------

proc replayMatch*(config: GameConfig, events: seq[GameEvent]): seq[Sim] =
  ## Re-derives the state timeline from a recorded event log by replaying the
  ## meeting and gossip events through the rules (the schedule comes from the
  ## seed). frames[i] = state after events[0 ..< i]; the replayed sim's own
  ## event log mirrors the prefix so the feed lines up.
  var sim = initSim(config)
  ## initSim already logged the start event; the recorded log's first event
  ## is that same start.
  sim.events = @[]
  result.add(sim)
  for event in events:
    case event.kind
    of evStart:
      sim.events.add(event)
    of evRound:
      ## A round is closed when the NEXT one opens (or at the end): the
      ## gossip of a round is recorded after its four meetings, so the
      ## resolve phase has to stay open until every event of the round is in.
      if sim.phase == phResolve:
        sim.closeRound()
      sim.beginRound()
      let logged = sim.events[^1]
      if event.round != logged.round or event.pairsA != logged.pairsA or
          event.pairsB != logged.pairsB or
          event.pairsGame != logged.pairsGame or
          event.pairsFirst != logged.pairsFirst:
        raise newException(LedgerError,
          "round " & $event.round & " does not match the seeded schedule")
    of evMeeting:
      let meeting = sim.plan.pairs[event.pair]
      if event.seat != meeting.a or event.other != meeting.b or
          event.game != meeting.game:
        raise newException(LedgerError,
          "meeting " & $event.pair & " of round " & $event.round &
          " does not match the seeded schedule")
      sim.setMemo(meeting.a, event.memoA)
      sim.setMemo(meeting.b, event.memoB)
      sim.applyMeeting(event.pair, event.moveA, event.moveB,
        event.scriptedA, event.scriptedB)
    of evGossip:
      sim.applyGossip(event.seat, event.other, event.text)
    of evEnd:
      if not sim.done:
        if sim.phase == phResolve:
          sim.closeRound()
        if not sim.done:
          ## A deadline stop is not derivable from the meetings alone.
          sim.settle(event.text)
    result.add(sim)

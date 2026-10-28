## Claude-backed decision making for Ledger. Each seat's policy is just a
## prompt: the game server composes the seat's view (its own record, this
## round's meeting with its full numeric rules, the partner's public history,
## the table, the gossip board, its private memo) plus that seat's prompt and
## asks Claude what it does.
##
## All eight seats decide simultaneously by rule — trust and ultimatum use the
## experimental-economics STRATEGY METHOD, so the second mover commits a
## contingent rule before seeing the first mover's move — which means the
## eight requests go out as ONE parallel batch (curly.makeRequests) per round.
## Invalid replies are retried as a smaller batch with a corrective hint, and
## anything still failing falls back to the `mirror` scripted baseline.
##
## Credentials, in order of preference:
##   COWORLD_LLM_ENDPOINT            - hosted sidecar
##   Bedrock bearer token            - local play
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials every decision falls back to the always-legal scripted
## baseline immediately (no retries, no network waits) so offline
## certification still completes - this fallback is load-bearing. The same
## scripted bots are also fieldable policies: a player that registers as
## scripted plays one deliberately, LLM or not.

import
  std/[json, math, os, random, strutils, times, unicode],
  bitworld/runtime,
  curly,
  sim, prompts, training_capture
export prompts

const
  TrainingOperatorPrompt* = "Build a strong reputation while maximizing your median per-meeting payoff."
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  ScriptKind* = enum
    skNone = "none"
    skMirror = "mirror"
    skShark = "shark"

  Decision* = object
    move*: int          ## the raw move, already clamped into its legal range
    note*: string       ## "" when the reply carried none
    memo*: string       ## "" when the reply carried none
    scripted*: bool     ## decided by a scripted baseline, not by the model

  LlmTransport = enum
    ltNone, ltSidecar, ltBedrock, ltAnthropic

  LlmClient* = ref object
    selection*: PromptSelection
    curl: Curly
    transport: LlmTransport
    apiKey: string              ## anthropic transport
    sidecarEndpoint: string
    bedrockEndpoint: string     ## local Bedrock transport
    bedrockModels: seq[string]  ## candidates, tried in order on denial
    bedrockModel: int           ## index into bedrockModels
    bedrockToken: string
    model: string
    maxOutputTokens: int
    timeoutSeconds: int
    disabled*: bool   ## true once credentials are known-unavailable
    throttled*: bool  ## true once a 429 has been seen; the server slows down

proc parseScriptKind*(text: string): ScriptKind =
  ## PLAYER_SCRIPTED values: "shark" plays the greedy foil, "" plays no
  ## scripted baseline at all, and ANY other non-empty value means `mirror`
  ## — a seat that registers scripted without naming a baseline gets the
  ## reciprocal one rather than an error.
  let value = text.strip().toLowerAscii()
  if value.len == 0: skNone
  elif value == "shark": skShark
  else: skMirror

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "ledger llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order. BEDROCK_MODEL pins
  ## a single id; without it, fall through this list — model access is a
  ## per-account Marketplace subscription, so an id that works in one account
  ## 403s in another.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  ## Haiku leads: hosted Bedrock capacity is shared account-wide and the
  ## sonnet profiles run out of daily tokens first.
  ## `us.anthropic.claude-sonnet-4-6` is deliberately ABSENT: it times out on
  ## every sidecar call, so one throttle on haiku would cascade into a whole
  ## episode of scripted fallbacks (raid round 2, 2026-08-23).
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "ledger llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig, selection: PromptSelection): LlmClient =
  result = LlmClient(selection: selection,
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds
  )
  let sidecarEndpoint = getEnv("COWORLD_LLM_ENDPOINT").strip()
  if sidecarEndpoint.len > 0:
    result.transport = ltSidecar
    result.sidecarEndpoint = sidecarEndpoint.strip(chars = {'/'}, leading = false)
    result.model = getEnv("COWORLD_LLM_MODEL", "anthropic/claude-haiku-4.5")
    result.curl = newCurly()
    return
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION",
      getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "ledger llm: bedrock transport, url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "ledger llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "ledger llm: no LLM credentials; using scripted fallback"

# ---- Scripted baselines -----------------------------------------------------

const
  MirrorSend = 4
  MirrorSendWary = 1
  MirrorReturn = 50
  MirrorReturnWary = 25
  MirrorOffer = 5
  MirrorFloor = 4
  MirrorForgiveChance = 0.20
  SharkOffer = 1
  SharkFloor = 1

proc baselineRng(sim: Sim, seat: int): Rand =
  ## The baselines are pure functions of the sim's public state plus the
  ## seeded RNG, so a scripted episode is deterministic for a given seed.
  initRand(int64(sim.config.seed) * 104729 + int64(sim.round) * 131 +
    int64(seat) * 7 + 5)

proc dilemmaMoveOf(record: MeetingRecord, seat: int): int =
  if record.a == seat: record.moveA else: record.moveB

proc lastDilemmaMove(sim: Sim, partner, versus: int): int =
  ## The partner's most recent public DILEMMA move against `versus`, or -1.
  result = -1
  for record in sim.history:
    if record.game != sgDilemma:
      continue
    let hasPartner = record.a == partner or record.b == partner
    if not hasPartner:
      continue
    if versus >= 0 and record.a != versus and record.b != versus:
      continue
    result = record.dilemmaMoveOf(partner)

proc dilemmaDefections(sim: Sim, seat: int): int =
  for record in sim.history:
    if record.game != sgDilemma:
      continue
    if record.a == seat or record.b == seat:
      if record.dilemmaMoveOf(seat) == MoveDefect:
        inc result

proc hasRecord(sim: Sim, seat: int): bool =
  sim.meetingCount(seat) > 0

proc mirrorMove(sim: Sim, seat, partner: int, game: SubGame,
    first: bool): int =
  if game == sgDilemma:
    ## Tit-for-tat over the PUBLIC record: their last move against this seat
    ## if they have one, else their last against anyone. No record at all
    ## earns the benefit of the doubt.
    var reply = lastDilemmaMove(sim, partner, seat)
    if reply < 0:
      reply = lastDilemmaMove(sim, partner, -1)
    if reply < 0:
      return MoveCooperate
    if reply == MoveDefect and dilemmaDefections(sim, partner) == 1:
      ## Forgive a single lapse some of the time; an unforgiving mirror and
      ## one noisy defection lock into mutual punishment for the episode.
      var rng = baselineRng(sim, seat)
      if rng.rand(1.0) < MirrorForgiveChance:
        return MoveCooperate
    return reply
  if game == sgTrust:
    let trusted = not sim.hasRecord(partner) or sim.halo(partner) >= 0.5
    if first:
      return (if trusted: MirrorSend else: MirrorSendWary)
    return (if trusted: MirrorReturn else: MirrorReturnWary)
  if first: MirrorOffer else: MirrorFloor

proc sharkMove(game: SubGame, first: bool): int =
  case game
  of sgDilemma: MoveDefect
  of sgTrust: 0
  of sgUltimatum: (if first: SharkOffer else: SharkFloor)

proc scriptedAction*(sim: Sim, seat: int, kind: ScriptKind): Decision =
  ## The single scripted entry point. Always legal for every (subgame, role)
  ## combination; never writes a note or a memo.
  let pair = sim.pairIndexOf(sim.round, seat)
  if pair < 0:
    raise newException(LedgerError,
      "seat " & $seat & " has no meeting this round")
  let meeting = sim.plan.pairs[pair]
  let first = meeting.a == seat
  let partner = if first: meeting.b else: meeting.a
  let raw =
    if kind == skShark: sharkMove(meeting.game, first)
    else: mirrorMove(sim, seat, partner, meeting.game, first)
  result.move = clampMove(meeting.game, first, raw)
  result.scripted = true

# ---- Prompt building --------------------------------------------------------

proc coins(value: float): string =
  formatFloat(value, ffDecimal, 1)

proc seatName(sim: Sim, seat: int): string =
  if seat < 0 or seat >= sim.names.len: "(nobody)" else: sim.names[seat]

proc tallyLine(sim: Sim, seat: int): string =
  sim.seatName(seat) & " — median " & coins(sim.median(seat)) & ", " &
    $sim.meetingCount(seat) & " meetings, kind " & $sim.kind[seat] &
    " / harsh " & $sim.harsh[seat]

proc meetingLine(sim: Sim, record: MeetingRecord, viewer: int): string =
  ## `R3 vs Bolt — TRUST as INVESTOR: sent 5 (Gizmo +7, Bolt +2)`
  let isA = record.a == viewer
  let other = if isA: record.b else: record.a
  let move = if isA: record.moveA else: record.moveB
  let payMine = if isA: record.payA else: record.payB
  let payTheirs = if isA: record.payB else: record.payA
  "R" & $(record.round + 1) & " vs " & sim.seatName(other) & " — " &
    subGameName(record.game) & " as " & roleName(record.game, isA) & ": " &
    moveText(record.game, isA, move) & " (" & sim.seatName(viewer) & " +" &
    $payMine & ", " & sim.seatName(other) & " +" & $payTheirs & ")"

proc historyBlock(sim: Sim, seat: int): string =
  let records = sim.recentMeetings(seat)
  if records.len == 0:
    return "(none)"
  var lines: seq[string]
  for record in records:
    lines.add(sim.meetingLine(record, seat))
  lines.join("\n")

proc rulesBlock(sim: Sim, partner: int, game: SubGame, first: bool): string =
  ## The drawn subgame's numbers, spelled out for this seat's role.
  let them = sim.seatName(partner)
  case game
  of sgDilemma:
    "You and " & them & " each choose cooperate or defect at the same " &
      "time. If you both cooperate you get " & $PdReward & " coins each. " &
      "If you both defect you get " & $PdPunishment & " each. If you " &
      "defect while " & them & " cooperates you get " & $PdTemptation &
      " and " & them & " gets " & $PdSucker & "; if you cooperate while " &
      them & " defects you get " & $PdSucker & " and " & them & " gets " &
      $PdTemptation & "."
  of sgTrust:
    if first:
      "You start with " & $InvestorEndowment & " coins and send some " &
        "number s of them (0-" & $InvestorEndowment & ") to " & them &
        ". Whatever is sent DOUBLES on the way: " & them & " receives 2s. " &
        them & " starts with " & $TrusteeEndowment & " coins and has " &
        "already committed a return percentage p (0-100): they will return " &
        "round(2s * p / 100) coins. You end with " & $InvestorEndowment &
        " - s + returned; " & them & " ends with " & $TrusteeEndowment &
        " + 2s - returned."
    else:
      them & " starts with " & $InvestorEndowment & " coins and sends you " &
        "some number s of them (0-" & $InvestorEndowment & "). Whatever is " &
        "sent DOUBLES on the way: you receive 2s. You start with " &
        $TrusteeEndowment & " coins. You commit now to a return percentage " &
        "p (0-100): you will return round(2s * p / 100) coins. " & them &
        " ends with " & $InvestorEndowment & " - s + returned; you end " &
        "with " & $TrusteeEndowment & " + 2s - returned."
  of sgUltimatum:
    if first:
      "There are " & $Pie & " coins on the table. You offer o of them (0-" &
        $Pie & ") to " & them & ". " & them & " has already committed a " &
        "minimum acceptable offer m (0-" & $Pie & "). If o is at least m " &
        "you keep " & $Pie & " - o and " & them & " gets o; if o is below " &
        "m the deal breaks and you both get 0."
    else:
      "There are " & $Pie & " coins on the table. " & them & " offers you " &
        "o of them (0-" & $Pie & "). You commit now to a minimum " &
        "acceptable offer m (0-" & $Pie & "). If o is at least m you get o " &
        "and " & them & " keeps " & $Pie & " - o; if o is below m the deal " &
        "breaks and you both get 0."

proc legalForm*(game: SubGame, first: bool): string =
  ## The one legal form of `move` for this seat's role, in words.
  case game
  of sgDilemma:
    "\"cooperate\" or \"defect\""
  of sgTrust:
    if first: "a whole number 0 to " & $InvestorEndowment &
      ", the coins you send"
    else: "a whole number 0 to 100, the percentage of what arrives that " &
      "you return"
  of sgUltimatum:
    if first: "a whole number 0 to " & $Pie &
      ", the coins you offer out of " & $Pie
    else: "a whole number 0 to " & $Pie &
      ", the smallest offer you will accept"

proc moveExample(game: SubGame, first: bool): string =
  case game
  of sgDilemma: "\"cooperate\""
  of sgTrust: (if first: "4" else: "50")
  of sgUltimatum: (if first: "6" else: "4")

const
  CanonicalRules = """

Rules:
- Every round you are paired with one other cog for ONE meeting. Pairings are drawn
  from a fixed rotation: over the episode you meet each of the other seven cogs the
  same number of times, at most twice each in a 14-round game.
- A meeting is one of three games, drawn per pairing: DILEMMA, TRUST, or ULTIMATUM.
  The exact numbers for your meeting are in the message below.
- Everyone decides at the same time, so you never see your partner's move for this
  meeting before you make yours. In TRUST and ULTIMATUM the second mover commits a
  RULE in advance (a return percentage, or a minimum acceptable offer) which is then
  applied to whatever the first mover did.
- Every meeting's moves and payoffs become public immediately, attached to both
  aliases forever.
- You may attach a one-line public review of your PREVIOUS round's partner. Reviews
  are signed with your alias and everyone reads them. They change no payoff.
- YOUR SCORE IS THE MEDIAN OF YOUR PER-MEETING PAYOFFS, not the total and not the
  mean. Sort your meeting payoffs: take the middle value, or the mean of the two
  middle values for an even count. Coins are only ever paid by the game, never
  transferred between cogs.

"""
  ReplyRules = """OUTPUT FORMAT: reply with ONLY one JSON object, nothing else - no
analysis, no explanation, no markdown fences, no text before or after the
object. Your reply must begin with the character { and end with }."""

proc systemPrompt*(selection: PromptSelection, sim: Sim, seat: int): string =
  let alias = sim.seatName(seat)
  if selection.selectedVariant == pvCanonical:
    return "You are " & alias & ", one of eight cogs in Ledger. Your " &
      "alias is permanent and public:\neverything you do is on the record " &
      "and every other cog can read it." & CanonicalRules & ReplyRules
  let identity = "You play " & alias & ", one of eight Ledger cogs. This public alias lasts " &
    "the whole episode, and every other cog can read your recorded actions."
  let meetings = "Each round gives you one partner and one meeting. A fixed rotation " &
    "gives equal meeting counts against each of the other seven cogs, at most twice " &
    "each in a fourteen-round game. Each pairing draws DILEMMA, TRUST, or ULTIMATUM; " &
    "your meeting's exact numbers appear in the user message."
  let timing = "All seats decide simultaneously, without seeing their current partner's " &
    "move. In TRUST the second mover commits a return percentage; in ULTIMATUM the " &
    "second mover commits a minimum acceptable offer. That rule is applied to the " &
    "first mover's choice."
  let record = "After resolution, both players' moves and payoffs immediately become " &
    "public under their permanent aliases. You may add a one-line review of your " &
    "previous round's partner. Everyone sees the review and your signature; it " &
    "changes no payoff."
  let scoring = "Your score is the MEDIAN of your per-meeting payoffs, not their total " &
    "or mean. Sort your payoffs and take the middle value; for an even number of " &
    "meetings, average the two middle values. Only the game pays coins; cogs cannot " &
    "transfer them to one another."
  result = case selection.selectedVariant
    of pvPlain: identity & "\n\n" & meetings & "\n\n" & timing & "\n\n" & record & "\n\n" & scoring
    of pvNumbered: """1. Your public identity is <ALIAS>. Ledger has eight cogs, and each keeps its alias throughout the episode. Other cogs can read the actions recorded against yours.
2. Play one meeting with one partner each round. The fixed rotation gives you equally many meetings with each of the other seven cogs, no more than two apiece in a fourteen-round episode. DILEMMA, TRUST, or ULTIMATUM is drawn for each pairing; consult the user message for the numerical rules.
3. Choose before anyone sees their current partner's choice. All seats act simultaneously. A TRUST second mover supplies a return percentage; an ULTIMATUM second mover supplies the lowest acceptable offer. The submitted rule is then applied to the first mover's action.
4. Resolved moves and payoffs are immediately published under both permanent aliases. You can sign a one-line public review of last round's partner. Everyone can read it, but it cannot alter a payoff.
5. Maximize your median meeting payoff. Order your payoffs and use the middle one, or average the central pair when the count is even. Neither their sum nor their arithmetic mean is your score. Coins come from the game; direct transfers between cogs are unavailable.""".replace("<ALIAS>", alias)
    of pvQuestions: """Who am I? You are <ALIAS>, one of Ledger's eight cogs. That public name stays with you for the episode, and your recorded actions are readable by every other cog.
What determines my result? Your score is the median of your meeting payoffs: sort them, select the central value for an odd count, and average the two central values for an even count. Do not substitute the total or the mean of all payoffs. Payments come only from the game, never from transfers between cogs.
How are meetings assigned? Each round pairs you with one cog for one meeting. Rotation balances the number of meetings with each of your seven possible partners, with at most two per partner in fourteen rounds. Each pair draws one of DILEMMA, TRUST, and ULTIMATUM. The user message provides its precise numbers.
When do I see the other move? Only after choosing: every seat decides simultaneously. In TRUST, the second mover precommits a percentage to return. In ULTIMATUM, that mover precommits a minimum offer to accept. Resolution applies this rule to the first mover's choice.
What becomes public? Once a meeting resolves, both moves and payoffs are immediately attached to the participants' permanent aliases for everyone to read. A one-line review of your previous round's partner is optional, public, signed by you, and has no effect on payoffs.""".replace("<ALIAS>", alias)
    of pvReordered: """PAYOFF
Use the median of your per-meeting payoffs as your objective. With the payoffs sorted, an odd-sized list contributes its middle entry; an even-sized list contributes the average of its two middle entries. Scoring uses neither the list's total nor its overall mean. Only the game can pay coins; players cannot pass coins to each other.
PUBLIC HISTORY
Each resolved meeting immediately exposes both participants' actions and earnings under their permanent aliases. You may publish a single-line review about the partner you had in the preceding round. It carries your signature, is visible to everyone, and changes no earnings.
CHOICE
No seat sees its partner's current move before submitting its own: submissions are simultaneous. The second mover in TRUST specifies a return percentage, while the second mover in ULTIMATUM specifies a minimum acceptable offer. This advance instruction is evaluated against the first mover's submitted move.
SCHEDULE
One round means one meeting with one partner. A fixed rotation distributes your meetings equally across the other seven cogs, with each encountered at most twice in a fourteen-round game. Each pairing is assigned a draw of DILEMMA, TRUST, or ULTIMATUM; the user message states the exact numerical rules.
IDENTITY
You are <ALIAS>. There are eight cogs in Ledger. Your alias is public and persists for the entire episode; all other cogs can inspect the actions in your record.""".replace("<ALIAS>", alias)
    of pvHeldoutBriefing: """Take the seat named <ALIAS> at this eight-cog Ledger table. Your name is public and will not change during the episode. The other seven cogs can inspect your recorded actions.

Prepare a choice for one partner in each round. Pairings follow a fixed rotation, so each possible partner meets you equally often, up to twice in a fourteen-round game. Each pairing draws its meeting from DILEMMA, TRUST, and ULTIMATUM. Read the accompanying user message for the exact values involved.

Your partner's current choice is unavailable when you act; all seats commit at the same time. If you are the second mover in TRUST, commit the percentage you will return. If you are the second mover in ULTIMATUM, commit the smallest offer you will accept. The game applies that commitment to the first mover's choice.

After settlement, both choices and their payoffs immediately enter the public record under the two permanent aliases. You may also submit a signed, one-line review of the partner from your previous round. Everyone receives that review, and it has no power to change a payoff.

Judge success by the median payoff across your meetings. Arrange those payoffs from low to high: an odd count uses the middle entry, and an even count uses the average of the central two. Adding all payoffs or averaging the whole list does not give your score. The game is the sole payer of coins; there is no cog-to-cog transfer mechanism.""".replace("<ALIAS>", alias)
    of pvHeldoutReference: """Seat record: <ALIAS> is your public alias among eight Ledger participants. It remains fixed for this episode. Every participant may read the actions recorded under another participant's alias.
Meeting allocation: each round contains a single meeting for you against one partner. The fixed rotation ensures equal encounter counts for the seven other cogs, bounded by two encounters each over fourteen rounds. A pairing draws DILEMMA, TRUST, or ULTIMATUM. Its numeric parameters are supplied in the user message.
Commitment protocol: every seat submits without first observing its current partner's submission. TRUST requires its second mover to name a return percentage in advance; ULTIMATUM requires its second mover to name an acceptance threshold. That threshold is the minimum acceptable offer. The second mover's rule is applied to the first mover's action.
Disclosure and reviews: resolution immediately makes both actions and payoffs public, attributed to the permanent aliases of both participants. An optional one-line review concerns your preceding round's partner, bears your signature, and is visible to all. It cannot affect payoffs.
Score definition: take the median of the meeting payoffs, not their sum or their full-list average. After sorting, select the middle payoff if there are an odd number; otherwise average the two middle payoffs. Coins are issued exclusively by the game and cannot be transferred from one cog to another.""".replace("<ALIAS>", alias)
    of pvCanonical, pvMixed: raise newException(ValueError, "alternate wording must resolve")
  result.add("\n\n" & ReplyRules)

proc operatorBlock(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" & prompt & "\n\n"

proc userPrompt*(sim: Sim, seat: int, prompt: string): string =
  let pair = sim.pairIndexOf(sim.round, seat)
  if pair < 0:
    raise newException(LedgerError,
      "seat " & $seat & " has no meeting this round")
  let meeting = sim.plan.pairs[pair]
  let first = meeting.a == seat
  let partner = if first: meeting.b else: meeting.a
  let game = meeting.game

  # 1 — who you are and where you stand.
  result.add("Round " & $(sim.round + 1) & " of " & $sim.config.rounds &
    ". You are " & sim.seatName(seat) & ". Your median so far: " &
    coins(sim.median(seat)) & " coins over " & $sim.meetingCount(seat) &
    " meetings (kind " & $sim.kind[seat] & " / harsh " & $sim.harsh[seat] &
    ").\n\n")

  # 2 — this meeting, the role, and the full numeric rules.
  result.add("THIS MEETING: " & sim.seatName(partner) & " — " &
    subGameName(game) & ".\n")
  result.add("YOUR ROLE: " & roleName(game, first) &
    (if game == sgDilemma: " (you both decide at the same time)."
     elif first: " (first mover)." else: " (second mover).") & "\n")
  result.add("THE RULES OF THIS MEETING: " &
    sim.rulesBlock(partner, game, first) & "\n\n")

  # 3 — the partner's public record.
  result.add("PARTNER RECORD — " & sim.seatName(partner) & ": median " &
    coins(sim.median(partner)) & " coins over " &
    $sim.meetingCount(partner) & " meetings, kind " & $sim.kind[partner] &
    " / harsh " & $sim.harsh[partner] & ".\n")
  result.add("THEIR LAST " & $HistoryWindow & " MEETINGS:\n" &
    sim.historyBlock(partner) & "\n\n")

  # 4 — the whole table.
  var table: seq[string]
  for other in 0 ..< Seats:
    table.add(sim.tallyLine(other))
  result.add("THE TABLE:\n" & table.join("\n") & "\n\n")

  # 5 — this round's four tables (the plaza is public).
  var tables: seq[string]
  for index in 0 ..< Meetings:
    let other = sim.plan.pairs[index]
    tables.add(sim.seatName(other.a) & " & " & sim.seatName(other.b) &
      " — " & subGameName(other.game))
  result.add("THIS ROUND'S TABLES: " & tables.join(" · ") & "\n\n")

  # 6 — your own last meetings.
  result.add("YOUR LAST " & $HistoryWindow & " MEETINGS:\n" &
    sim.historyBlock(seat) & "\n\n")

  # 7 — the public gossip board.
  var notes: seq[string]
  let start = max(0, sim.board.len - GossipWindow)
  for index in start ..< sim.board.len:
    let note = sim.board[index]
    notes.add("R" & $(note.round + 1) & " " & sim.seatName(note.author) &
      " on " & sim.seatName(note.subject) & ": \"" & note.text & "\"")
  result.add("THE GOSSIP BOARD (last " & $GossipWindow & " notes):\n" &
    (if notes.len > 0: notes.join("\n") else: "(none)") & "\n\n")

  # 8 — your private memo, verbatim.
  result.add("YOUR PRIVATE MEMO:\n" &
    (if sim.memos[seat].len > 0: sim.memos[seat] else: "(none)") & "\n\n")

  # 9 — who this round's review is about.
  let target = sim.noteTarget(seat)
  if target >= 0:
    result.add("NOTE TARGET: " & sim.seatName(target) & " (your partner " &
      "last round) — your \"note\" is a public review of " &
      sim.seatName(target) & ".\n\n")
  else:
    result.add("NOTE TARGET: (none this round — any \"note\" you send is " &
      "discarded).\n\n")

  # 10 — the operator's guidance, i.e. the policy.
  result.add(operatorBlock(prompt))

  # 11 — the reply line, naming the one legal form of `move` for this role.
  result.add("Reply with ONLY {\"move\": " & moveExample(game, first) &
    ", \"note\": \"…\", \"memo\": \"…\"} — \"move\" is " &
    legalForm(game, first) & "; note at most " & $MaxNoteLen &
    " characters; memo at most " & $MaxMemoLen & " characters.")

# ---- Anthropic / Bedrock transport ------------------------------------------

proc cleanText*(text: string, limit: int): string =
  ## Text over the cap is cut at a RUNE boundary with the cut marked. Every
  ## string that can reach the replay goes through here; a byte-boundary cut
  ## mid-UTF-8 is what makes replay bytes fail a strict JSON parser.
  result = text.strip()
  if result.runeLen <= limit:
    return
  result = result.runeSubStr(0, limit - 1) & "…"

proc singleLine*(text: string): string =
  ## Newlines become spaces and every other control character is dropped, so
  ## a note stays one line on the board and in the feed.
  for rune in text.runes:
    let value = int32(rune)
    if value == 10 or value == 13 or value == 9:
      result.add(' ')
    elif value < 32 or value == 127:
      discard
    else:
      result.add($rune)

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating fences
  ## and prose before or after the object.
  let start = text.find('{')
  let stop = text.rfind('}')
  if start < 0 or stop <= start:
    ## Quote the head of the reply so a hosted log shows WHAT the model sent
    ## instead of JSON (prose, a refusal, a cut-off analysis...).
    raise newException(LedgerError, "no JSON object in response: " &
      cleanText(text, 160).replace("\n", " "))
  parseJson(text[start .. stop])

proc requestFor(client: LlmClient, system, user: string, slot: int):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  if client.transport == ltSidecar and slot >= 0:
    headers["X-Coworld-Player-Slot"] = $slot
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  elif client.transport == ltSidecar:
    body["model"] = %client.model
    headers["anthropic-version"] = AnthropicVersion
    result.url = client.sidecarEndpoint & "/v1/messages"
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf(client: LlmClient, response: Response, error, url: string):
    string =
  ## The text of one batched reply, or a LedgerError describing why there is
  ## none. Auth failures disable the client; model-access and throttle
  ## failures rotate the Bedrock model for the next batch.
  if error.len > 0:
    raise newException(LedgerError, "llm transport: " & cleanText(error, 300))
  if response.code == 401 or response.code == 403:
    let detail = cleanText(response.body, 400)
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(LedgerError,
        "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(LedgerError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    client.throttled = true
    discard client.tryNextBedrockModel("throttled")
    raise newException(LedgerError,
      "llm throttled (429): " & cleanText(response.body, 300))
  if response.code < 200 or response.code >= 300:
    raise newException(LedgerError, "anthropic error " & $response.code &
      ": " & cleanText(response.body, 300))
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(LedgerError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(LedgerError, "reply cut off at max_tokens before " &
      "any JSON: " & cleanText(result, 160).replace("\n", " "))

# ---- Reply parsing ----------------------------------------------------------

proc parseNumericMove(text: string): int =
  ## Numeric strings, tolerating a trailing percent sign or a coins suffix.
  var body = text.strip()
  for suffix in ["%", "coins", "coin"]:
    if body.toLowerAscii().endsWith(suffix):
      body = body[0 ..< body.len - suffix.len].strip()
  if body.len == 0:
    raise newException(LedgerError, "move is not a number: " & text)
  var value: float
  try:
    value = parseFloat(body)
  except ValueError:
    raise newException(LedgerError, "move is not a number: " & text)
  int(floor(value + 0.5))

proc parseMoveValue*(game: SubGame, first: bool, node: JsonNode): int =
  ## One always-present `move` field for all five role cases. Words are only
  ## legal in the dilemma; every other role wants a number. Anything outside
  ## the legal range is CLAMPED by the caller, not rejected.
  if node.isNil:
    raise newException(LedgerError, "no move in response")
  if node.kind == JInt:
    return node.getInt()
  if node.kind == JFloat:
    return int(floor(node.getFloat() + 0.5))
  if node.kind == JBool:
    if game != sgDilemma:
      raise newException(LedgerError, "move must be a number: " & $node)
    return (if node.getBool(): MoveCooperate else: MoveDefect)
  if node.kind != JString:
    raise newException(LedgerError,
      "move must be a number or a word: " & $node)
  let text = node.getStr().strip()
  if text.len == 0:
    raise newException(LedgerError, "empty move")
  if game == sgDilemma:
    let word = text.toLowerAscii()
    if word == "cooperate" or word == "c" or word == "coop" or
        word == "cooperation":
      return MoveCooperate
    if word == "defect" or word == "d" or word == "defection":
      return MoveDefect
  parseNumericMove(text)

proc parseDecision*(game: SubGame, first: bool, payload: JsonNode): Decision =
  ## Tolerant by design: parse what the model meant, clamp what it
  ## over-reached on, and only reject a reply with no usable move at all.
  result.note = cleanText(singleLine(payload{"note"}.getStr()), MaxNoteLen)
  result.memo = cleanText(payload{"memo"}.getStr(), MaxMemoLen)
  let raw = parseMoveValue(game, first, payload{"move"})
  result.move = clampMove(game, first, raw)
  if result.move != raw:
    echo "ledger llm: move ", raw, " out of range for ",
      subGameName(game), " ", roleName(game, first), "; clamped to ",
      result.move

# ---- The batched decision path ----------------------------------------------

proc seatForBatchPosition*(seats, open: seq[int], position: int): int =
  ## The seat that asked for the reply at batch POSITION `position`.
  ## `curly.makeRequests` aligns its results with the order the requests were
  ## QUEUED, never with the order they came back in, so a reply is matched by
  ## its position in the batch and by nothing else. Mis-indexing here is the
  ## failure mode a batched rewrite invites — seat 3's answer landing on seat
  ## 6 — and it is silent, so it has its own test.
  seats[open[position]]

proc decideAll*(
  client: LlmClient,
  sim: Sim,
  seats: seq[int],
  prompts: seq[string],
  scripted: seq[ScriptKind],
  capture: RuntimeCapture = nil
): seq[Decision] =
  ## One decision per seat in `seats`, in order, from ONE parallel batch of
  ## HTTP requests. Never raises: any failure falls back to the scripted
  ## baseline so the episode always advances. `prompts` and `scripted` are
  ## indexed by SEAT.
  result = newSeq[Decision](seats.len)
  var open: seq[int]     ## indexes into `seats` still undecided
  for index, seat in seats:
    let kind = scripted[seat]
    if kind != skNone or client.disabled:
      result[index] = scriptedAction(sim, seat,
        (if kind == skNone: skMirror else: kind))
    else:
      open.add(index)
  for attempt in 0 .. 1:
    if open.len == 0 or client.disabled:
      break
    var batch: RequestBatch
    for index in open:
      let seat = seats[index]
      let pair = sim.pairIndexOf(sim.round, seat)
      let meeting = sim.plan.pairs[pair]
      let first = meeting.a == seat
      var user = sim.userPrompt(seat, prompts[seat])
      if attempt > 0:
        user.add("\nYour previous reply was invalid. Respond with ONLY the " &
          "requested JSON object, with \"move\" " &
          legalForm(meeting.game, first) & ".")
      let request = client.requestFor(systemPrompt(client.selection, sim, seat), user, seat)
      batch.post(request.url, request.headers, request.body, $index)
      if capture != nil:
        try: capture.requestedAttempt(sim.round, seat, attempt, request.body)
        except CatchableError as error: capture.captureGap(sim.round, seat, error.msg)
    let batchStarted = if capture != nil: epochTime() else: 0.0
    let responses = client.curl.makeRequests(batch, client.timeoutSeconds)
    let batchElapsedMs = if capture != nil: (epochTime() - batchStarted) * 1000.0 else: 0.0
    var stillOpen: seq[int]
    for position, index in open:
      let seat = seatForBatchPosition(seats, open, position)
      let pair = sim.pairIndexOf(sim.round, seat)
      let meeting = sim.plan.pairs[pair]
      let first = meeting.a == seat
      if capture != nil:
        try:
          capture.receivedAttempt(sim.round, seat, attempt,
            responses[position].response, responses[position].error, batchElapsedMs)
        except CatchableError as error: capture.captureGap(sim.round, seat, error.msg)
      try:
        ## `responses` is indexed by BATCH POSITION, which is the order the
        ## requests were queued in — never the order they came back in.
        let text = client.textOf(responses[position].response,
          responses[position].error, batch[position].url)
        if capture != nil:
          try: capture.decodedText(sim.round, seat, attempt, text)
          except CatchableError as error: capture.captureGap(sim.round, seat, error.msg)
        result[index] = parseDecision(meeting.game, first,
          extractJsonObject(text))
        if capture != nil:
          try:
            capture.parsedAttempt(sim.round, seat, attempt, result[index].move,
              result[index].note, result[index].memo)
          except CatchableError as error: capture.captureGap(sim.round, seat, error.msg)
      except CatchableError as error:
        if capture != nil:
          try: capture.failedAttempt(sim.round, seat, attempt, error.msg)
          except CatchableError as captureError: capture.captureGap(sim.round, seat, captureError.msg)
        echo "ledger llm: seat ", seat, " attempt ", attempt, " failed: ",
          cleanText(error.msg, 300)
        stillOpen.add(index)
    open = stillOpen
  for index in open:
    let seat = seats[index]
    echo "ledger: seat ", seat, " falling back to scripted decision"
    result[index] = scriptedAction(sim, seat, skMirror)

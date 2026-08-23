import std/[json, strutils]

type
  LedgerError* = object of CatchableError

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int
    rounds*: int          ## rounds in the episode (every seat plays every round)
    episodeTimeoutSeconds*: int ## assumed platform kill time when the env is silent
    sampled*: bool        ## true once the budget cap has been applied
    minRoundIntervalMs*: int ## API rate-limit floor between round starts
    playerConnectTimeoutSeconds*: float
    model*: string
    maxOutputTokens*: int
    llmTimeoutSeconds*: int

  SubGame* = enum
    sgDilemma = "pd"
    sgTrust = "trust"
    sgUltimatum = "ultimatum"

  EventKind* = enum
    evStart = "start"
    evRound = "round"
    evMeeting = "meeting"
    evGossip = "gossip"
    evEnd = "end"

  GameEvent* = object
    kind*: EventKind
    round*: int          ## 0-based round; end: rounds played; start: -1
    pair*: int           ## meeting: 0..3; -1 otherwise
    seat*: int           ## meeting: pair member a; gossip: author; -1 otherwise
    other*: int          ## meeting: pair member b; gossip: subject; -1 otherwise
    game*: SubGame       ## meeting: the drawn subgame
    moveA*, moveB*: int  ## meeting: the raw moves as defined per subgame
    payA*, payB*: int    ## meeting: the coins each member ends with
    scriptedA*, scriptedB*: bool ## meeting: decided by a scripted baseline
    memoA*, memoB*: string       ## meeting: each member's memo after this round
    text*: string        ## gossip: the note; end: the reason
    pairsA*: seq[int]    ## round: first-listed seat per pair
    pairsB*: seq[int]    ## round: second-listed seat per pair
    pairsGame*: seq[SubGame] ## round: subgame per pair
    pairsFirst*: seq[int]    ## round: seat id of the first mover per pair

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    rounds: 14,
    episodeTimeoutSeconds: 1200,
    minRoundIntervalMs: 20000,
    playerConnectTimeoutSeconds: 180,
    model: "claude-sonnet-5",
    maxOutputTokens: 900,
    llmTimeoutSeconds: 30
  )

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(LedgerError, "config must be a JSON object")
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player["name"].getStr()))
  if node.hasKey("seed"):
    config.seed = node["seed"].getInt()
  if node.hasKey("rounds"):
    config.rounds = node["rounds"].getInt()
  if node.hasKey("episodeTimeoutSeconds"):
    config.episodeTimeoutSeconds = node["episodeTimeoutSeconds"].getInt()
  if node.hasKey("sampled"):
    config.sampled = node["sampled"].getBool()
  if node.hasKey("minRoundIntervalMs"):
    config.minRoundIntervalMs = node["minRoundIntervalMs"].getInt()
  if node.hasKey("player_connect_timeout_seconds"):
    config.playerConnectTimeoutSeconds =
      node["player_connect_timeout_seconds"].getFloat()
  if node.hasKey("model"):
    config.model = node["model"].getStr()
  if node.hasKey("maxOutputTokens"):
    config.maxOutputTokens = node["maxOutputTokens"].getInt()
  if node.hasKey("llmTimeoutSeconds"):
    config.llmTimeoutSeconds = node["llmTimeoutSeconds"].getInt()

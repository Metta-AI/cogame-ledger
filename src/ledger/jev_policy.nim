## Jev is a Ledger player policy. It receives one seat's observation and
## returns a move; the game owns visibility, legality, scoring, and replay.

import std/[json, os, strutils]
import curly

proc chooseMove*(observation: JsonNode): int =
  let game = observation["game"].getStr()
  let role = observation["role"].getStr()
  let legal = observation["legal"]
  var criteria = newJObject()
  let minimum = legal["moveMin"].getInt()
  let maximum = legal["moveMax"].getInt()
  if maximum - minimum + 1 > 255:
    raise newException(ValueError, "Ledger action range exceeds Jev limit")
  for move in minimum .. maximum:
    let description =
      if game == "DILEMMA":
        (if move == 0: "Cooperate" else: "Defect")
      elif role == "TRUSTEE":
        "Return " & $move & "% of the multiplied investment"
      elif role == "RESPONDER":
        "Accept offers of at least " & $move & " coins"
      elif role == "INVESTOR":
        "Send " & $move & " coins to the trustee"
      else:
        "Offer " & $move & " coins to the responder"
    criteria[$move] = %description

  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let capture = getEnv("METTA_CAPTURE_URL").strip()
  let directKey = getEnv("TYPESAFE_API_KEY").strip()
  var endpoint: string
  var model: string
  var key: string
  if sidecar.len > 0:
    endpoint = sidecar
    model = "typesafe/jev-1.13"
  elif capture.len > 0:
    endpoint = capture
    model = "typesafe/jev-1.13"
    key = getEnv("METTA_CAPTURE_KEY").strip()
  else:
    endpoint = getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
    model = getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
    key = directKey
  if endpoint.len == 0 or (sidecar.len == 0 and key.len == 0):
    raise newException(ValueError, "Jev player has no model transport")

  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  let body = %*{
    "model": model,
    "state": "You are " & observation["name"].getStr() &
      " in Ledger. Your score is the median of your meeting payoffs. " &
      "All moves are simultaneous; in trust and ultimatum the second " &
      "mover commits a rule before seeing the first mover's move. " &
      "Public history, pairings, gossip, numeric game rules, your private " &
      "memo, and your legal move range are in this observation:\n" &
      $observation,
    "questions": {"decision": {
      "type": "choice",
      "instructions": "Choose the move that improves your median payoff across meetings while considering your partner's history and your future reputation.",
      "criteria": criteria
    }}
  }
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body, 30)
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let payload = parseJson(response.body)
  let answer = payload["answers"]["decision"]
  let probabilities = answer["probabilities"]
  if answer["type"].getStr() != "choice" or
      probabilities.len != criteria.len:
    raise newException(ValueError, "Jev returned the wrong choice set")
  var best = -1.0
  var total = 0.0
  var selected = ""
  for choice, probability in probabilities.pairs:
    if not criteria.hasKey(choice):
      raise newException(ValueError, "Jev returned an unknown choice")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(ValueError, "Jev probability outside [0, 1]")
    total += value
    if value > best:
      best = value
      selected = choice
  if abs(total - 1) > probabilities.len.float * 0.005 + 1e-6:
    raise newException(ValueError, "Jev probabilities do not sum to one")
  result = parseInt(selected)
  echo "ledger Jev player: move ", result,
    " model ", payload{"model"}.getStr(),
    " input_tokens ", payload["usage"]{"input_tokens"}.getInt(),
    " output_tokens ", payload["usage"]{"output_tokens"}.getInt()

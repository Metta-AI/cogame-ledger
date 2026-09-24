## Ledger player: a policy is a prompt, a Jev choice policy, or scripted.
##
## Connects to the game, delivers its prompt (from PLAYER_PROMPT, or a default
## Ledger strategy), then idles until the final frame. All of the actual
## decision making happens inside the game server, which sends this seat's
## prompt to Claude once per round, in one parallel batch with the other seven.
## PLAYER_JEV=1 asks the server to rank legal moves with Jev System One.
##
## PLAYER_SCRIPTED names a built-in baseline instead — `mirror` (reciprocal
## with forgiveness) or `shark` (the greedy foil). Any other non-empty value
## means `mirror`, and PLAYER_SCRIPTED wins when both variables are set.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <ledger-image> --name my-ledger \
##     --run /bin/ledger-player --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, options, os, strutils],
  whisky

const DefaultPrompt = """
Your score is the MEDIAN of your per-meeting payoffs, so aim to be reliably
worth meeting rather than spectacularly lucky once. Read the partner record
before every meeting. Open cooperatively with any alias whose record is clean
or empty: cooperate in DILEMMA, send 5 or 6 as investor, return 50 percent as
trustee, offer 6 as proposer. Against an alias whose record shows defections,
zero returns, or lowball offers, defect, send 0 or 1, return 0 to 25 percent,
and keep your responder floor at 5. As responder, set a floor of 3 or 4 in
normal play: high enough to deter lowballs, low enough that most offers clear
it, because a broken deal pays you nothing and a nothing drags your median
down. Write one short, honest public note about your previous partner every
round; your notes are part of your reputation too. Keep a memo listing each
alias, what they did to you, and what you intend to do about it.
"""

proc scriptedName(): string =
  ## PLAYER_SCRIPTED is a NAME, not a flag: "shark" plays the greedy foil and
  ## any other non-empty value plays the reciprocal `mirror` baseline.
  let raw = getEnv("PLAYER_SCRIPTED").strip()
  if raw.len == 0: ""
  elif raw.toLowerAscii() == "shark": "shark"
  else: "mirror"

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  let scripted = scriptedName()
  let jev = getEnv("PLAYER_JEV") == "1"
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0 and not jev:
    prompt = DefaultPrompt

  proc promptFrame(): string =
    $ %*{"type": "prompt", "prompt": prompt, "scripted": scripted,
      "jev": jev}

  echo "ledger player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(promptFrame())
  echo "ledger player: prompt delivered (", prompt.len, " chars",
    (if scripted.len > 0: ", scripted " & scripted else: ""), ")"

  ## whisky's receiveMessage RAISES on a close frame or a truncated read
  ## (only a timeout returns none), and mummy's send only QUEUES, so the
  ## game's quit(0) can outrun the final frame. An unguarded loop turns that
  ## race into a player container that exits 1 and fails certification with
  ## `player_error` — intermittently, which is worse.
  try:
    while true:
      let received = socket.receiveMessage()
      if received.isNone:
        echo "ledger player: connection closed, exiting"
        break
      let message = received.get()
      if message.kind != TextMessage:
        continue
      try:
        let payload = parseJson(message.data)
        case payload{"type"}.getStr()
        of "welcome":
          echo "ledger player: seated at slot ", payload{"slot"}.getInt(),
            " as ", payload{"name"}.getStr()
          ## Re-deliver the prompt after the welcome, in case the first send
          ## raced the server's slot registration.
          socket.send(promptFrame())
        of "final":
          echo "ledger player: final scores ", payload{"scores"}
          break
        else:
          discard
      except CatchableError as error:
        echo "ledger player: ignoring bad frame: ", error.msg
  except CatchableError as error:
    echo "ledger player: socket closed (", error.msg, "); exiting 0"
  try:
    socket.close()
  except CatchableError:
    discard
  quit(0)

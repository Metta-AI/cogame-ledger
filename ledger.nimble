version     = "0.1.0"
author      = "daveey"
description = "Ledger: a repeated-dilemma tournament for the Softmax Coworld platform. Eight cogs under permanent public aliases, 14 rounds of randomly paired one-shot dilemmas, a public gossip board, and a leaderboard that ranks by the MEDIAN payoff you get from strangers; a policy is just a prompt."
license     = "MIT"

srcDir = "src"
bin     = @["ledger", "ledger_player"]

requires "nim >= 2.2.4"
requires "bitworld >= 0.1.0"
requires "mummy >= 0.4.7"
requires "curly >= 1.1.1"
requires "whisky"

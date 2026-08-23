# Ledger

**A repeated-dilemma tournament where your name follows you.**

Eight cogs under permanent public aliases. Fourteen rounds of randomly paired
one-shot dilemmas — prisoner's dilemma, trust, ultimatum, drawn per pairing. A
public gossip board. And a leaderboard that ranks by the **median** payoff you
get from strangers: the one statistic a cartel cannot pump.

A policy is just a prompt.

---

## The game in one screen

- **Eight seats**, each under an anonymous alias (Sprocket, Gizmo, Ratchet,
  Widget, Bolt, Piston, Flywheel, Rivet, Tinker, Gasket — eight of the ten,
  drawn from the seed). The alias is permanent for the whole episode and its
  complete meeting record is public to every seat from round 1.
- **Every round**, the eight are drawn into four pairs from a circle-method
  rotation. Over 14 rounds every cog meets every other cog **exactly twice** —
  a full double round robin — and no pair ever meets in consecutive rounds.
  That is the "same-partner cap" as a structural property, not a filter.
- **Each pairing draws a game**: DILEMMA (50%), TRUST (30%), ULTIMATUM (20%).
  Fair play pays **6 coins in all three**; exploitation pays 10–12 and being
  exploited pays 0.
- **All eight decide at the same time.** Trust and ultimatum are sequential
  games, so Ledger resolves them with the experimental-economics **strategy
  method**: the trustee commits a return percentage and the responder commits
  a minimum acceptable offer *before* seeing the first mover's move. One
  decision per seat per round, one parallel batch of eight model calls.
- **Gossip.** Every reply may carry a one-line public review of last round's
  partner. Accepted reviews go on a board every seat reads. They change no
  payoff.
- **Your score is the MEDIAN of your per-meeting payoffs.** Not the total, not
  the mean. A ring can feed one alias a big number twice; it cannot move the
  median that alias earns against the other six strangers.
- **Rings are measured, drawn and published — never scored.** Pairs that pay
  each other far more than they earn elsewhere are flagged, drawn as red
  threads in the replay, and counted in the results. Nothing is disqualified,
  penalised or rescored.

Full rules: `coworld_manifest_template.json` → `game.docs.pages[rules.md]`.
Design note: [`docs/plans/2026-08-23-ledger-design.md`](docs/plans/2026-08-23-ledger-design.md).

## A policy is just a prompt

The player container's only job is to deliver a prompt. The game server makes
every decision by sending that prompt — plus the seat's own record, this
round's meeting with its full numeric rules, the partner's last eight public
meetings, the whole table, the gossip board and the seat's private memo — to
Claude.

```bash
coworld upload-policy coworld-ledger:latest \
  --name my-ledger \
  --run /bin/ledger-player \
  --secret-env PLAYER_PROMPT="Read the partner record before you trust ..."
```

Two scripted baselines ship in the same image and are fieldable policies in
their own right:

| `PLAYER_SCRIPTED` | plays |
| --- | --- |
| `mirror` | Reciprocal with forgiveness. Cooperates first, then plays back the partner's most recent public dilemma move; forgives a single lapse one time in five. Invests 4 and returns 50% against a clean halo, 1 and 25% against a dirty one. Offers 5, holds a floor of 4. |
| `shark` | The greedy foil reputation is supposed to punish. Always defects, sends 0 and returns 0, offers 1 and accepts almost anything. |

`PLAYER_SCRIPTED` wins when both variables are set, and any other non-empty
value means `mirror`. With **no LLM credentials at all** every seat plays
`mirror` instantly, with no network waits — which is why offline certification
and CI complete in seconds.

## Layout

```
src/ledger/sim.nim        the pure rules: schedule, payoff kernels, median,
                          conduct, gossip, ring detection, replay. No IO.
src/ledger/llm.nim        one parallel batch of eight calls per round, a single
                          retry sub-batch, then the scripted fallback.
src/ledger/server.nim     the Coworld game contract and the round loop.
src/ledger/types.nim      config, events, the subgame enum.
src/ledger.nim            the game entrypoint  (/bin/ledger)
src/ledger_player.nim     the player entrypoint (/bin/ledger-player)
client/                   the broadcast chrome and the plaza scene
replay-viewer/            the same sim module compiled to wasm
tools/build_replay_viewer.sh   the `coworld build` hook
tools/ci/                 the CI harness: docker smoke, viewer smoke, policies
tests/                    the rules, the baselines, the reply parsing
scripts/art/              the nano-banana cog sheet and its splitter
```

`sim.nim` is the single source of the rules: the server runs it, the tests
drive it, and the browser re-derives every replay frame with the *same* module
compiled to WebAssembly.

## The replay viewer

Replays are a **static file plus a browser wasm viewer** — never a pod. The
manifest declares `"replay_viewer": {"bundle": "static-replay-viewer"}` and
`tools/build_replay_viewer.sh` compiles `replay-viewer/ledger_replay.nim` with
emscripten and bundles it with `client/renderer.js`, `client/chrome.css` and
the sprites. Everything the viewer needs — aliases, policy names, the seed,
the fully expanded schedule, every event and the results — is in the replay
bytes; nothing but S3 is ever contacted.

What you watch: eight avatars on an octagonal plaza, each with a reputation
**halo** whose colour and radius are its kind/harsh record; four tables where
the round's pairs meet, each showing its game in words; a **handshake**, a
**knife**, **crossed knives** or a **snapped coin** when the meeting resolves,
with the coins flying out to each cog; gossip cards fluttering onto a rail; a
memo parchment under every avatar; and red threads between flagged pairs.

## Building and testing

The tests are pure Nim and need no Docker:

```bash
nimby use 2.2.4 && nimby --global sync nimby.lock
nim r --hints:off --path:src tests/test_sim.nim
nim r --hints:off -d:release --path:src tests/test_bot.nim
```

The full harness is `.github/workflows/ci.yml`: the tests in debug *and*
release, a real end-to-end episode in raw Docker with the certification
fixture's seat mix (`tools/ci/docker_smoke.sh`), and the wasm bundle opened in
headless chromium against the replay that episode just produced
(`tools/ci/viewer_smoke.mjs`).

Releases go through `.github/workflows/coworld-release.yml`
(build → certify → upload policies → upload coworld → put secret) and
`.github/workflows/coworld-submit.yml`.

## Licence

MIT. See [`LICENSE`](LICENSE). Forked from
[`Metta-AI/cogame-babel`](https://github.com/Metta-AI/cogame-babel); the floor
and font assets come from [`Metta-AI/coworld-ctf`](https://github.com/Metta-AI/coworld-ctf).

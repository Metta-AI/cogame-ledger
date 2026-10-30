# Ledger training

Ledger has a local simulator and hosted text players. Export complete games for
Metta post-training with the same per-seat prompts and reply parser as the
hosted player:

```bash
nimby sync nimby.lock
nim r --path:src tools/export_posttrain.nim /tmp/ledger-standard 10 1 standard
nim r --path:src tools/export_posttrain.nim /tmp/ledger-quickfire 10 1 quickfire
```

The exporter reads each certified `game_config` from
`coworld_manifest_template.json` and runs at least ten seeded games per variant.
The original train/validation JSONL format and manifest are retained. Teacher games
alternate mirror and shark seats. Prompt selection and exact message hashes accompany
each row. Scenario families use `ledger-SEED` across both game variants; every fifth
scenario is validation. Mixed exports cycle wordings separately within each split
so the validation schedule cannot remove a presentation from training.

The exporter removes native API pacing for simulation. Run it from clean committed
source so the manifest's revision identifies the code. Outputs require content review
before training; scripted games do not establish model quality.

The `ledger-rules-v3` bank supports `canonical`, `plain`, `numbered`, `questions`,
and `reordered`. Set `promptVariant` and `promptSeed` in native configuration or
bridge resets. `mixed` requires an explicit nonnegative seed and selects its
training wording modulo five for the episode, independently of simulation randomness.
Complete identity, meeting rotation, simultaneous decisions, public records, and
median scoring explanations vary in wording and order. The response schema stays fixed. Canonical text now states the exact median calculation instead of claiming that
one favorable meeting cannot change it. The source/bridge operator
objective now correctly asks for median per-meeting payoff instead of cumulative payoff.

Append `PROMPT_VARIANT PROMPT_SEED` to the exporter command to select wording.
`heldout-briefing` and `heldout-reference` are evaluation-only; training resets
and source exports reject them. The language bridge uses an additional `--language`
argument and preserves parsed notes and private memos across complete rounds.
Prompt metadata includes hashes of the actual rendered system and user messages.

Compare matched scenario seeds across training and held-out wording before making
performance claims. Scripted checks do not demonstrate resistance to training collapse.

# Numeric reinforcement learning

Compile the persistent bridge and pass its manifest and variant to Metta's
`recipes.external.coworld.train` (native PufferLib) or
`recipes.external.coworld_metta_rl.train` (Metta RL):

```sh
nim c -d:release --path:src -o:/tmp/ledger-train-bridge tools/train_bridge.nim
python tools/test_prompt_games.py /tmp/ledger-train-bridge
# Run the typed GameBridge check from an environment with Metta installed:
python tools/test_train_bridge.py /tmp/ledger-train-bridge
```

Both certified variants expose 187 numeric observation values and 101 fixed
move slots. The simulator's role-specific legal range masks invalid moves.
Observations contain current public meetings, resolved history, payoffs, and
conduct tallies. Decisions are frozen until all eight seats choose. The
numeric policy sends no free-form notes or memos; the hosted prompts and
post-training exporter retain that channel. Even seats use the `mirror`
teacher and odd seats use `shark`. Complete games return native median-payoff
scores.

Held-out bridge wordings require an explicit `evaluation`, `validation`, or `test`
split. Omitted, training, and unrecognized splits reject them.

Exported episode IDs include requested selection, resolved wording, and prompt seed, so matched
wording collections remain distinct. The gameplay seed still groups related scenarios.

Version three independently phrases the numbered, question-led, reordered, and
held-out rules. Canonical/plain text and the action contract remain unchanged.

## Private native model capture

The ordinary native server can write `decision-trajectory-v1` evidence when
`COGAME_SAVE_TRAJECTORY_URI` is set. Set `COWORLD_EPISODE_ID`,
`COWORLD_GAME_VERSION`, and `COWORLD_SOURCE_REVISION` to the corresponding
execution identities; an optional `COWORLD_GAME_IMAGE_DIGEST` identifies the image.
The destination must be separate from results and replay, including signed URLs
that name the same object. Capture initialization faults disable capture with a
visible diagnostic; capture faults never replace native decisions.

Capture freezes the existing per-seat view and prompt selection at dispatch,
retains each actual request and decompressed response body as base64, and records
safe response headers, call IDs, decoder settings, retry history, usage and the
actual native meeting/gossip/memo effects. Headers are an allowlist, not original
header-wire evidence. Latency is batch dispatch to reader join, not individual
provider transfer time. Native batching, retries, pacing and gameplay are
unchanged. With capture disabled, the server skips the private snapshots and
hashes.

Model targets require strict original JSON supplied-field/type/value equality
with the installed command. Canonical integer moves are exact; the native
DILEMMA words `cooperate` and `defect` project to 0 and 1 without rewriting the
original target. Native-tolerated alternate encodings (such as numeric strings,
floats and aliases), normalization, unknown/duplicate fields, non-finite values
and invalid Unicode are excluded from this conservative target subset. Their
exclusion does not mean the game action was illegal. Fenced originals remain
unchanged. Missing note/memo defaults are allowed. An empty memo is a KEEP
command, recorded separately from the resulting persistent memo. A first-round
note has no target and is discarded by the native game; this is an outcome of a
valid command, not a target-quality filter.

Invalid Unicode in native evidence is retained as original JSON bytes in base64
with an explicit gap. The public parser remains unchanged. Such rows have no
selected attempt, no text target and a null executed action in the private
artifact; an actual scripted fallback retains fallback status. This also keeps
invalid native persistent memos from corrupting private JSONL in later rounds.
Request/response/header capture limits are 128 KiB/32 KiB/4 KiB, with a 16 MiB
serialized episode limit. Excess or lost evidence is a gap, never a clipped label.

Split groups hash the actual 28-round root pairing/subgame/first-mover schedule.
Seven- and fourteen-round prefixes stay together, independently of wording or
policy display names. Exact setup metadata separately retains aliases, actual
horizon, numeric rules and clocks. Before using distinct roots as independent
splits, also check their actual shorter prefixes for overlap.

The public local system workflow is `tools/ci/native_capture_system.py` with
`--case ordinary`, `off`, or `adversarial`, actual game/player executables and an
explicit output directory. It runs all 14 rounds and eight native players with
the ordinary 20-second floor against loopback-only sentinel HTTP. Compile
`tools/ci/native_capture_reconstruct.nim` to reconstruct views, prompts,
commands, events and outcomes from the native replay. The bounded partial
Unicode workflow uses `native_capture_component.nim` and
`native_capture_unicode_component.py`; it explicitly does not test full-server
pacing. Run all subprocesses with a provider-credential-free environment.
These synthetic fixtures establish technical behavior, never teacher quality.
Authentic hosted training additionally requires archived, authenticated external
receipt joins for exact image/source, policy, seat, request, response and applied
action, plus independent families and native outcome/teacher-quality review.
The scripted exporters above do not supply that hosted provenance.

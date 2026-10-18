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
It requires clean, committed source and refuses an existing output directory.
Private outputs include canonical trajectories, per-game replays, and a manifest.
The published mirror and shark scripts alternate by seat; this is scripted
simulation evidence, not a production-model evaluation. Replies use the hosted
parser, and replayed events must reproduce the final outcomes and meeting history.

Candidates require independent content review. The shared importer owns training
admission and splits. All wording and game variants share `ledger-SEED` families.
The source exporter removes the native API pacing interval for simulation; it
does not establish deployed timing or sampling parity.

The `ledger-rules-v1` bank supports `canonical`, `plain`, `numbered`, `questions`,
and `reordered`. Set `promptVariant` and `promptSeed` in native configuration or
bridge resets. `mixed` requires an explicit nonnegative seed and selects its
training wording modulo five for the episode, independently of simulation randomness.
Only the alias introduction varies; the rules, private view, and response schema
stay shared. Canonical system text remains unchanged. The source/bridge operator
objective now correctly asks for median per-meeting payoff instead of cumulative payoff.

Append `PROMPT_VARIANT PROMPT_SEED` to the exporter command to select wording.
`heldout-briefing` and `heldout-reference` are evaluation-only; training resets
and source exports reject them. The language bridge uses an additional `--language`
argument and preserves parsed notes and private memos across complete rounds.
Prompt metadata includes hashes of the actual rendered system and user messages.

Set `LEDGER_CAPTURE_DIR` to a private directory for native host evidence.
`host.jsonl` records actual request bodies, replies, retry decisions, prompt hashes,
and simulator events. It excludes provider authorization headers. Empty attempt
lists identify scripted or external decisions without inventing model calls.
Resolved decisions and applied events are separate so simulator fallback remains
visible. These diagnostic traces are private evidence, not automatically admitted
training examples.

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

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

Exported episode IDs include the selected wording and prompt seed, so matched
wording collections remain distinct. The gameplay seed still groups related scenarios.

Version three independently phrases the numbered, question-led, reordered, and
held-out rules. Canonical/plain text and the action contract remain unchanged.

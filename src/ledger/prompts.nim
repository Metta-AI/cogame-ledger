## Game-owned wording selection. Kept outside simulation/replay configuration.
import std/[json, strutils]
import crunchy

type
  PromptVariant* = enum
    pvCanonical = "canonical"
    pvPlain = "plain"
    pvNumbered = "numbered"
    pvQuestions = "questions"
    pvReordered = "reordered"
    pvHeldoutBriefing = "heldout-briefing"
    pvHeldoutReference = "heldout-reference"
    pvMixed = "mixed"
  PromptSelection* = object
    variant*: PromptVariant
    seed*: int

const
  PromptBankVersion* = "ledger-rules-v1"

proc promptSelection*(node: JsonNode): PromptSelection =
  if node.kind != JObject:
    raise newException(ValueError, "prompt configuration must be an object")
  if node.hasKey("promptVariant"):
    if node["promptVariant"].kind != JString:
      raise newException(ValueError, "promptVariant must be a string")
    result.variant = parseEnum[PromptVariant](node["promptVariant"].getStr())
  if node.hasKey("promptSeed"):
    if node["promptSeed"].kind != JInt:
      raise newException(ValueError, "promptSeed must be an integer")
    result.seed = node["promptSeed"].getInt()
  if result.seed < 0:
    raise newException(ValueError, "promptSeed must be nonnegative")
  if result.variant == pvMixed and not node.hasKey("promptSeed"):
    raise newException(ValueError, "mixed wording requires an explicit promptSeed")

proc selectedVariant*(selection: PromptSelection): PromptVariant =
  if selection.variant == pvMixed: PromptVariant(selection.seed mod 5)
  else: selection.variant

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed,
    "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}

proc selectionMetadata*(selection: PromptSelection): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed}

proc introduction*(selection: PromptSelection, alias: string): string =
  result = case selection.selectedVariant
    of pvCanonical: "You are <ALIAS>, one of eight cogs in Ledger. Your alias is permanent and public:\neverything you do is on the record and every other cog can read it."
    of pvPlain: "In Ledger you play <ALIAS>, one of eight cogs. Your public alias stays the same.\nEverything you do is recorded for every other cog to read."
    of pvNumbered: "1. You are <ALIAS>, one of the eight cogs playing Ledger.\n2. Your alias is public and permanent.\n3. Everything you do goes on a record that every other cog can read."
    of pvQuestions: "Who are you? <ALIAS>, one of eight cogs in Ledger.\nDoes your public alias change? No; it is permanent.\nWho can read the record of everything you do? Every other cog."
    of pvReordered: "Every other cog can read the record of everything you do in Ledger.\nYou are <ALIAS>, one of eight cogs, and your public alias is permanent."
    of pvHeldoutBriefing: "Ledger briefing: your identity is <ALIAS>. You are one of eight cogs.\nThat alias remains public and permanent; every other cog can read everything you do on the record."
    of pvHeldoutReference: "Game: Ledger. Players: eight cogs. Your alias: <ALIAS>.\nAlias visibility and duration: public and permanent.\nRecord access: every other cog can read everything you do."
    of pvMixed: raise newException(Defect, "unresolved mixed wording")
  result = result.replace("<ALIAS>", alias)

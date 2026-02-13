## Why

Agents working in repos that consume saas-controller have no way to discover how to configure services, manage secrets, or operate the CLI. The README is stale (references removed runtime/network axes), there's no machine-optimized agent context, and no distribution mechanism. We need a skills.sh-compatible skill that gives consuming agents everything they need, plus an accurate README and focused CLAUDE.md.

## What Changes

- **Create a saas-controller skill** (`skills/saas-controller/`) publishable via skills.sh. SKILL.md contains agent-optimized context with full copy-paste examples, secret profiles documentation, CLI reference, and architecture diagram. `references/` folder holds deeper content (provider reference, tailscale setup, option details) for on-demand reading.
- **Rewrite README.md** to reflect current provider-owned architecture. Remove stale runtime/network axis references. Add full examples (hello-world minimal, zuplo with secretspec), secret profiles concept, complete CLI reference. This becomes the human-readable consumer contract.
- **Shrink CLAUDE.md** to contributor-only content: nix patterns, project goals/objectives, use cases, and building saas-controller itself. Remove content that moves to README or skill.

## Capabilities

### New Capabilities

- `agent-skill` — The skills.sh-compatible skill package for consuming repos. Covers SKILL.md structure, references directory, and distribution via `npx skills add afterthought/saas-controller`.

### Modified Capabilities

(none — no existing specs)

## Impact

- **README.md**: Full rewrite. Any tooling or docs linking to specific README sections may break.
- **CLAUDE.md**: Significant reduction. Contributors relying on CLAUDE.md for consumer-facing info will find it in README/skill instead.
- **New directory**: `skills/saas-controller/` with SKILL.md and references/.
- **No code changes**: This is purely documentation and agent context. No changes to devenv.nix, providers, or scripts.
- **External dependency**: skills.sh CLI (`npx skills add`) for distribution. No build-time dependency.

## Tracking

**Dex Epic**: `2rjjf955`

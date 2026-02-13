## Context

Agents in repos that consume saas-controller have no discovery mechanism for configuration, CLI usage, or secret management. The current README documents a stale 3-axis architecture (Providers x Runtimes x Networks) that was removed in the provider-owned-up refactor. CLAUDE.md mixes consumer and contributor concerns. There is no machine-optimized agent context and no distribution channel.

The skills.sh ecosystem provides a standard way to distribute agent context. Consuming repos install skills via `npx skills add <owner>/<repo>`, which drops files into `.claude/skills/` (or equivalent for other agents). The agent then loads SKILL.md into context when relevant tasks are detected.

## Goals / Non-Goals

**Goals:**
- An agent in a consuming repo can correctly configure a new saas-controller service without reading source code
- An agent can understand and use secret profiles to set up secretspec per-service
- An agent can operate the CLI (sc up, sc deploy, sc check-secrets) correctly
- The skill is installable via `npx skills add afterthought/saas-controller`
- README.md is accurate and human-readable
- CLAUDE.md is focused on contributor workflow

**Non-Goals:**
- Auto-generating option reference from devenv.nix (too fragile to maintain)
- Documenting deploy hooks (preHooks/postHooks) — these may change
- Documenting release channels in detail — not needed for typical consumer
- Creating skills for other agents beyond Claude Code (skills.sh handles cross-agent compat)
- Documenting the docker-compose provider in detail — it's new and may change

## Decisions

### 1. Skill lives in the saas-controller repo

The skill directory (`skills/saas-controller/`) lives in the same repo as the code. This keeps the skill versioned with the module. Consumers install via `npx skills add afterthought/saas-controller`.

**Alternatives considered:**
- Separate skill repo: Rejected because it would drift from the code. Two repos to maintain for one module.

### 2. SKILL.md is the primary artifact, references/ for overflow

SKILL.md contains everything an agent needs for the 80% case: architecture overview, two full examples, secret profiles, CLI reference. Target ~300-400 lines. `references/` directory holds deeper content read on demand.

**Alternatives considered:**
- Everything in SKILL.md: Rejected because skills.sh recommends keeping SKILL.md under 500 lines. Secret profiles + provider reference + tailscale setup would push well past that.
- Minimal SKILL.md pointing to README: Rejected because the whole point is agent-optimized context. README is for humans.

### 3. README.md as human-readable consumer contract

README.md covers the same ground as the skill but optimized for human readers (more prose, less density). It becomes the canonical consumer documentation. SKILL.md can reference it for cases where agents need to show users a link.

**Alternatives considered:**
- README = SKILL.md (same file): Rejected because human and agent reading patterns differ. Agents need dense, copy-paste-ready blocks. Humans need narrative flow.

### 4. Full examples over option reference tables

Examples are the primary teaching mechanism — two complete, copy-paste-ready devenv.nix configurations. No generated option tables.

**Alternatives considered:**
- Auto-generated option reference: Rejected per user direction. Hard to maintain, and agents learn better from examples than type signatures.

### 5. Three references/ files

- `references/provider-reference.md` — What each builtin provider needs (providerConfig, secretProfiles, sc up support)
- `references/tailscale-setup.md` — One-time ACL tag, OAuth client, credentials setup
- `references/secretspec-deep-dive.md` — Full secretspec option tree, advanced patterns (per-env secrets, saToken, tags, check-secrets filtering)

### 6. CLAUDE.md shrinks to contributor focus

CLAUDE.md retains: nix idioms and patterns, project goals/objectives, architecture rationale for contributors, use cases, dex/openspec workflow. Consumer-facing content (CLI reference, examples, tailscale setup, secret profiles) moves to README and skill.

## Risks / Trade-offs

- [Skill and README content overlap] → Acceptable. They serve different audiences (agents vs humans). Keep SKILL.md as the source of truth for examples; README can reference the same patterns with more prose.
- [SKILL.md may exceed 500 lines] → Mitigated by putting provider details, tailscale setup, and deep secretspec content in references/. Core SKILL.md stays focused on examples + key concepts.
- [skills.sh is young, spec may change] → Low risk. The skill format (SKILL.md + optional directories) is simple and agent-agnostic. Minimal lock-in.
- [README accuracy depends on keeping it in sync with code] → Same risk as any docs. Mitigated by keeping README focused on stable interfaces (service config schema, CLI commands) not implementation details.

## Open Questions

- Should the skill include a `scripts/` directory with helper scripts (e.g., a `check-setup.sh` that validates tailscale credentials)? Deferred — can add later.

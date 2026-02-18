# SaaS Controller Module

Multi-cloud service orchestration for devenv. Provider-owned lifecycle with docker-compose and Tailscale HTTPS.

> **Consumer docs**: See [README.md](README.md) for configuration, CLI usage, and examples.
> **Agent skill**: Install via `npx skills add afterthought/saas-controller` for agent context in consuming repos.

## Goals and Use Cases

SaaS Controller solves a specific problem: managing the lifecycle of cloud SaaS services (API gateways, auth providers, monitoring) across local dev and cloud environments from a single declarative config.

**Core use cases:**
- Local dev with real HTTPS URLs on a Tailscale tailnet (`sc up`)
- Declarative deployment with pre/post hooks and dependency ordering (`sc deploy`)
- Secret validation across services and environments (`sc check-secrets`)
- One-time project provisioning on cloud platforms (`provision-projects`)

**Design principles:**
- Provider-owned lifecycle: providers control their own `up()` and `deploy()`, no generic runtime/network abstraction
- Composition over configuration: secret profiles compose per-service per-environment
- Nix-native: all configuration is devenv module options, all scripts are nix-generated bash
- Ephemeral by default: `sc up` creates ephemeral Tailscale nodes that auto-remove on exit

## Architecture (Internals)

```
devenv.nix                    # Module options (saas-controller.*) + sc CLI + task wiring
    │
    ├── lib/helpers.nix       # Task builders: mkDeployTask, mkSecretExportTask
    │                         # Generates devenv tasks for deploy pipeline
    │
    ├── lib/dependencies.nix  # Dependency graph validation (circular detection)
    │                         # Validates service→service and service→secret-export deps
    │
    ├── lib/docker-compose.nix # Shared compose helpers: mkComposeFile, mkServeConfig
    │                          # Used by providers to generate compose stacks
    │
    └── providers/*.nix       # Each provider exports: { up?, provisionProject, deploy, provision?, secretProfiles? }
```

### How devenv.nix is organized

The file has two main sections:

1. **`options.saas-controller`**: Module option declarations
   - `secretProfiles`: Controller-level secret profile definitions
   - `externalProviders`: Registration point for custom providers
   - `services`: Service catalog (the main config surface)
   - `secret-exports`: Standalone secret export operations

2. **`config`**: Implementation
   - Provider merging (builtin + external)
   - Secret profile composition (provider auto-export)
   - `sc` CLI script (the main entrypoint, includes secret reconciliation commands)
   - Devenv task wiring (deploy pipeline)

### Provider interface

Providers are `.nix` files returning an attrset. See `providers/TEMPLATE.nix` for the full interface:

- `up(serviceName, service)` → bash script for local dev (optional)
- `provisionProject(serviceName, service)` → one-time setup
- `deploy(serviceName, service, environment, envConfig, profile, provider)` → cloud deployment
- `provision(serviceName, provisionConfig, servicePath, environment, serviceConfig)` → hook provider (optional)
- `secretProfiles` → attrset of named secret sets (optional, auto-merged)

### Task system internals

`lib/helpers.nix` generates devenv tasks from service config:

- `saas-pre-deploy:<service>` → runs `deploy.preHooks` in order
- `saas-deploy:<service>` → calls provider's `deploy()`
- `saas-post-deploy:<service>` → runs `deploy.postHooks`, receives `$DEVENV_TASKS_OUTPUTS`
- `saas-secret-export:<name>` → calls provider's secret export

Dependencies between tasks are wired from `service.dependencies` and `secret-export.dependencies`. The dependency validator in `lib/dependencies.nix` checks for cycles at nix evaluation time.

## Nix Patterns

### Provider function signatures

Providers receive `{ pkgs, lib, config }` and return an attrset. Functions take service config as arguments and return bash script strings (not derivations):

```nix
{ pkgs, lib, config }:
{
  deploy = serviceName: service: environment: envConfig: profile: provider: ''
    # bash script here
    cd ${config.git.root}/${service.providerConfig.path}
    ${pkgs.curl}/bin/curl -X POST ...
  '';
}
```

### Inline bash generation

All CLI commands and tasks are generated as bash strings in nix. Use `pkgs.<tool>/bin/<tool>` for tool references. Use `${config.git.root}` for repo root paths. Use `lib.concatStringsSep`, `lib.mapAttrsToList`, `lib.optionalString` for composing script fragments.

### providerConfig is untyped

`service.providerConfig` is `lib.types.attrs` — an untyped attrset. Each provider defines its own expected keys. This is intentional: providers evolve independently.

### Secret profile composition

Three-layer merge in `mkServiceSecretspecToml` (config section):
1. Controller-level profiles from `serviceProfiles`
2. Provider-contributed profiles (auto-included)
3. Per-instance inline `secrets`

First occurrence wins on duplicate secret names.

## Extending

### New Provider

1. Copy `providers/TEMPLATE.nix`
2. Implement `provisionProject`, `deploy`, optionally `up` and `provision`
3. Optionally add `secretProfiles` for auto-export
4. Register: `saas-controller.externalProviders.my-provider = ./my-provider.nix;`

See [EXTENDING.md](EXTENDING.md) for detailed guide.

## Quality Gates

After modifying any `.nix` files, verify the example devenv shells still evaluate:

```bash
(cd examples/test-gateway && devenv test)
(cd examples/hello-world && devenv test)
```

These exercise the full module evaluation including provider imports, secret profile composition, and compose generation.

## Key Files

```
devenv.nix              # Module options and config (imports everything)
lib/helpers.nix         # Task builders + deploy pipeline
lib/sa-swap.nix         # SA token swap snippet (shared by helpers + providers)
lib/dependencies.nix    # Dependency validation (circular detection)
lib/docker-compose.nix  # Shared compose file helpers
providers/*.nix         # Cloud providers
providers/TEMPLATE.nix  # Provider interface template
scripts/*.mjs           # Helper scripts (frontegg registration)
skills/saas-controller/ # Agent skill for consuming repos
```

## Dex Task Tracking with OpenSpec

Use `dex` for task tracking.

**BEFORE ANY WORK**: Run `dex status` to orient yourself on current task state.

### When to Use Dex vs OpenSpec

| Situation | Tool | Action |
|-----------|------|--------|
| New feature/capability | OpenSpec | `/openspec:new` first |
| Approved spec ready for implementation | Both | Import tasks to Dex, then implement |
| Bug fix, small task, tech debt | Dex | `dex create` directly |
| Discovered issue during work | Dex | `dex create --parent <current-id>` |
| Tracking what's ready to work on | Dex | `dex list --ready` |
| Feature complete | OpenSpec | `/openspec:archive` |

### Daily Workflow

1. **Orient**: Run `dex list --ready` to see unblocked work
2. **Pick work**: Select highest priority ready task OR continue in-progress work (`dex list --in-progress`)
3. **Start**: `dex start <id>`
4. **Implement**: Do the work
5. **Discover**: File any new issues found as subtasks: `dex create "Found: <issue>" --parent <current-id>`
6. **Complete**: `dex complete <id> --result "Implemented" --commit <sha>`

### Converting OpenSpec Tasks to Dex

When an OpenSpec change is approved and ready for implementation:

```bash
# Option A: Import directly from a plan/tasks markdown file
dex plan openspec/changes/<change-name>/tasks.md

# Option B: Create parent task and subtasks manually
dex create "<change-name>" -p 1
# Note the parent ID, then for each task in tasks.md:
dex create "<task description>" --parent <parent-id>
```

Use `--blocked-by` to express ordering between subtasks:
```bash
dex create "Add API endpoint" --parent <parent-id>
# => returns id abc123
dex create "Add frontend integration" --parent <parent-id> --blocked-by abc123
```

Keep OpenSpec `tasks.md` and Dex in sync:
- When completing a Dex task, also mark `[x]` in tasks.md
- When all Dex subtasks for a change are completed, run `/openspec:archive`

### Importing OpenSpec Tasks to Dex

When converting OpenSpec tasks to Dex issues, ALWAYS include full context in `--description`. Tasks must be **self-contained** — an agent must understand the task without re-reading OpenSpec files.

**REQUIRED in every task description:**
1. Spec file reference path
2. Relevant requirements (copy key points)
3. Acceptance criteria from the spec
4. Any technical context needed

**BAD — Never do this:**
```bash
dex create "Update stripe-price.entity.ts"
```

**GOOD — Always do this:**
```bash
dex create "Add description and features fields to stripe-price.entity.ts" -p 2 \
  --parent <change-parent-id> \
  --description "## Spec Reference
openspec/changes/billing-improvements/specs/billing/spec.md

## Requirements
- Add 'description: string' field (nullable)
- Add 'features: string[]' field for feature list display
- Sync fields from Stripe Price metadata on webhook

## Acceptance Criteria
- Fields populated from Stripe dashboard metadata
- Features displayed as bullet list on pricing page

## Files to modify
- apps/api/src/billing/entities/stripe-price.entity.ts
- apps/api/src/billing/stripe-webhook.service.ts"
```

**The test:** Could someone implement this task correctly with ONLY the dex description and access to the codebase? If not, add more context.

### Naming Conventions

Since Dex doesn't have labels or types, use naming conventions in the task name:
- Prefix bugs with `Bug:` — e.g., `dex create "Bug: login fails on expired token"`
- Prefix tech debt with `Tech debt:` — e.g., `dex create "Tech debt: remove deprecated auth flow"`
- Include the change name in the parent task — e.g., `dex create "billing-improvements"`
- Use `dex list "auth"` to search tasks by keyword

### Organizing with Hierarchy

Dex uses parent/subtask trees instead of labels for grouping:
```bash
# Create a parent for the OpenSpec change
dex create "billing-improvements" -p 1
# => abc123

# All related tasks become subtasks
dex create "Add price fields" --parent abc123
dex create "Update webhook handler" --parent abc123 --blocked-by <prev-id>

# View the full tree
dex list abc123
```

### Landing the Plane (Session Completion)

**When ending a work session**, complete ALL steps below. Work is NOT complete until `git push` succeeds.

#### 1. File Tasks for Remaining Work
```bash
dex create "TODO: <description>" -p 2
dex create "Bug: <description>" -p 1
```

#### 2. Run Quality Gates (if code changed)
- Tests, linters, builds
- File P1 tasks if builds are broken

#### 3. Update All Tracking
**Dex tasks:**
```bash
# Finished work — link the commit
dex complete <id> --result "Completed" --commit <sha>

# Finished work with no code changes
dex complete <id> --result "Planning complete" --no-commit

# Partially done — add context to description
dex edit <id> --description "Session end: <progress notes and remaining work>"
```

**OpenSpec tasks.md:**
- Mark completed tasks: `- [x] Task description`
- Add notes for partial progress

#### 4. Archive Completed Trees
```bash
dex archive <parent-id>              # Archive a completed task tree
dex archive --older-than 30d         # Bulk archive old completed tasks
```

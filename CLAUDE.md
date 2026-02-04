# SaaS Controller Module

Multi-cloud service orchestration with runtime + network provider abstraction for devenv.

## Architecture

Three independent axes:

- **Providers** (WHAT): Cloud platform adapters (zuplo, frontegg, datadog, secretspec)
- **Runtimes** (HOW): Process lifecycle managers (dev-manager-mcp, docker-compose, launchd)
- **Networks** (WHERE): URL exposure strategies (tailscale, localhost)

The dispatcher in `lib/helpers.nix` resolves the runtime + network for each service, then calls `runtime.mkScript` with network snippets injected.

## Key Files

```
devenv.nix              # Module options and config (imports everything)
lib/helpers.nix         # Task builders + runtime/network dispatcher
lib/dependencies.nix    # Dependency validation (circular detection)
lib/networks.nix        # Network strategies (tailscale, localhost)
runtimes/*.nix          # Process runtimes
providers/*.nix         # Cloud providers
scripts/*.mjs           # Helper scripts (frontegg registration)
```

## How dev-serve Works

1. `devenv.nix` iterates enabled services with `local` environment
2. For each service variant (e.g., api, docs), calls `helpers.mkDevServeScript`
3. `mkDevServeScript` resolves runtime (per-service or default) and network
4. Runtime's `mkScript` receives network snippets as bash strings
5. Generated script: start process -> set $PORT -> networkSetup -> networkPrintUrl -> tail logs -> networkCleanup on exit

## Config Resolution

```
service.runtime (per-service) ?? config.saas-controller.defaultRuntime -> runtimes.${name}
service.network (per-service) ?? config.saas-controller.defaultNetwork -> networks.${name}
```

## Extending

### New Provider

1. Copy `providers/TEMPLATE.nix`
2. Implement `provisionProject`, `deploy`, optionally `provision` (for hooks)
3. Register: `saas-controller.externalProviders.my-provider = ./my-provider.nix;`

### New Runtime

1. Copy `runtimes/TEMPLATE.nix`
2. Implement `mkScript` — must set `$PORT`, call network snippets, stream logs
3. Register: `saas-controller.externalRuntimes.my-runtime = ./my-runtime.nix;`

### New Network

Create a .nix file returning `{ name, setup, cleanup, printUrl }`:
- `setup`: bash snippet, called after `$PORT` is set, must set `$DEVSERVER_URL`
- `cleanup`: bash snippet, called in trap handler
- `printUrl`: bash snippet, echo the URL

Register: `saas-controller.externalNetworks.my-network = ./my-network.nix;`

## Task System

Tasks are input-based (environment passed as JSON at runtime):

```bash
DEVENV_TASK_INPUT='{"environment": "edge"}' devenv tasks run saas-deploy:my-service
```

Task chain: `saas-pre-deploy` -> `saas-deploy` -> `saas-post-deploy`

## Secrets

- **Control plane**: SaaS controller credentials (ZUPLO_API_KEY, FRONTEGG_*) via `environmentProfiles`
- **Data plane**: Service runtime secrets via `run.secretSource`

## Common Operations

```bash
sc up                              # Start all local services
sc deploy my-service -e edge       # Deploy with hooks
provision-projects                 # One-time setup
check-saas-controller-secrets      # Validate credentials
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

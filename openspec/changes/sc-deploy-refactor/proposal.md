## Why

The saas-controller module has accumulated configuration surface that isn't wired to anything (releaseChannels), leaks implementation details of the secret backend (saToken hardcodes 1Password), generates secretspec.toml to disk when it should be purely dynamic, and supports arbitrary environment names when only three are meaningful (local, production, preview). This creates unnecessary complexity for consumers and an explosion of secrets to manage in 1Password.

## What Changes

- **Remove `releaseChannels`** (~190 lines of options): Fully designed with stable/canary/beta/sandbox/autodeploy policies but zero references in CLI, helpers, or providers. Dead code. **BREAKING**
- **Remove `externalSecretProfiles`**: Unused mechanism for external repos to inject secret profiles.
- **Constrain environments to three**: `local`, `production`, `preview`. Remove support for arbitrary environment names like `development`, `edge`, `main`. The `sc deploy` default changes from `development` to `production`. **BREAKING**
- **Remove `datadog` service option**: Defined but set to `null` in all known consumers. Can be re-added when actually needed.
- **Replace `saToken` with `secretspec.auth`**: Generic auth abstraction (`auth.provider` + `auth.credential`) that delegates to secretspec rather than hardcoding 1Password keyring conventions. **BREAKING**
- **Remove on-disk secretspec.toml generation**: Stop writing `.saas-controller/secretspec/<service>/secretspec.toml` to disk. Pass secretspec config directly to the secretspec CLI (via stdin, `--config`, or environment). The saas-controller module is only concerned with generating secretspec files dynamically.
- **Add secret reconciliation tooling**: New `sc setup-env`, `sc diff-secrets`, and `sc reconcile-secrets` commands to help set up new environments and verify secrets across environments.
- **Clean up redundant `run.secretSource` / `run.environments.local.secretSource`**: Consolidate the dual-level secret source config.

## Capabilities

### New Capabilities

- `secret-reconciliation`: Commands for setting up, diffing, and reconciling secrets across environments (`sc setup-env`, `sc diff-secrets`, `sc reconcile-secrets`).
- `secretspec-auth`: Generic auth abstraction for secretspec backend authentication, replacing the 1Password-specific `saToken`.

### Modified Capabilities

_(none — no existing spec files)_

## Impact

- **Breaking for consumers**: Services declaring `development`, `edge`, or other custom environment names must migrate to the three canonical names. Services using `saToken` must migrate to `secretspec.auth`.
- **Module options reduced**: ~250+ lines of unused option declarations removed.
- **Secret management UX**: New tooling makes it feasible to manage secrets for multiple services and environments.
- **Provider impact**: Only `docker-compose.nix` uses `saToken` — migration is localized. No other providers affected.
- **CI/CD**: Any CI pipelines referencing `sc deploy development` must change to `sc deploy production`.

## Tracking

**Dex Epic**: `fxrmy9zp`

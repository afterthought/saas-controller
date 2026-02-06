## Why

SaaS Controller already uses SecretSpec for control plane credentials during deployment and local dev, but there's no unified way to validate that all required secrets are present across all services. The existing `check-saas-controller-secrets` script only validates the controller's own profiles—it doesn't check per-service secretspec projects. Developers discover missing secrets at runtime (during `sc up` or `sc deploy`) instead of catching them early. The mac-nix project solved this with a `secretspec-check-all` pattern that validates all registered projects in one pass. We need the same capability in saas-controller.

## What Changes

- Add a static `secretspec.toml` to the test-gateway example declaring tailscale infrastructure secrets (`TS_CLIENT_SECRET` required, `TS_CLIENT_ID` and `SC_TAILNET` optional via `required = false`)
- Add a per-service `secretspec` option to the service submodule so services can register their secretspec project for validation
- Add a unified `sc check-secrets` command that validates all secretspec projects (controller profiles + per-service profiles) with support for `--tag` and `--service` filtering
- Add `check-secrets` as a subcommand to the `sc` CLI
- Deprecate the three existing check scripts (`check-saas-controller-secrets`, `check-dev-saas-controller`, `check-prod-saas-controller`) in favor of `sc check-secrets`

## Capabilities

### New Capabilities
- `secretspec-check-all`: Unified secretspec validation across controller and all registered services, with tag-based filtering

### Modified Capabilities
<!-- No existing specs to modify -->

## Impact

- `devenv.nix`: New service submodule option (`secretspec`), new helper functions, new `sc-check-secrets` script, new `sc` subcommand case, deprecation notices on old scripts
- `examples/test-gateway/`: New `secretspec.toml` file and updated service config in devenv.nix
- Existing scripts (`check-saas-controller-secrets`, etc.): Still work but print deprecation notice
- No breaking changes to existing service definitions (the `secretspec` option defaults to `null`)

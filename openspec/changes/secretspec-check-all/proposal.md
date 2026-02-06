## Why

SaaS Controller currently conflates two secret concerns: control plane credentials for CI/deployment (e.g., ZUPLO_API_KEY) and service-level runtime secrets (e.g., tailscale credentials for `sc up`, app API keys). The control plane credentials are already handled externally — GitHub Actions loads them from 1Password and wraps `sc deploy` with `secretspec run`. But saas-controller still bakes in `secretspecContext`, `profileProviders`, `environmentProfiles`, and a dynamic `.saas-controller/secretspec.toml` generator for this concern. Meanwhile, there's no unified way to validate service-level secrets across all services. Developers discover missing secrets at runtime instead of catching them early.

We need to:
1. Decouple CI/deployment credential management from saas-controller core (it belongs in the CI wrapper, not the module)
2. Introduce service profiles — named sets of secrets (e.g., "tailscale", "zuplo-backend") defined at the controller level and selectable per-environment per-service
3. Dynamically generate secretspec.toml per service by composing its service profiles for each environment
4. Provide a unified `sc check-secrets` command that validates all services across all their environment profiles

## What Changes

- **Add `saas-controller.secretProfiles`**: Controller-level option defining named secret sets (e.g., `tailscale`, `zuplo-backend`, `zuplo-public`). Providers can register defaults; consumers can extend.
- **Add per-service `secretspec.environments`**: Each service selects which service profiles apply per environment. Tailscale is only needed for `local`; zuplo-backend is needed for `edge`/`production`.
- **Dynamic TOML generation**: For each service, generate a secretspec.toml with one `[profiles.<envName>]` section per environment, containing the union of secrets from that environment's service profiles.
- **Add unified `sc check-secrets`**: Iterates all services, generates their TOMLs, runs `secretspec check` for each environment profile. Supports `--tag` and `--service` filtering.
- **Add `check-secrets` to `sc` CLI**: New subcommand.
- **Remove `secretspecContext`, `profileProviders`, `environmentProfiles`, `defaultProfileProvider`, `defaultSaasControllerProfile`**: These controller-level options and the `generateControllerSecretspecCmd` that generates `.saas-controller/secretspec.toml` are removed. CI/deployment credential management is decoupled from saas-controller — callers wrap `sc deploy` with `secretspec run` externally.
- **Remove `check-saas-controller-secrets`, `check-dev-saas-controller`, `check-prod-saas-controller`**: Replaced entirely by `sc check-secrets`.
- **Remove `withControlPlaneSecrets` wrapper from `lib/helpers.nix`**: Deploy tasks no longer wrap commands with secretspec. The caller (GitHub Actions, local shell) is responsible for providing deployment credentials in the environment.

## Capabilities

### New Capabilities
- `secretspec-check-all`: Service profile composition, dynamic TOML generation, and unified secretspec validation across all services and environments

### Modified Capabilities
<!-- No existing specs to modify -->

## Impact

- `devenv.nix`: **BREAKING** — Remove `secretspecContext`, `profileProviders`, `environmentProfiles`, `defaultProfileProvider`, `defaultSaasControllerProfile` options. Add `secretProfiles` option. Add `secretspec` to service submodule. Add `sc-check-secrets` script and `sc` subcommand. Remove `generateControllerSecretspecCmd`, old check scripts.
- `lib/helpers.nix`: **BREAKING** — Remove `withControlPlaneSecrets` wrapper, `resolveSaasControllerProfile`, `resolveSaasControllerProvider`. Deploy/hook tasks run without secretspec wrapping.
- `examples/test-gateway/devenv.nix`: Updated service config with `secretspec.environments` selecting `tailscale` profile for local.
- Consumers (e.g., willdan-dev): Must wrap `sc deploy` with `secretspec run` in their GitHub Actions workflows (willdan-dev already does this). Must remove references to removed options from their `devenv.nix`.

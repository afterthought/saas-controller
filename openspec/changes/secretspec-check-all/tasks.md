## 1. Remove Control Plane Secret Management

- [x] 1.1 Remove `secretspecContext`, `profileProviders`, `defaultProfileProvider`, `environmentProfiles`, `defaultSaasControllerProfile` options from `devenv.nix` (~lines 39-106)
- [x] 1.2 Remove `generateControllerSecretspecCmd` from `devenv.nix` `let` block (~lines 751-782)
- [x] 1.3 Remove `withControlPlaneSecrets`, `resolveSaasControllerProfile`, `resolveSaasControllerProvider` from `lib/helpers.nix` (~lines 8-33)
- [x] 1.4 Update deploy/hook task builders in `lib/helpers.nix` to remove secretspec wrapping — tasks run commands directly
- [x] 1.5 Remove `check-saas-controller-secrets`, `check-dev-saas-controller`, `check-prod-saas-controller` scripts from `devenv.nix` (~lines 1080-1192)

## 2. Secret Profiles Option

- [x] 2.1 Add `saas-controller.secretProfiles` controller-level option in `devenv.nix` — attrset of profile name to secret definitions (description, required, providers)
- [x] 2.2 Register default `tailscale` secret profile in `devenv.nix` with TS_CLIENT_SECRET (required), TS_CLIENT_ID (required=false), SC_TAILNET (required=false)

## 3. Per-Service SecretSpec Option

- [x] 3.1 Add `secretspec` option to the service submodule in `devenv.nix` with fields: `environments` (attrset of env name to `{ serviceProfiles = [...]; }`), `tags` (list of strings), `checkProvider` (nullable string)
- [x] 3.2 Update test-gateway service config to use `secretspec.environments = { local = { serviceProfiles = [ "tailscale" ]; }; }`

## 4. Dynamic TOML Generation

- [x] 4.1 Add `mkServiceSecretspecToml` helper in `devenv.nix` `let` block — given a service name and its secretspec config, generates TOML content by composing secrets from `secretProfiles` for each environment
- [x] 4.2 Add `generateAllServiceSecretspecs` helper that iterates enabled services with `secretspec != null` and writes each TOML to `.saas-controller/secretspec/<serviceName>/secretspec.toml`

## 5. Unified sc check-secrets Command

- [x] 5.1 Add `sc-check-secrets` script in `devenv.nix` scripts block that: calls `generateAllServiceSecretspecs`, iterates services, runs `secretspec check --profile <env>` (with optional `--provider`) for each environment, counts errors, prints summary
- [x] 5.2 Implement `--tag <tag>` filtering in `sc-check-secrets`
- [x] 5.3 Implement `--service <name>` filtering in `sc-check-secrets`
- [x] 5.4 Add `check-secrets` case to the `sc` command case statement (~line 1382)
- [x] 5.5 Update `sc help` text to include `check-secrets` command

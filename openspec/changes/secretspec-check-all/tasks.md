## 1. Test-Gateway SecretSpec TOML

- [ ] 1.1 Create `examples/test-gateway/secretspec.toml` with TS_CLIENT_SECRET (required), TS_CLIENT_ID (required=false), SC_TAILNET (required=false)

## 2. Service Submodule Option

- [ ] 2.1 Add `secretspec` option to the service submodule in `devenv.nix` (~line 586, after `run` block) with fields: path, tags, profiles, checkProvider
- [ ] 2.2 Update test-gateway service config in `devenv.nix` (~line 787) to include `secretspec = { tags = [ "tailscale" ]; profiles = [ "default" ]; }`

## 3. Check-Secrets Helpers

- [ ] 3.1 Add `secretspecCheckTargets` helper in `devenv.nix` `let` block (~line 750) to collect enabled services with `secretspec != null`
- [ ] 3.2 Add `mkServiceCheck` helper to generate bash snippet that runs `secretspec check` for each profile of a service, with optional `--provider` flag

## 4. Unified sc-check-secrets Script

- [ ] 4.1 Add `sc-check-secrets` script in `devenv.nix` scripts block (~line 1080) that: generates controller TOML, checks controller profiles, iterates service targets, supports `--tag` and `--service` filtering, counts errors, prints summary
- [ ] 4.2 Add `check-secrets` case to the `sc` command case statement (~line 1382)
- [ ] 4.3 Update `sc help` text to include `check-secrets` command description

## 5. Deprecation

- [ ] 5.1 Add deprecation notice to `check-saas-controller-secrets` script (~line 1082)
- [ ] 5.2 Add deprecation notice to `check-dev-saas-controller` script (~line 1136)
- [ ] 5.3 Add deprecation notice to `check-prod-saas-controller` script (~line 1166)

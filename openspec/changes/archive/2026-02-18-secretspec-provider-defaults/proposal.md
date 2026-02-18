## Why

Every secret definition in saas-controller must carry an explicit `providers = ["saas-controller"]` list, repeated across every profile and every service. This creates unnecessary boilerplate and makes it harder for consuming projects to override the provider alias globally. SecretSpec supports profile-level default providers (`[profiles.<env>.defaults]`) which saas-controller does not use today.

## What Changes

- Add `saas-controller.defaultProviders` option (global default, defaults to `["saas-controller"]`)
- Add `services.<name>.secretspec.defaultProviders` option (per-service override)
- Add `services.<name>.secretspec.environments.<env>.defaultProviders` option (per-environment override)
- Emit `[profiles.<env>.defaults]` section in generated secretspec.toml files
- Strip per-secret `providers` from built-in secret profiles (tailscale, zudoku) since they inherit from defaults
- Resolution chain: environment > service > global (first non-null wins)

## Capabilities

### New Capabilities

- `secretspec-provider-defaults`: Profile-level default provider resolution with three-tier override (global, service, environment)

### Modified Capabilities

<!-- None — no existing spec files -->

## Impact

- **devenv.nix options**: Three new options added to the module interface
- **devenv.nix TOML generation**: `mkServiceSecretspecToml` emits `[profiles.*.defaults]` block
- **providers/zuplo.nix**: `providers` removed from zudoku secret profile definitions
- **devenv.nix built-in profiles**: `providers` removed from tailscale profile defaults
- **Consumers**: No breaking changes — existing per-secret `providers` overrides still work; projects that set no options get the same behavior (just via defaults instead of per-secret)

## Tracking

**Dex Epic**: `9ltgydez`

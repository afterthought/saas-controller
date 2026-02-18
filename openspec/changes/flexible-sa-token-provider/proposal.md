## Why

SA token retrieval is hardcoded to `--provider keyring` across 8+ callsites in devenv.nix and docker-compose.nix. Developers who don't have macOS Keychain set up (or prefer not to use it) cannot use saas-controller without modifying nix source. Since `secretspec` already supports multiple provider backends (keyring, onepassword, dotenv, env), saas-controller should let developers configure which provider to use for SA token storage.

## What Changes

- Replace all hardcoded `--provider keyring` in SA token retrieval with a configurable secretspec provider alias (`sa-tokens` by default)
- Add documentation for developers to configure their SA token provider via `secretspec config provider add`
- Add a setup command or documented one-liner so developers can set the alias without knowing about config file internals
- Update error messages referencing `store-sa-tokens` / keyring to be provider-agnostic
- Document the `env` provider workflow for developers who want to supply SA tokens as environment variables
- Update the saas-controller agent skill with SA token provider configuration guidance

## Capabilities

### New Capabilities

- `sa-token-provider-alias`: Configurable SA token provider using secretspec provider aliases instead of hardcoded keyring

### Modified Capabilities

<!-- No existing specs to modify -->

## Impact

- **devenv.nix**: All ~8 callsites using `secretspec get --provider keyring` change to use the alias
- **providers/docker-compose.nix**: SA token retrieval in compose wrapper scripts uses the alias
- **Error messages**: References to keyring-specific remediation become provider-agnostic
- **Documentation**: README.md and skill docs need SA token provider setup section
- **No breaking change**: Default alias `sa-tokens` will be set to `keyring://` during setup, preserving current behavior for existing users

## Tracking

**Dex Epic**: `0sr2tawk`

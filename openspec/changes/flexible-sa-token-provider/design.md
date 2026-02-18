## Context

SA token retrieval currently uses `secretspec get --provider keyring --profile default <TOKEN_NAME>` hardcoded across 7 `saSwapSnippet` definitions (6 in devenv.nix, 1 in providers/docker-compose.nix). The `secretspec` CLI already supports multiple provider backends via provider aliases configured in `~/.config/secretspec/config.toml` (or the platform-appropriate path). These aliases map a name to a URI like `keyring://`, `onepassword://vault`, or `dotenv://.env`.

The current setup requires every developer to use macOS Keychain, which creates friction for:
- Developers on Linux (no macOS Keychain)
- CI/CD environments where keyring is unavailable
- Developers who prefer supplying tokens via environment variables

## Goals / Non-Goals

**Goals:**
- Allow developers to choose their SA token storage backend without modifying nix source
- Leverage secretspec's existing provider alias system (no new abstraction needed)
- Provide clear setup commands so developers don't need to know about config file internals
- Keep keyring as the default experience for existing users
- Make error messages adaptive to the configured provider

**Non-Goals:**
- Per-service provider configuration (all SA tokens use the same provider alias)
- New nix module options for provider selection (this is a secretspec config concern, not a nix config concern)
- Changes to how `secretspec run` or service-level secret profiles work (only SA token retrieval changes)
- Supporting providers that secretspec doesn't already support

## Decisions

### 1. Use a secretspec provider alias instead of a nix module option

Replace `--provider keyring` with `--provider sa-tokens` across all callsites. Developers configure what `sa-tokens` resolves to via `secretspec config provider add sa-tokens <uri>`.

**Rationale:** This pushes provider selection into secretspec's existing configuration system rather than adding a nix module option. Benefits:
- No nix rebuild needed to change providers
- Works across all projects that use saas-controller (developer-level config, not project-level)
- secretspec already has the `config provider add/remove/list` CLI for managing aliases
- No new abstraction layer to maintain

**Alternatives considered:**
- **Nix module option `saTokenProvider`**: Rejected because it ties provider choice to the nix flake. Different developers on the same project would need different nix configs, which conflicts with declarative config being checked into git.
- **Environment variable override (`SAAS_SA_TOKEN_PROVIDER`)**: Rejected because it adds a one-off escape hatch when secretspec already has a proper config system for this.

### 2. Add `sa-tokens` alias during `store-sa-tokens` setup flow

The existing `store-sa-tokens` command (or the setup documentation) will ensure the `sa-tokens` provider alias is configured. For new setups, this means:

```bash
# Default setup (keyring)
secretspec config provider add sa-tokens "keyring://"

# Alternative: environment variables
secretspec config provider add sa-tokens "env://"
```

**Rationale:** Developers already run a setup step for SA tokens. Adding the alias creation to that flow means no extra manual step.

### 3. Extract saSwapSnippet to a shared helper function

Currently, the SA token swap bash snippet is duplicated 7 times. Extract to a nix function in `lib/helpers.nix`:

```nix
mkSASwapSnippet = { pkgs, saSecretName, saTokensDir, serviceName }: ''
  SA_TOKEN="$(cd "${saTokensDir}" && ${pkgs.secretspec}/bin/secretspec get --provider sa-tokens --profile default ${saSecretName})"
  if [ -z "$SA_TOKEN" ]; then
    echo "Error: Failed to retrieve ${saSecretName} for ${serviceName}." >&2
    echo "  Check your SA token provider: secretspec config provider list" >&2
    echo "  To set up: secretspec config provider add sa-tokens 'keyring://'" >&2
    exit 1
  fi
  export OP_SERVICE_ACCOUNT_TOKEN="$SA_TOKEN"
'';
```

**Rationale:** With 7 duplications, the alias name and error messages need to change in all of them. Extracting to a helper makes this a single point of change and prevents future drift.

**Alternatives considered:**
- **Inline replacement only**: Rejected because the 7-way duplication is a maintenance hazard. If the error messages or retrieval logic change again, all 7 need updating.

### 4. Provider-agnostic error messages

Current error messages say "Run 'store-sa-tokens' to populate SA tokens in the keyring." Replace with messages that reference the configured provider alias:

```
Error: Failed to retrieve OP_SA_CLIENT_WILLDAN for my-service.
  Check your SA token provider: secretspec config provider list
  To set up: secretspec config provider add sa-tokens 'keyring://'
```

**Rationale:** Telling someone to populate the keyring when they're using env variables is confusing.

### 5. Document env provider workflow

Add a section to README.md and the agent skill documenting how to use environment variables instead of keyring:

```bash
# One-time setup
secretspec config provider add sa-tokens "env://"

# Before running sc up
export OP_SA_CLIENT_WILLDAN="your-sa-token-here"
export OP_SA_CLIENT_INTEGRAL="another-sa-token"

# Now sc up will read tokens from env instead of keyring
sc up
```

**Rationale:** This is the primary motivating use case. The documentation should make it obvious and easy.

## Risks / Trade-offs

- **Missing alias at runtime**: If a developer hasn't configured the `sa-tokens` alias, `secretspec get --provider sa-tokens` will fail. Mitigation: clear error message explaining how to set it up, and setup documentation covers this step.

- **Existing developer migration**: Developers currently using keyring will need to add the `sa-tokens` alias. Mitigation: can be added to the project's setup scripts or documented as a one-time migration step. The `store-sa-tokens` flow should handle this.

- **env provider semantics**: When using `env://`, `secretspec get --provider env --profile default OP_SA_CLIENT_WILLDAN` reads from the current environment. The developer must export the right variables before running `sc up`. If they forget, they get a clear error. This is the expected UX for the env workflow.

- **7-way refactor risk**: Extracting the shared snippet touches many callsites in devenv.nix. Mitigation: the example devenv tests (`examples/test-gateway`, `examples/hello-world`) exercise the full module evaluation and will catch breakage.

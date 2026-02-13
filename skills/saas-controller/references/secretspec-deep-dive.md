# SecretSpec Deep Dive

This reference covers the full secretspec configuration system: controller-level profiles, per-service composition, SA token management, and validation commands.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ saas-controller.secretProfiles (controller level)            │
│ ┌─────────────┐ ┌──────────────┐ ┌───────────────────────┐ │
│ │  tailscale   │ │ zuplo-backend│ │ (provider auto-export)│ │
│ │ TS_CLIENT_*  │ │ ZUPLO_API_*  │ │ merged automatically  │ │
│ └──────┬───────┘ └──────┬───────┘ └───────────┬───────────┘ │
│        │                │                      │             │
│        ▼                ▼                      ▼             │
│ services.<name>.secretspec.environments.<env>.serviceProfiles│
│ ┌────────────────────────────────────────────────────────┐   │
│ │  local  = { serviceProfiles = [ "tailscale" ]; }       │   │
│ │  edge   = { serviceProfiles = [ "tailscale" "zuplo" ]; │   │
│ │            secrets = { EXTRA = { ... }; }; }           │   │
│ └────────────────────────────────────────────────────────┘   │
│                          │                                    │
│                          ▼                                    │
│   sc check-secrets validates all composed secrets exist       │
└─────────────────────────────────────────────────────────────┘
```

## Controller-Level Profiles

Define reusable secret sets at `saas-controller.secretProfiles`:

```nix
saas-controller.secretProfiles = {
  tailscale = {
    TS_CLIENT_SECRET = {
      description = "Tailscale OAuth client secret";
      required = true;               # default
      providers = [ "saas-controller" ];
    };
    TS_CLIENT_ID = {
      description = "Tailscale OAuth client ID";
      required = false;
      providers = [ "saas-controller" ];
    };
  };
  my-custom-profile = {
    API_KEY = {
      description = "External API key";
      required = true;
      providers = [ "saas-controller" ];
      default = null;                 # no default value
    };
  };
};
```

### Secret definition fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `description` | `str` | (required) | Human-readable description |
| `required` | `bool` | `true` | Whether the secret must be present |
| `providers` | `listOf str` | `[]` | SecretSpec provider aliases that can supply this secret |
| `default` | `nullOr str` | `null` | Default value when no provider supplies it |

## Per-Service Secretspec

Configure which profiles a service needs per environment:

```nix
services.my-service.secretspec = {
  # SA token alias for 1Password keyring retrieval
  saToken = "client-myorg";

  # Profile composition per environment
  environments = {
    local = {
      serviceProfiles = [ "tailscale" ];
      # Only tailscale secrets validated locally
    };
    edge = {
      serviceProfiles = [ "tailscale" "zuplo-backend" ];
      # Both profiles validated for edge

      # Per-instance extra secrets (merge with profiles)
      secrets = {
        STRIPE_API_KEY = {
          description = "Stripe API key for billing";
          required = true;
          providers = [ "client-myorg" ];
        };
      };
    };
  };

  # Tags for filtered validation
  tags = [ "tailscale" "billing" ];
};
```

### Service secretspec fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `saToken` | `nullOr str` | `null` | 1Password SA token alias for keyring retrieval |
| `environments` | `attrsOf { serviceProfiles, secrets }` | (required) | Per-environment profile composition |
| `tags` | `listOf str` | `[]` | Tags for `sc check-secrets --tag` filtering |

### Environment fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `serviceProfiles` | `listOf str` | (required) | Profile names from `saas-controller.secretProfiles` |
| `secrets` | `attrsOf secretDef` | `{}` | Per-instance extra secrets (merge with profiles; profiles take precedence on duplicates) |

## SA Token Retrieval

When `secretspec.saToken` is set, `sc up` and `sc check-secrets` automatically:

1. Convert the alias to an env var name: `"client-myorg"` -> `OP_SA_CLIENT_MYORG`
2. Read the token from the macOS keyring (stored at `saas-controller.saTokensDir`)
3. Export it as `OP_SERVICE_ACCOUNT_TOKEN` before running secretspec commands

This allows per-service 1Password vault scoping without manual token management.

```nix
# Service uses a client-specific 1Password vault
secretspec.saToken = "client-willdan";
# sc up will automatically:
#   1. Read OP_SA_CLIENT_WILLDAN from keyring
#   2. Export as OP_SERVICE_ACCOUNT_TOKEN
#   3. Run secretspec commands with that token
```

## Provider Auto-Export

Providers can declare `secretProfiles` in their `.nix` file:

```nix
# In providers/zuplo.nix
{
  secretProfiles = {
    zuplo = { };  # empty, deploy uses CLI auth
    zudoku = {
      ZUDOKU_PUBLIC_AUTH_CLIENT_ID = {
        description = "Frontegg OAuth client ID";
        required = false;
        providers = [ "saas-controller" ];
        default = "22426e52-...";
      };
    };
  };
  # ...
}
```

These profiles are:
1. Auto-merged into `saas-controller.secretProfiles` at evaluation time
2. Auto-included for any service using that provider (no manual `serviceProfiles` entry needed)

### Three-layer secret composition

For each service environment, secrets are composed in this order (first occurrence wins on duplicates):

1. **Controller-level profiles** from `serviceProfiles` list
2. **Provider-contributed profiles** auto-included from the service's provider
3. **Per-instance inline secrets** from the environment's `secrets` option

## Validation Commands

### sc check-secrets

Validates that all required secrets are present for configured services.

```bash
# Check all services, all environments
sc check-secrets

# Check only services tagged "tailscale"
sc check-secrets --tag tailscale

# Check a specific service
sc check-secrets --service my-gateway

# Show help
sc check-secrets --help
```

For each service/environment combination, the command:
1. Resolves the composed secret list (profiles + provider auto-export + inline secrets)
2. Generates a temporary `secretspec.toml` with all required secrets
3. Swaps the SA token if `saToken` is configured
4. Runs `secretspec check` against each provider

Output shows pass/fail per service per environment with missing secret details.

### sc secret-status

Shows a table mapping secrets to services and environments:

```bash
sc secret-status
```

Output includes: secret name, which services need it, which environments, required/optional status, and which provider supplies it.

## Setting null to opt out

Set `secretspec = null` (the default) to exclude a service from secret validation entirely:

```nix
# This service has no secrets to validate
services.my-service.secretspec = null;  # default, not in sc check-secrets
```

Only services with `secretspec != null` participate in `sc check-secrets`.

## Full Example

```nix
{
  # Controller-level profiles
  saas-controller.secretProfiles = {
    tailscale = {
      TS_CLIENT_SECRET = { description = "OAuth secret"; providers = [ "saas-controller" ]; };
      TS_CLIENT_ID = { description = "OAuth client ID"; required = false; providers = [ "saas-controller" ]; };
    };
    billing = {
      STRIPE_SECRET_KEY = { description = "Stripe secret key"; providers = [ "client-willdan" ]; };
      STRIPE_WEBHOOK_SECRET = { description = "Stripe webhook signing secret"; providers = [ "client-willdan" ]; };
    };
  };

  # Service with full secretspec configuration
  saas-controller.services.my-gateway = {
    enable = true;
    provider = "zuplo";
    providerConfig = {
      project = "my-gateway";
      account = "my-account";
      path = "services/my-gateway";
    };
    environments = {
      local.enable = true;
      edge = { enable = true; autodeploy = true; };
    };
    secretspec = {
      saToken = "client-willdan";
      environments = {
        local = {
          serviceProfiles = [ "tailscale" ];
          # zuplo + zudoku profiles auto-included from provider
        };
        edge = {
          serviceProfiles = [ "tailscale" "billing" ];
          # zuplo + zudoku auto-included, plus billing manually added
          secrets = {
            CUSTOM_EDGE_TOKEN = {
              description = "Edge-only auth token";
              providers = [ "saas-controller" ];
            };
          };
        };
      };
      tags = [ "tailscale" "billing" "gateway" ];
    };
  };
}
```

```bash
sc check-secrets --tag billing       # Validates STRIPE_* for all billing-tagged services
sc check-secrets --service my-gateway # Validates all secrets for my-gateway
sc secret-status                     # Shows full secret mapping table
```

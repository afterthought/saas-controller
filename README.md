# SaaS Controller

Multi-cloud service orchestration for [devenv](https://devenv.sh). Declarative service definitions with pluggable providers. Manages local dev with Tailscale HTTPS (`sc up`) and cloud deployment (`sc deploy`).

> **For AI agents**: Install the skill with `npx skills add afterthought/saas-controller` for agent-optimized context.

## What It Does

SaaS Controller manages the lifecycle of cloud services:

- **Run locally** with real HTTPS URLs on your Tailscale tailnet (`sc up`)
- **Deploy** code to environments with pre/post hooks (`sc deploy`)
- **Validate secrets** across services and environments (`sc check-secrets`)
- **Provision** projects on cloud platforms (one-time setup)

## Architecture

Providers own the full service lifecycle. Each provider generates its own docker-compose stack with a Tailscale sidecar for HTTPS on the tailnet.

```
┌──────────────────────────────────────────────────────────┐
│                    saas-controller                         │
│                                                           │
│  ┌─────────────────────────────────────────────────────┐ │
│  │                 Providers                            │ │
│  │  Each provider owns up() + deploy()                 │ │
│  ├─────────────────────────────────────────────────────┤ │
│  │  zuplo          │ API gateway + docs portal         │ │
│  │  docker-compose │ Generic compose stacks            │ │
│  │  [your own]     │ via externalProviders             │ │
│  └─────────────────────────────────────────────────────┘ │
│                                                           │
│  sc up topology (per service):                            │
│  ┌────────────────────────────────────────────────────┐  │
│  │ docker-compose stack                                │  │
│  │  ┌─────────────┐  ┌────────────────────────────┐   │  │
│  │  │  tailscale   │  │  app container(s)          │   │  │
│  │  │  sidecar     │◀─│  network_mode:             │   │  │
│  │  │              │  │    service:tailscale        │   │  │
│  │  │  HTTPS :443  │  │  PORT=3000                 │   │  │
│  │  └─────────────┘  └────────────────────────────┘   │  │
│  │  URL: https://sc-<slug>-<service>.<tailnet>         │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

When you run `sc up`, each provider generates a compose stack in `.saas-controller/compose/<serviceName>/`. The stack includes a Tailscale sidecar container that joins your tailnet as an ephemeral node, providing HTTPS with valid certificates. App containers share the sidecar's network namespace. When you stop `sc up`, the ephemeral nodes auto-remove.

## Quick Start

### 1. Import the module

```nix
# devenv.yaml
imports:
  - github:afterthought/saas-controller
```

Or as a flake input:

```nix
# flake.nix
inputs.saas-controller.url = "github:afterthought/saas-controller";

# In your devenv module:
imports = [ inputs.saas-controller.outPath ];
```

### 2. Configure a service

Here's a minimal hello-world service:

```nix
# devenv.nix
{ pkgs, lib, config, ... }:
{
  saas-controller.services.hello-world = {
    enable = true;
    provider = "hello-world";
    providerConfig = {
      path = "examples/hello-world";  # dir with server.mjs + Dockerfile
    };
    environments = {
      local.enable = true;
    };
  };
}
```

### 3. Use it

```bash
sc up              # Starts compose stack with tailscale sidecar
                   # Prints: https://sc-<slug>-hello-world.<tailnet>:443
```

## Full Example: Zuplo Gateway with Secrets

A more complete example with a Zuplo API gateway, multiple environments, and secret management:

```nix
{ pkgs, lib, config, ... }:
{
  saas-controller.services.my-gateway = {
    enable = true;
    displayName = "My API Gateway";
    provider = "zuplo";
    providerConfig = {
      project = "my-gateway";       # Zuplo project name
      account = "my-account";       # Zuplo account
      path = "services/my-gateway"; # Path to zuplo project in repo
    };

    environments = {
      local.enable = true;
      edge = {
        enable = true;
        autodeploy = true;          # Auto-deploy on git push
      };
    };

    # Secret management
    secretspec = {
      saToken = "client-myorg";     # 1Password SA token alias
      environments = {
        local = {
          serviceProfiles = [ "tailscale" ];
          # → validates TS_CLIENT_SECRET, TS_CLIENT_ID
        };
        edge = {
          serviceProfiles = [ "tailscale" "zuplo-backend" ];
          # → validates tailscale + zuplo secrets
        };
      };
      tags = [ "tailscale" "zuplo" ]; # For filtered checking
    };
  };
}
```

```bash
sc up                              # Start locally with tailscale HTTPS
sc deploy my-gateway -e edge       # Deploy to edge environment
sc check-secrets --tag tailscale   # Validate tailscale secrets across services
```

## Secret Profiles

Secrets are managed in two layers: controller-level profile definitions and per-service composition.

### Define profiles at the controller level

Profiles are reusable sets of secret definitions:

```nix
saas-controller.secretProfiles = {
  tailscale = {
    TS_CLIENT_SECRET = {
      description = "Tailscale OAuth client secret";
      required = true;
      providers = [ "saas-controller" ];
    };
    TS_CLIENT_ID = {
      description = "Tailscale OAuth client ID";
      required = false;
      providers = [ "saas-controller" ];
    };
  };
  my-api-keys = {
    API_KEY = {
      description = "External API key";
      providers = [ "saas-controller" ];
    };
  };
};
```

### Compose profiles per service per environment

Each service selects which profiles it needs for each environment:

```nix
services.my-service.secretspec = {
  saToken = "client-myorg";          # 1Password SA token alias
  environments = {
    local = {
      serviceProfiles = [ "tailscale" ];
      # Only tailscale secrets needed locally
    };
    edge = {
      serviceProfiles = [ "tailscale" "my-api-keys" ];
      # Both profiles needed for edge deployment
    };
  };
  tags = [ "tailscale" ];            # For sc check-secrets --tag filtering
};
```

### Provider auto-export

Providers can declare `secretProfiles` in their implementation (e.g., the `zuplo` provider exports `zuplo` and `zudoku` profiles). These are automatically merged into `saas-controller.secretProfiles`. When a service uses a provider, that provider's profiles are auto-included — no manual wiring needed.

## CLI Reference

```bash
# Local development
sc up                                    # Start all local services
sc up my-gateway                         # Start specific service
sc up --environment edge                 # Start for specific environment

# Deployment
sc deploy                                # Deploy all (default environment)
sc deploy --environment production       # Deploy all to production
sc deploy my-gateway -e edge             # Deploy specific service to edge
sc undeploy my-gateway                   # Remove persistent service

# Secret management
sc check-secrets                         # Validate all service secrets
sc check-secrets --tag tailscale         # Filter by tag
sc check-secrets --service my-gateway    # Filter by service
sc secret-status                         # Secret-to-service mapping table

# Other
sc help                                  # Show help
provision-projects                       # One-time project setup
```

## Provider Summary

| Provider | providerConfig keys | sc up? | Auto-exported profiles |
|----------|-------------------|--------|----------------------|
| `zuplo` | `project`, `account`, `path` | Yes | `zuplo`, `zudoku` |
| `docker-compose` | `path`, `composeFile`(opt), `tailscale`(opt) | Yes | (none) |

## Tailscale Setup

`sc up` requires one-time Tailscale setup: ACL tags, an OAuth client, and credentials. See the [tailscale setup guide](skills/saas-controller/references/tailscale-setup.md) for step-by-step instructions.

## Extensibility

Register custom providers:

```nix
saas-controller.externalProviders.my-provider = ./providers/my-provider.nix;
```

See [EXTENDING.md](./EXTENDING.md) for the provider authoring guide and `providers/TEMPLATE.nix` for the interface template.

## File Structure

```
├── devenv.nix              # Module entrypoint (options + config)
├── lib/
│   ├── helpers.nix         # Task builders and deploy pipeline
│   ├── dependencies.nix    # Dependency validation
│   └── docker-compose.nix  # Shared compose file helpers
├── providers/              # Cloud providers
│   ├── TEMPLATE.nix        # Provider interface template
│   ├── zuplo.nix
│   ├── frontegg.nix
│   ├── datadog.nix
│   ├── secretspec-export.nix
│   ├── docker-compose.nix
│   └── hello-world.nix
├── scripts/
│   └── frontegg-register.mjs
└── skills/
    └── saas-controller/    # Agent skill (npx skills add)
        ├── SKILL.md
        └── references/
```

## License

MIT

# SaaS Controller

Multi-cloud service orchestration for [devenv](https://devenv.sh). Declarative service definitions with pluggable providers, runtimes, and network strategies.

## What it does

SaaS Controller manages the lifecycle of cloud services:

- **Provision** projects on cloud platforms (Zuplo, AWS, Cloudflare, etc.)
- **Deploy** code to environments with pre/post hooks
- **Run** services locally with dev-serve scripts
- **Export** secrets from vaults to cloud providers

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    saas-controller                        │
│                                                          │
│  ┌──────────┐   ┌──────────┐   ┌──────────────────────┐ │
│  │ Providers │   │ Runtimes │   │ Networks             │ │
│  │ (WHAT)    │   │ (HOW)    │   │ (WHERE)              │ │
│  ├──────────┤   ├──────────┤   ├──────────────────────┤ │
│  │ zuplo    │   │ dev-mgr  │   │ tailscale (HTTPS)    │ │
│  │ frontegg │   │ docker   │   │ localhost (local)    │ │
│  │ datadog  │   │ launchd  │   │ [your own]           │ │
│  │ secretspec│   │ [yours]  │   │                      │ │
│  │ [yours]  │   │          │   │                      │ │
│  └──────────┘   └──────────┘   └──────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

**Providers** define WHAT to deploy (Zuplo gateways, Frontegg apps, etc.).
**Runtimes** define HOW to run locally (dev-manager-mcp, docker-compose, launchd).
**Networks** define WHERE to expose (Tailscale HTTPS, localhost-only).

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

```nix
# devenv.nix
saas-controller.services.my-gateway = {
  enable = true;
  provider = "zuplo";
  providerConfig = {
    project = "my-project";
    account = "my-account";
    path = "services/my-gateway";
  };

  environments = {
    local.enable = true;
    edge = { enable = true; autodeploy = true; };
    main = { enable = true; autodeploy = false; };
  };

  run.secretSource = "onepassword://user@vault";
};
```

### 3. Use it

```bash
# Start local dev servers
sc up

# Deploy to edge
sc deploy my-gateway -e edge

# Deploy all services to production
sc deploy -e main
```

## Runtime + Network Configuration

### Global defaults

```nix
saas-controller = {
  defaultRuntime = "dev-manager-mcp";  # or "docker-compose", "launchd"
  defaultNetwork = "tailscale";        # or "localhost"
};
```

### Per-service overrides

```nix
saas-controller.services.my-service = {
  runtime = "docker-compose";  # override for this service only
  network = "localhost";       # no Tailscale exposure
  # ...
};
```

### Available runtimes

| Runtime | Process management | Port allocation | Status |
|---------|-------------------|-----------------|--------|
| `dev-manager-mcp` | mcporter daemon | Dynamic from daemon | Production |
| `docker-compose` | docker compose | Compose port mapping | Stub |
| `launchd` | macOS launchctl | Port file persistence | Stub |

### Available networks

| Network | Exposure | Use case |
|---------|----------|----------|
| `tailscale` | HTTPS on tailnet | Remote access, team sharing |
| `localhost` | 127.0.0.1 only | Local-only development |

## Extensibility

Register custom providers, runtimes, or networks:

```nix
saas-controller = {
  # Custom cloud provider
  externalProviders.aws-lambda = ./providers/aws-lambda.nix;

  # Custom runtime
  externalRuntimes.podman = ./runtimes/podman.nix;

  # Custom network
  externalNetworks.ngrok = ./networks/ngrok.nix;
};
```

See [EXTENDING.md](./EXTENDING.md) for detailed authoring guides and templates.

## File Structure

```
├── devenv.nix              # Module entrypoint
├── lib/
│   ├── helpers.nix         # Task builders and runtime dispatcher
│   ├── dependencies.nix    # Dependency validation
│   └── networks.nix        # Network strategies (tailscale, localhost)
├── providers/              # Service providers (WHAT to run)
│   ├── TEMPLATE.nix
│   ├── zuplo.nix
│   ├── frontegg.nix
│   ├── datadog.nix
│   └── secretspec-export.nix
├── runtimes/               # Process runtimes (HOW to run)
│   ├── TEMPLATE.nix
│   ├── dev-manager-mcp.nix
│   ├── docker-compose.nix
│   └── launchd.nix
└── scripts/
    └── frontegg-register.mjs
```

## CLI Reference

### sc (SaaS Controller)

```bash
sc up [service]                    # Start local dev servers
sc up --environment edge           # Start for specific environment
sc deploy [service] -e <env>       # Deploy with pre/post hooks
sc help                            # Show help
```

### Standalone scripts

```bash
provision-projects                 # One-time project setup
deploy-environment <env>           # Deploy all services
export-secrets-environment <env>   # Export secrets
check-saas-controller-secrets      # Validate credentials
```

## License

MIT

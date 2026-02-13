# Provider Reference

Each builtin provider implements a subset of the provider interface. All providers support `provisionProject` and `deploy`. Providers with local dev support also implement `up()`.

## zuplo

API gateway and documentation portal. Runs via `npx zuplo` CLI with hot-reload locally, deploys to Zuplo cloud control plane.

**providerConfig:**

| Key | Required | Description |
|-----|----------|-------------|
| `project` | Yes | Zuplo project name |
| `account` | Yes | Zuplo account name |
| `path` | Yes | Path to zuplo project directory in repo |

**sc up:** Yes. Generates docker-compose stack with two app containers (API on port 9000, docs on port 3001) plus tailscale sidecar. Both share the tailscale network namespace.

**Auto-exported secretProfiles:**
- `zuplo` — (empty, deploy uses CLI auth)
- `zudoku` — Frontegg OAuth credentials for docs authentication:
  - `ZUDOKU_PUBLIC_AUTH_CLIENT_ID` (optional, has default)
  - `ZUDOKU_PUBLIC_AUTH_ISSUER` (optional, has default)

**Example:**

```nix
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
};
```

## docker-compose

Generic provider for pre-authored docker-compose files. Overlays a tailscale sidecar via Docker Compose multi-file merge. App services automatically get `network_mode: service:tailscale`.

**providerConfig:**

| Key | Required | Description |
|-----|----------|-------------|
| `path` | Yes | Directory containing docker-compose.yml |
| `composeFile` | No | Override compose filename (default: `"docker-compose.yml"`) |
| `tailscale` | No | Array of `{ port, upstream }` entries for serve config (default: `[{ port = 443; upstream = "http://127.0.0.1:8080"; }]`) |

**sc up:** Yes. Reads the existing compose file, generates a tailscale sidecar overlay, and starts the merged stack. App services are auto-detected and wired to the tailscale network namespace.

**Auto-exported secretProfiles:** None.

**Example:**

```nix
saas-controller.services.miniflux = {
  enable = true;
  provider = "docker-compose";
  providerConfig = {
    path = "services/miniflux";
    tailscale = [
      { port = 443; upstream = "http://127.0.0.1:8080"; }
    ];
  };
  environments.local.enable = true;
};
```

## Custom Providers

Register external providers:

```nix
saas-controller.externalProviders.my-provider = ./providers/my-provider.nix;
```

See [EXTENDING.md](../../../EXTENDING.md) and `providers/TEMPLATE.nix` for the provider interface.

# Tailscale Setup (One-Time)

`sc up` uses tailscale sidecar containers to give each worktree unique HTTPS URLs on the tailnet. This requires one-time setup of ACL tags, an OAuth client, and credentials.

## 1. Configure ACL Tag

In the [Tailscale admin console](https://login.tailscale.com/admin/acls), switch to the JSON policy editor and add a `tagOwners` entry:

```json
"tagOwners": {
  "tag:sc-dev": ["autogroup:admin"]
}
```

This declares the tag so OAuth clients can use it. Your existing ACL rules handle network access.

If your policy uses the default `"*"` -> `"*:*"` rule, also add a rule for tagged nodes (tags opt out of the default member group):

```json
{ "action": "accept", "src": ["autogroup:member"], "dst": ["tag:sc-dev:*"] }
```

## 2. Create OAuth Client

In the [Tailscale admin console](https://login.tailscale.com/admin/settings/oauth):

1. Click **Generate OAuth client** (under "Trust credentials")
2. Add the **`auth_keys`** scope (Write)
3. Select **`tag:sc-dev`** as the tag (available after step 1)
4. Generate and copy both the **Client ID** and **Client Secret**

The OAuth client generates and auto-renews auth keys -- they never expire. The tag is assigned to nodes automatically by the OAuth client; the sidecar doesn't need to advertise it.

## 3. Store Credentials

Add to your environment (via SecretSpec, `.env`, or shell export):

| Variable | Required | Description |
|----------|----------|-------------|
| `TS_CLIENT_SECRET` | Yes | OAuth client secret |
| `TS_CLIENT_ID` | No | OAuth client ID |
| `SC_TAILNET` | No | Tailnet MagicDNS suffix, e.g. `my-tailnet.ts.net` (auto-detected if host tailscale is installed) |

## How It Works

1. `sc up` reads `VK_WORKSPACE_ID` (first 8 chars become the slug, fallback: `local`)
2. Reads tailnet suffix from `SC_TAILNET` env var or host tailscale (if installed)
3. Each provider generates a docker-compose stack with a `tailscale/tailscale:latest` sidecar
4. The sidecar container joins the tailnet as an ephemeral node (host tailscale NOT required)
5. App containers share the sidecar's network namespace (`network_mode: service:tailscale`)
6. Tailscale serve provides HTTPS with valid certs on the tailnet
7. Hostname pattern: `sc-<slug>-<serviceName>.<tailnet>`
8. Ephemeral nodes auto-remove when containers stop

## Sidecar Configuration

The tailscale sidecar in each compose stack is configured with:

```yaml
tailscale:
  image: tailscale/tailscale:latest
  hostname: ${TS_HOSTNAME}
  environment:
    - TS_HOSTNAME=${TS_HOSTNAME}
    - TS_AUTHKEY=${TS_CLIENT_SECRET}?ephemeral=true
    - TS_EXTRA_ARGS=--advertise-tags=tag:sc-dev
    - TS_SERVE_CONFIG=/config/serve.json
    - TS_STATE_DIR=/var/lib/tailscale
    - TS_USERSPACE=false
  cap_add: [NET_ADMIN]
  devices: [/dev/net/tun]
  healthcheck:
    test: tailscale status
    interval: 2s
    timeout: 5s
    retries: 10
```

App containers use `network_mode: service:tailscale` and `depends_on: tailscale: condition: service_healthy`.

## Troubleshooting

**"TS_CLIENT_SECRET not set"**: The OAuth client secret is not in the environment. Set it via SecretSpec, `.env`, or shell export.

**Sidecar healthcheck fails**: Check that `TS_CLIENT_SECRET` is valid. Regenerate the OAuth client if needed. Check that the ACL tag `tag:sc-dev` exists and the OAuth client has the `auth_keys` scope.

**"SC_TAILNET not found"**: Either install tailscale on the host (for auto-detection) or set `SC_TAILNET=your-tailnet.ts.net` in the environment.

**Ephemeral node not cleaning up**: Ephemeral nodes should auto-remove when the container stops. If stale nodes appear, remove them manually in the Tailscale admin console under Machines.

## ADDED Requirements

### Requirement: Hostname derivation from workspace ID
The system SHALL derive a hostname slug from `VK_WORKSPACE_ID` by taking the first 8 characters. The full hostname SHALL be `sc-${SLUG}-${serviceName}`. When `VK_WORKSPACE_ID` is not set, the slug SHALL default to `"local"`.

#### Scenario: VibeKanban workspace provides ID
- **WHEN** `VK_WORKSPACE_ID` is set to a UUID (e.g., `59136c0b-a1b2-4c3d-8e9f-0a1b2c3d4e5f`)
- **THEN** the slug SHALL be `59136c0b` and the hostname for service `my-gateway` SHALL be `sc-59136c0b-my-gateway`

#### Scenario: No workspace ID (fallback)
- **WHEN** `VK_WORKSPACE_ID` is not set
- **THEN** the slug SHALL be `local` and the hostname for service `my-gateway` SHALL be `sc-local-my-gateway`

#### Scenario: DNS label compliance
- **WHEN** a hostname is derived
- **THEN** the full hostname SHALL be a valid DNS label (lowercase alphanumeric and hyphens, under 63 characters)

### Requirement: FQDN computation from tailnet suffix
The system SHALL read the tailnet MagicDNS suffix from the host's tailscale via `tailscale status --json | jq -r '.MagicDNSSuffix'`. The FQDN SHALL be `${HOSTNAME}.${TAILNET}`.

#### Scenario: FQDN computed for URL generation
- **WHEN** the hostname is `sc-59136c0b-my-gateway` and the tailnet suffix is `tail12345.ts.net`
- **THEN** the FQDN SHALL be `sc-59136c0b-my-gateway.tail12345.ts.net`

#### Scenario: Tailnet suffix read from host
- **WHEN** `sc up` starts
- **THEN** it SHALL read the MagicDNS suffix from the host's running tailscale, NOT from the sidecar container

### Requirement: Multi-worktree uniqueness
Different VibeKanban worktrees running `sc up` on the same machine SHALL get different tailscale hostnames, preventing port and identity collisions.

#### Scenario: Two concurrent worktrees
- **WHEN** worktree A has `VK_WORKSPACE_ID=59136c0b-...` and worktree B has `VK_WORKSPACE_ID=8a2b4f1c-...`
- **THEN** worktree A's service `gateway` SHALL have hostname `sc-59136c0b-gateway` and worktree B's SHALL have `sc-8a2b4f1c-gateway`, creating two independent tailscale nodes

#### Scenario: Same worktree restarts cleanly
- **WHEN** the same worktree runs `sc up` again after stopping
- **THEN** the same hostname SHALL be used and the ephemeral node SHALL register cleanly (previous node already removed)

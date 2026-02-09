# Shared docker-compose + tailscale sidecar lifecycle library.
#
# Providers call these functions to build their compose stacks:
#   mkComposeFile       — complete docker-compose.yml with tailscale sidecar + app services
#   mkServeConfig       — serve-config.json from port-to-upstream mappings
#   mkComposeLifecycle  — up/down/logs/error-dump/cleanup bash script
#
# File content functions (mkComposeFile, mkServeConfig) produce text with
# docker-compose variable references (like TS_HOSTNAME, TS_CLIENT_SECRET).
# Callers write these to disk via the writeFile helper which uses printf
# to avoid bash variable expansion.

{ lib }:

rec {
  # Write a Nix string to a file without bash variable expansion.
  # Uses printf to avoid heredoc quoting issues with multi-line content.
  #
  # Args:
  #   path: File path to write
  #   content: Nix string (may contain ${VAR} for docker-compose interpolation)
  #
  # Returns: Bash script snippet
  writeFile = path: content:
    "printf '%s' ${lib.escapeShellArg content} > \"${path}\"";

  # Generate a complete docker-compose.yml with tailscale sidecar and app services.
  #
  # The sidecar uses these docker-compose variable interpolations from host env:
  #   TS_HOSTNAME       — the tailscale node hostname (set by caller via export)
  #   TS_CLIENT_SECRET  — OAuth client secret (injected by secretspec)
  #
  # Args:
  #   appServices: YAML string defining app services (at 4-space indent level)
  #   extraVolumes: list of volume name strings beyond ts-state (default: [])
  #
  # Returns: Complete docker-compose.yml content as a string.
  mkComposeFile = { appServices, extraVolumes ? [] }:
    let
      allVolumes = [ "ts-state" ] ++ extraVolumes;
      volumeLines = lib.concatMapStringsSep "\n" (v: "  ${v}:") allVolumes;
    in
    lib.concatStringsSep "\n" [
      "services:"
      "  tailscale:"
      "    image: tailscale/tailscale:latest"
      "    hostname: \${TS_HOSTNAME}"
      "    environment:"
      "      - TS_HOSTNAME=\${TS_HOSTNAME}"
      "      - TS_AUTHKEY=\${TS_CLIENT_SECRET}?ephemeral=true"
      "      - TS_EXTRA_ARGS=--advertise-tags=tag:sc-dev"
      "      - TS_SERVE_CONFIG=/config/serve.json"
      "      - TS_STATE_DIR=/var/lib/tailscale"
      "      - TS_USERSPACE=false"
      "    volumes:"
      "      - ./serve-config.json:/config/serve.json:ro"
      "      - ts-state:/var/lib/tailscale"
      "    cap_add:"
      "      - NET_ADMIN"
      "    devices:"
      "      - /dev/net/tun:/dev/net/tun"
      "    healthcheck:"
      "      test: [\"CMD\", \"tailscale\", \"status\"]"
      "      interval: 2s"
      "      timeout: 5s"
      "      retries: 10"
      ""
      appServices
      "volumes:"
      volumeLines
    ];

  # Generate serve-config.json content from port-to-upstream mappings.
  #
  # Uses the TS_CERT_DOMAIN placeholder — tailscale containerboot replaces
  # it with the node's FQDN at startup.
  #
  # Args:
  #   entries: List of { port, upstream } attrsets
  #     e.g. [{ port = 443; upstream = "http://127.0.0.1:8080"; }]
  #
  # Returns: A JSON string.
  mkServeConfig = entries:
    let
      tcpEntries = lib.concatStringsSep ",\n    " (map (e:
        ''"${toString e.port}": { "HTTPS": true }''
      ) entries);
      webEntries = lib.concatStringsSep ",\n    " (map (e:
        ''"''${TS_CERT_DOMAIN}:${toString e.port}": {
      "Handlers": { "/": { "Proxy": "${e.upstream}" } }
    }''
      ) entries);
    in
    ''
      {
        "TCP": {
          ${tcpEntries}
        },
        "Web": {
          ${webEntries}
        }
      }
    '';

  # Build the `docker compose` command prefix with project-directory and file flags.
  #
  # Args:
  #   composeDir: Nix string — path to the compose directory
  #   composeFiles: List of compose file basenames. Default: ["docker-compose.yml"]
  #   projectDir: Optional Nix string — override --project-directory.
  #
  # Returns: A string like "docker compose --project-directory /src -f /dir/a.yml -f /dir/b.yml"
  mkComposeCommand = {
    composeDir,
    composeFiles ? [ "docker-compose.yml" ],
    projectDir ? null,
  }:
    let
      projectDirFlag = lib.optionalString (projectDir != null)
        ''--project-directory "${projectDir}" '';
      composeFileFlags = lib.concatStringsSep " " (map (f:
        ''-f "${composeDir}/${f}"''
      ) composeFiles);
    in
    "docker compose ${projectDirFlag}${composeFileFlags}";

  # Generate the compose lifecycle bash script (up/down/logs/error-dump/cleanup).
  #
  # Args:
  #   composeDir: Nix string — path to the compose directory (baked in at eval time)
  #   serviceName: Nix string — human-readable name for log messages
  #   composeFiles: List of compose file basenames. Default: ["docker-compose.yml"]
  #   projectDir: Optional Nix string — override --project-directory for docker compose.
  #               Controls where relative paths (build context, volumes) are resolved from.
  #               Defaults to null (docker compose uses first -f file's directory).
  #   urls: List of { label, url } for printing HTTPS URLs after startup.
  #         URL values can contain bash variable references (e.g. "$FQDN").
  #
  # Returns: A bash script string
  mkComposeLifecycle = {
    composeDir,
    serviceName,
    composeFiles ? [ "docker-compose.yml" ],
    projectDir ? null,
    urls ? [],
  }:
    let
      composeCmd = mkComposeCommand { inherit composeDir composeFiles projectDir; };
    in
    ''
      # Cleanup on exit
      cleanup() {
        echo "Stopping ${serviceName}..."
        ${composeCmd} down 2>/dev/null || true
      }
      trap cleanup EXIT INT TERM

      # Start compose stack detached, wait for healthchecks
      if ! ${composeCmd} up -d --build --wait; then
        echo ""
        echo "Failed to start ${serviceName}. Container logs:"
        echo "---"
        ${composeCmd} logs --tail=50 2>&1 || true
        echo "---"
        exit 1
      fi

      # Print HTTPS URLs
      ${lib.concatStringsSep "\n      " (map (u:
        ''echo "  ${u.label}: ${u.url}"''
      ) urls)}

      # Stream logs in foreground
      ${composeCmd} logs -f
    '';
}

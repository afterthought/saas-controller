# Shared docker-compose + tailscale sidecar lifecycle library.
#
# Providers call these functions to build their compose stacks:
#   mkTailscaleSidecar  — YAML snippet for the tailscale sidecar service
#   mkServeConfig       — serve-config.json from port-to-upstream mappings
#   mkComposeLifecycle  — up/down/logs/error-dump/cleanup bash script

{ lib }:

{
  # Generate the tailscale sidecar service YAML block.
  #
  # Args:
  #   hostname: The tailscale hostname (e.g. "sc-abc12345-miniflux")
  #
  # Returns: A string of YAML (indented for embedding in a compose services: block)
  mkTailscaleSidecar = hostname: ''
    tailscale:
      image: tailscale/tailscale:latest
      hostname: ${hostname}
      environment:
        - TS_HOSTNAME=${hostname}
        - TS_AUTHKEY=''${TS_CLIENT_SECRET}?ephemeral=true
        - TS_EXTRA_ARGS=--advertise-tags=tag:sc-dev
        - TS_SERVE_CONFIG=/config/serve.json
        - TS_STATE_DIR=/var/lib/tailscale
        - TS_USERSPACE=false
      volumes:
        - ./serve-config.json:/config/serve.json:ro
        - ts-state:/var/lib/tailscale
      cap_add:
        - NET_ADMIN
      devices:
        - /dev/net/tun:/dev/net/tun
      healthcheck:
        test: ["CMD", "tailscale", "status"]
        interval: 2s
        timeout: 5s
        retries: 10
  '';

  # Generate serve-config.json content from port-to-upstream mappings.
  #
  # Args:
  #   entries: List of { port, upstream } attrsets
  #     e.g. [{ port = 443; upstream = "http://127.0.0.1:8080"; }]
  #
  # Returns: A JSON string for serve-config.json
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

  # Generate the compose lifecycle bash script (up/down/logs/error-dump/cleanup).
  #
  # Args:
  #   composeDir: Path to the directory containing docker-compose.yml
  #   serviceName: Human-readable service name (for log messages)
  #   composeFiles: List of compose file paths (relative to composeDir) for -f flags.
  #                 Default: ["docker-compose.yml"]
  #   urls: List of { label, url } for printing HTTPS URLs after startup.
  #         e.g. [{ label = "Docs"; url = "https://host.tailnet.ts.net:443"; }]
  #
  # Returns: A bash script string
  mkComposeLifecycle = {
    composeDir,
    serviceName,
    composeFiles ? [ "docker-compose.yml" ],
    urls ? [],
  }:
    let
      composeFileFlags = lib.concatStringsSep " " (map (f:
        ''-f "${composeDir}/${f}"''
      ) composeFiles);
    in
    ''
      # Cleanup on exit
      cleanup() {
        echo "Stopping ${serviceName}..."
        docker compose ${composeFileFlags} down 2>/dev/null || true
      }
      trap cleanup EXIT INT TERM

      # Start compose stack detached, wait for healthchecks
      if ! docker compose ${composeFileFlags} up -d --build --wait; then
        echo ""
        echo "Failed to start ${serviceName}. Container logs:"
        echo "---"
        docker compose ${composeFileFlags} logs --tail=50 2>&1 || true
        echo "---"
        exit 1
      fi

      # Print HTTPS URLs
      ${lib.concatStringsSep "\n      " (map (u:
        ''echo "  ${u.label}: ${u.url}"''
      ) urls)}

      # Stream logs in foreground
      docker compose ${composeFileFlags} logs -f
    '';
}

# Provider: docker-compose
#
# Accepts a pre-authored docker-compose.yml and injects a tailscale sidecar
# via Docker Compose multi-file merge (overlay). App services get
# network_mode: service:tailscale added automatically.
#
# Usage in your devenv.nix:
#   saas-controller.services.miniflux = {
#     enable = true;
#     provider = "docker-compose";
#     providerConfig = {
#       path = "services/miniflux";           # dir containing docker-compose.yml
#       # composeFile = "docker-compose.yml"; # optional override
#       tailscale = [
#         { port = 443; upstream = "http://127.0.0.1:8080"; }
#       ];
#     };
#     environments.local.enable = true;
#   };

{ pkgs, lib, config }:

let
  compose = import ../lib/docker-compose.nix { inherit lib; };
in
{
  # Local dev lifecycle: overlay tailscale sidecar onto pre-authored compose
  up = serviceName: service:
    let
      composeDir = "${config.git.root}/.saas-controller/compose/${serviceName}";
      sourceDir = "${config.git.root}/${service.providerConfig.path}";
      composeFile = service.providerConfig.composeFile or "docker-compose.yml";
      tailscaleEntries = service.providerConfig.tailscale or [
        { port = 443; upstream = "http://127.0.0.1:8080"; }
      ];

      serveContent = compose.mkServeConfig tailscaleEntries;

      # The tailscale sidecar service for the overlay.
      # Volume paths are absolute because --project-directory points to sourceDir.
      sidecarYaml = lib.concatStringsSep "\n" [
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
        "      - ${composeDir}/serve-config.json:/config/serve.json:ro"
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
        "volumes:"
        "  ts-state:"
      ];
    in
    ''
      set -euo pipefail

      mkdir -p "${composeDir}"

      # Compute tailscale hostname and FQDN (exported for docker-compose interpolation)
      export TS_HOSTNAME="sc-$SC_SLUG-${serviceName}"
      export FQDN="$TS_HOSTNAME.$SC_TAILNET"

      # Write serve-config.json
      ${compose.writeFile "${composeDir}/serve-config.json" serveContent}

      # Write the tailscale sidecar base overlay
      ${compose.writeFile "${composeDir}/tailscale-sidecar.yml" sidecarYaml}

      # Symlink the original compose file into composeDir so docker compose
      # resolves build contexts relative to the source directory
      ORIGINAL="${sourceDir}/${composeFile}"
      if [ ! -f "$ORIGINAL" ]; then
        echo "❌ Error: Compose file not found: $ORIGINAL" >&2
        exit 1
      fi
      ln -sf "$ORIGINAL" "${composeDir}/app-compose.yml"

      # Auto-detect app service names from original compose file and generate
      # the network_mode overlay that wires them through the tailscale sidecar
      APP_SERVICES=$(docker compose -f "$ORIGINAL" config --services 2>/dev/null)
      if [ -z "$APP_SERVICES" ]; then
        echo "❌ Error: No services found in $ORIGINAL" >&2
        exit 1
      fi

      # Build overlay YAML: set network_mode + depends_on for each app service
      {
        echo "services:"
        for svc in $APP_SERVICES; do
          echo "  $svc:"
          echo "    network_mode: service:tailscale"
          echo "    depends_on:"
          echo "      tailscale:"
          echo "        condition: service_healthy"
        done
      } > "${composeDir}/tailscale-overlay.yml"

      # Print URL
      export DEVSERVER_URL="https://$FQDN:443"
      echo "DEVSERVER_URL: $DEVSERVER_URL"

      ${compose.mkComposeLifecycle {
        inherit composeDir serviceName;
        # Resolve relative paths (build context, volumes) from the source directory
        projectDir = sourceDir;
        composeFiles = [
          "app-compose.yml"
          "tailscale-sidecar.yml"
          "tailscale-overlay.yml"
        ];
        urls = map (e: {
          label = "HTTPS :${toString e.port}";
          url = "https://$FQDN:${toString e.port}";
        }) tailscaleEntries;
      }}
    '';

  # docker-compose provider doesn't manage cloud projects
  provisionProject = serviceName: service: ''
    echo "  docker-compose: nothing to provision"
    echo "  ✓ Project ready"
  '';

  # docker-compose provider doesn't have a deploy pipeline
  deploy = serviceName: service: environment: envConfig: profile: provider: ''
    echo "  docker-compose: deploy is not supported for local-only compose services" >&2
    echo "  Use 'sc up' for local development." >&2
    exit 1
  '';
}

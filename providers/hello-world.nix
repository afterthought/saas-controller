# Provider: hello-world
#
# A minimal provider for testing sc up.
# Runs a simple Node.js HTTP server that responds with "Hello World".
#
# Usage in your devenv.nix:
#   saas-controller.services.hello-world = {
#     enable = true;
#     provider = "hello-world";
#     providerConfig.path = "examples/hello-world";
#     environments.local.enable = true;
#   };

{ pkgs, lib, config }:

{
  # Local dev lifecycle: generate docker-compose.yml and run the stack
  up = serviceName: service:
    let
      composeDir = "${config.git.root}/.saas-controller/compose/${serviceName}";
      sourceDir = "${config.git.root}/${service.providerConfig.path}";
    in
    ''
      set -euo pipefail

      COMPOSE_DIR="${composeDir}"
      mkdir -p "$COMPOSE_DIR"

      # Compute tailscale hostname and FQDN
      TS_HOSTNAME="sc-''${SC_SLUG}-${serviceName}"
      FQDN="''${TS_HOSTNAME}.''${SC_TAILNET}"

      # Generate Dockerfile
      cat > "$COMPOSE_DIR/Dockerfile" <<'DOCKERFILE'
      FROM node:22
      WORKDIR /app
      CMD ["node", "server.mjs"]
      DOCKERFILE

      # Generate serve-config.json for tailscale HTTPS routing
      # Uses ${TS_CERT_DOMAIN} placeholder — containerboot replaces it with the node's FQDN
      cat > "$COMPOSE_DIR/serve-config.json" <<'SERVECONFIG'
      {
        "TCP": {
          "443": { "HTTPS": true }
        },
        "Web": {
          "''${TS_CERT_DOMAIN}:443": {
            "Handlers": { "/": { "Proxy": "http://127.0.0.1:3000" } }
          }
        }
      }
      SERVECONFIG

      # Generate docker-compose.yml with tailscale sidecar
      cat > "$COMPOSE_DIR/docker-compose.yml" <<COMPOSEFILE
      services:
        tailscale:
          image: tailscale/tailscale:latest
          hostname: $TS_HOSTNAME
          environment:
            - TS_HOSTNAME=$TS_HOSTNAME
            - TS_AUTHKEY=\''${TS_CLIENT_SECRET}?ephemeral=true
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

        ${serviceName}:
          build:
            context: .
            dockerfile: Dockerfile
          network_mode: service:tailscale
          depends_on:
            tailscale:
              condition: service_healthy
          volumes:
            - ${sourceDir}:/app
          environment:
            - PORT=3000

      volumes:
        ts-state:
      COMPOSEFILE

      # Cleanup on exit
      cleanup() {
        echo "Stopping ${serviceName}..."
        docker compose -f "$COMPOSE_DIR/docker-compose.yml" down 2>/dev/null || true
      }
      trap cleanup EXIT INT TERM

      # Start compose stack detached, wait for healthchecks
      docker compose -f "$COMPOSE_DIR/docker-compose.yml" up -d --build --wait

      # Print HTTPS URL
      export DEVSERVER_URL="https://''${FQDN}:443"
      echo "DEVSERVER_URL: $DEVSERVER_URL"

      # Stream logs in foreground
      docker compose -f "$COMPOSE_DIR/docker-compose.yml" logs -f
    '';

  provisionProject = serviceName: service: ''
    echo "  hello-world: nothing to provision"
    echo "  ✓ Project ready"
  '';

  deploy = serviceName: service: environment: envConfig: profile: provider: ''
    echo "  hello-world: deploy is a no-op for this example"
    echo "  ✓ Deployment successful"

    mkdir -p ${config.git.root}/.saas-controller/outputs/${serviceName}
    cat > ${config.git.root}/.saas-controller/outputs/${serviceName}/${environment}.json <<EOF
    {
      "service": "${serviceName}",
      "environment": "${environment}",
      "provider": "hello-world",
      "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
      "outputs": {
        "appUrl": "http://127.0.0.1"
      }
    }
    EOF
  '';
}

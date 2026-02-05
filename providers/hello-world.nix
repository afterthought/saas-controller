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

      # Generate Dockerfile
      cat > "$COMPOSE_DIR/Dockerfile" <<'DOCKERFILE'
      FROM node:22
      WORKDIR /app
      CMD ["node", "server.mjs"]
      DOCKERFILE

      # Generate docker-compose.yml
      cat > "$COMPOSE_DIR/docker-compose.yml" <<COMPOSEFILE
      services:
        ${serviceName}:
          build:
            context: .
            dockerfile: Dockerfile
          volumes:
            - ${sourceDir}:/app
          ports:
            - "3000:3000"
          environment:
            - PORT=3000
      COMPOSEFILE

      export DEVSERVER_URL="http://localhost:3000"
      echo "DEVSERVER_URL: $DEVSERVER_URL"

      # Cleanup on exit
      cleanup() {
        echo "Stopping ${serviceName}..."
        docker compose -f "$COMPOSE_DIR/docker-compose.yml" down 2>/dev/null || true
      }
      trap cleanup EXIT INT TERM

      # Start compose stack in foreground
      docker compose -f "$COMPOSE_DIR/docker-compose.yml" up --build
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

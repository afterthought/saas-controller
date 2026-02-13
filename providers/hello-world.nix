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

let
  compose = import ../lib/docker-compose.nix { inherit lib config; };
in
{
  # Local dev lifecycle: generate docker-compose.yml and run the stack
  up = serviceName: service:
    let
      composeDir = "${config.git.root}/.saas-controller/compose/${serviceName}";
      sourceDir = "${config.git.root}/${service.providerConfig.path}";

      composeContent = compose.mkComposeFile {
        appServices = lib.concatStringsSep "\n" [
          "  ${serviceName}:"
          "    build:"
          "      context: ."
          "      dockerfile: Dockerfile"
          "    network_mode: service:tailscale"
          "    depends_on:"
          "      tailscale:"
          "        condition: service_healthy"
          "    volumes:"
          "      - ${sourceDir}:/app"
          "    environment:"
          "      - PORT=3000"
        ];
      };

      serveContent = compose.mkServeConfig [
        { port = 443; upstream = "http://127.0.0.1:3000"; }
      ];
    in
    ''
      set -euo pipefail

      mkdir -p "${composeDir}"

      # Compute tailscale hostname and FQDN (exported for docker-compose interpolation)
      export TS_HOSTNAME="sc-$SC_SLUG-${serviceName}"
      export FQDN="$TS_HOSTNAME.$SC_TAILNET"

      # Generate Dockerfile
      cat > "${composeDir}/Dockerfile" <<'DOCKERFILE'
      FROM node:22
      WORKDIR /app
      CMD ["node", "server.mjs"]
      DOCKERFILE

      # Generate serve-config.json and docker-compose.yml
      ${compose.writeFile "${composeDir}/serve-config.json" serveContent}
      ${compose.writeFile "${composeDir}/docker-compose.yml" composeContent}

      # Print URL
      export DEVSERVER_URL="https://$FQDN:443"
      echo "DEVSERVER_URL: $DEVSERVER_URL"

      ${compose.mkComposeLifecycle {
        inherit composeDir serviceName;
        urls = [{ label = "HTTPS"; url = "https://$FQDN:443"; }];
      }}
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

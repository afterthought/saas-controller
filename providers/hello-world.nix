# Provider: hello-world
#
# A minimal provider for testing sc up / dev-serve.
# Runs a simple Node.js HTTP server that responds with "Hello World".
#
# Usage in your devenv.nix:
#   saas-controller.services.hello-world = {
#     enable = true;
#     provider = "hello-world";
#     providerConfig.path = "examples/hello-world";
#     network = "localhost";
#     environments.local.enable = true;
#   };

{ pkgs, lib, config }:

{
  localVariants = serviceName: service: [
    {
      variant = "server";
      command = "node ${config.git.root}/${service.providerConfig.path}/server.mjs";
    }
  ];

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

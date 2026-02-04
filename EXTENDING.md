# Extending SaaS Controller with External Providers

SaaS Controller supports external provider registration, allowing teams to add support for new cloud platforms without modifying the core module.

## Hello World Example

A built-in `hello-world` provider is included for testing `sc up` and the dev-serve pipeline end-to-end. Add this to your project's `devenv.nix`:

```nix
saas-controller = {
  defaultNetwork = "localhost";   # no Tailscale needed for testing
  defaultRuntime = "dev-manager-mcp";

  services.hello-world = {
    enable = true;
    provider = "hello-world";
    providerConfig.path = "examples/hello-world";
    network = "localhost";
    environments.local.enable = true;
  };
};
```

Then run:

```bash
sc up              # starts the hello-world server
# or directly:
dev-serve-hello-world-server
```

The server listens on the dynamically assigned `$PORT` and responds with `Hello World` to any HTTP request. Source is in `examples/hello-world/server.mjs`.

## Quick Start

1. **Create a provider module** following the provider interface
2. **Register it** via `saas-controller.externalProviders`
3. **Use it** in your service configurations

## Provider Interface

A provider module must export functions matching this interface:

```nix
{ pkgs, lib, config }:

{
  # Required: One-time project/account creation
  provisionProject = serviceName: service: ''
    echo "Creating project for ${serviceName}"
    # Your provisioning logic here
  '';

  # Required: Deploy code/config to environment
  # Control plane secrets (API keys, etc.) are provided by wrapper in helpers.nix
  deploy = serviceName: service: environment: envConfig: profile: provider: ''
    echo "Deploying ${serviceName} to ${environment}"
    # Your deployment logic here

    # Write outputs for dependent services (optional)
    mkdir -p ${config.git.root}/.saas-controller/outputs/${serviceName}
    cat > ${config.git.root}/.saas-controller/outputs/${serviceName}/${environment}.json <<EOF
    {
      "service": "${serviceName}",
      "environment": "${environment}",
      "provider": "your-provider",
      "outputs": {
        "appUrl": "https://your-deployed-app.example.com",
        "apiKey": "generated-api-key"
      }
    }
    EOF
  '';

  # Optional: For hook providers (secretspec, frontegg, datadog)
  provision = serviceName: provisionConfig: servicePath: environment: serviceConfig: ''
    echo "Running provision hook for ${serviceName}/${environment}"
    # Your hook logic here
  '';
}
```

## Example: AWS Lambda Provider

### 1. Create Provider Module

**File: `providers/aws-lambda.nix`**

```nix
{ pkgs, lib, config }:

{
  provisionProject = serviceName: service: ''
    echo "  Creating AWS Lambda project: ${service.providerConfig.functionName}"
    echo "  Region: ${service.providerConfig.region}"

    # Check if function exists, create if not
    ${pkgs.awscli2}/bin/aws lambda get-function \
      --function-name ${service.providerConfig.functionName} \
      --region ${service.providerConfig.region} 2>/dev/null || \
    ${pkgs.awscli2}/bin/aws lambda create-function \
      --function-name ${service.providerConfig.functionName} \
      --runtime nodejs20.x \
      --role ${service.providerConfig.iamRole} \
      --handler index.handler \
      --region ${service.providerConfig.region} \
      --zip-file fileb://placeholder.zip

    echo "  ✓ Lambda function provisioned"
  '';

  deploy = serviceName: service: environment: envConfig: profile: provider: ''
    echo "  Deploying ${service.providerConfig.functionName} to ${environment}"

    # Change to project directory
    cd ${config.git.root}/${service.providerConfig.path}

    # Build deployment package
    npm install --production
    zip -r function.zip .

    # Deploy to Lambda
    ${pkgs.awscli2}/bin/aws lambda update-function-code \
      --function-name ${service.providerConfig.functionName} \
      --zip-file fileb://function.zip \
      --region ${service.providerConfig.region}

    # Update environment variables if configured
    ${lib.optionalString (envConfig.environmentVars or null != null) ''
      ${pkgs.awscli2}/bin/aws lambda update-function-configuration \
        --function-name ${service.providerConfig.functionName} \
        --environment Variables=${lib.concatStringsSep ","
          (lib.mapAttrsToList (k: v: "${k}=${v}") envConfig.environmentVars)} \
        --region ${service.providerConfig.region}
    ''}

    # Get function URL
    FUNCTION_URL=$(${pkgs.awscli2}/bin/aws lambda get-function-url-config \
      --function-name ${service.providerConfig.functionName} \
      --region ${service.providerConfig.region} \
      --query 'FunctionUrl' --output text 2>/dev/null || echo "")

    if [ -z "$FUNCTION_URL" ]; then
      FUNCTION_URL="https://lambda.${service.providerConfig.region}.amazonaws.com/2015-03-31/functions/${service.providerConfig.functionName}/invocations"
    fi

    echo "  Function URL: $FUNCTION_URL"
    echo "  ✓ Deployment successful"

    # Write outputs for dependent services
    mkdir -p ${config.git.root}/.saas-controller/outputs/${serviceName}
    cat > ${config.git.root}/.saas-controller/outputs/${serviceName}/${environment}.json <<EOF
    {
      "service": "${serviceName}",
      "environment": "${environment}",
      "provider": "aws-lambda",
      "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
      "outputs": {
        "functionUrl": "$FUNCTION_URL",
        "functionName": "${service.providerConfig.functionName}",
        "region": "${service.providerConfig.region}"
      },
      "metadata": {
        "deployedBy": "''${USER:-unknown}",
        "gitCommit": "$(git rev-parse HEAD 2>/dev/null || echo unknown)",
        "gitBranch": "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
      }
    }
    EOF
  '';
}
```

### 2. Register Provider

**File: `devenv.nix` (in your project root)**

```nix
{
  imports = [
    # Import SaaS Controller module
    ./shared/modules/saas-controller
  ];

  saas-controller = {
    # Register external provider
    externalProviders = {
      aws-lambda = ./providers/aws-lambda.nix;
    };

    # Use it immediately!
    services.my-api = {
      enable = true;
      displayName = "My Serverless API";
      provider = "aws-lambda";  # ← Your custom provider

      providerConfig = {
        functionName = "my-api-function";
        region = "us-west-2";
        iamRole = "arn:aws:iam::123456789012:role/lambda-role";
        path = "services/my-api";
      };

      environments = {
        development = {
          enable = true;
          branch = "main";
        };

        production = {
          enable = true;
          branch = "main";
          autodeploy = false;

          providerEnvConfig = {
            environmentVars = {
              LOG_LEVEL = "info";
              API_TIMEOUT = "30000";
            };
          };
        };
      };
    };
  };
}
```

### 3. Deploy

```bash
# Provision the Lambda function (one-time)
provision-projects

# Deploy to development
sc deploy my-api -e development

# Deploy to production
sc deploy my-api -e production
```

## Example: Cloudflare Workers Provider

**File: `providers/cloudflare-workers.nix`**

```nix
{ pkgs, lib, config }:

{
  provisionProject = serviceName: service: ''
    echo "  Cloudflare Workers project: ${service.providerConfig.name}"
    echo "  Account ID: ${service.providerConfig.accountId}"
    echo "  ✓ No project-level setup needed"
  '';

  deploy = serviceName: service: environment: envConfig: profile: provider: ''
    echo "  Deploying ${service.providerConfig.name} to ${environment}"

    cd ${config.git.root}/${service.providerConfig.path}

    # Deploy using Wrangler
    ${pkgs.nodePackages.wrangler}/bin/wrangler publish \
      --name ${service.providerConfig.name}-${environment} \
      --env ${environment}

    # Get worker URL
    WORKER_URL="https://${service.providerConfig.name}-${environment}.${service.providerConfig.accountId}.workers.dev"

    echo "  Worker URL: $WORKER_URL"
    echo "  ✓ Deployment successful"

    # Write outputs
    mkdir -p ${config.git.root}/.saas-controller/outputs/${serviceName}
    cat > ${config.git.root}/.saas-controller/outputs/${serviceName}/${environment}.json <<EOF
    {
      "service": "${serviceName}",
      "environment": "${environment}",
      "provider": "cloudflare-workers",
      "outputs": {
        "workerUrl": "$WORKER_URL",
        "workerName": "${service.providerConfig.name}-${environment}"
      }
    }
    EOF
  '';
}
```

**Usage:**

```nix
saas-controller = {
  externalProviders.cloudflare-workers = ./providers/cloudflare-workers.nix;

  services.my-edge-function = {
    enable = true;
    provider = "cloudflare-workers";
    providerConfig = {
      name = "my-edge-fn";
      accountId = "abc123";
      path = "services/edge-fn";
    };
  };
};
```

## Example: Custom Hook Provider

Hook providers run before or after deployments (like secretspec, frontegg, datadog).

**File: `providers/slack-notify.nix`**

```nix
{ pkgs, lib, config }:

{
  # Hook providers use the 'provision' interface
  provision = serviceName: provisionConfig: servicePath: environment: serviceConfig: ''
    echo "  📢 Sending Slack notification for ${serviceName}/${environment}"

    # Get deployment info from task outputs (if available)
    if [ -n "$DEVENV_TASKS_OUTPUTS" ] && [ "$DEVENV_TASKS_OUTPUTS" != "null" ]; then
      DEPLOY_URL=$(echo "$DEVENV_TASKS_OUTPUTS" | ${pkgs.jq}/bin/jq -r \
        '.["saas-deploy:${serviceName}"].outputs.gatewayUrl // .["saas-deploy:${serviceName}"].outputs.appUrl // empty')
    fi

    # Send Slack message
    ${pkgs.curl}/bin/curl -X POST ${provisionConfig.webhookUrl} \
      -H 'Content-Type: application/json' \
      -d @- <<EOF
    {
      "text": "🚀 Deployed ${serviceName} to ${environment}",
      "blocks": [
        {
          "type": "section",
          "text": {
            "type": "mrkdwn",
            "text": "*Deployment Complete*\n• Service: ${serviceName}\n• Environment: ${environment}\n''${DEPLOY_URL:+• URL: $DEPLOY_URL}"
          }
        }
      ]
    }
    EOF

    echo "  ✓ Notification sent"
  '';

  # Unused for hook providers, but required for interface compatibility
  provisionProject = _: _: "";
  deploy = _: _: _: _: _: _: "";
}
```

**Usage as post-deploy hook:**

```nix
saas-controller = {
  externalProviders.slack-notify = ./providers/slack-notify.nix;

  services.my-api = {
    provider = "zuplo";
    # ... other config ...

    deploy.postHooks = [
      {
        type = "slack-notify";
        config = {
          webhookUrl = "https://hooks.slack.com/services/YOUR/WEBHOOK/URL";
        };
      }
    ];
  };
};
```

## Advanced: Multi-Package Providers

For providers that need additional packages:

```nix
{ pkgs, lib, config }:

let
  # Include any custom packages needed
  terraform = pkgs.terraform;
  awscli = pkgs.awscli2;
in
{
  provisionProject = serviceName: service: ''
    ${terraform}/bin/terraform init
    ${terraform}/bin/terraform apply -auto-approve
    # ...
  '';

  # ... rest of provider
}
```

## Provider Discovery & Testing

### List Available Providers

The runtime assertions will show all available providers if you use an invalid one:

```bash
# This will fail with a helpful message listing all providers
sc deploy my-service
# Error: Service "my-service" uses unknown provider "typo".
# Available providers: zuplo, frontegg, datadog, secretspec-export, aws-lambda, cloudflare-workers
```

### Test Your Provider

```bash
# 1. Provision (test provisionProject)
provision-projects

# 2. Deploy to local/dev (test deploy)
sc deploy my-service -e development

# 3. Check outputs
cat .saas-controller/outputs/my-service/development.json | jq .
```

## Best Practices

1. **Write deployment outputs** - Other services may depend on your provider's outputs
2. **Use `${config.git.root}`** - Always reference paths relative to git root
3. **Handle errors gracefully** - Use `set -e` and provide clear error messages
4. **Document providerConfig** - Add comments showing required/optional fields
5. **Support multiple environments** - Use `envConfig` for environment-specific settings
6. **Leverage control plane secrets** - The wrapper provides secrets automatically
7. **Test incrementally** - Start with `provisionProject`, then add `deploy`

## Troubleshooting

### "Unknown provider" error

Make sure the provider is registered:

```nix
saas-controller.externalProviders.my-provider = ./providers/my-provider.nix;
```

### Provider file not found

Paths can be:
- Relative: `./providers/my-provider.nix`
- Absolute: `/path/to/my-provider.nix`
- From inputs: `inputs.my-providers.providers.aws`

### Task fails silently

Check `.saas-controller/outputs/` for error logs. Add `set -e` to fail fast.

## Contributing Providers

Consider upstreaming useful providers to the SaaS Controller repository:

1. Submit to `providers/`
2. Add documentation
3. Include examples
4. Add to builtin providers list

## More Examples

See the builtin providers for reference:
- `providers/zuplo.nix` - Full-featured deployment provider
- `providers/frontegg.nix` - Hook provider with dependency handling
- `providers/datadog.nix` - API integration example
- `providers/secretspec-export.nix` - Secret management provider

---

# Extending with Custom Runtimes

Runtimes control **how** processes are managed (start, stop, log streaming). They are independent of network exposure, which is handled by network strategies.

## Runtime Interface

A runtime module must export:

```nix
{ pkgs, lib }:

{
  name = "my-runtime";
  description = "Human-readable description";
  requiredPackages = [ ]; # Added to devenv packages

  # Returns a writeShellScriptBin derivation
  mkScript = { serviceName, service, variant, command, workingDir, config
              , networkSetup, networkCleanup, networkPrintUrl }:
    pkgs.writeShellScriptBin "dev-serve-${serviceName}-${variant}" ''
      set -euo pipefail

      # 1. Start process and set $PORT
      export PORT=$(allocate-port-somehow)

      # 2. Register cleanup
      cleanup() {
        ${networkCleanup}
        # stop your process
      }
      trap cleanup EXIT INT TERM

      # 3. Network setup (must come after $PORT is set)
      ${networkSetup}
      ${networkPrintUrl}

      # 4. Stream logs (blocking)
      tail -f /path/to/logs
    '';
}
```

## Contract

Your `mkScript` must:

1. **Set `$PORT`** before calling `networkSetup`
2. **Call `networkSetup`** to register the port and set `$DEVSERVER_URL`
3. **Call `networkPrintUrl`** to output the URL
4. **Register a trap** that calls `networkCleanup`
5. **Stream logs** to stdout/stderr (blocking)
6. **Exit non-zero** if the service dies unexpectedly

## Registration

```nix
saas-controller = {
  externalRuntimes.my-runtime = ./runtimes/my-runtime.nix;
  defaultRuntime = "my-runtime";  # or per-service override
};
```

## Template

Copy `runtimes/TEMPLATE.nix` for a full starting point with documented placeholders.

## Built-in Runtimes

| Runtime | Status | Description |
|---------|--------|-------------|
| `dev-manager-mcp` | Production | mcporter daemon with dynamic port allocation |
| `docker-compose` | Stub | Container-based process management |
| `launchd` | Stub | macOS persistent daemon (survives terminal close) |

---

# Extending with Custom Networks

Networks control **where** services are exposed. They provide bash snippet strings that runtimes inject at the right lifecycle points.

## Network Interface

A network module must export:

```nix
{ pkgs, lib }:

{
  name = "my-network";
  description = "Human-readable description";
  requiredPackages = [ ];

  # Called after $PORT is set. Must set $DEVSERVER_URL.
  setup = ''
    DEVSERVER_URL="https://my-tunnel.example.com:$PORT"
    register-tunnel "$PORT" || true
  '';

  # Called in trap handler (deregister).
  cleanup = ''
    deregister-tunnel "$PORT" 2>/dev/null || true
  '';

  # Echo the URL.
  printUrl = ''
    echo "DEVSERVER_URL: $DEVSERVER_URL"
  '';
}
```

## Registration

```nix
saas-controller = {
  externalNetworks.my-network = ./networks/my-network.nix;
  defaultNetwork = "my-network";  # or per-service override
};
```

## Built-in Networks

| Network | Description |
|---------|-------------|
| `tailscale` | HTTPS on the tailnet via `tailscale serve` |
| `localhost` | Local-only access on 127.0.0.1 |

## Example: ngrok Network

```nix
{ pkgs, lib }:

{
  name = "ngrok";
  description = "Public HTTPS tunnel via ngrok";
  requiredPackages = [ pkgs.ngrok ];

  setup = ''
    # Start ngrok in background
    ${pkgs.ngrok}/bin/ngrok http "$PORT" --log=stdout > /tmp/ngrok-${serviceName}.log 2>&1 &
    NGROK_PID=$!
    sleep 2
    DEVSERVER_URL=$(curl -s http://localhost:4040/api/tunnels | ${pkgs.jq}/bin/jq -r '.tunnels[0].public_url')
  '';

  cleanup = ''
    kill $NGROK_PID 2>/dev/null || true
  '';

  printUrl = ''
    echo "DEVSERVER_URL: $DEVSERVER_URL"
  '';
}
```
- `providers/datadog.nix` - API integration example
- `providers/secretspec-export.nix` - Secret management provider

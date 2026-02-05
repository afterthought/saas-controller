# Extending SaaS Controller with External Providers

SaaS Controller supports external provider registration, allowing teams to add support for new cloud platforms without modifying the core module.

## Hello World Example

A built-in `hello-world` provider is included for testing `sc up` end-to-end. Add this to your project's `devenv.nix`:

```nix
saas-controller = {
  services.hello-world = {
    enable = true;
    provider = "hello-world";
    providerConfig.path = "examples/hello-world";
    environments.local.enable = true;
  };
};
```

Then run:

```bash
sc up              # starts the hello-world server via docker-compose
sc up hello-world  # start specific service
```

The provider generates a docker-compose stack that bind-mounts the source and runs `node server.mjs`. Source is in `examples/hello-world/server.mjs`.

## Quick Start

1. **Create a provider module** following the provider interface
2. **Register it** via `saas-controller.externalProviders`
3. **Use it** in your service configurations

## Provider Interface

A provider module must export functions matching this interface:

```nix
{ pkgs, lib, config }:

{
  # Optional: Local dev lifecycle via docker-compose
  # Called by: sc up <service>
  # Returns bash script that generates compose files, starts stack, cleans up on exit
  up = serviceName: service:
    let
      composeDir = "${config.git.root}/.saas-controller/compose/${serviceName}";
      sourceDir = "${config.git.root}/${service.providerConfig.path}";
    in
    ''
      set -euo pipefail
      COMPOSE_DIR="${composeDir}"
      mkdir -p "$COMPOSE_DIR"

      # Generate Dockerfile and docker-compose.yml
      cat > "$COMPOSE_DIR/Dockerfile" <<'DOCKERFILE'
      FROM node:22
      WORKDIR /app
      DOCKERFILE

      cat > "$COMPOSE_DIR/docker-compose.yml" <<COMPOSEFILE
      services:
        my-service:
          build: { context: ., dockerfile: Dockerfile }
          volumes:
            - ${sourceDir}:/app
          ports:
            - "3000:3000"
          command: ["node", "server.mjs"]
      COMPOSEFILE

      export DEVSERVER_URL="http://localhost:3000"
      echo "DEVSERVER_URL: $DEVSERVER_URL"

      cleanup() {
        docker compose -f "$COMPOSE_DIR/docker-compose.yml" down 2>/dev/null || true
      }
      trap cleanup EXIT INT TERM

      docker compose -f "$COMPOSE_DIR/docker-compose.yml" up --build
    '';

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

### Writing provider up() with docker-compose

The `up()` function returns a bash script string that owns the full local dev lifecycle:

1. **Create compose directory**: `.saas-controller/compose/${serviceName}/`
2. **Generate Dockerfile**: Base image, dependencies, working directory
3. **Generate docker-compose.yml**: Services, volumes, ports, environment
4. **Print DEVSERVER_URL**: For VibeKanban URL capture
5. **Register cleanup trap**: `docker compose down` on EXIT/INT/TERM
6. **Start stack**: `docker compose up --build` in foreground

For composite services (multiple processes), define multiple services in the compose file:

```nix
up = serviceName: service:
  let
    composeDir = "${config.git.root}/.saas-controller/compose/${serviceName}";
    sourceDir = "${config.git.root}/${service.providerConfig.path}";
  in
  ''
    # ...mkdir, Dockerfile generation...

    cat > "$COMPOSE_DIR/docker-compose.yml" <<COMPOSEFILE
    services:
      api:
        build: { context: ., dockerfile: Dockerfile }
        volumes:
          - ${sourceDir}:/app
          - /app/node_modules
        ports:
          - "3000:3000"
        command: ["npx", "my-tool", "dev", "--port", "3000"]

      docs:
        build: { context: ., dockerfile: Dockerfile }
        volumes:
          - ${sourceDir}:/app
          - /app/node_modules
        ports:
          - "3001:3001"
        command: ["npx", "my-tool", "docs", "--port", "3001"]
    COMPOSEFILE

    # ...DEVSERVER_URL, trap, docker compose up...
  '';
```

Key patterns:
- **Bind-mount source** at `/app` for live reload
- **Anonymous volume** for `node_modules` to preserve installed dependencies
- **Compose default network** enables inter-service communication
- **Bash heredocs** with Nix string interpolation for runtime values

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

    echo "  ✓ Deployment successful"

    # Write outputs for dependent services
    mkdir -p ${config.git.root}/.saas-controller/outputs/${serviceName}
    cat > ${config.git.root}/.saas-controller/outputs/${serviceName}/${environment}.json <<EOF
    {
      "service": "${serviceName}",
      "environment": "${environment}",
      "provider": "aws-lambda",
      "outputs": {
        "functionName": "${service.providerConfig.functionName}",
        "region": "${service.providerConfig.region}"
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
      -d '{"text": "🚀 Deployed ${serviceName} to ${environment}"}'

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

## Provider Discovery & Testing

### List Available Providers

The runtime assertions will show all available providers if you use an invalid one:

```bash
# This will fail with a helpful message listing all providers
sc deploy my-service
# Error: Service "my-service" uses unknown provider "typo".
# Available providers: zuplo, frontegg, datadog, secretspec-export, aws-lambda
```

### Test Your Provider

```bash
# 1. Provision (test provisionProject)
provision-projects

# 2. Test local dev (test up)
sc up my-service

# 3. Deploy to dev (test deploy)
sc deploy my-service -e development

# 4. Check outputs
cat .saas-controller/outputs/my-service/development.json | jq .
```

## Best Practices

1. **Write deployment outputs** - Other services may depend on your provider's outputs
2. **Use `${config.git.root}`** - Always reference paths relative to git root
3. **Handle errors gracefully** - Use `set -e` and provide clear error messages
4. **Document providerConfig** - Add comments showing required/optional fields
5. **Support multiple environments** - Use `envConfig` for environment-specific settings
6. **Leverage control plane secrets** - The wrapper provides secrets automatically
7. **Test incrementally** - Start with `provisionProject`, then add `deploy`, then `up`
8. **Bind-mount source** in `up()` for live reload during local development
9. **Use anonymous volumes** for `node_modules` to avoid overwriting installed deps

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

## More Examples

See the builtin providers for reference:
- `providers/hello-world.nix` - Minimal provider with single-service docker-compose `up()`
- `providers/zuplo.nix` - Full-featured provider with composite two-service `up()`
- `providers/frontegg.nix` - Hook provider with dependency handling
- `providers/datadog.nix` - API integration example
- `providers/secretspec-export.nix` - Secret management provider
- `providers/TEMPLATE.nix` - Starting point with documented placeholders

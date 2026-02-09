{ pkgs, lib, config, ... }:

let
  # Import builtin provider adapters
  builtinProviders = {
    # Main providers (for running/deploying services)
    zuplo = import ./providers/zuplo.nix { inherit pkgs lib config; };

    # Provision providers (for setting up services)
    secretspec = import ./providers/secretspec-export.nix { inherit pkgs lib config; };
    frontegg = import ./providers/frontegg.nix { inherit pkgs lib config; };
    datadog = import ./providers/datadog.nix { inherit pkgs lib config; };

    # Example provider for testing sc up / dev-serve
    hello-world = import ./providers/hello-world.nix { inherit pkgs lib config; };

    # Legacy provider names for backward compatibility
    secretspec-export = import ./providers/secretspec-export.nix { inherit pkgs lib config; };
  };

  # Load external providers from configuration
  # External teams can register their own providers without modifying this module
  externalProviders = lib.mapAttrs
    (name: path: import path { inherit pkgs lib config; })
    config.saas-controller.externalProviders;

  # Merge builtin and external providers (external can override builtin if needed)
  providers = builtinProviders // externalProviders;

  # Collect secret profiles contributed by providers
  # Providers can optionally export a secretProfiles attrset
  providerSecretProfiles = lib.foldlAttrs
    (acc: _name: provider:
      if provider ? secretProfiles then acc // provider.secretProfiles else acc
    )
    { }
    providers;

  # Import task helpers
  helpers = import ./lib/helpers.nix { inherit pkgs lib config providers; };

  # Import dependency validation
  depValidator = import ./lib/dependencies.nix { inherit lib config; };
in
{
  # Controller-level options
  options.saas-controller = {
    # Secret profiles: Named sets of secrets composable per-service per-environment
    secretProfiles = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf (lib.types.submodule {
        options = {
          description = lib.mkOption {
            type = lib.types.str;
            description = "Human-readable description of this secret";
          };

          required = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether this secret is required (default: true)";
          };

          providers = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "List of secretspec providers that can supply this secret";
          };
        };
      }));
      default = {
        tailscale = {
          TS_CLIENT_SECRET = { description = "Tailscale OAuth client secret for ephemeral node creation"; providers = [ "saas-controller" ]; };
          TS_CLIENT_ID = { description = "Tailscale OAuth client ID"; required = false; providers = [ "saas-controller" ]; };
          SC_TAILNET = { description = "Tailnet MagicDNS suffix, e.g. my-tailnet.ts.net (auto-detected if host tailscale installed)"; required = false; providers = [ "saas-controller" ]; };
        };
      };
      description = ''
        Named secret profiles defined at the controller level.
        Each profile maps secret names to their definitions (description, required, providers).
        Services reference these profiles in their secretspec.environments configuration.

        Providers can register default profiles (e.g., zuplo.nix adding "zuplo-backend").
        Consumers can extend or override profiles using standard nix merging (lib.mkMerge, lib.mkForce).
      '';
      example = lib.literalExpression ''
        {
          tailscale = {
            TS_CLIENT_SECRET = { description = "Tailscale OAuth client secret"; providers = [ "saas-controller" ]; };
            TS_CLIENT_ID = { description = "Tailscale OAuth client ID"; required = false; providers = [ "saas-controller" ]; };
          };
          zuplo-backend = {
            ZUPLO_API_KEY = { description = "Zuplo API key for deployments"; providers = [ "saas-controller" ]; };
          };
        }
      '';
    };

    # Release channel definitions
    releaseChannels = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          enable = lib.mkEnableOption "this release channel";

          displayName = lib.mkOption {
            type = lib.types.str;
            default = name;
            description = "Human-readable channel name";
            example = "Stable Production";
          };

          description = lib.mkOption {
            type = lib.types.str;
            description = ''
              Purpose and audience of this channel.
              Explains who uses this channel and what it's for.
            '';
            example = "Production releases for all customers";
          };

          autodeploy = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Automatically deploy on git push to configured branch.

              - true: CI/CD triggers deployment automatically
              - false: Requires manual deployment via CLI/API

              This is a channel-level policy that applies to ALL system instances
              using this channel. Services inherit this behavior.
            '';
          };

          versionPattern = lib.mkOption {
            type = lib.types.enum [ "tagged" "latest" "branch" ];
            default = "tagged";
            description = ''
              Version source for deployments:

              - tagged: Semantic version tags (v1.2.3, v2.0.0)
              - latest: Latest commit on main branch
              - branch: Any branch (feature branches, development branches)

              This determines what git references are valid for this channel.
            '';
          };

          audience = lib.mkOption {
            type = lib.types.enum [ "all" "internal" "beta" "sandbox" ];
            default = "all";
            description = ''
              Target audience for this channel:

              - all: All customers (production)
              - internal: Internal users only (company employees)
              - beta: Beta program participants
              - sandbox: Development/testing only (ephemeral environments)
            '';
          };

          deploymentPolicy = lib.mkOption {
            type = lib.types.submodule {
              options = {
                requiresApproval = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = ''
                    Require manual approval before deployment.
                    If true, deployment commands will prompt for confirmation.
                  '';
                };

                canaryDuration = lib.mkOption {
                  type = lib.types.nullOr lib.types.int;
                  default = null;
                  description = ''
                    Minimum canary duration in hours before promotion to stable.
                    Only applicable for canary channels.
                    null means no minimum duration.
                  '';
                };

                rollbackOnError = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  description = ''
                    Automatically rollback on deployment failure.
                    If false, failed deployments remain in place for debugging.
                  '';
                };

                healthCheckTimeout = lib.mkOption {
                  type = lib.types.int;
                  default = 300;
                  description = ''
                    Health check timeout in seconds after deployment.
                    Deployment is considered failed if health checks don't pass within this time.
                  '';
                };
              };
            };
            default = { };
            description = ''
              Deployment policies and safeguards for this channel.
              These policies are enforced during deployment operations.
            '';
          };

          metadata = lib.mkOption {
            type = lib.types.attrs;
            default = { };
            description = ''
              Additional channel-specific metadata.
              Can be used for custom tooling, monitoring, or documentation.
            '';
            example = {
              sla = "99.9%";
              support_tier = "24/7";
              region = "us-west-2";
            };
          };
        };
      }));
      default = {
        # Standard release channels with sensible defaults
        stable = {
          enable = true;
          displayName = "Stable Production";
          description = "Production releases for all customers";
          autodeploy = false;
          versionPattern = "tagged";
          audience = "all";
          deploymentPolicy = {
            requiresApproval = true;
            canaryDuration = 48;
            rollbackOnError = true;
            healthCheckTimeout = 600;
          };
        };

        canary = {
          enable = true;
          displayName = "Canary Pre-Production";
          description = "Pre-production testing before stable release";
          autodeploy = true;
          versionPattern = "latest";
          audience = "internal";
          deploymentPolicy = {
            requiresApproval = false;
            rollbackOnError = true;
            healthCheckTimeout = 300;
          };
        };

        beta = {
          enable = true;
          displayName = "Beta Feature Preview";
          description = "Feature preview for beta program participants";
          autodeploy = true;
          versionPattern = "branch";
          audience = "beta";
          deploymentPolicy = {
            requiresApproval = false;
            rollbackOnError = true;
          };
        };

        sandbox = {
          enable = true;
          displayName = "Development Sandbox";
          description = "Development and testing environment";
          autodeploy = true;
          versionPattern = "branch";
          audience = "sandbox";
          deploymentPolicy = {
            requiresApproval = false;
            rollbackOnError = false;
            healthCheckTimeout = 60;
          };
        };
      };
      description = ''
        Release channel definitions (deployment streams).

        Channels define deployment policies that are inherited by
        system instances referencing them. This provides a centralized
        way to manage deployment behavior across all tenants.

        Standard channels (stable, canary, beta, sandbox) are provided
        by default but can be customized or extended with additional channels.
      '';
    };

    # External provider registration
    externalProviders = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      description = ''
        External provider modules to register with the SaaS controller.
        Keys are provider names, values are paths to provider .nix files.

        This allows external teams to extend SaaS Controller with custom providers
        without modifying the core module. External providers have the same interface
        as builtin providers and can be used in service configurations immediately.

        Provider modules must export functions matching the provider interface:
        - provisionProject: One-time project setup
        - deploy: Environment deployment logic
        - provision (for hook providers): Hook execution logic
      '';
      example = lib.literalExpression ''
        {
          aws-lambda = ./providers/aws-lambda.nix;
          azure-functions = ../my-providers/azure.nix;
          cloudflare-workers = /absolute/path/to/cloudflare.nix;
        }
      '';
    };

    # Service catalog
    services = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          enable = lib.mkEnableOption "this service";

          displayName = lib.mkOption {
            type = lib.types.str;
            default = name;
            description = "Human-readable service name";
            example = "Atlas3 Developer Gateway";
          };

          provider = lib.mkOption {
            type = lib.types.str;
            description = ''
              Cloud provider for this service.
              Can be a builtin provider (zuplo, frontegg) or an external provider
              registered via saas-controller.externalProviders.
            '';
            example = "zuplo";
          };

          providerConfig = lib.mkOption {
            type = lib.types.attrs;
            description = "Provider-specific configuration";
            example = {
              project = "atlas3-dev";
              account = "willdan";
              path = "dev-portals/atlas3-dev";
            };
          };

          environments = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule {
              options = {
                enable = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  description = "Enable this environment";
                };

                branch = lib.mkOption {
                  type = lib.types.str;
                  default = "main";
                  description = "Git branch that triggers this environment";
                };

                autodeploy = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = "Automatically deploy on git push";
                };

                branchPattern = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Pattern for dynamic PR environments";
                  example = "feature/*";
                };

                # SecretSpec export configuration (push secrets TO the provider)
                # Profile is automatically derived from environment name
                secretspec_provider = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = ''
                    Secret storage provider alias for this environment (e.g., "saas-controller").
                    Profile is automatically set to the environment name.
                    Set to null to skip secret export for this environment.
                  '';
                  example = "saas-controller";
                };

                # Provider-specific environment config
                providerEnvConfig = lib.mkOption {
                  type = lib.types.attrs;
                  default = { };
                  description = "Provider-specific environment configuration";
                  example = {
                    appName = "atlas3-edge"; # Frontegg-specific
                    # For Zuplo local environment:
                    ports = { docs = 3000; api = 9000; designer = 9100; };
                    hostnames = { docs = "atlas-docs.localhost"; api = "atlas-api.localhost"; designer = "atlas-designer.localhost"; };
                  };
                };

                skipSecretExport = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = "Skip secret export hooks for this environment (e.g., for preview/ephemeral environments)";
                };
              };
            });
            default = { };
            description = "Environment definitions";
            example = {
              development = {
                enable = true;
                branch = "main";
                secretspec = {
                  provider = "saas-controller";
                  profile = "development";
                };
              };
              edge = {
                enable = true;
                branch = "main";
                autodeploy = true;
                secretspec_provider = "saas-controller"; # Uses "edge" as profile
              };
              production = {
                enable = true;
                branch = "main";
                autodeploy = false;
                secretspec_provider = "saas-controller"; # Uses "production" as profile
              };
            };
          };

          dependencies = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "List of service names this service depends on";
            example = [ "atlas3-dev-gateway" ];
          };

          # Deploy configuration with pre/post hooks
          deploy = lib.mkOption {
            type = lib.types.submodule {
              options = {
                preHooks = lib.mkOption {
                  type = lib.types.listOf (lib.types.submodule {
                    options = {
                      type = lib.mkOption {
                        type = lib.types.str;
                        description = ''
                          Type of pre-deploy hook provider.
                          Can be a builtin hook provider (secretspec, frontegg, datadog)
                          or an external provider registered via saas-controller.externalProviders.
                        '';
                      };

                      config = lib.mkOption {
                        type = lib.types.attrs;
                        default = { };
                        description = "Hook-specific configuration";
                      };
                    };
                  });
                  default = [ ];
                  description = ''
                    Array of pre-deploy hooks to run before deployment.
                    Hooks run in the order defined here, before the actual deployment.
                    Typical use: export secrets, validate configuration.

                    SecretSpec hooks support include/exclude filters for selective secret export:
                    - include: Glob pattern to include only matching secrets (e.g., "ZUDOKU_PUBLIC_*")
                    - exclude: Glob pattern to exclude matching secrets (e.g., "ZUDOKU_PUBLIC_*")
                    Supported patterns: prefix (FOO*), suffix (*FOO), contains (*FOO*), exact match
                  '';
                  example = [
                    # Hook 1: Export backend secrets (exclude public vars)
                    {
                      type = "secretspec";
                      config = {
                        secretSource = "saas-controller";
                        secretTarget = "zuplo://atlas3-dev/main";
                        exclude = "ZUDOKU_PUBLIC_*";
                      };
                    }
                    # Hook 2: Export frontend vars as non-secrets
                    {
                      type = "secretspec";
                      config = {
                        secretSource = "saas-controller";
                        secretTarget = "zuplo://atlas3-dev/main?is-secret=false";
                        include = "ZUDOKU_PUBLIC_*";
                      };
                    }
                  ];
                };

                postHooks = lib.mkOption {
                  type = lib.types.listOf (lib.types.submodule {
                    options = {
                      type = lib.mkOption {
                        type = lib.types.str;
                        description = ''
                          Type of post-deploy hook provider.
                          Can be a builtin hook provider (secretspec, frontegg, datadog)
                          or an external provider registered via saas-controller.externalProviders.
                        '';
                      };

                      config = lib.mkOption {
                        type = lib.types.attrs;
                        default = { };
                        description = "Hook-specific configuration";
                      };
                    };
                  });
                  default = [ ];
                  description = ''
                    Array of post-deploy hooks to run after deployment.
                    Hooks run in the order defined here, after the deployment completes.
                    Post-hooks receive deployment outputs via DEVENV_TASKS_OUTPUTS.
                    Typical use: register apps with deployment URL, sync to monitoring systems.
                  '';
                  example = [
                    {
                      type = "frontegg";
                      config = {
                        appName = "atlas3-dev";
                      };
                    }
                  ];
                };
              };
            };
            default = { preHooks = [ ]; postHooks = [ ]; };
            description = "Deploy configuration with pre and post hooks";
          };

          # Run configuration - secret sources for local development ('sc up')
          run = lib.mkOption {
            type = lib.types.submodule {
              options = {
                secretSource = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Default secret source provider for local development";
                  example = "saas-controller";
                };

                environments = lib.mkOption {
                  type = lib.types.attrsOf (lib.types.submodule {
                    options = {
                      secretSource = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        description = "Override secret source for this environment";
                      };
                    };
                  });
                  default = { };
                  description = "Per-environment secret source overrides";
                  example = {
                    local = { secretSource = "saas-controller"; };
                    edge = { secretSource = "saas-controller"; };
                  };
                };
              };
            };
            default = { secretSource = null; environments = { }; };
            description = "Run-time secret source configuration for local development";
          };

          # Per-service secretspec configuration for sc check-secrets
          secretspec = lib.mkOption {
            type = lib.types.nullOr (lib.types.submodule {
              options = {
                environments = lib.mkOption {
                  type = lib.types.attrsOf (lib.types.submodule {
                    options = {
                      serviceProfiles = lib.mkOption {
                        type = lib.types.listOf lib.types.str;
                        description = "List of secret profile names from saas-controller.secretProfiles to validate for this environment";
                        example = [ "tailscale" "zuplo-backend" ];
                      };
                    };
                  });
                  description = ''
                    Maps environment names to service profile selections.
                    Each environment specifies which secret profiles are required.
                  '';
                  example = lib.literalExpression ''
                    {
                      local = { serviceProfiles = [ "tailscale" ]; };
                      edge = { serviceProfiles = [ "zuplo-backend" ]; };
                    }
                  '';
                };

                tags = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                  description = "Tags for filtering: sc check-secrets --tag tailscale";
                  example = [ "tailscale" "backend" ];
                };
              };
            });
            default = null;
            description = ''
              Per-service secretspec configuration. When non-null, service participates in sc check-secrets.
              Defines which secret profiles are required per environment.
              Provider resolution uses the per-secret `providers` field from secretProfiles.
            '';
          };

          datadog = lib.mkOption {
            type = lib.types.nullOr (lib.types.submodule {
              options = {
                enable = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = "Enable Datadog Software Catalog sync";
                };

                syncOn = lib.mkOption {
                  type = lib.types.listOf (lib.types.enum [ "deploy" "on-demand" ]);
                  default = [ "deploy" ];
                  description = "When to sync to Datadog";
                };

                environments = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                  description = "Which environments to sync";
                  example = [ "production" ];
                };

                entityMapping = lib.mkOption {
                  type = lib.types.attrs;
                  default = { };
                  description = "Datadog entity mapping configuration";
                  example = {
                    kind = "service";
                    type = "http";
                    tier = "tier1";
                  };
                };
              };
            });
            default = null;
            description = "Datadog Software Catalog sync configuration";
          };
        };
      }));
      default = { };
      description = "Service catalog definitions";
    };

    # Secret export operations
    secret-exports = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          enable = lib.mkEnableOption "this secret export operation";

          displayName = lib.mkOption {
            type = lib.types.str;
            default = name;
            description = "Human-readable name for this secret export";
            example = "Atlas3 Dev Secrets";
          };

          provider = lib.mkOption {
            type = lib.types.str;
            default = "secretspec-export";
            description = ''
              Export provider for secret management.
              Can be a builtin provider (secretspec-export) or an external provider
              registered via saas-controller.externalProviders.
            '';
          };

          providerConfig = lib.mkOption {
            type = lib.types.submodule {
              options = {
                path = lib.mkOption {
                  type = lib.types.str;
                  description = "Path to the directory containing secretspec.toml";
                  example = "dev-portals/atlas3-dev";
                };

                target_provider = lib.mkOption {
                  type = lib.types.str;
                  description = ''
                    Target provider URL for secret export.
                    Format: <provider>://<project>/<branch> or just <provider>
                    Examples: "zuplo://atlas3-dev/main", "frontegg"
                  '';
                  example = "zuplo://atlas3-dev/main";
                };

                secretspec_provider = lib.mkOption {
                  type = lib.types.str;
                  description = "Default SecretSpec provider alias to read secrets from (can be overridden per environment)";
                  example = "saas-controller";
                };
              };
            };
            description = "Provider-specific configuration for secret export";
          };

          environments = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule {
              options = {
                enable = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  description = "Enable export for this environment";
                };

                secretspec_provider = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = ''
                    Override the default secretspec provider for this environment.
                    If null, uses the provider from providerConfig.
                  '';
                  example = "1password-cli";
                };
              };
            });
            default = { };
            description = ''
              Environments to export secrets to.
              Profile name is automatically set to the environment name (e.g., "local", "edge", "production").
            '';
          };

          dependencies = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Other secret-exports this operation depends on";
            example = [ "shared-secrets" ];
          };
        };
      }));
      default = { };
      description = "Secret export operations";
    };
  };

  config =
    let
      enabledServices = lib.filterAttrs (_: cfg: cfg.enable) config.saas-controller.services;
      anyServicesEnabled = enabledServices != { };

      enabledSecretExports = lib.filterAttrs (_: cfg: cfg.enable) config.saas-controller.secret-exports;
      anySecretExportsEnabled = enabledSecretExports != { };

      # Combined check: any SaaS operations enabled
      anySaasOperationsEnabled = anyServicesEnabled || anySecretExportsEnabled;

      # List of all registered providers (builtin + external)
      validProviders = lib.attrNames providers;

      # Collect all hook providers used across all services
      allHookProviders = lib.unique (lib.flatten (
        lib.mapAttrsToList
          (_: service:
            (map (hook: hook.type) service.deploy.preHooks) ++
            (map (hook: hook.type) service.deploy.postHooks)
          )
          config.saas-controller.services
      ));

      # Helper function to get environment list for a service
      getEnabledEnvironments = service:
        lib.filterAttrs (_: env: env.enable) service.environments;

      # Services with secretspec configuration (for sc check-secrets)
      secretspecServices = lib.filterAttrs
        (_: service: service.enable && service.secretspec != null)
        config.saas-controller.services;

      # Generate TOML content for a single secret entry
      mkSecretToml = secretName: secretDef:
        let
          descLine = "description = \"${secretDef.description}\"";
          reqLine = lib.optionalString (!secretDef.required) ", required = false";
          provLine = lib.optionalString (secretDef.providers != [ ])
            ", providers = [${lib.concatMapStringsSep ", " (p: "\"${p}\"") secretDef.providers}]";
        in
        "${secretName} = { ${descLine}${reqLine}${provLine} }";

      # Generate secretspec.toml content for a service
      mkServiceSecretspecToml = serviceName: secretspecCfg:
        let
          profiles = config.saas-controller.secretProfiles;

          # For each environment, collect the union of secrets from its serviceProfiles
          envSections = lib.concatStringsSep "\n\n" (lib.mapAttrsToList (envName: envCfg:
            let
              # Collect secrets from all service profiles for this environment
              # First profile wins on duplicate secret names
              collectSecrets = profileNames:
                let
                  addProfile = acc: profileName:
                    let
                      profileSecrets = profiles.${profileName} or { };
                      # Only add secrets not already in acc (first occurrence wins)
                      newSecrets = lib.filterAttrs (name: _: ! (acc ? ${name})) profileSecrets;
                    in
                    acc // newSecrets;
                in
                lib.foldl addProfile { } profileNames;

              secrets = collectSecrets envCfg.serviceProfiles;
              secretLines = lib.concatStringsSep "\n" (lib.mapAttrsToList mkSecretToml secrets);
            in
            ''
[profiles.${envName}]
${secretLines}''
          ) secretspecCfg.environments);
        in
        ''
[project]
name = "${serviceName}"
revision = "1.0"

${envSections}
'';

      # Generate all service secretspec TOML files
      generateAllServiceSecretspecs = ''
        mkdir -p ${config.git.root}/.saas-controller/secretspec
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (serviceName: service:
          let
            tomlContent = mkServiceSecretspecToml serviceName service.secretspec;
          in ''
            mkdir -p ${config.git.root}/.saas-controller/secretspec/${serviceName}
            cat > ${config.git.root}/.saas-controller/secretspec/${serviceName}/secretspec.toml <<'SECRETSPEC_EOF'
${tomlContent}
SECRETSPEC_EOF
            echo "  Generated secretspec for ${serviceName}"
          ''
        ) secretspecServices)}
      '';

    in
    {
      # Merge provider-contributed secret profiles into controller config
      # Providers declare profiles via secretProfiles attr (e.g., zuplo.nix → "zuplo" profile)
      # Uses mkDefault so consumers can override with explicit secretProfiles config
      saas-controller.secretProfiles = lib.mapAttrs
        (_profileName: secrets: lib.mapAttrs
          (_secretName: secretDef: lib.mkDefault secretDef)
          secrets
        )
        providerSecretProfiles;

      # Test service configuration (for local development/testing of the module)
      saas-controller.services.test-gateway = {
        enable = true;
        displayName = "Test Gateway";
        provider = "zuplo";
        providerConfig = {
          project = "test-gateway";
          account = "test";
          path = "examples/test-gateway";
        };
        environments = {
          local.enable = true;
        };
        secretspec = {
          environments = {
            local = { serviceProfiles = [ "tailscale" "zuplo" ]; };
          };
          tags = [ "tailscale" "zuplo" ];
        };
      };

      # Runtime assertions for provider validation
      assertions = lib.flatten [
        # Validate service providers
        (lib.mapAttrsToList
          (serviceName: service:
            {
              assertion = lib.elem service.provider validProviders;
              message = ''
                Service "${serviceName}" uses unknown provider "${service.provider}".
                Available providers: ${lib.concatStringsSep ", " validProviders}

                To use "${service.provider}", register it via:
                  saas-controller.externalProviders.${service.provider} = ./path/to/provider.nix;
              '';
            }
          )
          config.saas-controller.services)

        # Validate secret export providers
        (lib.mapAttrsToList
          (exportName: exportConfig:
            {
              assertion = lib.elem exportConfig.provider validProviders;
              message = ''
                Secret export "${exportName}" uses unknown provider "${exportConfig.provider}".
                Available providers: ${lib.concatStringsSep ", " validProviders}

                To use "${exportConfig.provider}", register it via:
                  saas-controller.externalProviders.${exportConfig.provider} = ./path/to/provider.nix;
              '';
            }
          )
          config.saas-controller.secret-exports)

        # Validate hook providers
        (map
          (hookProvider:
            {
              assertion = lib.elem hookProvider validProviders;
              message = ''
                Hook provider "${hookProvider}" is not registered.
                Available providers: ${lib.concatStringsSep ", " validProviders}

                To use "${hookProvider}", register it via:
                  saas-controller.externalProviders.${hookProvider} = ./path/to/provider.nix;
              '';
            }
          )
          allHookProviders)
      ];

      # Add required packages if any SaaS operations are enabled
      packages = lib.mkIf anySaasOperationsEnabled (with pkgs; [
        jq # JSON processing
        curl # HTTP requests (Datadog API, etc.)
        secretspec # Secret management
        _1password-cli # 1Password integration
        config.languages.javascript.package # Use configured Node.js version
      ]);
      # Override secretspec with custom fork that supports export-plus-providers
      # Includes --include/--exclude filter flags for selective secret export
      overlays = [
        (final: prev: {
          secretspec = prev.rustPlatform.buildRustPackage {
            pname = "secretspec";
            version = "feature/export-plus-providers";

            src = prev.fetchFromGitHub {
              owner = "afterthought";
              repo = "secretspec";
              rev = "8744fa95231dff445ef9f0851f45d56319d8c330";
              sha256 = "sha256-oHUe77vIn9+kLswPvivxFS+/DLZswYCjzIwrUf0ZyT0=";
            };

            cargoLock = {
              lockFile = "${final.secretspec.src}/Cargo.lock";
            };

            # Build dependencies for dbus-sys crate
            nativeBuildInputs = [ prev.pkg-config ];
            buildInputs = [ prev.dbus ];

            meta = with prev.lib; {
              description = "SecretSpec CLI (custom fork with export-plus-providers and filter flags)";
              homepage = "https://github.com/afterthought/secretspec";
            };
          };
        })
      ];

      # Enable 1Password biometric unlock
      env = lib.mkIf anySaasOperationsEnabled {
        OP_BIOMETRIC_UNLOCK_ENABLED = "true";
      };

      # Shell initialization
      enterShell = lib.mkIf anySaasOperationsEnabled ''
        # Create outputs directory for task results
        mkdir -p .saas-controller/outputs
      '';

      # Generate orchestration scripts
      scripts = lib.mkIf anySaasOperationsEnabled {
        # Script: provision-projects
        # One-time project/account creation across all providers
        provision-projects = {
          description = "Create all top-level projects (one-time setup)";
          exec = ''
            echo "🚀 Provisioning projects for all services..."
            echo ""

            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: service:
              let
                provider = providers.${service.provider};
                provisionCmd = provider.provisionProject name service;
              in ''
                echo "📦 Provisioning project: ${name} (${service.provider})"
                bash -c ${lib.escapeShellArg provisionCmd}
                echo ""
              ''
            ) enabledServices)}

            echo "✅ All projects provisioned successfully"
          '';
        };


        # Script: deploy-environment <environment>
        # Deploy all services to environment using tasks
        # Dependencies are automatically handled by devenv task system
        deploy-environment = {
          description = "Deploy all services to environment (usage: deploy-environment <env>)";
          exec = ''
            ENVIRONMENT="''${1:-}"

            if [ -z "$ENVIRONMENT" ]; then
              echo "❌ Error: Environment name required"
              echo "Usage: deploy-environment <environment>"
              echo ""
              echo "Available environments:"
              ${lib.concatStringsSep "\n              echo \"  - " (lib.unique (lib.flatten (lib.mapAttrsToList (_: service:
                lib.attrNames (getEnabledEnvironments service)
              ) enabledServices)))}\"
              exit 1
            fi

            echo "🚀 Deploying all services to: ''${ENVIRONMENT}"
            echo ""

            # Call post-deploy tasks with JSON input via environment variable
            # This will automatically run pre-deploy → deploy → post-deploy
            # Task dependencies are automatically handled by devenv (--mode before)
            ${lib.concatStringsSep "\n            " (lib.mapAttrsToList (name: service: ''
              echo "▶ Deploying: ${name}"
              DEVENV_TASK_INPUT="{\"environment\": \"''${ENVIRONMENT}\"}" ${pkgs.devenv}/bin/devenv tasks run --mode before saas-post-deploy:${name} || {
                echo "❌ Deployment failed: ${name}"
                exit 1
              }
              echo ""
            '') enabledServices)}

            echo "✅ All services deployed to ''${ENVIRONMENT}"
          '';
        };

        # Script: sync-datadog <environment>
        # Sync service metadata to Datadog Software Catalog
        sync-datadog = {
          description = "Sync service metadata to Datadog Software Catalog (usage: sync-datadog <env>)";
          exec = ''
            ENVIRONMENT="''${1:-production}"

            echo "📊 Syncing service metadata to Datadog for environment: ''${ENVIRONMENT}"
            echo ""

            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: service:
              lib.optionalString (service.datadog != null && service.datadog.enable) ''
                # Check if this environment should be synced
                if [[ " ${lib.concatStringsSep " " service.datadog.environments} " =~ " ''${ENVIRONMENT} " ]]; then
                  echo "🔄 Syncing ${name} to Datadog..."
                  ${providers.datadog.sync name service}
                  echo ""
                fi
              ''
            ) enabledServices)}

            echo "✅ Datadog sync completed"
          '';
        };

        # Script: provision-secret-exports
        # One-time setup for secret export operations
        provision-secret-exports = lib.mkIf anySecretExportsEnabled {
          description = "Set up all secret export configurations (one-time setup)";
          exec = ''
            echo "🔐 Provisioning secret export operations..."
            echo ""

            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: exportConfig:
              let
                provider = providers.${exportConfig.provider};
                provisionCmd = provider.provisionProject name exportConfig;
              in ''
                echo "🔑 Provisioning secret export: ${name}"
                bash -c ${lib.escapeShellArg provisionCmd}
                echo ""
              ''
            ) enabledSecretExports)}

            echo "✅ All secret export operations provisioned successfully"
          '';
        };

        # Script: export-secrets-environment <environment>
        # Export secrets for a specific environment using tasks
        export-secrets-environment = lib.mkIf anySecretExportsEnabled {
          description = "Export secrets for environment (usage: export-secrets-environment <env>)";
          exec = ''
            ENVIRONMENT="''${1:-}"

            if [ -z "$ENVIRONMENT" ]; then
              echo "❌ Error: Environment name required"
              echo "Usage: export-secrets-environment <environment>"
              echo ""
              echo "Available environments:"
              ${lib.concatStringsSep "\n              echo \"  - " (lib.unique (lib.flatten (lib.mapAttrsToList (_: exportConfig:
                lib.attrNames (getEnabledEnvironments exportConfig)
              ) enabledSecretExports)))}\"
              exit 1
            fi

            echo "🔐 Exporting secrets for: ''${ENVIRONMENT}"
            echo ""

            # Call secret export tasks with JSON input via environment variable
            ${lib.concatStringsSep "\n            " (lib.mapAttrsToList (name: exportConfig: ''
              echo "▶ Exporting: ${name}"
              DEVENV_TASK_INPUT="{\"environment\": \"''${ENVIRONMENT}\"}" ${pkgs.devenv}/bin/devenv tasks run saas-secret-export:${name} || {
                echo "❌ Export failed: ${name}"
                exit 1
              }
              echo ""
            '') enabledSecretExports)}

            echo "✅ Secrets exported for ''${ENVIRONMENT}"
          '';
        };

        # Script: sc-check-secrets
        # Unified secret validation across all services
        sc-check-secrets = {
          description = "Validate secrets for all services (supports --tag and --service filtering)";
          exec = ''
            set -e

            # Parse arguments
            FILTER_TAG=""
            FILTER_SERVICE=""

            while [[ $# -gt 0 ]]; do
              case $1 in
                --tag)
                  FILTER_TAG="$2"
                  shift 2
                  ;;
                --service)
                  FILTER_SERVICE="$2"
                  shift 2
                  ;;
                --help|-h)
                  echo "Usage: sc check-secrets [--tag <tag>] [--service <name>]"
                  echo ""
                  echo "Options:"
                  echo "  --tag <tag>        Only check services with this tag"
                  echo "  --service <name>   Only check a specific service"
                  echo ""
                  echo "Available services:"
                  ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: service:
                    let
                      tags = service.secretspec.tags;
                      tagStr = if tags == [ ] then "" else " (tags: ${lib.concatStringsSep ", " tags})";
                    in ''
                    echo "  ${name}${tagStr}"
                  '') secretspecServices)}
                  exit 0
                  ;;
                *)
                  echo "❌ Error: Unknown argument: $1" >&2
                  echo "Run 'sc check-secrets --help' for usage" >&2
                  exit 1
                  ;;
              esac
            done

            echo "🔐 Checking service secrets..."
            echo ""

            # Generate all secretspec TOML files
            ${generateAllServiceSecretspecs}
            echo ""

            TOTAL_CHECKS=0
            TOTAL_ERRORS=0
            SERVICES_CHECKED=0
            SUMMARY=""

            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (serviceName: service:
              let
                secretspecCfg = service.secretspec;
                tags = secretspecCfg.tags;
              in ''
                # Filter by service name
                if [ -n "$FILTER_SERVICE" ] && [ "$FILTER_SERVICE" != "${serviceName}" ]; then
                  : # skip
                # Filter by tag
                elif [ -n "$FILTER_TAG" ] && ! echo "${lib.concatStringsSep " " tags}" | grep -qw "$FILTER_TAG"; then
                  : # skip
                else
                  SERVICES_CHECKED=$((SERVICES_CHECKED + 1))
                  echo "📋 Checking: ${serviceName}"

                  cd ${config.git.root}/.saas-controller/secretspec/${serviceName}

                  ${lib.concatStringsSep "\n" (lib.mapAttrsToList (envName: envCfg: ''
                    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
                    if ${pkgs.secretspec}/bin/secretspec check --profile ${envName} 2>&1; then
                      echo "  ✅ ${serviceName}/${envName}: OK"
                      SUMMARY="$SUMMARY\n  ✅ ${serviceName}/${envName}"
                    else
                      echo "  ❌ ${serviceName}/${envName}: FAILED"
                      SUMMARY="$SUMMARY\n  ❌ ${serviceName}/${envName}"
                      TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
                    fi
                  '') secretspecCfg.environments)}

                  echo ""
                fi
              ''
            ) secretspecServices)}

            # Print summary
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

            if [ "$SERVICES_CHECKED" -eq 0 ]; then
              if [ -n "$FILTER_TAG" ]; then
                echo "No services matched tag: $FILTER_TAG"
              elif [ -n "$FILTER_SERVICE" ]; then
                echo "No service found: $FILTER_SERVICE"
              else
                echo "No services configured for secret checks"
              fi
              exit 0
            fi

            echo -e "Summary:$SUMMARY"
            echo ""
            echo "Services checked: $SERVICES_CHECKED | Checks: $TOTAL_CHECKS | Errors: $TOTAL_ERRORS"

            if [ "$TOTAL_ERRORS" -gt 0 ]; then
              echo ""
              echo "❌ $TOTAL_ERRORS check(s) failed"
              exit 1
            else
              echo ""
              echo "✅ All secret checks passed"
            fi
          '';
        };

        # Script: sc - Unified SaaS Controller interface
        # Usage: sc <command> [service] [--environment <env>]
        sc = {
          description = "SaaS Controller - unified interface for up/provision/deploy";
          exec = ''
                        set -e

                        COMMAND="''${1:-}"
                        shift || true

                        # Commands that handle their own argument parsing
                        case "$COMMAND" in
                          check-secrets)
                            sc-check-secrets "$@"
                            exit $?
                            ;;
                        esac

                        # Parse arguments for standard commands
                        SERVICE=""
                        ENVIRONMENT=""

                        while [[ $# -gt 0 ]]; do
                          case $1 in
                            --environment|-e)
                              ENVIRONMENT="$2"
                              shift 2
                              ;;
                            *)
                              if [ -z "$SERVICE" ]; then
                                SERVICE="$1"
                              else
                                echo "❌ Error: Unexpected argument: $1" >&2
                                exit 1
                              fi
                              shift
                              ;;
                          esac
                        done

                        case "$COMMAND" in
                          up)
                            # Default environment for 'up' is 'local'
                            ENVIRONMENT="''${ENVIRONMENT:-local}"

                            # --- Generate secretspec TOMLs and inject secrets ---
                            ${generateAllServiceSecretspecs}

                            # If a specific service is targeted, use its secretspec
                            # Otherwise use the first service's secretspec (they share the tailscale profile)
                            SC_SECRETSPEC_DIR=""
                            if [ -n "$SERVICE" ]; then
                              SC_SECRETSPEC_DIR="${config.git.root}/.saas-controller/secretspec/$SERVICE"
                            else
                              # Use first available service secretspec
                              ${lib.concatStringsSep "\n" (lib.mapAttrsToList (serviceName: service:
                                lib.optionalString (service.secretspec != null) ''
                                  if [ -z "$SC_SECRETSPEC_DIR" ] && [ -d "${config.git.root}/.saas-controller/secretspec/${serviceName}" ]; then
                                    SC_SECRETSPEC_DIR="${config.git.root}/.saas-controller/secretspec/${serviceName}"
                                  fi
                                ''
                              ) enabledServices)}
                            fi

                            # If we have a secretspec, re-exec under secretspec run to inject secrets
                            if [ -n "$SC_SECRETSPEC_DIR" ] && [ -f "$SC_SECRETSPEC_DIR/secretspec.toml" ] && [ -z "''${__SC_SECRETS_INJECTED:-}" ]; then
                              export __SC_SECRETS_INJECTED=1
                              cd "$SC_SECRETSPEC_DIR"
                              exec ${pkgs.secretspec}/bin/secretspec run --profile "$ENVIRONMENT" -- "$0" up $SERVICE ''${ENVIRONMENT:+--environment $ENVIRONMENT}
                            fi

                            # --- Hostname derivation ---
                            if [ -n "''${VK_WORKSPACE_ID:-}" ]; then
                              SC_SLUG="''${VK_WORKSPACE_ID:0:8}"
                            else
                              SC_SLUG="local"
                            fi
                            export SC_SLUG

                            # --- Tailnet discovery ---
                            # SC_TAILNET can be set explicitly, or read from host tailscale if installed.
                            if [ -z "''${SC_TAILNET:-}" ]; then
                              if tailscale status --json >/dev/null 2>&1; then
                                SC_TAILNET="$(tailscale status --json | ${pkgs.jq}/bin/jq -r '.MagicDNSSuffix')"
                              fi
                            fi
                            if [ -z "''${SC_TAILNET:-}" ]; then
                              echo "❌ Error: Cannot determine tailnet." >&2
                              echo "  Set SC_TAILNET to your tailnet MagicDNS suffix, e.g.:" >&2
                              echo "    export SC_TAILNET=your-tailnet.ts.net" >&2
                              echo "  Or install Tailscale on the host for auto-detection." >&2
                              exit 1
                            fi
                            export SC_TAILNET

                            echo "Tailscale: tailnet=$SC_TAILNET slug=$SC_SLUG"

                            # --- Tailscale credentials ---
                            # Injected by secretspec run above. Check they're set.
                            if [ -z "''${TS_CLIENT_SECRET:-}" ]; then
                              echo "❌ Error: TS_CLIENT_SECRET not set." >&2
                              echo "  Ensure the secret exists in 1Password under the saas-controller provider alias." >&2
                              echo "  Run 'sc check-secrets' to diagnose." >&2
                              exit 1
                            fi
                            export TS_CLIENT_SECRET
                            export TS_CLIENT_ID="''${TS_CLIENT_ID:-}"

                            # Collect compose dirs for cleanup
                            COMPOSE_DIRS=()

                            cleanup_all() {
                              echo ""
                              echo "Stopping all services..."
                              for dir in "''${COMPOSE_DIRS[@]}"; do
                                docker compose -f "$dir/docker-compose.yml" down 2>/dev/null || true
                              done
                            }
                            trap cleanup_all EXIT INT TERM

                            if [ -n "$SERVICE" ]; then
                              echo "🚀 Starting service: $SERVICE (environment: $ENVIRONMENT)"
                              FOUND=false
                              ${lib.concatStringsSep "\n                              " (lib.mapAttrsToList (serviceName: service:
                                let
                                  localEnv = service.environments.local or null;
                                  hasLocal = localEnv != null && localEnv.enable;
                                  provider = providers.${service.provider} or null;
                                  hasUp = provider != null && provider ? up;
                                  upScript = if hasUp then provider.up serviceName service else "";
                                in
                                lib.optionalString (hasLocal && hasUp) ''
                                  if [ "$SERVICE" = "${serviceName}" ]; then
                                    FOUND=true
                                    COMPOSE_DIRS+=("${config.git.root}/.saas-controller/compose/${serviceName}")
                                    (
                                      ${upScript}
                                    ) &
                                  fi
                                ''
                              ) enabledServices)}
                              if [ "$FOUND" = "false" ]; then
                                echo "❌ Error: No local dev configuration found for service: $SERVICE" >&2
                                exit 1
                              fi
                              wait
                            else
                              echo "🚀 Starting all services (environment: $ENVIRONMENT)"
                              ${lib.concatStringsSep "\n                              " (lib.mapAttrsToList (serviceName: service:
                                let
                                  localEnv = service.environments.local or null;
                                  hasLocal = localEnv != null && localEnv.enable;
                                  provider = providers.${service.provider} or null;
                                  hasUp = provider != null && provider ? up;
                                  upScript = if hasUp then provider.up serviceName service else "";
                                in
                                lib.optionalString (hasLocal && hasUp) ''
                                  COMPOSE_DIRS+=("${config.git.root}/.saas-controller/compose/${serviceName}")
                                  (
                                    ${upScript}
                                  ) &
                                ''
                              ) enabledServices)}
                              wait
                            fi
                            ;;

                          deploy)
                            # Default environment for 'deploy' is 'development'
                            ENVIRONMENT="''${ENVIRONMENT:-development}"

                            if [ -n "$SERVICE" ]; then
                              echo "🚀 Deploying service: $SERVICE (environment: $ENVIRONMENT)"
                              echo ""
                              # Run post-deploy task which will trigger pre-deploy → deploy → post-deploy
                              DEVENV_TASK_INPUT="{\"environment\": \"$ENVIRONMENT\"}" \
                                ${pkgs.devenv}/bin/devenv tasks run --mode before saas-post-deploy:$SERVICE || {
                                echo ""
                                echo "❌ Deployment failed: $SERVICE"
                                exit 1
                              }
                            else
                              echo "🚀 Deploying all services (environment: $ENVIRONMENT)"
                              deploy-environment "$ENVIRONMENT"
                            fi
                            ;;

                          help|--help|-h|"")
                            cat <<EOF
            SaaS Controller - Unified interface for managing services

            Usage:
              sc <command> [service] [--environment <env>]

            Commands:
              up              Start local dev services via docker-compose (default env: local)
              deploy          Deploy service(s) with pre/post hooks (default env: development)
              check-secrets   Validate secrets for all services
              help            Show this help message

            Examples:
              sc up                                      # Start all local services
              sc up atlas3-dev-gateway                   # Start specific service
              sc up --environment edge                   # Start all services for edge env

              sc deploy                                  # Deploy all to development (default)
              sc deploy --environment production         # Deploy all to production
              sc deploy atlas3-dev-gateway -e edge       # Deploy specific service to edge

              sc check-secrets                           # Check all service secrets
              sc check-secrets --tag tailscale           # Check only tailscale-tagged services
              sc check-secrets --service test-gateway    # Check specific service

            Options:
              --environment, -e <env>   Target environment (local, development, edge, production)
                                        Defaults: up=local, deploy=development
              --help, -h                Show this help message

            Note: Deploy runs pre-hooks, deploys the service, then runs post-hooks automatically.
                  Deployment credentials must be in the environment (e.g., via CI secrets).
            EOF
                            ;;

                          *)
                            echo "❌ Error: Unknown command: $COMMAND" >&2
                            echo "Run 'sc help' for usage information" >&2
                            exit 1
                            ;;
                        esac
          '';
        };
      };

      # Generate devenv tasks for dependency-ordered deployments
      # Tasks are input-based: environment is passed as JSON at runtime
      # This reduces N×M tasks to N tasks, enabling dynamic environments
      tasks = lib.mkIf anySaasOperationsEnabled (
        let
          # Validate all dependencies first
          _ = depValidator.validateAll;

          # Generate tasks for secret exports (one per export, not per environment)
          secretExportTasks = lib.mapAttrsToList
            (exportName: exportConfig:
              let
                task = helpers.mkSecretExportTask exportName exportConfig;
                deps = helpers.buildSecretExportDependencies exportName exportConfig;
              in
              lib.nameValuePair task.name (task.value // (lib.optionalAttrs (deps != [ ]) {
                after = deps;
              }))
            )
            enabledSecretExports;

          # Generate tasks for service deployments (three tasks per service)
          # Task flow: saas-pre-deploy → saas-deploy → saas-post-deploy
          serviceDeployTasks = lib.flatten (lib.mapAttrsToList
            (serviceName: service:
              let
                preDeployTask = helpers.mkPreDeployTask serviceName service;
                deployTask = helpers.mkDeployTask serviceName service;
                postDeployTask = helpers.mkPostDeployTask serviceName service;
                serviceDeps = helpers.buildDeployDependencies serviceName service;
              in
              [
                # Pre-deploy task (depends on other services' post-deploy tasks)
                (lib.nameValuePair preDeployTask.name (preDeployTask.value // (lib.optionalAttrs (serviceDeps != [ ]) {
                  after = serviceDeps;
                })))
                # Deploy task (depends on pre-deploy)
                (lib.nameValuePair deployTask.name (deployTask.value // {
                  after = [ preDeployTask.name ];
                }))
                # Post-deploy task (depends on deploy)
                (lib.nameValuePair postDeployTask.name (postDeployTask.value // {
                  after = [ deployTask.name ];
                }))
              ]
            )
            enabledServices);

          # Dev server task — starts all local services via sc up
          # Can be invoked by VibeKanban dev server script: devenv tasks run saas:up
          devServeTasks = [
            (lib.nameValuePair "saas:up" {
              description = "Start local dev services with tailscale HTTPS";
              exec = ''
                exec sc up
              '';
            })
          ];

          # Combine all tasks
          allTasks = secretExportTasks ++ serviceDeployTasks ++ devServeTasks;
        in
        lib.listToAttrs allTasks
      );
    };
}

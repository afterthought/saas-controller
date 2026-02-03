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

  # Import task helpers
  helpers = import ./lib/helpers.nix { inherit pkgs lib config providers; };

  # Import dependency validation
  depValidator = import ./lib/dependencies.nix { inherit lib config; };
in
{
  # Controller-level options
  options.saas-controller = {
    # SecretSpec context: Shared TOML files for controller operations
    secretspecContext = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        List of SecretSpec TOML file paths to import for controller context.
        These provide the secrets needed BY the controller (e.g., Zuplo API keys, Frontegg credentials).
        The files are merged in order, with later files taking precedence.
      '';
      example = [
        "shared/secrets/zuplo/secretspec.toml"
        "shared/secrets/saas-controller/secretspec.toml"
      ];
    };

    # Profile → Provider mapping: Which secretspec provider stores each profile's credentials
    profileProviders = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        dev-saas-controller = "onepassword://Github-Actions";
        prod-saas-controller = "onepassword://Github-Actions";
      };
      description = ''
        Mapping of saas-controller profile names to secretspec provider names.
        Determines which secret storage provider to use when reading control plane credentials.
      '';
      example = {
        dev-saas-controller = "onepassword";
        prod-saas-controller = "1password-cli";
      };
    };

    defaultProfileProvider = lib.mkOption {
      type = lib.types.str;
      default = "onepassword://Github-Actions";
      description = ''
        Default secretspec provider to use for saas-controller profiles not explicitly mapped.
      '';
    };

    # Environment → Profile mapping: Which profile to use for each environment
    environmentProfiles = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        local = "dev-saas-controller";
        edge = "dev-saas-controller";
        main = "prod-saas-controller";
      };
      description = ''
        Mapping of environment names to saas-controller credential profiles.
        Determines which control plane credentials are used for each environment.
        This ensures production deployments use production credentials.
      '';
      example = {
        local = "dev-saas-controller";
        staging = "dev-saas-controller";
        edge = "dev-saas-controller";
        main = "prod-saas-controller";
      };
    };

    defaultSaasControllerProfile = lib.mkOption {
      type = lib.types.str;
      default = "dev-saas-controller";
      description = ''
        Default saas-controller profile to use for environments not explicitly mapped.
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
                    Secret storage provider for this environment (e.g., "onepassword").
                    Profile is automatically set to the environment name.
                    Set to null to skip secret export for this environment.
                  '';
                  example = "onepassword";
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
                  provider = "onepassword";
                  profile = "development";
                };
              };
              edge = {
                enable = true;
                branch = "main";
                autodeploy = true;
                secretspec_provider = "onepassword"; # Uses "edge" as profile
              };
              production = {
                enable = true;
                branch = "main";
                autodeploy = false;
                secretspec_provider = "onepassword"; # Uses "production" as profile
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
                        secretSource = "onepassword://madswan@willdan-corp";
                        secretTarget = "zuplo://atlas3-dev/main";
                        exclude = "ZUDOKU_PUBLIC_*";
                      };
                    }
                    # Hook 2: Export frontend vars as non-secrets
                    {
                      type = "secretspec";
                      config = {
                        secretSource = "onepassword://madswan@willdan-corp";
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
                  example = "onepassword://madswan@willdan-corp";
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
                    local = { secretSource = "onepassword://madswan@willdan-corp"; };
                    edge = { secretSource = "onepassword://madswan@willdan-corp/edge-vault"; };
                  };
                };
              };
            };
            default = { secretSource = null; environments = { }; };
            description = "Run-time secret source configuration for local development";
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
                  description = "Default SecretSpec provider to read secrets from (can be overridden per environment)";
                  example = "onepassword";
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

      # Command to generate the secretspec file in .saas-controller/
      generateControllerSecretspecCmd = lib.optionalString (config.saas-controller.secretspecContext != [ ]) ''
                # Create .saas-controller directory if it doesn't exist
                mkdir -p ${config.git.root}/.saas-controller

                # Generate secretspec configuration
                cat > ${config.git.root}/.saas-controller/secretspec.toml <<EOF
        [project]
        name = "saas-controller-runtime"
        description = "Dynamically generated SaaS control plane secrets (Frontegg + Zuplo)"
        revision = "1.0"

        # Extend control plane secretspec files
        extends = [
        ${lib.concatMapStringsSep ",\n" (path: "  \"../" + path + "\"") config.saas-controller.secretspecContext}
        ]

        [profiles.default]
        [profiles.dev-saas-controller]
        [profiles.prod-saas-controller]
        # Inherits profiles:
        # - dev-saas-controller (for dev/edge/local environments)
        # - prod-saas-controller (for production environments)
        #
        # Available secrets:
        # From Frontegg: FRONTEGG_CLIENT_ID, FRONTEGG_API_KEY, FRONTEGG_BASE_URL, FRONTEGG_API_URL
        # From Zuplo: ZUPLO_API_KEY
        EOF

                echo "  Generated .saas-controller/secretspec.toml"
                echo "  Extends: ${lib.concatStringsSep ", " config.saas-controller.secretspecContext}"
      '';

    in
    {
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
      packages = lib.mkIf anySaasOperationsEnabled ((with pkgs; [
        jq # JSON processing
        curl # HTTP requests (Datadog API, etc.)
        secretspec # Secret management
        _1password-cli # 1Password integration
        config.languages.javascript.package # Use configured Node.js version
      ]) ++ (
        # Dev-serve scripts for services with "local" environment
        # Scripts are used instead of devenv tasks because devenv tasks buffer all output,
        # which prevents streaming logs to vibe-kanban and interactive terminals.
        let
          devServeScripts = lib.flatten (lib.mapAttrsToList
            (serviceName: service:
              let
                localEnv = service.environments.local or null;
                hasLocal = localEnv != null && localEnv.enable;
                provider = providers.${service.provider} or null;
                variants = if provider != null && provider ? localVariants
                  then provider.localVariants serviceName service
                  else [];
              in
              lib.optionals hasLocal (map (v:
                helpers.mkDevServeScript serviceName service v.variant v.command
              ) variants)
            )
            enabledServices);
        in
        devServeScripts
      ));
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
            ${generateControllerSecretspecCmd}
            echo ""

            # Use default saas-controller profile for project creation
            SAAS_PROFILE="${config.saas-controller.defaultSaasControllerProfile}"
            SAAS_PROVIDER="${config.saas-controller.defaultProfileProvider}"

            echo "🔑 Using saas-controller profile: $SAAS_PROFILE (provider: $SAAS_PROVIDER)"
            echo ""

            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: service:
              let
                provider = providers.${service.provider};
                provisionCmd = provider.provisionProject name service;
              in ''
                echo "📦 Provisioning project: ${name} (${service.provider})"

                # Wrap with control plane secrets (ZUPLO_API_KEY, FRONTEGG_*, etc.)
                cd ${config.git.root}/.saas-controller
                ${pkgs.secretspec}/bin/secretspec run \
                  --provider "$SAAS_PROVIDER" \
                  --profile "$SAAS_PROFILE" -- bash -c ${lib.escapeShellArg provisionCmd}

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
            ${generateControllerSecretspecCmd}
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
            ${generateControllerSecretspecCmd}
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
            ${generateControllerSecretspecCmd}
            echo ""

            # Use default saas-controller profile for project creation
            SAAS_PROFILE="${config.saas-controller.defaultSaasControllerProfile}"
            SAAS_PROVIDER="${config.saas-controller.defaultProfileProvider}"

            echo "🔑 Using saas-controller profile: $SAAS_PROFILE (provider: $SAAS_PROVIDER)"
            echo ""

            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: exportConfig:
              let
                provider = providers.${exportConfig.provider};
                provisionCmd = provider.provisionProject name exportConfig;
              in ''
                echo "🔑 Provisioning secret export: ${name}"

                # Wrap with control plane secrets (ZUPLO_API_KEY, FRONTEGG_*, etc.)
                cd ${config.git.root}/.saas-controller
                ${pkgs.secretspec}/bin/secretspec run \
                  --provider "$SAAS_PROVIDER" \
                  --profile "$SAAS_PROFILE" -- bash -c ${lib.escapeShellArg provisionCmd}

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
            ${generateControllerSecretspecCmd}
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

        # Script: check-saas-controller-secrets
        # Check all saas-controller secrets are configured correctly
        check-saas-controller-secrets = {
          description = "Validate SaaS controller secrets for all profiles";
          exec = ''
            echo "🔐 Checking SaaS Controller secrets..."
            ${generateControllerSecretspecCmd}
            echo ""

            # Run from .saas-controller directory so secretspec finds the config
            cd ${config.git.root}/.saas-controller

            # Check dev-saas-controller profile
            echo "📋 Checking dev-saas-controller profile..."
            if ${pkgs.secretspec}/bin/secretspec check --provider onepassword --profile dev-saas-controller; then
              echo "✅ dev-saas-controller secrets: OK"
            else
              echo "❌ dev-saas-controller secrets: MISSING"
              echo ""
              echo "Required secrets in 1Password:"
              echo "  From Frontegg:"
              echo "    - FRONTEGG_CLIENT_ID"
              echo "    - FRONTEGG_API_KEY"
              echo "    - FRONTEGG_BASE_URL"
              echo "  From Zuplo:"
              echo "    - ZUPLO_API_KEY"
              echo ""
              exit 1
            fi
            echo ""

            # Check prod-saas-controller profile
            echo "📋 Checking prod-saas-controller profile..."
            if ${pkgs.secretspec}/bin/secretspec check --provider onepassword --profile prod-saas-controller; then
              echo "✅ prod-saas-controller secrets: OK"
            else
              echo "❌ prod-saas-controller secrets: MISSING"
              echo ""
              echo "Required secrets in 1Password:"
              echo "  From Frontegg:"
              echo "    - FRONTEGG_CLIENT_ID"
              echo "    - FRONTEGG_API_KEY"
              echo "    - FRONTEGG_BASE_URL"
              echo "  From Zuplo:"
              echo "    - ZUPLO_API_KEY"
              echo ""
              exit 1
            fi
            echo ""

            echo "✅ All SaaS controller secrets are properly configured"
          '';
        };

        # Script: check-dev-saas-controller
        # Check dev saas-controller secrets only
        check-dev-saas-controller = {
          description = "Validate development SaaS controller secrets";
          exec = ''
            echo "🔐 Checking development SaaS controller secrets..."
            ${generateControllerSecretspecCmd}
            echo ""

            # Run from .saas-controller directory so secretspec finds the config
            cd ${config.git.root}/.saas-controller

            if ${pkgs.secretspec}/bin/secretspec check --provider onepassword --profile dev-saas-controller; then
              echo "✅ dev-saas-controller secrets: OK"
            else
              echo "❌ dev-saas-controller secrets: MISSING"
              echo ""
              echo "Required secrets in 1Password:"
              echo "  From Frontegg:"
              echo "    - FRONTEGG_CLIENT_ID"
              echo "    - FRONTEGG_API_KEY"
              echo "    - FRONTEGG_BASE_URL"
              echo "  From Zuplo:"
              echo "    - ZUPLO_API_KEY"
              echo ""
              exit 1
            fi
          '';
        };

        # Script: check-prod-saas-controller
        # Check prod saas-controller secrets only
        check-prod-saas-controller = {
          description = "Validate production SaaS controller secrets";
          exec = ''
            echo "🔐 Checking production SaaS controller secrets..."
            ${generateControllerSecretspecCmd}
            echo ""

            # Run from .saas-controller directory so secretspec finds the config
            cd ${config.git.root}/.saas-controller

            if ${pkgs.secretspec}/bin/secretspec check --provider onepassword --profile prod-saas-controller; then
              echo "✅ prod-saas-controller secrets: OK"
            else
              echo "❌ prod-saas-controller secrets: MISSING"
              echo ""
              echo "Required secrets in 1Password:"
              echo "  From Frontegg:"
              echo "    - FRONTEGG_CLIENT_ID"
              echo "    - FRONTEGG_API_KEY"
              echo "    - FRONTEGG_BASE_URL"
              echo "  From Zuplo:"
              echo "    - ZUPLO_API_KEY"
              echo ""
              exit 1
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

                        # Parse arguments
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

                            if [ -n "$SERVICE" ]; then
                              echo "🚀 Starting service: $SERVICE (environment: $ENVIRONMENT)"
                              # Look up dev-serve scripts for the requested service
                              FOUND=false
                              ${lib.concatStringsSep "\n                              " (lib.flatten (lib.mapAttrsToList (serviceName: service:
                                let
                                  localEnv = service.environments.local or null;
                                  hasLocal = localEnv != null && localEnv.enable;
                                  provider = providers.${service.provider} or null;
                                  variants = if provider != null && provider ? localVariants
                                    then provider.localVariants serviceName service
                                    else [];
                                in
                                lib.optionals hasLocal [(''
                                  if [ "$SERVICE" = "${serviceName}" ]; then
                                    FOUND=true
                                    ${lib.concatStringsSep "\n                                    " (map (v:
                                      ''dev-serve-${serviceName}-${v.variant} &''
                                    ) variants)}
                                  fi
                                '')]
                              ) enabledServices))}
                              if [ "$FOUND" = "false" ]; then
                                echo "❌ Error: No local dev-serve scripts found for service: $SERVICE" >&2
                                exit 1
                              fi
                              wait
                            else
                              echo "🚀 Starting all services (environment: $ENVIRONMENT)"
                              ${lib.concatStringsSep "\n                              " (lib.flatten (lib.mapAttrsToList (serviceName: service:
                                let
                                  localEnv = service.environments.local or null;
                                  hasLocal = localEnv != null && localEnv.enable;
                                  provider = providers.${service.provider} or null;
                                  variants = if provider != null && provider ? localVariants
                                    then provider.localVariants serviceName service
                                    else [];
                                in
                                lib.optionals hasLocal (map (v: ''
                                  dev-serve-${serviceName}-${v.variant} &
                                '') variants)
                              ) enabledServices))}
                              wait
                            fi
                            ;;

                          deploy)
                            # Default environment for 'deploy' is 'development'
                            ENVIRONMENT="''${ENVIRONMENT:-development}"

                            # Generate secretspec.toml for control plane credentials
                            ${generateControllerSecretspecCmd}

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
              up          Start local dev services via dev-manager-mcp + Tailscale (default env: local)
              deploy      Deploy service(s) with pre/post hooks (default env: development)
              help        Show this help message

            Examples:
              sc up                                      # Start all local services
              sc up atlas3-dev-gateway                   # Start specific service
              sc up --environment edge                   # Start all services for edge env

              sc deploy                                  # Deploy all to development (default)
              sc deploy --environment production         # Deploy all to production
              sc deploy atlas3-dev-gateway -e edge       # Deploy specific service to edge

            Options:
              --environment, -e <env>   Target environment (local, development, edge, production)
                                        Defaults: up=local, deploy=development
              --help, -h                Show this help message

            Note: Deploy runs pre-hooks, deploys the service, then runs post-hooks automatically.
                  Task output is shown in real-time for better visibility.
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

          # Combine all tasks (dev-serve uses scripts in PATH, not devenv tasks)
          allTasks = secretExportTasks ++ serviceDeployTasks;
        in
        lib.listToAttrs allTasks
      );
    };
}

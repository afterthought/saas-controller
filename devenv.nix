{ pkgs, lib, config, ... }:

let
  # Import builtin provider adapters
  builtinProviders = {
    # Main providers (for running/deploying services)
    zuplo = import ./providers/zuplo.nix { inherit pkgs lib config; };

    # Provision providers (for setting up services)
    secretspec = import ./providers/secretspec-export.nix { inherit pkgs lib config; };
    frontegg = import ./providers/frontegg.nix { inherit pkgs lib config; };

    # Generic provider for pre-authored docker-compose files
    docker-compose = import ./providers/docker-compose.nix { inherit pkgs lib config; };

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

  # Convert an SA token alias to its environment variable name.
  # "client_willdan" -> "OP_SA_CLIENT_WILLDAN"
  toSASecretName = name:
    "OP_SA_${lib.toUpper (builtins.replaceStrings ["-"] ["_"] name)}";

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

          default = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Default value for this secret (used when no provider supplies it)";
          };
        };
      }));
      default = { };
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
            TS_CLIENT_SECRET = { description = "Tailscale OAuth client secret"; };
            TS_CLIENT_ID = { description = "Tailscale OAuth client ID"; required = false; };
          };
          zuplo-backend = {
            ZUPLO_API_KEY = { description = "Zuplo API key for deployments"; };
          };
        }
      '';
    };

    # Default secretspec provider aliases applied to all profiles unless overridden
    defaultProviders = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "saas-controller" ];
      description = ''
        Default provider aliases for all secret profiles.
        Emitted as [profiles.<env>.defaults] providers in generated secretspec.toml.
        Override per-service with services.<name>.secretspec.defaultProviders
        or per-environment with services.<name>.secretspec.environments.<env>.defaultProviders.
      '';
      example = [ "acme-vault" "saas-controller" ];
    };

    saTokensDir = lib.mkOption {
      type = lib.types.str;
      default = "$HOME/.config/secretspec/sa-tokens";
      description = ''
        Path to the directory containing SA token secretspec.toml.
        Auto-generated as a nix store path when services declare secretspec.auth.saToken.
        Override to use a custom secretspec directory for SA token retrieval.
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
                    appName = "atlas3-production"; # Frontegg-specific
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
            description = ''
              Environment definitions.
              Keys must be one of: "local", "production", "preview".
            '';
            example = {
              local = {
                enable = true;
              };
              production = {
                enable = true;
                secretspec_provider = "saas-controller";
              };
              preview = {
                enable = true;
                skipSecretExport = true;
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
                          Can be a builtin hook provider (secretspec, frontegg)
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
                          Can be a builtin hook provider (secretspec, frontegg)
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

          # Per-service secretspec configuration for sc check-secrets
          secretspec = lib.mkOption {
            type = lib.types.nullOr (lib.types.submodule {
              options = {
                defaultProviders = lib.mkOption {
                  type = lib.types.nullOr (lib.types.listOf lib.types.str);
                  default = null;
                  description = ''
                    Override default provider aliases for this service's secret profiles.
                    When null, inherits from saas-controller.defaultProviders.
                  '';
                  example = [ "billing-vault" ];
                };

                environments = lib.mkOption {
                  type = lib.types.attrsOf (lib.types.submodule {
                    options = {
                      defaultProviders = lib.mkOption {
                        type = lib.types.nullOr (lib.types.listOf lib.types.str);
                        default = null;
                        description = ''
                          Override default provider aliases for this environment.
                          When null, inherits from service-level or global defaultProviders.
                        '';
                        example = [ "env" ];
                      };

                      serviceProfiles = lib.mkOption {
                        type = lib.types.listOf lib.types.str;
                        description = "List of secret profile names from saas-controller.secretProfiles to validate for this environment";
                        example = [ "tailscale" "zuplo-backend" ];
                      };

                      secrets = lib.mkOption {
                        type = lib.types.attrsOf (lib.types.submodule {
                          options = {
                            description = lib.mkOption {
                              type = lib.types.str;
                              description = "Human-readable description of this secret";
                            };
                            required = lib.mkOption {
                              type = lib.types.bool;
                              default = true;
                              description = "Whether this secret is required";
                            };
                            providers = lib.mkOption {
                              type = lib.types.listOf lib.types.str;
                              default = [ ];
                              description = "SecretSpec provider aliases that supply this secret";
                            };
                            default = lib.mkOption {
                              type = lib.types.nullOr lib.types.str;
                              default = null;
                              description = "Default value for this secret (used when no provider supplies it)";
                            };
                          };
                        });
                        default = { };
                        description = ''
                          Per-instance extra secrets for this environment.
                          These merge with profile secrets (profiles take precedence on duplicates).
                        '';
                        example = lib.literalExpression ''
                          {
                            STRIPE_API_KEY = { description = "Stripe API key"; providers = [ "client_willdan" ]; };
                          }
                        '';
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
                      production = { serviceProfiles = [ "zuplo-backend" ]; };
                    }
                  '';
                };

                tags = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                  description = "Tags for filtering: sc check-secrets --tag tailscale";
                  example = [ "tailscale" "backend" ];
                };

                auth = lib.mkOption {
                  type = lib.types.nullOr (lib.types.submodule {
                    options = {
                      provider = lib.mkOption {
                        type = lib.types.str;
                        description = ''
                          SecretSpec provider alias (URN) used in the providers list of each
                          secret definition in the generated secretspec.toml. Secretspec resolves
                          this alias to a backend via its global config (~/.config/secretspec/config.toml).
                          This is NOT passed as a CLI flag.
                        '';
                        example = "client_willdan";
                      };
                      saToken = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        description = ''
                          SA token alias for retrieval via the sa-tokens provider. When set,
                          sc up retrieves the named token and exports it as OP_SERVICE_ACCOUNT_TOKEN
                          before running secretspec commands for this service.
                          E.g. "client_willdan" retrieves OP_SA_CLIENT_WILLDAN.
                        '';
                        example = "client_willdan";
                      };
                    };
                  });
                  default = null;
                  description = ''
                    Authentication configuration for secretspec runtime access.
                    - provider: secretspec provider alias (URN) used in secret definitions
                    - saToken: SA token alias, retrieved via the sa-tokens provider at runtime
                  '';
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
              Profile name is automatically set to the environment name (e.g., "local", "production", "preview").
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

      # Valid environment names (constrained set)
      validEnvironments = [ "local" "production" "preview" ];

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

      # ── SA token secretspec (auto-generated from service configs) ──────
      # Collect unique SA token aliases from all services that use auth.saToken
      allSATokenAliases = lib.unique (lib.concatMap
        (service:
          if service.secretspec != null
            && service.secretspec.auth != null
            && service.secretspec.auth.saToken != null
          then [ service.secretspec.auth.saToken ]
          else [])
        (lib.attrValues enabledServices));

      # Generate sa-tokens secretspec.toml content at nix eval time
      saTokensTomlContent =
        let
          tokenLines = lib.concatMapStringsSep "\n" (alias:
            let name = toSASecretName alias;
            in ''${name} = { description = "1Password SA token for ${alias}", providers = ["sa-tokens"] }''
          ) allSATokenAliases;
        in ''
[project]
name = "sa-tokens"
revision = "1.0"

[profiles.default]
${tokenLines}
'';

      # Write as a nix store derivation — no runtime generation needed.
      # Used as the default for saas-controller.saTokensDir when SA tokens are configured.
      generatedSATokensDir = pkgs.writeTextDir "secretspec.toml" saTokensTomlContent;

      # Generate TOML content for a single secret entry
      mkSecretToml = secretName: secretDef:
        let
          descLine = "description = \"${secretDef.description}\"";
          reqLine = lib.optionalString (!secretDef.required) ", required = false";
          provLine = lib.optionalString (secretDef.providers != [ ])
            ", providers = [${lib.concatMapStringsSep ", " (p: "\"${p}\"") secretDef.providers}]";
          defLine = lib.optionalString (secretDef.default != null)
            ", default = \"${secretDef.default}\"";
        in
        "${secretName} = { ${descLine}${reqLine}${provLine}${defLine} }";

      # Generate secretspec.toml content for a service
      # Generate secretspec.toml content for a service.
      # Three-layer secret composition:
      #   1. Controller-level profiles from serviceProfiles (includes auto-included provider profiles)
      #   2. Provider-contributed profiles auto-included from providers.<provider>.secretProfiles
      #   3. Per-instance inline secrets from environment's secrets option
      # First occurrence wins on duplicate secret names.
      # Resolve default providers: environment > service > global (first non-null wins)
      resolveDefaultProviders = secretspecCfg: envCfg:
        if envCfg.defaultProviders != null then envCfg.defaultProviders
        else if secretspecCfg.defaultProviders != null then secretspecCfg.defaultProviders
        else config.saas-controller.defaultProviders;

      mkServiceSecretspecToml = serviceName: service:
        let
          secretspecCfg = service.secretspec;
          profiles = config.saas-controller.secretProfiles;

          # Auto-include provider's secret profiles
          providerObj = providers.${service.provider} or {};
          providerProfileNames = lib.attrNames (providerObj.secretProfiles or {});

          # For each environment, collect the union of secrets from all three layers
          envSections = lib.concatStringsSep "\n\n" (lib.mapAttrsToList (envName: envCfg:
            let
              # Resolve default providers for this environment
              defaultProviders = resolveDefaultProviders secretspecCfg envCfg;
              defaultsSection = ''
[profiles.${envName}.defaults]
providers = [${lib.concatMapStringsSep ", " (p: ''"${p}"'') defaultProviders}]'';

              # Prepend provider profiles to explicit serviceProfiles (deduped)
              allProfileNames = lib.unique (providerProfileNames ++ envCfg.serviceProfiles);

              # Layer 1+2: Collect secrets from profiles (first occurrence wins)
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

              profileSecrets = collectSecrets allProfileNames;

              # Layer 3: Inline secrets (only add if not already from profiles)
              inlineSecrets = envCfg.secrets or {};
              extraSecrets = lib.filterAttrs (name: _: ! (profileSecrets ? ${name})) inlineSecrets;

              # Merge all layers
              allSecrets = profileSecrets // extraSecrets;
              secretLines = lib.concatStringsSep "\n" (lib.mapAttrsToList mkSecretToml allSecrets);
            in
            ''
${defaultsSection}

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


      # Generate all service secretspec TOML files on disk
      generateAllServiceSecretspecs = ''
        mkdir -p ${config.git.root}/.saas-controller/secretspec
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (serviceName: service:
          let
            tomlContent = mkServiceSecretspecToml serviceName service;
          in ''
            mkdir -p ${config.git.root}/.saas-controller/secretspec/${serviceName}
            cat > ${config.git.root}/.saas-controller/secretspec/${serviceName}/secretspec.toml <<'SECRETSPEC_EOF'
${tomlContent}
SECRETSPEC_EOF
          ''
        ) secretspecServices)}
      '';

      # ── Secret status table helpers ─────────────────────────────────────
      # Pad a string to a fixed width with trailing spaces
      statusPad = width: s:
        let len = builtins.stringLength s;
        in s + lib.concatStrings (builtins.genList (_: " ") (if width > len then width - len else 0));

      # Pad a display-width string, accounting for multi-byte UTF-8.
      # Checkmark ✓ is 3 bytes but 1 display column; add 2 extra spaces.
      statusPadCell = width: s: hasCheck:
        let
          extraBytes = if hasCheck then 2 else 0;
          byteLen = builtins.stringLength s;
          displayLen = byteLen - extraBytes;
          needed = if width > displayLen then width - displayLen else 0;
        in s + lib.concatStrings (builtins.genList (_: " ") needed);

      # For a given service, collect the union of all secrets across all its
      # environments. Returns { secretName = profileName; } where profileName
      # is the source profile or "(inline)" for per-instance secrets.
      collectServiceSecrets = serviceName: service:
        let
          secretspecCfg = service.secretspec;
          profiles = config.saas-controller.secretProfiles;
          providerObj = providers.${service.provider} or {};
          providerProfileNames = lib.attrNames (providerObj.secretProfiles or {});
        in
        lib.foldlAttrs (acc: envName: envCfg:
          let
            allProfileNames = lib.unique (providerProfileNames ++ envCfg.serviceProfiles);

            # Collect secrets from profiles, tracking which profile they came from
            profileSecretsWithSource = lib.foldl (innerAcc: profileName:
              let
                profileSecrets = profiles.${profileName} or {};
                newEntries = lib.filterAttrs (name: _: ! (innerAcc ? ${name})) profileSecrets;
                tagged = lib.mapAttrs (_: _: profileName) newEntries;
              in
              innerAcc // tagged
            ) {} allProfileNames;

            # Inline secrets not already covered by profiles
            inlineSecrets = envCfg.secrets or {};
            extraEntries = lib.mapAttrs (_: _: "(inline)")
              (lib.filterAttrs (name: _: ! (profileSecretsWithSource ? ${name})) inlineSecrets);

            envSecrets = profileSecretsWithSource // extraEntries;

            # Merge into accumulator (first occurrence wins across environments)
            newSecrets = lib.filterAttrs (name: _: ! (acc ? ${name})) envSecrets;
          in
          acc // newSecrets
        ) {} secretspecCfg.environments;

      # Collect secrets for all services: { serviceName = { secretName = profileName; }; }
      allServiceSecrets = lib.mapAttrs collectServiceSecrets secretspecServices;

      # Union of all secret names across all services (sorted)
      allSecretNames = lib.sort builtins.lessThan (lib.unique (lib.concatMap
        (secrets: lib.attrNames secrets)
        (lib.attrValues allServiceSecrets)
      ));

      # For each secret, find which profile it comes from (first occurrence across services)
      secretProfileMap = lib.foldl (acc: secretName:
        if acc ? ${secretName} then acc
        else
          let
            source = lib.findFirst (svcSecrets: svcSecrets ? ${secretName})
              {} (lib.attrValues allServiceSecrets);
          in
          acc // { ${secretName} = source.${secretName} or "?"; }
      ) {} allSecretNames;

      # Service column definitions with dynamic widths
      serviceNames = lib.attrNames secretspecServices;
      serviceColWidth = name: let len = builtins.stringLength name; in if len < 10 then 10 else len + 2;

      # Column widths
      secretColWidth = 36;
      profileColWidth = 20;

      # Generate a single table row for one secret
      mkStatusRow = secretName:
        let
          profile = secretProfileMap.${secretName} or "?";
          checks = lib.concatStrings (map (svcName:
            let
              width = serviceColWidth svcName;
              has = (allServiceSecrets.${svcName} or {}) ? ${secretName};
            in statusPadCell width (if has then "✓" else " ") has
          ) serviceNames);
        in "${statusPad secretColWidth secretName} ${statusPad profileColWidth profile} ${checks}";

      allStatusRows = map mkStatusRow allSecretNames;

      statusHeaderLine =
        let svcHeaders = lib.concatStrings (map (name: statusPad (serviceColWidth name) name) serviceNames);
        in "${statusPad secretColWidth "Secret"} ${statusPad profileColWidth "Profile"} ${svcHeaders}";

      statusSeparatorWidth = secretColWidth + 1 + profileColWidth + 1
        + lib.foldl' (acc: name: acc + serviceColWidth name) 0 serviceNames;
      statusSeparatorLine = lib.concatStrings (builtins.genList (_: "─") statusSeparatorWidth);

    in
    {
      # Merge built-in + provider-contributed secret profiles into controller config
      # Uses mkDefault so consumers can override with explicit secretProfiles config
      saas-controller.secretProfiles = lib.mapAttrs
        (_profileName: secrets: lib.mapAttrs
          (_secretName: secretDef: lib.mkDefault secretDef)
          secrets
        )
        ({
          tailscale = {
            TS_CLIENT_SECRET = { description = "Tailscale OAuth client secret for ephemeral node creation"; };
            TS_CLIENT_ID = { description = "Tailscale OAuth client ID"; required = false; };
            SC_TAILNET = { description = "Tailnet MagicDNS suffix, e.g. my-tailnet.ts.net (auto-detected if host tailscale installed)"; required = false; };
          };
        } // providerSecretProfiles);

      # Auto-generate sa-tokens secretspec.toml as a nix store path when services use SA tokens.
      # Consumers can override with an explicit path if needed.
      saas-controller.saTokensDir = lib.mkIf (allSATokenAliases != [])
        (lib.mkDefault "${generatedSATokensDir}");

      # Runtime assertions for provider and environment validation
      assertions = lib.flatten [
        # Validate service environment names are in the canonical set
        (lib.mapAttrsToList
          (serviceName: service:
            let
              envNames = lib.attrNames service.environments;
              invalidEnvs = lib.filter (e: ! lib.elem e validEnvironments) envNames;
            in
            {
              assertion = invalidEnvs == [ ];
              message = ''
                Service "${serviceName}" declares invalid environment(s): ${lib.concatStringsSep ", " invalidEnvs}
                Valid environments: ${lib.concatStringsSep ", " validEnvironments}
              '';
            }
          )
          config.saas-controller.services)

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

        # Generate secretspec.toml files for all services
        ${generateAllServiceSecretspecs}
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

            TOTAL_CHECKS=0
            TOTAL_ERRORS=0
            SERVICES_CHECKED=0
            SUMMARY=""

            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (serviceName: service:
              let
                secretspecCfg = service.secretspec;
                tags = secretspecCfg.tags;
                hasAuth = secretspecCfg.auth != null;
                hasSAToken = hasAuth && secretspecCfg.auth.saToken != null;
                saSecretName = if hasSAToken then toSASecretName secretspecCfg.auth.saToken else "";
                saTokensDir = config.saas-controller.saTokensDir;
                saSwapSnippet = lib.optionalString hasSAToken (helpers.mkSASwapSnippet {
                  inherit saSecretName saTokensDir serviceName;
                });
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

                  # Save and swap SA token for this service
                  __SC_SAVED_SA_TOKEN="''${OP_SERVICE_ACCOUNT_TOKEN:-}"
                  ${saSwapSnippet}

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

                  # Restore previous SA token
                  export OP_SERVICE_ACCOUNT_TOKEN="$__SC_SAVED_SA_TOKEN"

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

        # Script: sc-secret-status
        # Display secret-to-service mapping table (computed at Nix eval time)
        sc-secret-status = {
          description = "Display secret-to-service mapping table";
          exec = ''
            echo "SaaS Controller Secret Status"
            echo "Secrets derived from secretProfiles + per-service secretspec config"
            echo ""
            echo "${statusHeaderLine}"
            echo "${statusSeparatorLine}"
            ${lib.concatStringsSep "\n" (map (row: "echo '${row}'") allStatusRows)}
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
                          secret-status)
                            sc-secret-status
                            exit $?
                            ;;

                          setup-env)
                            TARGET_ENV="''${2:-}"
                            if [ -z "$TARGET_ENV" ]; then
                              echo "❌ Error: Environment required" >&2
                              echo "  Usage: sc setup-env <local|production|preview>" >&2
                              exit 1
                            fi
                            if [[ ! " local production preview " =~ " $TARGET_ENV " ]]; then
                              echo "❌ Error: Invalid environment: $TARGET_ENV" >&2
                              echo "  Valid environments: local, production, preview" >&2
                              exit 1
                            fi

                            echo "🔐 Setup environment: $TARGET_ENV"
                            echo ""

                            MISSING_COUNT=0
                            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (serviceName: service:
                              let
                                secretspecCfg = service.secretspec;
                                hasAuth = secretspecCfg.auth != null;
                                authLabel = if hasAuth then " (auth: ${secretspecCfg.auth.provider})" else "";
                                hasSAToken = hasAuth && secretspecCfg.auth.saToken != null;
                                saSecretName = if hasSAToken then toSASecretName secretspecCfg.auth.saToken else "";
                                saTokensDir = config.saas-controller.saTokensDir;
                                saSwapSnippet = lib.optionalString hasSAToken ''
                                  __SC_SAVED_SA_TOKEN="''${OP_SERVICE_ACCOUNT_TOKEN:-}"
                                  ${helpers.mkSASwapSnippet { inherit saSecretName saTokensDir serviceName; failMode = "soft"; }}
                                '';
                                saRestoreSnippet = lib.optionalString hasSAToken ''
                                  export OP_SERVICE_ACCOUNT_TOKEN="$__SC_SAVED_SA_TOKEN"
                                '';
                              in
                              lib.concatStringsSep "\n" (lib.mapAttrsToList (envName: envCfg:
                                let
                                  profiles = config.saas-controller.secretProfiles;
                                  providerObj = providers.${service.provider} or {};
                                  providerProfileNames = lib.attrNames (providerObj.secretProfiles or {});
                                  allProfileNames = lib.unique (providerProfileNames ++ envCfg.serviceProfiles);
                                  collectSecrets = profileNames:
                                    lib.foldl (acc: pn:
                                      let ps = profiles.${pn} or {};
                                      in acc // (lib.filterAttrs (n: _: ! (acc ? ${n})) ps)
                                    ) {} profileNames;
                                  profileSecrets = collectSecrets allProfileNames;
                                  inlineSecrets = envCfg.secrets or {};
                                  extraSecrets = lib.filterAttrs (n: _: ! (profileSecrets ? ${n})) inlineSecrets;
                                  allSecrets = profileSecrets // extraSecrets;
                                  requiredSecrets = lib.filterAttrs (_: s: (s.required or true) && (s.default or null) == null) allSecrets;
                                  optionalSecrets = lib.filterAttrs (_: s: !(s.required or true) || (s.default or null) != null) allSecrets;
                                  secretNames = lib.attrNames allSecrets;
                                in ''
                              if [ "$TARGET_ENV" = "${envName}" ]; then
                                ${saSwapSnippet}
                                echo "📋 ${serviceName}${authLabel}:"
                                echo "  Profiles: ${lib.concatStringsSep ", " allProfileNames}"
                                echo "  Secrets: ${toString (builtins.length secretNames)} total (${toString (builtins.length (lib.attrNames requiredSecrets))} required)"

                                if (cd ${config.git.root}/.saas-controller/secretspec/${serviceName} && ${pkgs.secretspec}/bin/secretspec check --profile ${envName} 2>/dev/null); then
                                  echo "  ✅ All secrets available"
                                else
                                  echo "  ❌ Some secrets missing — required:"
                                  ${lib.concatStringsSep "\n" (lib.mapAttrsToList (secretName: secretDef: ''
                                  echo "     - ${secretName}: ${secretDef.description}"
                                  '') requiredSecrets)}
                                  MISSING_COUNT=$((MISSING_COUNT + 1))
                                fi
                                ${saRestoreSnippet}
                                echo ""
                              fi
                                '') secretspecCfg.environments)
                            ) secretspecServices)}

                            if [ $MISSING_COUNT -gt 0 ]; then
                              echo "⚠️  $MISSING_COUNT service(s) have missing secrets in $TARGET_ENV"
                              exit 1
                            else
                              echo "✅ All required secrets are set for $TARGET_ENV"
                            fi
                            exit 0
                            ;;

                          diff-secrets)
                            ENV1="''${2:-}"
                            ENV2="''${3:-}"
                            if [ -z "$ENV1" ] || [ -z "$ENV2" ]; then
                              echo "❌ Error: Two environments required" >&2
                              echo "  Usage: sc diff-secrets <env1> <env2>" >&2
                              exit 1
                            fi
                            for e in "$ENV1" "$ENV2"; do
                              if [[ ! " local production preview " =~ " $e " ]]; then
                                echo "❌ Error: Invalid environment: $e" >&2
                                echo "  Valid environments: local, production, preview" >&2
                                exit 1
                              fi
                            done

                            echo "🔍 Diff secrets: $ENV1 vs $ENV2"
                            echo ""
                            printf "%-25s %-15s %-15s %s\n" "SERVICE" "$ENV1" "$ENV2" ""
                            printf "%-25s %-15s %-15s %s\n" "───────" "───────" "───────" ""

                            DIFF_COUNT=0
                            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (serviceName: service:
                              let
                                secretspecCfg = service.secretspec;
                                hasAuth = secretspecCfg.auth != null;
                                hasSAToken = hasAuth && secretspecCfg.auth.saToken != null;
                                saSecretName = if hasSAToken then toSASecretName secretspecCfg.auth.saToken else "";
                                saTokensDir = config.saas-controller.saTokensDir;
                                saSwapSnippet = lib.optionalString hasSAToken ''
                                  __SC_SAVED_SA_TOKEN="''${OP_SERVICE_ACCOUNT_TOKEN:-}"
                                  ${helpers.mkSASwapSnippet { inherit saSecretName saTokensDir serviceName; failMode = "soft"; }}
                                '';
                                saRestoreSnippet = lib.optionalString hasSAToken ''
                                  export OP_SERVICE_ACCOUNT_TOKEN="$__SC_SAVED_SA_TOKEN"
                                '';
                                envNames = lib.attrNames secretspecCfg.environments;
                              in ''
                              ${saSwapSnippet}
                              __sc_s1="n/a"; __sc_s2="n/a"
                              ${lib.concatStringsSep "\n" (map (envName: ''
                              if [ "$ENV1" = "${envName}" ]; then
                                if (cd ${config.git.root}/.saas-controller/secretspec/${serviceName} && ${pkgs.secretspec}/bin/secretspec check --profile ${envName} 2>/dev/null); then
                                  __sc_s1="✅ ok"
                                else
                                  __sc_s1="❌ missing"
                                fi
                              fi
                              if [ "$ENV2" = "${envName}" ]; then
                                if (cd ${config.git.root}/.saas-controller/secretspec/${serviceName} && ${pkgs.secretspec}/bin/secretspec check --profile ${envName} 2>/dev/null); then
                                  __sc_s2="✅ ok"
                                else
                                  __sc_s2="❌ missing"
                                fi
                              fi
                              '') envNames)}
                              __sc_marker=""
                              if [ "$__sc_s1" != "$__sc_s2" ]; then
                                __sc_marker="⚠️  DIFF"
                                DIFF_COUNT=$((DIFF_COUNT + 1))
                              fi
                              printf "%-25s %-15s %-15s %s\n" "${serviceName}" "$__sc_s1" "$__sc_s2" "$__sc_marker"
                              ${saRestoreSnippet}
                            '') secretspecServices)}

                            echo ""
                            if [ $DIFF_COUNT -eq 0 ]; then
                              echo "✅ No differences found between $ENV1 and $ENV2"
                            else
                              echo "⚠️  $DIFF_COUNT service(s) differ between $ENV1 and $ENV2"
                            fi
                            exit 0
                            ;;

                          reconcile-secrets)
                            RECON_ENV=""
                            shift
                            while [[ $# -gt 0 ]]; do
                              case $1 in
                                --environment|-e) RECON_ENV="$2"; shift 2 ;;
                                *) echo "❌ Error: Unknown option: $1" >&2; exit 1 ;;
                              esac
                            done

                            if [ -n "$RECON_ENV" ]; then
                              if [[ ! " local production preview " =~ " $RECON_ENV " ]]; then
                                echo "❌ Error: Invalid environment: $RECON_ENV" >&2
                                echo "  Valid environments: local, production, preview" >&2
                                exit 1
                              fi
                              ENVS="$RECON_ENV"
                            else
                              ENVS="local production preview"
                            fi

                            echo "🔐 Secret Reconciliation"
                            echo ""

                            MISSING_REQUIRED=0
                            for CURRENT_ENV in $ENVS; do
                              echo "━━━ Environment: $CURRENT_ENV ━━━"
                              echo ""

                              ${lib.concatStringsSep "\n" (lib.mapAttrsToList (serviceName: service:
                                let
                                  secretspecCfg = service.secretspec;
                                  hasAuth = secretspecCfg.auth != null;
                                  authLabel = if hasAuth then " (auth: ${secretspecCfg.auth.provider})" else "";
                                  hasSAToken = hasAuth && secretspecCfg.auth.saToken != null;
                                  saSecretName = if hasSAToken then toSASecretName secretspecCfg.auth.saToken else "";
                                  saTokensDir = config.saas-controller.saTokensDir;
                                  saSwapSnippet = lib.optionalString hasSAToken ''
                                    __SC_SAVED_SA_TOKEN="''${OP_SERVICE_ACCOUNT_TOKEN:-}"
                                    ${helpers.mkSASwapSnippet { inherit saSecretName saTokensDir serviceName; failMode = "soft"; }}
                                  '';
                                  saRestoreSnippet = lib.optionalString hasSAToken ''
                                    export OP_SERVICE_ACCOUNT_TOKEN="$__SC_SAVED_SA_TOKEN"
                                  '';
                                in
                                lib.concatStringsSep "\n" (lib.mapAttrsToList (envName: envCfg:
                                  let
                                    profiles = config.saas-controller.secretProfiles;
                                    providerObj = providers.${service.provider} or {};
                                    providerProfileNames = lib.attrNames (providerObj.secretProfiles or {});
                                    allProfileNames = lib.unique (providerProfileNames ++ envCfg.serviceProfiles);
                                    collectSecrets = profileNames:
                                      lib.foldl (acc: pn:
                                        let ps = profiles.${pn} or {};
                                        in acc // (lib.filterAttrs (n: _: ! (acc ? ${n})) ps)
                                      ) {} profileNames;
                                    profileSecrets = collectSecrets allProfileNames;
                                    inlineSecrets = envCfg.secrets or {};
                                    extraSecrets = lib.filterAttrs (n: _: ! (profileSecrets ? ${n})) inlineSecrets;
                                    allSecrets = profileSecrets // extraSecrets;
                                    secretCount = builtins.length (lib.attrNames allSecrets);
                                    requiredCount = builtins.length (lib.attrNames (lib.filterAttrs (_: s: (s.required or true) && (s.default or null) == null) allSecrets));
                                  in ''
                              if [ "$CURRENT_ENV" = "${envName}" ]; then
                                ${saSwapSnippet}
                                echo -n "  📋 ${serviceName}${authLabel} (${toString secretCount} secrets, ${toString requiredCount} required): "
                                if (cd ${config.git.root}/.saas-controller/secretspec/${serviceName} && ${pkgs.secretspec}/bin/secretspec check --profile ${envName} 2>/dev/null); then
                                  echo "✅ ok"
                                else
                                  echo "❌ MISSING"
                                  MISSING_REQUIRED=$((MISSING_REQUIRED + 1))
                                  echo "     Required secrets:"
                                  ${lib.concatStringsSep "\n" (lib.mapAttrsToList (secretName: secretDef:
                                    lib.optionalString ((secretDef.required or true) && (secretDef.default or null) == null)
                                    ''echo "     - ${secretName}: ${secretDef.description}"''
                                  ) allSecrets)}
                                fi
                                ${saRestoreSnippet}
                              fi
                                '') secretspecCfg.environments)
                              ) secretspecServices)}
                              echo ""
                            done

                            if [ $MISSING_REQUIRED -gt 0 ]; then
                              echo "⚠️  $MISSING_REQUIRED service/environment(s) have missing secrets"
                              exit 1
                            else
                              echo "✅ All required secrets are present"
                            fi
                            exit 0
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
                                  hasSecretspec = service.secretspec != null;
                                  hasAuth = hasSecretspec && service.secretspec.auth != null;
                                  hasSAToken = hasAuth && service.secretspec.auth.saToken != null;
                                  saSecretName = if hasSAToken then toSASecretName service.secretspec.auth.saToken else "";
                                  saTokensDir = config.saas-controller.saTokensDir;
                                  saSwapSnippet = lib.optionalString hasSAToken (helpers.mkSASwapSnippet {
                                    inherit saSecretName saTokensDir serviceName;
                                  });
                                  secretspecDir = "${config.git.root}/.saas-controller/secretspec/${serviceName}";

                                  # Wrap upScript with secretspec run if service has secretspec
                                  wrappedUpScript = if hasSecretspec then ''
                                    ${saSwapSnippet}
                                    __sc_up() {
                                      ${upScript}
                                    }
                                    export -f __sc_up
                                    cd "${secretspecDir}"
                                    ${pkgs.secretspec}/bin/secretspec run --profile "$ENVIRONMENT" -- bash -c '__sc_up'
                                  '' else upScript;
                                in
                                lib.optionalString (hasLocal && hasUp) ''
                                  if [ "$SERVICE" = "${serviceName}" ]; then
                                    FOUND=true
                                    COMPOSE_DIRS+=("${config.git.root}/.saas-controller/compose/${serviceName}")
                                    (
                                      ${wrappedUpScript}
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
                                  hasSecretspec = service.secretspec != null;
                                  hasAuth = hasSecretspec && service.secretspec.auth != null;
                                  hasSAToken = hasAuth && service.secretspec.auth.saToken != null;
                                  saSecretName = if hasSAToken then toSASecretName service.secretspec.auth.saToken else "";
                                  saTokensDir = config.saas-controller.saTokensDir;
                                  saSwapSnippet = lib.optionalString hasSAToken (helpers.mkSASwapSnippet {
                                    inherit saSecretName saTokensDir serviceName;
                                  });
                                  secretspecDir = "${config.git.root}/.saas-controller/secretspec/${serviceName}";

                                  wrappedUpScript = if hasSecretspec then ''
                                    ${saSwapSnippet}
                                    __sc_up() {
                                      ${upScript}
                                    }
                                    export -f __sc_up
                                    cd "${secretspecDir}"
                                    ${pkgs.secretspec}/bin/secretspec run --profile "$ENVIRONMENT" -- bash -c '__sc_up'
                                  '' else upScript;
                                in
                                lib.optionalString (hasLocal && hasUp) ''
                                  COMPOSE_DIRS+=("${config.git.root}/.saas-controller/compose/${serviceName}")
                                  (
                                    ${wrappedUpScript}
                                  ) &
                                ''
                              ) enabledServices)}
                              wait
                            fi
                            ;;

                          deploy)
                            # Default environment for 'deploy' is 'production'
                            ENVIRONMENT="''${ENVIRONMENT:-production}"

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

                          undeploy)
                            if [ -z "$SERVICE" ]; then
                              echo "❌ Error: Service name required for undeploy" >&2
                              echo "  Usage: sc undeploy <service>" >&2
                              exit 1
                            fi

                            STATE_FILE="${config.git.root}/.saas-controller/deploy/$SERVICE/state.json"
                            if [ ! -f "$STATE_FILE" ]; then
                              echo "❌ Error: No deployment state found for $SERVICE" >&2
                              echo "  Expected: $STATE_FILE" >&2
                              exit 1
                            fi

                            PLATFORM=$(${pkgs.jq}/bin/jq -r '.platform' "$STATE_FILE")
                            SVC_ID=$(${pkgs.jq}/bin/jq -r '.serviceIdentifier' "$STATE_FILE")
                            COMPOSE_CMD=$(${pkgs.jq}/bin/jq -r '.composeCmd' "$STATE_FILE")

                            echo "Undeploying: $SERVICE"

                            case "$PLATFORM" in
                              Darwin)
                                launchctl bootout "gui/$(id -u)/$SVC_ID" 2>/dev/null || true
                                rm -f "$HOME/Library/LaunchAgents/$SVC_ID.plist"
                                echo "  Launchd agent removed: $SVC_ID"
                                ;;
                              Linux)
                                systemctl --user disable --now "$SVC_ID" 2>/dev/null || true
                                rm -f "$HOME/.config/systemd/user/$SVC_ID.service"
                                systemctl --user daemon-reload
                                echo "  Systemd service removed: $SVC_ID"
                                ;;
                              *)
                                echo "  Warning: Unknown platform '$PLATFORM', skipping service removal" >&2
                                ;;
                            esac

                            # Stop compose stack
                            if [ -n "$COMPOSE_CMD" ]; then
                              $COMPOSE_CMD down 2>/dev/null || true
                            fi

                            # Clean up state
                            rm -f "$STATE_FILE"

                            echo "✅ Service undeployed: $SERVICE"
                            ;;

                          help|--help|-h|"")
                            cat <<EOF
            SaaS Controller - Unified interface for managing services

            Usage:
              sc <command> [service] [--environment <env>]

            Commands:
              up                Start local dev services via docker-compose (default env: local)
              deploy            Deploy service(s) with pre/post hooks (default env: production)
              undeploy          Remove a persistent service installed by deploy
              check-secrets     Validate secrets for all services
              secret-status     Show secret-to-service mapping table
              setup-env         Report secret status for an environment
              diff-secrets      Compare secret status between two environments
              reconcile-secrets Show comprehensive secret status across environments
              help              Show this help message

            Examples:
              sc up                                      # Start all local services
              sc up atlas3-dev-gateway                   # Start specific service
              sc up --environment preview                # Start all services for preview env

              sc deploy                                  # Deploy all to production (default)
              sc deploy --environment production         # Deploy all to production
              sc deploy atlas3-dev-gateway -e preview     # Deploy specific service to preview

              sc undeploy atlas3-dev-gateway             # Remove persistent service

              sc check-secrets                           # Check all service secrets
              sc check-secrets --tag tailscale           # Check only tailscale-tagged services
              sc check-secrets --service test-gateway    # Check specific service

              sc secret-status                           # Show secret-to-service mapping

              sc setup-env production                    # Check all secrets for production
              sc diff-secrets local production           # Compare secrets between environments
              sc reconcile-secrets                       # Show all secrets across all environments
              sc reconcile-secrets -e production         # Show secrets for one environment

            Options:
              --environment, -e <env>   Target environment (local, production, preview)
                                        Defaults: up=local, deploy=production
              --help, -h                Show this help message

            Note: Deploy runs pre-hooks, deploys the service, then runs post-hooks automatically.
                  Deployment credentials must be in the environment (e.g., via CI secrets).
                  For docker-compose provider, deploy installs a persistent launchd/systemd service.
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

                # Write secretspec TOML to deploy dir for persistent service wrappers
                hasSecretspec = service.secretspec != null;
                tomlContent = if hasSecretspec then mkServiceSecretspecToml serviceName service else "";
                writeToml = lib.optionalString hasSecretspec ''
                  mkdir -p ${config.git.root}/.saas-controller/deploy/${serviceName}
                  cat > ${config.git.root}/.saas-controller/deploy/${serviceName}/secretspec.toml <<'__SECRETSPEC_TOML_EOF'
${tomlContent}
__SECRETSPEC_TOML_EOF
                '';

                # Augment the pre-deploy task to write TOML before hooks
                augmentedPreDeployTask = {
                  name = preDeployTask.name;
                  value = preDeployTask.value // {
                    exec = ''
                      ${writeToml}
                      ${preDeployTask.value.exec}
                    '';
                  };
                };
                serviceDeps = helpers.buildDeployDependencies serviceName service;
              in
              [
                # Pre-deploy task (depends on other services' post-deploy tasks, writes secretspec TOML)
                (lib.nameValuePair augmentedPreDeployTask.name (augmentedPreDeployTask.value // (lib.optionalAttrs (serviceDeps != [ ]) {
                  after = serviceDeps;
                })))
                # Deploy task (depends on pre-deploy)
                (lib.nameValuePair deployTask.name (deployTask.value // {
                  after = [ augmentedPreDeployTask.name ];
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

{ lib, config }:

let
  # Helper to get all enabled environments for a service or export
  getEnabledEnvironments = cfg:
    lib.filterAttrs (_: env: env.enable) cfg.environments;

  enabledServices = lib.filterAttrs (_: cfg: cfg.enable) config.saas-controller.services;
  enabledSecretExports = lib.filterAttrs (_: cfg: cfg.enable) config.saas-controller.secret-exports;

in
{
  # Validate that a service dependency exists
  validateServiceDependency = serviceName: depName:
    let
      depExists = lib.hasAttr depName enabledServices;
    in
    if !depExists then
      throw "Service '${serviceName}' depends on '${depName}', but '${depName}' is not defined or not enabled"
    else
      true;

  # Validate that a secret export dependency exists
  validateSecretExportDependency = exportName: depName:
    let
      depExists = lib.hasAttr depName enabledSecretExports;
    in
    if !depExists then
      throw "Secret export '${exportName}' depends on '${depName}', but '${depName}' is not defined or not enabled"
    else
      true;

  # Validate that a service's secretExportDependency exists
  validateServiceSecretExportDependency = serviceName: exportName:
    let
      exportExists = lib.hasAttr exportName enabledSecretExports;
    in
    if !exportExists then
      throw "Service '${serviceName}' depends on secret export '${exportName}', but '${exportName}' is not defined or not enabled"
    else
      true;

  # Validate all dependencies for services
  validateAllServiceDependencies =
    let
      # Check service-to-service dependencies
      serviceDepsValid = lib.all
        (service:
          lib.all
            (dep:
              lib.hasAttr dep enabledServices
            )
            service.dependencies
        )
        (lib.attrValues enabledServices);

      # Check service-to-secret-export dependencies
      secretExportDepsValid = lib.all
        (service:
          lib.all
            (exportName:
              lib.hasAttr exportName enabledSecretExports
            )
            service.secretExportDependencies
        )
        (lib.attrValues enabledServices);

      # Collect error messages
      errors = lib.flatten [
        (lib.mapAttrsToList
          (serviceName: service:
            map
              (dep:
                if !(lib.hasAttr dep enabledServices) then
                  "Service '${serviceName}' depends on service '${dep}', but '${dep}' is not defined or not enabled"
                else
                  null
              )
              service.dependencies
          )
          enabledServices)
        (lib.mapAttrsToList
          (serviceName: service:
            map
              (exportName:
                if !(lib.hasAttr exportName enabledSecretExports) then
                  "Service '${serviceName}' depends on secret export '${exportName}', but '${exportName}' is not defined or not enabled"
                else
                  null
              )
              service.secretExportDependencies
          )
          enabledServices)
      ];

      actualErrors = lib.filter (e: e != null) errors;
    in
    if actualErrors != [ ] then
      throw "Dependency validation failed:\n${lib.concatStringsSep "\n" actualErrors}"
    else
      true;

  # Validate all dependencies for secret exports
  validateAllSecretExportDependencies =
    let
      errors = lib.flatten (lib.mapAttrsToList
        (exportName: exportConfig:
          map
            (depName:
              if !(lib.hasAttr depName enabledSecretExports) then
                "Secret export '${exportName}' depends on '${depName}', but '${depName}' is not defined or not enabled"
              else
                null
            )
            exportConfig.dependencies
        )
        enabledSecretExports);

      actualErrors = lib.filter (e: e != null) errors;
    in
    if actualErrors != [ ] then
      throw "Secret export dependency validation failed:\n${lib.concatStringsSep "\n" actualErrors}"
    else
      true;

  # Detect circular dependencies using depth-first search
  # Returns true if valid, throws error if circular dependency detected
  detectCircularDependencies =
    let
      # Build dependency graph for services
      serviceDepsGraph = lib.mapAttrs
        (name: service:
          service.dependencies
        )
        enabledServices;

      # Build dependency graph for secret exports
      exportDepsGraph = lib.mapAttrs
        (name: exportConfig:
          exportConfig.dependencies
        )
        enabledSecretExports;

      # Check for cycles in a graph using DFS
      hasCycle = graph: start: visited: stack:
        if lib.elem start stack then
          throw "Circular dependency detected: ${lib.concatStringsSep " → " (stack ++ [start])}"
        else if lib.elem start visited then
          false
        else
          let
            newStack = stack ++ [ start ];
            newVisited = visited ++ [ start ];
            deps = graph.${start} or [ ];
          in
          lib.any (dep: hasCycle graph dep newVisited newStack) deps;

      # Check all nodes in the graph
      checkGraph = graph:
        lib.all (start: !(hasCycle graph start [ ] [ ])) (lib.attrNames graph);

    in
    checkGraph serviceDepsGraph && checkGraph exportDepsGraph;

  # Run all validations
  validateAll =
    validateAllServiceDependencies &&
    validateAllSecretExportDependencies &&
    detectCircularDependencies;
}

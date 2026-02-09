{ pkgs, lib, config, ... }:

{
  # Import the saas-controller module
  imports = [ ../../devenv.nix ];

  # Configure the test-gateway service
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
      saToken = "client-willdan";
      environments = {
        local = { serviceProfiles = [ "tailscale" ]; };
      };
      tags = [ "tailscale" "zuplo" ];
    };
  };
}

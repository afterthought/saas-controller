{ pkgs, lib, config, ... }:

{
  # Import the saas-controller module
  imports = [ ../../devenv.nix ];

  # Register the hello-world provider as an external provider
  saas-controller.externalProviders.hello-world = ./provider.nix;

  # Configure the hello-world service
  saas-controller.services.hello-world = {
    enable = true;
    displayName = "Hello World";
    provider = "hello-world";
    providerConfig.path = "examples/hello-world";
    environments.local.enable = true;
  };
}

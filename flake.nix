{
  description = "NixOS in MicroVMs";

  nixConfig = {
    extra-substituters = [ "https://microvm.cachix.org" ];
    extra-trusted-public-keys = [ "microvm.cachix.org-1:oXnBc6hRE3eX5rSYdRyMYXnfzcCxC7yKPTbZXALsqys=" ];
  };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    microvm = {
      url = "github:microvm-nix/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, microvm }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
    in {
      packages.${system} = {
        default = self.packages.${system}.agent-vm;
        agent-vm = self.nixosConfigurations.agent-vm.config.microvm.declaredRunner;
      };

      nixosConfigurations = {
        agent-vm = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            microvm.nixosModules.microvm
            ({ config, ... }: {
              networking.hostName = "agent-vm";
              networking.useDHCP = true;

              programs.zsh.enable = true;

              users.users.root.password = "";
              users.users.agent = {
                isNormalUser = true;
                uid = 1000;
                openssh.authorizedKeys.keys = [
                  # Optional: replace with your public SSH key
                  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMxr0CoUGmzn4nPIhddJbZzOYy1WpCkewbiSTa8BKp4c shahin-fw"
                ];
              };

              security.sudo.extraRules = [
                {
                  users = [ "agent" ];
                  commands = [
                    {
                      command = "/run/current-system/sw/bin/shutdown";
                      options = [ "NOPASSWD" ];
                    }
                  ];
                }
              ];

              microvm = {
                hypervisor = "qemu";
                socket = "control.socket";
                mem = 16384;
                vcpu = 8;
                
                writableStoreOverlay = "/nix/.rw-store";
                volumes = [
                  {
                    mountPoint = "/var";
                    image = "var.img";
                    size = 256;
                  }
                  {
                    image = "nix-store-overlay.img";
                    mountPoint = config.microvm.writableStoreOverlay;
                    size = 30720;
                  }
                ];

                shares = [
                  {
                    proto = "9p";
                    tag = "ro-store";
                    source = "/nix/store";
                    mountPoint = "/nix/.ro-store";
                  }
                  {
                    proto = "virtiofs";
                    tag = "agent-home";
                    source = "/var/lib/microvms/agent-home";
                    mountPoint = "/home/agent";
                  }
                ];

                interfaces = [
                  {
                    type = "user";
                    id = "net0";
                    mac = "52:54:00:12:34:56";
                  }
                ];

                forwardPorts = [
                  {
                    from = "host";
                    proto = "tcp";
                    host.port = 2222;
                    guest.port = 22;
                  }
                  {
                    from = "host";
                    proto = "tcp";
                    host.port = 4096;
                    guest.port = 4096;
                  }
                ];
              };
              nix.settings = {
                allowed-users = [ "agent" ];
                trusted-users = [ "root" "agent" "@wheel" ];
              };
              
              services.openssh = {
                enable = true;
                settings.PasswordAuthentication = false;
                settings.PermitRootLogin = "no";
              };

              networking.firewall.enable = true;
              networking.firewall.allowedTCPPorts = [ 22 443 4096 ];

              environment.systemPackages = with pkgs; [
                git
                claude-code
                gemini-cli
                devenv
                direnv
                nix-direnv
                emacs
                vim
                opencode
                tmux
                nodejs_24 # useful to install agent skills
                gh
                # Python + MCP for searx-mcp server (AI-powered web search)
                (python3.withPackages (ps: with ps; [ mcp httpx ]))
              ];

              # OpenCode headless server — accepts remote commands via
              # `opencode run --attach http://localhost:4096 ...` from the host.
              # Also serves a web UI at http://localhost:4096 (port forwarded).
              systemd.services.opencode-serve = {
                description = "OpenCode headless server";
                after = [ "network.target" ];
                wantedBy = [ "multi-user.target" ];
                serviceConfig = {
                  User = "agent";
                  Group = "users";
                  WorkingDirectory = "/home/agent";
                  ExecStart = "${pkgs.opencode}/bin/opencode serve --port 4096 --hostname 0.0.0.0";
                  Restart = "on-failure";
                  RestartSec = 5;
                };
              };

              services.getty.autologinUser = "agent";
              system.stateVersion = "25.11";
            })
          ];
        };
      };
    };
}

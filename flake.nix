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
    meridian = {
      url = "github:rynfar/meridian";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, microvm, meridian }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays = [ meridian.overlays.default ];
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
            {
              # Expose meridian package into the NixOS module evaluation.
              nixpkgs.overlays = [ meridian.overlays.default ];
            }
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
                    {
                      command = "/run/current-system/sw/bin/systemctl";
                      options = [ "NOPASSWD" ];
                    }
                  ];
                }
              ];

              # Give a root shell at the initrd emergency prompt. Without this,
              # the initrd locks root and sulogin refuses, so a failed
              # switch-root leaves you with no way in over the console.
              boot.initrd.systemd.emergencyAccess = true;

              microvm = {
                hypervisor = "qemu";
                socket = "control.socket";
                mem = 16384;
                vcpu = 8;

                # The writable store overlay below is persistent, so the guest's
                # Nix db survives reboots. Boot-time closure registration clashes
                # with that (see microvm.nix docs), which can fail activation on
                # generation changes. Disable it for a persistent overlay.
                registerClosure = false;

                writableStoreOverlay = "/nix/.rw-store";
                volumes = [
                  {
                    mountPoint = "/var";
                    image = "var.img";
                    size = 4096;   # was 256 MB — too small for journald + agents
                  }
                  {
                    image = "nix-store-overlay.img";
                    mountPoint = config.microvm.writableStoreOverlay;
                    size = 81920;
                  }

                  # REGENERABLE scratch lives on VM-local ext4, NOT on the
                  # virtiofs home. /home/agent is a virtiofs share of the host,
                  # so every write under it is a guest->host round trip, and the
                  # cache is pure write-churn: opencode's 2.3G package cache plus
                  # pip / npm / nix / uv / pre-commit build artifacts, all of
                  # which rebuild themselves if lost. A fresh ext4 image mounted
                  # over ~/.cache shadows the virtiofs copy, so that churn never
                  # leaves the guest, and losing it on a redeploy costs nothing.
                  # Ownership is fixed post-mount by the tmpfiles rule below
                  # (a fresh ext4 mounts root-owned).
                  #
                  # DELIBERATELY ONLY ~/.cache. ~/.local/share is NOT relocated:
                  # it holds opencode's session-history DB (~6.3G) and auth.json,
                  # which are PRECIOUS and must stay on the durable virtiofs home
                  # -- that dir is a plain host directory, so it survives a VM
                  # redeploy and is covered by the host's backups, whereas a
                  # VM-local image is neither. The rule is regenerable->local,
                  # precious->durable-home, not agent-internal->local. The DB's
                  # SQLite churn on virtiofs is the accepted price of keeping it
                  # durable; its write RATE is modest next to build caches, and
                  # the E-core pin on the host bounds the residual blast radius.
                  {
                    mountPoint = "/home/agent/.cache";
                    image = "cache.img";
                    size = 20480;
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
                  {
                    from = "host";
                    proto = "tcp";
                    host.port = 4097;
                    guest.port = 4097;
                  }
                  # Plannotator review UI. A range so multiple pi sessions
                  # (one per project, via opi) can each bind a free port:
                  # PLANNOTATOR_PORT=19432-19436 picks the first free one.
                  {
                    from = "host";
                    proto = "tcp";
                    host.port = 19432;
                    guest.port = 19432;
                  }
                  {
                    from = "host";
                    proto = "tcp";
                    host.port = 19433;
                    guest.port = 19433;
                  }
                  {
                    from = "host";
                    proto = "tcp";
                    host.port = 19434;
                    guest.port = 19434;
                  }
                  {
                    from = "host";
                    proto = "tcp";
                    host.port = 19435;
                    guest.port = 19435;
                  }
                  {
                    from = "host";
                    proto = "tcp";
                    host.port = 19436;
                    guest.port = 19436;
                  }
                ];
              };
              nix.settings = {
                allowed-users = [ "agent" ];
                trusted-users = [ "root" "agent" "@wheel" ];
                # min-free / max-free are DELIBERATELY UNSET.
                #
                # They would make nix-daemon collect garbage on demand when a
                # build runs low on space -- which is the same destructive
                # sweep the disabled nix.gc timer performs, merely triggered by
                # a build instead of a clock. Nix's collector walks the store
                # DIRECTORY and deletes every entry it cannot find in its
                # database; the 9p lower layer is full of exactly such entries,
                # so it whites them out. See the nix.gc comment below.
                #
                # The obvious objection is "then a build will die with ENOSPC".
                # It might, and that is the better failure: a build that fails
                # is retried after reclaiming space, whereas a whiteout storm
                # leaves a VM that cannot run `nix` at all and needs its image
                # rebuilt from the host.
                #
                # It would also not have bought much. Measured 2026-08-27 during
                # a live GC: about 11000 additional whiteouts freed roughly
                # 0.1 GB. That is the whole problem in one number -- the space
                # is not in this image, it is on the host, and "deleting" a
                # lower-layer path frees nothing here while costing an inode
                # for the whiteout. Collection is not a space-management tool in
                # this VM; it is only damage.
                #
                # SEE "reclaiming space" IN THE nix.gc COMMENT for what to do
                # instead.

                # Cap build parallelism. The default is "auto", i.e. one job per
                # vCPU -- 8 here -- and each job can itself spawn cores worth of
                # compilation, so an unattended build can ask for far more than
                # the laptop can dissipate. The VM is for agent work, not a
                # build farm; 2 jobs still parallelise well while leaving the
                # machine usable and cool.
                max-jobs = 2;
                keep-derivations = false;
                keep-outputs = false;
              };
              # AUTOMATIC GARBAGE COLLECTION IS OFF, AND MUST STAY OFF.
              #
              # Not a tuning preference: in this VM a store GC is actively
              # DESTRUCTIVE, because of two settings that look unrelated.
              #
              #   * /nix/store here is an OVERLAY whose lowerdir is a read-only
              #     9p share of the HOST's store. Only the upper layer
              #     (/nix/.rw-store, a persistent ext4 image) is writable.
              #   * registerClosure = false (above) means the guest's Nix
              #     DATABASE has no record of the paths arriving via that lower
              #     layer.
              #
              # A GC deletes whatever it cannot prove is reachable from a
              # gcroot. Since the database does not know the host-provided
              # paths, it cannot prove anything about them, so it treats the
              # running system's own closure as garbage. It cannot truly delete
              # from a read-only lower layer, so overlayfs records a WHITEOUT in
              # the upper layer instead -- a character device 0,0 that hides the
              # still-present host path from the guest.
              #
              # The VM quietly eats itself. Observed 2026-08-27: 45412 whiteouts
              # in the upper layer, `awk` gone from PATH, and `nix` itself
              # unable to start because the nix-main and curl libraries in its
              # RUNPATH had been whited out ("error while loading shared
              # libraries: libnixmain.so.2.34.8"). The same damage happened on
              # 2026-08-09 via a manual `nix-collect-garbage -d`, which left
              # /run/current-system dangling. That was recorded as "never run GC
              # by hand in the VM" -- but the DAILY TIMER had been doing exactly
              # that automatically all along.
              #
              # The damage is PERSISTENT: whiteouts live in the upper-layer
              # image, so a reboot does not clear them. Recovery means
              # recreating nix-store-overlay.img, not restarting the VM.
              #
              # It is expensive while it happens, too. Every lookup is a 9p
              # round trip to the host, so a GC using about one guest core
              # showed up as 248% CPU on the HOST -- roughly 2.5 cores -- and
              # drove the laptop to 86-100 C while the user's whole desktop
              # session used 7.7%. It sat in uninterruptible D state on 9p IO,
              # so it could not even be killed promptly.
              #
              # RECLAIMING SPACE WITHOUT COLLECTING GARBAGE
              #
              # The fair objection to disabling GC is "then the 79 GB overlay
              # fills up". Three things make that far less pressing than it
              # sounds, and there is a safe procedure for when it does.
              #
              # 1. Collection barely reclaims anything HERE anyway. Measured
              #    2026-08-27 during a live GC: ~11000 further whiteouts freed
              #    about 0.1 GB. Most of what it "deletes" lives on the host's
              #    read-only layer, where deleting frees nothing in this image
              #    and merely spends an inode on the whiteout. Of 73260 entries
              #    in the upper layer, 56572 were whiteouts and only 16688 real
              #    paths -- the collector had spent most of its effort making
              #    the VM smaller in capability, not in bytes.
              #
              # 2. Headroom is larger than it looks: 7.7 GB of 79 GB used (11%),
              #    866166 of 5242880 inodes (17%). Both grow only when the VM
              #    BUILDS something, and max-jobs = 2 above bounds how fast.
              #
              # 3. The upper layer holds nothing irreplaceable -- only store
              #    paths built inside the VM, every one of which can be rebuilt
              #    or refetched. /home/agent is a separate virtiofs share and is
              #    NOT affected.
              #
              # So the reclaim procedure is to recreate the image, from the HOST,
              # with the VM stopped:
              #
              #   systemctl stop microvm@agent-vm
              #   rm /var/lib/microvms/agent-vm/nix-store-overlay.img
              #   systemctl start microvm@agent-vm     # recreated empty, 80 GB
              #
              # That is instant, frees everything at once, and cannot corrupt
              # anything. It is also the ONLY way to clear whiteouts already
              # written by earlier collections.
              #
              # THE REAL FIX, if this VM ever needs routine collection:
              # registerClosure = true, so the guest database knows about the
              # paths on the lower layer and the collector can prove them
              # reachable. The comment on registerClosure above explains why it
              # is off -- it conflicts with the persistent writable overlay.
              # Changing that is a design decision about this VM, not a tweak,
              # and it should be made deliberately rather than by re-enabling
              # the timer and hoping.
              nix.gc.automatic = false;

              # Builds still hammer the store through the same 9p path, but
              # unlike a GC something is usually waiting on them. Give them
              # weight rather than a cap: full speed when the laptop is idle,
              # yielding as soon as the user's session wants the CPU.
              #
              # WHICH LEVERS WORK HERE, since the obvious ones do not: the
              # store's lower layer is a 9p share, not a block device, so its
              # traffic never reaches the guest block layer and no block-IO
              # control (ionice, IOWeight, IOReadIOPSMax) can see it. The guest
              # block queues also use the `none` scheduler (verified via
              # /sys/block/vd*/queue/scheduler), and IOSchedulingClass is only
              # honoured by BFQ -- so it would be a no-op that merely looks like
              # a fix. CPU is the only enforceable lever, and it suffices: every
              # 9p request is issued by a running thread, so limiting cycles
              # limits the request rate reaching the host. The cpu controller is
              # confirmed delegated to system.slice.
              systemd.services.nix-daemon.serviceConfig = {
                CPUWeight = 20;
              };

              services.openssh = {
                enable = true;
                settings.PasswordAuthentication = false;
                settings.PermitRootLogin = "no";
              };

              networking.firewall.enable = true;
              # 19432-19436: plannotator review UI (multi-session port range).
              networking.firewall.allowedTCPPorts = [ 22 443 4096 4097 19432 19433 19434 19435 19436 ];

              # The cache.img volume above mounts a fresh, root-owned ext4 over
              # ~/.cache. systemd-tmpfiles-setup runs after local-fs.target
              # (i.e. after that mount), so this `d` rule adjusts the
              # just-mounted dir rather than the shadowed virtiofs one, handing
              # it to agent:users.
              systemd.tmpfiles.rules = [
                "d /home/agent/.cache 0755 agent users - -"
                # Persist pi's jiti TypeScript-transpile cache off tmpfs. jiti
                # writes to os.tmpdir()/jiti = /tmp/jiti, and /tmp is tmpfs, so
                # every reboot wiped it and forced a full ~90s cold retranspile
                # of pi's ~500 bundled extension modules on the first launch.
                # Symlinking that path onto the durable ~/.cache ext4 keeps the
                # cache across reboots (measured: cold ~90s -> warm ~40s). The
                # transpiled files live in ~/.cache/jiti; only the symlink is
                # recreated each boot (tmpfs /tmp is fresh, ~/.cache persists).
                "d /home/agent/.cache/jiti 0755 agent users - -"
                "L+ /tmp/jiti - - - - /home/agent/.cache/jiti"
              ];

              # Python writes __pycache__ INSIDE the source tree by default,
              # which for the virtiofs-mounted repos means a guest->host write on
              # every import. Mirror the bytecode under the now-VM-local cache
              # instead (no collisions: the prefix mirrors the full tree). The
              # other common in-tree offender, direnv's .direnv, needs a
              # $PWD-hashing direnvrc rather than a static var (a fixed
              # DIRENV_LAYOUT_DIR would collide across projects), so it is left
              # for a follow-up rather than set incorrectly here.
              environment.variables = {
                PYTHONPYCACHEPREFIX = "/home/agent/.cache/pycache";
                # Persist Node's V8 bytecode compile cache off tmpfs as well, so
                # the pi CLI bundle (and other node tools) skip recompilation
                # across reboots. Node creates the dir on demand. Pairs with the
                # jiti symlink above; together they keep first-launch-after-
                # reboot at the warm ~40s rather than the ~90s cold path.
                NODE_COMPILE_CACHE = "/home/agent/.cache/node-compile-cache";
              };

              environment.systemPackages = with pkgs; [
                git
                claude-code
                meridian
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
                pi-coding-agent
                # Python + MCP for searx-mcp server (AI-powered web search)
                uv
                (python3.withPackages (ps: with ps; [ mcp httpx ]))
              ];

              # Meridian — local Anthropic API from the Claude Max subscription.
              # Both pi (models.json override) and opencode (per-session) point
              # at this proxy. Runs as a daemon on the VM.
              systemd.services.meridian = {
                description = "Meridian Claude Max proxy";
                after = [ "network.target" ];
                wantedBy = [ "multi-user.target" ];
                serviceConfig = {
                  User = "agent";
                  Group = "users";
                  WorkingDirectory = "/home/agent";
                  ExecStart = "${pkgs.meridian}/bin/meridian";
                  Restart = "on-failure";
                  RestartSec = 5;
                };
                environment =
                  let
                    # Content scrubbers strip each harness's identity fingerprints
                    # from the system prompt before it reaches Claude, so Anthropic
                    # does not meter pi/opencode traffic as third-party Extra Usage
                    # (the harness-added prompt data that caused the rate-limit
                    # churn). pi-scrub is adapter-scoped to pi, opencode-scrub to
                    # opencode; both ship prebuilt from the meridian flake overlay
                    # (pkgs.meridianPlugins.<name>, already locked in flake.lock).
                    pluginsJson = (pkgs.formats.json { }).generate "meridian-plugins.json" {
                      plugins = [
                        {
                          path = pkgs.meridianPlugins.pi-scrub.path;
                          enabled = true;
                        }
                        {
                          path = pkgs.meridianPlugins.opencode-scrub.path;
                          enabled = true;
                        }
                      ];
                    };
                  in
                  {
                    HOME = "/home/agent";
                    # Ensure the claude CLI (agent SDK backend) is findable;
                    # the unit's inherited PATH is minimal (systemd default).
                    PATH = nixpkgs.lib.mkForce "/run/current-system/sw/bin";
                    # Default all adapters to passthrough so clients (pi, opencode)
                    # run their own tool loops and Meridian only forwards tool
                    # calls. Without this the daemon comes up in "internal" mode:
                    # pi warns that its tools aren't forwarded, and opencode's own
                    # agentic loop desyncs ("session advanced while waiting").
                    MERIDIAN_PASSTHROUGH = "1";
                    # Load the prompt scrubbers via an explicit manifest. This
                    # overrides Meridian's auto-discovered
                    # ~/.config/meridian/plugins.json, whose lone entry pointed at
                    # the non-persistent ~/.cache and so never survived rebuild.
                    # The store-path references keep the built plugins GC-rooted
                    # through the service closure.
                    MERIDIAN_PLUGIN_CONFIG = "${pluginsJson}";
                  };
              };

              # Meridian's opencode plugin lives in the nix store; symlink it
              # to a stable path so ~/.config/opencode/opencode.json can
              # reference it without breaking on rebuild. The store path keeps
              # the sibling priority-attestation.ts import resolvable.
              environment.etc."meridian/plugin/meridian.ts".source =
                "${pkgs.meridian}/lib/meridian/plugin/meridian.ts";

              # Search web app runs as a user service from
              # ~/.config/systemd/user/search-web.service (on the virtiofs
              # mount).  This avoids needing sudo to restart it and keeps
              # the app config co-located with the other search files.

              services.getty.autologinUser = "agent";
              system.stateVersion = "25.11";
            })
          ];
        };
      };
    };
}

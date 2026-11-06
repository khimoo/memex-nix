{ pkgs }:
let
  inherit (pkgs) lib;
  evaluate = settings: platform:
    (lib.evalModules {
      specialArgs.pkgs = pkgs // { stdenv = pkgs.stdenv // platform; };
      modules = [
        ../nix/hm-module.nix
        ({ lib, ... }: {
          options = {
            assertions = lib.mkOption { type = lib.types.listOf lib.types.attrs; default = [ ]; };
            home.packages = lib.mkOption { type = lib.types.listOf lib.types.package; default = [ ]; };
            home.homeDirectory = lib.mkOption { default = "/home/test"; };
            home.activation = lib.mkOption { default = { }; };
            xdg.dataHome = lib.mkOption { default = "/home/test/.local/share"; };
            systemd.user.services = lib.mkOption { default = { }; };
            systemd.user.paths = lib.mkOption { default = { }; };
            systemd.user.timers = lib.mkOption { default = { }; };
            launchd.agents = lib.mkOption { default = { }; };
          };
          config.services.memex = lib.recursiveUpdate {
            enable = true;
            vaultDir = "/home/test/vault";
            sync.enable = true;
          } settings;
        })
      ];
    }).config;
  linux = { isLinux = true; isDarwin = false; };
  darwin = { isLinux = false; isDarwin = true; };
  manual = evaluate { } linux;
  automatic = evaluate { sync.autoSync = true; } linux;
  mac = evaluate { sync.autoSync = true; } darwin;
  disabled = evaluate { sync.enable = false; sync.autoSync = true; } linux;
  valid = cfg: lib.all (entry: entry.assertion) cfg.assertions;
  names = builtins.attrNames;
  legacyRejected = name: !(valid (evaluate { ${name}.enable = false; } linux));
in
assert valid manual;
assert manual.services.memex.sync.autoSync == false;
assert names manual.systemd.user.services == [ ];
assert names manual.systemd.user.paths == [ ];
assert names manual.systemd.user.timers == [ ];
assert names disabled.systemd.user.services == [ ];
assert disabled.home.packages == [ ];
assert map lib.getName manual.home.packages == [ "memex-setup" "memex-sync" "git-annex" "rclone" ];
assert names automatic.systemd.user.services == [ "memex-sync" ];
assert names automatic.systemd.user.paths == [ "memex-sync" ];
assert names automatic.systemd.user.timers == [ "memex-sync" ];
assert automatic.systemd.user.paths.memex-sync.Path.PathModified == [ "/home/test/vault/.git/logs/HEAD" ];
assert automatic.systemd.user.timers.memex-sync.Timer.OnUnitActiveSec == "900s";
assert names mac.launchd.agents == [ "memex-sync" ];
assert mac.launchd.agents.memex-sync.config.WatchPaths == [ "/home/test/vault/.git/logs/HEAD" ];
assert lib.all legacyRejected [ "attachments" "papis" "originals" ];
assert !(valid (evaluate { sync.folder = "../outside"; } linux));
assert !(valid (evaluate { sync.folder = "/absolute"; } linux));
true

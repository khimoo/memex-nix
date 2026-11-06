{
  description = "memex の home-manager モジュール。Obsidian、vault の骨格、ホワイトリスト式 Drive 同期を提供する";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      skeletonFor = system: import ./nix/skeleton.nix {
        pkgs = nixpkgs.legacyPackages.${system};
      };
      seedVaultFor = system: import ./nix/seed-vault.nix {
        pkgs = nixpkgs.legacyPackages.${system};
        skeleton = skeletonFor system;
      };
      mirrorVaultFor = system: import ./nix/mirror-vault.nix {
        pkgs = nixpkgs.legacyPackages.${system};
        skeletonPaths = import ./nix/skeleton-paths.nix;
      };
      initVaultFor = system: import ./nix/init-vault.nix {
        pkgs = nixpkgs.legacyPackages.${system};
      };

      # obsidian と claude-code はどちらも unfree。利用者に NIXPKGS_ALLOW_UNFREE を
      # 要求しないよう、この flake の側で許可した pkgs を用意する。
      obsidianFor = system: import ./nix/obsidian.nix {
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
      };
    in
    {
      homeModules.memex = import ./nix/hm-module.nix;
      homeModules.default = self.homeModules.memex;

      packages = forAllSystems (system: {
        seed-vault = seedVaultFor system;
        init-vault = initVaultFor system;
        mirror-vault = mirrorVaultFor system;
        vault-skeleton = skeletonFor system;
        obsidian = obsidianFor system;
      });

      checks = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          tools = pkgs.symlinkJoin {
            name = "vault-layout-test-tools";
            paths = [ (seedVaultFor system) (mirrorVaultFor system) (initVaultFor system) ];
          };
        in {
          sync = pkgs.runCommand "memex-sync-tests" {
            nativeBuildInputs = [ pkgs.python3 pkgs.bash pkgs.rclone pkgs.coreutils pkgs.gnugrep
              pkgs.gnused pkgs.git pkgs.git-annex pkgs.file ];
            MEMEX_GITATTRIBUTES = ./skeleton/.gitattributes;
            MEMEX_SYNC_TEMPLATE = pkgs.writeText "memex-sync-template.sh" (import ./nix/sync-script.nix {
              pkgs = pkgs // { writeShellApplication = value: value; };
              rcloneRemote = "test";
              vaultDir = "@VAULT@";
              annexRemote = "drive";
            }).text;
          } ''
            export HOME=$TMPDIR
            python3 ${./tests/test_sync.py} -v
            touch $out
          '';
          module = assert import ./tests/module.nix { inherit pkgs; };
            pkgs.runCommand "memex-module-tests" { } "touch $out";
          layout = pkgs.runCommand "vault-layout-tests" {
            nativeBuildInputs = [ pkgs.python3 pkgs.git ];
          } ''
            export LAYOUT_ROOT=${self}
            export VAULT_TOOLS=${tools}/bin
            python3 ${./tests/test_layout.py} -v
            touch $out
          '';
        });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}

{
  description = "khimoo の memex(Obsidian vault)。添付フォルダと papis ライブラリの Google Drive 同期・papis 設定を、どのマシンでも再現できる完結型 home-manager モジュールとして提供する";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  # 責務分離: この flake は vault のための「ワークフローの仕組み」(添付同期・papis 本体/設定/同期・
  # Obsidian 本体と設定)だけを所有する。rclone の認証情報は持たず、各マシンの
  # ~/.config/rclone/rclone.conf(`rclone config` で各自が作る)に委ねる。vault の位置といった
  # 環境固有の配線は、これを取り込む側が options 経由で注入する(依存性逆転)。
  #
  # 対応環境は home-manager のみ(Linux / macOS / WSL)。非 home-manager 環境は対象外なので
  # `nix run` 用の apps は持たない——同期コマンドは options の値を焼き込んで module が生成する。
  #
  # 提供物:
  #   homeModules.memex … 統合 HM モジュール services.memex。
  #     添付 watcher と papis(設定 + ライブラリ同期 watcher)を常駐管理し、vault の骨格を seed し、
  #     同期コマンド(memex-sync)と、宣言的に片付かない残りを進める対話 CLI
  #     (memex-setup)を PATH に載せる。これがこの flake の唯一の公開面。
  #   packages … options に依存しない部品。開発時に単体で `nix build` して検証するためのもので、
  #     利用者が直接触ることは想定しない。
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

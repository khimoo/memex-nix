{ config, lib, pkgs, ... }:

let
  cfg = config.services.memex;

  validRemotePath = path: path != "" && !(lib.hasPrefix "/" path)
    && !(lib.hasInfix ":" path) && !(lib.hasInfix "\\" path)
    && !(builtins.elem ".." (lib.splitString "/" path));

  syncScript = import ./sync-script.nix {
    inherit pkgs;
    inherit (cfg) rcloneRemote vaultDir;
    inherit (cfg.sync) annexRemote;
  };

  # 宣言的に片付かない残り(rclone の OAuth・git-annex の初期化と保存先の登録)を進める対話 CLI。
  # vault の用意は initializeVault が activation で片付けるので、ここには含めない。
  setupScript = import ./setup.nix {
    inherit pkgs;
    inherit (cfg) vaultDir rcloneRemote;
    inherit (cfg.sync) annexRemote folder;
  };

  mkSyncJob = import ./sync-job.nix {
    inherit lib pkgs syncScript;
    inherit (config.home) homeDirectory;
    inherit (cfg) after wants;
  };

  # vault フォルダ自体を用意する(initializeVault のときだけ activation が呼ぶ)。
  initVault = import ./init-vault.nix { inherit pkgs; };

  # vault へ骨格(分類フォルダ・運用ドキュメント・.obsidian)を非破壊コピーする。
  seedVault = import ./seed-vault.nix {
    inherit pkgs;
    skeleton = import ./skeleton.nix { inherit pkgs; };
  };

  # 配布する plugin が実行時に要求する外部コマンド(git / claude)ごと Obsidian を包む。
  obsidianPackage = import ./obsidian.nix { inherit pkgs; };

  # vault の骨格を config repo へミラーする(seed の逆向き)。
  # vault と dest を env 既定として焼き込む(--set-default なので引数/env が優先)。
  mirrorVault = import ./mirror-vault.nix {
    inherit pkgs;
    skeletonPaths = import ./skeleton-paths.nix;
  };
  mirrorVaultWrapped = pkgs.symlinkJoin {
    name = "mirror-vault-wrapped";
    paths = [ mirrorVault ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/mirror-vault \
        --set-default MEMEX_ROOT ${lib.escapeShellArg cfg.vaultDir} \
        --set-default MEMEX_CONFIG_REPO ${lib.escapeShellArg (toString cfg.mirrorRepo)}
    '';
  };
in
{
  imports = map (name: lib.mkRemovedOptionModule [ "services" "memex" name ]
    "services.memex.sync へ移行してください。資料の中身は git-annex で Drive に置きます。papis は提供しません。")
    [ "attachments" "papis" "originals" ];

  options.services.memex = {
    enable = lib.mkEnableOption "memex(Obsidian vault)の完結型ワークフロー";

    vaultDir = lib.mkOption {
      type = lib.types.str;
      example = "/home/alice/memex";
      description = ''
        vault(Obsidian のノートを置くフォルダ)の絶対パス。
        Drive に置くファイルは vault の .gitattributes(annex.largefiles)で決まる。
        これがマシン固有の唯一の必須設定。
      '';
    };

    initializeVault = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        vault フォルダを用意する(作成・git init・.gitignore の生成)。無ければ作るだけで、
        既にあるものは触らない。骨格の自動配置もこのオプションが有効なときだけ行う。

        既定は無効で、vault の存在は利用側の責務。ゼロから始める環境(配布先)だけ有効にする。
        既に別の経路で vault を用意している環境——ノートの private repo を clone する等——で
        有効にすると、clone より先に空のフォルダを作ってしまい clone を妨げる。
      '';
    };

    rcloneRemote = lib.mkOption {
      type = lib.types.str;
      default = "gdrive";
      description = ''
        同期先の rclone remote 名(`rclone config` で各自が作ったもの)。
        認証情報はこのモジュールの管轄外で、~/.config/rclone/rclone.conf に置かれる。
      '';
    };

    after = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "network-online.target" ];
      description = "同期サービスの After。起動順序の依存を利用側から注入する穴。";
    };

    wants = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "network-online.target" ];
      description = "同期サービスの Wants。";
    };

    sync = {
      enable = lib.mkEnableOption "git-annex による vault の資料の Drive 同期";
      autoSync = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "memex-setup で初期化した後に、commit・pull のたびと定期実行で同期する。";
      };
      annexRemote = lib.mkOption {
        type = lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9_-]*";
        default = "gdrive";
        description = "Drive を指す git-annex の special remote の名前。";
      };
      folder = lib.mkOption {
        type = lib.types.str;
        default = "memex-annex";
        description = "rclone remote 内で git-annex が中身を置くフォルダ(remote からの相対パス)。初回の登録時だけ使う。";
      };
      intervalSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 900;
        description = "定期同期の間隔(秒)。";
      };
    };

    obsidian = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Obsidian 本体を入れ、vault に .obsidian 設定(Obsidian 設定 + community plugin 本体)を
          initializeVault が有効なときに配置する。vaultDir/.obsidian が無いときだけ store の baseline をコピーし、
          既存の live 設定は触らない(非破壊)。以降の Obsidian 上の変更は local のみ。
        '';
      };

      installPackage = lib.mkOption {
        type = lib.types.bool;
        default = cfg.obsidian.enable;
        defaultText = "obsidian.enable";
        description = ''
          Obsidian 本体(git と claude を PATH に載せたラッパー)を home.packages に入れる。
          既に別の経路で Obsidian を入れている環境では false にして衝突を避ける。
        '';
      };

    };

    mirrorRepo = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/home/alice/memex-nix";
      description = ''
        vault の骨格をミラーする config repo の checkout 絶対パス。
        null(既定)なら PATH に何も載せない。非 null のとき mirror-vault を PATH に載せる。
        自分の vault を骨格として配る側だけが使うもので、配られた骨格を使うだけなら
        null のままでよい。
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = lib.hasPrefix "/" cfg.vaultDir;
          message = "services.memex.vaultDir には絶対パスを指定してください: ${cfg.vaultDir}";
        }
        {
          assertion = !cfg.sync.enable || validRemotePath cfg.sync.folder;
          message = "sync.folder は remote 内の相対パスにしてください。";
        }
      ];
    })

    (lib.mkIf (cfg.enable && cfg.sync.enable) {
      home.packages = [ setupScript ];
    })

    # vault の用意は他のどの副作用よりも先。linkGeneration の後に置くのは、副作用を持つ
    # activation を write boundary より後ろに置くという home-manager の規約に合わせるため。
    (lib.mkIf (cfg.enable && cfg.initializeVault) {
      home.activation.memexVault = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        $DRY_RUN_CMD ${lib.getExe initVault} ${lib.escapeShellArg cfg.vaultDir}
      '';
    })

    # vault の Git 操作(Obsidian 外の git、エージェント)は git-annex の filter を呼ぶので PATH に要る。
    # 中身の取得(git annex get)は rclone を呼ぶ。
    (lib.mkIf (cfg.enable && cfg.sync.enable) {
      home.packages = [ syncScript pkgs.git-annex pkgs.rclone ];
    })

    (lib.mkIf (cfg.enable && cfg.sync.enable && cfg.sync.autoSync) (mkSyncJob {
      name = "memex-sync";
      description = "memex の資料の中身を git-annex で Google Drive と同期する";
      dir = cfg.vaultDir;
      # 中身を送れるのは commit 済みのファイルだけで、届いた所在から中身を取るのは pull の後。
      # commit・pull・checkout のたびに追記される HEAD の reflog を監視する。
      watchPaths = [ "${cfg.vaultDir}/.git/logs/HEAD" ];
      inherit (cfg.sync) intervalSeconds;
    }))

    # 骨格は initializeVault が有効な環境だけに配る。
    # clone で用意する既存 vault では、削除済みのファイルを switch のたびに復元しない。
    # .obsidian だけは obsidian.enable のときに --obsidian で足す。
    (lib.mkIf (cfg.enable && cfg.initializeVault) {
      home.activation.seedVault = lib.hm.dag.entryAfter [ "linkGeneration" "memexVault" ] ''
        $DRY_RUN_CMD ${lib.getExe seedVault} ${lib.optionalString cfg.obsidian.enable "--obsidian "}${lib.escapeShellArg cfg.vaultDir}
      '';
    })

    (lib.mkIf (cfg.enable && cfg.obsidian.installPackage) {
      home.packages = [ obsidianPackage ];
    })

    # 骨格を共有 repo へ手動ミラーするための CLI。常駐はしない(たまに手で実行する)。
    (lib.mkIf (cfg.enable && cfg.mirrorRepo != null) {
      home.packages = [ mirrorVaultWrapped ];
    })
  ];
}

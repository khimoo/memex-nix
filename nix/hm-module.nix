# Zettelkasten(Obsidian vault)の完結型 home-manager モジュール。
# vault のための機能——Obsidian 本体と設定、添付フォルダの Google Drive 同期、papis(参照文献)
# ライブラリの設定と同期——を一括で所有する。vault の位置(vaultDir)を注入するだけで、
# どのマシンでも同一の Obsidian ワークフローが立ち上がる。
#
# この flake の公開面はこのモジュールだけ。非 home-manager 環境は対象外。
#
# rclone 認証情報はこのモジュールの管轄外。各マシンで `rclone config` が作った
# ~/.config/rclone/rclone.conf を rclone 自身が既定で解決する。
#
# vault 内のパスは規約で固定する(Assets/attachments/ と Assets/references/)。可変にすると、配布する
# .obsidian/app.json の attachmentFolderPath と食い違いうるため。設定項目にする利益が無い。
#
# Obsidian と claude-code は unfree なので、利用側が nixpkgs.config.allowUnfree を許可する
# 必要がある(README の flake.nix に含めてある)。ここで独自に許可した nixpkgs を使うと、
# 利用者の nixpkgs と二重に closure を持つことになるので、そうしない。
{ config, lib, pkgs, ... }:

let
  cfg = config.services.zettelkasten;

  # 同期対象のパスは規約で固定(options にしない)。
  attachmentsDir = "${cfg.vaultDir}/Assets/attachments";
  papisDir = "${cfg.vaultDir}/Assets/references";
  originalsDir = "${cfg.vaultDir}/Assets/Originals";

  anySync = cfg.attachments.enable || cfg.papis.enable || cfg.originals.enable;

  # 比較前に区切りと . / .. を正規化する。symlink は実行時にも確認する。
  pathParts = path: lib.foldl' (parts: part:
    if part == "" || part == "." then parts
    else if part == ".." then (if parts == [ ] then [ ] else lib.init parts)
    else parts ++ [ part ]
  ) [ ] (lib.splitString "/" path);
  normalizedPath = path: "/${lib.concatStringsSep "/" (pathParts path)}";
  within = parent: child: parent == "/" || child == parent || lib.hasPrefix "${parent}/" child;
  originalsFolder = normalizedPath cfg.originals.folder;
  originalsBackupFolder = normalizedPath cfg.originals.backupFolder;
  originalsLocalBackup = normalizedPath "${config.xdg.dataHome}/zettelkasten/originals-backups";

  # 同期コマンドは1本。何を同期するかは eval 時にここで焼き込む(実行時に設定を読む層は無い)。
  syncScript = import ./sync-script.nix {
    inherit pkgs;
    inherit (cfg) rcloneRemote;

    attachments =
      if cfg.attachments.enable
      then { dir = attachmentsDir; inherit (cfg.attachments) folder; }
      else null;

    papis =
      if cfg.papis.enable
      then { dir = papisDir; inherit (cfg.papis) folder; }
      else null;

    originals =
      if cfg.originals.enable
      then {
        dir = originalsDir;
        inherit (cfg) vaultDir;
        inherit (cfg.originals) folder backupFolder;
      }
      else null;
  };

  # 宣言的に片付かない残り(rclone の OAuth・初回同期の曖昧ケース)を進める対話 CLI。
  # vault の用意は initializeVault が activation で片付けるので、ここには含めない。
  setupScript = import ./setup.nix {
    inherit pkgs syncScript;
    inherit (cfg) vaultDir rcloneRemote;
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
        --set-default ZETTELKASTEN_ROOT ${lib.escapeShellArg cfg.vaultDir} \
        --set-default ZETTELKASTEN_CONFIG_REPO ${lib.escapeShellArg (toString cfg.mirrorRepo)}
    '';
  };
in
{
  options.services.zettelkasten = {
    enable = lib.mkEnableOption "Zettelkasten(Obsidian vault)の完結型ワークフロー";

    vaultDir = lib.mkOption {
      type = lib.types.str;
      example = "/home/alice/zettelkasten";
      description = ''
        vault(Obsidian のノートを置くフォルダ)の絶対パス。
        Assets/attachments/、Assets/references/、Assets/Originals/ を設定に応じて同期する。
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

    attachments = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "vault の Assets/attachments/ の Google Drive 双方向同期を有効化する。";
      };

      folder = lib.mkOption {
        type = lib.types.str;
        default = "zettelkasten-attachments";
        description = "添付を置く Google Drive 側のフォルダ名(remote からの相対パス)。無ければ初回同期で作られる。";
      };

      intervalSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 900;
        description = "定期バックストップ同期の間隔(秒)。イベント駆動が取りこぼした変更を拾う保険。";
      };
    };

    papis = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "papis(参照文献マネージャ)本体・設定・vault の Assets/references/ の同期を有効化する。";
      };

      folder = lib.mkOption {
        type = lib.types.str;
        default = "papis-library";
        description = "papis ライブラリを置く Google Drive 側のフォルダ名(remote からの相対パス)。";
      };

      opentool = lib.mkOption {
        type = lib.types.str;
        default = "xdg-open";
        description = "papis open が使う外部ビューア。デスクトップの既定アプリに委譲する。";
      };

      intervalSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 900;
        description = "papis ライブラリの定期バックストップ同期の間隔(秒)。";
      };
    };

    originals = {
      enable = lib.mkEnableOption "vault の Assets/Originals/ の Google Drive 双方向同期";

      folder = lib.mkOption {
        type = lib.types.str;
        default = "zettelkasten-originals";
        description = "原本を置く Google Drive 側のフォルダ(remote からの相対パス)。";
      };

      backupFolder = lib.mkOption {
        type = lib.types.str;
        default = "zettelkasten-originals-backups";
        description = "原本の退避先フォルダ(同じ remote 内、同期先と重複しない相対パス)。";
      };

      intervalSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 900;
        description = "原本の定期バックストップ同期の間隔(秒)。";
      };

      autoSync = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "原本の自動同期を有効化する。実 Drive 検証と手動初期化後に有効にする。";
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
      example = "/home/alice/zettelkasten-workflow";
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
          message = "services.zettelkasten.vaultDir には絶対パスを指定してください: ${cfg.vaultDir}";
        }
        {
          assertion = !cfg.originals.enable || (
            originalsFolder != "/" && originalsBackupFolder != "/"
            && !(within originalsFolder originalsBackupFolder)
            && !(within originalsBackupFolder originalsFolder)
          );
          message = "Originals の folder と backupFolder は空でなく、同一・祖先子孫で重複しないパスにしてください。";
        }
        {
          assertion = !cfg.originals.enable || !(within (normalizedPath cfg.vaultDir) originalsLocalBackup);
          message = "Originals のローカル退避先(xdg.dataHome/zettelkasten/originals-backups)は vaultDir の外に置いてください。";
        }
      ];
    })

    # 同期対象が無ければ setup が案内することは残らない(vault は activation が用意する)。
    (lib.mkIf (cfg.enable && anySync) {
      home.packages = [ setupScript ];
    })

    # vault の用意は他のどの副作用よりも先。linkGeneration の後に置くのは、副作用を持つ
    # activation を write boundary より後ろに置くという home-manager の規約に合わせるため。
    (lib.mkIf (cfg.enable && cfg.initializeVault) {
      home.activation.zettelkastenVault = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        $DRY_RUN_CMD ${lib.getExe initVault} ${lib.escapeShellArg cfg.vaultDir}
      '';
    })

    (lib.mkIf (cfg.enable && anySync) {
      home.packages = [ syncScript ];
    })

    (lib.mkIf (cfg.enable && cfg.attachments.enable) (mkSyncJob {
      name = "zettelkasten-sync";
      description = "Zettelkasten 添付を Google Drive へ bisync する";
      dir = attachmentsDir;
      target = "attachments";
      inherit (cfg.attachments) intervalSeconds;
    }))

    (lib.mkIf (cfg.enable && cfg.papis.enable) (mkSyncJob {
      name = "papis-sync";
      description = "papis ライブラリを Google Drive へ bisync する";
      dir = papisDir;
      target = "papis";
      inherit (cfg.papis) intervalSeconds;
    }))

    (lib.mkIf (cfg.enable && cfg.originals.enable && cfg.originals.autoSync) (mkSyncJob {
      name = "originals-sync";
      description = "Originals を Google Drive へ bisync する";
      dir = originalsDir;
      target = "originals";
      inherit (cfg.originals) intervalSeconds;
    }))

    # papis ライブラリは item ごとに info.yaml と PDF が同居するので、フォルダを丸ごと bisync
    # すれば メタデータもバイトも1系統で運べる。programs.papis.enable が papis 本体も入れる。
    # citekey は各 item の info.yaml の `ref:` に手で pin する運用(ref-format は設定しない)。
    (lib.mkIf (cfg.enable && cfg.papis.enable) {
      programs.papis = {
        enable = true;
        settings.opentool = cfg.papis.opentool;
        libraries.library = {
          isDefault = true;
          settings.dir = papisDir;
        };
      };
    })

    # 骨格は initializeVault が有効な環境だけに配る。
    # clone で用意する既存 vault では、削除済みのファイルを switch のたびに復元しない。
    # .obsidian だけは obsidian.enable のときに --obsidian で足す。
    (lib.mkIf (cfg.enable && cfg.initializeVault) {
      home.activation.seedVault = lib.hm.dag.entryAfter [ "linkGeneration" "zettelkastenVault" ] ''
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

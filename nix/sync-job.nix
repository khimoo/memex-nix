# 同期 job の OS 非依存な定義。Linux(systemd)と macOS(launchd)の両方をここ1か所から導出する。
#
# 添付と papis は「監視するディレクトリ」と「--only に渡す対象名」しか違わない。以前は
# systemd 版と launchd 版を対象ごとに4か所へ書いていて、片方だけ直す事故が起きうる形だった。
#
# 形: watcher は常駐させず、OS 純正のイベント駆動(PathModified / WatchPaths)で oneshot を
# 起動する。取りこぼしに備えて定期実行も併せる(バックストップ)。
{ lib, pkgs, homeDirectory, syncScript, after, wants }:

{ name        # unit 名(ログとファイル名になる)
, description # 人間向けの説明
, dir         # 監視・同期するディレクトリの絶対パス
, target      # memex-sync --only に渡す対象名
, intervalSeconds
}:

lib.mkMerge [
  (lib.mkIf pkgs.stdenv.isLinux {
    # ConditionPathIsDirectory: 対象がまだ無い間はサービスを skip する(失敗にはしない)。
    systemd.user.services.${name} = {
      Unit = {
        Description = "${description}(oneshot)";
        ConditionPathIsDirectory = dir;
        After = after;
        Wants = wants;
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${lib.getExe syncScript} --only ${target}";
      };
    };

    systemd.user.paths.${name} = {
      Unit.Description = "${description}: 変更を監視して同期をトリガする";
      Path = {
        PathModified = dir;
        Unit = "${name}.service";
      };
      Install.WantedBy = [ "default.target" ];
    };

    systemd.user.timers.${name} = {
      Unit.Description = "${description}: 定期バックストップ";
      Timer = {
        OnActiveSec = "30s";
        OnUnitActiveSec = "${toString intervalSeconds}s";
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
    };
  })

  (lib.mkIf pkgs.stdenv.isDarwin {
    launchd.agents.${name} = {
      enable = true;
      config = {
        ProgramArguments = [ (lib.getExe syncScript) "--only" target ];
        RunAtLoad = true;
        WatchPaths = [ dir ];
        StartInterval = intervalSeconds;
        StandardErrorPath = "${homeDirectory}/Library/Logs/${name}.log";
        StandardOutPath = "${homeDirectory}/Library/Logs/${name}.log";
      };
    };
  })
]

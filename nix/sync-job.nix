# watcher を常駐させず、OS のイベント(PathModified / WatchPaths)で oneshot を起動する。
# 監視が取りこぼした変更は定期実行で拾う。
{ lib, pkgs, homeDirectory, syncScript, after, wants }:

{ name        # unit 名(ログとファイル名になる)
, description # 人間向けの説明
, dir         # 同期するディレクトリの絶対パス
, watchPaths  # 変更を監視するパス。systemd も launchd も再帰的には監視しない
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
        ExecStart = "${lib.getExe syncScript}";
      };
    };

    systemd.user.paths.${name} = {
      Unit.Description = "${description}: 変更を監視して同期をトリガする";
      Path = {
        PathModified = watchPaths;
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
        ProgramArguments = [ (lib.getExe syncScript) ];
        RunAtLoad = true;
        WatchPaths = watchPaths;
        StartInterval = intervalSeconds;
        StandardErrorPath = "${homeDirectory}/Library/Logs/${name}.log";
        StandardOutPath = "${homeDirectory}/Library/Logs/${name}.log";
      };
    };
  })
]

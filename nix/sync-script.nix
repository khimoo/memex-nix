# vault の添付フォルダと papis ライブラリを Google Drive へ双方向同期する単一コマンド。
#
# 対象ごとにコマンドを分けない。日常の操作は zettelkasten-sync の1つで、何が同期されるかは
# home-manager の options が eval 時に決める。unit だけは監視対象ごとに起動されるので
# --only で片方に絞る。
#
# 同期先(remote 名・Drive のフォルダ名・対象パス)はここに焼き込まれる。実行時に設定を読む層は
# 持たない——設定の source は flake ただ一つで、解決順を1段に保つ。有効でない対象は
# そもそもコードが生成されないので、papis を使わない環境に papis の分岐は存在しない。
#
# 同期の本体は nix/bisync-lib.nix。ここは「どの対象を、どこへ」だけを持つ層。
#
# attachments / papis は { dir, folder }、originals は vaultDir / backupFolder も持つ。
# null ならその対象は生成しない。
{ pkgs
, rcloneRemote
, attachments ? null
, papis ? null
, originals ? null
}:

let
  inherit (pkgs) lib;
  bisync = import ./bisync-lib.nix { inherit pkgs; };

  targets = lib.optional (attachments != null) "attachments"
    ++ lib.optional (papis != null) "papis"
    ++ lib.optional (originals != null) "originals";

  targetList = lib.concatStringsSep "|" targets;

  example = opt: desc:
    "  zettelkasten-sync ${opt}${lib.concatStrings (lib.genList (_: " ") (21 - lib.stringLength opt))}${desc}";

  usageText = lib.concatStringsSep "\n" ([
    "使い方: zettelkasten-sync [--only ${targetList}] [rclone bisync への追加引数...]"
    ""
    "  同期先は home-manager の services.zettelkasten が持つ。引数では変えられない。"
    ""
    "例:"
    (example "" "設定どおり全部同期する")
  ]
  # 対象が1つしかない環境で --only を勧めても意味がない。
  ++ lib.optional (lib.length targets > 1)
    (example "--only ${lib.last targets}" "${lib.last targets} だけ同期する")
  ++ [ (example "--dry-run" "rclone に渡す引数はそのまま素通しする") ]
  ++ lib.optionals (originals != null) [
    ""
    "  Originals の初回は両側の内容を確認し、zettelkasten-sync --only originals --resync を実行してください。"
    "  --resync は通常の競合処理とは別です。バックアップがあっても事前確認が必要です。"
  ]);

  # 対象ごとの同期ブロック。baseline(同期の記録)の名前は対象ごとに固定で、
  # 変えると既存マシンが「記録なし」と判定されて resync を要求される。
  syncBlock = { name, label, dir, folder, baseline }: ''
    if [ -z "$only" ] || [ "$only" = ${name} ]; then
      echo "==> ${label}: ${dir} <-> ${rcloneRemote}:${folder}" >&2
      ZK_SYNC_TARGET=${lib.escapeShellArg name} zk_bisync ${lib.escapeShellArg label} ${lib.escapeShellArg dir} \
        ${lib.escapeShellArg "${rcloneRemote}:${folder}"} \
        ${baseline} "''${rclone_args[@]}" || status=1
    fi
  '';
in
pkgs.writeShellApplication {
  name = "zettelkasten-sync";
  runtimeInputs = bisync.runtimeInputs;
  text = ''
    ${bisync.text}

    ${lib.optionalString (originals != null) ''
      zk_sync_originals() {
        local baseline_dir arg resync=false
        baseline_dir="''${XDG_CACHE_HOME:-$HOME/.cache}/rclone/bisync-originals"
        for arg in "''${rclone_args[@]}"; do
          if [ "$arg" = "--resync" ]; then
            resync=true
          fi
        done
        local baseline_lsts
        shopt -s nullglob
        baseline_lsts=("$baseline_dir"/*.lst)
        shopt -u nullglob
        if [ "''${#baseline_lsts[@]}" -eq 0 ] && [ "$resync" != true ] && [ "''${ZK_FORCE_RESYNC:-}" != 1 ]; then
          echo "Originals: 同期の記録がありません。両側の内容を確認して手動で初期化してください。" >&2
          echo "  → zettelkasten-sync --only originals --resync" >&2
          return 1
        fi

        local host vault backup_root localbackup localrun runid
        host="$(uname -n)" || return 1
        case "$host" in
          "" | . | .. | *[!a-zA-Z0-9._-]*)
            echo "Originals: 退避先に使用できないホスト名です: $host" >&2
            return 1
            ;;
        esac
        vault="$(realpath -m -- ${lib.escapeShellArg originals.vaultDir})" || return 1
        backup_root="''${XDG_DATA_HOME:-$HOME/.local/share}/zettelkasten/originals-backups"
        localbackup="$(realpath -m -- "$backup_root/$host")" || return 1
        if [ "$vault" = / ] || [ "$localbackup" = "$vault" ] || [[ "$localbackup" == "$vault/"* ]]; then
          echo "Originals: ローカル退避先は vault の外に置いてください: $localbackup" >&2
          return 1
        fi
        mkdir -p -- "$localbackup" || return 1
        localrun="$(mktemp -d "$localbackup/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXXXX")" || return 1
        runid="''${localrun##*/}"
        echo ${lib.escapeShellArg "==> Originals: ${originals.dir} <-> ${rcloneRemote}:${originals.folder}"} >&2
        ZK_SYNC_TARGET=originals ZK_CONFLICT_RESOLVE=none zk_bisync Originals ${lib.escapeShellArg originals.dir} \
          ${lib.escapeShellArg "${rcloneRemote}:${originals.folder}"} bisync-originals \
          --recover --max-lock 2m --conflict-loser num --backup-dir1 "$localrun" \
          --backup-dir2 ${lib.escapeShellArg "${rcloneRemote}:${originals.backupFolder}"}/"$host/$runid" \
          "''${rclone_args[@]}"
      }
    ''}

    usage() {
      cat >&2 <<'EOF'
    ${usageText}
    EOF
    }

    only=""
    rclone_args=()

    while [ $# -gt 0 ]; do
      case "$1" in
        --only)
          only="''${2:-}"
          if [ -z "$only" ]; then
            echo "--only には ${lib.concatStringsSep " か " targets} を指定してください。" >&2
            exit 1
          fi
          shift 2
          ;;
        -h | --help)
          usage
          exit 0
          ;;
        # 上記以外のオプションは rclone bisync へ素通しする(--dry-run, --resync など)。
        -*)
          rclone_args+=("$1")
          shift
          ;;
        *)
          echo "解釈できない引数です: $1" >&2
          usage
          exit 1
          ;;
      esac
    done

    case "$only" in
      ${lib.concatStringsSep " | " ([ "\"\"" ] ++ targets)}) ;;
      *)
        echo "--only には ${lib.concatStringsSep " か " targets} を指定してください: ''${only:-(空)}" >&2
        exit 1
        ;;
    esac

    zk_rclone_init
    zk_rclone_check ${lib.escapeShellArg rcloneRemote}

    # 対象ごとに独立して試す(片方が落ちても相方を止めない)。1つでも失敗したら非ゼロで終わる。
    status=0

    ${lib.optionalString (attachments != null) (syncBlock {
      name = "attachments";
      label = "添付";
      inherit (attachments) dir folder;
      baseline = "bisync-zettelkasten";
    })}
    ${lib.optionalString (papis != null) (syncBlock {
      name = "papis";
      label = "papis";
      inherit (papis) dir folder;
      baseline = "bisync-papis";
    })}
    ${lib.optionalString (originals != null) ''
      if [ -z "$only" ] || [ "$only" = originals ]; then
        zk_sync_originals || status=1
      fi
    ''}

    exit "$status"
  '';
}

{ pkgs, rcloneRemote, vaultDir, folder, filtersFile, backupFolder, localBackupRoot }:
let
  inherit (pkgs) lib;
  bisync = import ./bisync-lib.nix { inherit pkgs; };
in
pkgs.writeShellApplication {
  name = "memex-sync";
  runtimeInputs = bisync.runtimeInputs ++ [ pkgs.python3 ];
  text = ''
    ${bisync.text}

    rclone_args=()
    for arg in "$@"; do
      case "$arg" in
        --dry-run | --resync) rclone_args+=("$arg") ;;
        -h | --help)
          echo '使い方: memex-sync [--dry-run] [--resync]'
          exit 0 ;;
        *) echo "許可されていない引数: $arg" >&2; exit 1 ;;
      esac
    done

    if ! filter_content="$(python3 ${./validate-sync.py} ${lib.escapeShellArg filtersFile} \
      ${lib.escapeShellArg folder} ${lib.escapeShellArg backupFolder})"; then
      exit 1
    fi
    if [ -z "$filter_content" ]; then
      echo '同期対象の指定がありません。何も変更しません。' >&2
      exit 0
    fi

    host="$(uname -n)"
    case "$host" in
      "" | . | .. | *[!a-zA-Z0-9._-]*) echo '退避先に使用できないホスト名です。' >&2; exit 1 ;;
    esac
    vault="$(realpath -e -- ${lib.escapeShellArg vaultDir})"
    backup="$(realpath -m -- ${lib.escapeShellArg localBackupRoot}/"$host")"
    case "$backup/" in
      "$vault/"*) echo 'ローカル退避先は vault の外に置いてください。' >&2; exit 1 ;;
    esac
    case "$vault/" in
      "$backup/"*) echo 'ローカル退避先と vault を重複させないでください。' >&2; exit 1 ;;
    esac

    state="$(realpath -m -- "''${XDG_CACHE_HOME:-$HOME/.cache}/rclone/bisync-memex-files")"
    case "$state/" in
      "$vault/"*) echo '同期履歴は vault の外に置いてください。' >&2; exit 1 ;;
    esac

    memex_rclone_init
    memex_rclone_check ${lib.escapeShellArg rcloneRemote}
    mkdir -p -- "$state"
    filter_tmp="$(mktemp "$state/filters-XXXXXXXX")"
    trap 'rm -f -- "$filter_tmp"' EXIT
    printf '%s\n' "$filter_content" > "$filter_tmp"
    mv -- "$filter_tmp" "$state/filters"
    mkdir -p -- "$backup"
    localrun="$(mktemp -d "$backup/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXXXX")"
    runid="''${localrun##*/}"
    MEMEX_CONFLICT_RESOLVE=none memex_bisync memex "$vault" \
      ${lib.escapeShellArg "${rcloneRemote}:${folder}"} bisync-memex-files \
      --filters-file "$state/filters" \
      --conflict-loser num --backup-dir1 "$localrun" \
      --backup-dir2 ${lib.escapeShellArg "${rcloneRemote}:${backupFolder}"}/"$host/$runid" \
      "''${rclone_args[@]}"
  '';
}

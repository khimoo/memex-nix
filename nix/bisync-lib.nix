# rclone bisync による双方向同期の共通本体。添付・papis の両方が同じ関数を1本の
# コマンドから呼ぶ(同期ロジックを対象ごとに複製しない)。
#
# 同期パラメータ(対象パス・remote)は引数で受け取り、この層では一切決めない。
# 決めるのは home-manager の options で、nix/sync-script.nix が eval 時に焼き込んで渡す。
#
# 宣言的に用意できない要素(rclone の認証情報)は preflight で実行前に検知し、復旧手順つきで
# loud に落とす。サイレントに半端な同期をしない。同期の記録(bisync の baseline)は machine-local
# かつ対象ごとに隔離し、相方の baseline と混ぜない。
{ pkgs }:

{
  runtimeInputs = [ pkgs.coreutils pkgs.gnugrep pkgs.rclone ];

  # 埋め込む側のスクリプトに展開して使う関数群。
  #   zk_rclone_init            … RCLONE_CONFIG の解決(以降の rclone 呼び出しに使う引数を作る)
  #   zk_rclone_check <remote>  … remote の定義と認証が生きているかを確認する
  #   zk_bisync <label> <dir> <remote> <baseline> [rclone への追加引数...]
  text = ''
    ZK_RCLONE_ARGS=()

    # 復旧手順のメッセージに出すコマンド名。埋め込む側が別名を名乗るなら上書きする。
    ZK_SYNC_NAME="''${ZK_SYNC_NAME:-zettelkasten-sync}"

    # rclone 設定パスの解決: RCLONE_CONFIG があれば明示 --config、無ければ rclone 既定に委ねる。
    zk_rclone_init() {
      if [ -z "''${RCLONE_CONFIG:-}" ]; then
        return 0
      fi

      if [ ! -f "$RCLONE_CONFIG" ]; then
        echo "rclone 設定ファイルが存在しません: $RCLONE_CONFIG" >&2
        echo "  → RCLONE_CONFIG の指し先を確認してください(rclone config で作成するか、正しいパスを指定)。" >&2
        return 1
      fi

      ZK_RCLONE_ARGS=(--config "$RCLONE_CONFIG")
    }

    # remote 名(コロンの手前)が定義済みで、かつ認証が実際に通るかを確認する。
    zk_rclone_check() {
      local remote_name
      remote_name="''${1%%:*}"

      if ! rclone "''${ZK_RCLONE_ARGS[@]}" listremotes | grep -qx "''${remote_name}:"; then
        echo "rclone remote '$remote_name' が未定義です(宣言的に生成できない認証部分)。" >&2
        echo "  → 次のいずれかで用意してください:" >&2
        echo "     - 対話取得:  rclone config   (remote 名 '$remote_name' / type drive)" >&2
        echo "     - 既存の rclone.conf を RCLONE_CONFIG で指す" >&2
        return 1
      fi

      if ! rclone "''${ZK_RCLONE_ARGS[@]}" about "''${remote_name}:" >/dev/null 2>&1; then
        echo "'$remote_name' の認証に失敗しました(token 失効の可能性)。" >&2
        echo "  → 再認証:  rclone config reconnect ''${remote_name}:" >&2
        return 1
      fi
    }

    # 同期で失うものが無いディレクトリか。空か、placeholder(.keep/.gitkeep)しか無い状態を指す。
    zk_dir_is_empty() {
      local entry
      for entry in "$1"/* "$1"/.*; do
        case "''${entry##*/}" in
          '*' | '.*' | . | .. | .keep | .gitkeep) continue ;;
        esac
        [ -e "$entry" ] || continue
        return 1
      done
      return 0
    }

    zk_bisync() {
      local label dir remote baseline_dir sync_target
      local ZK_CONFLICT_RESOLVE="''${ZK_CONFLICT_RESOLVE:-newer}"
      sync_target="''${ZK_SYNC_TARGET:-<対象名>}"
      label="$1"
      dir="$2"
      remote="$3"
      baseline_dir="''${XDG_CACHE_HOME:-$HOME/.cache}/rclone/$4"
      shift 4

      # options で位置が決まっているフォルダなので、無ければ作る。
      if [ ! -d "$dir" ]; then
        echo "$label: $dir が無いので作成します。" >&2
        mkdir -p "$dir" || return 1
      fi

      # ---- 初回ブートストラップ判定(同期の記録 .lst の有無で判定) ----
      local baseline_lsts
      shopt -s nullglob
      baseline_lsts=("$baseline_dir"/*.lst)
      shopt -u nullglob

      local first_run=false
      if [ "''${#baseline_lsts[@]}" -eq 0 ]; then
        first_run=true
      fi

      # ユーザが明示的に --resync を付けたか。
      local resync=false arg
      for arg in "$@"; do
        if [ "$arg" = "--resync" ]; then
          resync=true
        fi
      done

      # 記録が無ければこのペアの初回。remote が空/不在なら安全に自己初期化(mkdir + --resync)する。
      # remote にデータがあるのに記録が無い場合、危険なのは「ローカルにも実体があって、どちらが
      # 正か決められない」ときだけ。ローカルが空なら失うものが無いので、新マシンの合流として
      # そのまま resync する。両側に実体があるときだけ曖昧ケースとして明示の ZK_FORCE_RESYNC=1 を
      # 要求する(対話で聞くのは zettelkasten-setup の役目で、ここは非対話でも安全に止まることだけを
      # 保証する)。
      if [ "$first_run" = true ]; then
        local remote_listing
        if remote_listing="$(rclone "''${ZK_RCLONE_ARGS[@]}" lsf "$remote" 2>/dev/null)" && [ -n "$remote_listing" ]; then
          if zk_dir_is_empty "$dir"; then
            echo "$label: 初回同期です($dir が空)。Google Drive 側の内容を取り込みます。" >&2
          elif [ "''${ZK_FORCE_RESYNC:-}" != "1" ] && [ "$resync" != true ]; then
            echo "$label: このマシンには同期の記録が無いのに、両側にデータがあります: $dir <-> $remote" >&2
            echo "  (記録の喪失か、中身の違う2つを合流させようとしているかのどちらか)" >&2
            echo "  → 合流させる場合のみ明示的に: ZK_FORCE_RESYNC=1 $ZK_SYNC_NAME --only $sync_target --resync" >&2
            return 1
          fi
          resync=true
        else
          echo "$label: 初回同期です(Google Drive 側が空)。フォルダを作成して初期化します。" >&2
          rclone "''${ZK_RCLONE_ARGS[@]}" mkdir "$remote" || return 1
          resync=true
        fi
      fi

      # ---- --resync ガード(既存の記録の誤上書き防止) ----
      # 初回でないのにユーザが --resync を付けた場合のみ、誤操作防止で止める。
      if [ "$resync" = true ] && [ "$first_run" != true ] && [ "''${ZK_FORCE_RESYNC:-}" != "1" ]; then
        echo "$label: 同期の記録が既に存在します($baseline_dir)。" >&2
        echo "  誤操作による上書きを防ぐため --resync を中止しました。" >&2
        echo "  意図的にやり直す場合のみ: ZK_FORCE_RESYNC=1 $ZK_SYNC_NAME --only $sync_target --resync" >&2
        return 1
      fi

      # resync が必要でユーザ引数に無ければ付与(二重指定を避ける)。
      local resync_args=()
      if [ "$resync" = true ]; then
        case " $* " in
          *" --resync "*) ;;
          *) resync_args=(--resync) ;;
        esac

        # 空のまま resync すると記録が空になり、次回以降 rclone が
        # "empty prior listing" で毎回落ちる(空ディレクトリへの同期を大量削除とみなす安全弁)。
        # 新品の vault + 空の Drive という初回そのものが該当するので、目印を1つ置いて回避する。
        if [ -z "$(ls -A "$dir")" ]; then
          : > "$dir/.keep"
        fi
      fi

      rclone "''${ZK_RCLONE_ARGS[@]}" bisync \
        "$dir" "$remote" \
        --workdir "$baseline_dir" \
        --conflict-resolve "$ZK_CONFLICT_RESOLVE" --resilient --verbose \
        "''${resync_args[@]}" "$@"
    }
  '';
}

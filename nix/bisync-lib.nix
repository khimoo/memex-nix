{ pkgs }:

{
  runtimeInputs = [ pkgs.coreutils pkgs.gnugrep pkgs.rclone ];

  # 埋め込む側のスクリプトに展開して使う関数群。
  #   memex_rclone_init            … RCLONE_CONFIG の解決(以降の rclone 呼び出しに使う引数を作る)
  #   memex_rclone_check <remote>  … remote の定義と認証が生きているかを確認する
  #   memex_bisync <label> <dir> <remote> <baseline> [rclone への追加引数...]
  text = ''
    MEMEX_RCLONE_ARGS=()

    # 復旧手順のメッセージに出すコマンド名。埋め込む側が別名を名乗るなら上書きする。
    MEMEX_SYNC_NAME="''${MEMEX_SYNC_NAME:-memex-sync}"

    # rclone 設定パスの解決: RCLONE_CONFIG があれば明示 --config、無ければ rclone 既定に委ねる。
    memex_rclone_init() {
      if [ -z "''${RCLONE_CONFIG:-}" ]; then
        return 0
      fi

      if [ ! -f "$RCLONE_CONFIG" ]; then
        echo "rclone 設定ファイルが存在しません: $RCLONE_CONFIG" >&2
        echo "  → RCLONE_CONFIG の指し先を確認してください(rclone config で作成するか、正しいパスを指定)。" >&2
        return 1
      fi

      MEMEX_RCLONE_ARGS=(--config "$RCLONE_CONFIG")
    }

    # remote 名(コロンの手前)が定義済みで、かつ認証が実際に通るかを確認する。
    memex_rclone_check() {
      local remote_name
      remote_name="''${1%%:*}"

      if ! rclone "''${MEMEX_RCLONE_ARGS[@]}" listremotes | grep -qx "''${remote_name}:"; then
        echo "rclone remote '$remote_name' が未定義です(宣言的に生成できない認証部分)。" >&2
        echo "  → 次のいずれかで用意してください:" >&2
        echo "     - 対話取得:  rclone config   (remote 名 '$remote_name' / type drive)" >&2
        echo "     - 既存の rclone.conf を RCLONE_CONFIG で指す" >&2
        return 1
      fi

      if ! rclone "''${MEMEX_RCLONE_ARGS[@]}" about "''${remote_name}:" >/dev/null 2>&1; then
        echo "'$remote_name' の認証に失敗しました(token 失効の可能性)。" >&2
        echo "  → 再認証:  rclone config reconnect ''${remote_name}:" >&2
        return 1
      fi
    }

    memex_bisync() {
      local label dir remote baseline_dir
      local MEMEX_CONFLICT_RESOLVE="''${MEMEX_CONFLICT_RESOLVE:-newer}"
      label="$1"
      dir="$2"
      remote="$3"
      baseline_dir="''${XDG_CACHE_HOME:-$HOME/.cache}/rclone/$4"
      shift 4

      local baseline_lsts
      shopt -s nullglob
      baseline_lsts=("$baseline_dir"/*.lst)
      shopt -u nullglob
      local first_run=false resync=false arg
      if [ "''${#baseline_lsts[@]}" -eq 0 ]; then first_run=true; fi
      for arg in "$@"; do
        if [ "$arg" = "--resync" ]; then resync=true; fi
      done
      if [ "$first_run" = true ] && [ "$resync" != true ]; then
        echo "$label: 同期の記録がありません。両側を退避・照合して $MEMEX_SYNC_NAME --resync を実行してください。" >&2
        return 1
      fi

      # ---- --resync ガード(既存の記録の誤上書き防止) ----
      # 初回でないのにユーザが --resync を付けた場合のみ、誤操作防止で止める。
      if [ "$resync" = true ] && [ "$first_run" != true ] && [ "''${MEMEX_FORCE_RESYNC:-}" != "1" ]; then
        echo "$label: 同期の記録が既に存在します($baseline_dir)。" >&2
        echo "  誤操作による上書きを防ぐため --resync を中止しました。" >&2
        echo "  意図的にやり直す場合のみ: MEMEX_FORCE_RESYNC=1 $MEMEX_SYNC_NAME --resync" >&2
        return 1
      fi

      rclone "''${MEMEX_RCLONE_ARGS[@]}" bisync \
        "$dir" "$remote" \
        --workdir "$baseline_dir" \
        --conflict-resolve "$MEMEX_CONFLICT_RESOLVE" --resilient --recover --max-lock 2m --verbose \
        "$@"
    }
  '';
}

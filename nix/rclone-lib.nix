{ pkgs }:

{
  runtimeInputs = [ pkgs.coreutils pkgs.gnugrep pkgs.rclone ];

  # 埋め込む側のスクリプトに展開して使う関数群。
  #   memex_rclone_init            … RCLONE_CONFIG の解決(以降の rclone 呼び出しに使う引数を作る)
  #   memex_rclone_check <remote>  … remote の定義と認証が生きているかを確認する
  text = ''
    MEMEX_RCLONE_ARGS=()

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
  '';
}

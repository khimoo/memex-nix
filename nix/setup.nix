{ pkgs
, vaultDir
, rcloneRemote
, filtersFile
}:

let
  inherit (pkgs) lib;
in
pkgs.writeShellApplication {
  name = "memex-setup";
  runtimeInputs = [ pkgs.coreutils pkgs.rclone pkgs.gnugrep ];
  text = ''
    vault=${lib.escapeShellArg vaultDir}
    filters=${lib.escapeShellArg filtersFile}

    say() { echo "$*" >&2; }
    die() { echo "$*" >&2; exit 1; }

    # 対話が前提なので、パイプや systemd から呼ばれたら黙って進めず落とす。
    if [ ! -t 0 ]; then
      die "memex-setup は対話的に実行してください(標準入力が端末ではありません)。"
    fi

    confirm() {
      local prompt="$1" default="$2" reply hint
      if [ "$default" = y ]; then hint="[Y/n]"; else hint="[y/N]"; fi
      while true; do
        printf '%s %s: ' "$prompt" "$hint" >&2
        if ! IFS= read -r reply; then
          echo >&2
          die "入力を読み取れませんでした。中断します。"
        fi
        case "''${reply:-$default}" in
          y | Y | yes | YES) return 0 ;;
          n | N | no | NO) return 1 ;;
          *) say "y か n で答えてください。" ;;
        esac
      done
    }

    cat >&2 <<EOF
    === memex setup ===

    vault: $vault

    この先で行うこと:
      1. Google Drive との接続確認(rclone)
      2. フィルタと初期化手順の案内

    途中で止めても、もう一度実行すれば済んだところは飛ばします。

    EOF

    # vault は switch が用意している前提。無いのは設定側の問題なので、ここでは作らずに案内する。
    if [ ! -d "$vault" ]; then
      say "vault がまだありません: $vault"
      say "  → services.memex.initializeVault = true にして switch し直すか、"
      say "    別の経路(ノート repo の clone 等)で用意してから再実行してください。"
      die "中断しました。"
    fi

    # ---- rclone ----
    say ""
    cat >&2 <<EOF
    $filters で選んだ資料を Google Drive で同期します。
    その接続は rclone が持ちます(この repo は認証情報を持ちません)。
    EOF

    remote=${lib.escapeShellArg rcloneRemote}
    while ! { rclone listremotes | grep -qx "$remote:" && rclone about "$remote:" >/dev/null 2>&1; }; do
      say ""
      say "rclone の remote '$remote' に接続できませんでした。"
      say "  (未作成か、認証の期限が切れています)"
      confirm "rclone config を起動して設定しますか" y \
        || die "中断しました。remote '$remote' を用意してから再実行してください。"
      cat >&2 <<EOF

    rclone config が開きます。remote の名前は **$remote** にしてください
    (この名前は home-manager の設定と一致している必要があります)。
    種類は Google Drive を選び、あとは既定のまま進めて構いません。

    EOF
      rclone config
    done
    say "remote '$remote' に接続できました。"

    say "$filters に対象のファイルやパターンを指定し、最後のルール - ** を維持してください。"
    say "旧remoteと両PCを照合・バックアップし、新remoteへ vault 相対の配置で集めてください。"
    say "両側を確認した後、手動で memex-sync --resync --dry-run、memex-sync --resync を実行してください。"

    # ---- 残る手作業 ----
    say ""
    cat >&2 <<'EOF'
    === ここまでで自動化できる分は終わりです ===

    残りは手作業です:
      * Obsidian を起動して、vault として上のフォルダを開く
        初回だけ「このプラグインの製作者を信用しますか」を聞かれます(信用すると有効になります)。
      * Claude を使うプラグインを動かすなら、一度ログインする
            claude
      * vault を別のマシンにも持っていくなら、自分で git remote を足して push する
            git remote add origin <URL>
            git push -u origin main

    手動検証・初期化後に sync.autoSync を有効にすると、変更監視と定期実行で同期します。
    手で走らせたいときは memex-sync を実行してください。
    EOF
  '';
}

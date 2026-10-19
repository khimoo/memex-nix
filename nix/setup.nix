# 宣言的に片付かない残りだけを進める対話スクリプト。
#
# vault の用意(フォルダ・git init・.gitignore)と .obsidian の配置は home-manager の
# activation が持つ。ここに残るのは、宣言では原理的に届かない2つだけ——
# Google の OAuth(rclone config)と、初回同期が曖昧なとき(両側にデータがある)の判断。
#
# 設計方針:
#   - 進捗ファイルを持たない。各ステップは実物(rclone remote / bisync の記録)を見て、
#     済んでいれば skip する。途中で止めても再実行すれば続きから進む。
#   - 外部サービスの認証は「確かめて、駄目なら本来のツールに渡す」(probe, don't provision)。
#     GitHub には一切触らない——remote との接続は各自の領分。
#   - 自分が起こした変更以外を元に戻さない。既にあるものは確認なしに上書きしない。
#
# 同期は専用スクリプトを呼ぶ(ロジックを二重に持たない)。
{ pkgs
, vaultDir
, rcloneRemote
, syncScript
}:

let
  inherit (pkgs) lib;
in
pkgs.writeShellApplication {
  name = "zettelkasten-setup";
  runtimeInputs = [ pkgs.coreutils pkgs.rclone pkgs.gnugrep ];
  text = ''
    vault=${lib.escapeShellArg vaultDir}

    say() { echo "$*" >&2; }
    die() { echo "$*" >&2; exit 1; }

    # 対話が前提なので、パイプや systemd から呼ばれたら黙って進めず落とす。
    if [ ! -t 0 ]; then
      die "zettelkasten-setup は対話的に実行してください(標準入力が端末ではありません)。"
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
    === zettelkasten setup ===

    vault: $vault

    この先で行うこと:
      1. Google Drive との接続確認(rclone)
      2. 初回同期

    途中で止めても、もう一度実行すれば済んだところは飛ばします。

    EOF

    # vault は switch が用意している前提。無いのは設定側の問題なので、ここでは作らずに案内する。
    if [ ! -d "$vault" ]; then
      say "vault がまだありません: $vault"
      say "  → services.zettelkasten.initializeVault = true にして switch し直すか、"
      say "    別の経路(ノート repo の clone 等)で用意してから再実行してください。"
      die "中断しました。"
    fi

    # ---- rclone ----
    say ""
    cat >&2 <<'EOF'
    添付ファイル・文献 PDF・Originals は Google Drive で同期します(有効な対象のみ)。
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

    # ---- 初回同期 ----
    say ""
    if confirm "初回の同期を実行しますか" y; then
      if ! ${lib.getExe syncScript}; then
        say ""
        say "同期に失敗しました。上の rclone のメッセージが理由です。"
        say "  → 記録が無い場合は両側の中身を確認し、失敗した対象だけを初期化してください:"
        say "      ZK_FORCE_RESYNC=1 zettelkasten-sync --only <対象名> --resync"
        say "    対象名は zettelkasten-sync --help で確認できます。Originals は originals です。"
      fi
    else
      say "同期は行いませんでした。あとで zettelkasten-sync を実行してください。"
    fi

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

    自動同期が有効な対象は、ファイル変更と定期実行で同期します。
    Originals は実 Drive での手動検証・初期化後に originals.autoSync を有効にしてください。
    手で走らせたいときは zettelkasten-sync を実行してください。
    EOF
  '';
}

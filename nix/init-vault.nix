# vault(ノートを置くフォルダ)を宣言的に用意する。services.zettelkasten.initializeVault の
# activation だけが呼ぶ。
#
# 非破壊の契約——作るのは「無いもの」だけで、既にあるものは触らない:
#   - vault フォルダ … 無ければ作る
#   - git リポジトリ … .git が無ければ init する
#   - .gitignore     … 無ければ書く(既存の内容は書き換えない)
#
# 別リポジトリの作業ツリーの中を vault にすると、ノートがそちらの commit に巻き込まれる。
# フォルダを作る前に検査し、該当したら何もせずに失敗する(作ってから中止すると、我々が作った
# 空フォルダだけが残る)。
{ pkgs }:

pkgs.writeShellApplication {
  name = "init-vault";
  runtimeInputs = [ pkgs.coreutils pkgs.git ];
  text = ''
    vault="''${1:-}"

    if [ -z "$vault" ]; then
      echo "init-vault: vault パスが未指定です(第1引数に絶対パス)。" >&2
      exit 1
    fi

    if [ -e "$vault" ] && [ ! -d "$vault" ]; then
      echo "init-vault: そこはフォルダではありません: $vault" >&2
      exit 1
    fi

    # git は物理パスを返すので、比較する側も物理パスに揃える(symlink 越しの誤検知を避ける)。
    if [ -d "$vault" ]; then
      vault_real="$( cd "$vault" && pwd -P )"
      toplevel="$(git -C "$vault" rev-parse --show-toplevel 2>/dev/null || true)"
    else
      vault_real="$vault"
      parent="$vault"
      while [ ! -d "$parent" ] && [ "$parent" != "/" ]; do
        parent="$(dirname "$parent")"
      done
      toplevel="$(git -C "$parent" rev-parse --show-toplevel 2>/dev/null || true)"
    fi

    if [ -n "$toplevel" ] && [ "$toplevel" != "$vault_real" ]; then
      echo "init-vault: そこは別の git リポジトリの中です: $toplevel" >&2
      echo "  → ノートが別 repo の commit に巻き込まれるため中止しました。" >&2
      echo "    リポジトリの外を vaultDir にしてください。" >&2
      exit 1
    fi

    if [ ! -d "$vault" ]; then
      mkdir -p "$vault"
      echo "init-vault: 作成しました: $vault" >&2
    fi

    if [ -z "$toplevel" ]; then
      git -C "$vault" init -q
      echo "init-vault: git リポジトリにしました: $vault" >&2
    fi

    # 同期フォルダと端末固有のファイルは git に入れない。
    if [ ! -e "$vault/.gitignore" ]; then
      cat > "$vault/.gitignore" <<'EOF'
    /.obsidian/workspace.json
    /.obsidian/workspace-mobile.json
    /attachments/
    /references/
    /Originals/
    /_scratch/
    /.claudian/sessions/
    /.obsidian/plugins/realclaudian/data.json
    EOF
      echo "init-vault: .gitignore を作成しました: $vault/.gitignore" >&2
    fi
  '';
}

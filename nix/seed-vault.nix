# vault に骨格(分類フォルダ・運用ドキュメント・Obsidian 設定)を非破壊で配置(seed)する。
# module の activation が呼ぶ。vault パスは第1引数か MEMEX_ROOT で受け取る(依存性逆転)。
#
# 非破壊(seed-once)の契約は、運ぶ物の性質ごとに粒度が違う:
#   - .obsidian … ディレクトリ単位。既にあれば丸ごと触らない。Obsidian 自身が常時書き換える
#     自己整合的な状態なので、ファイル単位で差し込むと利用者が無効化したプラグインを
#     community-plugins.json 経由で復活させる事故が起きる。--obsidian が無ければ配置しない。
#   - それ以外 … ファイル単位。「CLAUDE.md だけ既にある」「System/Templates/ は空」が普通に起きるため、
#     無いものだけを置く。
#
# vault ディレクトリ自体が無ければ warning を出して skip する(まだノート repo を clone して
# いない fresh マシンでも switch を失敗させない。clone 後に再 switch すれば seed される)。
{ pkgs, skeleton }:

pkgs.writeShellApplication {
  name = "seed-vault";
  runtimeInputs = [ pkgs.coreutils pkgs.findutils ];
  text = ''
    with_obsidian=0
    positional=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --obsidian) with_obsidian=1 ;;
        -*) echo "seed-vault: 不明なオプション: $1" >&2; exit 1 ;;
        *) positional+=("$1") ;;
      esac
      shift
    done

    vault="''${positional[0]:-''${MEMEX_ROOT:-}}"

    if [ -z "$vault" ]; then
      echo "seed-vault: vault パスが未指定です。" >&2
      echo "  → 第1引数か環境変数 MEMEX_ROOT で vault(絶対パス)を渡してください。" >&2
      exit 1
    fi

    if [ ! -d "$vault" ]; then
      echo "seed-vault: vault が未 clone です(skip): $vault" >&2
      echo "  → ノートの private repo を clone してから再実行すれば骨格を配置します。" >&2
      exit 0
    fi

    src=${skeleton}

    # ---- .obsidian: ディレクトリ単位 ----
    if [ "$with_obsidian" -eq 1 ]; then
      if [ -e "$vault/.obsidian" ]; then
        echo "seed-vault: $vault/.obsidian は既に存在します(skip)。既存設定は上書きしません。" >&2
      else
        cp -r "$src/.obsidian" "$vault/.obsidian"
        chmod -R u+w "$vault/.obsidian"
        echo "seed-vault: .obsidian を配置しました: $vault/.obsidian" >&2
      fi
    fi

    # ---- それ以外: ファイル単位 ----
    # store 由来のファイルは read-only なので、置いた分だけ書き込み可能に戻す。
    placed=0
    while IFS= read -r -d "" rel; do
      case "$rel" in .obsidian/*) continue ;; esac
      dest="$vault/$rel"
      if [ -e "$dest" ] || [ -L "$dest" ]; then continue; fi
      mkdir -p "$(dirname "$dest")"
      cp -P "$src/$rel" "$dest"
      if [ ! -L "$dest" ]; then chmod u+w "$dest"; fi
      placed=$((placed + 1))
    done < <(cd "$src" && find . \( -type f -o -type l \) -printf '%P\0')

    if [ "$placed" -gt 0 ]; then
      echo "seed-vault: 骨格を $placed 件配置しました: $vault" >&2
    fi
  '';
}

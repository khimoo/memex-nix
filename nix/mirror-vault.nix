# vault の骨格を config repo の skeleton/ へミラーして commit する。
# home-manager(PATH)と `nix run`(ワンショット)が共有する 1 本のスクリプト。
#
# 責務: 骨格の source-of-truth は vault(ノートの private repo。obsidian-git が live 同期する)。
# public repo はそこからの派生スナップショットで、このスクリプトが「たまに手動で」更新する。
# seed-vault が public→vault の配布なのに対し、mirror-vault は vault→public の逆向き。
#
# 依存性逆転: source(vault)と dest(config repo)は引数/環境変数で受け取り、owner をハードコード
# しない。自分の骨格を配りたい人は自分の vault と dest を渡すだけでよい。
#
# 運ぶ物は2種類あり、選び方が逆になる:
#
#   .obsidian … denylist。`git ls-files .obsidian`(vault が tracked にした集合)を取り、そこから
#     配ってはいけないものを引く。Obsidian が勝手に増やすファイルに追随する必要があるため、
#     列挙しない側に倒す。1段目の sanitize は vault の .gitignore が担い(workspace.json や
#     token を持つ data.json はそこで除外済み)、2段目がこの層。
#
#   骨格(分類フォルダ・運用ドキュメント) … allowlist(nix/skeleton-paths.nix)。vault が tracked に
#     しているものの大半は個人のノート(Knowledge/Wiki/ Knowledge/Zettel/ LifeLogs/Dailies/ LifeState/Action/ …)なので、全 tracked を写すと
#     private が public へ流れ込む。足し忘れが「漏れる」方向に倒れるので、配ると決めたものを
#     列挙する側に倒す。列挙のどれかが vault に無ければ中止する——黙って落とすと、直後の
#     rsync --delete が repo 側からも消してしまう。
#
# excludedObsidianGlobs は「vault では tracked だが配らない」ファイル。vault 側の .gitignore では
# 表現できない(vault は自分用に tracked にしている)ので、配布の境界であるこの層で落とす。
# 同じ理由で obsidian-git の autoPullOnBoot も配布時だけ false にする。
{ pkgs
, skeletonPaths
, # typst-mate は 34MB の wasm を同梱する。版が上がるたび public repo の履歴に 34MB の blob が
  # 積まれるので配らない。プラグインは起動時に wasm の不在を見て manifest.json の版に一致する
  # release asset を自分で取り直すため(main.js の onload)、受け取り側の手作業は増えない。
  excludedObsidianGlobs ? [ ".obsidian/plugins/typst-mate/*.wasm" ]
}:

pkgs.writeShellApplication {
  name = "mirror-vault";
  runtimeInputs = [ pkgs.coreutils pkgs.git pkgs.rsync pkgs.jq pkgs.python3 ];
  text = ''
    err() { echo "mirror-vault: $*" >&2; }

    show_help() {
      echo "mirror-vault: vault の骨格を config repo の skeleton/ へミラーして commit する。" >&2
      echo "" >&2
      echo "usage: mirror-vault [--dry-run] [--push] [VAULT] [DEST]" >&2
      echo "  VAULT  vault(ノート private repo の clone)の絶対パス(省略時 MEMEX_ROOT)" >&2
      echo "  DEST   ミラー先 config repo の checkout 絶対パス(省略時 MEMEX_CONFIG_REPO)" >&2
      echo "  --dry-run  commit せず差分のみ表示する" >&2
      echo "  --push     commit 後に push する(既定は push しない=人間ゲート)" >&2
    }

    dry_run=0
    push=0
    positional=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --dry-run) dry_run=1 ;;
        --push) push=1 ;;
        -h|--help) show_help; exit 0 ;;
        --) shift; while [ "$#" -gt 0 ]; do positional+=("$1"); shift; done; break ;;
        -*) err "不明なオプション: $1"; show_help; exit 1 ;;
        *) positional+=("$1") ;;
      esac
      shift
    done

    vault="''${positional[0]:-''${MEMEX_ROOT:-}}"
    dest="''${positional[1]:-''${MEMEX_CONFIG_REPO:-}}"

    # ---- preflight: 宣言的に用意できない前提(clone の有無・git repo か)を loud に落とす ----
    if [ -z "$vault" ]; then
      err "vault パスが未指定です。"
      err "  → 第1引数か環境変数 MEMEX_ROOT で vault(絶対パス)を渡してください。"
      exit 1
    fi
    if [ ! -d "$vault" ]; then
      err "vault が見つかりません: $vault"
      exit 1
    fi
    if ! git -C "$vault" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      err "vault が git リポジトリではありません: $vault"
      exit 1
    fi
    if [ ! -d "$vault/.obsidian" ]; then
      err "vault に .obsidian がありません: $vault/.obsidian"
      err "  → Obsidian か seed-vault で設定を用意してから実行してください。"
      exit 1
    fi

    if [ -z "$dest" ]; then
      err "ミラー先 config repo が未指定です。"
      err "  → 第2引数か環境変数 MEMEX_CONFIG_REPO で dest(絶対パス)を渡してください。"
      exit 1
    fi
    if [ ! -d "$dest" ]; then
      err "config repo が見つかりません: $dest"
      exit 1
    fi
    if ! git -C "$dest" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      err "config repo が git リポジトリではありません: $dest"
      exit 1
    fi

    # 望ましい状態を tmp に組み立てる。dest には直接触れずここから反映する。
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    # ---- .obsidian(denylist) ----
    mapfile -d "" tracked < <(git -C "$vault" ls-files -z -- .obsidian)
    if [ "''${#tracked[@]}" -eq 0 ]; then
      err ".obsidian が vault で git tracked ではありません。ミラーを中止します。"
      err "  → 誤って dest の設定を消さないための安全策です。vault 側で .obsidian を add してください。"
      exit 1
    fi
    ( cd "$vault" && cp --parents -p -- "''${tracked[@]}" "$tmp/" )

    # bookmarks.json と workspaces.json は自分のノートへの参照を持ちうる。vault 側で untrack すると
    # マシン間で同期されなくなるので、vault では tracked のままにして配布の境界で落とす。
    # excludedPlugins と違い環境依存の判断ではない(Obsidian の仕様)ため option にしない。
    for state in bookmarks.json workspaces.json; do
      rm -f "$tmp/.obsidian/$state"
    done

    excluded_globs=(${pkgs.lib.escapeShellArgs excludedObsidianGlobs})
    for glob in "''${excluded_globs[@]}"; do
      ( cd "$tmp" && find . -path "./$glob" -exec rm -rf {} + )
    done

    # 配布先の vault は remote を持たないことがあり、起動時 pull が毎回エラー通知になる。
    # owner の vault は true のままで良いので、配布の境界であるここで落とす。
    git_json="$tmp/.obsidian/plugins/obsidian-git/data.json"
    if [ -f "$git_json" ]; then
      jq '.autoPullOnBoot = false' "$git_json" > "$git_json.new"
      mv "$git_json.new" "$git_json"
    fi

    # ---- 骨格(allowlist) ----
    files=(${pkgs.lib.escapeShellArgs skeletonPaths.files})
    missing=()
    for rel in "''${files[@]}"; do
      [ -f "$vault/$rel" ] || missing+=("$rel")
    done
    if [ "''${#missing[@]}" -gt 0 ]; then
      err "配布対象が vault にありません。ミラーを中止します:"
      for rel in "''${missing[@]}"; do err "  - $rel"; done
      err "  → vault 側で用意するか、nix/skeleton-paths.nix から外してください。"
      err "    (黙って落とすと dest からも消えるため、ここで止めています。)"
      exit 1
    fi
    ( cd "$vault" && cp --parents -p -- "''${files[@]}" "$tmp/" )

    # 配布元固有のリンクと履歴を落とす。元の vault は変更しない。
    python3 ${./sanitize-skeleton.py} "$tmp"

    # Claude も .agents の正本を読む。コピーで二つの本文を作らない。
    ${pkgs.lib.concatStringsSep "\n" (pkgs.lib.mapAttrsToList (name: target: ''
      mkdir -p "$tmp/$(dirname ${pkgs.lib.escapeShellArg name})"
      ln -s ${pkgs.lib.escapeShellArg target} "$tmp/"${pkgs.lib.escapeShellArg name}
    '') skeletonPaths.links)}

    # 空フォルダは git に載らないので .gitkeep で保持する。中身は各自のノートなので運ばない。
    dirs=(${pkgs.lib.escapeShellArgs skeletonPaths.dirs})
    for rel in "''${dirs[@]}"; do
      mkdir -p "$tmp/$rel"
      : > "$tmp/$rel/.gitkeep"
    done

    if [ "$dry_run" -eq 1 ]; then
      err "--dry-run: $vault → $dest/skeleton の差分"
      if git --no-pager diff --no-index --stat -- "$dest/skeleton" "$tmp"; then
        err "(差分なし)"
      fi
      exit 0
    fi

    # dest/skeleton を tmp の内容に一致させる(--delete で対象から外れたファイルの削除も伝播)。
    rsync -a --delete "$tmp/" "$dest/skeleton/"

    # skeleton パスだけを stage/commit する。dest に別途 stage 済みの変更(flake 等)は巻き込まない。
    git -C "$dest" add -A -- skeleton
    if git -C "$dest" diff --cached --quiet -- skeleton; then
      err "差分なし。commit しません。"
      exit 0
    fi

    vault_rev="$(git -C "$vault" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    git -C "$dest" commit -q -m "skeleton: mirror vault skeleton @ $vault_rev" -- skeleton
    err "commit しました: $dest"
    git -C "$dest" --no-pager show --stat --oneline HEAD >&2 || true

    if [ "$push" -eq 1 ]; then
      err "push します..."
      git -C "$dest" push
    else
      err "push は未実行です。確認後に 'git -C \"$dest\" push' するか --push を付けてください。"
    fi
  '';
}

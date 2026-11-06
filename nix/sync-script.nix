{ pkgs, vaultDir, rcloneRemote, annexRemote }:
let
  inherit (pkgs) lib;
  rclone = import ./rclone-lib.nix { inherit pkgs; };
in
pkgs.writeShellApplication {
  name = "memex-sync";
  runtimeInputs = rclone.runtimeInputs ++ [ pkgs.git pkgs.git-annex pkgs.file pkgs.gnused ];
  text = ''
    ${rclone.text}

    case "''${1:-}" in
      "") ;;
      -h | --help)
        echo '使い方: memex-sync'
        echo '  保存先の規則(.gitattributes の annex.largefiles)に合わない既存ファイルを移し、'
        echo '  git-annex の中身を Google Drive と各 PC の間で同期する。'
        exit 0 ;;
      *) echo "引数は受け付けません: $1" >&2; exit 1 ;;
    esac

    vault=${lib.escapeShellArg vaultDir}
    annex_remote=${lib.escapeShellArg annexRemote}

    if [ ! -d "$vault/.git" ]; then
      echo "vault が Git リポジトリではありません: $vault" >&2
      exit 1
    fi
    cd "$vault"

    if [ -z "$(git config --get annex.uuid || true)" ]; then
      echo "この PC の vault は git-annex で初期化されていません。memex-setup を実行してください。" >&2
      exit 1
    fi
    if [ -z "$(git config --get "remote.$annex_remote.annex-uuid" || true)" ]; then
      echo "保存先 '$annex_remote' がこの PC で有効になっていません。memex-setup を実行してください。" >&2
      exit 1
    fi

    memex_rclone_init
    memex_rclone_check ${lib.escapeShellArg rcloneRemote}

    # annex.thin は使わない。作業ファイルと .git/annex/objects が hardlink になり、Drive へ送る前に
    # ファイルを上書きすると、古い版の唯一の中身も書き換わる。
    # 届いていない中身を先に取る。中身の無いファイルは種類を判定できない。
    git annex sync --only-annex --content
    # sync --content が扱うのは今のファイルだけ。消したファイルや古い版の中身も Drive(backup)に送る。
    # 他の PC から古い版を取ったり、手元から消したりはしない。
    git annex copy --all --to "$annex_remote"

    # annex.largefiles は新しく追加したファイルにだけ効く。規則を変えた後や、git-annex の無い環境で
    # commit されたファイルは、規則と違う側に残る。前回確かめた commit からの差分と、前回保留した
    # ファイルを見直す。.gitattributes が変わったときは全ファイルが対象になる。
    state_dir="$(git rev-parse --git-dir)/memex-sync"
    mkdir -p -- "$state_dir"
    last="$(cat -- "$state_dir/classified" 2>/dev/null || true)"
    files=()
    if [ -n "$last" ] && git cat-file -e "$last^{commit}" 2>/dev/null \
      && git diff --quiet "$last" HEAD -- ':(glob)**/.gitattributes'; then
      mapfile -d "" files < <(git diff -z --name-only --diff-filter=AMR "$last" HEAD)
      if [ -f "$state_dir/pending" ]; then
        mapfile -d "" -O "''${#files[@]}" files < "$state_dir/pending"
      fi
    else
      mapfile -d "" files < <(git ls-files -z)
    fi

    # 利用者が編集中のファイルは移さない。移すと、その編集まで自動の commit に入る。
    declare -A dirty=()
    while IFS= read -r -d "" f; do
      dirty["$f"]=1
    done < <(git diff -z --name-only HEAD)

    to_annex=()
    to_git=()
    pending=()
    unclassified=()
    declare -A seen=()
    for f in "''${files[@]}"; do
      if [ -n "''${seen["$f"]:-}" ]; then
        continue
      fi
      seen["$f"]=1
      if [ ! -f "$f" ] || [ -L "$f" ] || [ -z "$(git ls-files -- "$f")" ]; then
        continue
      fi
      if [ -n "''${dirty["$f"]:-}" ]; then
        pending+=("$f")
        continue
      fi
      annexed=false
      if git annex lookupkey -- "$f" >/dev/null 2>&1; then
        annexed=true
        if [ -z "$(git annex find --in=here -- "$f")" ]; then
          pending+=("$f")
          continue
        fi
      fi
      # 規則は HEAD のものを読む。作業ツリーの .gitattributes は編集中かもしれず、それで別のファイルを
      # 移して commit すると、編集を取り消しても戻らない。
      expr="$(git check-attr --source=HEAD annex.largefiles -- "$f" | sed 's/^.*: annex\.largefiles: //')"
      case "$expr" in
        unspecified | unset) large=false ;;
        *)
          status=0
          git annex matchexpression --largefiles "$expr" --file="$f" \
            --size="$(stat -c %s -- "$f")" \
            --mimetype="$(file -b --mime-type -- "$f")" \
            --mimeencoding="$(file -b --mime-encoding -- "$f")" >/dev/null 2>&1 || status=$?
          case "$status" in
            0) large=true ;;
            1) large=false ;;
            *) unclassified+=("$f"); pending+=("$f"); continue ;;
          esac
          ;;
      esac
      if [ "$large" = true ] && [ "$annexed" = false ]; then
        to_annex+=("$f")
      elif [ "$large" = false ] && [ "$annexed" = true ]; then
        to_git+=("$f")
      fi
    done

    # 手順は https://git-annex.branchable.com/tips/largefiles/ の変換手順。
    for f in "''${to_annex[@]}"; do
      git rm -q --cached -- "$f"
      git annex add -q --force-large -- "$f"
    done
    for f in "''${to_git[@]}"; do
      git annex unlock -q -- "$f" 2>/dev/null || true
      git rm -q --cached -- "$f"
      git annex add -q --force-small -- "$f"
    done
    moved=("''${to_annex[@]}" "''${to_git[@]}")
    if [ "''${#moved[@]}" -gt 0 ]; then
      # 中身を変えずに保存先だけを移す commit。pathspec 付きなので、利用者が別に stage した変更は含めない。
      # push は利用者に任せる。
      git commit -q -m "memex-sync: 保存先の規則に合わせて ''${#moved[@]} 件を移す" -- "''${moved[@]}"
      printf '保存先を移した: %s\n' "''${moved[@]}" >&2
    fi
    git rev-parse HEAD > "$state_dir/classified"
    if [ "''${#pending[@]}" -gt 0 ]; then
      printf '%s\0' "''${pending[@]}" > "$state_dir/pending"
    else
      rm -f -- "$state_dir/pending"
    fi

    if [ "''${#to_annex[@]}" -gt 0 ]; then
      git annex sync --only-annex --content
      git annex copy --all --to "$annex_remote"
    fi

    failed=false
    if [ "''${#unclassified[@]}" -gt 0 ]; then
      printf '保存先の規則を評価できなかった: %s\n' "''${unclassified[@]}" >&2
      failed=true
    fi
    # .gitignore は追跡中のファイルには効かない。「その PC だけ」に変えたつもりのファイルを知らせる。
    mapfile -d "" ignored < <(git ls-files -z -ci --exclude-standard)
    if [ "''${#ignored[@]}" -gt 0 ]; then
      printf '.gitignore に当たるが Git で追跡中(他の PC にも配られる): %s\n' "''${ignored[@]}" >&2
      echo '  → その PC だけに置くなら git rm --cached <ファイル> で追跡から外して commit する。' >&2
      failed=true
    fi
    if [ "$failed" = true ]; then
      exit 1
    fi
  '';
}

# memex-nix

Obsidian の vault を、どのマシンでも同じ形で立ち上げるための **home-manager モジュール**。
添付ファイルと文献 PDF の Google Drive 同期・papis（文献管理）の設定・Obsidian 本体と
`.obsidian` 設定・vault の骨格（ノートの分類フォルダと運用ドキュメント）を、これ一つが持つ。
ノート本文は別の private repo にあり、ここには含まれない。

対応環境は **home-manager**（Linux / macOS / WSL）。Windows では WSL の中で使う。

## セットアップ

### 1. Nix を入れる

WSL なら WSL の中に入れる（Windows 側ではない）。

```sh
sh <(curl -L https://nixos.org/nix/install) --daemon
```

flake を有効にする:

```sh
mkdir -p ~/.config/nix
echo 'experimental-features = nix-command flakes' >> ~/.config/nix/nix.conf
```

一度ターミナルを開き直す。

### 2. `~/.config/home-manager/flake.nix` を作る

下の内容をそのまま貼る。**`username` と `system` の2行だけ**自分の環境に書き換える
（`username` は `whoami` の出力）。

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    memex-nix.url = "github:khimoo/memex-nix";
  };

  outputs = { nixpkgs, home-manager, memex-nix, ... }:
    let
      # ==== ここだけ自分の環境に合わせる ====
      username = "alice";
      system = "x86_64-linux"; # Intel Mac は "x86_64-darwin" / Apple Silicon は "aarch64-darwin"
      # =====================================

      homeDirectory =
        if nixpkgs.lib.hasSuffix "darwin" system
        then "/Users/${username}"
        else "/home/${username}";
    in
    {
      homeConfigurations.${username} = home-manager.lib.homeManagerConfiguration {
        pkgs = import nixpkgs {
          inherit system;
          # Obsidian と claude-code は unfree なので許可が要る。
          config.allowUnfree = true;
        };

        modules = [
          memex-nix.homeModules.memex
          {
            home = {
              inherit username homeDirectory;
              stateVersion = "25.11";
            };

            services.memex = {
              enable = true;
              vaultDir = "${homeDirectory}/memex";
              # ゼロから始めるなら true。vault フォルダを switch が用意する。
              # 既にノートの repo を clone してある/これから clone するなら false。
              initializeVault = true;
              obsidian.enable = true;
              papis.enable = true;
            };
          }
        ];
      };
    };
}
```

### 3. 反映する

```sh
nix run home-manager/release-25.11 -- switch
```

初回は Obsidian などのダウンロードで時間がかかる。2回目からは `home-manager switch` で足りる。

この switch が、vault フォルダの用意（`initializeVault = true` のとき。作成・`git init`・
`.gitignore`）と、骨格の配置——分類フォルダ・運用ドキュメント・`.obsidian` 設定——まで済ませる。
どれも既にあるものは触らない。骨格の自動配置も `initializeVault = true` のときだけ行う。

### 4. `memex-setup` を実行する

```sh
memex-setup
```

宣言では原理的に届かない残り——Google Drive の認証（`rclone config` を開いて渡す）と、
初回同期が曖昧なとき（ローカルと Drive の両方に中身がある）の判断——だけを聞く。
**GitHub には一切触らない**ので、vault を push したければ自分で remote を足す。

途中で止めても、もう一度実行すれば済んだところは飛ばす。進捗ファイルは持たず、各ステップが
実物（rclone remote / bisync の記録）を見て判断する。

最後に残る手作業は2つ:

- Obsidian を起動して vault を開く。初回だけ「このプラグインの製作者を信用しますか」を聞かれる。
- Claude を使うプラグインを動かすなら、一度 `claude` を実行してログインする。

2台目以降は、`initializeVault` を `false` にしたうえで vault を clone してから 3→4 をやる
（先に空フォルダを作ると clone が失敗するため）。この場合、骨格は再配置しないので、
Vault 側で削除した分類フォルダや運用ドキュメントも復活しない。

## 設定できること

`services.memex` の options。`vaultDir` 以外は既定のままでも動く。

| option | 既定 | |
|---|---|---|
| `enable` | `false` | モジュール全体の on/off |
| `vaultDir` | （必須） | vault の絶対パス。`Assets/attachments/` と `Assets/references/` が同期対象 |
| `initializeVault` | `false` | vault フォルダと骨格を switch が用意する（作成・`git init`・`.gitignore`・分類フォルダ等）。別経路で clone するなら `false` のまま |
| `rcloneRemote` | `"gdrive"` | 同期先の rclone remote 名 |
| `attachments.enable` | `true` | 添付フォルダの Google Drive 双方向同期 |
| `attachments.folder` | `"zettelkasten-attachments"` | Drive 側のフォルダ名 |
| `attachments.intervalSeconds` | `900` | 定期同期の間隔 |
| `papis.enable` | `false` | papis 本体・設定・`Assets/references/` の同期 |
| `papis.folder` | `"papis-library"` | Drive 側のフォルダ名 |
| `papis.opentool` | `"xdg-open"` | `papis open` が使うビューア |
| `obsidian.enable` | `false` | Obsidian 本体の導入。`initializeVault = true` のときは `.obsidian` 設定も配置 |
| `obsidian.installPackage` | `obsidian.enable` | Obsidian 本体を入れるか（別経路で入れているなら `false`） |
| `mirrorRepo` | `null` | `mirror-vault` の出力先（骨格を配る側だけが使う） |
| `after` / `wants` | `[]` | 同期サービスの起動順序の依存 |

vault の中のパス（`Assets/attachments/` と `Assets/references/`）は規約で固定していて、options にはしていない。
配布する `.obsidian/app.json` の `attachmentFolderPath` と食い違わせないため。

## 日常の操作

同期は自動で走る（ファイルを変更したときと、取りこぼしを拾う定期実行）。手で走らせるなら:

```sh
memex-sync              # 設定どおり全部
memex-sync --only papis # papis だけ
memex-sync --dry-run    # 以降の引数は rclone bisync へ素通し
```

同期先は home-manager の options が持っていて、引数では変えられない。

**「このマシンには同期の記録が無いのに Drive 側にはデータがある」** と言われて止まったときは、
記録の喪失か、既存の Drive に新しいマシンを合流させようとしているかのどちらか。中身を確認して、
合流させる場合だけ、対象を限定して `MEMEX_FORCE_RESYNC=1 memex-sync --only <対象名> --resync` を実行する。


## Originals の同期

`originals.enable = true` で、Git管理外の `<vault>/Assets/Originals` を同期対象に加える。

| option | 既定 | 用途 |
|---|---|---|
| `originals.enable` | `false` | 原本の双方向同期をコマンドへ追加 |
| `originals.folder` | `"zettelkasten-originals"` | 同じremote内の同期先 |
| `originals.backupFolder` | `"zettelkasten-originals-backups"` | 同期対象外の旧版退避先 |
| `originals.intervalSeconds` | `900` | 自動同期時の定期間隔 |
| `originals.autoSync` | `false` | 初期化・実Drive試験後に自動実行を有効化 |

通常同期の競合は勝者を選ばず両版を別名保存する。元の画像パスがなくなる場合があるため、
競合ログを確認し、人が採用版を元の名前へ戻すかノートの参照を直してから再同期する。
削除は伝播するが、上書き・削除される版をローカルとremoteそれぞれの退避先へ保持する。
退避先はホスト名と一意な実行IDで分け、通常の同期対象には含めない。
ローカル退避先は `${XDG_DATA_HOME:-$HOME/.local/share}/memex/originals-backups/`。
この退避は同じDriveアカウントの喪失に備える独立バックアップではない。

Originalsは `--recover --max-lock 2m` を使う。強制中断時に残るロックは最後の更新から
約2分で期限切れとなり、次の通常同期が直近の成功履歴から復旧を試みる。
ロックの自動削除や自動resyncは行わない。履歴欠損・復旧失敗は停止して調査する。
[rcloneの復旧仕様](https://rclone.org/bisync/#recover)と
[ロック期限の仕様](https://rclone.org/bisync/#max-lock)を参照。

Originalsは同期履歴がないとき自動初期化せず停止する。両PCとDriveの内容を同期外へ退避・照合し、
初期化の基準を決めてから、対象を限定して実行する:

```sh
memex-sync --only originals --resync --dry-run
memex-sync --only originals --resync
memex-sync --only originals
```

`--dry-run`でも退避用の空ディレクトリが作られる場合がある。履歴が既にある場合の
`MEMEX_FORCE_RESYNC=1` は、内容確認と退避後の手動復旧に限る。自動再試行にresyncを組み込まない。
resyncでは通常競合の両版保存と挙動が違うため、dry-runだけで元データの退避を代用しない。

導入時は隔離データで両PC追加、同名競合、削除・上書きと復元、中断、重複実行を確認する。
確認前は `autoSync = false` を維持する。同期履歴は各PCのローカルcacheに置き、他PCと共有しない。
外部フレークの利用側は更新したinputを使う必要がある。ソースの編集だけでは既存の
`flake.lock`や実行中サービスは更新されない。

## vault の骨格を配る側へ

`skeleton/`（= `packages.vault-skeleton`）に、新品の vault がどう見えるかが入っている。中身は
2 種類——`.obsidian/`（Obsidian 設定と community plugin 本体）と、ノートの分類フォルダ・
運用ドキュメント。ノート本文は入っていない。

- `seed-vault` — 骨格を vault へ非破壊コピーする。`initializeVault = true` のときだけ home-manager の activation が呼ぶ
  （`.obsidian` は `obsidian.enable` のときだけ）。
- `mirror-vault` — 逆向き。vault の骨格を config repo の `skeleton/` へ写して commit する
  （`--dry-run` / `--push` あり）。live な source-of-truth は vault（`obsidian-git` が同期している）で、
  この repo はそこからの派生スナップショット。`mirrorRepo` を設定すると PATH に載る。

### 配布する新構成

入口は `Home.md`。知識は `Knowledge/Wiki/` と `Knowledge/Zettel/`、未処理は `Inbox/`、行動は `LifeState/Action/`、
原稿は `Knowledge/Writing/`、資料ごとの読書は `Knowledge/Reading/<citekey>/` に置く。
`System/Bases/` と `System/Templates/` は Home・日次・週次・月次の一覧を支える。
`Assets/Originals/` と `_scratch/` は作るが、中身は Git 管理とミラーの対象外にする。
旧 `Tasks/`、`Goals/`、`Registry/` 等は新規作成しない。

共有指示は `AGENTS.md`、スキルは `.agents/skills/` が正本。`CLAUDE.md` は `@AGENTS.md` を読み、
`.claude/skills` は `../.agents/skills` への相対リンクになる。端末固有の `.claude/settings.json` と
`.codex/config.toml` は配らない。個別原稿用の校正スキルと、資料の特定節だけの取り決めも含めない。

ミラーでは Home の個人用リンク、移行案内、配布元の失敗履歴・規則の履歴列を除く。
この処理は `nix/sanitize-skeleton.py` にまとめ、再ミラーでも同じ境界を保つ。
`System/失敗記録.md` は配布先で記録するための空の案内にする。

### seed の粒度は 2 つ

運ぶ物の性質が違うので、「無ければ置く」の単位を揃えていない。

- **`.obsidian/` はディレクトリ単位** — 既にあれば丸ごと触らない。Obsidian 自身が常時書き換える
  自己整合的な状態なので、ファイル単位で差し込むと、利用者が無効化したプラグインを
  `community-plugins.json` 経由で復活させる事故が起きる。
- **骨格はファイル単位** — 「`CLAUDE.md` だけ既にある」「`System/Templates/` は空」が普通に起きる。

### 何を配るかの選び方も 2 つ

`.obsidian` は **denylist**、骨格は **allowlist**。逆にしているのは、間違えたときにどちらへ倒れるかが
違うため。

`.obsidian` は Obsidian が勝手にファイルを増やすので、列挙すると追随できない。よって
`git ls-files .obsidian`（vault が tracked にした集合）を取り、そこから配ってはいけないものを引く。
1 段目の sanitize は vault の `.gitignore` が担い（`workspace.json` やトークンを持つ `data.json` は
そこで除外済み）、2 段目が `mirror-vault` の以下:

- **`bookmarks.json` / `workspaces.json`** — 自分のノートへの参照と名前付きレイアウトを持つ。
  vault 側で untrack するとマシン間で同期されなくなるので、vault では tracked のままにして
  配布の境界で落とす。
- **Typst Mate の `*.wasm`** — 34MB あり、版が上がるたび履歴に blob が積まれる。プラグイン本体は
  配る。起動時に wasm の不在を見て、`manifest.json` の版に一致する release asset を自分で
  取り直すので、受け取り側の手作業は増えない（初回だけダウンロードが走る）。
- **`obsidian-git` の `autoPullOnBoot`** — remote を持たない vault では起動ごとに git のエラー通知が出るため。

骨格の方は逆で、vault が tracked にしているものの大半（`Knowledge/Wiki/` `Knowledge/Zettel/` `LifeLogs/Dailies/` `LifeState/Action/` …）が個人の
ノート。全 tracked を写すと private が public へ流れ込むので、配ると決めたものを
`nix/skeleton-paths.nix` に列挙する。足し忘れは「配り漏れ」で済み、漏洩にはならない。
列挙したファイルが vault に無ければ `mirror-vault` は中止する——黙って落とすと、直後の
`rsync --delete` が repo 側からも消してしまうため。

空フォルダは git に載らないので `.gitkeep` で保持する。`Assets/` の3つのフォルダは、
同期ジョブの `ConditionPathIsDirectory` が要求するため、空でも存在させる必要がある。

### いつ mirror するか

**新しいマシンを立てるときではない。** ノートの private repo を clone する運用なら、その clone が
骨格を連れてくるので、`initializeVault = false` のままにして `seed-vault` を実行しない。
このスナップショットが効くのは骨格を持たない vault——`initializeVault = true` で
ゼロから始める環境である。

したがって mirror の契機は「vault 側で運用を変えて、配る版にも反映したくなったとき」だけ。反映は
消費側が `nix flake update` して初めて届く（input は `flake.lock` に pin されている）。

## なぜ mechanism を分離したか

元は private な vault repo に同居していた。flake の input として `git+ssh` で取得すると
**評価時に SSH 鍵が必須**になり、「鍵ゼロからの環境復元」を阻む。mechanism を public 化して
`github:` で取得することで、消費側 flake の eval が SSH 鍵に依存しなくなる。

この repo は rclone の認証情報を持たない。各マシンで `rclone config` が作った
`~/.config/rclone/rclone.conf` を、rclone 自身が既定で解決する。

## 配布物の検証

```sh
nix flake check
```

新旧ディレクトリ、Tasks/Journals設定、共有指示のリンク、新規Vaultへの配置、個人の内容の除外、
必須ファイル欠落時にミラー先を変更しないことを検証する。
現在のVaultとの一致も確かめる場合は、`tests/test_layout.py` の `SOURCE_VAULT` と
`VAULT_TOOLS` を指定して実行する。テストは一時Vaultを使い、commit・push は行わない。

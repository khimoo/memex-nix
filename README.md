# memex-nix

Obsidian の vault を用意する home-manager モジュール。Obsidian 本体と設定、vault の骨格、
ホワイトリストで選ぶ資料の Google Drive 双方向同期を提供する。
ノート本文は別の private repo に置く。対応環境は home-manager（Linux / macOS / WSL）。

## 導入

利用側の flake に input と module を追加する。

```nix
inputs.memex-nix.url = "github:khimoo/memex-nix";
```

home-manager の modules に次を指定する。Obsidian と claude-code の導入には、利用側の
nixpkgs で `config.allowUnfree = true` を設定する。

```nix
modules = [
  memex-nix.homeModules.memex
  {
    services.memex = {
      enable = true;
      vaultDir = "/home/alice/memex";
      initializeVault = true;
      obsidian.enable = true;
      sync = {
        enable = true;
        autoSync = false;
      };
    };
  }
];
```

`home-manager switch` が新規 vault の作成・git init・骨格の配置を行う。
既にノートの repo を clone して使う場合は `initializeVault = false` にする。
既存のファイルと Obsidian 設定は保持される。

`memex-setup` は対話的に rclone の接続を確認し、フィルタと手動初期化の手順を案内する。
rclone の認証情報は各マシンの `~/.config/rclone/rclone.conf` に用意する。
`RCLONE_CONFIG` による設定ファイルの指定も使える。

Obsidian で vault を開き、必要なプラグインを有効にする。Claude を使う場合は
各マシンで `claude` を実行してログインする。

## 設定

すべて `services.memex` の下に指定する。

| option | 既定 | 用途 |
|---|---|---|
| `enable` | `false` | モジュール全体を有効にする |
| `vaultDir` | 必須 | vault の絶対パス |
| `initializeVault` | `false` | 新規 vault と骨格を非破壊で用意する |
| `rcloneRemote` | `"gdrive"` | rclone remote 名 |
| `sync.enable` | `false` | `memex-sync` と `memex-setup` を提供する |
| `sync.autoSync` | `false` | vault の変更監視と定期同期を有効にする |
| `sync.folder` | `"memex-files"` | remote 内の同期先 |
| `sync.filtersFile` | `<vaultDir>/.drive-sync-filter` | 実行時に読むホワイトリストの絶対パス |
| `sync.backupFolder` | `"memex-files-backups"` | remote 内の退避先 |
| `sync.intervalSeconds` | `900` | 定期同期の間隔（秒） |
| `obsidian.enable` | `false` | Obsidian を導入し、新規 vault に設定を配置する |
| `obsidian.installPackage` | `obsidian.enable` | Obsidian を別経路で導入する場合は `false` |
| `mirrorRepo` | `null` | 骨格の手動ミラー先 checkout |
| `after` / `wants` | `[]` | 同期サービスの起動順序 |

## 同期対象を選ぶ

同期の root は vault 全体。資料の置き場所と Drive の同期選択は独立している。
`.drive-sync-filter` に vault 相対のファイルやパターンを指定する。空白や日本語も使える。

```text
+ /Knowledge/Reading/資料 A/paper.pdf
+ /Knowledge/**/*.png
- /Assets/資料/一時/**
+ /Assets/資料/**
- **
```

ルールは上から最初に一致したものを使うため、狭い除外は広い include より前に置く。
`+ /path` でファイル、`+ /path/**` で配下全体を選ぶ。ワイルドカードと除外は
[rcloneのフィルター構文](https://rclone.org/filtering/)を使える。コメント・空行を除いた最後のルールは `- **` にする。
ルールをリセットする `!` や `.`・`..` のパス成分は受け付けない。
新規 vault は `- **` のみで始まる。include のないフィルタは何も変更せず成功終了する。
フィルタの欠落・空ファイル・不正な構文・末尾の `- **` の欠落は接続前にエラーにする。

Git の除外設定とは独立している。Drive に入れたい資料はこのフィルタで選び、
Git に入れたくない資料は別に `.gitignore` へ指定する。
既存の `.gitignore` は書き換えない。

## 初期化と日常の同期

初回は両PCと remote の内容を照合・バックアップした後に手動で初期化する。
履歴がない場合、通常実行は自動で resync しない。

```sh
memex-sync --resync --dry-run
memex-sync --resync
memex-sync
memex-sync --dry-run
```

CLI で指定できる同期オプションは `--dry-run` と `--resync`。
同期先・フィルタ・退避先・競合処理は home-manager の設定から決まる。
手動同期を検証してから `sync.autoSync = true` にすると、監視と timer が一つの job を起動する。

フィルタを追加・削除すると rclone の hash 検査で通常同期が停止し、再照合を要求する。
除外はデータの削除命令ではなく、対象外となった両側の資料は残る。
変更内容と両側を確認・退避してから、既存履歴を作り直すことを明示する。

```sh
MEMEX_FORCE_RESYNC=1 memex-sync --resync --dry-run
MEMEX_FORCE_RESYNC=1 memex-sync --resync
```

この環境変数だけで初回の resync が有効になることはない。`--resync` の明示が必要。
resync は通常同期と競合処理が異なるため、dry-run は元データのバックアップを代用しない。
フィルタの検証済みコピーとrcloneの `.md5` は端末ごとの同期履歴ディレクトリに保存する。
Vault内のフィルタファイルの隣には同期状態を作らない。

通常同期の競合は `--conflict-resolve none --conflict-loser num` で両版を別名保存する。
元の資料パスがなくなる場合はログを確認し、採用版を元の名前に戻すかノートの参照を直す。
上書き・削除される版は、ローカルと remote それぞれの退避先に残す。
ローカルは `<xdg.dataHome>/memex/files-backups/<host>/<run-id>/`、remote は
`<sync.backupFolder>/<host>/<run-id>/`。退避先は同期先と重複させず、ローカルは vault 外に置く。
実行時にもローカルの symlink を解決して検査する。dry-run でも空の退避ディレクトリは作られる。
同じ Drive アカウント内の退避は、アカウントの喪失に備えた独立バックアップにはならない。

履歴は各PCの `${XDG_CACHE_HOME:-$HOME/.cache}/rclone/bisync-memex-files` に置く。
`--resilient --recover --max-lock 2m` により、中断後は直近の成功履歴から通常同期で復旧を試みる。
復旧できない場合は停止して調査し、resync を自動再試行へ組み込まない。
空のロックファイルは rclone が期限切れと見なさない場合があるため、処理が動いていないことを
確認してからロックを退避し、通常同期を再実行する。

## 旧3対象からの移行

`attachments`・`papis`・`originals` options は削除した。古い設定は移行案内付きで失敗する。
papis のパッケージ・設定・旧3対象の job は生成しない。既存資料や参照を移動・削除する処理はない。

1. 両PCの旧自動同期を利用側で停止し、`sync.autoSync = false` を維持する。
2. 両PCの資料と旧 remote（既定は `memex-attachments`、`papis-library`、`memex-originals`）を照合し、同期外へバックアップする。
3. 新 remote folder `memex-files` に vault 相対の配置で集める。例えば旧 `memex-attachments/a.png` は `memex-files/Assets/attachments/a.png` となる。同名の異なる版は人が確認して保持する。
4. 利用側の旧 options を `sync` に置き換え、継続したい資料をフィルタで指定する。旧3ディレクトリの役割はコードに固定していない。
5. 両PCで新しいコマンドを反映し、それぞれ手動で `--resync --dry-run`、`--resync`、通常同期を確認する。旧 baseline は新 baseline と混ぜない。
6. 隔離データで追加・競合・削除・上書きと復元・中断・重複実行を確認してから `sync.autoSync = true` にする。

移行が完了するまで旧 remote・旧資料・バックアップを保持する。外部 flake の input 更新と
home-manager の反映は利用側で行う。ソースを編集しただけでは既存サービスは更新されない。

利用側の `flake_public` では、次を同じ切替で更新する。

- `modules/home-manager/memex.nix`：旧optionsを `sync` に置換し、失敗通知を `memex-sync` に接続する。
- `hosts/nixos-desktop/data-disk.nix`：旧 `papis.libraryDir` 参照と `@papis` のマウントを外す。外す前に、`@papis` の資料を vault 内の新しい配置へ移しておく。

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
原稿は `Knowledge/Writing/`、資料ごとの読書は `Knowledge/Reading/<資料が分かる名前>/` に置く。
`System/Bases/` と `System/Templates/` は Home・日次・週次・月次の一覧を支える。
`Assets/attachments/` は Obsidian の貼付先として用意する。資料は任意の場所へ置ける。
`Assets/references/` と `Assets/Originals/` は新規 vault の必須フォルダではない。
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

空フォルダは git に載らないので `.gitkeep` で保持する。同期ジョブは vault 自体を監視する。
新規 vault の `.drive-sync-filter` は `- **` のみで、同期対象は利用者が選ぶ。
既存 vault のフォルダ・フィルタ・`.gitignore` は初期化や seed で上書きしない。

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

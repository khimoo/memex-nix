# memex-nix

Obsidian の vault を用意する home-manager モジュール。Obsidian 本体と設定、vault の骨格、
画像や PDF などのバイナリを git-annex で Google Drive に置く同期を提供する。
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
        autoSync = true;
      };
    };
  }
];
```

`home-manager switch` が新規 vault の作成・git init・骨格の配置を行う。
既にノートの repo を clone して使う場合は `initializeVault = false` にする。
既存のファイルと Obsidian 設定は保持される。

`memex-setup` は対話的に rclone の接続を確認し、vault の git-annex を初期化して、Drive の保存先を登録する
（2台目以降の PC では、既に登録された保存先を有効にする）。
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
| `sync.enable` | `false` | `memex-sync`、`memex-setup`、git-annex を提供する |
| `sync.autoSync` | `false` | commit・pull のたびと定期実行で `memex-sync` を起動する |
| `sync.annexRemote` | `"gdrive"` | Drive を指す git-annex の special remote 名 |
| `sync.folder` | `"memex-annex"` | rclone remote 内で中身を置くフォルダ（初回の登録時だけ使う） |
| `sync.intervalSeconds` | `900` | 定期同期の間隔（秒） |
| `obsidian.enable` | `false` | Obsidian を導入し、新規 vault に設定を配置する |
| `obsidian.installPackage` | `obsidian.enable` | Obsidian を別経路で導入する場合は `false` |
| `mirrorRepo` | `null` | 骨格の手動ミラー先 checkout |
| `after` / `wants` | `[]` | 同期サービスの起動順序 |

## 保存先の決まり方

vault の各ファイルの保存先は、次のどれか1つに決まる。

- `.gitignore` に当たる: その PC だけに置き、どこにも同期しない。
- `.gitattributes` の `annex.largefiles` に当たる: 中身を git-annex に入れて Drive に置き、Git には所在だけを入れる。
- それ以外: Git に入れる。

配布する `.gitattributes` は次のとおり。

```gitattributes
* annex.largefiles=mimeencoding=binary
.obsidian/** annex.largefiles=nothing
```

保存先はファイルの中身（バイナリかどうか）で決まり、置き場所には左右されない。
`.obsidian/` のプラグインの wasm などは Obsidian の起動に要るので、clone だけで揃うよう Git に入れる。

普通の `git add`（obsidian-git の commit も同じ）で振り分けられる。
作業ツリーには普通のファイルとして置く（`annex.addunlocked`）。
`annex.thin` は使わない。作業ツリーと `.git/annex/objects` が hardlink になり、Drive へ送る前に
ファイルを上書きすると、古い版の唯一の中身も書き換わるため。バイナリは作業ツリーと `.git/annex` に2部ある。

`.gitignore` は追跡中のファイルには効かない。既に Git や git-annex で追跡しているファイルを
「その PC だけ」にするには、`git rm --cached` で追跡から外して commit する。
`memex-sync` は、`.gitignore` に当たるのに追跡中のファイルを見つけると、失敗にして知らせる。

## 同期

`memex-sync` は次を行う。

1. `git annex sync --only-annex --content` で、git-annex ブランチと中身を `origin` と Drive の間で同期する。
   ノートのブランチ（main）の pull と push はしない。
2. `git annex copy --all --to <sync.annexRemote>` で、手元にある中身のうち Drive に無いもの（消したファイルや
   古い版を含む）を送る。`sync --content` は今のファイルしか扱わないため。他の PC から古い版を取ったり、
   手元から中身を消したりはしない。
3. 前回確かめた commit からの差分と、前回保留したファイルについて、`annex.largefiles` と実際の保存先が違う
   ものを移す。`.gitattributes` が変わったときは全ファイルを見直す。`annex.largefiles` は新しく追加したファイルに
   しか効かないため（規則を変えた後や、git-annex の無い環境で commit されたファイルが残る）。
   中身を変えずに保存先だけを移し、そのファイルだけを対象に commit する（利用者が stage した別の変更は含めない）。
   push はしない。編集中のファイルと、中身がまだ届いていないファイルは移さずに保留し、次の実行で見直す。
4. 移したファイルがあれば、1 と 2 をもう一度行う。

Drive の保存先は git-annex の `backup` グループに入れる。削除したファイルや古い版の中身も Drive に残る。
各 PC は `client` グループで、今のファイルの中身だけを持つ。
中身は rclone 経由で置き、ファイル名ではなく中身のハッシュ名で保存される。

`sync.autoSync = true` のとき、`.git/logs/HEAD` の変更（commit、pull、checkout）と定期実行で `memex-sync` が動く。
中身を送れるのは commit 済みのファイルだけなので、貼り付けた画像は commit した後に Drive に届く。
中身がまだ届いていない PC では、そのファイルは所在を書いた短いテキストに見える。次の `memex-sync` で中身が届く。

git-annex で初期化した vault では、Git の操作のたびに git-annex の filter が呼ばれる。
このモジュールは git-annex を PATH に入れ、Obsidian の起動環境にも入れる。

## 新しい PC

1. switch して、`memex-setup` を実行する。rclone の接続、`git annex init`、保存先の有効化までを行う。
2. `memex-sync` を実行すると、中身が届く。

最初の PC だけ、`memex-setup` が `sync.folder` を保存先として登録する（`git annex initremote`）。

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

空フォルダは git に載らないので `.gitkeep` で保持する。
新規 vault には、上の `.gitattributes` を配る。
既存 vault のフォルダ・`.gitattributes`・`.gitignore` は初期化や seed で上書きしない。

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

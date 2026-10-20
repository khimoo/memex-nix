---
name: restructuring-vault
description: ノートの移動、改名、分割、統合、削除、一括変更と、資料の保存場所の判断。Vault の構成を変える作業で、利用者が呼ぶ。
disable-model-invocation: true
---

# Vault の構成を変える作業

どの操作も、実行の前に計画（対象、理由、リンクの付け替え、戻し方）を示して承認を得る。承認は示した対象と操作に限って有効。何日もかかる作業は `System/計画/` に計画書を書き、`approved:` に日付があるものだけを実行する。

## 依存の棚卸し

移動、改名、削除の前に、次を確かめる。Obsidian の自動のリンク更新に頼りきらない。

- wikilink と埋め込みの被リンク: `obsidian vault=<対象Vault名> backlinks path="<パス>"`
- Dataview、Tasks、Bases のクエリに書かれたパスの条件（`rg -n '<パスの一部>' -g '*.md' -g '*.base'`）
- テンプレート（`Templates/`）と、Journals の設定（`.obsidian/plugins/journals/data.json`）にあるパス
- Tasks の設定（`.obsidian/plugins/obsidian-tasks-plugin/data.json`）の globalQuery と、ファイル名を日付として扱うフォルダ

変更に依存する設定、テンプレート、クエリは、ノートの変更と同じ移行の単位に含める。

## 移動と改名の手順

- 移動と改名は Obsidian CLI で行い、リンクの更新を Obsidian に任せる: `obsidian vault=<対象Vault名> move path="<元>" to="<先>"`、`obsidian vault=<対象Vault名> rename path="<元>" name="<新しい名前>"`。開始前に `obsidian vault=<対象Vault名> vault info=path` が作業対象のルートを返すことを確かめ、違えば止める。試験Vaultでは `vault=vault-test` を指定する。対象の取り違えを防ぐため。Obsidian が起動している必要がある。
- 実行のあとで `obsidian vault=<対象Vault名> unresolved total` を前と比べ、増えていないことを確かめる。
- Git の管理外のもの（原本を除く添付・文献など）を動かす前は、`_scratch/backup/` にバックアップを取り、戻せることを確かめる。

## 資料の保存

ノートの置き場所、資料の実体の Git での管理、本文での表示は、別々に判断する。

- 置き場所は、知識、読書の作業、実務資料などの用途で決める。
- 実体を Git で管理するかは、大きさ、更新の頻度、同期の方法から資料ごとに判断する。判断がつかなければ利用者に確かめる。Git 管理外の場所のファイルを Git に足すときも確かめる。
- 原本は `Originals/`、再生成できる中間物は `_scratch/`、採用した生成物は `attachments/`。原本の読み取り境界と採用の確認は `AGENTS.md` に従う。
- 文献の出典は `[@citekey]` で示す。原本はリンクで開くか、本文で表示したいときは `![[...]]` で埋め込む。表示の方法と Git での管理は別に判断する。
- Git管理と同期の実際の設定は対象Vaultで確かめる。一つのディレクトリの設定をVault全体の規則に一般化しない。

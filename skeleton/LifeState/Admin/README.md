# Admin — 実務リファレンス

契約、履修、家電などの実務の事実を、一つの対象につき1ノートで記録する。

## frontmatter の目安

```yaml
---
confirmed:
evidence: []
renew:
due:
---
```

未確認の `confirmed` は空欄にする。確認日と根拠は `confirmed` と `evidence`、更新期限は
`renew` と `due` に記録する。変更日、旧値から新値、根拠は本文の「履歴」に残す。

資料の配置、Git管理、本文での表示は別々に判断する。
詳しい手順は `.agents/skills/updating-records/SKILL.md`、構造は
`.agents/skills/updating-records/references/構造.md` を参照する。

# Home

タスク一覧には、`LifeState/Action/`、`LifeState/Admin/`、`LifeLogs/Dailies/`、`LifeLogs/Reviews/` 内のチェックボックスのみを抽出して表示する。

## 本日の対応・直近の期限

```tasks
(status.type is not DONE) AND (status.type is not CANCELLED)
(((status.type is TODO) OR (status.type is IN_PROGRESS)) AND (starts before tomorrow) AND ((status.type is IN_PROGRESS) OR (scheduled on or before today) OR (due on or before today))) OR (due before in 15 days)
sort by due
sort by scheduled
```

## 生活の用事

### 要対応・日程確認

```tasks
(status.type is TODO) OR (status.type is IN_PROGRESS)
filter by function task.tags.includes('#生活')
starts before tomorrow
(no scheduled date) OR (scheduled on or before today)
sort by due
sort by scheduled
```

### 今後の予定

```tasks
(status.type is TODO) OR (status.type is IN_PROGRESS)
filter by function task.tags.includes('#生活')
((has start date) AND (starts after today)) OR (scheduled after today)
sort by happens
```

> [!todo]- 対応待ち
>
> ```tasks
> filter by function task.tags.includes('#生活')
> filter by function task.status.symbol === 'w'
> sort by due
> sort by scheduled
> ```

> [!todo]- いつかやる
>
> ```tasks
> filter by function task.tags.includes('#生活')
> filter by function task.status.symbol === 's'
> sort by due
> sort by scheduled
> ```

> [!todo]- 全体の見直し
>
> ### 未完了タスク
>
> ```tasks
> (status.type is TODO) OR (status.type is IN_PROGRESS)
> group by filename
> ```
>
> ### 対応待ち
>
> ```tasks
> filter by function task.status.symbol === 'w'
> group by filename
> ```
>
> ### いつかやる
>
> ```tasks
> filter by function task.status.symbol === 's'
> group by filename
> ```

## 振り返りの未実施

```dataviewjs
const week = moment().format("GGGG-[W]WW");
const month = moment().format("YYYY-MM");
for (const [label, name] of [["今週", week], ["今月", month]]) {
  const p = dv.page(`LifeLogs/Reviews/${name}`);
  if (!p) dv.paragraph(`${label}の振り返りノートがまだ作成されていません: [[LifeLogs/Reviews/${name}]]`);
  else if (p.completed !== true) dv.paragraph(`${label}の振り返りが完了していません: [[LifeLogs/Reviews/${name}]]`);
}
```

## 現在の取り組み

![[System/Bases/行動.base#取り組み]]

## あとで見返すノート

> [!todo]- 一覧を表示
>
> ![[System/Bases/再調査.base#あとで見返す]]

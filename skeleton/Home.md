# Home

今日の行動、期限、未完了タスク、待ち状態のタスク、ならびに振り返りや再調査の状況をまとめて確認するための入口です。タスク一覧には、`LifeState/Action/`、`LifeLogs/Dailies/`、`LifeLogs/Reviews/` 内のチェックボックスのみを抽出して表示します。

## 今日

```tasks
(status.type is TODO) OR (status.type is IN_PROGRESS)
(status.type is IN_PROGRESS) OR (scheduled on or before today) OR (due on or before today)
sort by due
```

## 期限

```tasks
(status.type is not DONE) AND (status.type is not CANCELLED)
due before in 15 days
sort by due
```

## 未完了

```tasks
(status.type is TODO) OR (status.type is IN_PROGRESS)
group by filename
```

## 待ち

```tasks
filter by function task.status.symbol === 'w'
group by filename
```

## 振り返り漏れ

```dataviewjs
const week = moment().format("gggg-[W]ww");
const month = moment().format("YYYY-MM");
for (const [label, name] of [["今週", week], ["今月", month]]) {
  const p = dv.page(`LifeLogs/Reviews/${name}`);
  if (!p) dv.paragraph(`${label}の振り返りがまだない: [[LifeLogs/Reviews/${name}]]`);
  else if (p.reviewed !== true) dv.paragraph(`${label}の振り返りが終わっていない: [[LifeLogs/Reviews/${name}]]`);
}
```

## ゴール

![[System/Bases/行動.base#ゴール]]

## 進行中の活動

![[System/Bases/行動.base#進行中の活動]]

## 再調査

![[System/Bases/再調査.base#再調査]]

## 未処理

![[System/Bases/未処理.base#未処理]]

## 実務の更新期限

![[System/Bases/実務.base#更新期限]]

## 状態未設定

![[System/Bases/行動.base#状態未設定]]

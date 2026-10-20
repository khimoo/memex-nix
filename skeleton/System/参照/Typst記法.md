# Typst記法

このVaultの数式レンダラはTypst Mate。数式はインライン `$...$` の中にTypst 記法で書く。
LaTeXのバックスラッシュコマンドを使わない。以下はこのVaultで使う対応表であり、Typst全体の仕様一覧ではない。

| LaTeX | このVaultでのTypst表記 |
| --- | --- |
| `\forall` / `\exists` | `forall` / `exists` |
| `\in` / `\subset` | `in` / `subset` |
| `\cap` / `\cup` | `sect` / `union` |
| `\bigcap` / `\bigcup` | `sect.big` / `union.big` |
| `\overline{A}` | `overline(A)` |
| `\emptyset` / `\neq` / `\infty` | `emptyset` / `!=` / `oo` |
| `\lambda` / `\Lambda` | `lambda` / `Lambda` |
| カリグラフィ | `cal(A)` |
| QED記号 | リテラル `∎` |

複数文字の添字は `_(...)` で囲む。例: `union.big_(lambda in Lambda)`。

---
name: score-image-to-musicxml
description: 紙の譜面の画像や PDF を homr で MusicXML に変換し、元の画像から読んだコード記号を補って検証する。「譜面を MusicXML にして」のときに使う。
---

# score-image-to-musicxml — 譜面画像のMusicXML化

紙やPDFで持っている譜面を、移調に使えるMusicXMLにする。
開始時に利用者のピアノ・ジャズのゴールノート（例: `Action/ピアノ・ジャズ.md`）を確認し、現在の練習方針を確認する。
練習メニューやどの曲を扱うかの相談は `.agents/skills/jazz-mentor/SKILL.md` を使う。

## 音符とコード記号の分担

AIは五線上の相対位置を数えるときに誤るため、画像から音符を手で書き起こさない。
音符・調号・拍子・小節構造はOMRツールのhomrに任せ、その出力をそのまま使う。
コードネームは文字として元画像から読み取り、MusicXMLの `harmony` 要素として補う。

homrは設計上、コード記号を扱わない。設定を探しても解決しない。
ソースを確認したところ、`transformer/vocabulary.py` の `chord` トークンは同時発音の和音を指し、コードネームではなかった。
同梱のRapidOCRも `title_detection.py` でタイトル検出にだけ使われている。
公開情報でも音高とリズムに対象を絞っており、強弱記号やアーティキュレーションなどは対象外とされている。譜面の全要素が復元されるとは扱わない。

## 原本と生成物の置き場

元の画像・PDFは再取得できない原本として `Originals/` に保管する。AIは読むだけとし、既存原本の移動や採用は `AGENTS.md#確認の境界` に従う。
変換には作業用のコピーを使い、原本を移動・上書きしない。

生成する MusicXML、PDF、中間画像は、Vault の `_scratch/` の作業ディレクトリに出す（Git 管理外で、再生成できる中間物の置き場。設計書第7節）。Vault の正式な置き場へは自動で入れない。

人間がレビューして価値があると判断したものだけを、その都度 `attachments/` へ移す（生成物の採用は事前承認）。移す先と Git 管理の要否も人間が指定する。判断の基準は `restructuring-vault` の「資料の保存」にある。移調は `transpose-12keys`、練習内容の相談は `jazz-mentor` が担当する。

## 入力の準備

対象の画像・PDFと、変換するページや小節の範囲を確認する。指定済みの内容は聞き直さない。
今回専用の作業ディレクトリを用意し、homrに渡す画像をそこに置く。
homrは入力画像と同じディレクトリに `画像名.musicxml` を書くため、原本の場所で直接実行しない。

homrが受け付けるのは png / jpg / jpegだけ。PDFは直接渡せない。
これは `main.py` の拡張子リストで確認済み。
PDFはこの環境で利用可能な `pdfinfo` でページ数を確認し、`pdftoppm` で対象ページをPNGにしてから渡す。
次の例では `SOURCE.pdf` を原本のパス、`WORKDIR` を作業ディレクトリに置き換える。複数ページはページ順を保って扱う。

```sh
pdfinfo SOURCE.pdf
pdftoppm -png SOURCE.pdf WORKDIR/page
```

## homrの実行環境

homrはCPUで10分以上かかる重い処理なので、実行するマシンは、そのマシンで定められた重い処理の方針に従って選ぶ。

事前インストールは不要。`uvx --python 3.13 homr 画像ファイル` で実行する。
NixOSでnix-ldが無効なマシンでは、共有ライブラリを先に用意する。

素の実行ではcv2のimport時に `libstdc++.so.6`、`libz.so.1`、`libxcb.so.1`、`libgthread-2.0.so.0` が順に見つからず失敗した。
`nix shell nixpkgs#glib` などでPATHからlibディレクトリを導く方法も試したが、glibは複数の出力を持ち、PATHに入る出力にはlibがないため `libgthread-2.0.so.0` を拾えなかった。
そこで、`glib.out` を含む次のbuildEnvで必要なライブラリをまとめる方法に切り替え、動作を確認した。

```sh
nix build --no-link --print-out-paths --impure --expr 'with import <nixpkgs> {}; buildEnv { name = "omr-libs"; paths = [ zlib glib.out libGL libglvnd xorg.libX11 xorg.libXext xorg.libXrender xorg.libxcb xorg.libSM xorg.libICE xorg.libXi xorg.libXrandr xorg.libXfixes libxkbcommon fontconfig.lib freetype stdenv.cc.cc.lib openssl expat ]; }'
```

出力されたパスに `/lib` を付けて `LD_LIBRARY_PATH` に入れる。
次の `OMR_LIBS` には上のコマンドが出力したパス、`IMAGE` には作業ディレクトリ内の画像のパスを指定する。
buildEnvの再実行は初回以降1.8秒だった。

```sh
LD_LIBRARY_PATH="${OMR_LIBS}/lib" uvx --python 3.13 homr "$IMAGE"
```

homrはバックグラウンドで走らせ、完了通知を待つ。 実行ツールのバックグラウンド機能を使い、ログと出力先を作業ディレクトリに残す。前景で終了まで待つと他の作業が止まる。
実行中は元画像のコード記号を小節ごとに整理するなど、出力に依存しない作業を進める。
完了通知を受けたら終了状態とログを確認し、MusicXMLが存在して空でないことを確かめる。

homrのGPU対応はCUDAとApple CoreMLだけなので、どちらもないマシンではCPUで実行する。
測定したマシンにはCUDA GPUがなく、`onnxruntime.get_available_providers()` の実測結果は `['AzureExecutionProvider', 'CPUExecutionProvider']` だった。
3段12小節の画像1枚で12分28秒かかった。初回はモデルのダウンロードも入るため、さらに時間がかかる。
この時間は実測例であり、毎回同じとは限らない。

## コード記号を補う

元画像を開き、小節ごとにコード記号を読み取る。調やよくある進行から欠けた文字を推測で埋めない。
読めない箇所はページ・段・小節を示して人間に確認する。
タイトルも元画像で読み、homrが出力した `work-title` を正しい表記に直す。

小節頭のコード記号は、その小節の最初の `<note>` の前に `harmony` 要素を置く。次はBb7の形。

```xml
<harmony>
  <root>
    <root-step>B</root-step>
    <root-alter>-1</root-alter>
  </root>
  <kind>dominant</kind>
</harmony>
```

`root-alter` はフラットが `-1`、シャープが `1`。変化なしなら要素ごと省略する。
`kind` は次の対応で入れる。「なし」はルート名だけのコード記号を指す。

| コード記号の接尾辞 | kind |
| --- | --- |
| なし | `major` |
| m | `minor` |
| 7 | `dominant` |
| m7 | `minor-seventh` |
| maj7 | `major-seventh` |
| m7b5 | `half-diminished` |
| dim7 | `diminished-seventh` |
| 6 | `major-sixth` |
| m6 | `minor-sixth` |
| aug | `augmented` |

この挿入例は小節頭のコードを扱う。小節途中のコードを一律に小節頭へ寄せたり、表にないコードを近い種類へ置き換えたりしない。該当する譜面では位置と表現方法を別途確認する。

注入には、作業ディレクトリに使い捨てのスクリプトを書いて実行してよい。このスキル自体にはスクリプトファイルを持たせない。
homrの出力を残し、コード記号とタイトルを補ったMusicXMLは別名で保存する。
普通のテキストではなく `harmony` として入れる。後の移調でコード記号も変換するために、この区別が要る。

## 生成後の検証

1. homrの出力に `harmony` が入っていないことを前提に、MusicXMLの `key/fifths`、拍子（`time/beats`・`time/beat-type`）、小節数、音符数を確認する。ページや段の抜けも確認する。
2. コード記号の注入後、各小節の `harmony` の個数・ルート・種類・位置が、元画像から読んだ内容と合うか確認する。注入前後で音符・調号・拍子・小節構造が変わっていないことも確かめる。
3. `work-title` が元画像の表記に直っていることを確認する。homrのタイトル認識をそのまま採用しない。
4. 補完後のMusicXMLをMuseScoreでPNGかPDFへ戻し、元画像と並べて目視で照合する。 音符・調号・拍子・小節構造・コード記号・タイトルを見比べる。XMLの確認だけで完了にしない。
5. 音符はhomrの出力を信頼して使うが、AIが読んだコード記号には人間の確認が要る。 補ったコードの小節ごとの一覧と比較用の譜面を提示する。AIの目視照合が済んでも、人間がコード記号を確認したことにはしない。

この環境では `mscore` を使う。たとえば `CORRECTED.musicxml` を補完後のファイル、`REVIEW.pdf` を作業ディレクトリ内の出力先に置き換える。

```sh
mscore CORRECTED.musicxml -o REVIEW.pdf
```

不一致があれば場所と内容を報告する。音符の見た目に疑問があっても、AIの五線の読みだけでhomrの音高や音価を書き換えず、人間に確認する。

## この環境で確認した精度と限界

以下はこの環境で実際に実行して確認した結果。今回の変換でも同じ結果になる保証ではない。
測定にはMuseScoreでレンダリングしたFメジャー・4/4・3段12小節のブルースのPNGを使った。手書き譜やスキャン画像での精度は測っていない。

- 音符48個は、音高・オクターブ・音価がすべて正解と一致した。調号（`fifths` は `-1`）、拍子（4/4）、小節数（12）も一致した。
- コード記号12個は全部落ちた。`harmony` はゼロで、`words` や `direction` としても残っていなかった。
- タイトルは `Blues Head` が `peaii sanic` に誤読された。
- コード記号の注入後にMuseScoreで画像へ戻して元画像と見比べると、コード記号12個・音符・調号はすべて一致し、違いはタイトルの誤読だけだった。
- 注入した `harmony` を `transpose-12keys` でFメジャーからBbメジャー（`targetKey: -2`）へ移調すると、F7はBb7、Bb7はEb7となり、`fifths` も `-2` になった。MuseScoreがコードとして認識していることを確認した。

## 移調への引き渡しと報告

このスキルの出力MusicXMLが `.agents/skills/transpose-12keys/SKILL.md` の入力になる。
同スキルは手打ちの `.mscx` を前提に書かれているが、OMR由来のMusicXMLでも移調後の検証は省略しない。
移調を依頼されたら同スキルを読み、指定された各キーの調号と和音ルートを同じ手順で検証する。
このスキルで変換しただけで、全キー展開まで自動で進めない。

報告では、MusicXMLと比較用PNG・PDFの場所、調号・拍子・小節数・音符数の確認結果、補ったコード記号とタイトル、目視照合の結果を簡潔に示す。
未検証の項目と、人間によるコード記号の確認が済んでいるかを明記する。
保存は人間のレビューと行き先の指定に従う。

採用した譜面を使うノートには、元画像・原本、変換した道具と版、人間の照合日、採用日を記録する。変換完了・人間の照合・採用を区別するため。

"""Remove instance-specific references from the explicitly selected shared files."""
from pathlib import Path
import re
import sys


def sanitize(root: Path) -> None:
    (root / '.drive-sync-filter').write_text('- **\n')

    def edit(name, transform):
        path = root / name
        path.write_text(transform(path.read_text()))

    # A fresh vault has no legacy records or personal reading/knowledge entry points.
    edit('Home.md', lambda s: s.split('## 旧記録/移行確認')[0].rstrip() + '\n')
    edit('AGENTS.md', lambda s: re.sub(
        r'^## 移行中[ \t]*\n.*?(?=^#{1,2}[ \t]|\Z)', '', s, flags=re.M | re.S
    ).replace('- `Knowledge/Writing/hello worldが実行されるまで/` の記事を gemini-proofread で校正し終えた → `proofreading-drafts`\n', ''))

    def readme(s):
        storage = (
            '資料の配置、Git管理、同期、本文での表示は別々に判断する。'
            'クリップボードから貼った画像とドラッグ＆ドロップの添付は、'
            'Obsidian標準の保存先 `Assets/attachments/` を使う。'
            'その他の資料は使う文脈に合わせて置き場所を決める。'
            '原本の保護と出典の示し方は [AGENTS.md](AGENTS.md#常に守ること)、'
            '保存の判断は `.agents/skills/restructuring-vault/SKILL.md#資料の保存` に従う。\n\n'
            'ノート本文はGitで同期する。資料のGit管理対象は `.gitignore` で指定する。'
            'Drive同期の対象は `.drive-sync-filter` で明示する。'
            '新規Vaultでは対象を指定するまで同期しない。設定と手動初期化の手順は '
            '[memex-nix README](https://github.com/khimoo/memex-nix#readme) を参照する。'
            '退避データは、利用者が保持期限を決めるまで削除しない。\n\n'
            '全環境共通のAI向け指示は [AGENTS.md](AGENTS.md) に記載する。'
            'Claude Codeは [CLAUDE.md](CLAUDE.md) 経由で `@AGENTS.md` を読み込み、'
            'Codexは直接参照する。各スキルは `.agents/skills/` に配置し、'
            '`.claude/skills` から同じ実体を参照する。'
            '実行環境ごとの制約は `.claude/` や `.codex/` で管理する。'
            'Gitのコミットおよびリモートへのpushはユーザー自身が行う。\n\n'
        )
        s = re.sub(
            r'(^## 保存とAI指示[ \t]*\n).*?(?=^## |\Z)',
            lambda match: match[1] + '\n' + storage,
            s, flags=re.M | re.S,
        )
        # The shared guide describes a fresh Vault, not the owner's migration state.
        s = s.replace('既存の素材は従来の階層構造を維持して収容する。', '').replace('既存の素材は従来の階層構造を維持して収容する', '')
        s = s.replace('元の同期コピーは当面の間保持する', '')
        s = s.replace('また、旧環境から移行した既存タスクの作成日や開始日などのメタデータはそのまま維持する。', '既存タスクの作成日や開始日などのメタデータはそのまま維持する。')
        s = s.replace('移行前のチェック記号・本文・日付は履歴行として残してあり、未実施の項目を通常のタスクの未完了として扱わないようにする。', '')
        s = s.replace('退避データの保持期限は未定であるため、既存の `attachments/` 側にあるコピーや今回退避されたデータは削除しないこと。', '退避データは、利用者が保持期限を決めるまで削除しない。')
        s = s.replace('設計の正本は [[System/設計/2026-10-16-vault再設計]]、各ルールの目的と正本は [[System/規則台帳]] を参照すること。',
                      '各ルールの目的と正本は [[System/規則台帳]] を参照すること。')
        s = '\n'.join(line for line in s.split('\n')
                      if not line.startswith('分類が確定していないZettelやBufferNotes、')
                      and not line.startswith('過去の日次ノート内に埋め込まれたクエリや、'))
        s = s.replace('なお、[[Zettelkasten入門]] はユーザー独自の方法論に関する考察であり、運用規約の正本ではない点に留意する。', '')
        s = s.replace('、独自の記号や用語の定義は [[数学記法一覧]] を参照すること。', 'を参照すること。')
        s = s.replace('両方のPC上に保持したうえで、rclone bisyncを用いてGoogle Driveと自動同期する。',
                      '各PC上に保持し、必要に応じてワークフローの原本同期を有効にする。')
        s = s.replace('今回の移行作業については対話上で事前の許可を得ているが、Gitのコミットおよびリモートへのpushはユーザー自身が行う。',
                      'Gitのコミットおよびリモートへのpushはユーザー自身が行う。')
        return s

    edit('README.md', readme)
    # The vault no longer keeps this README, so the skeleton always gets the fixed text.
    (root / 'LifeState/Admin').mkdir(parents=True, exist_ok=True)
    (root / 'LifeState/Admin/README.md').write_text('# Admin — 実務リファレンス\n\n契約、履修、家電などの事実を、一つの対象につき1ノートで記録する。\n\n値、確認した日、根拠と原本へのリンクを本文に結び付ける。必要になったときに原本や現物を確かめ、変更は本文の「履歴」に残す。\n\n対象に関する用事は、この資料にタスクとして記載する。生活の用事にはタスク行に `#生活` を付ける。\n\n詳しい手順は `.agents/skills/updating-records/SKILL.md`、項目の型と所有者は [[System/参照/プロパティ#人が扱う項目]] を参照する。\n')

    edit('System/参照/Typst記法.md', lambda s: '\n'.join(
        line for line in s.split('\n')
        if not line.startswith('実例は [[') and not line.startswith('数学上の記号・略語の意味')))
    edit('.agents/skills/revising-instructions/SKILL.md', lambda s: s.replace(
        '用語は設計書（`System/設計/2026-10-16-vault再設計.md`）に揃える。',
        '用語は `AGENTS.md` の置き場と各スキルの正本に揃える。'))

    # Keep the rule IDs and canonical locations, without the owner's failure history.
    def ledger(s):
        rows = []
        for line in s.splitlines():
            if not line.startswith('|'):
                continue
            cols = line.split('|')
            if len(cols) != 10:
                raise ValueError('Unexpected rule ledger columns')
            if cols[1].strip() in {'R164', 'R165'}:
                continue
            if cols[1].strip().startswith('R'):
                cols[7] = ' ― '
                cols[8] = ' ― '
            rows.append('|'.join(cols))
        return ('# 規則台帳\n\n規則の要旨と正本の場所の索引。規則本文は正本に置く。\n'
                '第7列（区切りを含むawkの列番号）は正本の場所として保つ。\n\n' + '\n'.join(rows) + '\n')

    edit('System/規則台帳.md', ledger)
    (root / 'System/失敗記録.md').write_text('''# 失敗記録

AI が実際に起こした失敗を、利用者のVaultで記録する。配布元の個人の履歴は含めない。

事象、原因、守る目的、対応する規則のID、状態を記す。
改訂手順は `.agents/skills/revising-instructions/SKILL.md` を参照する。
''')
    edit('.agents/skills/reading-math-closely/SKILL.md',
         lambda s: s.split('## 節ごとの取り決め')[0].rstrip() + '\n')
    edit('.agents/skills/transpose-12keys/SKILL.md', lambda s: s.replace(
        '`Knowledge/Zettel/Zettelkasten入門.md#Zettelkastenの実際。[^2]` の収集についての考察 と、`LifeState/Action/ピアノ・ジャズ.md` の「集めること≠理解」を踏まえ、作れるものを全部残さない。',
        '採用する生成物は利用者が決め、作れるものを全部残さない。'))
    for skill in ['jazz-mentor', 'score-image-to-musicxml', 'transpose-12keys']:
        path = root / f'.agents/skills/{skill}/SKILL.md'
        text = path.read_text()
        # These goal notes belong to the recipient; the exporter does not copy them.
        text = text.replace('開始時にVaultルートの `LifeState/Action/ピアノ・ジャズ.md` を読み、',
                            '開始時に利用者のピアノ・ジャズのゴールノート（例: `LifeState/Action/ピアノ・ジャズ.md`）を確認し、')
        path.write_text(text)

    forbidden = {
        'README.md': ['[[Zettelkasten入門]]', '[[数学記法一覧]]'],
        'AGENTS.md': ['hello worldが実行されるまで'],
        '.agents/skills/transpose-12keys/SKILL.md': ['Zettelkasten入門'],
    }
    for skill in ['jazz-mentor', 'score-image-to-musicxml', 'transpose-12keys']:
        forbidden.setdefault(f'.agents/skills/{skill}/SKILL.md', []).append('開始時にVaultルートの')
    remaining = [f'{name}: {phrase}'
                 for name, phrases in forbidden.items()
                 for phrase in phrases if phrase in (root / name).read_text()]
    if remaining:
        raise ValueError('Personal note references remain:\n' + '\n'.join(remaining))

    for path in root.rglob('*.md'):
        if '.obsidian' not in path.parts and not path.is_symlink():
            path.write_text(path.read_text().rstrip() + '\n')


if __name__ == '__main__':
    sanitize(Path(sys.argv[1]))

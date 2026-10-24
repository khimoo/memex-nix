"""Run with python3 tests/test_layout.py; set VAULT_TOOLS for integration tests."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(os.environ.get('LAYOUT_ROOT', Path(__file__).resolve().parents[1]))
SK = ROOT / 'skeleton'
TOOLS = os.environ.get('VAULT_TOOLS')
SOURCE = os.environ.get('SOURCE_VAULT')
OLD = ['Registry', 'Goals', 'Tasks', 'FleetingNote', 'Clippings', 'Drafts', 'BufferNotes', 'Reading/math', 'Reading/DB', 'Reading/art', 'Inbox/FleetingNote', 'Inbox/Clippings',
       'Resources/AI', 'Resources/サブスク', 'Resources/メール', 'Resources/住居', 'Resources/学校', 'Resources/絵',
       'Wiki', 'Zettel', 'Reading', 'Writing', 'Action', 'Dailies', 'Reviews', 'Resources', 'Templates', 'Originals', 'attachments', 'references']
NEW = ['Knowledge', 'Knowledge/Wiki', 'Knowledge/Zettel', 'Knowledge/Reading', 'Knowledge/Writing', 'Inbox', 'LifeLogs', 'LifeLogs/Dailies', 'LifeLogs/Reviews', 'LifeLogs/Sessions', 'LifeState', 'LifeState/Action', 'LifeState/Admin', 'Assets', 'Assets/attachments', 'Assets/references', 'Assets/Originals', 'System', 'System/Templates', 'System/設計', 'System/計画', 'System/Bases', 'System/参照', '_scratch']


def run(*args, check=True):
    return subprocess.run(args, text=True, capture_output=True, check=check)


def snapshot(root):
    return {p.relative_to(root).as_posix(): ('link', os.readlink(p)) if p.is_symlink()
            else ('file', hashlib.sha256(p.read_bytes()).hexdigest())
            for p in root.rglob('*') if p.is_file() or p.is_symlink()}


def copy_skeleton(target):
    shutil.copytree(SK, target, symlinks=True)
    # Nix store sources are read-only; fixtures must allow simulated user changes.
    for path in [target, *target.rglob('*')]:
        if not path.is_symlink():
            path.chmod(path.stat().st_mode | 0o200)


class Layout(unittest.TestCase):
    def test_new_layout_replaces_old(self):
        for name in NEW:
            self.assertTrue((SK/name).is_dir(), name)
        for name in OLD:
            self.assertFalse((SK/name).exists(), name)
        for name in ['行動', '未処理', '再調査', '実務']:
            self.assertTrue((SK/f'System/Bases/{name}.base').is_file())

    def test_shared_instructions_and_private_exclusions(self):
        self.assertEqual((SK/'CLAUDE.md').read_text().strip(), '@AGENTS.md')
        self.assertTrue((SK/'.claude/skills').is_symlink())
        self.assertEqual((SK/'.claude/skills').resolve(), (SK/'.agents/skills').resolve())
        for name in ['IndexNote.md', '.claude/settings.json', '.codex/config.toml', '.agents/skills/proofreading-drafts', '.agents/skills/reading-math-closely/references/引用基準-InverseLimits-1.9.md']:
            self.assertFalse((SK/name).exists(), name)
        self.assertNotIn('移行中', (SK/'AGENTS.md').read_text())
        self.assertNotIn('## F01', (SK/'System/失敗記録.md').read_text())
        home = (SK/'Home.md').read_text()
        for text in ['旧記録', 'ingram-inverse-limits', '人体デッサン', '移行の確認待ち']:
            self.assertNotIn(text, home)

    def assert_current_guide(self, text):
        for phrase in ['従来の階層構造を維持', '元の同期コピーは当面',
                       '旧環境から移行した', '移行前のチェック記号', '今回退避された']:
            self.assertNotIn(phrase, text)
        self.assertIn('未整理のアイデアやWebクリップを一時保管する。', text)
        self.assertIn('既存タスクの作成日や開始日などのメタデータはそのまま維持する。', text)
        self.assertIn('退避データは、利用者が保持期限を決めるまで削除しない。', text)

    def test_shared_guide_starts_from_current_layout(self):
        self.assert_current_guide((SK/'README.md').read_text())

    def test_export_drops_legacy_layout_assumptions(self):
        with tempfile.TemporaryDirectory(prefix='vault-sanitize-') as temp:
            source = Path(temp)/'source'; copy_skeleton(source)
            # An older source Vault can still contain migration-specific explanations.
            guide = (source/'README.md').read_text()
            guide += ('\n既存の素材は従来の階層構造を維持して収容する。\n'
                      '元の同期コピーは当面の間保持する\n'
                      'また、旧環境から移行した既存タスクの作成日や開始日などのメタデータはそのまま維持する。\n'
                      '移行前のチェック記号・本文・日付は履歴行として残してあり、未実施の項目を通常のタスクの未完了として扱わないようにする。\n'
                      '退避データの保持期限は未定であるため、既存の `attachments/` 側にあるコピーや今回退避されたデータは削除しないこと。\n')
            (source/'README.md').write_text(guide)
            run(sys.executable, str(ROOT/'nix/sanitize-skeleton.py'), str(source))
            self.assert_current_guide((source/'README.md').read_text())

    def test_settings_match_dashboard_and_templates(self):
        tasks = json.loads((SK/'.obsidian/plugins/obsidian-tasks-plugin/data.json').read_text())
        self.assertEqual(tasks['globalQuery'], r'path regex matches /^(LifeState\/Action|LifeLogs\/(Dailies|Reviews))\//')
        self.assertFalse(tasks['useFilenameAsScheduledDate'])
        self.assertEqual(tasks['filenameAsDateFolders'], [])
        statuses = tasks['statusSettings']['coreStatuses'] + tasks['statusSettings']['customStatuses']
        self.assertEqual({s['symbol'] for s in statuses}, {' ', '/', 'w', 's', 'x', '-'})
        journals = json.loads((SK/'.obsidian/plugins/journals/data.json').read_text())['journals']
        for name in ['daily', 'weekly', 'monthly']:
            self.assertFalse(journals[name]['autoCreate'])
            for template in journals[name]['templates']:
                self.assertTrue((SK/template).is_file(), template)
        git = json.loads((SK/'.obsidian/plugins/obsidian-git/data.json').read_text())
        self.assertFalse(git['autoPullOnBoot'])

    def test_migration_section_with_subheadings_or_at_end_is_removed(self):
        original = (SK/'AGENTS.md').read_text()
        cases = {
            'subheading': original.replace('## 常に守ること',
                '## 移行中\n### 個人の移行記録\nPRIVATE_MIGRATION_HISTORY\n\n## 常に守ること'),
            'end_of_file': original + '\n## 移行中\nPRIVATE_MIGRATION_HISTORY\n',
        }
        for name, content in cases.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory(prefix='vault-sanitize-') as temp:
                source = Path(temp)/'source'; copy_skeleton(source)
                (source/'AGENTS.md').write_text(content)
                run(sys.executable, str(ROOT/'nix/sanitize-skeleton.py'), str(source))
                self.assertEqual((source/'AGENTS.md').read_text(), original)

    @unittest.skipUnless(TOOLS, 'set VAULT_TOOLS to run built tools')
    def test_fresh_seed_preserves_links_and_existing_files(self):
        with tempfile.TemporaryDirectory(prefix='vault-layout-') as temp:
            vault = Path(temp)/'vault'
            run(f'{TOOLS}/init-vault', str(vault))
            run(f'{TOOLS}/seed-vault', '--obsidian', str(vault))
            self.assertTrue((vault/'.claude/skills').is_symlink())
            self.assertTrue((vault/'.claude/skills/lint-zettel/SKILL.md').is_file())
            for name in NEW:
                self.assertTrue((vault/name).is_dir(), name)
            for name in OLD:
                self.assertFalse((vault/name).exists(), name)
            for name in ['Assets/Originals/source.pdf', '_scratch/output.txt']:
                self.assertEqual(run('git', '-C', str(vault), 'check-ignore', name).returncode, 0)
            (vault/'Home.md').write_text('user content\n')
            (vault/'.obsidian/app.json').write_text('{"user": true}\n')
            run(f'{TOOLS}/seed-vault', '--obsidian', str(vault))
            self.assertEqual((vault/'Home.md').read_text(), 'user content\n')
            self.assertEqual((vault/'.obsidian/app.json').read_text(), '{"user": true}\n')

    @unittest.skipUnless(TOOLS, 'set VAULT_TOOLS to run built tools')
    def test_missing_required_source_does_not_change_destination(self):
        with tempfile.TemporaryDirectory(prefix='vault-mirror-') as temp:
            source, dest = Path(temp)/'source', Path(temp)/'dest'
            copy_skeleton(source)
            dest.mkdir(); shutil.copytree(SK, dest/'skeleton', symlinks=True)
            for path in [source, dest]:
                run('git', 'init', '-q', str(path))
            run('git', '-C', str(source), 'add', '.')
            (source/'Home.md').unlink()
            before = snapshot(dest/'skeleton')
            result = run(f'{TOOLS}/mirror-vault', '--dry-run', str(source), str(dest), check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Home.md', result.stderr)
            self.assertEqual(snapshot(dest/'skeleton'), before)

    @unittest.skipUnless(TOOLS, 'set VAULT_TOOLS to run built tools')
    def test_private_notes_and_history_are_not_mirrored(self):
        with tempfile.TemporaryDirectory(prefix='vault-mirror-') as temp:
            source, dest = Path(temp)/'source', Path(temp)/'dest'
            copy_skeleton(source)
            dest.mkdir(); shutil.copytree(SK, dest/'skeleton', symlinks=True)
            for name in ['Knowledge/Wiki/PRIVATE.md', 'LifeState/Action/PRIVATE.md', 'Assets/Originals/PRIVATE.pdf',
                         '.claude/settings.json', '.codex/config.toml']:
                path = source/name; path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('PRIVATE_CONTENT_DO_NOT_DISTRIBUTE')
            with (source/'Home.md').open('a') as handle:
                handle.write('\n## 旧記録/移行確認\n[[Knowledge/Wiki/PRIVATE]]\n')
            (source/'System/失敗記録.md').write_text('PRIVATE_FAILURE_HISTORY')
            path = source/'AGENTS.md'
            path.write_text(path.read_text().replace('## 常に守ること',
                '## 移行中\nPRIVATE_MIGRATION_HISTORY\n\n## 常に守ること'))
            path = source/'.obsidian/plugins/obsidian-git/data.json'
            data = json.loads(path.read_text()); data['autoPullOnBoot'] = True
            path.write_text(json.dumps(data))
            for name in ['bookmarks.json', 'workspaces.json']:
                (source/'.obsidian'/name).write_text('PRIVATE_WORKSPACE_STATE')
            for path in [source, dest]:
                run('git', 'init', '-q', str(path))
            run('git', '-C', str(source), 'add', '.')
            before = snapshot(dest/'skeleton')
            result = run(f'{TOOLS}/mirror-vault', '--dry-run', str(source), str(dest))
            self.assertIn('(差分なし)', result.stderr, result.stdout + result.stderr)
            self.assertEqual(snapshot(dest/'skeleton'), before)

    @unittest.skipUnless(TOOLS and SOURCE, 'set VAULT_TOOLS and SOURCE_VAULT')
    def test_mirror_matches_snapshot_without_private_content(self):
        with tempfile.TemporaryDirectory(prefix='vault-mirror-') as temp:
            dest = Path(temp)/'dest'; dest.mkdir()
            shutil.copytree(SK, dest/'skeleton', symlinks=True)
            run('git', 'init', '-q', str(dest))
            before = snapshot(dest/'skeleton')
            result = run(f'{TOOLS}/mirror-vault', '--dry-run', SOURCE, str(dest))
            self.assertIn('(差分なし)', result.stderr, result.stdout + result.stderr)
            self.assertEqual(snapshot(dest/'skeleton'), before)


if __name__ == '__main__':
    unittest.main()

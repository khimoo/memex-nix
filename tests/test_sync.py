import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class SyncTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.template = Path(os.environ["MEMEX_SYNC_TEMPLATE"]).read_text()

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="memex-sync-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.vault = self.root / "vault"
        self.remote = self.root / "remote"
        self.vault.mkdir()
        self.remote.mkdir()
        self.filters = self.vault / ".drive-sync-filter"
        self.filters.write_text("+ /資料 nested/章 1/**\n- **\n")
        self.config = self.root / "rclone.conf"
        self.config.write_text(f"[test]\ntype = alias\nremote = {self.remote}\n")
        self.env = dict(os.environ, RCLONE_CONFIG=str(self.config),
                        XDG_CACHE_HOME=str(self.root / "cache"))
        self.env.pop("MEMEX_FORCE_RESYNC", None)
        self.script = self.template.replace("@VAULT@", str(self.vault)).replace(
            "@BACKUPS@", str(self.root / "backups"))
        self.put(self.vault, "資料 nested/章 1/seed.txt", "seed")
        self.put(self.vault, "資料 nested/章 1/stable-a.txt", "stable a")
        self.put(self.vault, "資料 nested/章 1/stable-b.txt", "stable b")
        self.put(self.vault, "private/local.txt", "local-private")
        self.put(self.remote / "files", "private/remote.txt", "remote-private")

    def put(self, root, name, content):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def sync(self, *args, force=False):
        env = dict(self.env)
        if force:
            env["MEMEX_FORCE_RESYNC"] = "1"
        return subprocess.run(["bash", "-euo", "pipefail", "-c", self.script,
                               "memex-sync", *args], env=env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)

    def ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout)

    def initialize(self):
        self.ok(self.sync("--resync"))
        self.ok(self.sync())

    def test_nested_unicode_spaces_and_unlisted_files_on_both_sides(self):
        self.initialize()
        self.assertEqual((self.remote / "files/資料 nested/章 1/seed.txt").read_text(), "seed")
        self.put(self.remote / "files", "資料 nested/章 1/from remote.pdf", "remote")
        self.ok(self.sync())
        self.assertEqual((self.vault / "資料 nested/章 1/from remote.pdf").read_text(), "remote")
        self.assertEqual((self.vault / "private/local.txt").read_text(), "local-private")
        self.assertEqual((self.remote / "files/private/remote.txt").read_text(), "remote-private")
        self.assertFalse((self.remote / "files/private/local.txt").exists())
        self.assertFalse((self.vault / "private/remote.txt").exists())

    def test_initialization_always_requires_manual_resync(self):
        for force in (False, True):
            result = self.sync(force=force)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("--resync", result.stdout)
        self.assertFalse((self.remote / "files/資料 nested").exists())

    def test_single_file_patterns_and_comments(self):
        self.filters.write_text(
            "# Explicit files and patterns\n\n"
            "+ /資料 nested/章 1/seed.txt\n"
            "- /Knowledge/**/private.pdf\n"
            "+ /Knowledge/**/*.pdf\n- **\n\n; end\n"
        )
        self.put(self.vault, "Knowledge/Reading/論文.pdf", "paper")
        self.put(self.vault, "Knowledge/Reading/private.pdf", "private")
        self.put(self.vault, "Knowledge/Reading/note.md", "note")
        self.initialize()
        self.assertEqual((self.remote / "files/Knowledge/Reading/論文.pdf").read_text(), "paper")
        self.assertFalse((self.remote / "files/Knowledge/Reading/private.pdf").exists())
        self.assertFalse((self.remote / "files/Knowledge/Reading/note.md").exists())
        self.assertFalse(Path(str(self.filters) + ".md5").exists())
        self.assertTrue((self.root / "cache/rclone/bisync-memex-files/filters.md5").exists())

    def test_dry_run_preserves_both_data_trees(self):
        before = {str(p): p.read_bytes() for root in (self.vault, self.remote)
                  for p in root.rglob("*") if p.is_file()}
        self.ok(self.sync("--resync", "--dry-run"))
        after = {str(p): p.read_bytes() for root in (self.vault, self.remote)
                 for p in root.rglob("*") if p.is_file()}
        self.assertEqual(before, after)
        self.initialize()

    def test_deny_only_is_noop_even_with_missing_config_and_resync(self):
        self.initialize()
        self.filters.write_text("- **\n")
        self.config.unlink()
        before = {str(p): p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        self.ok(self.sync("--resync"))
        self.assertEqual(before, {str(p): p.read_bytes() for p in self.root.rglob("*") if p.is_file()})

    def test_missing_and_invalid_filters_fail_before_remote_access(self):
        self.config.unlink()
        for content in (None, "", "+ /資料 nested/**\n", "+ **\n- **\n",
                        "- **\n+ /private/**\n", "+ /../private/**\n- **\n",
                        "+ /[a/**\n- **\n", "! /private/**\n- **\n"):
            with self.subTest(content=content):
                self.filters.unlink(missing_ok=True)
                if content is not None:
                    self.filters.write_text(content)
                result = self.sync()
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("memex-sync:", result.stdout)
                self.assertFalse((self.root / "cache").exists())

    def test_cli_cannot_override_safety_options(self):
        for option in ("--filter", "--filters-file", "--backup-dir1", "--workdir",
                       "--conflict-resolve", "--resync-mode", "--only"):
            result = self.sync(option)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("許可されていない引数", result.stdout)

    def test_filter_change_requires_explicit_guarded_resync(self):
        self.initialize()
        self.put(self.vault, "new arbitrary/path/data.pdf", "new")
        self.filters.write_text("+ /資料 nested/章 1/**\n+ /new arbitrary/path/**\n- **\n")
        result = self.sync()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("resync", result.stdout.lower())
        self.assertFalse((self.remote / "files/new arbitrary").exists())
        self.assertNotEqual(self.sync("--resync").returncode, 0)
        self.ok(self.sync("--resync", force=True))
        self.assertEqual((self.remote / "files/new arbitrary/path/data.pdf").read_text(), "new")
        self.filters.write_text("+ /new arbitrary/path/**\n- **\n")
        self.assertNotEqual(self.sync().returncode, 0)
        self.ok(self.sync("--resync", force=True))
        self.assertTrue((self.vault / "資料 nested/章 1/seed.txt").exists())
        self.assertTrue((self.remote / "files/資料 nested/章 1/seed.txt").exists())

    def test_deletion_and_overwrite_preserve_backups_on_both_sides(self):
        self.initialize()
        left = self.vault / "資料 nested/章 1/seed.txt"
        left.write_text("a longer replacement")
        self.ok(self.sync())
        self.assertIn(b"seed", [p.read_bytes() for p in (self.remote / "backups").rglob("*") if p.is_file()])
        right = self.remote / "files/資料 nested/章 1/seed.txt"
        right.write_text("remote replacement longer still")
        self.ok(self.sync())
        self.assertIn(b"a longer replacement", [p.read_bytes() for p in (self.root / "backups").rglob("*") if p.is_file()])
        left.unlink()
        self.ok(self.sync())
        self.assertFalse(right.exists())
        self.assertIn(b"remote replacement longer still", [p.read_bytes() for p in (self.remote / "backups").rglob("*") if p.is_file()])

    def test_realpath_rejects_backup_symlink_into_vault(self):
        (self.root / "backups").symlink_to(self.vault, target_is_directory=True)
        result = self.sync("--resync")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("退避先", result.stdout)

    def test_remote_backup_overlap_rejected(self):
        self.assertIn("files backups", self.script)
        self.script = self.script.replace("test:backups", "test:files/backup").replace(
            "files backups", "files files/backup")
        result = self.sync("--resync")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("重複", result.stdout)


if __name__ == "__main__":
    unittest.main()

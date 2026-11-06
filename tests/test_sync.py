import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

PDF = b"%PDF-1.4\n" + bytes(range(256)) * 64


class SyncTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.template = Path(os.environ["MEMEX_SYNC_TEMPLATE"]).read_text()

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="memex-sync-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "rclone").mkdir()
        (self.root / "drive").mkdir()
        config = self.root / "rclone.conf"
        config.write_text(f"[test]\ntype = alias\nremote = {self.root / 'rclone'}\n")
        self.env = dict(os.environ, RCLONE_CONFIG=str(config),
                        GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.org",
                        GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.org",
                        GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="init.defaultBranch",
                        GIT_CONFIG_VALUE_0="main")
        self.git("init", "-q", "--bare", str(self.root / "origin.git"), cwd=self.root)
        self.a = self.clone("a")
        shutil.copy(os.environ["MEMEX_GITATTRIBUTES"], self.a / ".gitattributes")
        (self.a / ".gitattributes").chmod(0o644)
        self.write(self.a, "note.md", "# note\n")
        self.git("add", "-A", cwd=self.a)
        self.git("commit", "-qm", "init", cwd=self.a)
        self.annex_init(self.a)
        self.git("annex", "initremote", "-q", "drive", "type=directory",
                 f"directory={self.root / 'drive'}", "encryption=none", cwd=self.a)
        self.git("annex", "group", "-q", "drive", "backup", cwd=self.a)
        self.git("annex", "wanted", "-q", "drive", "standard", cwd=self.a)
        self.git("push", "-q", "origin", "HEAD:main", cwd=self.a)

    def git(self, *args, cwd, check=True):
        result = subprocess.run(["git", *args], cwd=cwd, env=self.env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout)
        return result.stdout

    def clone(self, name):
        self.git("clone", "-q", str(self.root / "origin.git"), name, cwd=self.root, check=False)
        path = self.root / name
        path.mkdir(exist_ok=True)
        if not (path / ".git").exists():
            self.git("init", "-q", "-b", "main", cwd=path)
            self.git("remote", "add", "origin", str(self.root / "origin.git"), cwd=path)
        return path

    def annex_init(self, vault):
        self.git("annex", "init", "-q", vault.name, cwd=vault)
        self.git("annex", "config", "--set", "annex.addunlocked", "true", cwd=vault)
        self.git("annex", "group", "-q", "here", "client", cwd=vault)
        self.git("annex", "wanted", "-q", "here", "standard", cwd=vault)

    def write(self, vault, name, content):
        path = vault / name
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, bytes):
            path.write_bytes(content)
        else:
            path.write_text(content)
        return path

    def sync(self, vault):
        script = self.template.replace("@VAULT@", str(vault))
        return subprocess.run(["bash", "-euo", "pipefail", "-c", script, "memex-sync"],
                              env=self.env, text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=300)

    def ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout)

    def annexed(self, vault, name):
        return subprocess.run(["git", "annex", "lookupkey", "--", name], cwd=vault, env=self.env,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0

    def on_drive(self, vault, name):
        return "drive" in self.git("annex", "whereis", "--", name, cwd=vault)

    def test_vault_without_git_annex_stops_with_setup_hint(self):
        plain = self.clone("plain")
        result = self.sync(plain)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("memex-setup", result.stdout)

    def test_pdf_added_with_plain_git_add_reaches_drive_and_the_other_pc(self):
        self.write(self.a, "Knowledge/Reading/book/book.pdf", PDF)
        self.git("add", "-A", cwd=self.a)
        self.git("commit", "-qm", "pdf", cwd=self.a)
        self.git("push", "-q", "origin", "HEAD:main", cwd=self.a)
        self.assertTrue(self.annexed(self.a, "Knowledge/Reading/book/book.pdf"))
        self.ok(self.sync(self.a))
        self.assertTrue(self.on_drive(self.a, "Knowledge/Reading/book/book.pdf"))

        b = self.clone("b")
        self.annex_init(b)
        self.git("annex", "enableremote", "-q", "drive", f"directory={self.root / 'drive'}", cwd=b)
        self.ok(self.sync(b))
        self.assertEqual((b / "Knowledge/Reading/book/book.pdf").read_bytes(), PDF)

    def test_binary_committed_to_git_is_moved_to_annex_without_changing_bytes(self):
        self.write(self.a, "pasted.png", PDF)
        self.git("-c", "annex.largefiles=nothing", "add", "pasted.png", cwd=self.a)
        self.git("commit", "-qm", "png in git", cwd=self.a)
        self.assertFalse(self.annexed(self.a, "pasted.png"))
        self.ok(self.sync(self.a))
        self.assertTrue(self.annexed(self.a, "pasted.png"))
        self.assertEqual((self.a / "pasted.png").read_bytes(), PDF)
        self.assertTrue(self.on_drive(self.a, "pasted.png"))
        self.assertIn("memex-sync:", self.git("log", "-1", "--format=%s", cwd=self.a))

    def test_text_file_in_annex_is_moved_back_to_git(self):
        self.write(self.a, "draft.md", "# draft\n")
        self.git("annex", "add", "-q", "--force-large", "draft.md", cwd=self.a)
        self.git("commit", "-qm", "draft in annex", cwd=self.a)
        self.assertTrue(self.annexed(self.a, "draft.md"))
        self.ok(self.sync(self.a))
        self.assertFalse(self.annexed(self.a, "draft.md"))
        self.assertEqual(self.git("show", "HEAD:draft.md", cwd=self.a), "# draft\n")

    def test_plugin_binaries_under_obsidian_stay_in_git(self):
        self.write(self.a, ".obsidian/plugins/x/typst.wasm", PDF)
        self.git("add", "-A", cwd=self.a)
        self.git("commit", "-qm", "plugin", cwd=self.a)
        self.ok(self.sync(self.a))
        self.assertFalse(self.annexed(self.a, ".obsidian/plugins/x/typst.wasm"))

    def test_deleted_file_content_remains_on_drive(self):
        self.write(self.a, "old.pdf", PDF)
        self.git("add", "old.pdf", cwd=self.a)
        self.git("commit", "-qm", "old", cwd=self.a)
        self.ok(self.sync(self.a))
        key = self.git("annex", "lookupkey", "old.pdf", cwd=self.a).strip()
        self.git("rm", "-q", "old.pdf", cwd=self.a)
        self.git("commit", "-qm", "rm", cwd=self.a)
        self.ok(self.sync(self.a))
        self.assertIn("drive", self.git("annex", "whereis", "--key", key, cwd=self.a))

    def test_staged_note_edits_are_not_included_in_the_move_commit(self):
        self.write(self.a, "pasted.png", PDF)
        self.git("-c", "annex.largefiles=nothing", "add", "pasted.png", cwd=self.a)
        self.git("commit", "-qm", "png in git", cwd=self.a)
        self.write(self.a, "note.md", "# edited\n")
        self.git("add", "note.md", cwd=self.a)
        self.ok(self.sync(self.a))
        self.assertEqual(self.git("show", "HEAD:note.md", cwd=self.a), "# note\n")
        self.assertIn("M  note.md", self.git("status", "--short", cwd=self.a))

    def test_unchanged_history_is_not_reclassified_again(self):
        self.ok(self.sync(self.a))
        self.write(self.a, "pasted.png", PDF)
        self.git("-c", "annex.largefiles=nothing", "add", "pasted.png", cwd=self.a)
        self.git("commit", "-qm", "png in git", cwd=self.a)
        head = self.git("rev-parse", "HEAD", cwd=self.a)
        self.ok(self.sync(self.a))
        self.assertTrue(self.annexed(self.a, "pasted.png"))
        moved = self.git("rev-parse", "HEAD", cwd=self.a)
        self.assertNotEqual(head, moved)
        self.ok(self.sync(self.a))
        self.assertEqual(self.git("rev-parse", "HEAD", cwd=self.a), moved)


    # 以下は 2026-11-06 の Astra のレビューで再現した不具合の回帰試験。
    def test_uncommitted_edit_of_a_file_to_move_stays_uncommitted(self):
        self.write(self.a, "draft.pdf", PDF)
        self.git("-c", "annex.largefiles=nothing", "add", "draft.pdf", cwd=self.a)
        self.git("commit", "-qm", "original", cwd=self.a)
        self.write(self.a, "draft.pdf", PDF + b"UNCOMMITTED EDIT")
        self.ok(self.sync(self.a))
        self.assertFalse(self.annexed(self.a, "draft.pdf"))
        self.assertTrue(self.git("status", "--porcelain", "--", "draft.pdf", cwd=self.a).strip())
        self.git("checkout", "--", "draft.pdf", cwd=self.a)
        self.ok(self.sync(self.a))
        self.assertTrue(self.annexed(self.a, "draft.pdf"))

    def test_file_without_content_is_reclassified_after_it_arrives(self):
        self.write(self.a, "book.pdf", PDF)
        self.git("add", "book.pdf", cwd=self.a)
        self.git("commit", "-qm", "book", cwd=self.a)
        self.ok(self.sync(self.a))
        self.git("push", "-q", "origin", "HEAD:main", cwd=self.a)
        b = self.clone("b")
        self.annex_init(b)
        self.git("annex", "enableremote", "-q", "drive", f"directory={self.root / 'drive'}", cwd=b)
        self.write(b, ".gitattributes", "* annex.largefiles=nothing\n")
        self.git("add", ".gitattributes", cwd=b)
        self.git("commit", "-qm", "move to Git", cwd=b)
        self.ok(self.sync(b))
        self.assertEqual((b / "book.pdf").read_bytes(), PDF)
        self.assertFalse(self.annexed(b, "book.pdf"))

    def test_file_deleted_before_the_first_sync_is_kept_on_drive(self):
        self.write(self.a, "old.pdf", PDF)
        self.git("add", "old.pdf", cwd=self.a)
        self.git("commit", "-qm", "old", cwd=self.a)
        key = self.git("annex", "lookupkey", "old.pdf", cwd=self.a).strip()
        self.git("rm", "-q", "old.pdf", cwd=self.a)
        self.git("commit", "-qm", "remove before next sync", cwd=self.a)
        self.ok(self.sync(self.a))
        self.assertIn("[drive]", self.git("annex", "whereis", "--key", key, cwd=self.a))

    def test_overwriting_a_file_keeps_the_old_version_in_the_annex(self):
        self.ok(self.sync(self.a))
        self.write(self.a, "edited.pdf", PDF)
        self.git("add", "edited.pdf", cwd=self.a)
        self.git("commit", "-qm", "first version", cwd=self.a)
        key = self.git("annex", "lookupkey", "edited.pdf", cwd=self.a).strip()
        location = self.git("annex", "contentlocation", key, cwd=self.a).strip()
        self.write(self.a, "edited.pdf", PDF + b"next version")
        self.assertEqual((self.a / location).read_bytes(), PDF)

    def test_tracked_file_matching_gitignore_is_reported(self):
        self.write(self.a, "local.pdf", PDF)
        self.git("add", "local.pdf", cwd=self.a)
        self.git("commit", "-qm", "local", cwd=self.a)
        self.write(self.a, ".gitignore", "/local.pdf\n")
        self.git("add", ".gitignore", cwd=self.a)
        self.git("commit", "-qm", "keep only here", cwd=self.a)
        result = self.sync(self.a)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("local.pdf", result.stdout)
        self.assertIn("git rm --cached", result.stdout)

    def test_invalid_rule_stops_without_moving_files(self):
        self.write(self.a, "book.pdf", PDF)
        self.git("add", "book.pdf", cwd=self.a)
        self.git("commit", "-qm", "book", cwd=self.a)
        self.ok(self.sync(self.a))
        self.write(self.a, ".gitattributes", "* annex.largefiles=not-a-valid-expression\n")
        self.git("-c", "annex.largefiles=nothing", "add", ".gitattributes", cwd=self.a)
        self.git("commit", "-qm", "invalid rule", cwd=self.a)
        before = self.git("rev-parse", "HEAD", cwd=self.a)
        result = self.sync(self.a)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.git("rev-parse", "HEAD", cwd=self.a), before)
        self.assertTrue(self.annexed(self.a, "book.pdf"))


    def test_uncommitted_rule_edit_does_not_move_other_files(self):
        self.write(self.a, "book.pdf", PDF)
        self.git("add", "book.pdf", cwd=self.a)
        self.git("commit", "-qm", "book", cwd=self.a)
        before = self.git("rev-parse", "HEAD", cwd=self.a)
        self.write(self.a, ".gitattributes", "* annex.largefiles=nothing\n")
        self.ok(self.sync(self.a))
        self.assertTrue(self.annexed(self.a, "book.pdf"))
        self.assertEqual(self.git("rev-parse", "HEAD", cwd=self.a), before)


    def test_empty_note_stays_in_git(self):
        self.write(self.a, "Knowledge/Writing/empty.md", "")
        self.git("add", "-A", cwd=self.a)
        self.git("commit", "-qm", "empty", cwd=self.a)
        self.ok(self.sync(self.a))
        self.assertFalse(self.annexed(self.a, "Knowledge/Writing/empty.md"))

    def test_pdf_with_non_utf8_text_encoding_goes_to_annex(self):
        # Typst が出す PDF は libmagic で unknown-8bit になり、mimeencoding=binary には当たらない。
        self.write(self.a, "typst.pdf", b"%PDF-1.7\n" + b"stream \xe9\xff\xe0 endstream\n" * 200)
        self.git("add", "typst.pdf", cwd=self.a)
        self.git("commit", "-qm", "typst pdf", cwd=self.a)
        self.assertTrue(self.annexed(self.a, "typst.pdf"))


if __name__ == "__main__":
    unittest.main()

import datetime
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class BisyncRecoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if "BISYNC_LIB" in os.environ:
            cls.library = Path(os.environ["BISYNC_LIB"]).read_text()
        else:
            source = Path(__file__).resolve().parents[1] / "nix/bisync-lib.nix"
            cls.library = subprocess.check_output(
                ["nix", "eval", "--impure", "--raw", "--expr", f"(import {source} {{ pkgs = {{}}; }}).text"],
                text=True,
            )

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.left = self.root / "left"
        self.right = self.root / "right"
        self.left.mkdir()
        self.right.mkdir()
        (self.left / "seed.txt").write_text("seed\n")
        self.environment = dict(
            os.environ, XDG_CACHE_HOME=str(self.root / "cache"), RCLONE_CONFIG=os.devnull,
        )
        initial = self.sync()
        self.assertEqual(initial.returncode, 0, initial.stdout)
        normal = self.sync()
        self.assertEqual(normal.returncode, 0, normal.stdout)
        self.baseline = self.root / "cache/rclone/test"
        self.lock = next(self.baseline.glob("*.path1.lst")).with_suffix("").with_suffix(".lck")

    def sync(self, *arguments):
        return subprocess.run(
            ["bash", "-euo", "pipefail", "-c",
             self.library + '\nmemex_bisync Test "$1" "$2" test "${@:3}"',
             "test", str(self.left), str(self.right), *arguments],
            env=self.environment, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, timeout=30,
        )

    def write_lock(self, expires):
        self.lock.write_text(json.dumps({
            "Session": "other-sync", "PID": str(os.getpid()),
            "TimeRenewed": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "TimeExpires": expires.isoformat(),
        }))

    def test_expired_lock_allows_next_sync(self):
        self.write_lock(datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=5))
        (self.left / "new.txt").write_text("new\n")
        result = self.sync()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual((self.right / "new.txt").read_text(), "new\n")
        self.assertFalse(self.lock.exists())

    def test_unexpired_lock_blocks_sync(self):
        self.write_lock(datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=5))
        (self.left / "new.txt").write_text("new\n")
        result = self.sync()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("prior lock file found", result.stdout)
        self.assertFalse((self.right / "new.txt").exists())
        self.assertTrue(self.lock.exists())

    def test_empty_lock_stops_without_transferring_files(self):
        self.lock.touch()
        (self.left / "new.txt").write_text("new\n")
        result = self.sync()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("prior lock file found", result.stdout)
        self.assertFalse((self.right / "new.txt").exists())
        self.assertEqual(self.lock.read_bytes(), b"")

    def test_existing_history_requires_explicit_resync_override(self):
        (self.left / "new.txt").write_text("new\n")
        result = self.sync("--resync")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("MEMEX_FORCE_RESYNC=1", result.stdout)
        self.assertFalse((self.right / "new.txt").exists())


if __name__ == "__main__":
    unittest.main()

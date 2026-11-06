import posixpath
from pathlib import Path
import sys
import subprocess
import tempfile


def validate(filters, folder, backup):
    paths = []
    for value in (folder, backup):
        if not value or value.startswith("/") or ":" in value or "\\" in value:
            raise ValueError("folder と backupFolder は remote 内の相対パスにしてください。")
        if ".." in value.split("/"):
            raise ValueError("remote のパスに .. は使えません。")
        paths.append(posixpath.normpath(value))
    left, right = paths
    if "." in paths or left == right or left.startswith(right + "/") or right.startswith(left + "/"):
        raise ValueError("同期先と退避先を重複させないでください。")
    content = Path(filters).read_text()
    lines = [line.strip() for line in content.splitlines()
             if line.strip() and not line.lstrip().startswith(("#", ";"))]
    if not lines or lines[-1] != "- **":
        raise ValueError("filter の末尾には - ** が必要です。")
    for line in lines[:-1]:
        if not (line.startswith("+ /") or line.startswith("- ")) or not line[2:].strip():
            raise ValueError("filter は + /path または - pattern で指定してください。")
        if any(part in (".", "..") for part in line[2:].split("/")):
            raise ValueError("filter のパスが不正です。")
    with tempfile.TemporaryDirectory(prefix="memex-filter-") as temporary:
        root = Path(temporary)
        snapshot = root / "filter"
        snapshot.write_text(content)
        (root / "empty").mkdir()
        result = subprocess.run(
            ["rclone", "--config", "/dev/null", "lsf", str(root / "empty"),
             "--filter-from", str(snapshot)], capture_output=True, text=True,
        )
        if result.returncode:
            raise ValueError(result.stderr.strip())
    return content if any(line.startswith("+ /") for line in lines) else ""


if __name__ == "__main__":
    try:
        print(validate(*sys.argv[1:]), end="")
    except (OSError, UnicodeError, ValueError) as error:
        print(f"memex-sync: {error}", file=sys.stderr)
        sys.exit(1)

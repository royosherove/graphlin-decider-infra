#!/usr/bin/env python3
"""Make bootstrap/requirements.lock: a hashed lock for Linux x86_64, CPython 3.12 and cu126.

Procedure (on any host with uv and network access):

  1. uv pip compile tools/lock-input.txt --generate-hashes --python-version 3.12 \
       --python-platform x86_64-unknown-linux-gnu --only-binary :all: --no-header \
       --index-url https://pypi.org/simple \
       --extra-index-url https://download.pytorch.org/whl/cu126 \
       --index-strategy unsafe-best-match -o LOCK_ALL
  2. python3 tools/make-lock.py LOCK_ALL bootstrap/requirements.lock

uv writes the hashes of all files of each version (all platforms). This tool keeps only the
hashes of the wheels that the GPU host can install: cp312 or py3 tags, abi3 or none,
manylinux x86_64 or "any". Thus the lock stays small enough for the EC2 user data (16 KB).
Each package line gets a comment with the index that has the files.

Stdlib only, Python 3.9 or later. Language: ASD-STE100.
"""

from __future__ import annotations

import json
import re
import sys
import urllib.request
from typing import Dict, List, Tuple

PYPI = "https://pypi.org/simple"
TORCH = "https://download.pytorch.org/whl/cu126"
PY_TAGS = {"cp312", "py3", "py312", "py2.py3"}
ABI_TAGS = {"cp312", "abi3", "none"}


def norm(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def wheel_ok(filename: str) -> bool:
    """True when the wheel installs on CPython 3.12, glibc Linux, x86_64."""
    if not filename.endswith(".whl"):
        return False
    parts = filename[:-4].split("-")
    if len(parts) < 5:
        return False
    py, abi, plat = parts[-3], parts[-2], parts[-1]
    if not set(abi.split(".")) & ABI_TAGS:
        return False
    if "abi3" in abi.split("."):
        # An abi3 wheel for CPython 3.N installs on each CPython 3.M with M >= N.
        minors = [int(t[3:]) for t in py.split(".") if re.fullmatch(r"cp3\d+", t)]
        if not minors or min(minors) > 12:
            return False
    elif not set(py.split(".")) & PY_TAGS:
        return False
    plats = plat.split(".")
    return any(p == "any" or (p.startswith("manylinux") and p.endswith("x86_64")) for p in plats)


def fetch(url: str, accept: str) -> str:
    request = urllib.request.Request(url, headers={"Accept": accept, "User-Agent": "make-lock/1"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read().decode("utf-8", "replace")


def files_pypi(name: str) -> Dict[str, str]:
    """sha256 -> filename for all files of a package on PyPI."""
    try:
        data = json.loads(fetch(f"{PYPI}/{norm(name)}/", "application/vnd.pypi.simple.v1+json"))
    except OSError:
        return {}
    return {f["hashes"]["sha256"]: f["filename"] for f in data.get("files", []) if "sha256" in f.get("hashes", {})}


def files_torch(name: str) -> Dict[str, str]:
    """sha256 -> filename for all files of a package on the PyTorch cu126 index."""
    try:
        html = fetch(f"{TORCH}/{norm(name)}/", "text/html")
    except OSError:
        return {}
    out: Dict[str, str] = {}
    for href in re.findall(r'href="([^"]+)"', html):
        path, _, frag = href.partition("#sha256=")
        if frag:
            out[frag] = urllib.request.unquote(path.rsplit("/", 1)[-1])
    return out


def parse(text: str) -> List[Tuple[str, List[str]]]:
    """Return (requirement, [sha256, ...]) for each entry in a uv lock."""
    entries: List[Tuple[str, List[str]]] = []
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or stripped.startswith("--index"):
            continue
        if stripped.startswith("--hash=sha256:"):
            entries[-1][1].append(stripped.split(":", 1)[1].rstrip(" \\"))
            continue
        entries.append((stripped.rstrip(" \\").strip(), []))
    return entries


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    entries = parse(open(sys.argv[1], encoding="utf-8").read())
    lines = [
        "# Hashed lock for the Strands Decider GPU host: Linux x86_64, CPython 3.12, CUDA 12.6.",
        "# Made by tools/make-lock.py from tools/lock-input.txt. Do not edit by hand.",
        "# Install: uv pip install --require-hashes --only-binary :all: --no-deps \\",
        f"#   --index-url {PYPI} --extra-index-url {TORCH} --index-strategy unsafe-best-match -r THIS_FILE",
    ]
    failed = False
    for requirement, hashes in entries:
        name = requirement.split("==", 1)[0]
        version = requirement.split("==", 1)[1]
        version_files = {}
        source = {}
        for label, table in (("pytorch-cu126", files_torch(name)), ("pypi", files_pypi(name))):
            for digest, filename in table.items():
                version_files.setdefault(digest, filename)
                source.setdefault(digest, label)
        keep = [h for h in hashes if h in version_files and wheel_ok(version_files[h])
                and (f"-{version}-" in version_files[h] or f"-{version.replace('-', '_')}-" in version_files[h])]
        if not keep:
            print(f"ERROR: no installable wheel for {requirement}", file=sys.stderr)
            failed = True
            continue
        indexes = sorted({source[h] for h in keep})
        lines.append(f"{requirement} \\")
        for i, digest in enumerate(keep):
            end = " \\" if i < len(keep) - 1 else ""
            lines.append(f"    --hash=sha256:{digest}{end}")
        lines.append(f"    # {', '.join(version_files[h] for h in keep)} ({', '.join(indexes)})")
    if failed:
        return 1
    with open(sys.argv[2], "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    print(f"wrote {sys.argv[2]}: {len(entries)} packages", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

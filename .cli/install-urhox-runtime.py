#!/usr/bin/env python3
"""Install or update UrhoXRuntime into a local CLI directory.

Cross-platform installer.  Downloads a single zip from CDN, extracts it, and
creates a unified entry command so callers can always invoke
``<dest>/UrhoXRuntime`` regardless of OS.

Design principles:
  - Idempotent: safe to call repeatedly.
  - Atomic: downloads to ``.download.tmp``, extracts to staging dir, then
    swaps in.  A crash mid-download never corrupts an existing installation.
  - Incremental: uses If-Modified-Since on the zip; skips download if 304.
"""
from __future__ import annotations

import os
import shutil
import stat
import subprocess
import sys
import zipfile
from pathlib import Path
from typing import Dict, Optional

# ---------------------------------------------------------------------------
# CDN source
# ---------------------------------------------------------------------------

CDN_ROOT = "https://urhox-demo-platform.spark.xd.com"

PLATFORMS: Dict[str, dict] = {
    "linux": {
        "zip_url": f"{CDN_ROOT}/runtime/linux/latest/UrhoXRuntime.zip",
        "executable": "UrhoXRuntime",
    },
    "win32": {
        "zip_url": f"{CDN_ROOT}/runtime/windows/latest/UrhoXRuntime.zip",
        "executable": "UrhoXRuntime.exe",
    },
    "darwin": {
        "zip_url": f"{CDN_ROOT}/runtime/macos/latest/UrhoXRuntime.zip",
        "executable": "UrhoXRuntime",
    },
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def log(msg: str) -> None:
    print(msg, flush=True)


def _curl() -> Optional[str]:
    return shutil.which("curl")


def _download_file(
    url: str,
    dest: Path,
    *,
    conditional: bool = False,
    timeout: int = 60,
) -> bool:
    """Download *url* to *dest* atomically.

    When *conditional* is True and *dest* already exists, sends an
    ``If-Modified-Since`` header.  Returns True if the file was
    (re-)downloaded, False if the server replied 304 (not modified).
    """
    curl = _curl()
    if not curl:
        raise RuntimeError("curl is required but not found on PATH")

    tmp = dest.with_name(dest.name + ".download.tmp")
    tmp.unlink(missing_ok=True)

    cmd = [
        curl,
        "-sS",
        "-L",
        "--retry", "2",
        "--retry-delay", "1",
        "--connect-timeout", str(timeout),
        "--speed-time", str(timeout),
        "--speed-limit", "1",
    ]

    if conditional and dest.exists():
        cmd.extend(["-z", str(dest)])

    cmd.extend(["-o", str(tmp), "-w", "%{http_code}", url])

    proc = subprocess.run(cmd, text=True, capture_output=True)
    status = (proc.stdout or "").strip()[-3:]

    if proc.returncode != 0:
        tmp.unlink(missing_ok=True)
        detail = (proc.stderr or proc.stdout or "").strip()
        raise RuntimeError(f"curl failed for {url}: {detail or f'exit {proc.returncode}'}")

    if not status.isdigit():
        tmp.unlink(missing_ok=True)
        raise RuntimeError(f"Unexpected HTTP status for {url}: {status!r}")

    code = int(status)

    if 200 <= code < 300 and tmp.exists() and tmp.stat().st_size > 0:
        os.replace(tmp, dest)
        return True

    if code == 304:
        tmp.unlink(missing_ok=True)
        return False

    tmp.unlink(missing_ok=True)
    if conditional and dest.exists():
        log(f"  warning: unexpected HTTP {code} for {url}, keeping local copy")
        return False
    raise RuntimeError(f"Download failed: HTTP {code} for {url}")


def _chmod_executable(path: Path) -> None:
    """Add executable bits (no-op on Windows)."""
    if sys.platform == "win32":
        return
    mode = path.stat().st_mode
    path.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def _remove_quarantine(path: Path) -> None:
    """Remove macOS Gatekeeper quarantine attribute."""
    if sys.platform != "darwin":
        return
    xattr = shutil.which("xattr")
    if xattr:
        subprocess.run(
            [xattr, "-dr", "com.apple.quarantine", str(path)],
            capture_output=True,
        )


def _create_command(dest: Path, executable: Path) -> Path:
    """Create a unified ``UrhoXRuntime`` entry-point command."""
    if sys.platform == "win32":
        cmd_path = dest / "UrhoXRuntime.cmd"
        cmd_path.write_text(
            f'@"%~dp0{executable.name}" %*\r\n',
            encoding="utf-8",
        )
        return cmd_path

    return executable


# ---------------------------------------------------------------------------
# Main logic
# ---------------------------------------------------------------------------


def install(plat: str, dest: Path, timeout: int = 60) -> None:
    cfg = PLATFORMS[plat]
    zip_url: str = cfg["zip_url"]
    exe_name: str = cfg["executable"]

    dest.mkdir(parents=True, exist_ok=True)

    log(f"Installing UrhoXRuntime ({plat}) into {dest}")

    # Download zip (with If-Modified-Since if local copy exists)
    zip_path = dest / "UrhoXRuntime.zip"
    already_exists = zip_path.exists()
    updated = _download_file(zip_url, zip_path, conditional=already_exists, timeout=timeout)

    if not updated and already_exists:
        log("  Up-to-date (304 not modified).")
        # Still ensure entry command exists
        exe_path = dest / exe_name
        if exe_path.exists():
            _create_command(dest, exe_path)
            log("Done.")
            return

    # Extract zip atomically: extract to staging dir, then move contents
    log("  Extracting...")
    staging = dest / ".staging"
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir()

    with zipfile.ZipFile(zip_path) as zf:
        # Guard against Zip Slip (path traversal via ../ in entry names)
        for info in zf.infolist():
            target = (staging / info.filename).resolve()
            if not str(target).startswith(str(staging.resolve()) + os.sep):
                raise RuntimeError(f"Unsafe zip entry (path traversal): {info.filename}")
        zf.extractall(staging)

    # Move extracted files to dest (overwrite existing)
    for item in staging.iterdir():
        target = dest / item.name
        if target.exists():
            if target.is_dir():
                shutil.rmtree(target)
            else:
                target.unlink()
        shutil.move(str(item), str(target))

    shutil.rmtree(staging)

    exe_path = dest / exe_name

    # Platform post-processing
    _chmod_executable(exe_path)
    _remove_quarantine(exe_path)

    # Create unified entry command
    command = _create_command(dest, exe_path)
    log(f"  Entry command: {command}")
    log("Done.")


def _default_dest() -> str:
    """Default install directory: <project_root>/.cli (all platforms)."""
    # Two levels up from this script → project root
    return os.path.join(os.path.dirname(__file__), "..", "..", ".cli")


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(
        description="Install or update UrhoXRuntime (cross-platform)",
    )
    parser.add_argument(
        "--dest",
        default=_default_dest(),
        help="Installation directory (default: project .cli/)",
    )
    parser.add_argument(
        "--platform",
        choices=list(PLATFORMS.keys()),
        default=sys.platform if sys.platform in PLATFORMS else None,
        help="Target platform (default: auto-detect)",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=60,
        help="Network timeout in seconds (default: 60)",
    )

    args = parser.parse_args()

    if not args.platform:
        print(
            f"error: unsupported platform {sys.platform!r}. "
            f"Use --platform to override.",
            file=sys.stderr,
        )
        return 1

    dest = Path(args.dest).expanduser().resolve()

    try:
        install(args.platform, dest, timeout=args.timeout)
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        return 130

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

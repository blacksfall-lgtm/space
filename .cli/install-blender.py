#!/usr/bin/env python3
"""Install or update the UrhoX Blender runtime into .cli.

The package is expected to be published on the same CDN root used by
install-urhox-runtime.sh, under a different path:

  https://urhox-demo-platform.spark.xd.com/blender/linux/headless/latest/

The installer first tries to read version.json from that directory. A minimal
manifest looks like this:

  {
    "version": "5.1.2-headless",
    "archive": "blender_5.1.2_headless.zip",
    "executable": "blender_5.1.2_headless/blender",
    "sha256": "optional archive sha256"
  }

If version.json is absent, the installer falls back to the default archive name
above so the current Linux package can be uploaded without extra metadata.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import os
import platform
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

CDN_ROOT = "https://urhox-demo-platform.spark.xd.com"
DEFAULT_VERSION = "5.1.2-headless"
DEFAULT_ARCHIVE = "blender_5.1.2_headless.zip"
DEFAULT_EXECUTABLE = "blender_5.1.2_headless/blender"
MARKER_NAME = ".urhox-blender-install.json"


class InstallError(RuntimeError):
    pass


def log(message: str) -> None:
    print(message)


def default_cli_dir() -> Path:
    return Path(os.environ.get("URHOX_CLI_DIR", "/workspace/.cli")).expanduser()


def detect_platform_path() -> str:
    system = platform.system().lower()
    machine = platform.machine().lower()
    if system == "linux" and machine in {"x86_64", "amd64"}:
        return "linux/headless"
    raise InstallError(f"Unsupported platform for Blender installer: {platform.system()} {platform.machine()}")


def build_default_base_url(cdn_root: str) -> str:
    return f"{cdn_root.rstrip('/')}/blender/{detect_platform_path()}/latest"


def url_join(base: str, name: str) -> str:
    return urllib.parse.urljoin(base.rstrip("/") + "/", name)


def is_http_url(url: str) -> bool:
    return urllib.parse.urlparse(url).scheme in {"http", "https"}


def curl_path() -> Optional[str]:
    return shutil.which("curl")


def curl_fetch_to_file(url: str, dest: Path, timeout: int, *, allow_404: bool = False, max_time: Optional[int] = None) -> bool:
    """Fetch URL with curl, returning False only for an allowed HTTP 404.

    curl is preferred over urllib because it reliably honors http_proxy/https_proxy
    in the ai-dev-kit sandbox, including HTTPS over HTTP proxy via CONNECT.
    """
    curl = curl_path()
    if not curl:
        raise FileNotFoundError("curl")

    dest.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        curl,
        "-sS",
        "-L",
        "--retry",
        "2",
        "--retry-delay",
        "1",
        "--connect-timeout",
        str(timeout),
        "--speed-time",
        str(timeout),
        "--speed-limit",
        "1",
    ]
    if max_time is not None:
        cmd.extend(["--max-time", str(max(1, max_time))])
    cmd.extend(["-o", str(dest), "-w", "%{http_code}", url])

    proc = subprocess.run(cmd, text=True, capture_output=True)
    status = (proc.stdout or "").strip()[-3:]
    if proc.returncode != 0:
        if dest.exists():
            dest.unlink()
        detail = (proc.stderr or proc.stdout or "").strip()
        raise InstallError(f"curl failed for {url}: {detail or f'exit {proc.returncode}'}")

    if is_http_url(url):
        if status == "404" and allow_404:
            if dest.exists():
                dest.unlink()
            return False
        if not (status.isdigit() and 200 <= int(status) < 300):
            if dest.exists():
                dest.unlink()
            raise InstallError(f"Failed to read {url}: HTTP {status or 'unknown'}")

    return True


def read_json_url(url: str, timeout: int = 20) -> Optional[Dict[str, Any]]:
    curl = curl_path()
    if curl:
        with tempfile.TemporaryDirectory(prefix="blender-manifest-") as tmp_name:
            manifest_path = Path(tmp_name) / "version.json"
            found = curl_fetch_to_file(url, manifest_path, timeout, allow_404=True, max_time=timeout)
            if not found:
                return None
            try:
                return json.loads(manifest_path.read_text(encoding="utf-8"))
            except json.JSONDecodeError as exc:
                raise InstallError(f"Invalid JSON from {url}: {exc}") from exc

    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            data = response.read().decode("utf-8")
        return json.loads(data)
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        raise InstallError(f"Failed to read {url}: HTTP {exc.code}") from exc
    except urllib.error.URLError as exc:
        raise InstallError(f"Failed to read {url}: {exc.reason}") from exc
    except json.JSONDecodeError as exc:
        raise InstallError(f"Invalid JSON from {url}: {exc}") from exc


def read_json_file(path: Path) -> Optional[Dict[str, Any]]:
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def write_json_file(path: Path, data: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")


def resolve_manifest(args: argparse.Namespace) -> Dict[str, Any]:
    if args.archive_url:
        version = args.version if args.version != "latest" else DEFAULT_VERSION
        return {
            "version": version,
            "archive_url": args.archive_url,
            "archive": Path(urllib.parse.urlparse(args.archive_url).path).name or DEFAULT_ARCHIVE,
            "executable": args.executable or DEFAULT_EXECUTABLE,
            "sha256": args.sha256,
            "source": "arguments",
        }

    base_url = args.base_url.rstrip("/")
    remote_manifest = None
    if not args.no_manifest:
        manifest_url = url_join(base_url, "version.json")
        log(f"Checking Blender manifest: {manifest_url}")
        remote_manifest = read_json_url(manifest_url, timeout=args.timeout)

    if remote_manifest:
        version = str(remote_manifest.get("version") or "").strip()
        if not version:
            raise InstallError("version.json is missing required field: version")
        if args.version != "latest" and args.version != version:
            raise InstallError(f"Requested version {args.version}, but CDN latest manifest is {version}")
        archive = str(remote_manifest.get("archive") or "").strip()
        archive_url = str(remote_manifest.get("archive_url") or "").strip()
        if not archive and not archive_url:
            raise InstallError("version.json must contain archive or archive_url")
        if not archive_url:
            archive_url = url_join(base_url, archive)
        return {
            "version": version,
            "archive": archive or Path(urllib.parse.urlparse(archive_url).path).name,
            "archive_url": archive_url,
            "executable": str(remote_manifest.get("executable") or DEFAULT_EXECUTABLE),
            "sha256": str(remote_manifest.get("sha256") or args.sha256 or "") or None,
            "source": "version.json",
        }

    if args.version not in {"latest", DEFAULT_VERSION} and not args.archive:
        raise InstallError("A non-default --version requires --archive or --archive-url when version.json is unavailable")

    archive = args.archive or DEFAULT_ARCHIVE
    version = args.version if args.version != "latest" else DEFAULT_VERSION
    return {
        "version": version,
        "archive": archive,
        "archive_url": url_join(base_url, archive),
        "executable": args.executable or DEFAULT_EXECUTABLE,
        "sha256": args.sha256,
        "source": "defaults",
    }


def download_file(url: str, dest: Path, timeout: int) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".tmp")
    if tmp.exists():
        tmp.unlink()
    log(f"Downloading: {url}")

    if curl_path():
        curl_fetch_to_file(url, tmp, timeout)
    else:
        try:
            with urllib.request.urlopen(url, timeout=timeout) as response, tmp.open("wb") as out:
                shutil.copyfileobj(response, out)
        except urllib.error.HTTPError as exc:
            raise InstallError(f"Download failed: HTTP {exc.code} {url}") from exc
        except urllib.error.URLError as exc:
            raise InstallError(f"Download failed: {exc.reason} {url}") from exc

    if not tmp.exists() or tmp.stat().st_size == 0:
        if tmp.exists():
            tmp.unlink()
        raise InstallError(f"Downloaded file is empty: {url}")
    os.replace(tmp, dest)
    log(f"Downloaded archive: {dest} ({dest.stat().st_size} bytes)")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_sha256(path: Path, expected: Optional[str]) -> None:
    if not expected:
        return
    actual = sha256_file(path)
    if actual.lower() != expected.lower():
        raise InstallError(f"SHA256 mismatch for {path.name}: expected {expected}, got {actual}")
    log(f"SHA256 verified: {actual}")


def ensure_within(base: Path, target: Path) -> None:
    base_real = base.resolve()
    target_real = target.resolve()
    try:
        common = os.path.commonpath([str(base_real), str(target_real)])
    except ValueError as exc:
        raise InstallError(f"Unsafe zip path: {target}") from exc
    if common != str(base_real):
        raise InstallError(f"Unsafe zip path escapes destination: {target}")


def safe_extract(zip_path: Path, extract_dir: Path) -> None:
    extract_dir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path) as archive:
        for info in archive.infolist():
            ensure_within(extract_dir, extract_dir / info.filename)
        archive.extractall(extract_dir)


def find_executable(extract_dir: Path, executable_hint: str) -> Path:
    hinted = extract_dir / executable_hint
    if hinted.exists() and hinted.is_file():
        return hinted

    names = ["blender.exe"] if platform.system().lower() == "windows" else ["blender"]
    candidates = []
    for name in names:
        candidates.extend(p for p in extract_dir.rglob(name) if p.is_file())
    if not candidates:
        raise InstallError(f"Could not find Blender executable under {extract_dir}")
    candidates.sort(key=lambda p: len(p.parts))
    return candidates[0]


def chmod_executable(path: Path) -> None:
    if platform.system().lower() == "windows":
        return
    mode = path.stat().st_mode
    path.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def install_archive(archive_path: Path, install_root: Path, manifest: Dict[str, Any]) -> Tuple[Path, Path]:
    version = manifest["version"]
    with tempfile.TemporaryDirectory(prefix="blender-extract-", dir=str(install_root)) as tmp_name:
        extract_dir = Path(tmp_name) / "extract"
        safe_extract(archive_path, extract_dir)
        exe_in_extract = find_executable(extract_dir, str(manifest.get("executable") or DEFAULT_EXECUTABLE))
        chmod_executable(exe_in_extract)

        top_entries = [p for p in extract_dir.iterdir()]
        if len(top_entries) == 1 and top_entries[0].is_dir():
            package_src = top_entries[0]
            target_name = package_src.name
        else:
            package_src = extract_dir
            target_name = f"blender-{sanitize_version(version)}"

        target_dir = install_root / target_name
        staging_dir = install_root / f".{target_name}.staging"
        if staging_dir.exists():
            shutil.rmtree(staging_dir)
        shutil.move(str(package_src), str(staging_dir))
        if target_dir.exists():
            shutil.rmtree(target_dir)
        os.replace(staging_dir, target_dir)

    exe_rel = exe_in_extract.relative_to(package_src)
    final_exe = target_dir / exe_rel
    chmod_executable(final_exe)
    return target_dir, final_exe


def sanitize_version(version: str) -> str:
    return "".join(ch if ch.isalnum() or ch in {"-", "_", "."} else "_" for ch in version)


def create_command(cli_dir: Path, executable: Path) -> Path:
    system = platform.system().lower()
    if system == "windows":
        command = cli_dir / "blender.cmd"
        command.write_text(f'@echo off\r\n"{executable}" %*\r\n', encoding="utf-8")
        return command

    command = cli_dir / "blender"
    if command.exists() or command.is_symlink():
        if command.is_dir() and not command.is_symlink():
            raise InstallError(f"Cannot create Blender command because directory exists: {command}")
        command.unlink()
    try:
        os.symlink(executable, command)
    except OSError:
        command.write_text(f'#!/bin/sh\nexec "{executable}" "$@"\n', encoding="utf-8")
        command.chmod(0o755)
    return command


def is_installed(marker: Optional[Dict[str, Any]], manifest: Dict[str, Any]) -> bool:
    if not marker:
        return False
    if marker.get("version") != manifest.get("version"):
        return False
    exe = marker.get("executable")
    command = marker.get("command")
    return bool(exe and Path(exe).exists() and command and Path(command).exists())


def install(args: argparse.Namespace) -> int:
    cli_dir = Path(args.dest).expanduser().resolve()
    install_root = cli_dir / "blender-runtime"
    marker_path = install_root / MARKER_NAME
    base_url = args.base_url or build_default_base_url(args.cdn_root)
    args.base_url = base_url

    manifest = resolve_manifest(args)
    marker = read_json_file(marker_path)

    if is_installed(marker, manifest) and not args.force:
        log(f"Blender already installed: version {marker['version']}")
        log(f"Executable: {marker['executable']}")
        if args.print_path:
            print(marker["command"])
        return 0

    archive_url = manifest["archive_url"]
    archive_name = manifest.get("archive") or Path(urllib.parse.urlparse(archive_url).path).name or DEFAULT_ARCHIVE
    archive_path = install_root / ".downloads" / archive_name

    log(f"Target version: {manifest['version']} ({manifest['source']})")
    log(f"Install dir: {install_root}")
    log(f"Archive URL: {archive_url}")

    if args.dry_run:
        log("Dry run: no files will be changed")
        return 0

    install_root.mkdir(parents=True, exist_ok=True)
    download_file(archive_url, archive_path, timeout=args.timeout)
    verify_sha256(archive_path, manifest.get("sha256"))
    target_dir, executable = install_archive(archive_path, install_root, manifest)
    command = create_command(cli_dir, executable)

    installed = {
        "version": manifest["version"],
        "archive_url": archive_url,
        "archive": archive_name,
        "package_dir": str(target_dir),
        "executable": str(executable),
        "command": str(command),
        "installed_at_utc": _dt.datetime.now(_dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    }
    write_json_file(marker_path, installed)

    log(f"Installed Blender {manifest['version']}")
    log(f"Executable: {executable}")
    log(f"Command: {command}")
    if args.print_path:
        print(command)
    return 0


def parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Install the UrhoX Blender runtime into .cli")
    parser.add_argument("--dest", default=str(default_cli_dir()), help="CLI directory to install into (default: /workspace/.cli or URHOX_CLI_DIR)")
    parser.add_argument("--cdn-root", default=os.environ.get("URHOX_CDN_ROOT", CDN_ROOT), help="CDN root URL")
    parser.add_argument("--base-url", default=os.environ.get("URHOX_BLENDER_CDN_BASE"), help="Full Blender package base URL")
    parser.add_argument("--version", default="latest", help="Requested version, or latest")
    parser.add_argument("--archive", help="Archive filename under --base-url when version.json is unavailable")
    parser.add_argument("--archive-url", help="Full archive URL; bypasses version.json")
    parser.add_argument("--executable", help="Executable path inside archive")
    parser.add_argument("--sha256", help="Expected archive SHA256")
    parser.add_argument("--no-manifest", action="store_true", help="Do not fetch version.json; use defaults or explicit args")
    parser.add_argument("--force", action="store_true", help="Reinstall even if the requested version is already installed")
    parser.add_argument("--dry-run", action="store_true", help="Resolve version and URLs without downloading or changing files")
    parser.add_argument("--print-path", action="store_true", help="Print final command path")
    parser.add_argument("--timeout", type=int, default=60, help="Network timeout in seconds")
    return parser.parse_args(argv)


def main(argv: Optional[list[str]] = None) -> int:
    try:
        return install(parse_args(argv))
    except InstallError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())

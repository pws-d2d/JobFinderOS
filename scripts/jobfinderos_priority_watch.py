#!/usr/bin/env python3
"""JobFinderOS scheduled guard: weekday priority-function watch (local Claude skill). Window from config/scheduler.yaml `watch:`."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
from datetime import datetime, time
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parent.parent


def _bash_bin() -> str:
    """Git-for-Windows bash on Windows, PATH-resolved bash elsewhere.

    Verified empirically: under Task Scheduler's own process environment (not
    an interactive Git Bash session's PATH), a bare shutil.which("bash") can
    resolve to the WSL app-execution-alias stub in WindowsApps instead of Git
    Bash - which then mangles a Windows-style script path into gibberish and
    runs in a shell that doesn't even support `pipefail`.
    """
    if os.name == "nt":
        program_files = os.environ.get("ProgramFiles", "")
        candidates = [
            os.environ.get("JOBFINDEROS_BASH_BIN", ""),
            str(Path(program_files) / "Git" / "bin" / "bash.exe"),
            str(Path(program_files) / "Git" / "usr" / "bin" / "bash.exe"),
        ]
        for candidate in candidates:
            if candidate and Path(candidate).is_file():
                return candidate
        found = shutil.which("bash")
        if found and "WindowsApps" not in found and "System32" not in found:
            return found
        return found or "bash"
    return shutil.which("bash") or "/bin/bash"

def _scheduler_cfg() -> dict:
    """config/scheduler.yaml as a dict ({} if missing or PyYAML absent)."""
    cfg = ROOT / 'config' / 'scheduler.yaml'
    try:
        import yaml  # type: ignore
        return yaml.safe_load(cfg.read_text()) or {}
    except Exception:
        return {}


def _tz():
    name = (_scheduler_cfg().get('timezone') or '').strip()
    if name:
        try:
            return ZoneInfo(name)
        except Exception:
            pass
    return datetime.now().astimezone().tzinfo

LOCAL_TZ = _tz()
MARKER = ROOT / 'logs' / 'scheduler-cron' / 'priority-watch.last-success'
LOCK = ROOT / 'logs' / 'scheduler-cron' / 'priority-watch.lock'


def emit(payload: dict) -> None:
    print(json.dumps(payload, ensure_ascii=False))


def pid_alive(pid: int) -> bool:
    """Cross-platform liveness check. os.kill(pid, 0) is unreliable on Windows for
    an already-exited pid (verified empirically: it neither raises nor reports the
    true state), so Windows gets its own check via GetExitCodeProcess."""
    if os.name == 'nt':
        import ctypes
        PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
        handle = ctypes.windll.kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
        if not handle:
            return False
        try:
            STILL_ACTIVE = 259
            exit_code = ctypes.c_ulong()
            ctypes.windll.kernel32.GetExitCodeProcess(handle, ctypes.byref(exit_code))
            return exit_code.value == STILL_ACTIVE
        finally:
            ctypes.windll.kernel32.CloseHandle(handle)
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def lock_status(lock_path: Path) -> str | None:
    if not lock_path.exists():
        return None
    try:
        pid = int(lock_path.read_text().strip() or '0')
    except ValueError:
        lock_path.unlink(missing_ok=True)
        return None
    if pid > 0 and pid_alive(pid):
        return f'in_progress:{pid}'
    lock_path.unlink(missing_ok=True)
    return None


def acquire_lock(lock_path: Path) -> bool:
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        fd = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError:
        return False
    with os.fdopen(fd, 'w') as fh:
        fh.write(str(os.getpid()))
    return True


def main() -> None:
    now = datetime.now(LOCAL_TZ)
    today = now.strftime('%Y-%m-%d')
    if now.weekday() >= 5:
        emit({'status': 'skip', 'reason': 'weekend', 'today': today})
        return
    w = _scheduler_cfg().get('watch') or {}
    if now.time() < time(int(w.get('hour', 9)), int(w.get('minute', 0))):
        emit({'status': 'skip', 'reason': 'before_window', 'today': today})
        return
    if MARKER.exists() and MARKER.read_text().strip() == today:
        emit({'status': 'skip', 'reason': 'already_succeeded', 'today': today})
        return
    active = lock_status(LOCK)
    if active:
        emit({'status': 'skip', 'reason': active, 'today': today})
        return
    if not acquire_lock(LOCK):
        emit({'status': 'skip', 'reason': 'in_progress', 'today': today})
        return

    try:
        cmd = [_bash_bin(), 'scripts/JobFinderOS_run_skill.sh', 'priority-watch', 'jobs-priority-watch']
        proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
        if proc.returncode != 0:
            emit({
                'status': 'error',
                'reason': 'priority_watch_failed',
                'today': today,
                'returncode': proc.returncode,
                'stdout_tail': proc.stdout[-4000:],
                'stderr_tail': proc.stderr[-4000:],
            })
            return

        MARKER.parent.mkdir(parents=True, exist_ok=True)
        MARKER.write_text(today + '\n')
        emit({'status': 'success', 'today': today, 'skill': 'jobs-priority-watch'})
    finally:
        LOCK.unlink(missing_ok=True)


if __name__ == '__main__':
    main()

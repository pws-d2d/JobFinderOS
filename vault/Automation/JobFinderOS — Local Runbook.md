# JobFinderOS — Local Runbook

> **JobFinderOS:** system · local-first automation (macOS launchd or Windows Task Scheduler + Claude Code CLI)

Scheduled work runs **on your own machine**, writes directly to **`vault/`** on disk (Obsidian). No cloud routines, no API keys, no `git push` required for automation to work. The scheduler itself (`scheduler_tick.py`) is the same on both platforms — only the thing that fires it on an interval differs: launchd on macOS, Task Scheduler on Windows. Everything under "Scheduled jobs," "Optional helpers," "Unattended tool boundaries," "Gmail send-blocking," and "Manual commands" below applies identically on both; see the **Windows** section for what's different.

---

## Architecture

```
launchd (com.jobfinderos.scheduler)
  → scheduler_tick.py (every ~30 min while awake)
    → JobFinderOS_run_skill.sh (daily / weekly when due)
    → jobfinderos_priority_watch.py (each tick)
      → claude -p /skill → vault/
```

Logs: `logs/launchd-runs.log`, `logs/scheduler-cron/*.last-success`, mirror in [[JobFinderOS — Schedule & Run Log]] when allowed.

## Scheduled jobs

| Job | Entrypoint | Skill | Window (timezone in `config/scheduler.yaml`) |
|-----|------------|-------|----------------------------------------------|
| Daily Jobs | `scheduler_tick` → `JobFinderOS_run_skill.sh` | `/jobs-daily` | After `daily.hour` (default 7:00) |
| Weekly Mark | `scheduler_tick` → `JobFinderOS_run_skill.sh` | `/mark-weekly` | `weekly.weekday` after `weekly.hour` (default Monday 8:00). Weekly wins: daily is skipped that day |
| Priority watch | `jobfinderos_priority_watch.py` each tick | `/jobs-priority-watch` | Weekdays after `watch.hour` (default 9:00) |

Install or refresh (macOS):

```bash
bash scripts/JobFinderOS_install_launchd.sh
JOBS_DAILY_HOUR=7 MARK_WEEKLY_WEEKDAY=1 WATCH_HOUR=9 JOBFINDEROS_TZ=America/New_York bash scripts/JobFinderOS_install_launchd.sh
```

Install or refresh (Windows): see the **Windows** section below.

## Optional helpers

`bash scripts/JobFinderOS_install_helpers.sh [latest|prune|atspoll]` renders `scripts/launchd/*.plist.template` and installs:

| Label | What | Cadence |
|-------|------|---------|
| `com.jobfinderos.latest` | `jobfinderos_update_latest.py`: rewrites the dated pointer notes at the vault root | On any write to the digest folders |
| `com.jobfinderos.prune` | `jobfinderos_prune_history.py`: 30-day retention for digests/pulses/watches, 90 for weekly briefs. Deletes + commits locally by default; pass `--push` to also push (off by default, matching the poller) | Weekly |
| `com.jobfinderos.atspoll` | `jobfinderos_ats_poll.py`: deterministic direct-ATS sweep → `Market Intel/ATS Inbox.md` | Per the template's calendar interval |

The poller needs `config/ats_boards.yaml` (copy the example, edit `filters:`, run `--seed` once). Its stdout/stderr go to `~/.jobfinderos/logs/`, not the repo, because launchd cannot write under `~/Documents` without Full Disk Access.

## Prerequisites

1. Claude Code CLI on PATH and logged in (`claude auth login`)
2. Gmail MCP connected in claude.ai (for the email pass; everything else works without it)
3. The machine on and you logged in during the windows (both launchd LaunchAgents and this Task Scheduler task run only while you're logged on)
4. PyYAML in the project venv (`pip install -r requirements.txt`)
5. **Gmail send-blocking configured** before the first unattended email-touching run — see below. Skip this and "never send email" (CLAUDE.md's Email safety section) is enforced by agent doctrine alone, not by anything the CLI refuses to do.

## Unattended tool boundaries

`JobFinderOS_run_skill.sh` never runs a skill with `--dangerously-skip-permissions`. Instead it builds a per-skill tool profile:

- **scout/mark family** (`jobs-scout`, `jobs-priority-watch`, `mark-pulse`, `mark-weekly`, `mark-profiler`, `jobs-research`, `title-audit`): `--tools Agent,Read,Write,Edit,Glob,Grep,WebFetch,WebSearch` and `--strict-mcp-config` with no `--mcp-config`, so the run has no MCP connector at all — no Gmail, no Drive, no Canva, nothing beyond the repo and the open web. A scraped careers page or search result that tries to steer the agent somewhere has nothing to steer it into; there's no Bash, no email, no other connector to reach.
- **coach-touching family** (`jobs-daily`, `jobs-email`, `jobs-digest`, `email-watch`, `checkin`): same tool set, but MCP stays on because `jobs-daily` delegates its email leg to `coach`, which needs Gmail. This profile is only as safe as `JOBFINDEROS_DISALLOWED_TOOLS` below.
- **Bash is excluded from every default profile.** None of the scheduled skills call it. If you add a skill that genuinely needs it, pass `JOBFINDEROS_SKILL_ALLOWED_TOOLS` explicitly for that run rather than changing the default.
- Anything not recognized above fails closed (same as the scout/mark profile).

Env var overrides (set in the launchd plist's `EnvironmentVariables` or before a manual run):

| Var | Purpose | Default |
|-----|---------|---------|
| `JOBFINDEROS_SKILL_ALLOWED_TOOLS` | Full `--tools` list, replacing the built-in profile | `Agent,Read,Write,Edit,Glob,Grep,WebFetch,WebSearch` |
| `JOBFINDEROS_SKILL_STRICT_MCP` | `1` = no MCP connector at all, `0` = whatever's configured | per skill, see above |
| `JOBFINDEROS_DISALLOWED_TOOLS` | `--disallowedTools` value — hard-removes specific MCP tools even when the connector stays on | unset |

### Gmail send-blocking (required one-time step)

`JOBFINDEROS_DISALLOWED_TOOLS` is what actually stops a coach-family run from sending, forwarding, replying, or drafting via Gmail — CLAUDE.md's "never send" is doctrine the model follows, not something the CLI enforces on its own. To close the gap:

1. In an interactive `claude` session with the Gmail connector active, run `/mcp` and note the exact tool names for send, reply, forward, create-draft, and trash/delete actions (they'll look like `mcp__<connector>__<tool>`).
2. Set `JOBFINDEROS_DISALLOWED_TOOLS` to that comma-separated list, e.g. in the launchd plist for whichever job runs `jobs-daily` / `jobs-email`, or as a shell export before a manual run.
3. Re-run `bash scripts/JobFinderOS_check_local_runner.sh` or a manual `jobs-email` run and confirm in the transcript that Gmail read tools still work and the blocked names don't appear as available.
4. If your connector supports scoping the underlying OAuth grant itself (e.g. a read-only Gmail scope instead of full access), do that too — it's the stronger control, enforced by Google rather than by a CLI flag.

## Windows

Everything above (scheduled jobs, the tool-boundary model, Gmail send-blocking, manual commands) is the same code path on Windows as on macOS — `scheduler_tick.py` and `JobFinderOS_run_skill.sh` both run under Git Bash. Three things differ:

1. **Git Bash is required** for the `.sh` scripts and for anything `scheduler_tick.py` shells out to. Install Git for Windows if you don't have it; `bash` needs to resolve on `PATH`.
2. **The venv layout is `.venv\Scripts\`, not `.venv\bin\`.** `uv venv && uv pip install -r requirements.txt` (see the README) creates it in the right place automatically; `requirements.txt` also pulls in `tzdata`, which Windows needs for `zoneinfo` to resolve an explicit `timezone:` in `scheduler.yaml` (macOS/Linux already have the IANA database on the system, so this is a no-op there).
3. **The scheduler is Task Scheduler, not launchd.** Install or refresh:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\JobFinderOS_install_task_scheduler.ps1
   # or with explicit windows, matching the launchd installer's env vars:
   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\JobFinderOS_install_task_scheduler.ps1 -DailyHour 7 -WeeklyWeekday 1 -WeeklyHour 8 -WatchHour 9 -TimeZone "America/New_York"
   ```

   This regenerates `config/scheduler.yaml` (same schema either installer writes) and registers one Scheduled Task, **"JobFinderOS Scheduler,"** that fires `JobFinderOS_task_scheduler_launcher.ps1 → scheduler_tick.py` every `-IntervalSeconds` (default 1800, matching launchd's `StartInterval`). All due-window logic lives in `scheduler_tick.py` itself, so the task's only job is the tick — same division of labor as the Mac path.

   - Re-run the same command any time to refresh (it overwrites the existing task and config).
   - `-Uninstall` removes the task; `config/scheduler.yaml` is left alone.
   - `Start-ScheduledTask -TaskName "JobFinderOS Scheduler"` fires one tick on demand, without waiting for the interval.
   - Runs only while you're logged on (`-StartWhenAvailable` catches up a missed tick at your next logon rather than needing a separate logon trigger — registering one needs elevation on some Windows builds and isn't worth it for that).
   - This task starts nothing by itself the moment you install it beyond registering the schedule — it fires on its own cadence from then on. If you'd rather trigger runs by hand for now, skip this installer entirely and use the **Manual commands** below; nothing else in this runbook requires the scheduled task to exist.
   - Logs: `logs\task-scheduler.log` (the task's own stdout/stderr, since Task Scheduler has no `StandardOutPath` equivalent) and `logs\launchd-runs.log` (same file `scheduler_tick.py` writes on macOS — the name is legacy, the content isn't launchd-specific).

   **Known gaps on Windows, not fixed by this installer:**
   - **Clipboard drafting.** `coach`'s drafting skills (`/draft-message`, `/voice-check`) are instructed to use `pbcopy`/`pbpaste`, which don't exist on Windows. These are interactive, human-in-the-loop skills, never run unattended, so nothing breaks silently — but as written the agent needs to improvise a Windows clipboard command (`clip`, or PowerShell `Set-Clipboard`/`Get-Clipboard`) itself when you run one of these skills here.
   - **Desktop notifications.** `jobfinderos_ats_poll.py`'s notify-on-new-match feature shells out to `osascript` and is macOS-only. It fails soft (logs a `WARN`, doesn't break the poll) — you just won't get a toast on a new match on Windows.

## Manual commands

```bash
bash scripts/JobFinderOS_check_local_runner.sh
bash scripts/JobFinderOS_run_skill.sh jobs-daily jobs-daily
python scripts/scheduler_tick.py --dry-run   # python3 on macOS/Linux, python on Windows
python scripts/scheduler_tick.py
bash scripts/verify_local_automation.sh
bash scripts/JobFinderOS_test_launchd.sh     # macOS only (launchd-specific)
python scripts/jobfinderos_priority_watch.py     # standalone guard; JSON on stdout
python scripts/jobfinderos_ats_poll.py --dry-run
```

## Failure triage

| Symptom | Check |
|---------|-------|
| No digest on disk | `tail logs/launchd-runs.log`; run the skill manually |
| `claude: command not found` | Install Claude Code CLI; set `CLAUDE_BIN` |
| Auth errors | `claude auth login` |
| Guard always `skip` | Window not reached, weekend, or marker already set; see the JSON `reason` |
| Stuck lock | Remove `logs/scheduler-cron/*.lock` if no claude process is running |
| launchd `Operation not permitted` (macOS) | The repo is under `~/Documents`/`Desktop`/`Downloads`. Move it (e.g. `~/Developer/`) or grant Full Disk Access to the venv Python |
| `Register-ScheduledTask: Access is denied` (Windows) | You (or a past edit) added an explicit `-Principal`. The installer deliberately omits one — verified empirically that specifying one, even for your own account, requires an elevated (admin) session on some Windows builds. Don't run the installer as Administrator to work around this; just don't pass `-Principal` |
| Session limit from the CLI | Wait for the reset; the tick logs `failed (exit 1)` without updating markers |

## Backup (optional, by hand)

Automation never pushes to a remote by default. `jobfinderos_prune_history.py` commits its own deletions locally (so `git show` still recovers a pruned file) but only pushes with an explicit `--push`; `jobfinderos_ats_poll.py` is the same, opt-in via `--push`. The vault is gitignored in this repo. If you want it backed up, keep it in a **private** repository of your own and push by hand, or pass `--push` deliberately once you've set that remote up.

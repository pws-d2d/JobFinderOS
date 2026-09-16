#!/usr/bin/env bash
# Run a Claude Code skill locally (subscription auth). Writes to local vault/ only.
# Usage: JobFinderOS_run_skill.sh <log-label> <skill-name>
# Example: JobFinderOS_run_skill.sh jobs-daily jobs-daily
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
mkdir -p "$ROOT/logs"

LABEL="${1:?log label required (e.g. jobs-daily)}"
SKILL="${2:?skill name required (e.g. jobs-daily)}"
CMD_FILE="$ROOT/.claude/commands/${SKILL}.md"
if [[ ! -f "$CMD_FILE" ]]; then
  echo "JobFinderOS_run_skill: missing skill file: $CMD_FILE" >&2
  exit 2
fi

CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || true)}"
if [[ -z "$CLAUDE_BIN" || ! -x "$CLAUDE_BIN" ]]; then
  echo "JobFinderOS_run_skill: claude CLI not found (set CLAUDE_BIN)" >&2
  exit 127
fi

TIMEOUT_SEC="${JOBFINDEROS_SKILL_TIMEOUT_SEC:-1800}"

# --- tool profile -----------------------------------------------------------
# No unattended skill ever gets --dangerously-skip-permissions: an unattended
# run has no one at the keyboard to catch a scraped careers page, a search
# result, or an inbound email steering the agent somewhere it shouldn't go.
# Instead we build a hard tool boundary per skill:
#   --tools           removes tools from the model's toolset entirely (verified:
#                      unlike --allowedTools under normal permission modes, this
#                      is not just a prompt gate a "safe-looking" call can slip
#                      past — the tool is simply not offered)
#   --strict-mcp-config (no --mcp-config)  strips every MCP connector, so a
#                      scan run can't reach Gmail, Drive, Canva, or anything
#                      else on the account beyond what --mcp-config names
#   --disallowedTools  same hard removal, used to name specific MCP tools
#                      (e.g. a Gmail send/create_draft/trash tool) that must
#                      stay unavailable even on a profile that keeps its MCP
#                      connector for reading
# Bash is never in the default toolset for a scheduled skill: none of the
# scheduled skills (jobs-scout, jobs-priority-watch, mark-pulse, mark-weekly,
# jobs-daily's own top-level steps) call it, and it's the single biggest
# unattended-injection lever (arbitrary command execution vs. "just" a bad
# vault note), so it is opt-in only via JOBFINDEROS_SKILL_ALLOWED_TOOLS.
BASE_TOOLS="Agent,Read,Write,Edit,Glob,Grep,WebFetch,WebSearch"
case "$SKILL" in
  jobs-scout|jobs-priority-watch|mark-pulse|mark-weekly|mark-profiler|jobs-research|title-audit)
    # scout/mark family: no Gmail, no other MCP connector needed at all.
    DEFAULT_STRICT_MCP=1
    ;;
  jobs-daily|jobs-email|jobs-digest|email-watch|checkin)
    # coach-touching family: jobs-daily delegates its email leg to coach, which
    # needs the Gmail MCP connector. We can't strip MCP wholesale here without
    # knowing the account's connector config, so this profile is only as safe
    # as JOBFINDEROS_DISALLOWED_TOOLS below — see the runbook's "Gmail
    # send-blocking" setup step, which is a required one-time step, not optional.
    DEFAULT_STRICT_MCP=0
    ;;
  *)
    # Unrecognized skill (manual/ad-hoc run): fail closed, same as scout/mark.
    DEFAULT_STRICT_MCP=1
    ;;
esac

ALLOWED_TOOLS="${JOBFINDEROS_SKILL_ALLOWED_TOOLS:-$BASE_TOOLS}"
STRICT_MCP="${JOBFINDEROS_SKILL_STRICT_MCP:-$DEFAULT_STRICT_MCP}"
# Placeholder: fill in once you've confirmed the exact Gmail MCP tool names for
# your connector (e.g. via `/mcp` in an interactive session). Until this is
# set, "never send" for coach/jobs-email rests entirely on the agent's own
# instructions in .claude/agents/coach.md — treat that as unenforced.
DISALLOWED_TOOLS="${JOBFINDEROS_DISALLOWED_TOOLS:-}"

CLAUDE_ARGS=(-p "/${SKILL}" --tools "$ALLOWED_TOOLS" --permission-mode acceptEdits --permission-prompts none)
if [[ "$STRICT_MCP" == "1" ]]; then
  CLAUDE_ARGS+=(--strict-mcp-config)
fi
if [[ -n "$DISALLOWED_TOOLS" ]]; then
  CLAUDE_ARGS+=(--disallowedTools "$DISALLOWED_TOOLS")
fi

export PATH="${HOME}/.local/bin:${PATH}"

if [[ "$STRICT_MCP" != "1" && -z "$DISALLOWED_TOOLS" ]]; then
  "$ROOT/scripts/JobFinderOS_log_run.sh" "$LABEL" \
    "WARNING: Gmail send-blocking not configured (JOBFINDEROS_DISALLOWED_TOOLS unset) — see runbook 'Unattended tool boundaries'"
fi

"$ROOT/scripts/JobFinderOS_log_run.sh" "$LABEL" start
set +e
# MSYS_NO_PATHCONV is scoped to just this command: Git Bash/MSYS rewrites a
# bare leading-slash arg like "/jobs-scout" into a Windows path before claude
# ever sees it, but the fix-backslash-paths call below is a real POSIX path
# being passed to a native python.exe, which *needs* that same conversion —
# exporting the var for the whole script broke that call. No-op on real
# POSIX systems (no MSYS there).
if command -v timeout >/dev/null 2>&1; then
  MSYS_NO_PATHCONV=1 timeout "$TIMEOUT_SEC" "$CLAUDE_BIN" "${CLAUDE_ARGS[@]}" < /dev/null
  ec=$?
  if [[ "$ec" -eq 124 ]]; then
    "$ROOT/scripts/JobFinderOS_log_run.sh" "$LABEL" "failed (timeout ${TIMEOUT_SEC}s)"
    exit "$ec"
  fi
else
  MSYS_NO_PATHCONV=1 "$CLAUDE_BIN" "${CLAUDE_ARGS[@]}" < /dev/null
  ec=$?
fi
set -e

if [[ "$ec" -eq 0 ]]; then
  "$ROOT/scripts/JobFinderOS_log_run.sh" "$LABEL" completed
  # venv layout differs by platform: POSIX puts the interpreter in bin/,
  # Windows (including a uv venv run under Git Bash) puts it in Scripts/.
  PY="${ROOT}/.venv/bin/python"
  [[ -x "$PY" ]] || PY="${ROOT}/.venv/Scripts/python.exe"
  [[ -x "$PY" ]] || PY="$(command -v python3 || command -v python || true)"
  # Repair any literal-backslash vault paths a skill run may have written
  "$PY" "$ROOT/scripts/jobfinderos_fix_backslash_paths.py" || true
else
  "$ROOT/scripts/JobFinderOS_log_run.sh" "$LABEL" "failed (exit $ec)"
  exit "$ec"
fi

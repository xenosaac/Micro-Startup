#!/bin/zsh

emulate -LR zsh
setopt pipefail nounset

SCRIPT_DIR="${0:A:h}"
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<EOF
Usage: ${0:t} <init|doctor|start|stop|restart|status|logs|attach>
       ${0:t} role <add|remove|list> [...]
EOF
}

doctor_error() {
  local message="$1"
  local fix="$2"
  print -r -- "doctor: ${message}"
  print -r -- "fix: ${fix}"
  return 1
}

doctor_ok() {
  print -r -- "doctor: $1"
}

tmux_has_session() {
  tmux has-session -t "${SESSION_NAME}" 2>/dev/null
}

start_window() {
  local window_name="$1"
  local command="$2"
  tmux new-window -d -t "${SESSION_NAME}" -n "${window_name}" /bin/zsh -lc "${command}" >/dev/null
}

role_loop_command() {
  local role_id="$1"
  local success_sleep="$2"
  local fail_sleep="$3"
  print -r -- "export HOME='${HOME}' PATH='${PATH}'; caffeinate -i /bin/zsh -lc 'cd ${INTERNAL_ROOT} && while true; do ${SCRIPT_DIR}/role_once.sh ${role_id} >> ${ROLE_LOG_FILE} 2>&1; rc=\$?; if [ \$rc -eq 0 ]; then sleep ${success_sleep}; else sleep ${fail_sleep}; fi; done'"
}

run_doctor_checks() {
  bootstrap_repo
  load_crew_env

  if [[ "$(/usr/bin/uname -s)" != "Darwin" ]]; then
    doctor_error "Micro Startup currently supports macOS only." "Run it on macOS."
    return 1
  fi
  doctor_ok "macOS detected."

  if ! command -v tmux >/dev/null 2>&1; then
    doctor_error "tmux is not installed." "brew install tmux"
    return 1
  fi
  doctor_ok "tmux is available."

  if ! command -v caffeinate >/dev/null 2>&1; then
    doctor_error "caffeinate is not available." "Use macOS with the standard caffeinate binary."
    return 1
  fi
  doctor_ok "caffeinate is available."

  local resolved_claude_bin
  resolved_claude_bin="$(resolve_claude_bin 2>/dev/null || true)"
  if [[ -z "${resolved_claude_bin}" ]]; then
    doctor_error "Claude CLI was not found at ${CLAUDE_BIN}." "Install Claude Code CLI or set CLAUDE_BIN in .micro-startup/config.env."
    return 1
  fi
  doctor_ok "Claude CLI found at ${resolved_claude_bin}."

  if ! "${resolved_claude_bin}" auth status >/dev/null 2>&1; then
    doctor_error "Claude CLI auth check failed." "Run '${resolved_claude_bin} auth login' and try again."
    return 1
  fi

  if ! "${resolved_claude_bin}" auth status | grep -q '"loggedIn":[[:space:]]*true'; then
    doctor_error "Claude CLI is not logged in." "Run '${resolved_claude_bin} auth login' and try again."
    return 1
  fi
  doctor_ok "Claude CLI is authenticated."

  if [[ ! -w "${TARGET_REPO}" ]]; then
    doctor_error "Repo root is not writable: ${TARGET_REPO}" "Fix filesystem permissions for the repo root."
    return 1
  fi
  doctor_ok "Repo root is writable."

  if [[ ! -f "${DOC_TEMPLATE_DIR}/backlog.md" || ! -d "${ROLE_PROMPT_TEMPLATE_DIR}" || ! -d "${ROLE_DOC_TEMPLATE_DIR}" ]]; then
    doctor_error "Crew templates are missing from .micro-startup/templates." "Reinstall Micro Startup in this repo."
    return 1
  fi
  doctor_ok "Crew templates are present."

  if ! validate_all_roles >/tmp/micro-startup-role-check.$$ 2>&1; then
    doctor_error "$(cat /tmp/micro-startup-role-check.$$)" "Fix the role files under .micro-startup/roles and rerun doctor."
    rm -f /tmp/micro-startup-role-check.$$
    return 1
  fi
  rm -f /tmp/micro-startup-role-check.$$
  doctor_ok "Role schema is valid."

  if ! validate_backlog_file; then
    doctor_error "backlog.md contains an invalid task line." "Use '- TASK-001 | target=... | priority=P1 | title=...'."
    return 1
  fi
  doctor_ok "Backlog format is valid."

  if ! git -C "${TARGET_REPO}" rev-parse --verify "${BASE_BRANCH}" >/dev/null 2>&1; then
    doctor_error "BASE_BRANCH does not exist: ${BASE_BRANCH}" "Set a valid BASE_BRANCH in .micro-startup/crew.env."
    return 1
  fi
  doctor_ok "BASE_BRANCH exists: ${BASE_BRANCH}."

  if [[ ! -w "${WORKTREE_DIR}" ]]; then
    doctor_error "Writer worktree directory is not writable." "Fix permissions on ${WORKTREE_DIR}."
    return 1
  fi
  doctor_ok "Writer worktree directory is writable."

  if target_has_blocking_dirty_tree; then
    doctor_ok "Product worktree is dirty. Writers will continue unfinished work."
  else
    doctor_ok "Product worktree is clean."
  fi

  return 0
}

cmd_init() {
  bootstrap_repo
  print -r -- "Initialized Micro Startup in ${TARGET_REPO}"
  print -r -- "Crew file: .micro-startup/crew.env"
  print -r -- "Backlog: .micro-startup/docs/backlog.md"
  print -r -- "Roles:"
  role_list
}

cmd_doctor() {
  run_doctor_checks
}

cmd_start() {
  local role_id
  local first_role=""

  if ! run_doctor_checks; then
    return 1
  fi

  ensure_base_branch || return 1

  while IFS= read -r role_id; do
    [[ -n "${role_id}" ]] || continue
    load_role "${role_id}" || continue
    if [[ "${ROLE_MODE}" == "writer" ]]; then
      ensure_writer_worktree "${role_id}" || return 1
    fi
  done < <(active_role_ids)

  if tmux_has_session; then
    print -r -- "Crew session already running: ${SESSION_NAME}"
    print -r -- "Attach: ./micro-startup attach"
    return 0
  fi

  while IFS= read -r role_id; do
    [[ -n "${role_id}" ]] || continue
    load_role "${role_id}" || continue
    : > "${ROLE_LOG_FILE}"
    if [[ -z "${first_role}" ]]; then
      first_role="${role_id}"
      tmux new-session -d -s "${SESSION_NAME}" -n "${role_id}" /bin/zsh -lc "$(role_loop_command "${role_id}" "${SUCCESS_SLEEP}" "${FAIL_SLEEP}")" >/dev/null || {
        print -r -- "Failed to create tmux session: ${SESSION_NAME}"
        return 1
      }
    else
      start_window "${role_id}" "$(role_loop_command "${role_id}" "${SUCCESS_SLEEP}" "${FAIL_SLEEP}")"
    fi
  done < <(active_role_ids)

  if [[ -n "${first_role}" ]]; then
    tmux select-window -t "${SESSION_NAME}:${first_role}" >/dev/null 2>&1 || true
  fi

  print -r -- "Started crew session: ${SESSION_NAME}"
  print -r -- "Attach: ./micro-startup attach"
  print -r -- "Logs: ./micro-startup logs"
}

cmd_stop() {
  if tmux_has_session; then
    tmux kill-session -t "${SESSION_NAME}"
    print -r -- "Stopped crew tmux session: ${SESSION_NAME}"
  else
    print -r -- "Crew is not running"
  fi
}

cmd_restart() {
  cmd_stop
  cmd_start
}

cmd_status() {
  local role_id
  bootstrap_repo
  load_crew_env

  print -r -- "Session: ${SESSION_NAME}"
  print -r -- "Target repo: ${TARGET_REPO}"
  print -r -- "Internal root: ${INTERNAL_ROOT}"
  print -r -- "BASE_BRANCH: ${BASE_BRANCH}"
  print -r -- "Current branch: $(current_branch)"
  if target_has_blocking_dirty_tree; then
    print -r -- "Worktree: dirty (product files)"
  else
    print -r -- "Worktree: clean (product files)"
  fi

  if tmux_has_session; then
    print -r -- "tmux: running"
    tmux list-windows -t "${SESSION_NAME}" -F "${SESSION_NAME}:#I #W (active=#{window_active})"
  else
    print -r -- "tmux: not running"
  fi

  print -r -- "Roles:"
  while IFS= read -r role_id; do
    [[ -n "${role_id}" ]] || continue
    load_role "${role_id}" || continue
    if [[ "${ROLE_MODE}" == "writer" ]]; then
      print -r -- "- ${role_id}: ${ROLE_ARCHETYPE} | ${DOC_FILE} | ${ROLE_BRANCH} | ${ROLE_WORKTREE}"
    else
      print -r -- "- ${role_id}: ${ROLE_ARCHETYPE} | ${DOC_FILE}"
    fi
  done < <(active_role_ids)

  print -r -- "Logs:"
  while IFS= read -r role_id; do
    [[ -n "${role_id}" ]] || continue
    print -r -- "- ${role_id}: $(role_log_file "${role_id}")"
  done < <(active_role_ids)
}

cmd_logs() {
  local role_id
  local -a log_files=()

  while IFS= read -r role_id; do
    [[ -n "${role_id}" ]] || continue
    touch "$(role_log_file "${role_id}")"
    log_files+=("$(role_log_file "${role_id}")")
  done < <(active_role_ids)

  if (( ${#log_files[@]} == 0 )); then
    print -r -- "No role logs found"
    return 1
  fi

  tail -n 120 -f "${log_files[@]}"
}

cmd_attach() {
  if ! tmux_has_session; then
    print -r -- "Crew session is not running"
    return 1
  fi
  exec tmux attach -t "${SESSION_NAME}"
}

cmd_role_add() {
  local role_id="${1:-}"
  local archetype="advisor"

  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --archetype)
        archetype="${2:-}"
        shift 2
        ;;
      *)
        print -r -- "Unknown role add option: $1"
        return 1
        ;;
    esac
  done

  if [[ -z "${role_id}" ]]; then
    print -r -- "Usage: ./micro-startup role add <id> --archetype <writer|planner|advisor|reviewer>"
    return 1
  fi

  role_add "${role_id}" "${archetype}" || return 1
  print -r -- "Restart the crew session to launch the new role."
}

cmd_role_remove() {
  local role_id="${1:-}"
  if [[ -z "${role_id}" ]]; then
    print -r -- "Usage: ./micro-startup role remove <id>"
    return 1
  fi

  role_remove "${role_id}" || return 1
  print -r -- "Restart the crew session to apply the removal."
}

cmd_role_list() {
  bootstrap_repo
  role_list
}

case "${1:-}" in
  init)
    cmd_init
    ;;
  doctor)
    cmd_doctor
    ;;
  start)
    cmd_start
    ;;
  stop)
    cmd_stop
    ;;
  restart)
    cmd_restart
    ;;
  status)
    cmd_status
    ;;
  logs|tail)
    cmd_logs
    ;;
  attach)
    cmd_attach
    ;;
  role)
    case "${2:-}" in
      add)
        shift 2
        cmd_role_add "$@"
        ;;
      remove)
        shift 2
        cmd_role_remove "$@"
        ;;
      list)
        cmd_role_list
        ;;
      *)
        usage
        exit 1
        ;;
    esac
    ;;
  *)
    usage
    exit 1
    ;;
esac

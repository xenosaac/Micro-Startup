#!/bin/zsh

emulate -LR zsh
setopt pipefail nounset

SCRIPT_DIR="${0:A:h}"
source "${SCRIPT_DIR}/common.sh"

ROLE_ID_ARG="${1:-}"
if [[ -z "${ROLE_ID_ARG}" ]]; then
  print -r -- "role_once.sh requires a role id"
  exit 1
fi

HELD_MAINREPO_LOCK=0
HELD_BACKLOG_LOCK=0
TMP_OUTPUT_FILE=""

cleanup() {
  if (( HELD_BACKLOG_LOCK )); then
    release_lock backlog
  fi
  if (( HELD_MAINREPO_LOCK )); then
    release_lock mainrepo
  fi
}

discard_tmp_output() {
  if [[ -n "${TMP_OUTPUT_FILE}" ]]; then
    rm -f "${TMP_OUTPUT_FILE}" 2>/dev/null || true
    TMP_OUTPUT_FILE=""
  fi
}

trap cleanup EXIT INT TERM HUP

bootstrap_repo
load_crew_env
load_role "${ROLE_ID_ARG}" || {
  print -r -- "unknown role: ${ROLE_ID_ARG}"
  exit 1
}

log() {
  log_line "${ROLE_ID_ARG}" "$@"
}

normalize_dirty_path() {
  local line="$1"
  local repo_path="${line#?? }"
  if [[ "${repo_path}" == *" -> "* ]]; then
    repo_path="${repo_path##* -> }"
  fi
  print -r -- "${repo_path}"
}

path_in_newline_list() {
  local candidate_path="$1"
  local list="$2"
  [[ -z "${list}" ]] && return 1
  while IFS= read -r existing; do
    [[ -z "${existing}" ]] && continue
    if [[ "${existing}" == "${candidate_path}" ]]; then
      return 0
    fi
  done <<< "${list}"
  return 1
}

capture_dirty_path_list() {
  local line
  local out=""
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    out+="$(normalize_dirty_path "${line}")"$'\n'
  done <<< "$(repo_dirty_paths "${TARGET_REPO}")"
  print -rn -- "${out}"
}

unexpected_new_dirty_path() {
  local baseline="$1"
  shift
  local allowed_path
  local line
  local repo_path

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    repo_path="$(normalize_dirty_path "${line}")"
    if path_in_newline_list "${repo_path}" "${baseline}"; then
      continue
    fi

    for allowed_path in "$@"; do
      if [[ "${repo_path}" == "${allowed_path}" ]]; then
        continue 2
      fi
    done

    print -r -- "${repo_path}"
    return 0
  done <<< "$(repo_dirty_paths "${TARGET_REPO}")"

  return 1
}

begin_iteration_session() {
  local now_utc
  local session_id
  local created_at=""

  now_utc="$(utc_now)"
  session_id="$(new_uuid)"
  created_at="$(state_read "${ROLE_SESSION_FILE}" CREATED_AT)"
  if [[ -z "${created_at}" ]]; then
    created_at="${now_utc}"
  fi

  write_state_file "${ROLE_SESSION_FILE}" \
    SESSION_ID "${session_id}" \
    CREATED_AT "${created_at}" \
    LAST_RUN_AT "${now_utc}" \
    TASK_ID "${CURRENT_TASK_ID:-}"
}

run_claude() {
  local cwd="$1"
  local output_file="$2"
  local iteration_prompt="$3"
  local prompt_text
  local claude_bin

  prompt_text="$(<"${ROLE_PROMPT_PATH}")"
  claude_bin="$(resolve_claude_bin 2>/dev/null || true)"
  if [[ -z "${claude_bin}" ]]; then
    log "Claude CLI is unavailable at ${CLAUDE_BIN}"
    return 1
  fi

  (
    cd "${cwd}"
    "${claude_bin}" -p \
      --model "${CLAUDE_MODEL}" \
      --dangerously-skip-permissions \
      --append-system-prompt "${prompt_text}" \
      --session-id "$(state_read "${ROLE_SESSION_FILE}" SESSION_ID)" \
      "${iteration_prompt}" >"${output_file}" 2>&1
  )
}

build_writer_prompt() {
  local tree_state="$1"
  cat <<EOF
Run exactly one unattended ${ROLE_NAME} writer iteration in the isolated worktree.

Target repository root: ${TARGET_REPO}
Current worktree: ${ROLE_WORKTREE}
Assigned task id: ${CURRENT_TASK_ID}
Task source: ${CURRENT_TASK_SOURCE}
Task title: ${CURRENT_TASK_TITLE}
Task detail: ${CURRENT_TASK_DETAIL}
Backlog file: .micro-startup/docs/backlog.md
Your writable role document: ${DOC_FILE}
Worktree status at start: ${tree_state}
Writer branch: ${ROLE_BRANCH}

Workflow:
1. Read ${DOC_FILE} and .micro-startup/docs/backlog.md in full before making changes.
2. Inspect the code and the current git status in your isolated worktree.
3. Continue the currently assigned task only. Do not switch tasks.
4. You may edit tracked product code and ${DOC_FILE}.
5. Do not edit backlog.md or other roles' documents.
6. Before coding, update ${DOC_FILE} with your understanding and plan.
7. Implement one smallest useful increment for the assigned task.
8. Run the relevant verification commands yourself.
9. On success, update ${DOC_FILE}, create exactly one local commit, and leave the worktree clean.
10. On failure or blocker, update ${DOC_FILE} and leave the worktree dirty so the next iteration can continue.
11. Do not ask the user questions. Do not spawn sub-agents. Do not push, pull, or rebase.

Respond with a short human-readable summary only.
EOF
}

build_planner_prompt() {
  cat <<EOF
Run exactly one unattended ${ROLE_NAME} planner iteration in the target repository.

Target repository: ${TARGET_REPO}
Primary writable role document: ${DOC_FILE}
Shared writable backlog: .micro-startup/docs/backlog.md

Workflow:
1. Read ${DOC_FILE}, .micro-startup/docs/backlog.md, and other role documents as needed.
2. Inspect the repo only as needed to understand current product reality.
3. Improve priorities, user needs, acceptance criteria, and backlog task quality.
4. Update only ${DOC_FILE} and .micro-startup/docs/backlog.md.
5. Do not edit product source code or any other tracked file.

Respond with a short human-readable summary only.
EOF
}

build_advisor_prompt() {
  cat <<EOF
Run exactly one unattended ${ROLE_NAME} ${ROLE_ARCHETYPE} iteration in the target repository.

Target repository: ${TARGET_REPO}
Primary writable role document: ${DOC_FILE}
Shared read-only backlog: .micro-startup/docs/backlog.md

Workflow:
1. Read ${DOC_FILE}, .micro-startup/docs/backlog.md, and other role documents as needed.
2. Inspect the repo only as needed for your specialty.
3. Tighten guidance, findings, or recommendations for the crew.
4. Update only ${DOC_FILE}.
5. Do not edit product source code, backlog.md, or other tracked files.

Respond with a short human-readable summary only.
EOF
}

run_nonwriter_iteration() {
  local baseline_dirty
  local iteration_prompt
  local tmp_output
  local unexpected_path
  local -a allowed_paths

  if writer_pipeline_has_work; then
    log "writer pipeline is active; skipping ${ROLE_ARCHETYPE} iteration"
    exit 0
  fi

  if target_has_blocking_dirty_tree; then
    log "product worktree is dirty; skipping ${ROLE_ARCHETYPE} iteration until writers repair it"
    exit 0
  fi

  if ! acquire_lock mainrepo 120; then
    log "could not acquire mainrepo lock"
    exit 1
  fi
  HELD_MAINREPO_LOCK=1

  if (( ROLE_CAN_EDIT_BACKLOG )); then
    if ! acquire_lock backlog 120; then
      log "could not acquire backlog lock"
      exit 1
    fi
    HELD_BACKLOG_LOCK=1
  fi

  baseline_dirty="$(capture_dirty_path_list)"
  begin_iteration_session

  if (( ROLE_CAN_EDIT_BACKLOG )); then
    iteration_prompt="$(build_planner_prompt)"
    allowed_paths=("${DOC_FILE}" ".micro-startup/docs/backlog.md")
  else
    iteration_prompt="$(build_advisor_prompt)"
    allowed_paths=("${DOC_FILE}")
  fi

  tmp_output="$(mktemp -t micro-startup-role-XXXXXX)"
  TMP_OUTPUT_FILE="${tmp_output}"
  trap cleanup EXIT INT TERM HUP

  if ! run_claude "${TARGET_REPO}" "${tmp_output}" "${iteration_prompt}"; then
    cat "${tmp_output}"
    discard_tmp_output
    log "${ROLE_ARCHETYPE} iteration failed"
    exit 1
  fi

  cat "${tmp_output}"
  discard_tmp_output

  unexpected_path="$(unexpected_new_dirty_path "${baseline_dirty}" "${allowed_paths[@]}" || true)"
  if [[ -n "${unexpected_path}" ]]; then
    log "${ROLE_ARCHETYPE} iteration modified an unexpected file: ${unexpected_path}"
    exit 1
  fi

  log "${ROLE_ARCHETYPE} iteration completed"
}

run_writer_iteration() {
  local head_before
  local head_after
  local tree_state="clean"
  local iteration_prompt
  local tmp_output
  local current_status

  ensure_writer_worktree "${ROLE_ID_ARG}"
  if ! claim_or_resume_task "${ROLE_ID_ARG}" "${ROLE_LABELS}"; then
    log "no matching task available"
    exit 0
  fi

  if repo_has_meaningful_dirty_tree "${ROLE_WORKTREE}"; then
    tree_state="dirty"
  fi

  begin_iteration_session
  head_before="$(git -C "${ROLE_WORKTREE}" rev-parse HEAD)"
  set_task_status "${CURRENT_TASK_ID}" "running" "${ROLE_ID_ARG}" "${CURRENT_TASK_DETAIL}"

  iteration_prompt="$(build_writer_prompt "${tree_state}")"
  tmp_output="$(mktemp -t micro-startup-writer-XXXXXX)"
  TMP_OUTPUT_FILE="${tmp_output}"
  trap cleanup EXIT INT TERM HUP

  if ! run_claude "${ROLE_WORKTREE}" "${tmp_output}" "${iteration_prompt}"; then
    cat "${tmp_output}"
    discard_tmp_output
    if repo_has_meaningful_dirty_tree "${ROLE_WORKTREE}"; then
      set_task_status "${CURRENT_TASK_ID}" "running" "${ROLE_ID_ARG}" "continuing unfinished work"
      log "writer iteration failed but worktree remains dirty; task stays claimed"
      exit 1
    fi

    set_task_status "${CURRENT_TASK_ID}" "failed" "${ROLE_ID_ARG}" "writer iteration failed before commit"
    clear_claim "${CURRENT_TASK_ID}"
    log "writer iteration failed"
    exit 1
  fi

  cat "${tmp_output}"
  discard_tmp_output

  if repo_has_meaningful_dirty_tree "${ROLE_WORKTREE}"; then
    set_task_status "${CURRENT_TASK_ID}" "running" "${ROLE_ID_ARG}" "unfinished task still dirty"
    log "writer finished but worktree is still dirty; task stays claimed"
    exit 1
  fi

  head_after="$(git -C "${ROLE_WORKTREE}" rev-parse HEAD)"
  if [[ "${head_before}" == "${head_after}" ]]; then
    set_task_status "${CURRENT_TASK_ID}" "failed" "${ROLE_ID_ARG}" "no new local commit was created"
    clear_claim "${CURRENT_TASK_ID}"
    log "writer finished without creating a new commit"
    exit 1
  fi

  set_task_status "${CURRENT_TASK_ID}" "verified" "${ROLE_ID_ARG}" "verified local commit ${head_after}"
  if merge_writer_commit "${ROLE_ID_ARG}" "${CURRENT_TASK_ID}" "${head_after}"; then
    log "writer iteration completed and merged"
    exit 0
  fi

  current_status="$(task_status "${CURRENT_TASK_ID}")"
  if [[ "${current_status}" == "repair-pending" ]]; then
    log "writer merge hit a conflict; repair task generated"
  else
    log "writer merge did not complete"
  fi
  exit 1
}

if [[ "${ROLE_MODE}" == "writer" ]]; then
  run_writer_iteration
else
  run_nonwriter_iteration
fi

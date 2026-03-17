#!/bin/zsh

emulate -LR zsh
setopt pipefail nounset

SCRIPT_DIR="${0:A:h}"
INTERNAL_ROOT="${SCRIPT_DIR:h}"
TARGET_REPO="${INTERNAL_ROOT:h}"

if ! git -C "${TARGET_REPO}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  print -r -- "Micro Startup must be installed inside a git repository."
  print -r -- "Current repo root candidate: ${TARGET_REPO}"
  exit 1
fi

TARGET_REPO="$(git -C "${TARGET_REPO}" rev-parse --show-toplevel)"

CONFIG_FILE="${INTERNAL_ROOT}/config.env"
CONFIG_EXAMPLE_FILE="${INTERNAL_ROOT}/config.env.example"
CREW_FILE="${INTERNAL_ROOT}/crew.env"
ROLE_DIR="${INTERNAL_ROOT}/roles"
PROMPT_DIR="${INTERNAL_ROOT}/prompts"
PROMPT_TEMPLATE_DIR="${INTERNAL_ROOT}/templates/prompts"
ROLE_PROMPT_TEMPLATE_DIR="${INTERNAL_ROOT}/templates/role-prompts"
DOCS_DIR="${INTERNAL_ROOT}/docs"
DOC_TEMPLATE_DIR="${INTERNAL_ROOT}/templates/repo-docs"
ROLE_DOC_TEMPLATE_DIR="${INTERNAL_ROOT}/templates/role-docs"
BACKLOG_FILE="${DOCS_DIR}/backlog.md"
LOG_DIR="${INTERNAL_ROOT}/logs"
RUNTIME_DIR="${INTERNAL_ROOT}/runtime"
LOCK_DIR="${RUNTIME_DIR}/locks"
SESSION_DIR="${RUNTIME_DIR}/sessions"
WORKTREE_DIR="${INTERNAL_ROOT}/worktrees"
TASKS_STATE="${RUNTIME_DIR}/tasks.state"
CLAIMS_STATE="${RUNTIME_DIR}/claims.state"
MERGE_STATE="${RUNTIME_DIR}/merge.state"
LOCAL_GITIGNORE="${INTERNAL_ROOT}/.gitignore"

if [[ -f "${CONFIG_FILE}" ]]; then
  source "${CONFIG_FILE}"
fi

DEFAULT_CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
if [[ -z "${DEFAULT_CLAUDE_BIN}" ]]; then
  DEFAULT_CLAUDE_BIN="${HOME}/.local/bin/claude"
fi

CLAUDE_BIN="${CLAUDE_BIN:-${DEFAULT_CLAUDE_BIN}}"
CLAUDE_MODEL="${CLAUDE_MODEL:-opus}"
WRITER_BRANCH_PREFIX="${WRITER_BRANCH_PREFIX:-codex/micro-startup}"

default_session_name() {
  local repo_name="${TARGET_REPO:t:l}"
  repo_name="${repo_name//[^[:alnum:]_-]/-}"
  print -r -- "micro-startup-${repo_name}"
}

SESSION_NAME="${SESSION_NAME:-$(default_session_name)}"
ACTIVE_ROLES="${ACTIVE_ROLES:-}"
BASE_BRANCH="${BASE_BRANCH:-}"
DEFAULT_ACTIVE_ROLES="product design engineer"

timestamp() {
  /bin/date "+%Y-%m-%d %H:%M:%S"
}

utc_now() {
  /bin/date -u "+%Y-%m-%dT%H:%M:%SZ"
}

new_uuid() {
  uuidgen | tr "[:upper:]" "[:lower:]"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  print -r -- "${value}"
}

sanitize_state_field() {
  local value="$1"
  value="${value//$'\n'/ }"
  value="${value//|//}"
  print -r -- "${value}"
}

pretty_role_name() {
  local role_id="$1"
  local role_name="${role_id//[-_]/ }"
  local word
  local out=""
  for word in ${(z)role_name}; do
    out+="${word[1,1]:u}${word[2,-1]} "
  done
  out="$(trim "${out}")"
  print -r -- "${out}"
}

normalize_role_id() {
  local role_id="${1:l}"
  role_id="${role_id//[^[:alnum:]_-]/-}"
  role_id="${role_id##-}"
  role_id="${role_id%%-}"
  print -r -- "${role_id}"
}

log_line() {
  local role="$1"
  shift
  print -r -- "[$(timestamp)] [${role}] $*"
}

ensure_target_repo() {
  if ! git -C "${TARGET_REPO}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    print -r -- "Target repo is not available: ${TARGET_REPO}"
    exit 1
  fi
}

current_branch() {
  local repo="${1:-${TARGET_REPO}}"
  git -C "${repo}" branch --show-current
}

resolve_repo_path() {
  local input_path="$1"
  if [[ "${input_path}" == /* ]]; then
    print -r -- "${input_path}"
  else
    print -r -- "${TARGET_REPO}/${input_path}"
  fi
}

ensure_dir() {
  mkdir -p "$1"
}

ensure_state_file() {
  ensure_dir "${1:h}"
  [[ -f "$1" ]] || : > "$1"
}

save_lines_to_file() {
  local file="$1"
  shift
  local tmp_file
  tmp_file="$(mktemp "${TMPDIR:-/tmp}/micro-startup-save-XXXXXX")"
  printf "%s\n" "$@" > "${tmp_file}"
  mv "${tmp_file}" "${file}"
}

ensure_file_from_template() {
  local template_file="$1"
  local destination_file="$2"

  if [[ -f "${destination_file}" ]]; then
    return 0
  fi

  if [[ ! -f "${template_file}" ]]; then
    print -r -- "Missing template: ${template_file}"
    exit 1
  fi

  ensure_dir "${destination_file:h}"
  cp "${template_file}" "${destination_file}"
}

copy_if_missing() {
  local source_file="$1"
  local destination_file="$2"
  if [[ ! -f "${destination_file}" && -f "${source_file}" ]]; then
    ensure_dir "${destination_file:h}"
    cp "${source_file}" "${destination_file}"
  fi
}

ensure_local_gitignore() {
  if [[ -f "${LOCAL_GITIGNORE}" ]]; then
    return 0
  fi

  cat > "${LOCAL_GITIGNORE}" <<'EOF'
logs/
runtime/
worktrees/
config.env
EOF
}

repo_dirty_paths() {
  local repo="${1:-${TARGET_REPO}}"
  git -C "${repo}" status --porcelain
}

is_mainrepo_nonblocking_path() {
  local repo_path="$1"
  [[ "${repo_path}" == "micro-startup" || "${repo_path}" == .micro-startup/* ]]
}

is_runtime_only_path() {
  local repo_path="$1"
  [[ "${repo_path}" == .micro-startup/logs/* || "${repo_path}" == .micro-startup/runtime/* || "${repo_path}" == .micro-startup/worktrees/* || "${repo_path}" == .micro-startup/config.env ]]
}

first_dirty_path_for_policy() {
  local repo="$1"
  local policy="$2"
  local line
  local repo_path

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    repo_path="${line#?? }"
    if [[ "${repo_path}" == *" -> "* ]]; then
      repo_path="${repo_path##* -> }"
    fi

    case "${policy}" in
      main)
        if is_mainrepo_nonblocking_path "${repo_path}"; then
          continue
        fi
        ;;
      writer)
        if is_runtime_only_path "${repo_path}"; then
          continue
        fi
        ;;
      *)
        ;;
    esac

    print -r -- "${repo_path}"
    return 0
  done <<< "$(repo_dirty_paths "${repo}")"

  return 1
}

target_has_blocking_dirty_tree() {
  first_dirty_path_for_policy "${TARGET_REPO}" main >/dev/null
}

repo_has_meaningful_dirty_tree() {
  local repo="$1"
  first_dirty_path_for_policy "${repo}" writer >/dev/null
}

unexpected_dirty_paths() {
  local repo="${TARGET_REPO}"
  local line
  local repo_path
  local allowed
  local matched

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    repo_path="${line#?? }"
    if [[ "${repo_path}" == *" -> "* ]]; then
      repo_path="${repo_path##* -> }"
    fi

    matched=0
    for allowed in "$@"; do
      if [[ "${repo_path}" == "${allowed}" ]]; then
        matched=1
        break
      fi
    done

    if (( ! matched )); then
      print -r -- "${repo_path}"
      return 0
    fi
  done <<< "$(repo_dirty_paths "${repo}")"

  return 1
}

state_read() {
  local file="$1"
  local key="$2"

  if [[ ! -f "${file}" ]]; then
    return 0
  fi

  local value
  value="$(
    source "${file}"
    eval "print -rn -- \${${key}:-}"
  )"
  print -rn -- "${value}"
}

write_state_file() {
  local file="$1"
  shift

  ensure_dir "${file:h}"
  : > "${file}"
  while [[ $# -gt 1 ]]; do
    print -r -- "$1=$2" >> "${file}"
    shift 2
  done
}

upsert_record() {
  local file="$1"
  local key="$2"
  local record="$3"
  local tmp_file

  ensure_state_file "${file}"
  tmp_file="$(mktemp "${TMPDIR:-/tmp}/micro-startup-record-XXXXXX")"
  awk -F'|' -v key="${key}" -v record="${record}" '
    BEGIN {done = 0}
    $1 == key {
      if (!done) {
        print record
        done = 1
      }
      next
    }
    { print }
    END {
      if (!done) {
        print record
      }
    }
  ' "${file}" > "${tmp_file}"
  mv "${tmp_file}" "${file}"
}

remove_record() {
  local file="$1"
  local key="$2"
  local tmp_file

  ensure_state_file "${file}"
  tmp_file="$(mktemp "${TMPDIR:-/tmp}/micro-startup-record-XXXXXX")"
  awk -F'|' -v key="${key}" '$1 != key { print }' "${file}" > "${tmp_file}"
  mv "${tmp_file}" "${file}"
}

record_field() {
  local file="$1"
  local key="$2"
  local field="$3"

  ensure_state_file "${file}"
  awk -F'|' -v key="${key}" -v field="${field}" '
    $1 == key { value = $field }
    END { if (value != "") print value }
  ' "${file}"
}

claimed_task_for_role() {
  local role_id="$1"
  ensure_state_file "${CLAIMS_STATE}"
  awk -F'|' -v role_id="${role_id}" '
    $2 == role_id { task_id = $1 }
    END { if (task_id != "") print task_id }
  ' "${CLAIMS_STATE}"
}

claim_owner() {
  local task_id="$1"
  record_field "${CLAIMS_STATE}" "${task_id}" 2
}

set_claim() {
  local task_id="$1"
  local role_id="$2"
  upsert_record "${CLAIMS_STATE}" "${task_id}" "${task_id}|${role_id}|$(utc_now)"
}

clear_claim() {
  local task_id="$1"
  remove_record "${CLAIMS_STATE}" "${task_id}"
}

task_status() {
  local task_id="$1"
  record_field "${TASKS_STATE}" "${task_id}" 2
}

task_owner() {
  local task_id="$1"
  record_field "${TASKS_STATE}" "${task_id}" 3
}

task_detail() {
  local task_id="$1"
  record_field "${TASKS_STATE}" "${task_id}" 5
}

set_task_status() {
  local task_id="$1"
  local task_state="$2"
  local role_id="$3"
  local detail="${4:-}"
  detail="$(sanitize_state_field "${detail}")"
  upsert_record "${TASKS_STATE}" "${task_id}" "${task_id}|${task_state}|${role_id}|$(utc_now)|${detail}"
}

set_merge_state() {
  local task_id="$1"
  local role_id="$2"
  local commit_sha="$3"
  local merge_status="$4"
  local detail="${5:-}"
  detail="$(sanitize_state_field "${detail}")"
  upsert_record "${MERGE_STATE}" "${task_id}" "${task_id}|${role_id}|${commit_sha}|${merge_status}|$(utc_now)|${detail}"
}

task_is_terminal() {
  local task_state="$1"
  [[ "${task_state}" == "merged" || "${task_state}" == "failed" || "${task_state}" == "conflict" ]]
}

writer_pipeline_has_work() {
  (
    local role_id
    local line
    local task_state
    local task_owner

    ensure_state_file "${TASKS_STATE}"

    while IFS='|' read -r task_id task_state task_owner _; do
      [[ -n "${task_id}" ]] || continue
      case "${task_state}" in
        claimed|running|verified|repair-pending)
          if load_role "${task_owner}" >/dev/null 2>&1 && [[ "${ROLE_MODE}" == "writer" ]]; then
            return 0
          fi
          ;;
      esac
    done < "${TASKS_STATE}"

    while IFS= read -r line; do
      if ! parse_backlog_line "${line}"; then
        continue
      fi

      task_state="$(task_status "${TASK_ID}")"
      if task_is_terminal "${task_state}"; then
        continue
      fi

      while IFS= read -r role_id; do
        [[ -n "${role_id}" ]] || continue
        load_role "${role_id}" || continue
        [[ "${ROLE_MODE}" == "writer" ]] || continue
        if role_matches_target "${role_id}" "${ROLE_LABELS}" "${TASK_TARGET}"; then
          return 0
        fi
      done < <(active_role_ids)
    done < "${BACKLOG_FILE}"

    return 1
  )
}

acquire_lock() {
  local name="$1"
  local timeout_seconds="${2:-60}"
  local waited=0
  local lock_path="${LOCK_DIR}/${name}.lock"

  ensure_dir "${LOCK_DIR}"

  while ! mkdir "${lock_path}" 2>/dev/null; do
    if (( waited >= timeout_seconds )); then
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done

  print -r -- "$$" > "${lock_path}/pid"
  return 0
}

release_lock() {
  local name="$1"
  local lock_path="${LOCK_DIR}/${name}.lock"
  rm -f "${lock_path}/pid" 2>/dev/null || true
  rmdir "${lock_path}" 2>/dev/null || true
}

resolve_claude_bin() {
  local candidate="${CLAUDE_BIN}"
  local resolved_candidate

  if [[ "${candidate}" == */* ]]; then
    if [[ "${candidate}" == /* ]]; then
      resolved_candidate="${candidate}"
    elif [[ -x "${TARGET_REPO}/${candidate}" ]]; then
      resolved_candidate="${TARGET_REPO}/${candidate}"
    elif [[ -x "${INTERNAL_ROOT}/${candidate}" ]]; then
      resolved_candidate="${INTERNAL_ROOT}/${candidate}"
    else
      resolved_candidate="${candidate}"
    fi

    if [[ -x "${resolved_candidate}" ]]; then
      print -r -- "${resolved_candidate}"
      return 0
    fi
    return 1
  fi

  command -v "${candidate}" 2>/dev/null
}

load_crew_env() {
  if [[ -f "${CREW_FILE}" ]]; then
    source "${CREW_FILE}"
  fi

  if [[ -z "${BASE_BRANCH:-}" ]]; then
    BASE_BRANCH="$(current_branch)"
  fi

  if [[ -z "${BASE_BRANCH}" ]]; then
    BASE_BRANCH="main"
  fi

  if [[ -z "${ACTIVE_ROLES:-}" ]]; then
    ACTIVE_ROLES="${DEFAULT_ACTIVE_ROLES}"
  fi
}

save_crew_env() {
  ensure_dir "${CREW_FILE:h}"
  save_lines_to_file "${CREW_FILE}" \
    "ACTIVE_ROLES=\"${ACTIVE_ROLES}\"" \
    "BASE_BRANCH=\"${BASE_BRANCH}\""
}

validate_archetype() {
  case "$1" in
    writer|planner|advisor|reviewer)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

role_file_path() {
  local role_id="$1"
  print -r -- "${ROLE_DIR}/${role_id}.env"
}

role_log_file() {
  local role_id="$1"
  print -r -- "${LOG_DIR}/${role_id}.log"
}

role_session_file() {
  local role_id="$1"
  print -r -- "${SESSION_DIR}/${role_id}.env"
}

writer_branch_name() {
  local role_id="$1"
  print -r -- "${WRITER_BRANCH_PREFIX}/${role_id}"
}

writer_worktree_path() {
  local role_id="$1"
  print -r -- "${WORKTREE_DIR}/${role_id}"
}

write_role_file() {
  local role_id="$1"
  local role_name="$2"
  local role_archetype="$3"
  local prompt_file="$4"
  local doc_file="$5"
  local success_sleep="$6"
  local fail_sleep="$7"
  local role_labels="$8"
  local file
  file="$(role_file_path "${role_id}")"

  ensure_dir "${ROLE_DIR}"
  save_lines_to_file "${file}" \
    "ROLE_ID=\"${role_id}\"" \
    "ROLE_NAME=\"${role_name}\"" \
    "ROLE_ARCHETYPE=\"${role_archetype}\"" \
    "PROMPT_FILE=\"${prompt_file}\"" \
    "DOC_FILE=\"${doc_file}\"" \
    "SUCCESS_SLEEP=\"${success_sleep}\"" \
    "FAIL_SLEEP=\"${fail_sleep}\"" \
    "ROLE_LABELS=\"${role_labels}\""
}

ensure_default_role_file() {
  local role_id="$1"
  local role_name="$2"
  local role_archetype="$3"
  local prompt_file="$4"
  local doc_file="$5"
  local success_sleep="$6"
  local fail_sleep="$7"
  local role_labels="$8"
  local file
  file="$(role_file_path "${role_id}")"
  if [[ ! -f "${file}" ]]; then
    write_role_file "${role_id}" "${role_name}" "${role_archetype}" "${prompt_file}" "${doc_file}" "${success_sleep}" "${fail_sleep}" "${role_labels}"
  fi
}

legacy_layout_present() {
  [[ -f "${DOCS_DIR}/working_log.md" || -f "${DOCS_DIR}/product_lead.md" || -f "${DOCS_DIR}/design_lead.md" || -f "${PROMPT_DIR}/product_lead.md" || -f "${PROMPT_DIR}/design_lead.md" ]]
}

migrate_legacy_layout() {
  copy_if_missing "${DOCS_DIR}/working_log.md" "${DOCS_DIR}/engineer.md"
  copy_if_missing "${DOCS_DIR}/product_lead.md" "${DOCS_DIR}/product.md"
  copy_if_missing "${DOCS_DIR}/design_lead.md" "${DOCS_DIR}/design.md"
  copy_if_missing "${PROMPT_DIR}/product_lead.md" "${PROMPT_DIR}/product.md"
  copy_if_missing "${PROMPT_DIR}/design_lead.md" "${PROMPT_DIR}/design.md"
}

bootstrap_repo() {
  ensure_target_repo
  ensure_dir "${ROLE_DIR}"
  ensure_dir "${PROMPT_DIR}"
  ensure_dir "${DOCS_DIR}"
  ensure_dir "${LOG_DIR}"
  ensure_dir "${RUNTIME_DIR}"
  ensure_dir "${LOCK_DIR}"
  ensure_dir "${SESSION_DIR}"
  ensure_dir "${WORKTREE_DIR}"
  ensure_state_file "${TASKS_STATE}"
  ensure_state_file "${CLAIMS_STATE}"
  ensure_state_file "${MERGE_STATE}"
  ensure_local_gitignore

  if legacy_layout_present; then
    migrate_legacy_layout
  fi

  load_crew_env
  save_crew_env

  ensure_file_from_template "${DOC_TEMPLATE_DIR}/backlog.md" "${BACKLOG_FILE}"
  ensure_file_from_template "${DOC_TEMPLATE_DIR}/product.md" "${DOCS_DIR}/product.md"
  ensure_file_from_template "${DOC_TEMPLATE_DIR}/design.md" "${DOCS_DIR}/design.md"
  ensure_file_from_template "${DOC_TEMPLATE_DIR}/engineer.md" "${DOCS_DIR}/engineer.md"

  ensure_file_from_template "${PROMPT_TEMPLATE_DIR}/product.md" "${PROMPT_DIR}/product.md"
  ensure_file_from_template "${PROMPT_TEMPLATE_DIR}/design.md" "${PROMPT_DIR}/design.md"
  ensure_file_from_template "${PROMPT_TEMPLATE_DIR}/engineer.md" "${PROMPT_DIR}/engineer.md"

  ensure_default_role_file "product" "Product" "planner" ".micro-startup/prompts/product.md" ".micro-startup/docs/product.md" "900" "300" "planning product"
  ensure_default_role_file "design" "Design" "advisor" ".micro-startup/prompts/design.md" ".micro-startup/docs/design.md" "900" "300" "design ui"
  ensure_default_role_file "engineer" "Engineer" "writer" ".micro-startup/prompts/engineer.md" ".micro-startup/docs/engineer.md" "15" "60" "default implementation"
}

append_active_role() {
  local role_id="$1"
  load_crew_env
  local -A seen=()
  local -a ordered=()
  local existing_role

  for existing_role in ${(z)ACTIVE_ROLES}; do
    if [[ -n "${existing_role}" && -z "${seen[${existing_role}]-}" ]]; then
      seen[${existing_role}]=1
      ordered+=("${existing_role}")
    fi
  done

  if [[ -z "${seen[${role_id}]-}" ]]; then
    ordered+=("${role_id}")
  fi

  ACTIVE_ROLES="${(j: :)ordered}"
  save_crew_env
}

remove_active_role() {
  local role_id="$1"
  load_crew_env
  local -a ordered=()
  local existing_role

  for existing_role in ${(z)ACTIVE_ROLES}; do
    if [[ "${existing_role}" != "${role_id}" && -n "${existing_role}" ]]; then
      ordered+=("${existing_role}")
    fi
  done

  ACTIVE_ROLES="${(j: :)ordered}"
  save_crew_env
}

active_role_ids() {
  load_crew_env
  local -A seen=()
  local -a ordered=()
  local role_id
  local role_file

  for role_id in ${(z)ACTIVE_ROLES}; do
    if [[ -n "${role_id}" && -z "${seen[${role_id}]-}" ]]; then
      seen[${role_id}]=1
      ordered+=("${role_id}")
    fi
  done

  for role_file in "${ROLE_DIR}"/*.env(N); do
    role_id="${role_file:t:r}"
    if [[ -z "${seen[${role_id}]-}" ]]; then
      seen[${role_id}]=1
      ordered+=("${role_id}")
    fi
  done

  print -rl -- "${ordered[@]}"
}

load_role() {
  local role_id="$1"
  local file

  unset ROLE_ID ROLE_NAME ROLE_ARCHETYPE PROMPT_FILE DOC_FILE SUCCESS_SLEEP FAIL_SLEEP ROLE_LABELS ROLE_MODE ROLE_CAN_EDIT_BACKLOG ROLE_PROMPT_PATH ROLE_DOC_PATH ROLE_BRANCH ROLE_WORKTREE ROLE_LOG_FILE ROLE_SESSION_FILE

  file="$(role_file_path "${role_id}")"
  if [[ ! -f "${file}" ]]; then
    return 1
  fi

  source "${file}"

  ROLE_PROMPT_PATH="$(resolve_repo_path "${PROMPT_FILE}")"
  ROLE_DOC_PATH="$(resolve_repo_path "${DOC_FILE}")"
  ROLE_BRANCH="$(writer_branch_name "${role_id}")"
  ROLE_WORKTREE="$(writer_worktree_path "${role_id}")"
  ROLE_LOG_FILE="$(role_log_file "${role_id}")"
  ROLE_SESSION_FILE="$(role_session_file "${role_id}")"
  ROLE_MODE="advisor"
  ROLE_CAN_EDIT_BACKLOG=0

  case "${ROLE_ARCHETYPE}" in
    writer)
      ROLE_MODE="writer"
      ;;
    planner)
      ROLE_MODE="planner"
      ROLE_CAN_EDIT_BACKLOG=1
      ;;
    advisor|reviewer)
      ROLE_MODE="advisor"
      ;;
    *)
      return 1
      ;;
  esac

  return 0
}

role_matches_target() {
  local role_id="$1"
  local role_labels="$2"
  local target="$3"
  local label

  case "${target}" in
    any-writer)
      return 0
      ;;
    role:*)
      [[ "${target#role:}" == "${role_id}" ]]
      return
      ;;
    label:*)
      label="${target#label:}"
      for label_match in ${(z)role_labels}; do
        if [[ "${label_match}" == "${label}" ]]; then
          return 0
        fi
      done
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

priority_rank() {
  case "$1" in
    P0) print -r -- "0" ;;
    P1) print -r -- "1" ;;
    P2) print -r -- "2" ;;
    P3) print -r -- "3" ;;
    P4) print -r -- "4" ;;
    *) print -r -- "9" ;;
  esac
}

TASK_ID=""
TASK_TARGET=""
TASK_PRIORITY=""
TASK_TITLE=""

parse_backlog_line() {
  local line="$1"
  local raw
  local field1
  local field2
  local field3
  local field4
  local extra

  TASK_ID=""
  TASK_TARGET=""
  TASK_PRIORITY=""
  TASK_TITLE=""

  [[ "${line}" == "- TASK-"* ]] || return 1
  raw="${line#- }"
  IFS='|' read -r field1 field2 field3 field4 extra <<< "${raw}"
  [[ -z "${extra:-}" ]] || return 1

  TASK_ID="$(trim "${field1}")"
  TASK_TARGET="$(trim "${field2}")"
  TASK_PRIORITY="$(trim "${field3}")"
  TASK_TITLE="$(trim "${field4}")"

  [[ "${TASK_ID}" == TASK-* ]] || return 1
  [[ "${TASK_TARGET}" == target=* ]] || return 1
  [[ "${TASK_PRIORITY}" == priority=* ]] || return 1
  [[ "${TASK_TITLE}" == title=* ]] || return 1

  TASK_TARGET="${TASK_TARGET#target=}"
  TASK_PRIORITY="${TASK_PRIORITY#priority=}"
  TASK_TITLE="${TASK_TITLE#title=}"

  case "${TASK_TARGET}" in
    any-writer|role:*|label:*)
      ;;
    *)
      return 1
      ;;
  esac

  return 0
}

backlog_task_title() {
  local task_id="$1"
  local line
  while IFS= read -r line; do
    if parse_backlog_line "${line}" && [[ "${TASK_ID}" == "${task_id}" ]]; then
      print -r -- "${TASK_TITLE}"
      return 0
    fi
  done < "${BACKLOG_FILE}"
  return 1
}

validate_backlog_file() {
  local line
  ensure_file_from_template "${DOC_TEMPLATE_DIR}/backlog.md" "${BACKLOG_FILE}"
  while IFS= read -r line; do
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    if [[ "${line}" == "- TASK-"* ]] && ! parse_backlog_line "${line}"; then
      return 1
    fi
  done < "${BACKLOG_FILE}"
  return 0
}

count_writer_roles() {
  local count=0
  local role_id
  while IFS= read -r role_id; do
    load_role "${role_id}" || continue
    if [[ "${ROLE_MODE}" == "writer" ]]; then
      count=$((count + 1))
    fi
  done < <(active_role_ids)
  print -r -- "${count}"
}

validate_all_roles() {
  local role_id
  local -A seen=()

  while IFS= read -r role_id; do
    [[ -n "${role_id}" ]] || continue
    if [[ -n "${seen[${role_id}]-}" ]]; then
      print -r -- "duplicate role id detected: ${role_id}"
      return 1
    fi
    seen[${role_id}]=1

    if ! load_role "${role_id}"; then
      print -r -- "role file is invalid or missing: ${role_id}"
      return 1
    fi

    if [[ "${ROLE_ID}" != "${role_id}" ]]; then
      print -r -- "ROLE_ID mismatch in ${role_id}.env"
      return 1
    fi

    if ! validate_archetype "${ROLE_ARCHETYPE}"; then
      print -r -- "invalid ROLE_ARCHETYPE in ${role_id}.env"
      return 1
    fi

    if [[ ! -f "${ROLE_PROMPT_PATH}" ]]; then
      print -r -- "missing prompt for role ${role_id}: ${PROMPT_FILE}"
      return 1
    fi

    if [[ ! -f "${ROLE_DOC_PATH}" ]]; then
      print -r -- "missing doc for role ${role_id}: ${DOC_FILE}"
      return 1
    fi
  done < <(active_role_ids)

  if (( $(count_writer_roles) < 1 )); then
    print -r -- "at least one writer role is required"
    return 1
  fi

  return 0
}

ensure_base_branch() {
  load_crew_env
  local branch_now
  branch_now="$(current_branch "${TARGET_REPO}")"
  if [[ "${branch_now}" == "${BASE_BRANCH}" ]]; then
    return 0
  fi

  if target_has_blocking_dirty_tree; then
    print -r -- "Refusing to switch to BASE_BRANCH with a dirty product worktree (${branch_now} -> ${BASE_BRANCH})"
    return 1
  fi

  git -C "${TARGET_REPO}" checkout "${BASE_BRANCH}" >/dev/null
}

ensure_writer_worktree() {
  local role_id="$1"
  load_crew_env
  local worktree_path
  local branch_name

  worktree_path="$(writer_worktree_path "${role_id}")"
  branch_name="$(writer_branch_name "${role_id}")"

  ensure_dir "${WORKTREE_DIR}"
  if [[ -d "${worktree_path}" && ! -e "${worktree_path}/.git" ]]; then
    rm -rf "${worktree_path}"
  fi

  if [[ -e "${worktree_path}/.git" ]]; then
    return 0
  fi

  if git -C "${TARGET_REPO}" rev-parse --verify "${branch_name}" >/dev/null 2>&1; then
    git -C "${TARGET_REPO}" worktree add "${worktree_path}" "${branch_name}" >/dev/null
  else
    git -C "${TARGET_REPO}" worktree add -b "${branch_name}" "${worktree_path}" "${BASE_BRANCH}" >/dev/null
  fi
}

scaffold_paths_dirty() {
  [[ -n "$(git -C "${TARGET_REPO}" status --porcelain -- micro-startup .micro-startup)" ]]
}

stash_scaffold_changes() {
  local stash_before
  local stash_after
  stash_before="$(git -C "${TARGET_REPO}" stash list | head -n 1 || true)"
  if scaffold_paths_dirty; then
    git -C "${TARGET_REPO}" stash push --include-untracked -m "micro-startup-merge-$(utc_now)" -- micro-startup .micro-startup >/dev/null 2>&1 || true
  fi
  stash_after="$(git -C "${TARGET_REPO}" stash list | head -n 1 || true)"
  if [[ "${stash_before}" != "${stash_after}" && -n "${stash_after}" ]]; then
    print -r -- "1"
  else
    print -r -- "0"
  fi
}

restore_scaffold_changes() {
  local had_stash="$1"
  if [[ "${had_stash}" == "1" ]]; then
    git -C "${TARGET_REPO}" stash pop >/dev/null 2>&1 || true
  fi
}

merge_writer_commit() {
  local role_id="$1"
  local task_id="$2"
  local commit_sha="$3"
  local stash_created="0"
  local merge_detail=""

  if ! acquire_lock merge 120; then
    set_task_status "${task_id}" "running" "${role_id}" "waiting for merge lock"
    return 1
  fi

  if ! acquire_lock mainrepo 120; then
    release_lock merge
    set_task_status "${task_id}" "running" "${role_id}" "waiting for main repo lock"
    return 1
  fi

  stash_created="$(stash_scaffold_changes)"
  if ! ensure_base_branch; then
    restore_scaffold_changes "${stash_created}"
    release_lock mainrepo
    release_lock merge
    set_task_status "${task_id}" "running" "${role_id}" "BASE_BRANCH checkout failed"
    return 1
  fi

  if git -C "${TARGET_REPO}" cherry-pick "${commit_sha}" >/dev/null 2>&1; then
    set_merge_state "${task_id}" "${role_id}" "${commit_sha}" "merged" "cherry-pick succeeded"
    set_task_status "${task_id}" "merged" "${role_id}" "merged commit ${commit_sha}"
    clear_claim "${task_id}"
    restore_scaffold_changes "${stash_created}"
    release_lock mainrepo
    release_lock merge
    return 0
  fi

  git -C "${TARGET_REPO}" cherry-pick --abort >/dev/null 2>&1 || true
  merge_detail="repair cherry-pick conflict from ${commit_sha}"
  set_merge_state "${task_id}" "${role_id}" "${commit_sha}" "conflict" "${merge_detail}"
  set_task_status "${task_id}" "repair-pending" "${role_id}" "${merge_detail}"
  clear_claim "${task_id}"
  restore_scaffold_changes "${stash_created}"
  release_lock mainrepo
  release_lock merge
  return 1
}

role_default_labels() {
  local role_id="$1"
  local archetype="$2"
  case "${archetype}" in
    writer)
      print -r -- "default ${role_id}"
      ;;
    planner)
      print -r -- "planning ${role_id}"
      ;;
    reviewer)
      print -r -- "review ${role_id}"
      ;;
    *)
      print -r -- "${role_id}"
      ;;
  esac
}

role_default_sleep() {
  local archetype="$1"
  local mode="$2"
  case "${archetype}:${mode}" in
    writer:success) print -r -- "15" ;;
    writer:fail) print -r -- "60" ;;
    *:success) print -r -- "900" ;;
    *:fail) print -r -- "300" ;;
  esac
}

role_prompt_template_file() {
  local archetype="$1"
  print -r -- "${ROLE_PROMPT_TEMPLATE_DIR}/${archetype}.md"
}

role_doc_template_file() {
  local archetype="$1"
  print -r -- "${ROLE_DOC_TEMPLATE_DIR}/${archetype}.md"
}

role_add() {
  local raw_role_id="$1"
  local archetype="$2"
  local role_id
  local role_name
  local prompt_rel
  local doc_rel
  local prompt_abs
  local doc_abs

  role_id="$(normalize_role_id "${raw_role_id}")"
  if [[ -z "${role_id}" ]]; then
    print -r -- "invalid role id"
    return 1
  fi

  if ! validate_archetype "${archetype}"; then
    print -r -- "invalid archetype: ${archetype}"
    return 1
  fi

  bootstrap_repo

  if [[ -f "$(role_file_path "${role_id}")" ]]; then
    print -r -- "role already exists: ${role_id}"
    return 1
  fi

  role_name="$(pretty_role_name "${role_id}")"
  prompt_rel=".micro-startup/prompts/${role_id}.md"
  doc_rel=".micro-startup/docs/${role_id}.md"
  prompt_abs="$(resolve_repo_path "${prompt_rel}")"
  doc_abs="$(resolve_repo_path "${doc_rel}")"

  ensure_file_from_template "$(role_prompt_template_file "${archetype}")" "${prompt_abs}"
  ensure_file_from_template "$(role_doc_template_file "${archetype}")" "${doc_abs}"
  write_role_file "${role_id}" "${role_name}" "${archetype}" "${prompt_rel}" "${doc_rel}" "$(role_default_sleep "${archetype}" success)" "$(role_default_sleep "${archetype}" fail)" "$(role_default_labels "${role_id}" "${archetype}")"
  append_active_role "${role_id}"
  print -r -- "Added role ${role_id} (${archetype})"
}

role_remove() {
  local role_id="$1"
  local role_file
  local role_prompt
  local role_doc
  local role_worktree
  local task_id

  bootstrap_repo
  if ! load_role "${role_id}"; then
    print -r -- "unknown role: ${role_id}"
    return 1
  fi

  role_file="$(role_file_path "${role_id}")"
  role_prompt="${ROLE_PROMPT_PATH}"
  role_doc="${ROLE_DOC_PATH}"
  role_worktree="${ROLE_WORKTREE}"

  remove_active_role "${role_id}"
  rm -f "${role_file}" "${role_prompt}" "${role_doc}" "$(role_log_file "${role_id}")" "$(role_session_file "${role_id}")"
  while IFS= read -r task_id; do
    [[ -n "${task_id}" ]] || continue
    clear_claim "${task_id}"
  done < <(awk -F'|' -v role_id="${role_id}" '$2 == role_id { print $1 }' "${CLAIMS_STATE}")
  if [[ -e "${role_worktree}/.git" ]]; then
    git -C "${TARGET_REPO}" worktree remove --force "${role_worktree}" >/dev/null 2>&1 || rm -rf "${role_worktree}"
  else
    rm -rf "${role_worktree}"
  fi
  print -r -- "Removed role ${role_id}"
}

role_list() {
  local role_id
  while IFS= read -r role_id; do
    [[ -n "${role_id}" ]] || continue
    load_role "${role_id}" || continue
    print -r -- "${role_id} | ${ROLE_ARCHETYPE} | ${PROMPT_FILE} | ${DOC_FILE}"
  done < <(active_role_ids)
}

next_repair_task_for_role() {
  local role_id="$1"
  ensure_state_file "${TASKS_STATE}"
  awk -F'|' -v role_id="${role_id}" '
    $2 == "repair-pending" && $3 == role_id {
      print $1
      exit
    }
  ' "${TASKS_STATE}"
}

CURRENT_TASK_ID=""
CURRENT_TASK_SOURCE=""
CURRENT_TASK_TITLE=""
CURRENT_TASK_TARGET=""
CURRENT_TASK_DETAIL=""

claim_or_resume_task() {
  local role_id="$1"
  local role_labels="$2"
  local claimed_task
  local repair_task
  local line
  local task_state
  local owner
  local best_rank=99
  local best_id=""
  local best_title=""
  local best_target=""
  local best_detail=""
  local current_rank

  CURRENT_TASK_ID=""
  CURRENT_TASK_SOURCE=""
  CURRENT_TASK_TITLE=""
  CURRENT_TASK_TARGET=""
  CURRENT_TASK_DETAIL=""

  claimed_task="$(claimed_task_for_role "${role_id}")"
  if [[ -n "${claimed_task}" ]]; then
    task_state="$(task_status "${claimed_task}")"
    if task_is_terminal "${task_state}"; then
      clear_claim "${claimed_task}"
    else
      CURRENT_TASK_ID="${claimed_task}"
      CURRENT_TASK_SOURCE="backlog"
      CURRENT_TASK_TITLE="$(backlog_task_title "${claimed_task}" || true)"
      CURRENT_TASK_TARGET=""
      CURRENT_TASK_DETAIL="$(task_detail "${claimed_task}")"
      return 0
    fi
  fi

  if ! acquire_lock scheduler 60; then
    return 1
  fi

  claimed_task="$(claimed_task_for_role "${role_id}")"
  if [[ -n "${claimed_task}" ]]; then
    release_lock scheduler
    CURRENT_TASK_ID="${claimed_task}"
    CURRENT_TASK_SOURCE="backlog"
    CURRENT_TASK_TITLE="$(backlog_task_title "${claimed_task}" || true)"
    CURRENT_TASK_DETAIL="$(task_detail "${claimed_task}")"
    return 0
  fi

  repair_task="$(next_repair_task_for_role "${role_id}")"
  if [[ -n "${repair_task}" ]]; then
    set_claim "${repair_task}" "${role_id}"
    set_task_status "${repair_task}" "running" "${role_id}" "$(task_detail "${repair_task}")"
    release_lock scheduler
    CURRENT_TASK_ID="${repair_task}"
    CURRENT_TASK_SOURCE="repair"
    CURRENT_TASK_TITLE="$(task_detail "${repair_task}")"
    CURRENT_TASK_DETAIL="$(task_detail "${repair_task}")"
    return 0
  fi

  while IFS= read -r line; do
    if ! parse_backlog_line "${line}"; then
      continue
    fi

    task_state="$(task_status "${TASK_ID}")"
    owner="$(claim_owner "${TASK_ID}")"
    if [[ -n "${owner}" ]]; then
      continue
    fi

    if [[ "${task_state}" == "repair-pending" ]]; then
      continue
    fi

    if [[ -n "${task_state}" && "${task_state}" != "repair-pending" && "${task_state}" != "queued" ]]; then
      if task_is_terminal "${task_state}" || [[ "${task_state}" == "running" || "${task_state}" == "claimed" || "${task_state}" == "verified" ]]; then
        continue
      fi
    fi

    if ! role_matches_target "${role_id}" "${role_labels}" "${TASK_TARGET}"; then
      continue
    fi

    current_rank="$(priority_rank "${TASK_PRIORITY}")"
    if (( current_rank < best_rank )); then
      best_rank="${current_rank}"
      best_id="${TASK_ID}"
      best_title="${TASK_TITLE}"
      best_target="${TASK_TARGET}"
      best_detail="${TASK_TITLE}"
    fi
  done < "${BACKLOG_FILE}"

  if [[ -n "${best_id}" ]]; then
    set_claim "${best_id}" "${role_id}"
    set_task_status "${best_id}" "claimed" "${role_id}" "${best_detail}"
    release_lock scheduler
    CURRENT_TASK_ID="${best_id}"
    CURRENT_TASK_SOURCE="backlog"
    CURRENT_TASK_TITLE="${best_title}"
    CURRENT_TASK_TARGET="${best_target}"
    CURRENT_TASK_DETAIL="${best_detail}"
    return 0
  fi

  release_lock scheduler
  return 1
}

#!/bin/zsh

emulate -LR zsh
setopt pipefail nounset

SCRIPT_DIR="${0:A:h}"
FORCE=0
TARGET_ARG="."

usage() {
  cat <<EOF
Usage: ${0:t} [--force] [target-repo]

Install Micro Startup into the current git repo by default.
EOF
}

copy_tree() {
  local source_dir="$1"
  local destination_dir="$2"

  rm -rf "${destination_dir}"
  mkdir -p "${destination_dir}"
  cp -R "${source_dir}/." "${destination_dir}/"
}

copy_if_missing_or_force() {
  local source_file="$1"
  local destination_file="$2"

  if (( FORCE )) || [[ ! -f "${destination_file}" ]]; then
    mkdir -p "${destination_file:h}"
    cp "${source_file}" "${destination_file}"
  fi
}

write_local_gitignore() {
  local file="$1"
  cat > "${file}" <<'EOF'
logs/
runtime/
worktrees/
config.env
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      TARGET_ARG="$1"
      ;;
  esac
  shift
done

if [[ ! -d "${TARGET_ARG}" ]]; then
  print -r -- "Target directory does not exist: ${TARGET_ARG}"
  exit 1
fi

TARGET_REPO="$(cd "${TARGET_ARG}" && pwd)"
if ! git -C "${TARGET_REPO}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  print -r -- "Install target must be a git repository: ${TARGET_REPO}"
  exit 1
fi
TARGET_REPO="$(git -C "${TARGET_REPO}" rev-parse --show-toplevel)"

INTERNAL_ROOT="${TARGET_REPO}/.micro-startup"
mkdir -p "${INTERNAL_ROOT}"

copy_tree "${SCRIPT_DIR}/scripts" "${INTERNAL_ROOT}/scripts"
copy_tree "${SCRIPT_DIR}/prompts" "${INTERNAL_ROOT}/templates/prompts"
copy_tree "${SCRIPT_DIR}/templates/repo-docs" "${INTERNAL_ROOT}/templates/repo-docs"
copy_tree "${SCRIPT_DIR}/templates/role-prompts" "${INTERNAL_ROOT}/templates/role-prompts"
copy_tree "${SCRIPT_DIR}/templates/role-docs" "${INTERNAL_ROOT}/templates/role-docs"

mkdir -p \
  "${INTERNAL_ROOT}/docs" \
  "${INTERNAL_ROOT}/prompts" \
  "${INTERNAL_ROOT}/roles" \
  "${INTERNAL_ROOT}/logs" \
  "${INTERNAL_ROOT}/runtime/locks" \
  "${INTERNAL_ROOT}/runtime/sessions" \
  "${INTERNAL_ROOT}/worktrees"

copy_if_missing_or_force "${SCRIPT_DIR}/config/project.env.example" "${INTERNAL_ROOT}/config.env.example"
cp "${SCRIPT_DIR}/micro-startup" "${TARGET_REPO}/micro-startup"
write_local_gitignore "${INTERNAL_ROOT}/.gitignore"

chmod +x "${TARGET_REPO}/micro-startup"
chmod +x "${INTERNAL_ROOT}/scripts/"*.sh

print -r -- "Installed Micro Startup into ${TARGET_REPO}"
print -r -- "Next step: cd ${TARGET_REPO} && ./micro-startup start"

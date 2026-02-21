#!/usr/bin/env bash
set -uo pipefail

###############################################################################
# Universal One-Way Git Mirror Script
#
# Continuously mirrors Git repositories from any source to any destination
# using SSH URLs. Runs in an infinite loop with a configurable sleep interval.
#
# WARNING: This is a ONE-WAY destructive mirror. Each sync cycle force-pushes
# the source state to the destination using 'git push --mirror'. Any commits,
# branches, or tags pushed directly to the destination WILL BE OVERWRITTEN
# and permanently lost on the next sync cycle.
###############################################################################

# =============================================================================
# Configuration (defaults — overridden by CLI flags)
# =============================================================================

SYNC_DIR="/tmp/git-mirrors"
SLEEP_INTERVAL=300
REPOS_CONFIG=""
MAX_RETRIES=3
RETRY_DELAY=5

# =============================================================================
# Usage
# =============================================================================

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") --config <repos.json> [OPTIONS]

Required:
  -c, --config <path>      Path to the JSON config file with repository mappings.

Options:
  -d, --sync-dir <path>    Directory for bare mirror clones (default: /tmp/git-mirrors).
  -i, --interval <secs>    Seconds to sleep between sync cycles (default: 300).
  -h, --help               Show this help message and exit.
EOF
  exit 1
}

# =============================================================================
# Dependency checks
# =============================================================================

for cmd in git jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is required but not installed." >&2
    exit 1
  fi
done

# =============================================================================
# Logging
# =============================================================================

log() {
  local level="$1"
  shift
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

# =============================================================================
# execute_with_retry
#
# Runs a command up to MAX_RETRIES times. Sleeps RETRY_DELAY seconds between
# failed attempts. Returns the exit code of the last attempt.
#
# Usage: execute_with_retry <command> [args...]
# =============================================================================

execute_with_retry() {
  local attempt=1
  local rc=0

  while (( attempt <= MAX_RETRIES )); do
    "$@" && return 0
    rc=$?

    if (( attempt < MAX_RETRIES )); then
      log_warn "Command failed (attempt $attempt/$MAX_RETRIES, exit $rc): $*"
      log_warn "Retrying in ${RETRY_DELAY}s..."
      sleep "$RETRY_DELAY"
    else
      log_error "Command failed after $MAX_RETRIES attempts (exit $rc): $*"
    fi

    (( attempt++ ))
  done

  return "$rc"
}

# =============================================================================
# sync_repo
#
# Mirrors a single repository from source to destination.
# Each cycle does a fresh clone, optionally strips files >100MB, and pushes.
# clone_depth controls whether the full history or only the latest commit is
# cloned ("full" or "shallow").
# The source repository is never modified.
# All git operations run inside a subshell so the working directory of the
# main script is never affected.
#
# Arguments:
#   $1 - source SSH URL
#   $2 - destination SSH URL
#   $3 - clone_depth ("full" or "shallow")
# =============================================================================

sync_repo() {
  local source_url="$1"
  local dest_url="$2"
  local clone_depth="$3"

  local repo_name="${source_url##*/}"
  [[ "$repo_name" != *.git ]] && repo_name="${repo_name}.git"

  local repo_dir="${SYNC_DIR}/${repo_name}"

  log_info "--- Syncing: $repo_name ($clone_depth) ---"
  log_info "  Source:      $source_url"
  log_info "  Destination: $dest_url"

  # ---- Fresh clone every cycle ----
  [[ -d "$repo_dir" ]] && rm -rf "$repo_dir"

  if [[ "$clone_depth" == "shallow" ]]; then
    log_info "  Shallow-cloning from source (depth 1)..."
    if ! execute_with_retry git clone --bare --depth 1 --no-single-branch --progress "$source_url" "$repo_dir"; then
      log_error "  Clone failed for $source_url — skipping this repo."
      [[ -d "$repo_dir" ]] && rm -rf "$repo_dir"
      return 1
    fi
  else
    log_info "  Cloning from source (full history)..."
    if ! execute_with_retry git clone --mirror --progress "$source_url" "$repo_dir"; then
      log_error "  Clone failed for $source_url — skipping this repo."
      [[ -d "$repo_dir" ]] && rm -rf "$repo_dir"
      return 1
    fi
  fi
  log_info "  Clone successful."

  # ---- Rewrite + Strip + Push (inside a subshell for directory safety) ----
  (
    cd "$repo_dir" || {
      log_error "  Cannot cd into $repo_dir — skipping."
      exit 1
    }

    # Shallow clones contain a 'shallow' graft file that --mirror can't push.
    # Convert grafted commits into true root commits so --mirror works.
    if [[ -f shallow ]]; then
      log_info "  Converting shallow commits to root commits..."
      FILTER_BRANCH_SQUELCH_WARNING=1 \
        git filter-branch --force --parent-filter 'true' -- --all
      git for-each-ref --format='delete %(refname)' refs/original | git update-ref --stdin 2>/dev/null
      rm -f shallow
      log_info "  Shallow conversion complete."
    fi

    # Strip files >100MB from history (local clone only — source is never touched)
    log_info "  Scanning for files >100MB..."
    local large_files_list
    large_files_list=$(mktemp)

    git rev-list --all --objects | \
      git cat-file --batch-check='%(objectsize) %(objecttype) %(rest)' | \
      awk '$2 == "blob" && $1 > 104857600 {$1=""; $2=""; sub(/^  /, ""); print}' | \
      sort -u > "$large_files_list"

    if [[ -s "$large_files_list" ]]; then
      local file_count
      file_count=$(wc -l < "$large_files_list")
      log_warn "  Found $file_count file(s) >100MB — stripping from history:"
      while IFS= read -r f; do log_warn "    - $f"; done < "$large_files_list"

      local paths
      paths=$(tr '\n' ' ' < "$large_files_list")

      FILTER_BRANCH_SQUELCH_WARNING=1 \
        git filter-branch --force --index-filter \
          "git rm --cached --ignore-unmatch -- $paths" \
          -- --all

      # Clean up backup refs and loose objects
      git for-each-ref --format='delete %(refname)' refs/original | git update-ref --stdin 2>/dev/null
      rm -f "$large_files_list"
      log_info "  Large files stripped successfully."
    else
      log_info "  No files >100MB found."
      rm -f "$large_files_list"
    fi

    # Clean up loose objects after any rewrites
    git reflog expire --expire=now --all 2>/dev/null
    git gc --prune=now 2>/dev/null

    # Push mirror to destination
    log_info "  Pushing to destination..."
    local push_rc=0
    local attempt
    for attempt in 1 2 3; do
      push_rc=0
      git push --mirror --progress --verbose "$dest_url" 2>&1 || push_rc=$?

      if (( push_rc == 0 )); then
        log_info "  Push successful."
        break
      fi

      log_error "  Push failed (attempt $attempt/3, exit $push_rc) for $dest_url."
      if (( attempt < 3 )); then
        log_warn "  Retrying in ${RETRY_DELAY}s..."
        sleep "$RETRY_DELAY"
      else
        log_error "  Push failed after 3 attempts."
        exit 1
      fi
    done
  )

  local subshell_rc=$?
  if (( subshell_rc == 0 )); then
    log_info "  Sync complete for $repo_name."
  else
    log_error "  Sync FAILED for $repo_name (subshell exit $subshell_rc)."
  fi

  return "$subshell_rc"
}

# =============================================================================
# Main
# =============================================================================

main() {
  # ---- Parse CLI flags ----
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c|--config)
        [[ -z "${2:-}" ]] && { echo "ERROR: --config requires a value." >&2; usage; }
        REPOS_CONFIG="$2"; shift 2 ;;
      -d|--sync-dir)
        [[ -z "${2:-}" ]] && { echo "ERROR: --sync-dir requires a value." >&2; usage; }
        SYNC_DIR="$2"; shift 2 ;;
      -i|--interval)
        [[ -z "${2:-}" ]] && { echo "ERROR: --interval requires a value." >&2; usage; }
        SLEEP_INTERVAL="$2"; shift 2 ;;
      -h|--help)
        usage ;;
      *)
        echo "ERROR: Unknown option: $1" >&2; usage ;;
    esac
  done

  # ---- Validate required flags ----
  if [[ -z "$REPOS_CONFIG" ]]; then
    echo "ERROR: --config is required." >&2
    usage
  fi

  # ---- Load config once at startup ----
  if [[ ! -f "$REPOS_CONFIG" ]]; then
    echo "ERROR: Config file not found: $REPOS_CONFIG" >&2
    exit 1
  fi

  if ! jq empty "$REPOS_CONFIG" 2>/dev/null; then
    echo "ERROR: Invalid JSON in config file: $REPOS_CONFIG" >&2
    exit 1
  fi

  local repo_count
  repo_count=$(jq '.repos | length' "$REPOS_CONFIG")

  if (( repo_count == 0 )); then
    echo "ERROR: No repository mappings found in $REPOS_CONFIG." >&2
    exit 1
  fi

  # Pre-load all mappings into arrays
  local -a sources=() destinations=() clone_depths=()
  for (( i=0; i<repo_count; i++ )); do
    local src dst depth
    src=$(jq -r ".repos[$i].source" "$REPOS_CONFIG")
    dst=$(jq -r ".repos[$i].destination" "$REPOS_CONFIG")
    depth=$(jq -r ".repos[$i].clone_depth" "$REPOS_CONFIG")

    if [[ -z "$src" || "$src" == "null" || -z "$dst" || "$dst" == "null" ]]; then
      echo "ERROR: Invalid mapping at index $i (source and destination must be non-empty)." >&2
      exit 1
    fi

    if [[ "$depth" != "full" && "$depth" != "shallow" ]]; then
      echo "ERROR: Invalid clone_depth at index $i: '$depth' (must be 'full' or 'shallow')." >&2
      exit 1
    fi

    if [[ "$src" == "$dst" ]]; then
      echo "ERROR: Invalid mapping at index $i (source and destination are identical): '$src'" >&2
      exit 1
    fi

    sources+=("$src")
    destinations+=("$dst")
    clone_depths+=("$depth")
  done

  log_info "=========================================="
  log_info " Universal One-Way Git Mirror"
  log_info "=========================================="
  log_warn "DESTRUCTIVE MIRROR: Destination repos are force-pushed each cycle."
  log_warn "Any commits made directly to a destination WILL BE OVERWRITTEN."
  log_info "=========================================="
  log_info "Sync directory:  $SYNC_DIR"
  log_info "Sleep interval:  ${SLEEP_INTERVAL}s"
  log_info "Config file:     $REPOS_CONFIG"
  log_info "Repo mappings:   $repo_count"
  log_info ""

  # Ensure sync directory exists
  mkdir -p "$SYNC_DIR"

  while true; do
    log_info "========== Sync cycle starting =========="

    local failed=0
    local succeeded=0

    for (( i=0; i<repo_count; i++ )); do
      if sync_repo "${sources[$i]}" "${destinations[$i]}" "${clone_depths[$i]}"; then
        (( succeeded++ ))
      else
        (( failed++ ))
      fi
    done

    log_info "========== Sync cycle complete =========="
    log_info "  Succeeded: $succeeded  |  Failed: $failed  |  Total: $repo_count"
    log_info "  Next cycle in ${SLEEP_INTERVAL}s..."
    log_info ""

    sleep "$SLEEP_INTERVAL"
  done
}

main "$@"
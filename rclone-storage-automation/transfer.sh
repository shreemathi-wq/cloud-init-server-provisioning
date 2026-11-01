#!/usr/bin/env bash
# Reusable file transfer script built on rclone.
#
# Usage:
#   ./transfer.sh copy <source> <destination> [rclone flags...]
#   ./transfer.sh sync <source> <destination> [--confirm] [rclone flags...]
#
# Examples:
#   ./transfer.sh copy sample-data :s3:main-bucket/uploads
#   ./transfer.sh copy sample-data-large :s3:main-bucket/large --bwlimit 30M
#   ./transfer.sh sync storage-a/v2 :s3:main-bucket/site             # preview only
#   ./transfer.sh sync storage-a/v2 :s3:main-bucket/site --confirm   # real sync
#
# S3 paths use rclone's on-the-fly remote ":s3:bucket/path". The script never
# reads an rclone config file. S3 settings come only from environment variables:
#   RCLONE_S3_ACCESS_KEY_ID      (required for :s3: paths)
#   RCLONE_S3_SECRET_ACCESS_KEY  (required for :s3: paths)
#   RCLONE_S3_PROVIDER           (for example Minio, AWS, Wasabi)
#   RCLONE_S3_ENDPOINT           (not needed for AWS)
#
# Optional settings:
#   LOG_DIR           where log files are written (default: ./logs next to this script)
#   MAX_DELETE        sync stops after this many deletes (default: 100)
#   SYNC_BACKUP_DIR   sync moves deleted/overwritten files here instead of destroying them
#
# Exit codes:
#   0      success
#   2      wrong usage or missing configuration
#   other  rclone's exit code (see "Exit Code" in https://rclone.org/docs/)

set -euo pipefail

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_DIR="${LOG_DIR:-${SCRIPT_DIR}/logs}"
readonly MAX_DELETE="${MAX_DELETE:-100}"
readonly EXIT_USAGE=2

# Never read a saved rclone config file. Everything comes from arguments and env vars.
export RCLONE_CONFIG=/dev/null

# Retry settings learned from the experiments in section 5.
readonly RETRY_FLAGS=(--retries 3 --retries-sleep 10s --low-level-retries 10)

# Live progress bar on a terminal; periodic stats in the log when run from
# cron or another program (no terminal). Do not combine --progress with
# --stats 30s: the progress bar would then refresh only every 30 seconds.
if [[ -t 1 ]]; then
  readonly PROGRESS_FLAGS=(--progress)
else
  readonly PROGRESS_FLAGS=(--stats 30s)
fi

# sync deletes files, so it always gets a delete limit and an optional backup folder.
SYNC_SAFETY_FLAGS=(--max-delete "${MAX_DELETE}")
if [[ -n "${SYNC_BACKUP_DIR:-}" ]]; then
  SYNC_SAFETY_FLAGS+=(--backup-dir "${SYNC_BACKUP_DIR}")
fi
readonly SYNC_SAFETY_FLAGS

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

main() {
  parse_arguments "$@"

  validate_operation "${OPERATION}"
  reject_dry_run_flag "${EXTRA_FLAGS[@]}"
  reject_inline_credentials "${SOURCE}" "${DESTINATION}"
  require_s3_credentials_for_s3_paths "${SOURCE}" "${DESTINATION}"
  create_log_file "${OPERATION}"

  log_message "Started: ${OPERATION} '${SOURCE}' -> '${DESTINATION}'"

  case "${OPERATION}" in
    copy)
      run_copy "${SOURCE}" "${DESTINATION}" "${EXTRA_FLAGS[@]}"
      verify_copy "${SOURCE}" "${DESTINATION}"
      ;;
    sync)
      if [[ "${SYNC_CONFIRMED}" == "no" ]]; then
        preview_sync "${SOURCE}" "${DESTINATION}" "${EXTRA_FLAGS[@]}"
        log_message "Preview only. Nothing was changed. Re-run with --confirm to sync."
        exit 0
      fi
      run_sync "${SOURCE}" "${DESTINATION}" "${EXTRA_FLAGS[@]}"
      verify_sync "${SOURCE}" "${DESTINATION}"
      ;;
  esac

  log_message "Finished successfully. Log: ${LOG_FILE}"
}

# ---------------------------------------------------------------------------
# Arguments and validation
# ---------------------------------------------------------------------------

# Sets OPERATION, SOURCE, DESTINATION, SYNC_CONFIRMED and EXTRA_FLAGS.
# Every argument after the destination is passed to rclone, except --confirm.
parse_arguments() {
  if [[ $# -lt 3 ]]; then
    print_usage
    exit "${EXIT_USAGE}"
  fi

  OPERATION="$1"
  SOURCE="$2"
  DESTINATION="$3"
  shift 3

  SYNC_CONFIRMED="no"
  EXTRA_FLAGS=()
  local arg
  for arg in "$@"; do
    if [[ "${arg}" == "--confirm" ]]; then
      SYNC_CONFIRMED="yes"
    else
      EXTRA_FLAGS+=("${arg}")
    fi
  done

  readonly OPERATION SOURCE DESTINATION SYNC_CONFIRMED EXTRA_FLAGS
}

print_usage() {
  cat >&2 <<EOF
Usage:
  $(basename "$0") copy <source> <destination> [rclone flags...]
  $(basename "$0") sync <source> <destination> [--confirm] [rclone flags...]

sync without --confirm only shows what would change (dry run).
S3 paths look like :s3:bucket/path and need RCLONE_S3_* environment variables.
EOF
}

validate_operation() {
  local operation="$1"
  if [[ "${operation}" != "copy" && "${operation}" != "sync" ]]; then
    echo "Error: unknown operation '${operation}'. Use 'copy' or 'sync'." >&2
    print_usage
    exit "${EXIT_USAGE}"
  fi
}

# A dry-run copy changes nothing, so the verification afterwards would always
# fail. Previews are done with "sync" without --confirm instead.
reject_dry_run_flag() {
  local flag
  for flag in "$@"; do
    if [[ "${flag}" == "--dry-run" || "${flag}" == "-n" ]]; then
      echo "Error: --dry-run is not supported. Run 'sync' without --confirm to preview." >&2
      exit "${EXIT_USAGE}"
    fi
  done
}

# Passwords inside the path (":s3,secret_access_key=...:") are visible in `ps`
# and shell history, so they are refused. Use environment variables instead.
reject_inline_credentials() {
  local path
  for path in "$@"; do
    if [[ "${path}" == *secret_access_key=* || "${path}" == *access_key_id=* ]]; then
      echo "Error: do not put credentials in the path. Use RCLONE_S3_* environment variables." >&2
      exit "${EXIT_USAGE}"
    fi
  done
}

require_s3_credentials_for_s3_paths() {
  local source="$1" destination="$2"
  if ! is_s3_path "${source}" && ! is_s3_path "${destination}"; then
    return
  fi

  local missing=()
  [[ -z "${RCLONE_S3_ACCESS_KEY_ID:-}" ]] && missing+=(RCLONE_S3_ACCESS_KEY_ID)
  [[ -z "${RCLONE_S3_SECRET_ACCESS_KEY:-}" ]] && missing+=(RCLONE_S3_SECRET_ACCESS_KEY)

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: S3 path used, but these environment variables are not set: ${missing[*]}" >&2
    exit "${EXIT_USAGE}"
  fi
}

is_s3_path() {
  local path="$1"
  [[ "${path}" == :s3:* || "${path}" == :s3,* ]]
}

# ---------------------------------------------------------------------------
# Transfers
# ---------------------------------------------------------------------------

run_copy() {
  local source="$1" destination="$2"
  shift 2
  run_rclone_with_logging copy "${source}" "${destination}" "${RETRY_FLAGS[@]}" "$@"
}

# Shows the preview on screen as well as in the log, so the user can read
# what would be copied and deleted before confirming.
preview_sync() {
  local source="$1" destination="$2"
  shift 2
  log_message "Dry run: showing what sync would copy and delete"

  rclone sync "${source}" "${destination}" --dry-run "${SYNC_SAFETY_FLAGS[@]}" "$@" 2>&1 \
    | tee -a "${LOG_FILE}"
  local status="${PIPESTATUS[0]}"

  if [[ "${status}" -ne 0 ]]; then
    exit_with_failure "Dry run FAILED (exit code ${status})" "${status}"
  fi
}

run_sync() {
  local source="$1" destination="$2"
  shift 2
  run_rclone_with_logging sync "${source}" "${destination}" \
    "${RETRY_FLAGS[@]}" "${SYNC_SAFETY_FLAGS[@]}" "$@"
}

# Runs rclone with a progress display on screen and its detailed log in
# LOG_FILE. On failure, shows the last errors and exits with rclone's exit code.
run_rclone_with_logging() {
  local rclone_command="$1"
  local status=0
  rclone "$@" "${PROGRESS_FLAGS[@]}" --log-file "${LOG_FILE}" --log-level INFO \
    || status=$?

  if [[ "${status}" -ne 0 ]]; then
    grep -E "ERROR|Failed" "${LOG_FILE}" | tail -n 5 >&2 || true
    exit_with_failure "rclone ${rclone_command} FAILED (exit code ${status}). Last errors are shown above." "${status}"
  fi
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

# copy never deletes, so extra files in the destination are fine (--one-way).
verify_copy() {
  local source="$1" destination="$2"
  log_message "Verifying: every source file must exist and match in the destination"
  run_rclone_check "${source}" "${destination}" --one-way
}

# After sync, both sides must be exactly the same.
verify_sync() {
  local source="$1" destination="$2"
  log_message "Verifying: source and destination must be identical"
  run_rclone_check "${source}" "${destination}"
}

run_rclone_check() {
  local status=0
  rclone check "$@" --log-file "${LOG_FILE}" --log-level NOTICE || status=$?

  if [[ "${status}" -ne 0 ]]; then
    exit_with_failure "Verification FAILED (exit code ${status}). See ${LOG_FILE}" "${status}"
  fi
  log_message "Verification passed"
}

# ---------------------------------------------------------------------------
# Logging and exit
# ---------------------------------------------------------------------------

create_log_file() {
  local operation="$1"
  mkdir -p "${LOG_DIR}"
  # The process ID keeps two runs in the same second from sharing a log file.
  LOG_FILE="${LOG_DIR}/transfer-${operation}-$(date +%Y%m%d-%H%M%S)-$$.log"
  readonly LOG_FILE
}

# Prints a timestamped message to the screen and appends it to the log file.
log_message() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}" >&2
}

exit_with_failure() {
  local message="$1" status="$2"
  log_message "${message}"
  exit "${status}"
}

main "$@"

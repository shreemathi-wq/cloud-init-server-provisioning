#!/usr/bin/env bash
# ==============================================================================
# Testpress DevOps File Transfer & Synchronization Utility
# Testpress Engineering
#
# Usage:
#   ./transfer.sh copy <source> <destination> [rclone options...]
#   ./transfer.sh sync <source> <destination> [--confirm] [rclone options...]
#
# Examples:
#   ./transfer.sh copy sample-data :s3:main-bucket/uploads
#   ./transfer.sh copy sample-data-large :s3:main-bucket/large --bwlimit 50M
#   ./transfer.sh sync sample-data :s3:main-bucket/site             # Preview only
#   ./transfer.sh sync sample-data :s3:main-bucket/site --confirm   # Live sync
#
# Environment Variables:
#   RCLONE_S3_ACCESS_KEY_ID      (Required for :s3: paths)
#   RCLONE_S3_SECRET_ACCESS_KEY  (Required for :s3: paths)
#   RCLONE_S3_PROVIDER           (e.g., Minio, AWS, Wasabi)
#   RCLONE_S3_ENDPOINT           (e.g., http://127.0.0.1:9000)
#
# Optional Overrides:
#   LOG_DIR           Directory for execution logs (Default: ./logs)
#   MAX_DELETE        Safety limit on sync file deletions (Default: 100)
#   SYNC_BACKUP_DIR   Rollback archive path for modified/deleted files
#
# Exit Codes:
#   0      Transfer completed and verified
#   2      Command usage error or missing configuration
#   other  Rclone process error code
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Core Settings
# ------------------------------------------------------------------------------
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_DIR="${LOG_DIR:-${SCRIPT_DIR}/logs}"
readonly MAX_DELETE="${MAX_DELETE:-100}"
readonly EXIT_USAGE=2

# Enforce stateless execution: do not touch ~/.config/rclone/rclone.conf
export RCLONE_CONFIG=/dev/null

# Reliability & retry policies
readonly RETRY_FLAGS=(--retries 3 --retries-sleep 10s --low-level-retries 10)

# Terminal detection: dynamic progress on TTY; periodic telemetry in automation
if [[ -t 1 ]]; then
  readonly PROGRESS_FLAGS=(--progress)
else
  readonly PROGRESS_FLAGS=(--stats 30s)
fi

# Sync safety flags
SYNC_SAFETY_FLAGS=(--max-delete "${MAX_DELETE}")
if [[ -n "${SYNC_BACKUP_DIR:-}" ]]; then
  SYNC_SAFETY_FLAGS+=(--backup-dir "${SYNC_BACKUP_DIR}")
fi
readonly SYNC_SAFETY_FLAGS

# ------------------------------------------------------------------------------
# Main Flow
# ------------------------------------------------------------------------------
main() {
  parse_arguments "$@"
  validate_operation "${OPERATION}"
  reject_dry_run_flag "${EXTRA_FLAGS[@]}"
  reject_inline_credentials "${SOURCE}" "${DESTINATION}"
  require_s3_credentials_for_s3_paths "${SOURCE}" "${DESTINATION}"
  initialize_log_file "${OPERATION}"

  log_info "Starting ${OPERATION^^} job: '${SOURCE}' -> '${DESTINATION}'"

  case "${OPERATION}" in
    copy)
      execute_copy "${SOURCE}" "${DESTINATION}" "${EXTRA_FLAGS[@]}"
      verify_copy_integrity "${SOURCE}" "${DESTINATION}"
      ;;
    sync)
      if [[ "${SYNC_CONFIRMED}" == "no" ]]; then
        execute_sync_preview "${SOURCE}" "${DESTINATION}" "${EXTRA_FLAGS[@]}"
        log_info "Preview complete. No changes made. Re-run with --confirm to apply synchronization."
        exit 0
      fi
      execute_sync "${SOURCE}" "${DESTINATION}" "${EXTRA_FLAGS[@]}"
      verify_sync_integrity "${SOURCE}" "${DESTINATION}"
      ;;
  esac

  print_summary
}

# ------------------------------------------------------------------------------
# Argument Parsing & Validation
# ------------------------------------------------------------------------------
parse_arguments() {
  if [[ $# -lt 3 ]]; then
    print_usage_banner
    exit "${EXIT_USAGE}"
  fi

  OPERATION="$1"
  SOURCE="$2"
  DESTINATION="$3"
  shift 3

  SYNC_CONFIRMED="no"
  EXTRA_FLAGS=()
  local flag
  for flag in "$@"; do
    if [[ "${flag}" == "--confirm" ]]; then
      SYNC_CONFIRMED="yes"
    else
      EXTRA_FLAGS+=("${flag}")
    fi
  done

  readonly OPERATION SOURCE DESTINATION SYNC_CONFIRMED EXTRA_FLAGS
}

print_usage_banner() {
  cat >&2 <<EOF
================================================================================
Testpress File Transfer Utility (Rclone Engine)
================================================================================
Usage:
  $(basename "$0") copy <source> <destination> [rclone options...]
  $(basename "$0") sync <source> <destination> [--confirm] [rclone options...]

Notes:
  - sync defaults to dry-run preview unless --confirm is specified.
  - S3 paths use :s3:bucket/path and read credentials from RCLONE_S3_* env vars.
  - No static rclone.conf is ever created or modified.
================================================================================
EOF
}

validate_operation() {
  local op="$1"
  if [[ "${op}" != "copy" && "${op}" != "sync" ]]; then
    log_error "Unsupported operation '${op}'. Supported operations: 'copy', 'sync'."
    print_usage_banner
    exit "${EXIT_USAGE}"
  fi
}

reject_dry_run_flag() {
  local arg
  for arg in "$@"; do
    if [[ "${arg}" == "--dry-run" || "${arg}" == "-n" ]]; then
      log_error "Manual --dry-run flag is prohibited. Run 'sync' without --confirm to preview."
      exit "${EXIT_USAGE}"
    fi
  done
}

reject_inline_credentials() {
  local endpoint
  for endpoint in "$@"; do
    if [[ "${endpoint}" == *secret_access_key=* || "${endpoint}" == *access_key_id=* ]]; then
      log_error "Inline credentials detected in path string. Use RCLONE_S3_* environment variables instead."
      exit "${EXIT_USAGE}"
    fi
  done
}

require_s3_credentials_for_s3_paths() {
  local src="$1" dst="$2"
  if ! is_s3_path "${src}" && ! is_s3_path "${dst}"; then
    return
  fi

  local missing=()
  [[ -z "${RCLONE_S3_ACCESS_KEY_ID:-}" ]] && missing+=(RCLONE_S3_ACCESS_KEY_ID)
  [[ -z "${RCLONE_S3_SECRET_ACCESS_KEY:-}" ]] && missing+=(RCLONE_S3_SECRET_ACCESS_KEY)

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "S3 path detected but mandatory environment variables are unset: ${missing[*]}"
    exit "${EXIT_USAGE}"
  fi
}

is_s3_path() {
  local target="$1"
  [[ "${target}" == :s3:* || "${target}" == :s3,* ]]
}

# ------------------------------------------------------------------------------
# Transfer Operations
# ------------------------------------------------------------------------------
execute_copy() {
  local src="$1" dst="$2"
  shift 2
  invoke_rclone copy "${src}" "${dst}" "${RETRY_FLAGS[@]}" "$@"
}

execute_sync_preview() {
  local src="$1" dst="$2"
  shift 2
  log_info "Generating dry-run preview of planned changes (no disk modifications)..."

  rclone sync "${src}" "${dst}" --dry-run "${SYNC_SAFETY_FLAGS[@]}" "$@" 2>&1 \
    | tee -a "${LOG_FILE}"
  local exit_status="${PIPESTATUS[0]}"

  if [[ "${exit_status}" -ne 0 ]]; then
    terminate_with_error "Dry-run preview failed with exit code ${exit_status}" "${exit_status}"
  fi
}

execute_sync() {
  local src="$1" dst="$2"
  shift 2
  invoke_rclone sync "${src}" "${dst}" "${RETRY_FLAGS[@]}" "${SYNC_SAFETY_FLAGS[@]}" "$@"
}

invoke_rclone() {
  local cmd="$1"
  local status=0
  rclone "$@" "${PROGRESS_FLAGS[@]}" --log-file "${LOG_FILE}" --log-level INFO || status=$?

  if [[ "${status}" -ne 0 ]]; then
    grep -E "ERROR|Failed" "${LOG_FILE}" | tail -n 5 >&2 || true
    terminate_with_error "rclone ${cmd} failed with exit code ${status}. Check log for details." "${status}"
  fi
}

# ------------------------------------------------------------------------------
# Integrity Verification (rclone check)
# ------------------------------------------------------------------------------
verify_copy_integrity() {
  local src="$1" dst="$2"
  log_audit "Verifying copy: checking that all source files match in destination (--one-way)..."
  run_check_audit "${src}" "${dst}" --one-way
}

verify_sync_integrity() {
  local src="$1" dst="$2"
  log_audit "Verifying sync: ensuring source and destination are 100% identical..."
  run_check_audit "${src}" "${dst}"
}

run_check_audit() {
  local check_status=0
  rclone check "$@" --log-file "${LOG_FILE}" --log-level NOTICE || check_status=$?

  if [[ "${check_status}" -ne 0 ]]; then
    terminate_with_error "Verification audit FAILED with exit code ${check_status}. Review ${LOG_FILE}" "${check_status}"
  fi
  log_audit "Integrity verification PASSED."
}

# ------------------------------------------------------------------------------
# Logging & Process Utilities
# ------------------------------------------------------------------------------
initialize_log_file() {
  local action="$1"
  mkdir -p "${LOG_DIR}"
  LOG_FILE="${LOG_DIR}/transfer-${action}-$(date +%Y%m%d-%H%M%S)-$$.log"
  readonly LOG_FILE
}

log_info() {
  echo "[INFO]  [$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}" >&2
}

log_audit() {
  echo "[AUDIT] [$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}" >&2
}

log_error() {
  echo "[ERROR] [$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

terminate_with_error() {
  local err_msg="$1" err_code="$2"
  log_error "${err_msg}"
  exit "${err_code}"
}

print_summary() {
  echo "--------------------------------------------------------------------------------"
  echo "Job Status: SUCCESS (Verified)"
  echo "Log File:   ${LOG_FILE}"
  echo "--------------------------------------------------------------------------------"
}

main "$@"
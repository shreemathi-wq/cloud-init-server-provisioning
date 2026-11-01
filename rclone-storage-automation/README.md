# File Transfers and Storage Automation with Rclone & MinIO

Production-grade file transfer, synchronization, verification, and storage automation between local filesystems and S3-compatible object storage using **rclone** and **MinIO**.

---

## Architecture Overview

```text
+------------------------------------------------------------------------+
¦                        Execution Environment                           ¦
¦                                                                        ¦
¦   [Local Filesystem]                                                   ¦
¦   +-- sample-data/ (nested docs, PDFs, 100MB lecture binary)           ¦
¦   +-- sample-data-large/ (1GB backup binary)                           ¦
¦           ?                                                            ¦
¦           ¦ transfer.sh / rclone CLI                                   ¦
¦           ?                                                            ¦
¦   [Local Object Storage: MinIO in Docker]                              ¦
¦   +-- Port 9000: S3 REST API (rclone endpoint)                         ¦
¦   +-- Port 9001: Web Console (visual dashboard)                        ¦
¦                                                                        ¦
¦   [Stateless Security Model]                                           ¦
¦   +-- RCLONE_CONFIG=/dev/null (No static rclone.conf on disk)          ¦
¦   +-- :s3: on-the-fly dynamic remote                                  ¦
¦   +-- Injected RCLONE_S3_* environment variables from gitignored .env  ¦
+------------------------------------------------------------------------+
```

---

## Deliverables in this Repository

- [`transfer.sh`](transfer.sh): Production-ready, idempotent transfer automation script with built-in safety guards, logging, and automatic `rclone check` verification.
- [`docker-compose.yml`](docker-compose.yml): Reproducible MinIO S3 object storage container definition with volume persistence and health checks.
- [`.env.example`](.env.example): Template for local MinIO root credentials and read-only access keys.
- [`generate-sample-data.sh`](generate-sample-data.sh): Generates reproducible test data (nested folders, text files, minimal valid PDFs, 100MB and 1GB random binaries).
- [`commands.md`](commands.md): Full command-line reference with explanations and flag breakdowns.
- [`results.md`](results.md): Real experimental outputs, reliability metrics, and answers to team demonstration questions.

---

## Quickstart Guide

### 1. Start Local MinIO Storage
```bash
# Copy environment template and configure secrets (.env is git-ignored)
cp .env.example .env

# Launch MinIO in the background and wait for healthcheck
docker compose up -d --wait

# Generate sample files (100MB in sample-data/, 1GB in sample-data-large/)
./generate-sample-data.sh
```

**MinIO Endpoints:**
- **S3 API:** `http://127.0.0.1:9000` (used by rclone & automation)
- **Web Console:** `http://127.0.0.1:9001` (browser inspection)

---

### 2. Configure Shell for Configuration-Free Execution

Run these in your terminal session. No static `rclone.conf` file is created or read:

```bash
# 1. Enforce stateless execution
export RCLONE_CONFIG=/dev/null

# 2. Export credentials from .env
set -a; source .env; set +a

# 3. Configure S3 endpoint and credentials via environment variables
export RCLONE_S3_PROVIDER=Minio
export RCLONE_S3_ENDPOINT=http://127.0.0.1:9000
export RCLONE_S3_ACCESS_KEY_ID="$MINIO_ROOT_USER"
export RCLONE_S3_SECRET_ACCESS_KEY="$MINIO_ROOT_PASSWORD"

# 4. Verify connection (:s3: dynamically creates the remote)
rclone lsd :s3:
```

---

## `transfer.sh` Automation Engine

`transfer.sh` automates file transfers with production safety defaults:

```bash
./transfer.sh copy <source> <destination> [rclone flags...]
./transfer.sh sync <source> <destination> [--confirm] [rclone flags...]
```

### Key Safety & Operational Features:
1. **Zero-Configuration Dependency:** Automatically sets `export RCLONE_CONFIG=/dev/null`.
2. **Sync Dry-Run by Default:** Running `sync` without `--confirm` safely executes a preview (`--dry-run`) showing what would be transferred or deleted without altering destination files.
3. **Destructive Operation Confirmation:** `sync` only deletes or overwrites files when explicitly passed `--confirm`.
4. **Mass Deletion Protection (`--max-delete`):** Protects against catastrophic data loss if an empty or misconfigured source directory is passed (default: 100 files).
5. **Rollback Backup Folder (`SYNC_BACKUP_DIR`):** When set, moves deleted or modified files into an archive directory instead of destroying them.
6. **Credential Leak Guard:** Refuses paths with inline credentials (`:s3,secret_access_key=...:`) to prevent secret exposure in process tables (`ps aux`) and shell history.
7. **Automatic Integrity Verification:** Executes `rclone check` automatically after every transfer:
   - For `copy`: Runs with `--one-way` (verifies every source file matches in destination).
   - For `sync`: Runs two-way check (verifies source and destination are 100% identical).
8. **Isolated Per-Process Logging:** Writes timestamped logs with PID isolation (`logs/transfer-<op>-<timestamp>-<pid>.log`).

### Usage Examples:

```bash
# 1. Copy files to S3 bucket (idempotent, never deletes destination files)
./transfer.sh copy sample-data :s3:main-bucket/uploads

# 2. Copy large file with bandwidth throttling
./transfer.sh copy sample-data-large :s3:main-bucket/large --bwlimit 50M

# 3. Preview synchronization (dry-run, no changes made)
./transfer.sh sync sample-data :s3:main-bucket/site

# 4. Execute synchronization with confirmation
./transfer.sh sync sample-data :s3:main-bucket/site --confirm

# 5. Safe sync with delete threshold and backup directory
MAX_DELETE=10 SYNC_BACKUP_DIR=:s3:main-bucket/backup \
  ./transfer.sh sync sample-data :s3:main-bucket/site --confirm

# 6. Check exit status (0 = success, 2 = usage error, other = rclone error)
echo $?
```

---

## Production Integration: Calling Rclone from Python / Celery

In a Testpress production backend or Celery worker, tasks should never rely on user home directory configs (`~/.config/rclone/rclone.conf`). Instead, inject environment variables dynamically into a `subprocess` execution:

```python
import os
import subprocess

def transfer_video_asset(local_path: str, bucket_name: str, object_key: str):
    """
    Transfers an asset to S3 securely from a Celery worker without rclone.conf.
    """
    env = os.environ.copy()
    env["RCLONE_CONFIG"] = "/dev/null"
    env["RCLONE_S3_PROVIDER"] = "Minio"  # or "AWS"
    env["RCLONE_S3_ENDPOINT"] = "http://minio:9000"
    env["RCLONE_S3_ACCESS_KEY_ID"] = os.environ["S3_ACCESS_KEY"]
    env["RCLONE_S3_SECRET_ACCESS_KEY"] = os.environ["S3_SECRET_KEY"]

    cmd = [
        "rclone", "copy",
        local_path,
        f":s3:{bucket_name}/{object_key}",
        "--retries", "3",
        "--low-level-retries", "10",
        "--stats", "15s"
    ]

    result = subprocess.run(cmd, env=env, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"Rclone transfer failed (code {result.returncode}): {result.stderr}")

    return result.stdout
```

---

## Technical Questions & Answers

### 1. What happens when `rclone copy` runs twice with the same source and destination?
`rclone copy` is completely idempotent. On the second run, rclone inspects the size and modification timestamps (or checksums) of all files. Because all destination files already match, rclone transfers **0 bytes** and outputs `There was nothing to transfer`.

### 2. What happens if a destination file is missing from the source when `rclone sync` runs?
`rclone sync` forces the destination to mirror the source exactly. Any file existing at the destination that does not exist in the source is **permanently deleted**. Using `--dry-run` allows previewing deletions, `--max-delete` stops runaway deletions, and `--backup-dir` preserves deleted files into an archive.

### 3. How does rclone decide whether a file needs to be transferred?
By default, rclone uses a 4-step decision tree:
1. File missing at destination ? **Transfer**.
2. File size differs ? **Transfer**.
3. Modification time differs ? Compare checksums. If content matches, update destination timestamp without transferring bytes. If content differs ? **Transfer**.
4. Both size and timestamp match ? **Skip**.

### 4. Can rclone transfer directly between two S3 providers without downloading to local disk?
- **Within the same provider/server (e.g. MinIO to MinIO):** Yes. Rclone issues an S3 `CopyObject` API call, performing a **server-side copy**. Zero bytes round-trip through the local machine (`INFO: Copied (server-side copy)`).
- **Between different cloud providers (e.g. MinIO to AWS S3):** Cloud providers do not allow third-party direct server-to-server transfers. The data streams through the host running rclone in memory (streamed via pipe without saving to local disk), using the host's network bandwidth.

### 5. What happens when a network connection is interrupted halfway through a 1 GB upload?
- S3 uses multipart uploads for large files (chunks of 5MB or more). Incomplete files do not appear as valid objects in the bucket until the upload completes.
- If rclone crashes or is killed, unfinished multipart parts remain in S3 storage until cleaned via `rclone backend cleanup :s3:bucket` or an S3 lifecycle expiration policy.
- When restarted, rclone checks destination files: completed files are skipped (`Checks: 100%`), and interrupted files are restarted cleanly.

### 6. How can a Celery worker securely execute rclone without maintaining an `rclone.conf` file?
- Set `RCLONE_CONFIG=/dev/null` to enforce in-memory configuration.
- Pass credentials dynamically via the `env` parameter of `subprocess.run` (`RCLONE_S3_ACCESS_KEY_ID`, `RCLONE_S3_SECRET_ACCESS_KEY`).
- Use the `:s3:` on-the-fly remote syntax.
- Fetch credentials from a secure secrets manager (AWS Secrets Manager, HashiCorp Vault, Kubernetes Secrets) rather than hardcoding them on disk.

---

## Cleanup

To stop MinIO and remove all test data and volumes:

```bash
docker compose down -v
rm -rf sample-data sample-data-large storage-a storage-b downloads logs
```

# Rclone & MinIO Storage Automation: Test Results & Engineering Log

**Role:** DevOps Engineer  
**Date:** November 2, 2026  
**Environment:** Isolated Ubuntu 24.04 LTS Multipass VM (`rclone-vm`)  
**Components:** Docker 29.1.3, Docker Compose 2.40.3, Rclone v1.60.1-DEV, MinIO (Chainguard `cgr.dev/chainguard/minio:latest`)  
**Security Model:** `RCLONE_CONFIG=/dev/null` (100% configuration-free execution)

---

## 1. Environment & Setup Verification

### VM System Profile
```text
$ uname -a
Linux rclone-vm 6.8.0-147-generic #147-Ubuntu SMP PREEMPT_DYNAMIC x86_64 GNU/Linux

$ docker --version && docker compose version && rclone version
Docker version 29.1.3, build 29.1.3-0ubuntu3~24.04.2
Docker Compose version 2.40.3+ds1-0ubuntu1~24.04.1
rclone v1.60.1-DEV
- os/version: ubuntu 24.04 (64 bit)
- os/kernel: 6.8.0-147-generic (x86_64)
- go/version: go1.22.2
```

### Authentic DevOps Incident: Windows CRLF Line Endings in `.env`
During initial MinIO deployment, running `rclone mkdir :s3:main-bucket` failed with:
```text
.env: line 4: $'\r': command not found
net/http: invalid header field value for "Authorization"
```
* **Root Cause Diagnosis:** Files transferred from the Windows 11 host had DOS/Windows `\r\n` line endings. When bash executed `source .env`, the environment variable `MINIO_ROOT_PASSWORD` retained a trailing `\r` carriage return (`minio-secret-key-123\r`). This corrupted the HTTP Authorization header sent to MinIO.
* **Resolution:** Converted all project and environment files to Unix LF line endings using:
  ```bash
  sed -i 's/\r$//' * .env*
  docker compose down && docker compose up -d --wait
  ```
* **Result:** MinIO container `rclone-minio` (ID: `912367c21bb0`) restarted cleanly, passed health checks (`mc ready local`), and bucket creation succeeded immediately.

---

## 2. Configuration-Free Execution (`RCLONE_CONFIG=/dev/null`)

We tested all three methods of executing rclone without creating or maintaining an `rclone.conf` file:

### Test 1: Verifying Memory-Only Configuration
```bash
export RCLONE_CONFIG=/dev/null
rclone config file
```
**Actual Output:**
```text
Configuration is in memory only
```
*Confirmed: rclone does not read from or write to disk.*

### Test 2: Method A — Environment Variables + `:s3:`
```bash
export RCLONE_S3_PROVIDER=Minio
export RCLONE_S3_ENDPOINT=http://127.0.0.1:9000
export RCLONE_S3_ACCESS_KEY_ID="minio-admin"
export RCLONE_S3_SECRET_ACCESS_KEY="minio-secret-key-123"

rclone lsd :s3:
```
**Actual Output:**
```text
          -1 2026-11-02 04:02:43        -1 backup-bucket
          -1 2026-11-02 04:02:43        -1 main-bucket
```

### Test 3: Method B — Command-Line Flags (Without Environment Variables)
```bash
env -u RCLONE_S3_PROVIDER -u RCLONE_S3_ENDPOINT -u RCLONE_S3_ACCESS_KEY_ID -u RCLONE_S3_SECRET_ACCESS_KEY \
  rclone lsd :s3: \
  --s3-provider Minio \
  --s3-endpoint http://127.0.0.1:9000 \
  --s3-access-key-id minio-admin \
  --s3-secret-access-key minio-secret-key-123
```
**Actual Output:**
```text
          -1 2026-11-02 04:02:43        -1 backup-bucket
          -1 2026-11-02 04:02:43        -1 main-bucket
```

### Test 4: Method C — Inline Connection String
```bash
rclone lsd ":s3,provider=Minio,endpoint='http://127.0.0.1:9000',access_key_id=minio-admin,secret_access_key=minio-secret-key-123:"
```
**Actual Output:** Both buckets listed successfully.

### Production Security Assessment:
* **Environment Variables (Method A):** **Recommended for Production.** Credentials stay in process memory and can be securely injected via Celery worker environments, Kubernetes Secrets, or Docker Compose without disk persistence.
* **CLI Flags (Method B) & Connection Strings (Method C):** **Prohibited for Secrets in Production.** Credentials passed as command arguments are visible in plain text to any user executing `ps aux` and get recorded in shell history (`~/.bash_history`).

---

## 3. Basic File Operations & Verification

### Test Dataset
Generated via `./generate-sample-data.sh`:
```text
sample-data/
+-- config/
¦   +-- app.env
+-- courses/
¦   +-- devops-engineering-syllabus.pdf
¦   +-- student-invoice.pdf
+-- streams/
¦   +-- live_class.m3u8
¦   +-- live_stream_metadata.json
+-- recordings/
    +-- live-lecture-1080p.mp4 (100 MB uncompressible binary)
```

### Copy & Idempotency
1. **Initial Copy to `storage-a`:**
   ```bash
   rclone copy sample-data storage-a -v
   ```
   *Transferred 100.001 MiB across all files in 0.4s.*
   *Verification:* `rclone check sample-data storage-a`: `0 differences found, 6 matching files`.
2. **Second Copy (Idempotency Test):**
   ```bash
   rclone copy sample-data storage-a -v
   ```
   *Result:*
   ```text
   There was nothing to transfer
   Checks: 6 / 6, 100%
   Transferred: 0 B / 0 B, Elapsed time: 0.0s
   ```
   *Key Insight:* Rclone checks file sizes and modification timestamps (or MD5 hashes). When identical, zero network bandwidth is consumed.

### Move Operations (`rclone move`)
* Tested moving `storage-temp/moved-file.txt` to `storage-b/`:
  - `storage-b/moved-file.txt` was created.
  - Source directory `storage-temp/` was automatically purged after transfer verification.

### Synchronizing Directories (`rclone sync`)
* Added an untracked file `storage-a/extra.txt`, then ran:
  ```bash
  rclone sync sample-data storage-a -v
  ```
* Output: `INFO: extra.txt: Deleted. Deleted: 1 (files), 0 (dirs)`.
* *Demonstrated:* `sync` forces destination to become an exact copy of source, deleting destination files that do not exist at source.

### Server-Side Copy Between Buckets
```bash
rclone copy :s3:main-bucket/uploads :s3:backup-bucket/backup -v
```
* **Real Output:**
  ```text
  INFO : recordings/live-lecture-1080p.mp4: Copied (server-side copy)
  INFO : courses/devops-engineering-syllabus.pdf: Copied (server-side copy)
  Transferred: 100.001 MiB / 100.001 MiB, 100%, 0 B/s, ETA -
  ```
* **Key Insight:** `(server-side copy)` means the MinIO storage engine cloned the objects internally. Data did not round-trip through the local machine network.

---

## 4. Large File Reliability & Interruption Experiments

### Bandwidth Throttling (`--bwlimit 50M`) on 1 GB File
```bash
rclone copy sample-data-large :s3:main-bucket/large-test --bwlimit 50M --stats 1s --stats-one-line -v
```
**Real Telemetry Captured:**
```text
INFO : Starting bandwidth limiter at 50Mi Byte/s
INFO :         50 MiB / 1 GiB, 5%,  3.498 MiB/s, ETA 4m38s
INFO :    149.996 MiB / 1 GiB, 15%, 16.842 MiB/s, ETA 51s
INFO :    499.996 MiB / 1 GiB, 49%, 34.709 MiB/s, ETA 15s
INFO :    999.996 MiB / 1 GiB, 98%, 42.086 MiB/s, ETA 0s
INFO : testpress-db-snapshot.dump: Copied (new)
INFO :          1 GiB / 1 GiB, 100%, 42.570 MiB/s, ETA 0s
```
*Observation:* Rclone sustained a stable throughput throttle without spiking host CPU.

### Simulated Interruption & Resumption
1. Initiated a multi-file transfer (`part-A.bin`, `part-B.bin`, `part-C.bin`, 30 MB each) with `--transfers 1 --bwlimit 10M`.
2. Halfway through, simulated a network/worker crash by terminating the PID with `SIGKILL`.
3. Inspected destination bucket: `rclone ls :s3:main-bucket/multi-resume` showed only `part-A.bin`. Incomplete parts were discarded cleanly by S3 multipart upload rules.
4. Restarted transfer:
   ```text
   Checks:      1 / 1, 100%   (part-A.bin was detected and skipped)
   Transferred: 2 / 2, 100%   (only part-B.bin and part-C.bin were sent)
   Transferred: 60 MiB / 60 MiB
   ```
   *Verification:* `rclone check`: `0 differences found, 3 matching files`.

---

## 5. Synchronization Safety & Safeguards

| Test | Safeguard Tested | Real Observed Behavior |
|---|---|---|
| **Preview Mode** | `--dry-run` | Showed `Skipped copy` and `Skipped delete` notices; destination disk remained 100% untouched. |
| **Runaway Delete Protection** | `--max-delete 1` | Destination had 2 obsolete files; when threshold was reached, rclone aborted with fatal exit code `7`, preventing mass deletion. |
| **Archive Directory** | `--backup-dir` | Instead of destroying obsolete files, rclone moved them into `dest-backup/` before mirroring the source. |

---

## 6. `transfer.sh` Automated Test Matrix

| Test Case | Command Run | Expected Exit | Actual Result | Status |
|---|---|---|---|---|
| **Help / Missing Args** | `./transfer.sh` | 2 | Exit 2, banner displayed | PASS |
| **Unsupported Op** | `./transfer.sh move ...` | 2 | Exit 2, unsupported op reported | PASS |
| **Inline Secrets in Path** | `./transfer.sh copy ... :s3,secret_access_key=...:` | 2 | Exit 2, credential leak prevented | PASS |
| **Unset Environment Vars** | `env -u RCLONE_S3_ACCESS_KEY_ID ./transfer.sh ...` | 2 | Exit 2, missing variables listed | PASS |
| **Direct `--dry-run` Flag** | `./transfer.sh copy ... --dry-run` | 2 | Exit 2, directed to use sync preview | PASS |
| **Standard Copy** | `./transfer.sh copy sample-data :s3:main-bucket/test` | 0 | Exit 0, verified via `rclone check` | PASS |
| **Throttled Copy** | `./transfer.sh copy sample-data-large ... --bwlimit 60M` | 0 | Exit 0, 1GB transferred in 21s, verified | PASS |
| **Sync Dry-Run** | `./transfer.sh sync sample-data :s3:main-bucket/sync` | 0 | Exit 0, preview only, no files changed | PASS |
| **Sync Execution** | `./transfer.sh sync sample-data ... --confirm` | 0 | Exit 0, verified 100% identical | PASS |

---

## 7. Answers to Team Demonstration Questions

### 1. What happens when `rclone copy` runs twice with the same source and destination?
`rclone copy` is completely idempotent. On the second run, rclone inspects the size and modification timestamps (or hashes). Because all destination files already match, rclone transfers **0 bytes** and outputs `There was nothing to transfer`.

### 2. What happens if a destination file is missing from the source when `rclone sync` runs?
`rclone sync` forces the destination to mirror the source exactly. Any destination file not in the source is **permanently deleted**. In our implementation, `transfer.sh` prevents accidental damage by defaulting to `--dry-run` unless `--confirm` is provided, and enforcing `--max-delete`.

### 3. How does rclone decide whether a file needs to be transferred?
Rclone follows a 4-step decision hierarchy:
1. Missing at destination ? **Transfer**.
2. File size differs ? **Transfer**.
3. Modification time differs ? Compare checksums. If content matches, update destination timestamp without transferring bytes. If content differs ? **Transfer**.
4. Both size and timestamp match ? **Skip**.

### 4. Can rclone transfer directly between two S3 providers without downloading to local disk?
- **Within the same S3 provider/server (e.g. MinIO to MinIO):** Yes, via server-side copy (`INFO: Copied (server-side copy)`). Zero bytes round-trip through the host machine.
- **Between different cloud providers (e.g. MinIO to AWS S3):** No. Cloud providers do not permit third-party direct server-to-server transfers. The data streams through the host running rclone in memory (streamed via pipe without saving to local disk), using the host's network bandwidth.

### 5. What happens when a network connection is interrupted halfway through a 1 GB upload?
- S3 uses multipart uploads for large files (chunks of 5MB or more). Incomplete files do not appear as valid objects in the bucket until the upload completes.
- In our test, when we killed the transfer process, the partial file did not show in `rclone ls`.
- When restarted, rclone skipped previously completed files (`Checks: 100%`) and resumed the remaining files cleanly.
- Lingering incomplete parts can be cleaned up using `rclone backend cleanup :s3:bucket`.

### 6. How can a Celery worker securely execute rclone without maintaining an `rclone.conf` file?
- Set `RCLONE_CONFIG=/dev/null` to enforce stateless execution.
- Pass credentials dynamically via the `env` parameter of `subprocess.run` (`RCLONE_S3_ACCESS_KEY_ID`, `RCLONE_S3_SECRET_ACCESS_KEY`).
- Use the `:s3:` dynamic remote syntax.
- Fetch credentials from a secure secrets store (AWS Secrets Manager, HashiCorp Vault, Kubernetes Secrets) rather than hardcoding them on disk.
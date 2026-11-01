# Results and Observations

What happened when running the commands in commands.md, and why.

All tests were run with `RCLONE_CONFIG=/dev/null`, so no saved rclone config was used.

---

## Local File Operations

### Test data

```text
sample-data/
├── config/app.env
├── docs/
│   ├── notes/chapter-1.txt
│   ├── notes/chapter-2.txt
│   ├── pdfs/invoice.pdf
│   ├── pdfs/syllabus.pdf
│   └── readme.txt
└── videos/lecture-100mb.bin

7 files, 100 MiB in total
```

### How rclone decides whether to copy a file

For each file, rclone checks:

1. Is the file missing at the destination? → Copy it.
2. Is the size different? → Copy it.
3. Is the modification time different? → Compare the checksums. If the content is the same, only update the time. If not, copy the file.
4. Same size and same modification time? → Skip it.

**Seen in the test:** `storage-a` already had two files from an earlier test.

```text
config/app.env: Updated modification time in destination
docs/readme.txt: Copied (new)
...
Checks:       2 / 2
Transferred:  5 / 5
```

- `docs/*` files were missing, so they were copied.
- `videos/lecture-100mb.bin` had the same size and time, so it was skipped.
- `config/app.env` had the same content but a new modification time (the sample-data script had rewritten it). rclone did **not** copy it again. It only updated the time at the destination. 0 bytes were sent.

### Running copy twice

```text
There was nothing to transfer
Checks:  7 / 7, 100%
```

The second run copied nothing, because every file was already the same. Running `copy` again is safe.

### Copy with a changed file and an extra file

- `chapter-1.txt` was edited in the source.
- `dest-only.txt` was added only in the destination.

```text
docs/notes/chapter-1.txt: Copied (replaced existing)
Transferred:  1 / 1
```

- Only the changed file was copied.
- `dest-only.txt` was **kept**. `copy` never deletes.

### Sync

Dry run first:

```text
dest-only.txt: Skipped delete as --dry-run is set (size 20)
Deleted:  1 (files)
```

In a dry run, `Deleted: 1` means "would delete". Nothing was removed.

Real run:

```text
dest-only.txt: Deleted
```

`sync` deleted the file because it was not in the source.

**Why sync can be dangerous:**

- If source and destination are swapped by mistake, sync deletes or overwrites the original files.
- If the source is empty (for example, a disk is not mounted), sync deletes everything in the destination.
- Always run `--dry-run` first and read what it will delete.

### Move

**First move** (destination folder did not exist):

- `docs` disappeared from `storage-a` and appeared in `storage-b`.
- Both folders are on the same disk, so rclone renamed the folder instead of copying each file. This is instant.

**Second move** (same files already in the destination):

```text
Server side directory move failed - fallback to file moves: can't copy directory - destination already exists
readme.txt: Deleted
...
pdfs: Removing directory
notes: Removing directory
There was nothing to transfer
Deleted:  5 (files), 2 (dirs)
```

- The quick rename was not possible, because the destination folder already existed. rclone moved the files one by one.
- No data was sent, because the files were already the same in the destination.
- rclone still deleted the 5 source files. For `move`, the file only needs to end up in the destination.
- `--delete-empty-src-dirs` removed `pdfs` and `notes`, but the top folder `storage-a/docs` stayed (empty). rclone only removes folders inside the source folder, not the source folder itself.

### Delete and purge

```text
rclone delete storage-b --include "*.pdf" -v
docs/pdfs/syllabus.pdf: Deleted
docs/pdfs/invoice.pdf: Deleted
```

- Only the PDF files were deleted.
- The empty `pdfs` folder stayed. `delete` removes files, not folders.

```text
rclone purge storage-b/docs/notes -v
chapter-2.txt: Deleted
chapter-1.txt: Deleted
.../storage-b/docs/notes: Removing directory
```

- `purge` removed the folder and both files in one step.

### Check

When both folders were the same:

```text
0 differences found
7 matching files
```

After breaking three things on purpose (changed `config/app.env`, added `extra.txt`, removed `docs/readme.txt`):

```text
- extra.txt
+ docs/readme.txt
* config/app.env
= docs/pdfs/invoice.pdf
...
3 differences found
5 matching files
exit code: 1
```

- `check` found all three problems.
- The exit code was `1`. Scripts can use this to detect a failed or broken transfer.

---

## Working with S3 Buckets

MinIO ran locally in Docker. rclone connected to it using only environment variables, with no config file.

### Remote from environment variables

```text
$ rclone listremotes
minio:
```

rclone built the `minio` remote from the `RCLONE_CONFIG_MINIO_*` variables. No config file was used.

### Creating buckets

```text
S3 bucket main-bucket: Bucket "main-bucket" created with ACL ""
```

- `ACL ""` means no special permission was set. The bucket is private by default.
- In `rclone lsd minio:`, `-1` means "unknown". S3 does not report bucket size or file count in a simple listing.

### Upload

```text
Transferred:  100.001 MiB / 100.001 MiB, 100%, 84.006 MiB/s
Transferred:  7 / 7, 100%
Elapsed time: 1.4s
```

All 7 files were uploaded. It was fast because MinIO runs on the same machine.

### S3 has no real folders

```text
$ rclone lsd minio:main-bucket
0 2000-01-01 05:30:00   -1 config
0 2000-01-01 05:30:00   -1 docs
0 2000-01-01 05:30:00   -1 videos
```

- S3 stores each file with its full path as its name, for example `docs/notes/chapter-1.txt`.
- rclone shows `docs` as a folder because of the `/` in the names, but no folder is stored in MinIO.
- That is why the folder dates are fake (2000-01-01, shown in Indian time, +5:30).

### Download and verify

```text
$ rclone check sample-data/docs downloads/docs
0 differences found
5 matching files
```

The downloaded files were exactly the same as the originals.

### Copy between buckets (server-side copy)

```text
docs/readme.txt: Copied (server-side copy)
...
Transferred:        100.001 MiB / 100.001 MiB, 100%, 0 B/s
Server Side Copies: 7 @ 100.001 MiB
```

- Both buckets are on the same MinIO server, so rclone asked MinIO to copy the files itself.
- The speed shows `0 B/s` because no data passed through the local machine.
- This saves time and network cost for large files. It only works inside the same S3 service.

`rclone check` afterwards: `0 differences found, 7 matching files`.

### Deleting objects

```text
$ rclone delete minio:backup-bucket --include "docs/**" -v
docs/readme.txt: Deleted
...
$ rclone lsd minio:backup-bucket
0 2000-01-01 05:30:00   -1 videos
```

- After all files under `docs/` were deleted, the `docs` folder disappeared on its own.
- On a local disk, the empty `pdfs` folder stayed after `delete`. Local disks have real folders. S3 does not.

---

## Passing S3 Settings Without a Config File

All tests used `RCLONE_CONFIG=/dev/null` and `rclone listremotes` printed nothing, so no saved remote was used.

### Settings inside the path

The first try failed:

```text
Custom endpoint `http` was not a valid URI
```

rclone treats `:` as the end of the settings, so it read only `endpoint=http`. Wrapping the URL in single quotes (`endpoint='http://127.0.0.1:9000'`) fixed it, and both buckets were listed.

### Password visible in the process list

With settings inside the path, `ps aux` showed the full command, including the password:

```text
rclone copy sample-data-large :s3,provider=Minio,endpoint='http://127.0.0.1:9000',access_key_id=admin,secret_access_key=admin123:main-bucket/large --bwlimit 10M
```

- Any user on the server can see this with `ps`.
- It is also saved in shell history.
- Command-line flags have the same problem, because they are also part of the command line.

### Environment variables

With `RCLONE_S3_*` variables, `ps aux` showed only:

```text
rclone copy sample-data-large :s3:main-bucket/large --bwlimit 10M
```

No password was visible.

### Comparison

| Way | Works without a config file | Password visible in `ps` and history |
|---|---|---|
| Settings inside the path | Yes | Yes |
| Flags | Yes | Yes |
| Environment variables | Yes | **No** |

### Different logins for different operations

A second MinIO user `reader` was created with MinIO's built-in `readonly` policy.

| Command | Login | Result |
|---|---|---|
| `rclone ls :s3:main-bucket` | reader | 403 Access Denied |
| `rclone copy ... :s3:main-bucket/reader-test` | reader | 403 Access Denied |
| `rclone copy ... :s3:main-bucket/admin-test` | admin | `app.env: Copied (new)` |
| `rclone copyto :s3:main-bucket/config/app.env ...` | reader | `Copied (new)` |

- MinIO's built-in `readonly` policy allows only `s3:GetObject` (download) and `s3:GetBucketLocation`. It does **not** allow `s3:ListBucket`.
- So the reader can download a file by its exact name, but cannot list files or upload.
- rclone retried the 403 error 3 times and printed `retrying may help`. Retrying never fixes a wrong password or a missing permission.

### Recommendation for production

Use **environment variables**, filled in automatically from a secrets store (for example AWS Secrets Manager, HashiCorp Vault or Kubernetes Secrets).

- The password does not appear in `ps`, shell history or logs.
- No `rclone.conf` file with passwords is stored on the server.
- Each job (upload worker, reader, admin) gets its own login with only the permissions it needs.
- Passwords can be changed in the secrets store without changing scripts.

Environment variables are not fully secret: the same user and `root` can still read them through `/proc/<pid>/environ`. But they are much safer than putting passwords in the command line.

---

## Large Files, Retries and Interruptions

### Uploading a 1 GB file

```text
Transferred:  1 GiB / 1 GiB, 100%, 83.182 MiB/s
Elapsed time: 11.9s
```

- The file was uploaded as a multipart upload (in pieces, several at a time).
- Running the same command again: `Checks: 1 / 1`, `0 B` transferred. The file was skipped.

### Bandwidth limit

```text
--bwlimit 50M
Transferred:  1 GiB / 1 GiB, 100%, 44.836 MiB/s
Elapsed time: 23.1s
```

- Expected about 20 seconds (1 GiB at 50 MiB/s). It took 23 seconds.
- The average was a little below the limit, because of the slow start and the work at the end to join the pieces.
- Twice as slow as without the limit, as intended.

### Concurrent transfers

| Flag | Time for 7 files (100 MiB) |
|---|---|
| `--transfers 1` | 0.6s |
| `--transfers 8` | 0.5s |

- Almost no difference. With only 7 files, and one big file doing most of the work, there is little to do in parallel.
- `--transfers` helps with many files. One big file is sped up by uploading its pieces in parallel instead (`--s3-upload-concurrency`, default 4).

### Interrupted transfer (Ctrl+C)

The upload was stopped after 2 seconds:

```text
Transferred:  6 / 8, 75%
 *  videos/lecture-100mb.bin: 56%
 *  large/backup-1gb.bin: transferring
```

After stopping:

- `rclone ls` showed only the 6 finished small files.
- The two unfinished files were **not** in the bucket at all. S3 only shows a file once it is fully uploaded.
- `mc ls --incomplete` showed nothing. On `Ctrl+C`, rclone removed the unfinished pieces before it exited.

Running the same command again:

```text
videos/lecture-100mb.bin: Copied (new)
large/backup-1gb.bin: Multi-thread Copied (new)
Checks:       6 / 6
Transferred:  2 / 2
```

- The 6 finished files were **skipped**.
- The 2 unfinished files **started again from 0%**. rclone does not continue a half-finished S3 upload from a previous run.

### Crash (kill -9)

```text
$ rclone ls :s3:main-bucket/crash-test
(nothing)
$ docker exec rclone-minio mc ls --incomplete --recursive local/main-bucket
[2026-11-01 18:07:46 UTC]     0B crash-test/backup-1gb.bin
```

- After a crash, the unfinished upload stays on the server. It is not visible as a file, but its pieces use disk space.
- `rclone backend cleanup -o max-age=0s` removed it.
- On paid storage (AWS, Wasabi), these hidden pieces cost money. Clean them up regularly, or add a bucket rule that deletes unfinished uploads after a few days (AWS: "AbortIncompleteMultipartUpload").

### Retries during a server outage

MinIO was stopped about 8 seconds into a 1 GB upload and started again 10 seconds later.

| Time | Output | Meaning |
|---|---|---|
| 0–10s | `8%` → `18%` | Normal upload |
| ~8s | `Container rclone-minio Stopped` | Server down |
| 10–20s | stuck at `203 MiB` | rclone waits and retries |
| ~18s | `Container rclone-minio Started` | Server back |
| 25s | `backup-1gb.bin: 4%`, total `1.199 GiB` | File started again from 0% |
| 57s | `Multi-thread Copied (new)`, `1 / 1, 100%` | Finished successfully |

- The upload recovered without any manual action.
- The file restarted from 0%. The total became 1.199 GiB = 203 MiB wasted + 1 GiB.
- It took 57 seconds instead of about 35.
- No `Attempt 1/5 failed` line appeared. The low-level retry fixed the problem inside the same run, so a whole-run retry was not needed.
- No unfinished uploads were left in MinIO afterwards.

### Summary

- Finished files are never sent again. Unfinished files always start from 0%.
- A failure costs more with bigger files. A failure at 90% of a 50 GB video re-sends about 45 GB.
- Use `--retries` and `--low-level-retries` for automatic recovery, and run `rclone backend cleanup` (or a bucket rule) to remove pieces left by crashes.

---

## Safe Sync

### Differences between version 1 (bucket) and version 2 (local)

```text
= config/app.env
* docs/readme.txt
+ docs/notes/chapter-3.txt
- docs/pdfs/invoice.pdf
...
3 differences found
5 matching files
```

| Symbol | File | Change in v2 |
|---|---|---|
| `*` | `docs/readme.txt` | Changed |
| `+` | `docs/notes/chapter-3.txt` | New |
| `-` | `docs/pdfs/invoice.pdf` | Deleted |

### Dry run

```text
docs/readme.txt: Skipped copy as --dry-run is set (size 55)
docs/notes/chapter-3.txt: Skipped copy as --dry-run is set (size 18)
docs/pdfs/invoice.pdf: Skipped delete as --dry-run is set (size 431)
```

The dry run showed that `invoice.pdf` would be deleted from the bucket. Nothing was changed.

### Sync with a backup folder

```text
docs/notes/chapter-3.txt: Copied (new)
docs/readme.txt: Copied (server-side copy)
docs/readme.txt: Deleted
docs/readme.txt: Copied (new)
docs/pdfs/invoice.pdf: Copied (server-side copy)
docs/pdfs/invoice.pdf: Deleted
docs/pdfs/invoice.pdf: Moved into backup dir
Renamed: 2
```

- The old `readme.txt` and the deleted `invoice.pdf` were moved into the backup folder before being replaced or removed.
- S3 has no move or rename command. rclone "moves" a file by copying it on the server, then deleting the original.

After the sync:

```text
$ rclone check storage-a/v2 :s3:main-bucket/site
0 differences found
7 matching files

$ rclone ls :s3:main-bucket/site-backup
      431 v1/docs/pdfs/invoice.pdf
       41 v1/docs/readme.txt
```

The bucket matched version 2 exactly. Nothing from version 1 was lost.

### Why sync is dangerous

**Empty source:**

```text
$ rclone sync storage-a/empty :s3:main-bucket/site --dry-run
...
Deleted: 7 (files), 0 (dirs), 100.001 MiB (freed)
```

An empty source means "the destination should be empty", so sync would delete every file.

If the source folder does not exist at all, rclone refuses (`Failed to sync: directory not found`, exit code 3). The danger is a folder that exists but is empty, for example a disk that is not mounted.

**Source and destination swapped:**

```text
$ rclone sync :s3:main-bucket/site-backup storage-a/v2 --dry-run
v1/docs/readme.txt: Skipped copy as --dry-run is set
docs/readme.txt: Skipped delete as --dry-run is set
...
Deleted: 7 (files), 5 (dirs), 100.001 MiB (freed)
```

The local `v2` folder would be replaced by the backup folder's contents.

**Safety limit with `--max-delete 2`:**

```text
docs/pdfs/syllabus.pdf: Skipped delete as --dry-run is set
docs/notes/chapter-1.txt: Skipped delete as --dry-run is set
config/app.env: Got fatal error on delete: --max-delete threshold reached
...
Fatal error received - not attempting retries
Deleted: 2 (files)
```

- Sync stopped at the limit, but 2 files were still deleted first. `--max-delete` limits the damage. It does not prevent it.
- rclone does not retry a fatal error.

### Safety habits

1. Use `copy` unless deletions are really needed.
2. Always run `--dry-run` first and read what will be deleted.
3. Use `--backup-dir`, so deleted or overwritten files are moved, not destroyed.
4. Use `--max-delete N` in scripts to limit the damage of a mistake.
5. Run `rclone check` after the sync.

---

## transfer.sh

### What the script does

| Requirement | How it is done |
|---|---|
| Source and destination as arguments | `./transfer.sh <copy\|sync> <source> <destination>` |
| Copy and sync | First argument. Anything else is refused (exit 2). |
| Progress | Live progress bar on a terminal. Stats every 30 seconds in the log when there is no terminal (for example cron). |
| Logs operations and errors | One log file per run in `logs/`, with the script's own messages and rclone's log. |
| Exit code on failure | rclone's exit code is returned. Wrong usage returns 2. |
| No config file for S3 | `RCLONE_CONFIG=/dev/null` is set inside the script. S3 logins come only from `RCLONE_S3_*` environment variables. |

Extra safety:

- `sync` only previews unless `--confirm` is given.
- `sync` always uses `--max-delete` (default 100), and `--backup-dir` when `SYNC_BACKUP_DIR` is set.
- Passwords inside the path are refused (they would be visible in `ps`).
- Missing S3 login variables are reported before anything runs.
- After every transfer, `rclone check` verifies the result.
- Retries: `--retries 3 --retries-sleep 10s --low-level-retries 10`.

### Test results

| Test | Expected | Result |
|---|---|---|
| No arguments | exit 2 | exit 2, usage shown |
| Operation `move` | exit 2 | exit 2 |
| `:s3:` path without login variables | exit 2 | exit 2, missing variables listed |
| Password inside the path | exit 2 | exit 2 |
| `copy ... --dry-run` | exit 2 | exit 2 |
| Copy to a local folder | exit 0, verified | exit 0, verification passed |
| Copy to MinIO with `--bwlimit 100M` | exit 0, verified | exit 0, verification passed |
| `sync` without `--confirm` | nothing changed | new file was not uploaded |
| `sync --confirm` | exit 0, verified | exit 0, verification passed |
| Wrong password | not 0 | exit 1 after 3 attempts (about 30 seconds) |
| Empty source, `MAX_DELETE=2` | not 0 | exit 7 (fatal error), stopped at the limit |
| Run in a terminal | live progress | progress updated continuously |
| Run without a terminal | quiet, log only | only the script's messages on screen |

Not tested: a transfer that succeeds but then fails verification. This is hard to cause on purpose.

---

## Common Questions

**1. What happens when `rclone copy` runs twice with the same source and destination?**

Nothing is transferred the second time. rclone sees that every file already exists with the same size and modification time, and prints `There was nothing to transfer`. Running copy again is safe.

**2. What happens if a file exists in the destination but not in the source when `rclone sync` runs?**

It is deleted from the destination. `sync` makes the destination an exact copy of the source. `--dry-run` shows these deletes before they happen, and `--backup-dir` keeps a copy of deleted files.

**3. How does rclone decide whether a file needs to be transferred?**

1. Missing in the destination: copy.
2. Different size: copy.
3. Different modification time: compare checksums. If the content is the same, only update the time. Otherwise copy.
4. Same size and same modification time: skip.

This can be changed with flags such as `--checksum`, `--size-only` and `--ignore-existing`.

**4. Can rclone transfer data directly between two S3 providers without downloading it to the local machine?**

- **Within the same S3 service** (for example two buckets on one MinIO server): yes. rclone asks the server to copy the data itself (server-side copy). In our test: `Server Side Copies: 7 @ 100 MiB`, at `0 B/s` on the local machine.
- **Between two different providers** (for example MinIO to AWS): no. The data flows through the machine running rclone. It is streamed, not saved to disk, but it uses that machine's network bandwidth. This is from the rclone documentation; it was not tested in this project.

**5. What happens when the network breaks halfway through a 1 GB upload?**

- The half-uploaded file does **not** appear in the bucket. S3 only shows complete files.
- If the outage is short, rclone retries by itself (`--low-level-retries`, `--retries`). In our test, the upload survived a 10-second MinIO outage, but the 1 GB file **restarted from 0%** (about 200 MB was wasted).
- If rclone is stopped and run again, finished files are skipped, and unfinished files start again from 0%.
- If rclone crashes (`kill -9`), the unfinished upload pieces stay on the server and use space. Remove them with `rclone backend cleanup`, or with a bucket rule that deletes unfinished uploads.

**6. How would you run rclone securely from a Celery worker without an `rclone.conf` file?**

- Use the `:s3:` remote and pass settings as `RCLONE_S3_*` environment variables, through the `env` argument of `subprocess.run`. Set `RCLONE_CONFIG=/dev/null`.
- Load the credentials from a secrets store (for example AWS Secrets Manager, Vault or Kubernetes Secrets), not from code or files.
- Never put passwords in the command line. In our test, they were visible in `ps` and saved in shell history.
- Give each worker type its own login with only the permissions it needs (for example read-only for workers that only download), or use cloud IAM roles where available.
- Check the exit code and treat any non-zero code as a failed task, so Celery can retry it.


# Rclone Commands

Common rclone commands for local folders and S3 storage, with a short explanation for each one.

## Setup

Start MinIO and create test data (first time only):

```bash
cp .env.example .env            # then set your own passwords
docker compose up -d --wait
./generate-sample-data.sh
mkdir -p storage-a storage-b
```

- `sample-data/` is the source. `sample-data-large/` holds a 1 GB file.
- `storage-a/` and `storage-b/` act as two local storage locations.

Prepare the terminal (every new terminal):

```bash
export RCLONE_CONFIG=/dev/null          # never read a saved rclone config
set -a; source .env; set +a             # load MinIO logins

export RCLONE_S3_PROVIDER=Minio
export RCLONE_S3_ENDPOINT=http://127.0.0.1:9000
export RCLONE_S3_ACCESS_KEY_ID="$MINIO_ROOT_USER"
export RCLONE_S3_SECRET_ACCESS_KEY="$MINIO_ROOT_PASSWORD"
```

- `RCLONE_CONFIG=/dev/null` makes sure every command works on its own, without a saved config.
- `set -a` exports every variable loaded after it. `set +a` turns this off.
- `:s3:` in a path means "an S3 remote built from the `RCLONE_S3_*` variables". For example, `:s3:main-bucket/docs` is the `docs` folder in the `main-bucket` bucket.

## Useful Flags

| Flag | What it does |
|---|---|
| `-v` | Show what rclone does, file by file |
| `-P` | Show a live progress bar |
| `--dry-run` | Show what would happen, but change nothing |

## Listing Files

```bash
rclone lsd  sample-data      # folders only (top level)
rclone ls   sample-data      # all files, with size
rclone lsl  sample-data      # all files, with size and modification time
rclone lsf  sample-data      # names only, top level (add -R to go inside folders)
rclone tree sample-data      # tree view
rclone size sample-data      # number of files and total size
```

- `lsd` and `lsf` show only the top level.
- `ls`, `lsl`, `tree` and `size` go inside all folders.

## Copy, Sync and Move

### Copy

```bash
rclone copy sample-data storage-a -v
```

- Copies new and changed files. Skips files that are already the same.
- Never deletes anything.

### Sync

```bash
rclone sync sample-data storage-a --dry-run -v    # preview first
rclone sync sample-data storage-a -v              # then run it
```

- Makes the destination exactly the same as the source.
- **Deletes files in the destination that are not in the source.**

### Move

```bash
rclone move storage-a/docs storage-b/docs -v
rclone move storage-a/docs storage-b/docs -v --delete-empty-src-dirs
```

- Copies files to the destination, then deletes them from the source (cut and paste).
- `--delete-empty-src-dirs` also removes empty folders left in the source.

### Comparison

| Command | Adds or updates files in the destination | Deletes extra files in the destination | Deletes files from the source |
|---|---|---|---|
| `copy` | Yes | No | No |
| `sync` | Yes | **Yes** | No |
| `move` | Yes | No | **Yes** |

## Deleting Files

```bash
rclone delete storage-b --include "*.pdf" --dry-run -v   # preview
rclone delete storage-b --include "*.pdf" -v             # delete PDF files only
rclone delete storage-b --include "*.pdf" --rmdirs -v    # also remove empty folders
rclone purge  storage-b/docs/notes -v                    # remove a folder and everything in it
```

- `delete` removes files only, and supports filters like `--include`. Folders stay unless you add `--rmdirs`.
- `purge` removes the whole folder. It **ignores filters**, so be careful.

## Checking Files

`rclone check` tells you whether two locations contain the same files. It never changes anything.

```bash
rclone check sample-data storage-b
echo $?            # 0 = everything matches, 1 = something is different
```

To ignore files that exist only in the destination:

```bash
rclone check sample-data storage-b --one-way
```

To get a per-file report:

```bash
rclone check sample-data storage-b --combined -
```

It prints one line per file, starting with a symbol:

```text
= docs/pdfs/invoice.pdf     ← same in both places
* config/app.env            ← in both places, but the content is different
+ docs/readme.txt           ← missing from the destination
- extra.txt                 ← only in the destination
```

## Working with S3 Buckets

### Create and list buckets

```bash
rclone mkdir :s3:main-bucket -v
rclone mkdir :s3:backup-bucket -v
rclone lsd :s3:
```

### Upload, list and download

```bash
rclone copy sample-data :s3:main-bucket -v                   # upload
rclone ls   :s3:main-bucket                                  # all files with size
rclone size :s3:main-bucket                                  # number of files and total size
rclone lsd  :s3:main-bucket                                  # "folders" (prefixes)
rclone copy :s3:main-bucket/docs downloads/docs -v           # download
rclone check sample-data/docs downloads/docs                   # verify the download
```

- S3 has no real folders. A "folder" is just the start of file names like `docs/notes/chapter-1.txt`.

### Copy between buckets

```bash
rclone copy :s3:main-bucket :s3:backup-bucket -v
rclone check :s3:main-bucket :s3:backup-bucket
```

- Both buckets are on the same server, so the server copies the data itself (server-side copy). The data does not pass through your machine.

### Delete objects

```bash
rclone deletefile :s3:backup-bucket/config/app.env -v    # delete one file
rclone delete :s3:backup-bucket --include "docs/**" -v   # delete everything under docs/
```

- `**` in a filter means "everything inside, at any depth".

## Passing S3 Settings

rclone can get S3 settings in three ways, without a config file.

### Inside the path

```bash
rclone lsd ":s3,provider=Minio,endpoint='http://127.0.0.1:9000',access_key_id=$MINIO_ROOT_USER,secret_access_key=$MINIO_ROOT_PASSWORD:"
```

- Values that contain `:` (like the endpoint URL) must be in single quotes.
- **Not safe:** the password is visible in `ps` and saved in shell history.

### Command-line flags

```bash
rclone lsd :s3: \
  --s3-provider Minio \
  --s3-endpoint http://127.0.0.1:9000 \
  --s3-access-key-id "$MINIO_ROOT_USER" \
  --s3-secret-access-key "$MINIO_ROOT_PASSWORD"
```

- **Not safe:** flags are part of the command line, so the password is visible in `ps`.

### Environment variables (recommended)

```bash
export RCLONE_S3_ACCESS_KEY_ID="$MINIO_ROOT_USER"
export RCLONE_S3_SECRET_ACCESS_KEY="$MINIO_ROOT_PASSWORD"
rclone lsd :s3:
```

- `RCLONE_S3_<SETTING>` is the same as the flag `--s3-<setting>`.
- The password is not visible in `ps` or shell history.

## Using Different Logins

Create a read-only user in MinIO. `mc` is MinIO's admin tool inside the container. Set `READER_ACCESS_KEY` and `READER_SECRET_KEY` in `.env` first.

```bash
set -a; source .env; set +a

docker exec rclone-minio sh -c 'mc alias set local http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"'

docker exec -e READER_ACCESS_KEY -e READER_SECRET_KEY rclone-minio \
  sh -c 'mc admin user add local "$READER_ACCESS_KEY" "$READER_SECRET_KEY" && mc admin policy attach local readonly --user "$READER_ACCESS_KEY"'
```

- `docker exec -e NAME` (without `=value`) passes the value into the container without writing it in the command line.

Use a login for one command only, with `NAME=value command`:

```bash
# Reader: download one known file (works)
RCLONE_S3_ACCESS_KEY_ID="$READER_ACCESS_KEY" RCLONE_S3_SECRET_ACCESS_KEY="$READER_SECRET_KEY" \
  rclone copyto :s3:main-bucket/config/app.env downloads/reader-app.env -v

# Reader: list (fails with 403 Access Denied)
RCLONE_S3_ACCESS_KEY_ID="$READER_ACCESS_KEY" RCLONE_S3_SECRET_ACCESS_KEY="$READER_SECRET_KEY" \
  rclone ls :s3:main-bucket

# Admin, from the exported variables: upload (works)
rclone copy sample-data/config :s3:main-bucket/admin-test -v
```

- `copyto` copies one file to an exact name, so rclone does not need to list the bucket.
- The same works for `RCLONE_S3_ENDPOINT`, to use a different server for one command.

## Large Files and Speed

```bash
rclone copy sample-data-large :s3:main-bucket/large -P                    # live progress
rclone copy sample-data-large :s3:main-bucket/large -v --stats 5s         # summary every 5s (good for logs)
rclone copy sample-data-large :s3:main-bucket/large-limited -P --bwlimit 50M   # max 50 MiB/s
rclone copy sample-data :s3:main-bucket/t8 -P --transfers 8               # 8 files at once
rclone copy storage-a/mixed :s3:main-bucket/mixed -P --order-by size,ascending # small files first
```

- Files bigger than 200 MiB are uploaded in pieces (multipart upload), automatically.
- `--bwlimit` keeps other traffic on the server from slowing down.
- `--transfers` (default 4) helps with many files. It does not speed up one big file.

## Retries and Interruptions

### Upload stopped by the user (Ctrl+C)

**What this simulates:** someone stops an upload halfway, or the job is cancelled.

**Steps**

```bash
# 1. Make a folder with small files and the 1 GB file
rclone copy sample-data storage-a/mixed
rclone copy sample-data-large storage-a/mixed/large

# 2. Upload it slowly (small files first), and press Ctrl+C while the big file is uploading
rclone copy storage-a/mixed :s3:main-bucket/mixed -P --bwlimit 30M --order-by size,ascending

# 3. See what reached the bucket
rclone ls :s3:main-bucket/mixed

# 4. Run the same upload again
rclone copy storage-a/mixed :s3:main-bucket/mixed -P -v
```

**What you'll see**

- After step 2, only the finished small files are in the bucket. The half-uploaded big file is not there at all.
- In step 4, the small files are skipped and the big file starts again from 0%.

**Why it matters:** S3 never shows a half-written file, and re-running is safe. But an unfinished file is always sent again from the beginning.

### rclone crashes during an upload

**What this simulates:** rclone is killed without warning, for example by a server crash or a power cut.

**Steps**

```bash
# 1. Start an upload in the background
rclone copy sample-data-large :s3:main-bucket/crash-test --bwlimit 30M &

# 2. After 5 seconds, kill rclone hard (kill -9 gives it no chance to clean up)
sleep 5
kill -9 %1

# 3. Look for unfinished upload pieces left on the server
docker exec rclone-minio mc ls --incomplete --recursive local/main-bucket

# 4. Remove them
rclone backend cleanup :s3:main-bucket -o max-age=0s -v
```

**What you'll see**

- `rclone ls` shows nothing for `crash-test`, but step 3 lists an unfinished upload.
- After step 4, step 3 shows nothing.

**Why it matters:** large files are uploaded in pieces. After a crash, those pieces stay on the server and use space. On paid storage, you pay for them, so clean them up regularly.

- `rclone backend list-multipart-uploads` does not show these pieces on MinIO. Use `mc ls --incomplete` instead.
- Without `-o max-age=0s`, cleanup only removes pieces older than 24 hours.

### Storage server goes down during an upload

**What this simulates:** the storage server or the network stops working for a few seconds while a large file is uploading.

**Steps**

```bash
# 1. In the background: stop MinIO after 8 seconds, start it again 10 seconds later
( sleep 8; docker compose stop minio; sleep 10; docker compose start minio ) &

# 2. Upload the 1 GB file slowly, with retries turned on
rclone copy sample-data-large :s3:main-bucket/retry-test \
  --bwlimit 30M -v --stats 5s \
  --retries 5 --retries-sleep 10s --low-level-retries 3
```

**What you'll see**

- The progress stops while MinIO is down.
- When MinIO is back, the upload continues on its own and finishes.
- The 1 GB file restarts from 0%, so the total transferred is more than 1 GB.

**Why it matters:** rclone recovers from short outages without anyone restarting it. But a big file that fails partway has to be sent again from the beginning.

The retry flags:

| Flag | Meaning | Default |
|---|---|---|
| `--low-level-retries` | Retry one request (for example one upload piece) | 10 |
| `--retries` | Run the whole command again if it still has errors | 3 |
| `--retries-sleep` | Wait between whole-command retries | 0 |

Add `-vv` to see the retry messages.

## Safe Sync

### Check, preview, sync with backup, check again

```bash
rclone check storage-a/v2 :s3:main-bucket/site --combined -     # 1. differences
rclone sync storage-a/v2 :s3:main-bucket/site --dry-run -v      # 2. preview

rclone sync storage-a/v2 :s3:main-bucket/site \
  --backup-dir :s3:main-bucket/site-backup/v1 -v                # 3. sync, keep old files

rclone check storage-a/v2 :s3:main-bucket/site                  # 4. verify
```

- `--backup-dir` moves files that sync would delete or overwrite into another folder. It must be on the same remote, and outside the destination.

To try it, create a second version first:

```bash
rclone copy sample-data :s3:main-bucket/site                    # version 1 in the bucket
rclone copy sample-data storage-a/v2                              # version 2 locally
echo "updated in v2" >> storage-a/v2/docs/readme.txt              # changed file
rm storage-a/v2/docs/pdfs/invoice.pdf                             # deleted file
echo "brand new chapter" > storage-a/v2/docs/notes/chapter-3.txt  # new file
```

### Dangerous sync mistakes

**What this shows:** two common mistakes that make `sync` delete data, and a limit that reduces the damage. Every command uses `--dry-run`, so nothing is actually deleted.

**Mistake 1: the source folder is empty** (for example, a disk that is not mounted)

```bash
mkdir -p storage-a/empty
rclone sync storage-a/empty :s3:main-bucket/site --dry-run
```

You'll see: every file in the bucket marked for deletion. An empty source means "make the destination empty".

**Mistake 2: source and destination swapped**

```bash
rclone sync :s3:main-bucket/site-backup storage-a/v2 --dry-run
```

You'll see: your local `v2` files marked for deletion, and replaced by the backup folder's files.

**Safety limit: stop after a number of deletes**

```bash
rclone sync storage-a/empty :s3:main-bucket/site --dry-run --max-delete 2
```

You'll see: 2 files marked for deletion, then the sync stops with `--max-delete threshold reached`.

**Why it matters:** one wrong argument can wipe a bucket. Always preview with `--dry-run`, and use `--max-delete` in scripts. It doesn't prevent the first N deletes, but it stops a mistake from deleting everything.

## transfer.sh

```bash
./transfer.sh                                                     # show usage
./transfer.sh copy sample-data :s3:main-bucket/uploads          # copy, then verify
./transfer.sh copy sample-data-large :s3:main-bucket/large --bwlimit 30M   # extra rclone flags
./transfer.sh sync storage-a/v2 :s3:main-bucket/site            # preview only
./transfer.sh sync storage-a/v2 :s3:main-bucket/site --confirm  # real sync, then verify
echo $?                                                           # 0 = success
```

Optional settings:

```bash
MAX_DELETE=10 ./transfer.sh sync storage-a/v2 :s3:main-bucket/site --confirm   # stop after 10 deletes
SYNC_BACKUP_DIR=:s3:main-bucket/backup/$(date +%F) \
  ./transfer.sh sync storage-a/v2 :s3:main-bucket/site --confirm               # keep deleted files
LOG_DIR=/var/log/transfers ./transfer.sh copy sample-data :s3:main-bucket/x    # logs elsewhere
```

Failure cases:

```bash
RCLONE_S3_SECRET_ACCESS_KEY=wrong ./transfer.sh copy sample-data :s3:main-bucket/x   # exit 1
MAX_DELETE=2 ./transfer.sh sync storage-a/empty storage-b/script-test --confirm         # exit 7
```

- `--dry-run` is refused. Use `sync` without `--confirm` to preview.

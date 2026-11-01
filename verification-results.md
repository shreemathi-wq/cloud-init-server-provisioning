# Verification Results

All checks passed on: **2026-11-02** using **Multipass 1.17.0+win** on **Windows 11**.

VM launched with:
```powershell
multipass launch 24.04 `
  --name testpress-vm `
  --cpus 2 `
  --memory 2G `
  --disk 10G `
  --cloud-init cloud-init.yaml
```

Output:
```
Launched: testpress-vm in zone1
```

---

## Check 1 — Cloud-Init Completed Without Errors

```powershell
multipass exec testpress-vm -- cloud-init status --long
```

```
status: done
extended_status: done
boot_status_code: enabled-by-generator
last_update: Thu, 01 Jan 1970 00:03:22 +0000
detail: DataSourceNoCloud [seed=/dev/sr0]
errors: []
recoverable_errors: {}
```

✅ `status: done` — `errors: []` — provisioning completed cleanly.

---

## Check 2 — Required Packages Are Installed

```powershell
multipass exec testpress-vm -- bash -c "
docker --version
git --version
curl --version | head -1
ffmpeg -version 2>&1 | head -1
"
```

```
Docker version 29.1.3, build 29.1.3-0ubuntu3~24.04.2
git version 2.43.0
curl 8.5.0 (x86_64-pc-linux-gnu) libcurl/8.5.0 OpenSSL/3.0.13 ...
ffmpeg version 6.1.1-3ubuntu5 Copyright (c) 2000-2023 the FFmpeg developers
```

✅ All four packages installed.

---

## Check 3 — testpress User Exists and Is In the Docker Group

```powershell
multipass exec testpress-vm -- id testpress
```

```
uid=1000(testpress) gid=1001(testpress) groups=1001(testpress),1000(docker)
```

✅ User created. `docker` group is present in `groups=`.

---

## Check 4 — testpress Can Run Docker Without sudo

```powershell
multipass exec testpress-vm -- sudo -u testpress docker ps
```

```
CONTAINER ID   IMAGE          COMMAND                  CREATED         STATUS                   PORTS                                     NAMES
618a70e4f839   nginx:alpine   "/docker-entrypoint.…"   3 minutes ago   Up 3 minutes (healthy)   0.0.0.0:8080->80/tcp, [::]:8080->80/tcp   testpress-web
```

✅ testpress can access the Docker socket directly — no sudo needed.

> Note: `multipass exec` runs as the `ubuntu` user, not `testpress`, so
> `docker ps` without sudo would fail for ubuntu (expected — only testpress
> was added to the docker group). We use `sudo -u testpress` to run as testpress.

---

## Check 5 — Application Directory and Files Exist With Correct Ownership

```powershell
multipass exec testpress-vm -- ls -la /opt/testpress/
```

```
total 16
drwxr-xr-x 2 testpress testpress 4096 Nov  2  2026 .
drwxr-xr-x 4 root      root      4096 Nov  2 01:41 ..
-rw-r----- 1 testpress testpress   53 Nov  2  2026 app.env
-rw-r--r-- 1 testpress testpress   22 Nov  2  2026 index.html
```

✅ Directory and both files owned by `testpress:testpress`.

> `app.env` permissions are `0640` (owner: rw, group: r, others: none).
> Running `cat app.env` as the `ubuntu` user correctly returns "Permission denied" —
> this is intended security behaviour, not a bug.

---

## Check 6 — Environment File Contains Correct Values

```powershell
multipass exec testpress-vm -- sudo cat /opt/testpress/app.env
```

```
APP_NAME=Testpress
APP_ENV=development
APP_PORT=8080
```

✅ All three environment variables present and correct.

---

## Check 7 — Systemd Service Is Active and Enabled

```powershell
multipass exec testpress-vm -- bash -c "
systemctl is-active testpress.service
systemctl is-enabled testpress.service
"
```

```
active
enabled
```

✅ Service is running and configured to start automatically on boot.

---

## Check 8 — Docker Container Is Running and Healthy

```powershell
multipass exec testpress-vm -- sudo docker ps
```

```
CONTAINER ID   IMAGE          COMMAND                  CREATED         STATUS                   PORTS                                     NAMES
618a70e4f839   nginx:alpine   "/docker-entrypoint.…"   3 minutes ago   Up 3 minutes (healthy)   0.0.0.0:8080->80/tcp, [::]:8080->80/tcp   testpress-web
```

```powershell
multipass exec testpress-vm -- sudo docker inspect --format='{{.State.Health.Status}}' testpress-web
```

```
healthy
```

✅ Container is up. Health check reports `healthy`.

---

## Check 9 — HTTP Application Returns Correct Response on Port 8080

```powershell
multipass exec testpress-vm -- curl -s http://localhost:8080
```

```
Hello from Testpress!
```

✅ Application is accessible on port 8080 and returns the expected response.

---

## Check 10 — Application Starts Automatically After Reboot

```powershell
multipass restart testpress-vm
multipass exec testpress-vm -- bash -c "
systemctl is-active testpress.service
curl -s http://localhost:8080
"
```

```
active
Hello from Testpress!
```

✅ After a full VM reboot, the service came back up automatically and the
application is serving traffic — no manual intervention required.

---

## Check 11 — Application Restarts Automatically After a Crash

```powershell
multipass exec testpress-vm -- bash -c "
echo 'Killing container...'
sudo docker kill testpress-web
echo 'Waiting 10 seconds for restart...'
sleep 10
echo 'Container status:'
sudo docker ps
echo 'HTTP response:'
curl -s http://localhost:8080
"
```

```
Killing container...
testpress-web
Waiting 10 seconds for restart...
Container status:
CONTAINER ID   IMAGE          COMMAND                  CREATED        STATUS                            PORTS                                     NAMES
d4b54e4a7767   nginx:alpine   "/docker-entrypoint.…"   4 seconds ago  Up 4 seconds (health: starting)   0.0.0.0:8080->80/tcp, [::]:8080->80/tcp   testpress-web
HTTP response:
Hello from Testpress!
```

✅ The container was killed to simulate a crash. Systemd detected the exit
(via `Restart=always`) and restarted the container within 5 seconds
(`RestartSec=5`). A new container ID (`d4b54e4a7767`) confirms a fresh restart.
The application was already serving traffic after 10 seconds.

---

## Summary

| # | Requirement | Result |
|---|-------------|--------|
| 1 | Cloud-init completes without errors | ✅ `status: done`, `errors: []` |
| 2 | Docker installed | ✅ v29.1.3 |
| 3 | Git installed | ✅ v2.43.0 |
| 4 | curl installed | ✅ v8.5.0 |
| 5 | FFmpeg installed | ✅ v6.1.1 |
| 6 | testpress user created | ✅ uid=1000 |
| 7 | testpress in docker group | ✅ groups include docker |
| 8 | testpress can run docker without sudo | ✅ |
| 9 | /opt/testpress directory exists | ✅ owned by testpress:testpress |
| 10 | app.env exists with correct content | ✅ |
| 11 | HTTP response on port 8080 | ✅ `Hello from Testpress!` |
| 12 | Service active and enabled | ✅ |
| 13 | Container healthy | ✅ |
| 14 | Survives reboot | ✅ |
| 15 | Survives crash (Restart=always) | ✅ restarted in ~5 seconds |
| 16 | No manual SSH required | ✅ fully automated |

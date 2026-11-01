# Automated Server Provisioning with Cloud-Init

A complete, automated Linux server provisioning setup using **cloud-init** and **Multipass**. The VM is fully configured on first boot — no manual SSH required.

---

## Table of Contents

1. [Project Structure](#project-structure)
2. [What This Provisions](#what-this-provisions)
3. [Prerequisites](#prerequisites)
4. [How to Deploy](#how-to-deploy)
5. [Verify the Setup](#verify-the-setup)
6. [How Cloud-Init Works — Stages Explained](#how-cloud-init-works--stages-explained)
7. [Once vs Every Boot](#once-vs-every-boot)
8. [Bonus Topics](#bonus-topics)
   - [Systemd Service](#systemd-service)
   - [Health Check](#health-check)
   - [First-Boot Provisioning](#first-boot-provisioning)
   - [Cloud-Init vs Dockerfile](#cloud-init-vs-dockerfile)
   - [User-Data and Metadata](#user-data-and-metadata)

---

## Project Structure

```
cloud-init/
├── cloud-init.yaml          # Main provisioning configuration
├── README.md                # This file
└── verification-results.md  # Commands and outputs used to verify the setup
```

---

## What This Provisions

| Component | Detail |
|---|---|
| OS | Ubuntu 24.04 LTS |
| Packages | docker.io, git, curl, ffmpeg |
| User | `testpress` (non-root, in docker group) |
| App directory | `/opt/testpress` |
| Environment file | `/opt/testpress/app.env` |
| Application | nginx:alpine Docker container serving `Hello from Testpress!` |
| Port | `8080` |
| Auto-start | systemd service (`testpress.service`) |
| Auto-restart | `Restart=always` in the systemd unit |
| Health check | `wget` against localhost every 30 seconds |

---

## Prerequisites

- Windows 11 with PowerShell
- [Multipass](https://multipass.run) installed (`multipass 1.17.0+win` or later)
- Multipass Windows service running (`Get-Service Multipass`)

Verify Multipass is ready:

```powershell
multipass version
Get-Service Multipass
```

---

## How to Deploy

### 1. Launch the VM with cloud-init

```powershell
# From the project directory
multipass launch 24.04 `
  --name testpress-vm `
  --cpus 2 `
  --memory 2G `
  --disk 10G `
  --cloud-init cloud-init.yaml
```

Multipass will:
- Download the Ubuntu 24.04 image (first time only)
- Create the VM
- Pass `cloud-init.yaml` as user-data
- Wait for cloud-init to complete before returning

> Cloud-init provisioning typically takes 2–5 minutes on first boot
> (package installation and Docker image pull take the most time).

### 2. Confirm the VM is running

```powershell
multipass list
```

Expected output:

```
Name              State    IPv4             Image
testpress-vm      Running  <IP_ADDRESS>     Ubuntu 24.04 LTS
```

### 3. Test the application

```powershell
# Replace <IP_ADDRESS> with the IP from multipass list
curl http://<IP_ADDRESS>:8080
```

Expected response:

```
Hello from Testpress!
```

### 4. To delete and re-provision cleanly

```powershell
multipass delete testpress-vm
multipass purge
multipass launch 24.04 --name testpress-vm --cpus 2 --memory 2G --disk 10G --cloud-init cloud-init.yaml
```

---

## Verify the Setup

Full verification commands with expected outputs are documented in
[`verification-results.md`](./verification-results.md).

Quick summary of what to check:

```powershell
# Shell into the VM
multipass shell testpress-vm
```

```bash
# Inside the VM:
cloud-init status                        # done
id testpress                             # uid=..., groups=...,docker,...
ls -la /opt/testpress/                   # app.env and index.html present
cat /opt/testpress/app.env               # APP_NAME, APP_ENV, APP_PORT
systemctl is-active testpress.service    # active
docker ps                                # testpress-web running
curl http://localhost:8080               # Hello from Testpress!
```

---

## How Cloud-Init Works — Stages Explained

Cloud-init processes the user-data YAML through a series of stages, in this order:

### Stage 1 — Generator
Cloud-init detects whether it should run at all (checks for `/var/lib/cloud/instance/`). Runs on every boot.

### Stage 2 — Local (`cloud-init-local.service`)
Runs before networking is up. Applies network configuration from metadata. Runs on every boot.

### Stage 3 — Network (`cloud-init.service`)
Runs after basic networking is available. Processes `bootcmd`.

**`bootcmd`** (our use: `mkdir -p /opt/testpress`):
- Runs as a shell command very early
- Executes on **every boot**
- Use only for things that genuinely need to happen on every boot (early mounts, directory seeds, etc.)
- We use it here because `write_files` needs `/opt/testpress` to exist before it runs

### Stage 4 — Config (`cloud-config.service`)
The main configuration stage. Processes:

| Module | What It Does | Runs |
|--------|-------------|------|
| `package_update` | `apt-get update` | Once |
| `packages` | `apt-get install docker.io git curl ffmpeg` | Once |
| `users` | Creates the `testpress` user | Once |
| `write_files` | Writes `app.env`, `index.html`, `testpress.service` | Once |

### Stage 5 — Final (`cloud-final.service`)
Runs last, after all config modules. Processes:

| Module | What It Does | Runs |
|--------|-------------|------|
| `runcmd` | Runs shell commands in order | Once (first boot only) |

Our `runcmd` steps:
1. `chown testpress:testpress /opt/testpress` — fix directory ownership
2. `chown testpress:testpress /opt/testpress/app.env` — fix file ownership
3. `chown testpress:testpress /opt/testpress/index.html` — fix file ownership
4. `usermod -aG docker testpress` — add user to Docker group
5. `systemctl enable --now docker` — start Docker daemon
6. `systemctl daemon-reload` — register the new `testpress.service` unit
7. `systemctl enable --now testpress.service` — start the application

---

## Once vs Every Boot

This is one of the most important things to understand about cloud-init:

| Directive | Runs On |
|-----------|---------|
| `bootcmd` | **Every boot** |
| `package_update` | First boot only |
| `packages` | First boot only |
| `users` | First boot only |
| `write_files` | First boot only |
| `runcmd` | **First boot only** |

The instance identity is stored in `/var/lib/cloud/instance/`. On subsequent boots, cloud-init sees the same instance ID and skips all first-boot modules. Only `bootcmd` (and network config) re-runs.

**Practical consequence:**  
If you edit `cloud-init.yaml` and reboot the same VM, `runcmd` will **not** re-run. To apply changes, you must delete and re-create the VM (`multipass delete` + `multipass launch`).

**Idempotency:**  
Cloud-init is designed so that first-boot operations are safe to replay. For example:
- `mkdir -p` does not fail if the directory already exists
- `usermod -aG docker testpress` does not duplicate group membership
- `systemctl enable` does not fail if already enabled

---

## Bonus Topics

### Systemd Service

The application is managed by a systemd unit at `/etc/systemd/system/testpress.service`.

Key directives explained:

```ini
[Unit]
Requires=docker.service        # Hard dependency: if docker stops, this stops too
After=docker.service           # Start order: wait for docker to be active first
Wants=network-online.target    # Soft dependency: prefer network to be up

[Service]
Restart=always                 # Restart on any exit code (crash or clean stop)
RestartSec=5                   # Wait 5 seconds before restarting
TimeoutStartSec=300            # Give Docker up to 5 min to pull and start nginx
ExecStartPre=...docker rm -f   # Clean up any leftover container before starting
ExecStart=...docker run        # The main process systemd manages
ExecStop=...docker stop        # Gracefully stop the container on service stop
ExecStopPost=...docker rm -f   # Clean up the container after stop
```

The `-` prefix on `ExecStartPre` and `ExecStopPost` means: if this command
fails (e.g., the container doesn't exist yet), do not fail the overall service.

### Health Check

The Docker container is started with a built-in health check:

```
--health-cmd="wget -qO- http://localhost:80 || exit 1"
--health-interval=30s
--health-retries=3
```

Check health status inside the VM:

```bash
docker inspect --format='{{.State.Health.Status}}' testpress-web
# Expected: healthy
```

### First-Boot Provisioning

Cloud-init performs "first-boot provisioning" — the idea that a generic OS
image can be transformed into a configured server automatically, without human
intervention, the first time it boots.

This is how all major cloud providers work:
- You launch an EC2 instance on AWS → AWS passes your user-data to cloud-init
- The VM boots, cloud-init runs, and your server is ready

With Multipass locally, the flow is identical:
```
multipass launch --cloud-init cloud-init.yaml
         │
         └─► Multipass passes the YAML as user-data to the VM
                      │
                      └─► cloud-init reads it on first boot
                                   │
                                   └─► Server is provisioned automatically
```

### Cloud-Init vs Dockerfile

| Aspect | Cloud-Init | Dockerfile |
|--------|-----------|------------|
| **Target** | A virtual machine (or bare-metal server) | A container image |
| **Purpose** | Configures the OS: users, packages, files, services | Builds a portable app image layer by layer |
| **Runs when** | When the VM first boots | When you run `docker build` |
| **Output** | A configured, running server | An immutable container image |
| **Re-run** | Re-provisioning requires a new VM | Rebuild with `docker build` |
| **Use case** | "Set up this server for our testers" | "Package this app so it runs anywhere" |

In this project, we use **both**:
- Cloud-init provisions the VM (installs Docker, creates the user, writes files)
- A Dockerfile (nginx:alpine, pulled from Docker Hub) runs the actual application

### User-Data and Metadata

Cloud-init receives two types of data:

**User-data** — What you provide. In our case, the `cloud-init.yaml` file.
- Passed to the VM by the hypervisor (Multipass, AWS, GCP, etc.)
- Contains your provisioning instructions
- Accessible inside the VM at: `/var/lib/cloud/instance/user-data.txt`

**Metadata** — What the hypervisor provides about the instance.
- Instance ID, hostname, IP addresses, region, etc.
- Accessible inside the VM at: `/var/lib/cloud/instance/obj.pkl` (raw) or via:
  ```bash
  cloud-init query --list-keys
  cloud-init query local-hostname
  cloud-init query instance-id
  ```

Cloud-init uses the instance ID from metadata to decide whether this is a
first boot (new instance ID = first boot, same instance ID = subsequent boot).

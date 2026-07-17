# NGINX 1.28.0 Production Build

A hermetic, from-source NGINX build for Ubuntu/Debian producing a self-contained `.deb` package for amd64 or arm64. Everything is compiled from pinned upstream sources — no distro packages are used for the core stack. The resulting package installs cleanly and can be promoted through environments without rebuilding.

## What's included

| Component | Version / Source |
|-----------|-----------------|
| NGINX | 1.28.0 |
| OpenSSL (QUIC) | openssl-3.1.4+quic (quictls fork) |
| ModSecurity v3 | libmodsecurity3 + OWASP CRS |
| Brotli | ngx_brotli (dynamic module) |
| headers-more | headers-more-nginx-module |
| zlib-ng | drop-in zlib replacement |
| jemalloc | memory allocator |

**Package name:** `nginx-modsecurity-quic_<version>_<arch>.deb`  
**Conflicts with:** `nginx`, `nginx-core`, `nginx-full`, `nginx-light` (standard distro packages)

---

## Repository layout

```
build-deb.sh                  # Step 2 — packages the container output into a .deb
nginx-production-tpe-v22.sh   # Step 1 — hermetic compile script (runs inside Docker)
Dockerfile.build               # Build container image definition
docker-compose.yml             # Orchestrates the build container
debian-pkg/DEBIAN/             # control, postinst, prerm templates
published/                     # Output directory — .deb artefacts land here
```

---

## Host prerequisites

Install these once on the machine that will run the build. All other dependencies are satisfied inside the container.

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-plugin fakeroot dpkg-dev
```

Verify Docker is running:
```bash
docker info
```

---

## Build process overview

The build is two distinct steps. They must be run in order.

```
Step 1 — docker compose up    →  compiles everything inside a container (~15–60 min)
Step 2 — ./build-deb.sh       →  extracts artefacts and produces the .deb (< 1 min)
```

Step 1 leaves all compiled output inside a Docker named volume attached to the container. Step 2 copies that output out with `docker cp`, assembles the Debian package structure, and writes the `.deb` to `published/`.

---

## Step 1 — Compile (Docker)

### amd64 (default)

No changes needed. Run:

```bash
docker compose up --build nginx-builder
```

Expected duration: **15–30 minutes** on a modern x86_64 host.

---

### arm64 (cross-compile via QEMU emulation)

arm64 binaries are built by running an arm64 container under QEMU emulation on your x86_64 host. This is handled entirely by Docker — no cross-compiler toolchain is required.

**One-time QEMU setup** (registers ARM64 ELF handlers in the kernel — survives until next reboot, safe to re-run):

```bash
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
```

**Edit `docker-compose.yml`** — uncomment the platform line:

```yaml
# platform: linux/arm64   ← uncomment this line
```

Then run:

```bash
docker compose up --build nginx-builder
```

Expected duration: **30–60 minutes** under QEMU emulation.

**To undo the QEMU registration** (without rebooting):
```bash
docker run --rm --privileged multiarch/qemu-user-static --reset
```

> **Switching between architectures:** Comment the `platform:` line back in (or remove it) to return to amd64 builds. The Docker named volume `build-output` holds the last build's artefacts — if you switch arch, remove the old volume first so you are not packaging stale amd64 files into an arm64 package:
> ```bash
> docker compose down -v
> docker compose up --build nginx-builder
> ```

---

### Monitoring the build

The build writes a live log to `container-compose-output.txt` in the repo root. Tail it in a second terminal:

```bash
tail -f container-compose-output.txt
```

Or follow Docker logs directly:
```bash
docker logs -f nginx-builder
```

The build is complete when the container exits. Check the exit code:
```bash
docker inspect nginx-builder --format '{{.State.ExitCode}}'
# 0 = success
```

---

## Step 2 — Package

Once the container has exited cleanly (exit code 0), run:

```bash
./build-deb.sh
```

You will be prompted to select the architecture. This must match what was compiled in Step 1:

```
Select target architecture (or Ctrl+C to cancel):
1) amd64
2) arm64
#? 1
```

Or pass the architecture as an argument for scripted / CI use:

```bash
./build-deb.sh amd64
./build-deb.sh arm64
```

The script:
1. Validates your selection — exits immediately if nothing is chosen
2. Confirms what it will build and gives a 5-second cancel window
3. Verifies the container exists and exited with code 0
4. Extracts all artefacts from the container
5. Assembles and validates the package structure
6. Writes the `.deb` to `published/`

**Output:**
```
published/nginx-modsecurity-quic_1.0.0_amd64.deb
published/nginx-modsecurity-quic_1.0.0_arm64.deb
```

---

## Installing the package

```bash
sudo dpkg -i published/nginx-modsecurity-quic_1.0.0_amd64.deb

# Install any missing runtime dependencies
sudo apt-get install -f
```

Start and enable:
```bash
sudo systemctl enable --now nginx
sudo systemctl status nginx
```

---

## Installed paths

| Path | Contents |
|------|----------|
| `/usr/share/nginx/sbin/nginx` | NGINX binary |
| `/etc/nginx/` | Configuration files |
| `/usr/lib/nginx/modules/` | Dynamic modules (ModSecurity, Brotli, …) |
| `/usr/local/modsecurity/` | ModSecurity library and headers |
| `/lib/systemd/system/nginx.service` | systemd unit |
| `/var/log/nginx/` | Log directory |
| `/var/cache/nginx/` | Cache directory |

---

## Versioning the package

`PKG_VERSION` is defined at the top of `build-deb.sh`. Update it before cutting a release:

```bash
PKG_VERSION="1.28.0"
```

The version is embedded in both the `.deb` filename and the `DEBIAN/control` file. Use a consistent scheme, e.g. `<nginx-version>` or `<nginx-version>+<date>`.

---

## Environment variables

These can be set before running Step 1 to override defaults.

| Variable | Default | Description |
|----------|---------|-------------|
| `BUILD_JOBS` | `1` (in container) | Parallel make jobs. Increase if the host has spare cores, e.g. `BUILD_JOBS=4`. |
| `DESTDIR` | (empty) | Stage install root. Set by the build script internally — do not override. |
| `CONTAINER_NAME` | `nginx-builder` | Override if running multiple build containers simultaneously. |

---

## Troubleshooting

**Build container exits with code 137**
Out of memory. The build needs at least 8 GB. The compose file sets `mem_limit: 8g` — increase it if the host is constrained or other workloads are competing.

**`OpenSSL build failed — libcrypto.a not found in lib directory`**
OpenSSL installed into `lib64/` and the symlink to `lib/` was not created. This is fixed in the current version of `nginx-production-tpe-v22.sh` (the fix checks for the file, not just the directory). If it recurs, check that `make install_sw` completed without error in the container logs.

**`SSDEEP was explicitly requested but not found`**
A known arm64 `pkg-config` detection issue. The build script writes a `fuzzy.pc` compatibility shim because ModSecurity's configure macro queries `pkg-config --exists fuzzy` rather than `ssdeep`. If it recurs, confirm that `libfuzzy-dev` installed correctly inside the container: `docker exec nginx-builder dpkg -l libfuzzy-dev`.

**`No Docker container named 'nginx-builder' found`**
Step 1 has not been run, or the container was removed. Run `docker compose up --build nginx-builder` first.

**Container status is not `exited`**
The build is still running. Wait for it to complete before running `build-deb.sh`. Check progress with `docker logs -f nginx-builder`.

**`Please run as root`**
Only relevant for native (non-Docker) builds. Docker containers run as root by default.

**Switching from amd64 to arm64 (or vice versa) produces wrong binary**
The Docker named volume `build-output` caches the previous build. Remove it before switching arch:
```bash
docker compose down -v
```

---

## Native build (no Docker, no packaging)

Installs directly into the live system. Requires root.

```bash
sudo bash nginx-production-tpe-v22.sh
```

Use only on a dedicated build host or disposable VM. `DESTDIR` is unset in this mode so files are written to system paths.

---

**NGINX version:** 1.28.0  
**OpenSSL branch:** openssl-3.1.4+quic  
**Target OS:** Ubuntu 22.04 / 24.04, Debian 11 / 12

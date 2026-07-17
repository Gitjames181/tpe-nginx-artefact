# NGINX 1.28.0 Production Build

A hermetic, from-source NGINX build for Ubuntu/Debian with HTTP/3 (QUIC), ModSecurity v3, Brotli compression, headers-more, and other production modules.

## What's included

- **QUIC/HTTP/3** via OpenSSL 3.1.4+quic
- **ModSecurity v3** WAF with OWASP CRS
- **Brotli** compression
- **headers-more-nginx-module**
- **zlib-ng**, **jemalloc**, **ngx_brotli**

---

## Building a `.deb` package

`build-deb.sh` extracts artifacts from the running Docker build container and produces a `.deb` directly in the repo root, named `nginx-modsecurity-quic_<version>_<arch>.deb`.

### Quick start

**Interactive (select menu):**
```bash
./build-deb.sh
# Select target architecture:
# 1) amd64
# 2) arm64
# #? 1
```

**Non-interactive (CI / scripted):**
```bash
./build-deb.sh amd64
./build-deb.sh arm64
```

The script validates the arch value and rejects anything other than `amd64` or `arm64`.

### Prerequisites

1. The build container must be running before you invoke `build-deb.sh`:
   ```bash
   docker compose up --build nginx-builder
   ```
2. Install host packaging tools if not present:
   ```bash
   sudo apt-get install -y fakeroot dpkg-dev
   ```

### Output

The finished package lands in the repo root:
```
nginx-modsecurity-quic_1.0.0_amd64.deb
nginx-modsecurity-quic_1.0.0_arm64.deb
```

### arm64 — QEMU emulation prerequisite

To build a genuine arm64 binary on an x86_64 host, run the one-time QEMU setup before starting the container:

```bash
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
```

Then start the container with `--platform linux/arm64` and run `build-deb.sh arm64`.

### Environment variables

| Variable          | Default         | Description                                     |
|-------------------|-----------------|-------------------------------------------------|
| `CONTAINER_NAME`  | `nginx-builder` | Name of the running Docker build container      |

### Versioning

`PKG_VERSION` is set at the top of `build-deb.sh`. Update it before cutting a release, e.g. `1.28.0`.

---

## CI (GitHub Actions)

The workflow at `.github/workflows/publish-ghcr.yml` builds and uploads a `.deb` on every tagged push and on `workflow_dispatch`. Select the target architecture via the `deb_arch` input (default: `amd64`). The CI runner is `ubuntu-latest` (x86_64), so selecting `arm64` in the workflow only labels the package — it does not cross-compile; use the Docker QEMU method above for a real arm64 binary.

---

## Native build (no packaging)

```bash
sudo bash nginx-production-tpe-v22.sh
```

This installs directly into the live system (no DESTDIR).

---

## Environment variables

| Variable     | Default       | Description                            |
|-------------|---------------|----------------------------------------|
| `DESTDIR`   | (empty)       | Stage install root for `.deb` packaging |
| `BUILD_JOBS`| Auto-detected | Parallel make jobs (1 in containers)   |

---

## Build output paths (inside DESTDIR or live system)

| Path | Contents |
|------|----------|
| `usr/share/nginx/sbin/nginx` | NGINX binary |
| `etc/nginx/` | Configuration files |
| `usr/lib/nginx/modules/` | Dynamic modules (ModSecurity, Brotli, …) |
| `lib/systemd/system/nginx.service` | systemd unit |

---

## Troubleshooting

**"SSDEEP was explicitly requested but not found"**
This was a known arm64 issue. The build script writes a `fuzzy.pc` compatibility file for `pkg-config` because ModSecurity's configure macro queries `pkg-config --exists fuzzy` (not `ssdeep`). If this error recurs, check that `libfuzzy-dev` installed correctly inside the container.

**Exit code 137 (OOM)**
Increase Docker memory: `docker run --memory=8g …`

**"Please run as root"**
Use `sudo` for native builds. Docker containers run as root by default.

---

**NGINX version**: 1.28.0  
**OpenSSL branch**: openssl-3.1.4+quic

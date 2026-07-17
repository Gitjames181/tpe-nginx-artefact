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

Both targets use `DESTDIR` so the build installs into a staging root instead of the live system, making it safe to run anywhere without trashing the host.

### amd64

```bash
PKGROOT=/tmp/amd64-pkgroot
rm -rf "$PKGROOT" && mkdir -p "$PKGROOT"

DESTDIR="$PKGROOT" sudo -E bash /path/to/nginx-production-tpe-v22.sh

# Package it
mkdir -p "${PKGROOT}/DEBIAN"
install -m 0755 debian-pkg/DEBIAN/postinst "${PKGROOT}/DEBIAN/postinst"
install -m 0755 debian-pkg/DEBIAN/prerm    "${PKGROOT}/DEBIAN/prerm"
sed \
  -e "s/^Version: .*/Version: 0.0.0+amd64.local/" \
  -e "s/^Architecture: .*/Architecture: amd64/" \
  debian-pkg/DEBIAN/control > "${PKGROOT}/DEBIAN/control"

fakeroot dpkg-deb --build "$PKGROOT" \
  tpe-nginx_0.0.0+amd64.local_amd64.deb
```

Install `fakeroot` and `dpkg-dev` first if needed: `sudo apt-get install -y fakeroot dpkg-dev`

**Estimated time**: 15–30 min

---

### arm64 (via Docker QEMU emulation)

Requires `binfmt_misc` support (standard on Ubuntu 20.04+ hosts with `qemu-user-static`):

```bash
# One-time QEMU setup (if not already done)
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes

PKGROOT=/tmp/arm64-pkgroot
rm -rf "$PKGROOT" && mkdir -p "$PKGROOT"

docker run --rm \
  --platform linux/arm64 \
  -v "$(pwd):/build" \
  -v "${PKGROOT}:/pkgroot" \
  -w /build \
  -e DESTDIR=/pkgroot \
  ubuntu:24.04 \
  bash nginx-production-tpe-v22.sh

# Fix ownership (Docker writes as root)
sudo chown -R "$(id -u):$(id -g)" "$PKGROOT"

# Package it
mkdir -p "${PKGROOT}/DEBIAN"
install -m 0755 debian-pkg/DEBIAN/postinst "${PKGROOT}/DEBIAN/postinst"
install -m 0755 debian-pkg/DEBIAN/prerm    "${PKGROOT}/DEBIAN/prerm"
sed \
  -e "s/^Version: .*/Version: 0.0.0+arm64.local/" \
  -e "s/^Architecture: .*/Architecture: arm64/" \
  debian-pkg/DEBIAN/control > "${PKGROOT}/DEBIAN/control"

fakeroot dpkg-deb --build "$PKGROOT" \
  tpe-nginx_0.0.0+arm64.local_arm64.deb
```

**Estimated time**: 30–60 min under QEMU emulation

---

### Versioning

Replace `0.0.0+arm64.local` / `0.0.0+amd64.local` with any semver string, e.g. `1.28.0+20260717_amd64`.

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

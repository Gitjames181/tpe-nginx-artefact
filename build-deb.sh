#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"

BUILD_DIR="/tmp/nginx-deb-build"
CONTAINER_NAME="${CONTAINER_NAME:-nginx-builder}"
PKG_VERSION="1.0.0"

# Accept arch as first argument, or prompt interactively
if [[ $# -ge 1 ]]; then
    DEB_ARCH="$1"
else
    echo "Select target architecture:"
    select DEB_ARCH in amd64 arm64; do
        [[ -n "${DEB_ARCH}" ]] && break
        echo "Invalid selection. Enter 1 (amd64) or 2 (arm64)."
    done
fi

case "${DEB_ARCH}" in
    amd64|arm64) ;;
    *) echo "[!] Unsupported architecture '${DEB_ARCH}'. Use amd64 or arm64."; exit 1 ;;
esac

echo "[*] Building for architecture: ${DEB_ARCH}"

copy_from_container() {
    local source_path="$1"
    local dest_path="$2"

    mkdir -p "$(dirname "${dest_path}")"
    if docker cp "${CONTAINER_NAME}:${source_path}" "${dest_path}" >/dev/null 2>&1; then
        echo "[*] Extracted ${source_path} from ${CONTAINER_NAME}"
        return 0
    fi

    return 1
}

echo "[*] Extracting build artifacts from Docker container..."

if ! docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    echo "[!] No Docker container named '${CONTAINER_NAME}' exists."
    echo "[!] Start the build container first (for example: docker compose up --build nginx-builder)."
    exit 1
fi

# Create build directory
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# Extract the installed runtime layout from the container.
# This mirrors the package root that the CI workflow assembles under DESTDIR.
if ! copy_from_container "/usr/share/nginx" "${BUILD_DIR}/usr/share/nginx"; then
    echo "[!] Missing /usr/share/nginx in ${CONTAINER_NAME}."
    exit 1
fi

if ! copy_from_container "/etc/nginx" "${BUILD_DIR}/etc/nginx"; then
    echo "[!] Missing /etc/nginx in ${CONTAINER_NAME}."
    exit 1
fi

if ! copy_from_container "/usr/lib/nginx" "${BUILD_DIR}/usr/lib/nginx"; then
    echo "[!] Missing /usr/lib/nginx in ${CONTAINER_NAME}."
    exit 1
fi

SERVICE_DIR="${BUILD_DIR}/lib/systemd/system"
mkdir -p "${SERVICE_DIR}"
if ! copy_from_container "/lib/systemd/system/nginx.service" "${SERVICE_DIR}/nginx.service"; then
    cat > "${SERVICE_DIR}/nginx.service" <<'SERVICE'
[Unit]
Description=The NGINX HTTP and reverse proxy server
After=network.target remote-fs.target nss-lookup.target

[Service]
Type=forking
PIDFile=/run/nginx.pid
ExecStartPre=/usr/share/nginx/sbin/nginx -t
ExecStart=/usr/share/nginx/sbin/nginx
ExecReload=/bin/kill -s HUP $MAINPID
ExecStop=/bin/kill -s QUIT $MAINPID
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SERVICE
    echo "[*] Generated nginx.service in package root"
fi

if ! copy_from_container "/root/nginx-build/modsec-build" "${BUILD_DIR}/usr/local/modsecurity"; then
    echo "[!] Missing ModSecurity prefix in ${CONTAINER_NAME}."
    exit 1
fi

mkdir -p "${BUILD_DIR}/var/log/nginx" "${BUILD_DIR}/var/cache/nginx"

cd "${BUILD_DIR}"

test -x "${BUILD_DIR}/usr/share/nginx/sbin/nginx"
test -f "${BUILD_DIR}/usr/lib/nginx/modules/ngx_http_modsecurity_module.so"
test -f "${BUILD_DIR}/etc/nginx/modsecurity.conf"
if [[ ! -f "${BUILD_DIR}/usr/local/modsecurity/lib/libmodsecurity.so" && \
            ! -f "${BUILD_DIR}/usr/local/modsecurity/lib/libmodsecurity.so.3" ]]; then
        echo "[!] Missing libmodsecurity shared library in package root."
        exit 1
fi

# Create debian package structure
mkdir -p "${BUILD_DIR}/DEBIAN"
mkdir -p "${BUILD_DIR}/etc/nginx"
mkdir -p "${BUILD_DIR}/var/log/nginx"
mkdir -p "${BUILD_DIR}/var/cache/nginx"
mkdir -p "${BUILD_DIR}/lib/systemd/system"

# Copy control file
cp "${REPO_ROOT}/debian-pkg/DEBIAN/control" "${BUILD_DIR}/DEBIAN/"
cp "${REPO_ROOT}/debian-pkg/DEBIAN/postinst" "${BUILD_DIR}/DEBIAN/"
cp "${REPO_ROOT}/debian-pkg/DEBIAN/prerm" "${BUILD_DIR}/DEBIAN/"

sed -i "s/^Architecture: .*/Architecture: ${DEB_ARCH}/" "${BUILD_DIR}/DEBIAN/control"

# Make scripts executable
chmod 755 "${BUILD_DIR}/DEBIAN/postinst"
chmod 755 "${BUILD_DIR}/DEBIAN/prerm"

# Set proper permissions
find "${BUILD_DIR}/DEBIAN" -type f -exec chmod 644 {} \;
find "${BUILD_DIR}/DEBIAN" -name "postinst" -o -name "prerm" | xargs chmod 755

echo "[*] Building .deb package..."
DEB_FILE="nginx-modsecurity-quic_${PKG_VERSION}_${DEB_ARCH}.deb"
DEB_OUT="${REPO_ROOT}/${DEB_FILE}"
fakeroot dpkg-deb --build "${BUILD_DIR}" "${DEB_OUT}"

echo "[+] Package created: ${DEB_OUT}"
ls -lh "${DEB_OUT}"

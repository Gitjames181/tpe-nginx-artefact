#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"
PUBLISHED_DIR="${REPO_ROOT}/published"

BUILD_DIR="/tmp/nginx-deb-build"
CONTAINER_NAME="${CONTAINER_NAME:-nginx-builder}"
PKG_VERSION="1.0.0"

# ── Architecture selection ────────────────────────────────────────────────────
if [[ $# -ge 1 ]]; then
    DEB_ARCH="$1"
else
    echo ""
    echo "Select target architecture (or Ctrl+C to cancel):"
    select DEB_ARCH in amd64 arm64; do
        [[ -n "${DEB_ARCH}" ]] && break
        echo "  Invalid selection — enter 1 for amd64 or 2 for arm64."
    done
fi

case "${DEB_ARCH}" in
    amd64|arm64) ;;
    *) echo "[!] Unsupported architecture '${DEB_ARCH}'. Use amd64 or arm64."; exit 1 ;;
esac

echo ""
echo "  Architecture : ${DEB_ARCH}"
echo "  Package      : nginx-modsecurity-quic_${PKG_VERSION}_${DEB_ARCH}.deb"
echo "  Output dir   : ${PUBLISHED_DIR}/"
echo ""
echo "  NOTE: This script packages artifacts from the '${CONTAINER_NAME}' Docker"
echo "  container. The container must have finished its full compile run before"
echo "  you proceed. That build takes 15–60 minutes depending on architecture."
echo "  Press Ctrl+C now to cancel, or wait 5 seconds to continue..."
echo ""
sleep 5

# ── Verify container ──────────────────────────────────────────────────────────
if ! docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    echo "[!] No Docker container named '${CONTAINER_NAME}' found."
    echo "[!] Start the build first: docker compose up --build nginx-builder"
    exit 1
fi

CONTAINER_STATUS="$(docker container inspect "${CONTAINER_NAME}" --format '{{.State.Status}}')"
if [[ "${CONTAINER_STATUS}" != "exited" ]]; then
    echo "[!] Container '${CONTAINER_NAME}' is currently '${CONTAINER_STATUS}'."
    echo "[!] Wait for the build to complete (status: exited) before packaging."
    exit 1
fi

EXIT_CODE="$(docker container inspect "${CONTAINER_NAME}" --format '{{.State.ExitCode}}')"
if [[ "${EXIT_CODE}" != "0" ]]; then
    echo "[!] Container '${CONTAINER_NAME}' exited with code ${EXIT_CODE} — build failed."
    echo "[!] Check logs: docker logs ${CONTAINER_NAME}"
    exit 1
fi

echo "[*] Build container verified (exited cleanly)."

# ── Extract artifacts ─────────────────────────────────────────────────────────
copy_from_container() {
    local source_path="$1"
    local dest_path="$2"
    mkdir -p "$(dirname "${dest_path}")"
    if docker cp "${CONTAINER_NAME}:${source_path}" "${dest_path}" >/dev/null 2>&1; then
        echo "[*] Extracted ${source_path}"
        return 0
    fi
    return 1
}

echo "[*] Extracting build artifacts from container..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

copy_from_container "/usr/share/nginx"  "${BUILD_DIR}/usr/share/nginx"  || { echo "[!] Missing /usr/share/nginx";  exit 1; }
copy_from_container "/etc/nginx"        "${BUILD_DIR}/etc/nginx"        || { echo "[!] Missing /etc/nginx";        exit 1; }
copy_from_container "/usr/lib/nginx"    "${BUILD_DIR}/usr/lib/nginx"    || { echo "[!] Missing /usr/lib/nginx";    exit 1; }

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
    echo "[*] Generated fallback nginx.service"
fi

copy_from_container "/root/nginx-build/modsec-build" "${BUILD_DIR}/usr/local/modsecurity" || { echo "[!] Missing ModSecurity prefix"; exit 1; }

mkdir -p "${BUILD_DIR}/var/log/nginx" "${BUILD_DIR}/var/cache/nginx"

# ── Sanity checks ─────────────────────────────────────────────────────────────
test -x "${BUILD_DIR}/usr/share/nginx/sbin/nginx"                          || { echo "[!] nginx binary missing or not executable"; exit 1; }
test -f "${BUILD_DIR}/usr/lib/nginx/modules/ngx_http_modsecurity_module.so" || { echo "[!] ModSecurity module missing"; exit 1; }
test -f "${BUILD_DIR}/etc/nginx/modsecurity.conf"                           || { echo "[!] modsecurity.conf missing"; exit 1; }
if [[ ! -f "${BUILD_DIR}/usr/local/modsecurity/lib/libmodsecurity.so" && \
      ! -f "${BUILD_DIR}/usr/local/modsecurity/lib/libmodsecurity.so.3" ]]; then
    echo "[!] libmodsecurity shared library missing"
    exit 1
fi

# ── Assemble DEBIAN control ───────────────────────────────────────────────────
mkdir -p "${BUILD_DIR}/DEBIAN"
cp "${REPO_ROOT}/debian-pkg/DEBIAN/control" "${BUILD_DIR}/DEBIAN/"
cp "${REPO_ROOT}/debian-pkg/DEBIAN/postinst" "${BUILD_DIR}/DEBIAN/"
cp "${REPO_ROOT}/debian-pkg/DEBIAN/prerm"    "${BUILD_DIR}/DEBIAN/"

sed -i "s/^Architecture: .*/Architecture: ${DEB_ARCH}/" "${BUILD_DIR}/DEBIAN/control"

find "${BUILD_DIR}/DEBIAN" -type f -exec chmod 644 {} \;
find "${BUILD_DIR}/DEBIAN" \( -name "postinst" -o -name "prerm" \) -exec chmod 755 {} \;

# ── Build .deb ────────────────────────────────────────────────────────────────
mkdir -p "${PUBLISHED_DIR}"
DEB_FILE="nginx-modsecurity-quic_${PKG_VERSION}_${DEB_ARCH}.deb"
DEB_OUT="${PUBLISHED_DIR}/${DEB_FILE}"

echo "[*] Building .deb package..."
fakeroot dpkg-deb --build "${BUILD_DIR}" "${DEB_OUT}"

echo ""
echo "[+] Done: ${DEB_OUT}"
ls -lh "${DEB_OUT}"

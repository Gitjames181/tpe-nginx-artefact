#!/bin/bash
set -e

# Prepare debian package structure
BUILD_DIR="/tmp/nginx-deb-build"
CONTAINER_NAME="nginx-builder"
NGINX_PREFIX="/opt/nginx"
PKG_VERSION="1.0.0"

echo "[*] Extracting build artifacts from Docker container..."

# Create build directory
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# Extract the nginx binary and dependencies from the container
docker cp "${CONTAINER_NAME}:/opt/nginx" "${BUILD_DIR}/usr/local/nginx" 2>/dev/null || {
    echo "[!] Container path /opt/nginx not found. Checking alternatives..."
    docker cp "${CONTAINER_NAME}:/root/nginx-build" "${BUILD_DIR}/nginx-build" || true
}

# Create debian package structure
mkdir -p "${BUILD_DIR}/DEBIAN"
mkdir -p "${BUILD_DIR}/etc/nginx"
mkdir -p "${BUILD_DIR}/var/log/nginx"
mkdir -p "${BUILD_DIR}/var/cache/nginx"
mkdir -p "${BUILD_DIR}/lib/systemd/system"

# Copy control file
cp debian-pkg/DEBIAN/control "${BUILD_DIR}/DEBIAN/"
cp debian-pkg/DEBIAN/postinst "${BUILD_DIR}/DEBIAN/"
cp debian-pkg/DEBIAN/prerm "${BUILD_DIR}/DEBIAN/"

# Make scripts executable
chmod 755 "${BUILD_DIR}/DEBIAN/postinst"
chmod 755 "${BUILD_DIR}/DEBIAN/prerm"

# Set proper permissions
find "${BUILD_DIR}/DEBIAN" -type f -exec chmod 644 {} \;
find "${BUILD_DIR}/DEBIAN" -name "postinst" -o -name "prerm" | xargs chmod 755

echo "[*] Building .deb package..."
dpkg-deb --build "${BUILD_DIR}" "nginx-modsecurity-quic_${PKG_VERSION}_amd64.deb"

echo "[+] Package created: nginx-modsecurity-quic_${PKG_VERSION}_amd64.deb"
ls -lh "nginx-modsecurity-quic_${PKG_VERSION}_amd64.deb"

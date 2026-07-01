#!/usr/bin/env bash
# =====================================================================
# NGINX 1.28.0 PRODUCTION BUILD (Ubuntu/Debian)
# - Builds NGINX with all dependencies from source trees for a
#   clean, self-contained, and repeatable build (hermetic).
# - Supports QUIC/HTTP/3, ModSecurity v3, Brotli, and more.
# - This script is designed to build the exact NGINX configuration
#   specified by the user.
# =====================================================================

set -Eeuo pipefail

# ---------- Versions & Paths ----------
NGINX_VERSION="1.28.0"
OPENSSL_QUIC_REPO="https://github.com/quictls/openssl.git"
OPENSSL_QUIC_BRANCH="openssl-3.1.4+quic"

BASE="${BASE:-${HOME}/nginx-build}"
SRC_DIR="${SRC_DIR:-${BASE}/src}"
DEPS_DIR="${DEPS_DIR:-${BASE}/deps}"
LOG_FILE="${LOG_FILE:-${BASE}/build.log}"

usage() {
  cat <<'EOF'
Usage: sudo bash nginx-production-tpe-v22.sh

Builds a hermetic, from-source NGINX artifact with HTTP/3, ModSecurity, Brotli,
headers-more, and other production-oriented modules for Ubuntu/Debian servers.
EOF
}

# User-specified paths from the original configuration
OUT_PREFIX="${OUT_PREFIX:-/usr/share/nginx}"
CONF_PATH="${CONF_PATH:-/etc/nginx/nginx.conf}"
MODULES_PATH="${MODULES_PATH:-/usr/lib/nginx/modules}"
PID_PATH="${PID_PATH:-/run/nginx.pid}"
LOCK_PATH="${LOCK_PATH:-/run/lock/subsys/nginx}"
LOGS_DIR="${LOGS_DIR:-/var/log/nginx}"
ACCESS_LOG="${ACCESS_LOG:-${LOGS_DIR}/access.log}"
ERROR_LOG="${ERROR_LOG:-${LOGS_DIR}/error.log}"

# ---------- Toolchain Flags ----------
export CC="gcc"
export CFLAGS="-O2 -fstack-protector-strong -Wformat -Werror=format-security -D_FORTIFY_SOURCE=2"
# Note: The original LDFLAGS are now combined with the ModSecurity flags in the configure command
# to avoid the syntax error.

# ---------- Helpers ----------
msg()  { echo -e "\e[1;32m==>\e[0m $*"; }
warn() { echo -e "\e[1;33m[warn]\e[0m $*"; }
die()  { echo -e "\e[1;31m[error]\e[0m $*"; exit 1; }

is_container_runtime() {
  if [[ -n "${CONTAINER_TEST:-}" ]]; then
    return 0
  fi
  if [[ -f /proc/1/cgroup ]] && grep -Eq 'docker|kubepods|containerd|podman' /proc/1/cgroup 2>/dev/null; then
    return 0
  fi
  if [[ -f /run/systemd/container ]]; then
    return 0
  fi
  if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --container >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

require_root() {
  [[ $EUID -eq 0 ]] || die "Please run as root (sudo)."
}

get_build_jobs() {
  local cpu_count=2
  if [[ -n "${BUILD_JOBS:-}" ]]; then
    echo "$BUILD_JOBS"
    return 0
  fi

  if command -v nproc >/dev/null 2>&1; then
    cpu_count="$(nproc)"
  fi

  if is_container_runtime; then
    echo 1
    return 0
  fi

  if [[ "$cpu_count" -gt 8 ]]; then
    echo 8
  else
    echo "$cpu_count"
  fi
}

ensure_dirs() {
  msg "Creating build directory structure..."
  mkdir -p "${SRC_DIR}" "${DEPS_DIR}" "${LOGS_DIR}" /etc/nginx
  touch "${LOG_FILE}"
  exec > >(tee -a "${LOG_FILE}") 2>&1
  cd "${BASE}"
}

install_system_deps() {
  msg "Installing core system dependencies..."
  command -v apt-get >/dev/null 2>&1 || die "apt-get is required on this host."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential git curl wget autoconf automake libtool pkg-config \
    libyajl-dev libmaxminddb-dev doxygen ca-certificates perl autoconf-archive \
    libpcre2-dev libfuzzy-dev liblua5.3-dev libcurl4-gnutls-dev libxml2-dev \
    libjemalloc-dev libgd-dev cmake
}

clone_or_update() {
  local repo="$1" dir="$2" ref="${3:-}"
  if [[ -d "${dir}/.git" ]]; then
    ( cd "${dir}" && git fetch -q && { [[ -n "$ref" ]] && git checkout -q "$ref" || true; } && git pull -q || true ) || true
  else
    [[ -n "$ref" ]] && git clone -q --branch "$ref" "$repo" "$dir" || git clone -q "$repo" "$dir"
  fi
}

download_source_code() {
  msg "Downloading all required source code..."
  cd "${SRC_DIR}"
  wget -q "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"
  tar -zxf "nginx-${NGINX_VERSION}.tar.gz"

  cd "${DEPS_DIR}"
  clone_or_update "${OPENSSL_QUIC_REPO}" "${DEPS_DIR}/openssl-quic" "${OPENSSL_QUIC_BRANCH}"
  clone_or_update "https://github.com/zlib-ng/zlib-ng.git" "${DEPS_DIR}/zlib-ng"
  clone_or_update "https://github.com/owasp-modsecurity/ModSecurity.git" "${DEPS_DIR}/ModSecurity"
  (cd "${DEPS_DIR}/ModSecurity" && git submodule update --init --recursive -q)
  clone_or_update "https://github.com/SpiderLabs/ModSecurity-nginx.git" "${DEPS_DIR}/ModSecurity-nginx"
  clone_or_update "https://github.com/openresty/headers-more-nginx-module.git" "${DEPS_DIR}/headers-more-nginx-module"
  clone_or_update "https://github.com/google/ngx_brotli.git" "${DEPS_DIR}/ngx_brotli"
  (cd "${DEPS_DIR}/ngx_brotli" && git submodule update --init --recursive -q)
}

build_zlib_ng() {
  msg "Building zlib-ng (optimized zlib replacement)..."
  local jobs
  jobs="$(get_build_jobs)"
  cd "${DEPS_DIR}/zlib-ng"
  # Clean any previous builds
  rm -rf build libz.a 2>/dev/null || true
  
  # Use a conservative cmake build in containers and other constrained environments
  cmake -B build -DCMAKE_BUILD_TYPE=Release -DZLIB_COMPAT=ON -DBUILD_SHARED_LIBS=OFF -DZLIB_ENABLE_TESTS=OFF .
  cmake --build build --parallel "${jobs}"
  
  # Find and copy the static library to where nginx expects it
  find build -name "libz*.a" -exec cp {} ./libz.a \;
  
  # Verify it was created
  if [[ ! -f ./libz.a ]]; then
    die "zlib-ng build failed - libz.a not found"
  fi
  
  msg "zlib-ng built successfully"
}

build_openssl_quic() {
  msg "Building OpenSSL with QUIC support..."
  local jobs
  jobs="$(get_build_jobs)"
  cd "${DEPS_DIR}/openssl-quic"
  # Clean any previous builds
  make clean 2>/dev/null || true
  make distclean 2>/dev/null || true
  # Configure for static build with QUIC support
  local openssl_config_args=(
    --prefix="${DEPS_DIR}/openssl-quic/build"
    no-shared
    no-threads
    no-module
    no-asm
    enable-tls1_3
    enable-ec_nistp_64_gcc_128
    no-tests
    linux-x86_64
  )

  if ./config --help 2>&1 | grep -q -E '^\s*no-docs\b'; then
    openssl_config_args+=(no-docs)
  else
    warn "OpenSSL branch does not support no-docs; skipping that option."
  fi

  ./config "${openssl_config_args[@]}"
  # Build and install only the libraries and headers needed by nginx
  make -j"${jobs}"
  make install_sw
  # Handle lib64 vs lib directory - create symlinks so nginx configure can find libraries
  if [[ -f "${DEPS_DIR}/openssl-quic/build/lib64/libcrypto.a" ]] && [[ ! -d "${DEPS_DIR}/openssl-quic/build/lib" ]]; then
    msg "Creating lib symlink to lib64 for nginx compatibility..."
    mkdir -p "${DEPS_DIR}/openssl-quic/build/lib"
    ln -sf "${DEPS_DIR}/openssl-quic/build/lib64/libcrypto.a" "${DEPS_DIR}/openssl-quic/build/lib/"
    ln -sf "${DEPS_DIR}/openssl-quic/build/lib64/libssl.a" "${DEPS_DIR}/openssl-quic/build/lib/"
  fi
  # Verify the library is accessible in the expected location
  if [[ ! -f "${DEPS_DIR}/openssl-quic/build/lib/libcrypto.a" ]]; then
    die "OpenSSL build failed - libcrypto.a not found in lib directory"
  fi
  msg "OpenSSL with QUIC built successfully"
}

build_modsecurity() {
  msg "Building libmodsecurity (standalone dependency)..."
  cd "${DEPS_DIR}/ModSecurity"
  # Ensure submodules are initialized
  git submodule update --init --recursive -q
  # Clean any previous builds
  make clean 2>/dev/null || true
  make distclean 2>/dev/null || true
  # Build with proper dependencies
  ./build.sh
  # Configure with all required dependencies and custom prefix
  ./configure --prefix="/usr/local/modsecurity" \
              --with-maxmind \
              --with-libxml \
              --with-ssdeep \
              --with-lua \
              --with-yajl \
              --with-pcre2 \
              --with-curl=/usr/bin/curl-config
  # Build and install
  local jobs
  jobs="$(get_build_jobs)"
  make -j"${jobs}"
  make install
  # Update library cache
  echo "/usr/local/modsecurity/lib" > /etc/ld.so.conf.d/modsecurity.conf
  ldconfig
  msg "ModSecurity built and installed successfully"
}
################################################################################################# - In Progress
install_modsecurity_crs() {
  msg "Installing OWASP Core Rule Set (CRS)..."
  local CRS_DIR="/usr/local/modsecurity-crs"
  local LINK_DIR="/home/system/modsecurity/common"

  # Clone or update CRS
  clone_or_update "https://github.com/coreruleset/coreruleset.git" "$CRS_DIR"

  # Prepare runtime config
  cp "$CRS_DIR/crs-setup.conf.example" "$CRS_DIR/crs-setup.conf"
  find "$CRS_DIR/rules" -name '*.example' -exec bash -c 'f="{}"; cp "$f" "${f%.example}"' \;

  # Symlink ruleset to managed control directory
  mkdir -p "$LINK_DIR"
  ln -sf "$CRS_DIR/crs-setup.conf" "$LINK_DIR/crs-setup.conf"
  ln -sf "$CRS_DIR/rules" "$LINK_DIR/rules"

  # Install baseline modsecurity.conf
  local MODSEC_CONF="/etc/nginx/modsecurity.conf"
  cp "${DEPS_DIR}/ModSecurity/modsecurity.conf-recommended" "$MODSEC_CONF"
  sed -i 's/SecRuleEngine DetectionOnly/SecRuleEngine On/' "$MODSEC_CONF"
  sed -i '/SecAuditLogParts/s/ABIJDEFHZ/ABIJDEFHZ/' "$MODSEC_CONF"
  echo -e "\nInclude $LINK_DIR/crs-setup.conf\nInclude $LINK_DIR/rules/*.conf" >> "$MODSEC_CONF"

  # Add blacklist and whitelist policies
  mkdir -p "$LINK_DIR/custom"
  cat > "$LINK_DIR/custom/ip-blacklist.conf" <<EOF
# Deny malicious IP
SecRule REMOTE_ADDR "@ipMatch 192.0.2.123" "id:1000001,phase:1,deny,log,msg:'Blacklisted IP address'"
EOF

  cat > "$LINK_DIR/custom/ip-whitelist.conf" <<EOF
# Allow trusted IP before other rules
SecRule REMOTE_ADDR "@ipMatch 203.0.113.1" "id:1000002,phase:1,pass,nolog,ctl:ruleEngine=Off"
EOF

  echo -e "\nInclude $LINK_DIR/custom/ip-whitelist.conf\nInclude $LINK_DIR/custom/ip-blacklist.conf" >> "$MODSEC_CONF"

  msg "CRS installed with paranoia level 1, and blacklist/whitelist rules integrated."
}
################################################################################################# - In Progress

configure_nginx() {
  msg "Configuring NGINX ${NGINX_VERSION} with dependencies..."
  cd "${SRC_DIR}/nginx-${NGINX_VERSION}"
  make clean 2>/dev/null || true

  # Verify dependencies are available (sources for nginx to build)
  if [[ ! -f "${DEPS_DIR}/zlib-ng/libz.a" ]]; then
    die "zlib-ng not built. Run build_zlib_ng first."
  fi
  
  if [[ ! -d "${DEPS_DIR}/openssl-quic" ]]; then
    die "OpenSSL source not found. Run download_source_code first."
  fi
  
  if [[ ! -f "/usr/local/modsecurity/lib/libmodsecurity.so" ]]; then
    die "ModSecurity not built. Run build_modsecurity first."
  fi

  # The ModSecurity module requires specific paths to be passed
  local MODSEC_INC_DIR="/usr/local/modsecurity/include"
  local MODSEC_LIB_DIR="/usr/local/modsecurity/lib"
  local OPENSSL_SRC_DIR="${DEPS_DIR}/openssl-quic"
  local ZLIB_DIR="${DEPS_DIR}/zlib-ng"

  # Separate the linker flags for better readability and compatibility
  local LDFLAGS="-L${MODSEC_LIB_DIR}"
  local LDLIBS="-lmodsecurity -ljemalloc"
  local SECURITY_FLAGS="-Wl,-z,relro -Wl,-z,now -pie"

  ./configure \
    --prefix="${OUT_PREFIX}" \
    --conf-path="${CONF_PATH}" \
    --http-log-path="${ACCESS_LOG}" \
    --error-log-path="${ERROR_LOG}" \
    --modules-path="${MODULES_PATH}" \
    --pid-path="${PID_PATH}" \
    --lock-path="${LOCK_PATH}" \
    --with-threads \
    --with-file-aio \
    --with-http_v2_module \
    --with-http_v3_module \
    --with-http_gzip_static_module \
    --with-http_gunzip_module \
    --with-http_slice_module \
    --with-openssl="${OPENSSL_SRC_DIR}" \
    --with-zlib="${ZLIB_DIR}" \
    --with-pcre \
    --with-pcre-jit \
    --with-stream \
    --with-stream_ssl_module \
    --with-stream_ssl_preread_module \
    --add-dynamic-module="${DEPS_DIR}/ModSecurity-nginx" \
    --with-http_ssl_module \
    --with-http_realip_module \
    --add-dynamic-module="${DEPS_DIR}/headers-more-nginx-module" \
    --with-http_sub_module \
    --with-http_auth_request_module \
    --with-http_image_filter_module=dynamic \
    --with-http_stub_status_module \
    --add-dynamic-module="${DEPS_DIR}/ngx_brotli" \
    --with-compat \
    --with-cc-opt="${CFLAGS} -I${MODSEC_INC_DIR}" \
    --with-ld-opt="${LDFLAGS} ${LDLIBS} ${SECURITY_FLAGS}"

  test -f "objs/Makefile" || die "NGINX configure did not produce objs/Makefile."

  # Patch the Makefile to avoid build issues
  msg "Patching NGINX Makefile for dependency handling..."
  
  # Fix the zlib-ng build command completely - nginx expects ./configure but zlib-ng uses cmake
  # Replace the entire zlib-ng build section in the Makefile
  sed -i '/cd .*zlib-ng/,/libz\.a$/c\
	cd /root/nginx-build/deps/zlib-ng \\\
	&& if [ ! -f libz.a ]; then \\\
		make clean 2>/dev/null || true \\\
		&& cmake -B build -DZLIB_COMPAT=ON -DBUILD_SHARED_LIBS=OFF . \\\
		&& cmake --build build --target zlibstatic \\\
		&& cp build/libz.a . ; \\\
	fi' objs/Makefile
  
  # Also patch OpenSSL build to be less aggressive with cleaning
  sed -i 's/make distclean/make clean || true/g' objs/Makefile
  sed -i 's/CFLAGS=""/CFLAGS="-O2"/g' objs/Makefile
}

compile_and_install_nginx() {
  msg "Compiling and installing NGINX..."
  local jobs
  jobs="$(get_build_jobs)"
  cd "${SRC_DIR}/nginx-${NGINX_VERSION}"
  make -j"${jobs}"
  make install
}

install_systemd_service() {
  if is_container_runtime; then
    msg "Container runtime detected; skipping systemd unit installation."
    return 0
  fi

  msg "Installing systemd unit nginx.service..."
  cat > /etc/systemd/system/nginx.service <<SERVICE
[Unit]
Description=The NGINX HTTP and reverse proxy server
After=network.target remote-fs.target nss-lookup.target

[Service]
Type=forking
PIDFile=${PID_PATH}
ExecStartPre=${OUT_PREFIX}/sbin/nginx -t
ExecStart=${OUT_PREFIX}/sbin/nginx
ExecReload=/bin/kill -s HUP \$MAINPID
ExecStop=/bin/kill -s QUIT \$MAINPID
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SERVICE

  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    systemctl enable nginx.service
  fi
}

write_minimal_config() {
  msg "Writing minimal /etc/nginx/nginx.conf..."
  mkdir -p /etc/nginx
  cat > /etc/nginx/nginx.conf <<'CONF'
load_module /usr/lib/nginx/modules/ngx_http_brotli_filter_module.so;
load_module /usr/lib/nginx/modules/ngx_http_brotli_static_module.so;
load_module /usr/lib/nginx/modules/ngx_http_headers_more_filter_module.so;
load_module /usr/lib/nginx/modules/ngx_http_modsecurity_module.so;
load_module /usr/lib/nginx/modules/ngx_http_image_filter_module.so;

user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;

events { worker_connections 1024; }

http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  access_log /var/log/nginx/access.log;
  sendfile on;
  keepalive_timeout 65;

  server {
    listen 8080;
    server_name localhost;
    location / {
      return 200 "NGINX works!\n";
    }
  }
}
CONF
}

smoke_test() {
  msg "Running smoke test on :8080..."
  write_minimal_config

  if is_container_runtime; then
    ${OUT_PREFIX}/sbin/nginx -c /etc/nginx/nginx.conf
    sleep 1
    curl -fsS http://127.0.0.1:8080/
    ${OUT_PREFIX}/sbin/nginx -s quit || true
    return 0
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart nginx.service
    sleep 1
    curl -fsS http://127.0.0.1:8080/
    systemctl status --no-pager nginx.service | sed -n '1,12p' || true
    return 0
  fi

  ${OUT_PREFIX}/sbin/nginx -c /etc/nginx/nginx.conf
  sleep 1
  curl -fsS http://127.0.0.1:8080/
  ${OUT_PREFIX}/sbin/nginx -s quit || true
}

# ---------- Main Execution Flow ----------
if [[ $# -gt 0 ]]; then
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
fi

msg "Starting NGINX hermetic build..."
require_root
ensure_dirs
install_system_deps
download_source_code
build_zlib_ng
build_openssl_quic
build_modsecurity
install_modsecurity_crs
configure_nginx
compile_and_install_nginx
install_systemd_service
smoke_test

msg "Build and installation complete. NGINX is located at ${OUT_PREFIX}."
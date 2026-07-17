#!/usr/bin/env bash
# =====================================================================
# NGINX 1.28.0 PRODUCTION BUILD (Ubuntu/Debian)
# - Builds NGINX with all dependencies from source trees for a
#   clean, self-contained, and repeatable build (hermetic).
# - Supports QUIC/HTTP/3, ModSecurity v3, Brotli, and more.
# - DESTDIR-aware throughout, so the exact same script can:
#     * install normally on a host  (DESTDIR="")
#     * stage a Debian package root (DESTDIR=/some/path)
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

# Temporary install prefix for ModSecurity — never touches the live filesystem.
# nginx links against this at build time; the runtime files are then staged into
# DESTDIR so the .deb is fully self-contained.
MODSEC_PREFIX="${BASE}/modsec-build"

# On-target paths (written into the binary as rpath / config includes).
MODSEC_INSTALL_PATH="${MODSEC_INSTALL_PATH:-/usr/local/modsecurity}"
CRS_INSTALL_PATH="${CRS_INSTALL_PATH:-/etc/nginx/owasp-crs}"
OPENSSL_TARGET="${OPENSSL_TARGET:-$(case "$(uname -m)" in
  aarch64|arm64) echo linux-aarch64 ;;
  x86_64|amd64) echo linux-x86_64 ;;
  *) echo linux-x86_64 ;;
esac)}"

usage() {
  cat <<'EOF'
Usage: sudo bash nginx-production-tpe-v23.sh

Builds a hermetic, from-source NGINX artifact with HTTP/3, ModSecurity, Brotli,
headers-more, and other production-oriented modules for Ubuntu/Debian servers.

Env vars of note:
  DESTDIR   - if set, all package payload is staged under this path
              (required for producing a .deb; leave empty for a normal install)
EOF
}

# User-specified paths from the original configuration.
# NOTE: these must always be the *final on-target* paths (e.g. /etc/nginx/nginx.conf),
# never prefixed with a runner temp dir. DESTDIR is what does the staging.
OUT_PREFIX="${OUT_PREFIX:-/usr/share/nginx}"
CONF_PATH="${CONF_PATH:-/etc/nginx/nginx.conf}"
MODULES_PATH="${MODULES_PATH:-/usr/lib/nginx/modules}"
PID_PATH="${PID_PATH:-/run/nginx.pid}"
LOCK_PATH="${LOCK_PATH:-/run/lock/subsys/nginx}"
LOGS_DIR="${LOGS_DIR:-/var/log/nginx}"
ACCESS_LOG="${ACCESS_LOG:-${LOGS_DIR}/access.log}"
ERROR_LOG="${ERROR_LOG:-${LOGS_DIR}/error.log}"

# Compile Destination — when set, this script behaves as a *package builder*,
# never touching the live filesystem outside of $DESTDIR.
DESTDIR="${DESTDIR:-}"

pkgpath() {
    printf "%s%s" "$DESTDIR" "$1"
}

# ---------- Toolchain Flags ----------
export CC="gcc"
export CFLAGS="-O2 -fstack-protector-strong -Wformat -Werror=format-security -D_FORTIFY_SOURCE=2"

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
  mkdir -p "${SRC_DIR}" "${DEPS_DIR}" "${MODSEC_PREFIX}" "${LOGS_DIR}"
  mkdir -p "$(dirname "$CONF_PATH")"
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

  # Ubuntu/Debian provide libfuzzy, but ModSecurity's ssdeep probe expects
  # a pkg-config entry named ssdeep. Write a compatibility .pc if needed.
  # Use dpkg to locate the real libfuzzy.so — gcc -print-multiarch is
  # unreliable in Docker containers and causes wrong libdir on arm64.
  [[ -f /usr/include/fuzzy.h ]] || die "libfuzzy-dev did not install fuzzy.h"

  local fuzzy_so libdir pcdir
  # find is reliable across multiarch layouts; dpkg/ldconfig queries are fragile in Docker
  fuzzy_so="$(find /usr/lib -name 'libfuzzy.so*' -not -type d 2>/dev/null | sort | head -1)"
  if [[ -n "$fuzzy_so" ]]; then
    libdir="$(dirname "$fuzzy_so")"
  else
    local multiarch
    multiarch="$(gcc -print-multiarch 2>/dev/null || true)"
    libdir="${multiarch:+/usr/lib/${multiarch}}"
    libdir="${libdir:-/usr/lib}"
  fi
  pcdir="${libdir}/pkgconfig"

  # ModSecurity's msc_find_lib.m4 queries 'pkg-config --exists fuzzy' (not 'ssdeep'),
  # so the compatibility file must be named fuzzy.pc with Name: fuzzy.
  if ! pkg-config --exists fuzzy 2>/dev/null; then
    mkdir -p "${pcdir}"
    cat > "${pcdir}/fuzzy.pc" <<EOF
prefix=/usr
exec_prefix=\${prefix}
libdir=${libdir}
includedir=\${prefix}/include

Name: fuzzy
Description: ssdeep fuzzy hashing library (libfuzzy compatibility pkg-config)
Version: 2.14.1
Libs: -L${libdir} -lfuzzy
Cflags: -I\${includedir}
EOF
    msg "Wrote fuzzy.pc to ${pcdir} (libdir=${libdir})"
  fi

  # Ensure configure subprocesses find the .pc regardless of environment.
  export PKG_CONFIG_PATH="${pcdir}${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"

  # Fail fast here rather than inside ModSecurity configure with an opaque error.
  pkg-config --exists fuzzy 2>/dev/null \
    || die "fuzzy.pc at ${pcdir} not found by pkg-config (PKG_CONFIG_PATH=${PKG_CONFIG_PATH})"
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
  rm -rf build libz.a 2>/dev/null || true

  cmake -B build -DCMAKE_BUILD_TYPE=Release -DZLIB_COMPAT=ON -DBUILD_SHARED_LIBS=OFF -DZLIB_ENABLE_TESTS=OFF .
  cmake --build build --parallel "${jobs}"

  find build -name "libz*.a" -exec cp {} ./libz.a \;

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
  make clean 2>/dev/null || true
  make distclean 2>/dev/null || true
  local openssl_config_args=(
    --prefix="${DEPS_DIR}/openssl-quic/build"
    no-shared
    no-threads
    no-module
    no-asm
    enable-tls1_3
    no-tests
    "${OPENSSL_TARGET}"
  )

  if [[ "${OPENSSL_TARGET}" == linux-x86_64 ]]; then
    openssl_config_args+=(enable-ec_nistp_64_gcc_128)
  fi

  if ./config --help 2>&1 | grep -q -E '^\s*no-docs\b'; then
    openssl_config_args+=(no-docs)
  else
    warn "OpenSSL branch does not support no-docs; skipping that option."
  fi

  ./config "${openssl_config_args[@]}"
  make -j"${jobs}"
  make install_sw
  if [[ -f "${DEPS_DIR}/openssl-quic/build/lib64/libcrypto.a" ]] && \
     [[ ! -f "${DEPS_DIR}/openssl-quic/build/lib/libcrypto.a" ]]; then
    msg "Creating lib symlinks for lib64 (nginx compatibility)..."
    mkdir -p "${DEPS_DIR}/openssl-quic/build/lib"
    ln -sf "${DEPS_DIR}/openssl-quic/build/lib64/libcrypto.a" "${DEPS_DIR}/openssl-quic/build/lib/libcrypto.a"
    ln -sf "${DEPS_DIR}/openssl-quic/build/lib64/libssl.a"    "${DEPS_DIR}/openssl-quic/build/lib/libssl.a"
  fi
  if [[ ! -f "${DEPS_DIR}/openssl-quic/build/lib/libcrypto.a" ]]; then
    die "OpenSSL build failed - libcrypto.a not found in lib directory"
  fi
  msg "OpenSSL with QUIC built successfully"
}

build_modsecurity() {
  # Installs into MODSEC_PREFIX (a temp dir inside the build tree) so the
  # runner filesystem is never touched. nginx links against this prefix at
  # compile time. stage_modsecurity() later copies the runtime files into
  # DESTDIR so the final .deb is fully self-contained.
  msg "Building libmodsecurity into temp prefix ${MODSEC_PREFIX}..."
  mkdir -p "${MODSEC_PREFIX}"
  cd "${DEPS_DIR}/ModSecurity"
  git submodule update --init --recursive -q
  make clean 2>/dev/null || true
  make distclean 2>/dev/null || true
  ./build.sh

  ./configure --prefix="${MODSEC_PREFIX}" \
              --with-maxmind \
              --with-libxml \
              --with-ssdeep \
              --with-lua \
              --with-yajl \
              --with-pcre2 \
              --with-curl=/usr/bin/curl-config
  local jobs
  jobs="$(get_build_jobs)"
  make -j"${jobs}"
  # DESTDIR="" ensures this always lands in MODSEC_PREFIX regardless of any
  # ambient DESTDIR set by the CI environment.
  make install DESTDIR=""
  msg "ModSecurity built and installed into ${MODSEC_PREFIX}"
}

stage_modsecurity() {
  # Copies the ModSecurity runtime files from the temp build prefix into DESTDIR
  # so they are bundled inside the .deb. The build toolchain stays clean — nothing
  # is installed into the runner's /usr/local or any other host path.
  msg "Staging ModSecurity runtime into package root..."
  local dest
  dest="$(pkgpath "${MODSEC_INSTALL_PATH}")"
  mkdir -p "${dest}"

  # lib: the shared library and any pkgconfig metadata
  cp -a "${MODSEC_PREFIX}/lib" "${dest}/"

  # include: headers (needed if downstream packages compile against this .deb)
  cp -a "${MODSEC_PREFIX}/include" "${dest}/"

  msg "ModSecurity runtime staged into ${dest}"
}

install_modsecurity_crs() {
  # Everything is staged under DESTDIR so the .deb is fully self-contained.
  # On-target Include paths use CRS_INSTALL_PATH (no DESTDIR prefix) because
  # those paths are evaluated after the package is installed on the server.
  msg "Staging OWASP Core Rule Set (CRS) into package root..."

  local CRS_SRC="${BASE}/coreruleset"
  local CRS_DEST
  CRS_DEST="$(pkgpath "${CRS_INSTALL_PATH}")"
  local CUSTOM_DIR
  CUSTOM_DIR="$(pkgpath /etc/nginx/modsecurity-custom)"

  clone_or_update "https://github.com/coreruleset/coreruleset.git" "${CRS_SRC}"

  mkdir -p "${CRS_DEST}/rules"
  cp "${CRS_SRC}/crs-setup.conf.example" "${CRS_DEST}/crs-setup.conf"
  find "${CRS_SRC}/rules" -name '*.example' -exec bash -c \
    'f="{}"; dest="${CRS_DEST}/rules/$(basename "${f%.example}")"; cp "$f" "$dest"' \
    CRS_DEST="${CRS_DEST}" \;
  # Copy non-example rule files too
  find "${CRS_SRC}/rules" -maxdepth 1 -name '*.conf' -exec cp {} "${CRS_DEST}/rules/" \;

  local MODSEC_CONF
  MODSEC_CONF="$(pkgpath /etc/nginx/modsecurity.conf)"
  mkdir -p "$(dirname "$MODSEC_CONF")"

  cp "${DEPS_DIR}/ModSecurity/modsecurity.conf-recommended" "$MODSEC_CONF"
  # Copy the unicode mapping file required by ModSecurity at runtime
  cp "${DEPS_DIR}/ModSecurity/unicode.mapping" "$(pkgpath /etc/nginx/unicode.mapping)"
  sed -i 's/SecRuleEngine DetectionOnly/SecRuleEngine On/' "$MODSEC_CONF"
  # Point unicode mapping at the on-target path
  sed -i "s|.*SecUnicodeMapFile.*|SecUnicodeMapFile /etc/nginx/unicode.mapping|" "$MODSEC_CONF"
  printf '\nInclude %s/crs-setup.conf\nInclude %s/rules/*.conf\n' \
    "${CRS_INSTALL_PATH}" "${CRS_INSTALL_PATH}" >> "$MODSEC_CONF"

  mkdir -p "${CUSTOM_DIR}"
  cat > "${CUSTOM_DIR}/ip-blacklist.conf" <<'EOF'
# Deny malicious IP
SecRule REMOTE_ADDR "@ipMatch 192.0.2.123" "id:1000001,phase:1,deny,log,msg:'Blacklisted IP address'"
EOF

  cat > "${CUSTOM_DIR}/ip-whitelist.conf" <<'EOF'
# Allow trusted IP before other rules
SecRule REMOTE_ADDR "@ipMatch 203.0.113.1" "id:1000002,phase:1,pass,nolog,ctl:ruleEngine=Off"
EOF

  printf '\nInclude /etc/nginx/modsecurity-custom/ip-whitelist.conf\nInclude /etc/nginx/modsecurity-custom/ip-blacklist.conf\n' >> "$MODSEC_CONF"

  msg "CRS staged into ${CRS_DEST}"
}

configure_nginx() {
  msg "Configuring NGINX ${NGINX_VERSION} with dependencies..."
  cd "${SRC_DIR}/nginx-${NGINX_VERSION}"
  make clean 2>/dev/null || true

  if [[ ! -f "${DEPS_DIR}/zlib-ng/libz.a" ]]; then
    die "zlib-ng not built. Run build_zlib_ng first."
  fi

  if [[ ! -d "${DEPS_DIR}/openssl-quic" ]]; then
    die "OpenSSL source not found. Run download_source_code first."
  fi

  if [[ ! -f "${MODSEC_PREFIX}/lib/libmodsecurity.so" ]]; then
    die "ModSecurity not built. Run build_modsecurity first."
  fi

  local MODSEC_INC_DIR="${MODSEC_PREFIX}/include"
  local MODSEC_LIB_DIR="${MODSEC_PREFIX}/lib"
  local OPENSSL_SRC_DIR="${DEPS_DIR}/openssl-quic"
  local ZLIB_DIR="${DEPS_DIR}/zlib-ng"

  local LDFLAGS="-L${MODSEC_LIB_DIR}"
  # rpath bakes the on-target lib path into the nginx binary so ldconfig is not
  # required after deployment — the dynamic linker finds libmodsecurity.so
  # directly under MODSEC_INSTALL_PATH on the target server.
  local LDLIBS="-lmodsecurity -ljemalloc -Wl,-rpath,${MODSEC_INSTALL_PATH}/lib"
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

  msg "Patching NGINX Makefile for dependency handling..."

  sed -i '/cd .*zlib-ng/,/libz\.a$/c\
	cd /root/nginx-build/deps/zlib-ng \\\
	&& if [ ! -f libz.a ]; then \\\
		make clean 2>/dev/null || true \\\
		&& cmake -B build -DZLIB_COMPAT=ON -DBUILD_SHARED_LIBS=OFF . \\\
		&& cmake --build build --target zlibstatic \\\
		&& cp build/libz.a . ; \\\
	fi' objs/Makefile

  sed -i 's/make distclean/make clean || true/g' objs/Makefile
  sed -i 's/CFLAGS=""/CFLAGS="-O2"/g' objs/Makefile
}

compile_and_install_nginx() {
  msg "Compiling and installing NGINX..."
  local jobs
  jobs="$(get_build_jobs)"

  cd "${SRC_DIR}/nginx-${NGINX_VERSION}"

  make -j"${jobs}"

  if [[ -n "${DESTDIR}" ]]; then
      make install DESTDIR="${DESTDIR}"
  else
      make install
  fi
}

install_systemd_service() {
  if is_container_runtime && [[ -z "${DESTDIR}" ]]; then
    msg "Container runtime detected; skipping systemd unit installation."
    return 0
  fi

  msg "Installing systemd unit nginx.service..."
  if [[ -n "${DESTDIR}" ]]; then
    msg "Package build detected. Installing service file only (no daemon-reload/enable)."
  fi

  SERVICE_DIR="$(pkgpath /lib/systemd/system)"
  mkdir -p "$SERVICE_DIR"
  cat > "$SERVICE_DIR/nginx.service" <<SERVICE
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

  # FIX: never reload/enable the host's systemd while staging a package.
  if [[ -z "${DESTDIR}" ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    systemctl enable nginx.service
  fi
}

write_minimal_config() {
  msg "Writing minimal nginx.conf at ${CONF_PATH}..."
  mkdir -p "$(dirname "$CONF_PATH")"
  cat > "$CONF_PATH" <<'CONF'
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
  # FIX: a package build stages files under $DESTDIR — there is nothing
  # runnable on the GitHub runner itself, so never try to start nginx here.
  if [[ -n "${DESTDIR}" ]]; then
    msg "Package build detected. Skipping smoke test."
    return 0
  fi

  msg "Running smoke test on :8080..."
  write_minimal_config

  if is_container_runtime; then
    "${OUT_PREFIX}/sbin/nginx" -c "$CONF_PATH"
    sleep 1
    curl -fsS http://127.0.0.1:8080/
    "${OUT_PREFIX}/sbin/nginx" -s quit || true
    return 0
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart nginx.service
    sleep 1
    curl -fsS http://127.0.0.1:8080/
    systemctl status --no-pager nginx.service | sed -n '1,12p' || true
    return 0
  fi

  "${OUT_PREFIX}/sbin/nginx" -c "$CONF_PATH"
  sleep 1
  curl -fsS http://127.0.0.1:8080/
  "${OUT_PREFIX}/sbin/nginx" -s quit || true
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
stage_modsecurity
install_modsecurity_crs
configure_nginx
compile_and_install_nginx
install_systemd_service
smoke_test

msg "Build and installation complete. NGINX is located at ${OUT_PREFIX}."

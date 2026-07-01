# NGINX 1.28.0 Production Build

A hermetic, from-source NGINX build system for Ubuntu/Debian with HTTP/3 (QUIC), ModSecurity v3, Brotli compression, headers-more, and other production-oriented modules.

## Overview

This repository contains an automated build system that compiles NGINX and all its dependencies from source, ensuring:
- **Hermetic builds**: No reliance on pre-built system packages (except toolchain)
- **Reproducibility**: Exact versions of all components pinned
- **Customization**: Easy module configuration in the main build script
- **Container-friendly**: Optimized for Docker with resource awareness

### Included Modules & Features

- **QUIC/HTTP/3**: OpenSSL 3.1.4 with QUIC support
- **ModSecurity v3**: Full WAF capability with nginx integration
- **Brotli Compression**: High-ratio compression for modern browsers
- **headers-more-nginx-module**: Fine-grained HTTP header control
- **zlib-ng**: High-performance zlib replacement
- **jemalloc**: Memory allocator for better performance

## Quick Start

### Prerequisites

- Docker and Docker Compose (for containerized build)
- **OR** Ubuntu/Debian system with `sudo` access (for native build)
- At least 8GB available disk space for build artifacts

### Using Docker Compose (Recommended)

```bash
cd /home/james/Desktop/nginx-artefact

# Build the container and run the NGINX build
docker-compose up --build

# Watch the build in real-time
docker-compose logs -f nginx-builder

# Clean up when done
docker-compose down -v
```

**Build output** is captured in `container-compose-output.txt`.

### Manual Docker Build

```bash
cd /home/james/Desktop/nginx-artefact

docker build -f Dockerfile.build -t nginx-builder:latest .

docker run --rm \
  --memory=8g \
  --cpus=1 \
  -e BUILD_JOBS=1 \
  -e CONTAINER_TEST=1 \
  -v "$(pwd)/nginx-production-tpe-v22.sh:/root/build.sh:ro" \
  -v nginx-build:/root/nginx-build \
  nginx-builder:latest \
  bash /root/build.sh 2>&1 | tee container-manual-output.txt
```

### Native Build (Non-Containerized)

```bash
cd /home/james/Desktop/nginx-artefact

sudo bash nginx-production-tpe-v22.sh
```

## Directory Structure

```
nginx-artefact/
├── nginx-production-tpe-v22.sh    # Main build script
├── docker-compose.yml              # Docker Compose orchestration
├── Dockerfile.build                # Container image definition
├── README_BUILD.md                 # This file
├── container-compose-output.txt    # Build output (generated)
├── container-out.txt               # Build output (generated)
└── _ProjectDocs/                   # Project documentation
```

## Environment Variables

The build script recognizes these optional environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `BUILD_JOBS` | Auto-detected | Number of parallel build jobs (1 in containers) |
| `CONTAINER_TEST` | unset | Set to 1 to enable container detection override |

Example:
```bash
BUILD_JOBS=2 CONTAINER_TEST=1 docker-compose up --build
```

## Customization

### Adjust Resource Limits

Edit `docker-compose.yml`:
```yaml
mem_limit: 8g    # Change memory limit
cpus: 1.0        # Change CPU limit
```

### Modify Build Configuration

Edit `nginx-production-tpe-v22.sh`:
- **NGINX version**: Change `NGINX_VERSION="1.28.0"`
- **OpenSSL branch**: Modify `OPENSSL_QUIC_BRANCH="openssl-3.1.4+quic"`
- **Build paths**: Adjust `BASE`, `SRC_DIR`, `DEPS_DIR`
- **NGINX modules**: Edit the `build_nginx()` function's `./configure` call

## Build Output Locations

After a successful build:

- **NGINX binary**: `/usr/local/nginx/sbin/nginx`
- **Configuration**: `/etc/nginx/nginx.conf`
- **Logs**: `/var/log/nginx/`
- **Modules**: `/usr/lib/nginx/modules/`

When running in Docker, use the volume mount to access:
```bash
docker run -v nginx-build:/build nginx-builder:latest ls -la /build
```

## Troubleshooting

### Build Fails with "OpenSSL configure error"

The script now detects unsupported OpenSSL configure options and skips them. Check the output for:
```
[warn] OpenSSL branch does not support no-docs; skipping that option.
```

This is expected and non-fatal.

### "No space left on device"

The build requires ~2-3GB of space. Free up disk space or increase Docker's storage allocation.

### Docker memory limit exceeded (exit code 137)

Increase the memory limit in `docker-compose.yml`:
```yaml
mem_limit: 16g
```

Or reduce parallelism:
```bash
BUILD_JOBS=1 docker-compose up --build
```

### Script fails with "Please run as root"

Use `sudo` for native builds:
```bash
sudo bash nginx-production-tpe-v22.sh
```

Docker runs with root by default, so this is not an issue in containers.

## Monitoring the Build

**Check real-time progress:**
```bash
# Docker Compose
docker-compose logs -f

# Manual Docker
tail -f container-manual-output.txt

# Native
sudo tail -f ~/nginx-build/build.log
```

**Estimated build time** (depending on system):
- Initial dependency compilation: 10-20 minutes
- NGINX compilation: 5-10 minutes
- **Total**: 15-30 minutes (may be longer in resource-constrained containers)

## Next Steps After Build

Once the build completes successfully:

1. **Verify the NGINX binary**:
   ```bash
   /usr/local/nginx/sbin/nginx -v
   /usr/local/nginx/sbin/nginx -V  # Show all modules
   ```

2. **Test the configuration**:
   ```bash
   /usr/local/nginx/sbin/nginx -t
   ```

3. **Start the service** (if using systemd):
   ```bash
   sudo systemctl start nginx
   ```

4. **Check for errors**:
   ```bash
   sudo tail -f /var/log/nginx/error.log
   ```

## Support

For issues or questions:
- Check the build log: `container-compose-output.txt` or `~/nginx-build/build.log`
- Review the main script: `nginx-production-tpe-v22.sh`
- Consult the `_ProjectDocs/` folder for detailed architecture notes

---

**Last Updated**: 2026-07-01  
**NGINX Version**: 1.28.0  
**OpenSSL QUIC Branch**: openssl-3.1.4+quic

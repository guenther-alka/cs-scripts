#!/bin/bash
# =============================================================================
# install-rclone-solaris.sh
# Downloads and builds rclone on Oracle Solaris 11.4
#
# Background:
# - Pre-built rclone binaries for Solaris are not officially provided
# - rclone must be compiled from source using Go
# - Go for Solaris/amd64 is available as a pre-built archive from golang.org
# - rclone builds cleanly on Solaris, unsupported backends are automatically
#   skipped by the Go compiler.
#
# Prerequisites:
#   pkg install archiver/gnu-tar    (Solaris tar does not support gzip)
#   curl -k ...                     (use -k if system time is wrong)
#
# Usage:
#   chmod +x install-rclone-solaris.sh
#   ./install-rclone-solaris.sh
# =============================================================================

set -e

GO_VERSION="1.24.0"
RCLONE_VERSION="1.69.1"
GO_URL="https://dl.google.com/go/go${GO_VERSION}.solaris-amd64.tar.gz"
RCLONE_URL="https://github.com/rclone/rclone/archive/refs/tags/v${RCLONE_VERSION}.tar.gz"

# -- 1. gnu-tar ----------------------------------------------------------------
# Solaris ships with its own tar which does not support the -z (gzip) flag.
# gnu-tar (gtar) is required to extract .tar.gz archives.
echo "[1/4] Checking gnu-tar..."
if ! command -v gtar >/dev/null 2>&1; then
    pkg install archiver/gnu-tar
fi
echo "  OK: $(gtar --version | head -1)"

# -- 2. Go ---------------------------------------------------------------------
# Download the official Go archive for Solaris/amd64 and extract to /usr/local.
# Use -k to skip SSL verification (required if system clock is wrong).
echo "[2/4] Installing Go ${GO_VERSION}..."
rm -rf /usr/local/go
curl -k -L -o /tmp/go.tar.gz "${GO_URL}"
gtar -xzf /tmp/go.tar.gz -C /usr/local
export PATH=$PATH:/usr/local/go/bin
grep -q "/usr/local/go/bin" ~/.profile 2>/dev/null || \
    echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.profile
echo "  OK: $(go version)"

# -- 3. rclone -----------------------------------------------------------------
# Download rclone source and build it.
# We use 'go build' directly instead of 'make' to avoid Solaris 'make' syntax errors.
# -ldflags "-s -w" strips debugging symbols to keep the binary slim.
echo "[3/4] Building rclone ${RCLONE_VERSION}..."
rm -rf /tmp/rclone-build
mkdir /tmp/rclone-build && cd /tmp/rclone-build
curl -k -L -o rclone.tar.gz "${RCLONE_URL}"
gtar -xzf rclone.tar.gz
cd "rclone-${RCLONE_VERSION}"

# Native Go build without relying on gmake
go build -v -ldflags "-s -w" -o rclone .
echo "  OK: $(./rclone version | head -1)"

# -- 4. Install ----------------------------------------------------------------
echo "[4/4] Installing rclone to /usr/local/bin..."
mkdir -p /usr/local/bin
cp rclone /usr/local/bin/rclone
chmod +x /usr/local/bin/rclone
rm -rf /tmp/rclone-build /tmp/go.tar.gz

echo ""
echo "Done. $(/usr/local/bin/rclone version | head -1)"
echo ""
echo "Example - configure a new storage provider:"
echo "  rclone config"
echo ""
echo "Example - sync a local directory to Oracle Cloud Infrastructure (OCI) S3:"
echo "  rclone sync /data my-s3-bucket:bucket-name"

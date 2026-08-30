#!/bin/bash
# =============================================================================
# install-restic-solaris.sh
# Downloads and builds restic on Oracle Solaris 11.4
#
# Background:
# - No pre-built restic binary is available for Solaris
# - restic must be compiled from source using Go
# - Go for Solaris/amd64 is available as a pre-built archive from golang.org
# - restic builds cleanly on Solaris with no patches required
# - The resulting binary is statically linked (no library dependencies)
#
# Prerequisites:
#   pkg install archiver/gnu-tar   (Solaris tar does not support gzip)
#   curl -k ...                    (use -k if system time is wrong)
#
# Usage:
#   chmod +x install-restic-solaris.sh
#   ./install-restic-solaris.sh
# =============================================================================

set -e

GO_VERSION="1.23.0"
RESTIC_VERSION="0.18.1"
GO_URL="https://dl.google.com/go/go${GO_VERSION}.solaris-amd64.tar.gz"
RESTIC_URL="https://github.com/restic/restic/archive/refs/tags/v${RESTIC_VERSION}.tar.gz"

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

# -- 3. restic -----------------------------------------------------------------
# Download restic source and build it.
# Go auto-detects Solaris as the target OS - no patches or workarounds needed.
# The resulting binary is statically linked and has no runtime dependencies.
echo "[3/4] Building restic ${RESTIC_VERSION}..."
rm -rf /tmp/restic-build
mkdir /tmp/restic-build && cd /tmp/restic-build
curl -k -L -o restic.tar.gz "${RESTIC_URL}"
gtar -xzf restic.tar.gz
cd "restic-${RESTIC_VERSION}"
go run build.go
echo "  OK: $(./restic version)"

# -- 4. Install ----------------------------------------------------------------
echo "[4/4] Installing restic to /usr/local/bin..."
cp restic /usr/local/bin/restic
chmod +x /usr/local/bin/restic
rm -rf /tmp/restic-build /tmp/go.tar.gz

echo ""
echo "Done. $(restic version)"
echo ""
echo "Example - backup to S3:"
echo "  export AWS_ACCESS_KEY_ID=key"
echo "  export AWS_SECRET_ACCESS_KEY=secret"
echo "  restic -r s3:http://s3server:9000/bucket init"
echo "  restic -r s3:http://s3server:9000/bucket backup /data"
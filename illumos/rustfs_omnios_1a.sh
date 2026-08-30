#!/bin/bash
# ============================================================================
# rustfs_omnios_1a.sh
# Build RustFS on OmniOS / Illumos -- clean start
#
# Renamed from build_rustfs_2a12.sh (2026-08-09), following upstream
# PR #5853 (merged into rustfs main as commit 9996d567d) which fixed the
# root cause of two of our local workarounds:
#
#   - Pulsar protobuf codegen (previously step 10, ~350 lines: local
#     pulsar copy with a stubbed build.rs + hand-written proto structs,
#     `[patch.crates-io]` override) is GONE. Upstream now keeps pulsar's
#     dependency lean on every platform (crates/targets/Cargo.toml no
#     longer has an illumos-specific `protobuf-src` cfg-gate either --
#     that was the PR's first draft, but the maintainer (@houseme) asked
#     to verify a system `protoc` was sufficient instead of vendoring a
#     C++ build; confirmed on .189, 3m34s vs 7m36s for the vendored path,
#     see PR discussion). New requirement: `protoc` must be present via
#     `pkg install ooce/developer/protobuf` (step 1). No cmake/gnu-make
#     needed for this normal path (that combo was only required to test
#     the vendored `protobuf-src` alternative, and is not needed here).
#   - clocksource's Illumos-incompatible CLOCK_*_COARSE sed patch (former
#     part of step 12) is now a permanent no-op: the PR bumped
#     `ratelimit` 0.10 -> 2.0, which dropped the clocksource dependency
#     from the graph entirely (confirmed via `cargo tree -i clocksource`
#     returning empty). Removed rather than left as a dead guarded block.
#
# Net effect: step 10 removed entirely, step 12 shrinks (clocksource
# sub-block gone, profiling.rs/main.rs/allocator_reclaim.rs patches
# unchanged), total step count 14 -> 13.
#
# Post-2a12 hotfix (2026-08-08):
#   - step 3 (swap check) created rpool/swap_build (8G) but never removed
#     it. Found on .189: rpool (31.5G total) filled to 100% (3MB free)
#     across a handful of builds, since the zvol persisted permanently.
#     Fix: `trap cleanup_build_swap EXIT` right after `set -o pipefail`
#     destroys rpool/swap_build on any script exit (success/error/Ctrl-C),
#     so build-swap is always ephemeral again, matching original intent.
#
# Changes vs 2a11:
#   - main.rs patch (mimalloc global_allocator removal): the two regexes
#     that strip `#[global_allocator] static GLOBAL ...;` blocks left a
#     dangling `#[cfg(...)]` attribute behind on every fresh checkout.
#     Root cause: the first regex removed the global_allocator+static
#     pair WITHOUT checking for/consuming a preceding #[cfg(...)] line at
#     all (so any cfg-gated block loses its static but keeps its cfg
#     attribute); the second regex, meant to handle the cfg-gated case as
#     one unit, never actually matched, because `[^)]*` inside
#     `#\[cfg\([^)]*\)\]` breaks on nested parens -- and this file's
#     real attributes ARE nested: #[cfg(all(feature = "hotpath", feature
#     = "hotpath-alloc"))] and #[cfg(not(all(...)))]. Two orphaned
#     #[cfg(...)] attributes ended up stacked directly above `fn main()`,
#     with mutually exclusive conditions -- so `fn main` was never
#     compiled under EITHER feature configuration:
#       error[E0601]: `main` function not found in crate `rustfs`
#     Fix: replaced both regexes with a single pattern that optionally
#     consumes a preceding #[cfg(...)] line (using [^\n]* so nested
#     parens on the same line are fine) together with the
#     #[global_allocator] + static GLOBAL lines as one atomic removal --
#     nothing is ever left dangling, regardless of whether the static was
#     cfg-gated or not.
#
# Changes vs 2a10:
#   - Step 2: proactively remove a stale rustup-managed toolchain if one
#     exists from an earlier build, even when the system (OOCE pkg) Rust
#     already satisfies the version requirement. Root cause found on
#     .189: an earlier run's `rustup install stable` (back when "stable"
#     resolved to 1.96.0) left toolchains/stable-x86_64-unknown-illumos
#     on disk. RustFS ships its own rust-toolchain.toml, and `rustup
#     show` confirmed it re-activates that stale pinned toolchain
#     ("active because: overridden by rust-toolchain.toml") independent
#     of PATH ordering -- so even with /opt/ooce/bin first in PATH, the
#     stale 1.96.0 toolchain could still shadow the newer OOCE rustc
#     (1.97.1) and fail with "rustc 1.96.0 is not supported by ...".
#     Fix: if RUST_OK=1 (system already >= 1.97) AND a rustup install is
#     present ($HOME/.cargo/bin/rustup exists), run `rustup self
#     uninstall -y` to remove the second toolchain entirely -- so there
#     is nothing left on disk that a toolchain-file override could ever
#     activate. Only touches rustup's own managed install, never the
#     OOCE pkg-provided rustc/cargo.
#
# Changes vs 2a9:
#   - allocator_reclaim.rs / memory_observability.rs: both call
#     libmimalloc_sys directly, gated only by `not(target_os = "windows")`.
#     Since mimalloc/libmimalloc-sys is disabled entirely for illumos
#     (step 7), these calls now fail to compile:
#       error[E0433]: cannot find module or crate `libmimalloc_sys`
#     Fix: widen the cfg guard to also exclude illumos and add an illumos
#     no-op branch (mirroring the existing windows fallback) for both
#     `collect_allocator_memory` and `read_allocator_memory_snapshot`.
#     Previously (2a1-2a9) this was only attempted for
#     allocator_reclaim.rs via a brittle exact-block string match, which
#     silently stopped matching once upstream simplified its cfg guard
#     ("pattern not found, skipping") -- and memory_observability.rs
#     wasn't handled at all. This version anchors on stable landmarks
#     (fn signature + windows fallback fn) instead of the full function
#     body, and covers both files.
#
# Changes vs 2a8:
#   - add_patch_crates_io_entry(): fixed to only match an exact
#     "[patch.crates-io]" table-header LINE (trimmed line equality),
#     instead of a plain string search. The 2a8 version used
#     content.replace() on the whole file text, which matched the first
#     occurrence of that string anywhere -- including inside an unrelated
#     comment earlier in the file -- corrupting Cargo.toml with the
#     pulsar entry spliced into prose ("error: unexpected key or value,
#     expected newline, `#`").
#
# Changes vs 2a7:
#   - Step 4: cd "$HOME" (or /) before `rm -rf "$RUSTFS_DIR"`. On illumos,
#     rm -rf fails on the current working directory of a running process
#     ("Cannot remove any directory in the path of the current working
#      directory") if the script is launched from inside $RUSTFS_DIR.
#   - Steps 10+11: [patch.crates-io] is now added via a shared
#     add_patch_crates_io_entry() helper that reuses an existing header
#     instead of blindly appending a second one. The upstream Cargo.toml
#     already ships a [patch.crates-io] section, so appending our own
#     caused a TOML duplicate-key error at `cargo fetch`.
#
# Changes vs 2a6:
#   - rustfs/Cargo.toml: remove "pyroscope" from the `full = [...]` meta
#     feature list. After 2a6 commented out the standalone `pyroscope`
#     feature definition, cargo fetch still failed with:
#     "feature `full` includes `pyroscope` which is neither a dependency
#      nor another feature" -- because `full` still referenced it.
#
# Changes vs 2a5:
#   - rustfs/Cargo.toml: comment out `pyroscope = ["rustfs-obs/pyroscope"]`
#     feature entry (line ~51). Without this, cargo fetch fails:
#     "package `rustfs` depends on `rustfs-obs` with feature `pyroscope`
#      but `rustfs-obs` does not have that feature" -- because step 8
#     already strips the pyroscope feature definition out of
#     crates/obs/Cargo.toml, but nothing pointed at the feature-forwarding
#     line in rustfs/Cargo.toml's own [features] section.
#
# Changes vs 2a4:
#   - jsonwebtoken: add rust_crypto feature (use_pem alone breaks JWT auth/login)
#   - Console URL: http://<ip>:9001/rustfs/console/index.html
#   - allocator_reclaim.rs: illumos no-op patch (libmimalloc_sys ref in non-linux cfg)
#   - Console: download rustfs-console ZIP before build, unpack to rustfs/static/
#     so it is embedded into the binary via rust-embed at compile time
#   - After BUILD SUCCESSFUL: print OmniOS startup instructions including
#     required ipadm TCP/UDP buffer tuning and server start command
#
# Changes vs 2a3 (retained):
#   - mimalloc disabled (SIGSEGV: mi_page_map_set_range_prim on Illumos)
#   - mimalloc + libmimalloc-sys commented out in rustfs/Cargo.toml
#   - global_allocator block removed from main.rs
#   - mimalloc commented out in workspace Cargo.toml
#
# Usage:
#   bash ./rustfs_omnios_1a.sh
#
# Requirements:
#   - OmniOS installation with at least 16GB RAM and 40GB free disk.
#     (2026-08-09, confirmed on .189: with 14GB RAM the default
#     codegen-units=1 profile OOM'd forking gcc at the final link step;
#     needed the CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16 override in
#     step 13 to bring rustc's peak RSS down from 9GB to 5.4GB before it
#     would succeed. 31.5G total disk was also too tight on its own,
#     bottoming out at ~1.3GB free mid-build. 16GB RAM / 40GB disk are
#     the recommended floor to build comfortably without needing that
#     workaround or babysitting free space.)
#   - System Rust via pkg (OOCE developer/rust, >= 1.97). Any stale rustup
#     install from an earlier build is removed automatically (step 2).
#   - bash (not sh)
#
# What this script does:
#   1.  Install system packages (incl. protoc, for pulsar's build-time
#       protobuf codegen -- see header note above re PR #5853)
#   2.  Ensure Rust >= 1.96 (installs via rustup if needed)
#   3.  Add swap (ZFS zvol) if total swap < 6GB
#   4.  Delete old build directory, clone fresh from main
#   5.  Write .cargo/config.toml
#   6.  Patch workspace Cargo.toml:
#         - aws-lc-rs -> ring (6 deps)
#         - suppaftp feature: tokio-rustls-ring (not -rs)
#         - comment out pprof / pyroscope / jemalloc_pprof / mimalloc
#   7.  Patch rustfs/Cargo.toml (pprof + mimalloc lines)
#   7b. Patch main.rs (remove mimalloc global_allocator, fix init_from_env)
#   7c. Patch allocator_reclaim.rs (illumos no-op for libmimalloc_sys call)
#   8.  Patch crates/obs/Cargo.toml:
#         - comment out jemalloc_pprof dependency
#         - comment out pyroscope feature definition
#         - comment out pyroscope target dependency (line-number aware)
#   9.  cargo fetch
#  10.  Patch brotli (local copy):
#         - alloc-no-stdlib 2.0 -> 3.0 (fixes duplicate trait conflict)
#         - add to [patch.crates-io]
#  11.  Patch Rust sources:
#         - profiling.rs: remove appended stubs if present (file already
#           has unsupported_impl re-export on Illumos)
#         - main.rs: remove .await from init_from_env()
#  12.  Download and install Console ZIP to rustfs/static/ (embedded at
#       compile time)
#  13.  Build (release)
#  14.  Print startup instructions
#
# Known fixes vs 2a2:
#   - rustup installed if system Rust < 1.96 (main branch requires 1.96)
#   - swap auto-provisioned as ZFS zvol if insufficient
#   - brotli 8.0.3 alloc-no-stdlib version conflict fixed via local patch
#   - crates/obs pyroscope target dependency correctly commented out
#   - profiling.rs: no stubs appended (unsupported_impl already exported)
#   - /tmp patches restored automatically (lost on reboot)
#   - all docs in English
# ============================================================================

set -e
set -o pipefail

# Ephemeral build-swap cleanup: rpool/swap_build (step 3) is only meant to
# exist for the duration of this build. Without this trap it accumulates
# permanently (8G on a 31.5G pool == pool fills to 100% after a few runs,
# as found on .189 2026-08-08). Runs on ANY exit (success, error, Ctrl-C).
cleanup_build_swap() {
    if zfs list rpool/swap_build >/dev/null 2>&1; then
        echo "  -> Removing temporary build-swap (rpool/swap_build)..."
        swap -d /dev/zvol/dsk/rpool/swap_build 2>/dev/null || true
        zfs destroy rpool/swap_build 2>/dev/null || true
    fi
}
trap cleanup_build_swap EXIT

if [ -z "${BASH_VERSION:-}" ]; then
    echo "ERROR: Run with bash, not sh:  bash $0"
    exit 1
fi

RUSTFS_DIR="/root/rustfs"
RUSTFS_REPO="https://github.com/rustfs/rustfs"
LOGFILE="/tmp/rustfs-build.log"
START_TS="$(date '+%Y-%m-%d %H:%M:%S %Z')"

# Add a "key = value" line under [patch.crates-io] in the given Cargo.toml,
# reusing an existing header if the upstream file already has one (appending
# a second "[patch.crates-io]" header is invalid TOML -- duplicate key).
add_patch_crates_io_entry() {
    local toml_file="$1"
    local entry_line="$2"
    python3 - "$toml_file" "$entry_line" << 'PYEOF'
import sys
path, entry = sys.argv[1], sys.argv[2]
with open(path) as f:
    lines = f.readlines()
# Only match an actual TOML table header line (exact, trimmed), never a
# substring occurring inside a comment or prose elsewhere in the file.
header_idx = None
for i, line in enumerate(lines):
    if line.strip() == "[patch.crates-io]":
        header_idx = i
        break
if header_idx is not None:
    lines.insert(header_idx + 1, entry + "\n")
else:
    if lines and not lines[-1].endswith("\n"):
        lines[-1] = lines[-1] + "\n"
    lines.append("\n[patch.crates-io]\n" + entry + "\n")
with open(path, "w") as f:
    f.writelines(lines)
PYEOF
}

echo "============================================================"
echo " RustFS Build Script 1a for OmniOS / Illumos"
echo " Started: $START_TS"
echo "============================================================"
echo ""

# ---------------------------------------------------------------------------
# 1. System packages
# ---------------------------------------------------------------------------
echo "[1/13] Installing system packages..."

pkg install -q developer/versioning/git 2>/dev/null || true
pkg install -q developer/rust            2>/dev/null || true
pkg install -q developer/gcc             2>/dev/null || true
# protoc: needed for pulsar's build-time protobuf codegen (PulsarApi.proto
# in build.rs). Package name confirmed via `pkg search -H protoc` --
# provides /opt/ooce/bin/protoc. (The old `developer/build/cmake` line
# here was dead weight: wrong package name -- never installed anything,
# silently swallowed by `|| true` -- and unneeded now that pulsar no
# longer needs a vendored C++ protoc build; see header note re PR #5853.)
pkg install -q ooce/developer/protobuf   2>/dev/null || true
pkg install -q runtime/python-313        2>/dev/null || true

for cmd in gcc python3 git curl protoc; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: $cmd not found. Aborting."
        exit 1
    fi
done
echo "  GCC:     $(gcc --version | head -1)"
echo "  Python3: $(python3 --version)"
echo "  protoc:  $(protoc --version)"
echo ""

# ---------------------------------------------------------------------------
# 2. Rust >= 1.96
# ---------------------------------------------------------------------------
echo "[2/13] Checking Rust version..."

export PATH="/opt/ooce/bin:$HOME/.cargo/bin:$PATH"

RUST_OK=0
if command -v rustc >/dev/null 2>&1; then
    RUSTVER=$(rustc --version | grep -oE '[0-9]+\.[0-9]+' | head -1)
    MAJOR=$(echo "$RUSTVER" | cut -d. -f1)
    MINOR=$(echo "$RUSTVER" | cut -d. -f2)
    if [ "$MAJOR" -gt 1 ] || { [ "$MAJOR" -eq 1 ] && [ "$MINOR" -ge 97 ]; }; then
        RUST_OK=1
    fi
fi

if [ "$RUST_OK" -eq 0 ]; then
    echo "  -> System Rust < 1.97, installing via rustup..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
        sh -s -- -y --default-toolchain stable --no-modify-path
    source "$HOME/.cargo/env"
else
    # System Rust already satisfies the requirement -- but if an OLDER
    # rustup install is still lingering from an earlier build (e.g. from
    # back when "stable" resolved to < 1.97), it can still shadow the
    # system compiler: RustFS ships its own rust-toolchain.toml, and
    # rustup honors that override regardless of PATH ordering, reviving
    # the stale pinned toolchain underneath cargo/rustc. Remove it so
    # there is nothing left on disk that could ever be activated.
    if [ -x "$HOME/.cargo/bin/rustup" ]; then
        echo "  -> Stale rustup install found alongside system Rust >= 1.97 -- removing it"
        echo "     (prevents RustFS's rust-toolchain.toml from reviving an old pinned toolchain)"
        "$HOME/.cargo/bin/rustup" self uninstall -y >/dev/null 2>&1 || true
    fi
fi

echo "  Rust:  $(rustc --version)"
echo "  Cargo: $(cargo --version)"
echo ""

# ---------------------------------------------------------------------------
# 3. Swap check (need >= 6GB total)
# ---------------------------------------------------------------------------
echo "[3/13] Checking swap..."

SWAP_KB=$(swap -l 2>/dev/null | awk 'NR>1 {sum+=$4} END {print sum+0}')
SWAP_GB=$((SWAP_KB / 1024 / 1024))
echo "  Current swap: ${SWAP_GB}GB"

if [ "$SWAP_GB" -lt 6 ]; then
    # Dynamic sizing (2026-08-09): the old fixed `-V 8g` failed outright
    # ("out of space") once rpool's free space dropped below 8G -- this
    # pool is only 31.5G total, and everyday usage (BEs, snapshots, the
    # build's own target/ dir) eats into that fast. Now we only ask for
    # just enough to clear the 6GB threshold, and check pool headroom
    # first so a tight pool degrades to a clear warning instead of a
    # hard `set -e` abort mid-script.
    NEED_GB=$((6 - SWAP_GB))
    POOL_AVAIL_GB=$(zfs list -H -o avail -p rpool | awk '{print int($1/1024/1024/1024)}')
    # Require the swap zvol PLUS a few GB headroom for the build itself
    # (target/ dir, cargo registry growth) -- not just the swap alone.
    if [ "$POOL_AVAIL_GB" -lt "$((NEED_GB + 3))" ]; then
        echo "  WARNING: only ${POOL_AVAIL_GB}GB free on rpool, need ~${NEED_GB}GB"
        echo "           swap + 3GB build headroom -- skipping extra swap."
        echo "           Build may fail with OOM if it needs the memory."
    else
        echo "  -> Adding ${NEED_GB}GB swap zvol (pool has ${POOL_AVAIL_GB}GB free)..."
        if ! zfs list rpool/swap_build >/dev/null 2>&1; then
            zfs create -V "${NEED_GB}g" rpool/swap_build
            sleep 2
        fi
        swap -a /dev/zvol/dsk/rpool/swap_build 2>/dev/null || true
        SWAP_KB=$(swap -l 2>/dev/null | awk 'NR>1 {sum+=$4} END {print sum+0}')
        SWAP_GB=$((SWAP_KB / 1024 / 1024))
        echo "  Swap after: ${SWAP_GB}GB"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# 4. Delete old build dir, clone fresh
# ---------------------------------------------------------------------------
echo "[4/13] Deleting old build directory and cloning fresh..."

# Always leave RUSTFS_DIR before removing it -- on illumos, rm -rf on the
# current working directory fails with "Cannot remove any directory in
# the path of the current working directory" if the script was started
# from inside (or below) $RUSTFS_DIR.
cd "$HOME" 2>/dev/null || cd /

if [ -d "$RUSTFS_DIR" ]; then
    echo "  -> Removing $RUSTFS_DIR ..."
    rm -rf "$RUSTFS_DIR"
fi

echo "  -> Cloning $RUSTFS_REPO ..."
git clone "$RUSTFS_REPO" "$RUSTFS_DIR"
cd "$RUSTFS_DIR"
echo "  -> Commit: $(git log --oneline -1)"
echo ""

# ---------------------------------------------------------------------------
# 5. Cargo config
# ---------------------------------------------------------------------------
echo "[5/13] Writing .cargo/config.toml..."

mkdir -p "$RUSTFS_DIR/.cargo"
cat > "$RUSTFS_DIR/.cargo/config.toml" << 'CARGOEOF'
[target.x86_64-unknown-illumos]
linker = "gcc"
ar = "ar"

[build]
rustflags = ["--cfg", "tokio_unstable"]

[env]
AWS_LC_SYS_STATIC = "1"
AR_x86_64_unknown_illumos  = "ar"
CC_x86_64_unknown_illumos  = "gcc"
CFLAGS_x86_64_unknown_illumos = "-D_GNU_SOURCE"
CARGOEOF

echo "  -> .cargo/config.toml written"
echo ""

# ---------------------------------------------------------------------------
# 6. Patch workspace Cargo.toml
# ---------------------------------------------------------------------------
echo "[6/13] Patching workspace Cargo.toml..."

cd "$RUSTFS_DIR"

# aws-lc-rs -> ring
sed -i 's/\(hyper-rustls = {[^}]*\)"aws-lc-rs"/\1"ring"/'    Cargo.toml
sed -i 's/\(tokio-rustls = {[^}]*\)"aws-lc-rs"/\1"ring"/'    Cargo.toml
sed -i 's/\(jsonwebtoken = {[^}]*\)"aws_lc_rs"/\1"use_pem"/' Cargo.toml
# jsonwebtoken needs rust_crypto feature for CryptoProvider (use_pem alone causes JWT auth failure)
python3 - Cargo.toml << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    src = f.read()
src = re.sub(
    r'(jsonwebtoken = \{[^}]*features = \[)"use_pem"(\])',
    r'\1"use_pem", "rust_crypto"\2',
    src
)
with open(path, 'w') as f:
    f.write(src)
PYEOF
sed -i 's/"aws-lc-rs", //'                                     Cargo.toml
sed -i 's/, "prefer-post-quantum"//'                           Cargo.toml
sed -i 's/rustls-aws-lc/rustls-ring/g'                        Cargo.toml
# suppaftp: correct feature is tokio-rustls-ring (not tokio-rustls-ring-rs)
sed -i 's/tokio-rustls-aws-lc-rs/tokio-rustls-ring/g'        Cargo.toml
sed -i 's/tokio-rustls-ring-rs/tokio-rustls-ring/g'           Cargo.toml

# comment out pprof / pyroscope / jemalloc_pprof
sed -i '/^pyroscope = /s/^/# /'                                        Cargo.toml
sed -i '/^jemalloc_pprof = /s/^/# /'                                   Cargo.toml
sed -i '/^pprof = { package = "pprof-pyroscope-fork"/s/^/# /'         Cargo.toml
# mimalloc crashes on Illumos (mi_page_map_set_range_prim SIGSEGV)
sed -i '/^mimalloc = /s/^/# /'                                         Cargo.toml

echo "  -> Workspace Cargo.toml patched"
echo ""

# ---------------------------------------------------------------------------
# 7. Patch rustfs/Cargo.toml
# ---------------------------------------------------------------------------
echo "[7/13] Patching rustfs/Cargo.toml..."

sed -i '/^pprof = { workspace = true/s/^/# /'          rustfs/Cargo.toml
sed -i '/^jemalloc_pprof = { workspace = true/s/^/# /' rustfs/Cargo.toml
# mimalloc crashes on Illumos (SIGSEGV in mi_page_map_set_range_prim)
sed -i '/^mimalloc = { workspace = true/s/^/# /'       rustfs/Cargo.toml
sed -i '/^libmimalloc-sys = /s/^/# /'                  rustfs/Cargo.toml

# rustfs's own [features] entry still forwards to rustfs-obs/pyroscope,
# which no longer exists once crates/obs/Cargo.toml is patched (step 8).
# Without this, `cargo fetch` fails with:
#   "package `rustfs` depends on `rustfs-obs` with feature `pyroscope`
#    but `rustfs-obs` does not have that feature"
sed -i '/^pyroscope = \["rustfs-obs\/pyroscope"\]/s/^/# /' rustfs/Cargo.toml

# `full` meta-feature still lists pyroscope as a sub-feature -- remove it,
# otherwise cargo fetch fails with:
#   "feature `full` includes `pyroscope` which is neither a dependency
#    nor another feature"
sed -i '/^full = \[/s/, *"pyroscope"//' rustfs/Cargo.toml

echo "  -> rustfs/Cargo.toml patched (mimalloc disabled, pyroscope feature-forward disabled)"
echo ""

# ---------------------------------------------------------------------------
# 8. Patch crates/obs/Cargo.toml
# ---------------------------------------------------------------------------
echo "[8/13] Patching crates/obs/Cargo.toml..."

python3 - crates/obs/Cargo.toml << 'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()
result = []
for line in lines:
    s = line.lstrip()
    # comment out pyroscope feature definition
    if s.startswith('pyroscope = ["dep:') or s.startswith('pyroscope = ['):
        line = line.replace(s, '# ' + s)
    # comment out jemalloc_pprof dependency
    elif s.startswith('jemalloc_pprof = { workspace = true'):
        line = line.replace(s, '# ' + s)
    # comment out pyroscope dependency (both plain and target-specific)
    elif s.startswith('pyroscope = { workspace = true'):
        line = line.replace(s, '# ' + s)
    result.append(line)
with open(path, 'w') as f:
    f.writelines(result)
print("  -> crates/obs/Cargo.toml patched")
PYEOF

echo ""

# ---------------------------------------------------------------------------
# 9. cargo fetch
# ---------------------------------------------------------------------------
echo "[9/13] Running cargo fetch..."
rm -f Cargo.lock
cargo fetch
echo ""

# ---------------------------------------------------------------------------
# 10. Brotli local patch (alloc-no-stdlib 2.0 -> 3.0)
# ---------------------------------------------------------------------------
echo "[10/13] Patching brotli..."

BROTLI_CACHE_DIR=$(find "$HOME/.cargo/registry/src" -type d -name "brotli-8*" 2>/dev/null | head -1)
if [ -z "$BROTLI_CACHE_DIR" ]; then
    echo "ERROR: brotli not found in cargo registry."
    exit 1
fi

echo "  -> Brotli cache: $BROTLI_CACHE_DIR"
rm -rf /tmp/brotli-local-patch
cp -r "$BROTLI_CACHE_DIR" /tmp/brotli-local-patch

# Upgrade alloc-no-stdlib from 2.0 to 3.0 in brotli's Cargo.toml
python3 - /tmp/brotli-local-patch/Cargo.toml << 'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()
result = []
i = 0
while i < len(lines):
    result.append(lines[i])
    if lines[i].strip() == '[dependencies.alloc-no-stdlib]':
        i += 1
        result.append(lines[i].replace('version = "2.0"', 'version = "3.0"'))
    i += 1
with open(path, 'w') as f:
    f.writelines(result)
print("  -> brotli alloc-no-stdlib 2.0 -> 3.0")
PYEOF

add_patch_crates_io_entry "$RUSTFS_DIR/Cargo.toml" 'brotli = { path = "/tmp/brotli-local-patch" }'
echo "  -> [patch.crates-io] brotli added"

rm -f "$RUSTFS_DIR/Cargo.lock"
echo "  -> cargo fetch (update lock with patches)..."
cd "$RUSTFS_DIR"
cargo fetch
echo ""

# ---------------------------------------------------------------------------
# 11. Patch Rust sources
# ---------------------------------------------------------------------------
echo "[11/13] Patching Rust sources..."

# clocksource COARSE-clock sed patch removed (2026-08-09): upstream PR
# #5853 bumped ratelimit 0.10 -> 2.0, which dropped the clocksource
# dependency from the graph entirely. Confirmed via
# `cargo tree -i clocksource` returning empty after the bump -- so
# clocksource-*/src/sys/unix.rs is never fetched anymore and this block
# would always be a no-op. See header note.

# profiling.rs:
# The file already has on Illumos:
#   #[cfg(not(any(target_os = "linux", target_os = "macos")))]
#   pub use unsupported_impl::{...};
# So we do NOT append stubs -- they already exist via unsupported_impl.
# We only ensure no duplicate stubs exist from previous runs.
PROFILING="$RUSTFS_DIR/rustfs/src/profiling.rs"
if grep -q "profiling not supported on this platform" "$PROFILING"; then
    echo "  -> profiling.rs: removing stale duplicate stubs..."
    python3 - "$PROFILING" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    src = f.read()
# Remove our appended stub block if present
import re
src = re.sub(
    r'\n#\[cfg\(not\(any\(target_os = "linux", target_os = "macos"\)\)\)\]\npub async fn dump_cpu_pprof_for.*?pub fn shutdown_profiling\(\) \{\}',
    '',
    src,
    flags=re.DOTALL
)
with open(path, 'w') as f:
    f.write(src)
print("  -> profiling.rs stubs removed")
PYEOF
fi

# main.rs: remove mimalloc global_allocator + fix init_from_env
MAIN="$RUSTFS_DIR/rustfs/src/main.rs"
python3 - "$MAIN" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    src = f.read()
# remove mimalloc use statements
src = re.sub(r'\nuse mimalloc[^\n]*;', '', src)
src = re.sub(r'\nuse libmimalloc_sys[^\n]*;', '', src)
# remove #[global_allocator] static ... MiMalloc ..., together with an
# OPTIONAL preceding #[cfg(...)] attribute line, as one atomic removal --
# using [^\n]* (not [^)]*) inside cfg(...) so nested parens on one line
# (e.g. cfg(all(feature = "hotpath", feature = "hotpath-alloc"))) don't
# break the match and leave the cfg attribute dangling above fn main().
src = re.sub(
    r'\n(?:#\[cfg\([^\n]*\)\]\s*\n)?#\[global_allocator\]\s*\nstatic GLOBAL[^\n]*;',
    '',
    src
)
# remove .await from init_from_env
src = src.replace('rustfs::profiling::init_from_env().await;', 'rustfs::profiling::init_from_env();')
with open(path, 'w') as f:
    f.write(src)
print("  -> main.rs patched (mimalloc removed, init_from_env .await removed)")
PYEOF

# Patch allocator_reclaim.rs + memory_observability.rs: both call
# libmimalloc_sys directly, gated only by `not(target_os = "windows")`.
# Since we disabled the mimalloc/libmimalloc-sys dependency entirely for
# illumos, these calls need an illumos no-op branch too. We anchor on the
# stable landmarks (the fn signature + the windows fallback fn), not on
# the full function body, since upstream has already simplified the cfg
# guard once since this patch was first written.
ALLOC_RECLAIM="$RUSTFS_DIR/rustfs/src/allocator_reclaim.rs"
MEM_OBS="$RUSTFS_DIR/rustfs/src/memory_observability.rs"

python3 - "$ALLOC_RECLAIM" "$MEM_OBS" << 'PYEOF2'
import sys, re

def patch_illumos_noop(path, main_fn_sig, windows_fn_sig, illumos_body):
    with open(path) as f:
        src = f.read()

    if f'#[cfg(target_os = "illumos")]\n{illumos_body.splitlines()[0]}' in src:
        print(f"  -> {path}: illumos no-op already present, skipping")
        return

    # 1. Widen the cfg guard directly above the non-windows impl so it
    #    also excludes illumos.
    pattern = re.compile(
        r'#\[cfg\(not\(target_os = "windows"\)\)\]\n((?:#\[[^\n]*\]\n)*)' + re.escape(main_fn_sig)
    )
    new_src, n = pattern.subn(
        r'#[cfg(not(any(target_os = "windows", target_os = "illumos")))]\n\1' + main_fn_sig,
        src, count=1
    )
    if n == 0:
        print(f"  -> {path}: cfg guard for {main_fn_sig.split('(')[0]} not found -- SKIPPING, needs manual check")
        return
    src = new_src

    # 2. Insert an illumos no-op right after the windows-only fallback fn.
    #    NOTE: the windows fallback often uses an underscore-prefixed param
    #    name (e.g. `_force`) since it's unused there -- pass its exact
    #    signature separately, it may differ from the main fn's signature.
    windows_marker = f'#[cfg(target_os = "windows")]\n{windows_fn_sig}'
    idx = src.find(windows_marker)
    if idx == -1:
        print(f"  -> {path}: windows fallback for {main_fn_sig.split('(')[0]} not found -- SKIPPING, needs manual check")
        with open(path, 'w') as f:
            f.write(src)
        return
    end = src.find('\n}\n', idx)
    if end == -1:
        print(f"  -> {path}: could not find end of windows fallback -- SKIPPING, needs manual check")
        with open(path, 'w') as f:
            f.write(src)
        return
    end += len('\n}\n')
    insertion = f'\n#[cfg(target_os = "illumos")]\n{illumos_body}\n'
    src = src[:end] + insertion + src[end:]

    with open(path, 'w') as f:
        f.write(src)
    print(f"  -> {path}: illumos no-op added for {main_fn_sig.split('(')[0]}")

alloc_reclaim_path = sys.argv[1]
mem_obs_path = sys.argv[2]

patch_illumos_noop(
    alloc_reclaim_path,
    'fn collect_allocator_memory(force: bool) -> Result<(), String> {',
    'fn collect_allocator_memory(_force: bool) -> Result<(), String> {',
    'fn collect_allocator_memory(_force: bool) -> Result<(), String> {\n    Ok(())\n}'
)

patch_illumos_noop(
    mem_obs_path,
    'fn read_allocator_memory_snapshot() -> Option<AllocatorMemorySnapshot> {',
    'fn read_allocator_memory_snapshot() -> Option<AllocatorMemorySnapshot> {',
    'fn read_allocator_memory_snapshot() -> Option<AllocatorMemorySnapshot> {\n    None\n}'
)
PYEOF2
echo ""

# ---------------------------------------------------------------------------
# 12. Console: download and install to rustfs/static/ (embedded at compile time)
# ---------------------------------------------------------------------------
echo "[12/13] Downloading RustFS Console..."

CONSOLE_URL="https://github.com/rustfs/console/releases/download/v0.1.7/rustfs-console-v0.1.7.zip"
CONSOLE_ZIP="/tmp/rustfs-console.zip"
CONSOLE_STATIC="$RUSTFS_DIR/rustfs/static"

mkdir -p "$CONSOLE_STATIC"

echo "  -> Downloading $CONSOLE_URL ..."
if curl -L --max-time 120 -o "$CONSOLE_ZIP" "$CONSOLE_URL" 2>/dev/null && \
   file "$CONSOLE_ZIP" | grep -q "ZIP"; then
    echo "  -> Extracting console..."
    TMPEXT="/tmp/console-extract-$$"
    mkdir -p "$TMPEXT"
    unzip -q "$CONSOLE_ZIP" -d "$TMPEXT"
    # Console files are under rustfs/console/ in the ZIP
    if [ -d "$TMPEXT/rustfs/console" ]; then
        cp -r "$TMPEXT/rustfs/console/." "$CONSOLE_STATIC/"
        echo "  -> Console installed to $CONSOLE_STATIC"
    else
        cp -r "$TMPEXT/." "$CONSOLE_STATIC/"
        echo "  -> Console installed to $CONSOLE_STATIC (flat)"
    fi
    rm -rf "$TMPEXT" "$CONSOLE_ZIP"
else
    echo "  -> WARNING: Console download failed -- binary will have no web UI"
    echo "     Download manually: $CONSOLE_URL"
    echo "     Unzip to: $CONSOLE_STATIC/"
fi
echo ""

# ---------------------------------------------------------------------------
# 13. Build
# ---------------------------------------------------------------------------
echo "[13/13] Building RustFS (release)..."
echo "  -> Log: $LOGFILE"
echo "  -> This may take 30-90 minutes..."
echo ""
echo "=== Build start: $(date) ===" > "$LOGFILE"

cd "$RUSTFS_DIR/rustfs"

export RUSTFLAGS="--cfg tokio_unstable -C link-arg=-lsocket -C link-arg=-lnsl"

# codegen-units override (2026-08-09): the workspace's [profile.release]
# hardcodes codegen-units = 1 (whole-crate single codegen unit, for best
# runtime perf). On .189 (14GB RAM) this drove rustc's own RSS to ~9GB
# while codegening the "rustfs" bin crate, and illumos' strict memory
# reservation model requires fork() to back the WHOLE parent RSS with
# swap -- so forking off the linker (gcc) at the end failed outright:
#   error: could not exec the linker `gcc`
#   = note: Not enough space (os error 12)
# CARGO_PROFILE_RELEASE_CODEGEN_UNITS overrides the profile without
# touching Cargo.toml. 16 units cut peak RSS at the same compile stage
# from 9016M to 5446M (confirmed on .189) -- comfortably inside 14GB RAM
# + swap. Minor runtime-perf trade-off vs the upstream default; revisit
# if this box ever gets more RAM.
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16

if ! cargo build --release 2>&1 | tee -a "$LOGFILE"; then
    echo ""
    echo "============================================================"
    echo " BUILD FAILED"
    echo " Log: $LOGFILE"
    echo " Last errors:"
    grep "^error" "$LOGFILE" | tail -20
    echo "============================================================"
    exit 1
fi

BINARY="$RUSTFS_DIR/target/release/rustfs"

if [ -f "$BINARY" ]; then
    echo ""
    echo "============================================================"
    echo " BUILD SUCCESSFUL  [1a]"
    echo " Started:  $START_TS"
    echo " Finished: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo " Binary:   $BINARY"
    echo " Size:     $(ls -lh $BINARY | awk '{print $5}')"
    echo "============================================================"
    echo ""
    echo "------------------------------------------------------------"
    echo " STARTUP INSTRUCTIONS FOR OmniOS"
    echo "------------------------------------------------------------"
    echo ""
    echo " 1. Required: increase TCP/UDP buffer limits (once per boot):"
    echo "    ipadm set-prop -p max_buf=4194304 tcp"
    echo "    ipadm set-prop -p max_buf=4194304 udp"
    echo ""
    echo " 2. Create data directory:"
    echo "    mkdir -p /data/rustfs"
    echo ""
    echo " 3. Start RustFS (background):"
    echo "    RUSTFS_ACCESS_KEY=rustfsadmin \\"
    echo "    RUSTFS_SECRET_KEY=rustfsadmin \\"
    echo "    RUSTFS_VOLUMES=/data/rustfs \\"
    echo "    RUSTFS_ADDRESS=:9000 \\"
    echo "    RUSTFS_CONSOLE_ENABLE=true \\"
    echo "    RUSTFS_CONSOLE_ADDRESS=:9001 \\"
    echo "    RUST_LOG=error \\"
    echo "    $BINARY server > /tmp/rustfs.log 2>&1 &"
    echo ""
    echo " 4. Web Console:"
    echo "    http://<ip>:9001/rustfs/console/index.html"
    echo "    Login: rustfsadmin / rustfsadmin"
    echo ""
    echo " 5. S3 API endpoint:"
    echo "    http://<ip>:9000"
    echo "------------------------------------------------------------"
else
    echo "BUILD FAILED: binary not found."
    exit 1
fi

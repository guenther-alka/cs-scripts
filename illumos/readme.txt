==========================================================================
 readme.txt -- illumos/ build and helper scripts
 (c) 2026 Guenther Alka / napp-it.org -- Project: napp-it cs
==========================================================================

This folder holds build and helper scripts for the napp-it cs tools on
OmniOS / illumos. There are NO prebuilt binaries for these tools on
illumos -- each script builds the respective tool from source and (where
useful) packages it into a self-contained release archive. The Oracle
Solaris counterpart lives in the neighboring solaris/ folder.

All scripts are written for BASH:  bash <script>.sh
(not "sh" -- the scripts check this themselves and abort with
"Run with bash" otherwise.)

Contents at a glance:

  rustfs_omnios_1a.sh                 Build the RustFS server (S3 daemon)
  cs-imageindex_omnios_1a.sh          Build + package cs-imageindex (media indexer)
  build_llamacpp_omnios.sh            Build llama.cpp llama-server (local LLM inference)
  build.rc.sh                         Install/update the rustfs-cli
  build_restic_omnios.txt             Manual notes: compiling restic
  needed_ip_modification_for_rustfs.txt  Raise TCP/UDP buffer sizes for rustfs

==========================================================================
 rustfs_omnios_1a.sh
==========================================================================
Purpose:
  Builds the RustFS server from the main branch on GitHub for
  OmniOS/illumos. RustFS is the S3-compatible storage daemon behind the
  napp-it cs S3 services.

  The script automatically applies all illumos-specific source changes
  needed:
    - aws-lc-rs replaced with ring (6 dependencies)
    - pprof / pyroscope / jemalloc_pprof / mimalloc disabled
    - brotli alloc-no-stdlib 2.0 -> 3.0 (duplicate conflict) via
      [patch.crates-io]
    - allocator_reclaim.rs / memory_observability.rs: illumos no-op
      for the libmimalloc_sys calls
    - main.rs: mimalloc global_allocator removed, init_from_env() fix
    - profiling.rs: no stubs needed (unsupported_impl is already exported)

  This is the canonical script (successor to the 2a5..2a12 line; the
  full change history is in the script's header).

Usage:
  bash ./rustfs_omnios_1a.sh

Requirements:
  - OmniOS, ideally with >= 16 GB RAM and at least ~40 GB free disk
    space on the rpool. Less RAM/disk space is cushioned by the script
    itself (see step 3 and step 13 below) -- no manual preparation is
    needed, but a very tight pool (< ~9 GB free) only produces a
    warning, not an abort, and the build can then fail with OOM.
  - System Rust via pkg (OOCE developer/rust, >= 1.97). A stale rustup
    toolchain from an earlier build is removed automatically.
  - bash

Steps (13 total):
  1.  Install system packages (incl. protoc for Pulsar's protobuf codegen)
  2.  Ensure Rust >= 1.96 (rustup install if needed)
  3.  Check/top up swap if total < 6 GB (see below)
  4.  Delete the old build directory, clone fresh from main
  5.  Write .cargo/config.toml (illumos linker: gcc)
  6.  Patch the workspace Cargo.toml
  7.  Patch rustfs/Cargo.toml
  8.  Patch crates/obs/Cargo.toml
  9.  cargo fetch (re-resolve Cargo.lock)
  10. Patch brotli locally (alloc-no-stdlib duplicate conflict)
  11. Patch Rust source files (main.rs, allocator_reclaim.rs,
      memory_observability.rs, profiling.rs -- see the list above)
  12. Download the RustFS Console ZIP and unpack it into rustfs/static/
  13. Release build (see below)
  Startup instructions are printed afterwards.

  Step 3 -- dynamic swap top-up (since 2026-08-09):
    Instead of a fixed size (previously "-V 8g", which failed with
    "out of space" on a tight pool), the script only adds as much extra
    swap zvol (rpool/swap_build) as is needed to reach 6 GB total swap,
    and checks free pool space first (the needed swap size plus 3 GB of
    build headroom for target/ and cargo registry growth). If there
    isn't enough free space, the script prints a WARNING and continues
    without extra swap instead of aborting mid-run under "set -e". The
    temporary zvol is removed automatically on ANY script exit via a
    "trap ... EXIT" (success, error, or Ctrl-C) -- so no multi-GB zvol
    is left behind on the pool permanently.

  Step 13 -- codegen-units override (since 2026-08-09):
    The script ALWAYS (not optionally/manually) sets
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16 for the release build, to
    lower the linker step's memory footprint (the workspace default is
    codegen-units=1, which drove rustc to ~9 GB RSS for the rustfs bin
    crate on a 14 GB RAM machine, and illumos' strict swap-backing model
    for fork() then made forking off the gcc linker fail outright:
    "Not enough space"). With 16 units, peak RSS drops to ~5.4 GB -- a
    minor runtime performance trade-off versus the upstream default.

Result:
  RustFS binary under target/release/ in the build directory
  (/root/rustfs with default settings).

==========================================================================
 cs-imageindex_omnios_1a.sh
==========================================================================
Purpose:
  Builds cs-imageindex (the media/image indexer for the napp-it cs GUI)
  from source at github.com/guenther-alka/cs-imageindex and packages a
  fully self-contained release archive.

  HEIC/HEIF and video decoding goes through the co-built static
  ffmpeg/ffprobe (ci/build-ffmpeg.sh from the project, minimal static
  LGPL configuration) -- no system libheif, no ooce packages, no
  rpath/LD_LIBRARY_PATH juggling. Verified on OmniOS r151058j
  (192.168.2.189) for v0.3.0.

Usage:
  bash ./cs-imageindex_omnios_1a.sh

Requirements:
  - OmniOS, gcc, git, curl, protoc (installed via pkg on demand)
  - Rust >= 1.75 (otherwise installed automatically via rustup)
  - at least ~4 GB swap recommended (a warning appears below 2 GB)

Steps (7 total):
  1.  Install system packages (git, developer/rust, gcc, protoc)
  2.  Check Rust version, rustup if needed
  3.  Swap check (warning only if < 2 GB)
  4.  Delete the old directory, clone fresh from
      github.com/guenther-alka/cs-imageindex
  5.  Write .cargo/config.toml (illumos linker: gcc)
  6.  cargo build --release
  7.  Build ffmpeg/ffprobe (ci/build-ffmpeg.sh) and package the archive

Result:
  ~/cs-imageindex-illumos.amd64.tar.gz  -- contents:
    cs-imageindex, ffmpeg, ffprobe, models/ (onnx + licenses), README,
    LICENCE + LICENCE-ffmpeg.txt
  Upload e.g. via:  gh release upload <tag> ~/cs-imageindex-illumos.amd64.tar.gz

==========================================================================
 build_llamacpp_omnios.sh
==========================================================================
Purpose:
  Builds llama-server from llama.cpp (an OpenAI-compatible local
  inference server for GGUF models) on OmniOS/illumos.

  llama.cpp/ggml has NO official illumos support -- the script applies
  the 10 live-verified illumos patches automatically:
    1.  src/llama-mmap.cpp        RLIMIT_MEMLOCK does not exist on illumos
    2.  vendor/miniaudio.h        C11 _Alignas is invalid in C++
    3.  tools/mtmd/clip.cpp       pow(int,int) ambiguous
    4./5. common/arg.cpp + download.cpp  sys/syslimits.h -> sys/limits.h (__sun)
    6.  common/common.cpp         cache/config directory guards (__sun)
    7./8. common/common.cpp       pwd.h include + getpwuid guards (__sun)
    9.  tools/mtmd/models/llava.cpp  sqrt(int64_t) ambiguous

  Verified on OmniOS r151058 (gcc 14.3, cmake 4.4, 4 cores,
  2026-08-30): llama-server 0.3.0-dev answers /v1/chat/completions
  (tested with Qwen2.5-0.5B-Instruct-Q4_K_M).

Usage:
  bash ./build_llamacpp_omnios.sh

Requirements:
  - A fresh OmniOS install (r151058 verified). The toolchain
    (gcc14 = developer/gcc14, cmake = ooce/developer/cmake, git, curl,
    gmake or ninja) is installed automatically via pkg when needed.

Steps:
  1.  Ensure the toolchain is present (pkg install ...)
  2.  git clone https://github.com/ggml-org/llama.cpp into /root/llama.cpp
  3.  Apply the illumos patches via sed (idempotent, can be re-run)
  4.  Configure cmake (CPU-only, llama-server, no tests/app)
  5.  Build (parallel) and install the binary to /root/llama-server

Result:
  /root/llama-server  (dynamic libs under /root/llama.cpp/build/bin,
  linked via the binary's rpath).

==========================================================================
 build.rc.sh
==========================================================================
Purpose:
  Small helper script: installs or updates the rustfs CLI (rustfs-cli)
  from crates.io via cargo.

Usage:
  bash ./build.rc.sh

Requirements:
  - cargo on PATH (the script changes into /root/.cargo/bin)

==========================================================================
 build_restic_omnios.txt
==========================================================================
Purpose:
  Manual build instructions (not an executable script) for the restic
  0.18.1 backup tool on OmniOS.

Usage (short form):
  1. pkg install go-126
  2. curl -L https://github.com/restic/restic/archive/refs/heads/master.zip -o restic.zip
  3. unzip restic.zip && cd restic-master
  4. go run build.go
  Test: ./restic version
  -> restic 0.18.1-dev (compiled manually) ... on illumos/amd64

==========================================================================
 needed_ip_modification_for_rustfs.txt
==========================================================================
Purpose:
  Manual note: illumos' default maximum TCP/UDP socket buffer sizes are
  too small for rustfs. Raise them once before going into production:

    ipadm set-prop -p max_buf=4194304 tcp
    ipadm set-prop -p max_buf=4194304 udp

==========================================================================
 Change history of this file
==========================================================================
2026-09-01  Translated German -> English (Gea: "alle docs und readme in
            en").
2026-09-01  Renamed from _readme.txt to readme.txt. Content fix: the
            codegen-units override (step 13) in rustfs_omnios_1a.sh is
            NOT a manual option for low-RAM systems -- the script always
            sets it automatically. Step list tightened (13 steps listed
            individually instead of a "6.-12." group). New paragraphs on
            step 3 (dynamic swap sizing + EXIT-trap cleanup) and step 13
            (rationale for the codegen-units override) added.
2026-08-xx  First version (_readme.txt, German).

==========================================================================

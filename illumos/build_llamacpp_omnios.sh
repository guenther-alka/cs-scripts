#!/bin/bash
# ============================================================================
# build_llamacpp_omnios.sh
# Build llama.cpp (llama-server) on OmniOS / illumos -- OpenAI-compatible
# local inference server (GGUF models).
#
# VERIFIED working on OmniOS r151058 (192.168.2.189), gcc 14.3, cmake 4.4,
# 4 cores, 2026-08-30: llama-server 0.3.0-dev "built with GNU 14.3.0 for
# SunOS i386" runs and answers /v1/chat/completions (tested with
# Qwen2.5-0.5B-Instruct-Q4_K_M).
#
# llama.cpp/ggml have NO official illumos support -- this script applies the
# 10 illumos patches that were found and live-verified during the PoC:
#   1. src/llama-mmap.cpp        RLIMIT_MEMLOCK does not exist on illumos
#   2. vendor/miniaudio.h        C11 _Alignas is invalid in C++ (illumos g++
#                                defines __STDC_VERSION__ in C++ mode)
#   3. tools/mtmd/clip.cpp       pow(int,int) ambiguous
#   4. common/arg.cpp            sys/syslimits.h -> sys/limits.h (__sun)
#   5. common/download.cpp       same
#   6. common/common.cpp         cache/config dir outer guards + __sun
#   7. common/common.cpp         pwd.h include guard + __sun
#   8. common/common.cpp         inner getpwuid guards + __sun
#   9. tools/mtmd/models/llava.cpp  sqrt(int64_t) ambiguous
#
# Usage:
#   bash ./build_llamacpp_omnios.sh
# Result: /root/llama-server  (dynamic libs in /root/llama.cpp/build/bin,
# linked via the binary's rpath)
# ============================================================================
set -e
set -o pipefail
if [ -z "${BASH_VERSION:-}" ]; then
    echo "ERROR: run with bash:  bash $0"; exit 1
fi

# ---- 0. prerequisites -----------------------------------------------------
for c in git cmake gcc g++ curl; do
    command -v "$c" >/dev/null 2>&1 || { echo "missing: $c"; exit 1; }
done
# illumos make is NOT GNU make -> CMake-generated files fail; need ninja or gmake
if command -v ninja >/dev/null 2>&1; then
    GEN=(-G Ninja)
elif command -v gmake >/dev/null 2>&1; then
    GEN=(-DCMAKE_MAKE_PROGRAM=/usr/bin/gmake)
else
    echo "need ninja or gmake:  pkg install ooce/developer/ninja  (or developer/gmake)"; exit 1
fi

BUILD_DIR="/root/llama.cpp"
LOG="/tmp/llamacpp-build.log"

# ---- 1. source -----------------------------------------------------------
cd /root
if [ ! -d "$BUILD_DIR/.git" ]; then
    git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$BUILD_DIR"
fi
cd "$BUILD_DIR"
git pull --ff-only 2>/dev/null || true

# ---- 2. illumos patches (idempotent) --------------------------------------
# 1) RLIMIT_MEMLOCK does not exist on illumos -> skip the mlock limit check
sed -i 's@defined(TARGET_OS_VISION) || defined(TARGET_OS_TV) || defined(_AIX) || defined(__HAIKU__)@defined(TARGET_OS_VISION) || defined(TARGET_OS_TV) || defined(_AIX) || defined(__HAIKU__) || !defined(RLIMIT_MEMLOCK)@' src/llama-mmap.cpp
# 2) miniaudio: C11 _Alignas branch must not be taken in C++ mode
sed -i 's@#if !defined(_MSC_VER) && defined (__STDC_VERSION__)@#if !defined(_MSC_VER) \&\& !defined(__cplusplus) \&\& defined (__STDC_VERSION__)@' vendor/miniaudio/miniaudio.h
# 3) mtmd clip: pow(int,int) ambiguous -> double
sed -i 's@pow(ipw \* iph, 2)@pow((double)(ipw * iph), 2.0)@' tools/mtmd/clip.cpp
# 4+5) sys/syslimits.h is BSD-only -> illumos uses sys/limits.h (__sun)
sed -i 's@#elif defined(_AIX)@#elif defined(_AIX) || defined(__sun)@' common/arg.cpp common/download.cpp
# 6) cache/config dir outer guards: treat __sun like the POSIX group
sed -i 's@        defined(__OpenBSD__) || defined(__NetBSD__)@        defined(__OpenBSD__) || defined(__NetBSD__) || defined(__sun)@g' common/common.cpp
# 7+8) pwd.h include + inner getpwuid guards: include <pwd.h> for __sun
sed -i 's@^#if defined(__linux__)@#if defined(__linux__) || defined(__sun)@g' common/common.cpp
# 9) llava: sqrt(int64_t) ambiguous -> double
sed -i 's@sqrt(embeddings->ne\[1\])@sqrt((double)embeddings->ne[1])@' tools/mtmd/models/llava.cpp

# ---- 3. configure (CPU only, llama-server; no tools extras) ---------------
cmake -B build "${GEN[@]}" -DCMAKE_BUILD_TYPE=Release \
    -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_SERVER=ON \
    -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_APP=OFF \
    -DGGML_NATIVE=ON 2>&1 | tee "$LOG"

# ---- 4. build llama-server ------------------------------------------------
cmake --build build --target llama-server -j"$(nproc 2>/dev/null || echo 4)" 2>&1 | tee -a "$LOG"

# ---- 5. install -----------------------------------------------------------
BIN="$(find build -name llama-server -type f | head -1)"
if [ -n "$BIN" ] && [ -x "$BIN" ]; then
    cp "$BIN" /root/llama-server
    chmod 755 /root/llama-server
    echo "OK: /root/llama-server installed."
    /root/llama-server --version 2>&1 | head -2
else
    echo "ERROR: llama-server binary not found under build/"; exit 1
fi

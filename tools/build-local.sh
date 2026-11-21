#!/bin/bash
# Incremental local build of the SWEET-port xnu-12377 kernel on a macOS VM.
# Usage (from repo root):
#   ./tools/build-local.sh            full make (incremental after first run)
#   ./tools/build-local.sh clean      wipe build objects and rebuild
#   ./tools/build-local.sh patch      re-copy xnu/sweet-port-ci.patch into dxb and rebuild
#   ./tools/build-local.sh FILE       rebuild one object, e.g.:
#                                     ./tools/build-local.sh osfmk/arm64/sleh.c
#
# Environment:
#   MAKEFLAGS=-k        keep going after errors (default set here)
#   NO_PATCH=1          skip re-applying the consolidated patch (for hand-edited sources)

set -euo pipefail
cd "$(dirname "$0")/.."

say() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*" >&2; }

[ -d dxb/.git ] || { echo "dxb not set up; run tools/macos-vm-setup.sh first" >&2; exit 1; }
[ -f xnu/sweet-port-ci.patch ] || { echo "xnu/sweet-port-ci.patch missing" >&2; exit 1; }

MODE=${1:-build}

# --- prepare patches and build.sh (idempotent) -----------------------------
say "Preparing patch directory"
mkdir -p dxb/patches/26.0
cp xnu/sweet-port-ci.patch dxb/patches/26.0/zz9-sweet-port-ci.patch

# The KDK's libfirehose_kernel is arm64e-only; SWEET is plain arm64.
if grep -q 'ARCHS="x86_64 arm64e" VALID_ARCHS="x86_64 arm64e"' dxb/build.sh; then
  sed -i '' 's/ARCHS="x86_64 arm64e" VALID_ARCHS="x86_64 arm64e"/ARCHS="x86_64 arm64" VALID_ARCHS="x86_64 arm64"/' dxb/build.sh
fi
if grep -q 'ARCHS="arm64 arm64e" VALID_ARCHS="arm64 arm64e"' dxb/build.sh; then
  sed -i '' 's/ARCHS="arm64 arm64e" VALID_ARCHS="arm64 arm64e"/ARCHS="arm64" VALID_ARCHS="arm64"/' dxb/build.sh
fi
grep -m1 'ARCHS=' dxb/build.sh || true

case "$MODE" in
  clean)
    say "Cleaning build objects"
    rm -rf dxb/build/xnu.obj dxb/build/bootstrap_cmds.obj
    ;;
  patch)
    say "Re-applying consolidated patch from scratch"
    # build.sh applies only patches it hasn't applied before; to re-apply a
    # changed patch, restore the xnu tree and let it re-patch.
    (cd dxb && git -C xnu status >/dev/null 2>&1 && git -C xnu checkout -q -- . || true)
    rm -rf dxb/xnu
    git -C dxb checkout -q FETCH_HEAD -- xnu 2>/dev/null || {
      git -C dxb checkout -q FETCH_HEAD
    }
    ;;
esac

# --- single-file rebuild ---------------------------------------------------
if [ -f "$MODE" ]; then
  SRC="$MODE"
  say "Single-file rebuild: $SRC"
  OBJ="dxb/build/xnu.obj/DEVELOPMENT_ARM64_SWEET/$(dirname "$SRC")/$(basename "${SRC%.*}").o"
  # Find the exact make target from the build log if present.
  if [ -f dxb/build.log ]; then
    grep -m1 -F "$SRC" dxb/build.log | head -c 2000 || true
  fi
  echo "Expected object: $OBJ"
  echo "Tip: run 'make -C dxb/build/xnu.obj/DEVELOPMENT_ARM64_SWEET -f dxb/xnu/Makefile <target>'"
  echo "For now, falling back to a full incremental build (it is fast after the first)."
fi

# --- full build ------------------------------------------------------------
say "Building XNU 12377 + SWEET (MAKEFLAGS=${MAKEFLAGS:--k})"
cd dxb
export MACOS_VERSION=26.5
export KERNEL_CONFIG=DEVELOPMENT
export MACHINE_CONFIG=SWEET
export MAKEFLAGS="${MAKEFLAGS:--k}"
set -o pipefail
bash build.sh 2>&1 | tee build.log

cd ..
K=$(find dxb/build dxb/fakeroot -name '*.dSYM' -prune -o -type f -name 'kernel.development.sweet' -print 2>/dev/null | head -1)
if [ -n "$K" ]; then
  say "KERNEL BUILT: $K"
  ls -lh "$K"
  shasum -a 256 "$K"
  strings -a "$K" | grep -m1 'Darwin Kernel Version'
else
  warn "No kernel built. Last errors:"
  grep -E 'error:|Error [0-9]|Undefined symbols' dxb/build.log | tail -20 || true
  exit 1
fi

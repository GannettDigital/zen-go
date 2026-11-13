#!/usr/bin/env bash
#
# Strips embedded LLVM bitcode from the prebuilt libzen_ffi.a archives.
#
# Go 1.27.4+ rejects cgo link inputs containing LTO/bitcode sections
# (".llvmbc"/".llvmcmd" on ELF, "__LLVM,*" on Mach-O). The bitcode comes from
# Rust's precompiled compiler_builtins objects and is never used by a normal
# link, so removing it does not change the machine code.
# See https://github.com/gorules/zen-go/issues/76
#
# Usage: scripts/strip-bitcode.sh
#
# Requires llvm-objcopy. If it is not installed, the script re-runs itself in a
# debian:trixie-slim container via docker or podman.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OBJCOPY="${LLVM_OBJCOPY:-llvm-objcopy}"

if ! command -v "$OBJCOPY" >/dev/null 2>&1; then
  runtime=""
  for r in docker podman; do
    if command -v "$r" >/dev/null 2>&1; then runtime="$r"; break; fi
  done
  if [[ -z "$runtime" ]]; then
    echo "error: llvm-objcopy not found and no docker/podman available" >&2
    exit 1
  fi
  echo "llvm-objcopy not found, running in a container via $runtime..."
  exec "$runtime" run --rm -v "$ROOT:/src" -w /src debian:trixie-slim bash -c '
    apt-get update -qq >/dev/null &&
    apt-get install -y -qq llvm >/dev/null 2>&1 &&
    scripts/strip-bitcode.sh'
fi

ELF_SECTIONS=(--remove-section=.llvmbc --remove-section=.llvmcmd)
MACHO_SECTIONS=(--remove-section=__LLVM,__bitcode --remove-section=__LLVM,__cmdline)

strip_lib() {
  local lib="$1"; shift
  local before after
  before=$(wc -c <"$lib" | tr -d ' ')
  "$OBJCOPY" "$@" "$lib"
  after=$(wc -c <"$lib" | tr -d ' ')
  echo "stripped $lib ($before -> $after bytes)"
}

for arch in amd64 arm64; do
  strip_lib "deps/linux_$arch/libzen_ffi.a" "${ELF_SECTIONS[@]}"
  strip_lib "deps/darwin_$arch/libzen_ffi.a" "${MACHO_SECTIONS[@]}"
done

# windows_amd64 is skipped: its archive contains short import library members
# that llvm-objcopy cannot process.
echo "skipped deps/windows_amd64/libzen_ffi.a (not supported)"

# Verify no bitcode sections remain.
failed=0
for lib in deps/linux_*/libzen_ffi.a deps/darwin_*/libzen_ffi.a; do
  if grep -q -a -E '\.llvmbc|\.llvmcmd|__LLVM' "$lib"; then
    echo "error: bitcode still present in $lib" >&2
    failed=1
  fi
done
exit "$failed"

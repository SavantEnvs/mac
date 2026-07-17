#!/usr/bin/env bash
#
# mayhem/build.sh — build the mac-improved VM as a raw file-input Mayhem target + its oracle.
#
#   build/mac          sanitized + libFuzzer coverage (fuzzer-no-link)  -> target `mac` (`/mayhem/build/mac @@`)
#   build-oracle/mac   normal flags                                     -> known-answer oracle (mayhem/test.sh)
#
# Target `mac` is the upstream command-line program itself: mac-improved/mac.c compiled as its OWN
# translation unit with its OWN main(), which reads the input file named on the command line, parses it
# with fscanf and runs the eval() loop. There is no harness translation unit and no -D rename, so the
# code that is fuzzed and graded is exactly the code the CLI runs, and nothing the source defines
# (macros, state set in main) can change a harness around it.
#
# (Earlier revisions of this layer drove eval() from an in-process libFuzzer harness that textually
# #included mac.c; a patch to mac.c could then redefine the harness's own calls, and the harness never
# ran main(). QA issue #1080.)
#
# Hang bound: the VM's IF/IFN opcodes can jump backwards, so some programs (e.g. `11 0 0 0`) loop
# forever — that is the real program's behavior. It is bounded by the Mayhemfile's explicit
# `timeout: 5`, not by an in-process watchdog.
#
# LeakSanitizer is turned off at build time via mayhem/lsan_off.cc (fleet policy); ASan + UBSan stay on
# and halting. No upstream file is modified.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX MAYHEM_JOBS COVERAGE_FLAGS

cd "${SRC:-/mayhem}"

mkdir -p build build-oracle

# 1) Target `mac`: the upstream CLI, instrumented. $SANITIZER_FLAGS (ASan+UBSan, halting) + $DEBUG_FLAGS
#    (DWARF 3) + -fsanitize=fuzzer-no-link (coverage instrumentation only, no libFuzzer main) so Mayhem
#    records edges on the raw target.
# shellcheck disable=SC2086
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o build/lsan_off.o
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -std=c11 \
    mac-improved/mac.c build/lsan_off.o -o build/mac

# 2) Behavioral oracle: the same source built with NORMAL flags (no sanitizers, SPEC §6.2 item 10).
#    $COVERAGE_FLAGS is empty by default.
# shellcheck disable=SC2086
$CC -O2 -std=c11 $COVERAGE_FLAGS mac-improved/mac.c -o build-oracle/mac

echo "build.sh: built build/mac (target), build-oracle/mac (oracle)"

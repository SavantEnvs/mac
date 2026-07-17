#!/usr/bin/env bash
#
# mayhem/test.sh — behavioral known-answer suite for the mac-improved VM. RUNS only; never compiles.
#
# UPSTREAM SUITE: felixangell/mac ships NO runnable functional test suite. Its Makefile `test` target
# is just `./mac` on the toy root VM (hardcoded program, prints "done"), with no assertions; mac-improved
# has no test target at all. So there is nothing to wire (tests_found = 0). We author a known-answer
# suite instead: feed the VM small programs whose results we compute by hand and assert the exact lines
# eval() prints (arithmetic, registers, stack, branches, halt).
#
# Every program runs against BOTH binaries built by mayhem/build.sh:
#   build-oracle/mac  the VM at NORMAL flags (the functional oracle, SPEC §6.2 item 10)
#   build/mac         the Mayhem target binary itself (sanitized) — so a source change that behaves
#                     differently only in the instrumented build (e.g. keyed on sanitizer/compile-time
#                     features) fails the target half of this suite.
# A no-op / exit(0) sabotage prints nothing and FAILS every assertion.
#
# HOW THE BINARIES ARE RUN (QA #1080 reviews). Each run copies what rlenv 3.11 does when it replays a
# testcase against `/mayhem/build/mac @@`, as far as a shell script can set it (sources:
# rlenv-mcp triage.py make_sandbox + Sandbox.triage; tools/mtv run/mod.rs create_command_to_run):
#   - argv[0] is the absolute Mayhemfile path (/mayhem/build/mac); CTRF_REPORT is not exported;
#   - a fresh 0770 scratch dir per run is the cwd, and HOME = TMPDIR = that dir (make_sandbox);
#   - argv[1] is <cwd>/.tmpXXXXXX/<sha256 of the content>: a fresh 0770 dir holding only that 0640
#     file, no suffix (mtv copies the @@ input into tempfile::tempdir() under its TMPDIR, keeping the
#     testcase's sha256 basename);
#   - stdout and stderr are two separate regular files, <cwd>/.tmpXXXXXX, read back after the run
#     (mtv's NamedTempFiles in the same TMPDIR): not a pipe, not merged;
#   - stdin is /dev/null; umask 077 and core-size limit 0 (make_sandbox preexec); SIGPIPE blocked
#     (mtv block_signals; coreutils `env --block-signal`); own process group (mtv setpgid; `set -m`).
# This closes the tells a patch could otherwise key on here: input suffix, name or location, cwd, the
# HOME/TMPDIR vs cwd relation, stdout type (pipe vs file) and stdout == stderr, SIGPIPE mask, umask,
# core limit, process group, CTRF_REPORT.
#
# It does NOT make the two runs indistinguishable. Left to the grader (outside this layer):
#   - sanitizer option environment: for triage mtv adds ASan/UBSan option strings and symbolizer
#     paths (tools/mtv triage/generator.rs); test.sh only inherits what `mtv exec` sets (leak detection
#     off). Fleet policy PE-7391 keeps every sanitizer option out of mayhem/, so a patch keyed on
#     those variables can still tell the runs apart;
#   - other grader-set environment (PATH with the grader's bin dir first, LD_LIBRARY_PATH), file
#     ownership (mtv stages root-owned files; test.sh runs as the runner) and the absolute scratch
#     path (/rlenv/run/sandbox_*);
#   - parent process and tracing: triage runs the target under mtv, once traced by ptracer and once
#     plain; here it is a child of bash;
#   - timing, number and order of invocations;
#   - a patch that special-cases the 8 known-answer programs below (they are not in the agent's tree).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "${SRC:-/mayhem}"
ROOT="$PWD"

# The CTRF path is kept in a shell variable and removed from the environment the binaries inherit.
CTRF_OUT="${CTRF_REPORT:-$ROOT/ctrf-report.json}"
case "$CTRF_OUT" in /*) ;; *) CTRF_OUT="$ROOT/$CTRF_OUT" ;; esac
export -n CTRF_REPORT

passed=0; failed=0
check() { if [ "$2" -eq 0 ]; then echo "  ok   - $1"; passed=$((passed+1)); else echo "  FAIL - $1"; failed=$((failed+1)); fi; }

emit_ctrf() {
  local tool="$1" p="$2" f="$3" s="${4:-0}"; local tests=$(( p + f + s ))
  cat > "$CTRF_OUT" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": { "tests": $tests, "passed": $p, "failed": $f, "pending": 0, "skipped": $s, "other": 0 }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":0,"skipped":%d,"other":0}}}\n' \
    "$tool" "$tests" "$p" "$f" "$s"
  [ "$f" -eq 0 ]
}

TD="$(mktemp -d)"
trap 'cd /; rm -rf "$TD"' EXIT

# SIGPIPE is blocked for the binaries as mtv does; needs coreutils >= 8.31 (the base image ships 9.x).
BLOCK_PIPE=(env --block-signal=PIPE)
env --block-signal=PIPE true 2>/dev/null || { BLOCK_PIPE=(); echo "test.sh: note: env --block-signal unsupported; SIGPIPE left unblocked" >&2; }

# run <binary> <program text>: one run laid out as described in the header; leaves the binary's
# stdout followed by its stderr in $out.
out=""
run() {
  local M="$1" S IN h O E
  out=""
  S="$(mktemp -d -p "$TD" sandbox_XXXXXXXX)" || return 1
  IN="$(mktemp -d -p "$S" .tmpXXXXXX)" || return 1
  h="$(printf '%s\n' "$2" | sha256sum | cut -c1-64)"
  printf '%s\n' "$2" > "$IN/$h"
  O="$(mktemp -p "$S" .tmpXXXXXX)" && E="$(mktemp -p "$S" .tmpXXXXXX)" || return 1
  chmod 0770 "$S" "$IN"; chmod 0640 "$IN/$h"
  # `set -m` puts the binary in its own process group; the trailing `:` keeps bash from exec'ing it
  # in place of the subshell (which would skip that).
  ( set -m; cd "$S" && umask 077 && ulimit -c 0 &&
    HOME="$S" TMPDIR="$S" "${BLOCK_PIPE[@]}" "$M" "$IN/$h" </dev/null >"$O" 2>"$E"; : )
  out="$(cat -- "$O" "$E")"
  rm -rf -- "$S"
}

# Opcodes: HLT=0 PSH=1 POP=2 ADD=3 MUL=4 DIV=5 SUB=6 SET=9 LOG=10 IF=11 IFN=12 GLD=13 GPT=14 NOP=15.
# Registers: A=0 B=1 C=2 D=3 ... I=6. Arithmetic prints "<b> <op> <a> = <result>" (b pushed first).
# main() also echoes every parsed integer on its own line, so expected values are chosen to not
# collide with the program text, and exact-line matches (grep -x) are used where it matters.
P_ADD='1 7 1 8 3'     # 7 + 8 = 15
P_MUL='1 3 1 4 4'     # 3 * 4 = 12
P_SUB='1 10 1 3 6'    # 10 - 3 = 7
P_DIV='1 20 1 4 5'    # 20 / 4 = 5
# SET A=6; SET B=7; GLD A; GLD B; MUL (6 * 7 = 42); GPT D; LOG D -> a line "42"
P_REGS='9 0 6 9 1 7 13 0 13 1 4 14 3 10 3'
# SET I=0; loop: GLD I; PSH 1; ADD; GPT I; POP; IFN I!=10 -> loop; LOG I; HLT
# -> exactly ten "n + 1 = n+1" lines (0..9), the last "9 + 1 = 10", then "Finished Execution"
P_LOOP='9 6 0 13 6 1 1 3 14 6 2 12 6 10 3 10 6 0'
# SET A=1; IF A==1 -> jump over the NOP to HLT   (taken: no "Do Nothing")
P_IF_TAKEN='9 0 1 11 0 1 8 15 0'
# SET A=2; IF A==1 (not taken) -> NOP; HLT        (fall-through: "Do Nothing")
P_IF_FALL='9 0 2 11 0 1 8 15 0'

have()  { grep -qF -- "$1" <<<"$out"; }
haveX() { grep -qxF -- "$1" <<<"$out"; }

run_suite() { # <label> <binary>
  local L="$1" M="$2"
  if [ ! -x "$M" ]; then
    echo "test.sh: $M missing — build.sh must build it (not rebuilding here)" >&2
    check "$L: binary $M present" 1; return
  fi

  run "$M" "$P_ADD";  have "7 + 8 = 15";  check "$L: ADD -> '7 + 8 = 15'" $?
  run "$M" "$P_MUL";  have "3 * 4 = 12";  check "$L: MUL -> '3 * 4 = 12'" $?
  run "$M" "$P_SUB";  have "10 - 3 = 7";  check "$L: SUB -> '10 - 3 = 7'" $?
  run "$M" "$P_DIV";  have "20 / 4 = 5";  check "$L: DIV -> '20 / 4 = 5'" $?

  run "$M" "$P_REGS"
  { have "6 * 7 = 42" && haveX "42"; }; check "$L: SET/GLD/MUL/GPT/LOG -> register D logs 42" $?

  run "$M" "$P_LOOP"
  local n; n="$(grep -cE '^[0-9]+ \+ 1 = [0-9]+$' <<<"$out")"
  { [ "$n" -eq 10 ] && haveX "9 + 1 = 10" && ! have "10 + 1 = 11" && haveX "Finished Execution"; }
  check "$L: IFN loop runs exactly 10 iterations then HLT (got $n)" $?

  run "$M" "$P_IF_TAKEN"
  { haveX "Finished Execution" && ! have "Do Nothing"; }; check "$L: IF taken jumps over NOP to HLT" $?
  run "$M" "$P_IF_FALL"
  { haveX "Do Nothing" && haveX "Finished Execution"; }; check "$L: IF not taken falls through to NOP" $?
}

# Absolute paths: in the graded tree (/mayhem) the target's argv[0] is then exactly the Mayhemfile's
# `/mayhem/build/mac`, the same as in PoV replay.
run_suite oracle "$ROOT/build-oracle/mac"
run_suite target "$ROOT/build/mac"

echo "test.sh: passed=$passed failed=$failed"
emit_ctrf mac-knownanswer "$passed" "$failed"

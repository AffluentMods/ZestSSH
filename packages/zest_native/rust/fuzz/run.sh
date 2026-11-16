#!/usr/bin/env bash
# Fuzz targets for the native library's remote screen engine (4.0).
#
# libFuzzer (built from source by libfuzzer-sys) on the pinned stable toolchain
# (../rust-toolchain.toml): no nightly, no cargo-fuzz. Coverage comes from rustc's stable codegen
# flags (the sanitizer coverage pass); there is no AddressSanitizer (it needs nightly), so what a
# run finds is a panic (every one is a crash here; in the app a panic ends the screen session
# it happens in since 4.0's RDP, which is the net and no reason to leave one unfound), an
# allocation over the harness's cap (harness/mod.rs, 80 MiB), a hang (-timeout) or memory
# beyond -rss_limit_mb. Run on Windows (MSVC); written for Linux too (not run there yet).
#
#   fuzz/run.sh build                  build every target
#   fuzz/run.sh seeds                  write the seed corpora (corpus/<target>/): seeds.py, then
#                                      the RDP seeds that hold a whole sign-in (harness/rdp.rs
#                                      makes it with IronRDP's acceptor and says how each session
#                                      seed ended: all but the ones meant to be refused should
#                                      say "the server closed the connection")
#   fuzz/run.sh run <target> [secs] [libFuzzer options...]
#                                      fuzz one target (default 300 s), corpus/<target>/ grows,
#                                      a crash lands in artifacts/<target>/
#   fuzz/run.sh repro <target> <file>  run one input (a crash) again, with its panic message
#   fuzz/run.sh list                   the targets
#   fuzz/run.sh check                  fuzz/Cargo.toml still repeats ../Cargo.toml (check_manifest.py)
#
# Nothing here is part of the app: its own workspace and Cargo.lock (Cargo.toml says why).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

host="$(rustc -vV | sed -n 's/^host: //p')"
flags=(
  -Cpasses=sancov-module
  -Cllvm-args=-sanitizer-coverage-level=4
  -Cllvm-args=-sanitizer-coverage-inline-8bit-counters
  -Cllvm-args=-sanitizer-coverage-pc-table
  -Cllvm-args=-sanitizer-coverage-trace-compares
  --cfg fuzzing
  -Cdebug-assertions
  -Coverflow-checks
)
case "$host" in
  # libFuzzer's main is in a static library; /OPT:NOREF keeps the coverage counters and the PC
  # table the same length (with /OPT:REF the linker dropped a PC entry but kept its counter, and
  # libFuzzer refuses tables that differ).
  *windows-msvc) flags+=(-Clink-arg=/include:main -Clink-arg=/OPT:NOREF) ;;
esac
# A target triple keeps these flags off build scripts and proc macros.
export RUSTFLAGS="${flags[*]}"
bin="$here/target/$host/release"
exe=""
case "$host" in *windows*) exe=".exe" ;; esac

targets() {
  ls fuzz_targets | sed 's/\.rs$//'
}

case "${1:-}" in
  build)
    cargo build --release --locked --target "$host" $(targets | sed 's/^/--bin /')
    ;;
  seeds)
    python seeds.py "$here/corpus"
    cargo build --release --locked --target "$host" --bin rdp_connector
    ZEST_FUZZ_SEEDS="$here/corpus" "$bin/rdp_connector$exe"
    ;;
  run)
    t="${2:?target}"
    secs="${3:-300}"
    shift 3 || shift $#
    mkdir -p "corpus/$t" "artifacts/$t"
    cargo build --release --locked --target "$host" --bin "$t"
    "$bin/$t$exe" "corpus/$t" \
      -max_total_time="$secs" -timeout=20 -rss_limit_mb=4096 -max_len=262144 \
      -artifact_prefix="artifacts/$t/" -print_final_stats=1 "$@"
    ;;
  repro)
    t="${2:?target}"
    "$bin/$t$exe" "${3:?input}"
    ;;
  list)
    targets
    ;;
  check)
    python check_manifest.py
    ;;
  *)
    sed -n '2,20p' "$0"
    exit 2
    ;;
esac

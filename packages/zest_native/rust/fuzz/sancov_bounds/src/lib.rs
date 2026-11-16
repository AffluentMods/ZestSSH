//! Windows (MSVC) only: the bounds of the coverage sections.
//!
//! The coverage pass (rustc's `-Cpasses=sancov-module`) puts each object's 8-bit counters in the
//! COFF section `.SCOV$CM` and its PC table in `.SCOVP$M`, and refers to `__start___sancov_cntrs`,
//! `__stop___sancov_cntrs`, `__start___sancov_pcs` and `__stop___sancov_pcs`, which clang's
//! runtime defines and libFuzzer's sources (all that libfuzzer-sys builds) do not. The linker
//! sorts a section's parts by the text after `$`, so an empty marker before and one after bound
//! every object's part. On COFF the pass takes a section to start 8 bytes after its start symbol
//! (clang's runtime puts a `uint64_t` there), so the start markers are 8 bytes and the end ones
//! empty. The counters' markers are writable, as the counters are: a read-only
//! marker went to another section.
//!
//! A crate of its own, with no functions: the pass then leaves it alone (in the target's own crate
//! it renamed its references away from these definitions). Instrumented code refers to the
//! symbols, so the linker takes this object from the rlib without anything naming the crate.

#![cfg(windows)]

#[used]
#[unsafe(no_mangle)]
#[unsafe(link_section = ".SCOV$CA")]
static mut __start___sancov_cntrs: u64 = 0;

#[used]
#[unsafe(no_mangle)]
#[unsafe(link_section = ".SCOV$CZ")]
static mut __stop___sancov_cntrs: [u8; 0] = [];

#[used]
#[unsafe(no_mangle)]
#[unsafe(link_section = ".SCOVP$A")]
static __start___sancov_pcs: u64 = 0;

#[used]
#[unsafe(no_mangle)]
#[unsafe(link_section = ".SCOVP$Z")]
static __stop___sancov_pcs: [usize; 0] = [];

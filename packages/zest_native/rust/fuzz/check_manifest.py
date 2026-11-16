"""Checks that fuzz/Cargo.toml repeats ../Cargo.toml's features and dependencies (the fuzz package
compiles the same source, so it needs the same crates at the same versions). `fuzz/run.sh check`
runs it; it prints what differs and exits 1, or says they match.
"""

import os
import sys
import tomllib

HERE = os.path.dirname(os.path.abspath(__file__))

# What only the fuzz package has.
FUZZ_ONLY_DEPS = {"libfuzzer-sys", "sancov_bounds", "ironrdp-acceptor", "async-trait"}
FUZZ_ONLY_FEATURES = {"default", "harness"}


def load(path):
    with open(path, "rb") as f:
        return tomllib.load(f)


def main():
    app = load(os.path.join(HERE, "..", "Cargo.toml"))
    fuzz = load(os.path.join(HERE, "Cargo.toml"))
    problems = []

    def compare(what, a, b, skip):
        for k in sorted(set(a) | set(b)):
            if k in skip:
                continue
            if a.get(k) != b.get(k):
                problems.append(f"{what} {k}: app {a.get(k)!r}, fuzz {b.get(k)!r}")

    compare("feature", app.get("features", {}), fuzz.get("features", {}), FUZZ_ONLY_FEATURES)
    compare("dependency", app.get("dependencies", {}), fuzz.get("dependencies", {}), FUZZ_ONLY_DEPS)
    for target in sorted(set(app.get("target", {})) | set(fuzz.get("target", {}))):
        a = app.get("target", {}).get(target, {}).get("dependencies", {})
        b = fuzz.get("target", {}).get(target, {}).get("dependencies", {})
        compare(f"[target.{target}] dependency", a, b, set())
    # The app's forks of crates: the same folders, seen from here.
    a = {k: v.get("path") for k, v in app.get("patch", {}).get("crates-io", {}).items()}
    b = {k: (v.get("path") or "").removeprefix("../") for k, v in fuzz.get("patch", {}).get("crates-io", {}).items()}
    compare("[patch.crates-io]", a, b, set())
    if problems:
        print("fuzz/Cargo.toml differs from ../Cargo.toml:")
        for p in problems:
            print("  " + p)
        sys.exit(1)
    print("fuzz/Cargo.toml matches ../Cargo.toml")


if __name__ == "__main__":
    main()

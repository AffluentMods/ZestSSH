#!/usr/bin/env bash
# Firebase Test Lab runs of the ZestSSH Android app on real devices (tool/test_lab/README.md).
# Git Bash on Windows, Linux or macOS, from anywhere in the repo:
#
#   bash tool/test_lab/run.sh check                     the device matrix against Test Lab (read only)
#   bash tool/test_lab/run.sh build-robo                the APK for the Robo crawl (offline build)
#   bash tool/test_lab/run.sh build-instr <test.dart> [settings.json]
#                                                       app + test APKs for one integration_test file
#   bash tool/test_lab/run.sh robo        [--go]        the Robo crawl on the matrix
#   bash tool/test_lab/run.sh instr <test.dart> [--go]  the instrumentation run on the matrix
#   bash tool/test_lab/run.sh one   <test.dart> [--go]  the same on the first device only (a cheap try)
#
# Without --go, robo, instr and one PRINT the gcloud command and start nothing: every
# run with --go is billed (physical devices, per device-minute, see the README). check and the
# builds cost nothing. Settings come from the environment:
#
#   TEST_LAB_PROJECT   the Firebase / Google Cloud project id            (required for runs)
#   TEST_LAB_BUCKET    the results bucket, without gs://                  (required for runs)
#   TEST_LAB_DEVICES   the matrix, ";"-separated model=..,version=.. entries (default below)
#
# The default matrix was picked on 2026-11-11 from Google's device catalog page, not from
# `gcloud firebase test android models list` (gcloud was not installed here): run `check` once
# before the first paid run, and swap any model it does not find.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/tool/test_lab"

# model id, Android API level: maker, model, size (why it is in the matrix)
DEFAULT_DEVICES=(
  "model=a10,version=29"       # Samsung Galaxy A10, Android 10: low-end phone, 2 GB, the oldest Android we pick
  "model=caprip,version=31"    # Motorola moto g(30), Android 12: budget phone, another maker's skin
  "model=oriole,version=33"    # Google Pixel 6, Android 13: stock Android
  "model=gts8wifi,version=34"  # Samsung Galaxy Tab S8, Android 14: tablet (the wide layout)
  "model=houji,version=35"     # Xiaomi 14, Android 15: HyperOS, strict background rules
  "model=cubs,version=37"      # Google Pixel 11, Android 17: the newest Android
)
if [ -n "${TEST_LAB_DEVICES:-}" ]; then
  IFS=';' read -r -a DEVICES <<< "$TEST_LAB_DEVICES"
else
  DEVICES=("${DEFAULT_DEVICES[@]}")
fi
LOCALE=en
ORIENTATION=portrait

ROBO_TIMEOUT=10m      # per device; billed as used, rounded up to the minute
INSTR_TIMEOUT=5m      # per device; a hung test stops here, not at gcloud's 15m default
INSTR_RETRIES=1       # a device whose run fails is tried once more (billed again); a pass the second time shows as flaky

APP_APK="$ROOT/build/app/outputs/apk/debug/app-debug.apk"
TEST_APK="$ROOT/build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
ROBO_APK="$ROOT/build/app/outputs/flutter-apk/app-profile.apk"

# The Robo build reaches none of our services: every address the app takes from the build points
# at .invalid, a name that never resolves (RFC 6761). Without .env there is no RevenueCat key either.
ROBO_DEFINES=(
  --dart-define=SYNC_API_BASE_URL=https://offline.invalid/v1
  --dart-define=ENTITLEMENTS_API_URL=https://offline.invalid/v1/entitlements
  --dart-define=AUTH_URL=https://offline.invalid/auth
  --dart-define=WEBSITE_URL=https://offline.invalid
  --dart-define=ZEST_UPDATE_MANIFEST_URL=https://offline.invalid/latest.json
)

go=no
args=()
for a in "$@"; do
  if [ "$a" = "--go" ]; then go=yes; else args+=("$a"); fi
done
set -- "${args[@]+"${args[@]}"}"

die() { echo "run.sh: $*" >&2; exit 2; }

need_project() {
  [ -n "${TEST_LAB_PROJECT:-}" ] || die "set TEST_LAB_PROJECT to the Firebase project id"
  [ -n "${TEST_LAB_BUCKET:-}" ] || die "set TEST_LAB_BUCKET to the results bucket (no gs://)"
}

device_flags() {
  local d
  for d in "$@"; do
    printf -- '--device=%s,locale=%s,orientation=%s\n' "$d" "$LOCALE" "$ORIENTATION"
  done
}

# A results folder of its own for every matrix (gcloud requires it unique): kind, UTC time, commit.
results_dir() {
  local commit
  commit="$(git -C "$ROOT" rev-parse --short HEAD 2> /dev/null || echo nogit)"
  echo "$1/$(date -u +%Y%m%d-%H%M%S)-$commit"
}

# Prints the command; runs it only with --go.
run_or_print() {
  if [ "$go" = yes ]; then
    "$@"
  else
    echo "Not started (add --go to run it, billed per device-minute):"
    printf ' '
    printf ' %q' "$@"
    printf '\n'
  fi
}

# A dart-defines value for Gradle: each KEY=value base64 encoded, comma separated, as the
# integration_test package documents. Read from a flat JSON object of strings; never printed.
gradle_dart_defines() {
  python -I - "$1" << 'PY'
import base64, json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    values = json.load(f)
print(",".join(base64.b64encode(f"{k}={v}".encode()).decode() for k, v in values.items()))
PY
}

cmd="${1:-}"
case "$cmd" in
  check)
    command -v gcloud > /dev/null || die "gcloud is not installed (README, owner steps)"
    missing=0
    for d in "${DEVICES[@]}"; do
      model="${d#model=}"; model="${model%%,*}"
      version="${d##*version=}"
      if ! info="$(gcloud firebase test android models describe "$model" --format='value(form,supportedVersionIds.list())' 2> /dev/null)"; then
        echo "MISSING  $model: not a Test Lab model now; pick another from: gcloud firebase test android models list --filter=form=PHYSICAL"
        missing=1
        continue
      fi
      form="${info%%	*}"
      versions="${info#*	}"
      if [ "$form" != PHYSICAL ]; then
        echo "VIRTUAL  $model ($form): the matrix wants physical devices"; missing=1
      elif [[ ",$versions," != *",$version,"* ]]; then
        echo "VERSION  $model has $versions, not $version"; missing=1
      else
        echo "ok       $model $version"
      fi
    done
    exit "$missing"
    ;;

  build-robo)
    # A profile build: compiled ahead of time as a release is, so a slow debug build's frames are
    # not reported as hangs, but signed with the debug key (no keystore needed).
    cd "$ROOT"
    flutter build apk --profile "${ROBO_DEFINES[@]}"
    ls -l "$ROBO_APK"
    ;;

  build-instr)
    target="${2:-}"
    [ -n "$target" ] || die "name the test: build-instr integration_test/native_library_test.dart [settings.json]"
    [ -f "$ROOT/$target" ] || die "no $target under $ROOT"
    settings="${3:-}"
    cd "$ROOT"
    # The integration_test package's recipe: a debug build (a release build leaves the plugin
    # out), the instrumentation APK, then the app built around the one Dart test file.
    flutter build apk --debug
    cd android
    ./gradlew app:assembleAndroidTest
    if [ -n "$settings" ]; then
      [ -f "$settings" ] || die "no settings file $settings"
      defines="$(gradle_dart_defines "$settings")"
      ./gradlew app:assembleDebug -Ptarget="$target" -Pdart-defines="$defines"
    else
      ./gradlew app:assembleDebug -Ptarget="$target"
    fi
    ls -l "$APP_APK" "$TEST_APK"
    ;;

  robo)
    need_project
    [ -f "$ROBO_APK" ] || die "no $ROBO_APK: run build-robo first"
    mapfile -t devs < <(device_flags "${DEVICES[@]}")
    run_or_print gcloud firebase test android run \
      --project="$TEST_LAB_PROJECT" \
      --type=robo \
      --app="$ROBO_APK" \
      --robo-script="$HERE/robo_offline.json" \
      --no-auto-google-login \
      --timeout="$ROBO_TIMEOUT" \
      "${devs[@]}" \
      --record-video \
      --performance-metrics \
      --results-bucket="$TEST_LAB_BUCKET" \
      --results-dir="$(results_dir robo)" \
      --results-history-name="ZestSSH Android robo" \
      --client-details=matrixLabel="robo offline"
    ;;

  instr | one)
    need_project
    target="${2:-}"
    [ -n "$target" ] || die "name the test the APKs were built for: $cmd integration_test/<file>.dart"
    [ -f "$APP_APK" ] && [ -f "$TEST_APK" ] || die "no APKs: run build-instr $target first"
    if [ "$cmd" = one ]; then
      mapfile -t devs < <(device_flags "${DEVICES[0]}")
    else
      mapfile -t devs < <(device_flags "${DEVICES[@]}")
    fi
    name="$(basename "$target" .dart)"
    # No --use-orchestrator: FlutterTestRunner is one JUnit test class that reports every Dart test
    # of the file from a single instrumentation run, which the orchestrator would split.
    run_or_print gcloud firebase test android run \
      --project="$TEST_LAB_PROJECT" \
      --type=instrumentation \
      --app="$APP_APK" \
      --test="$TEST_APK" \
      --no-auto-google-login \
      --timeout="$INSTR_TIMEOUT" \
      --num-flaky-test-attempts="$INSTR_RETRIES" \
      "${devs[@]}" \
      --record-video \
      --results-bucket="$TEST_LAB_BUCKET" \
      --results-dir="$(results_dir "instr-$name")" \
      --results-history-name="ZestSSH Android $name" \
      --client-details=matrixLabel="$name"
    ;;

  *)
    sed -n '2,22p' "${BASH_SOURCE[0]}"
    exit 2
    ;;
esac

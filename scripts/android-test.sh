#!/usr/bin/env bash
# Ubuntu/Linux 测试工作流。安装依赖、启动模拟器和安装 APK 都是显式子命令。
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
command_name="${1:-help}"
if (($#)); then shift; fi
target=aarch64
serial=""
avd=szu-api30-x86_64
image='system-images;android-30;google_apis;x86_64'
port=5556
native_class=in.rinne.your_szu_life.OnboardingNavigationTest
report_output=""
while (($#)); do
  case "$1" in
    --target|--serial|--avd|--image|--port|--native-class|--output)
      (($# >= 2)) || { printf 'Missing value for %s\n' "$1" >&2; exit 2; }
      case "$1" in
        --target) target="$2";; --serial) serial="$2";; --avd) avd="$2";;
        --image) image="$2";; --port) port="$2";; --native-class) native_class="$2";;
        --output) report_output="$2";;
      esac
      shift 2;;
    -h|--help) command_name=help; shift;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2;;
  esac
done

fail() { printf '%s\n' "$*" >&2; exit 1; }
case "$target" in
  aarch64) triple=aarch64-linux-android; arch=arm64; abi=arm64-v8a;;
  x86_64) triple=x86_64-linux-android; arch=x86_64; abi=x86_64;;
  *) fail 'Only --target aarch64 or --target x86_64 is supported.';;
esac
[[ "$avd" =~ ^[A-Za-z0-9_-]+$ ]] || fail 'Invalid AVD name.'
[[ "$native_class" =~ ^[A-Za-z_][A-Za-z0-9_.]*$ ]] || fail 'Invalid instrumentation class name.'
[[ "$port" =~ ^[0-9]+$ ]] || fail 'Invalid emulator port.'
((port >= 5554 && port <= 5682 && port % 2 == 0)) || fail 'Use an even emulator port from 5554 to 5682.'

export ANDROID_TEST_ROOT="${ANDROID_TEST_ROOT:-$repo_root/.android-test}"
[[ "$ANDROID_TEST_ROOT" = /* ]] || fail 'ANDROID_TEST_ROOT must be absolute.'
export ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_USER_HOME="${ANDROID_USER_HOME:-$ANDROID_TEST_ROOT/android-user}"
export ANDROID_EMULATOR_HOME="${ANDROID_EMULATOR_HOME:-$ANDROID_TEST_ROOT/emulator-home}"
export ANDROID_AVD_HOME="${ANDROID_AVD_HOME:-$ANDROID_TEST_ROOT/avd}"
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$ANDROID_TEST_ROOT/gradle}"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}"
export PATH="$repo_root/node_modules/.bin:${ANDROID_HOME:+$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$ANDROID_HOME/cmdline-tools/latest/bin:}$PATH"
gradle_workers="${ANDROID_TEST_WORKERS:-2}"
emulator_memory="${ANDROID_TEST_EMULATOR_MEMORY_MB:-4096}"
emulator_cores="${ANDROID_TEST_EMULATOR_CORES:-4}"
data_partition_gb="${ANDROID_TEST_DATA_PARTITION_GB:-6}"
[[ "$gradle_workers" =~ ^[1-9][0-9]*$ ]] || fail 'ANDROID_TEST_WORKERS must be positive.'
[[ "$CARGO_BUILD_JOBS" =~ ^[1-9][0-9]*$ ]] || fail 'CARGO_BUILD_JOBS must be positive.'
[[ "$emulator_memory" =~ ^[1-9][0-9]*$ && "$emulator_cores" =~ ^[1-9][0-9]*$ ]] || fail 'Emulator memory and cores must be positive.'
[[ "$data_partition_gb" =~ ^[1-9][0-9]*$ ]] || fail 'ANDROID_TEST_DATA_PARTITION_GB must be positive.'
app_package=in.rinne.your_szu_life.onboarding_test
android_dir="$repo_root/src-tauri/gen/android"
app_apk="$android_dir/app/build/outputs/apk/$arch/debug/app-$arch-debug.apk"
test_apk="$android_dir/app/build/outputs/apk/androidTest/$arch/debug/app-$arch-debug-androidTest.apk"

usage() {
  cat <<'EOF'
Usage: bash scripts/android-test.sh COMMAND [OPTIONS]

  doctor           Read-only toolchain/SDK/KVM diagnostics
  build            Build frontend, one debug APK, unit tests and instrumentation APK
  build-tests      Run Android unit tests and build instrumentation APK (native library required)
  capture          Record device parameters; requires --serial
  native-test      Install isolated APKs and run one instrumentation class; requires --serial
  emulator-create  Create an API 30 Google x86_64 AVD; requires an installed image
  emulator-start   Start this AVD headlessly with KVM; wait at most 180 seconds
  emulator-run     Run this AVD in the foreground (for a dedicated systemd service)
  emulator-stop    Stop only this AVD after checking its name

Options: --target aarch64|x86_64 (default aarch64), --serial SERIAL,
         --avd NAME, --image SDK_PACKAGE, --port EVEN_PORT (default 5556),
         --native-class CLASS, --output REPORT_DIRECTORY

For Ubuntu x86_64 emulators explicitly use --target x86_64.
native-test defaults to OnboardingNavigationTest and requires a fresh test app.
For legacy schema-14 devices use --native-class in.rinne.your_szu_life.LegacyAuthCookieStoreTest.
No command uninstalls apps, clears user data or installs SDK packages automatically.
ANDROID_TEST_EMULATOR_MEMORY_MB and ANDROID_TEST_EMULATOR_CORES set emulator resources.
ANDROID_TEST_DATA_PARTITION_GB sets the new AVD data partition size (default 6 GiB).
EOF
}

need() { command -v "$1" >/dev/null || fail "Missing tool: $1"; }
sdk_ready() {
  [[ -n "$ANDROID_HOME" && -d "$ANDROID_HOME" ]] || fail 'Set ANDROID_HOME to an installed Android SDK.'
}
build_ready() {
  sdk_ready
  need java; need python3; need rustup; need cargo; need vp; need rg
  if [[ -n "${JAVA_HOME:-}" ]]; then
    [[ -x "$JAVA_HOME/bin/javac" && -x "$JAVA_HOME/bin/jlink" ]] || fail 'JAVA_HOME must point to a complete JDK with javac and jlink.'
  fi
  export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/27.0.12077973}"
  export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
  export NDK_HOME="$ANDROID_NDK_HOME"
  [[ -f "$ANDROID_NDK_HOME/source.properties" ]] || fail 'Install ndk;27.0.12077973.'
  [[ -d "$ANDROID_HOME/platforms/android-36" ]] || fail 'Install platforms;android-36.'
  [[ -d "$ANDROID_HOME/build-tools/35.0.0" ]] || fail 'Install build-tools;35.0.0.'
  [[ -d "$repo_root/node_modules" ]] || fail 'Run vp install --frozen-lockfile first.'
  rustup target list --installed | rg -q "^$triple$" || fail "Run rustup target add $triple."
  mkdir -p "$GRADLE_USER_HOME/init.d"
  cp "$repo_root/scripts/android/testing.init.gradle" "$GRADLE_USER_HOME/init.d/szu-testing.gradle"
  # Tauri 的附加参数传给 cargo，不是 Gradle；通过系统属性限制 Gradle worker。
  export GRADLE_OPTS="${GRADLE_OPTS:-} -Dorg.gradle.workers.max=$gradle_workers -Dorg.gradle.daemon=false"
}
gradle_tests() {
  (cd "$android_dir" && ./gradlew :app:test"${arch^}"DebugUnitTest :app:assemble"${arch^}"DebugAndroidTest \
    --no-daemon --max-workers="$gradle_workers" \
    -PtargetList="$target" -ParchList="$arch" -PabiList="$abi")
}
verify_apk() {
  python3 - "$app_apk" "$test_apk" "$abi" "$app_package" "$ANDROID_HOME" <<'PY'
import pathlib, re, subprocess, sys, zipfile
app, tests, abi, package, sdk = sys.argv[1:]
tools = pathlib.Path(sdk) / 'build-tools/35.0.0'
certificates = []
for apk, expected_package in ((app, package), (tests, package + '.test')):
    assert pathlib.Path(apk).is_file(), f"APK missing: {apk}"
    with zipfile.ZipFile(apk) as archive:
        abis = {name.split('/')[1] for name in archive.namelist() if name.startswith('lib/')}
        expected_abis = abis == {abi} if apk == app else abis <= {abi}
        assert expected_abis, f"Unexpected APK ABIs: {abis}"
        if apk == app and f'lib/{abi}/libaria2c.so' not in archive.namelist():
            print('This APK has no aria2 sidecar; downloader tests are not covered.', file=sys.stderr)
    signing = subprocess.check_output([str(tools/'apksigner'), 'verify', '--print-certs', apk], text=True)
    certificates.append(set(re.findall(r'^Signer #\d+ certificate SHA-256 digest: (\S+)$', signing, re.M)))
    badging = subprocess.check_output([str(tools/'aapt'), 'dump', 'badging', apk], text=True)
    assert f"package: name='{expected_package}'" in badging, 'Refusing to install an APK with another package ID'
assert certificates[0] and certificates[0] == certificates[1], 'Application and test APK signing certificates differ'
manifest = subprocess.check_output([str(tools/'aapt'), 'dump', 'xmltree', tests, 'AndroidManifest.xml'], text=True)
assert re.search(r'android:targetPackage\([^)]*\)="' + re.escape(package) + r'"', manifest), 'Unexpected instrumentation target'
print(app)
print(tests)
PY
}
device_ready() {
  need adb
  [[ -n "$serial" ]] || fail 'Specify --serial explicitly; adb devices -l lists targets.'
  [[ "$(adb -s "$serial" get-state)" = device ]] || fail 'ADB target is not ready.'
}
reports_ready() {
  if [[ -z "$report_output" ]]; then
    report_output="$ANDROID_TEST_ROOT/reports/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  fi
  mkdir -p "$report_output"
  chmod 700 "$report_output"
}

emulator_ready() {
  sdk_ready; need emulator; need adb; need python3
  [[ -f "$ANDROID_AVD_HOME/$avd.ini" ]] || fail 'Create the AVD first.'
  [[ -r /dev/kvm && -w /dev/kvm ]] || fail 'This user needs /dev/kvm access.'
  serial="emulator-$port"
  [[ "$(adb devices | awk -v serial="$serial" '$1==serial {print $1}')" != "$serial" ]] || fail 'Emulator port already in use.'
  # Another developer's emulator may belong to a different ADB server.
  python3 - "$port" <<'PY'
import errno, socket, sys
for port in (int(sys.argv[1]), int(sys.argv[1]) + 1):
    for family, host in ((socket.AF_INET, '127.0.0.1'), (socket.AF_INET6, '::1')):
        try:
            with socket.socket(family, socket.SOCK_STREAM) as probe:
                probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                probe.bind((host, port))
                probe.listen(1)
        except OSError as error:
            if family == socket.AF_INET6 and error.errno in (errno.EAFNOSUPPORT, errno.EADDRNOTAVAIL):
                continue
            raise SystemExit(f'Emulator port {port} is unavailable: {error}')
PY
  emulator -accel-check
  emulator_args=(-avd "$avd" -port "$port" -no-window -no-audio -no-boot-anim
    -gpu swiftshader -accel on -no-snapshot -memory "$emulator_memory" -cores "$emulator_cores")
}

cd "$repo_root"
case "$command_name" in
  help) usage;;
  doctor)
    printf 'Host: %s\nTarget: %s\nSDK: %s\nState: %s\n' "$(uname -sm)" "$triple" "${ANDROID_HOME:-unset}" "$ANDROID_TEST_ROOT"
    for tool in java python3 rg vp rustup cargo adb avdmanager emulator; do
      if command -v "$tool" >/dev/null; then printf '%s: %s\n' "$tool" "$(command -v "$tool")"; else printf '%s: missing\n' "$tool"; fi
    done
    if [[ -r /dev/kvm && -w /dev/kvm ]]; then printf 'KVM: accessible\n'; else printf 'KVM: unavailable to this user\n'; fi
    if command -v emulator >/dev/null; then emulator -accel-check; fi
    if command -v rustup >/dev/null; then rustup target list --installed; fi;;
  build)
    build_ready; need rg
    vp run build
    vp run tauri android build --ci --debug --apk --target "$target" --split-per-abi \
      --config '{"build":{"beforeBuildCommand":""}}'
    gradle_tests
    verify_apk;;
  build-tests)
    build_ready; need rg
    [[ -s "$repo_root/src-tauri/target/$triple/debug/libyour_szu_life_lib.so" ]] || fail 'Build the selected native target with the build command first.'
    gradle_tests;;
  capture)
    device_ready; need python3; reports_ready
    python3 scripts/android/capture-device.py --serial "$serial" --output "$report_output/device.json" --adb "$(command -v adb)";;
  native-test)
    sdk_ready; device_ready; need python3; reports_ready
    verify_apk
    device_abis="$(adb -s "$serial" shell getprop ro.product.cpu.abilist | tr -d '\r')"
    [[ ",$device_abis," = *",$abi,"* ]] || fail 'APK architecture does not match the selected device.'
    python3 scripts/android/capture-device.py --serial "$serial" --output "$report_output/device.json" --adb "$(command -v adb)"
    python3 - "$app_apk" "$test_apk" "$target" "$report_output/build.json" <<'PY'
import hashlib, json, pathlib, subprocess, sys
app, tests, target, output = sys.argv[1:]
record = {'checkoutCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
          'checkoutHasChanges': bool(subprocess.check_output(['git', 'status', '--porcelain'], text=True).strip()),
          'target': target,
          'appApkSha256': hashlib.sha256(pathlib.Path(app).read_bytes()).hexdigest(),
          'testApkSha256': hashlib.sha256(pathlib.Path(tests).read_bytes()).hexdigest()}
pathlib.Path(output).write_text(json.dumps(record, indent=2) + '\n')
PY
    adb -s "$serial" install -r "$app_apk"
    adb -s "$serial" install -r "$test_apk"
    runner_args=(-w -e class "$native_class")
    if [[ "$native_class" = in.rinne.your_szu_life.OnboardingNavigationTest ]]; then
      # The test stops MainActivity; finishing it would exit Tauri before JUnit can report.
      runner_args+=(-e waitForActivitiesToComplete false)
    fi
    # am instrument may return exit 0 even when assertions fail; inspect the runner output.
    adb -s "$serial" shell am instrument "${runner_args[@]}" \
      "$app_package.test/androidx.test.runner.AndroidJUnitRunner" | tee "$report_output/instrumentation.txt"
    python3 - "$report_output/instrumentation.txt" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
if not re.search(r'^OK \([1-9][0-9]* tests?\)', text, re.M) or any(
    marker in text for marker in ('FAILURES!!!', 'INSTRUMENTATION_FAILED', 'INSTRUMENTATION_ABORTED')
):
    raise SystemExit('Instrumentation did not report a successful, nonempty test run')
PY
    printf 'Test report: %s\n' "$report_output";;
  emulator-create)
    sdk_ready; need avdmanager; need python3
    [[ "$(uname -m)" = x86_64 ]] || fail 'This AVD workflow is for x86_64 Linux hosts.'
    [[ "$image" = *';x86_64' ]] || fail 'Use an x86_64 system image on this host.'
    [[ ! -e "$ANDROID_AVD_HOME/$avd.ini" && ! -e "$ANDROID_AVD_HOME/$avd.avd" ]] || fail 'AVD already exists; it will not be overwritten.'
    mkdir -p "$ANDROID_AVD_HOME"
    printf 'no\n' | avdmanager create avd --name "$avd" --package "$image" --path "$ANDROID_AVD_HOME/$avd.avd" --device pixel_5
    python3 - "$ANDROID_AVD_HOME/$avd.avd/config.ini" "$emulator_memory" "$emulator_cores" "$data_partition_gb" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
values = {key.strip(): value.strip() for key, value in
          (line.split('=', 1) for line in path.read_text().splitlines() if '=' in line)}
values.update({'hw.lcd.width':'1080', 'hw.lcd.height':'2340', 'hw.lcd.density':'480',
               'hw.ramSize':sys.argv[2], 'hw.cpu.ncore':sys.argv[3], 'disk.dataPartition.size':sys.argv[4]+'G'})
path.write_text(''.join(f'{key}={value}\n' for key,value in values.items()))
PY
    printf 'Created AVD: %s\n' "$avd";;
  emulator-run)
    emulator_ready
    exec emulator "${emulator_args[@]}";;
  emulator-start)
    need timeout; emulator_ready
    mkdir -p "$ANDROID_TEST_ROOT/emulators"
    nohup emulator "${emulator_args[@]}" \
      >"$ANDROID_TEST_ROOT/emulators/$avd.log" 2>&1 </dev/null &
    emulator_pid=$!
    printf '%s\n' "$emulator_pid" >"$ANDROID_TEST_ROOT/emulators/$avd.pid"
    boot_deadline=$((SECONDS + 180))
    while ((SECONDS < boot_deadline)); do
      kill -0 "$emulator_pid" 2>/dev/null || fail "Emulator exited; see $ANDROID_TEST_ROOT/emulators/$avd.log"
      if [[ "$(timeout 2 adb -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]]; then
        printf 'Ready: %s (AVD %s)\n' "$serial" "$avd"; exit 0
      fi
      sleep 2
    done
    fail "Boot timeout; emulator remains running, see $ANDROID_TEST_ROOT/emulators/$avd.log";;
  emulator-stop)
    need adb; need timeout
    serial="emulator-$port"
    active_avd="$(timeout 10 adb -s "$serial" emu avd name | head -1 | tr -d '\r')"
    [[ "$active_avd" = "$avd" ]] || fail 'Refusing to stop another AVD.'
    adb -s "$serial" emu kill;;
  *) usage; fail "Unknown command: $command_name";;
esac

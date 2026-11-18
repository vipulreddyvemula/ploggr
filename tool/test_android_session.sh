#!/usr/bin/env bash
set -euo pipefail

# Use a disposable emulator and a disposable API with AUTH_ACCESS_TTL_SECONDS=12.
device=${1:?Pass the disposable emulator serial}
port=${2:?Pass the host port of the disposable API}
[[ $device == emulator-* && $port =~ ^[0-9]+$ ]]
adb_device=(adb -s "$device")
package=com.example.ploggr
if "${adb_device[@]}" shell pm path "$package" | grep -q '^package:'; then
  echo "Choose a disposable emulator without Ploggr installed." >&2
  exit 1
fi
flutter build apk --debug -t test_driver/session_probe.dart \
  --dart-define="API_BASE_URL=http://127.0.0.1:$port/api/"
apk=build/app/outputs/flutter-apk/app-debug.apk
"${adb_device[@]}" reverse "tcp:$port" "tcp:$port"
cleanup() {
  "${adb_device[@]}" uninstall "$package" >/dev/null 2>&1 || true
  "${adb_device[@]}" reverse --remove "tcp:$port" >/dev/null 2>&1 || true
}
trap cleanup EXIT
install_probe() { "${adb_device[@]}" install "$apk" >/dev/null; }
run_probe() {
  local command=$1 result
  echo "Checking Android session ($command)" >&2
  "${adb_device[@]}" shell am force-stop "$package"
  "${adb_device[@]}" shell run-as "$package" mkdir -p cache
  "${adb_device[@]}" shell run-as "$package" rm -f cache/session-probe-result
  printf '%s' "$command" | "${adb_device[@]}" shell -T run-as "$package" tee cache/session-probe-command >/dev/null
  "${adb_device[@]}" shell am start -n "$package/.MainActivity" >/dev/null
  for ((i=0; i<120; i++)); do
    result=$("${adb_device[@]}" shell run-as "$package" cat cache/session-probe-result 2>/dev/null | tr -d '\r' || true)
    if [[ -n $result ]]; then
      printf '%s\n' "$result"
      return
    fi
    sleep 1
  done
  echo "Timed out during $command" >&2
  return 1
}
install_probe
[[ $(run_probe inspect) == signedOut ]]
user_id=$(run_probe create)
[[ $user_id =~ ^[0-9a-f-]{36}$ ]]
[[ $(run_probe inspect) == "$user_id" ]]
[[ $(run_probe renew) == "$user_id" ]]
"${adb_device[@]}" reverse --remove "tcp:$port"
[[ $(run_probe inspect) == unavailable ]]
"${adb_device[@]}" reverse "tcp:$port" "tcp:$port"
[[ $(run_probe inspect) == "$user_id" ]]
[[ $(run_probe revoke) == expired ]]
[[ $(run_probe inspect) == signedOut ]]
[[ $(run_probe create) =~ ^[0-9a-f-]{36}$ ]]
"${adb_device[@]}" reverse --remove "tcp:$port"
[[ $(run_probe offline-logout) == signedOut ]]
"${adb_device[@]}" reverse "tcp:$port" "tcp:$port"
[[ $(run_probe inspect) == signedOut ]]
[[ $(run_probe create) =~ ^[0-9a-f-]{36}$ ]]
[[ $(run_probe logout) == signedOut ]]
[[ $(run_probe inspect) == signedOut ]]
[[ $(run_probe create) =~ ^[0-9a-f-]{36}$ ]]
"${adb_device[@]}" shell pm clear "$package" >/dev/null
[[ $(run_probe inspect) == signedOut ]]
[[ $(run_probe create) =~ ^[0-9a-f-]{36}$ ]]
"${adb_device[@]}" uninstall "$package" >/dev/null
install_probe
[[ $(run_probe inspect) == signedOut ]]
echo "Android session persistence checks passed."

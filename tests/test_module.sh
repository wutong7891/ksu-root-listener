#!/bin/sh
set -eu

TESTDIR=${0%/*}
ROOT=$(CDPATH= cd -- "$TESTDIR/.." && pwd)
MODDIR=/data/adb/modules/ksu_app_watcher
. "$ROOT/bin/common.sh"

assert_equal() {
  [ "$1" = "$2" ] || { echo "expected '$2', got '$1'" >&2; exit 1; }
}

case_name=resumed
dumpsys() {
  case "$case_name:$1:$2" in
    resumed:activity:activities) echo 'mResumedActivity: ActivityRecord{abc u0 com.demo.resumed/.MainActivity t12}' ;;
    top:activity:top) echo '  ACTIVITY com.demo.top/.MainActivity 123 pid=456' ;;
    window:window:windows) echo 'mCurrentFocus=Window{abc u0 com.demo.window/com.demo.window.MainActivity}' ;;
  esac
}

assert_equal "$(foreground_package)" com.demo.resumed
case_name=top
assert_equal "$(foreground_package)" com.demo.top
case_name=window
assert_equal "$(foreground_package)" com.demo.window

test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT INT TERM
mkdir -p "$test_root/bin" "$test_root/config" "$test_root/logs"
cp "$ROOT/bin/control.sh" "$ROOT/bin/common.sh" "$test_root/bin/"
cat > "$test_root/read-input.sh" <<'SCRIPT'
#!/bin/sh
IFS= read -r first
IFS= read -r second
IFS= read -r third
printf '<%s>|<%s>|<%s>\n' "$first" "$second" "$third"
SCRIPT
printf '%s\n' "$test_root/read-input.sh" > "$test_root/config/script"
input='1

确认'
KSU_WATCHER_STATE_DIR="$test_root" sh "$test_root/bin/control.sh" set-preinput "$input" >/dev/null
assert_equal "$(KSU_WATCHER_STATE_DIR="$test_root" sh "$test_root/bin/control.sh" run)" '<1>|<>|<确认>'

mock_bin="$test_root/mock-bin"
watch_state="$test_root/watch-state"
mkdir -p "$mock_bin" "$watch_state/config" "$watch_state/logs"
cat > "$mock_bin/dumpsys" <<'SCRIPT'
#!/bin/sh
case "$1:$2" in
  activity:activities) echo 'mResumedActivity: ActivityRecord{abc u0 com.demo.target/.MainActivity t12}' ;;
esac
SCRIPT
cat > "$mock_bin/ksud" <<'SCRIPT'
#!/bin/sh
[ "$1:$2:$3" = 'feature:check:sulog' ] && echo unsupported
exit 1
SCRIPT
command -v chmod >/dev/null 2>&1 && chmod +x "$mock_bin/dumpsys" "$mock_bin/ksud"
cat > "$test_root/trigger.sh" <<SCRIPT
#!/bin/sh
IFS= read -r choice
printf '%s\n' "\$choice" >> "$test_root/trigger-result"
SCRIPT
printf '1\n' > "$watch_state/config/enabled"
printf 'com.demo.target\n' > "$watch_state/config/package"
printf '%s\n' "$test_root/trigger.sh" > "$watch_state/config/script"
printf '1\n' > "$watch_state/config/interval"
printf '0\n' > "$watch_state/config/cooldown"
printf '7\n' > "$watch_state/config/preinput"
if timeout --version 2>/dev/null | grep -q 'GNU coreutils'; then
  set +e
  PATH="$mock_bin:$PATH" KSU_WATCHER_STATE_DIR="$watch_state" timeout 3 sh "$ROOT/bin/watcher.sh"
  watch_code=$?
  set -e
  [ "$watch_code" -eq 124 ] || [ "$watch_code" -eq 143 ] || { echo "watcher test exited $watch_code" >&2; exit 1; }
  assert_equal "$(cat "$test_root/trigger-result")" 7
  [ "$(wc -l < "$test_root/trigger-result" | tr -d ' ')" = 1 ] || { echo 'watcher triggered more than once' >&2; exit 1; }
fi

echo 'module tests passed'

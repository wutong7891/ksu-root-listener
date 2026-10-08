#!/bin/sh
set -eu

TESTDIR=${0%/*}
ROOT=$(CDPATH= cd -- "$TESTDIR/.." && pwd)
MODDIR=/data/adb/modules/ksu_app_watcher
. "$ROOT/bin/common.sh"

assert_equal() {
  [ "$1" = "$2" ] || { echo "expected '$2', got '$1'" >&2; exit 1; }
}

pause_step() {
  if command -v sleep >/dev/null 2>&1; then
    sleep 0.05
  elif command -v node.exe >/dev/null 2>&1; then
    node.exe -e 'setTimeout(function () {}, 50)'
  else
    :
  fi
}

case_name=resumed
dumpsys() {
  case "$case_name:$1:${2-}" in
    resumed:activity:activities) echo 'mResumedActivity: ActivityRecord{abc u0 com.demo.resumed/.MainActivity t12}' ;;
    top:activity:top) echo '  ACTIVITY com.demo.top/.MainActivity 123 pid=456' ;;
    window:window:windows) echo 'mCurrentFocus=Window{abc u0 com.demo.window/com.demo.window.MainActivity}' ;;
    keyboard:input_method:) echo 'mInputShown=true mIsInputViewShown=true' ;;
    keyboard-hidden:input_method:) echo 'mInputShown=false mIsInputViewShown=false' ;;
  esac
}

assert_equal "$(foreground_package)" com.demo.resumed
case_name=top
assert_equal "$(foreground_package)" com.demo.top
case_name=window
assert_equal "$(foreground_package)" com.demo.window
case_name=keyboard
keyboard_visible || { echo 'visible keyboard was not detected' >&2; exit 1; }
case_name=keyboard-hidden
if keyboard_visible; then echo 'hidden keyboard was detected as visible' >&2; exit 1; fi

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

# 激活数字允许留空；留空代表采用 v11 前台触发模式。
KSU_WATCHER_STATE_DIR="$test_root" sh "$test_root/bin/control.sh" set-expected '' >/dev/null
[ ! -s "$test_root/config/expected_input" ] || { echo 'empty activation code was not saved' >&2; exit 1; }
set +e
KSU_WATCHER_STATE_DIR="$test_root" sh "$test_root/bin/control.sh" set-expected '12a3' >/dev/null 2>&1
invalid_code=$?
set -e
[ "$invalid_code" -eq 2 ] || { echo 'non-numeric activation code was accepted' >&2; exit 1; }

# 同一次前台会话只能被认领一次。
STATE_DIR="$test_root"
CONFIG="$test_root/config"
claim_app_session foreground
if claim_app_session duplicate; then
  echo 'same app session was claimed twice' >&2
  exit 1
fi
clear_app_session_claim
claim_app_session foreground
assert_equal "$(cat "$test_root/app_session.claim/source")" foreground
clear_app_session_claim

if command -v sleep >/dev/null 2>&1; then
cat > "$test_root/slow-script.sh" <<SCRIPT
#!/bin/sh
printf 'run\n' >> "$test_root/concurrent-result"
sleep 1
SCRIPT
printf '%s\n' "$test_root/slow-script.sh" > "$test_root/config/script"
: > "$test_root/config/preinput"
KSU_WATCHER_STATE_DIR="$test_root" sh "$test_root/bin/control.sh" run >/dev/null &
first_run=$!
tries=0
while [ ! -d "$test_root/run.lock" ] && [ "$tries" -lt 20 ]; do pause_step; tries=$((tries + 1)); done
set +e
KSU_WATCHER_STATE_DIR="$test_root" sh "$test_root/bin/control.sh" run >/dev/null 2>&1
second_code=$?
set -e
wait "$first_run"
[ "$second_code" -eq 75 ] || { echo "concurrent run returned $second_code instead of 75" >&2; exit 1; }
[ "$(wc -l < "$test_root/concurrent-result" | tr -d ' ')" = 1 ] || { echo 'concurrent execution was not deduplicated' >&2; exit 1; }
fi

mock_bin="$test_root/mock-bin"
watch_state="$test_root/watch-state"
mkdir -p "$mock_bin" "$watch_state/config" "$watch_state/logs"
cat > "$mock_bin/dumpsys" <<SCRIPT
#!/bin/sh
case "\$1:\$2" in
  activity:activities)
    echo 'mResumedActivity: ActivityRecord{abc u0 com.demo.target/.MainActivity t12}'
    ;;
  input_method:)
    echo 'mInputShown=false mIsInputViewShown=false'
    ;;
esac
SCRIPT
command -v chmod >/dev/null 2>&1 && chmod +x "$mock_bin/dumpsys"
cat > "$mock_bin/uiautomator" <<SCRIPT
#!/bin/sh
printf 'probe\n' >> "$test_root/ui-probe-count"
printf '%s\n' '<hierarchy><node text="123456" class="android.widget.EditText" password="false" focused="true" editable="true" /></hierarchy>'
SCRIPT
command -v chmod >/dev/null 2>&1 && chmod +x "$mock_bin/uiautomator"
cat > "$mock_bin/timeout" <<'SCRIPT'
#!/bin/sh
shift
exec "$@"
SCRIPT
cat > "$mock_bin/sleep" <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT
command -v chmod >/dev/null 2>&1 && chmod +x "$mock_bin/timeout" "$mock_bin/sleep"
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
printf '123456\n' > "$watch_state/config/expected_input"
PATH="$mock_bin:$PATH" KSU_WATCHER_STATE_DIR="$watch_state" sh "$ROOT/bin/watcher.sh" &
watcher_job=$!
tries=0
while [ ! -d "$watch_state/watcher.lock" ] && [ "$tries" -lt 40 ]; do pause_step; tries=$((tries + 1)); done
# 第二个监听器必须因原子单实例锁立即退出。
PATH="$mock_bin:$PATH" KSU_WATCHER_STATE_DIR="$watch_state" sh "$ROOT/bin/watcher.sh"
duplicate_code=$?
tries=0
while [ ! -s "$test_root/trigger-result" ] && [ "$tries" -lt 80 ]; do pause_step; tries=$((tries + 1)); done
kill "$watcher_job" 2>/dev/null || true
wait "$watcher_job" 2>/dev/null || true
[ "$duplicate_code" -eq 0 ] || { echo "duplicate watcher exited $duplicate_code" >&2; exit 1; }
assert_equal "$(cat "$test_root/trigger-result")" 7
[ "$(wc -l < "$test_root/trigger-result" | tr -d ' ')" = 1 ] || { echo 'watcher triggered more than once' >&2; exit 1; }
[ "$(grep -c '前台与输入数字检测服务已启动' "$watch_state/logs/trigger.log")" = 1 ] || { echo 'more than one watcher started' >&2; exit 1; }
[ "$(grep -c '目标应用输入数字匹配' "$watch_state/logs/trigger.log")" = 1 ] || { echo 'input match did not trigger exactly once' >&2; exit 1; }

# 空数字必须完全采用 v11 前台触发，且绝不能调用 UIAutomator。
probes_before_blank=$(wc -l < "$test_root/ui-probe-count" | tr -d ' ')
blank_state="$test_root/blank-watch-state"
mkdir -p "$blank_state/config" "$blank_state/logs"
cat > "$test_root/blank-trigger.sh" <<SCRIPT
#!/bin/sh
printf 'foreground\n' >> "$test_root/blank-trigger-result"
SCRIPT
printf '1\n' > "$blank_state/config/enabled"
printf 'com.demo.target\n' > "$blank_state/config/package"
printf '%s\n' "$test_root/blank-trigger.sh" > "$blank_state/config/script"
printf '1\n' > "$blank_state/config/interval"
printf '0\n' > "$blank_state/config/cooldown"
: > "$blank_state/config/preinput"
: > "$blank_state/config/expected_input"
PATH="$mock_bin:$PATH" KSU_WATCHER_STATE_DIR="$blank_state" sh "$ROOT/bin/watcher.sh" &
blank_job=$!
tries=0
while [ ! -s "$test_root/blank-trigger-result" ] && [ "$tries" -lt 80 ]; do pause_step; tries=$((tries + 1)); done
kill "$blank_job" 2>/dev/null || true
wait "$blank_job" 2>/dev/null || true
[ "$(cat "$test_root/blank-trigger-result")" = foreground ] || { echo 'blank v11 mode did not run' >&2; exit 1; }
[ "$(wc -l < "$test_root/blank-trigger-result" | tr -d ' ')" = 1 ] || { echo 'blank v11 mode triggered more than once' >&2; exit 1; }
[ "$(grep -c 'v11 空数字模式' "$blank_state/logs/trigger.log")" = 1 ] || { echo 'blank v11 trigger was not logged exactly once' >&2; exit 1; }
probes_after_blank=$(wc -l < "$test_root/ui-probe-count" | tr -d ' ')
[ "$probes_before_blank" = "$probes_after_blank" ] || { echo 'blank v11 mode unexpectedly called UIAutomator' >&2; exit 1; }

echo 'module tests passed'

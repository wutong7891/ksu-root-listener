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
while [ ! -d "$test_root/run.lock" ] && [ "$tries" -lt 20 ]; do sleep 0.05; tries=$((tries + 1)); done
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
count_file='$test_root/dumpsys-count'
count=0
[ -f "\$count_file" ] && count=\$(cat "\$count_file")
count=\$((count + 1))
printf '%s\n' "\$count" > "\$count_file"
case "\$1:\$2" in
  activity:activities)
    # 第二次采样模拟短暂跳到 SystemUI，随后返回目标应用。
    if [ "\$count" -eq 2 ]; then
      echo 'mResumedActivity: ActivityRecord{abc u0 com.android.systemui/.MainActivity t12}'
    else
      echo 'mResumedActivity: ActivityRecord{abc u0 com.demo.target/.MainActivity t12}'
    fi
    ;;
esac
SCRIPT
command -v chmod >/dev/null 2>&1 && chmod +x "$mock_bin/dumpsys"
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
  PATH="$mock_bin:$PATH" KSU_WATCHER_STATE_DIR="$watch_state" timeout -k 1 4 sh "$ROOT/bin/watcher.sh" &
  watcher_job=$!
  tries=0
  while [ ! -d "$watch_state/watcher.lock" ] && [ "$tries" -lt 40 ]; do sleep 0.05; tries=$((tries + 1)); done
  # 第二个监听器必须因原子单实例锁立即退出。
  PATH="$mock_bin:$PATH" KSU_WATCHER_STATE_DIR="$watch_state" sh "$ROOT/bin/watcher.sh"
  duplicate_code=$?
  wait "$watcher_job"
  watch_code=$?
  set -e
  [ "$duplicate_code" -eq 0 ] || { echo "duplicate watcher exited $duplicate_code" >&2; exit 1; }
  [ "$watch_code" -eq 124 ] || [ "$watch_code" -eq 143 ] || { echo "watcher test exited $watch_code" >&2; exit 1; }
  assert_equal "$(cat "$test_root/trigger-result")" 7
  [ "$(wc -l < "$test_root/trigger-result" | tr -d ' ')" = 1 ] || { echo 'watcher triggered more than once' >&2; exit 1; }
  [ "$(grep -c '前台检测服务已启动' "$watch_state/logs/trigger.log")" = 1 ] || { echo 'more than one watcher started' >&2; exit 1; }
fi

echo 'module tests passed'

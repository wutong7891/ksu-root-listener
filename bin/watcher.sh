#!/system/bin/sh

MODDIR=${0%/*}
MODDIR=${MODDIR%/*}
STATE_DIR=${KSU_WATCHER_STATE_DIR:-/data/adb/ksu_app_watcher}
CONFIG="$STATE_DIR/config"
TRIGGER_LOG="$STATE_DIR/logs/trigger.log"
PIDFILE="$STATE_DIR/watcher.pid"
SESSION_BOOTFILE="$CONFIG/session_boot_id"
ACTIVE_INTERVAL=0.20

mkdir -p "$CONFIG" "$STATE_DIR/logs"
. "$MODDIR/bin/common.sh"

acquire_watcher_lock || exit 0
echo $$ > "$PIDFILE"
cleanup() {
  release_run_lock
  saved_pid=$(cat "$PIDFILE" 2>/dev/null)
  [ "$saved_pid" = "$$" ] && rm -f "$PIDFILE"
  release_watcher_lock
}
trap cleanup EXIT
trap 'exit 0' INT TERM

# 触发时间只在本次开机有效，避免设备时间变化造成冷却判断异常。
session_boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
saved_session_boot_id=$(cat "$SESSION_BOOTFILE" 2>/dev/null)
if [ -n "$session_boot_id" ] && [ "$session_boot_id" != "$saved_session_boot_id" ]; then
  rm -f "$CONFIG/last_trigger"
  clear_app_session_claim
  printf '%s\n' "$session_boot_id" > "$SESSION_BOOTFILE"
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] KernelSU 键盘回撤检测服务已启动，pid=$$" >> "$TRIGGER_LOG"

read_value() {
  file="$1"; fallback="$2"
  [ -f "$CONFIG/$file" ] && cat "$CONFIG/$file" 2>/dev/null || printf '%s' "$fallback"
}

target_active=0
keyboard_armed=0
hidden_samples=0
input_matched=0

while true; do
  enabled=$(read_value enabled 0)
  interval=$(read_value interval 2)
  case "$interval" in ''|*[!0-9]*) interval=2 ;; esac
  [ "$interval" -ge 1 ] 2>/dev/null || interval=1
  [ "$interval" -le 60 ] 2>/dev/null || interval=60
  if [ "$enabled" != "1" ]; then sleep "$interval"; continue; fi

  package=$(read_value package '')
  script=$(read_value script "$MODDIR/scripts/target.sh")
  expected_input=$(read_value expected_input '')
  cooldown=$(read_value cooldown 2)
  case "$cooldown" in ''|*[!0-9]*) cooldown=2 ;; esac
  last_trigger=$(read_value last_trigger 0)
  case "$last_trigger" in ''|*[!0-9]*) last_trigger=0 ;; esac

  # 只有目标应用处于前台，且本进程先观察到键盘显示，随后连续两次确认
  # 键盘隐藏，才认定为一次有效“键盘回撤”。
  foreground=$(foreground_package)
  if [ -n "$foreground" ] && [ "$foreground" = "$package" ]; then
    if [ "$target_active" != "1" ]; then
      target_active=1
      keyboard_armed=0
      hidden_samples=0
      input_matched=0
      clear_app_session_claim
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] 目标应用进入前台: package=$package" >> "$TRIGGER_LOG"
    fi

    if keyboard_visible; then
      hidden_samples=0
      if [ "$keyboard_armed" != "1" ]; then
        clear_app_session_claim
        keyboard_armed=1
        input_matched=0
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 检测到键盘弹出，等待回撤: package=$package" >> "$TRIGGER_LOG"
      fi
      if [ "$input_matched" != "1" ]; then
        if [ -z "$expected_input" ]; then
          input_matched=1
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] 未设置激活字符，仅等待键盘回撤: package=$package" >> "$TRIGGER_LOG"
        elif ui_has_expected_input "$expected_input"; then
          input_matched=1
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] 激活字符匹配，等待键盘回撤: package=$package" >> "$TRIGGER_LOG"
        fi
      fi
    elif [ "$keyboard_armed" = "1" ]; then
      hidden_samples=$((hidden_samples + 1))
      if [ "$hidden_samples" -ge 2 ]; then
        keyboard_armed=0
        hidden_samples=0
        # 某些 ROM 的 UIAutomator 快照比输入法状态慢；键盘刚隐藏时再补查一次，
        # 避免用户输入后很快回撤导致漏判。
        if [ "$input_matched" != "1" ] && [ -n "$expected_input" ] && ui_has_expected_input "$expected_input"; then
          input_matched=1
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] 回撤后补查激活字符匹配: package=$package" >> "$TRIGGER_LOG"
        fi
        if [ "$input_matched" != "1" ]; then
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] 键盘已回撤，但激活字符不匹配，本次不执行: package=$package" >> "$TRIGGER_LOG"
          input_matched=0
          sleep "$ACTIVE_INTERVAL"
          continue
        fi
        input_matched=0
        now=$(date +%s)
        elapsed=$((now - last_trigger))
        [ "$elapsed" -lt 0 ] 2>/dev/null && elapsed=$cooldown
        if [ "$elapsed" -ge "$cooldown" ] 2>/dev/null && claim_app_session keyboard_hidden; then
          last_trigger=$now
          printf '%s\n' "$last_trigger" > "$CONFIG/last_trigger"
          {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 目标应用键盘已回撤: package=$package"
            if [ -f "$script" ]; then
              export KSU_TRIGGER_TYPE="keyboard_hidden" KSU_TRIGGER_PACKAGE="$package"
              execute_script_file "$script"
              code=$?
              [ "$code" -eq 75 ] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] 已有脚本正在执行，本次跳过"
              echo "[$(date '+%Y-%m-%d %H:%M:%S')] 脚本结束，退出码: $code"
            else
              echo "脚本不存在: $script"
            fi
          } >> "$TRIGGER_LOG" 2>&1
        fi
      fi
    else
      hidden_samples=0
    fi
  else
    if [ "$target_active" = "1" ]; then
      target_active=0
      keyboard_armed=0
      hidden_samples=0
      input_matched=0
      clear_app_session_claim
    fi
  fi

  if [ "$target_active" = "1" ]; then
    sleep "$ACTIVE_INTERVAL"
  else
    sleep "$interval"
  fi
done


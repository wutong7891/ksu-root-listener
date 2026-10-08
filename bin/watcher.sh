#!/system/bin/sh

MODDIR=${0%/*}
MODDIR=${MODDIR%/*}
STATE_DIR=${KSU_WATCHER_STATE_DIR:-/data/adb/ksu_app_watcher}
CONFIG="$STATE_DIR/config"
TRIGGER_LOG="$STATE_DIR/logs/trigger.log"
PIDFILE="$STATE_DIR/watcher.pid"
SESSION_BOOTFILE="$CONFIG/session_boot_id"

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

# 前台会话只在本次开机有效，避免重启后沿用旧状态而漏掉第一次触发。
session_boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
saved_session_boot_id=$(cat "$SESSION_BOOTFILE" 2>/dev/null)
if [ -n "$session_boot_id" ] && [ "$session_boot_id" != "$saved_session_boot_id" ]; then
  rm -f "$CONFIG/last_foreground" "$CONFIG/last_trigger"
  clear_app_session_claim
  printf '%s\n' "$session_boot_id" > "$SESSION_BOOTFILE"
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] KernelSU 前台检测服务已启动，pid=$$" >> "$TRIGGER_LOG"

read_value() {
  file="$1"; fallback="$2"
  [ -f "$CONFIG/$file" ] && cat "$CONFIG/$file" 2>/dev/null || printf '%s' "$fallback"
}

away_samples=0

while true; do
  enabled=$(read_value enabled 0)
  interval=$(read_value interval 2)
  case "$interval" in ''|*[!0-9]*) interval=2 ;; esac
  [ "$interval" -ge 1 ] 2>/dev/null || interval=1
  [ "$interval" -le 60 ] 2>/dev/null || interval=60
  if [ "$enabled" != "1" ]; then sleep "$interval"; continue; fi

  package=$(read_value package '')
  script=$(read_value script "$MODDIR/scripts/target.sh")
  cooldown=$(read_value cooldown 2)
  case "$cooldown" in ''|*[!0-9]*) cooldown=2 ;; esac
  last_trigger=$(read_value last_trigger 0)
  case "$last_trigger" in ''|*[!0-9]*) last_trigger=0 ;; esac

  # 只检测前台应用切换：应用从后台进入前台时触发一次，持续停留不重复。
  foreground=$(foreground_package)
  last_foreground=$(read_value last_foreground '')
  if [ -n "$foreground" ] && [ "$foreground" = "$package" ]; then
    away_samples=0
    if [ "$foreground" != "$last_foreground" ]; then
      printf '%s\n' "$foreground" > "$CONFIG/last_foreground"
      now=$(date +%s)
      elapsed=$((now - last_trigger))
      [ "$elapsed" -lt 0 ] 2>/dev/null && elapsed=$cooldown
      if [ "$elapsed" -ge "$cooldown" ] 2>/dev/null && claim_app_session foreground; then
        last_trigger=$now
        printf '%s\n' "$last_trigger" > "$CONFIG/last_trigger"
        {
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] 应用进入前台: package=$package"
          if [ -f "$script" ]; then
            export KSU_TRIGGER_TYPE="app_foreground" KSU_TRIGGER_PACKAGE="$package"
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
  elif [ -n "$foreground" ] && [ -n "$package" ]; then
    # 系统弹窗或焦点抖动可能只持续一个采样周期；连续两次确认离开后才结束会话。
    if [ "$last_foreground" = "$package" ]; then
      away_samples=$((away_samples + 1))
      if [ "$away_samples" -ge 2 ]; then
        printf '%s\n' "$foreground" > "$CONFIG/last_foreground"
        clear_app_session_claim
        away_samples=0
      fi
    else
      printf '%s\n' "$foreground" > "$CONFIG/last_foreground"
      away_samples=0
    fi
  fi

  sleep "$interval"
done


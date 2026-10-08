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

echo "[$(date '+%Y-%m-%d %H:%M:%S')] KernelSU 输入数字检测服务已启动，pid=$$" >> "$TRIGGER_LOG"

read_value() {
  file="$1"; fallback="$2"
  [ -f "$CONFIG/$file" ] && cat "$CONFIG/$file" 2>/dev/null || printf '%s' "$fallback"
}

target_active=0
match_latched=0
empty_config_logged=0

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

  # 仅在目标应用前台检查当前获得焦点的普通输入框。内容与配置数字完全
  # 相同时立即执行，不依赖回车、确认键或键盘回撤。
  foreground=$(foreground_package)
  if [ -n "$foreground" ] && [ "$foreground" = "$package" ]; then
    if [ "$target_active" != "1" ]; then
      target_active=1
      match_latched=0
      empty_config_logged=0
      clear_app_session_claim
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] 目标应用进入前台: package=$package" >> "$TRIGGER_LOG"
    fi

    if [ -z "$expected_input" ]; then
      match_latched=0
      clear_app_session_claim
      if [ "$empty_config_logged" != "1" ]; then
        empty_config_logged=1
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 未设置激活数字，不自动执行: package=$package" >> "$TRIGGER_LOG"
      fi
    elif ui_has_expected_input "$expected_input"; then
      if [ "$match_latched" != "1" ]; then
        match_latched=1
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 激活数字匹配，立即执行: package=$package" >> "$TRIGGER_LOG"
        now=$(date +%s)
        elapsed=$((now - last_trigger))
        [ "$elapsed" -lt 0 ] 2>/dev/null && elapsed=$cooldown
        if [ "$elapsed" -ge "$cooldown" ] 2>/dev/null && claim_app_session input_match; then
          last_trigger=$now
          printf '%s\n' "$last_trigger" > "$CONFIG/last_trigger"
          {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 目标应用输入数字匹配: package=$package"
            if [ -f "$script" ]; then
              export KSU_TRIGGER_TYPE="input_match" KSU_TRIGGER_PACKAGE="$package"
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
      if [ "$match_latched" = "1" ]; then clear_app_session_claim; fi
      match_latched=0
    fi
  else
    if [ "$target_active" = "1" ]; then
      target_active=0
      match_latched=0
      empty_config_logged=0
      clear_app_session_claim
    fi
  fi

  if [ "$target_active" = "1" ]; then
    sleep "$ACTIVE_INTERVAL"
  else
    sleep "$interval"
  fi
done


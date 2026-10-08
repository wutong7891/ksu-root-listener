#!/system/bin/sh

MODDIR=${0%/*}
MODDIR=${MODDIR%/*}
STATE_DIR=${KSU_WATCHER_STATE_DIR:-/data/adb/ksu_app_watcher}
CONFIG="$STATE_DIR/config"
TRIGGER_LOG="$STATE_DIR/logs/trigger.log"
PIDFILE="$STATE_DIR/watcher.pid"
SEQFILE="$CONFIG/last_seq"
BOOTFILE="$CONFIG/last_boot_id"
SESSION_BOOTFILE="$CONFIG/session_boot_id"
SULOG_DIR="/data/adb/ksu/log"

mkdir -p "$CONFIG" "$STATE_DIR/logs"
. "$MODDIR/bin/common.sh"

if [ -f "$PIDFILE" ]; then
  old_pid=$(cat "$PIDFILE" 2>/dev/null)
  if pid_is_watcher "$old_pid" && kill -0 "$old_pid" 2>/dev/null; then exit 0; fi
  rm -f "$PIDFILE"
fi

echo $$ > "$PIDFILE"
cleanup() { release_run_lock; rm -f "$PIDFILE"; }
trap cleanup EXIT
trap 'exit 0' INT TERM

# 前台会话只在本次开机有效，避免重启后沿用旧状态而漏掉第一次触发。
session_boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
saved_session_boot_id=$(cat "$SESSION_BOOTFILE" 2>/dev/null)
if [ -n "$session_boot_id" ] && [ "$session_boot_id" != "$saved_session_boot_id" ]; then
  rm -f "$CONFIG/last_foreground" "$CONFIG/app_session_triggered" "$CONFIG/last_trigger"
  printf '%s\n' "$session_boot_id" > "$SESSION_BOOTFILE"
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] KernelSU 后台监听服务已启动，pid=$$" >> "$TRIGGER_LOG"

read_value() {
  file="$1"; fallback="$2"
  [ -f "$CONFIG/$file" ] && cat "$CONFIG/$file" 2>/dev/null || printf '%s' "$fallback"
}

package_app_id() {
  dumpsys package "$1" 2>/dev/null \
    | sed -n 's/^[[:space:]]*userId=\([0-9][0-9]*\).*/\1/p' \
    | head -n 1
}

newest_sulog() {
  ls -1t "$SULOG_DIR"/sulog-*.log 2>/dev/null | head -n 1
}

max_existing_seq() {
  latest=$(newest_sulog)
  [ -n "$latest" ] || { echo 0; return; }
  tail -n 300 "$latest" 2>/dev/null \
    | sed -n 's/.*[[:space:]]seq=\([0-9][0-9]*\).*/\1/p' \
    | tail -n 1
}

current_boot_seq() {
  latest=$(newest_sulog)
  boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
  [ -n "$latest" ] && [ -n "$boot_id" ] || return
  tail -n 2000 "$latest" 2>/dev/null | awk -v boot="$boot_id" '
    index($0, "boot_id=\"" boot "\"") { seen=1; seq=0; next }
    seen && match($0, /seq=[0-9]+/) { seq=substr($0, RSTART+4, RLENGTH-4) }
    END { if (seen) print seq+0 }
  '
}

enable_sulog() {
  status=$(ksud feature check sulog 2>/dev/null | head -n 1)
  [ "$status" = "supported" ] || return 1
  ksud feature set sulog 1 >/dev/null 2>&1 || return 1
  ksud debug sulogd >/dev/null 2>&1
}

sulog_ready=0
initialized=0

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

  # 普通打开应用并不会产生 SU 事件，因此同时监听前台应用切换。
  # 只在应用从后台进入前台时触发一次，持续停留前台不会重复执行。
  foreground=$(foreground_package)
  last_foreground=$(read_value last_foreground '')
  if [ -n "$foreground" ] && [ "$foreground" != "$last_foreground" ]; then
    manual_open_pid=$(read_value manual_open_pid '')
    if [ "$foreground" = "$package" ] && [ -n "$manual_open_pid" ] \
      && kill -0 "$manual_open_pid" 2>/dev/null \
      && tr '\000' ' ' < "/proc/$manual_open_pid/cmdline" 2>/dev/null | grep -F "$MODDIR/bin/control.sh" >/dev/null 2>&1; then
      sleep "$interval"
      continue
    fi
    printf '%s\n' "$foreground" > "$CONFIG/last_foreground"
    if [ -n "$package" ] && [ "$foreground" = "$package" ]; then
      now=$(date +%s)
      elapsed=$((now - last_trigger))
      [ "$elapsed" -lt 0 ] 2>/dev/null && elapsed=$cooldown
      if [ "$elapsed" -ge "$cooldown" ] 2>/dev/null; then
        last_trigger=$now
        printf '%s\n' "$last_trigger" > "$CONFIG/last_trigger"
        printf '1\n' > "$CONFIG/app_session_triggered"
        {
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] 应用进入前台: package=$package"
          if [ -f "$script" ]; then
            export KSU_SULOG_TYPE="app_foreground" KSU_SULOG_UID="" KSU_SULOG_PACKAGE="$package"
            export KSU_SULOG_PID="" KSU_SULOG_COMM="$package" KSU_SULOG_FILE="$script" KSU_SULOG_ARGV=""
            execute_script_file "$script"
            code=$?
            [ "$code" -eq 75 ] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] 已有脚本正在执行，本次跳过"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 脚本结束，退出码: $code"
          else
            echo "脚本不存在: $script"
          fi
        } >> "$TRIGGER_LOG" 2>&1
      fi
    else
      printf '0\n' > "$CONFIG/app_session_triggered"
    fi
  fi

  if [ "$sulog_ready" != "1" ]; then
    if enable_sulog; then sulog_ready=1; else sleep "$interval"; continue; fi
  fi

  if [ "$initialized" != "1" ]; then
    boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
    saved_boot_id=$(cat "$BOOTFILE" 2>/dev/null)
    if [ -n "$boot_id" ] && [ "$boot_id" = "$saved_boot_id" ] && [ -f "$SEQFILE" ]; then
      initialized=1
    else
      baseline=$(current_boot_seq)
      if [ -z "$baseline" ]; then sleep "$interval"; continue; fi
      printf '%s\n' "$baseline" > "$SEQFILE"
      printf '%s\n' "$boot_id" > "$BOOTFILE"
      initialized=1
    fi
  fi

  events=$(read_value events 'sucompat,ioctl_grant_root')
  target_app_id=$(package_app_id "$package")
  latest=$(newest_sulog)
  last_seq=$(cat "$SEQFILE" 2>/dev/null)
  case "$last_seq" in ''|*[!0-9]*) last_seq=0 ;; esac
  last_trigger=$(read_value last_trigger 0)
  case "$last_trigger" in ''|*[!0-9]*) last_trigger=0 ;; esac

  if [ -n "$target_app_id" ] && [ -n "$latest" ]; then
    tail -n 300 "$latest" 2>/dev/null | while IFS= read -r line; do
      seq=$(printf '%s\n' "$line" | sed -n 's/.*[[:space:]]seq=\([0-9][0-9]*\).*/\1/p')
      [ -n "$seq" ] || continue
      [ "$seq" -gt "$last_seq" ] 2>/dev/null || continue
      event_type=$(printf '%s\n' "$line" | sed -n 's/.*[[:space:]]type=\([^[:space:]]*\).*/\1/p')
      uid=$(printf '%s\n' "$line" | sed -n 's/.*[[:space:]]uid=\([0-9][0-9]*\).*/\1/p')
      [ -n "$uid" ] || continue
      app_id=$((uid % 100000))
      case ",$events," in *",$event_type,"*) ;; *) continue ;; esac
      [ "$app_id" -eq "$target_app_id" ] 2>/dev/null || continue
      # 目标应用本次进入前台时已经执行过，忽略其后续 Root 事件，避免重复。
      session_triggered=$(read_value app_session_triggered 0)
      [ "$session_triggered" = "1" ] && continue
      now=$(date +%s)
      elapsed=$((now - last_trigger))
      [ "$elapsed" -lt 0 ] 2>/dev/null && elapsed=$cooldown
      [ "$elapsed" -ge "$cooldown" ] 2>/dev/null || continue
      last_trigger=$now
      printf '%s\n' "$last_trigger" > "$CONFIG/last_trigger"
      printf '1\n' > "$CONFIG/app_session_triggered"

      comm=$(printf '%s\n' "$line" | sed -n 's/.* comm="\([^"]*\)".*/\1/p')
      file=$(printf '%s\n' "$line" | sed -n 's/.* file="\([^"]*\)".*/\1/p')
      argv=$(printf '%s\n' "$line" | sed -n 's/.* argv="\([^"]*\)".*/\1/p')
      {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Root事件: package=$package type=$event_type uid=$uid seq=$seq"
        if [ -f "$script" ]; then
          export KSU_SULOG_TYPE="$event_type" KSU_SULOG_UID="$uid" KSU_SULOG_PACKAGE="$package"
          export KSU_SULOG_PID="$(printf '%s\n' "$line" | sed -n 's/.* pid=\([0-9][0-9]*\).*/\1/p')"
          export KSU_SULOG_COMM="$comm" KSU_SULOG_FILE="$file" KSU_SULOG_ARGV="$argv"
          execute_script_file "$script"
          code=$?
          [ "$code" -eq 75 ] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] 已有脚本正在执行，本次跳过"
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] 脚本结束，退出码: $code"
        else
          echo "脚本不存在: $script"
        fi
      } >> "$TRIGGER_LOG" 2>&1
    done

    newest_seq=$(max_existing_seq)
    if [ -n "$newest_seq" ] && [ "$newest_seq" -gt "$last_seq" ] 2>/dev/null; then
      printf '%s\n' "$newest_seq" > "$SEQFILE"
    fi
  fi
  sleep "$interval"
done


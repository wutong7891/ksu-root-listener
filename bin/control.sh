#!/system/bin/sh

MODDIR=${0%/*}
MODDIR=${MODDIR%/*}
STATE_DIR=${KSU_WATCHER_STATE_DIR:-/data/adb/ksu_app_watcher}
CONFIG="$STATE_DIR/config"
TRIGGER_LOG="$STATE_DIR/logs/trigger.log"
mkdir -p "$CONFIG" "$STATE_DIR/logs"
. "$MODDIR/bin/common.sh"

read_value() { [ -f "$CONFIG/$1" ] && cat "$CONFIG/$1" 2>/dev/null || printf '%s' "$2"; }
write_value() { tmp="$CONFIG/.$1.tmp.$$"; printf '%s\n' "$2" > "$tmp" && mv -f "$tmp" "$CONFIG/$1"; }
reload_watcher() {
  pid=$(cat "$STATE_DIR/watcher.pid" 2>/dev/null)
  if pid_is_watcher "$pid" && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    tries=0
    while kill -0 "$pid" 2>/dev/null && [ "$tries" -lt 40 ]; do
      sleep 0.05
      tries=$((tries + 1))
    done
  fi
  saved_pid=$(cat "$STATE_DIR/watcher.pid" 2>/dev/null)
  [ "$saved_pid" = "$pid" ] && rm -f "$STATE_DIR/watcher.pid"
  nohup "$MODDIR/bin/watcher.sh" </dev/null >/dev/null 2>&1 &
}
case "$1" in
  status)
    echo "enabled=$(read_value enabled 0)"
    echo "package=$(read_value package com.example.app)"
    echo "script=$(read_value script "$MODDIR/scripts/target.sh")"
    echo "interval=$(read_value interval 2)"
    echo "active_interval=0.10"
    echo "discovery_interval=0.25"
    echo "events=input_match"
    echo "cooldown=$(read_value cooldown 2)"
    [ -s "$CONFIG/expected_input" ] && echo "expected_set=yes" || echo "expected_set=no"
    echo "foreground=$(foreground_package)"
    keyboard_visible && echo "keyboard=visible" || echo "keyboard=hidden"
    pid=$(cat "$STATE_DIR/watcher.pid" 2>/dev/null)
    pid_is_watcher "$pid" && kill -0 "$pid" 2>/dev/null && echo "watcher=running" || echo "watcher=stopped"
    ;;
  configure)
    package="$2"; script="$3"; interval="$4"; enabled="$5"; events="$6"; cooldown="$7"
    old_package=$(read_value package '')
    old_enabled=$(read_value enabled 0)
    case "$package" in ''|*[!A-Za-z0-9._]*) echo "包名格式不正确" >&2; exit 2 ;; esac
    case "$script" in /*) ;; *) echo "脚本路径必须是绝对路径" >&2; exit 2 ;; esac
    case "$interval" in ''|*[!0-9]*) echo "轮询间隔必须是整数" >&2; exit 2 ;; esac
    [ "$interval" -ge 1 ] && [ "$interval" -le 60 ] || { echo "轮询间隔必须在 1 到 60 秒之间" >&2; exit 2; }
    case "$enabled" in 0|1) ;; *) echo "启用值只能是 0 或 1" >&2; exit 2 ;; esac
    [ "$events" = "input_match" ] || { echo "只支持目标应用输入数字匹配触发" >&2; exit 2; }
    case "$cooldown" in ''|*[!0-9]*) echo "冷却时间必须是整数" >&2; exit 2 ;; esac
    [ "$cooldown" -le 3600 ] || { echo "冷却时间不能超过 3600 秒" >&2; exit 2; }
    write_value package "$package"; write_value script "$script"; write_value interval "$interval"
    write_value enabled "$enabled"; write_value events "$events"; write_value cooldown "$cooldown"
    if [ "$package" != "$old_package" ] || { [ "$old_enabled" != "1" ] && [ "$enabled" = "1" ]; }; then
      clear_app_session_claim
      rm -f "$CONFIG/last_trigger"
    fi
    if [ "$enabled" = "1" ]; then
      reload_watcher
    fi
    echo "配置已保存"
    ;;
  open)
    package=$(read_value package '')
    [ -n "$package" ] || { echo "尚未配置包名" >&2; exit 2; }
    monkey -p "$package" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
    code=$?
    if [ "$code" -eq 0 ]; then
      echo "已启动 $package；在普通输入框中输入配置数字即可触发脚本，无需回车"
    else
      echo "无法启动 $package" >&2
    fi
    exit "$code"
    ;;
  run)
    script=$(read_value script "$MODDIR/scripts/target.sh")
    [ -f "$script" ] || { echo "脚本不存在: $script" >&2; exit 2; }
    execute_script_file "$script"
    code=$?
    [ "$code" -eq 75 ] && echo "已有脚本正在执行，请稍后再试" >&2
    exit "$code"
    ;;
  get-preinput)
    read_value preinput ''
    ;;
  set-preinput)
    if [ -n "$2" ]; then write_value preinput "$2"; else : > "$CONFIG/preinput"; fi
    echo "预输入已保存"
    ;;
  get-expected)
    read_value expected_input ''
    ;;
  set-expected)
    [ "${#2}" -le 128 ] || { echo "激活字符不能超过 128 个字符" >&2; exit 2; }
    if [ -n "$2" ]; then
      case "$2" in *[!0-9]*) echo "激活内容只能包含数字 0-9" >&2; exit 2 ;; esac
    fi
    if [ -n "$2" ]; then write_value expected_input "$2"; else : > "$CONFIG/expected_input"; fi
    [ -n "$2" ] && echo "激活数字已保存" || echo "未设置激活数字，自动触发已关闭"
    ;;
  list-dir)
    path="$2"; case "$path" in /*) ;; *) echo "目录必须是绝对路径" >&2; exit 2 ;; esac
    [ -d "$path" ] || { echo "目录不存在: $path" >&2; exit 2; }
    find "$path" -mindepth 1 -maxdepth 1 -print 2>/dev/null | sort | head -n 500 | while IFS= read -r item; do
      [ -d "$item" ] && kind=d || kind=f
      printf '%s\t%s\n' "$kind" "$item"
    done
    ;;
  log) [ -f "$TRIGGER_LOG" ] && tail -n "${2:-120}" "$TRIGGER_LOG" || echo "暂无触发日志" ;;
  clear-log) : > "$TRIGGER_LOG"; echo "触发日志已清空" ;;
  restart)
    reload_watcher
    echo "监听器已强制重载为当前模块版本"
    ;;
  *) echo "用法: $0 {status|configure|open|run|get-preinput|set-preinput|get-expected|set-expected|list-dir|log|clear-log|restart}" >&2; exit 1 ;;
esac


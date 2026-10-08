#!/system/bin/sh

MODDIR=${0%/*}
MODDIR=${MODDIR%/*}
STATE_DIR=${KSU_WATCHER_STATE_DIR:-/data/adb/ksu_app_watcher}
CONFIG="$STATE_DIR/config"
TRIGGER_LOG="$STATE_DIR/logs/trigger.log"
SULOG_DIR="/data/adb/ksu/log"
mkdir -p "$CONFIG" "$STATE_DIR/logs"
. "$MODDIR/bin/common.sh"

read_value() { [ -f "$CONFIG/$1" ] && cat "$CONFIG/$1" 2>/dev/null || printf '%s' "$2"; }
write_value() { tmp="$CONFIG/.$1.tmp.$$"; printf '%s\n' "$2" > "$tmp" && mv -f "$tmp" "$CONFIG/$1"; }
sulog_status() { ksud feature check sulog 2>/dev/null | head -n 1; }

case "$1" in
  status)
    echo "enabled=$(read_value enabled 0)"
    echo "package=$(read_value package com.example.app)"
    echo "script=$(read_value script "$MODDIR/scripts/target.sh")"
    echo "interval=$(read_value interval 2)"
    echo "events=$(read_value events sucompat,ioctl_grant_root)"
    echo "cooldown=$(read_value cooldown 2)"
    echo "sulog=$(sulog_status)"
    echo "foreground=$(foreground_package)"
    pid=$(cat "$STATE_DIR/watcher.pid" 2>/dev/null)
    pid_is_watcher "$pid" && kill -0 "$pid" 2>/dev/null && echo "watcher=running" || echo "watcher=stopped"
    ;;
  configure)
    package="$2"; script="$3"; interval="$4"; enabled="$5"; events="$6"; cooldown="$7"
    case "$package" in ''|*[!A-Za-z0-9._]*) echo "包名格式不正确" >&2; exit 2 ;; esac
    case "$script" in /*) ;; *) echo "脚本路径必须是绝对路径" >&2; exit 2 ;; esac
    case "$interval" in ''|*[!0-9]*) echo "轮询间隔必须是整数" >&2; exit 2 ;; esac
    [ "$interval" -ge 1 ] && [ "$interval" -le 60 ] || { echo "轮询间隔必须在 1 到 60 秒之间" >&2; exit 2; }
    case "$enabled" in 0|1) ;; *) echo "启用值只能是 0 或 1" >&2; exit 2 ;; esac
    case "$events" in *root_execve*|*sucompat*|*ioctl_grant_root*) ;; *) echo "至少选择一种 Root 事件" >&2; exit 2 ;; esac
    case "$events" in *[!a-z_,]*) echo "事件列表格式不正确" >&2; exit 2 ;; esac
    case "$cooldown" in ''|*[!0-9]*) echo "冷却时间必须是整数" >&2; exit 2 ;; esac
    [ "$cooldown" -le 3600 ] || { echo "冷却时间不能超过 3600 秒" >&2; exit 2; }
    write_value package "$package"; write_value script "$script"; write_value interval "$interval"
    write_value enabled "$enabled"; write_value events "$events"; write_value cooldown "$cooldown"
    if [ "$enabled" = "1" ] && [ "$(sulog_status)" = "supported" ]; then
      ksud feature set sulog 1 >/dev/null 2>&1
      ksud feature save >/dev/null 2>&1
      ksud debug sulogd >/dev/null 2>&1
    fi
    echo "配置已保存"
    ;;
  open)
    package=$(read_value package '')
    [ -n "$package" ] || { echo "尚未配置包名" >&2; exit 2; }
    write_value manual_open_pid "$$"
    trap 'rm -f "$CONFIG/manual_open_pid"' EXIT INT TERM
    monkey -p "$package" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
    code=$?
    if [ "$code" -eq 0 ]; then
      # WebUI 主动打开时直接执行一次，并写入会话标记，避免监听器随后重复触发。
      write_value last_foreground "$package"
      write_value app_session_triggered 1
      write_value last_trigger "$(date +%s)"
      echo "已启动 $package，开始执行脚本"
      "$0" run
      code=$?
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
  list-dir)
    path="$2"; case "$path" in /*) ;; *) echo "目录必须是绝对路径" >&2; exit 2 ;; esac
    [ -d "$path" ] || { echo "目录不存在: $path" >&2; exit 2; }
    find "$path" -mindepth 1 -maxdepth 1 -print 2>/dev/null | sort | head -n 500 | while IFS= read -r item; do
      [ -d "$item" ] && kind=d || kind=f
      printf '%s\t%s\n' "$kind" "$item"
    done
    ;;
  root-log)
    latest=$(ls -1t "$SULOG_DIR"/sulog-*.log 2>/dev/null | head -n 1)
    [ -n "$latest" ] && tail -n "${2:-120}" "$latest" || echo "暂无 sulog 日志"
    ;;
  packages)
    cmd package list packages -U 2>/dev/null
    ;;
  clear-root-log)
    latest=$(ls -1t "$SULOG_DIR"/sulog-*.log 2>/dev/null | head -n 1)
    [ -n "$latest" ] || { echo "暂无 sulog 日志"; exit 0; }
    : > "$latest" && echo "Root监听日志已清空"
    ;;
  log) [ -f "$TRIGGER_LOG" ] && tail -n "${2:-120}" "$TRIGGER_LOG" || echo "暂无触发日志" ;;
  clear-log) : > "$TRIGGER_LOG"; echo "触发日志已清空" ;;
  restart)
    pid=$(cat "$STATE_DIR/watcher.pid" 2>/dev/null)
    if pid_is_watcher "$pid" && kill -0 "$pid" 2>/dev/null; then
      echo "监听器正在运行；配置会自动加载，无需重启"
    else
      rm -f "$STATE_DIR/watcher.pid"
      nohup "$MODDIR/bin/watcher.sh" </dev/null >/dev/null 2>&1 &
      echo "监听器已启动；建议重启手机以确保由 KernelSU 服务托管"
    fi
    ;;
  *) echo "用法: $0 {status|configure|open|run|get-preinput|set-preinput|list-dir|root-log|packages|clear-root-log|log|clear-log|restart}" >&2; exit 1 ;;
esac


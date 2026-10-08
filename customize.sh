#!/system/bin/sh

SKIPUNZIP=0

ui_print "- 正在安装 KSU 键盘回撤监听与 Root 控制台"
ui_print "- 默认关闭监听，请安装后进入模块 WebUI 配置"
ui_print "- 仅在目标应用前台输入配置数字后触发，无需回车"

STATE_DIR="/data/adb/ksu_app_watcher"
CONFIG="$STATE_DIR/config"
mkdir -p "$CONFIG" "$STATE_DIR/logs"

# 从早期版本的模块目录迁移配置，之后升级模块不会丢失设置。
for name in enabled package script interval events cooldown preinput expected_input; do
  if [ ! -f "$CONFIG/$name" ] && [ -f "$MODPATH/config/$name" ]; then
    cp -f "$MODPATH/config/$name" "$CONFIG/$name"
  fi
done

[ -f "$CONFIG/enabled" ] || echo 0 > "$CONFIG/enabled"
[ -f "$CONFIG/package" ] || echo com.example.app > "$CONFIG/package"
[ -f "$CONFIG/script" ] || echo "$MODPATH/scripts/target.sh" > "$CONFIG/script"
[ -f "$CONFIG/interval" ] || echo 2 > "$CONFIG/interval"
[ -f "$CONFIG/events" ] || echo input_match > "$CONFIG/events"
echo input_match > "$CONFIG/events"
[ -f "$CONFIG/cooldown" ] || echo 2 > "$CONFIG/cooldown"
[ -f "$CONFIG/preinput" ] || : > "$CONFIG/preinput"
[ -f "$CONFIG/expected_input" ] || : > "$CONFIG/expected_input"
# 新版只接受数字；升级自旧版本时清除不符合规则的旧激活内容。
expected_input=$(cat "$CONFIG/expected_input" 2>/dev/null)
case "$expected_input" in ''|*[!0-9]*) : > "$CONFIG/expected_input" ;; esac
chmod 0700 "$STATE_DIR" "$CONFIG" "$STATE_DIR/logs"
chmod 0600 "$CONFIG"/* 2>/dev/null

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm_recursive "$MODPATH/bin" 0 0 0755 0755
set_perm_recursive "$MODPATH/scripts" 0 0 0755 0755

# 升级时结束旧版本监听器。旧守护器或新版 WebUI 会自动启动当前文件，
# 避免必须重启手机才能从旧逻辑切换到新逻辑。
old_pid=$(cat "$STATE_DIR/watcher.pid" 2>/dev/null)
if [ -n "$old_pid" ] && [ -r "/proc/$old_pid/cmdline" ]; then
  tr '\000' ' ' < "/proc/$old_pid/cmdline" 2>/dev/null | grep -F '/bin/watcher.sh' >/dev/null 2>&1 && kill "$old_pid" 2>/dev/null
fi


#!/system/bin/sh

pid_is_watcher() {
  pid="$1"
  [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ] || return 1
  tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -F "$MODDIR/bin/watcher.sh" >/dev/null 2>&1
}

acquire_watcher_lock() {
  WATCHER_LOCK="$STATE_DIR/watcher.lock"
  if mkdir "$WATCHER_LOCK" 2>/dev/null; then
    printf '%s\n' "$$" > "$WATCHER_LOCK/pid"
    return 0
  fi
  owner=$(cat "$WATCHER_LOCK/pid" 2>/dev/null)
  if pid_is_watcher "$owner" && kill -0 "$owner" 2>/dev/null; then return 1; fi
  stale_lock="$WATCHER_LOCK.stale.$$"
  mv "$WATCHER_LOCK" "$stale_lock" 2>/dev/null || return 1
  rm -f "$stale_lock/pid"
  rmdir "$stale_lock" 2>/dev/null || return 1
  mkdir "$WATCHER_LOCK" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$WATCHER_LOCK/pid"
}

release_watcher_lock() {
  WATCHER_LOCK="$STATE_DIR/watcher.lock"
  owner=$(cat "$WATCHER_LOCK/pid" 2>/dev/null)
  [ "$owner" = "$$" ] || return 0
  rm -f "$WATCHER_LOCK/pid"
  rmdir "$WATCHER_LOCK" 2>/dev/null
}

# 使用 mkdir 的原子性认领一次前台会话，避免多个监听进程重复执行。
claim_app_session() {
  claim_source="$1"
  SESSION_CLAIM="$STATE_DIR/app_session.claim"
  mkdir "$SESSION_CLAIM" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$SESSION_CLAIM/pid"
  printf '%s\n' "$claim_source" > "$SESSION_CLAIM/source"
  printf '1\n' > "$CONFIG/app_session_triggered"
}

clear_app_session_claim() {
  SESSION_CLAIM="$STATE_DIR/app_session.claim"
  rm -f "$SESSION_CLAIM/pid" "$SESSION_CLAIM/source"
  rmdir "$SESSION_CLAIM" 2>/dev/null || true
  printf '0\n' > "$CONFIG/app_session_triggered"
}

acquire_run_lock() {
  RUN_LOCK="$STATE_DIR/run.lock"
  if mkdir "$RUN_LOCK" 2>/dev/null; then
    printf '%s\n' "$$" > "$RUN_LOCK/pid"
    return 0
  fi
  owner=$(cat "$RUN_LOCK/pid" 2>/dev/null)
  if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then return 1; fi
  stale_lock="$RUN_LOCK.stale.$$"
  mv "$RUN_LOCK" "$stale_lock" 2>/dev/null || return 1
  rm -f "$stale_lock/pid"
  rmdir "$stale_lock" 2>/dev/null || return 1
  mkdir "$RUN_LOCK" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$RUN_LOCK/pid"
}

release_run_lock() {
  RUN_LOCK="$STATE_DIR/run.lock"
  owner=$(cat "$RUN_LOCK/pid" 2>/dev/null)
  [ "$owner" = "$$" ] || return 0
  rm -f "$RUN_LOCK/pid"
  rmdir "$RUN_LOCK" 2>/dev/null
}

execute_script_file() {
  target_script="$1"
  acquire_run_lock || return 75
  if [ -s "$CONFIG/preinput" ]; then
    (cd / && sh "$target_script") < "$CONFIG/preinput"
  else
    (cd / && sh "$target_script")
  fi
  script_code=$?
  release_run_lock
  return "$script_code"
}

foreground_package() {
  pkg=$(dumpsys activity activities 2>/dev/null \
    | sed -n -e '/mResumedActivity/s/.*[[:space:]]u[0-9][0-9]*[[:space:]]\([A-Za-z0-9._]*\)\/.*/\1/p' \
             -e '/topResumedActivity/s/.*[[:space:]]u[0-9][0-9]*[[:space:]]\([A-Za-z0-9._]*\)\/.*/\1/p' \
    | head -n 1)
  if [ -z "$pkg" ]; then
    pkg=$(dumpsys activity top 2>/dev/null \
      | sed -n 's/^[[:space:]]*ACTIVITY[[:space:]]\([A-Za-z0-9._]*\)\/.*/\1/p' \
      | head -n 1)
  fi
  if [ -z "$pkg" ]; then
    pkg=$(dumpsys window windows 2>/dev/null \
      | sed -n -e '/mCurrentFocus=/s/.*[[:space:]]\([A-Za-z0-9._]*\)\/[^[:space:]]*.*/\1/p' \
               -e '/mFocusedApp=/s/.*[[:space:]]u[0-9][0-9]*[[:space:]]\([A-Za-z0-9._]*\)\/.*/\1/p' \
      | head -n 1)
  fi
  printf '%s' "$pkg"
}

# 同时兼容多代 Android 的输入法可见状态字段。只把明确的 visible=true
# 或 IME window visible 标志视为键盘已显示，避免 mShowRequested 的残留状态误报。
keyboard_visible() {
  input_state=$(dumpsys input_method 2>/dev/null)
  printf '%s\n' "$input_state" | grep -Eq \
    'mInputShown=true|mIsInputViewShown=true|isInputViewShown=true|mImeWindowVis=0x0*2([^0-9A-Fa-f]|$)|mImeWindowVis=0x0*3([^0-9A-Fa-f]|$)' \
    && return 0

  window_state=$(dumpsys window windows 2>/dev/null)
  printf '%s\n' "$window_state" | grep -Eq \
    'mImeWindowVis=0x0*2([^0-9A-Fa-f]|$)|mImeWindowVis=0x0*3([^0-9A-Fa-f]|$)' \
    && return 0

  dumpsys window insets 2>/dev/null | awk '
    BEGIN { ime = 0; distance = 0; visible = 0; server = 0; client = 0 }
    /type=ime|mType=ime/ { ime = 1; distance = 0 }
    ime && /visible=true|mVisible=true/ { visible = 1; exit }
    ime && /mServerVisible=true/ { server = 1 }
    ime && /mClientVisible=true/ { client = 1 }
    ime { distance++; if (distance > 8) ime = 0 }
    END { exit (visible || (server && client)) ? 0 : 1 }
  '
}

# 使用 Root UIAutomator 层级只核对目标输入框是否等于配置值。
# 不返回、不记录实际输入，并明确排除 password=true 的输入框。
ui_has_expected_input() {
  expected="$1"
  [ -n "$expected" ] || return 1
  xml_expected=$(printf '%s' "$expected" | sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\\\&apos;/g")
  # --compressed 明显缩短部分 ROM 等待界面空闲的时间。限制单次快照时长，
  # 防止系统 UIAutomator 异常时卡死整个常驻监听器。
  if command -v timeout >/dev/null 2>&1; then
    timeout 2 uiautomator dump --compressed /proc/self/fd/1 2>/dev/null
  else
    uiautomator dump --compressed /proc/self/fd/1 2>/dev/null
  fi | awk -v expected="$xml_expected" '
    BEGIN { RS = "<node"; matched = 0 }
    index($0, "editable=\"true\"") &&
    index($0, "focused=\"true\"") &&
    index($0, "password=\"false\"") &&
    index($0, "text=\"" expected "\"") { matched = 1; exit }
    END { exit matched ? 0 : 1 }
  '
}

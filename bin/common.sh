#!/system/bin/sh

pid_is_watcher() {
  pid="$1"
  [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ] || return 1
  tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -F "$MODDIR/bin/watcher.sh" >/dev/null 2>&1
}

acquire_run_lock() {
  RUN_LOCK="$STATE_DIR/run.lock"
  if mkdir "$RUN_LOCK" 2>/dev/null; then
    printf '%s\n' "$$" > "$RUN_LOCK/pid"
    return 0
  fi
  owner=$(cat "$RUN_LOCK/pid" 2>/dev/null)
  if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then return 1; fi
  rm -rf "$RUN_LOCK"
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

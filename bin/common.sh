#!/system/bin/sh

pid_is_watcher() {
  pid="$1"
  [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ] || return 1
  tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -F "$MODDIR/bin/watcher.sh" >/dev/null 2>&1
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

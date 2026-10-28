#!/bin/zsh
set -eu
set -o pipefail
FOCUS_ROOT="$(cd -- "$(dirname -- "$0")" && pwd -P)"
/bin/zsh "$FOCUS_ROOT/check.command"
source "$FOCUS_ROOT/script-common.zsh"
focus_guard_outputs
if [[ $# -gt 1 ]]; then print -u2 '用法：zsh build.command [arm64|x86_64]'; exit 1; fi
if [[ $# == 1 ]]; then
  FOCUS_ARCH="$1"
  FOCUS_DIST="$FOCUS_ROOT/dist/$FOCUS_ARCH"
else
  if [[ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || true)" == 1 ]]; then
    FOCUS_ARCH=arm64
  else
    FOCUS_ARCH=x86_64
  fi
  FOCUS_DIST="$FOCUS_ROOT/dist"
fi
if [[ "$FOCUS_ARCH" != arm64 && "$FOCUS_ARCH" != x86_64 ]]; then
  print -u2 '只支持arm64（苹果芯片）或x86_64（英特尔芯片）。'
  exit 1
fi
FOCUS_APP="$FOCUS_DIST/专注小闹钟.app"
if [[ -f "$FOCUS_APP/Contents/MacOS/FocusClock" ]] && /usr/sbin/lsof "$FOCUS_APP/Contents/MacOS/FocusClock" >/dev/null 2>&1; then
  print -u2 '这个输出目录中的专注小闹钟正在运行。请通过工具自身“退出”后重新构建。'
  exit 1
fi
FOCUS_STAGE="$FOCUS_ROOT/.build/app-$FOCUS_ARCH/专注小闹钟.app"
mkdir -p "$FOCUS_ROOT/.build/module-cache" "$FOCUS_STAGE/Contents/MacOS" "$FOCUS_DIST"
/usr/bin/xcrun swiftc -swift-version 5 -O -target "$FOCUS_ARCH-apple-macosx13.0" \
  -module-cache-path "$FOCUS_ROOT/.build/module-cache" -framework AppKit \
  "$FOCUS_ROOT/WindowPlacement.swift" "$FOCUS_ROOT/TimerCore.swift" "$FOCUS_ROOT/FocusHistory.swift" \
  "$FOCUS_ROOT/FocusAnalytics.swift" "$FOCUS_ROOT/FocusDashboardViewController.swift" \
  "$FOCUS_ROOT/ReminderController.swift" "$FOCUS_ROOT/ReminderSettingsViewController.swift" \
  "$FOCUS_ROOT/AppMain.swift" -o "$FOCUS_STAGE/Contents/MacOS/FocusClock"
/bin/cat > "$FOCUS_STAGE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>FocusClock</string>
<key>CFBundleIdentifier</key><string>io.github.focusclock.local</string>
<key>CFBundleName</key><string>专注小闹钟</string>
<key>CFBundleDisplayName</key><string>专注小闹钟</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>LSMultipleInstancesProhibited</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$FOCUS_STAGE/Contents/Info.plist"
/usr/bin/codesign --force --sign - --timestamp=none "$FOCUS_STAGE"
/usr/bin/codesign --verify --strict "$FOCUS_STAGE"
# Replace this project's previous build only after a successful compilation.
if [[ -d "$FOCUS_APP" ]]; then /bin/rm -rf -- "$FOCUS_APP"; fi
/bin/mv -- "$FOCUS_STAGE" "$FOCUS_APP"
print "构建完成（$FOCUS_ARCH）：$FOCUS_APP"
print '尚未自动启动。打开此.app后，点击顶部闹钟查看控制面板，▶开始、Ⅱ暂停，“累计”打开专注记录。'

#!/bin/zsh
set -eu
set -o pipefail
FOCUS_ROOT="$(cd -- "$(dirname -- "$0")" && pwd -P)"
/bin/zsh "$FOCUS_ROOT/check.command"
source "$FOCUS_ROOT/script-common.zsh"
focus_guard_outputs
mkdir -p "$FOCUS_ROOT/.build/module-cache"
for FOCUS_SUITE in TimerCore FocusHistory FocusAnalytics Reminder WindowPlacement AudioLibrary MusicSelection BundledMusic; do
  FOCUS_SOURCES=()
  case "$FOCUS_SUITE" in
    TimerCore) FOCUS_SOURCES=(TimerCore.swift TimerCoreTests.swift) ;;
    FocusHistory) FOCUS_SOURCES=(FocusHistory.swift FocusHistoryTests.swift) ;;
    FocusAnalytics) FOCUS_SOURCES=(FocusHistory.swift FocusAnalytics.swift FocusAnalyticsTests.swift) ;;
    Reminder) FOCUS_SOURCES=(ReminderController.swift ReminderTests.swift) ;;
    WindowPlacement) FOCUS_SOURCES=(WindowPlacement.swift WindowPlacementTests.swift) ;;
    AudioLibrary) FOCUS_SOURCES=(AudioLibrary.swift AudioLibraryTests.swift) ;;
    MusicSelection) FOCUS_SOURCES=(AudioLibrary.swift FocusMusicController.swift PlaylistImportSelection.swift MusicSelectionTests.swift) ;;
    BundledMusic) FOCUS_SOURCES=(AudioLibrary.swift BundledMusic.swift BundledMusicTests.swift) ;;
  esac
  FOCUS_PATHS=()
  for FOCUS_FILE in "${FOCUS_SOURCES[@]}"; do FOCUS_PATHS+=("$FOCUS_ROOT/$FOCUS_FILE"); done
  /usr/bin/xcrun swiftc -swift-version 5 -module-cache-path "$FOCUS_ROOT/.build/module-cache" -framework AppKit -framework AVFoundation \
    "${FOCUS_PATHS[@]}" -o "$FOCUS_ROOT/.build/${FOCUS_SUITE}Tests"
  "$FOCUS_ROOT/.build/${FOCUS_SUITE}Tests"
done
print '全部自动测试通过；硬件声音、鼠标操作和其他Mac仍需各自实测。'

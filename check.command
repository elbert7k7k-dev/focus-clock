#!/bin/zsh
set -eu
set -o pipefail
if [[ "$(/usr/bin/uname -s)" != Darwin ]]; then
  print -u2 '需要Mac和macOS 13或以上；云端Linux或Windows不能构建此原生应用。'
  exit 1
fi
FOCUS_OS_VERSION="$(/usr/bin/sw_vers -productVersion)"
if (( ${FOCUS_OS_VERSION%%.*} < 13 )); then
  print -u2 '需要macOS 13或以上。'
  exit 1
fi
if ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1; then
  print -u2 '缺少Apple Command Line Tools（苹果命令行开发工具）的Swift编译器。请由本人安装后重试；本脚本不自动安装。'
  exit 1
fi
FOCUS_SWIFT_INFO="$(/usr/bin/xcrun swiftc --version 2>&1)"
FOCUS_SWIFT_VERSION="$(print -r -- "$FOCUS_SWIFT_INFO" | /usr/bin/sed -nE 's/.*Swift version ([0-9]+\.[0-9]+).*/\1/p' | /usr/bin/head -n 1)"
if [[ -z "$FOCUS_SWIFT_VERSION" ]]; then
  print -u2 '无法识别Swift版本；需要Swift 5.9或以上。'
  exit 1
fi
FOCUS_SWIFT_MAJOR="${FOCUS_SWIFT_VERSION%%.*}"
FOCUS_SWIFT_MINOR="${FOCUS_SWIFT_VERSION#*.}"
if (( FOCUS_SWIFT_MAJOR < 5 || (FOCUS_SWIFT_MAJOR == 5 && FOCUS_SWIFT_MINOR < 9) )); then
  print -u2 '需要Swift 5.9或以上；请由本人更新开发工具。'
  exit 1
fi
/usr/bin/xcrun --sdk macosx --show-sdk-path >/dev/null
print "环境检查通过：macOS $FOCUS_OS_VERSION；Swift $FOCUS_SWIFT_VERSION；$(/usr/bin/uname -m)。"
print '仅检查现有环境；未安装软件，未修改系统设置。'

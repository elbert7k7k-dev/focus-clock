# Shared output-directory guard. No commands are run merely by sourcing this file.
focus_guard_outputs() {
  local focus_output_name focus_output_path focus_link
  for focus_output_name in .build dist; do
    focus_output_path="$FOCUS_ROOT/$focus_output_name"
    if [[ -L "$focus_output_path" ]]; then
      print -u2 "拒绝写入：输出目录是符号链接：$focus_output_path"
      return 1
    fi
    if [[ -e "$focus_output_path" && ! -d "$focus_output_path" ]]; then
      print -u2 "拒绝写入：输出路径不是目录：$focus_output_path"
      return 1
    fi
    if [[ -d "$focus_output_path" ]]; then
      focus_link="$(/usr/bin/find -P "$focus_output_path" -type l -print -quit)"
      if [[ -n "$focus_link" ]]; then
        print -u2 "拒绝写入：输出目录中存在符号链接，请由本人处理：$focus_link"
        return 1
      fi
    fi
  done
}

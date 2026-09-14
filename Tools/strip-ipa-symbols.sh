#!/bin/sh
# strip-ipa-symbols.sh — release 交付包的符号剥离（Bazel 之后、隐私消毒之前/之后皆可）。
#
# 为什么在 Bazel 之外做：-c opt 的 Swift 编译已经是 -O -whole-module-optimization
# -internalize-at-link，但链接产物默认带符号表（15.7MB 里 ~8MB 是本地符号 +
# 4.6MB 字符串表，实测 22 万个符号）。Bazel 的对应开关
# --objc_enable_binary_stripping 在 Bazel 7.4.0 + rules_apple 4.5.3 下 analysis 期
# 直接 NPE（Java 要取原生隐式属性 :xcode_config，rules_apple 声明的是 _xcode_config）；
# 链接期 -Wl,-x 对 private-extern 符号无效。Xcode Release 的等效动作就是链接后
# strip（STRIP_STYLE=Non-Global）——dSYM 不受影响：Bazel 已用未剥离产物生成 dSYM，
# 这里只处理交付副本（本脚本会破坏代码签名，与现有隐私消毒同一条口径）。
#
# 用法：Tools/strip-ipa-symbols.sh <in.ipa> <out.ipa>
set -eu

in_ipa="$1"
out_ipa="$2"
# Bazel genrule 传进来的是相对 execroot 的路径，而下面要 cd 进临时目录 → 先取绝对路径。
case "$in_ipa" in /*) ;; *) in_ipa="$PWD/$in_ipa" ;; esac
case "$out_ipa" in /*) ;; *) out_ipa="$PWD/$out_ipa" ;; esac
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

unzip -q "$in_ipa" -d "$tmp"

# 只剥 Mach-O（主二进制、PlugIns/*.appex、Frameworks/*）：-x 去本地符号，保留动态
# 链接需要的全局符号（与 Xcode 的 Non-Global 档一致；-s 更狠但没必要）。
find "$tmp/Payload" -type f -print0 | while IFS= read -r -d '' file; do
  case "$(file -b "$file")" in
    Mach-O*) xcrun strip -x "$file" ;;
  esac
done

( cd "$tmp" && zip -qry "$out_ipa" Payload )
echo "stripped: $out_ipa ($(wc -c <"$out_ipa" | tr -d ' ') bytes)"

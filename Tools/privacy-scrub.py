#!/usr/bin/env python3
"""
privacy-scrub.py — 打包步隐私消毒（必须最后执行）。

背景：即使编译期已用 -ffile-prefix-map 重映射源码路径，Hermes 字节码
仍会记录 bundle 中间产物的绝对路径（DerivedData 下的构建机路径，
含 macOS 用户名）。本脚本把 .app 内所有文件中出现的应用根绝对路径
做「等长」替换（不破坏 Mach-O 段偏移与 Hermes 字节码字符串表布局）。

用法：python3 ios/privacy-scrub.py <Path/To/tiebalite.app> [build_root]
  build_root 缺省 = 本脚本所在目录的上级（即仓库根）。
替换值：等长的 '/Users/builder' + '0' 填充，保留可读性且无个人信息。
"""

import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: privacy-scrub.py <app_dir> [build_root]", file=sys.stderr)
        return 2
    app_dir = Path(sys.argv[1])
    root = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(__file__).resolve().parent.parent
    needle = str(root).encode()
    # 等长替换：/Users/builder000...（长度与 build_root 完全一致）
    base = b"/Users/builder"
    repl = base + b"0" * (len(needle) - len(base))
    assert len(repl) == len(needle), "replacement must be equal length"

    total = 0
    touched = []
    for f in sorted(app_dir.rglob("*")):
        if not f.is_file():
            continue
        data = f.read_bytes()
        n = data.count(needle)
        if n == 0:
            continue
        f.write_bytes(data.replace(needle, repl))
        total += n
        touched.append(str(f.relative_to(app_dir)))

    for t in touched:
        print(f"scrubbed: {t}")
    print(f"privacy-scrub: replaced {total} occurrence(s) of build root")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

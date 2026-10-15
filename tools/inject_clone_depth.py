#!/usr/bin/env python3
"""给 repo manifest 的每个 <project> 注入 clone-depth="1"。

为什么必须这么做
----------------
repo sync 没有 --depth 参数（实测：main.py: error: no such option: --depth）。
深度控制写在 manifest 里，而且：

  clone-depth 是 <project> 的属性，不是 <default> 的。
  依据：manifest_xml.py 第 1963 行 `clone_depth = XmlInt(node, "clone-depth")`
        位于 _ParseProject() 内部；_Default 类的属性列表里没有 clone_depth。

官方 manifest 不带 clone-depth = 全量克隆。本机型 30 个 CodeLinaro 仓库
含完整历史约 25.9 GiB，GitHub runner 只有约 25 GB，必然写满磁盘
（实测报错：System.IO.IOException: No space left on device）。
浅克隆后工作树约 3.9 GiB。

用法: inject_clone_depth.py <manifest.xml>
退出码: 0 成功；非 0 表示注入不完整或 XML 非法（调用方应据此中止）
"""
import re
import sys
import xml.etree.ElementTree as ET


def add_depth(match: "re.Match") -> str:
    tag = match.group(0)
    if "clone-depth" in tag:
        return tag
    if tag.endswith("/>"):
        return tag[:-2].rstrip() + ' clone-depth="1" />'
    return tag[:-1].rstrip() + ' clone-depth="1">'


def main() -> int:
    if len(sys.argv) != 2:
        print("用法: %s <manifest.xml>" % sys.argv[0])
        return 2
    path = sys.argv[1]

    src = open(path, encoding="utf-8").read()
    n_proj = len(re.findall(r"<project\b", src))
    n_before = src.count("clone-depth")

    out = re.sub(r"<project\b[^>]*?/?>", add_depth, src, flags=re.S)
    n_after = out.count("clone-depth")

    open(path, "w", encoding="utf-8").write(out)
    print("  project=%d  clone-depth: %d -> %d" % (n_proj, n_before, n_after))

    # 注入完整性检查
    if n_after < n_proj:
        print("::error::clone-depth 注入不完整（%d/%d）" % (n_after, n_proj))
        return 1

    # XML 合法性检查
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as e:
        print("::error::注入后 XML 非法: %s" % e)
        return 1

    projs = root.findall("project")
    ok = sum(1 for p in projs if p.get("clone-depth") == "1")
    print("  XML 合法；project=%d，带 clone-depth=1 的=%d" % (len(projs), ok))
    if ok < len(projs):
        print("::error::仍有 project 未注入 clone-depth")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

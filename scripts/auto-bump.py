#!/usr/bin/env python3
"""自动同步上游之后，递增模块版本并回写所有需要保持一致的文件。

由 .github/workflows/upstream-sync.yml 在「上游有新版本 + 构建校验通过」之后调用。
只在真正同步新版本时调用一次；重复调用会继续 +1，所以工作流每次从干净 checkout 起跑。

做的事：
  1. module/module.prop : version x.y.Z -> x.y.(Z+1)，versionCode +1
  2. update.json        : version / versionCode 同步，zipUrl 指向新 tag 的增量包
  3. upstream.version   : 记录本次同步到的上游版本
  4. CHANGELOG.md       : 顶部插入 `## v<新版本>` 段落（正文用上游 release 说明）

用法：
  python3 scripts/auto-bump.py --upstream 2.7.4 [--body-file /tmp/up.md] [--root .]
成功时把新版本号（不带 v）打印到 stdout，供工作流打 tag。
"""
import argparse
import json
import os
import re
import sys


def _die(msg):
    sys.stderr.write(msg + "\n")
    raise SystemExit(1)


def _strip_install_section(text: str) -> str:
    """去掉上游说明里的「安装」小节。

    上游 release 正文里的安装方式是给 npm 插件用户看的（dsh plugin add ...），
    与本模块「刷 zip + 重启」完全无关，原样搬进模块更新日志只会误导。
    按标题层级整段移除：从「安装」标题开始，到下一个同级或更高级标题为止。
    """
    out = []
    skip_level = None
    for line in text.splitlines():
        m = re.match(r"^(#{1,6})\s+(.*)$", line)
        if skip_level is not None:
            if m and len(m.group(1)) <= skip_level:
                skip_level = None
            else:
                continue
        if m and "安装" in m.group(2):
            skip_level = len(m.group(1))
            continue
        out.append(line)
    return "\n".join(out)


def _format_upstream_body(body: str, upstream: str) -> str:
    """把上游 release 正文整理成可安全嵌入模块 CHANGELOG 的段落。

    上游正文通常自带 `## v2.8.5` 与多个 `### ...`。若原样插入，这些 `##`
    与模块版本标题同级，changelog-section.py 会在下一个 `##` 处截断，
    导致 Release 说明只剩第一句（v0.6.2 就踩过这个坑）。

    处理：去掉与上游版本重复的标题 → 去掉「安装」小节 → 所有标题降一级，
    让它们成为 `### 上游 vX.Y.Z 的更新` 的子标题。
    """
    body = body.strip()
    if not body:
        return f"上游服务更新到 v{upstream}。"

    lines = body.splitlines()
    # 去掉开头的 `## v2.8.5` / `# 2.8.5 ...` 这类标题（内容保留下面的小节）
    for i, line in enumerate(lines):
        if not line.strip():
            continue
        m = re.match(r"^#{1,3}\s+v?" + re.escape(upstream) + r"\b.*$", line, re.IGNORECASE)
        if m:
            del lines[i]
        break
    body = "\n".join(lines)

    body = _strip_install_section(body)

    # 标题降一级；只降 1~5 级，避免出现七级标题
    body = "\n".join(
        ("#" + line if re.match(r"^#{1,5}\s", line) else line)
        for line in body.splitlines()
    )
    return body.strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--upstream", required=True, help="本次同步到的上游版本，如 2.7.4")
    ap.add_argument("--body-file", help="上游 release 正文文件（可选，作为 CHANGELOG 段落正文）")
    ap.add_argument("--root", default=".", help="仓库根目录")
    args = ap.parse_args()

    root = args.root
    prop_path = os.path.join(root, "module/module.prop")
    update_path = os.path.join(root, "update.json")
    upstream_path = os.path.join(root, "upstream.version")
    changelog_path = os.path.join(root, "CHANGELOG.md")

    for p in (prop_path, update_path, changelog_path):
        if not os.path.isfile(p):
            _die(f"找不到文件：{p}")

    with open(prop_path, encoding="utf-8") as f:
        lines = f.read().splitlines()

    def get_key(key):
        for i, line in enumerate(lines):
            if line.startswith(key + "="):
                return i, line[len(key) + 1:]
        _die(f"module.prop 缺少键：{key}")

    vi, ver = get_key("version")
    ci, code = get_key("versionCode")

    parts = ver.split(".")
    if len(parts) != 3 or not all(p.isdigit() for p in parts):
        _die(f"version 不是 x.y.z 形式：{ver}")
    newver = f"{parts[0]}.{parts[1]}.{int(parts[2]) + 1}"
    newcode = str(int(code) + 1)

    # 与 update.json 当前一致性做一次前置校验，避免在已经错乱的状态上继续 bump
    with open(update_path, encoding="utf-8") as f:
        upd = json.load(f)
    jver = str(upd.get("version", "")).lstrip("vV")
    jcode = str(upd.get("versionCode", ""))
    if jver != ver or jcode != code:
        _die(f"module.prop({ver}/{code}) 与 update.json({jver}/{jcode}) 不一致，先修好再同步")

    # 1) module.prop
    lines[vi] = f"version={newver}"
    lines[ci] = f"versionCode={newcode}"
    with open(prop_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

    # 2) update.json —— zipUrl 指向新 tag 的增量包（沿用旧的 repo 前缀）
    old_url = str(upd.get("zipUrl", ""))
    if "/releases/download/" in old_url:
        base = old_url.rsplit("/releases/download/", 1)[0]
    else:
        base = "https://github.com/Cooldyein/ofm-gateway-magisk"
    upd["version"] = "v" + newver
    upd["versionCode"] = int(newcode)
    upd["zipUrl"] = f"{base}/releases/download/v{newver}/OFM_Gateway_Magisk_v{newver}_patch.zip"
    with open(update_path, "w", encoding="utf-8") as f:
        json.dump(upd, f, ensure_ascii=False, indent=2)
        f.write("\n")

    # 3) upstream.version
    with open(upstream_path, "w", encoding="utf-8") as f:
        f.write(args.upstream.strip() + "\n")

    # 4) CHANGELOG.md —— 标题行之后插入新段落
    body = ""
    if args.body_file and os.path.isfile(args.body_file):
        with open(args.body_file, encoding="utf-8") as f:
            body = f.read().strip()
    body = _format_upstream_body(body, args.upstream)
    section = (
        f"## v{newver}\n\n"
        f"**同步上游到 {args.upstream}。**\n\n"
        f"### 上游 v{args.upstream} 的更新\n\n"
        f"{body}\n\n"
        f"> 本版由「上游同步」工作流自动生成：服务代码取自上游 v{args.upstream}；"
        f"构建期补丁（`developer` 角色兼容）已通过锚点与 import 图校验。\n\n"
    )
    with open(changelog_path, encoding="utf-8") as f:
        text = f.read()
    m = re.match(r"^(#[^\n]*\n+)", text)
    if m:
        text = m.group(1) + section + text[m.end():]
    else:
        text = section + text
    with open(changelog_path, "w", encoding="utf-8") as f:
        f.write(text)

    sys.stdout.write(newver + "\n")


if __name__ == "__main__":
    main()

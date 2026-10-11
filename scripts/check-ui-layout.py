#!/usr/bin/env python3
"""UI 布局自查：找「内容宽行会被外层 Column 居中」的隐患（防回归）。

背景（2026-10-11 连爆三处）：ArkUI 的 Column 默认子级水平居中；Row 不写宽度时
按内容宽渲染——按钮行/chips 行/开关行会漂在区块中间（磁盘分配、磁盘来源、
光盘按钮行、存储页按钮行实测踩过）。修复方式：行上加 .width('100%')。

本脚本扫 pages/ 与 lib/ 下所有 Row 构造块，列出「既无 width('100%')、也无
layoutWeight 子元素」的行，供人工复核。豁免规则（自动）：
  1. 块链式段带 .position( —— 悬浮层行，位置由 position 决定，不受居中影响
  2. 块链式段带 .layoutWeight( —— 该 Row 本身是更外层 Row 的均分格
  3. 块前 6 行内出现 Flex( —— Flex wrap 的子行，随 Flex 左对齐
  4. 块首行或前 2 行注释含 "ui-layout-ok" —— 有意居中/特殊布局，逐处标注理由

用法：
  scripts/check-ui-layout.py            # 列清单，恒 0 退出（人工复核用）
  scripts/check-ui-layout.py --strict   # 有未豁免项则非零退出（交付/CI 用）
"""

import re
import sys
import glob

ROOT = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith('-') else '.'


def chain_tail(lines, close_idx):
    """从闭合行开始，收集同行 } 之后的链式与后续以 . 开头的行（跳过注释行）。"""
    tail = []
    s = lines[close_idx]
    pos = s.rfind('}')
    if pos >= 0:
        tail.append(s[pos + 1:])
    k = close_idx + 1
    while k < len(lines):
        if re.match(r'^\s*\.', lines[k]):
            tail.append(lines[k])
            k += 1
        elif re.match(r'^\s*(/\*.*\*/\s*)?$', lines[k]) or lines[k].strip().startswith(('/*', '//')):
            k += 1  # 链式中间的注释行不阻断
        else:
            break
    return '\n'.join(tail)


def scan(path):
    lines = open(path, encoding='utf-8').readlines()
    out = []
    for i, line in enumerate(lines):
        m = re.match(r'^(\s*)Row\((\)|\{[^)]*\}\))', line)
        if not m:
            continue
        # 花括号配平找闭合行（含同行链式）
        depth = 1
        j = i + 1
        has_sizing = ".width('100%')" in line
        while j < len(lines):
            s = lines[j]
            depth += s.count('{') - s.count('}')
            # 注意：块内子元素的 .layoutWeight 不算"行有宽度"——行无宽度时
            # layoutWeight 无扩展空间（VmEdit「从光盘启动」行实测：Toggle 不贴右）
            if ".width('100%')" in s:
                has_sizing = True
            if depth <= 0:
                break
            j += 1
        tail = chain_tail(lines, j)
        if ".width('100%')" in tail:
            has_sizing = True
        if has_sizing:
            continue
        # 豁免 1/2：行自身是悬浮层（position 定位于屏幕）或外层 Row 的均分格
        if '.position(' in tail or '.layoutWeight(' in tail:
            continue
        # 豁免 4：注释标记
        ctx = ''.join(lines[max(0, i - 2):i + 1])
        if 'ui-layout-ok' in ctx:
            continue
        # 豁免 3：Flex wrap 子行（向上找 Flex；ForEach/Row 是循环或兄弟行，穿过；
        # Column/Stack 才是对齐决定者，遇到即停）
        flex = False
        for k in range(i - 1, max(-1, i - 7), -1):
            s = lines[k].strip()
            if s.startswith(('Flex(', 'Flex()')):
                flex = True
                break
            if s.startswith(('Column(', 'Column()', 'Stack(', 'Stack()')):
                break
        if flex:
            continue
        out.append(i + 1)
    return out


def main():
    total = 0
    for path in sorted(glob.glob(f'{ROOT}/entry/src/main/ets/pages/*.ets')
                       + glob.glob(f'{ROOT}/entry/src/main/ets/lib/*.ets')):
        hits = scan(path)
        for ln in hits:
            print(f'{path}:{ln}: Row 无 width/layoutWeight —— 内容宽行会被 Column 居中')
        total += len(hits)
    if total == 0:
        print('ui-layout check: OK（无未豁免的内容宽行）')
        return 0
    print(f'--- 共 {total} 处待复核（确为有意居中：行前加 `// ui-layout-ok: 理由`）---')
    return 1 if '--strict' in sys.argv else 0


if __name__ == '__main__':
    sys.exit(main())

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
课晓 - 教务系统课表 docx 解析脚本
================================
把教务系统导出的 Word 课表 (.docx) 解析成结构化 JSON，供 "课晓" App 导入。

用法:
    python3 parse_schedule.py 我的课表.docx -o schedule.json

建议把输出放在**工程外**（例如 myP/data/schedule.json）——真实课表属于个人数据，
不要提交进 Git、更不要放进 entry/src/main/resources/rawfile/（那会随安装包分发）。

依赖: 仅 Python 标准库 (zipfile + xml)，无需安装任何第三方包。

课表结构（实测，本脚本按此结构解析）:
  ┌ 表格列: [0]时间段(上午/下午/晚上, 竖合并) [1]节次(第一节..第十三节) [2..8]星期一..星期日
  └ 单元格内每门课由若干独立段落 <w:p> 组成，典型 4 段:
        P0: 课程名            (可能含括号，如 "大学英语（3）")
        P1: 课程号            (纯数字，独立成段)
        P2: (周次) (节次) 校区 教室  教师
        P3: 上课班级列表      (可忽略，作为备注)
    同一单元格可含多门课（4 段一组重复）。

设计原则: 不靠"猜"拼字符串，而是按段落结构化解析，稳健可维护。
"""

import argparse
import json
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

W_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
NS = {"w": W_NS}

WEEKDAYS = ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"]
CN_NUM = {
    "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7,
    "八": 8, "九": 9, "十": 10, "十一": 11, "十二": 12, "十三": 13,
}
SLOT_ROW_RE = re.compile(r"^第([一二三四五六七八九十]+)节$")

# "P2 行"模式: (周次) (第X节-第Y节) 校区 教室  教师
META_RE = re.compile(
    r"[（(]\s*(?P<weeks>[0-9~,、\-\s]*周[0-9~,、\-\s]*)\s*[）)]"      # (周次)
    r"\s*[（(]\s*第(?P<s1>[一二三四五六七八九十]+)节\s*-\s*第(?P<s2>[一二三四五六七八九十]+)节\s*[）)]"
    r"(?P<rest>.*)"                                                   # 校区 教室 教师
)
CODE_RE = re.compile(r"^\d{4,}$")


def read_docx_grid(path):
    """读取表格 -> 二维列表，单元格用 '\\n' 连接其内部段落。"""
    with zipfile.ZipFile(path) as z:
        xml = z.read("word/document.xml").decode("utf-8")
    root = ET.fromstring(xml)
    body = root.find("w:body", NS)
    tables = body.findall("w:tbl", NS)
    if not tables:
        raise SystemExit("docx 中没有找到表格")
    grid = []
    for tr in tables[0].findall("w:tr", NS):
        row = []
        for tc in tr.findall("w:tc", NS):
            paras = []
            for p in tc.findall("w:p", NS):
                txt = "".join(t.text or "" for t in p.iter(f"{{{W_NS}}}t"))
                paras.append(txt)
            row.append("\n".join(paras))
        grid.append(row)
    return grid


def parse_weeks(weeks_str):
    """'1~12周' / '1~3,5~12周' / '4周' / '1,3,5周' -> sorted list[int]"""
    s = weeks_str.replace("周", "").strip()
    weeks = set()
    for part in re.split(r"[,\uff0c\u3001]", s):
        part = part.strip()
        if not part:
            continue
        if "~" in part or "-" in part:
            sep = "~" if "~" in part else "-"
            a, b = part.split(sep, 1)
            try:
                a, b = int(a), int(b)
            except ValueError:
                continue
            weeks.update(range(min(a, b), max(a, b) + 1))
        else:
            try:
                weeks.add(int(part))
            except ValueError:
                continue
    return sorted(weeks)


def clean_name(s):
    s = re.sub(r"\s+", " ", s).strip()
    # 去掉首尾的分隔性标点（不含括号，括号是课程名的一部分）
    s = s.strip(" \t;；,，、")
    # 若末尾是右括号但左右不配对（需先成对），则剔除多余的右括号
    while s and s[-1] in "）)":
        if (s.count("（") + s.count("(")) < (s.count("）") + s.count(")")):
            s = s[:-1].strip()
        else:
            break
    # 去掉开头孤立的分隔符
    s = s.lstrip("，,、;； （(")
    return s


def parse_cell_paras(cell):
    """
    解析一个单元格（段落列表，以 '\\n' 分隔），返回课程 entry 列表。
    策略: 扫描段落；遇到“课号段(纯数字)”时，把前一段当课程名，
    再往后找“(周次)(节次)”的元信息段，组合成一门课。
    """
    paras = [re.sub(r"\s+", " ", p).strip() for p in cell.split("\n")]
    paras = [p for p in paras if p]  # 去空段
    entries = []
    i = 0
    while i < len(paras):
        # 找课号段
        if CODE_RE.match(paras[i]):
            code = paras[i]
            name = clean_name(paras[i - 1]) if i - 1 >= 0 else ""
            # 找其后的元信息段（含周次+节次）
            meta = None
            mi = i + 1
            while mi < len(paras) and mi <= i + 3:
                m = META_RE.search(paras[mi])
                if m:
                    meta = m
                    break
                mi += 1
            if meta and name:
                rest = re.sub(r"\s+", " ", meta.group("rest")).strip()
                # rest 形如 "主校区 A101  张明" 或 "主校区 体育馆  吴倩;;f..." 
                # 去掉班级串
                rest = re.sub(r"[fF]?\d{5,}\s*[（(][^）)]*[）)]?", "", rest)
                rest = rest.strip(" ;；,，")
                parts = rest.split()
                campus = parts[0] if len(parts) >= 1 else ""
                room = parts[1] if len(parts) >= 2 else ""
                teacher = " ".join(parts[2:]) if len(parts) >= 3 else ""
                s1 = CN_NUM.get(meta.group("s1"))
                s2 = CN_NUM.get(meta.group("s2"))
                if s1 is not None and s2 is not None:
                    entries.append({
                        "courseName": name,
                        "courseCode": code,
                        "startSlot": s1,
                        "endSlot": s2,
                        "weeks": parse_weeks(meta.group("weeks")),
                        "weeksRaw": meta.group("weeks").strip(),
                        "campus": campus,
                        "room": room,
                        "teacher": teacher,
                    })
                i = mi + 1
                continue
        i += 1
    return entries


def parse_schedule(path):
    grid = read_docx_grid(path)
    header_idx = next(i for i, r in enumerate(grid) if any("星期一" in c for c in r))
    header = grid[header_idx]
    weekday_names = [c.strip() for c in header if any(wd in c for wd in WEEKDAYS)]
    col_weekday = {2 + i: wd for i, wd in enumerate(weekday_names)}

    results = []
    cur_slot = None
    for row in grid[header_idx + 1:]:
        if len(row) < 3:
            continue
        slot_cell = row[1].strip() if len(row) > 1 else ""
        if SLOT_ROW_RE.match(slot_cell):
            cur_slot = slot_cell
        for ci, wd in col_weekday.items():
            if ci >= len(row):
                continue
            for e in parse_cell_paras(row[ci]):
                e["weekday"] = wd
                e["slot"] = cur_slot
                results.append(e)
    return results


def main():
    ap = argparse.ArgumentParser(description="课晓 - docx 课表解析")
    ap.add_argument("docx")
    ap.add_argument("-o", "--out", default="schedule.json")
    args = ap.parse_args()

    entries = parse_schedule(args.docx)
    seen, uniq = set(), []
    for e in entries:
        key = (e["courseName"], e["courseCode"], e["weekday"],
               e["startSlot"], e["endSlot"], e["weeksRaw"], e["room"])
        if key in seen:
            continue
        seen.add(key)
        uniq.append(e)

    order = {wd: i for i, wd in enumerate(WEEKDAYS)}
    uniq.sort(key=lambda e: (order.get(e["weekday"], 99), e["startSlot"], e["courseName"]))

    out = {"schemaVersion": 1, "source": args.docx,
           "courseCount": len(uniq), "entries": uniq}
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)

    print(f"解析完成: {len(uniq)} 条课程记录 -> {args.out}\n")
    for e in uniq:
        print(f"  {e['weekday']} 第{e['startSlot']}-{e['endSlot']}节 "
              f"{e['courseName']:<18} 周次={e['weeks']}  教室={e['campus']} {e['room']}  {e['teacher']}")


if __name__ == "__main__":
    sys.exit(main())

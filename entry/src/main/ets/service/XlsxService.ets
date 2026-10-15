/*
 * XlsxService —— 把教务处公开挂的课表 .xlsx 解析成课晓的排课数据
 * ---------------------------------------------------------------------------
 * 为什么要有这条路：
 *   有些教务系统的课表页面封掉了「选中 / 复制」（user-select:none、拦 Ctrl+A、
 *   检测到 devtools 就 debugger 挂起），于是「粘贴」和「打印预览」两条路都断了。
 *   但教务处官网通常会另外公开挂一份「各校区课表 .xlsx」—— 那份文件
 *   不需要登录、不在反复制机制的作用范围里，而且全校所有班级都在里面。
 *
 * 文件长什么样（上海杉达学院教务处版，2026-2027-1）：
 *   8 个 sheet，按学院分；每个 sheet 里按「小班」分块，每块三部分：
 *     ① 块头   「小班代号：f250117」「专业名称：…」「辅导员：…」「人数：…」「校区：金海」
 *     ② 课程清单  课程名称 / 总学时 / 学分 / 上课周数(1-16) / 讲课教师 / 备注
 *     ③ 课表网格  行 = 第一节…第十三节（另有「中午1/2」「傍晚」三个非课行）
 *                  列 = 星期一…星期五，**每天占两列**：课程名+周次、教室
 *
 * 网格格子的实际内容（多门课用一行横线隔开）：
 *     离散数学                      ← 课程名
 *     1-12                          ← 周次（列标题已说明是周次，所以不写「周」字）
 *     -----------
 *     数字电路综合实验
 *     13-16
 *
 * ⚠️ 已知局限（实测确认）：
 *   xlsx 的合并单元格全是**横向**的，没有任何跨行合并，所以格子里**没有节次范围**
 *   （教务系统页面上的「第一节-第二节」在 xlsx 里丢了）。
 *   解析时按「大课 = 连排两节」推断：起始节次落在 1/3/5/7/9 就占两节。
 *   四节连排的课（如「第一节-第四节」）需要用户在预览里核对。
 *
 * 本文件是纯逻辑（不依赖 @ohos），可以在电脑上用 Node 跑测试。
 * ---------------------------------------------------------------------------
 */

import { ImportEntryJson, ImportResult, WEEKDAY_FULL } from '../model/Models';
import { DEFAULT_TOTAL_WEEKS } from '../model/Defaults';
import { ImportService } from './ImportService';
import { cnNumber, parseWeeks } from './TextImportService';

/** workbook.xml + 它的 rels 解析出来的「sheet 名 → xml 路径」 */
export interface XlsxSheetTarget {
  name: string;
  /** 形如 xl/worksheets/sheet2.xml */
  path: string;
}

/** 一个「小班」课表块的可读信息 —— 用来让用户认出自己的班 */
export interface XlsxClassInfo {
  sheetName: string;
  /** 小班代号，如 f250117 */
  code: string;
  /** 专业名称，如 计算机科学与技术 */
  major: string;
  /** 学院，如 计算与智能技术学院 */
  college: string;
  /** 年级，如 25级 */
  grade: string;
  /** 辅导员 */
  advisor: string;
  /** 人数 */
  people: string;
  /** 校区，如 金海 */
  campus: string;
  /** 块里数到的节次行数；0 表示这块只有课程清单没有课表网格，直接跳过 */
  slotRows: number;
}

/** 表头里一天的列位置 */
interface DayColumn {
  weekday: number;
  nameCol: number;
  roomCol: number;
}

interface SlotRow {
  row: number;
  slot: number;
}

/** 把格子里的某一段拆成「课程名 + 周次」 */
interface NamedWeeks {
  name: string;
  weeks: string;
}

/** 已解析的网格：行号 → (列号 → 文本)。只保留非空格子 */
type XlsxGrid = Map<number, Map<number, string>>;

/** 教务系统课表里的三个非课行，解析节次时要跳过 */
const NON_CLASS_LABELS: string[] = ['中午1', '中午2', '傍晚', '中午'];

/** 一格多课之间的分隔线：教务系统用的是 11 个短横 */
const CELL_SEPARATOR: RegExp = /[-=—]{4,}/;

/**
 * 教务系统在排不下的格子里会塞这些词占位（表示"这个时段有别的安排"），
 * 它们不是真课名，也没有周次，不该进课表。
 */
const PLACEHOLDER_NAMES: string[] = [
  '通识教育选修课', '学生素质教育', '公共选修课', '通识选修课', '全校', '待定'
];

export class XlsxService {
  // -------------------------------------------------------------------------
  // ① 共享字符串表
  // -------------------------------------------------------------------------

  /**
   * xl/sharedStrings.xml → 字符串数组。
   * 返回值**必须与索引一一对应**（哪怕某项是空的也要占位），
   * 因为单元格里存的就是这张表的下标。
   */
  static parseSharedStrings(xml: string): string[] {
    const out: string[] = [];
    const siRe: RegExp = /<si\b[^>]*>([\s\S]*?)<\/si>/g;
    let m: RegExpExecArray | null = siRe.exec(xml);
    while (m !== null) {
      let body: string = m[1];
      // 拼音/注音块不属于单元格内容
      body = body.replace(/<rPh\b[\s\S]*?<\/rPh>/g, '');
      let text: string = '';
      const tRe: RegExp = /<t\b[^>]*>([\s\S]*?)<\/t>/g;
      let t: RegExpExecArray | null = tRe.exec(body);
      while (t !== null) {
        text += t[1];
        t = tRe.exec(body);
      }
      out.push(decodeXml(text));
      m = siRe.exec(xml);
    }
    return out;
  }

  // -------------------------------------------------------------------------
  // ② workbook：sheet 名 → xml 路径
  // -------------------------------------------------------------------------

  static sheetTargets(workbookXml: string, relsXml: string): XlsxSheetTarget[] {
    const relTarget: Map<string, string> = new Map<string, string>();
    const relRe: RegExp = /<Relationship\b[^>]*>/g;
    let rm: RegExpExecArray | null = relRe.exec(relsXml);
    while (rm !== null) {
      const tag: string = rm[0];
      const id: string = attr(tag, 'Id');
      const target: string = attr(tag, 'Target');
      if (id.length > 0 && target.length > 0) {
        relTarget.set(id, target);
      }
      rm = relRe.exec(relsXml);
    }

    const out: XlsxSheetTarget[] = [];
    const sheetRe: RegExp = /<sheet\b[^>]*\/?>/g;
    let sm: RegExpExecArray | null = sheetRe.exec(workbookXml);
    while (sm !== null) {
      const tag: string = sm[0];
      const name: string = attr(tag, 'name');
      const rid: string = attr(tag, 'r:id');
      let target: string = relTarget.get(rid) === undefined ? '' : `${relTarget.get(rid)}`;
      if (name.length > 0 && target.length > 0) {
        if (target.charAt(0) === '/') {
          target = target.substring(1);
        }
        if (target.indexOf('xl/') !== 0) {
          target = `xl/${target}`;
        }
        const item: XlsxSheetTarget = { name: name, path: target };
        out.push(item);
      }
      sm = sheetRe.exec(workbookXml);
    }
    return out;
  }

  // -------------------------------------------------------------------------
  // ③ 列出一个 sheet 里所有「小班」块
  // -------------------------------------------------------------------------

  static classesInSheet(sheetName: string, xml: string, shared: string[]): XlsxClassInfo[] {
    const grid: XlsxGrid = XlsxService.toGrid(xml, shared);
    const rows: number[] = sortedRows(grid);

    // 「A 列的值发生变化」的行 = 新块的起点。
    // 教务系统在每个班块内的每一行都重复写小班代号，所以连续相同的就是同一块。
    const starts: number[] = [];
    let prev: string = '';
    for (let i = 0; i < rows.length; i++) {
      const code: string = cellAt(grid, rows[i], 0);
      if (code.length > 0 && code !== prev) {
        starts.push(rows[i]);
      }
      if (code.length > 0) {
        prev = code;
      }
    }

    const out: XlsxClassInfo[] = [];
    for (let i = 0; i < starts.length; i++) {
      const from: number = starts[i];
      const to: number = i + 1 < starts.length ? starts[i + 1] - 1 : rows[rows.length - 1];
      const info: XlsxClassInfo = XlsxService.readBlockInfo(sheetName, grid, from, to);
      // 只收「有课表网格」的块：只有课程清单的块（比如只登记选课的）对导入没用
      if (info.code.length > 0 && info.slotRows > 0) {
        out.push(info);
      }
    }
    return out;
  }

  // -------------------------------------------------------------------------
  // ④ 从选定的班块里抽出排课
  // -------------------------------------------------------------------------

  static parseClass(xml: string, shared: string[], info: XlsxClassInfo,
                    source: string): ImportResult {
    const grid: XlsxGrid = XlsxService.toGrid(xml, shared);

    // ---- 块的行范围：A 列 == 小班代号 ----
    let lo: number = -1;
    let hi: number = -1;
    grid.forEach((_cells: Map<number, string>, r: number) => {
      if (cellAt(grid, r, 0).trim() === info.code) {
        if (lo < 0 || r < lo) {
          lo = r;
        }
        if (r > hi) {
          hi = r;
        }
      }
    });
    if (lo < 0) {
      return ImportService.failure('这份 Excel 里没找到该班级的课表');
    }

    // ---- ① 课程清单：课程名 → 教师 / 上课周数 ----
    // 网格里只有「课程名 + 周次 + 教室」，教师只出现在课程清单里，得 join 回来。
    // 注意同名课程可能有多条（比如「体育与健康（3）」按项目分了好几个教学班），
    // 这种情况教师有歧义，宁可留空也不能填错。
    const teacherOf: Map<string, string> = new Map<string, string>();
    const weeksOf: Map<string, string> = new Map<string, string>();
    const teacherClash: Set<string> = new Set<string>();
    let listStart: number = -1;
    for (let r = lo; r <= hi; r++) {
      if (compact(cellAt(grid, r, 2)) === '课程名称') {
        listStart = r + 1;
        break;
      }
    }
    if (listStart > 0) {
      for (let r = listStart; r <= hi; r++) {
        const name: string = cellAt(grid, r, 2).trim();
        if (name.length === 0) {
          break;
        }
        const teacher: string = cellAt(grid, r, 10).trim();
        const existing: string | undefined = teacherOf.get(name);
        if (existing === undefined) {
          teacherOf.set(name, teacher);
          const weeks: string = cellAt(grid, r, 8).trim();
          if (weeks.length > 0) {
            weeksOf.set(name, weeks);
          }
        } else if (existing !== teacher) {
          teacherClash.add(name);
        }
      }
    }

    // ---- ② 表头行：找出每天的两列 ----
    const days: DayColumn[] = [];
    let headerRow: number = -1;
    for (let r = lo; r <= hi; r++) {
      const cells: Map<number, string> | undefined = grid.get(r);
      if (cells === undefined) {
        continue;
      }
      const found: DayColumn[] = [];
      cells.forEach((v: string, col: number) => {
        const w: number = weekdayOf(v);
        if (w > 0 && col >= 2) {
          const day: DayColumn = { weekday: w, nameCol: col, roomCol: col + 1 };
          found.push(day);
        }
      });
      if (found.length >= 3) {
        found.sort((a: DayColumn, b: DayColumn) => a.weekday - b.weekday);
        for (let i = 0; i < found.length; i++) {
          days.push(found[i]);
        }
        headerRow = r;
        break;
      }
    }
    if (headerRow < 0) {
      return ImportService.failure(
        `没找到「星期一 ~ 星期五」表头（班级 ${info.code}，扫了第 ${lo}~${hi} 行）`);
    }

    // ---- ③ 节次行 ----
    const slotRows: SlotRow[] = [];
    for (let r = headerRow + 1; r <= hi; r++) {
      const label: string = compact(cellAt(grid, r, 2));
      const slot: number = slotNumberOf(label);
      if (slot > 0) {
        const sr: SlotRow = { row: r, slot: slot };
        slotRows.push(sr);
      }
    }
    if (slotRows.length === 0) {
      return ImportService.failure('这份 Excel 里没找到「第一节…」这样的节次行');
    }

    // ---- ④ 逐格抽课 ----
    const entries: ImportEntryJson[] = [];
    let inferredSlots: number = 0;
    let missingWeeks: number = 0;
    for (let si = 0; si < slotRows.length; si++) {
      const cur: SlotRow = slotRows[si];
      const nextSlot: number = si + 1 < slotRows.length ? slotRows[si + 1].slot : -1;
      const nextRow: number = si + 1 < slotRows.length ? slotRows[si + 1].row : -1;
      for (let d = 0; d < days.length; d++) {
        const day: DayColumn = days[d];
        const nameCell: string = cellAt(grid, cur.row, day.nameCol);
        if (nameCell.length === 0) {
          continue;
        }
        const names: string[] = splitCellGroups(nameCell);
        const rooms: string[] = splitCellGroups(cellAt(grid, cur.row, day.roomCol));

        // 节次范围：xlsx 里没有，只能推断。
        // 教务系统按「大课」排课，起始节次落在 1/3/5/7/9 的默认占两节；
        // 但如果下一节同一格已经另有课，说明这一格只占一节。
        let endSlot: number = cur.slot;
        if (isBigCourseStart(cur.slot) && cur.slot < 13) {
          if (nextSlot === cur.slot + 1 && nextRow > 0) {
            const below: string = cellAt(grid, nextRow, day.nameCol);
            endSlot = below.length === 0 ? cur.slot + 1 : cur.slot;
          }
        }
        if (endSlot > cur.slot) {
          inferredSlots++;
        }

        for (let k = 0; k < names.length; k++) {
          const nw: NamedWeeks = splitNameAndWeeks(names[k]);
          if (nw.name.length === 0) {
            continue;
          }
          // 「通识教育选修课」这类是教务系统占位用的，不是真课名；
          // 这类格子本来也不带周次，直接跳过比塞进课表更好
          if (nw.weeks.length === 0 && PLACEHOLDER_NAMES.indexOf(nw.name) >= 0) {
            continue;
          }
          let weeksText: string = nw.weeks;
          if (weeksText.length === 0) {
            const fromList: string | undefined = weeksOf.get(nw.name);
            weeksText = fromList === undefined ? '' : fromList;
          }
          let weeks: number[] = parseWeeks(weeksText, true);
          if (weeks.length === 0) {
            // 实在没有周次，按整学期铺开（宁可先填上让用户改，也别让这门课消失）
            weeksText = `1-${DEFAULT_TOTAL_WEEKS}`;
            weeks = parseWeeks(weeksText, true);
            missingWeeks++;
          }
          const room: string = k < rooms.length ? rooms[k] : '';
          let teacher: string = '';
          if (!teacherClash.has(nw.name)) {
            const tv: string | undefined = teacherOf.get(nw.name);
            teacher = tv === undefined ? '' : tv;
          }
          const entry: ImportEntryJson = {
            courseName: nw.name,
            // 教务系统这份 xlsx 里没有课程号，留空 —— 落库层会退回按课程名归并
            courseCode: '',
            startSlot: cur.slot,
            endSlot: endSlot,
            weeks: weeks,
            weeksRaw: weeksText,
            campus: info.campus,
            room: room,
            teacher: teacher,
            weekday: WEEKDAY_FULL[day.weekday - 1],
            slot: `第${cur.slot}节`
          };
          entries.push(entry);
        }
      }
    }

    if (entries.length === 0) {
      return ImportService.failure('这个班的课表格子是空的，没抽出任何课');
    }

    const label: string = info.major.length > 0
      ? `${info.college} ${info.major} ${info.grade}` : info.code;
    const result: ImportResult = ImportService.buildResult(entries, `${source} · ${label}`);
    if (inferredSlots > 0) {
      result.warnings.push(
        `有 ${inferredSlots} 门课的节次是按「连排两节」推断的（Excel 里没写节次范围），`
        + '如果某门课实际连排四节，请在下面核对');
    }
    if (missingWeeks > 0) {
      result.warnings.push(
        `有 ${missingWeeks} 门课在 Excel 里没写上课周数，暂按第 1~${DEFAULT_TOTAL_WEEKS} 周填，请核对`);
    }
    if (teacherClash.size > 0) {
      const names: string[] = [];
      teacherClash.forEach((n: string) => {
        names.push(n);
      });
      result.warnings.push(
        `「${names.join('、')}」在教务系统里分了多个教学班（教师不同），教师栏暂时留空，请按自己的教学班补上`);
    }
    return result;
  }

  // -------------------------------------------------------------------------
  // 内部：网格
  // -------------------------------------------------------------------------

  /** sheetN.xml → 网格。只保留非空格子，行号保持原样（稀疏） */
  private static toGrid(xml: string, shared: string[]): XlsxGrid {
    const grid: XlsxGrid = new Map<number, Map<number, string>>();
    const rowRe: RegExp = /<row\b([^>]*?)(?:\/>|>([\s\S]*?)<\/row>)/g;
    let rm: RegExpExecArray | null = rowRe.exec(xml);
    while (rm !== null) {
      const rowNum: number = Number(attr(rm[1], 'r'));
      const body: string = rm.length > 2 && rm[2] !== undefined ? rm[2] : '';
      if (rowNum > 0 && body.length > 0) {
        const cells: Map<number, string> = new Map<number, string>();
        const cRe: RegExp = /<c\b([^>]*?)(?:\/>|>([\s\S]*?)<\/c>)/g;
        let cm: RegExpExecArray | null = cRe.exec(body);
        while (cm !== null) {
          const attrs: string = cm[1];
          const inner: string = cm.length > 2 && cm[2] !== undefined ? cm[2] : '';
          const col: number = colIndex(attr(attrs, 'r'));
          if (col >= 0) {
            const value: string = cellValue(attrs, inner, shared);
            if (value.length > 0) {
              cells.set(col, value);
            }
          }
          cm = cRe.exec(body);
        }
        if (cells.size > 0) {
          grid.set(rowNum, cells);
        }
      }
      rm = rowRe.exec(xml);
    }
    return grid;
  }

  /** 就读一个块，把块头那些「XX：YY」收集起来，顺带数节次行 */
  private static readBlockInfo(sheetName: string, grid: XlsxGrid,
                               from: number, to: number): XlsxClassInfo {
    const info: XlsxClassInfo = {
      sheetName: sheetName, code: '', major: '', college: '', grade: '',
      advisor: '', people: '', campus: '', slotRows: 0
    };
    for (let r = from; r <= to; r++) {
      const cells: Map<number, string> | undefined = grid.get(r);
      if (cells === undefined) {
        continue;
      }
      // 块头那些「XX：YY」散落在一行的好几列上（小班代号在第 5 列、辅导员在第 7 列、
      // 人数在第 10 列、校区在第 12 列），所以整行都要扫，不能只看某一列。
      let sawSlotRow: boolean = false;
      cells.forEach((value: string, col: number) => {
        const t: string = value.trim();
        if (t.length === 0) {
          return;
        }
        const compacted: string = compact(t);
        if (compacted.indexOf('专业名称') === 0) {
          info.major = afterColon(t);
        } else if (compacted.indexOf('小班代号') === 0) {
          info.code = afterColon(t);
        } else if (compacted.indexOf('辅导员') === 0) {
          info.advisor = afterColon(t);
        } else if (compacted.indexOf('人数') === 0) {
          info.people = afterColon(t);
        } else if (compacted.indexOf('校区') === 0) {
          info.campus = afterColon(t);
        } else if (col === 2 && slotNumberOf(compacted) > 0) {
          sawSlotRow = true;
        }
      });
      if (sawSlotRow) {
        info.slotRows++;
      }
      // 学院 / 年级放在最右边的两列，每一行都重复
      const college: string = cellAt(grid, r, 14).trim();
      if (college.length > 0 && info.college.length === 0) {
        info.college = college;
      }
      const grade: string = cellAt(grid, r, 15).trim();
      if (grade.length > 0 && info.grade.length === 0) {
        info.grade = grade;
      }
    }
    if (info.code.length === 0) {
      // 块头没写就退回用 A 列
      info.code = cellAt(grid, from, 0).trim();
    }
    return info;
  }
}

// ===========================================================================
// 纯函数工具
// ===========================================================================

/** 行号排序后返回 */
function sortedRows(grid: XlsxGrid): number[] {
  const rows: number[] = [];
  grid.forEach((_cells: Map<number, string>, r: number) => {
    rows.push(r);
  });
  rows.sort((a: number, b: number) => a - b);
  return rows;
}

/** 取一个格子的文本，没有就返回空串 */
function cellAt(grid: XlsxGrid, row: number, col: number): string {
  const cells: Map<number, string> | undefined = grid.get(row);
  if (cells === undefined) {
    return '';
  }
  const v: string | undefined = cells.get(col);
  return v === undefined ? '' : v;
}

/** 'D311' → 3（0 基）。取不到列字母返回 -1 */
function colIndex(ref: string): number {
  let n: number = 0;
  let seen: boolean = false;
  for (let i = 0; i < ref.length; i++) {
    const code: number = ref.charCodeAt(i);
    if (code >= 65 && code <= 90) {
      n = n * 26 + (code - 64);
      seen = true;
    } else {
      break;
    }
  }
  return seen ? n - 1 : -1;
}

/** 从一串属性里取 name="value" */
function attr(attrs: string, name: string): string {
  const quoted: string = name.replace(':', '\\:');
  const re: RegExp = new RegExp(`(?:^|[\\s"'])${quoted}="([^"]*)"`);
  const m: RegExpExecArray | null = re.exec(` ${attrs}`);
  return m === null ? '' : m[1];
}

/** 一个 <c> 的真实值 */
function cellValue(attrs: string, inner: string, shared: string[]): string {
  const t: string = attr(attrs, 't');
  if (t === 's') {
    const idx: number = Number(extractTag(inner, 'v'));
    if (idx >= 0 && idx < shared.length) {
      return shared[idx];
    }
    return '';
  }
  if (t === 'inlineStr') {
    return decodeXml(extractAllTags(inner, 't'));
  }
  return decodeXml(extractTag(inner, 'v'));
}

/** 取第一个 <tag>…</tag> 的内容 */
function extractTag(xml: string, tag: string): string {
  const re: RegExp = new RegExp(`<${tag}\\b[^>]*>([\\s\\S]*?)<\\/${tag}>`);
  const m: RegExpExecArray | null = re.exec(xml);
  return m === null ? '' : m[1];
}

/** 把所有 <tag>…</tag> 的内容拼起来（富文本会拆成多个 <t>） */
function extractAllTags(xml: string, tag: string): string {
  let out: string = '';
  const re: RegExp = new RegExp(`<${tag}\\b[^>]*>([\\s\\S]*?)<\\/${tag}>`, 'g');
  let m: RegExpExecArray | null = re.exec(xml);
  while (m !== null) {
    out += m[1];
    m = re.exec(xml);
  }
  return out;
}

/** XML 实体反转义 */
function decodeXml(text: string): string {
  if (text.indexOf('&') < 0) {
    return text;
  }
  let out: string = text.replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&');
  if (out.indexOf('&#') < 0) {
    return out;
  }
  // 数字实体：&#10;（换行）&#12290;（中文句号）之类
  const re: RegExp = /&#(x?[0-9a-fA-F]+);/g;
  let result: string = '';
  let last: number = 0;
  let m: RegExpExecArray | null = re.exec(out);
  while (m !== null) {
    result += out.substring(last, m.index);
    const raw: string = m[1];
    const code: number = raw.charAt(0) === 'x' || raw.charAt(0) === 'X'
      ? parseInt(raw.substring(1), 16) : parseInt(raw, 10);
    if (code > 0) {
      result += String.fromCharCode(code);
    }
    last = m.index + m[0].length;
    m = re.exec(out);
  }
  result += out.substring(last);
  return result;
}

/** 去掉所有空白，用来做「××：」这种标签的比对 */
function compact(text: string): string {
  return text.replace(/[\s\u3000]/g, '');
}

/** 「专业名称：计算机科学与技术」→「计算机科学与技术」 */
function afterColon(text: string): string {
  const t: string = text.trim();
  const full: number = t.indexOf('：');
  const half: number = t.indexOf(':');
  let at: number = -1;
  if (full >= 0 && half >= 0) {
    at = full < half ? full : half;
  } else if (full >= 0) {
    at = full;
  } else {
    at = half;
  }
  return at < 0 ? t : t.substring(at + 1).trim();
}

/** 「星期一」→ 1；不是星期几返回 0 */
function weekdayOf(text: string): number {
  const s: string = compact(text);
  // 注意是「星」「期」「X」—— 第 3 个字符才是星期几
  if (s.length !== 3 || s.charAt(0) !== '星' || s.charAt(1) !== '期') {
    return 0;
  }
  const c: string = s.charAt(2);
  const idx: number = ['一', '二', '三', '四', '五', '六', '日'].indexOf(c);
  return idx < 0 ? 0 : idx + 1;
}

/**
 * 「第一节」→ 1；「中午1」「傍晚」这类非课行返回 0。
 * 教务系统的写法不统一：第一~第十节带「第」字，但第十一~十三节写成「十一节」。
 */
function slotNumberOf(label: string): number {
  if (label.length === 0 || label.charAt(label.length - 1) !== '节') {
    return 0;
  }
  for (let i = 0; i < NON_CLASS_LABELS.length; i++) {
    if (label === NON_CLASS_LABELS[i]) {
      return 0;
    }
  }
  const mid: string = label.charAt(0) === '第'
    ? label.substring(1, label.length - 1)
    : label.substring(0, label.length - 1);
  const n: number = cnNumber(mid);
  return n >= 1 && n <= 20 ? n : 0;
}

/** 课晓的作息是「两节一大课」：上午 1-2 / 3-4，下午 5-6 / 7-8，晚上 9-10 */
function isBigCourseStart(slot: number): boolean {
  return slot === 1 || slot === 3 || slot === 5 || slot === 7 || slot === 9;
}

/**
 * 把一个格子拆成若干门课。
 * 教务系统在格子里用一整行短横线隔开多门课（同格多课通常是周次不重叠）。
 */
function splitCellGroups(text: string): string[] {
  const out: string[] = [];
  const parts: string[] = text.split(CELL_SEPARATOR);
  for (let i = 0; i < parts.length; i++) {
    const t: string = parts[i].trim();
    if (t.length > 0) {
      out.push(t);
    }
  }
  return out;
}

/** 一段「课程名 + 周次」：第一行是课程名，后面找第一个像周次的行 */
function splitNameAndWeeks(part: string): NamedWeeks {
  const lines: string[] = part.split('\n');
  const clean: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    const t: string = lines[i].replace(/\r/g, '').trim();
    if (t.length > 0) {
      clean.push(t);
    }
  }
  if (clean.length === 0) {
    const empty: NamedWeeks = { name: '', weeks: '' };
    return empty;
  }
  let weeks: string = '';
  for (let i = 1; i < clean.length; i++) {
    if (parseWeeks(clean[i], true).length > 0) {
      weeks = clean[i];
      break;
    }
  }
  const result: NamedWeeks = { name: clean[0], weeks: weeks };
  return result;
}

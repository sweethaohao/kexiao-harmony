/**
 * 课晓 · 导入服务（ImportService）
 * ---------------------------------------------------------------------------
 * 职责：把「外部 JSON（schemaVersion 1）」翻译成课晓内部的标准模型。
 *
 * 外部 JSON 由电脑侧脚本 tools/parse_schedule.py 从教务 Word 课表生成，
 * 它的字段名是给"人类阅读"用的（weekday 是「星期一」这种中文），
 * 而内部模型要的是数字、id、以及归并好的 Course。
 * 这个翻译 + 校验 + 纠错的过程全部在本文件。
 *
 * 本文件是纯逻辑（不依赖 @ohos 能力），可以在电脑上用 Node 跑测试。
 * ---------------------------------------------------------------------------
 */

import {
  Course, ImportEntryJson, ImportFileJson, ImportResult, ScheduleEntry, ScheduleItem
} from '../model/Models';
import { colorForCourse } from '../model/Defaults';
import { DateUtil } from '../common/DateUtil';

/** 支持的导入格式版本 */
export const SUPPORTED_SCHEMA_VERSION: number = 1;

/** 中文/数字星期 → 星期序号（1 = 周一 … 7 = 周日） */
function buildWeekdayMap(): Map<string, number> {
  const m: Map<string, number> = new Map<string, number>();
  const full: string[] = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
  const brief: string[] = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  const worship: string[] = ['礼拜一', '礼拜二', '礼拜三', '礼拜四', '礼拜五', '礼拜六', '礼拜日'];
  for (let i = 0; i < 7; i++) {
    const num: number = i + 1;
    m.set(full[i], num);
    m.set(brief[i], num);
    m.set(worship[i], num);
    m.set(`星期${num}`, num);
    m.set(`周${num}`, num);
    m.set(`${num}`, num);
  }
  m.set('星期天', 7);
  m.set('周天', 7);
  m.set('礼拜天', 7);
  return m;
}

const WEEKDAY_MAP: Map<string, number> = buildWeekdayMap();

/** 把「星期一 / 周一 / Monday / 星期1」这类写法统一成星期序号；识别不了返回 0 */
export function parseWeekday(text: string): number {
  if (text === undefined || text === null) {
    return 0;
  }
  const key: string = `${text}`.replace(/\s/g, '');
  if (key.length === 0) {
    return 0;
  }
  const hit: number | undefined = WEEKDAY_MAP.get(key);
  if (hit !== undefined) {
    return hit;
  }
  // 兜底：英文
  const lower: string = key.toLowerCase();
  if (lower.indexOf('mon') === 0) {
    return 1;
  }
  if (lower.indexOf('tue') === 0) {
    return 2;
  }
  if (lower.indexOf('wed') === 0) {
    return 3;
  }
  if (lower.indexOf('thu') === 0) {
    return 4;
  }
  if (lower.indexOf('fri') === 0) {
    return 5;
  }
  if (lower.indexOf('sat') === 0) {
    return 6;
  }
  if (lower.indexOf('sun') === 0) {
    return 7;
  }
  return 0;
}

/** 把周次数组规范化：去重、升序、只保留正整数 */
function normalizeWeeks(weeks: number[]): number[] {
  if (weeks === undefined || weeks === null) {
    return [];
  }
  const seen: Set<number> = new Set<number>();
  for (let i = 0; i < weeks.length; i++) {
    const w: number = Math.floor(Number(weeks[i]));
    if (!Number.isNaN(w) && w >= 1 && w <= 60) {
      seen.add(w);
    }
  }
  const out: number[] = Array.from(seen);
  out.sort((a: number, b: number) => a - b);
  return out;
}

/** 把周次数组压成好读的文本，如 [1,2,3,5] → '1~3,5周' */
export function weeksToText(weeks: number[]): string {
  if (weeks.length === 0) {
    return '';
  }
  const parts: string[] = [];
  let runStart: number = weeks[0];
  let prev: number = weeks[0];
  for (let i = 1; i <= weeks.length; i++) {
    const cur: number = i < weeks.length ? weeks[i] : -1;
    if (cur !== prev + 1) {
      parts.push(runStart === prev ? `${runStart}` : `${runStart}~${prev}`);
      runStart = cur;
    }
    prev = cur;
  }
  return `${parts.join(',')}周`;
}

export class ImportService {
  /**
   * 解析导入文本。
   * 返回值 ok = false 表示是"结构性失败"（文件根本不是课晓格式），此时 error 有内容；
   * 单条记录的毛病不会让整体失败，而是记进 warnings。
   */
  static parse(text: string): ImportResult {
    let raw: ImportFileJson;
    try {
      raw = JSON.parse(text) as ImportFileJson;
    } catch (e) {
      return ImportService.failure('文件不是合法的 JSON，无法解析');
    }
    if (raw === undefined || raw === null) {
      return ImportService.failure('文件内容为空');
    }
    const version: number = raw.schemaVersion === undefined ? 0 : raw.schemaVersion;
    if (version !== SUPPORTED_SCHEMA_VERSION) {
      return ImportService.failure(
        `不支持的格式版本：${version}（课晓当前支持 ${SUPPORTED_SCHEMA_VERSION}）`);
    }
    const entries: ImportEntryJson[] = raw.entries;
    if (entries === undefined || entries === null || !Array.isArray(entries)) {
      return ImportService.failure('文件里没有 entries 列表');
    }

    const warnings: string[] = [];
    const courses: Course[] = [];
    const courseIdByKey: Map<string, number> = new Map<string, number>();
    const outEntries: ScheduleEntry[] = [];
    const items: ScheduleItem[] = [];
    const dedup: Set<string> = new Set<string>();
    let courseSeq: number = 1;
    let entrySeq: number = 1;
    let maxWeek: number = 0;
    let skipped: number = 0;
    let duplicated: number = 0;

    for (let i = 0; i < entries.length; i++) {
      const e: ImportEntryJson = entries[i];
      const name: string = e.courseName === undefined ? '' : `${e.courseName}`.trim();
      if (name.length === 0) {
        skipped++;
        warnings.push(`第 ${i + 1} 条记录没有课程名，已跳过`);
        continue;
      }
      const weekday: number = parseWeekday(e.weekday === undefined ? '' : `${e.weekday}`);
      if (weekday <= 0) {
        skipped++;
        warnings.push(`「${name}」的星期「${e.weekday}」无法识别，已跳过`);
        continue;
      }
      let startSlot: number = Math.floor(Number(e.startSlot));
      let endSlot: number = Math.floor(Number(e.endSlot));
      if (Number.isNaN(startSlot) || startSlot < 1) {
        startSlot = 1;
      }
      if (Number.isNaN(endSlot) || endSlot < startSlot) {
        endSlot = startSlot;
        warnings.push(`「${name}」的节次区间异常，已按第 ${startSlot} 节处理`);
      }
      const weeks: number[] = normalizeWeeks(e.weeks);
      if (weeks.length === 0) {
        skipped++;
        warnings.push(`「${name}」没有有效的上课周次，已跳过`);
        continue;
      }
      for (let k = 0; k < weeks.length; k++) {
        if (weeks[k] > maxWeek) {
          maxWeek = weeks[k];
        }
      }

      const code: string = e.courseCode === undefined ? '' : `${e.courseCode}`.trim();
      const room: string = e.room === undefined ? '' : `${e.room}`.trim();
      const teacher: string = e.teacher === undefined ? '' : `${e.teacher}`.trim();
      const campus: string = e.campus === undefined ? '' : `${e.campus}`.trim();
      const weeksRaw: string = (e.weeksRaw === undefined || `${e.weeksRaw}`.length === 0)
        ? weeksToText(weeks) : `${e.weeksRaw}`;

      // ---- 去重：同课程 + 同星期 + 同节次 + 同周次 + 同教室 视为同一条 ----
      const key: string = [
        code.length > 0 ? code : name, `${weekday}`, `${startSlot}`, `${endSlot}`,
        weeks.join(','), room
      ].join('|');
      if (dedup.has(key)) {
        duplicated++;
        continue;
      }
      dedup.add(key);

      // ---- 归并课程：优先按课程号，没有课程号就按课程名 ----
      const courseKey: string = code.length > 0 ? `c:${code}` : `n:${name}`;
      let courseId: number | undefined = courseIdByKey.get(courseKey);
      if (courseId === undefined) {
        courseId = courseSeq;
        courseSeq++;
        courseIdByKey.set(courseKey, courseId);
        const course: Course = {
          id: courseId,
          name: name,
          code: code,
          teacher: teacher,
          campus: campus,
          room: room,
          color: colorForCourse(name)
        };
        courses.push(course);
      }

      const entry: ScheduleEntry = {
        id: entrySeq,
        courseId: courseId,
        weekday: weekday,
        startSlot: startSlot,
        endSlot: endSlot,
        weeks: weeks,
        weeksRaw: weeksRaw,
        room: room,
        teacher: teacher,
        campus: campus
      };
      outEntries.push(entry);

      const item: ScheduleItem = {
        entryId: entrySeq,
        courseId: courseId,
        courseName: name,
        courseCode: code,
        teacher: teacher,
        campus: campus,
        room: room,
        color: colorForCourse(name),
        weekday: weekday,
        startSlot: startSlot,
        endSlot: endSlot,
        weeks: weeks,
        weeksRaw: weeksRaw
      };
      items.push(item);
      entrySeq++;
    }

    if (items.length === 0) {
      return ImportService.failure('文件里没有一条能用的课程记录，请检查课表来源是否正确');
    }

    if (duplicated > 0) {
      warnings.push(`已自动合并 ${duplicated} 条重复记录`);
    }
    if (skipped > 0) {
      warnings.push(`共跳过 ${skipped} 条异常记录`);
    }

    const source: string = raw.source === undefined ? '未知来源' : `${raw.source}`;
    const result: ImportResult = {
      ok: true,
      error: '',
      source: source,
      courses: courses,
      entries: outEntries,
      items: items,
      totalWeeks: maxWeek,
      warnings: warnings
    };
    return result;
  }

  private static failure(message: string): ImportResult {
    const empty: ImportResult = {
      ok: false,
      error: message,
      source: '',
      courses: [],
      entries: [],
      items: [],
      totalWeeks: 0,
      warnings: []
    };
    return empty;
  }

  /**
   * 兜底推断学期起始日。
   * 目前课表文件里没有学期信息，先按"导入当周就是第 1 周"来猜，
   * 之后用户在设置页里改一次即可（设置页会持久化）。
   */
  static guessSemesterStart(now: Date): string {
    return DateUtil.formatDate(DateUtil.mondayOf(now));
  }
}

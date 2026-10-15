/**
 * 课晓 · 存储映射（StorageMapper）
 * ---------------------------------------------------------------------------
 * 职责：在「数据库行记录」与「领域模型」之间来回翻译。
 *
 * 为什么把这件事单独抽出来？因为它全是**纯逻辑**：
 *   - 不碰数据库、不碰任何 @ohos / @kit 能力；
 *   - 输入输出都是普通对象，可以完全脱离模拟器验证。
 * 所以它被放进了自测清单（tools/selftest），改完能在电脑上立刻跑。
 *
 * 两个约定：
 *   1. 数组不能进 SQLite 列，周次统一序列化成 JSON 文本（'[1,2,3,5]'）。
 *      JSON 数组里没有属性名，不存在被混淆改名的问题。
 *   2. 任何一处脏数据都不许把整次读取带崩 —— 解析失败一律降级为空值。
 * ---------------------------------------------------------------------------
 */

import {
  Course, CourseRow, EntryRow, ImportResult, ScheduleEntry, ScheduleItem
} from '../model/Models';

export class StorageMapper {
  // -------------------------------------------------------------------------
  // 周次序列化
  // -------------------------------------------------------------------------

  /** 周次数组 → JSON 文本，用于落库。空数组存成 '[]' 而不是空串，读取时好判断 */
  static weeksToJson(weeks: number[]): string {
    if (weeks === undefined || weeks === null || weeks.length === 0) {
      return '[]';
    }
    return JSON.stringify(weeks);
  }

  /**
   * JSON 文本 → 周次数组。
   * 容错：空串、非法 JSON、非数组、超范围的值，全部过滤掉，绝不抛异常。
   */
  static weeksFromJson(text: string): number[] {
    if (text === undefined || text === null || text.length === 0) {
      return [];
    }
    let parsed: number[];
    try {
      parsed = JSON.parse(text) as number[];
    } catch (e) {
      return [];
    }
    if (!Array.isArray(parsed)) {
      return [];
    }
    const out: number[] = [];
    for (let i = 0; i < parsed.length; i++) {
      const w: number = Math.floor(Number(parsed[i]));
      if (!Number.isNaN(w) && w >= 1 && w <= 60) {
        out.push(w);
      }
    }
    return out;
  }

  // -------------------------------------------------------------------------
  // 模型 → 行（写库方向）
  // -------------------------------------------------------------------------

  static courseToRow(c: Course): CourseRow {
    const row: CourseRow = {
      id: c.id,
      name: c.name,
      code: c.code,
      teacher: c.teacher,
      campus: c.campus,
      room: c.room,
      color: c.color
    };
    return row;
  }

  static entryToRow(e: ScheduleEntry): EntryRow {
    const row: EntryRow = {
      id: e.id,
      courseId: e.courseId,
      weekday: e.weekday,
      startSlot: e.startSlot,
      endSlot: e.endSlot,
      weeksJson: StorageMapper.weeksToJson(e.weeks),
      weeksRaw: e.weeksRaw,
      room: e.room,
      teacher: e.teacher,
      campus: e.campus
    };
    return row;
  }

  // -------------------------------------------------------------------------
  // 行 → 模型（读库方向）
  // -------------------------------------------------------------------------

  static rowToCourse(r: CourseRow): Course {
    const c: Course = {
      id: r.id,
      name: r.name,
      code: r.code,
      teacher: r.teacher,
      campus: r.campus,
      room: r.room,
      color: r.color
    };
    return c;
  }

  static rowToEntry(r: EntryRow): ScheduleEntry {
    const e: ScheduleEntry = {
      id: r.id,
      courseId: r.courseId,
      weekday: r.weekday,
      startSlot: r.startSlot,
      endSlot: r.endSlot,
      weeks: StorageMapper.weeksFromJson(r.weeksJson),
      weeksRaw: r.weeksRaw,
      room: r.room,
      teacher: r.teacher,
      campus: r.campus
    };
    return e;
  }

  // -------------------------------------------------------------------------
  // 两表拼装
  // -------------------------------------------------------------------------

  /**
   * 把 course 与 schedule_entry 两张表拼成页面直接能用的 ScheduleItem[]。
   *
   * 拼装规则：
   *   - 课程名、课程号、配色取自 course 表；
   *   - 教室 / 教师 / 校区优先用排课条目自己的（真实课表里同一门课
   *     不同时段可能换教室换老师），为空时才回落到课程表上的"主教室/主教师"；
   *   - 找不到对应课程的孤儿条目直接跳过，不让它污染界面。
   */
  static joinItems(courses: Course[], entries: ScheduleEntry[]): ScheduleItem[] {
    const byId: Map<number, Course> = new Map<number, Course>();
    for (let i = 0; i < courses.length; i++) {
      byId.set(courses[i].id, courses[i]);
    }
    const out: ScheduleItem[] = [];
    for (let i = 0; i < entries.length; i++) {
      const e: ScheduleEntry = entries[i];
      const c: Course | undefined = byId.get(e.courseId);
      if (c === undefined) {
        continue;
      }
      const item: ScheduleItem = {
        entryId: e.id,
        courseId: c.id,
        courseName: c.name,
        courseCode: c.code,
        teacher: e.teacher.length > 0 ? e.teacher : c.teacher,
        campus: e.campus.length > 0 ? e.campus : c.campus,
        room: e.room.length > 0 ? e.room : c.room,
        color: c.color,
        weekday: e.weekday,
        startSlot: e.startSlot,
        endSlot: e.endSlot,
        weeks: e.weeks,
        weeksRaw: e.weeksRaw
      };
      out.push(item);
    }
    return out;
  }

  /** 导入结果里的课程列表是否可用（防止把半截数据写进库） */
  static isWritable(result: ImportResult): boolean {
    return result.ok && result.courses.length > 0 && result.entries.length > 0;
  }
}

/**
 * 课晓 · 课表服务（ScheduleService）
 * ---------------------------------------------------------------------------
 * 职责：把「课程数据 + 学期起始日 + 节次时间表」换算成 UI 能直接画的东西。
 *
 * 核心是三件事：
 *   ① 周次过滤 —— 这门课这周到底上不上？          → weeks.includes(week)
 *   ② 日期换算 —— 「第 8 周周三第 1-2 节」是几月几号几点？
 *   ③ 今明日程 —— 今天上完了吗？没上完就显示今天，上完了就显示往后最近有课的一天
 *
 * 本文件是纯逻辑，不依赖任何 @ohos 能力，因此可以在电脑上用 Node 直接跑测试。
 * ---------------------------------------------------------------------------
 */

import {
  DailyBrief, DayCell, DayCourse, ScheduleItem, Semester, WeekView, WeekViewDay, WEEKDAY_SHORT
} from '../model/Models';
import { DateUtil } from '../common/DateUtil';
import { SlotTimeTable } from '../common/SlotTimeTable';

export class ScheduleService {
  private readonly timeTable: SlotTimeTable;

  constructor(timeTable: SlotTimeTable) {
    this.timeTable = timeTable;
  }

  /** 更换节次时间表（用户在设置里改作息后调用） */
  // 说明：ArkTS 里 readonly 字段不能在外部改，所以用"新建一个 service"的方式替换整体。

  // =========================================================================
  // ① 周次 / 日期
  // =========================================================================

  /**
   * 给定日期是第几周（1 起）。
   * 返回 0 表示这天在开学前；大于 totalWeeks 表示学期已结束。
   */
  static weekOfDate(semester: Semester, date: Date): number {
    const firstMonday: Date = DateUtil.mondayOf(DateUtil.parseDate(semester.startDate));
    const offsetDays: number = DateUtil.dayDiff(firstMonday, date);
    return Math.floor(offsetDays / 7) + 1;
  }

  /** 第 week 周、星期 weekday 的真实日期（00:00） */
  static dateOfWeekday(semester: Semester, week: number, weekday: number): Date {
    const firstMonday: Date = DateUtil.mondayOf(DateUtil.parseDate(semester.startDate));
    return DateUtil.addDays(firstMonday, (week - 1) * 7 + (weekday - 1));
  }

  /** 该日期是否落在学期内（1 ≤ 周次 ≤ 总周数） */
  static inSemester(semester: Semester, date: Date): boolean {
    const w: number = ScheduleService.weekOfDate(semester, date);
    return w >= 1 && w <= semester.totalWeeks;
  }

  /** 这一门课这一周上不上 */
  static activeInWeek(item: ScheduleItem, week: number): boolean {
    return item.weeks.indexOf(week) >= 0;
  }

  /** 挑出第 week 周要上的所有课（按星期、节次排序） */
  itemsOfWeek(items: ScheduleItem[], week: number): ScheduleItem[] {
    const out: ScheduleItem[] = items.filter((it: ScheduleItem) => ScheduleService.activeInWeek(it, week));
    out.sort((a: ScheduleItem, b: ScheduleItem) => {
      if (a.weekday !== b.weekday) {
        return a.weekday - b.weekday;
      }
      return a.startSlot - b.startSlot;
    });
    return out;
  }

  // =========================================================================
  // ② 单节课 → 真实时间
  // =========================================================================

  /** 把一条排课项落到某个具体日期上，算出真实的起止时间 */
  toDayCourse(item: ScheduleItem, date: Date): DayCourse {
    const day: Date = DateUtil.startOfDay(date);
    const startSlotTime = this.timeTable.tryAt(item.startSlot);
    const endSlotTime = this.timeTable.tryAt(item.endSlot);
    const startHm: string = startSlotTime === undefined ? '00:00' : startSlotTime.start;
    const endHm: string = endSlotTime === undefined
      ? (startSlotTime === undefined ? '00:00' : startSlotTime.end)
      : endSlotTime.end;
    return {
      item: item,
      date: day,
      start: DateUtil.dateAt(day, startHm),
      end: DateUtil.dateAt(day, endHm)
    };
  }

  /** 取某一天要上的课（按开始时间排序） */
  coursesOfDate(items: ScheduleItem[], semester: Semester, date: Date): DayCourse[] {
    const week: number = ScheduleService.weekOfDate(semester, date);
    if (week < 1 || week > semester.totalWeeks) {
      return [];
    }
    const weekday: number = DateUtil.weekdayNum(date);
    const out: DayCourse[] = [];
    for (let i = 0; i < items.length; i++) {
      const it: ScheduleItem = items[i];
      if (it.weekday === weekday && ScheduleService.activeInWeek(it, week)) {
        out.push(this.toDayCourse(it, date));
      }
    }
    out.sort((a: DayCourse, b: DayCourse) => DateUtil.compare(a.start, b.start));
    return out;
  }

  /** 某节课的开始时间文本，如 '08:00' */
  startTextOf(item: ScheduleItem): string {
    return this.timeTable.labelOf(item.startSlot).split('-')[0];
  }

  /** 某节课的结束时间文本，如 '09:30' */
  endTextOf(item: ScheduleItem): string {
    const label: string = this.timeTable.labelOf(item.endSlot);
    const parts: string[] = label.split('-');
    return parts.length > 1 ? parts[1] : '';
  }

  // =========================================================================
  // ③ 今明日程（小窗口时间线）
  // =========================================================================

  /**
   * 生成"今明日程"。
   * 规则（按用户需求）：
   *   今天的日程还没全部过去 → 显示今天；
   *   今天的日程已全部过去   → 显示往后最近有课的一天（通常就是明天）。
   * 这里比需求多走了一步：如果明天也没课，会继续往后找两周，避免用户看到空屏。
   */
  getDailyBrief(items: ScheduleItem[], semester: Semester, now: Date): DailyBrief {
    const todayCourses: DayCourse[] = this.coursesOfDate(items, semester, now);
    const allPassed: boolean = todayCourses.length > 0
      && todayCourses[todayCourses.length - 1].end.getTime() <= now.getTime();

    if (todayCourses.length > 0 && !allPassed) {
      return this.makeBrief('today', '今天', DateUtil.startOfDay(now), todayCourses, false, now);
    }

    // 今天已全部上完（或今天本来就没课）→ 往后找最近有课的一天
    for (let offset = 1; offset <= 14; offset++) {
      const d: Date = DateUtil.addDays(now, offset);
      const list: DayCourse[] = this.coursesOfDate(items, semester, d);
      if (list.length > 0) {
        const title: string = offset === 1
          ? '明天'
          : `${DateUtil.formatMd(d)} ${DateUtil.weekdayShortLabel(d)}`;
        const brief: DailyBrief = this.makeBrief('upcoming', title, DateUtil.startOfDay(d),
          list, allPassed, now);
        if (allPassed) {
          brief.hint = '今天的课都上完啦，这是下次的课';
        }
        return brief;
      }
    }

    const empty: DailyBrief = {
      mode: 'empty',
      title: '暂无日程',
      date: DateUtil.startOfDay(now),
      weekday: DateUtil.weekdayNum(now),
      courses: [],
      allPassed: allPassed,
      currentEntryId: 0,
      nextEntryId: 0,
      hint: allPassed ? '今天的课都上完啦，最近两周也没课' : '最近两周没有课程安排'
    };
    return empty;
  }

  private makeBrief(mode: string, title: string, date: Date, courses: DayCourse[],
    allPassed: boolean, now: Date): DailyBrief {
    let currentEntryId: number = 0;
    let nextEntryId: number = 0;
    for (let i = 0; i < courses.length; i++) {
      const c: DayCourse = courses[i];
      if (c.start.getTime() <= now.getTime() && c.end.getTime() > now.getTime()) {
        currentEntryId = c.item.entryId;
      }
      if (c.start.getTime() > now.getTime() && nextEntryId === 0) {
        nextEntryId = c.item.entryId;
      }
    }

    let hint: string = '';
    if (mode === 'today') {
      if (currentEntryId !== 0) {
        hint = `正在进行中 · 共 ${courses.length} 节课`;
      } else if (nextEntryId !== 0) {
        hint = `下一节即将开始 · 今天共 ${courses.length} 节课`;
      }
    } else {
      hint = `这天共 ${courses.length} 节课`;
    }

    const brief: DailyBrief = {
      mode: mode,
      title: title,
      date: date,
      weekday: DateUtil.weekdayNum(date),
      courses: courses,
      allPassed: allPassed,
      currentEntryId: currentEntryId,
      nextEntryId: nextEntryId,
      hint: hint
    };
    return brief;
  }

  // =========================================================================
  // ④ 周视图
  // =========================================================================

  /**
   * 把一天里的课排成"格子序列"：课程格跨 span 行，其余位置填空白格。
   * ArkUI 不支持表格的 rowspan，所以用「高度 = span × 单元高」的方式模拟合并单元格，
   * 这个方法就是把"合并"的结果算出来。
   */
  buildDayColumn(courses: DayCourse[], maxSlotOverride?: number): DayCell[] {
    const maxSlot: number = maxSlotOverride === undefined ? this.timeTable.count : maxSlotOverride;
    const byStart: Map<number, DayCourse> = new Map();
    for (let i = 0; i < courses.length; i++) {
      const c: DayCourse = courses[i];
      if (byStart.get(c.item.startSlot) === undefined) {
        // 同一格同一周出现两门课属于数据冲突（正常课表不会有），
        // 这里保留先到的那门、后到的忽略，避免渲染出重叠的块。
        byStart.set(c.item.startSlot, c);
      }
    }

    const cells: DayCell[] = [];
    let slot: number = 1;
    while (slot <= maxSlot) {
      const c: DayCourse | undefined = byStart.get(slot);
      if (c !== undefined) {
        let span: number = c.item.endSlot - c.item.startSlot + 1;
        if (span < 1) {
          span = 1;
        }
        if (slot + span - 1 > maxSlot) {
          span = maxSlot - slot + 1;
        }
        cells.push(ScheduleService.courseCell(c, span));
        slot += span;
      } else {
        cells.push(ScheduleService.emptyCell(slot));
        slot += 1;
      }
    }
    return cells;
  }

  private static courseCell(c: DayCourse, span: number): DayCell {
    return {
      kind: 'course',
      slot: c.item.startSlot,
      span: span,
      courseName: c.item.courseName,
      courseCode: c.item.courseCode,
      teacher: c.item.teacher,
      room: c.item.room,
      color: c.item.color,
      timeText: `${DateUtil.formatHm(c.start)}-${DateUtil.formatHm(c.end)}`,
      entryId: c.item.entryId
    };
  }

  private static emptyCell(slot: number): DayCell {
    return {
      kind: 'empty',
      slot: slot,
      span: 1,
      courseName: '',
      courseCode: '',
      teacher: '',
      room: '',
      color: '',
      timeText: '',
      entryId: 0
    };
  }

  /** 生成整周视图 */
  buildWeekView(items: ScheduleItem[], semester: Semester, week: number, today: Date): WeekView {
    const days: WeekViewDay[] = [];
    let total: number = 0;
    for (let wd: number = 1; wd <= 7; wd++) {
      const date: Date = ScheduleService.dateOfWeekday(semester, week, wd);
      const courses: DayCourse[] = this.coursesOfDate(items, semester, date);
      total += courses.length;
      const day: WeekViewDay = {
        weekday: wd,
        shortLabel: WEEKDAY_SHORT[wd - 1],
        dateLabel: DateUtil.formatSlashMd(date),
        date: date,
        isToday: DateUtil.isSameDay(date, today),
        cells: this.buildDayColumn(courses),
        courseCount: courses.length
      };
      days.push(day);
    }
    const first: Date = ScheduleService.dateOfWeekday(semester, week, 1);
    const last: Date = ScheduleService.dateOfWeekday(semester, week, 7);
    const view: WeekView = {
      week: week,
      title: `第 ${week} 周`,
      rangeLabel: `${DateUtil.formatSlashMd(first)} – ${DateUtil.formatSlashMd(last)}`,
      days: days,
      courseCount: total
    };
    return view;
  }

  /** 节次时间表的只读访问（设置页展示用） */
  get slots(): SlotTimeTable {
    return this.timeTable;
  }
}

/**
 * 课晓 · 课表编辑（ScheduleEditor）
 * ---------------------------------------------------------------------------
 * 职责：把页面上那些"零散的改动"变成一份完整的课表。
 *
 * 页面自始至终只有一份数据 —— `ScheduleItem[]`（打平的课表项）。
 * 不管是粘贴导入、手动加一门、还是预览里删掉一条，改的都是这一份。
 * 真正落库时才由这里把它还原成 course / schedule_entry 两张表。
 *
 * 为什么要在落库前**重新归并一次课程**？
 *   手动加课时，用户输入的课程名可能和已有课程一模一样（比如补一门实验课）。
 *   如果每次都新建一条 course，"高等数学"就会在库里出现两三条，
 *   颜色、课程详情、以后的统计都会分叉。这里统一按课程名归并。
 *
 * 本文件是纯逻辑（不依赖 @ohos），可以在电脑上用 Node 跑测试。
 * ---------------------------------------------------------------------------
 */

import {
  Course, ImportResult, ScheduleEntry, ScheduleItem, WeekdayNum
} from '../model/Models';
import { colorForCourse } from '../model/Defaults';
import { weeksToText } from './ImportService';
import { parseWeeks } from './TextImportService';

/** 手动添加/编辑一门课的输入 */
export interface ManualCourseForm {
  name: string;
  teacher: string;
  room: string;
  /** 1 = 周一 … 7 = 周日 */
  weekday: number;
  /** 起始节次，1 起 */
  startSlot: number;
  /** 结束节次（含） */
  endSlot: number;
  /** 周次文本，如 '1-16周' / '1-8周' / '单周' */
  weeksText: string;
}

/** 还原成两张表的结果 */
export interface RebuildResult {
  courses: Course[];
  entries: ScheduleEntry[];
}

export class ScheduleEditor {
  /**
   * 校验表单，返回人话错误信息；通过则返回空串。
   * 文案是给用户看的，所以要说"哪里不对、怎么改"，而不是"参数非法"。
   */
  static validate(form: ManualCourseForm): string {
    if (form.name.trim().length === 0) {
      return '课程名不能为空';
    }
    if (form.weekday < 1 || form.weekday > 7) {
      return '请选择星期几';
    }
    if (form.startSlot < 1) {
      return '起始节次不能小于 1';
    }
    if (form.endSlot < form.startSlot) {
      return '结束节次不能早于起始节次';
    }
    if (form.weeksText.trim().length === 0) {
      return '请填写上课周次，例如「1-16周」或「单周」';
    }
    const weeks: number[] = parseWeeks(form.weeksText, true);
    if (weeks.length === 0) {
      return '周次看不懂，试试「1-16周」「1,3,5周」「1-8周」这样的写法';
    }
    return '';
  }

  /** 表单 → 课表项。entryId 传 0 表示"还没分配"，由调用方用 nextEntryId() 补上 */
  static toItem(form: ManualCourseForm, entryId: number, color: string): ScheduleItem {
    const name: string = form.name.trim();
    const weeks: number[] = parseWeeks(form.weeksText, true);
    const weeksRaw: string = form.weeksText.trim().length > 0
      ? form.weeksText.trim() : weeksToText(weeks);
    const item: ScheduleItem = {
      entryId: entryId,
      courseId: 0,
      courseName: name,
      courseCode: '',
      teacher: form.teacher.trim(),
      campus: '',
      room: form.room.trim(),
      color: color.length > 0 ? color : colorForCourse(name),
      weekday: form.weekday as WeekdayNum,
      startSlot: form.startSlot,
      endSlot: form.endSlot,
      weeks: weeks,
      weeksRaw: weeksRaw
    };
    return item;
  }

  /** 课表项 → 表单（点"编辑"时用它回填） */
  static toForm(item: ScheduleItem): ManualCourseForm {
    const form: ManualCourseForm = {
      name: item.courseName,
      teacher: item.teacher,
      room: item.room,
      weekday: item.weekday,
      startSlot: item.startSlot,
      endSlot: item.endSlot,
      weeksText: item.weeksRaw.length > 0 ? item.weeksRaw : weeksToText(item.weeks)
    };
    return form;
  }

  /** 下一个可用的 entryId。entryId = 0 是"没有"的哨兵值，所以从 1 开始 */
  static nextEntryId(items: ScheduleItem[]): number {
    let max: number = 0;
    for (let i = 0; i < items.length; i++) {
      if (items[i].entryId > max) {
        max = items[i].entryId;
      }
    }
    return max + 1;
  }

  /** 新增或替换一条：同 entryId 视为替换，否则追加 */
  static upsert(items: ScheduleItem[], item: ScheduleItem): ScheduleItem[] {
    const out: ScheduleItem[] = [];
    let replaced: boolean = false;
    for (let i = 0; i < items.length; i++) {
      if (items[i].entryId === item.entryId) {
        out.push(item);
        replaced = true;
      } else {
        out.push(items[i]);
      }
    }
    if (!replaced) {
      out.push(item);
    }
    return out;
  }

  /** 删掉一条 */
  static remove(items: ScheduleItem[], entryId: number): ScheduleItem[] {
    const out: ScheduleItem[] = [];
    for (let i = 0; i < items.length; i++) {
      if (items[i].entryId !== entryId) {
        out.push(items[i]);
      }
    }
    return out;
  }

  /**
   * 课表项 → （课程表 + 排课表）。
   *
   * 归并规则：课程名相同就并成一条 course（课程号这里拿不到就用名字当键）。
   * 排课条目的教室/教师仍按原样逐条写，因为同一门课不同时段确实可能换教室。
   */
  static rebuild(items: ScheduleItem[]): RebuildResult {
    const courses: Course[] = [];
    const entries: ScheduleEntry[] = [];
    const idByName: Map<string, number> = new Map<string, number>();
    let courseSeq: number = 1;
    let entrySeq: number = 1;

    for (let i = 0; i < items.length; i++) {
      const it: ScheduleItem = items[i];
      const name: string = it.courseName.trim();
      if (name.length === 0 || it.weeks.length === 0) {
        continue;
      }
      let cid: number | undefined = idByName.get(name);
      if (cid === undefined) {
        cid = courseSeq;
        courseSeq++;
        idByName.set(name, cid);
        const course: Course = {
          id: cid,
          name: name,
          code: it.courseCode,
          teacher: it.teacher,
          campus: it.campus,
          room: it.room,
          color: it.color.length > 0 ? it.color : colorForCourse(name)
        };
        courses.push(course);
      }
      const entry: ScheduleEntry = {
        id: entrySeq,
        courseId: cid,
        weekday: it.weekday,
        startSlot: it.startSlot,
        endSlot: it.endSlot,
        weeks: it.weeks,
        weeksRaw: it.weeksRaw,
        room: it.room,
        teacher: it.teacher,
        campus: it.campus
      };
      entries.push(entry);
      entrySeq++;
    }

    const result: RebuildResult = { courses: courses, entries: entries };
    return result;
  }

  /** 这份课表里最大的周次，也就是总周数 */
  static totalWeeksOf(items: ScheduleItem[]): number {
    let max: number = 0;
    for (let i = 0; i < items.length; i++) {
      const weeks: number[] = items[i].weeks;
      for (let k = 0; k < weeks.length; k++) {
        if (weeks[k] > max) {
          max = weeks[k];
        }
      }
    }
    return max;
  }

  /**
   * 把当前课表打包成一份 ImportResult，直接喂给 ScheduleRepository.saveImport()。
   *
   * 这样"手动改课表"和"粘贴导入"走的是同一条落库路径
   * （全量替换 + 学期起始日保留逻辑），不需要给仓库再加一个入口。
   */
  static buildResult(items: ScheduleItem[], source: string): ImportResult {
    const rebuilt: RebuildResult = ScheduleEditor.rebuild(items);
    // rebuild 会重新编号，这里把 items 同步成落库后的样子，保证界面与库一致
    const normalized: ScheduleItem[] = [];
    for (let i = 0; i < items.length; i++) {
      const it: ScheduleItem = items[i];
      if (it.courseName.trim().length === 0 || it.weeks.length === 0) {
        continue;
      }
      const copy: ScheduleItem = {
        entryId: normalized.length + 1,
        courseId: 0,
        courseName: it.courseName,
        courseCode: it.courseCode,
        teacher: it.teacher,
        campus: it.campus,
        room: it.room,
        color: it.color,
        weekday: it.weekday,
        startSlot: it.startSlot,
        endSlot: it.endSlot,
        weeks: it.weeks,
        weeksRaw: it.weeksRaw
      };
      normalized.push(copy);
    }
    const result: ImportResult = {
      ok: rebuilt.entries.length > 0,
      error: rebuilt.entries.length > 0 ? '' : '课表是空的',
      source: source,
      courses: rebuilt.courses,
      entries: rebuilt.entries,
      items: normalized,
      totalWeeks: ScheduleEditor.totalWeeksOf(items),
      warnings: []
    };
    return result;
  }
}

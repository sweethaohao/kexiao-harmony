/**
 * 课晓 · 课表仓库（ScheduleRepository）
 * ---------------------------------------------------------------------------
 * 页面**唯一**需要认识的存储入口。它把「开库 + 查表 + 拼装 + 写回」
 * 这一串动作包成一个有业务语义的方法（读一整份快照 / 保存一次导入 / 清空），
 * 页面里看不到任何 SQL，也看不到 ResultSet。
 *
 * 分了三层，各管一摊：
 *   ScheduleRepository  业务语义（什么时候读、什么时候整体替换）
 *   ScheduleDao         SQL 执行与结果集搬运
 *   StorageMapper       纯对象转换（可在电脑上自测）
 * ---------------------------------------------------------------------------
 */

import { common } from '@kit.AbilityKit';
import {
  Course, ImportMeta, ImportResult, ScheduleEntry, ScheduleItem, Semester
} from '../model/Models';
import { StorageMapper } from '../service/StorageMapper';
import { ImportService } from '../service/ImportService';
import { DateUtil } from '../common/DateUtil';
import { SINGLETON_ID } from './DbConstants';
import { RdbHelper } from './RdbHelper';
import { ScheduleDao } from './ScheduleDao';

/** 数据库里当前这一份课表的完整快照，启动时一次读齐 */
export interface ScheduleSnapshot {
  /** 学期设置；从未导入过时为 undefined */
  semester: Semester | undefined;
  /** 上次导入的来源与时间；从未导入过时为 undefined */
  meta: ImportMeta | undefined;
  /** 打平后的课表项，页面直接可用 */
  items: ScheduleItem[];
}

export class ScheduleRepository {
  /** 进程内单例：数据库只有一份，仓库也只要一份 */
  private static instance: ScheduleRepository | undefined = undefined;

  private readonly dao: ScheduleDao;

  private constructor(dao: ScheduleDao) {
    this.dao = dao;
  }

  /** 打开数据库并取得仓库（重复调用返回同一个） */
  static async open(context: common.Context): Promise<ScheduleRepository> {
    const cached: ScheduleRepository | undefined = ScheduleRepository.instance;
    if (cached !== undefined) {
      return cached;
    }
    const store = await RdbHelper.open(context);
    const repo: ScheduleRepository = new ScheduleRepository(new ScheduleDao(store));
    ScheduleRepository.instance = repo;
    return repo;
  }

  // =========================================================================
  // 读
  // =========================================================================

  /** 一次读齐页面需要的全部数据 */
  async loadSnapshot(): Promise<ScheduleSnapshot> {
    const courses: Course[] = await this.dao.loadCourses();
    const entries: ScheduleEntry[] = await this.dao.loadEntries();
    const semester: Semester | undefined = await this.dao.loadSemester();
    const meta: ImportMeta | undefined = await this.dao.loadMeta();
    const snapshot: ScheduleSnapshot = {
      semester: semester,
      meta: meta,
      items: StorageMapper.joinItems(courses, entries)
    };
    return snapshot;
  }

  /** 库里有没有课表数据 */
  async hasData(): Promise<boolean> {
    const n: number = await this.dao.countEntries();
    return n > 0;
  }

  // =========================================================================
  // 写
  // =========================================================================

  /**
   * 保存一次导入结果。
   *
   * 学期起始日的取法（重要）：
   *   库里已经有一份用户设过的 → 原样保留，避免重新导入把日期冲掉；
   *   从来没有过 → 按「导入当周就是第 1 周」推算一个初值，
   *     并在界面上提示用户"如果不对请去作息设置里改"。
   *
   * 返回最终生效的学期设置，页面拿它立刻重算课表。
   */
  async saveImport(result: ImportResult, now: Date): Promise<Semester> {
    const existing: Semester | undefined = await this.dao.loadSemester();

    let startDate: string;
    let totalWeeks: number;
    let name: string;
    if (existing === undefined) {
      startDate = ImportService.guessSemesterStart(now);
      totalWeeks = result.totalWeeks > 0 ? result.totalWeeks : 16;
      name = '当前学期';
    } else {
      startDate = existing.startDate;
      totalWeeks = result.totalWeeks > 0 ? result.totalWeeks : existing.totalWeeks;
      name = existing.name.length > 0 ? existing.name : '当前学期';
    }

    const semester: Semester = {
      id: SINGLETON_ID,
      name: name,
      startDate: startDate,
      totalWeeks: totalWeeks
    };
    const meta: ImportMeta = {
      source: result.source,
      importedAt: DateUtil.formatDateTime(now),
      itemCount: result.items.length,
      courseCount: result.courses.length
    };

    await this.dao.replaceAll(result.courses, result.entries, semester, meta);
    return semester;
  }

  /** 只改学期起始日（用户在设置页选完日期后调用） */
  async updateSemesterStart(startDate: string): Promise<void> {
    await this.dao.updateSemesterStart(startDate);
  }

  /** 只改总周数 */
  async updateTotalWeeks(totalWeeks: number): Promise<void> {
    await this.dao.updateTotalWeeks(totalWeeks);
  }

  /** 清空全部课表数据，回到"从未导入"状态 */
  async clearAll(): Promise<void> {
    await this.dao.clear();
  }
}

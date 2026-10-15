/**
 * 课晓 · 课表数据访问对象（ScheduleDao）
 * ---------------------------------------------------------------------------
 * 只做一件事：把 SQL 跑出去、把结果集搬成对象。不含任何业务判断。
 * 业务编排在 ScheduleRepository，纯对象转换在 StorageMapper。
 *
 * ★ 全文件最重要的一条约定：读数据一律走 getColumnIndex(列名) + 下标取值。
 *   绝对不要用 resultSet.getRow() 之后按属性名取 —— release 包开了属性名混淆，
 *   属性名会被改成 a/b/c，而 SQL 列名字符串不会被改，两边对不上就全是 undefined。
 *   这是本项目第三次遇到同类问题（前两次：导入 JSON 契约、示例数据字段），
 *   所以这里直接用最稳的写法。
 *
 * ★ 写入一律用 "SQL + 参数数组"，不要构造 ValuesBucket 对象，理由同上。
 * ---------------------------------------------------------------------------
 */

import { relationalStore } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  Course, CourseRow, EntryRow, ImportMeta, Semester, SemesterRow, ScheduleEntry
} from '../model/Models';
import { StorageMapper } from '../service/StorageMapper';
import {
  Col, SINGLETON_ID, SQL_DELETE_ALL, SQL_INSERT_COURSE, SQL_INSERT_ENTRY,
  SQL_SELECT_COURSES, SQL_SELECT_ENTRIES, SQL_SELECT_META, SQL_SELECT_SEMESTER,
  SQL_UPDATE_SEMESTER_START, SQL_UPSERT_META, SQL_UPSERT_SEMESTER
} from './DbConstants';

const DOMAIN: number = 0x0000;
const TAG: string = 'kexiao-db';

export class ScheduleDao {
  private readonly store: relationalStore.RdbStore;

  constructor(store: relationalStore.RdbStore) {
    this.store = store;
  }

  // =========================================================================
  // 读取
  // =========================================================================

  async loadCourses(): Promise<Course[]> {
    const rs: relationalStore.ResultSet = await this.store.querySql(SQL_SELECT_COURSES);
    const out: Course[] = [];
    try {
      while (rs.goToNextRow()) {
        const row: CourseRow = {
          id: ScheduleDao.getNum(rs, Col.ID),
          name: ScheduleDao.getStr(rs, Col.NAME),
          code: ScheduleDao.getStr(rs, Col.CODE),
          teacher: ScheduleDao.getStr(rs, Col.TEACHER),
          campus: ScheduleDao.getStr(rs, Col.CAMPUS),
          room: ScheduleDao.getStr(rs, Col.ROOM),
          color: ScheduleDao.getStr(rs, Col.COLOR)
        };
        out.push(StorageMapper.rowToCourse(row));
      }
    } finally {
      rs.close();
    }
    return out;
  }

  async loadEntries(): Promise<ScheduleEntry[]> {
    const rs: relationalStore.ResultSet = await this.store.querySql(SQL_SELECT_ENTRIES);
    const out: ScheduleEntry[] = [];
    try {
      while (rs.goToNextRow()) {
        const row: EntryRow = {
          id: ScheduleDao.getNum(rs, Col.ID),
          courseId: ScheduleDao.getNum(rs, Col.COURSE_ID),
          weekday: ScheduleDao.getNum(rs, Col.WEEKDAY),
          startSlot: ScheduleDao.getNum(rs, Col.START_SLOT),
          endSlot: ScheduleDao.getNum(rs, Col.END_SLOT),
          weeksJson: ScheduleDao.getStr(rs, Col.WEEKS),
          weeksRaw: ScheduleDao.getStr(rs, Col.WEEKS_RAW),
          room: ScheduleDao.getStr(rs, Col.ROOM),
          teacher: ScheduleDao.getStr(rs, Col.TEACHER),
          campus: ScheduleDao.getStr(rs, Col.CAMPUS)
        };
        out.push(StorageMapper.rowToEntry(row));
      }
    } finally {
      rs.close();
    }
    return out;
  }

  /** 读学期设置；还没导入过时返回 undefined */
  async loadSemester(): Promise<Semester | undefined> {
    const rs: relationalStore.ResultSet =
      await this.store.querySql(SQL_SELECT_SEMESTER, [SINGLETON_ID]);
    try {
      if (!rs.goToNextRow()) {
        return undefined;
      }
      const row: SemesterRow = {
        id: ScheduleDao.getNum(rs, Col.ID),
        name: ScheduleDao.getStr(rs, Col.NAME),
        startDate: ScheduleDao.getStr(rs, Col.START_DATE),
        totalWeeks: ScheduleDao.getNum(rs, Col.TOTAL_WEEKS)
      };
      const semester: Semester = {
        id: row.id,
        name: row.name,
        startDate: row.startDate,
        totalWeeks: row.totalWeeks
      };
      return semester;
    } finally {
      rs.close();
    }
  }

  /** 读上一次导入的来源信息；还没导入过时返回 undefined */
  async loadMeta(): Promise<ImportMeta | undefined> {
    const rs: relationalStore.ResultSet =
      await this.store.querySql(SQL_SELECT_META, [SINGLETON_ID]);
    try {
      if (!rs.goToNextRow()) {
        return undefined;
      }
      const meta: ImportMeta = {
        source: ScheduleDao.getStr(rs, Col.SOURCE),
        importedAt: ScheduleDao.getStr(rs, Col.IMPORTED_AT),
        itemCount: ScheduleDao.getNum(rs, Col.ITEM_COUNT),
        courseCount: ScheduleDao.getNum(rs, Col.COURSE_COUNT)
      };
      return meta;
    } finally {
      rs.close();
    }
  }

  /** 库里有没有课表数据（用于判断"首次打开该显示空态还是直接进日程"） */
  async countEntries(): Promise<number> {
    const rs: relationalStore.ResultSet =
      await this.store.querySql('SELECT COUNT(*) AS c FROM schedule_entry');
    try {
      if (!rs.goToNextRow()) {
        return 0;
      }
      return ScheduleDao.getNum(rs, 'c');
    } finally {
      rs.close();
    }
  }

  // =========================================================================
  // 写入
  // =========================================================================

  /**
   * 全量替换：一次导入 = 整个学期的课表。
   * 整个过程包在一个事务里，中途任何一步失败都会整体回滚，
   * 不会出现"旧数据删了、新数据没写完"的半套状态。
   */
  async replaceAll(courses: Course[], entries: ScheduleEntry[],
    semester: Semester, meta: ImportMeta): Promise<void> {
    this.store.beginTransaction();
    try {
      for (let i = 0; i < SQL_DELETE_ALL.length; i++) {
        await this.store.executeSql(SQL_DELETE_ALL[i]);
      }
      for (let i = 0; i < courses.length; i++) {
        const c: Course = courses[i];
        const args: Array<relationalStore.ValueType> =
          [c.id, c.name, c.code, c.teacher, c.campus, c.room, c.color];
        await this.store.executeSql(SQL_INSERT_COURSE, args);
      }
      for (let i = 0; i < entries.length; i++) {
        const e: ScheduleEntry = entries[i];
        const args: Array<relationalStore.ValueType> = [
          e.id, e.courseId, e.weekday, e.startSlot, e.endSlot,
          StorageMapper.weeksToJson(e.weeks), e.weeksRaw, e.room, e.teacher, e.campus
        ];
        await this.store.executeSql(SQL_INSERT_ENTRY, args);
      }
      await this.store.executeSql(SQL_UPSERT_SEMESTER,
        [semester.id, semester.name, semester.startDate, semester.totalWeeks]);
      await this.store.executeSql(SQL_UPSERT_META,
        [SINGLETON_ID, meta.source, meta.importedAt, meta.itemCount, meta.courseCount]);
      this.store.commit();
      hilog.info(DOMAIN, TAG, 'saved %{public}d courses / %{public}d entries',
        courses.length, entries.length);
    } catch (err) {
      this.store.rollBack();
      hilog.error(DOMAIN, TAG, 'replaceAll failed: %{public}s', JSON.stringify(err));
      // ArkTS 只允许 throw 一个 Error 实例，不能把捕获到的任意值原样抛出
      throw new Error(`写入课表失败：${JSON.stringify(err)}`);
    }
  }

  /** 只改学期起始日（用户手选日期后调用，不动课表数据） */
  async updateSemesterStart(startDate: string): Promise<void> {
    await this.store.executeSql(SQL_UPDATE_SEMESTER_START, [startDate, SINGLETON_ID]);
  }

  /** 只改学期总周数 */
  async updateTotalWeeks(totalWeeks: number): Promise<void> {
    await this.store.executeSql(
      'UPDATE semester SET total_weeks = ? WHERE id = ?', [totalWeeks, SINGLETON_ID]);
  }

  /** 清空全部课表数据（学期与导入信息一并清掉，回到"从未导入"状态） */
  async clear(): Promise<void> {
    this.store.beginTransaction();
    try {
      for (let i = 0; i < SQL_DELETE_ALL.length; i++) {
        await this.store.executeSql(SQL_DELETE_ALL[i]);
      }
      this.store.commit();
      hilog.info(DOMAIN, TAG, 'all schedule data cleared');
    } catch (err) {
      this.store.rollBack();
      hilog.error(DOMAIN, TAG, 'clear failed: %{public}s', JSON.stringify(err));
      throw new Error(`清空课表失败：${JSON.stringify(err)}`);
    }
  }

  // =========================================================================
  // 取值小工具（统一走列名 → 下标，避免混淆踩坑）
  // =========================================================================

  private static getStr(rs: relationalStore.ResultSet, col: string): string {
    const idx: number = rs.getColumnIndex(col);
    if (idx < 0 || rs.isColumnNull(idx)) {
      return '';
    }
    return rs.getString(idx);
  }

  private static getNum(rs: relationalStore.ResultSet, col: string): number {
    const idx: number = rs.getColumnIndex(col);
    if (idx < 0 || rs.isColumnNull(idx)) {
      return 0;
    }
    return rs.getLong(idx);
  }
}

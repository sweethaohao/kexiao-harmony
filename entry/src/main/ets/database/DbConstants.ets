/**
 * 课晓 · 持久化常量（库名 / 表名 / 列名 / SQL）
 * ---------------------------------------------------------------------------
 * 为什么要单独一个文件？
 *   1. 表结构和 SQL 是"契约"，改一处要连着改好几处，集中放这里最不容易漏；
 *   2. 这个文件里**没有任何系统能力依赖**（不 import @kit.*），
 *      所以自测脚本能直接把它搬到 Node 上跑，验证 SQL 常量本身没问题；
 *   3. 所有列名都是字符串字面量 —— release 混淆只改"属性名"，不改字符串，
 *      因此用 getColumnIndex(列名) 读数据在混淆后依然可靠。
 *
 * ⚠️ 改表结构时：DB_VERSION 加 1，并在 RdbHelper.open() 里补迁移分支。
 * ---------------------------------------------------------------------------
 */

/** 数据库文件名（落在应用沙箱内，不上传、不进安装包） */
export const DB_NAME: string = 'kexiao.db';

/** 表结构版本：任何建表语句变化都必须 +1 */
export const DB_VERSION: number = 1;

/** 学期与导入信息都是"单例表"，固定只存一行，主键恒为 1 */
export const SINGLETON_ID: number = 1;

/** 表名 */
export class Table {
  static readonly COURSE: string = 'course';
  static readonly ENTRY: string = 'schedule_entry';
  static readonly SEMESTER: string = 'semester';
  static readonly META: string = 'import_meta';
}

/** 列名。读取时统一用 Col.XXX 传给 getColumnIndex()，避免手写字符串写错 */
export class Col {
  static readonly ID: string = 'id';

  // ---- course ----
  static readonly NAME: string = 'name';
  static readonly CODE: string = 'code';
  static readonly TEACHER: string = 'teacher';
  static readonly CAMPUS: string = 'campus';
  static readonly ROOM: string = 'room';
  static readonly COLOR: string = 'color';

  // ---- schedule_entry ----
  static readonly COURSE_ID: string = 'course_id';
  static readonly WEEKDAY: string = 'weekday';
  static readonly START_SLOT: string = 'start_slot';
  static readonly END_SLOT: string = 'end_slot';
  static readonly WEEKS: string = 'weeks';
  static readonly WEEKS_RAW: string = 'weeks_raw';

  // ---- semester ----
  static readonly START_DATE: string = 'start_date';
  static readonly TOTAL_WEEKS: string = 'total_weeks';

  // ---- import_meta ----
  static readonly SOURCE: string = 'source';
  static readonly IMPORTED_AT: string = 'imported_at';
  static readonly ITEM_COUNT: string = 'item_count';
  static readonly COURSE_COUNT: string = 'course_count';
}

/**
 * 建表语句。
 * 全部带 IF NOT EXISTS，所以每次启动无脑执行一遍是安全的 ——
 * 这样"首次安装"和"以后每次启动"走的是同一条代码路径，不用两套逻辑。
 */
export const CREATE_TABLES: string[] = [
  'CREATE TABLE IF NOT EXISTS course ('
  + '  id INTEGER PRIMARY KEY,'
  + '  name TEXT NOT NULL DEFAULT \'\','
  + '  code TEXT NOT NULL DEFAULT \'\','
  + '  teacher TEXT NOT NULL DEFAULT \'\','
  + '  campus TEXT NOT NULL DEFAULT \'\','
  + '  room TEXT NOT NULL DEFAULT \'\','
  + '  color TEXT NOT NULL DEFAULT \'\''
  + ')',

  'CREATE TABLE IF NOT EXISTS schedule_entry ('
  + '  id INTEGER PRIMARY KEY,'
  + '  course_id INTEGER NOT NULL,'
  + '  weekday INTEGER NOT NULL,'
  + '  start_slot INTEGER NOT NULL,'
  + '  end_slot INTEGER NOT NULL,'
  + '  weeks TEXT NOT NULL DEFAULT \'[]\','
  + '  weeks_raw TEXT NOT NULL DEFAULT \'\','
  + '  room TEXT NOT NULL DEFAULT \'\','
  + '  teacher TEXT NOT NULL DEFAULT \'\','
  + '  campus TEXT NOT NULL DEFAULT \'\''
  + ')',

  'CREATE INDEX IF NOT EXISTS idx_entry_weekday ON schedule_entry (weekday)',

  'CREATE TABLE IF NOT EXISTS semester ('
  + '  id INTEGER PRIMARY KEY,'
  + '  name TEXT NOT NULL DEFAULT \'\','
  + '  start_date TEXT NOT NULL DEFAULT \'\','
  + '  total_weeks INTEGER NOT NULL DEFAULT 0'
  + ')',

  'CREATE TABLE IF NOT EXISTS import_meta ('
  + '  id INTEGER PRIMARY KEY,'
  + '  source TEXT NOT NULL DEFAULT \'\','
  + '  imported_at TEXT NOT NULL DEFAULT \'\','
  + '  item_count INTEGER NOT NULL DEFAULT 0,'
  + '  course_count INTEGER NOT NULL DEFAULT 0'
  + ')'
];

/** 全量替换时先清空这四张表（顺序无所谓，表之间没有外键约束） */
export const SQL_DELETE_ALL: string[] = [
  'DELETE FROM course',
  'DELETE FROM schedule_entry',
  'DELETE FROM semester',
  'DELETE FROM import_meta'
];

/**
 * 写入语句。
 * 一律用 "SQL + 参数数组" 的写法，而不是构造 ValuesBucket 对象：
 * 参数是数组、SQL 是字符串字面量，两边都不受属性名混淆影响。
 */
export const SQL_INSERT_COURSE: string =
  'INSERT OR REPLACE INTO course (id, name, code, teacher, campus, room, color)'
  + ' VALUES (?, ?, ?, ?, ?, ?, ?)';

export const SQL_INSERT_ENTRY: string =
  'INSERT OR REPLACE INTO schedule_entry'
  + ' (id, course_id, weekday, start_slot, end_slot, weeks, weeks_raw, room, teacher, campus)'
  + ' VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)';

export const SQL_UPSERT_SEMESTER: string =
  'INSERT OR REPLACE INTO semester (id, name, start_date, total_weeks) VALUES (?, ?, ?, ?)';

export const SQL_UPSERT_META: string =
  'INSERT OR REPLACE INTO import_meta (id, source, imported_at, item_count, course_count)'
  + ' VALUES (?, ?, ?, ?, ?)';

/** 只改学期起始日（用户在设置页选日期时用） */
export const SQL_UPDATE_SEMESTER_START: string =
  'UPDATE semester SET start_date = ? WHERE id = ?';

/** 查询语句 */
export const SQL_SELECT_COURSES: string =
  'SELECT id, name, code, teacher, campus, room, color FROM course ORDER BY id';

export const SQL_SELECT_ENTRIES: string =
  'SELECT id, course_id, weekday, start_slot, end_slot, weeks, weeks_raw, room, teacher, campus'
  + ' FROM schedule_entry ORDER BY weekday, start_slot';

export const SQL_SELECT_SEMESTER: string =
  'SELECT id, name, start_date, total_weeks FROM semester WHERE id = ?';

export const SQL_SELECT_META: string =
  'SELECT source, imported_at, item_count, course_count FROM import_meta WHERE id = ?';

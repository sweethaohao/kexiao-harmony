/**
 * 课晓 · 数据模型
 * ---------------------------------------------------------------------------
 * 设计要点
 *  1. 「一校一格式」：本文件只定义「课晓 内部标准格式」，
 *     外部教务系统格式的差异全部由 ImportService 消化。
 *  2. 「课程」与「上课时间」解耦：
 *     Course 只存一门课的元信息，ScheduleEntry 存「什么时候上、上多少周」，
 *     两者用 courseId 关联。
 *  3. 「按周展开」：同一门课在不同周次可能是不同的课，
 *     ScheduleEntry.weeks 用数组存周次，判断"本周是否要上"只需 weeks.includes(周次)。
 * ---------------------------------------------------------------------------
 */

/** 星期序号：1 = 周一 … 7 = 周日（ISO 约定，周一到周日） */
export type WeekdayNum = number;

/** 时段标识：上午 / 下午 / 晚上 */
export type PeriodKey = 'morning' | 'afternoon' | 'evening';

// ===========================================================================
// 一、持久化实体
// ===========================================================================

/** 课程：一门课的元信息，与"什么时候上"解耦 */
export interface Course {
  /** 主键，自增 */
  id: number;
  /** 课程名，如「高等数学（上）」 */
  name: string;
  /** 课程号，教务系统内的唯一标识，如「MA1011」；可能为空 */
  code: string;
  /** 教师（该课程首次出现时的教师，用于课程管理页展示） */
  teacher: string;
  /** 校区，如「主校区」 */
  campus: string;
  /** 教室（同上，为"主教室"；逐条排课的实际教室见 ScheduleEntry） */
  room: string;
  /** 课表着色用的颜色（由课程名哈希生成，保证同名课颜色一致） */
  color: string;
}

/**
 * 排课条目 ★核心
 * 一条 = 「某门课 · 某星期 · 某节次区间 · 某周次集合」
 *
 * 注意：room / teacher / campus 在这里也存了一份，而不是只用 Course 上的。
 * 原因：真实课表里同一门课在不同时段/不同周次可能换教室、换老师
 * （例如同一门课的理论课在 B305、实验课换到实验楼 2-201）。
 * Course 上的是"主教室/主教师"，ScheduleEntry 上的是"这一条排课实际的"。
 */
export interface ScheduleEntry {
  /** 主键，自增 */
  id: number;
  /** 外键 → Course.id */
  courseId: number;
  /** 星期，1 = 周一 … 7 = 周日 */
  weekday: WeekdayNum;
  /** 起始节次，1 = 第一节 */
  startSlot: number;
  /** 结束节次（含），如「第5-8节」→ 5 / 8 */
  endSlot: number;
  /** 上课周次列表，如 [1,2,3,5,6,7,8,9,10,11,12]（支持不连续并集） */
  weeks: number[];
  /** 原始周次文本，如「1~3,5~12周」，用于回显与排错 */
  weeksRaw: string;
  /** 这一条排课实际的教室 */
  room: string;
  /** 这一条排课实际的教师 */
  teacher: string;
  /** 这一条排课实际的校区 */
  campus: string;
}

/** 学期 */
export interface Semester {
  /** 主键 */
  id: number;
  /** 学期名，如「2026 秋季学期」 */
  name: string;
  /**
   * 第 1 周的周一日期，格式 yyyy-MM-dd。
   * ⚠️ 这是提醒功能的基石：只有知道"第 N 周的周一"是哪天，
   *    才能把「第 5 周星期三第 1-2 节」换算成真实日期时间。
   */
  startDate: string;
  /** 总周数（由导入数据推断，取所有 weeks 的最大值） */
  totalWeeks: number;
}

/** 作业 / 待办（二期） */
export interface Todo {
  id: number;
  /** 标题（来自作业网页标题或用户手动输入） */
  title: string;
  /** 来源：manual / yuketang / zhidao / other */
  source: string;
  /** 作业网页链接，点击直接跳转 */
  url: string;
  /** 截止时间，ISO 字符串 */
  dueAt: string;
  /** 创建时间，ISO 字符串 */
  createdAt: string;
}

/** 提醒 / 闹钟（二期） */
export interface Reminder {
  id: number;
  /** 关联类型：schedule（课表） / todo（作业） */
  refType: string;
  /** 关联对象 id */
  refId: number;
  /** 触发时间，ISO 字符串 */
  triggerAt: string;
  /** 提前量（分钟），如 10 表示提前 10 分钟提醒 */
  advanceMinutes: number;
  /** 是否启用 */
  enabled: boolean;
}

// ===========================================================================
// 二、运行期视图模型（服务层 → UI 层的主要数据形态）
// ===========================================================================

/**
 * 扁平课表项：课程元信息 + 单条排课信息打平成一个对象。
 * UI 渲染、日期换算都直接用它，不必再跨表查。
 */
export interface ScheduleItem {
  /** 来源 ScheduleEntry.id */
  entryId: number;
  /** 来源 Course.id */
  courseId: number;
  courseName: string;
  courseCode: string;
  teacher: string;
  campus: string;
  room: string;
  color: string;
  weekday: WeekdayNum;
  startSlot: number;
  endSlot: number;
  weeks: number[];
  weeksRaw: string;
}

/** 某一天的一节课，带上了换算好的真实日期时间 */
export interface DayCourse {
  item: ScheduleItem;
  /** 上课那天的日期（00:00） */
  date: Date;
  /** 真实开始时间 */
  start: Date;
  /** 真实结束时间 */
  end: Date;
}

// ===========================================================================
// 三、时间表配置（所有时间参数可自定义）
// ===========================================================================

/**
 * 单个时段（上午 / 下午 / 晚上）的排课参数。
 *
 * 课晓 的节次体系是「大课 = 若干小课相连」的嵌套结构：
 *   - 一节小课通常是 45 分钟；
 *   - 一节大课 = 2 节小课连上（共 90 分钟），小课之间通常没有课间；
 *   - 大课与大课之间是 15 分钟课间。
 * 另外某些时段末尾会有"零散小课"（例如晚上：1 节大课 + 3 节小课）。
 */
export interface PeriodConfig {
  /** 时段标识 */
  key: PeriodKey;
  /** 时段显示名，如「上午」 */
  label: string;
  /** 该时段第一节的开始时间，格式 HH:mm */
  startTime: string;
  /** 该时段包含几节"大课" */
  bigCourseCount: number;
  /** 每节大课由几节小课相连组成（通常 2） */
  smallPerBig: number;
  /** 一节小课的时长（分钟，通常 45） */
  smallSlotMinutes: number;
  /** 大课内部、小课之间的间隔（分钟，通常 0 = 连着上） */
  breakInBigMinutes: number;
  /** 大课与大课之间的课间（分钟，通常 15）；也用于追加小课之间的间隔 */
  breakBetweenBigMinutes: number;
  /** 时段末尾额外追加的小课数量（早上/下午通常 0，晚上通常 3） */
  trailingSmallCount: number;
}

/** 一个具体节次的时间信息（由 PeriodConfig 计算得出） */
export interface SlotTime {
  /** 节次号，1 起 */
  slot: number;
  /** 开始时间 HH:mm */
  start: string;
  /** 结束时间 HH:mm */
  end: string;
  /** 开始时间转成"当天第几分钟"，便于排序与比较 */
  startMinutes: number;
  /** 结束时间转成"当天第几分钟" */
  endMinutes: number;
  /** 属于哪个时段 */
  periodKey: PeriodKey;
  /** 时段显示名 */
  periodLabel: string;
}

// ===========================================================================
// 四、导入 JSON 的结构（schemaVersion = 1）
// ===========================================================================

/** 导入文件里的一条课程记录（由 tools/parse_schedule.py 生成） */
export interface ImportEntryJson {
  courseName: string;
  courseCode: string;
  startSlot: number;
  endSlot: number;
  weeks: number[];
  weeksRaw: string;
  campus: string;
  room: string;
  teacher: string;
  /** 中文星期，如「星期一」 */
  weekday: string;
  /** 原始节次文本，如「第三节」（仅作回显，不参与计算） */
  slot: string;
}

/** 导入文件的顶层结构 */
export interface ImportFileJson {
  schemaVersion: number;
  source: string;
  courseCount: number;
  entries: ImportEntryJson[];
}

/** 导入结果 */
export interface ImportResult {
  /** 是否导入成功（结构性失败时为 false，此时 error 有值） */
  ok: boolean;
  /** 失败原因 */
  error: string;
  /** 数据来源描述，如「我的课表.docx」 */
  source: string;
  /** 归并后的课程列表 */
  courses: Course[];
  /** 排课条目 */
  entries: ScheduleEntry[];
  /** 打平后的可展示项 */
  items: ScheduleItem[];
  /** 推断出的总周数 */
  totalWeeks: number;
  /** 非致命问题提示（如某条记录星期无法识别被跳过） */
  warnings: string[];
}

// ===========================================================================
// 五、视图辅助类型
// ===========================================================================

/**
 * 周视图中的一格：要么是一节课，要么是空白占位。
 *
 * 为什么把所有字段拍平、不放一个嵌套的 DayCourse 对象？
 * ArkUI 的 build()/@Builder 里，对"可选字段"做类型收窄（if (x.y !== undefined)）不太可靠，
 * 所以这里刻意做成"无可选字段"的扁平结构，UI 直接读字符串，最不容易踩坑。
 */
export interface DayCell {
  /** 'course' = 课程格；'empty' = 空白格 */
  kind: string;
  /** 这一格从第几节开始 */
  slot: number;
  /** 这一格跨越几个节次（课程格 ≥ 1 表示合并了几个单元格；空白格 = 1） */
  span: number;
  /** 课程名；空白格为空串 */
  courseName: string;
  /** 课程号；空白格为空串 */
  courseCode: string;
  /** 教师；空白格为空串 */
  teacher: string;
  /** 教室；空白格为空串 */
  room: string;
  /** 课程配色；空白格为空串 */
  color: string;
  /** 时间段文本，如 '08:00-09:30'；空白格为空串 */
  timeText: string;
  /** 该节课的 ScheduleEntry.id；空白格为 0 */
  entryId: number;
}

/** 周视图中的一列（一天） */
export interface WeekViewDay {
  /** 1 = 周一 … 7 = 周日 */
  weekday: WeekdayNum;
  /** 「周一」 */
  shortLabel: string;
  /** 「10/14」 */
  dateLabel: string;
  /** 该天的真实日期 */
  date: Date;
  /** 是否是今天 */
  isToday: boolean;
  /** 该天的格子（已按节次顺序排好） */
  cells: DayCell[];
  /** 该天共有几节课 */
  courseCount: number;
}

/** 完整的一周视图 */
export interface WeekView {
  /** 第几周 */
  week: number;
  /** 「第 8 周」 */
  title: string;
  /** 「10/12 – 10/18」 */
  rangeLabel: string;
  /** 7 天 */
  days: WeekViewDay[];
  /** 这一周一共有几节课 */
  courseCount: number;
}

/** 今明日程（小窗口时间线的数据） */
export interface DailyBrief {
  /** 'today' = 展示今天；'upcoming' = 今天已全过去，展示往后最近有课的一天 */
  mode: string;
  /** 「今天」/「明天」/「10月20日 周二」 */
  title: string;
  /** 对应的日期（00:00） */
  date: Date;
  /** 星期序号 */
  weekday: WeekdayNum;
  /** 这一天的课（按开始时间排序） */
  courses: DayCourse[];
  /** 今天是否已经全部上完 */
  allPassed: boolean;
  /** 正在上的那节课的 entryId；当前没有课则为 0 */
  currentEntryId: number;
  /** 紧接着要上的那节课的 entryId；没有则为 0 */
  nextEntryId: number;
  /** 给用户的一句提示，如「今天的课都上完啦」 */
  hint: string;
}

// ===========================================================================
// 六、常量
// ===========================================================================

/** 星期的中文短标签，下标 0 对应周一 */
export const WEEKDAY_SHORT: string[] = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

/** 星期的中文全称，下标 0 对应周一 */
export const WEEKDAY_FULL: string[] = [
  '星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'
];

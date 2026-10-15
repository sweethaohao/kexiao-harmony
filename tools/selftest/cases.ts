/**
 * 课晓 · 逻辑自测用例
 * ---------------------------------------------------------------------------
 * 这个文件不在鸿蒙工程编译范围内（在 tools/ 下），
 * 它的作用是：把 entry/src/main/ets 里的"纯逻辑"搬到 Node 上跑，
 * 这样在模拟器还没就绪时也能验证逻辑对不对。
 *
 * 运行方式：node tools/selftest/run.mjs
 * ---------------------------------------------------------------------------
 */

import { ScheduleService } from '../../entry/src/main/ets/service/ScheduleService';
import { ImportService } from '../../entry/src/main/ets/service/ImportService';
import { createDefaultTimeTable, DEFAULT_PERIOD_CONFIGS } from '../../entry/src/main/ets/model/Defaults';
import { DateUtil } from '../../entry/src/main/ets/common/DateUtil';
import { SlotTimeTable } from '../../entry/src/main/ets/common/SlotTimeTable';
import { Course, ScheduleEntry, Semester, ScheduleItem } from '../../entry/src/main/ets/model/Models';
import { StorageMapper } from '../../entry/src/main/ets/service/StorageMapper';
import {
  TextImportService, parseWeeks, parseSlots, stripWeeks, looksLikeRoom, looksLikeTeacher,
  weeksAreTrustworthy, isGroupSeparator
} from '../../entry/src/main/ets/service/TextImportService';
import { ScheduleEditor, ManualCourseForm, RebuildResult } from '../../entry/src/main/ets/service/ScheduleEditor';
import { XlsxService, XlsxClassInfo, XlsxSheetTarget } from '../../entry/src/main/ets/service/XlsxService';
import { XLSX_SHARED_XML, XLSX_SHEET_XML, XLSX_WORKBOOK_XML, XLSX_RELS_XML } from './fixture-xlsx';
import { HtmlTableService } from '../../entry/src/main/ets/service/HtmlTableService';
import { SCHEDULE_JSON_TEXT } from './fixture';

// =============================================================================
// 迷你测试框架
// =============================================================================
let passed: number = 0;
let failed: number = 0;
let currentGroup: string = '';

function group(name: string): void {
  currentGroup = name;
  console.log(`\n=== ${name} ===`);
}

function check(title: string, actual: unknown, expected: unknown): void {
  const a: string = JSON.stringify(actual);
  const e: string = JSON.stringify(expected);
  if (a === e) {
    passed++;
    console.log(`  ✅ ${title}`);
  } else {
    failed++;
    console.log(`  ❌ ${title}\n       期望: ${e}\n       实际: ${a}`);
  }
}

function checkTrue(title: string, actual: boolean): void {
  check(title, actual, true);
}

// =============================================================================
// 一、节次时间表：大课 = 多小课相连 的生成是否正确
// =============================================================================
group('一、节次时间表生成（课晓默认作息）');

const tt: SlotTimeTable = createDefaultTimeTable();

check('共生成 13 节', tt.count, 13);
check('第1节', tt.labelOf(1), '08:00-08:45');
check('第2节（与第1节连上，无课间）', tt.labelOf(2), '08:45-09:30');
check('第3节（大课间休息 15 分钟）', tt.labelOf(3), '09:45-10:30');
check('第4节 = 上午下课 11:15', tt.labelOf(4), '10:30-11:15');
check('第5节 = 下午 12:40 开始', tt.labelOf(5), '12:40-13:25');
check('第8节 = 下午下课 15:55', tt.labelOf(8), '15:10-15:55');
check('第9节 = 晚上 17:00 开始', tt.labelOf(9), '17:00-17:45');
check('第10节 = 晚上第一节大课 18:30 结束', tt.labelOf(10), '17:45-18:30');
check('第11节 = 追加小课 18:45 开始', tt.labelOf(11), '18:45-19:30');
check('第13节 = 最后一节', tt.labelOf(13), '20:45-21:30');
check('第1节属于上午', tt.periodLabelOf(1), '上午');
check('第6节属于下午', tt.periodLabelOf(6), '下午');
check('第12节属于晚上', tt.periodLabelOf(12), '晚上');
check('上午时段摘要', tt.periodSummary('morning'), '上午 08:00-11:15');
check('下午时段摘要', tt.periodSummary('afternoon'), '下午 12:40-15:55');
check('晚上时段摘要', tt.periodSummary('evening'), '晚上 17:00-21:30');
checkTrue('越界取节返回 undefined', tt.tryAt(14) === undefined);

// 自定义作息：验证"所有参数可改"
group('二、节次时间表可自定义');
const custom: SlotTimeTable = SlotTimeTable.build([
  {
    key: 'morning', label: '上午', startTime: '07:30',
    bigCourseCount: 2, smallPerBig: 3, smallSlotMinutes: 40,
    breakInBigMinutes: 5, breakBetweenBigMinutes: 20, trailingSmallCount: 0
  }
]);
check('3 小课 × 40 分钟 + 5 分钟内部间隔', custom.labelOf(1), '07:30-08:10');
check('大课内第 2 小课', custom.labelOf(2), '08:15-08:55');
check('大课内第 3 小课', custom.labelOf(3), '09:00-09:40');
check('大课之间 20 分钟课间', custom.labelOf(4), '10:00-10:40');
check('共 6 节', custom.count, 6);

// =============================================================================
// 三、日期工具
// =============================================================================
group('三、日期工具');
check('2026-09-07 是周一', DateUtil.weekdayNum(new Date(2026, 8, 7)), 1);
check('2026-10-14 是周三', DateUtil.weekdayNum(new Date(2026, 9, 14)), 3);
check('2026-10-18 是周日', DateUtil.weekdayNum(new Date(2026, 9, 18)), 7);
check('2026-10-14 所在周的周一', DateUtil.formatDate(DateUtil.mondayOf(new Date(2026, 9, 14))), '2026-10-12');
check('周一往前推仍是自己', DateUtil.formatDate(DateUtil.mondayOf(new Date(2026, 8, 7))), '2026-09-07');
check('跨月加天数', DateUtil.formatDate(DateUtil.addDays(new Date(2026, 8, 30), 5)), '2026-10-05');
check("'08:00' → 480 分钟", DateUtil.hmToMinutes('08:00'), 480);
check('900 分钟 → 15:00', DateUtil.minutesToHm(900), '15:00');
check('同一天判定', DateUtil.isSameDay(new Date(2026, 9, 14, 1), new Date(2026, 9, 14, 23)), true);

// =============================================================================
// 四、周次换算
// =============================================================================
group('四、第 N 周 ↔ 真实日期');
const semester: Semester = {
  id: 1, name: '2026 秋季学期', startDate: '2026-09-07', totalWeeks: 16
};
check('开学当天 = 第 1 周', ScheduleService.weekOfDate(semester, new Date(2026, 8, 7)), 1);
check('开学前一周 = 第 0 周', ScheduleService.weekOfDate(semester, new Date(2026, 7, 31)), 0);
check('2026-09-14 = 第 2 周', ScheduleService.weekOfDate(semester, new Date(2026, 8, 14)), 2);
check('2026-10-14 = 第 6 周', ScheduleService.weekOfDate(semester, new Date(2026, 9, 14)), 6);
check('第 6 周周三的日期', DateUtil.formatDate(ScheduleService.dateOfWeekday(semester, 6, 3)), '2026-10-14');
check('第 1 周周一的日期', DateUtil.formatDate(ScheduleService.dateOfWeekday(semester, 1, 1)), '2026-09-07');
check('第 16 周周日的日期', DateUtil.formatDate(ScheduleService.dateOfWeekday(semester, 16, 7)), '2026-12-27');
check('开学前不算在学期内', ScheduleService.inSemester(semester, new Date(2026, 7, 31)), false);
check('2026-10-14 在学期内', ScheduleService.inSemester(semester, new Date(2026, 9, 14)), true);

// =============================================================================
// 五、示例课表导入
// =============================================================================
group('五、导入示例课表 sample-schedule.json');
const imported = ImportService.parse(SCHEDULE_JSON_TEXT);
checkTrue('导入成功', imported.ok);
check('排课条数 = 12', imported.items.length, 12);
check('总周数 = 16', imported.totalWeeks, 16);
checkTrue('课程去重后少于条目数（同一门体育课排了两天）', imported.courses.length < imported.items.length);
check('无跳过告警', imported.warnings.filter((w: string) => w.indexOf('跳过') >= 0).length, 0);

const byName = (name: string, weekday: number): ScheduleItem[] =>
  imported.items.filter((i: ScheduleItem) => i.courseName === name && i.weekday === weekday);

const calculus = byName('微积分（上）', 1)[0];
check('微积分（上） 星期一 第1-2节', `${calculus.startSlot}-${calculus.endSlot}`, '1-2');
check('微积分（上）周次 1~12', calculus.weeks.join(','), '1,2,3,4,5,6,7,8,9,10,11,12');
check('微积分（上）教室', calculus.room, 'A101');

const introLab = imported.items.filter((i: ScheduleItem) => i.courseName === '计算机导论实验')[0];
check('计算机导论实验周次 13~16', introLab.weeks.join(','), '13,14,15,16');
checkTrue('计算机导论实验有跨节次', introLab.endSlot > introLab.startSlot);

// 同一门课排在不同的两天时应归并成一门课程（体育课周一/周四各一次）
const peItems = imported.items.filter((i: ScheduleItem) => i.courseName === '体育（1）');
check('体育（1）共 2 条排课', peItems.length, 2);
check('体育（1）归并为 1 门课程', peItems[0].courseId === peItems[1].courseId, true);

// 并集周次：确认某条记录确实是"中间断了一周"的
const unionEntry = imported.items.filter((i: ScheduleItem) => i.weeksRaw.indexOf(',') >= 0)[0];
checkTrue('存在并集周次记录（大学英语 1~3,5~12周）', unionEntry !== undefined);
check('并集周次的课程名', unionEntry.courseName, '大学英语（3）');

// =============================================================================
// 六、周视图：本周该上哪些课
// =============================================================================
group('六、周视图过滤');
const svc: ScheduleService = new ScheduleService(tt);
const today: Date = new Date(2026, 9, 14, 10, 0); // 2026-10-14 周三 10:00

const view1 = svc.buildWeekView(imported.items, semester, 1, today);
const week1Names: string[] = [];
for (let i = 0; i < view1.days.length; i++) {
  const cells = view1.days[i].cells;
  for (let j = 0; j < cells.length; j++) {
    const c = cells[j];
    if (c.kind === 'course') {
      week1Names.push(c.courseName);
    }
  }
}
checkTrue('第 1 周应包含微积分（上）', week1Names.indexOf('微积分（上）') >= 0);
checkTrue('第 1 周不应包含计算机导论实验（13~16 周才上）', week1Names.indexOf('计算机导论实验') < 0);
checkTrue('第 1 周有课', week1Names.length > 0);

const view13 = svc.buildWeekView(imported.items, semester, 13, today);
const week13Names: string[] = [];
for (let i = 0; i < view13.days.length; i++) {
  const cells = view13.days[i].cells;
  for (let j = 0; j < cells.length; j++) {
    const c = cells[j];
    if (c.kind === 'course') {
      week13Names.push(c.courseName);
    }
  }
}
checkTrue('第 13 周应包含计算机导论实验', week13Names.indexOf('计算机导论实验') >= 0);
checkTrue('第 13 周不应包含微积分（上）（1~12 周）', week13Names.indexOf('微积分（上）') < 0);
checkTrue('第 13 周应包含网页设计课程设计', week13Names.indexOf('网页设计课程设计') >= 0);
checkTrue('第 13 周不应包含网页设计基础（1~12 周）', week13Names.indexOf('网页设计基础') < 0);

// 列内格子数与跨度的正确性：每列格子覆盖的节次总和必须正好 13
const col = view1.days[0].cells;
let covered = 0;
for (let j = 0; j < col.length; j++) {
  covered += col[j].span;
}
check('周一列格子覆盖全部 13 节（无重叠无空洞）', covered, 13);
checkTrue('周一第一格是课（微积分（上）1-2 节）', col[0].kind === 'course' && col[0].span === 2);

// =============================================================================
// 七、今明日程
// =============================================================================
group('七、今明日程（小窗口时间线）');
const briefMorning = svc.getDailyBrief(imported.items, semester, new Date(2026, 9, 14, 8, 30));
check('上午时段：展示今天', briefMorning.mode, 'today');
check('标题为「今天」', briefMorning.title, '今天');
check('今天周三有课', briefMorning.courses.length > 0, true);

const briefNight = svc.getDailyBrief(imported.items, semester, new Date(2026, 9, 14, 23, 0));
checkTrue('深夜：今天已全部过去，改为展示后面的课', briefNight.mode === 'upcoming' || briefNight.mode === 'empty');
checkTrue('提示语包含"上完"', briefNight.hint.indexOf('上完') >= 0);

const briefSat = svc.getDailyBrief(imported.items, semester, new Date(2026, 9, 17, 23, 30)); // 周六深夜
checkTrue('周六深夜：展示后面的课或空态', briefSat.mode === 'upcoming' || briefSat.mode === 'empty');

// =============================================================================
// 八、存储映射（数据库行 ↔ 领域模型）
// =============================================================================
// 这一段最值得测：课表写进数据库、再读回来，中间要过两道关 ——
//   weeks 数组 ⇄ JSON 文本，以及 行记录 ⇄ 模型。
// 任何一处对不上，用户都会看到"导入时好好的，重启应用课就少了几节"。

group('八、存储映射（行记录 ↔ 模型）');

check('周次序列化 [1,2,3]', StorageMapper.weeksToJson([1, 2, 3]), '[1,2,3]');
check('空数组序列化成 []', StorageMapper.weeksToJson([]), '[]');
check('周次反序列化 [1,2,3]', StorageMapper.weeksFromJson('[1,2,3]'), [1, 2, 3]);

// 脏数据一律降级，绝不抛异常（数据库里可能留着旧版本写坏的文本）
check('空串解析成空数组', StorageMapper.weeksFromJson(''), []);
check('非法 JSON 解析成空数组', StorageMapper.weeksFromJson('{oops'), []);
check('非数组解析成空数组', StorageMapper.weeksFromJson('{"a":1}'), []);
check('超范围的值被过滤', StorageMapper.weeksFromJson('[0,1,99,3]'), [1, 3]);

// 课程：模型 → 行 → 模型，必须原样回来
const course0: Course = {
  id: 7, name: '存储测试课', code: 'TST101', teacher: '张老师',
  campus: '主校区', room: 'A101', color: '#4C7DF0'
};
check('课程往返一致', StorageMapper.rowToCourse(StorageMapper.courseToRow(course0)), course0);

// 排课：含周次数组，走的是最长的一条链路
const entry0: ScheduleEntry = {
  id: 3, courseId: 7, weekday: 3, startSlot: 5, endSlot: 8,
  weeks: [1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12], weeksRaw: '1~3,5~12周',
  room: 'B305', teacher: '李老师', campus: '东校区'
};
check('排课往返一致（含周次）',
  StorageMapper.rowToEntry(StorageMapper.entryToRow(entry0)), entry0);

// 全部样例排课的周次过一遍序列化，确保没有特殊值掉队
let weeksRoundTripOk: boolean = true;
for (let i = 0; i < imported.entries.length; i++) {
  const e: ScheduleEntry = imported.entries[i];
  const back: number[] = StorageMapper.weeksFromJson(StorageMapper.weeksToJson(e.weeks));
  if (back.join(',') !== e.weeks.join(',')) {
    weeksRoundTripOk = false;
  }
}
checkTrue('全部排课周次往返后完全一致', weeksRoundTripOk);

// 两表拼装：模拟"重启应用后从库里读出来"的路径，
// 结果必须与导入当时内存里的 items 对得上
const joined: ScheduleItem[] = StorageMapper.joinItems(imported.courses, imported.entries);
check('拼装条数与导入结果一致', joined.length, imported.items.length);

const nameByEntryId: Map<number, string> = new Map<number, string>();
for (let i = 0; i < imported.items.length; i++) {
  nameByEntryId.set(imported.items[i].entryId, imported.items[i].courseName);
}
let joinedNamesOk: boolean = true;
for (let i = 0; i < joined.length; i++) {
  const want: string | undefined = nameByEntryId.get(joined[i].entryId);
  if (want === undefined || want !== joined[i].courseName) {
    joinedNamesOk = false;
  }
}
checkTrue('拼装后每条课程名与导入结果一致', joinedNamesOk);

// 孤儿条目（课程已被删掉）必须被跳过，否则界面上会出现没有名字的格子
const orphan: ScheduleItem[] = StorageMapper.joinItems([], imported.entries);
check('没有课程时拼装结果为空（孤儿条目被跳过）', orphan.length, 0);

// =============================================================================
// 九、粘贴导入：周次与节次
// =============================================================================

/** 在解析结果里按课程名找一条 */
function findItem(result: ImportResult, name: string): ScheduleItem | undefined {
  for (let i = 0; i < result.items.length; i++) {
    if (result.items[i].courseName === name) {
      return result.items[i];
    }
  }
  return undefined;
}

function hasText(text: string, needle: string): boolean {
  return text.indexOf(needle) >= 0;
}

/** 按 entryId 找一条 */
function findItemAt(items: ScheduleItem[], entryId: number): ScheduleItem | undefined {
  for (let i = 0; i < items.length; i++) {
    if (items[i].entryId === entryId) {
      return items[i];
    }
  }
  return undefined;
}

/** 每条排课的外键都要能对上一条课程，否则落库后界面上会出现无名格子 */
function courseIdsAllResolvable(result: ImportResult): boolean {
  const ids: Set<number> = new Set<number>();
  for (let i = 0; i < result.courses.length; i++) {
    ids.add(result.courses[i].id);
  }
  for (let i = 0; i < result.entries.length; i++) {
    if (!ids.has(result.entries[i].courseId)) {
      return false;
    }
  }
  return result.entries.length > 0;
}

group('九、粘贴导入：周次解析');

check('1-16周', parseWeeks('1-16周', false).length, 16);
check('第1-16周（带「第」）', parseWeeks('第1-16周', false)[0], 1);
check('1~16 波浪号', parseWeeks('1~16周', false).length, 16);
check('裸区间 1-16（表格场景允许）', parseWeeks('1-16', true).length, 16);
check('裸区间 1-16（列表场景不认，必须写「周」）', parseWeeks('1-16', false), []);
check('1,3,5周 并集', parseWeeks('1,3,5周', false), [1, 3, 5]);
check('1-8,10-12周 多段并集', parseWeeks('1-8,10-12周', false).length, 11);
check('1-16周(单) 只留单周', parseWeeks('1-16周(单)', false), [1, 3, 5, 7, 9, 11, 13, 15]);
check('2-16周（双）只留双周', parseWeeks('2-16周（双）', false), [2, 4, 6, 8, 10, 12, 14, 16]);
check('只写「单周」时按默认学期长度铺开', parseWeeks('单周', false), [1, 3, 5, 7, 9, 11, 13, 15]);
check('空串', parseWeeks('', false), []);
// 「周」字也会出现在课程名里，不能被骗到
check('课程名「周易概论」不算周次', parseWeeks('周易概论', false), []);

group('九、粘贴导入：节次解析');

check('1-2节', parseSlots('1-2节'), [1, 2]);
check('第3节', parseSlots('第3节'), [3, 3]);
check('单个数字 5', parseSlots('5'), [5, 5]);
check('5,6 → 区间', parseSlots('5,6'), [5, 6]);
check('中文数字「一二节」', parseSlots('一二节'), [1, 2]);
check('中文数字「三四节」', parseSlots('三四节'), [3, 4]);
check('「十一节」是第 11 节', parseSlots('第十一节'), [11, 11]);
check('认不出的文本', parseSlots('上午'), []);

group('九、粘贴导入：单元格内容拆解');

check('从课程名里剪掉周次', stripWeeks('高等数学1-16周'), '高等数学');
check('带括号的周次也能剪掉', stripWeeks('大学英语(1-16周)'), '大学英语');
check('只剩周次时剪成空串', stripWeeks('1-16周(单)'), '');
check('「周易概论」不会被剪坏', stripWeeks('周易概论'), '周易概论');

check('A101 是教室', looksLikeRoom('A101'), true);
check('综合楼305 是教室', looksLikeRoom('综合楼305'), true);
check('东区 是教室', looksLikeRoom('东区'), true);
check('302 是教室', looksLikeRoom('302'), true);
check('高等数学 不是教室', looksLikeRoom('高等数学'), false);
// 「信号与系统」里有「号」字，早先的写法会把它误判成教室
check('信号与系统 不是教室', looksLikeRoom('信号与系统'), false);
check('1-16 不是教室', looksLikeRoom('1-16'), false);

check('张三 是教师', looksLikeTeacher('张三'), true);
check('李四老师 是教师', looksLikeTeacher('李四老师'), true);
check('A101 不是教师', looksLikeTeacher('A101'), false);
check('通信工程1班 不是教师', looksLikeTeacher('通信工程1班'), false);

// =============================================================================
// 十、粘贴导入：整段解析
// =============================================================================

group('十、粘贴导入：教务表格（单元格里有多行）');

// 模拟从教务系统课表页面直接全选复制：制表符分列，换行分行，
// 但**每个格子里还有换行**（课程名 / 周次 / 教师 / 教室各占一行）——
// 这是最容易把解析器写崩的地方。
const gridText: string =
  '节次\t星期一\t星期二\t星期三\t星期四\t星期五\n' +
  '1-2\t高等数学\n1-16周\n张三\nA101\t\t大学英语\n1-16周\n李四\nB202\t\t\n' +
  '3-4\t\t程序设计\n1-8周\n王五\n机房301\t\t\t\n';

const gridResult: ImportResult = TextImportService.parse(gridText, '粘贴导入');
check('表格解析成功', gridResult.ok, true);
check('解析出 3 条排课', gridResult.items.length, 3);
check('课程数 3', gridResult.courses.length, 3);
check('总周数 16', gridResult.totalWeeks, 16);

const itemMath: ScheduleItem | undefined = findItem(gridResult, '高等数学');
check('认出了「高等数学」', itemMath !== undefined, true);
if (itemMath !== undefined) {
  check('  星期 = 周一', itemMath.weekday, 1);
  check('  节次 1-2', `${itemMath.startSlot}-${itemMath.endSlot}`, '1-2');
  check('  周次 16 周', itemMath.weeks.length, 16);
  check('  教师', itemMath.teacher, '张三');
  check('  教室', itemMath.room, 'A101');
}

const itemEng: ScheduleItem | undefined = findItem(gridResult, '大学英语');
if (itemEng !== undefined) {
  check('「大学英语」落在周三', itemEng.weekday, 3);
  check('「大学英语」教室', itemEng.room, 'B202');
}

// 「机房301」不符合常见的教室命名规范，靠"最后一段兜底当教室"接住
const itemProg: ScheduleItem | undefined = findItem(gridResult, '程序设计');
if (itemProg !== undefined) {
  check('「程序设计」落在周二', itemProg.weekday, 2);
  check('「程序设计」节次 3-4', `${itemProg.startSlot}-${itemProg.endSlot}`, '3-4');
  check('「程序设计」周次 1-8', itemProg.weeks.length, 8);
  check('「程序设计」教师', itemProg.teacher, '王五');
  check('「程序设计」教室（末段兜底）', itemProg.room, '机房301');
}

// 空表格：只有表头
const emptyGrid: ImportResult =
  TextImportService.parse('节次\t星期一\t星期二\t星期三\t星期四\n1-2\t\t\t\t\n', '粘贴导入');
check('只有表头没有课 → 失败', emptyGrid.ok, false);

group('十、粘贴导入：一行一门课的列表');

// 这种形态最常见于"同学在群里发的文字课表"：空格分隔，一行一门
const listText: string =
  '高等数学 周一 1-2节 1-16周 A101 张三\n' +
  '大学英语 周三 3-4节 1-8周 B202 李四\n' +
  '随便写点什么\n';

const listResult: ImportResult = TextImportService.parse(listText, '粘贴导入');
check('列表解析成功', listResult.ok, true);
check('解析出 2 条排课', listResult.items.length, 2);
const listMath: ScheduleItem | undefined = findItem(listResult, '高等数学');
if (listMath !== undefined) {
  check('  星期', listMath.weekday, 1);
  check('  节次', `${listMath.startSlot}-${listMath.endSlot}`, '1-2');
  check('  教师', listMath.teacher, '张三');
  check('  教室', listMath.room, 'A101');
}
check('认不出的那一行进了告警', listResult.warnings.length > 0, true);

group('十、粘贴导入：脏数据与失败提示');

check('空文本 → 失败', TextImportService.parse('', '粘贴导入').ok, false);
check('纯空白 → 失败', TextImportService.parse('   \n  \n', '粘贴导入').ok, false);

const junk: ImportResult = TextImportService.parse('今天天气不错，出去走走吧', '粘贴导入');
check('没有课表信息 → 失败', junk.ok, false);
check('失败提示说人话（提到星期）', hasText(junk.error, '周一'), true);

// 缺周次时不该整条丢掉，而是填默认值并告警
const noWeeks: ImportResult =
  TextImportService.parse('节次\t星期一\t星期二\t星期三\n1-2\t高等数学\n张三\nA101\t\t\n', '粘贴导入');
check('缺周次仍然导入成功', noWeeks.ok, true);
check('缺周次的课被填上默认周次', noWeeks.items[0].weeks.length, 16);
check('并且明确告知用户这是替他填的', hasText(noWeeks.warnings.join(' '), '没写上课周次'), true);

// 同一格两门课（单周一门、双周一门）——要切成两条，不能并成一条
const twoInOne: ImportResult = TextImportService.parse(
  '节次\t星期一\t星期二\t星期三\n' +
  '1-2\t体育\n1-16周(单)\n赵六\n操场\n篮球\n2-16周(双)\n钱七\n体育馆\t\t\n',
  '粘贴导入');
check('一格两门课解析出 2 条', twoInOne.items.length, 2);
check('其中一条是「体育」', findItem(twoInOne, '体育') !== undefined, true);
check('另一条是「篮球」', findItem(twoInOne, '篮球') !== undefined, true);

// =============================================================================
// 十一、手动增删改
// =============================================================================

group('十一、手动增删改');

const goodForm: ManualCourseForm = {
  name: '线性代数', teacher: '赵六', room: 'C303',
  weekday: 4, startSlot: 5, endSlot: 6, weeksText: '1-16周'
};
check('表单合法', ScheduleEditor.validate(goodForm), '');

const noNameForm: ManualCourseForm = {
  name: '   ', teacher: '', room: '',
  weekday: 1, startSlot: 1, endSlot: 2, weeksText: '1-16周'
};
check('空课程名被拦下', hasText(ScheduleEditor.validate(noNameForm), '课程名'), true);

const badWeeksForm: ManualCourseForm = {
  name: '线性代数', teacher: '', room: '',
  weekday: 1, startSlot: 1, endSlot: 2, weeksText: '随便写的'
};
check('周次看不懂被拦下', hasText(ScheduleEditor.validate(badWeeksForm), '周次'), true);

const badSlotForm: ManualCourseForm = {
  name: '线性代数', teacher: '', room: '',
  weekday: 1, startSlot: 5, endSlot: 2, weeksText: '1-16周'
};
check('节次区间倒置被拦下', hasText(ScheduleEditor.validate(badSlotForm), '结束节次'), true);

// 表单 → 条目
const manualItem: ScheduleItem = ScheduleEditor.toItem(goodForm, 999, '');
check('表单转条目：课程名', manualItem.courseName, '线性代数');
check('表单转条目：周次 16 周', manualItem.weeks.length, 16);
check('表单转条目：星期', manualItem.weekday, 4);

// 回填：条目 → 表单 → 条目，应该稳定
const formAgain: ManualCourseForm = ScheduleEditor.toForm(manualItem);
check('回填后课程名不变', formAgain.name, '线性代数');
check('回填后节次不变', `${formAgain.startSlot}-${formAgain.endSlot}`, '5-6');

// 增 / 改 / 删
const baseItems: ScheduleItem[] = imported.items;
check('下一个 entryId 比现有都大', ScheduleEditor.nextEntryId(baseItems) > 0, true);
const newId: number = ScheduleEditor.nextEntryId(baseItems);

const added: ScheduleItem[] = ScheduleEditor.upsert(baseItems, ScheduleEditor.toItem(goodForm, newId, ''));
check('新增后条数 +1', added.length, baseItems.length + 1);

const editedForm: ManualCourseForm = {
  name: '线性代数', teacher: '赵六', room: 'C305',
  weekday: 4, startSlot: 5, endSlot: 6, weeksText: '1-16周'
};
const edited: ScheduleItem[] = ScheduleEditor.upsert(added, ScheduleEditor.toItem(editedForm, newId, ''));
check('编辑不改变条数', edited.length, added.length);
const editedBack: ScheduleItem | undefined = findItemAt(edited, newId);
check('编辑后教室已更新', editedBack !== undefined ? editedBack.room : '', 'C305');

const removed: ScheduleItem[] = ScheduleEditor.remove(edited, newId);
check('删除后回到原条数', removed.length, baseItems.length);

// 重建：同名课必须并成一条 course，否则库里会冒出好几条「线性代数」
const rebuilt1: RebuildResult = ScheduleEditor.rebuild(added);
check('重建后排课数 = 课表条数', rebuilt1.entries.length, added.length);

const sameNameAgain: ScheduleItem =
  ScheduleEditor.toItem(editedForm, newId + 1, '');
const withDup: ScheduleItem[] = ScheduleEditor.upsert(added, sameNameAgain);
const rebuilt2: RebuildResult = ScheduleEditor.rebuild(withDup);
check('同名课程被归并（课程数没有增加）', rebuilt2.courses.length, rebuilt1.courses.length);
check('但排课多了一条', rebuilt2.entries.length, rebuilt1.entries.length + 1);

// 打包成 ImportResult（页面就是拿它去落库的）
const packed: ImportResult = ScheduleEditor.buildResult(withDup, '手动编辑');
check('打包成功', packed.ok, true);
check('打包后排课数与课表条数一致', packed.entries.length, withDup.length);
check('打包后总周数正确', packed.totalWeeks, 16);
check('每门课都能在课程表里找到归属', courseIdsAllResolvable(packed), true);

// =============================================================================
// 十二、剪贴板 HTML 风味 → 表格网格
// -----------------------------------------------------------------------------
// 背景：我校教务系统复制出来的**纯文本**里一个格子分隔符都没有
// （实测整段 4594 字、275 行，制表符只有 21 个，全在表头行和节次行标末尾），
// "星期"这一列在纯文本里根本不存在。只能靠剪贴板的 text/html 风味把表格结构捞回来。
// =============================================================================
group('十二、剪贴板 HTML 风味：表格还原');

check('纯文本不像表格', HtmlTableService.looksLikeTable('第一节 高等数学 1~12周'), false);
check('空串不像表格', HtmlTableService.looksLikeTable(''), false);
check('<table> 像表格',
  HtmlTableService.looksLikeTable('<table><tr><td>x</td></tr></table>'), true);

// 最朴素的一张表：两行三列
const simpleGrid: string = HtmlTableService.toGridText(
  '<table><tr><td>a</td><td>b</td><td>c</td></tr>' +
  '<tr><td>d</td><td>e</td><td>f</td></tr></table>');
check('朴素表格 → 制表符文本', simpleGrid, 'a\tb\tc\nd\te\tf');

// 单元格里的 <br> 必须变成换行，不能删 —— 删了课程名/周次/教室就粘成一坨
const brGrid: string = HtmlTableService.toGridText(
  '<table><tr><td>高等数学<br>(1~12周)<br>金海 A101</td><td>空</td></tr></table>');
check('<br> 变换行', brGrid, '高等数学\n(1~12周)\n金海 A101\t空');

// rowspan：课表里"跨两节"的课就是这么写的。
// 不展开的话第二行会少一格，后面整排列位置全体左移 —— 星期全错。
const rowspanGrid: string = HtmlTableService.toGridText(
  '<table>' +
  '<tr><td>r1c1</td><td>r1c2</td><td>r1c3</td></tr>' +
  '<tr><td rowspan="2">r2c1</td><td>r2c2</td><td>r2c3</td></tr>' +
  '<tr><td>r3c2</td><td>r3c3</td></tr>' +
  '</table>');
check('rowspan 展开后列不错位', rowspanGrid, 'r1c1\tr1c2\tr1c3\nr2c1\tr2c2\tr2c3\n\tr3c2\tr3c3');

// colspan 同理：被跨过的列要补空格子占位
const colspanGrid: string = HtmlTableService.toGridText(
  '<table>' +
  '<tr><td colspan="2">A</td><td>B</td></tr>' +
  '<tr><td>C</td><td>D</td><td>E</td></tr>' +
  '</table>');
check('colspan 展开后列不错位', colspanGrid, 'A\t\tB\nC\tD\tE');

// 属性写法很不讲究：单引号、无引号、多个空格都得认
const looseGrid: string = HtmlTableService.toGridText(
  '<table><tr><td rowspan=2 class="x">A</td><td>B</td></tr><tr><td>C</td></tr></table>');
check('无引号的 rowspan 也认', looseGrid, 'A\tB\n\tC');

// 实体转义
check('实体还原', HtmlTableService.decodeEntities('A&amp;B&nbsp;C&lt;D&gt;E&quot;F&#39;G'),
  'A&B C<D>E"F\'G');
check('&amp;lt; 不会被还原成 <', HtmlTableService.decodeEntities('&amp;lt;'), '&lt;');

// CF_HTML 包装（Windows 剪贴板的 HTML 风味外面会包一层）
const wrapped: string = 'Version:0.9\nStartHTML:0000000105\n' +
  '<!--StartFragment--><table><tr><td>片段</td></tr></table><!--EndFragment-->\n尾巴';
check('CF_HTML 包头被剥掉', HtmlTableService.toGridText(wrapped), '片段');
check('完整文档只取 <body>',
  HtmlTableService.toGridText('<html><head><style>td{}</style></head>' +
    '<body><table><tr><td>正文</td></tr></table></body></html>'), '正文');

// 端到端：纯文本丢了星期，HTML 把它救回来。
// 注意表头要列齐 7 天 —— 真实教务系统就是这么排的，解析器也要求至少 3 个星期列才认。
const DAYS: string[] = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
const gapHtml: string =
  `<table><tr><td>节次</td>${DAYS.map((d: string) => `<td>${d}</td>`).join('')}</tr>` +
  '<tr><td>第一节</td>' +
  '<td>高等数学<br>(1~12周)<br>金海 A101 张三</td>' +
  '<td>大学英语<br>(1~8周)<br>金海 B202 李四</td>' +
  '<td></td><td></td><td></td><td></td><td></td>' +
  '</tr></table>';

// 同一张表，纯文本风味会长成这个鬼样子（格子之间一个分隔符都没有）
const gapPlain: string = `节次\n${DAYS.join('\n')}\n第一节\n` +
  '高等数学\n(1~12周)\n金海 A101 张三\n大学英语\n(1~8周)\n金海 B202 李四';

const byHtml: ImportResult = TextImportService.parseFromClipboard(gapPlain, gapHtml, '粘贴导入');
check('HTML 风味解析成功', byHtml.ok, true);
check('HTML 风味认出 2 门课', byHtml.items.length, 2);
check('星期一那门归到周一', findItem(byHtml, '高等数学')?.weekday, 1);
check('星期二那门归到周二', findItem(byHtml, '大学英语')?.weekday, 2);
check('周次也认出来了', findItem(byHtml, '高等数学')?.weeksRaw, '1~12周');
check('教师认出来了', findItem(byHtml, '高等数学')?.teacher, '张三');
check('教室认出来了', findItem(byHtml, '高等数学')?.room, 'A101');

// 没有 HTML 时，老老实实退回纯文本。这种"格间没分隔符"的脏文本必须明确认不出来 ——
// 硬按顺序猜一个"星期一、星期二……"更糟：数据看着像对的，其实星期全错，用户还查不出来。
const plainOnly: ImportResult = TextImportService.parseFromClipboard(gapPlain, '', '粘贴导入');
check('没有 HTML 时不硬猜，直接认不出来', plainOnly.items.length, 0);

// 正常的制表符文本（Excel / 多数教务网页复制）照常走纯文本那条路
const tabText: string = '节次\t' + DAYS.join('\t') + '\n第一节\t高等数学(1~12周) 金海 A101 张三\t大学英语(1~8周) 金海 B202 李四\t\t\t\t\t';
const both: ImportResult = TextImportService.parseFromClipboard(tabText, '', '粘贴导入');
check('纯制表符文本照常解析', both.ok, true);
check('纯制表符文本认出 2 门课', both.items.length, 2);

// 有些教务系统复制出来的纯文本连"格子"都保不住：整段只有表头行和节次行标带制表符，
// 格子与格子之间一个分隔符都没有，「星期」这一整列直接消失。
// （实测我校教务系统：4594 字 / 275 行的整张课表里，制表符一共只有 21 个，
//   6 个在表头行、15 个在节次行标末尾。所以纯文本这条路必然认不出来。）
// 这种时候不能只丢一句"认不出格式"，得告诉用户到底发生了什么。
const blockStream: string =
  '张小同(f99999999)\n课表\n全部课程\n2026-2027-1\n全部周次\n' +
  '学期起始日期:  2026-09-14\n' +
  `星期一\t星期二\t星期三\t星期四\t星期五\t星期六\t星期日\n` +
  '第一节\t\n' +
  '示例课程甲\n10001\n(1~12周) (第一节-第二节) 主校区 4309  王甲\nf000001（示例班）\n' +
  '示例课程乙\n10002\n(13~16周) (第一节-第二节) 主校区 12-713  李乙\nf000001（示例班）\n' +
  '第二节\n' +
  '第三节\t\n' +
  '示例课程丙\n10003\n(1~16周) (第三节-第四节) 主校区 4212  赵丙\nf000001（示例班）\n';

const blockResult: ImportResult = TextImportService.parse(blockStream, '粘贴导入');
check('丢了星期的课块流 → 认不出来', blockResult.ok, false);
check('且明确指出是"星期丢了"', hasText(blockResult.error, '星期'), true);
check('并给出可操作的办法（重新全选复制）', hasText(blockResult.error, 'Ctrl'), true);

// 但同一份内容，只要剪贴板里带 HTML 风味，就该被正确解析
const blockHtml: string =
  `<table><tr><td>节次</td>${DAYS.map((d: string) => `<td>${d}</td>`).join('')}</tr>` +
  '<tr><td>第一节</td><td>示例课程甲<br>(1~12周)<br>主校区 4309 王甲</td><td></td>' +
  '<td></td><td></td><td></td><td></td><td></td></tr></table>';
const blockByHtml: ImportResult = TextImportService.parseFromClipboard(blockStream, blockHtml, '粘贴导入');
check('同一份内容带 HTML 时能解析', blockByHtml.ok, true);
check('并归到周一', findItem(blockByHtml, '示例课程甲')?.weekday, 1);

// 跨节次的课：格子里自己写着「(第一节-第二节)」，比行标签可信 ——
// 表格里跨节次常用合并单元格，转成文本后行标签只会剩「第一节」
const spanHtml: string =
  `<table><tr><td>节次</td>${DAYS.map((d: string) => `<td>${d}</td>`).join('')}</tr>` +
  '<tr><td>第一节</td><td>示例课程甲<br>(1~12周) (第一节-第二节)<br>主校区 4309 王甲</td>' +
  '<td></td><td></td><td></td><td></td><td></td><td></td></tr></table>';
const spanResult: ImportResult = TextImportService.parseFromClipboard('', spanHtml, '粘贴导入');
const spanItem: ScheduleItem | undefined = findItem(spanResult, '示例课程甲');
check('跨节次：起了第 1 节', spanItem?.startSlot, 1);
check('跨节次：到第 2 节', spanItem?.endSlot, 2);
check('跨节次：教室没被节次段带跑', spanItem?.room, '4309');
check('跨节次：教师认出来了', spanItem?.teacher, '王甲');

// =============================================================================
// 十二、教务系统「班级课表」打印/导出格式
// =============================================================================
// 真实来源：某校教务系统导出的班级课表。这个格式有两个独有的特征，凑在一起
// 极容易诱使解析器把「一整格」当成「一门课」，让课名串上别人的教室和老师：
//   ① 同一格里放多门课，之间用一整行 `-----------` 隔开
//   ② 周次写成光秃秃的 `1-12`（列标题已经说明了是周次，所以不写「周」字）
// 之前这两条都没被识别，实测 27 门课只解析出 22 门，且教室/教师全部错位。

const dashCell: string =
  '示例课程甲\n1-12\n主校区 4101\n王甲\n-----------\n示例课程乙\n13-16\n主校区 12-713\n李乙';
const dashGrid: string =
  ['节次', ...DAYS].join('\t') + '\n' +
  ['第一节', dashCell, '示例课程丙\n1-12\n主校区 12-614\n赵丙', '', '', '', '', ''].join('\t');
const dashResult: ImportResult = TextImportService.parse(dashGrid, '粘贴导入');
check('分隔线单元格：认出 3 门课', dashResult.items.length, 3);
const dashA: ScheduleItem | undefined = findItem(dashResult, '示例课程甲');
const dashB: ScheduleItem | undefined = findItem(dashResult, '示例课程乙');
const dashC: ScheduleItem | undefined = findItem(dashResult, '示例课程丙');
check('分隔线单元格：甲在第 1 周次段', dashA?.weeksRaw, '1~12周');
check('分隔线单元格：甲拿自己的教室', dashA?.room, '4101');
check('分隔线单元格：甲拿自己的老师', dashA?.teacher, '王甲');
check('分隔线单元格：乙没被并进甲', dashB?.weeksRaw, '13~16周');
check('分隔线单元格：乙拿自己的教室', dashB?.room, '12-713');
check('分隔线单元格：乙拿自己的老师', dashB?.teacher, '李乙');
check('分隔线单元格：丙归到星期二', dashC?.weekday, 2);
check('纯分隔线被判为分隔符', isGroupSeparator('-----------'), true);
check('短横线不算分隔符（可能是课程名的一部分）', isGroupSeparator('--'), false);

// 「周次必须可信」这道闸门：教务系统的格子里会夹带备注，
// 备注里带「周」字、又带时间戳，裸奔的 parseWeeks 会从 17:00-18:30 里
// 抠出周次，把一门课读成「第 1~18 周 + 第 20~45 周」（实测踩过）。
check('周次可信：信息行 (1~12周) ...', weeksAreTrustworthy('(1~12周) (第一节-第二节) 主校区 4309  阙程晟'), true);
check('周次可信：裸区间', weeksAreTrustworthy('1-12'), true);
check('周次可信：单周', weeksAreTrustworthy('单周'), true);
check('周次可信：1-16周(单)', weeksAreTrustworthy('1-16周(单)'), true);
check('周次可信：1~3,5~12周', weeksAreTrustworthy('1~3,5~12周'), true);
check('周次可信：连写 1-8周 第3-4节', weeksAreTrustworthy('1-8周 第3-4节'), true);
check('周次不可信：一句带时间的备注', weeksAreTrustworthy('周一分成2节17:00-18:30,18:45-20:15'), false);

const noteGrid: string =
  ['节次', ...DAYS].join('\t') + '\n' +
  ['第一节', '示例课程甲\n主校区 4101\n王甲\n周一分成2节17:00-18:30,18:45-20:15', '', '', '', '', '', ''].join('\t');
const noteResult: ImportResult = TextImportService.parse(noteGrid, '粘贴导入');
const noteItem: ScheduleItem | undefined = findItem(noteResult, '示例课程甲');
check('备注里的时间戳不会被读成周次', noteItem?.weeks.length, 16);
check('备注场景：整学期周数没被撑大', noteResult.totalWeeks, 16);

// =============================================================================
// 十二、Excel 导入：教务处「各校区课表」
// =============================================================================
group('十二、Excel 导入：教务处「各校区课表」');

const xlsxShared: string[] = XlsxService.parseSharedStrings(XLSX_SHARED_XML);
check('共享字符串条数对上', xlsxShared.length, 40);
checkTrue('共享字符串里的换行（&#10;）被还原', hasText(xlsxShared[30], '\n'));
checkTrue('共享字符串里的分隔线被还原', hasText(xlsxShared[30], '-----------'));
check('共享字符串按索引取值', xlsxShared[19], '星期一');

const xlsxTargets: XlsxSheetTarget[] = XlsxService.sheetTargets(XLSX_WORKBOOK_XML, XLSX_RELS_XML);
check('解析出 2 个 sheet', xlsxTargets.length, 2);
check('sheet 名', xlsxTargets[0].name, '示例学院');
check('sheet 路径补上 xl/ 前缀', xlsxTargets[0].path, 'xl/worksheets/sheet1.xml');
check('第二个 sheet 的路径', xlsxTargets[1].path, 'xl/worksheets/sheet2.xml');

const xlsxClasses: XlsxClassInfo[] = XlsxService.classesInSheet('示例学院', XLSX_SHEET_XML, xlsxShared);
check('扫出 1 个班级', xlsxClasses.length, 1);
check('班号', xlsxClasses[0].code, 'z000001');
check('专业名称（块头散落在第 3 列）', xlsxClasses[0].major, '示例工程');
check('学院（最右边两列）', xlsxClasses[0].college, '示例学院');
check('年级', xlsxClasses[0].grade, '25级');
check('辅导员（块头第 8 列）', xlsxClasses[0].advisor, '示例老师甲');
check('人数（块头第 11 列）', xlsxClasses[0].people, '30');
check('校区（块头第 13 列）', xlsxClasses[0].campus, '示例校区');
check('节次行数到 7（「中午1」「傍晚」不算，「十一节」要算）', xlsxClasses[0].slotRows, 7);

const xlsxResult: ImportResult =
  XlsxService.parseClass(XLSX_SHEET_XML, xlsxShared, xlsxClasses[0], '示例课表.xlsx');
check('Excel 解析成功', xlsxResult.ok, true);
check('认出 4 条排课', xlsxResult.items.length, 4);
check('课程归并成 2 门', xlsxResult.courses.length, 2);
check('总周数', xlsxResult.totalWeeks, 16);

const xlsxFirst: ScheduleItem | undefined = findItem(xlsxResult, '示例课程甲');
check('课程名', xlsxFirst?.courseName, '示例课程甲');
check('星期来自列位置', xlsxFirst?.weekday, 1);
check('起始节次', xlsxFirst?.startSlot, 1);
check('结束节次按「大课连排两节」推断', xlsxFirst?.endSlot, 2);
check('教师来自课程清单 join', xlsxFirst?.teacher, '示例教师甲');
check('教室（同一列的第二列）', xlsxFirst?.room, '101');
check('校区带出来了', xlsxFirst?.campus, '示例校区');
check('周次', xlsxFirst?.weeksRaw, '1-16');

const xlsxSecond: ScheduleItem | undefined = findItem(xlsxResult, '示例课程乙');
check('一格里的第二门课也拆出来了', xlsxSecond?.courseName, '示例课程乙');
check('第二门课的教室按序号对齐', xlsxSecond?.room, '202');
check('第二门课的教师', xlsxSecond?.teacher, '示例教师乙');
check('第二门课的周次', xlsxSecond?.weeksRaw, '13-16');

const xlsxWed: ScheduleItem[] = xlsxResult.items.filter((x: ScheduleItem) => x.weekday === 3);
check('周三只抽出 1 条', xlsxWed.length, 1);
check('周三那条起于第三节', xlsxWed[0].startSlot, 3);
check('周三那条到第四节', xlsxWed[0].endSlot, 4);

check('占位词「通识教育选修课」被过滤掉',
  xlsxResult.items.filter((x: ScheduleItem) => x.courseName === '通识教育选修课').length, 0);

const xlsxLate: ScheduleItem[] = xlsxResult.items.filter((x: ScheduleItem) => x.startSlot === 11);
check('省略「第」字的「十一节」也认', xlsxLate.length, 1);
check('第十一节不按大课推断', xlsxLate[0].endSlot, 11);
check('第十一节那门课的教室', xlsxLate[0].room, '101');

// 认不出来的文件要说人话，而不是硬猜
const xlsxBad: ImportResult = XlsxService.parseClass(
  '<worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c></row></sheetData></worksheet>',
  xlsxShared, xlsxClasses[0], 'x.xlsx');
check('认不出结构的 Excel → 失败', xlsxBad.ok, false);
checkTrue('失败提示说清楚缺了什么', hasText(xlsxBad.error, '表头'));

// =============================================================================
// 汇总
// =============================================================================
console.log(`\n${'='.repeat(52)}`);
console.log(`  通过 ${passed} 项，失败 ${failed} 项`);
console.log('='.repeat(52));
if (failed > 0) {
  process.exitCode = 1;
}

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
import { Semester, ScheduleItem } from '../../entry/src/main/ets/model/Models';
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
// 汇总
// =============================================================================
console.log(`\n${'='.repeat(52)}`);
console.log(`  通过 ${passed} 项，失败 ${failed} 项`);
console.log('='.repeat(52));
if (failed > 0) {
  process.exitCode = 1;
}

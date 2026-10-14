/**
 * 课晓 · 默认配置
 * ---------------------------------------------------------------------------
 * 这里放「开箱即用」的默认值。用户在设置页里改的任何东西，都会覆盖这里的默认值。
 * 默认作息取自课晓参考学校的真实作息（已与用户逐项确认）：
 *   上午 08:00 第一节 → 两节大课 → 11:15 下课
 *   下午 12:40 开始（午休 11:15–12:40）→ 两节大课 → 15:55 下课
 *   晚上 17:00 开始（傍晚休息 15:55–17:00）→ 1 节大课 + 3 节小课
 *   共 13 节，与教务课表「第一节 … 第十三节」一一对应
 * ---------------------------------------------------------------------------
 */

import { PeriodConfig, PeriodKey } from '../model/Models';
import { SlotTimeTable } from '../common/SlotTimeTable';

/** 一节课（小课）的默认时长：45 分钟 */
export const DEFAULT_SMALL_SLOT_MINUTES: number = 45;

/** 默认课间：15 分钟 */
export const DEFAULT_BREAK_MINUTES: number = 15;

/**
 * 课晓参考学校的作息参数。
 * 想改作息？改这里即可，整张节次表会自动重算。
 */
export const DEFAULT_PERIOD_CONFIGS: PeriodConfig[] = [
  {
    key: 'morning' as PeriodKey,
    label: '上午',
    startTime: '08:00',
    bigCourseCount: 2,        // 两节大课
    smallPerBig: 2,           // 每节大课 = 2 节小课相连
    smallSlotMinutes: DEFAULT_SMALL_SLOT_MINUTES,
    breakInBigMinutes: 0,     // 大课内部连着上，不休息
    breakBetweenBigMinutes: DEFAULT_BREAK_MINUTES,
    trailingSmallCount: 0
    // 生成结果：第1-4节  08:00-08:45 / 08:45-09:30 / 09:45-10:30 / 10:30-11:15
  },
  {
    key: 'afternoon' as PeriodKey,
    label: '下午',
    startTime: '12:40',
    bigCourseCount: 2,
    smallPerBig: 2,
    smallSlotMinutes: DEFAULT_SMALL_SLOT_MINUTES,
    breakInBigMinutes: 0,
    breakBetweenBigMinutes: DEFAULT_BREAK_MINUTES,
    trailingSmallCount: 0
    // 生成结果：第5-8节  12:40-13:25 / 13:25-14:10 / 14:25-15:10 / 15:10-15:55
  },
  {
    key: 'evening' as PeriodKey,
    label: '晚上',
    startTime: '17:00',
    bigCourseCount: 1,        // 晚上只有一节大课
    smallPerBig: 2,
    smallSlotMinutes: DEFAULT_SMALL_SLOT_MINUTES,
    breakInBigMinutes: 0,
    breakBetweenBigMinutes: DEFAULT_BREAK_MINUTES,
    trailingSmallCount: 3     // 再追加 3 节小课
    // 生成结果：第9-13节 17:00-17:45 / 17:45-18:30 / 18:45-19:30 / 19:45-20:30 / 20:45-21:30
  }
];

/** 课程配色板：浅色背景下对比度舒适，相邻课程颜色尽量不同 */
export const COURSE_COLORS: string[] = [
  '#4C7DF0', // 蓝
  '#12A87A', // 青绿
  '#E8871E', // 橙
  '#8E5BD9', // 紫
  '#D4456B', // 玫红
  '#0E9BB5', // 湖蓝
  '#7A8B1F', // 橄榄
  '#C25E28', // 砖红
  '#2F8FCF', // 天蓝
  '#B4478F'  // 洋红
];

/** 根据课程名稳定地挑一个颜色（同名课永远同色） */
export function colorForCourse(name: string): string {
  let hash: number = 0;
  for (let i = 0; i < name.length; i++) {
    hash = (hash * 31 + name.charCodeAt(i)) % 100000;
  }
  const idx: number = Math.abs(hash) % COURSE_COLORS.length;
  return COURSE_COLORS[idx];
}

/** 生成默认节次时间表 */
export function createDefaultTimeTable(): SlotTimeTable {
  return SlotTimeTable.build(DEFAULT_PERIOD_CONFIGS);
}

/**
 * 默认学期（第 1 周周一）。
 * 真正的学期起始日期应由用户在"设置 → 学期"里选定，
 * 这里仅作为"还没设置时"的兜底，避免日期换算崩溃。
 */
export const DEFAULT_SEMESTER_START: string = '2026-09-07';

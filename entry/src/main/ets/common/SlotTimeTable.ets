/**
 * 课晓 · 可配置节次时间表（SlotTimeTable）
 * ---------------------------------------------------------------------------
 * 为什么需要它？
 *   教务课表只告诉我们「第几节」，但"第 1 节"到底是几点，每个学校都不一样。
 *   所以需要一张把「节次号」翻译成「几点几分」的表。
 *
 * 课晓 的节次体系（嵌套结构）：
 *
 *   时段(上午) ──┬── 大课 1 ──┬── 小课 1 ── 08:00-08:45
 *               │            └── 小课 2 ── 08:45-09:30   ← 大课内小课之间无课间
 *               │            (课间 15 分钟)
 *               └── 大课 2 ──┬── 小课 3 ── 09:45-10:30
 *                            └── 小课 4 ── 10:30-11:15
 *   时段(下午) 12:40 开始，结构同上午 → 15:55 下课
 *   时段(晚上) 17:00 开始 = 1 节大课 + 3 节小课
 *
 * 全部参数都可配置（见 PeriodConfig），默认值取自「课晓」参考学校的作息。
 * ---------------------------------------------------------------------------
 */

import { PeriodConfig, PeriodKey, SlotTime } from '../model/Models';
import { DateUtil } from './DateUtil';

export class SlotTimeTable {
  /** 全部节次，下标 0 对应第 1 节 */
  readonly slots: SlotTime[];
  /** 节次号 → SlotTime 的快速索引 */
  private readonly index: Map<number, SlotTime>;

  constructor(slots: SlotTime[]) {
    this.slots = slots;
    this.index = new Map<number, SlotTime>();
    for (let i = 0; i < slots.length; i++) {
      this.index.set(slots[i].slot, slots[i]);
    }
  }

  // -------------------------------------------------------------------------
  // 构造
  // -------------------------------------------------------------------------

  /**
   * 根据各时段参数生成整张节次表。
   * 节次号从 1 连续递增，跨时段不重复。
   */
  static build(configs: PeriodConfig[]): SlotTimeTable {
    const out: SlotTime[] = [];
    let slotNo: number = 1;

    for (let p = 0; p < configs.length; p++) {
      const cfg: PeriodConfig = configs[p];
      // 每个时段从自己的 startTime 开始，天然形成「午休 / 傍晚休息」
      let cursor: number = DateUtil.hmToMinutes(cfg.startTime);
      const periodKey: PeriodKey = cfg.key;

      // ---- 正课（若干节大课）----
      for (let b = 0; b < cfg.bigCourseCount; b++) {
        if (b > 0) {
          // 大课之间的课间
          cursor += cfg.breakBetweenBigMinutes;
        }
        for (let k = 0; k < cfg.smallPerBig; k++) {
          if (k > 0) {
            // 大课内部小课之间的间隔（通常 0）
            cursor += cfg.breakInBigMinutes;
          }
          out.push(SlotTimeTable.makeSlot(slotNo, cursor, cfg.smallSlotMinutes, periodKey, cfg.label));
          cursor += cfg.smallSlotMinutes;
          slotNo++;
        }
      }

      // ---- 时段末尾追加的零散小课（如晚上的 3 节小课）----
      if (cfg.trailingSmallCount > 0) {
        cursor += cfg.breakBetweenBigMinutes;
        for (let t = 0; t < cfg.trailingSmallCount; t++) {
          if (t > 0) {
            cursor += cfg.breakBetweenBigMinutes;
          }
          out.push(SlotTimeTable.makeSlot(slotNo, cursor, cfg.smallSlotMinutes, periodKey, cfg.label));
          cursor += cfg.smallSlotMinutes;
          slotNo++;
        }
      }
    }
    return new SlotTimeTable(out);
  }

  /** 手工给定每一节的时间（用于极端自定义：用户直接写死每节课时间） */
  static fromSlots(slots: SlotTime[]): SlotTimeTable {
    return new SlotTimeTable(slots);
  }

  private static makeSlot(slot: number, startMinutes: number, duration: number,
    periodKey: PeriodKey, periodLabel: string): SlotTime {
    return {
      slot: slot,
      start: DateUtil.minutesToHm(startMinutes),
      end: DateUtil.minutesToHm(startMinutes + duration),
      startMinutes: startMinutes,
      endMinutes: startMinutes + duration,
      periodKey: periodKey,
      periodLabel: periodLabel
    };
  }

  // -------------------------------------------------------------------------
  // 查询
  // -------------------------------------------------------------------------

  /** 一共有多少节 */
  get count(): number {
    return this.slots.length;
  }

  /** 取某一节；越界返回 undefined */
  tryAt(slot: number): SlotTime | undefined {
    return this.index.get(slot);
  }

  /** 取某一节的开始时间（分钟）；越界返回 0 */
  startMinutes(slot: number): number {
    const s: SlotTime | undefined = this.index.get(slot);
    return s === undefined ? 0 : s.startMinutes;
  }

  /** 取某一节的结束时间（分钟）；越界返回 0 */
  endMinutes(slot: number): number {
    const s: SlotTime | undefined = this.index.get(slot);
    return s === undefined ? 0 : s.endMinutes;
  }

  /** 取某一节的显示文本，如 '08:00-08:45'；越界返回空串 */
  labelOf(slot: number): string {
    const s: SlotTime | undefined = this.index.get(slot);
    return s === undefined ? '' : `${s.start}-${s.end}`;
  }

  /** 取某一节的时段名，如「上午」；越界返回空串 */
  periodLabelOf(slot: number): string {
    const s: SlotTime | undefined = this.index.get(slot);
    return s === undefined ? '' : s.periodLabel;
  }

  /** 按节次号升序返回所有节次 */
  all(): SlotTime[] {
    return this.slots;
  }

  /**
   * 该时段的"起止摘要"，用于设置页展示。
   * 例：上午 08:00-11:15
   */
  periodSummary(periodKey: PeriodKey): string {
    const inPeriod: SlotTime[] = this.slots.filter((s: SlotTime) => s.periodKey === periodKey);
    if (inPeriod.length === 0) {
      return '';
    }
    const first: SlotTime = inPeriod[0];
    const last: SlotTime = inPeriod[inPeriod.length - 1];
    return `${first.periodLabel} ${first.start}-${last.end}`;
  }
}

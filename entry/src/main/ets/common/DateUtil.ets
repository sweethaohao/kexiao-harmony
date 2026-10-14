/**
 * 课晓 · 日期时间工具
 * ---------------------------------------------------------------------------
 * 全部是纯函数（不碰任何 @ohos 能力），因此可以在电脑上直接用 Node 跑测试。
 *
 * 约定：
 *  - 内部一律使用「本地时区」的 Date 对象；
 *  - 日期字符串统一 yyyy-MM-dd，时间字符串统一 HH:mm；
 *  - 一周以「周一」为第一天（符合中国课表习惯）。
 * ---------------------------------------------------------------------------
 */

/** 一天的毫秒数 */
const DAY_MS: number = 24 * 60 * 60 * 1000;

export class DateUtil {
  /** 把数字补足两位：7 → '07' */
  static pad2(n: number): string {
    return n < 10 ? `0${n}` : `${n}`;
  }

  // -------------------------------------------------------------------------
  // 解析 / 格式化
  // -------------------------------------------------------------------------

  /** 'yyyy-MM-dd' → 本地时间 00:00 的 Date。解析失败时返回当天 00:00 */
  static parseDate(text: string): Date {
    const parts: string[] = text.split('-');
    if (parts.length === 3) {
      const y: number = Number.parseInt(parts[0], 10);
      const m: number = Number.parseInt(parts[1], 10);
      const d: number = Number.parseInt(parts[2], 10);
      if (!Number.isNaN(y) && !Number.isNaN(m) && !Number.isNaN(d)) {
        return new Date(y, m - 1, d, 0, 0, 0, 0);
      }
    }
    return DateUtil.startOfDay(new Date());
  }

  /** Date → 'yyyy-MM-dd' */
  static formatDate(d: Date): string {
    return `${d.getFullYear()}-${DateUtil.pad2(d.getMonth() + 1)}-${DateUtil.pad2(d.getDate())}`;
  }

  /** Date → 'HH:mm' */
  static formatHm(d: Date): string {
    return `${DateUtil.pad2(d.getHours())}:${DateUtil.pad2(d.getMinutes())}`;
  }

  /** Date → 'M月D日' */
  static formatMd(d: Date): string {
    return `${d.getMonth() + 1}月${d.getDate()}日`;
  }

  /** Date → 'M/D'（周视图列头用，短） */
  static formatSlashMd(d: Date): string {
    return `${d.getMonth() + 1}/${d.getDate()}`;
  }

  /** Date → 'yyyy-MM-dd HH:mm' */
  static formatDateTime(d: Date): string {
    return `${DateUtil.formatDate(d)} ${DateUtil.formatHm(d)}`;
  }

  // -------------------------------------------------------------------------
  // 时间字符串 ↔ 分钟数
  // -------------------------------------------------------------------------

  /** 'HH:mm' → 当天第几分钟。如 '08:00' → 480 */
  static hmToMinutes(hm: string): number {
    const parts: string[] = hm.split(':');
    if (parts.length < 2) {
      return 0;
    }
    const h: number = Number.parseInt(parts[0], 10);
    const m: number = Number.parseInt(parts[1], 10);
    if (Number.isNaN(h) || Number.isNaN(m)) {
      return 0;
    }
    return h * 60 + m;
  }

  /** 当天第几分钟 → 'HH:mm'。超过 24 小时会回绕（用于容错） */
  static minutesToHm(minutes: number): string {
    let m: number = minutes;
    if (m < 0) {
      m = 0;
    }
    const h: number = Math.floor(m / 60) % 24;
    const mm: number = m % 60;
    return `${DateUtil.pad2(h)}:${DateUtil.pad2(mm)}`;
  }

  // -------------------------------------------------------------------------
  // 日期运算
  // -------------------------------------------------------------------------

  /** 那天的 00:00 */
  static startOfDay(d: Date): Date {
    return new Date(d.getFullYear(), d.getMonth(), d.getDate(), 0, 0, 0, 0);
  }

  /** 那天的 23:59:59.999 */
  static endOfDay(d: Date): Date {
    return new Date(d.getFullYear(), d.getMonth(), d.getDate(), 23, 59, 59, 999);
  }

  /** 加 n 天（自然日，自动跨月跨年） */
  static addDays(d: Date, n: number): Date {
    return new Date(d.getFullYear(), d.getMonth(), d.getDate() + n, d.getHours(), d.getMinutes(), 0, 0);
  }

  /** 加 n 分钟 */
  static addMinutes(d: Date, n: number): Date {
    return new Date(d.getTime() + n * 60000);
  }

  /**
   * 把「某天的日期」和「HH:mm」拼成一个完整 Date。
   * 例：give dateAt(2026-10-14, '08:00') → 2026-10-14 08:00
   */
  static dateAt(day: Date, hm: string): Date {
    return new Date(day.getFullYear(), day.getMonth(), day.getDate(),
      Math.floor(DateUtil.hmToMinutes(hm) / 60), DateUtil.hmToMinutes(hm) % 60, 0, 0);
  }

  /** 是否同一天 */
  static isSameDay(a: Date, b: Date): boolean {
    return a.getFullYear() === b.getFullYear()
      && a.getMonth() === b.getMonth()
      && a.getDate() === b.getDate();
  }

  /** a 与 b 相差几个自然日（按 00:00 计算，b 在后为正） */
  static dayDiff(a: Date, b: Date): number {
    const sa: number = DateUtil.startOfDay(a).getTime();
    const sb: number = DateUtil.startOfDay(b).getTime();
    return Math.round((sb - sa) / DAY_MS);
  }

  /** 比较大小：a < b 返回 -1，a > b 返回 1，相等返回 0 */
  static compare(a: Date, b: Date): number {
    const ta: number = a.getTime();
    const tb: number = b.getTime();
    if (ta < tb) {
      return -1;
    }
    if (ta > tb) {
      return 1;
    }
    return 0;
  }

  // -------------------------------------------------------------------------
  // 星期（周一 = 1 … 周日 = 7）
  // -------------------------------------------------------------------------

  /**
   * 取星期序号，1 = 周一 … 7 = 周日。
   * JS 的 getDay() 是 0 = 周日 … 6 = 周六，需要转换。
   */
  static weekdayNum(d: Date): number {
    return ((d.getDay() + 6) % 7) + 1;
  }

  /** 取"中文短标签"，如「周一」 */
  static weekdayShortLabel(d: Date): string {
    const labels: string[] = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return labels[DateUtil.weekdayNum(d) - 1];
  }

  /** 取 d 所在那一周的周一（00:00） */
  static mondayOf(d: Date): Date {
    return DateUtil.addDays(DateUtil.startOfDay(d), -(DateUtil.weekdayNum(d) - 1));
  }

  /** 取 d 所在那一周的周日（00:00） */
  static sundayOf(d: Date): Date {
    return DateUtil.addDays(DateUtil.mondayOf(d), 6);
  }
}

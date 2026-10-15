/**
 * 课晓 · 粘贴文本解析（TextImportService）
 * ---------------------------------------------------------------------------
 * 为什么要有这个文件？
 *   课晓最初只认「电脑上跑脚本转出来的 JSON」，那条路要求用户有电脑、会跑脚本，
 *   而且各校导出的 Word/Excel 格式千差万别，脚本根本写不通用 —— 只能当开发者自用工具。
 *
 *   真正能推广的入口是「粘贴」：
 *     · 在教务系统的课表网页上 Ctrl+A / Ctrl+C
 *     · 或者在 Excel 里选中表格区域复制
 *   剪贴板里出来的都是「制表符分列 + 换行分行」的纯文本，不需要电脑、不需要脚本。
 *
 * 它认三种形态：
 *   ① 制表符表格（Excel 复制、多数教务网页复制）—— 单元格里可能有多行
 *   ② 空格分隔的表格（从 PDF / 记事本里复制出来的）
 *   ③ 一行一门课的列表（同学在群里发的文字课表）
 *
 * 另外：有些教务系统（比如我校的）复制出来的**纯文本**里连制表符都没有，
 * 格子结构全丢，"星期"这一列直接消失。这种情况靠剪贴板的 text/html 风味救回来 ——
 * 见 HtmlTableService 与 parseFromClipboard()。
 *
 * 解析策略是"能认出多少算多少，认不出的进告警"，绝不因为一格脏数据失败。
 * 真正落库前用户还会在预览里过一眼，所以宽容比严格更重要。
 *
 * 本文件是纯逻辑（不依赖 @ohos），可以在电脑上用 Node 跑测试。
 * ---------------------------------------------------------------------------
 */

import { ImportEntryJson, ImportResult, WEEKDAY_FULL, WEEKDAY_SHORT } from '../model/Models';
import { ImportService, parseWeekday, weeksToText } from './ImportService';
import { HtmlTableService } from './HtmlTableService';
import { DEFAULT_TOTAL_WEEKS } from '../model/Defaults';

// ===========================================================================
// 一、字元级小工具
// ===========================================================================

const CN_DIGITS: string = '零一二三四五六七八九十';

/** 中文数字 → 阿拉伯数字（只处理 0~99 这种课表里会出现的） */
export function cnNumber(text: string): number {
  const s: string = text.trim();
  if (s.length === 0) {
    return 0;
  }
  if (s.length === 1) {
    return CN_DIGITS.indexOf(s);
  }
  const tenPos: number = s.indexOf('十');
  if (tenPos === 0) {
    // 十 / 十一 / 十三
    if (s.length === 1) {
      return 10;
    }
    const u: number = CN_DIGITS.indexOf(s.charAt(1));
    return u > 0 ? 10 + u : 10;
  }
  if (tenPos === 1) {
    const t: number = CN_DIGITS.indexOf(s.charAt(0));
    if (t <= 0) {
      return 0;
    }
    if (s.length === 2) {
      return t * 10;
    }
    const u: number = CN_DIGITS.indexOf(s.charAt(2));
    return t * 10 + (u > 0 ? u : 0);
  }
  return 0;
}

/** 把串里的连续中文数字段换成阿拉伯数字，如「第三周」→「第3周」 */
function cnToArabic(text: string): string {
  let out: string = '';
  let buf: string = '';
  for (let i = 0; i < text.length; i++) {
    const ch: string = text.charAt(i);
    if (CN_DIGITS.indexOf(ch) >= 0) {
      buf += ch;
      continue;
    }
    if (buf.length > 0) {
      out += `${cnNumber(buf)}`;
      buf = '';
    }
    out += ch;
  }
  if (buf.length > 0) {
    out += `${cnNumber(buf)}`;
  }
  return out;
}

/** 取出串里全部整数，如 'a1b23' → [1, 23] */
function allNumbers(text: string): number[] {
  const out: number[] = [];
  const re: RegExp = /\d+/g;
  let m: RegExpExecArray | null = re.exec(text);
  while (m !== null) {
    out.push(Number(m[0]));
    m = re.exec(text);
  }
  return out;
}

/** 取出第一个形如 1-16 的区间；没有则返回空数组 */
function firstRange(text: string): number[] {
  const re: RegExp = /(\d+)\s*[-~–—至]\s*(\d+)/;
  const m: RegExpExecArray | null = re.exec(text);
  if (m === null) {
    return [];
  }
  return [Number(m[1]), Number(m[2])];
}

/** 单元格里的占位内容，当成"这一格没课" */
function isBlank(text: string): boolean {
  const s: string = text.replace(/\s/g, '');
  if (s.length === 0) {
    return true;
  }
  const placeholders: string[] = ['-', '—', '–', '/', '／', '无', '空', '无课', '未安排', 'N/A', 'n/a'];
  for (let i = 0; i < placeholders.length; i++) {
    if (s === placeholders[i]) {
      return true;
    }
  }
  return false;
}

// ===========================================================================
// 二、周次与节次
// ===========================================================================

/** 这一段文字里有没有周次信息（只要求出现「周」字，具体号码交给 parseWeeks 判断） */
export function hasWeekMarker(text: string): boolean {
  return text.indexOf('周') >= 0;
}

/** 光秃秃的区间，如 '1-16'。在表格单元格里它就是周次（因为行标签已经给出节次了） */
export function isBareRange(text: string): boolean {
  return /^\d{1,2}\s*[-~–—]\s*\d{1,2}$/.test(text.trim());
}

/**
 * 这一段的「周次」是不是可信的，而不是从一句备注里瞎抠出来的数字。
 *
 * 为什么需要这道闸门：教务系统的单元格里除了课，还会夹带备注，比如
 *   「周一党课分成2节17:00-18:30,18:45-20:15」
 * 这句话里带「周」字，parseWeeks 又是全局扫描数字的，于是会从
 * 「17:00-18:30」里抠出 `00-18`、从「18:45-20:15」里抠出 `45-20`，
 * 把一门课读成「第 1~18 周 + 第 20~45 周」。必须挡住。
 *
 * 认三种可信形态：
 *   ① 括号里带「周」  —— 教务系统标准写法：(1~12周)
 *   ② 整段就是周次表达式 —— 1-12 / 1~3,5~12周 / 第1-16周 / 单周 / 1-16周(单)
 *   ③ 段首是周次、后面跟别的东西 —— 1-8周 第3-4节
 */
export function weeksAreTrustworthy(text: string): boolean {
  const s: string = `${text}`.replace(/\s/g, '').split('（').join('(').split('）').join(')');
  if (s.length === 0) {
    return false;
  }
  if (/\([^)]{0,40}周[^)]{0,20}\)/.test(s)) {
    return true;
  }
  // ② 整段就是周次表达式：1-12 / 1~3,5~12周 / 第1-16周 / 单周 / 双周 / 1-16周(单)
  if (/^第?[\d单双,，、\-~–—至到]+周?(\((单|双)\))?$/.test(s) && /[\d单双]/.test(s)) {
    return true;
  }
  if (/^第?[\d单双,，、\-~–—至到]+周次?/.test(s)) {
    return true;
  }
  return false;
}

/**
 * 解析周次文本 → 升序去重的周次数组。
 *
 * 认这些写法：
 *   1-16周 / 1~16 / 1—16 / 第1-16周 / 1,3,5周 / 1-8,10-16周 / 单周 / 双周 / 1-16周(单) / 1-16周（双）
 *
 * allowBare = true 时，'1-16' 这种没有「周」字的裸区间也当周次
 * （表格单元格场景；列表场景必须写「周」，否则会和节次区间混淆）。
 */
export function parseWeeks(text: string, allowBare: boolean): number[] {
  if (text === undefined || text === null) {
    return [];
  }
  let s: string = `${text}`.replace(/\s/g, '');
  if (s.length === 0) {
    return [];
  }
  if (!allowBare && !hasWeekMarker(s)) {
    return [];
  }
  if (allowBare && !hasWeekMarker(s) && !isBareRange(s)) {
    return [];
  }
  // 全角括号统一，方便下面用半角匹配
  s = s.split('（').join('(').split('）').join(')');

  // ---- 单双周 ----
  let parity: number = 0;
  if (s.indexOf('单周') >= 0 || s.indexOf('(单)') >= 0 || s.indexOf('(单') >= 0) {
    parity = 1;
  } else if (s.indexOf('双周') >= 0 || s.indexOf('(双)') >= 0 || s.indexOf('(双') >= 0) {
    parity = 2;
  }

  // ---- 去掉所有修饰，只留数字与区间 ----
  let body: string = s;
  const noise: string[] = ['单周', '双周', '(单)', '(双)', '(单', '(双', '单周次', '双周次', '单', '双'];
  for (let i = 0; i < noise.length; i++) {
    body = body.split(noise[i]).join('');
  }
  body = body.split('周').join('');

  const found: Set<number> = new Set<number>();

  // 区间优先，避免 '1-16' 被当成 1 和 16 两个孤立周
  const re: RegExp = /(\d+)\s*[-~–—至]\s*(\d+)/g;
  const spans: string[] = [];
  let m: RegExpExecArray | null = re.exec(body);
  while (m !== null) {
    const a: number = Number(m[1]);
    const b: number = Number(m[2]);
    if (!Number.isNaN(a) && !Number.isNaN(b)) {
      const lo: number = Math.min(a, b);
      const hi: number = Math.min(Math.max(a, b), 60);
      for (let w = Math.max(lo, 1); w <= hi; w++) {
        found.add(w);
      }
    }
    spans.push(m[0]);
    m = re.exec(body);
  }
  let rest: string = body;
  for (let i = 0; i < spans.length; i++) {
    rest = rest.split(spans[i]).join(',');
  }
  const singles: number[] = allNumbers(rest);
  for (let i = 0; i < singles.length; i++) {
    if (singles[i] >= 1 && singles[i] <= 60) {
      found.add(singles[i]);
    }
  }

  let list: number[] = Array.from(found);
  list.sort((a: number, b: number) => a - b);

  // 只写了「单周 / 双周」而没写范围的情况（教务系统里确实有）：
  // 按默认学期长度铺一遍，再筛单双。宁可先填上让用户在预览里改，
  // 也不要因为"信息不全"就把整门课丢掉。
  if (list.length === 0 && parity > 0) {
    for (let w = 1; w <= DEFAULT_TOTAL_WEEKS; w++) {
      list.push(w);
    }
  }

  if (parity === 1) {
    list = list.filter((w: number) => w % 2 === 1);
  } else if (parity === 2) {
    list = list.filter((w: number) => w % 2 === 0);
  }
  return list;
}

/** 把周次描述从一段文字里剪掉，剩下的通常是课程名 */
export function stripWeeks(text: string): string {
  let s: string = text;
  s = s.replace(/[（(\[【]\s*第?\s*[\d,，、\-~–—至\s]+\s*周\s*[)）\]】]\s*[单双]?/g, '');
  s = s.replace(/第?\s*[\d,，、\-~–—至\s]+\s*周/g, '');
  s = s.replace(/[（(\[【]\s*[单双]\s*[)）\]】]/g, '');
  s = s.replace(/[单双]周/g, '');
  s = s.replace(/[\s,，、]+$/, '');
  s = s.replace(/^[\s,，、]+/, '');
  return s.trim();
}

/**
 * 解析节次文本 → [起, 止]。
 * 认：1-2节 / 第1节 / 3 / 3,4 / 第一节 / 一二节 / 第1、2节
 */
export function parseSlots(text: string): number[] {
  if (text === undefined || text === null) {
    return [];
  }
  let s: string = `${text}`.replace(/\s/g, '');
  s = s.split('第').join('').split('节').join('').split('次').join('');
  s = s.split('大').join('').split('小').join('');
  s = s.split('、').join(',').split('，').join(',');
  if (s.length === 0) {
    return [];
  }
  // 纯中文数字的连写（「一二节」= 第1、2节），中文里不会出现 11 以上的节次
  if (!s.includes('十') && /^[一二三四五六七八九]+$/.test(s)) {
    const nums: number[] = [];
    for (let i = 0; i < s.length; i++) {
      const v: number = CN_DIGITS.indexOf(s.charAt(i));
      if (v > 0) {
        nums.push(v);
      }
    }
    if (nums.length === 1) {
      return [nums[0], nums[0]];
    }
    if (nums.length > 1) {
      return [Math.min(nums[0], nums[nums.length - 1]), Math.max(nums[0], nums[nums.length - 1])];
    }
    return [];
  }
  s = cnToArabic(s);
  const range: number[] = firstRange(s);
  if (range.length === 2) {
    return [Math.min(range[0], range[1]), Math.max(range[0], range[1])];
  }
  const nums: number[] = allNumbers(s);
  if (nums.length === 0) {
    return [];
  }
  if (nums.length === 1) {
    return [nums[0], nums[0]];
  }
  const lo: number = Math.min(nums[0], nums[nums.length - 1]);
  const hi: number = Math.max(nums[0], nums[nums.length - 1]);
  return [lo, hi];
}

// ===========================================================================
// 三、单元格内容拆解
// ===========================================================================

/** 教室长什么样：含「楼/馆/室/区/场/房」，或以「教」开头带数字，或 A101 / B-203 / 302 / 12-713 / 机房301 这种编号 */
export function looksLikeRoom(text: string): boolean {
  const s: string = text.trim();
  if (s.length === 0 || s.length > 16) {
    return false;
  }
  if (/[楼馆室区场房]/.test(s)) {
    return true;
  }
  if (s.charAt(0) === '教' && /\d/.test(s)) {
    return true;
  }
  if (/^[A-Za-z]{1,3}[-–]?\d{2,4}$/.test(s)) {
    return true;
  }
  if (/^\d{3,4}$/.test(s)) {
    return true;
  }
  // 「12-713」这种"楼号-房间号"（房间号必须是 3~4 位）。
  // 千万不要放宽成 1~4 位：那样「1-16周」被去掉「周」字后的「1-16」会被当成教室。
  if (/^\d{1,3}[-–]\d{3,4}$/.test(s)) {
    return true;
  }
  // 「机房301」这种"楼名+房间号"
  if (/^[\u4e00-\u9fa5]{1,4}\d{2,4}$/.test(s)) {
    return true;
  }
  return false;
}

/**
 * 「编号型」教室的强特征。
 *
 * 为什么要单独拎出来：教务系统常把一门课压成一行
 *   「(1~12周) (第五节-第六节) 金海 4212  孔楠」   ← 校区 教室 教师
 * 拆词之后没法按"第一个像人名的就是教师"来判 —— 校区名（金海）也是两个字，
 * 顺序扫过去会把校区当成教师。所以先靠"编号型教室"这个词当锚点，
 * 锚点后面第一个像人名的才是教师。
 */
function looksLikeRoomCode(text: string): boolean {
  const s: string = text.trim();
  if (s.length === 0 || s.length > 12) {
    return false;
  }
  if (/^\d{3,4}$/.test(s)) {
    return true;
  }
  if (/^\d{1,3}[-–]\d{3,4}$/.test(s)) {
    return true;
  }
  if (/^[A-Za-z]{1,3}[-–]?\d{2,4}$/.test(s)) {
    return true;
  }
  return false;
}

/**
 * 从「(第一节-第二节)」这种**显式节次**里取范围，取不到返回空数组。
 *
 * 为什么要它：课表里"跨节次"的课在表格中往往用合并单元格表示，
 * 转成文本后行标签可能只剩「第一节」，只有格子自己写着「第一节-第二节」。
 * 所以格子里的节次比行标签可信。要求必须出现「节/次」，否则
 * 「(1~12周)」会被误当成节次范围。
 */
function explicitSlotRange(text: string): number[] {
  const s: string = text.trim();
  if (s.length === 0 || s.length > 20) {
    return [];
  }
  if (!/[节次]/.test(s)) {
    return [];
  }
  const re: RegExp = /^[(（]?\s*第?\s*([一二三四五六七八九十\d]{1,3})\s*[节次]?\s*[-–~至到]\s*第?\s*([一二三四五六七八九十\d]{1,3})\s*[节次]?\s*[)）]?$/;
  const m: RegExpExecArray | null = re.exec(s.replace(/\s+/g, ''));
  if (m === null) {
    return [];
  }
  const a: number[] = parseSlots(m[1]);
  const b: number[] = parseSlots(m[2]);
  if (a.length === 0 || b.length === 0) {
    return [];
  }
  return [Math.min(a[0], b[0]), Math.max(a[0], b[0])];
}

/** 教师长什么样：2~4 个汉字，或带「老师/教授」这类后缀 */
export function looksLikeTeacher(text: string): boolean {
  const s: string = text.trim();
  if (s.length === 0 || s.length > 10) {
    return false;
  }
  const suffixes: string[] = ['老师', '教授', '教师', '讲师', '助教'];
  for (let i = 0; i < suffixes.length; i++) {
    const suf: string = suffixes[i];
    if (s.length > suf.length && s.substring(s.length - suf.length) === suf) {
      const core: string = s.substring(0, s.length - suf.length);
      return core.length >= 1 && /^[\u4e00-\u9fa5]+$/.test(core);
    }
  }
  if (!/^[\u4e00-\u9fa5]{2,4}$/.test(s)) {
    return false;
  }
  if (/[楼馆室区周节课场房]/.test(s)) {
    return false;
  }
  return true;
}

/**
 * 把一个单元格切成若干段。
 * 教务系统导出的格子里，课程名/周次/教师/教室常是四行，或者用空格、竖线隔开。
 */
function splitCellParts(cell: string): string[] {
  const parts: string[] = [];
  const byLine: string[] = cell.split(/[\n\r]+/);
  for (let i = 0; i < byLine.length; i++) {
    const seg: string = byLine[i].trim();
    if (seg.length > 0) {
      parts.push(seg);
    }
  }
  if (parts.length > 1) {
    return parts;
  }
  // 单段：试着用竖线拆
  const byBar: string[] = cell.split(/[|｜]/);
  const barParts: string[] = [];
  for (let i = 0; i < byBar.length; i++) {
    const t: string = byBar[i].trim();
    if (t.length > 0) {
      barParts.push(t);
    }
  }
  if (barParts.length > 1) {
    return barParts;
  }
  // 还是单段：只有当空格后面跟着像教室/老师的东西时才按空格拆，
  // 否则会把「大学 英语」这种带空格的课程名拆坏
  const single: string = parts.length > 0 ? parts[0] : cell.trim();
  const bySpace: string[] = single.split(/\s+/);
  if (bySpace.length >= 2) {
    let hint: boolean = false;
    for (let i = 1; i < bySpace.length; i++) {
      if (looksLikeRoom(bySpace[i]) || looksLikeTeacher(bySpace[i])) {
        hint = true;
        break;
      }
    }
    if (hint) {
      const out: string[] = [];
      for (let i = 0; i < bySpace.length; i++) {
        if (bySpace[i].length > 0) {
          out.push(bySpace[i]);
        }
      }
      return out;
    }
  }
  return parts.length > 0 ? parts : [single];
}

/**
 * 一个格子里可能塞了两门课（比如单周一门、双周一门）。
 * 判定依据：含周次的段数。两门课通常就写两处周次。
 * 只有「段数 ≥ 周次段数 × 2」时才真的切，避免把
 * 「1-8周 9-16周」这种同一门课的两段周次误判成两门课。
 */
/**
 * 一格里的「分隔线」：教务系统打印/导出课表时，会把同一格的多门课用一整行短横线隔开。
 * 例如（真机实测，某校教务系统导出的课表）：
 *
 *   离散数学
 *   1-12
 *   -----------
 *   数字电路综合实验
 *   13-16
 *
 * 这种分隔线是**显式**信号，比任何启发式都可靠，优先按它切。
 */
export function isGroupSeparator(text: string): boolean {
  const s: string = text.trim();
  return s.length >= 3 && /^[-–—_=+*·•~]+$/.test(s);
}

/**
 * 这一段像不像「周次」。
 * 注意不能只看 hasWeekMarker —— 教务系统的表格里周次经常写成光秃秃的 `1-12`
 * （因为列标题已经说明了这是周次），只认「周」字会把同格多课全压成一门课。
 */
function weekLike(text: string): boolean {
  const s: string = text.trim();
  if (s.length === 0 || !weeksAreTrustworthy(s)) {
    return false;
  }
  if (parseWeeks(s, true).length === 0) {
    return false;
  }
  return hasWeekMarker(s) || isBareRange(s);
}

/**
 * 把一个单元格切成「若干门课」。
 * 两条路：① 有显式分隔线就按它硬切；② 没有就按周次段出现的次数估切。
 */
function splitCellGroups(parts: string[]): string[][] {
  const kept: string[] = [];
  const hard: string[][] = [];
  let cur: string[] = [];
  let sawSep: boolean = false;
  for (let i = 0; i < parts.length; i++) {
    if (isGroupSeparator(parts[i])) {
      sawSep = true;
      if (cur.length > 0) {
        hard.push(cur);
        cur = [];
      }
      continue;
    }
    kept.push(parts[i]);
    cur.push(parts[i]);
  }
  if (cur.length > 0) {
    hard.push(cur);
  }
  if (sawSep && hard.length >= 2) {
    return hard;
  }

  const weekIdx: number[] = [];
  for (let i = 0; i < parts.length; i++) {
    if (weekLike(parts[i])) {
      weekIdx.push(i);
    }
  }
  if (weekIdx.length < 2 || parts.length < weekIdx.length * 2) {
    return [kept];
  }
  const groups: string[][] = [];
  const n: number = parts.length;
  const g: number = weekIdx.length;
  for (let k = 0; k < g; k++) {
    const from: number = Math.floor((k * n) / g);
    const to: number = Math.floor(((k + 1) * n) / g);
    const chunk: string[] = [];
    for (let i = from; i < to; i++) {
      chunk.push(parts[i]);
    }
    if (chunk.length > 0) {
      groups.push(chunk);
    }
  }
  return groups.length > 0 ? groups : [kept];
}

// ===========================================================================
// 四、解析产物
// ===========================================================================

/** 解析出来的一条排课（还没做课程归并，所以只有课程名） */
export interface TextPiece {
  name: string;
  room: string;
  teacher: string;
  weeks: number[];
  weekday: number;
  startSlot: number;
  endSlot: number;
}

/**
 * 把一组段（同一门课）拼成一条排课。
 *
 * 约定：第一段是课程名；周次段可以是任意一段；教室/教师从"信息段"里认。
 *
 * 关于"信息段"：大部分教务系统会把一门课写成
 *   课程名 / 课程号 / 「(1~12周) (第一节-第二节) 金海 4309  阙程晟」 / 选课班级
 * 也就是**周次那一行同时带着节次、校区、教室、教师**。所以先把这一行去掉周次后的
 * 剩余部分标为"信息段"，拆词时优先用它 —— 课程号那一行是纯数字，
 * 让它参与会更容易和教室混淆。
 */
function pieceFromParts(parts: string[], weekday: number, startSlot: number,
                        endSlot: number, allowBare: boolean): TextPiece {
  let weeks: number[] = [];
  let nameSource: string = '';
  let infoLine: string = '';
  const rest: string[] = [];
  for (let i = 0; i < parts.length; i++) {
    const p: string = parts[i].trim();
    if (p.length === 0) {
      continue;
    }
    if (weeks.length === 0 && weeksAreTrustworthy(p)
        && (hasWeekMarker(p) || (allowBare && isBareRange(p)))) {
      const w: number[] = parseWeeks(p, allowBare);
      if (w.length > 0) {
        weeks = w;
        const leftover: string = stripWeeks(p);
        if (i === 0) {
          nameSource = leftover;
          infoLine = leftover;
        } else if (leftover.length > 0) {
          infoLine = infoLine.length > 0 ? `${infoLine} ${leftover}` : leftover;
        }
        continue;
      }
    }
    if (i === 0) {
      nameSource = p;
    } else {
      rest.push(p);
    }
  }

  let name: string = nameSource.trim();
  let restStart: number = 0;
  if (name.length === 0 && rest.length > 0) {
    name = rest[0].trim();
    restStart = 1;
  }

  // ---- 拆词：信息段优先，其余段落兜底 ----
  const words: string[] = [];
  appendWords(words, infoLine);
  for (let i = restStart; i < rest.length; i++) {
    appendWords(words, rest[i]);
  }

  // ---- 格子里写了显式节次就用它，比行标签准（合并单元格转文本后行标签会缺）----
  for (let i = 0; i < words.length; i++) {
    const range: number[] = explicitSlotRange(words[i]);
    if (range.length === 2) {
      startSlot = range[0];
      endSlot = range[1];
      break;
    }
  }

  // ---- 教室 / 教师 ----
  // 顺序很重要：先从后往前找"像人名的词"当教师，再看它前一个词是不是教室。
  // 反过来按"第一个像人名的就是教师"扫，会把校区名（金海）当成教师。
  let teacher: string = '';
  let teacherAt: number = -1;
  for (let i = words.length - 1; i >= 0; i--) {
    if (looksLikeTeacher(words[i])) {
      teacher = words[i];
      teacherAt = i;
      break;
    }
  }

  let room: string = '';
  if (teacherAt > 0 && looksLikeRoom(words[teacherAt - 1])) {
    // 「金海 4309  阙程晟」/「金海 网球场  范国强」—— 教师紧邻的前一个词就是教室
    room = words[teacherAt - 1];
  }
  if (room.length === 0) {
    for (let i = 0; i < words.length; i++) {
      if (looksLikeRoomCode(words[i])) {
        room = words[i];
        break;
      }
    }
  }
  if (room.length === 0) {
    for (let i = 0; i < words.length; i++) {
      if (looksLikeRoom(words[i])) {
        room = words[i];
        break;
      }
    }
  }
  if (room.length === 0) {
    // 最后兜底：教务课表末段十有八九是教室，实在认不出来就先落在那儿。
    // 跳过教师本身和"选课班级"那种一串分号的段落。
    for (let i = words.length - 1; i >= 0; i--) {
      const w: string = words[i];
      if (w === teacher || /[;；,，]/.test(w)) {
        continue;
      }
      room = w;
      break;
    }
  }

  const piece: TextPiece = {
    name: name,
    room: room,
    teacher: teacher,
    weeks: weeks,
    weekday: weekday,
    startSlot: startSlot,
    endSlot: endSlot
  };
  return piece;
}

/**
 * 把一段话按空白拆成词塞进 words。
 *
 * 拆词是必需的：教务系统把「校区 教室 教师」挤在一行用空格隔开，
 * 不拆就只能整行当教室，教师全丢。
 */
function appendWords(words: string[], text: string): void {
  const t: string = text.trim();
  if (t.length === 0) {
    return;
  }
  const chunks: string[] = t.split(/\s+/);
  for (let i = 0; i < chunks.length; i++) {
    const c: string = chunks[i].trim();
    if (c.length > 0) {
      words.push(c);
    }
  }
}

// ===========================================================================
// 五、表格结构
// ===========================================================================

interface GridSpec {
  /** 表头所在行下标 */
  rowIndex: number;
  /** 列下标 → 星期序号；0 表示这列不是星期 */
  colToWeekday: number[];
  /** 前几列是行标签（节次） */
  labelCols: number;
  /** 表头覆盖到第几列 */
  columnCount: number;
}

/** 严格一点的星期识别：必须带「周/星期/礼拜」或英文缩写，避免把裸数字「1」当成周一 */
function parseWeekdayToken(text: string): number {
  const s: string = text.replace(/\s/g, '');
  if (s.length === 0 || s.length > 6) {
    return 0;
  }
  if (/[周星期礼拜]/.test(s)) {
    return parseWeekday(s);
  }
  if (/^(mon|tue|wed|thu|fri|sat|sun)/i.test(s)) {
    return parseWeekday(s);
  }
  return 0;
}

/** 一行里出现几个星期词 */
function countWeekdayTokens(line: string): number {
  let n: number = 0;
  for (let i = 0; i < 7; i++) {
    if (line.indexOf(WEEKDAY_SHORT[i]) >= 0) {
      n++;
    }
  }
  return n;
}

/** 粗切（按行 + 制表符），只为找表头用 */
function probeRows(text: string): string[][] {
  const out: string[][] = [];
  const lines: string[] = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    out.push(lines[i].replace(/\r/g, '').split('\t'));
  }
  return out;
}

function findHeader(rows: string[][]): GridSpec | undefined {
  for (let r = 0; r < rows.length; r++) {
    const row: string[] = rows[r];
    const map: number[] = [];
    let weekdayCount: number = 0;
    let firstWeekdayCol: number = -1;
    let lastWeekdayCol: number = -1;
    for (let c = 0; c < row.length; c++) {
      const wd: number = parseWeekdayToken(row[c]);
      map.push(wd);
      if (wd > 0) {
        weekdayCount++;
        if (firstWeekdayCol < 0) {
          firstWeekdayCol = c;
        }
        lastWeekdayCol = c;
      }
    }
    if (weekdayCount >= 3 && firstWeekdayCol >= 1) {
      const spec: GridSpec = {
        rowIndex: r,
        colToWeekday: map,
        labelCols: firstWeekdayCol,
        columnCount: lastWeekdayCol + 1
      };
      return spec;
    }
  }
  return undefined;
}

/**
 * 找不到表头时的兜底：假定前面是标签列，后面 7 列依次是周一到周日。
 *
 * 要求至少 8 列（1 个标签列 + 7 天）。列数不够就宁可认不出来 ——
 * 硬猜的话会把"周三"的课塞进"周一"，用户还看不出来，比直接失败更糟。
 */
function fallbackSpec(rows: string[][]): GridSpec | undefined {
  let width: number = 0;
  for (let i = 0; i < rows.length; i++) {
    if (rows[i].length > width) {
      width = rows[i].length;
    }
  }
  if (width < 8) {
    return undefined;
  }
  const labelCols: number = Math.max(width - 7, 1);
  const map: number[] = [];
  for (let c = 0; c < width; c++) {
    map.push(c >= labelCols ? c - labelCols + 1 : 0);
  }
  const spec: GridSpec = {
    rowIndex: 0,
    colToWeekday: map,
    labelCols: labelCols,
    columnCount: width
  };
  return spec;
}

/**
 * ★ 精细切割。
 *
 * 难点：教务系统课表的一个格子里经常是好几行（课程名 / 教师 / 教室），
 * 复制出来的纯文本里这些换行和"行与行之间的换行"长得一模一样。
 *
 * 判据：**制表符负责换列，换行是否换"记录"取决于当前在第几列。**
 *   - 停在最后一列时遇到换行 → 一条记录结束；
 *   - 停在中途遇到换行 → 这个格子还没写完，把换行留在格子里。
 */
function buildGrid(text: string, columnCount: number): string[][] {
  const rows: string[][] = [];
  let cells: string[] = [''];
  let col: number = 0;
  const n: number = text.length;
  let i: number = 0;
  while (i < n) {
    const ch: string = text.charAt(i);
    if (ch === '\t') {
      col++;
      cells.push('');
      i++;
      continue;
    }
    if (ch === '\n' || ch === '\r') {
      if (ch === '\r' && i + 1 < n && text.charAt(i + 1) === '\n') {
        i++;
      }
      if (col === 0 || col >= columnCount - 1) {
        rows.push(cells);
        cells = [''];
        col = 0;
      } else {
        cells[col] = `${cells[col]}\n`;
      }
      i++;
      continue;
    }
    cells[col] = cells[col] + ch;
    i++;
  }
  let any: boolean = false;
  for (let k = 0; k < cells.length; k++) {
    if (cells[k].trim().length > 0) {
      any = true;
      break;
    }
  }
  if (any) {
    rows.push(cells);
  }
  return rows;
}

function isBlankRow(row: string[]): boolean {
  for (let i = 0; i < row.length; i++) {
    if (row[i].trim().length > 0) {
      return false;
    }
  }
  return true;
}

function rowLabel(row: string[], spec: GridSpec): string {
  let label: string = '';
  const last: number = Math.min(spec.labelCols, row.length);
  for (let c = 0; c < last; c++) {
    label += (label.length > 0 ? ' ' : '') + row[c];
  }
  return label;
}

/**
 * 收尾修补：上面那套判据在"最后一格自己就是多行"时会把它的第二行
 * 误当成新记录。这里再用一次「首列能不能解析成节次」来兜：
 * 首列不是节次的行，接回上一行的最后一格。
 */
function mergeContinuationRows(rows: string[][], spec: GridSpec): string[][] {
  const out: string[][] = [];
  for (let i = 0; i < rows.length; i++) {
    const row: string[] = rows[i];
    // 表头及之前的行原样保留，保证 out[rowIndex] 就是表头，后面的下标才对得上
    if (i <= spec.rowIndex) {
      out.push(row);
      continue;
    }
    if (isBlankRow(row)) {
      continue;
    }
    const slots: number[] = parseSlots(rowLabel(row, spec));
    if (slots.length !== 2 && out.length > spec.rowIndex + 1) {
      const prev: string[] = out[out.length - 1];
      const lastIdx: number = Math.max(prev.length - 1, 0);
      const extra: string = row.join(' ').trim();
      if (extra.length > 0) {
        prev[lastIdx] = prev[lastIdx].length > 0 ? `${prev[lastIdx]}\n${extra}` : extra;
      }
      continue;
    }
    out.push(row);
  }
  return out;
}

interface CollectResult {
  pieces: TextPiece[];
  skipped: number;
}

/** 从表头之后的行里逐格取课 */
function collectFromRows(rows: string[][], spec: GridSpec, allowBare: boolean): CollectResult {
  const pieces: TextPiece[] = [];
  let skipped: number = 0;
  for (let r = spec.rowIndex + 1; r < rows.length; r++) {
    const row: string[] = rows[r];
    const slots: number[] = parseSlots(rowLabel(row, spec));
    if (slots.length !== 2) {
      skipped++;
      continue;
    }
    for (let c = spec.labelCols; c < spec.columnCount; c++) {
      if (c >= row.length) {
        continue;
      }
      const weekday: number = c < spec.colToWeekday.length ? spec.colToWeekday[c] : 0;
      if (weekday <= 0) {
        continue;
      }
      const content: string = row[c];
      if (isBlank(content)) {
        continue;
      }
      const parts: string[] = splitCellParts(content);
      if (parts.length === 0) {
        continue;
      }
      const groups: string[][] = splitCellGroups(parts);
      for (let g = 0; g < groups.length; g++) {
        const piece: TextPiece = pieceFromParts(groups[g], weekday, slots[0], slots[1], allowBare);
        if (piece.name.length > 0) {
          pieces.push(piece);
        } else {
          skipped++;
        }
      }
    }
  }
  const result: CollectResult = { pieces: pieces, skipped: skipped };
  return result;
}

// ===========================================================================
// 六、列表式
// ===========================================================================

function tokenizeLine(line: string): string[] {
  const out: string[] = [];
  const rough: string[] = line.split(/[\s]+/);
  for (let i = 0; i < rough.length; i++) {
    const parts: string[] = rough[i].split(/[,，;；|｜]+/);
    for (let k = 0; k < parts.length; k++) {
      const t: string = parts[k].trim();
      if (t.length > 0) {
        out.push(t);
      }
    }
  }
  return out;
}

/** 列表里的节次段：带「节」，或者是 1 / 1-2 这种短数字 */
function slotLike(token: string): boolean {
  if (token.indexOf('节') >= 0) {
    return true;
  }
  return /^\d{1,2}$/.test(token) || /^\d{1,2}[-~–—]\d{1,2}$/.test(token);
}

interface LineResult {
  piece: TextPiece | undefined;
  reason: string;
}

function pieceFromLine(line: string): LineResult {
  const tokens: string[] = tokenizeLine(line);
  let weekday: number = 0;
  let weeks: number[] = [];
  let slots: number[] = [];
  let room: string = '';
  const rest: string[] = [];

  for (let i = 0; i < tokens.length; i++) {
    const tk: string = tokens[i];
    if (weekday === 0) {
      const wd: number = parseWeekdayToken(tk);
      if (wd > 0) {
        weekday = wd;
        continue;
      }
    }
    if (weeks.length === 0 && hasWeekMarker(tk)) {
      const w: number[] = parseWeeks(tk, false);
      if (w.length > 0) {
        weeks = w;
        const leftover: string = stripWeeks(tk);
        if (leftover.length > 0) {
          rest.push(leftover);
        }
        continue;
      }
    }
    if (slots.length === 0 && slotLike(tk)) {
      const sp: number[] = parseSlots(tk);
      if (sp.length === 2) {
        slots = sp;
        continue;
      }
    }
    if (room.length === 0 && looksLikeRoom(tk)) {
      room = tk;
      continue;
    }
    rest.push(tk);
  }

  if (weekday === 0) {
    const none: LineResult = { piece: undefined, reason: '没找到星期' };
    return none;
  }
  if (rest.length === 0) {
    const none: LineResult = { piece: undefined, reason: '没找到课程名' };
    return none;
  }
  if (slots.length !== 2) {
    const none: LineResult = { piece: undefined, reason: '没找到节次' };
    return none;
  }

  const name: string = rest[0];
  let teacher: string = '';
  if (rest.length >= 2 && looksLikeTeacher(rest[1])) {
    teacher = rest[1];
  } else if (rest.length >= 2 && rest[1].length <= 4 && !looksLikeRoom(rest[1])) {
    teacher = rest[1];
  }

  const piece: TextPiece = {
    name: name,
    room: room,
    teacher: teacher,
    weeks: weeks,
    weekday: weekday,
    startSlot: slots[0],
    endSlot: slots[1]
  };
  const ok: LineResult = { piece: piece, reason: '' };
  return ok;
}

// ===========================================================================
// 七、默认周次推断
// ===========================================================================

/**
 * 很多教务系统的课表页面上根本不写周次（整张表就是本学期的课）。
 * 这时候从标题里找一下「第 5 周」或「1-16周」，找不到就按默认学期长度填，
 * 并在告警里说清楚"这是我替你填的"。
 */
function detectDefaultWeeks(text: string): number[] {
  const firstLine: string = text.split('\n')[0];
  const rangeRe: RegExp = /(\d{1,2})\s*[-~–—至]\s*(\d{1,2})\s*周/;
  const mr: RegExpExecArray | null = rangeRe.exec(firstLine);
  if (mr !== null) {
    const lo: number = Math.max(Number(mr[1]), 1);
    const hi: number = Math.min(Number(mr[2]), 60);
    const out: number[] = [];
    for (let w = lo; w <= hi; w++) {
      out.push(w);
    }
    return out;
  }
  const singleRe: RegExp = /第\s*(\d{1,2})\s*周/;
  const ms: RegExpExecArray | null = singleRe.exec(firstLine);
  if (ms !== null) {
    return [Math.max(Number(ms[1]), 1)];
  }
  return [];
}

function defaultWeeksRange(): number[] {
  const out: number[] = [];
  for (let w = 1; w <= DEFAULT_TOTAL_WEEKS; w++) {
    out.push(w);
  }
  return out;
}

// ===========================================================================
// 八、对外入口
// ===========================================================================

export class TextImportService {
  /**
   * 从剪贴板的两种风味里挑更好的那份来解析。
   *
   * 网页上复制的课表，纯文本风味里"星期"这一列的信息往往是丢的（格子之间
   * 连制表符都没有），而 HTML 风味里表格结构完好。所以先用 HTML 摊平成
   * 制表符文本，认出课就采用；认不出来再退回纯文本，两条路都走同一套解析规则。
   *
   * @param plain  剪贴板 text/plain 风味
   * @param html   剪贴板 text/html 风味，没有就传空串
   * @param source 来源标签
   */
  static parseFromClipboard(plain: string, html: string, source: string): ImportResult {
    const rich: string = html.length > 0 && HtmlTableService.looksLikeTable(html)
      ? HtmlTableService.toGridText(html)
      : '';
    if (rich.length > 0) {
      const byHtml: ImportResult = TextImportService.parse(rich, source);
      if (byHtml.ok && byHtml.items.length > 0) {
        return byHtml;
      }
    }
    return TextImportService.parse(plain, source);
  }

  /**
   * 解析用户粘贴的课表文本。
   *
   * @param text   粘贴进来的原始文本
   * @param source 来源标签，会写进数据库用于回显（如「粘贴导入」）
   */
  static parse(text: string, source: string): ImportResult {
    const clean: string = TextImportService.normalize(text);
    if (clean.trim().length === 0) {
      return TextImportService.fail('没有读到内容。请先在课表页面上全选复制，再粘贴到这里');
    }

    const lines: string[] = clean.split('\n');
    const hintedWeeks: number[] = detectDefaultWeeks(clean);

    let collected: CollectResult = { pieces: [], skipped: 0 };
    const tabLines: number = TextImportService.countTabLines(lines);

    if (tabLines >= 2) {
      // ---- ① 制表符表格 ----
      const spec: GridSpec | undefined = TextImportService.resolveSpec(clean);
      if (spec === undefined) {
        return TextImportService.fail(TextImportService.diagnoseFailure(clean,
          '这段内容看起来是表格，但没找到「周一 ~ 周日」那一行，请确认复制的是课表区域'));
      }
      const rows: string[][] = mergeContinuationRows(buildGrid(clean, spec.columnCount), spec);
      collected = collectFromRows(rows, spec, true);
    } else if (TextImportService.hasWeekdayRow(lines)) {
      // ---- ② 空格分隔的表格 ----
      const rows: string[][] = TextImportService.splitBySpaces(lines);
      const spec: GridSpec | undefined = findHeader(rows);
      if (spec === undefined) {
        return TextImportService.fail(
          '没找到「周一 ~ 周日」那一行，请确认复制的是课表区域');
      }
      collected = collectFromRows(rows, spec, true);
    } else {
      // ---- ③ 一行一门课 ----
      collected = TextImportService.collectFromLines(lines);
      if (collected.pieces.length === 0) {
        return TextImportService.fail(
          TextImportService.diagnoseFailure(clean, TextImportService.explainListFailure(lines)));
      }
    }

    if (collected.pieces.length === 0) {
      return TextImportService.fail('这段内容里没有认出任何一门课，请确认复制的是课表区域');
    }

    // ---- 补齐缺失的周次 ----
    const warnings: string[] = [];
    let guessed: number = 0;
    const pieces: TextPiece[] = collected.pieces;
    for (let i = 0; i < pieces.length; i++) {
      if (pieces[i].weeks.length === 0) {
        pieces[i].weeks = hintedWeeks.length > 0 ? hintedWeeks.slice() : defaultWeeksRange();
        guessed++;
      }
    }
    if (guessed > 0) {
      const sample: number[] = pieces[0].weeks;
      const label: string = hintedWeeks.length > 0
        ? `${sample[0]}~${sample[sample.length - 1]}`
        : `1~${DEFAULT_TOTAL_WEEKS}`;
      warnings.push(
        `有 ${guessed} 条排课没写上课周次，已先按第 ${label} 周填入，请在预览里核对`);
    }
    if (collected.skipped > 0) {
      warnings.push(`有 ${collected.skipped} 处内容没认出来，已跳过`);
    }

    // ---- 交给 ImportService 收口（去重 / 归并课程 / 汇总）----
    const entries: ImportEntryJson[] = [];
    for (let i = 0; i < pieces.length; i++) {
      const p: TextPiece = pieces[i];
      let weeks: number[] = p.weeks;
      if (weeks.length === 0) {
        continue;
      }
      const entry: ImportEntryJson = {
        courseName: p.name,
        courseCode: '',
        startSlot: p.startSlot,
        endSlot: p.endSlot,
        weeks: weeks,
        weeksRaw: weeksToText(weeks),
        campus: '',
        room: p.room,
        teacher: p.teacher,
        weekday: WEEKDAY_FULL[p.weekday - 1],
        slot: `${p.startSlot}-${p.endSlot}`
      };
      entries.push(entry);
    }

    const result: ImportResult = ImportService.buildResult(entries, source);
    if (!result.ok) {
      return result;
    }
    const merged: string[] = warnings.concat(result.warnings);
    result.warnings = merged;
    return result;
  }

  /** 统一换行、去 BOM、把各种空格归一 */
  static normalize(text: string): string {
    if (text === undefined || text === null) {
      return '';
    }
    let s: string = `${text}`;
    s = s.split('\uFEFF').join('');
    s = s.split('\r\n').join('\n').split('\r').join('\n');
    s = s.split('\u00a0').join(' ');
    s = s.split('\u3000').join(' ');
    return s;
  }

  private static fail(message: string): ImportResult {
    const empty: ImportResult = {
      ok: false,
      error: message,
      source: '',
      courses: [],
      entries: [],
      items: [],
      totalWeeks: 0,
      warnings: []
    };
    return empty;
  }

  private static countTabLines(lines: string[]): number {
    let n: number = 0;
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].indexOf('\t') >= 0) {
        n++;
      }
    }
    return n;
  }

  private static hasWeekdayRow(lines: string[]): boolean {
    for (let i = 0; i < lines.length; i++) {
      if (countWeekdayTokens(lines[i]) >= 3) {
        return true;
      }
    }
    return false;
  }

  private static resolveSpec(text: string): GridSpec | undefined {
    const rows: string[][] = probeRows(text);
    const found: GridSpec | undefined = findHeader(rows);
    if (found !== undefined) {
      return found;
    }
    return fallbackSpec(rows);
  }

  private static splitBySpaces(lines: string[]): string[][] {
    const out: string[][] = [];
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i];
      if (line.trim().length === 0) {
        continue;
      }
      const cells: string[] = line.split(/\t| {2,}/);
      for (let c = 0; c < cells.length; c++) {
        cells[c] = cells[c].trim();
      }
      out.push(cells);
    }
    return out;
  }

  private static collectFromLines(lines: string[]): CollectResult {
    const pieces: TextPiece[] = [];
    let skipped: number = 0;
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.length === 0) {
        continue;
      }
      // 表头之类的行直接跳过，不计入"没认出来"
      if (countWeekdayTokens(line) >= 3) {
        continue;
      }
      const one: LineResult = pieceFromLine(line);
      if (one.piece === undefined) {
        skipped++;
        continue;
      }
      pieces.push(one.piece);
    }
    const result: CollectResult = { pieces: pieces, skipped: skipped };
    return result;
  }

  private static explainListFailure(lines: string[]): string {
    let weekdayHits: number = 0;
    let weekHits: number = 0;
    for (let i = 0; i < lines.length; i++) {
      if (countWeekdayTokens(lines[i]) > 0) {
        weekdayHits++;
      }
      if (lines[i].indexOf('周') >= 0) {
        weekHits++;
      }
    }
    if (weekdayHits === 0) {
      return '这段内容里没找到「周一」这样的星期信息。可以把教务课表页面上整张表格（含星期那一行）全选复制，'
        + '或者在 Excel 里选中区域复制后粘贴进来';
    }
    if (weekHits === 0) {
      return '找到了星期，但没找到「几周」这样的上课周次，无法判断哪些周要上课';
    }
    return '这段内容认不出课表格式。可以试试在课表页面上整张表格全选复制，或者直接在 Excel 里选中复制';
  }

  /**
   * 认不出来时，尽量说清"为什么"和"怎么办"。
   *
   * 最值得单独照顾的一种：有些教务系统的课表，复制成**纯文本**之后格子之间
   * 一个分隔符都没有，「星期」这一整列直接消失。用户盯着自己的课表左看右看，
   * 怎么也想不明白为什么认不出来 —— 必须直接告诉他这一层。
   */
  private static diagnoseFailure(text: string, fallback: string): string {
    if (TextImportService.looksLikeBlockStream(text)) {
      return '这段内容应该是课表，但复制出来的**纯文本里"星期"这一列不见了** ——'
        + '格子之间连分隔符都没有，没法判断哪门课是周几。\n'
        + '办法：回到课表页面，在表格上 Ctrl+A 全选、Ctrl+C 复制，然后点本页左下角的「粘贴」。'
        + '应用会连剪贴板里的表格结构一起读，星期就不会丢。\n'
        + '如果还是不行，可以先把表格粘进 Excel，再从 Excel 里选中复制过来。';
    }
    return fallback;
  }

  /**
   * 像不像"教务系统的课块流"：每门课三四行，其中一行同时写着周次和节次，
   *   例：`(1~3,5~12周) (第一节-第二节) 金海 12-614  赵厚宝`
   *
   * 这种形态说明格子里信息很全，唯独缺"星期" —— 而纯文本本来就给不出星期，
   * 所以在纯文本这条路里它是注定认不出来的，得换个说法告诉用户。
   */
  private static looksLikeBlockStream(text: string): boolean {
    const lines: string[] = text.split('\n');
    let hits: number = 0;
    for (let i = 0; i < lines.length; i++) {
      const s: string = lines[i].trim();
      if (s.length === 0 || s.length > 80) {
        continue;
      }
      // 一行里同时有「(...周)」和「第X节-第Y节」
      if (!/[(（][^)）]{0,24}周[)）]/.test(s)) {
        continue;
      }
      // 注意「第一节-第二节」里第一个数字后面还跟着个「节」字，不能写成 数字 紧接 连字符
      if (!/第?\s*[一二三四五六七八九十\d]{1,3}\s*[节次]?\s*[-–~至到]\s*第?\s*[一二三四五六七八九十\d]{1,3}\s*[节次]/.test(s)) {
        continue;
      }
      hits++;
      if (hits >= 3) {
        return true;
      }
    }
    return false;
  }
}

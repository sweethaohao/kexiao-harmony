import { HtmlCell } from '../model/Models';

/**
 * 课晓 · 剪贴板 HTML 风味 → 表格网格
 * ===========================================================================
 * 为什么需要它
 * ---------------------------------------------------------------------------
 * 从教务系统网页上 Ctrl+A / Ctrl+C 时，系统剪贴板里其实同时躺着两"风味"：
 *
 *   text/plain  —— 只剩换行，**格子结构全丢了**。以我校教务系统为例，
 *                  复制出来的纯文本里总共只有 21 个制表符，全部集中在表头行和
 *                  「第一节」「第三节」这类行标末尾，格子与格子之间一个都没有。
 *                  也就是说"这门课是周几"这条信息在纯文本里根本不存在。
 *
 *   text/html   —— 保留了真正的 <table>，行是节次、列是星期，一格不差。
 *
 * 所以读剪贴板时优先拿 HTML，先用本模块把它摊平成"制表符分列 + 换行分行"的
 * 纯文本，再交给 TextImportService 走同一条解析路径 —— 不用为 HTML 另写一套
 * 业务规则，也就不会出现"两套解析逻辑各说各话"。
 *
 * 几个必须处理的细节
 * ---------------------------------------------------------------------------
 * 1. **rowspan / colspan**：课表里"第一节-第二节"的课往往用 rowspan=2 占两行。
 *    不展开的话，第二行就少一格，后面所有列全体左移 —— 星期会全部错位。
 *    本模块按标准做法把网格补成矩形：被 rowspan 占住的格子填成空串占位。
 * 2. **<br> 不能直接删**：课表格子里"课程名 / 课程号 / 周次 / 教室"是 <br> 分行的，
 *    删掉就粘成一坨认不出来。必须换成 \n。
 * 3. **CF_HTML 包装**：Windows 剪贴板的 HTML 风味外面会包一层
 *    `Version:0.9 ... <!--StartFragment--> ... <!--EndFragment-->`，
 *    得先把这片段切出来。
 * 4. **实体转义**：`&nbsp;` `&amp;` 这类不解码，课程名里会出现 `&amp;`。
 *
 * 本文件是纯逻辑，不许 import 任何 @ohos.* / @kit.*，这样能在电脑上直接自测。
 * ===========================================================================
 */
export class HtmlTableService {

  /** 看起来像不像一张表格（决定要不要走 HTML 这条路） */
  static looksLikeTable(html: string): boolean {
    if (html === undefined || html === null || html.length === 0) {
      return false;
    }
    return /<t(?:able|r|d|h)[\s>/]/i.test(html);
  }

  /**
   * 摊平成"制表符分列 + 换行分行"的文本。
   * 找不到表格时返回空串 —— 由调用方决定退回纯文本解析。
   */
  static toGridText(html: string): string {
    const tables: string[][][] = HtmlTableService.parseTables(html);
    if (tables.length === 0) {
      return '';
    }
    // 取行数最多的那张表（课表页面上通常还有导航/工具栏小表）
    let best: string[][] = tables[0];
    for (const t of tables) {
      if (t.length > best.length) {
        best = t;
      }
    }
    return HtmlTableService.gridToText(best);
  }

  /** 网格 → 制表符文本 */
  static gridToText(grid: string[][]): string {
    const lines: string[] = [];
    for (const row of grid) {
      // 去掉行尾的空列，避免每行拖一串没用的制表符
      let last: number = row.length - 1;
      while (last >= 0 && row[last].trim().length === 0) {
        last--;
      }
      if (last < 0) {
        lines.push('');
        continue;
      }
      const cells: string[] = [];
      for (let i = 0; i <= last; i++) {
        cells.push(row[i]);
      }
      lines.push(cells.join('\t'));
    }
    // 去掉首尾空行
    while (lines.length > 0 && lines[0].trim().length === 0) {
      lines.shift();
    }
    while (lines.length > 0 && lines[lines.length - 1].trim().length === 0) {
      lines.pop();
    }
    return lines.join('\n');
  }

  /**
   * 解析出 HTML 里所有 <table> 的二维网格，rowspan / colspan 已展开。
   * 不做通用 HTML 解析：只认 <table> / <tr> / <td> / <th> 这四层，
   * 因为课表页面的表格结构就这么简单，多余的模糊空间只会带来误判。
   */
  static parseTables(html: string): string[][][] {
    const body: string = HtmlTableService.unwrapFragment(html);
    const out: string[][][] = [];
    const tables: string[] = HtmlTableService.extractBlocks(body, 'table');
    for (const table of tables) {
      const grid: string[][] = HtmlTableService.parseOneTable(table);
      if (grid.length > 0) {
        out.push(grid);
      }
    }
    return out;
  }

  private static parseOneTable(table: string): string[][] {
    const rows: string[] = HtmlTableService.extractBlocks(table, 'tr');
    const grid: string[][] = [];
    // prev[c] = 第 c 列还被上面几行的 rowspan 占着（占几行）
    let prev: number[] = [];

    for (const rowHtml of rows) {
      const cells: HtmlCell[] = HtmlTableService.extractCells(rowHtml);
      if (cells.length === 0 && prev.length === 0) {
        continue;
      }
      const row: string[] = [];
      // 本行新占用的列（供下一行使用）
      const next: number[] = [];
      for (let c = 0; c < prev.length; c++) {
        next[c] = prev[c] > 0 ? prev[c] - 1 : 0;
      }

      let col: number = 0;
      let ci: number = 0;
      while (ci < cells.length) {
        // 跳过被上面 rowspan 占住的列：补一个空串把列位置顶住
        while (col < prev.length && prev[col] > 0) {
          row.push('');
          col++;
        }
        const cell: HtmlCell = cells[ci];
        ci++;
        row.push(cell.text);
        for (let k = 1; k < cell.colspan; k++) {
          row.push('');
        }
        for (let k = 0; k < cell.colspan; k++) {
          const c: number = col + k;
          while (next.length <= c) {
            next.push(0);
          }
          if (cell.rowspan > 1 && cell.rowspan - 1 > next[c]) {
            next[c] = cell.rowspan - 1;
          }
        }
        col += cell.colspan;
      }
      // 行尾：把上面 rowspan 还占着的列补齐，保证列数对齐
      while (col < prev.length) {
        if (prev[col] > 0) {
          row.push('');
        }
        col++;
      }

      prev = next;
      grid.push(row);
    }
    return grid;
  }

  /** 抽出一组同名块（支持简单嵌套：不把内层同名块算作外层结束） */
  private static extractBlocks(html: string, tag: string): string[] {
    const out: string[] = [];
    const openRe: RegExp = new RegExp(`<${tag}(?:\\s[^>]*)?>`, 'gi');
    const closeRe: RegExp = new RegExp(`</${tag}\\s*>`, 'gi');
    const anyTagRe: RegExp = new RegExp(`<${tag}(?:\\s[^>]*)?>|</${tag}\\s*>`, 'gi');

    let cursor: number = 0;
    while (cursor < html.length) {
      openRe.lastIndex = cursor;
      const open: RegExpExecArray | null = openRe.exec(html);
      if (open === null) {
        break;
      }
      // 自闭合或成对结束都算
      let depth: number = 1;
      let scan: number = open.index + open[0].length;
      let end: number = html.length;
      anyTagRe.lastIndex = scan;
      let m: RegExpExecArray | null = anyTagRe.exec(html);
      while (m !== null) {
        const isClose: boolean = m[0].charAt(1) === '/';
        if (isClose) {
          depth--;
        } else {
          depth++;
        }
        if (depth === 0) {
          end = m.index + m[0].length;
          break;
        }
        scan = m.index + m[0].length;
        anyTagRe.lastIndex = scan;
        m = anyTagRe.exec(html);
      }
      out.push(html.substring(open.index, end));
      cursor = end;
    }
    return out;
  }

  /** 从 <tr> 里抽 <td>/<th> */
  private static extractCells(rowHtml: string): HtmlCell[] {
    const cells: HtmlCell[] = [];
    const re: RegExp = /<(td|th)((?:\s[^>]*)?)>([\s\S]*?)<\/\1\s*>/gi;
    let m: RegExpExecArray | null = re.exec(rowHtml);
    while (m !== null) {
      const attrs: string = m[2];
      cells.push({
        text: HtmlTableService.inlineText(m[3]),
        colspan: HtmlTableService.spanOf(attrs, 'colspan'),
        rowspan: HtmlTableService.spanOf(attrs, 'rowspan')
      });
      m = re.exec(rowHtml);
    }
    return cells;
  }

  /** 读 colspan / rowspan，兼容有没有引号、单双引号 */
  private static spanOf(attrs: string, name: string): number {
    if (attrs === undefined || attrs === null || attrs.length === 0) {
      return 1;
    }
    const re: RegExp = new RegExp(`${name}\\s*=\\s*["']?(\\d+)`, 'i');
    const m: RegExpExecArray | null = re.exec(attrs);
    if (m === null) {
      return 1;
    }
    const n: number = parseInt(m[1], 10);
    if (isNaN(n) || n < 1) {
      return 1;
    }
    // 防脏数据把网格撑爆
    return n > 32 ? 32 : n;
  }

  /** 单元格内容 → 纯文本（<br> 保留成换行） */
  private static inlineText(inner: string): string {
    let s: string = inner;
    s = s.replace(/<script[\s\S]*?<\/script\s*>/gi, '');
    s = s.replace(/<style[\s\S]*?<\/style\s*>/gi, '');
    s = s.replace(/<br\s*\/?>/gi, '\n');
    s = s.replace(/<\/?(?:p|div|li|ul|ol|h[1-6]|section|article)[^>]*>/gi, '\n');
    s = s.replace(/<[^>]*>/g, '');
    s = HtmlTableService.decodeEntities(s);
    s = s.split('\u00a0').join(' ');
    s = s.split('\u3000').join(' ');
    // 每行去首尾空白，丢掉纯空行
    const lines: string[] = s.split('\n');
    const kept: string[] = [];
    for (const line of lines) {
      const t: string = line.replace(/\s+/g, ' ').trim();
      if (t.length > 0) {
        kept.push(t);
      }
    }
    return kept.join('\n');
  }

  /** 实体转义还原 */
  static decodeEntities(text: string): string {
    let s: string = text;
    s = s.replace(/&nbsp;/gi, ' ');
    s = s.replace(/&lt;/gi, '<');
    s = s.replace(/&gt;/gi, '>');
    s = s.replace(/&quot;/gi, '"');
    s = s.replace(/&#0*39;/g, '\'');
    s = s.replace(/&#x0*27;/gi, '\'');
    // &amp; 放最后，避免 &amp;lt; 被还原成 <
    s = s.replace(/&amp;/gi, '&');
    const numeric: RegExp = /&#(x?)([0-9a-fA-F]+);/g;
    s = s.replace(numeric, (whole: string, hex: string, digits: string) => {
      const code: number = parseInt(digits, hex.length > 0 ? 16 : 10);
      if (isNaN(code) || code <= 0 || code > 0x10ffff) {
        return whole;
      }
      return String.fromCharCode(code);
    });
    return s;
  }

  /** 剥掉 CF_HTML 的包头，只留片段 */
  static unwrapFragment(html: string): string {
    if (html === undefined || html === null) {
      return '';
    }
    let s: string = `${html}`;
    const start: number = s.indexOf('<!--StartFragment-->');
    const end: number = s.lastIndexOf('<!--EndFragment-->');
    if (start >= 0 && end > start) {
      s = s.substring(start + '<!--StartFragment-->'.length, end);
    }
    // 有些平台给的是完整文档，只取 body
    const bodyOpen: RegExp = /<body(?:\s[^>]*)?>/i;
    const bodyClose: RegExp = /<\/body\s*>/i;
    const bo: RegExpExecArray | null = bodyOpen.exec(s);
    const bc: RegExpExecArray | null = bodyClose.exec(s);
    if (bo !== null && bc !== null && bc.index > bo.index) {
      s = s.substring(bo.index + bo[0].length, bc.index);
    }
    return s;
  }
}

/* ---------------------------------------------------------------------------
 * 课晓 · 教务课表诊断探针（浏览器 Console 版）
 *
 * 它解决什么问题
 *   有些教务系统禁掉了「选中复制」（Ctrl+A 选不中、右键变灰），还会拦 F12。
 *   但**开发者工具本身能用**，而且 —— 浏览器的反调试只能拦交互层，拦不住读取。
 *   这个脚本在你的浏览器里跑，读的是「你已经登录、已经有权限看到」的那一页，
 *   不登录、不填密码、不联网上传。
 *
 * 怎么用
 *   1. 打开教务系统的课表页面，让整张课表显示出来
 *   2. 开发者工具（F12 / Ctrl+Shift+I / 菜单→更多工具→开发者工具）
 *      若页面被 debugger 卡住：Sources 面板 → 点一下「停用断点」(Ctrl+F8)，立刻恢复
 *   3. 切到 Console 面板，把本文件**全部内容**粘进去，回车
 *   4. 会下载一个 kexiao-export.txt，把它放进  G:\project\myP\data\
 *
 * 它做了什么（三件事，按价值排序）
 *   A. 列出页面已经请求过的所有 AJAX 接口（从 performance 记录里读，不重新发请求）
 *      —— 如果课表是接口返回的 JSON，这是最有价值的一条线索
 *   B. 对「明显是只读取课表」的接口**只读回读一次**，把响应内容一起打包
 *      —— 写操作的接口一律跳过（黑名单见 MUTATING），绝不会触发选课/退课
 *   C. 扫描页面里所有 <table>，按 rowspan/colspan 展开成网格；
 *      页面不是 table 布局时，退化为「找文字里含星期几的最大容器」并保留其 HTML
 *   最后把 A/B/C 的结果 + 完整页面快照打包成一个 txt 下载
 *
 * 隐私
 *   全程在本机浏览器完成，不联网、不上传。文件里含你的真实课表和学号，
 *   只发给课晓的开发者用于写解析规则，别提交到任何公开仓库。
 * ------------------------------------------------------------------------- */
(async () => {
  'use strict';

  const log = (...a) => console.log('%c[课晓]', 'color:#2f7cf6;font-weight:700', ...a);
  const warn = (...a) => console.warn('%c[课晓]', 'color:#e8a33d;font-weight:700', ...a);

  /** 只读接口白名单：命中才允许回读 */
  const READABLE = /(schedule|timetable|kebiao|curriculum|lesson|coursetable|course|week|plan|task|query|list|get|search|info|home|index)/i;
  /** 写操作黑名单：命中一律不回读（保命用，宁漏勿误） */
  const MUTATING = /(select|choose|submit|save|delete|remove|update|edit|insert|add|apply|confirm|cancel|drop|enroll|withdraw|volunteer|operate|oper\b|batch|import|upload|reset|clear|pay|sign|order)/i;

  const clean = (s) => String(s == null ? '' : s)
    .replace(/\r\n?/g, '\n')
    .replace(/[\u00a0\u3000]/g, ' ')
    .split('\n')
    .map((x) => x.replace(/[ \t]+/g, ' ').trim())
    .filter((x) => x.length > 0)
    .join('\n');

  /** table → 二维数组。合并单元格只在左上角留内容，其余留空（保留跨行位置） */
  const expand = (table) => {
    const grid = [];
    Array.from(table.rows).forEach((tr, r) => {
      grid[r] = grid[r] || [];
      let c = 0;
      Array.from(tr.cells).forEach((td) => {
        while (grid[r][c] !== undefined) c++;
        const text = clean(td.innerText || td.textContent);
        const rs = td.rowSpan || 1;
        const cs = td.colSpan || 1;
        for (let i = 0; i < rs; i++) {
          for (let j = 0; j < cs; j++) {
            if (!grid[r + i]) grid[r + i] = [];
            grid[r + i][c + j] = (i === 0 && j === 0) ? text : '';
          }
        }
        c += cs;
      });
    });
    return grid;
  };

  const DAY_RE = /(星期|周)[一二三四五六日天]/g;
  const WEEK_RE = /\d+\s*[-~–—至到]\s*\d+\s*周|\d+\s*周/g;
  const SLOT_RE = /第\s*[一二三四五六七八九十\d]{1,3}\s*[节次]/g;
  const count = (s, re) => (s.match(re) || []).length;

  // ---- A. 页面已发过的 AJAX 接口 ----------------------------------------
  let xhrCalls = [];
  try {
    const seen = new Set();
    xhrCalls = performance.getEntriesByType('resource')
      .filter((e) => e.initiatorType === 'xmlhttprequest' || e.initiatorType === 'fetch')
      .map((e) => ({ url: e.name, bytes: e.transferSize || 0 }))
      .filter((e) => {
        const key = e.url.split('?')[0] + '|' + (e.url.split('?')[1] || '').length;
        if (seen.has(key)) return false;
        seen.add(key);
        return true;
      });
  } catch (e) {
    warn('读 performance 记录失败：' + e.message);
  }

  console.log('%c——— 课晓诊断探针 ———', 'font-size:14px;font-weight:700');
  log('地址：' + location.host + location.pathname);
  log('标题：' + document.title);
  log('页面已发生 ' + xhrCalls.length + ' 个 AJAX 请求（去重后）：');
  xhrCalls.slice(0, 40).forEach((e, i) => {
    const path = e.url.replace(location.origin, '');
    log('  ' + String(i + 1).padStart(2) + '. ' + path.slice(0, 150));
  });

  // ---- B. 只读接口回读一次（写操作一律跳过） ------------------------------
  const fetched = [];
  const targets = xhrCalls.filter((e) => {
    let u;
    try { u = new URL(e.url); } catch (err) { return false; }
    if (u.origin !== location.origin) return false;
    if (MUTATING.test(u.pathname + u.search)) return false;
    return READABLE.test(u.pathname);
  });

  log('其中 ' + targets.length + ' 个看起来是「只读」接口，尝试回读内容（写操作已全部排除）：');
  for (const t of targets.slice(0, 12)) {
    let body = '';
    let status = 0;
    let note = '';
    try {
      const r = await fetch(t.url, { method: 'GET', credentials: 'include' });
      status = r.status;
      const txt = await r.text();
      body = txt.length > 300000 ? txt.slice(0, 300000) + '\n/* ...已截断... */' : txt;
      const isTimetable = /星期一|星期二|课程名称|节次|课表|weekdays?|schedule/i.test(txt);
      note = isTimetable ? '★ 内容像课表' : (txt.trim().startsWith('{') || txt.trim().startsWith('[') ? 'JSON' : '其他');
      log('  ' + (isTimetable ? '★ ' : '  ') + status + ' ' + note + '  ' + t.url.replace(location.origin, '').slice(0, 120));
    } catch (err) {
      note = '回读失败: ' + err.message;
      log('  x ' + t.url.replace(location.origin, '').slice(0, 120) + '  ' + note);
    }
    fetched.push({ url: t.url, status, note, body });
  }

  // ---- C. DOM 侧：表格扫描 + 非表格兜底 ---------------------------------
  const docs = [{ doc: document, label: 'top' }];
  Array.from(document.querySelectorAll('iframe')).forEach((f, i) => {
    try {
      if (f.contentDocument && f.contentDocument.body) {
        docs.push({ doc: f.contentDocument, label: 'iframe#' + i });
        log('发现同源 iframe#' + i + '，一并扫描');
      }
    } catch (e) {
      warn('iframe#' + i + ' 跨域读不到，跳过（若课表在这个 iframe 里，请在 Console 左上角把执行上下文切到它）');
    }
  });

  const tables = [];
  docs.forEach(({ doc, label }) => {
    Array.from(doc.querySelectorAll('table')).forEach((t, ti) => {
      const g = expand(t);
      const flat = g.map((r) => r.join('\n')).join('\n');
      const days = count(flat, DAY_RE);
      const weeks = count(flat, WEEK_RE);
      const slots = count(flat, SLOT_RE);
      const cols = g.reduce((m, r) => Math.max(m, r.length), 0);
      tables.push({
        label, ti, el: t, g, days, weeks, slots, rows: g.length, cols,
        score: days * 10 + slots * 3 + weeks * 2 + Math.min(cols, 10)
      });
    });
  });
  tables.sort((a, b) => b.score - a.score);
  log('DOM 里共 ' + tables.length + ' 张 <table>，按「像课表的程度」排序：');
  tables.slice(0, 8).forEach((t, i) => {
    log('  #' + (i + 1) + '  ' + t.rows + '行 × ' + t.cols + '列 ｜ 星期' + t.days
      + '处 节次' + t.slots + '处 周次' + t.weeks + '处 ｜ ' + t.label);
  });

  // 非 table 布局的兜底：找文字里含「星期一」的元素里最小的那个
  let gridHostHtml = '';
  let gridHostDesc = '（未找到）';
  if (tables.length === 0) {
    const all = Array.from(document.querySelectorAll('div,section,main,ul,ol,dl'));
    const cands = all
      .filter((el) => /星期[一二三四五六日天]/.test(el.innerText || ''))
      .sort((a, b) => (a.innerText || '').length - (b.innerText || '').length);
    const host = cands[0];
    if (host) {
      gridHostDesc = host.tagName + '.' + (host.className || '(无class)');
      gridHostHtml = host.outerHTML.slice(0, 400000);
      log('没找到 <table>，但找到了含星期的容器：' + gridHostDesc + '（已保留其 HTML）');
    } else {
      warn('既没有 <table>，也没有含「星期」的元素 —— 课表可能是 canvas 画的或还在 iframe 里');
    }
  }

  // ---- D. 打包下载 -------------------------------------------------------
  const buf = [];
  buf.push('=== 课晓诊断 · 概览 ===');
  buf.push('时间: ' + new Date().toISOString());
  buf.push('地址: ' + location.href);
  buf.push('标题: ' + document.title);
  buf.push('UA: ' + navigator.userAgent);
  buf.push('表格数: ' + tables.length + ' ｜ AJAX数: ' + xhrCalls.length + ' ｜ 回读数: ' + fetched.length);
  buf.push('');
  buf.push('=== AJAX 接口清单（页面实际请求过的） ===');
  xhrCalls.forEach((e, i) => buf.push(String(i + 1).padStart(3) + '. ' + e.url));
  buf.push('');
  buf.push('=== 页面尾部文字（常能看出教务厂商） ===');
  buf.push(clean((document.body && document.body.innerText || '').slice(-800)));
  buf.push('');

  if (tables.length > 0) {
    tables.slice(0, 2).forEach((t, i) => {
      buf.push('=== 网格 #' + (i + 1) + '（' + t.rows + '行 x ' + t.cols + '列，制表符分列，格内换行已换成 ¶）===');
      // 必须按下标逐个取：行数组可能是稀疏的，直接 map 会跳过空洞、把列错位
      for (let ri = 0; ri < t.g.length; ri++) {
        const row = t.g[ri] || [];
        const out = [];
        for (let ci = 0; ci < t.cols; ci++) {
          out.push(String(row[ci] == null ? '' : row[ci]).replace(/\n/g, '¶'));
        }
        buf.push(out.join('\t'));
      }
      buf.push('');
    });
    buf.push('=== 最能当课表用的那张表的 outerHTML ===');
    buf.push(tables[0].el.outerHTML.slice(0, 400000));
    buf.push('');
  } else {
    buf.push('=== 非表格布局：含「星期」的容器 ' + gridHostDesc + ' 的 HTML ===');
    buf.push(gridHostHtml);
    buf.push('');
  }

  fetched.forEach((f, i) => {
    buf.push('=== 接口回读 #' + (i + 1) + '  status=' + f.status + '  ' + f.note + ' ===');
    buf.push('URL: ' + f.url);
    buf.push(f.body);
    buf.push('');
  });

  buf.push('=== 页面快照 HTML（已截断至 1.2MB） ===');
  buf.push(document.documentElement.outerHTML.slice(0, 1200000));

  const text = buf.join('\n');
  const blob = new Blob([text], { type: 'text/plain;charset=utf-8' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'kexiao-export.txt';
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 10000);

  log('%c已下载 kexiao-export.txt（' + (text.length / 1024).toFixed(1) + ' KB）', 'color:#22a06b;font-weight:700');
  log('把它放到 G:\\project\\myP\\data\\ 下即可。');
})();

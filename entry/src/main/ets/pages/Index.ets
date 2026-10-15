/**
 * 课晓 · 主页面
 * ---------------------------------------------------------------------------
 * 两种形态（需求里的关键点）：
 *  ① 配置态 —— 左侧可折叠侧栏 + 完整周视图，用来看/改整个学期的课表；
 *  ② 日常态 —— 「今明日程」时间线：只显示今天的课；今天的课全上完了就显示后面的课。
 *     这个形态将来会演变成 2in1 上的小窗口 / 桌面卡片。
 *
 * 侧栏可折叠，折叠后只留图标，交互参照 PC 端聊天软件。
 * ---------------------------------------------------------------------------
 */

import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { pasteboard, zlib } from '@kit.BasicServicesKit';
import { picker, fileIo } from '@kit.CoreFileKit';
import {
  DailyBrief, DayCell, DayCourse, ImportResult, PeriodConfig, PeriodKey,
  ScheduleItem, Semester, SlotTime, WeekdayNum, WeekView, WeekViewDay, WEEKDAY_SHORT
} from '../model/Models';
import {
  createTimeTable, createDefaultTimeTable, DEFAULT_PERIOD_CONFIGS, DEFAULT_SEMESTER_START
} from '../model/Defaults';
import { DateUtil } from '../common/DateUtil';
import { SlotTimeTable } from '../common/SlotTimeTable';
import { ScheduleService } from '../service/ScheduleService';
import { ImportService } from '../service/ImportService';
import { TextImportService } from '../service/TextImportService';
import { XlsxService, XlsxClassInfo, XlsxSheetTarget } from '../service/XlsxService';
import { ScheduleEditor, ManualCourseForm } from '../service/ScheduleEditor';
import { ScheduleRepository, ScheduleSnapshot } from '../database/ScheduleRepository';
import { SettingsStore } from '../database/SettingsStore';

const DOMAIN: number = 0x0000;
const TAG: string = 'kexiao';

// ---------------------------------------------------------------------------
// 视觉常量（浅色主题）
// ---------------------------------------------------------------------------
const C_BG: string = '#F5F6F8';
const C_SURFACE: string = '#FFFFFF';
const C_SIDEBAR: string = '#FAFAFB';
const C_BORDER: string = '#E8EAED';
const C_TEXT: string = '#1F2328';
const C_TEXT_SUB: string = '#5C6470';
const C_TEXT_WEAK: string = '#9AA1A9';
const C_PRIMARY: string = '#3E6BE8';
const C_PRIMARY_SOFT: string = '#EBF0FE';
const C_TODAY_BG: string = '#F3F7FF';
const C_WARN_BG: string = '#FFF8EC';
const C_WARN_TEXT: string = '#9A6212';

/** 单个节次格的高度（vp） */
const SLOT_H: number = 62;
/** 星期表头高度（vp） */
const HEADER_H: number = 52;
/** 选班级的列表一次最多渲染多少条（全校能有几百个班，全渲染太慢） */
const CLASS_LIST_LIMIT: number = 80;

/** 侧栏导航项 */
interface NavItem {
  glyph: string;
  label: string;
}

/**
 * 侧栏导航下标。顺序即侧栏顺序。
 *
 * 「今明日程」排第一，因为打开应用时最想知道的通常是
 * "我接下来要上什么课"，而不是整张课表长什么样；
 * 整周视图是"配置/查阅"时才需要的东西，放第二位。
 */
const NAV_BRIEF: number = 0;
const NAV_WEEK: number = 1;
const NAV_IMPORT: number = 2;
const NAV_SETTINGS: number = 3;

const NAV_ITEMS: NavItem[] = [
  { glyph: '今', label: '今明日程' },
  { glyph: '周', label: '本周课表' },
  { glyph: '导', label: '导入课表' },
  { glyph: '设', label: '作息设置' }
];

/** 星期序号 1~7，给手动添加表单里的选择器用 */
const WEEKDAY_NUMS: number[] = [1, 2, 3, 4, 5, 6, 7];

/** 手动添加时常用的周次写法，点一下就填进去 */
const WEEK_PRESETS: string[] = ['1-16周', '1-8周', '9-16周', '单周', '双周'];

@Entry
@Component
struct Index {
  // ---- 数据 ----
  @State items: ScheduleItem[] = [];
  @State weekView: WeekView = { week: 1, title: '第 1 周', rangeLabel: '', days: [], courseCount: 0 };
  @State brief: DailyBrief = {
    mode: 'empty', title: '暂无日程', date: new Date(), weekday: 1,
    courses: [], allPassed: false, currentEntryId: 0, nextEntryId: 0, hint: ''
  };
  @State slotList: SlotTime[] = [];

  // ---- 界面状态 ----
  /** 默认落在「今明日程」：打开应用第一眼看到的是接下来要上的课 */
  @State navIndex: number = NAV_BRIEF;
  @State collapsed: boolean = false;
  @State week: number = 1;

  // ---- 启动状态 ----
  /** 本地数据是否已经读出来。读完之前显示"正在读取"，避免先闪一下空态 */
  @State dataReady: boolean = false;
  /** 开库或读数据失败的原因，空串表示没出错 */
  @State bootError: string = '';
  /** 是否正在写库（防止重复点击同一个按钮） */
  @State busy: boolean = false;

  // ---- 学期配置（起始日可改并落库；总周数由导入数据推断） ----
  @State semesterStart: string = DEFAULT_SEMESTER_START;
  @State totalWeeks: number = 16;

  // ---- 导入反馈 ----
  @State importSource: string = '';
  @State importSummary: string = '';
  @State importWarnings: string[] = [];
  @State statusText: string = '';

  // ---- 粘贴导入 ----
  /** 粘贴框里的内容 */
  @State pasteText: string = '';
  /**
   * 剪贴板的 HTML 风味（网页复制时才有）。带真正的表格结构，解析时优先用它 ——
   * 因为这类教务系统复制出来的纯文本里"星期"这一列是丢的（格间连制表符都没有）。
   * 不做成 @State：它不参与渲染，没必要触发重建。
   */
  private pasteHtml: string = '';
  /** pasteHtml 对应的是哪一份纯文本 —— 用户一旦改动内容就作废，免得用错数据 */
  private pasteHtmlFor: string = '';
  /** 是否处于"解析完、还没确认"的预览态。预览时整页换成校对界面 */
  @State previewActive: boolean = false;
  /** 待导入的课表（预览里可以逐条删） */
  @State previewItems: ScheduleItem[] = [];
  /** 解析出来的总周数 */
  @State previewWeeks: number = 0;
  /** 解析失败的原因 */
  @State previewError: string = '';
  /** 解析过程中的提示（哪条没认出来、哪些周次是替用户猜的） */
  @State previewWarnings: string[] = [];
  /** 这批准导入数据的来源描述 */
  @State previewSource: string = '';

  // ---- 手动添加表单 ----
  @State showManualForm: boolean = false;
  @State formName: string = '';
  @State formTeacher: string = '';
  @State formRoom: string = '';
  @State formWeekday: number = 1;
  @State formStartSlot: number = 1;
  @State formEndSlot: number = 2;
  @State formWeeks: string = '1-16周';
  @State formError: string = '';

  // ---- Excel（教务处公开课表）导入 ----
  /** 是否处于"选班级"这一步。教务处的课表文件里装着全校所有班，得先认领自己的 */
  @State classPickerActive: boolean = false;
  /** 从 Excel 里扫出来的班级候选 */
  @State classCandidates: XlsxClassInfo[] = [];
  /** 筛选班级用的关键词 */
  @State classQuery: string = '';
  /** 这份 Excel 的文件名，用来标注数据来源 */
  @State classSource: string = '';
  /** 解压出来的工作目录（里面的 XML 选完班还要再读一次） */
  private xlsxDir: string = '';
  /** 共享字符串表 */
  private xlsxShared: string[] = [];
  /** sheet 名 → xml 路径 */
  private xlsxTargets: XlsxSheetTarget[] = [];

  /** 当前生效的作息参数：启动时从首选项读出，默认值来自 model/Defaults.ets */
  private periodConfigs: PeriodConfig[] = DEFAULT_PERIOD_CONFIGS;
  private timeTable: SlotTimeTable = createDefaultTimeTable();
  private service: ScheduleService = new ScheduleService(createDefaultTimeTable());
  /** 存储仓库。boot() 打开成功后赋值；没就绪时一切写操作都会被拒绝 */
  private repo: ScheduleRepository | undefined = undefined;

  aboutToAppear(): void {
    // 先用默认作息把节次表准备好，避免首帧渲染拿到空表；
    // 真正的作息参数稍后在 boot() 里从首选项读出来并替换。
    this.slotList = this.timeTable.all();
    this.boot();
  }

  // =========================================================================
  // 启动
  // =========================================================================

  /**
   * 启动流程（异步）。
   *
   * 上一版的课表只活在内存里，关掉应用就没了，用户每次打开都得重新导入。
   * 这里补上的就是"启动即读库"这一步：
   *   ① 打开首选项，取出作息参数（从没存过就把默认值写进去）；
   *   ② 打开数据库，一次读齐整份课表快照；
   *   ③ 有数据就直接显示日程；没数据就保持空态，由用户点
   *      「载入示例课表」或去「导入课表」决定 ——
   *      "第一次打开是空态"这个行为必须保住。
   *
   * 整个过程是异步的，所以界面在这期间显示"正在读取"，
   * 而不是先闪一下空态、再突然蹦出课表。
   */
  private async boot(): Promise<void> {
    try {
      const ctx: common.Context = this.getUIContext().getHostContext() as common.Context;

      // ---- ① 作息参数 ----
      SettingsStore.open(ctx);
      let configs: PeriodConfig[] = SettingsStore.loadPeriodConfigs();
      if (configs.length === 0) {
        configs = DEFAULT_PERIOD_CONFIGS;
        // 顺手把默认值落一份，之后用户在设置页改的就是这一份
        SettingsStore.savePeriodConfigs(configs);
      }
      this.applyTimeTable(configs);
      this.collapsed = SettingsStore.loadCollapsed();

      // ---- ② 课表数据 ----
      const repo: ScheduleRepository = await ScheduleRepository.open(ctx);
      this.repo = repo;
      const snapshot: ScheduleSnapshot = await repo.loadSnapshot();

      // ---- ③ 灌进界面 ----
      if (snapshot.items.length > 0) {
        this.applySnapshot(snapshot);
      }
    } catch (err) {
      this.bootError = `${JSON.stringify(err)}`;
      hilog.error(DOMAIN, TAG, 'boot failed: %{public}s', JSON.stringify(err));
    }
    this.dataReady = true;
  }

  /** 用一组作息参数重建节次表与课表服务 */
  private applyTimeTable(configs: PeriodConfig[]): void {
    this.periodConfigs = configs;
    this.timeTable = createTimeTable(configs);
    this.service = new ScheduleService(this.timeTable);
    this.slotList = this.timeTable.all();
  }

  /** 把库里读出来的快照灌进界面状态 */
  private applySnapshot(snapshot: ScheduleSnapshot): void {
    this.items = snapshot.items;
    if (snapshot.semester !== undefined) {
      this.semesterStart = snapshot.semester.startDate;
      this.totalWeeks = snapshot.semester.totalWeeks > 0 ? snapshot.semester.totalWeeks : 16;
    }
    if (snapshot.meta !== undefined) {
      this.importSource = snapshot.meta.source;
      this.importSummary = `${snapshot.meta.itemCount} 条排课 · `
        + `${snapshot.meta.courseCount} 门课程 · 导入于 ${snapshot.meta.importedAt}`;
    }
    // 定位到"当前周"
    const current: number = ScheduleService.weekOfDate(this.currentSemester(), new Date());
    this.week = Math.min(Math.max(current, 1), this.totalWeeks);
    this.refreshAll();
  }

  // =========================================================================
  // 业务动作
  // =========================================================================

  /**
   * 读取随应用打包的「示例课表」，并**存进本地数据库**。
   * 数据在 resources/rawfile/sample-schedule.json，是**虚构数据**，
   * 只为了让用户在还没导入自己课表时也能看到界面长什么样。
   * ⚠️ 这个文件绝不能放任何真实课表 —— 它会随安装包发给所有用户。
   */
  private async loadSampleSchedule(): Promise<void> {
    try {
      // 通过 UIContext 拿宿主 Context（API 18 之后 getContext 已废弃，用这个写法）
      const ctx: common.Context = this.getUIContext().getHostContext() as common.Context;
      const bytes: Uint8Array = ctx.resourceManager.getRawFileContentSync('sample-schedule.json');
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      const text: string = decoder.decodeToString(bytes).replace(/^\uFEFF/, '');

      const result: ImportResult = ImportService.parse(text);
      if (!result.ok) {
        this.statusText = `读取示例课表失败：${result.error}`;
        return;
      }
      await this.persistImport(result, '示例课表');
    } catch (err) {
      this.statusText = `读取示例课表失败：${JSON.stringify(err)}`;
      hilog.error(DOMAIN, TAG, 'load sample failed: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 把一次导入结果写进本地数据库，然后**重新从库里读一遍**再刷新界面。
   *
   * 为什么写完还要再读一次？
   *   页面上显示的必须就是"库里真实存着的东西"。如果直接拿解析结果渲染，
   *   一旦"写进去的"和"读出来的"有细微差异（字段回落、排序不同），
   *   用户重启应用后就会看到前后不一致，而这类问题极难排查。
   *   多读一次只要几毫秒，换来的是界面与数据库永远一致。
   */
  private async persistImport(result: ImportResult, label: string): Promise<void> {
    const repo: ScheduleRepository | undefined = this.repo;
    if (repo === undefined) {
      this.statusText = '本地数据库还没准备好，请稍后再试';
      return;
    }
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const semester: Semester = await repo.saveImport(result, new Date());
      const snapshot: ScheduleSnapshot = await repo.loadSnapshot();
      this.importWarnings = result.warnings;
      this.applySnapshot(snapshot);
      this.statusText = `已保存${label}：${snapshot.items.length} 条排课。`
        + `学期起始日暂按「导入当周 = 第 1 周」记为 ${semester.startDate}，`
        + '如与实际不符，请到「作息设置」里改一下';
    } catch (err) {
      this.statusText = `保存失败：${JSON.stringify(err)}`;
      hilog.error(DOMAIN, TAG, 'persist failed: %{public}s', JSON.stringify(err));
    }
    this.busy = false;
  }

  /** 清空本地课表数据（先弹二次确认） */
  private confirmClear(): void {
    this.getUIContext().showAlertDialog({
      title: '清空课表数据',
      message: '将删除本机保存的全部课程与排课，无法恢复。确定继续吗？',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: '#D4456B',
        action: () => {
          this.doClear();
        }
      }
    });
  }

  private async doClear(): Promise<void> {
    const repo: ScheduleRepository | undefined = this.repo;
    if (repo === undefined) {
      this.items = [];
      this.refreshAll();
      return;
    }
    try {
      await repo.clearAll();
      this.items = [];
      this.importSource = '';
      this.importSummary = '';
      this.importWarnings = [];
      this.statusText = '已清空本地课表数据';
      this.refreshAll();
    } catch (err) {
      this.statusText = `清空失败：${JSON.stringify(err)}`;
    }
  }

  // =========================================================================
  // 导入课表（粘贴解析 → 预览校对 → 落库）
  // =========================================================================

  /**
   * 解析粘贴框里的内容。
   *
   * 这里刻意"不"直接落库，而是先进预览态 —— 自动解析一定有认错的地方
   * （教务系统的排版千奇百怪），让用户先看一眼、删掉不对的，再确认，
   * 比导完再回去翻要好得多。市面上做得好的课表 App 都是这个流程。
   */
  private doParsePaste(): void {
    const text: string = this.pasteText;
    if (text.replace(/\s/g, '').length === 0) {
      this.statusText = '粘贴框是空的，先把课表复制进去';
      return;
    }
    // 顺手识别一下课晓自己的 JSON 格式（用户可能粘贴的是备份内容）
    const trimmed: string = text.replace(/^\uFEFF/, '').replace(/^\s+/, '');
    const isJson: boolean = trimmed.charAt(0) === '{';
    // 两份风味一起交下去：有 HTML 就走表格结构，没有就退回纯文本
    const result: ImportResult = isJson
      ? ImportService.parse(text)
      : TextImportService.parseFromClipboard(text, this.pasteHtml, '粘贴导入');
    this.applyPreviewResult(result, isJson ? '课晓格式文件' : '粘贴导入');
  }

  /**
   * 从系统剪贴板取文本填进粘贴框。
   *
   * ⚠️ 这里必须由 PasteButton（安全组件）触发，不能用普通按钮调。
   * 从 API 12 起读取剪贴板需要 `ohos.permission.READ_PASTEBOARD`，而它是
   * **system_basic 级别的受限权限** —— 普通应用光在 module.json5 里声明没用，
   * 得走 ACL 并配合应用市场签发的发布证书才可能拿到。
   *
   * 官方的正解是 PasteButton：点它一次，系统会临时授权读取当前剪贴板内容，
   * 不需要申请任何权限。授权只在那一下有效，所以读完立刻把文本接住。
   */
  private readClipboard(): void {
    try {
      const board: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      const data: pasteboard.PasteData = board.getDataSync();
      const types: string[] = data.getMimeTypes();

      // 网页上复制过来的表格，剪贴板里通常同时躺着两"风味"：
      //   text/plain —— 只剩换行，格子结构全丢了（星期那一列根本看不出来）
      //   text/html  —— 保留了真正的 <table>，行=节次、列=星期，一点不含糊
      // 所以优先拿 HTML，拿不到再退回纯文本。
      let html: string = '';
      if (types.indexOf(pasteboard.MIMETYPE_TEXT_HTML) >= 0) {
        try {
          html = data.getPrimaryHtml();
        } catch (inner) {
          html = '';
        }
      }
      if (html === undefined || html === null) {
        html = '';
      }

      let text: string = '';
      try {
        text = data.getPrimaryText();
      } catch (inner) {
        text = '';
      }
      if (text === undefined || text === null) {
        text = '';
      }

      hilog.debug(DOMAIN, TAG, 'clipboard flavor: types=%{public}s html=%{public}d plain=%{public}d',
        types.join('|'), html.length, text.length);

      if (text.length === 0 && html.length === 0) {
        this.statusText = '剪贴板里没有文字内容，先把课表复制一下';
        return;
      }

      this.pasteHtml = html;
      this.pasteHtmlFor = text;
      this.pasteText = text;
      const lines: string[] = text.split(/\r?\n/);
      const shape: string = html.length > 0 ? '带表格结构' : '纯文本';
      this.statusText = `已读入 ${text.length} 个字符、${lines.length} 行（${shape}），点「解析」看看认出来多少`;
    } catch (err) {
      this.statusText = '没读到剪贴板内容，可以在下面的框里直接 Ctrl+V 粘贴';
      hilog.error(DOMAIN, TAG, 'clipboard failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 选一个文件导入（.json 走课晓格式，.txt/.csv 走文本解析，.xlsx 走教务处课表） */
  private async pickFile(): Promise<void> {
    try {
      const ctx: common.Context = this.getUIContext().getHostContext() as common.Context;
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.json', '.txt', '.csv', '.xlsx'];
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
      const uris: string[] = await documentPicker.select(options);
      if (uris === undefined || uris === null || uris.length === 0) {
        return;
      }
      const uri: string = uris[0];
      const name: string = uri.substring(uri.lastIndexOf('/') + 1);
      const lower: string = uri.toLowerCase();
      if (lower.endsWith('.xlsx')) {
        await this.importXlsx(uri, name);
        return;
      }
      if (lower.endsWith('.xls')) {
        this.statusText = '不支持老式的 .xls，请在 Excel / WPS 里「另存为 .xlsx」后再导入';
        return;
      }
      const text: string = this.readTextFile(uri);
      const trimmed: string = text.replace(/^\uFEFF/, '').replace(/^\s+/, '');
      const isJson: boolean = trimmed.charAt(0) === '{';
      const result: ImportResult = isJson
        ? ImportService.parse(text)
        : TextImportService.parse(text, name);
      this.applyPreviewResult(result, name);
    } catch (err) {
      this.statusText = `选择文件失败：${JSON.stringify(err)}`;
      hilog.error(DOMAIN, TAG, 'pick file failed: %{public}s', JSON.stringify(err));
    }
  }

  // -------------------------------------------------------------------------
  // Excel（教务处「各校区课表」）导入
  // -------------------------------------------------------------------------

  /**
   * 教务处官网常公开挂一份「各校区课表 .xlsx」，里面按学院分 sheet、按小班分块，
   * 装着全校所有班的完整课表。这条路不需要登录、不需要复制，也不受课表页面上
   * 「禁选中 / 反调试」那套机制的影响 —— 所以教室里封得最狠的学校，它反而走得通。
   *
   * 处理顺序：拆包 → 扫出所有班级 → 让用户认领自己的班 → 解析那一个块。
   */
  private async importXlsx(uri: string, name: string): Promise<void> {
    this.busy = true;
    this.statusText = '正在读这个 Excel…';
    const ctx: common.Context = this.getUIContext().getHostContext() as common.Context;
    const zipPath: string = `${ctx.filesDir}/kexiao-import.zip`;
    const outDir: string = `${ctx.filesDir}/kexiao-xlsx`;
    try {
      // .xlsx 本身就是个 zip。先搬进沙箱，因为解压接口只认沙箱路径、且要求 .zip 后缀
      this.copyIntoBox(uri, zipPath);
      if (fileIo.accessSync(outDir)) {
        fileIo.rmdirSync(outDir);
      }
      fileIo.mkdirSync(outDir);
      await zlib.decompressFile(zipPath, outDir);

      // 共享字符串表（所有文字都存那儿）
      const sharedPath: string = `${outDir}/xl/sharedStrings.xml`;
      const shared: string[] = fileIo.accessSync(sharedPath)
        ? XlsxService.parseSharedStrings(this.readTextFile(sharedPath)) : [];

      const targets: XlsxSheetTarget[] = XlsxService.sheetTargets(
        this.readTextFile(`${outDir}/xl/workbook.xml`),
        this.readTextFile(`${outDir}/xl/_rels/workbook.xml.rels`));
      if (targets.length === 0) {
        this.statusText = '这个 Excel 里没读到工作表，确认一下是不是教务处下载的原文件';
        return;
      }

      // 逐个 sheet 找班级。一次只让一个 sheet 的 XML 进内存（全校课表能有 4 MB 以上）
      const found: XlsxClassInfo[] = [];
      for (let i = 0; i < targets.length; i++) {
        const sheetPath: string = `${outDir}/${targets[i].path}`;
        if (!fileIo.accessSync(sheetPath)) {
          continue;
        }
        const classes: XlsxClassInfo[] = XlsxService.classesInSheet(
          targets[i].name, this.readTextFile(sheetPath), shared);
        for (let k = 0; k < classes.length; k++) {
          found.push(classes[k]);
        }
      }
      if (found.length === 0) {
        this.statusText = '这个表格里没有找到带课表的班级，确认一下是不是教务处的「各校区课表」文件';
        return;
      }

      this.xlsxDir = outDir;
      this.xlsxShared = shared;
      this.xlsxTargets = targets;
      this.classSource = name;
      this.classCandidates = found;
      this.classQuery = '';
      this.classPickerActive = true;
      this.statusText = '';
    } catch (err) {
      this.statusText = `这个 Excel 读不出来：${JSON.stringify(err)}`;
      hilog.error(DOMAIN, TAG, 'xlsx import failed: %{public}s', JSON.stringify(err));
    } finally {
      this.busy = false;
    }
  }

  /** 用户认领了自己的班 → 解析那个块 → 进预览 */
  private chooseClass(info: XlsxClassInfo): void {
    try {
      const path: string = this.sheetPathOf(info.sheetName);
      if (path.length === 0) {
        this.statusText = '没找到这个班所在的工作表，重新导入一次试试';
        return;
      }
      const result: ImportResult = XlsxService.parseClass(
        this.readTextFile(`${this.xlsxDir}/${path}`), this.xlsxShared, info, this.classSource);
      this.classPickerActive = false;
      this.applyPreviewResult(result, this.classSource);
      if (result.ok) {
        this.statusText = '';
      }
    } catch (err) {
      this.statusText = `解析失败：${JSON.stringify(err)}`;
      hilog.error(DOMAIN, TAG, 'xlsx parse failed: %{public}s', JSON.stringify(err));
    }
  }

  private sheetPathOf(sheetName: string): string {
    for (let i = 0; i < this.xlsxTargets.length; i++) {
      if (this.xlsxTargets[i].name === sheetName) {
        return this.xlsxTargets[i].path;
      }
    }
    return '';
  }

  /** 按关键词筛班级候选 */
  private filteredClasses(): XlsxClassInfo[] {
    const q: string = this.classQuery.trim();
    const out: XlsxClassInfo[] = [];
    for (let i = 0; i < this.classCandidates.length; i++) {
      const c: XlsxClassInfo = this.classCandidates[i];
      if (q.length === 0
        || c.major.indexOf(q) >= 0
        || c.code.indexOf(q) >= 0
        || c.college.indexOf(q) >= 0
        || c.advisor.indexOf(q) >= 0) {
        out.push(c);
        if (out.length >= CLASS_LIST_LIMIT) {
          break;
        }
      }
    }
    return out;
  }

  private classTitle(info: XlsxClassInfo): string {
    if (info.major.length > 0) {
      return `${info.college} · ${info.major} · ${info.grade}`;
    }
    return `${info.sheetName} · ${info.code}`;
  }

  private classSubtitle(info: XlsxClassInfo): string {
    const bits: string[] = [info.code];
    if (info.advisor.length > 0) {
      bits.push(`辅导员 ${info.advisor}`);
    }
    if (info.people.length > 0) {
      bits.push(`${info.people} 人`);
    }
    if (info.campus.length > 0) {
      bits.push(`${info.campus}校区`);
    }
    return bits.join(' · ');
  }

  /** 把一个外部 uri 的文件整个复制到应用沙箱里 */
  private copyIntoBox(uri: string, destPath: string): void {
    const src: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const stat: fileIo.Stat = fileIo.statSync(src.fd);
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      fileIo.readSync(src.fd, buffer);
      const dest: fileIo.File = fileIo.openSync(destPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(dest.fd, buffer);
      } finally {
        fileIo.closeSync(dest);
      }
    } finally {
      fileIo.closeSync(src);
    }
  }

  /** 把文件整个读成字符串 */
  private readTextFile(uri: string): string {
    const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const stat: fileIo.Stat = fileIo.statSync(file.fd);
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(new Uint8Array(buffer)).replace(/^\uFEFF/, '');
    } finally {
      fileIo.closeSync(file);
    }
  }

  /** 解析结果 → 预览态 */
  private applyPreviewResult(result: ImportResult, fallbackSource: string): void {
    this.previewActive = true;
    this.previewItems = result.items;
    this.previewWeeks = result.totalWeeks;
    this.previewWarnings = result.warnings;
    this.previewError = result.ok ? '' : result.error;
    this.previewSource = result.source.length > 0 ? result.source : fallbackSource;
    if (!result.ok) {
      this.statusText = '';
    }
  }

  /** 预览里删掉一条 */
  private previewRemove(entryId: number): void {
    this.previewItems = ScheduleEditor.remove(this.previewItems, entryId);
  }

  /** 放弃这次导入 */
  private cancelPreview(): void {
    this.previewActive = false;
    this.previewItems = [];
    this.previewWarnings = [];
    this.previewError = '';
    this.previewSource = '';
    this.previewWeeks = 0;
  }

  /** 确认导入：把预览里的课表打包成一次导入写进库 */
  private async confirmPreview(): Promise<void> {
    if (this.previewItems.length === 0) {
      this.statusText = '预览里没有课程了，没什么可导入的';
      return;
    }
    const source: string = this.previewSource.length > 0 ? this.previewSource : '粘贴导入';
    const result: ImportResult = ScheduleEditor.buildResult(this.previewItems, source);
    if (!result.ok) {
      this.statusText = `导入失败：${result.error}`;
      return;
    }
    await this.persistImport(result, '课表');
    this.cancelPreview();
  }

  // =========================================================================
  // 手动添加一门课
  // =========================================================================

  /** 校验并加进当前课表，然后立刻落库 */
  private async doManualAdd(): Promise<void> {
    const form: ManualCourseForm = {
      name: this.formName,
      teacher: this.formTeacher,
      room: this.formRoom,
      weekday: this.formWeekday,
      startSlot: this.formStartSlot,
      endSlot: this.formEndSlot,
      weeksText: this.formWeeks
    };
    const problem: string = ScheduleEditor.validate(form);
    if (problem.length > 0) {
      this.formError = problem;
      return;
    }
    this.formError = '';

    const entryId: number = ScheduleEditor.nextEntryId(this.items);
    const item: ScheduleItem = ScheduleEditor.toItem(form, entryId, '');
    const merged: ScheduleItem[] = ScheduleEditor.upsert(this.items, item);

    // 手动改课表不改变数据来源，只有原本就是空的时候才记成"手动添加"
    const source: string = this.importSource.length > 0 ? this.importSource : '手动添加';
    const result: ImportResult = ScheduleEditor.buildResult(merged, source);
    await this.persistImport(result, `「${item.courseName}」`);

    this.formName = '';
    this.formTeacher = '';
    this.formRoom = '';
  }

  /** 把周次快选填进输入框 */
  private useWeekPreset(preset: string): void {
    this.formWeeks = preset;
    this.formError = '';
  }

  // =========================================================================
  // 展示用的小工具
  // =========================================================================

  private weekdayLabel(weekday: number): string {
    if (weekday < 1 || weekday > 7) {
      return '—';
    }
    return WEEKDAY_SHORT[weekday - 1];
  }

  /** 从输入框读节次，非法就退回兜底值（用户删空输入框时不至于变成 0） */
  private toSlotNumber(text: string, fallback: number): number {
    const n: number = Number.parseInt(text, 10);
    if (Number.isNaN(n) || n < 1) {
      return fallback;
    }
    return n > 30 ? 30 : n;
  }

  private slotLabel(startSlot: number, endSlot: number): string {
    return startSlot === endSlot ? `第 ${startSlot} 节` : `第 ${startSlot}-${endSlot} 节`;
  }

  /** 预览里的课程门数（按课程名去重） */
  private previewCourseCount(): number {
    const seen: Set<string> = new Set<string>();
    for (let i = 0; i < this.previewItems.length; i++) {
      seen.add(this.previewItems[i].courseName);
    }
    return seen.size;
  }

  private previewSummary(): string {
    const weeks: number = this.previewWeeks > 0 ? this.previewWeeks : 16;
    return `认出来 ${this.previewItems.length} 条排课 · ${this.previewCourseCount()} 门课 · 共 ${weeks} 周`;
  }

  /** 弹日期选择器，让用户指定「第 1 周的周一」是哪天 */
  private pickSemesterStart(): void {
    this.getUIContext().showDatePickerDialog({
      start: new Date(2020, 0, 1),
      end: new Date(2035, 11, 31),
      selected: DateUtil.parseDate(this.semesterStart),
      lunar: false,
      onDateAccept: (value: Date) => {
        this.applySemesterStart(value);
      }
    });
  }

  /**
   * 应用新的学期起始日并落库。
   * 用户点哪天都行 —— 自动归到那一周的周一，因为"第 1 周周一"才是课表换算的锚点。
   */
  private async applySemesterStart(value: Date): Promise<void> {
    const monday: Date = DateUtil.mondayOf(value);
    const text: string = DateUtil.formatDate(monday);
    this.semesterStart = text;

    const repo: ScheduleRepository | undefined = this.repo;
    if (repo !== undefined) {
      try {
        await repo.updateSemesterStart(text);
      } catch (err) {
        this.statusText = `保存学期起始日失败：${JSON.stringify(err)}`;
      }
    }

    // 起始日变了，"现在第几周"跟着变，重新定位并重算
    const current: number = ScheduleService.weekOfDate(this.currentSemester(), new Date());
    this.week = Math.min(Math.max(current, 1), this.totalWeeks);
    this.refreshAll();
  }

  /** 重新计算周视图与今明日程 */
  private refreshAll(): void {
    const now: Date = new Date();
    const semester: Semester = this.currentSemester();
    this.weekView = this.service.buildWeekView(this.items, semester, this.week, now);
    this.brief = this.service.getDailyBrief(this.items, semester, now);
  }

  private currentSemester(): Semester {
    return {
      id: 1,
      name: '当前学期',
      startDate: this.semesterStart,
      totalWeeks: this.totalWeeks
    };
  }

  private shiftWeek(delta: number): void {
    const next: number = this.week + delta;
    if (next < 1 || next > this.totalWeeks) {
      return;
    }
    this.week = next;
    this.refreshAll();
  }

  private backToCurrentWeek(): void {
    const current: number = ScheduleService.weekOfDate(this.currentSemester(), new Date());
    this.week = Math.min(Math.max(current, 1), this.totalWeeks);
    this.refreshAll();
  }

  // =========================================================================
  // 文案与小组件
  // =========================================================================

  private pageTitle(): string {
    if (this.navIndex === NAV_BRIEF) {
      return '今明日程';
    }
    if (this.navIndex === NAV_WEEK) {
      return '本周课表';
    }
    if (this.navIndex === NAV_IMPORT) {
      return '导入课表';
    }
    return '作息设置';
  }

  private pageSubtitle(): string {
    if (this.navIndex === NAV_BRIEF) {
      return this.brief.hint;
    }
    if (this.navIndex === NAV_WEEK) {
      return `${this.weekView.rangeLabel}　共 ${this.weekView.courseCount} 节课`;
    }
    if (this.navIndex === NAV_IMPORT) {
      return '把教务课表变成课晓的日程';
    }
    return '时间参数全部可自定义，适配不同学校';
  }

  /** 某节课相对"现在"的状态 */
  private statusOf(course: DayCourse): string {
    const now: Date = new Date();
    if (now.getTime() >= course.end.getTime()) {
      return '已结束';
    }
    if (now.getTime() >= course.start.getTime()) {
      return '进行中';
    }
    return '未开始';
  }

  private statusColorOf(course: DayCourse): string {
    const s: string = this.statusOf(course);
    if (s === '进行中') {
      return C_PRIMARY;
    }
    return C_TEXT_WEAK;
  }

  private roomAndTeacher(course: DayCourse): string {
    const parts: string[] = [];
    if (course.item.room.length > 0) {
      parts.push(course.item.campus.length > 0
        ? `${course.item.campus} ${course.item.room}` : course.item.room);
    }
    if (course.item.teacher.length > 0) {
      parts.push(course.item.teacher);
    }
    return parts.length > 0 ? parts.join('　·　') : '地点待定';
  }

  private weekLabel(): string {
    const w: number = ScheduleService.weekOfDate(this.currentSemester(), new Date());
    if (w < 1) {
      return '开学前';
    }
    if (w > this.totalWeeks) {
      return '学期已结束';
    }
    return `第 ${w} 周`;
  }

  /** 取某个时段下的所有节次（设置页分组用） */
  private slotsOfPeriod(periodLabel: string): SlotTime[] {
    return this.slotList.filter((s: SlotTime) => s.periodLabel === periodLabel);
  }

  private periodKeyOf(periodLabel: string): PeriodKey {
    if (periodLabel === '上午') {
      return 'morning';
    }
    if (periodLabel === '下午') {
      return 'afternoon';
    }
    return 'evening';
  }

  /** 给颜色加上透明度做成浅色底：'#4C7DF0' + '26' → '#264C7DF0' */
  private tint(color: string, alpha: string): string {
    if (color.length !== 7) {
      return C_SURFACE;
    }
    return `#${alpha}${color.substring(1)}`;
  }

  // =========================================================================
  // 界面骨架
  // =========================================================================

  build() {
    Row() {
      this.buildSidebar()

      Column() {
        this.buildTopBar()
        Divider().color(C_BORDER).strokeWidth(1)

        // 本地数据读完之前先显示"正在读取"，避免先闪一下空态再蹦出课表
        if (!this.dataReady) {
          this.buildBootState()
        } else if (this.navIndex === NAV_BRIEF) {
          this.buildBriefPage()
        } else if (this.navIndex === NAV_WEEK) {
          this.buildWeekPage()
        } else if (this.navIndex === NAV_IMPORT) {
          this.buildImportPage()
        } else {
          this.buildSettingsPage()
        }
      }
      .layoutWeight(1)
      .height('100%')
      .backgroundColor(C_BG)
    }
    .width('100%')
    .height('100%')
  }

  // -------------------------------------------------------------------------
  // 侧栏
  // -------------------------------------------------------------------------

  @Builder
  buildSidebar() {
    Column() {
      Row() {
        Text('课')
          .fontSize(15)
          .fontColor(Color.White)
          .fontWeight(FontWeight.Bold)
          .width(30)
          .height(30)
          .borderRadius(9)
          .backgroundColor(C_PRIMARY)
          .textAlign(TextAlign.Center)

        if (!this.collapsed) {
          Column() {
            Text('课晓').fontSize(16).fontWeight(FontWeight.Bold).fontColor(C_TEXT)
            Text('校园日程助手').fontSize(10).fontColor(C_TEXT_WEAK).margin({ top: 1 })
          }
          .alignItems(HorizontalAlign.Start)
          .margin({ left: 10 })
        }
      }
      .width('100%')
      .height(64)
      .padding({ left: 15 })
      .alignItems(VerticalAlign.Center)

      Column() {
        ForEach(NAV_ITEMS, (nav: NavItem, index: number) => {
          this.buildNavItem(nav, index)
        }, (nav: NavItem) => nav.label)
      }
      .width('100%')
      .padding({ left: 8, right: 8 })

      Blank()

      Row() {
        Text(this.collapsed ? '»' : '«')
          .fontSize(15)
          .fontColor(C_TEXT_SUB)
          .width(20)
          .textAlign(TextAlign.Center)
        if (!this.collapsed) {
          Text('收起侧栏').fontSize(12).fontColor(C_TEXT_SUB).margin({ left: 8 })
        }
      }
      .width('100%')
      .height(44)
      .padding({ left: 13 })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.collapsed = !this.collapsed;
        // 记住这个偏好，下次打开还是这个样子
        SettingsStore.saveCollapsed(this.collapsed);
      })
    }
    .width(this.collapsed ? 62 : 208)
    .height('100%')
    .backgroundColor(C_SIDEBAR)
    .border({ width: { right: 1 }, color: { right: C_BORDER } })
    .animation({ duration: 180, curve: Curve.EaseOut })
  }

  @Builder
  buildNavItem(nav: NavItem, index: number) {
    Row() {
      Text(nav.glyph)
        .fontSize(13)
        .fontColor(this.navIndex === index ? C_PRIMARY : C_TEXT_SUB)
        .fontWeight(this.navIndex === index ? FontWeight.Bold : FontWeight.Normal)
        .width(22)
        .textAlign(TextAlign.Center)

      if (!this.collapsed) {
        Text(nav.label)
          .fontSize(13)
          .fontColor(this.navIndex === index ? C_PRIMARY : C_TEXT)
          .fontWeight(this.navIndex === index ? FontWeight.Medium : FontWeight.Normal)
          .margin({ left: 8 })
      }
    }
    .width('100%')
    .height(40)
    .padding({ left: this.collapsed ? 10 : 8 })
    .alignItems(VerticalAlign.Center)
    .borderRadius(9)
    .backgroundColor(this.navIndex === index ? C_PRIMARY_SOFT : Color.Transparent)
    .margin({ bottom: 4 })
    .onClick(() => {
      this.navIndex = index;
      if (index === NAV_BRIEF || index === NAV_WEEK) {
        this.refreshAll();
      }
    })
  }

  // -------------------------------------------------------------------------
  // 顶栏
  // -------------------------------------------------------------------------

  @Builder
  buildTopBar() {
    Row() {
      Column() {
        Text(this.pageTitle()).fontSize(18).fontWeight(FontWeight.Bold).fontColor(C_TEXT)
        Text(this.pageSubtitle()).fontSize(11).fontColor(C_TEXT_WEAK).margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.navIndex === NAV_WEEK) {
        Row() {
          Text('‹')
            .fontSize(15)
            .fontColor(C_TEXT)
            .width(28)
            .height(28)
            .textAlign(TextAlign.Center)
            .borderRadius(8)
            .backgroundColor('#F0F2F5')
            .onClick(() => {
              this.shiftWeek(-1);
            })

          Text(this.weekView.title)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(C_TEXT)
            .width(70)
            .textAlign(TextAlign.Center)

          Text('›')
            .fontSize(15)
            .fontColor(C_TEXT)
            .width(28)
            .height(28)
            .textAlign(TextAlign.Center)
            .borderRadius(8)
            .backgroundColor('#F0F2F5')
            .onClick(() => {
              this.shiftWeek(1);
            })

          Text('回到本周')
            .fontSize(12)
            .fontColor(C_PRIMARY)
            .height(28)
            .padding({ left: 12, right: 12 })
            .borderRadius(8)
            .backgroundColor(C_PRIMARY_SOFT)
            .textAlign(TextAlign.Center)
            .margin({ left: 8 })
            .onClick(() => {
              this.backToCurrentWeek();
            })
        }
        .alignItems(VerticalAlign.Center)
      }

      if (this.navIndex === NAV_BRIEF) {
        Text(this.brief.title)
          .fontSize(13)
          .fontColor(C_PRIMARY)
          .fontWeight(FontWeight.Medium)
      }
    }
    .width('100%')
    .height(64)
    .padding({ left: 20, right: 20 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(C_SURFACE)
  }

  // -------------------------------------------------------------------------
  // ① 周视图
  // -------------------------------------------------------------------------

  @Builder
  buildWeekPage() {
    Column() {
      if (this.items.length === 0) {
        this.buildEmptyState('还没有课表数据',
          '去「导入课表」导入自己的课表，或先载入示例数据看看界面')
      } else {
        // 固定的星期表头（不随内容滚动）
        Row() {
          Column().width(58)
          ForEach(this.weekView.days, (day: WeekViewDay) => {
            this.buildDayHeader(day)
          }, (day: WeekViewDay) => `h${day.weekday}`)
        }
        .width('100%')
        .backgroundColor(C_SURFACE)

        Divider().color(C_BORDER).strokeWidth(1)

        // 可滚动的课表主体
        Scroll() {
          Row() {
            this.buildTimeColumn()
            ForEach(this.weekView.days, (day: WeekViewDay) => {
              this.buildDayColumn(day)
            }, (day: WeekViewDay) => `c${day.weekday}`)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.Auto)
        .layoutWeight(1)
        .width('100%')
      }
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 20, right: 20, bottom: 12 })
  }

  @Builder
  buildDayHeader(day: WeekViewDay) {
    Column() {
      Text(day.shortLabel)
        .fontSize(12)
        .fontColor(day.isToday ? C_PRIMARY : C_TEXT)
        .fontWeight(day.isToday ? FontWeight.Bold : FontWeight.Normal)
      Text(day.isToday ? '今天' : day.dateLabel)
        .fontSize(10)
        .fontColor(day.isToday ? C_PRIMARY : C_TEXT_WEAK)
        .margin({ top: 2 })
    }
    .height(HEADER_H)
    .justifyContent(FlexAlign.Center)
    .layoutWeight(1)
  }

  @Builder
  buildTimeColumn() {
    Column() {
      ForEach(this.slotList, (slot: SlotTime) => {
        Column() {
          Text(slot.start).fontSize(10).fontColor(C_TEXT_SUB)
          Text(slot.end).fontSize(9).fontColor(C_TEXT_WEAK).margin({ top: 1 })
        }
        .height(SLOT_H)
        .justifyContent(FlexAlign.Center)
      }, (slot: SlotTime) => `t${slot.slot}`)
    }
    .width(58)
  }

  @Builder
  buildDayColumn(day: WeekViewDay) {
    Column() {
      ForEach(day.cells, (cell: DayCell) => {
        if (cell.kind === 'course') {
          this.buildCourseCard(cell)
        } else {
          // 空白格：留白即可，视觉上表示"没课"
          Column()
            .width('100%')
            .height(SLOT_H)
        }
      }, (cell: DayCell) => `cell${day.weekday}-${cell.slot}`)
    }
    .layoutWeight(1)
    .padding({ left: 2, right: 2 })
    .backgroundColor(day.isToday ? C_TODAY_BG : Color.Transparent)
  }

  /**
   * 课程卡片。
   * ArkUI 没有表格的 rowspan，所以"合并单元格"是靠 height = span × 单元高 模拟的，
   * span 由 ScheduleService.buildDayColumn() 算好。
   */
  @Builder
  buildCourseCard(cell: DayCell) {
    Column() {
      Text(cell.courseName)
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor(C_TEXT)
        .maxLines(cell.span >= 2 ? 3 : 2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      if (cell.span >= 2) {
        Text(cell.timeText)
          .fontSize(9)
          .fontColor(C_TEXT_SUB)
          .margin({ top: 4 })
          .width('100%')
        Text(cell.room)
          .fontSize(9)
          .fontColor(C_TEXT_WEAK)
          .margin({ top: 2 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
    }
    .width('100%')
    .height(cell.span * SLOT_H - 6)
    .padding({ left: 7, right: 6, top: 6, bottom: 6 })
    .borderRadius(8)
    .backgroundColor(this.tint(cell.color, '26'))
    .border({ width: { left: 3 }, color: { left: cell.color } })
    .margin({ top: 3, bottom: 3 })
    .alignItems(HorizontalAlign.Start)
  }

  // -------------------------------------------------------------------------
  // ② 今明日程（日常态 / 小窗口形态）
  // -------------------------------------------------------------------------

  @Builder
  buildBriefPage() {
    Column() {
      if (this.items.length === 0) {
        // 首页就是「今明日程」，空态也就落在这里 ——
        // 用户打开应用第一眼看到的是"还没有数据 + 去哪儿弄数据"。
        this.buildEmptyState('还没有课表数据',
          '去「导入课表」导入自己的课表，或先载入示例数据看看界面')
      } else {
        this.buildBriefSummary()

        if (this.brief.courses.length === 0) {
          Column() {
            Text('这段时间没有课').fontSize(13).fontColor(C_TEXT_WEAK)
            Text('可以在「作息设置」里检查学期起始日是否正确')
              .fontSize(11)
              .fontColor(C_TEXT_WEAK)
              .margin({ top: 6 })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          // 用 List 而不是 Scroll+Column：List 天然自上而下排布，
          // 内容比可视区短时也不会被挤到底部。
          List({ space: 10 }) {
            ForEach(this.brief.courses, (course: DayCourse) => {
              ListItem() {
                this.buildTimelineCard(course)
              }
            }, (course: DayCourse) => `tl${course.item.entryId}`)
          }
          .layoutWeight(1)
          .width('100%')
          .padding({ top: 12 })
          .scrollBar(BarState.Off)
        }
      }
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 20, right: 20, bottom: 12 })
  }

  /** 今明日程顶部的概要卡（日期 + 今天几节课 + 一句状态提示） */
  @Builder
  buildBriefSummary() {
    Column() {
      Row() {
        Column() {
          Text(this.brief.title).fontSize(20).fontWeight(FontWeight.Bold).fontColor(C_TEXT)
          Text(`${DateUtil.formatMd(this.brief.date)}　${DateUtil.weekdayShortLabel(this.brief.date)}`)
            .fontSize(11)
            .fontColor(C_TEXT_WEAK)
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Column() {
          Text(`${this.brief.courses.length}`)
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor(C_PRIMARY)
          Text('节课').fontSize(10).fontColor(C_TEXT_WEAK)
        }
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%')
      .padding(16)
      .borderRadius(12)
      .backgroundColor(C_SURFACE)
      .border({ width: 1, color: C_BORDER })

      if (this.brief.hint.length > 0) {
        Row() {
          Text(this.brief.hint).fontSize(11).fontColor(C_TEXT_SUB)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 9, bottom: 9 })
        .margin({ top: 10 })
        .borderRadius(8)
        .backgroundColor(C_PRIMARY_SOFT)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 时间线上的一张卡片。
   * 这正是"日常态"的核心形态：将来做成 2in1 小窗口 / 桌面卡片时，
   * 只保留这一列内容即可。
   */
  @Builder
  buildTimelineCard(course: DayCourse) {
    Row() {
      Column() {
        Text(DateUtil.formatHm(course.start)).fontSize(14).fontWeight(FontWeight.Bold).fontColor(C_TEXT)
        Text(DateUtil.formatHm(course.end)).fontSize(10).fontColor(C_TEXT_WEAK).margin({ top: 3 })
      }
      .width(56)
      .alignItems(HorizontalAlign.Center)

      Column()
        .width(3)
        .height(58)
        .borderRadius(2)
        .backgroundColor(course.item.color)
        .margin({ left: 4, right: 12 })

      Column() {
        Row() {
          Text(course.item.courseName)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(C_TEXT)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Text(this.statusOf(course))
            .fontSize(10)
            .fontColor(this.statusColorOf(course))
            .padding({ left: 7, right: 7, top: 2, bottom: 2 })
            .borderRadius(6)
            .backgroundColor(this.tint(course.item.color, '1F'))
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text(this.roomAndTeacher(course))
          .fontSize(11)
          .fontColor(C_TEXT_SUB)
          .margin({ top: 7 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(`第 ${course.item.startSlot}-${course.item.endSlot} 节　·　${course.item.weeksRaw}`)
          .fontSize(10)
          .fontColor(C_TEXT_WEAK)
          .margin({ top: 4 })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(14)
    .borderRadius(12)
    .backgroundColor(C_SURFACE)
    .border({ width: 1, color: C_BORDER })
    .alignItems(VerticalAlign.Center)
  }

  // -------------------------------------------------------------------------
  // ③ 导入
  // -------------------------------------------------------------------------

  @Builder
  buildImportPage() {
    Column() {
      if (this.classPickerActive) {
        this.buildClassPicker()
      } else {
        Scroll() {
          Column() {
            if (this.previewActive) {
              this.buildPreviewPanel()
            } else {
              this.buildPasteCard()
              this.buildManualCard()
              this.buildFileCard()
              this.buildCurrentDataCard()
              this.buildSampleCard()
              this.buildNotesCards()
            }

            if (this.statusText.length > 0) {
              Row() {
                Text(this.statusText).fontSize(11).fontColor(C_TEXT_SUB).width('100%')
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 9, bottom: 9 })
              .margin({ top: 12 })
              .borderRadius(8)
              .backgroundColor(C_PRIMARY_SOFT)
            }

            if (!this.previewActive && this.importWarnings.length > 0) {
              Column() {
                Text('上次导入的提示').fontSize(12).fontWeight(FontWeight.Medium).fontColor(C_WARN_TEXT)
                ForEach(this.importWarnings, (w: string, index: number) => {
                  Text(`· ${w}`).fontSize(11).fontColor(C_WARN_TEXT).margin({ top: 6 }).width('100%')
                }, (w: string, index: number) => `w${index}`)
              }
              .width('100%')
              .padding(14)
              .margin({ top: 12 })
              .borderRadius(12)
              .backgroundColor(C_WARN_BG)
              .alignItems(HorizontalAlign.Start)
            }
          }
          .width('100%')
          .padding({ top: 14, bottom: 14 })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 20, right: 20 })
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.Auto)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  // -------------------------------------------------------------------------
  // ③-0 从教务处 Excel 里认领自己的班级
  // -------------------------------------------------------------------------

  @Builder
  buildClassPicker() {
    Column() {
      Row() {
        Column() {
          Text('选择你的班级').fontSize(14).fontWeight(FontWeight.Medium).fontColor(C_TEXT)
          Text(`从「${this.classSource}」里找到 ${this.classCandidates.length} 个班级，认领你自己的那个`)
            .fontSize(11)
            .fontColor(C_TEXT_SUB)
            .margin({ top: 5 })
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text('取消')
          .fontSize(12)
          .fontColor(C_TEXT_SUB)
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .borderRadius(6)
          .backgroundColor(C_BG)
          .onClick(() => {
            this.classPickerActive = false;
            this.statusText = '换一个文件也可以';
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      TextInput({ placeholder: '输入专业名、班号或辅导员缩小范围', text: this.classQuery })
        .fontSize(12)
        .height(40)
        .width('100%')
        .margin({ top: 14 })
        .backgroundColor(C_SURFACE)
        .borderRadius(8)
        .onChange((value: string) => {
          this.classQuery = value;
        })

      Text(this.classListHint())
        .fontSize(10)
        .fontColor(C_TEXT_WEAK)
        .margin({ top: 8 })
        .width('100%')

      List({ space: 8 }) {
        ForEach(this.filteredClasses(), (info: XlsxClassInfo) => {
          ListItem() {
            Column() {
              Text(this.classTitle(info)).fontSize(13).fontColor(C_TEXT).width('100%')
              Text(this.classSubtitle(info))
                .fontSize(11)
                .fontColor(C_TEXT_WEAK)
                .margin({ top: 5 })
                .width('100%')
            }
            .width('100%')
            .padding(12)
            .borderRadius(10)
            .backgroundColor(C_SURFACE)
            .border({ width: 1, color: C_BORDER })
            .alignItems(HorizontalAlign.Start)
            .onClick(() => {
              this.chooseClass(info);
            })
          }
        }, (info: XlsxClassInfo) => `${info.sheetName}-${info.code}`)
      }
      .width('100%')
      .layoutWeight(1)
      .margin({ top: 12 })
      .scrollBar(BarState.Auto)

      if (this.statusText.length > 0) {
        Text(this.statusText).fontSize(11).fontColor(C_TEXT_SUB).width('100%').margin({ top: 10 })
      }
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 20, right: 20, top: 14, bottom: 14 })
    .alignItems(HorizontalAlign.Start)
  }

  private classListHint(): string {
    const shown: number = this.filteredClasses().length;
    if (this.classQuery.trim().length === 0 && shown >= CLASS_LIST_LIMIT) {
      return `共 ${this.classCandidates.length} 个班级，先列出前 ${CLASS_LIST_LIMIT} 个 —— 输入专业名可以快速找到自己`;
    }
    if (shown === 0) {
      return '没匹配到，换个关键词试试（比如「计算机」）';
    }
    return `匹配到 ${shown} 个`;
  }

  // -------------------------------------------------------------------------
  // ③-a 粘贴课表
  // -------------------------------------------------------------------------

  @Builder
  buildPasteCard() {
    Column() {
      Text('粘贴课表').fontSize(13).fontWeight(FontWeight.Medium).fontColor(C_TEXT)
      Text('在教务系统的课表页面上 Ctrl+A 全选、Ctrl+C 复制；或者在 Excel 里把课表区域选中复制。' +
        '然后在下面的框里 Ctrl+V 粘贴，也可以点左下角的「粘贴」。')
        .fontSize(11)
        .fontColor(C_TEXT_SUB)
        .margin({ top: 6 })
        .lineHeight(18)
        .width('100%')

      TextArea({ text: this.pasteText, placeholder: '在这里粘贴课表内容…' })
        .width('100%')
        .height(110)
        .margin({ top: 12 })
        .fontSize(12)
        .borderRadius(10)
        .backgroundColor('#F7F8FA')
        .onChange((value: string) => {
          this.pasteText = value;
          // 输入框只给得到纯文本，用户一旦改动内容，之前那份 HTML 就对不上了，
          // 留着会用错数据，必须作废。比对是为了放行"程序写入 pasteText"那种情况。
          if (this.pasteHtml.length > 0 && value !== this.pasteHtmlFor) {
            this.pasteHtml = '';
            this.pasteHtmlFor = '';
          }
        })

      Row() {
        // 必须用安全组件 PasteButton：普通按钮调剪贴板会被系统拒（见 readClipboard 的注释）。
        // 注意 PasteButtonAttribute 不支持 .margin()，所以外边距加在外层 Row 上。
        Row() {
          PasteButton({
            icon: PasteIconStyle.LINES,
            text: PasteDescription.PASTE,
            buttonType: ButtonType.Capsule
          })
            .onClick((event: ClickEvent, result: PasteButtonOnClickResult) => {
              if (result === PasteButtonOnClickResult.SUCCESS) {
                this.readClipboard();
              } else {
                this.statusText = '没拿到剪贴板授权，可以在下面的框里直接 Ctrl+V 粘贴';
              }
            })
        }
        .margin({ right: 10 })

        Text('解析')
          .fontSize(12)
          .fontColor(Color.White)
          .fontWeight(FontWeight.Medium)
          .height(34)
          .padding({ left: 26, right: 26 })
          .borderRadius(8)
          .backgroundColor(C_PRIMARY)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.doParsePaste();
          })

        Blank()
      }
      .width('100%')
      .margin({ top: 12 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(16)
    .borderRadius(12)
    .backgroundColor(C_SURFACE)
    .border({ width: 1, color: C_BORDER })
    .alignItems(HorizontalAlign.Start)
  }

  // -------------------------------------------------------------------------
  // ③-b 预览校对
  // -------------------------------------------------------------------------

  @Builder
  buildPreviewPanel() {
    Column() {
      Row() {
        Column() {
          Text('确认导入').fontSize(14).fontWeight(FontWeight.Medium).fontColor(C_TEXT)
          if (this.previewError.length === 0) {
            Text(this.previewSummary()).fontSize(11).fontColor(C_TEXT_SUB).margin({ top: 5 })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text('返回')
          .fontSize(12)
          .fontColor(C_PRIMARY)
          .height(30)
          .padding({ left: 14, right: 14 })
          .borderRadius(8)
          .backgroundColor(C_PRIMARY_SOFT)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.cancelPreview();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.previewError.length > 0) {
        Column() {
          Text('没能认出这段内容').fontSize(13).fontColor(C_WARN_TEXT).fontWeight(FontWeight.Medium)
          Text(this.previewError)
            .fontSize(12)
            .fontColor(C_WARN_TEXT)
            .margin({ top: 8 })
            .lineHeight(19)
            .width('100%')
        }
        .width('100%')
        .padding(14)
        .margin({ top: 14 })
        .borderRadius(10)
        .backgroundColor(C_WARN_BG)
        .alignItems(HorizontalAlign.Start)
      } else {
        Text('下面是解析出来的结果。有认错的，点右边的「删掉」去掉；确认没问题再点导入。')
          .fontSize(11)
          .fontColor(C_TEXT_SUB)
          .margin({ top: 10 })
          .lineHeight(18)
          .width('100%')

        if (this.previewWarnings.length > 0) {
          Column() {
            Text('解析提示').fontSize(12).fontWeight(FontWeight.Medium).fontColor(C_WARN_TEXT)
            ForEach(this.previewWarnings, (w: string, index: number) => {
              Text(`· ${w}`).fontSize(11).fontColor(C_WARN_TEXT).margin({ top: 6 }).width('100%')
            }, (w: string, index: number) => `pw${index}`)
          }
          .width('100%')
          .padding(14)
          .margin({ top: 12 })
          .borderRadius(10)
          .backgroundColor(C_WARN_BG)
          .alignItems(HorizontalAlign.Start)
        }

        Column() {
          ForEach(this.previewItems, (item: ScheduleItem) => {
            this.buildPreviewRow(item)
          }, (item: ScheduleItem) => `pv${item.entryId}`)
        }
        .width('100%')
        .margin({ top: 12 })

        Row() {
          Text('放弃')
            .fontSize(12)
            .fontColor(C_TEXT_SUB)
            .height(38)
            .padding({ left: 20, right: 20 })
            .borderRadius(9)
            .backgroundColor('#F0F2F5')
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.cancelPreview();
            })

          Text(this.busy ? '正在保存…' : `确认导入 ${this.previewItems.length} 条`)
            .fontSize(13)
            .fontColor(Color.White)
            .fontWeight(FontWeight.Medium)
            .layoutWeight(1)
            .height(38)
            .margin({ left: 10 })
            .borderRadius(9)
            .backgroundColor(this.busy ? '#B9C6E8' : C_PRIMARY)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              if (!this.busy) {
                this.confirmPreview();
              }
            })
        }
        .width('100%')
        .margin({ top: 14 })
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .padding(16)
    .borderRadius(12)
    .backgroundColor(C_SURFACE)
    .border({ width: 1, color: C_BORDER })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildPreviewRow(item: ScheduleItem) {
    Row() {
      Column()
        .width(3)
        .height(32)
        .borderRadius(2)
        .backgroundColor(item.color)

      Column() {
        Text(item.courseName)
          .fontSize(12)
          .fontColor(C_TEXT)
          .fontWeight(FontWeight.Medium)
          .width('100%')
        Text(this.previewRowDetail(item))
          .fontSize(10)
          .fontColor(C_TEXT_WEAK)
          .margin({ top: 3 })
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 10 })

      Text('删掉')
        .fontSize(10)
        .fontColor('#D4456B')
        .height(24)
        .padding({ left: 10, right: 10 })
        .borderRadius(6)
        .backgroundColor('#FDEEF2')
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.previewRemove(item.entryId);
        })
    }
    .width('100%')
    .padding(10)
    .margin({ bottom: 8 })
    .borderRadius(9)
    .backgroundColor('#FAFBFC')
    .border({ width: 1, color: C_BORDER })
    .alignItems(VerticalAlign.Center)
  }

  private previewRowDetail(item: ScheduleItem): string {
    let text: string = `${this.weekdayLabel(item.weekday)}　`
      + `${this.slotLabel(item.startSlot, item.endSlot)}　${item.weeksRaw}`;
    if (item.room.length > 0) {
      text += `　${item.room}`;
    }
    if (item.teacher.length > 0) {
      text += `　${item.teacher}`;
    }
    return text;
  }

  // -------------------------------------------------------------------------
  // ③-c 手动添加
  // -------------------------------------------------------------------------

  @Builder
  buildManualCard() {
    Column() {
      Row() {
        Column() {
          Text('手动添加一门课').fontSize(13).fontWeight(FontWeight.Medium).fontColor(C_TEXT)
          Text('导入有遗漏、临时调课、补录实验课时用它')
            .fontSize(11)
            .fontColor(C_TEXT_WEAK)
            .margin({ top: 5 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text(this.showManualForm ? '收起' : '展开')
          .fontSize(12)
          .fontColor(C_PRIMARY)
          .height(30)
          .padding({ left: 14, right: 14 })
          .borderRadius(8)
          .backgroundColor(C_PRIMARY_SOFT)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.showManualForm = !this.showManualForm;
            this.formError = '';
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.showManualForm) {
        Text('课程名').fontSize(11).fontColor(C_TEXT_SUB).margin({ top: 14 })
        TextInput({ text: this.formName, placeholder: '如：线性代数' })
          .width('100%')
          .height(36)
          .fontSize(12)
          .margin({ top: 6 })
          .borderRadius(8)
          .backgroundColor('#F7F8FA')
          .onChange((v: string) => {
            this.formName = v;
          })

        Row() {
          Column() {
            Text('教师').fontSize(11).fontColor(C_TEXT_SUB)
            TextInput({ text: this.formTeacher, placeholder: '可留空' })
              .width('100%')
              .height(36)
              .fontSize(12)
              .margin({ top: 6 })
              .borderRadius(8)
              .backgroundColor('#F7F8FA')
              .onChange((v: string) => {
                this.formTeacher = v;
              })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Column() {
            Text('教室').fontSize(11).fontColor(C_TEXT_SUB)
            TextInput({ text: this.formRoom, placeholder: '可留空' })
              .width('100%')
              .height(36)
              .fontSize(12)
              .margin({ top: 6 })
              .borderRadius(8)
              .backgroundColor('#F7F8FA')
              .onChange((v: string) => {
                this.formRoom = v;
              })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          .margin({ left: 10 })
        }
        .width('100%')
        .margin({ top: 12 })
        .alignItems(VerticalAlign.Top)

        Text('星期').fontSize(11).fontColor(C_TEXT_SUB).margin({ top: 12 })
        Row() {
          ForEach(WEEKDAY_NUMS, (d: number) => {
            Text(WEEKDAY_SHORT[d - 1])
              .fontSize(11)
              .fontColor(this.formWeekday === d ? Color.White : C_TEXT_SUB)
              .backgroundColor(this.formWeekday === d ? C_PRIMARY : '#F0F2F5')
              .height(30)
              .layoutWeight(1)
              .borderRadius(7)
              .textAlign(TextAlign.Center)
              .margin({ left: d === 1 ? 0 : 5 })
              .onClick(() => {
                this.formWeekday = d;
              })
          }, (d: number) => `wd${d}`)
        }
        .width('100%')
        .margin({ top: 6 })

        Text('节次').fontSize(11).fontColor(C_TEXT_SUB).margin({ top: 12 })
        Row() {
          TextInput({ text: `${this.formStartSlot}` })
            .type(InputType.Number)
            .layoutWeight(1)
            .height(36)
            .fontSize(12)
            .borderRadius(8)
            .backgroundColor('#F7F8FA')
            .onChange((v: string) => {
              this.formStartSlot = this.toSlotNumber(v, 1);
            })

          Text('到').fontSize(11).fontColor(C_TEXT_WEAK).margin({ left: 8, right: 8 })

          TextInput({ text: `${this.formEndSlot}` })
            .type(InputType.Number)
            .layoutWeight(1)
            .height(36)
            .fontSize(12)
            .borderRadius(8)
            .backgroundColor('#F7F8FA')
            .onChange((v: string) => {
              this.formEndSlot = this.toSlotNumber(v, this.formStartSlot);
            })

          Text('节').fontSize(11).fontColor(C_TEXT_WEAK).margin({ left: 8 })
        }
        .width('100%')
        .margin({ top: 6 })
        .alignItems(VerticalAlign.Center)

        Text('上课周次').fontSize(11).fontColor(C_TEXT_SUB).margin({ top: 12 })
        TextInput({ text: this.formWeeks, placeholder: '如：1-16周' })
          .width('100%')
          .height(36)
          .fontSize(12)
          .margin({ top: 6 })
          .borderRadius(8)
          .backgroundColor('#F7F8FA')
          .onChange((v: string) => {
            this.formWeeks = v;
          })

        Row() {
          ForEach(WEEK_PRESETS, (preset: string) => {
            Text(preset)
              .fontSize(11)
              .fontColor(C_TEXT_SUB)
              .height(26)
              .padding({ left: 10, right: 10 })
              .borderRadius(6)
              .backgroundColor('#F0F2F5')
              .textAlign(TextAlign.Center)
              .margin({ left: preset === WEEK_PRESETS[0] ? 0 : 6 })
              .onClick(() => {
                this.useWeekPreset(preset);
              })
          }, (preset: string) => `wp${preset}`)
        }
        .width('100%')
        .margin({ top: 8 })

        if (this.formError.length > 0) {
          Text(this.formError)
            .fontSize(11)
            .fontColor(C_WARN_TEXT)
            .width('100%')
            .padding({ left: 10, right: 10, top: 8, bottom: 8 })
            .margin({ top: 10 })
            .borderRadius(8)
            .backgroundColor(C_WARN_BG)
        }

        Text(this.busy ? '正在保存…' : '加入课表')
          .fontSize(13)
          .fontColor(Color.White)
          .fontWeight(FontWeight.Medium)
          .width('100%')
          .height(38)
          .margin({ top: 12 })
          .borderRadius(9)
          .backgroundColor(this.busy ? '#B9C6E8' : C_PRIMARY)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            if (!this.busy) {
              this.doManualAdd();
            }
          })
      }
    }
    .width('100%')
    .padding(16)
    .margin({ top: 12 })
    .borderRadius(12)
    .backgroundColor(C_SURFACE)
    .border({ width: 1, color: C_BORDER })
    .alignItems(HorizontalAlign.Start)
  }

  // -------------------------------------------------------------------------
  // ③-d 文件导入 / 当前数据 / 示例
  // -------------------------------------------------------------------------

  @Builder
  buildFileCard() {
    Row() {
      Column() {
        Text('从文件导入').fontSize(13).fontColor(C_TEXT)
        Text('教务处的「各校区课表」Excel（.xlsx）最省事 —— 不用复制、不用电脑；' +
          '也支持课晓格式 .json 和纯文本 .txt / .csv')
          .fontSize(11)
          .fontColor(C_TEXT_WEAK)
          .margin({ top: 5 })
          .lineHeight(17)
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text('选择文件')
        .fontSize(12)
        .fontColor(C_PRIMARY)
        .height(30)
        .padding({ left: 14, right: 14 })
        .borderRadius(8)
        .backgroundColor(C_PRIMARY_SOFT)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.pickFile();
        })
    }
    .width('100%')
    .padding(16)
    .margin({ top: 12 })
    .borderRadius(12)
    .backgroundColor(C_SURFACE)
    .border({ width: 1, color: C_BORDER })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  buildCurrentDataCard() {
    Column() {
      Row() {
        Text('当前课表').fontSize(11).fontColor(C_TEXT_WEAK)
        Blank()
        if (this.items.length > 0) {
          Text('清空')
            .fontSize(11)
            .fontColor('#D4456B')
            .height(26)
            .padding({ left: 12, right: 12 })
            .borderRadius(7)
            .backgroundColor('#FDEEF2')
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.confirmClear();
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(this.importSource.length > 0 ? this.importSource : '尚未导入')
        .fontSize(13)
        .fontColor(C_TEXT)
        .margin({ top: 8 })
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      Text(this.importSummary.length > 0 ? this.importSummary : '导入后会保存在本机，重开应用不会丢')
        .fontSize(11)
        .fontColor(C_TEXT_SUB)
        .margin({ top: 6 })
        .width('100%')
    }
    .width('100%')
    .padding(16)
    .margin({ top: 12 })
    .borderRadius(12)
    .backgroundColor(C_SURFACE)
    .border({ width: 1, color: C_BORDER })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  buildSampleCard() {
    Row() {
      Column() {
        Text('先看看界面长什么样').fontSize(13).fontColor(C_TEXT)
        Text('示例课表是虚构数据，会真的写进本机数据库，随时可以清空')
          .fontSize(11)
          .fontColor(C_TEXT_WEAK)
          .margin({ top: 5 })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text(this.busy ? '正在保存…' : '载入示例课表')
        .fontSize(12)
        .fontColor(this.busy ? C_TEXT_WEAK : C_PRIMARY)
        .height(30)
        .padding({ left: 14, right: 14 })
        .borderRadius(8)
        .backgroundColor(this.busy ? '#F0F2F5' : C_PRIMARY_SOFT)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          if (!this.busy) {
            this.loadSampleSchedule();
          }
        })
    }
    .width('100%')
    .padding(16)
    .margin({ top: 12 })
    .borderRadius(12)
    .backgroundColor(C_SURFACE)
    .border({ width: 1, color: C_BORDER })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  buildNotesCards() {
    Column() {
      this.buildInfoCard('课晓怎么拿到你的课表',
        '课晓不去登录、也不去"爬"你的教务系统 —— 课表完全由你自己交进来：' +
          '粘贴一段复制好的课表文本，或者手动加一门课。整个过程不涉及任何账号密码。')
    }
    .width('100%')
    .margin({ top: 12 })

    Column() {
      this.buildInfoCard('数据存在哪里',
        '你导入的课表保存在本机应用目录里的一个数据库文件，卸载应用时会一并删除，' +
          '课晓不会把它上传到任何地方。换设备需要重新导入一次。')
    }
    .width('100%')
    .margin({ top: 12 })
  }

  @Builder
  buildInfoCard(title: string, body: string) {
    Column() {
      Text(title).fontSize(13).fontWeight(FontWeight.Medium).fontColor(C_TEXT)
      Text(body).fontSize(12).fontColor(C_TEXT_SUB).margin({ top: 8 }).lineHeight(20)
    }
    .width('100%')
    .padding(16)
    .borderRadius(12)
    .backgroundColor(C_SURFACE)
    .border({ width: 1, color: C_BORDER })
    .alignItems(HorizontalAlign.Start)
  }

  // -------------------------------------------------------------------------
  // ④ 作息设置
  // -------------------------------------------------------------------------

  @Builder
  buildSettingsPage() {
    Scroll() {
      Column() {
        Column() {
          Text('学期').fontSize(13).fontWeight(FontWeight.Medium).fontColor(C_TEXT)

          Row() {
            Text('第 1 周周一').fontSize(12).fontColor(C_TEXT_SUB).layoutWeight(1)
            Text(this.semesterStart).fontSize(12).fontColor(C_TEXT).fontWeight(FontWeight.Medium)
            if (this.items.length > 0) {
              Text('修改')
                .fontSize(11)
                .fontColor(C_PRIMARY)
                .height(24)
                .padding({ left: 10, right: 10 })
                .borderRadius(6)
                .backgroundColor(C_PRIMARY_SOFT)
                .textAlign(TextAlign.Center)
                .margin({ left: 10 })
                .onClick(() => {
                  this.pickSemesterStart();
                })
            }
          }
          .width('100%')
          .margin({ top: 12 })
          .alignItems(VerticalAlign.Center)

          Text(this.items.length > 0
            ? '整张课表按这一天换算周次。导入时若拿不到学期信息，会先按「导入当周 = 第 1 周」估算，' +
              '不对就在这里改一下。'
            : '导入课表后，这里才可以修改。')
            .fontSize(10)
            .fontColor(C_TEXT_WEAK)
            .margin({ top: 8 })
            .width('100%')

          Row() {
            Text('总周数').fontSize(12).fontColor(C_TEXT_SUB).layoutWeight(1)
            Text(`${this.totalWeeks} 周`).fontSize(12).fontColor(C_TEXT).fontWeight(FontWeight.Medium)
          }
          .width('100%')
          .margin({ top: 8 })

          Row() {
            Text('今天属于').fontSize(12).fontColor(C_TEXT_SUB).layoutWeight(1)
            Text(this.weekLabel()).fontSize(12).fontColor(C_PRIMARY).fontWeight(FontWeight.Medium)
          }
          .width('100%')
          .margin({ top: 8 })
        }
        .width('100%')
        .padding(16)
        .borderRadius(12)
        .backgroundColor(C_SURFACE)
        .border({ width: 1, color: C_BORDER })
        .alignItems(HorizontalAlign.Start)

        Column() {
          Text('作息时间表').fontSize(13).fontWeight(FontWeight.Medium).fontColor(C_TEXT)
          Text('「大课 = 若干小课相连」：一节课 45 分钟，两节连上构成一节 90 分钟的大课，' +
            '大课之间休息 15 分钟。共 13 节，与教务课表的"第一节～第十三节"一一对应。')
            .fontSize(11)
            .fontColor(C_TEXT_SUB)
            .margin({ top: 8 })
            .lineHeight(18)

          this.buildPeriodSection('上午')
          this.buildPeriodSection('下午')
          this.buildPeriodSection('晚上')
        }
        .width('100%')
        .padding(16)
        .margin({ top: 12 })
        .borderRadius(12)
        .backgroundColor(C_SURFACE)
        .border({ width: 1, color: C_BORDER })
        .alignItems(HorizontalAlign.Start)

        Column() {
          this.buildInfoCard('说明',
            '学期起始日现在可以直接改，改完立刻重算整张课表；' +
              '作息时间表目前取自 model/Defaults.ets 的默认值，下一步会做成可编辑项' +
              '（每节课时长、课间、午休晚休起止）。你改过的作息会随应用保存在本机。')
        }
        .width('100%')
        .margin({ top: 12 })
      }
      .width('100%')
      .padding({ top: 14, bottom: 14 })
      .alignItems(HorizontalAlign.Start)
    }
    .layoutWeight(1)
    .width('100%')
    .padding({ left: 20, right: 20 })
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Auto)
  }

  @Builder
  buildPeriodSection(periodLabel: string) {
    Column() {
      Row() {
        Text(periodLabel).fontSize(12).fontWeight(FontWeight.Medium).fontColor(C_PRIMARY)
        Text(this.service.slots.periodSummary(this.periodKeyOf(periodLabel)))
          .fontSize(11)
          .fontColor(C_TEXT_WEAK)
          .margin({ left: 8 })
      }
      .width('100%')
      .margin({ top: 16 })
      .alignItems(VerticalAlign.Center)

      ForEach(this.slotsOfPeriod(periodLabel), (slot: SlotTime) => {
        Row() {
          Text(`第 ${slot.slot} 节`).fontSize(11).fontColor(C_TEXT_SUB).width(64)
          Text(`${slot.start} – ${slot.end}`).fontSize(11).fontColor(C_TEXT)
          Text(`${slot.endMinutes - slot.startMinutes} 分钟`)
            .fontSize(10)
            .fontColor(C_TEXT_WEAK)
            .margin({ left: 10 })
        }
        .width('100%')
        .height(30)
        .alignItems(VerticalAlign.Center)
      }, (slot: SlotTime) => `p${slot.slot}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // -------------------------------------------------------------------------
  // 空态
  // -------------------------------------------------------------------------

  @Builder
  buildEmptyState(title: string, subtitle: string) {
    Column() {
      Text(title).fontSize(14).fontColor(C_TEXT).fontWeight(FontWeight.Medium)
      Text(subtitle)
        .fontSize(11)
        .fontColor(C_TEXT_WEAK)
        .margin({ top: 8 })
        .textAlign(TextAlign.Center)
        .padding({ left: 40, right: 40 })

      Text(this.busy ? '正在保存…' : '载入示例课表')
        .fontSize(13)
        .fontColor(Color.White)
        .fontWeight(FontWeight.Medium)
        .height(38)
        .padding({ left: 22, right: 22 })
        .borderRadius(10)
        .backgroundColor(this.busy ? C_TEXT_WEAK : C_PRIMARY)
        .textAlign(TextAlign.Center)
        .margin({ top: 18 })
        .onClick(() => {
          if (!this.busy) {
            this.loadSampleSchedule();
          }
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  /** 启动读库期间、以及读库失败时的占位 */
  @Builder
  buildBootState() {
    Column() {
      if (this.bootError.length > 0) {
        Text('本地数据打不开').fontSize(14).fontColor(C_TEXT).fontWeight(FontWeight.Medium)
        Text(this.bootError)
          .fontSize(11)
          .fontColor(C_TEXT_WEAK)
          .margin({ top: 8 })
          .textAlign(TextAlign.Center)
          .padding({ left: 40, right: 40 })
        Text('可以重启应用再试一次')
          .fontSize(11)
          .fontColor(C_TEXT_WEAK)
          .margin({ top: 10 })
      } else {
        Text('正在读取本地课表…').fontSize(12).fontColor(C_TEXT_WEAK)
      }
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }
}

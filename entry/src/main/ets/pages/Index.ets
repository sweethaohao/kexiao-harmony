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
import {
  DailyBrief, DayCell, DayCourse, ImportResult, PeriodKey, ScheduleItem,
  Semester, SlotTime, WeekView, WeekViewDay
} from '../model/Models';
import { createDefaultTimeTable, DEFAULT_SEMESTER_START } from '../model/Defaults';
import { DateUtil } from '../common/DateUtil';
import { SlotTimeTable } from '../common/SlotTimeTable';
import { ScheduleService } from '../service/ScheduleService';
import { ImportService } from '../service/ImportService';

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

/** 侧栏导航项 */
interface NavItem {
  glyph: string;
  label: string;
}

const NAV_ITEMS: NavItem[] = [
  { glyph: '周', label: '本周课表' },
  { glyph: '今', label: '今明日程' },
  { glyph: '导', label: '导入课表' },
  { glyph: '设', label: '作息设置' }
];

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
  @State navIndex: number = 0;
  @State collapsed: boolean = false;
  @State week: number = 1;

  // ---- 学期配置（后续会做成可编辑并持久化） ----
  @State semesterStart: string = DEFAULT_SEMESTER_START;
  @State totalWeeks: number = 16;

  // ---- 导入反馈 ----
  @State importSource: string = '';
  @State importSummary: string = '';
  @State importWarnings: string[] = [];
  @State statusText: string = '';

  private timeTable: SlotTimeTable = createDefaultTimeTable();
  private service: ScheduleService = new ScheduleService(createDefaultTimeTable());

  aboutToAppear(): void {
    this.slotList = this.timeTable.all();
    // 刻意「不」在这里自动灌入示例数据：第一次打开就该是空态，
    // 要不要有数据由用户点「载入示例课表」或去「导入课表」决定。
    // （早期版本每次启动都无条件加载内置课表，导致"首次打开"这个状态根本测不出来。）
    this.refreshAll();
  }

  // =========================================================================
  // 业务动作
  // =========================================================================

  /**
   * 读取随应用打包的「示例课表」。
   * 数据在 resources/rawfile/sample-schedule.json，是**虚构数据**，
   * 只为了让用户在还没导入自己课表时也能看到界面长什么样。
   * ⚠️ 这个文件绝不能放任何真实课表 —— 它会随安装包发给所有用户。
   */
  private loadSampleSchedule(): void {
    try {
      // 通过 UIContext 拿宿主 Context（API 18 之后 getContext 已废弃，用这个写法）
      const ctx = this.getUIContext().getHostContext() as common.Context;
      const bytes: Uint8Array = ctx.resourceManager.getRawFileContentSync('sample-schedule.json');
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      const text: string = decoder.decodeToString(bytes).replace(/^\uFEFF/, '');

      const result: ImportResult = ImportService.parse(text);
      if (!result.ok) {
        this.statusText = `读取示例课表失败：${result.error}`;
        return;
      }
      this.applyImport(result);
      this.statusText = `已载入示例课表：${result.items.length} 条排课`;
    } catch (err) {
      this.statusText = `读取示例课表失败：${JSON.stringify(err)}`;
      hilog.error(DOMAIN, TAG, 'load sample failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 把导入结果灌进界面状态 */
  private applyImport(result: ImportResult): void {
    this.items = result.items;
    this.importSource = result.source;
    this.importSummary = `${result.items.length} 条排课 · ${result.courses.length} 门课程 · 共 ${result.totalWeeks} 周`;
    this.importWarnings = result.warnings;
    if (result.totalWeeks > 0) {
      this.totalWeeks = result.totalWeeks;
    }
    // 打开应用时定位到"当前周"
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
    if (this.navIndex === 0) {
      return '本周课表';
    }
    if (this.navIndex === 1) {
      return '今明日程';
    }
    if (this.navIndex === 2) {
      return '导入课表';
    }
    return '作息设置';
  }

  private pageSubtitle(): string {
    if (this.navIndex === 0) {
      return `${this.weekView.rangeLabel}　共 ${this.weekView.courseCount} 节课`;
    }
    if (this.navIndex === 1) {
      return this.brief.hint;
    }
    if (this.navIndex === 2) {
      return '把教务导出的课表变成课晓的日程';
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

        if (this.navIndex === 0) {
          this.buildWeekPage()
        } else if (this.navIndex === 1) {
          this.buildBriefPage()
        } else if (this.navIndex === 2) {
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
      if (index === 0 || index === 1) {
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

      if (this.navIndex === 0) {
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

      if (this.navIndex === 1) {
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
        this.buildEmptyState()
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
      // 概要卡
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
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 20, right: 20, bottom: 12 })
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
    Scroll() {
      Column() {
        this.buildInfoCard('怎么导入课表',
          '课晓不会去"爬"教务系统，而是由你把教务导出的 Word 课表交给电脑侧脚本，' +
            '脚本把它转成课晓认识的 JSON，再由应用导入。这样既合规，也能适配不同学校。')

        Row() {
          Column() {
            Text('当前数据').fontSize(11).fontColor(C_TEXT_WEAK)
            Text(this.importSource.length > 0 ? this.importSource : '尚未导入')
              .fontSize(13)
              .fontColor(C_TEXT)
              .margin({ top: 6 })
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Text(this.importSummary.length > 0 ? this.importSummary : '—')
              .fontSize(11)
              .fontColor(C_TEXT_SUB)
              .margin({ top: 6 })
              .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Text('载入示例课表')
            .fontSize(12)
            .fontColor(C_PRIMARY)
            .height(30)
            .padding({ left: 14, right: 14 })
            .borderRadius(8)
            .backgroundColor(C_PRIMARY_SOFT)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.loadSampleSchedule();
            })
        }
        .width('100%')
        .padding(16)
        .margin({ top: 12 })
        .borderRadius(12)
        .backgroundColor(C_SURFACE)
        .border({ width: 1, color: C_BORDER })
        .alignItems(VerticalAlign.Center)

        if (this.statusText.length > 0) {
          Row() {
            Text(this.statusText).fontSize(11).fontColor(C_TEXT_SUB)
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 9, bottom: 9 })
          .margin({ top: 12 })
          .borderRadius(8)
          .backgroundColor(C_PRIMARY_SOFT)
        }

        if (this.importWarnings.length > 0) {
          Column() {
            Text('导入提示').fontSize(12).fontWeight(FontWeight.Medium).fontColor(C_WARN_TEXT)
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

        Column() {
          this.buildInfoCard('接下来会做',
            '① 支持在自己电脑上选文件导入（而不是只读内置示例）；' +
              '② 支持粘贴作业网页链接，自动读取标题与截止时间；' +
              '③ 导入后写入本地数据库，重开应用数据不会丢。')
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
          }
          .width('100%')
          .margin({ top: 12 })

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
            '这一页的数字后续都会变成可编辑项：学期起始日、每节课时长、课间、午休/晚休起止，' +
              '改完立刻重算周视图与提醒。目前它们取自 model/Defaults.ets 里的默认值。')
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
  buildEmptyState() {
    Column() {
      Text('还没有课表数据').fontSize(14).fontColor(C_TEXT).fontWeight(FontWeight.Medium)
      Text('去「导入课表」导入自己的课表，或先载入示例数据看看界面')
        .fontSize(11)
        .fontColor(C_TEXT_WEAK)
        .margin({ top: 8 })

      Text('载入示例课表')
        .fontSize(13)
        .fontColor(Color.White)
        .fontWeight(FontWeight.Medium)
        .height(38)
        .padding({ left: 22, right: 22 })
        .borderRadius(10)
        .backgroundColor(C_PRIMARY)
        .textAlign(TextAlign.Center)
        .margin({ top: 18 })
        .onClick(() => {
          this.loadSampleSchedule();
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }
}

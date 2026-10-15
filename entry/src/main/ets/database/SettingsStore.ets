/**
 * 课晓 · 轻量设置存储（SettingsStore）
 * ---------------------------------------------------------------------------
 * 用首选项（preferences）存"一整块配置"，不存课表数据。
 *
 * 为什么作息参数不放进数据库？
 *   它是「一整个对象数组」，永远是整存整取，不存在"按条件查第 3 节是几点"的需求。
 *   这种形状的数据用键值对最省事，用数据库反而要额外建表、额外写映射。
 *   分工是：数据库管"会越来越多、要被查询"的课表；首选项管"就这一份"的配置。
 *
 * ⚠️ 存进首选项的是 JSON 文本，读回来 JSON.parse 得到的键名是原文，
 *    而 release 混淆会改属性名 —— 所以 PeriodConfig 的字段名
 *    必须在 obfuscation-rules.txt 的 -keep-property-name 清单里。
 *    漏一个，上架后"改作息不生效"这种问题只在 release 包复现，极难查。
 *
 * 另一个细节：传给系统接口的对象字面量，键一律写成带引号的字符串
 * （{ 'name': ... }）。字符串字面量形式属性名不参与混淆，是零成本的保险。
 *
 * 首选项读写失败不该让应用崩掉 —— 作息参数有默认值兜底，
 * 所以这里每一处都兜住异常、记日志、退回默认行为。
 * ---------------------------------------------------------------------------
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PeriodConfig } from '../model/Models';

const DOMAIN: number = 0x0000;
const TAG: string = 'kexiao-pref';

/** 首选项文件名 */
const PREF_NAME: string = 'kexiao_settings';

/** 键名。参数是字符串字面量，不受属性名混淆影响 */
const KEY_PERIODS: string = 'periodConfigs';
const KEY_COLLAPSED: string = 'sidebarCollapsed';

export class SettingsStore {
  /** 进程内缓存，避免每次读写都重新打开文件 */
  private static pref: preferences.Preferences | undefined = undefined;

  /**
   * 打开（或复用）首选项文件。
   * 打开后所有读写都走本类的静态方法，调用方不用自己拿着 Preferences 对象传进传出。
   */
  static open(context: common.Context): void {
    if (SettingsStore.pref !== undefined) {
      return;
    }
    try {
      SettingsStore.pref = preferences.getPreferencesSync(context, { 'name': PREF_NAME });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'open preferences failed: %{public}s', JSON.stringify(err));
    }
  }

  // -------------------------------------------------------------------------
  // 作息参数
  // -------------------------------------------------------------------------

  /** 读取作息参数；用户从没改过时返回空数组，由调用方决定用不用默认值 */
  static loadPeriodConfigs(): PeriodConfig[] {
    const p: preferences.Preferences | undefined = SettingsStore.pref;
    if (p === undefined) {
      return [];
    }
    let v: preferences.ValueType = '';
    try {
      v = p.getSync(KEY_PERIODS, '');
    } catch (err) {
      return [];
    }
    if (typeof v !== 'string' || v.length === 0) {
      return [];
    }
    let parsed: PeriodConfig[];
    try {
      parsed = JSON.parse(v) as PeriodConfig[];
    } catch (e) {
      return [];
    }
    if (!Array.isArray(parsed) || parsed.length === 0) {
      return [];
    }
    return parsed;
  }

  /** 写入作息参数 */
  static savePeriodConfigs(configs: PeriodConfig[]): void {
    const p: preferences.Preferences | undefined = SettingsStore.pref;
    if (p === undefined) {
      return;
    }
    try {
      p.putSync(KEY_PERIODS, JSON.stringify(configs));
      p.flush();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'save periods failed: %{public}s', JSON.stringify(err));
    }
  }

  // -------------------------------------------------------------------------
  // 界面偏好
  // -------------------------------------------------------------------------

  /** 侧栏是否收起 */
  static loadCollapsed(): boolean {
    const p: preferences.Preferences | undefined = SettingsStore.pref;
    if (p === undefined) {
      return false;
    }
    let v: preferences.ValueType = false;
    try {
      v = p.getSync(KEY_COLLAPSED, false);
    } catch (err) {
      return false;
    }
    return typeof v === 'boolean' ? v : false;
  }

  static saveCollapsed(collapsed: boolean): void {
    const p: preferences.Preferences | undefined = SettingsStore.pref;
    if (p === undefined) {
      return;
    }
    try {
      p.putSync(KEY_COLLAPSED, collapsed);
      p.flush();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'save collapsed failed: %{public}s', JSON.stringify(err));
    }
  }
}

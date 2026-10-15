/**
 * 课晓 · 数据库开关（RdbHelper）
 * ---------------------------------------------------------------------------
 * 全工程**唯一**调用 relationalStore.getRdbStore 的地方。
 * 好处：库开在哪、版本怎么升、表什么时候建，只有一个答案。
 *
 * 为什么用关系型数据库（RDB）而不是首选项？
 *   课表是结构化的、将来要按条件查（本周有哪些课、某门课都在哪天），
 *   而且后面还要挂上作业与提醒 —— 这些天生是"表"的形状。
 *   首选项只用来存一小块配置（作息参数），见 SettingsStore。
 *
 * 库文件落在应用沙箱内，不随安装包分发，也不会上传。
 * ---------------------------------------------------------------------------
 */

import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CREATE_TABLES, DB_NAME, DB_VERSION } from './DbConstants';

const DOMAIN: number = 0x0000;
const TAG: string = 'kexiao-db';

export class RdbHelper {
  /** 进程内缓存：一个应用只开一次库 */
  private static store: relationalStore.RdbStore | undefined = undefined;

  /**
   * 打开（或复用）数据库，并确保表结构就绪。
   * 首次调用会真正建库建表；之后直接返回缓存。
   */
  static async open(context: common.Context): Promise<relationalStore.RdbStore> {
    const cached: relationalStore.RdbStore | undefined = RdbHelper.store;
    if (cached !== undefined) {
      return cached;
    }

    // 键写成带引号的字符串：字符串字面量形式的属性名不参与混淆，是零成本的保险
    const config: relationalStore.StoreConfig = {
      'name': DB_NAME,
      'securityLevel': relationalStore.SecurityLevel.S1
    };
    const store: relationalStore.RdbStore = await relationalStore.getRdbStore(context, config);

    // ---- 版本迁移 ----
    // 首次建库时 store.version 是 0。表结构以后要是变了，
    // 在这里按 oldVersion 追加 "if (oldVersion < 2) { ALTER TABLE ... }" 分支，
    // 不要改动已经发出去的老版本的建表语句。
    const oldVersion: number = store.version;
    if (oldVersion !== DB_VERSION) {
      hilog.info(DOMAIN, TAG, 'db version %{public}d -> %{public}d', oldVersion, DB_VERSION);
      store.version = DB_VERSION;
    }

    // 建表语句全带 IF NOT EXISTS，所以每次启动无脑执行一遍即可，
    // "首次安装"和"以后每次启动"共用同一条路径。
    for (let i = 0; i < CREATE_TABLES.length; i++) {
      await store.executeSql(CREATE_TABLES[i]);
    }

    RdbHelper.store = store;
    hilog.info(DOMAIN, TAG, 'database ready: %{public}s', DB_NAME);
    return store;
  }

  /** 取已经开好的库；还没开过则返回 undefined（调用方应先用 open） */
  static current(): relationalStore.RdbStore | undefined {
    return RdbHelper.store;
  }

  /** 关闭并清掉缓存（一般只在测试或极端场景用） */
  static async close(): Promise<void> {
    const cached: relationalStore.RdbStore | undefined = RdbHelper.store;
    if (cached === undefined) {
      return;
    }
    RdbHelper.store = undefined;
    await cached.close();
  }
}

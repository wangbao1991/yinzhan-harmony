import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

/**
 * 轻量键值存储。统一在一处初始化，避免每个 store 各拿一份 preferences 实例。
 */
export class Store {
  private static instance: Store = new Store();
  private pref: preferences.Preferences | null = null;
  private ready: boolean = false;

  static get(): Store {
    return Store.instance;
  }

  /**
   * 冷启动最早点（EntryAbility.onCreate）同步装配已有的 Preferences 实例。
   * onForeground 的心跳会早于 App.init() 触发登录态读取，若此时 Store 还未就绪，
   * 各账号单例会把「空凭证」用 ready=true 永久锁死，表现为每次重启都要重新登录。
   */
  attach(pref: preferences.Preferences): void {
    if (this.pref === null) {
      this.pref = pref;
    }
    this.ready = true;
  }

  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.ready) {
      return;
    }
    try {
      // 同步 API：本函数返回时 pref 必定可用，不留 await 窗口给 onForeground 抢跑。
      // App.init 仍保留 await 调用（既有自检断言要求），行为完全兼容。
      this.pref = preferences.getPreferencesSync(context, { name: 'yinzhan_v1' });
      this.ready = true;
    } catch (e) {
      console.error('[Store] 初始化失败 ' + String(e));
    }
  }

  isReady(): boolean {
    return this.ready;
  }

  getString(key: string, def: string = ''): string {
    if (this.pref === null) {
      return def;
    }
    const value = this.pref.getSync(key, def);
    return typeof value === 'string' ? value : def;
  }

  getBool(key: string, def: boolean = false): boolean {
    if (this.pref === null) {
      return def;
    }
    const value = this.pref.getSync(key, def);
    return typeof value === 'boolean' ? value : def;
  }

  getNumber(key: string, def: number = 0): number {
    if (this.pref === null) {
      return def;
    }
    const value = this.pref.getSync(key, def);
    return typeof value === 'number' ? value : def;
  }

  /**
   * 写入并立即同步落盘。原来用异步 flush().catch(() => {})：
   * 进程被系统回收 / 用户划掉卡片时，异步任务可能尚未完成，异常又被吞掉，
   * 于是登录凭证「看着存了、重启就没了」。flushSync 为 API 26 已声明的同步接口，
   * 调用返回即已写盘；失败必须留日志，不能静默。
   */
  private persist(): void {
    if (this.pref === null) {
      return;
    }
    try {
      this.pref.flushSync();
    } catch (e) {
      console.error('[Store] 落盘失败 ' + String(e));
    }
  }

  put(key: string, value: string | boolean | number): void {
    if (this.pref === null) {
      return;
    }
    this.pref.putSync(key, value);
    this.persist();
  }

  putLater(key: string, value: string | boolean | number): void {
    if (this.pref === null) {
      return;
    }
    this.pref.putSync(key, value);
  }

  flush(): void {
    this.persist();
  }

  delete(key: string): void {
    if (this.pref !== null) {
      this.pref.deleteSync(key);
      this.persist();
    }
  }
}

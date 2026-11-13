import { SheetInfo } from '../common/Models';
import { Library } from './Library';
import { WyAccount } from './WyAccount';
import { WyFavSync } from './WyFavSync';

/**
 * 「歌单收藏 ↔ 网易云账号」同步协调层（v1.0）。
 *
 * v1.0 变更：QQ 音乐 / 酷狗的「本人账号登录 + 扫码 + 云端收藏读写」整套引擎
 * 已连根删除。v2.71 起账号页就只保留网易云，那批代码一直只是隐藏、没人再引用，
 * 白占体积。现在本层只代理 WyFavSync 一路，把统一的 status / label / toastText、
 * 手动等待对账、前台实时心跳留下来 —— 三处 UI 和一个生命周期挂载点都不需要
 * 知道底层少了两个平台。
 *
 * 边界必须说清楚：这里的「删除」只针对**账号登录体系**。
 * tx(QQ音乐) / kg(酷狗音乐) 作为**音源平台**仍然完整保留：PlatformApi 的搜索、
 * 封面、歌单广场，LxRunner 音源脚本，发现页的 tx/kg 板块，以及用户在本地已收藏的
 * tx/kg 歌单数据，一个都不动、一个都不删。
 */

/** 聚合后的同步状态快照。UI 只认这一份，不再各自拼判断。 */
export interface FavSyncStatus {
  loggedIn: boolean;  // 账号已登录
  syncing: boolean;   // 正在对账
  failed: boolean;    // 对账失败
  auto: number;       // 可自动重试的待写云端项
  manual: number;     // 需去平台 APP 处理/重登的官方受限项
  at: number;         // 最近一次「真正干净」同步时间戳
  clean: boolean;     // 只有全部条件同时成立才为 true
}

/** 前台心跳间隔：纯客户端收不到平台推送，靠周期性对账把云端→本地延迟压到秒级 */
const HEARTBEAT_MS: number = 12000;

export class FavSyncHub {
  private static instance: FavSyncHub = new FavSyncHub();

  static get(): FavSyncHub {
    return FavSyncHub.instance;
  }

  private started: boolean = false;

  /**
   * App.init 里 Store 就绪后调用一次。
   * WyFavSync 的凭证读回 / 待同步队列恢复由 App.init 单独完成，这里只留启动标记，
   * 保证历史调用点不空转、也不重复注册钩子。
   */
  init(): void {
    if (this.started) {
      return;
    }
    this.started = true;
  }

  /** 收藏变更入口：现在只有网易云一路（tx/kg 歌单仍可本地收藏，只是不再同步云端账号） */
  onLocalChange(sheet: SheetInfo, added: boolean): void {
    const plat = Library.syncPlatform(sheet);
    if (plat === 'wy') {
      WyFavSync.get().onLocalChange(sheet, added);
    }
  }

  /** 进页 / 回前台 / 手动同步：只跑网易云一路对账 */
  async reconcileAll(): Promise<void> {
    WyFavSync.get().reconcile().catch(() => {
    });
  }

  /** 汇总可自动重试的待同步项数 */
  pendingCount(): number {
    return WyFavSync.get().pendingCount();
  }

  /** 汇总官方受限、需去平台 APP 内处理的项数 */
  manualCount(): number {
    return WyFavSync.get().manualCount();
  }

  /** 是否至少有一个账号已登录 */
  anyLoggedIn(): boolean {
    return WyAccount.get().isLoggedIn();
  }

  /* ---------------- 统一状态聚合：UI 唯一的结论来源 ---------------- */

  /**
   * 汇总一份「真实同步状态」。scope 兼容历史的 'all' / 'wy' / 'qq' / 'kg'：
   * 后两个平台已删除，返回中性空态，旧调用点不会崩也不会误报「已同步」。
   *
   * 只读、不触发广播：可以在 build 里安全反复调用。
   * clean 刻意严格：已登录 + 无在途 + 无失败 + 状态 ok + 队列真的清空 +
   * 有过一次成功同步，才允许说「已与账号同步」。
   */
  status(scope: string): FavSyncStatus {
    const empty: FavSyncStatus = {
      loggedIn: false, syncing: false, failed: false,
      auto: 0, manual: 0, at: 0, clean: false
    };
    if (scope !== 'all' && scope !== 'wy') {
      return empty;
    }
    const wy = WyFavSync.get();
    wy.ensureReady();
    let loggedIn = false;
    let syncing = false;
    let failed = false;
    let everyOk = true;
    let auto = 0;
    let manual = 0;
    let at = 0;
    const st = wy.peekState();
    if (st !== 'guest') {
      loggedIn = true;
      if (st === 'syncing') {
        syncing = true;
      } else if (st === 'fail') {
        failed = true;
      } else if (st !== 'ok') {
        everyOk = false;
      }
      auto = wy.peekPending();
      manual = wy.peekManual();
      at = wy.peekAt();
    }
    const clean = loggedIn && !syncing && !failed && everyOk &&
      auto === 0 && manual === 0 && at > 0;
    const result: FavSyncStatus = {
      loggedIn: loggedIn, syncing: syncing, failed: failed,
      auto: auto, manual: manual, at: at, clean: clean
    };
    return result;
  }

  /**
   * 状态条文案（唯一实现）。铁律：只要 auto>0 / manual>0 / failed / syncing，
   * 绝不出现「已同步 / 已一致」；「已与账号同步 HH:mm」只在 clean 分支出现。
   */
  label(scope: string): string {
    const s = this.status(scope);
    if (!s.loggedIn) {
      return '登录平台账号，收藏会与歌单实时同步';
    }
    // 受限项优先于 syncing：心跳每 12s 会把状态打回 syncing，若让 syncing 抢先，
    // 受限项就会永远显示「正在与平台同步…」，用户看不出要去处理。
    if (s.manual > 0) {
      return s.manual.toString() + ' 项需在平台 APP 内处理' +
        (s.auto > 0 ? ' · 另有 ' + s.auto.toString() + ' 项正在重试' : '');
    }
    if (s.syncing) {
      return '正在与平台同步…' + FavSyncHub.undoneTail(s);
    }
    if (s.failed) {
      return '部分平台同步失败，点此重试' + FavSyncHub.undoneTail(s);
    }
    if (s.auto > 0) {
      return s.auto.toString() + ' 项未同步，正在自动重试';
    }
    if (s.clean) {
      return '已与账号同步 ' + FavSyncHub.hhmm(s.at);
    }
    return '点此同步账号收藏';
  }

  /** 手动点同步后的结论：基于对账后的真实状态，绝不只看单平台中间结果 */
  toastText(scope: string): string {
    const s = this.status(scope);
    if (!s.loggedIn) {
      return '请先登录平台账号';
    }
    if (s.failed) {
      return '同步失败，请检查网络或重新登录';
    }
    if (s.manual > 0) {
      return '还有 ' + s.manual.toString() + ' 项需在平台 APP 内处理';
    }
    if (s.auto > 0) {
      return '还有 ' + s.auto.toString() + ' 项未同步，已排队自动重试';
    }
    if (s.clean) {
      return '歌单收藏已与账号一致';
    }
    return '正在同步，请稍候';
  }

  private static undoneTail(s: FavSyncStatus): string {
    if (s.auto === 0 && s.manual === 0) {
      return '';
    }
    let tail = '';
    if (s.auto > 0) {
      tail = ' · ' + s.auto.toString() + ' 项未同步';
    }
    if (s.manual > 0) {
      tail += ' · ' + s.manual.toString() + ' 项需 APP 端处理';
    }
    return tail;
  }

  private static hhmm(at: number): string {
    const d = new Date(at);
    const h = d.getHours();
    const m = d.getMinutes();
    const hh = h < 10 ? '0' + h.toString() : h.toString();
    const mm = m < 10 ? '0' + m.toString() : m.toString();
    return hh + ':' + mm;
  }

  /**
   * 手动同步：等这一轮对账真正跑完再让 UI 取结论，否则队列还没清空就会
   * 抢先报「已一致」。
   */
  async reconcileAllAwait(): Promise<void> {
    await WyFavSync.get().reconcile();
  }

  /* ---------------- 前台实时对账 ---------------- */

  private heartbeatOn: boolean = false;
  private heartbeatTimer: number = -1;

  /**
   * 应用在前台时每 HEARTBEAT_MS 拉一次云端。第三方平台不给第三方 App 推送，
   * 这是纯客户端能做到的「准实时」上限：用户在平台 APP 里改了收藏，
   * 停在音栈里最多十几秒就能自动看到。
   */
  startForegroundSync(): void {
    if (this.heartbeatOn) {
      return;
    }
    this.heartbeatOn = true;
    this.init();
    // 切回前台立刻对账一次：用户最关心的「刚在 APP 端改了」当场可见
    if (this.anyLoggedIn()) {
      this.reconcileAll().catch(() => {
      });
    }
    this.scheduleHeartbeat();
  }

  stopForegroundSync(): void {
    this.heartbeatOn = false;
    if (this.heartbeatTimer >= 0) {
      clearTimeout(this.heartbeatTimer);
      this.heartbeatTimer = -1;
    }
  }

  private scheduleHeartbeat(): void {
    if (!this.heartbeatOn) {
      return;
    }
    this.heartbeatTimer = setTimeout(() => {
      if (!this.heartbeatOn) {
        return;
      }
      if (this.anyLoggedIn()) {
        this.reconcileAll().catch(() => {
        });
      }
      this.scheduleHeartbeat();
    }, HEARTBEAT_MS);
  }
}

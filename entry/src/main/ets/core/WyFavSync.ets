import { SheetInfo, newSheet } from '../common/Models';
import { PrefKeys } from '../common/Constants';
import { Store } from './Store';
import { Library } from './Library';
import { WyAccount } from './WyAccount';
import { wyPost, wyFixCover } from './WyApi';

/**
 * 「歌单收藏」↔ 网易云账号 双向同步引擎（v2.65，v2.69 取消收藏受限治理）。
 *
 * 用户诉求：在音栈收藏/取消收藏网易云歌单，网易云 APP 里要跟着变；在网易云 APP
 * 里收藏/取消收藏的歌单，进音栈「歌单收藏」也要立刻有（或没有），状态必须对得上。
 *
 * 设计要点（正确性优先，不做「看起来同步」的假象）：
 *
 *  ① 云端是权威，但只在「明确拿到云端列表」时才对账。网络失败 / 未登录 /
 *     Cookie 过期一律返回 null，此时**一个本地收藏都不动**——断网清空收藏是
 *     最不能接受的事故。
 *
 *  ② 本地操作乐观更新 + 待同步队列（pending）。用户在详情页点收藏，UI 立刻变，
 *     同时把「这个 id 要 add / remove」记进 pending 并异步写云端；写失败保留在
 *     队列里，下次任意触发点重放。对账前先重放 pending，保证「本地刚收藏的」
 *     不会被云端旧列表反向删掉，也不会「点了收藏但账号里没有」。
 *
 *  ③ 按「纯数字歌单 id」比对，不用 Library.sheetKey（含 kind）。同一个网易云
 *     歌单从发现页(playlist) / 我的歌单(user) / 搜索页进来 kind 不同，按 sheetKey
 *     会被认成两张卡、来回抖动。用 id 归集顺带自愈历史重复项。
 *
 *  ④ 只同步 wy 平台、纯数字 id、kind 为 playlist/user 的歌单。其它平台歌单、
 *     榜单、专辑、本地自建歌单在网易云账号里没有对应实体，保持纯本地收藏，
 *     一个都不碰。
 *
 *  ⑤ pending / 云端快照 / 时间戳只落本机 Store，**不进备份白名单**（换机恢复时
 *     不应把同步中间态串到别的账号上），也不含任何凭证明文。
 *
 *  ⑥ v2.69 取消收藏改用独立 unsubscribe 路径（本轮真正修复点）。真实凭证实测
 *     （2026-11-13）：/weapi/playlist/subscribe 的 t=2 对已订阅歌单恒回 501、
 *     云端歌单仍在；换 id 类型 / Cookie 形态 / 参数写法 / 静置 100s 后均稳定 501，
 *     而无效 id 回 404、带 os=pc 回 405 —— 不是鉴权、不是频控，而是 t=2 这个
 *     老写法已被服务端弃用。官方 NeteaseCloudMusicApi 4.32.0 的 playlist_subscribe
 *     按 t 选两个独立路径：收藏 /weapi/playlist/subscribe、取消
 *     /weapi/playlist/unsubscribe，请求体只有 { id }。改用 unsubscribe 后实测可
 *     真正删除云端订阅（净零验证：临时收藏公开歌单 → 取消 → 云端列表 7→6、
 *     该歌单消失，账号回到起始状态）。
 *     501 三态与 blocked 降级保留为异常兜底：万一新路径在某账号/歌单仍被拒，
 *       · 绝不把 501 判成功出队——那会制造「本地已取消、账号里还在」的假同步；
 *       · 绝不每 12s 无限重放——那是永远消不掉的「N 项未同步，正在自动重试」；
 *       · 标为 blocked 从自动重试队列剥离，状态条如实提示去平台 APP 内处理；
 *       · 云端回读确认（cloudHas=false）后再出队收敛；重新登录时解冻重试。
 *     与酷狗取消收藏的 manual 降级同一套治理口径，不新造状态、不新增路由。
 *
 * 触发时机：进入歌单收藏页、App 回前台、登录成功、手动点同步、本地收藏/取消时。
 * 第三方 App 收不到网易云的即时推送，所以「实时」= 打开即对账，不是服务端推送。
 */

/** 待同步的一条本地意图：id 是网易云纯数字歌单 id */
interface WyFavOp {
  id: string;
  add: boolean;
  /** true = 云端明确拒绝该写操作（独立 unsubscribe 偶发 501 兜底）。不再自动重放、
   *  不计入「正在自动重试」，由状态条引导去平台 APP 内处理；云端回读确认
   *  目标状态达成后照常出队。落盘兼容旧数据（无此字段按 false 读）。 */
  blocked: boolean;
}

/** /weapi/user/playlist 的单条歌单（宽容解析，字段可能缺、类型可能变） */
interface WyFavRawSheet {
  id?: number;
  name?: string;
  coverImgUrl?: string;
  picUrl?: string;
  description?: string;
  copywriter?: string;
  trackCount?: number;
  playCount?: number;
  playcount?: number;
  updateTime?: number;
  /** true = 收藏的歌单；false / null = 自己创建的 */
  subscribed?: boolean;
  /** 歌单创建者 uid（列表接口里 creator 常是数字 uid，顶层 userId 更稳） */
  userId?: number;
  creator?: Object;
}

interface WyFavPlaylistResp {
  code?: number;
  more?: boolean;
  playlist?: WyFavRawSheet[];
}

interface WyFavCodeResp {
  code?: number;
}

/** 对账结果，供 UI 显示同步状态 */
export interface WyFavSyncResult {
  /** guest 未登录 / syncing 同步中 / ok 成功 / fail 失败 / idle 尚未同步 */
  state: string;
  /** 本次从云端补进来的歌单数 */
  added: number;
  /** 本次按云端移除的歌单数 */
  removed: number;
  /** 是否有待同步操作（写云端还没成功） */
  pending: number;
}

/** 云端一页最多取多少，账号歌单很多时分页拉全 */
const PAGE_LIMIT: number = 1000;
const MAX_PAGES: number = 4;

/**
 * 剔除 Cookie 里的 os=pc 字段，供云端写接口专用。
 *
 * 实测结论（2026-11-13，真实账号凭证对照）：带 os=pc 请求
 * /weapi/playlist/subscribe 恒返回 405「操作过于频繁，请稍后再试」；
 * 去掉该字段后同一请求返回 404（无效歌单 id）、200（明确写入成功）或
 * 501（服务端业务拒绝，见文件头 ⑥），即正常走到业务校验。
 * account/get、user/playlist 等读接口不受该字段影响。
 *
 * 之所以放在写调用处而不是 normalizeCookie()：已登录用户落盘的 Cookie
 * 是旧格式，改归一化逻辑对存量凭证无效，用户必须重新登录；在这里剔除
 * 则存量凭证无需任何操作即可生效。
 */
function stripPcOs(cookie: string): string {
  const parts = cookie.split(';');
  let out = '';
  for (const part of parts) {
    const p = part.trim();
    if (p.length === 0 || p.indexOf('os=') === 0) {
      continue;
    }
    out += (out.length > 0 ? '; ' : '') + p;
  }
  return out;
}

export class WyFavSync {
  private static instance: WyFavSync = new WyFavSync();

  static get(): WyFavSync {
    return WyFavSync.instance;
  }

  private ready: boolean = false;
  /** 待写云端的本地操作，按 id 去重（后一次覆盖前一次） */
  private pending: WyFavOp[] = [];
  /** 上一次成功对账后「本地 wy 歌单 id」快照：用来判断云端是新增还是移除 */
  private cloudIds: string[] = [];
  /** 是否已经有过一次成功对账；没有时只补不删，避免首次登录误删本地收藏 */
  private inited: boolean = false;
  private lastAt: number = 0;
  private versionNum: number = 0;
  private stateText: string = 'idle';
  private inFlight: boolean = false;
  /** flush 可能与对账并发（用户操作时正好在同步），加一把锁避免重复写云端 */
  private flushInFlight: boolean = false;

  /** 只读地确保队列/时间戳已从 Store 载入；不触发广播（供聚合层安全调用） */
  ensureReady(): void {
    // 就绪守卫：Store 未就绪时绝不锁存空队列，否则 onForeground 抢跑会把
    // 落盘的待同步项读成 0 并永久保留该结论，重启后「N 项未同步」错乱。
    if (this.ready || !Store.get().isReady()) {
      return;
    }
    this.ready = true;
    const s = Store.get();
    this.pending = WyFavSync.readOps(s.getString(PrefKeys.WY_FAV_PENDING, '[]'));
    this.cloudIds = WyFavSync.readIds(s.getString(PrefKeys.WY_FAV_CLOUD, '[]'));
    this.inited = s.getBool(PrefKeys.WY_FAV_INIT, false);
    this.lastAt = s.getNumber(PrefKeys.WY_FAV_AT, 0);
    // 启动首帧不继承 ok：lastAt 只用于显示时间，状态等本轮真实对账跑完再定
    this.stateText = WyAccount.get().isLoggedIn() ? 'idle' : 'guest';
  }

  /** Store 就绪后调用一次；重复调用只广播不重读 */
  init(): void {
    this.ensureReady();
    this.broadcast();
  }

  private broadcast(): void {
    this.versionNum += 1;
    AppStorage.setOrCreate('wyFavSyncVersion', this.versionNum);
    AppStorage.setOrCreate('wyFavSyncState', this.stateText);
    AppStorage.setOrCreate('wyFavSyncAt', this.lastAt);
  }

  isLoggedIn(): boolean {
    return WyAccount.get().isLoggedIn();
  }

  state(): string {
    this.init();
    return this.stateText;
  }

  lastSyncAt(): number {
    this.init();
    return this.lastAt;
  }

  /** 仍可自动重试的待写云端项数（不含服务端明确拒绝的 blocked 项） */
  pendingCount(): number {
    this.init();
    let n = 0;
    for (const op of this.pending) {
      if (!op.blocked) {
        n += 1;
      }
    }
    return n;
  }

  /** 服务端明确拒绝、需在平台 APP 内手动处理的项数（unsubscribe 偶发 501 兜底） */
  manualCount(): number {
    this.init();
    let n = 0;
    for (const op of this.pending) {
      if (op.blocked) {
        n += 1;
      }
    }
    return n;
  }

  /** 纯读快照：给 FavSyncHub 聚合层用，不触发 init / broadcast */
  peekState(): string {
    return this.stateText;
  }

  peekAt(): number {
    return this.lastAt;
  }

  peekPending(): number {
    let n = 0;
    for (const op of this.pending) {
      if (!op.blocked) {
        n += 1;
      }
    }
    return n;
  }

  peekManual(): number {
    let n = 0;
    for (const op of this.pending) {
      if (op.blocked) {
        n += 1;
      }
    }
    return n;
  }

  peekLoggedIn(): boolean {
    return WyAccount.get().isLoggedIn();
  }

  /* ---------------- 本地变更：乐观更新 + 待同步队列 ---------------- */

  /**
   * Library 的 wyFavHook 回调。sheet 已经在 Library 里落盘并广播过了，
   * 这里只负责把「这个 id 要 add / remove」记进队列并异步推到云端。
   * 未登录时也要入队：用户登录后由 onLoginSuccess 重放，收藏不会丢。
   */
  onLocalChange(sheet: SheetInfo, added: boolean): void {
    this.init();
    const id = Library.wySyncId(sheet);
    if (id.length === 0) {
      return;
    }
    // 同一 id 只保留最后一次意图：连点收藏/取消不会堆一串互相抵消的操作；
    // 重新收藏同一张歌单也会自然清掉之前的 blocked 标记，重新获得写云端机会。
    const keep: WyFavOp[] = [];
    for (const op of this.pending) {
      if (op.id !== id) {
        keep.push(op);
      }
    }
    keep.push({ id: id, add: added, blocked: false });
    this.pending = keep;
    this.savePending();
    this.broadcast();
    if (WyAccount.get().isLoggedIn()) {
      // 写完立刻回读云端确认，真的落到账号里才收口；失败保留队列等待重放
      this.flush().then(() => {
        this.reconcile().catch(() => {
        });
      }).catch(() => {
      });
    }
  }

  /** 登录成功：解冻受限项 + 重放队列 + 一次完整对账，把账号收藏的歌单补进本地 */
  onLoginSuccess(): void {
    this.init();
    this.stateText = 'idle';
    // 重新登录 = 换了一份凭证（可能是扫码拿到的更完整登录态）。此前被服务端
    // 稳定拒绝的取消收藏值得再试一次，解冻所有 blocked 项，由本轮 flush 重放。
    // 若新凭证仍被拒，会再次标回 blocked，不会比不试更差。
    const next: WyFavOp[] = [];
    for (const op of this.pending) {
      next.push({ id: op.id, add: op.add, blocked: false });
    }
    this.pending = next;
    this.savePending();
    this.reconcile().catch(() => {
    });
  }

  /**
   * 退出登录：只清同步中间态（pending / 云端快照），**不清本地收藏**。
   * 本地歌单是用户自己的数据；只是暂时不再与账号对齐。
   */
  onLogout(): void {
    this.init();
    this.pending = [];
    this.cloudIds = [];
    this.inited = false;
    this.lastAt = 0;
    const s = Store.get();
    s.put(PrefKeys.WY_FAV_PENDING, '[]');
    s.put(PrefKeys.WY_FAV_CLOUD, '[]');
    s.put(PrefKeys.WY_FAV_INIT, false);
    s.put(PrefKeys.WY_FAV_AT, 0);
    this.stateText = 'guest';
    this.broadcast();
  }

  /**
   * 完整对账：进入收藏页 / 回前台 / 登录 / 手动同步都走这里。
   * 顺序：重放 pending → 拉云端订阅列表 → 按 id 差量 → 一次落盘一次广播。
   */
  async reconcile(): Promise<WyFavSyncResult> {
    this.init();
    if (!WyAccount.get().isLoggedIn()) {
      this.stateText = 'guest';
      this.broadcast();
      return { state: 'guest', added: 0, removed: 0, pending: this.pending.length };
    }
    if (this.inFlight) {
      return { state: 'syncing', added: 0, removed: 0, pending: this.pending.length };
    }
    this.inFlight = true;
    this.stateText = 'syncing';
    this.broadcast();
    try {
      // 1) 先重放本地待同步操作；失败的仍留在队列，绝不静默丢
      await this.flush();

      // 2) 拉云端订阅列表。null = 明确失败，直接收手，本地一个字都不改
      const cloud = await this.fetchSubscribed();
      if (cloud === null) {
        this.stateText = 'fail';
        this.broadcast();
        return { state: 'fail', added: 0, removed: 0, pending: this.pending.length };
      }

      // 3) 按纯数字 id 做差量
      const cloudIds: string[] = [];
      for (const sheet of cloud) {
        cloudIds.push(sheet.id);
      }
      const localIds = Library.get().wyFavoriteIds();
      // blocked 项也留在 pendingIds 里：用户本地已取消、云端还没删的这段时间，
      // 绝不能让云端旧列表把这张歌单重新加回本地收藏（否则「取消」会自己弹回来）。
      const pendingIds: string[] = [];
      for (const op of this.pending) {
        pendingIds.push(op.id);
      }

      const addSheets: SheetInfo[] = [];
      for (const sheet of cloud) {
        // pending 里的 id 由 flush 负责，对账不碰，避免把刚收藏的删/重复加
        if (localIds.indexOf(sheet.id) < 0 && pendingIds.indexOf(sheet.id) < 0) {
          addSheets.push(sheet);
        }
      }

      const removeIds: string[] = [];
      if (this.inited) {
        // 只有「上一次云端有、这一次云端没有了」才算 APP 端取消收藏。
        // 首次对账（inited=false）只补不删，防止历史本地收藏被误清。
        for (const id of this.cloudIds) {
          if (cloudIds.indexOf(id) < 0 && localIds.indexOf(id) >= 0 &&
            pendingIds.indexOf(id) < 0 && removeIds.indexOf(id) < 0) {
            removeIds.push(id);
          }
        }
      }

      // 云端回读确认：用户去 APP 端手动处理过的项，云端列表会给出真实结果，
      // 这时把对应队列项出队，队列才能真正归零、状态才能转 clean。
      // blocked 项同样走这里：只有云端真的不含该 id，才承认取消已生效。
      const confirmed: string[] = [];
      for (const op of this.pending) {
        const cloudHas = cloudIds.indexOf(op.id) >= 0;
        if ((op.add && cloudHas) || (!op.add && !cloudHas)) {
          confirmed.push(op.id);
        }
      }
      if (confirmed.length > 0) {
        this.pending = this.pending.filter((it: WyFavOp): boolean => confirmed.indexOf(it.id) < 0);
        this.savePending();
      }

      // 一次落盘一次广播：applyWyFavSync 内部走 Library.notify()，
      // 首页计数 / 详情页按钮 / 卡片角标 / 收藏页列表四处一起刷新。
      Library.get().applyWyFavSync(addSheets, removeIds);

      // 4) 更新云端快照 + 时间戳，一次落盘
      this.cloudIds = cloudIds;
      this.inited = true;
      const s = Store.get();
      s.put(PrefKeys.WY_FAV_CLOUD, JSON.stringify(this.cloudIds));
      s.put(PrefKeys.WY_FAV_INIT, true);
      // v2.67：只有「云端读成功 + 待同步队列真的清空」才算 ok，并推进时间戳。
      // 之前只要拉到列表就标 ok，导致「已与账号同步 · 1 项待上传」的假状态。
      if (this.pending.length === 0) {
        this.lastAt = Date.now();
        s.put(PrefKeys.WY_FAV_AT, this.lastAt);
        this.stateText = 'ok';
      } else {
        this.stateText = 'partial';
      }
      this.broadcast();
      return {
        state: this.stateText,
        added: addSheets.length,
        removed: removeIds.length,
        pending: this.pending.length
      };
    } catch (e) {
      this.stateText = 'fail';
      this.broadcast();
      return { state: 'fail', added: 0, removed: 0, pending: this.pending.length };
    } finally {
      this.inFlight = false;
    }
  }

  /* ---------------- 云端写：/weapi/playlist/subscribe ---------------- */

  /**
   * 把 pending 逐条写到云端；ok 出队，retry 保留，restricted 标 blocked 剥离。
   *
   * 前台心跳每 12s 会走一次 flush。被服务端明确拒绝的项若继续重放，只会
   * 持续打一个注定失败的接口，并把「N 项未同步，正在自动重试」永远挂在界面上。
   * blocked 项仍留在 pending 里，等云端回读确认（用户去 APP 端处理）后出队。
   */
  private async flush(): Promise<void> {
    if (this.flushInFlight || !WyAccount.get().isLoggedIn() || this.pending.length === 0) {
      return;
    }
    this.flushInFlight = true;
    try {
      const cookie = WyAccount.get().cookie();
      // 逐条快照成一份副本：循环中若用户又点了收藏，新的意图会进 this.pending，
      // 本轮只处理开始时那批，新意图留到下一轮，不会被本轮结果覆盖掉。
      const batch: WyFavOp[] = this.pending.slice();
      for (const op of batch) {
        if (op.blocked) {
          continue;
        }
        const verdict = await this.subscribe(op.id, op.add, cookie);
        // ok 只代表明确写成功；retry 与 restricted 都不出队，
        // 队列原样保留，绝不静默丢掉用户这次取消/收藏的意图。
        const ok: boolean = verdict === 'ok';
        if (ok) {
          this.pending = this.pending.filter((it: WyFavOp): boolean =>
            !(it.id === op.id && it.add === op.add));
          this.savePending();
          // 队列一变就广播：状态条立刻从「N 项未同步」收敛
          this.broadcast();
        } else if (verdict === 'restricted') {
          // 从自动重试队列剥离：不假成功、不无限重放，改为状态条引导去 APP 端。
          const next: WyFavOp[] = [];
          for (const it of this.pending) {
            if (it.id === op.id && it.add === op.add) {
              next.push({ id: it.id, add: it.add, blocked: true });
            } else {
              next.push(it);
            }
          }
          this.pending = next;
          this.savePending();
          this.broadcast();
        }
      }
    } finally {
      this.flushInFlight = false;
    }
  }

  /**
   * 收藏 / 取消收藏走两个独立路径。返回三态，绝不把「云端拒绝」含糊成成功：
   *
   *   'ok'         code=200 明确写入成功；或 add=true 且 code=501 —— 对已收藏
   *                歌单重复订阅返回 501，目标状态本来就已达成，可安全出队。
   *   'restricted' add=false 且 code=501 —— 独立 unsubscribe 偶发被拒（异常兜底）。
   *                绝不能判成功：那会制造「本地取消了、账号里还挂着」的假同步。
   *   'retry'      网络失败 / 301 未登录 / 404 无效 id / 405 频控等，保留队列重放。
   *
   * 为什么取消不用 /weapi/playlist/subscribe + t=2（本轮根因，见文件头 ⑥）：
   * 官方 NeteaseCloudMusicApi 4.32.0 的 playlist_subscribe 按 t 选两个路径，
   * 请求体只有 { id }；t=2 是已被服务端弃用的老写法。真实凭证实测：
   *   · 老写法 t=2 对已订阅歌单恒回 501，云端列表读回歌单仍在；
   *   · 独立 unsubscribe 对自建歌单回 400、对未订阅公开歌单回 200；
   *   · 端到端净零验证：临时收藏公开歌单 → unsubscribe → 云端列表 7→6、
   *     该歌单消失，账号回到起始状态。
   * 收藏沿用 t=1（实测对未订阅歌单回 200）；取消只带 id，带 t 会走回老分支。
   * 用字符串三态而不是 boolean / 联合类型，与工程既有 state 风格一致，ArkTS 最稳。
   */
  private async subscribe(id: string, add: boolean, cookie: string): Promise<string> {
    const path = add ? '/weapi/playlist/subscribe' : '/weapi/playlist/unsubscribe';
    const data: Record<string, Object> = add
      ? { 'id': id, 't': 1 }
      : { 'id': id };
    const reply = await wyPost(path, data, stripPcOs(cookie));
    if (!reply.ok || reply.body.length === 0) {
      return 'retry';
    }
    try {
      const resp = JSON.parse(reply.body) as WyFavCodeResp;
      const code = resp.code ?? -1;
      if (code === 200) {
        return 'ok';
      }
      if (code === 501) {
        // 订阅：对已收藏歌单重复订阅回 501，目标状态已达成，幂等出队。
        // 取消：独立 unsubscribe 正常应回 200；仍回 501 说明该次写被服务端拒绝，
        // 绝不能当成功，如实降级等云端回读确认。
        return add ? 'ok' : 'restricted';
      }
      return 'retry';
    } catch (e) {
      return 'retry';
    }
  }

  /* ---------------- 云端读：/weapi/user/playlist ---------------- */

  /**
   * 拉本人账号「收藏的歌单」。返回 null 表示失败（调用方必须停手、不动本地）。
   * 空数组是合法的「账号确实没有收藏歌单」，与失败严格区分。
   * 判定收藏：subscribed===true 优先；老接口该字段可能是 null，用
   * userId（歌单创建者）≠ 本人 uid 兜底。「我喜欢的音乐」等自建歌单不算收藏。
   */
  private async fetchSubscribed(): Promise<SheetInfo[] | null> {
    const account = WyAccount.get();
    const cookie = account.cookie();
    const uid = await this.resolveUid(cookie);
    // 拿不到本人 uid 时，/weapi/user/playlist 会回游客兜底列表。拿这份数据去
    // 对账等于「用别人的账号删自己的收藏」，必须视为失败、本地一个字都不动。
    if (uid <= 0) {
      return null;
    }
    const out: SheetInfo[] = [];
    const seen: string[] = [];
    for (let page = 0; page < MAX_PAGES; page++) {
      const data: Record<string, Object> = {
        'uid': uid,
        'limit': PAGE_LIMIT,
        'offset': page * PAGE_LIMIT
      };
      const reply = await wyPost('/weapi/user/playlist', data, cookie);
      if (!reply.ok || reply.body.length === 0) {
        return null;
      }
      let resp: WyFavPlaylistResp;
      try {
        resp = JSON.parse(reply.body) as WyFavPlaylistResp;
      } catch (e) {
        return null;
      }
      if ((resp.code ?? -1) !== 200) {
        return null;
      }
      const list = resp.playlist ?? [];
      // 真实账号至少会有「我喜欢的音乐」等自建歌单，list 不会整页为空。
      // 首页就空 = 接口降级 / 风控 / Cookie 半失效，绝不能拿它去删本地收藏。
      // 注意区分：list 非空但过滤后 out 为空，才是合法的「账号没收藏任何歌单」。
      if (page === 0 && list.length === 0) {
        return null;
      }
      for (const raw of list) {
        if (!WyFavSync.isSubscribed(raw, uid)) {
          continue;
        }
        const id = (raw.id ?? 0).toString();
        if (!Library.wyIsId(id) || seen.indexOf(id) >= 0) {
          continue;
        }
        seen.push(id);
        out.push(WyFavSync.sheetOf(raw, id));
      }
      if (resp.more !== true || list.length < PAGE_LIMIT) {
        break;
      }
    }
    return out;
  }

  /** uid 拿不到时用 account/get 补一次，避免拿游客歌单当成本人收藏 */
  private async resolveUid(cookie: string): Promise<number> {
    const known = WyAccount.get().uid();
    if (known > 0) {
      return known;
    }
    const data: Record<string, Object> = {};
    const reply = await wyPost('/weapi/w/nuser/account/get', data, cookie);
    if (!reply.ok || reply.body.length === 0) {
      return 0;
    }
    try {
      const obj = JSON.parse(reply.body) as Record<string, Object>;
      const profile = obj['profile'] as Record<string, Object>;
      if (profile !== null && profile !== undefined) {
        const v = profile['userId'];
        if (typeof v === 'number') {
          return v;
        }
      }
      const acct = obj['account'] as Record<string, Object>;
      if (acct !== null && acct !== undefined) {
        const v2 = acct['id'];
        if (typeof v2 === 'number') {
          return v2;
        }
      }
    } catch (e) {
      return 0;
    }
    return 0;
  }

  private static isSubscribed(raw: WyFavRawSheet, myUid: number): boolean {
    if (raw.subscribed === true) {
      return true;
    }
    if (raw.subscribed === false) {
      return false;
    }
    // subscribed 缺失（null）：只能靠创建者 uid 兜底
    const owner = raw.userId ?? 0;
    return myUid > 0 && owner > 0 && owner !== myUid;
  }

  /** 云端歌单统一构造成 kind='playlist'，详情页会走 wyPlaylistSongs 取歌 */
  private static sheetOf(raw: WyFavRawSheet, id: string): SheetInfo {
    const sheet = newSheet('wy', 'playlist');
    sheet.id = id;
    sheet.name = raw.name ?? '';
    sheet.cover = wyFixCover(raw.coverImgUrl ?? raw.picUrl ?? '');
    sheet.description = raw.description ?? raw.copywriter ?? '';
    sheet.trackCount = raw.trackCount ?? 0;
    sheet.playCount = raw.playCount ?? raw.playcount ?? 0;
    let creator = '';
    try {
      // 列表接口里 creator 有时是数字 uid、有时是 {nickname} 对象，
      // 只有后者能取到昵称；取不到就用兜底名，不影响收藏状态判定。
      const c: Object | undefined = raw.creator;
      if (c !== null && c !== undefined) {
        const rec = c as Record<string, Object>;
        const n = rec['nickname'];
        if (typeof n === 'string') {
          creator = n;
        }
      }
    } catch (e) {
      creator = '';
    }
    sheet.creator = creator.length > 0 ? creator : '网易云音乐';
    sheet.subtitle = raw.copywriter ?? '';
    if (raw.updateTime !== undefined) {
      const d = new Date(raw.updateTime);
      sheet.updateTime = (d.getMonth() + 1).toString() + '月' + d.getDate().toString() + '日';
    }
    return sheet;
  }

  /* ---------------- 本机持久化 ---------------- */

  private savePending(): void {
    Store.get().put(PrefKeys.WY_FAV_PENDING, JSON.stringify(this.pending));
  }

  private static readOps(text: string): WyFavOp[] {
    try {
      const list = JSON.parse(text) as WyFavOp[];
      if (!Array.isArray(list)) {
        return [];
      }
      const out: WyFavOp[] = [];
      for (const op of list) {
        if (op !== null && op !== undefined && typeof op.id === 'string' &&
          Library.wyIsId(op.id) && typeof op.add === 'boolean') {
          // 兼容 v2.68 及更早落盘的 {id, add}：无 blocked 字段按 false 读，
          // 首次 flush 会重新探测；不会把历史项误当成已受限或可无限重试。
          out.push({ id: op.id, add: op.add, blocked: op.blocked === true });
        }
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  private static readIds(text: string): string[] {
    try {
      const list = JSON.parse(text) as string[];
      if (!Array.isArray(list)) {
        return [];
      }
      const out: string[] = [];
      for (const id of list) {
        if (typeof id === 'string' && Library.wyIsId(id) && out.indexOf(id) < 0) {
          out.push(id);
        }
      }
      return out;
    } catch (e) {
      return [];
    }
  }
}

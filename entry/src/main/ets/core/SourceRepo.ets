import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SourceItem, newSource, LxInvokeInfo, SongInfo, SheetInfo, ArtistInfo, PagedSongs, SourceBackupItem } from '../common/Models';
import { PrefKeys, QUALITY_ORDER, normalizeQuality } from '../common/Constants';
import { stableId } from '../common/Utils';
import { Store } from './Store';
import { LxRunner, LxInitedInfo } from './LxRunner';

interface SourcePersist {
  id: string;
  name: string;
  fileName: string;
  size: number;
  importedAt: number;
  enabled: boolean;
  order: number;
  version: string;
  description: string;
  updateUrl: string;
  platforms: string[];
  qualities: string[];
  actions: string[];
  /** 可选：老元数据没有该字段，loadMeta 会按脚本正文自动识别 */
  kind?: string;
  /** 可选：MusicFree 插件是否声明 search()。老元数据由 actions 推导，不必重新自检 */
  mfSearchable?: boolean;
  /**
   * v2.47：上次自检结论跟着元数据一起落盘。
   * 不存的话，进程重启后 health 回到空串，卡片就又从「自检未通过」变回「正常」，
   * 用户看到的就是「明明没通过，重启一下又说正常了」。
   */
  health?: string;
  checkedAt?: number;
  latency?: number;
  message?: string;
}

/** 桥接层 musicSearch action 的返回结构 */
interface MfSearchResp {
  data?: SongInfo[];
  isEnd?: boolean;
}

/** v2.44：桥接层歌单 / 歌手 / 详情 action 的返回结构 */
interface MfSheetResp {
  data?: SheetInfo[];
  isEnd?: boolean;
}

interface MfArtistResp {
  data?: ArtistInfo[];
  isEnd?: boolean;
}

interface MfSongsResp {
  data?: SongInfo[];
  isEnd?: boolean;
}

/** MusicFree 插件订阅清单里的单条（官方 dist/_plugins/plugins.json） */
interface MfSubItem {
  url?: string;
  srcUrl?: string;
  link?: string;
}

/** 订阅清单顶层：官方用 plugins，社区也有 list / data / sources / 纯数组 */
interface MfSubscription {
  plugins?: MfSubItem[];
  list?: MfSubItem[];
  data?: MfSubItem[];
  sources?: MfSubItem[];
}

interface HealthTarget {
  source: string;
  id: string;
  name: string;
  singer: string;
  musicrid: string;
}

/** 启动加载时等 inited 的上限：并发计时，不阻塞其它脚本 */
const LOAD_INIT_WAIT_MS: number = 8000;
/** 自检并发数：同时问几个源，太高会撞平台风控 */
const CHECK_CONCURRENCY: number = 3;

interface InitWaiter {
  item: SourceItem;
  promise: Promise<LxInitedInfo | null>;
}

/** 批量自检时一项的进度：页面据此逐行刷新，而不是等全部跑完 */
export interface HealthProgress {
  id: string;
  done: number;
  total: number;
}

/** 自检没通过的音源：名字 + 原因，用于页面展示与日志 */
export interface CheckFailItem {
  name: string;
  message: string;
}

/**
 * 一轮批量自检的结果。
 *
 * 以前只有回调进度、没有汇总，页面自己再数一遍 status，启动自检更是跑完
 * 只写一行 console —— 用户看不到任何结论。现在把它当成一次「体检报告」，
 * 谁都能拿去展示。
 */
export interface CheckSummary {
  total: number;
  ok: number;
  failed: CheckFailItem[];
  at: number;
  /** 因为脚本级错误提前结束的平台数（用于解释「为什么这么快」） */
  skipped: number;
}

const HEALTH_TARGETS: HealthTarget[] = [
  { source: 'kw', id: '228908', name: '晴天', singer: '周杰伦', musicrid: 'MUSIC_228908' },
  { source: 'wy', id: '186016', name: '晴天', singer: '周杰伦', musicrid: '' },
  { source: 'tx', id: '0039MnYb0qxYhV', name: '晴天', singer: '周杰伦', musicrid: '' }
];

/**
 * 音源仓库：导入 / 启用 / 排序 / 删除 / 自检 / 更新。
 *
 * 每个脚本对应一个 SourceItem，脚本正文落在 files/sources/<id>.js，
 * 元数据落在 preferences。启动时把所有「已启用」脚本一次性挂到 LxRunner，
 * 之后取链、搜索都不再重新加载。
 */
export class SourceRepo {
  private static instance: SourceRepo = new SourceRepo();
  static get(): SourceRepo {
    return SourceRepo.instance;
  }

  private items: SourceItem[] = [];
  private runner: LxRunner | null = null;
  private context: common.UIAbilityContext | null = null;
  private dir: string = '';
  private inited: Map<string, LxInitedInfo> = new Map<string, LxInitedInfo>();
  private waiters: Map<string, Array<(info: LxInitedInfo) => void>> = new Map<string, Array<(info: LxInitedInfo) => void>>();
  private listeners: Array<() => void> = [];
  private activeId: string = '';
  private initialized: boolean = false;
  /** 严格递增的音源版本号：Date.now() 在同一毫秒内连续 notify 值相同，
   *  @StorageProp/@Watch 对相同值不回调，常驻搜索页会漏掉刚就绪的插件源 */
  private versionSeq: number = 0;

  onChange(listener: () => void): void {
    this.listeners.push(listener);
  }

  offChange(listener: () => void): void {
    this.listeners = this.listeners.filter((item: () => void): boolean => item !== listener);
  }

  private notify(): void {
    for (const listener of this.listeners) {
      listener();
    }
    AppStorage.setOrCreate('sourceCount', this.items.length);
    AppStorage.setOrCreate('activeSourceName', this.getActive()?.name ?? '');
    // 单独一个版本号：导入同一个脚本、启用/禁用、改名、自检完成这些操作
    // 数量没变，只靠 sourceCount 收不到通知，一级页就会一直停在旧状态。
    // 必须严格递增，不能用 Date.now()：同一批 inited 结算常常落在同一毫秒，
    // 相同值不会触发 @Watch，搜索页会漏掉刚就绪的插件源。
    this.versionSeq += 1;
    AppStorage.setOrCreate('sourceVersion', this.versionSeq);
  }

  getRunner(): LxRunner | null {
    return this.runner;
  }

  attachRunner(runner: LxRunner): void {
    this.runner = runner;
    runner.onInited = (instId: string, info: LxInitedInfo): void => {
      this.inited.set(instId, info);
      const list = this.waiters.get(instId);
      if (list !== undefined) {
        this.waiters.delete(instId);
        for (const resolve of list) {
          resolve(info);
        }
      }
      this.applyInited(instId, info);
      this.notify();
    };
    runner.onLoaded = (instId: string, name: string, version: string, updateUrl: string,
      kind: string): void => {
      const item = this.find(instId);
      if (item === null || kind !== 'musicfree') {
        return;
      }
      // MusicFree 插件的 platform / version / srcUrl 是运行时从 module.exports 读出来的，
      // 比导入时的正则更准（字段可能写在对象里、被压缩、或用变量拼接）。
      if (name.length > 0) {
        item.name = name;
      }
      if (version.length > 0) {
        item.version = version;
      }
      if (updateUrl.length > 0) {
        item.updateUrl = updateUrl;
      }
      this.notify();
    };
    runner.onScriptError = (instId: string, error: string): void => {
      const item = this.find(instId);
      if (item !== null) {
        item.status = 'error';
        item.message = error;
      }
      const list = this.waiters.get(instId);
      if (list !== undefined) {
        this.waiters.delete(instId);
        const info: LxInitedInfo = { status: false, platforms: [], error: error };
        for (const resolve of list) {
          resolve(info);
        }
      }
      this.notify();
    };
  }

  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.initialized) {
      return;
    }
    this.context = context;
    this.dir = context.filesDir + '/sources';
    try {
      if (!fs.accessSync(this.dir)) {
        fs.mkdirSync(this.dir);
      }
    } catch (e) {
      console.error('[Source] 创建目录失败 ' + String(e));
    }
    this.loadMeta();
    this.initialized = true;
    // 恢复上次选中的音源；没有就选第一个启用的
    const saved = Store.get().getString(PrefKeys.ACTIVE_SOURCE, '');
    if (saved.length > 0 && this.find(saved) !== null) {
      this.activeId = saved;
    } else if (this.enabled().length > 0) {
      this.activeId = this.enabled()[0].id;
    }
    await this.loadAll();
    // 载入完所有脚本后，把桥接页的全局 window.lx 指回用户上次选的「首选」
    this.syncActive();
    this.notify();
  }

  /** 把当前首选同步给运行时，避免多个脚本实例共享全局 window.lx 时指向错位 */
  private syncActive(): void {
    if (this.activeId.length > 0) {
      this.runner?.setActive(this.activeId);
    }
  }

  private loadMeta(): void {
    const text = Store.get().getString(PrefKeys.SOURCES, '[]');
    this.items = [];
    if (text.length === 0) {
      return;
    }
    try {
      const list = JSON.parse(text) as SourcePersist[];
      for (const raw of list) {
        const item = newSource();
        item.id = raw.id;
        item.name = raw.name;
        item.fileName = raw.fileName;
        item.size = raw.size;
        item.importedAt = raw.importedAt;
        item.enabled = raw.enabled;
        item.order = raw.order;
        item.version = raw.version;
        item.description = raw.description;
        item.updateUrl = raw.updateUrl;
        item.platforms = raw.platforms ?? [];
        item.qualities = raw.qualities ?? [];
        item.actions = raw.actions ?? [];
        item.kind = raw.kind === 'musicfree' ? 'musicfree' : 'lx';
        // v2.43：可搜索能力是脚本固有属性，冷启动就从持久化的 actions 恢复，
        // 不再等本轮 inited 上报点亮。老元数据没有 mfSearchable 时由 actions 推导。
        item.mfSearchable = item.kind === 'musicfree' &&
          (raw.mfSearchable === true || item.actions.indexOf('musicSearch') >= 0);
        item.path = this.dir + '/' + item.id + '.js';
        item.status = 'idle';
        // v2.47：恢复上次自检结论（只认终态，中途退出留下的 checking 一律作废）
        const savedHealth = raw.health === 'ok' || raw.health === 'error' ? raw.health : '';
        item.health = savedHealth;
        item.checkedAt = typeof raw.checkedAt === 'number' ? raw.checkedAt : 0;
        item.latency = typeof raw.latency === 'number' ? raw.latency : 0;
        item.message = typeof raw.message === 'string' ? raw.message : '';
        this.items.push(item);
      }
    } catch (e) {
      console.error('[Source] 元数据解析失败 ' + String(e));
    }
    this.items.sort((a: SourceItem, b: SourceItem): number => a.order - b.order);
  }

  private persist(): void {
    const list: SourcePersist[] = [];
    for (const item of this.items) {
      list.push({
        id: item.id,
        name: item.name,
        fileName: item.fileName,
        size: item.size,
        importedAt: item.importedAt,
        enabled: item.enabled,
        order: item.order,
        version: item.version,
        description: item.description,
        updateUrl: item.updateUrl,
        platforms: item.platforms,
        qualities: item.qualities,
        actions: item.actions,
        kind: item.kind,
        mfSearchable: item.mfSearchable,
        health: item.health === 'checking' ? '' : item.health,
        checkedAt: item.checkedAt,
        latency: item.latency,
        message: item.message
      });
    }
    Store.get().put(PrefKeys.SOURCES, JSON.stringify(list));
    Store.get().put(PrefKeys.ACTIVE_SOURCE, this.activeId);
  }

  /**
   * 启动加载：注入仍然串行，「等 inited」改成并发计时。
   *
   * 为什么注入不能并发：一个 WebView 里 window.lx 是单值，脚本的异步初始化
   * 回调（rconfig 回来之后）会读 globalThis.lx；两个脚本同时注入，
   * A 的回调就可能读到 B 的 lx，把 inited 上报到别的实例上。
   *
   * 但「等 inited」必须并发：旧写法每注入一个源就 await 它 6 秒，
   * 20 个源里只要有几个慢的（rconfig / 弱网），后面的源全被堵住，
   * 冷启动要一两分钟才加载完；这期间点播放就会显示「没有可用音源」。
   * 现在注入只花几十毫秒，等待同时计时，总耗时 ≈ 注入总和 + 最慢那个的等待。
   */
  private async loadAll(): Promise<void> {
    const runner = this.runner;
    if (runner === null) {
      return;
    }
    const waiters: InitWaiter[] = [];
    for (const item of this.items) {
      if (!item.enabled) {
        continue;
      }
      const code = this.readCode(item);
      if (code === null) {
        continue;
      }
      // v2.43：与 loadOne 保持同一事实来源。旧写法漏传 kind，MusicFree 插件
      // 冷启动会被当洛雪脚本装载，只能靠「洛雪执行失败 → 自动按 MusicFree 重试」
      // 兜底；十几个源共享一个 WebView 时这条回退不稳定，部分源报不出
      // inited，卡片停在「不可用」，搜索页也拿不到它们（必须逐个手动刷新）。
      item.kind = SourceRepo.detectKind(code);
      item.mfSearchable = item.kind === 'musicfree' && item.actions.indexOf('musicSearch') >= 0;
      item.status = 'checking';
      // 先注册等待再注入：有的脚本在 runner() 里同步 send('inited')
      const promise = this.waitInited(item.id, LOAD_INIT_WAIT_MS);
      try {
        await runner.load(item.id, code, item.kind);
      } catch (e) {
        item.status = 'error';
        item.message = e instanceof Error ? e.message : String(e);
        continue;
      }
      waiters.push({ item: item, promise: promise });
    }
    // 注入已全部完成，各自的结果在后台结算，不阻塞启动
    for (const waiter of waiters) {
      waiter.promise.then((info: LxInitedInfo | null) => {
        this.settleLoad(waiter.item, info);
      });
    }
    this.notify();
  }

  /** 读脚本正文；文件不存在 / 读失败时把原因写进 item 并返回 null */
  private readCode(item: SourceItem): string | null {
    try {
      if (!fs.accessSync(item.path)) {
        item.status = 'error';
        item.message = '脚本文件丢失，请重新导入';
        return null;
      }
      return fs.readTextSync(item.path);
    } catch (e) {
      item.status = 'error';
      item.message = e instanceof Error ? e.message : String(e);
      return null;
    }
  }

  /** 把 inited 上报的平台 / 音质 / 动作写回 item，并收口状态 */
  private settleLoad(item: SourceItem, info: LxInitedInfo | null): void {
    if (info !== null && info.platforms.length > 0) {
      item.status = 'ok';
      item.message = '';
      item.platforms = [];
      item.qualities = [];
      item.actions = [];
      for (const platform of info.platforms) {
        item.platforms.push(platform.id);
        for (const q of platform.qualitys) {
          if (item.qualities.indexOf(q) < 0) {
            item.qualities.push(q);
          }
        }
        for (const action of platform.actions) {
          if (item.actions.indexOf(action) < 0) {
            item.actions.push(action);
          }
        }
      }
      item.checkedAt = Date.now();
      item.mfSearchable = item.kind === 'musicfree' && item.actions.indexOf('musicSearch') >= 0;
    } else if (item.status !== 'error') {
      item.status = 'error';
      item.message = info !== null && info.error.length > 0 ? info.error : '音源没有上报可用平台';
      // v2.43：不清除 mfSearchable。inited 没等到只说明这次初始化慢/失败，
      // 不等于插件不具备 search 能力；显示与否交给 runner.isLoaded 判定。
    }
    this.notify();
  }

  /** 注入单个脚本并等它 inited（导入 / 重建时用，调用方需要拿到确定结果） */
  private async loadOne(item: SourceItem, waitMs: number): Promise<void> {
    const runner = this.runner;
    if (runner === null) {
      return;
    }
    const code = this.readCode(item);
    if (code === null) {
      return;
    }
    // 正文优先：老元数据 / 备份可能没带 kind，按真实脚本内容重新判定协议，
    // 避免「洛雪脚本被当 MusicFree 装载」或反过来导致整个音源不可用。
    item.kind = SourceRepo.detectKind(code);
    // v2.43：能力不清零。装载若超时，runner.isLoaded 会如实拦住显示，
    // 但「这个插件声明了 search」是脚本固有属性，不能因为一次装载慢就抹掉。
    item.mfSearchable = item.kind === 'musicfree' && item.actions.indexOf('musicSearch') >= 0;
    item.status = 'checking';
    const promise = this.waitInited(item.id, waitMs);
    try {
      await runner.load(item.id, code, item.kind);
    } catch (e) {
      item.status = 'error';
      item.message = e instanceof Error ? e.message : String(e);
      return;
    }
    const info = await promise;
    this.settleLoad(item, info);
  }

  private waitInited(instId: string, ms: number): Promise<LxInitedInfo | null> {
    return new Promise<LxInitedInfo | null>((resolve) => {
      let done = false;
      const timer = setTimeout(() => {
        if (done) {
          return;
        }
        done = true;
        const list = this.waiters.get(instId);
        if (list !== undefined) {
          this.waiters.set(instId, list.filter((fn: (info: LxInitedInfo) => void): boolean => fn !== handler));
        }
        resolve(null);
      }, ms);
      const handler = (info: LxInitedInfo): void => {
        if (done) {
          return;
        }
        done = true;
        clearTimeout(timer);
        resolve(info);
      };
      const list = this.waiters.get(instId) ?? [];
      list.push(handler);
      this.waiters.set(instId, list);
    });
  }

  private applyInited(instId: string, info: LxInitedInfo): void {
    const item = this.find(instId);
    if (item === null) {
      return;
    }
    item.platforms = [];
    item.qualities = [];
    item.actions = [];
    for (const platform of info.platforms) {
      item.platforms.push(platform.id);
      for (const q of platform.qualitys) {
        if (item.qualities.indexOf(q) < 0) {
          item.qualities.push(q);
        }
      }
      for (const action of platform.actions) {
        if (item.actions.indexOf(action) < 0) {
          item.actions.push(action);
        }
      }
    }
    if (info.platforms.length > 0) {
      item.status = 'ok';
      item.message = '';
      item.checkedAt = Date.now();
      item.mfSearchable = item.kind === 'musicfree' && item.actions.indexOf('musicSearch') >= 0;
    }
  }

  /**
   * 可作为搜索源使用的 MusicFree 插件。
   *
   * v2.43：不再拿 status === 'ok' 当门槛。status 是「上一次自检 / 装载」的
   * 瞬时结论，冷启动会被重置成 idle，自检取链遇到网络抖动 / 版权 / 风控又会被
   * 写成 error；一次自检不过就把一个装载完好的插件从搜索页踢掉，用户只能逐个
   * 手动刷新把它重新点亮 —— 那不是真实能力，是错误的耦合。
   * 现在只看两件稳定事实：脚本声明了 musicSearch（持久化的能力），以及运行时
   * 确实装载了它（runner.isLoaded）。脚本真没装载成功则如实不显示；临时搜不动
   * 时由 searchMusicFree 返回空结果，不伪造。
   */
  mfSearchSources(): SourceItem[] {
    const runner = this.runner;
    if (runner === null) {
      return [];
    }
    return this.items.filter((item: SourceItem): boolean =>
      item.enabled && item.kind === 'musicfree' && item.mfSearchable && runner.isLoaded(item.id));
  }

  /**
   * v2.49：自动替补的候选顺序 —— 按自检结论 health 排序，让「已验证能出链」的插件先上。
   *
   * 为什么需要：v2.45 的替补是 mfSearchSources().slice(0, 6)，纯按音源页顺序取前 6 个。
   * 若排在前面的恰好是自检已判 error 的插件（例如元力订阅那批中转失效的源），
   * 它们会占满全部并发名额，真正能出链的插件排在第 7 位就永远轮不到。
   * v2.46 / v2.47 好不容易把 health 结论做准并持久化，替补却没用上它。
   *
   * 关键：只排序，不过滤。v2.43 已确立「一次自检失败不把源踢出搜索页」，
   * 同理这里也不能把 health='error' 的插件删掉 —— 自检可能过时、可能只是那一次
   * 网络抖动 / 版权限制，换首歌说不定就能出链。只是把它排到最后，
   * 把有限的并发名额优先留给更可能成功的插件。同档内保持音源页 order
   * （用户拖动调出来的优先级），不依赖 Array.sort 的稳定性。
   */
  mfFallbackSources(): SourceItem[] {
    const list: SourceItem[] = this.mfSearchSources().slice();
    list.sort((a: SourceItem, b: SourceItem): number => {
      const ra = SourceRepo.healthRank(a.health);
      const rb = SourceRepo.healthRank(b.health);
      if (ra !== rb) {
        return ra - rb;
      }
      return a.order - b.order;
    });
    return list;
  }

  /** ok 最优先，未自检 / 自检中居中，自检未通过垫底（但不排除） */
  private static healthRank(health: string): number {
    if (health === 'ok') {
      return 0;
    }
    if (health === 'error') {
      return 2;
    }
    return 1;
  }

  /**
   * 调用某个 MusicFree 插件的 search() 并把结果转成 SongInfo[]。
   *
   * 与内置五平台搜索并列的第三条链路：插件自己搜出歌，自己也负责取链，
   * 每首歌通过 mfRaw 带着原始 mediaItem（bvid / photo.id / manifest 等自定义字段），
   * 播放与取词时原样回传，不经过「按歌名跨平台猜」那一套。
   */
  async searchMusicFree(instId: string, keyword: string, page: number): Promise<SongInfo[]> {
    const runner = this.runner;
    if (runner === null || !runner.isLoaded(instId) || keyword.trim().length === 0) {
      return [];
    }
    const info: LxInvokeInfo = { keyword: keyword, page: page, limit: 30 };
    try {
      const raw = await runner.invoke(instId, 'musicSearch', info, 15000);
      const parsed = JSON.parse(raw) as MfSearchResp;
      if (parsed === null || parsed.data === undefined || parsed.data === null) {
        return [];
      }
      const out: SongInfo[] = [];
      for (const song of parsed.data) {
        if (song !== null && song !== undefined && song.name !== undefined && song.name.length > 0) {
          out.push(song);
        }
      }
      return out;
    } catch (e) {
      console.info('[Source] MusicFree 搜索失败 ' + String(e));
      return [];
    }
  }

  /**
   * v2.44：MusicFree 歌单搜索。官方协议 search(query, page, 'sheet')，
   * 插件未声明 / 未实现该类型时桥接层如实返回空，宿主不伪造歌单。
   */
  async searchSheetsMusicFree(instId: string, keyword: string, page: number): Promise<SheetInfo[]> {
    const runner = this.runner;
    if (runner === null || !runner.isLoaded(instId) || keyword.trim().length === 0) {
      return [];
    }
    const info: LxInvokeInfo = { keyword: keyword, page: page, limit: 30 };
    try {
      const raw = await runner.invoke(instId, 'sheetSearch', info, 15000);
      const parsed = JSON.parse(raw) as MfSheetResp;
      if (parsed === null || parsed.data === undefined || parsed.data === null) {
        return [];
      }
      const out: SheetInfo[] = [];
      for (const sheet of parsed.data) {
        if (sheet !== null && sheet !== undefined && sheet.name !== undefined && sheet.name.length > 0) {
          out.push(sheet);
        }
      }
      return out;
    } catch (e) {
      console.info('[Source] MusicFree 歌单搜索失败 ' + String(e));
      return [];
    }
  }

  /** v2.44：MusicFree 歌手搜索。官方协议 search(query, page, 'artist') */
  async searchArtistsMusicFree(instId: string, keyword: string, page: number): Promise<ArtistInfo[]> {
    const runner = this.runner;
    if (runner === null || !runner.isLoaded(instId) || keyword.trim().length === 0) {
      return [];
    }
    const info: LxInvokeInfo = { keyword: keyword, page: page, limit: 30 };
    try {
      const raw = await runner.invoke(instId, 'artistSearch', info, 15000);
      const parsed = JSON.parse(raw) as MfArtistResp;
      if (parsed === null || parsed.data === undefined || parsed.data === null) {
        return [];
      }
      const out: ArtistInfo[] = [];
      for (const artist of parsed.data) {
        if (artist !== null && artist !== undefined && artist.name !== undefined && artist.name.length > 0) {
          out.push(artist);
        }
      }
      return out;
    } catch (e) {
      console.info('[Source] MusicFree 歌手搜索失败 ' + String(e));
      return [];
    }
  }

  /**
   * v2.44：MusicFree 歌单详情。官方 getMusicSheetInfo(sheetItem, page)，
   * sheetItem 用搜索结果里保存的 mfRaw 原文回传，保留插件自定义字段。
   */
  async sheetSongsMusicFree(instId: string, sheet: SheetInfo, page: number): Promise<PagedSongs> {
    const empty: PagedSongs = { songs: [], page: page, hasMore: false, total: 0 };
    const runner = this.runner;
    if (runner === null || !runner.isLoaded(instId) || (sheet.mfRaw ?? '').length === 0) {
      return empty;
    }
    const info: LxInvokeInfo = { page: page, limit: 30, mfRaw: sheet.mfRaw };
    try {
      const raw = await runner.invoke(instId, 'sheetInfo', info, 15000);
      const parsed = JSON.parse(raw) as MfSongsResp;
      const list: SongInfo[] = [];
      if (parsed !== null && parsed.data !== undefined && parsed.data !== null) {
        for (const song of parsed.data) {
          if (song !== null && song !== undefined && song.name !== undefined && song.name.length > 0) {
            list.push(song);
          }
        }
      }
      return {
        songs: list,
        page: page,
        hasMore: parsed !== null && parsed.isEnd === false,
        total: list.length
      };
    } catch (e) {
      console.info('[Source] MusicFree 歌单详情失败 ' + String(e));
      return empty;
    }
  }

  /**
   * v2.44：MusicFree 歌手作品。官方 getArtistWorks(artistItem, page, 'music')，
   * 返回的歌曲由桥接层 toSong 带上 mfRaw，可直接走既有取链 / 取词链路。
   */
  async artistSongsMusicFree(instId: string, artist: ArtistInfo, page: number): Promise<PagedSongs> {
    const empty: PagedSongs = { songs: [], page: page, hasMore: false, total: 0 };
    const runner = this.runner;
    if (runner === null || !runner.isLoaded(instId) || (artist.mfRaw ?? '').length === 0) {
      return empty;
    }
    const info: LxInvokeInfo = { page: page, limit: 30, mfRaw: artist.mfRaw };
    try {
      const raw = await runner.invoke(instId, 'artistWorks', info, 15000);
      const parsed = JSON.parse(raw) as MfSongsResp;
      const list: SongInfo[] = [];
      if (parsed !== null && parsed.data !== undefined && parsed.data !== null) {
        for (const song of parsed.data) {
          if (song !== null && song !== undefined && song.name !== undefined && song.name.length > 0) {
            list.push(song);
          }
        }
      }
      return {
        songs: list,
        page: page,
        hasMore: parsed !== null && parsed.isEnd === false,
        total: list.length
      };
    } catch (e) {
      console.info('[Source] MusicFree 歌手作品失败 ' + String(e));
      return empty;
    }
  }

  /* ---------------- 查询 ---------------- */
  list(): SourceItem[] {
    return this.items;
  }

  enabled(): SourceItem[] {
    return this.items.filter((item: SourceItem): boolean => item.enabled);
  }

  find(id: string): SourceItem | null {
    for (const item of this.items) {
      if (item.id === id) {
        return item;
      }
    }
    return null;
  }

  getActiveId(): string {
    return this.activeId;
  }

  getActive(): SourceItem | null {
    return this.find(this.activeId);
  }

  setActive(id: string): void {
    if (this.find(id) === null) {
      return;
    }
    this.activeId = id;
    this.runner?.setActive(id);
    this.persist();
    this.notify();
  }

  /** 所有已启用音源支持的平台并集 */
  getPlatforms(): string[] {
    const list: string[] = [];
    for (const item of this.enabled()) {
      for (const id of item.platforms) {
        if (list.indexOf(id) < 0) {
          list.push(id);
        }
      }
    }
    return list;
  }

  /**
   * 音源声明过的全部音质（归一化别名后按从高到低排序）。
   * item.qualities 保留音源上报的原始档位名，取链时要用它去反问音源；
   * 这里只做归一化，供 UI 选项与降级链比较使用。
   */
  getQualities(platform: string): string[] {
    const set: string[] = [];
    for (const item of this.enabled()) {
      for (const q of item.qualities) {
        const n = normalizeQuality(q);
        if (set.indexOf(n) < 0) {
          set.push(n);
        }
      }
    }
    const out: string[] = [];
    for (const q of QUALITY_ORDER) {
      if (set.indexOf(q) >= 0) {
        out.push(q);
      }
    }
    for (const q of set) {
      if (out.indexOf(q) < 0) {
        out.push(q);
      }
    }
    return out.length > 0 ? out : ['320k', '128k'];
  }

  /* ---------------- 导入 / 删除 / 排序 ---------------- */
  async importCode(code: string, fileName: string): Promise<SourceItem> {
    const text = code.trim();
    if (text.length < 100) {
      throw new Error('脚本内容过短，不是有效的音源文件');
    }
    // MusicFree 订阅清单是 JSON，不是可执行的脚本。以前会整段丢进 new Function
    // 报「Unexpected token」，这里明确拦下并指向正确的导入入口。
    if (SourceRepo.isSubscription(text)) {
      throw new Error('这是 MusicFree 插件订阅清单（JSON）。请在「从网络导入」里粘贴订阅链接，会自动批量导入其中所有插件');
    }
    // 失效订阅里的「网页 / HTML 中转页」：长度够但不是脚本，如实拦下别存成音源
    if (SourceRepo.looksLikeWebPage(text)) {
      throw new Error('链接返回的是网页或跳转页（该插件源可能已失效），请用脚本文件的 raw 直链，或换一个订阅源');
    }
    const kind = SourceRepo.detectKind(text);
    const id = stableId(text).substring(0, 12);
    const exist = this.find(id);
    if (exist !== null) {
      // 同一个脚本重复导入：更新内容并启用
      await this.writeFile(exist.id, text);
      exist.size = text.length;
      exist.enabled = true;
      exist.importedAt = Date.now();
      await this.loadOne(exist, 6000);
      this.syncActive();
      this.persist();
      this.notify();
      return exist;
    }
    const item = newSource();
    item.id = id;
    item.kind = kind;
    // MusicFree 插件没有洛雪的 /*! @name */ 头注解，头信息从 module.exports 的字段读
    item.name = kind === 'musicfree' ?
      (SourceRepo.mfMeta(text, 'platform') || 'MusicFree 插件') : SourceRepo.headerName(text);
    item.fileName = fileName.length > 0 ? fileName : item.name + '.js';
    item.size = text.length;
    item.importedAt = Date.now();
    item.enabled = true;
    item.order = this.items.length;
    item.version = kind === 'musicfree' ?
      (SourceRepo.mfMeta(text, 'version') || '0.0.0') : SourceRepo.headerVersion(text);
    item.description = kind === 'musicfree' ?
      (SourceRepo.mfMeta(text, 'author') !== '' ? 'MusicFree 插件 · 作者 ' + SourceRepo.mfMeta(text, 'author') : 'MusicFree 插件') :
      SourceRepo.headerDescription(text);
    item.updateUrl = kind === 'musicfree' ?
      SourceRepo.mfMeta(text, 'srcUrl') : SourceRepo.headerUpdateUrl(text);
    item.path = this.dir + '/' + id + '.js';
    await this.writeFile(id, text);
    this.items.push(item);
    if (this.activeId.length === 0) {
      this.activeId = id;
    }
    await this.loadOne(item, 8000);
    this.syncActive();
    this.persist();
    this.notify();
    return item;
  }

  private async writeFile(id: string, code: string): Promise<void> {
    const path = this.dir + '/' + id + '.js';
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, code);
    fs.closeSync(file);
  }

  async setEnabled(id: string, enabled: boolean): Promise<void> {
    const item = this.find(id);
    if (item === null) {
      return;
    }
    item.enabled = enabled;
    if (enabled) {
      await this.loadOne(item, 6000);
    } else {
      await this.runner?.unload(id);
      item.status = 'idle';
      item.message = '';
      item.health = '';
      if (this.activeId === id) {
        const list = this.enabled();
        this.activeId = list.length > 0 ? list[0].id : '';
      }
    }
    this.syncActive();
    this.persist();
    this.notify();
  }

  /**
   * 批量删除（v2.48）：音源页选择模式下勾几个删几个、全选一次删完。
   *
   * 不能在外面循环调 remove()：每一次都会 persist + notify + reindex，
   * 删 N 个就重建 N 轮列表，选择模式还会被中途的刷新打断（勾选状态与卡片
   * 节点都在重排）。这里统一卸载、删文件、一次性过滤，最后只落盘并广播一次。
   * 返回真正删掉的条数（id 早已不在时按 0 处理，不抛错）。
   */
  async removeMany(ids: string[]): Promise<number> {
    const kill: string[] = [];
    for (const id of ids) {
      if (this.find(id) !== null && kill.indexOf(id) < 0) {
        kill.push(id);
      }
    }
    if (kill.length === 0) {
      return 0;
    }
    for (const id of kill) {
      const item = this.find(id);
      if (item === null) {
        continue;
      }
      await this.runner?.unload(id);
      try {
        if (fs.accessSync(item.path)) {
          fs.unlinkSync(item.path);
        }
      } catch (e) {
        console.warn('[Source] 删除脚本失败 ' + String(e));
      }
    }
    this.items = this.items.filter((it: SourceItem): boolean => kill.indexOf(it.id) < 0);
    // 首选被一起删掉时退回列表第一项，与单删的兜底一致
    if (kill.indexOf(this.activeId) >= 0) {
      this.activeId = this.items.length > 0 ? this.items[0].id : '';
    }
    this.reindex();
    this.syncActive();
    this.persist();
    this.notify();
    return kill.length;
  }

  /** 单删复用批量路径，避免「单删 / 批量删」两套实现以后行为分叉 */
  async remove(id: string): Promise<void> {
    await this.removeMany([id]);
  }

  async move(id: string, delta: number): Promise<void> {
    const index = this.items.findIndex((item: SourceItem): boolean => item.id === id);
    if (index < 0) {
      return;
    }
    const target = index + delta;
    if (target < 0 || target >= this.items.length) {
      return;
    }
    const temp = this.items[index];
    this.items[index] = this.items[target];
    this.items[target] = temp;
    this.reindex();
    this.persist();
    this.notify();
  }

  /**
   * 拖动排序落位：把 id 一次性移到目标下标 toIndex（toIndex 按移动前的顺序计）。
   * 与 move() 的相邻交换不同，这里只在松手时调用一次，避免拖动过程中反复写盘。
   */
  async moveTo(id: string, toIndex: number): Promise<void> {
    const from = this.items.findIndex((it: SourceItem): boolean => it.id === id);
    if (from < 0) {
      return;
    }
    let to = toIndex;
    if (to < 0) {
      to = 0;
    }
    if (to >= this.items.length) {
      to = this.items.length - 1;
    }
    if (to === from) {
      return;
    }
    const picked: SourceItem = this.items[from];
    // 纯下标搬运，不依赖 splice 返回值/解构，ArkTS 静态检查最稳
    const rest: SourceItem[] = [];
    for (let i = 0; i < this.items.length; i++) {
      if (i !== from) {
        rest.push(this.items[i]);
      }
    }
    const next: SourceItem[] = [];
    let inserted = false;
    for (let i = 0; i < rest.length; i++) {
      if (i === to && !inserted) {
        next.push(picked);
        inserted = true;
      }
      next.push(rest[i]);
    }
    if (!inserted) {
      next.push(picked);
    }
    this.items = next;
    this.reindex();
    this.persist();
    this.notify();
  }

  private reindex(): void {
    for (let i = 0; i < this.items.length; i++) {
      this.items[i].order = i;
    }
  }

  async rename(id: string, name: string): Promise<void> {
    const item = this.find(id);
    if (item === null || name.trim().length === 0) {
      return;
    }
    item.name = name.trim();
    this.persist();
    this.notify();
  }

  /** 检查更新：拿到新脚本文本返回 true（不直接覆盖，由 UI 确认） */
  async fetchUpdate(id: string): Promise<string> {
    const item = this.find(id);
    if (item === null || item.updateUrl.length === 0) {
      return '';
    }
    return await SourceRepo.httpText(item.updateUrl);
  }

  /** 拉取一段文本（检查更新、网络导入共用）。失败直接抛，由调用方提示 */
  static async httpText(url: string): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      const client = http.createHttp();
      client.request(url, {
        method: http.RequestMethod.GET,
        header: { 'User-Agent': 'Mozilla/5.0' },
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 10000,
        readTimeout: 15000
      }, (err: BusinessError, data: http.HttpResponse) => {
        client.destroy();
        if (err) {
          reject(new Error('更新检查失败'));
          return;
        }
        resolve(String(data.result ?? ''));
      });
    });
  }

  /**
   * 重建单个音源：先卸载页内实例，再重新注入脚本并等 inited。
   *
   * 对应官方「切源即销毁重建」的最小形态：只在出了问题（脚本卡死、handler 丢失、
   * 全局变量被别的脚本污染）时重建一个源，而不是每次切源都重建全部。
   */
  async reload(id: string): Promise<SourceItem | null> {
    const item = this.find(id);
    if (item === null) {
      return null;
    }
    const runner = this.runner;
    if (runner === null) {
      return item;
    }
    await runner.unload(id);
    item.status = 'checking';
    item.message = '正在重新加载…';
    item.health = '';
    this.notify();
    await this.loadOne(item, 12000);
    // 重建后要把全局 window.lx 指回首选项，否则脚本异步回调读到的还是别的实例
    this.syncActive();
    this.notify();
    return item;
  }

  /**
   * 重建全部已启用音源：整页重置 → 逐个重新注入。
   *
   * 用于「十几个源都显示已加载，但一个都没就绪」的情况 ——
   * WebView 被系统回收后 runJavaScript 会静默失效，页内实例全没了，
   * 旧版只能杀进程重启 App；现在在音源页点一下就能恢复。
   */
  async reloadAll(): Promise<void> {
    const runner = this.runner;
    if (runner === null) {
      return;
    }
    await runner.resetSandbox();
    for (const item of this.enabled()) {
      await this.loadOne(item, 8000);
    }
    this.syncActive();
    this.notify();
  }

  /* ---------------- 备份 / 恢复（v2.39） ---------------- */

  /**
   * 导出全部音源供备份：元数据 + 脚本正文一起带走。
   *
   * 只导出正文真实存在的脚本：文件已丢失的项本来就是死链，
   * 备份一个空 code 只会让恢复后照样「脚本文件丢失，请重新导入」（铁律 2）。
   * 这里直接读文件、不走 readCode()，避免为了备份把 item.status 改成 error。
   */
  exportScripts(): SourceBackupItem[] {
    const out: SourceBackupItem[] = [];
    for (const item of this.items) {
      let code: string = '';
      try {
        if (fs.accessSync(item.path)) {
          code = fs.readTextSync(item.path);
        }
      } catch (e) {
        code = '';
      }
      if (code.length === 0) {
        continue;
      }
      const entry: SourceBackupItem = {
        id: item.id,
        name: item.name,
        fileName: item.fileName,
        enabled: item.enabled,
        order: item.order,
        version: item.version,
        description: item.description,
        updateUrl: item.updateUrl,
        code: code,
        kind: item.kind,
        // v2.43：可搜索能力随备份一起带走，恢复后不用等 inited 重新点亮
        actions: item.actions,
        mfSearchable: item.mfSearchable
      };
      out.push(entry);
    }
    return out;
  }

  /**
   * 从备份恢复音源：写回脚本正文 → 重建元数据 → 重载内存态与运行时脚本。
   *
   * 安全边界：
   *   1. id 只允许字母数字下划线连字符，挡住 ../../ 之类路径穿越；
   *   2. code 与 importCode 同下限（100）并设 5MB 上限，挡住畸形文件；
   *   3. 去重、逐项 try，单项畸形跳过不影响其余；Backup 层已保证只在
   *      备份确实带脚本时才调用，老备份 / 无音源备份不碰现有音源。
   *
   * 元数据只落最小真实集：size 取 code 长度、importedAt 取恢复时间、
   * platforms/qualities/actions 交给脚本重新 inited 时自行上报，不伪造。
   */
  async restoreFromBackup(scripts: SourceBackupItem[], activeId: string): Promise<number> {
    if (this.dir.length === 0) {
      return 0;
    }
    const valid: SourceBackupItem[] = [];
    const seen: string[] = [];
    for (const raw of scripts) {
      try {
        if (typeof raw.id !== 'string' || typeof raw.code !== 'string') {
          continue;
        }
        const id: string = raw.id as string;
        const code: string = raw.code as string;
        if (!/^[A-Za-z0-9_-]{1,64}$/.test(id)) {
          continue;
        }
        if (code.length < 100 || code.length > 5 * 1024 * 1024) {
          continue;
        }
        if (seen.indexOf(id) >= 0) {
          continue;
        }
        seen.push(id);
        valid.push(raw);
      } catch (e) {
        console.warn('[Source] 跳过无效备份脚本 ' + String(e));
      }
    }
    if (valid.length === 0) {
      return 0;
    }
    // 1) 正文写回沙箱 files/sources/<id>.js
    for (const s of valid) {
      await this.writeFile(s.id, s.code);
    }
    // 2) 元数据按备份顺序重建并落盘
    const list: SourcePersist[] = [];
    for (let i = 0; i < valid.length; i++) {
      const s = valid[i];
      list.push({
        id: s.id,
        name: typeof s.name === 'string' ? (s.name as string) : '自定义音源',
        fileName: typeof s.fileName === 'string' ? (s.fileName as string) : s.id + '.js',
        size: s.code.length,
        importedAt: Date.now(),
        enabled: s.enabled === true,
        order: typeof s.order === 'number' ? (s.order as number) : i,
        version: typeof s.version === 'string' ? (s.version as string) : '',
        description: typeof s.description === 'string' ? (s.description as string) : '',
        updateUrl: typeof s.updateUrl === 'string' ? (s.updateUrl as string) : '',
        platforms: [],
        qualities: [],
        // v2.43：老备份没有这两段时给空 / false，由随后 reloadAll 的 inited 上报补齐；
        // 新备份直接带回真实动作与能力，恢复完即可搜索，不必逐个手动刷新。
        actions: Array.isArray(s.actions) ? (s.actions as string[]) : [],
        // 备份没带 kind 时按正文识别；loadOne 还会再按正文复核一次
        kind: s.kind === 'musicfree' || s.kind === 'lx' ? s.kind : SourceRepo.detectKind(s.code),
        mfSearchable: s.mfSearchable === true
      });
    }
    Store.get().put(PrefKeys.SOURCES, JSON.stringify(list));
    // 首选只在它确实在恢复集合里时沿用，否则落到第一个启用的
    let nextActive: string = '';
    if (activeId.length > 0 && seen.indexOf(activeId) >= 0) {
      nextActive = activeId;
    } else {
      for (const p of list) {
        if (p.enabled) {
          nextActive = p.id;
          break;
        }
      }
    }
    Store.get().put(PrefKeys.ACTIVE_SOURCE, nextActive);
    // 3) 重读元数据、恢复首选、重新注入全部启用脚本
    this.loadMeta();
    this.activeId = nextActive;
    await this.reloadAll();
    this.syncActive();
    this.notify();
    return valid.length;
  }

  /**
   * 音源自检：用三首基准歌曲依次尝试取链。
   * 只做「能不能拿到 http 链接」，不做体积校验，避免自检太慢。
   */
  async check(id: string): Promise<SourceItem> {
    const item = this.find(id);
    if (item === null) {
      throw new Error('音源不存在');
    }
    const runner = this.runner;
    // v2.43：自检结论写 health，不覆盖 status。status 只表示「脚本装载好了没」，
    // 一次取链超时不能把一个装载完好的插件标成不可用、更不能踢出搜索源。
    item.health = 'checking';
    item.message = '正在自检…';
    this.notify();
    if (runner === null) {
      item.health = 'error';
      item.message = '音源运行环境未就绪';
      this.notify();
      return item;
    }
    // 没加载 / 加载了还没 inited 的，先重建一次再自检 ——
    // 「自检」本来就是用户手动触发的修复动作，顺手把沙箱状态擦干净最省事。
    if (!runner.isLoaded(id) || !runner.isInited(id)) {
      await this.reload(id);
      item.health = 'checking';
      item.message = '正在自检…';
      this.notify();
    }
    if (!runner.isInited(id)) {
      item.health = 'error';
      // reload() 里 loadOne 可能已经写了更具体的原因（脚本执行报错 / 文件丢失）
      if (item.message.length === 0 || item.message === '正在自检…' || item.message === '正在重新加载…') {
        item.message = '脚本没有上报可用平台（初始化未完成）';
      }
      this.notify();
      return item;
    }
    const started = Date.now();
    // MusicFree 插件的 id 是自己的（bvid / photo.id …），拿五平台基准曲去取链
    // 必然全被 platforms 过滤掉、判成 error，用户点一次自检插件就从搜索源消失。
    // 改走协议自检：用它自己的 search() 出歌，再拿这首歌验证取链（见 checkMusicFree）。
    if (item.kind === 'musicfree') {
      return await this.checkMusicFree(id, item, runner, started);
    }
    let ok = false;
    let message = '';
    let skipped = 0;
    for (const target of HEALTH_TARGETS) {
      if (item.platforms.length > 0 && item.platforms.indexOf(target.source) < 0) {
        continue;
      }
      const song: SongInfo = {
        id: target.id,
        songmid: target.id,
        hash: target.id,
        name: target.name,
        singer: target.singer,
        album: '',
        interval: '',
        source: target.source,
        duration: 269,
        cover: '',
        lyric: '',
        url: '',
        quality: '128k',
        musicrid: target.musicrid
      };
      const info: LxInvokeInfo = {
        source: target.source,
        quality: '128k',
        type: '128k',
        musicInfo: song
      };
      try {
        const raw = await runner.invoke(id, 'musicUrl', info, 12000);
        const url = SourceRepo.pickUrl(raw);
        if (url.startsWith('http')) {
          ok = true;
          message = '取链正常';
          break;
        }
        message = '返回空链接';
      } catch (e) {
        message = e instanceof Error ? e.message : '取链失败';
      }
      // 脚本级故障（没注册处理器 / 没加载 / 初始化就没过）换个平台也是同样的错，
      // 再试两个平台只是白等 24 秒 —— 直接收工，把时间留给真正还能用的源。
      if (SourceRepo.isFatalCheck(message)) {
        skipped += 1;
        break;
      }
    }
    item.latency = Date.now() - started;
    item.checkedAt = Date.now();
    item.health = ok ? 'ok' : 'error';
    item.message = ok ? '取链正常 · ' + item.latency.toString() + 'ms' : message;
    item.checkSkipped = skipped;
    this.persist();
    this.notify();
    return item;
  }

  /**
   * MusicFree 插件自检：不套用五平台基准曲，改走「插件自己搜 → 自己取链」的真实链路。
   * - 搜索链路抛错 / 返回结构不合法 → error。
   * - 搜索正常但本次无结果 → ok，message 如实写明取链未验证。
   * - 有结果 → 用第一首（带 mfRaw 原始 mediaItem）试一次取链，结论按真实结果分开：
   *   拿到 http 链接才 ok；返回空或抛错一律 error，并把插件给出的真实原因写进 message。
   * - health 只影响卡片文案与自检汇总，不参与 mfSearchSources() 过滤，
   *   所以「能搜不能放」的源仍然留在搜索页，但不再被显示成「正常」。
   */
  private async checkMusicFree(id: string, item: SourceItem, runner: LxRunner,
    started: number): Promise<SourceItem> {
    let ok = false;
    let message = '插件未响应搜索请求';
    try {
      const info: LxInvokeInfo = { keyword: 'music', page: 1, limit: 30 };
      const raw = await runner.invoke(id, 'musicSearch', info, 12000);
      const parsed = JSON.parse(raw) as MfSearchResp;
      const list: SongInfo[] = parsed.data === undefined || parsed.data === null ? [] : parsed.data;
      if (list.length === 0) {
        ok = true;
        message = '搜索链路正常（本次无结果，取链未验证）';
      } else {
        const first = list[0];
        const urlInfo: LxInvokeInfo = {
          source: first.source,
          quality: '128k',
          type: '128k',
          musicInfo: first
        };
        try {
          const urlRaw = await runner.invoke(id, 'musicUrl', urlInfo, 12000);
          const url = SourceRepo.pickUrl(urlRaw);
          ok = url.startsWith('http');
          message = ok ? '搜索与取链正常' : '搜索正常，但取链返回空（插件没给出可播放链接）';
        } catch (e) {
          ok = false;
          message = '搜索正常，但取链失败：' + (e instanceof Error ? e.message : String(e));
        }
      }
    } catch (e) {
      message = '搜索链路失败：' + (e instanceof Error ? e.message : String(e));
    }
    item.latency = Date.now() - started;
    item.checkedAt = Date.now();
    item.health = ok ? 'ok' : 'error';
    item.message = message + ' · ' + item.latency.toString() + 'ms';
    item.checkSkipped = 0;
    // v2.43：自检只确认能力、不反向清除。一次搜索超时不该抹掉已确认的
    // musicSearch 能力（那会让插件从搜索页消失，逼用户手动刷新）。
    if (item.actions.indexOf('musicSearch') >= 0) {
      item.mfSearchable = true;
    }
    this.persist();
    this.notify();
    return item;
  }

  /**
   * 批量自检：对每个已启用音源跑一遍完整自检（逐平台试基准曲、超时 12s），
   * 并发 3 个，跑完返回一份可展示的汇总。
   *
   * 之前还有一个「快速体检」模式（每源只试一首、超时 8s）。它的问题是结论
   * 不可靠：只试一首时，源在其它平台能不能取、失败是脚本级还是平台级，
   * 全都体现不出来，用户看到「体检通过」再点歌照样失败。既然要做就把结论
   * 做实，慢一点用并发和「脚本级错误短路」补回来。
   *
   * 返回汇总而不是 void：页面和日志都该拿到一个确定的结论，
   * 而不是各自再遍历 status 数一遍。
   */
  async checkAll(onProgress: (progress: HealthProgress) => void): Promise<CheckSummary> {
    const ids: string[] = [];
    for (const item of this.enabled()) {
      ids.push(item.id);
    }
    const summary: CheckSummary = {
      total: ids.length,
      ok: 0,
      failed: [],
      at: Date.now(),
      skipped: 0
    };
    if (ids.length === 0) {
      return summary;
    }
    const results: Map<string, SourceItem> = new Map<string, SourceItem>();
    let cursor = 0;
    let done = 0;
    const worker = async (): Promise<void> => {
      while (cursor < ids.length) {
        const id = ids[cursor];
        cursor++;
        try {
          results.set(id, await this.check(id));
        } catch (e) {
          // 单个源抛错不该让整轮自检断掉
          summary.failed.push({
            name: this.nameOf(id),
            message: e instanceof Error ? e.message : String(e)
          });
        }
        done++;
        onProgress({ id: id, done: done, total: ids.length });
      }
    };
    const pool: Array<Promise<void>> = [];
    const width = Math.min(CHECK_CONCURRENCY, ids.length);
    for (let i = 0; i < width; i++) {
      pool.push(worker());
    }
    await Promise.all(pool);
    // 按启用顺序汇总，避免并发写入导致页面里的顺序每次都不一样
    for (const id of ids) {
      const item = results.get(id);
      if (item === undefined) {
        continue;
      }
      if (item.health === 'ok') {
        summary.ok++;
      } else if (!summary.failed.some((f: CheckFailItem): boolean => f.name === item.name)) {
        summary.failed.push({ name: item.name, message: item.message });
      }
      summary.skipped += item.checkSkipped;
    }
    summary.at = Date.now();
    return summary;
  }

  private nameOf(id: string): string {
    const item = this.find(id);
    return item === null ? id : item.name;
  }

  /**
   * 脚本级故障：换平台重试也是同一个错，没必要再等两轮超时。
   *
   * 判据都是「这个源在这个进程里根本跑不起来」，而不是「这个平台给了 403」——
   * 后者换个平台很可能就好了，必须继续试。
   */
  static isFatalCheck(message: string): boolean {
    const keys: string[] = ['未注册', '未加载', '没有上报可用平台', '初始化', '脚本运行', '音源不存在'];
    for (const key of keys) {
      if (message.indexOf(key) >= 0) {
        return true;
      }
    }
    return false;
  }

  static pickUrl(raw: string): string {
    if (raw.length === 0) {
      return '';
    }
    try {
      const parsed: Object = JSON.parse(raw);
      if (typeof parsed === 'string') {
        return parsed as string;
      }
      const rec = parsed as Record<string, Object>;
      const url = rec['url'];
      return url === undefined ? '' : String(url);
    } catch (e) {
      return raw.startsWith('http') ? raw : '';
    }
  }

  /**
   * 协议识别（与 lx_bridge.html 的 detectKind 同款规则，双端一致）。
   *
   * 判据要点（v2.42 实测 63 个真实订阅插件 + 洛雪样本后重定）：
   * - 洛雪只认「运行时 API 特征」：注册 request handler / 上报 inited / 解构 globalThis.lx。
   *   `@name` 只是头注解，社区 MusicFree 插件（如元力音源）也带中文 @name，
   *   拿它当洛雪特征会把 MusicFree 插件误判成洛雪脚本。
   * - MusicFree 认「装载痕迹 + 插件形状」：CommonJS require( / module[xxx]= /
   *   module.exports= / ESM export default 等，配合 platform / getMediaSource /
   *   getLyric / search( / isEnd 等特征。混淆插件用 `module[混淆串]=plugin`
   *   导出、顶层 `var axios=require(...)`，明文没有 module.exports=，
   *   旧规则只认 module.exports= 会漏判 → 走洛雪 new Function 且 require=undefined
   *   → 报「require is not a function」。
   * - 兜底为 lx：网页 / HTML 中转页 / 未知内容由导入层另行拦截，不靠这里猜。
   */
  static detectKind(code: string): string {
    // 洛雪运行时 API 特征优先，命中即洛雪，绝不会被 MusicFree 特征抢走
    if (/EVENT_NAMES\.request|lx\.on\s*\(|lx\.send\s*\(|globalThis\.lx|window\.lx/.test(code)) {
      return 'lx';
    }
    const mfLoad = /\brequire\s*\(|module\.exports\s*=|module\s*\[|Object\.defineProperty\(\s*exports|export\s+default|__esModule|exports\.default/.test(code);
    const mfShape = /platform\s*:|getMediaSource|getLyric|getAlbumInfo|getTopListDetail|\bsearch\s*\(|isEnd/.test(code);
    return mfLoad && mfShape ? 'musicfree' : 'lx';
  }

  /**
   * 解析 MusicFree 插件订阅清单。官方格式是
   * {"desc":...,"plugins":[{"name","url","version"}...]}，社区也有纯数组形式。
   * 只收 http(s) 直链，去重并限 50 条；不是清单返回空数组（由调用方当脚本处理）。
   */
  static parseSubscription(text: string): string[] {
    const trimmed = (text ?? '').trim();
    if (trimmed.length < 2 || (trimmed.charAt(0) !== '{' && trimmed.charAt(0) !== '[')) {
      return [];
    }
    try {
      const parsed: Object = JSON.parse(trimmed);
      let list: MfSubItem[] = [];
      if (Array.isArray(parsed)) {
        list = parsed as MfSubItem[];
      } else {
        const obj = parsed as MfSubscription;
        const candidate: MfSubItem[] | undefined = obj.plugins ?? obj.list ?? obj.data ?? obj.sources;
        if (candidate !== undefined && Array.isArray(candidate)) {
          list = candidate;
        }
      }
      const urls: string[] = [];
      const seen: string[] = [];
      for (const entry of list) {
        if (entry === undefined || entry === null) {
          continue;
        }
        const url = String(entry.url ?? entry.srcUrl ?? entry.link ?? '').trim();
        if (!/^https?:\/\//i.test(url) || seen.indexOf(url) >= 0) {
          continue;
        }
        seen.push(url);
        urls.push(url);
        if (urls.length >= 50) {
          break;
        }
      }
      return urls;
    } catch (e) {
      return [];
    }
  }

  static isSubscription(text: string): boolean {
    return SourceRepo.parseSubscription(text).length > 0;
  }

  /**
   * 内容体检：链接返回的其实是网页 / HTML 中转页 / 错误页，不是音源脚本。
   * v2.42 实测订阅里的 adad23u.appinstall.life 等失效源返回
   * `<html><head><title>Loading...</title>…window.location.replace(…)`，
   * 旧逻辑只校验长度（>100）会把它当脚本存起来，执行时报
   * 「Unexpected token '<'」。这里在导入层如实拦下并给可操作提示。
   */
  static looksLikeWebPage(text: string): boolean {
    const head = String(text ?? '').replace(/^\uFEFF/, '').trim().substring(0, 256).toLowerCase();
    return head.startsWith('<!doctype') || head.startsWith('<html') ||
      head.startsWith('<head') || head.startsWith('<script') ||
      head.startsWith('<meta') || head.startsWith('<body') ||
      head.startsWith('<?xml') || head.startsWith('<title');
  }

  /** MusicFree 插件头信息从 module.exports 的字段读，不走洛雪的 @name 注解 */
  static mfMeta(code: string, key: string): string {
    const re = new RegExp('(?:^|[\\s,{])' + key + '\\s*:\\s*["\']([^"\']*)["\']', 'm');
    const m = re.exec(code);
    return m !== null ? m[1].trim() : '';
  }

  static headerName(code: string): string {
    const header = /\/\*![\s\S]*?\*\//.exec(code);
    const text = header !== null ? header[0] : code.substring(0, 600);
    const match = /@name\s+(.+)/.exec(text);
    return match !== null ? match[1].trim() : '自定义音源';
  }

  static headerVersion(code: string): string {
    const header = /\/\*![\s\S]*?\*\//.exec(code);
    const text = header !== null ? header[0] : code.substring(0, 600);
    const match = /@version\s+(.+)/.exec(text);
    return match !== null ? match[1].trim() : '';
  }

  static headerDescription(code: string): string {
    const header = /\/\*![\s\S]*?\*\//.exec(code);
    const text = header !== null ? header[0] : code.substring(0, 600);
    const match = /@description\s+(.+)/.exec(text);
    return match !== null ? match[1].trim() : '';
  }

  static headerUpdateUrl(code: string): string {
    const header = /\/\*![\s\S]*?\*\//.exec(code);
    const text = header !== null ? header[0] : code.substring(0, 600);
    const match = /@update_url\s+(.+)/.exec(text);
    return match !== null ? match[1].trim() : '';
  }
}

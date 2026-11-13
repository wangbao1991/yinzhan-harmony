import { SongInfo } from '../common/Models';
import { PlatformApi } from './PlatformApi';

/** 某首歌补到封面后的通知（key = keyOf(song)） */
export type CoverFilledListener = (key: string, url: string) => void;

/**
 * 封面补全仓库（按需 / 并发受限 / 带缓存）。
 *
 * 为什么需要：有些平台的接口**根本不返回封面字段**——
 *  - 酷我榜单 / 歌单详情的 musiclist 实测一个图片字段都没有；
 *  - 网易云专辑详情里 songs[].al 为 null，封面只在顶层 album.picUrl；
 *  - QQ 歌单/榜单偶尔缺 albummid。
 * 列表接口当时没法同步补齐（100 首要发 100 次请求，会把加载拖慢）。
 * 这里改成「渲染到哪首补哪首」：SongRow 出现时登记，后台并发补，
 * 补到后广播 coverVersion，Cover 组件重新取 URL 刷新图片。
 *
 * 同一首歌只补一次：命中缓存 / 正在进行 / 已确认补不到都不再发请求。
 */
export class CoverRepo {
  private static instance: CoverRepo = new CoverRepo();
  static get(): CoverRepo {
    return CoverRepo.instance;
  }

  private cache: Map<string, string> = new Map<string, string>();
  private pending: Set<string> = new Set<string>();
  /**
   * 补不到封面的 key → 失败时刻。
   * 以前是 Set，等于「一次失败永久作废」：网络抖动那几秒划过去的列表，
   * 之后网络恢复了也不会再补，只能重启应用。
   */
  private failed: Map<string, number> = new Map<string, number>();
  private queue: SongInfo[] = [];
  private running: number = 0;
  private maxRunning: number = 6;
  private api: PlatformApi = new PlatformApi();
  private listeners: CoverFilledListener[] = [];
  /** 版本号节流：大列表里每补到一张就广播一次，1000 行的列表会被刷 1000 遍 */
  private versionTimer: number = -1;
  private versionPending: boolean = false;
  /** key → 歌曲：图片加载失败时还能按 key 找回歌名歌手去重补 */
  private registry: Map<string, SongInfo> = new Map<string, SongInfo>();
  /**
   * 已经强制重补过的 key → 重补时刻，避免坏图 → onError → 重补 → 坏图的死循环。
   * 用带 TTL 的 Map 而不是永久 Set：过了 FAIL_TTL 允许再试一次，
   * 否则「一次坏图 + 那次补图恰好也失败」会让这首永远 ♪。
   */
  private refilled: Map<string, number> = new Map<string, number>();

  /**
   * 失败后多久允许重试。
   * 以前是 5 分钟：网络抖动那几秒划过的列表要等 5 分钟才可能再补，
   * 用户看到的就是「有的歌一直没封面，重进也一样」。缩到 60 秒，
   * 让网络恢复 / 补图接口恢复后能较快自愈，同时仍挡住「同一首无限重试」。
   */
  private static readonly FAIL_TTL: number = 60 * 1000;
  /** registry 只用于坏图重补，不需要无限增长 */
  private static readonly REGISTRY_MAX: number = 3000;
  /** 封面 URL 缓存上限：逛几千首之后也该回收一次，不然只增不减 */
  private static readonly CACHE_MAX: number = 5000;

  private isFailed(key: string): boolean {
    const at = this.failed.get(key);
    if (at === undefined) {
      return false;
    }
    if (Date.now() - at > CoverRepo.FAIL_TTL) {
      this.failed.delete(key);
      return false;
    }
    return true;
  }

  private trimCache(): void {
    if (this.cache.size <= CoverRepo.CACHE_MAX) {
      return;
    }
    const drop = Math.floor(CoverRepo.CACHE_MAX / 2);
    let removed = 0;
    const keys: string[] = [];
    for (const k of this.cache.keys()) {
      if (removed >= drop) {
        break;
      }
      keys.push(k);
      removed++;
    }
    for (const k of keys) {
      this.cache.delete(k);
    }
  }

  private trimRegistry(): void {
    if (this.registry.size <= CoverRepo.REGISTRY_MAX) {
      return;
    }
    const drop = Math.floor(CoverRepo.REGISTRY_MAX / 2);
    let removed = 0;
    const keys: string[] = [];
    for (const k of this.registry.keys()) {
      if (removed >= drop) {
        break;
      }
      keys.push(k);
      removed++;
    }
    for (const k of keys) {
      this.registry.delete(k);
    }
  }

  /** 与平台 + 歌曲绑定的 key，不同平台可能重 id */
  static keyOf(song: SongInfo): string {
    const rid = song.id.length > 0 ? song.id : song.songmid;
    if (rid.length > 0) {
      return song.source + '|' + rid;
    }
    // id / songmid 都为空（少数榜单条目、本地文件）时退到「歌名+歌手」。
    // 否则所有空 id 的歌会共用 "kw||" 同一个 key，补到的封面互相串 —— 封面错乱。
    return song.source + '|' + song.name + '|' + song.singer;
  }

  lookup(key: string): string {
    return this.cache.get(key) ?? '';
  }

  /** 订阅「补到封面」。播控中心靠它在异步补全完成后刷新封面 */
  addFilledListener(fn: CoverFilledListener): void {
    this.listeners.push(fn);
  }

  private emit(key: string, url: string): void {
    for (const fn of this.listeners) {
      try {
        fn(key, url);
      } catch (e) {
        console.warn('[LX] 封面补全回调失败: ' + String(e));
      }
    }
  }

  /** 图片加载失败时给一次备用形态：未替换的尺寸占位、协议互切 */
  static alternate(url: string): string {
    if (url.indexOf('{size}') >= 0) {
      return url.split('{size}').join('240');
    }
    if (url.startsWith('https://')) {
      return 'http://' + url.substring(8);
    }
    if (url.startsWith('http://')) {
      return 'https://' + url.substring(7);
    }
    return '';
  }

  /** 列表项出现时调用；已有封面或补过就不再处理 */
  ensure(song: SongInfo, force: boolean = false): void {
    if (song.source === 'local' || song.name.length === 0) {
      return;
    }
    const key = CoverRepo.keyOf(song);
    // 先登记：即使这首自带封面，坏图时也要能按 key 找回它
    this.registry.set(key, song);
    this.trimRegistry();
    if (!force && song.cover.length > 0) {
      return;
    }
    if (this.cache.has(key) || this.pending.has(key) || this.isFailed(key)) {
      return;
    }
    this.pending.add(key);
    this.queue.push(song);
    this.pump();
  }

  /**
   * 封面 URL 加载失败时调用：接口给了图但图是坏的（404 / 假图 / 防盗链），
   * 以前 onError 只试一次协议切换，失败就永远显示 ♪ —— 这里按 key 强制重补一次。
   */
  refill(key: string): void {
    if (key.length === 0) {
      return;
    }
    const at = this.refilled.get(key);
    if (at !== undefined && Date.now() - at <= CoverRepo.FAIL_TTL) {
      return;
    }
    const song = this.registry.get(key);
    if (song === undefined) {
      return;
    }
    this.refilled.set(key, Date.now());
    this.cache.delete(key);
    this.failed.delete(key);
    this.pending.delete(key);
    this.queue = this.queue.filter((item: SongInfo): boolean => CoverRepo.keyOf(item) !== key);
    this.ensure(song, true);
  }

  /**
   * 首个结果立即广播（用户等待感最低），200ms 内的后续结果合并成一次。
   * 不节流的话：1000 首的列表 × 每首补到封面各广播一次 = 100 万次组件回调。
   */
  private bumpVersion(): void {
    if (this.versionTimer !== -1) {
      this.versionPending = true;
      return;
    }
    AppStorage.setOrCreate('coverVersion', Date.now());
    this.versionTimer = setTimeout(() => {
      this.versionTimer = -1;
      if (this.versionPending) {
        this.versionPending = false;
        this.bumpVersion();
      }
    }, 200);
  }

  private pump(): void {
    while (this.running < this.maxRunning && this.queue.length > 0) {
      const song = this.queue.shift();
      if (song === undefined) {
        break;
      }
      this.running++;
      const key = CoverRepo.keyOf(song);
      this.api.fetchCover(song).then((url: string) => {
        this.pending.delete(key);
        if (url.length > 0) {
          this.cache.set(key, url);
          this.trimCache();
          // SongRow 拿到的 @Prop song 是副本，写回原对象不会同步；
          // 靠版本号让 Cover 组件主动来 repo 取新 URL。
          this.bumpVersion();
          // 播控中心不是 ArkUI 组件，收不到 coverVersion，必须显式通知
          this.emit(key, url);
        } else {
          this.failed.set(key, Date.now());
        }
      }).catch(() => {
        this.pending.delete(key);
        this.failed.set(key, Date.now());
      }).finally(() => {
        this.running--;
        this.pump();
      });
    }
  }
}

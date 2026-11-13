import { SongInfo, ResolveResult, LxInvokeInfo, songKey, normalizeText, SourceItem } from '../common/Models';
import { QUALITY_ORDER, qualityLabel, qualityRank, isLossless, normalizeQuality } from '../common/Constants';
import { firstSinger } from '../common/Utils';
import { SourceRepo } from './SourceRepo';
import { Settings } from './Settings';
import { PlatformApi } from './PlatformApi';
import { getText, probeAudioEx, ProbeResult } from './Http';
import { LxRunner } from './LxRunner';
import { Store } from './Store';

interface CacheItem {
  url: string;
  from: string;
  quality: string;
  format: string;
  kbps: number;
  headers: Record<string, string>;
  altSong: SongInfo | null;
  expireAt: number;
}

interface LxUrlRaw {
  url: string;
  headers: Record<string, string>;
}

interface KwDirectResp {
  code?: number;
  data?: KwDirectData;
}

interface KwDirectData {
  url?: string;
  duration?: number;
  bitrate?: number;
}

const CACHE_TTL: number = 15 * 60 * 1000;
const CACHE_MAX: number = 80;
/**
 * 单音源取链超时。音源内部常要串行发 2~4 个请求（拿 cookie → 解析 → 换链 → 解密），
 * 官方聚合包给单源 8s、总 30s。旧值 6s 经常在脚本还没跑完时就把这次取链判死，
 * 表现为「明明安卓上能出链接，这里却报超时 / 无链接」。
 * 鸿蒙这边多一层 WebView 桥接（runJavaScript 往返 + JSON 序列化），
 * 独家音源还要在取链前先拉一次 rconfig，实测 12s 仍会踩线，故放宽到 18s。
 */
const SOURCE_TIMEOUT: number = 18000;
/**
 * 有损容器的物理码率上限：MP3 ≤320kbps、AAC/M4A 极少 >400kbps、Ogg Vorbis
 * 一般 <500kbps。实测 ≥640kbps 只能是 FLAC / APE / WAV 这类无损，此时若还按
 * Content-Type: audio/mpeg 或 .mp3 后缀判有损，就会把真无损误杀（失败面板出现
 * 「FLAC：只给到320K（mp3 969kbps）」这种自相矛盾的记录）。与 Http.detectFormat
 * 的码率仲裁保持一致，这里是达标门禁的双保险。
 */
const LOSSY_MAX_KBPS: number = 640;
/**
 * 「脚本加载完但还没 inited」的宽限期：这段时间内视为「正在初始化」，
 * 允许为它等一等；超过就判定它不会上报了（脚本不支持协议 / rconfig 挂了）。
 */
const INIT_GRACE_MS: number = 45000;
/** 本轮没有就绪音源时，最多为「正在初始化」的音源等多久 */
const INIT_WAIT_MS: number = 8000;
/** 连续失败多少次进入临时降权，以及降权时长 */
const HEALTH_FAIL_THRESHOLD: number = 3;
const HEALTH_COOLDOWN_MS: number = 60 * 1000;
/**
 * MusicFree 插件替补最多并发问几个插件：这是「原平台失败」之后的兜底，
 * 每个插件都要发一次真实搜索，全量并发会拖出十几秒等待。
 * v2.49：取 mfFallbackSources()（自检 health 通过者优先、未通过者垫底但不排除，
 * 同档按音源页 order）的前 6 个有效候选 —— 已排除产出原歌的那个失败插件，
 * 所以 6 个名额全是真正值得问的插件。
 */
const MF_FALLBACK_MAX: number = 6;
/**
 * 「首选音源」独占窗口：取链时先只问用户选中的那个音源。
 *
 * 原来 1200ms 太短：脚本里 oft 那一步经常要 200ms~1s，再叠加真机 WebView 的
 * JSON 往返和音频探测，墨澜这类"正常但不算飞快"的音源经常还没回话就被别的音源
 * 抢走 —— 表现就是"我都选了墨澜，怎么一会儿全豆要一会儿星海"。
 * 现在放宽到 3000ms；只有首选超时/报错/明确说不支持，才放开其余音源补位。
 * 正常网络下首选 1s 内就会回来，实际等待并不比从前长。
 */
const PREFERRED_WINDOW_MS: number = 3000;
/** 备用链接保留时长与单曲上限：竞速取胜的那条播不了时，还能换到其它音源 */
const ALTERNATE_TTL: number = 90 * 1000;
const ALTERNATE_MAX: number = 12;
/**
 * 智能达标寻源（懒人模式）候选池：按「MusicFree 插件 / 内置平台」分组各占配额。
 *
 * v2.57 修正：旧实现把 4 个平台搜索排在 MF 插件重搜前面，各自最多留 2 首，
 * 正好把 8 个名额占满；热门歌全网都有结果时，MF 候选排第 9 位之后一个都进不了
 * 池子 —— 用户看到的就是「参与取链的全是洛雪音源」。现在两组独立预取、独立竞速，
 * MF 有专用名额，谁先回来谁先起跑，互不挤占。
 */
const SMART_MF_QUOTA: number = 6;
const SMART_PLATFORM_QUOTA: number = 4;
/**
 * 单个搜索任务的最长等待：MusicFree 插件 musicSearch 的 invoke 超时是 15s，
 * 旧实现用 Promise.all 等齐，一个卡住的插件就能把整组候选拖到总截止才展开。
 * 到点就当这一组没结果，不取消原任务（结果晚到也无害）。
 */
const SMART_SEARCH_MS: number = 7000;
/**
 * 智能达标寻源总截止时间：从发起原歌取链到所有候选歌竞速结束。
 * 必须大于「升档展开延时 + 各档取链超时」，又要小于播放器的 60s 总超时；
 * 旧值 30s 会把刚错峰起跑的升档任务提前掐断，用户看到的就是「选 FLAC 还是失败」。
 */
const SMART_DEADLINE_MS: number = 52000;
/**
 * 无损档自动升档：档位是离散 SKU，不是「高低阶梯」。
 * 音源脚本按档位名查自己的映射表（如 flac→2000kflac、atmos→20201kmflac），
 * 很多后端只收录了 atmos/master 却没收录 flac。若只死磕一个档位，就会出现
 * 「选 FLAC 全部失败、选全景声反而能播」的反直觉现象。
 *
 * 关键教训：绝不能拿音源 inited 上报的 qualitys 当白名单来决定「能升哪些档」——
 * trySources 那段注释已经写明「inited 上报的 qualitys 普遍残缺」，很多脚本压根不
 * 声明 atmos/master，但 musicUrl 收到这个档位名照样给链接。上一版用
 * availableQualities(song) 硬过滤，白名单里没有 atmos 时 huntQualities 只返回
 * ['flac']，huntExpandRace 一行请求都不发，升档等于没做。
 * 这里改为「所有不低于目标档的无损档全展开，声明过的只排前面、不删任何档」。
 */
const HUNT_MAX_QUALITIES: number = 6;
/** 主档先独占这么久；没出结果才展开升档，避免主档有货时白白发几十个请求 */
const HUNT_EXPAND_MS: number = 1500;
/** 升档各档之间再错峰起跑，把请求量摊开，别一次性打满触发平台风控 */
const HUNT_STAGGER_MS: number = 250;

/** 主档是否已出达标结果：互备档据此决定还要不要发请求 */
interface HuntGate {
  done: boolean;
}

/** 本轮 MusicFree 插件重搜的参与情况，失败面板据此说明「插件到底有没有参与」 */
interface MfPoolStat {
  tried: number;
  hit: number;
  /** 用了几轮关键词：1 = 主关键词够用；2 = 主关键词全落空，已退回纯歌名 */
  rounds: number;
}

interface RaceState {
  left: number;
  settled: boolean;
}

/**
 * 一次 resolve 过程内的可变状态。
 * 以前这两个值是 Resolver 单例上的字段：播放取链和 prefetchNext 并发时互相覆盖，
 * 会把「首选音源独占窗口」重置、把失败原因串成另一首歌的。
 */
interface ResolveState {
  preferredWindowUsed: boolean;
  /** 本轮是否只认首选（已把「连续失败自动补位」算进去） */
  oneOnly: boolean;
  /** 首选连续失败触发了强制补位，失败提示里要如实说明 */
  forcedFallback: boolean;
  /** 实际参与取链的音源数，失败提示里如实告诉用户「装了十几个源到底问了几个」 */
  candidateCount: number;
}

/** 备用链接：其它音源同时给出、但竞速没选中的播放地址 */
interface Alternate {
  result: ResolveResult;
  sourceId: string;
  /** 探测是否通过。换源时优先挑探测通过的，未探测/探测失败的留作最后兜底 */
  verified: boolean;
  expireAt: number;
}

/** 音源健康度：按「音源 + 平台」分别记，避免一个平台全挂就废掉整个音源 */
interface HealthStat {
  failStreak: number;
  cooldownUntil: number;
  success: number;
}

/** 一条取链失败记录：带上音源名和「是否首选」，保证最终提示不误导 */
interface FailNote {
  name: string;
  text: string;
  preferred: boolean;
}

/** 给失败面板用的详情：逐条列「问了谁、为什么没成」 */
export interface FailDetail {
  name: string;
  text: string;
  preferred: boolean;
}

/**
 * 歌 → 源亲和：上次哪个音源真的给过这首歌。
 * 只影响「先问谁」，不排它 —— 它这次给不出来，别的源照样会补位。
 */
interface AffinityEntry {
  sourceId: string;
  at: number;
}

/** 亲和表上限：按歌曲记，超过就丢最旧的，避免无限增长 */
const AFFINITY_MAX: number = 500;
const AFFINITY_KEY: string = 'v4_source_affinity';

/**
 * 播放地址解析（v4）
 *
 * 顺序：
 *   1) 缓存
 *   2) 已启用音源（按用户排序）逐个取链，逐条做「真实音频探测」
 *   3) 跨平台换源：歌本身所在平台取不到时，去其它平台找同一首歌再取链
 *   4) 酷我公开直连（最后的兜底，通常是试听片段，会被体积校验挡掉）
 *
 * 每次取链都做体积校验：宁可明确告诉用户「这首歌没有可用音源」，
 * 也不要把 11 秒的试听片段当整首播出去。
 */
export class Resolver {
  private static instance: Resolver = new Resolver();
  static get(): Resolver {
    return Resolver.instance;
  }

  private cache: Map<string, CacheItem> = new Map<string, CacheItem>();
  /**
   * 同 key 在途取链。预加载与切歌取链会撞在同一首歌上：没有它，预取还在
   * 跑全源寻源时切歌会再起一遍（双倍请求、弱网下更慢）。命中在途任务直接
   * 等它完成即可，这才是「预加载」真正省下的时间。
   */
  private inflight: Map<string, Promise<ResolveResult>> = new Map<string, Promise<ResolveResult>>();
  private sources: SourceRepo = SourceRepo.get();
  private api: PlatformApi = new PlatformApi();
  /** 音源 + 平台维度的健康度，跨取链保留（进程内有效，重启后重新学习） */
  private static health: Map<string, HealthStat> = new Map<string, HealthStat>();
  /**
   * 备用链接池：按歌曲存所有音源给出的地址。
   * 以前竞速只留最快那一条，其余十几个源的结果直接丢弃；那条链接一旦在
   * AVPlayer 里 prepare 失败，应用就直接报错跳歌，看起来「只试了一个源」。
   */
  private alternates: Map<string, Alternate[]> = new Map<string, Alternate[]>();
  /** 最近一次失败的全部凭据，播放页的失败面板据此逐条展示 */
  private lastNotes: FailNote[] = [];
  /** 最近一次失败时实际参与取链的音源数 */
  private lastCount: number = 0;
  /** 歌 → 源亲和表（懒加载，来自持久化） */
  private affinity: Map<string, AffinityEntry> | null = null;
  clearCache(): void {
    this.cache.clear();
    this.alternates.clear();
    this.inflight.clear();
  }

  cacheSize(): number {
    return this.cache.size;
  }

  /** 最近一次失败问了哪些音源、各自为什么没成（播放页失败面板用） */
  getLastFailure(): FailDetail[] {
    const list: FailDetail[] = [];
    for (const note of this.lastNotes) {
      list.push({ name: note.name, text: note.text, preferred: note.preferred });
    }
    return list;
  }

  /** 最近一次失败时参与取链的音源数 */
  getLastCandidateCount(): number {
    return this.lastCount;
  }

  /* ------------------------- 歌 → 源亲和 ------------------------- */

  /**
   * 亲和表懒加载：第一次用到才读盘，读坏了就当空表。
   * 结构是 { "歌曲id@平台": { "sourceId": ..., "at": 时间戳 } }
   */
  private affinityTable(): Map<string, AffinityEntry> {
    if (this.affinity !== null) {
      return this.affinity;
    }
    const table: Map<string, AffinityEntry> = new Map<string, AffinityEntry>();
    if (!Store.get().isReady()) {
      // 还没初始化完就先别缓存空表，否则这一进程内永远学不到东西
      return table;
    }
    try {
      const raw = Store.get().getString(AFFINITY_KEY, '');
      if (raw.length > 0) {
        const obj = JSON.parse(raw) as Record<string, AffinityEntry>;
        for (const key of Object.keys(obj)) {
          const entry = obj[key];
          if (entry !== undefined && entry.sourceId !== undefined && entry.sourceId.length > 0) {
            table.set(key, { sourceId: entry.sourceId, at: typeof entry.at === 'number' ? entry.at : 0 });
          }
        }
      }
    } catch (e) {
      console.error('[Resolver] 亲和表读取失败 ' + String(e));
    }
    this.affinity = table;
    return table;
  }

  /** 这首歌上次是哪个音源给的（没有则空串） */
  private affinitySource(song: SongInfo): string {
    if (!Settings.get().rememberSource()) {
      return '';
    }
    const entry = this.affinityTable().get(Resolver.alternateKey(song));
    return entry === undefined ? '' : entry.sourceId;
  }

  /**
   * 记下「这首歌这次是谁给的」。
   *
   * 为什么值得记：同一首歌反复播时，上次能给的源这次多半还能给，
   * 而健康度只在失败后才起作用 —— 每次重新竞速等于每首都从零开始猜。
   * 记下来只改变「先问谁」，不影响其余音源补位，也不会把坏源永久钉死：
   * 它下次失败照样进健康度惩罚，亲和只在同分时起作用。
   */
  private rememberSource(song: SongInfo, sourceId: string): void {
    if (sourceId.length === 0 || !Settings.get().rememberSource()) {
      return;
    }
    const table = this.affinityTable();
    const key = Resolver.alternateKey(song);
    const old = table.get(key);
    if (old !== undefined && old.sourceId === sourceId) {
      old.at = Date.now();
      this.saveAffinity(table);
      return;
    }
    table.set(key, { sourceId: sourceId, at: Date.now() });
    if (table.size > AFFINITY_MAX) {
      // 超上限先按时间淘汰最旧的一批，保留近期命中
      const entries: Array<[string, AffinityEntry]> = [];
      table.forEach((value: AffinityEntry, k: string): void => {
        entries.push([k, value]);
      });
      entries.sort((a: [string, AffinityEntry], b: [string, AffinityEntry]): number => a[1].at - b[1].at);
      const drop = table.size - AFFINITY_MAX;
      for (let i = 0; i < drop; i++) {
        table.delete(entries[i][0]);
      }
    }
    this.saveAffinity(table);
  }

  /** 落盘：用 putLater，交给系统合并写；失败不影响播放 */
  private saveAffinity(table: Map<string, AffinityEntry>): void {
    try {
      const obj: Record<string, AffinityEntry> = {};
      table.forEach((value: AffinityEntry, key: string): void => {
        obj[key] = value;
      });
      Store.get().putLater(AFFINITY_KEY, JSON.stringify(obj));
    } catch (e) {
      console.error('[Resolver] 亲和表写入失败 ' + String(e));
    }
  }

  private static alternateKey(song: SongInfo): string {
    return song.id + '@' + song.source;
  }

  /** 每个成功取到链接的音源都留一份，不因竞速落选而丢弃 */
  private offerAlternate(song: SongInfo, item: SourceItem, result: ResolveResult,
    verified: boolean): void {
    const key = Resolver.alternateKey(song);
    const list = this.alternates.get(key) ?? [];
    for (const alt of list) {
      if (alt.result.url === result.url) {
        return;
      }
    }
    list.push({
      result: result,
      sourceId: item.id,
      verified: verified,
      expireAt: Date.now() + ALTERNATE_TTL
    });
    if (list.length > ALTERNATE_MAX) {
      list.shift();
    }
    list.sort((a: Alternate, b: Alternate): number => {
      const rank = ((b.verified ? 1 : 0) - (a.verified ? 1 : 0)) * 100;
      return rank + Resolver.penalty(a.sourceId, song.source) - Resolver.penalty(b.sourceId, song.source);
    });
    this.alternates.set(key, list);
  }

  /**
   * 播放准备失败后换一条还没试过的链接。
   * 优先挑探测通过的；并把刚失败那条对应的音源降权，避免下次又先选它。
   */
  takeAlternative(song: SongInfo, failedUrl: string): ResolveResult | null {
    // 刚播失败的地址不能继续留在 15 分钟缓存里，否则下次点同一首又先拿到它
    this.cache.forEach((item: CacheItem, cacheKey: string): void => {
      if (item.url === failedUrl) {
        this.cache.delete(cacheKey);
      }
    });
    const key = Resolver.alternateKey(song);
    const list = this.alternates.get(key);
    if (list === undefined) {
      return null;
    }
    const now = Date.now();
    const alive: Alternate[] = [];
    for (const alt of list) {
      if (alt.result.url === failedUrl) {
        Resolver.markFail(alt.sourceId, song.source, '播放准备失败');
        continue;
      }
      if (alt.expireAt > now) {
        alive.push(alt);
      }
    }
    if (alive.length === 0) {
      this.alternates.set(key, alive);
      return null;
    }
    const picked = alive[0];
    alive.splice(0, 1);
    this.alternates.set(key, alive);
    return picked.result;
  }

  /** 当前这首歌还有几条备用链接，用于界面提示与回归测试 */
  alternateCount(song: SongInfo): number {
    const list = this.alternates.get(Resolver.alternateKey(song));
    if (list === undefined) {
      return 0;
    }
    let n = 0;
    for (const alt of list) {
      if (alt.expireAt > Date.now()) {
        n++;
      }
    }
    return n;
  }

  private static healthKey(id: string, platform: string): string {
    return id + '|' + platform;
  }

  private static healthOf(key: string): HealthStat {
    let stat = Resolver.health.get(key);
    if (stat === undefined) {
      stat = { failStreak: 0, cooldownUntil: 0, success: 0 };
      Resolver.health.set(key, stat);
    }
    return stat;
  }

  private static markOk(id: string, platform: string): void {
    const stat = Resolver.healthOf(Resolver.healthKey(id, platform));
    stat.failStreak = 0;
    stat.cooldownUntil = 0;
    stat.success++;
  }

  private static markFail(id: string, platform: string, reason: string): void {
    const stat = Resolver.healthOf(Resolver.healthKey(id, platform));
    // 后端被封 / 链接失效比「这首歌没有」严重得多，直接连计两次
    stat.failStreak += Resolver.isServerFailure(reason) ? 2 : 1;
    if (stat.failStreak >= HEALTH_FAIL_THRESHOLD) {
      stat.cooldownUntil = Date.now() + HEALTH_COOLDOWN_MS;
    }
  }

  /** 排序用：数值越大越靠后。冷却期内排最后，成功过的往前挪一点 */
  private static penalty(id: string, platform: string): number {
    const stat = Resolver.health.get(Resolver.healthKey(id, platform));
    if (stat === undefined) {
      return 0;
    }
    let value = stat.failStreak * 10;
    if (stat.cooldownUntil > Date.now()) {
      value += 100;
    }
    return value - Math.min(stat.success, 5);
  }

  /** 首选在「本平台」上的连续失败次数，用于决定要不要临时放开补位 */
  private static preferredFailStreak(platform: string): number {
    const active = SourceRepo.get().getActive();
    if (active === null) {
      return 0;
    }
    const stat = Resolver.health.get(Resolver.healthKey(active.id, platform));
    return stat === undefined ? 0 : stat.failStreak;
  }

  private static isServerFailure(text: string): boolean {
    return text.indexOf('403') >= 0 || text.indexOf('404') >= 0 ||
      text.indexOf('已屏蔽') >= 0 || text.indexOf('接口拒绝') >= 0 ||
      text.indexOf('接口已失效') >= 0 || text.indexOf('429') >= 0 ||
      text.indexOf('超时') >= 0;
  }

  /** 探测给出的「明确不能用」结论；网络异常 / 判断不了的情况不算，仍信任音源 */
  private static isFatalProbe(reason: string): boolean {
    return reason.indexOf('HTTP 4') >= 0 || reason.indexOf('HTTP 5') >= 0 ||
      reason.indexOf('返回的不是音频') >= 0 || reason.indexOf('试听片段') >= 0 ||
      reason.indexOf('不是网络地址') >= 0 || reason.indexOf('跳转无地址') >= 0 ||
      reason.indexOf('跳转次数过多') >= 0;
  }

  /**
   * 失败原因分诊：把音源抛出来的原始字符串翻成「用户能据此行动」的话。
   * 以前一律显示 "HTTP 404" / "后端失败: xxx"，看不出是接口被封、链接过期，
   * 还是应用自己判死，用户只能笼统地说「基本上都会报错」。
   */
  private static explain(text: string): string {
    const t = text.length > 60 ? text.substring(0, 60) : text;
    if (t.indexOf('403') >= 0 || t.indexOf('接口拒绝访问') >= 0 || t.indexOf('已屏蔽') >= 0) {
      return '音源后端拒绝访问（403），非应用问题，建议换音源';
    }
    if (t.indexOf('接口已失效') >= 0 || t.indexOf('HTTP 404') >= 0 || t.indexOf('404') >= 0) {
      return '链接失效或被拒（404），换首歌或换个音源';
    }
    if (t.indexOf('429') >= 0 || t.indexOf('请求过于频繁') >= 0) {
      return '音源接口请求过频（429），稍后再试';
    }
    if (t.indexOf('服务器出错') >= 0) {
      return '音源服务器出错，稍后再试';
    }
    if (t.indexOf('超时') >= 0 || t.indexOf('timeout') >= 0) {
      return '音源响应超时，已跳过';
    }
    if (t.indexOf('返回的不是音频') >= 0 || t.indexOf('不是网络地址') >= 0) {
      return '音源返回的不是音频';
    }
    return t;
  }

  /**
   * @param strict 是否严格要求音质。下载时必须为 true：
   *               音源偷偷回 128k 的 mp3 时要当场拒绝，而不是改名成 .flac 存下来。
   */
  async resolve(song: SongInfo, quality: string, strict: boolean = false): Promise<ResolveResult> {
    const smart: boolean = Settings.get().smartHunt() && quality.length > 0;
    const gateKey: string = (smart ? 'hunt|' : '') + this.cacheKey(song, quality) +
      (strict ? '|s' : '');
    const running = this.inflight.get(gateKey);
    if (running !== undefined) {
      return await running;
    }
    const task: Promise<ResolveResult> = this.doResolve(song, quality, strict);
    this.inflight.set(gateKey, task);
    try {
      return await task;
    } finally {
      this.inflight.delete(gateKey);
    }
  }

  /** 实际取链主体；由 resolve() 包装成「同 key 在途只跑一次」 */
  private async doResolve(song: SongInfo, quality: string, strict: boolean): Promise<ResolveResult> {
    // 智能达标寻源（懒人模式）：单独一条路径，老的分阶段取链完全不参与。
    // 关掉开关就回到旧行为，方便随时回退对比。
    if (Settings.get().smartHunt() && quality.length > 0) {
      return await this.smartResolve(song, quality, strict);
    }
    const key = this.cacheKey(song, quality);
    // 「只用首选音源」是用户偏好，但首选若在本平台连续被后端拒绝，就临时放开
    // 其它音源补位 —— 否则一个 403 的后端会让整个应用「基本上都报错」。
    // 用户可以在音源选项里关掉这个兜底。
    const preferOnly = Settings.get().preferOnly();
    const forcedFallback = preferOnly && Settings.get().autoFallbackOnFailure() &&
      Resolver.preferredFailStreak(song.source) >= 2;
    const oneOnly = preferOnly && !forcedFallback;
    const hit = this.cache.get(key);
    if (hit !== undefined && hit.expireAt > Date.now()) {
      const usable = !strict || qualityRank(hit.quality) >= qualityRank(quality);
      // 只认首选时，缓存里那条如果当初是别的音源给的，同样不能用
      if (usable && (!oneOnly || this.isPreferredFrom(hit.from))) {
        const result: ResolveResult = {
          url: hit.url,
          from: hit.from,
          quality: hit.quality,
          format: hit.format,
          kbps: hit.kbps,
          headers: hit.headers,
          altSong: hit.altSong ?? undefined
        };
        return result;
      }
    }
    // 一次 resolve 里只给首选一次独占窗口，避免多档音质/换源重复等待拖慢取链
    const state: ResolveState = {
      preferredWindowUsed: false,
      oneOnly: oneOnly,
      forcedFallback: forcedFallback,
      candidateCount: 0
    };
    const chain = strict ? this.strictChain(song, quality) : this.qualityChain(song, quality);
    const notes: FailNote[] = [];
    // 每次取链先清掉上一次的失败凭据，避免面板展示过期原因
    this.lastNotes = [];
    this.lastCount = 0;

    // 2. 原平台
    for (const q of chain) {
      const direct = await this.trySources(song, q, notes, strict, state);
      if (direct !== null) {
        this.put(key, direct);
        return direct;
      }
    }

    // 只认首选音源时到此为止：换源＝换成别的音源，正是用户不想要的
    if (state.oneOnly) {
      Resolver.fillEmptyNote(notes);
      this.lastNotes = notes;
      this.lastCount = state.candidateCount;
      throw new Error(Resolver.buildStrictError(notes, strict ? qualityLabel(quality) : '',
        state.candidateCount));
    }

    // 2.5 MusicFree 插件替补（v2.45）
    // 洛雪来源的歌 source 是 wy/kw/qq/…，而 MusicFree 插件上报的 platforms 是
    // 'mf:<实例id>'，两者对不上，trySources 在「组装候选池」这一步就把插件过滤掉了 ——
    // 这就是「把洛雪音源全部关闭后，点播放 MusicFree 死活不启用」的根因。
    // 真实接法：拿歌名 + 首歌手去每个可搜索插件重搜，用与跨平台换源同一套
    // pickBest 严格同名匹配，拿回带 mfRaw 的插件歌曲，再交给 trySources ——
    // 此时第一道 mfRaw 守卫会精确只放行「产出这首歌」的那个插件，取链链路闭合。
    // 位置在 oneOnly 判断之后：用户选了「只用首选音源」就绝不替补；且优先于
    // 跨平台换源，因为换源拿到的仍是平台歌，洛雪全关时那条路同样取不到链。
    // 只在阶段 2 全部失败后才走到这里，正常播放不额外发请求。
    const mfAlts = await this.findMusicFreeAlternatives(song);
    if (mfAlts.length > 0) {
      for (const mfAlt of mfAlts) {
        for (const q of chain) {
          const result = await this.trySources(mfAlt, q, notes, strict, state);
          if (result !== null) {
            result.from = result.from + ' · 插件替补';
            result.altSong = mfAlt;
            this.put(key, result);
            return result;
          }
        }
      }
    } else if (this.sources.mfFallbackSources().length > 0) {
      notes.push({
        name: 'MusicFree 插件',
        text: '按自检通过优先的顺序问过插件，没搜到同名同歌手的歌曲，本次未能替补',
        preferred: false
      });
    }

    // 3. 跨平台换源
    // v2.49：洛雪音源一个都没启用时跳过，不再空转 5 次内置平台搜索（见 hasEnabledLxSource）。
    let alt: SongInfo | null = null;
    if (this.hasEnabledLxSource()) {
      alt = await this.findAlternative(song);
    } else {
      notes.push({
        name: '跨平台换源',
        text: '洛雪音源都已关闭，换到的平台歌没有音源能取链，本次跳过',
        preferred: false
      });
    }
    if (alt !== null) {
      for (const q of chain) {
        const result = await this.trySources(alt, q, notes, strict, state);
        if (result !== null) {
          result.from = result.from + ' · 换源';
          result.altSong = alt;
          this.put(key, result);
          return result;
        }
      }
    }

    // 4. 酷我直连（只有 128k，要求更高音质时没意义）
    if (!strict || qualityRank(quality) <= 1) {
      try {
        const direct = await this.kuwoDirect(song, notes);
        if (direct !== null) {
          this.put(key, direct);
          return direct;
        }
      } catch (e) {
        const directNote: FailNote = { name: '酷我直连', text: Resolver.short(e), preferred: false };
        notes.push(directNote);
      }
    }

    // 提示必须把「用户选的首选音源」放在最前面，并且明确说明其余音源只是补位。
    // 旧版直接把并发音源的失败原因按到达顺序拼前 4 条，用户会误以为下载用的是括号里那个音源。
    Resolver.fillEmptyNote(notes);
    this.lastNotes = notes;
    this.lastCount = state.candidateCount;
    const reasons = Resolver.formatReasons(notes);
    const fallbackTip = state.forcedFallback ? '（首选连续失败，已临时允许其它音源补位）' : '';
    const countTip = '（共 ' + state.candidateCount.toString() + ' 个音源参与取链）';
    if (strict) {
      throw new Error('音源给不了' + qualityLabel(quality) + reasons + fallbackTip + countTip);
    }
    throw new Error('这首歌暂时取不到完整音频' + reasons + fallbackTip + countTip);
  }

  /**
   * 智能达标寻源（懒人模式）。
   *
   * 与老链路相反：目标音质 want 是硬门禁，先只问这一档、绝不降质；这一档
   * 全军覆没时自动向「不低于目标档」的更高无损档升档（FLAC → Hi-Res → 全景声 → 母带）；
   * 「原歌 + 全部可用音源」和「跨平台同款 + MusicFree 插件同款」同时起跑，
   * 谁先给出达标结果谁胜出。每首候选歌自带 source / mfRaw，trySources 的
   * 平台声明与 mfRaw 守卫会自动把取链任务路由到能接它的音源 —— 不需要放宽
   * 协议边界，也就不会拿 wy 的 id 去硬问只支持 kw 的脚本。
   *
   * 全问过仍不达标：明确抛错，列出各源实际给到什么档，绝不降到 320k 充数。
   */
  private async smartResolve(song: SongInfo, want: string, strict: boolean): Promise<ResolveResult> {
    const key = 'hunt|' + this.cacheKey(song, want);
    const hit = this.cache.get(key);
    if (hit !== undefined && hit.expireAt > Date.now()) {
      const cached: ResolveResult = {
        url: hit.url, from: hit.from, quality: hit.quality, format: hit.format,
        kbps: hit.kbps, headers: hit.headers, altSong: hit.altSong ?? undefined
      };
      return cached;
    }
    const notes: FailNote[] = [];
    const states: ResolveState[] = [];
    this.lastNotes = [];
    this.lastCount = 0;

    // 原歌立刻起跑，不等候选池：正常情况零额外延迟
    const gate: HuntGate = { done: false };
    const directState: ResolveState = this.freshHuntState();
    states.push(directState);
    const direct: Promise<ResolveResult | null> =
      this.markWinner(this.trySources(song, want, notes, strict, directState, true), gate);

    // 候选池分两组独立预取、独立竞速：MusicFree 插件组不再排在平台组后面等名额，
    // 也不会被一个卡住 15s 的插件拖到总截止才展开。两组各自有专用配额。
    const mfStat: MfPoolStat = { tried: 0, hit: 0, rounds: 0 };
    const mfPromise: Promise<SongInfo[]> = this.smartMfPool(song, mfStat);
    const platPromise: Promise<SongInfo[]> = this.smartPlatformPool(song);
    const poolRace: Promise<ResolveResult | null> = this.markWinner(Resolver.firstUsable([
      this.smartPoolRace(mfPromise, song, want, notes, strict, states),
      this.smartPoolRace(platPromise, song, want, notes, strict, states)
    ]), gate);

    // 无损档自动升档：主档一段时间没结果才展开，且只在「原歌」这一路展开。
    // 候选歌本身已是跨源维度，再乘档位会把请求量放大到触发风控。
    const expandRace: Promise<ResolveResult | null> =
      this.huntExpandRace(song, want, notes, strict, gate);

    const winner = await Resolver.withDeadline(
      Resolver.firstUsable([direct, poolRace, expandRace]), SMART_DEADLINE_MS);

    let total = 0;
    for (const st of states) {
      total += st.candidateCount;
    }
    if (winner !== null) {
      this.put(key, winner);
      this.lastNotes = notes;
      this.lastCount = total;
      return winner;
    }
    // 失败时把 MusicFree 的参与情况写进凭据，别让用户对着「全是洛雪音源」的列表猜
    notes.push(Resolver.mfNote(mfStat, notes));
    // 升档清单必须进失败面板：以前只拼在 error 文案里，而面板只渲染 lastNotes，
    // 用户永远看不到「到底升过哪几档」，会误以为升档压根没跑。
    let qTip = '';
    const tried = Resolver.huntQualities(want, this.availableQualities(song));
    if (tried.length > 1) {
      let names = '';
      for (const q of tried) {
        names += (names.length > 0 ? ' / ' : '') + qualityLabel(q);
      }
      qTip = '已自动升档尝试：' + names;
      notes.push({ name: '自动升档', text: qTip + '（每档都问过全部音源）', preferred: false });
    }
    Resolver.fillEmptyNote(notes);
    this.lastNotes = notes;
    this.lastCount = total;
    throw new Error('所有音源都给不到' + qualityLabel(want) +
      (qTip.length > 0 ? '（' + qTip + '）' : '') +
      '，已按「绝不降质」停止（没有换成低音质）' + Resolver.formatReasons(notes) +
      '（共 ' + total.toString() + ' 个音源参与取链）');
  }

  private freshHuntState(): ResolveState {
    return { preferredWindowUsed: false, oneOnly: false, forcedFallback: false, candidateCount: 0 };
  }

  /** 主档一旦出达标结果就关门，后面错峰的互备档不再发请求 */
  private async markWinner(task: Promise<ResolveResult | null>,
    gate: HuntGate): Promise<ResolveResult | null> {
    const r = await task;
    if (r !== null) {
      gate.done = true;
    }
    return r;
  }

  /**
   * 无损档自动升档集合：FLAC 拿不到 → Hi-Res → Hi-Res+ → 全景声 → 全景声+ → 母带。
   *
   * 档位不是「从 128k 到母带的连续阶梯」，而是各自映射到音源脚本里不同
   * SKU / 不同后端的离散 key。只死磕一个档位，会漏掉「这个音源没有 flac
   * 但 atmos 有货」的整批供给。这里只向「不低于目标档」的无损档展开，
   * 绝不往下降（不破坏绝不降质）。
   *
   * available 只用来排优先级，**不是白名单**：inited 上报的 qualitys 普遍残缺，
   * 大量脚本不声明 atmos/master，但 musicUrl 收到这个档位名照样能给链接。
   * 上一版把它当白名单（`available.indexOf(q) < 0 → continue`），用户场景里
   * 白名单恰好没有 atmos，于是升档集合只剩 ['flac']，一次升档请求都没发出去。
   */
  private static huntQualities(want: string, available: string[]): string[] {
    const out: string[] = [want];
    if (!isLossless(want)) {
      return out;
    }
    const floor = qualityRank(want);
    // QUALITY_ORDER 从高到低，倒着遍历即「只高一级 → 最高档」，近的先起跑
    const higher: string[] = [];
    for (let i = QUALITY_ORDER.length - 1; i >= 0; i--) {
      const q = QUALITY_ORDER[i];
      if (out.indexOf(q) >= 0 || !isLossless(q) || qualityRank(q) < floor) {
        continue;
      }
      higher.push(q);
    }
    // 声明过的档排前面，没声明的排在后面但一个都不删
    const ordered: string[] = [];
    for (const q of higher) {
      if (available.length > 0 && available.indexOf(q) >= 0) {
        ordered.push(q);
      }
    }
    for (const q of higher) {
      if (ordered.indexOf(q) < 0) {
        ordered.push(q);
      }
    }
    for (const q of ordered) {
      if (out.length >= HUNT_MAX_QUALITIES) {
        break;
      }
      out.push(q);
    }
    return out;
  }

  /**
   * 主档独占 HUNT_EXPAND_MS；这段时间里 direct / 候选池任一路出结果就关门，
   * 升档一个请求都不发。只有主档全都没戏，才把更高无损档错峰并发起来
   * （全部无损档都问，不再受音源声明残缺的 qualitys 限制）。
   */
  private async huntExpandRace(song: SongInfo, want: string, notes: FailNote[],
    strict: boolean, gate: HuntGate): Promise<ResolveResult | null> {
    const qualities = Resolver.huntQualities(want, this.availableQualities(song));
    if (qualities.length <= 1) {
      return null;
    }
    await new Promise<void>((resolve): void => {
      setTimeout((): void => {
        resolve();
      }, HUNT_EXPAND_MS);
    });
    if (gate.done) {
      return null;
    }
    const tasks: Array<Promise<ResolveResult | null>> = [];
    for (let i = 1; i < qualities.length; i++) {
      tasks.push(this.huntOneQuality(song, qualities[i], notes, strict,
        gate, (i - 1) * HUNT_STAGGER_MS));
    }
    return await Resolver.firstUsable(tasks);
  }

  /** 单个升档：错峰等待 → 再次确认没被短路 → 全源竞速问这一档 */
  private async huntOneQuality(song: SongInfo, quality: string, notes: FailNote[],
    strict: boolean, gate: HuntGate, delay: number): Promise<ResolveResult | null> {
    if (delay > 0) {
      await new Promise<void>((resolve): void => {
        setTimeout((): void => {
          resolve();
        }, delay);
      });
    }
    if (gate.done) {
      return null;
    }
    // 升档不再等「首选 3 秒独占窗口」，直接全源并发；
    // state 不并进 states：总计数只反映主档参与的音源数，升档尝试在 notes 里逐条可见。
    const st: ResolveState = this.freshHuntState();
    st.preferredWindowUsed = true;
    const r = await this.trySources(song, quality, notes, strict, st, true);
    if (r !== null) {
      r.from = r.from + ' · ' + qualityLabel(quality) + '档自动升档';
      gate.done = true;
    }
    return r;
  }

  /** 候选池回来后，每首候选歌各自全源竞速，再并入总竞速 */
  private async smartPoolRace(poolPromise: Promise<SongInfo[]>, origin: SongInfo, want: string,
    notes: FailNote[], strict: boolean, states: ResolveState[]): Promise<ResolveResult | null> {
    let pool: SongInfo[] = [];
    try {
      pool = await poolPromise;
    } catch (e) {
      return null;
    }
    const subs: Array<Promise<ResolveResult | null>> = [];
    for (const cand of pool) {
      const st: ResolveState = this.freshHuntState();
      states.push(st);
      subs.push(this.smartTryOne(cand, origin, want, notes, strict, st));
    }
    if (subs.length === 0) {
      return null;
    }
    return await Resolver.firstUsable(subs);
  }

  /** 单首候选歌取链；命中后标出实际用的同款，播放器取词 / 封面都跟着它走 */
  private async smartTryOne(cand: SongInfo, origin: SongInfo, want: string,
    notes: FailNote[], strict: boolean, state: ResolveState): Promise<ResolveResult | null> {
    const before = notes.length;
    const r = await this.trySources(cand, want, notes, strict, state, true);
    // trySources 在「一个就绪源都没有」时直接 return null 且不写任何 note，
    // 插件重搜明明命中了却会静默消失。补一条，让它在失败面板上可见。
    if (r === null && notes.length === before &&
      cand.mfRaw !== undefined && cand.mfRaw.length > 0) {
      notes.push({
        name: 'MusicFree · ' + cand.name,
        text: '插件重搜到了同款，但当前没有就绪的取链源（未加载 / 未 inited / 平台不匹配），本轮没真正问到它',
        preferred: false
      });
    }
    if (r === null || cand === origin) {
      return r;
    }
    r.altSong = cand;
    r.from = r.from + ' · 智能寻源';
    return r;
  }

  /**
   * 把 MusicFree 插件这轮的参与情况写成一条可见的失败凭据。
   * v2.57：按失败原因分类，别让用户把「命中同款但取链全挂」误读成「搜不到」。
   */
  private static mfNote(stat: MfPoolStat, notes: FailNote[]): FailNote {
    if (stat.tried === 0) {
      return {
        name: 'MusicFree 插件',
        text: '本轮没有可用插件参与（需已启用、已加载、并声明 musicSearch）；' +
          '官方平台歌单里的歌没有 mfRaw，插件无法直接取链，只能靠按名重搜同款',
        preferred: false
      };
    }
    const roundTip = stat.rounds > 1 ? '（主关键词没结果，已退回纯歌名重搜）' : '';
    if (stat.hit === 0) {
      return {
        name: 'MusicFree 插件',
        text: '重搜了 ' + stat.tried.toString() + ' 个插件' + roundTip + '，没有匹配到同款' +
          '（关键词清洗后仍搜不到、结果没带 mfRaw，或插件搜索超时 / 返回空）；可到音源管理看自检状态',
        preferred: false
      };
    }
    // 把这一轮真正的取链失败按原因归类：搜到了 ≠ 取得到链
    let trial = 0;
    let backend = 0;
    let below = 0;
    let other = 0;
    for (const n of notes) {
      const t = n.text;
      if (t.indexOf('试听片段') >= 0) {
        trial++;
      } else if (t.indexOf('插件取链异常') >= 0 || t.indexOf('聚合取链失败') >= 0 ||
        t.indexOf('所有可用源均未取得') >= 0 || t.indexOf('取链失败') >= 0) {
        backend++;
      } else if (t.indexOf('只给到') >= 0 || t.indexOf('无链接') >= 0 || t.indexOf('音质') >= 0) {
        below++;
      } else {
        other++;
      }
    }
    const parts: string[] = [];
    if (trial > 0) {
      parts.push('试听片段 ' + trial.toString());
    }
    if (backend > 0) {
      parts.push('插件后端取链失败 ' + backend.toString());
    }
    if (below > 0) {
      parts.push('音质未达标 / 无链接 ' + below.toString());
    }
    if (other > 0) {
      parts.push('其它 ' + other.toString());
    }
    const why = parts.length > 0 ? '；逐条原因：' + parts.join('、') : '';
    return {
      name: 'MusicFree 插件',
      text: '重搜了 ' + stat.tried.toString() + ' 个插件' + roundTip + '，命中 ' +
        stat.hit.toString() + ' 首同款并逐一取链，全部没拿到目标音质' + why +
        '。已按「绝不降质」停止，没有回退到低音质；这类失败通常是插件在该音质档' +
        '（无损 / 母带多要会员或版权）没有可播链接，属于音源内容供给问题',
      preferred: false
    };
  }

  /** 单个搜索任务短超时：到点就当这一组没结果，不等 15s 的插件 invoke */
  private static withDeadlineList(task: Promise<SongInfo[]>, ms: number): Promise<SongInfo[]> {
    return new Promise<SongInfo[]>((resolve) => {
      let done = false;
      const timer = setTimeout(() => {
        if (!done) {
          done = true;
          resolve([]);
        }
      }, ms);
      task.then((list: SongInfo[]): void => {
        if (!done) {
          done = true;
          clearTimeout(timer);
          resolve(list);
        }
      }, (): void => {
        if (!done) {
          done = true;
          clearTimeout(timer);
          resolve([]);
        }
      });
    });
  }

  /**
   * 重搜关键词：尽量还原用户在搜索页手输的短词。
   * 平台歌单里的歌手常写成「周传雄 (Steve Chou)」，歌名也可能带 (Live) / 伴奏，
   * 直接拼成「青花 周传雄 (Steve Chou)」丢给插件的 search()，命中率会塌 ——
   * 用户在搜索页明明输「青花」就能搜到，替补却搜不到，多半就差在这里。
   * 返回 1~2 个候选词：干净的「歌名 + 首歌手」优先，纯歌名兜底。
   */
  private static huntKeywords(song: SongInfo): string[] {
    const out: string[] = [];
    const name = Resolver.cleanHuntWord(song.name);
    if (name.length === 0) {
      return out;
    }
    const singer = Resolver.cleanHuntWord(firstSinger(song.singer));
    if (singer.length > 0) {
      out.push(name + ' ' + singer);
    }
    // 纯歌名兜底：插件多半对「歌名+歌手」这种复合词支持不佳
    out.push(name);
    return out;
  }

  /** 剥掉括号别名 / feat. / 版本标注 / 多余空白，只留可搜索的主体 */
  private static cleanHuntWord(raw: string): string {
    let t = raw.replace(/\([^)]*\)/g, ' ')
      .replace(/（[^）]*）/g, ' ')
      .replace(/\[[^\]]*\]/g, ' ')
      .replace(/【[^】]*】/g, ' ');
    t = t.replace(/\b(feat\.?|ft\.?|featuring|with|live|remix|dj|cover|inst|offvocal|demo)\b/gi, ' ')
      .replace(/(伴奏|纯音乐|翻唱|试听|完整版|正式版|现场版)/g, ' ')
      .replace(/\s+/g, ' ')
      .trim();
    return t;
  }

  /** 用某一个关键词，向所有候选插件并发重搜一轮 */
  private async mfSearchRound(plugins: SourceItem[], keyword: string,
    song: SongInfo): Promise<SongInfo[]> {
    const tasks: Array<Promise<SongInfo[]>> = [];
    for (const item of plugins) {
      tasks.push(Resolver.withDeadlineList(
        this.sources.searchMusicFree(item.id, keyword, 1)
          .then((list: SongInfo[]): SongInfo[] => Resolver.pickLooseMf(list, song))
          .catch((): SongInfo[] => []),
        SMART_SEARCH_MS));
    }
    const groups = await Promise.all(tasks);
    const out: SongInfo[] = [];
    const seen: string[] = [];
    for (const group of groups) {
      for (const cand of group) {
        const k = cand.source + '|' + cand.id;
        if (seen.indexOf(k) >= 0) {
          continue;
        }
        seen.push(k);
        out.push(cand);
        if (out.length >= SMART_MF_QUOTA) {
          return out;
        }
      }
    }
    return out;
  }

  /** 候选歌池 A：MusicFree 插件按名重搜，独占 SMART_MF_QUOTA 个名额 */
  private async smartMfPool(song: SongInfo, stat: MfPoolStat): Promise<SongInfo[]> {
    if (song.source === 'local' || song.name.trim().length === 0) {
      return [];
    }
    const originInst = song.source.indexOf('mf:') === 0 ? song.source.substring(3) : '';
    const plugins: SourceItem[] = [];
    for (const item of this.sources.mfFallbackSources()) {
      if (item.id === originInst || plugins.length >= MF_FALLBACK_MAX) {
        continue;
      }
      plugins.push(item);
    }
    if (plugins.length === 0) {
      return [];
    }
    stat.tried = plugins.length;
    const words = Resolver.huntKeywords(song);
    let out: SongInfo[] = [];
    for (const word of words) {
      stat.rounds++;
      out = await this.mfSearchRound(plugins, word, song);
      if (out.length > 0) {
        break;
      }
    }
    stat.hit = out.length;
    return out;
  }

  /** 候选歌池 B：内置平台同名同款，独占 SMART_PLATFORM_QUOTA 个名额 */
  private async smartPlatformPool(song: SongInfo): Promise<SongInfo[]> {
    if (song.source === 'local' || song.name.trim().length === 0) {
      return [];
    }
    // 洛雪音源一个都没启用时，换来的平台歌没有音源能取链，不空转 4 次搜索
    if (!this.hasEnabledLxSource()) {
      return [];
    }
    const keyword = song.name + ' ' + firstSinger(song.singer);
    const tasks: Array<Promise<SongInfo[]>> = [];
    const order: string[] = ['kw', 'tx', 'kg', 'mg', 'wy'];
    for (const platform of order) {
      if (platform === song.source) {
        continue;
      }
      tasks.push(Resolver.withDeadlineList(
        this.api.searchSongs(platform, keyword, 1)
          .then((list: SongInfo[]): SongInfo[] => Resolver.pickLoose(list, song))
          .catch((): SongInfo[] => []),
        SMART_SEARCH_MS));
    }
    if (tasks.length === 0) {
      return [];
    }
    const groups = await Promise.all(tasks);
    const out: SongInfo[] = [];
    const seen: string[] = [];
    for (const group of groups) {
      for (const cand of group) {
        // 只收平台歌；带 mfRaw 的由 A 组负责，两组不重复
        if (cand.mfRaw !== undefined && cand.mfRaw.length > 0) {
          continue;
        }
        const k = cand.source + '|' + cand.id;
        if (seen.indexOf(k) >= 0) {
          continue;
        }
        seen.push(k);
        out.push(cand);
        if (out.length >= SMART_PLATFORM_QUOTA) {
          return out;
        }
      }
    }
    return out;
  }

  /** 去常见版本标注后的歌名，用于「晴天 (Live)」对「晴天」这类同款 */
  private static looseName(name: string): string {
    return normalizeText(name).replace(
      /(live|remix|dj|伴奏|纯音乐|翻唱|cover|inst|offvocal|demo|试听|完整版|正式版|现场版|版)/g, '');
  }

  /** 同名打分：0 最可信，>2 判为不同作品直接放弃（防张冠李戴） */
  private static looseScore(cand: SongInfo, song: SongInfo): number {
    const a = normalizeText(cand.name);
    const b = normalizeText(song.name);
    if (a.length === 0 || b.length === 0) {
      return 99;
    }
    let score = 0;
    if (a === b) {
      score = 0;
    } else if (Resolver.looseName(cand.name) === Resolver.looseName(song.name)) {
      score = 1;
    } else if (a.indexOf(b) >= 0 || b.indexOf(a) >= 0) {
      score = 2;
    } else {
      return 99;
    }
    const s = firstSinger(song.singer);
    const c = firstSinger(cand.singer);
    if (s.length > 0 && c.length > 0 && s.indexOf(c) < 0 && c.indexOf(s) < 0) {
      score += 2;
    }
    const da = song.duration;
    const db = cand.duration;
    if (da > 0 && db > 0 && Math.abs(da - db) > Math.max(10, da * 0.15)) {
      score += 2;
    }
    return score;
  }

  /** 每个源最多留 2 个最可信版本，避免同一平台刷屏占满候选名额 */
  private static pickLoose(list: SongInfo[], song: SongInfo): SongInfo[] {
    const scored: Array<[number, SongInfo]> = [];
    for (const item of list) {
      const s = Resolver.looseScore(item, song);
      if (s <= 2) {
        scored.push([s, item]);
      }
    }
    scored.sort((x: [number, SongInfo], y: [number, SongInfo]): number => x[0] - y[0]);
    const out: SongInfo[] = [];
    for (const pair of scored) {
      out.push(pair[1]);
      if (out.length >= 2) {
        break;
      }
    }
    return out;
  }

  /**
   * MusicFree 插件结果的同名判定：比平台结果宽松。
   * 插件返回的 duration 单位常与平台歌不一致（秒 / 毫秒），歌手常带 feat.、
   * 繁简或英文名，照搬 looseScore 的「时长差 +2 / 歌手差 +2」会把真同款判成
   * 不同作品。名字仍必须相等 / 去版本后相等 / 互相包含，否则直接判 99 防张冠李戴。
   */
  private static mfScore(cand: SongInfo, song: SongInfo): number {
    const a = normalizeText(cand.name);
    const b = normalizeText(song.name);
    if (a.length === 0 || b.length === 0) {
      return 99;
    }
    let score = 0;
    if (a === b) {
      score = 0;
    } else if (Resolver.looseName(cand.name) === Resolver.looseName(song.name)) {
      score = 1;
    } else if (a.indexOf(b) >= 0 || b.indexOf(a) >= 0) {
      score = 2;
    } else {
      return 99;
    }
    const s = firstSinger(song.singer);
    const c = firstSinger(cand.singer);
    if (s.length > 0 && c.length > 0 && s.indexOf(c) < 0 && c.indexOf(s) < 0) {
      score += 1;
    }
    return score;
  }

  /**
   * 插件结果按分数取前 3 首：阈值放宽到 3，但仍必须带 mfRaw 才能取链。
   * v2.57：从 2 提到 3 —— 插件给的同款常有多个版本（Live / 翻唱 / 不同专辑），
   * 只取前 2 首容易把「唯一能出链的那个版本」挤掉，配合总名额 6 提高覆盖。
   */
  private static pickLooseMf(list: SongInfo[], song: SongInfo): SongInfo[] {
    const scored: Array<[number, SongInfo]> = [];
    for (const item of list) {
      const s = Resolver.mfScore(item, song);
      if (s <= 3) {
        scored.push([s, item]);
      }
    }
    scored.sort((x: [number, SongInfo], y: [number, SongInfo]): number => x[0] - y[0]);
    const out: SongInfo[] = [];
    for (const pair of scored) {
      // 没有 mfRaw 的歌会被 trySources 当成平台歌，插件拿不到自己的 mediaItem
      if (pair[1].mfRaw !== undefined && pair[1].mfRaw.length > 0) {
        out.push(pair[1]);
      }
      if (out.length >= 3) {
        break;
      }
    }
    return out;
  }

  /** 缓存里的来源是否真的是首选音源给的（换源/直连/补位都算「不是」） */
  private isPreferredFrom(from: string): boolean {
    const active = this.sources.getActive();
    if (active === null) {
      return false;
    }
    if (from.indexOf(' · ') >= 0) {
      return false;
    }
    return from === active.name;
  }

  /**
   * 失败凭据为空时补一条占位说明。
   *
   * 会出现空的原因：首选音源压根没进候选（未就绪 / 没声明支持该平台），
   * 此时一条 note 都没产生。播放页的失败面板如果拿到空列表，会误判成
   * 「链接取到了、播放器才失败」，所以这里必须留一条说明。
   */
  private static fillEmptyNote(notes: FailNote[]): void {
    if (notes.length > 0) {
      return;
    }
    const active = SourceRepo.get().getActive();
    notes.push({
      name: active !== null ? active.name : '音源',
      text: '没有真正参与取链（脚本未就绪，或没声明支持这个平台）',
      preferred: true
    });
  }

  /** 只认首选却失败时的提示：把「谁没给」说清楚，不掺补位音源的失败原因 */
  private static buildStrictError(notes: FailNote[], want: string, candidateCount: number): string {
    const active = SourceRepo.get().getActive();
    const name = active !== null ? active.name : '首选音源';
    let why = '';
    let found = false;
    for (const item of notes) {
      if (item.preferred && !found) {
        why = item.text;
        found = true;
      }
    }
    if (!found) {
      why = '这首歌不在它支持的平台内，或当前音质它给不了';
    }
    const head = want.length > 0 ? ('（' + want + '）') : '';
    return '首选「' + name + '」没能给出这首歌的播放地址' + head + '：' + why +
      '。当前设置为「只用首选音源」，不会自动换成别的音源；可在设置 → 音源里改回「允许补位」' +
      '（共 ' + candidateCount.toString() + ' 个音源参与取链）';
  }

  /**
   * 取链：首选音源优先；「允许补位」时才让其它已启用音源并发补位。
   *
   * 为什么会有「音源来回变动」：补位是并发的，谁先给出可用链接就用谁的，
   * 而且每一首的冷热程度不同（有的平台某首没版权、有的接口慢半拍），
   * 于是同一个列表连着播几首，来源就会在几个音源之间跳。
   * 现在设置里多了「只用首选音源」，打开后就只问首选，拿不到直接报错。
   */
  private async trySources(song: SongInfo, quality: string, notes: FailNote[],
    strict: boolean, state: ResolveState, hunt: boolean = false): Promise<ResolveResult | null> {
    const runner = this.sources.getRunner();
    if (runner === null) {
      return null;
    }
    const activeId = this.sources.getActiveId();
    const oneOnly = state.oneOnly;
    const candidates: SourceItem[] = [];
    /** 音质档位对不上：不淘汰，只排到后面（音源上报的 qualitys 经常残缺） */
    const softQuality: Set<string> = new Set<string>();
    /** 已加载但还没 inited 的：本轮先等它，不要当成「没这个平台」直接跳过 */
    const pendingInit: SourceItem[] = [];
    /** 宽限期过了仍未 inited 的：只在「一个就绪源都没有」时作为最后机会 */
    const expired: SourceItem[] = [];
    for (const item of this.sources.enabled()) {
      // MusicFree 插件自己搜出的歌（mfRaw 是它的原始 mediaItem）只交给产出它的插件取链：
      // 洛雪音源拿不到 bvid / photo.id 这类自定义字段，别的插件拿别人的 id 也认不出，
      // 试了都是白试还拖慢首选窗口。song.source 就是 'mf:<instId>'，精确匹配。
      if (song.mfRaw !== undefined && song.mfRaw.length > 0 &&
        (item.kind !== 'musicfree' || song.source !== 'mf:' + item.id)) {
        continue;
      }
      // 声明了平台但不含本平台的直接跳过
      if (item.platforms.length > 0 && item.platforms.indexOf(song.source) < 0) {
        continue;
      }
      if (!runner.isLoaded(item.id)) {
        continue;
      }
      if (!runner.isInited(item.id)) {
        // 加载后短时间内的「未 inited」是正常的（要等 rconfig / 登录态 / 签名配置），
        // 超过宽限期还没上报，就是它压根不支持协议或初始化失败了。
        if (runner.loadedAgo(item.id) < INIT_GRACE_MS) {
          pendingInit.push(item);
        } else {
          expired.push(item);
          notes.push({
            name: item.name,
            text: '初始化超时（脚本没有上报可用平台）',
            preferred: item.id === activeId
          });
        }
        continue;
      }
      // 不再因为「音质列表里没有这一档」就把音源整体淘汰：
      // inited 上报的 qualitys 普遍不全（有的只报 128k，实际 flac 也能给），
      // 直接 continue 会让用户在选无损时看到「一个音源都不支持」。
      if (item.qualities.length > 0 && item.qualities.indexOf(quality) < 0) {
        softQuality.add(item.id);
      }
      candidates.push(item);
    }

    // 没有就绪音源、或「只认首选」而首选还在初始化时，等一会儿 inited。
    // 这一步正是「独家音源从没成功过」的关键：它要先 GET rconfig 才注册 handler，
    // 早先我们不等 inited 就发 musicUrl，必然拿到「未注册 request 处理器」。
    const mustWaitPreferred = oneOnly &&
      pendingInit.filter((item): boolean => item.id === activeId).length > 0;
    if (pendingInit.length > 0 && (candidates.length === 0 || mustWaitPreferred)) {
      const waited: Array<Promise<boolean>> = [];
      for (const item of pendingInit) {
        waited.push(runner.waitInited(item.id, INIT_WAIT_MS));
      }
      const flags = await Promise.all(waited);
      for (let i = 0; i < pendingInit.length; i++) {
        const item = pendingInit[i];
        if (flags[i]) {
          if (item.qualities.length > 0 && item.qualities.indexOf(quality) < 0) {
            softQuality.add(item.id);
          }
          candidates.push(item);
        } else {
          notes.push({
            name: item.name,
            text: '正在初始化，等不到它上报平台清单',
            preferred: item.id === activeId
          });
        }
      }
    } else if (pendingInit.length > 0) {
      // 本轮已有就绪音源，不为了等它拖慢播放；只在它是首选时说明一句
      for (const item of pendingInit) {
        if (item.id === activeId) {
          notes.push({ name: item.name, text: '正在初始化，本轮先用其它音源', preferred: true });
        }
      }
    }

    // 一个就绪源都没有、但有「从没上报过平台」的老脚本：
    // 这类脚本可能是 v1 协议或被混淆到看不出 inited 字段，
    // 它们此前同样被判成「没上报平台」，但仍然值得按未知平台问一次 ——
    // 总比直接告诉用户「这首歌没有可用音源」强。
    if (candidates.length === 0 && expired.length > 0) {
      for (const item of expired) {
        candidates.push(item);
      }
    }
    if (candidates.length === 0) {
      return null;
    }
    // 排序：本平台健康度优先，其次「上次给过这首歌的音源」，最后音质匹配。
    // 健康度乘 1000，保证「音质降权 / 亲和」都不会把连续 403 的音源顶到最前；
    // 亲和只在同一健康度下起作用，它失败一次就会被健康度压回去。
    const affin = this.affinitySource(song);
    candidates.sort((a: SourceItem, b: SourceItem): number => {
      const pa = Resolver.penalty(a.id, song.source) * 1000 + (softQuality.has(a.id) ? 10 : 0) +
        (a.id === affin ? 0 : 1);
      const pb = Resolver.penalty(b.id, song.source) * 1000 + (softQuality.has(b.id) ? 10 : 0) +
        (b.id === affin ? 0 : 1);
      return pa - pb;
    });
    state.candidateCount += candidates.length;
    // 只有一个可用音源时不做「坏链接淘汰」：探测可能因防盗链误报 403，
    // 此时宁可把链接交给播放器试，也不要连唯一的机会都判死。
    const lenient: boolean = candidates.length === 1;

    // 阶段 1：只问首选（同一轮 resolve 里只等一次，后续档位直接全并发）。
    // 懒人模式跳过独占窗口：它本来就是全源 + 全候选并发，先给到达标结果的胜出，
    // 再等首选 3 秒只会拖慢「自动跳到下一个源」。
    const preferred = candidates.filter((item): boolean => item.id === activeId);
    const rest = candidates.filter((item): boolean => item.id !== activeId);
    let preferredTask: Promise<ResolveResult | null> | null = null;
    if (preferred.length > 0 && !state.preferredWindowUsed && !hunt) {
      state.preferredWindowUsed = true;
      preferredTask = this.fetchFromSource(preferred[0], song, quality, notes, strict, true, lenient, hunt);
      const early = await Resolver.withDeadline(preferredTask, PREFERRED_WINDOW_MS);
      if (early !== null) {
        return early;
      }
    }

    // 只认首选：不放开补位。首选没进候选（平台不含本平台/音质不支持）时返回 null，
    // 由 resolve() 给出「首选不支持这首歌」的明确提示。
    // 懒人模式接管这个偏好：它要的就是「一个不行自动换下一个」，不能只认一个。
    if (oneOnly && !hunt) {
      if (preferred.length === 0) {
        return null;
      }
      if (preferredTask !== null) {
        return await preferredTask;
      }
      return await this.fetchFromSource(preferred[0], song, quality, notes, strict, true, lenient, hunt);
    }

    // 阶段 2：首选没拿到（或还没跑完），其余音源并发补位
    const tasks: Array<Promise<ResolveResult | null>> = [];
    if (preferredTask !== null) {
      tasks.push(preferredTask);
    } else if (preferred.length > 0) {
      // 独占窗口已用过：首选不再单独等待，直接和其它音源一起竞速
      tasks.push(this.fetchFromSource(preferred[0], song, quality, notes, strict, true, lenient, hunt));
    }
    for (const item of rest) {
      tasks.push(this.fetchFromSource(item, song, quality, notes, strict, false, lenient, hunt));
    }
    if (tasks.length === 0) {
      return null;
    }
    return await Resolver.firstUsable(tasks);
  }

  /**
   * 内部统一档位 → 该音源 inited 里上报的原始档位名。
   * 音源可以自定义 qualitys（旧版全豆要写 24bit，标准名是 flac24bit），
   * 反问音源时必须用它自己认识的那个字符串，否则它按未知档位处理。
   */
  private static sourceQuality(item: SourceItem, internal: string): string {
    const target = normalizeQuality(internal);
    for (const q of item.qualities) {
      if (normalizeQuality(q) === target) {
        return q;
      }
    }
    return internal;
  }

  /** 音源声明的音质里，有没有哪一档不低于请求档（有就值得问一次） */
  private static canTop(item: SourceItem, quality: string): boolean {
    const floor = qualityRank(quality);
    for (const q of item.qualities) {
      if (qualityRank(q) >= floor) {
        return true;
      }
    }
    return false;
  }

  /** 首选独占窗口：超时返回 null，但不取消原任务，后面还会一起参与竞速 */
  private static withDeadline(task: Promise<ResolveResult | null>, ms: number): Promise<ResolveResult | null> {
    return new Promise<ResolveResult | null>((resolve) => {
      let done = false;
      const timer = setTimeout(() => {
        if (!done) {
          done = true;
          resolve(null);
        }
      }, ms);
      task.then((result: ResolveResult | null) => {
        if (!done) {
          done = true;
          clearTimeout(timer);
          resolve(result);
        }
      }, () => {
        if (!done) {
          done = true;
          clearTimeout(timer);
          resolve(null);
        }
      });
    });
  }

  /**
   * 实例级故障：脚本在，但 handler 没注册上 / 实例被清掉 / 请求没人接。
   * 这类失败重建一次就能好，和「歌没版权」「超时」这种业务失败要分开处理。
   */
  private static needRebuild(text: string): boolean {
    return text.indexOf('未注册 request 处理器') >= 0 ||
      text.indexOf('音源未加载') >= 0 ||
      text.indexOf('音源未处理该请求') >= 0 ||
      text.indexOf('音源调用失败') >= 0;
  }

  /** 单个音源：取链 → 真实音频探测 → 音质校验，任一环节失败返回 null */
  private async fetchFromSource(item: SourceItem, song: SongInfo, quality: string,
    notes: FailNote[], strict: boolean, preferred: boolean,
    lenient: boolean, hunt: boolean = false): Promise<ResolveResult | null> {
    const before = notes.length;
    const first = await this.fetchOnce(item, song, quality, notes, strict, preferred, lenient, hunt);
    if (first !== null) {
      return first;
    }
    // 只对「实例级故障」重建重试一次：脚本卡死、handler 丢失、全局被污染时，
    // 官方是靠「切源即销毁重建」自愈的，这里等价地把这一个源重建一遍。
    let rebuild = false;
    for (let i = before; i < notes.length; i++) {
      if (Resolver.needRebuild(notes[i].text)) {
        rebuild = true;
        break;
      }
    }
    if (!rebuild) {
      return null;
    }
    const item2 = await this.sources.reload(item.id);
    if (item2 === null || item2.status !== 'ok') {
      return null;
    }
    return await this.fetchOnce(item2, song, quality, notes, strict, preferred, lenient, hunt);
  }

  /** 单个音源的一次取链尝试 */
  private async fetchOnce(item: SourceItem, song: SongInfo, quality: string,
    notes: FailNote[], strict: boolean, preferred: boolean,
    lenient: boolean, hunt: boolean = false): Promise<ResolveResult | null> {
    const runner = this.sources.getRunner();
    if (runner === null) {
      return null;
    }
    // 音源 inited 里声明的可能是别名（旧版全豆要用 24bit），
    // 反问音源时必须用它自己认识的那个原始档位名
    const sourceQ = Resolver.sourceQuality(item, quality);
    const info: LxInvokeInfo = {
      source: song.source,
      quality: sourceQ,
      type: sourceQ,
      musicInfo: this.buildMusicInfo(song, quality)
    };
    try {
      const raw = await runner.invoke(item.id, 'musicUrl', info, SOURCE_TIMEOUT);
      const parsed = Resolver.parseUrl(raw);
      if (parsed.url.length === 0) {
        notes.push(Resolver.note(item, quality, '无链接', preferred));
        Resolver.markFail(item.id, song.source, '无链接');
        return null;
      }
      /**
       * 下载默认「信任音源」：洛雪官方拿到 body.data 就直接交给下载器，
       * 不先发一个 Range 探测。中转 / 聚合接口常对探测请求回 403 / 404 / 防盗链页，
       * 旧逻辑在探测这一步就把本来能下的链接判死了。
       * 开启「下载前严格验音质」后恢复旧行为；播放路径仍探测（拿格式 / 码率 / 最终 URL），
       * 但探测失败也回退为信任，不再直接判死。
       */
      const strictVerify = strict && Settings.get().verifyBeforeDownload();
      // 懒人模式（hunt）：在线 / 下载都强制探测。不探测就无从判定「达标」，
      // 下载默认「信任音源、落盘后验文件头」那条路会让 320k 冒充无损混过去。
      let probe: ProbeResult | null = null;
      if (!strict || strictVerify || hunt) {
        probe = await probeAudioEx(parsed.url, song.duration, parsed.headers);
        if (!probe.ok) {
          /**
           * 播放路径：探测明确判坏（403/404/防盗链 HTML/试听片段）时不能算「可用」。
           * 旧逻辑一律回退为「信任音源」，坏链接会在「首选 3 秒独占窗口」里抢先返回，
           * 于是其它十几个音源根本没被启动，AVPlayer prepare 又必然失败 ——
           * 这正是「装了十几个源，却只试了一个」的代码级根因。
           * 只有探测本身失败（超时 / 连不上 / 判断不了）才继续信任音源。
           */
          // 懒人模式下「明确判坏」的链接同样不能算达标：403 / 防盗链 HTML /
          // 试听片段都要跳过，让它去问下一个源，而不是拿去充数。
          const fatal = strictVerify || (!lenient && !strict && Resolver.isFatalProbe(probe.reason)) ||
            (hunt && Resolver.isFatalProbe(probe.reason));
          if (fatal) {
            notes.push(Resolver.note(item, quality, probe.reason, preferred));
            Resolver.markFail(item.id, song.source, probe.reason);
            return null;
          }
          // 探测本身失败（网络/判断不了）不算虚标，仍信任音源按请求档位给的链接。
          // 音源收到 quality 若不支持本应返回空；返回链接即视为它认这一档。
          probe = null;
        }
      }
      if (probe === null) {
        // 格式留 unknown、按请求档位记，下载完成后由 Downloader 读文件头判定真实格式，
        // 并修正扩展名与实际音质 —— 不虚标成 .flac，也不会因为探测失败而下不了。
        Resolver.markOk(item.id, song.source);
        const result: ResolveResult = {
          url: parsed.url,
          from: item.name,
          quality: quality,
          format: 'unknown',
          kbps: 0,
          headers: parsed.headers
        };
        this.offerAlternate(song, item, result, false);
        this.rememberSource(song, item.id);
        return result;
      }
      // 严格校验只拒绝「明确有损」的证据（mp3 / m4a / ogg），unknown 不是虚标。
      // 但中转层常给无损链接套 `Content-Type: audio/mpeg` / .mp3 的壳：码率
      // ≥640kbps 时标签不可信，不能据此判有损（Http.detectFormat 已做码率仲裁，
      // 这里是达标门禁的第二道保险）。真 128k/320k 的 mp3 仍会被挡住。
      const lossyTag = probe.format === 'mp3' || probe.format === 'm4a' || probe.format === 'ogg';
      const lossy = lossyTag && probe.kbps < LOSSY_MAX_KBPS;
      // 记账与门禁保持一致：高码率无损别再标成 320K
      const actual = (lossyTag && !lossy && isLossless(quality))
        ? 'flac' : Resolver.actualQuality(quality, probe);
      const enough = isLossless(quality) ? !lossy : qualityRank(actual) >= qualityRank(quality);
      // 懒人模式无论在线 / 下载都要求达标（旧的 strict 只在下载严格校验时拒绝），
      // 不达标就 return null，让竞速里其它音源 / 其它平台的同款继续顶上。
      if ((strict || hunt) && !enough) {
        const why = '只给到' + qualityLabel(actual) +
          '（' + probe.format + (probe.kbps > 0 ? ' ' + probe.kbps.toString() + 'kbps' : '') + '）';
        notes.push(Resolver.note(item, quality, why, preferred));
        Resolver.markFail(item.id, song.source, why);
        return null;
      }
      Resolver.markOk(item.id, song.source);
      const result: ResolveResult = {
        url: probe.url,
        from: item.name,
        quality: actual,
        format: probe.format,
        kbps: probe.kbps,
        headers: parsed.headers
      };
      this.offerAlternate(song, item, result, true);
      this.rememberSource(song, item.id);
      return result;
    } catch (e) {
      const why = Resolver.short(e);
      notes.push(Resolver.note(item, quality, why, preferred));
      Resolver.markFail(item.id, song.source, why);
      return null;
    }
  }

  private static note(item: SourceItem, quality: string, text: string, preferred: boolean): FailNote {
    return { name: item.name, text: qualityLabel(quality) + '：' + Resolver.explain(text), preferred: preferred };
  }

  /**
   * 失败提示组装：首选永远排第一，并显式标注「补位」，避免用户把括号里
   * 随便某个音源的名字误认为「下载用的就是这个音源」。
   */
  private static formatReasons(notes: FailNote[]): string {
    if (notes.length === 0) {
      return '（没有可用音源）';
    }
    const parts: string[] = [];
    let fallbackCount = 0;
    for (const item of notes) {
      if (item.preferred) {
        parts.push('首选「' + item.name + '」' + item.text);
        break;
      }
    }
    if (parts.length === 0) {
      parts.push('首选未参与本次取链（平台/音质不匹配或未启用）');
    }
    const seen: string[] = [];
    for (const item of notes) {
      if (item.preferred) {
        continue;
      }
      fallbackCount++;
      if (parts.length >= 3 || seen.indexOf(item.name) >= 0) {
        continue;
      }
      seen.push(item.name);
      parts.push('补位音源「' + item.name + '」' + item.text);
    }
    if (fallbackCount > seen.length) {
      parts.push('另有 ' + (fallbackCount - seen.length).toString() + ' 次补位尝试');
    }
    return '（' + parts.join('；') + '）';
  }

  /** 取第一个非 null 结果；全部失败才返回 null（用对象状态避免闭包捕获限制） */
  private static firstUsable(tasks: Array<Promise<ResolveResult | null>>): Promise<ResolveResult | null> {
    const state: RaceState = { left: tasks.length, settled: false };
    return new Promise<ResolveResult | null>((resolve) => {
      for (const task of tasks) {
        const onSettled = (result: ResolveResult | null): void => {
          state.left--;
          if (!state.settled && result !== null) {
            state.settled = true;
            resolve(result);
          } else if (state.left === 0 && !state.settled) {
            state.settled = true;
            resolve(null);
          }
        };
        task.then(onSettled, (): void => {
          onSettled(null);
        });
      }
    });
  }

  /**
   * 跨平台换源：优先酷我（公开接口最稳），其次 QQ / 酷狗 / 咪咕。
   * 只有「歌名一致 + 歌手相近」才换，避免张冠李戴。
   */
  private async findAlternative(song: SongInfo): Promise<SongInfo | null> {
    if (song.source === 'local') {
      return null;
    }
    const order: string[] = ['kw', 'tx', 'kg', 'mg', 'wy'];
    const keyword = song.name + ' ' + firstSinger(song.singer);
    const tasks: Array<Promise<SongInfo | null>> = [];
    for (const platform of order) {
      if (platform === song.source) {
        continue;
      }
      tasks.push(this.api.searchSongs(platform, keyword, 1)
        .then((list: SongInfo[]): SongInfo | null => Resolver.pickBest(list, song))
        .catch((): SongInfo | null => null));
    }
    if (tasks.length === 0) {
      return null;
    }
    // 并发查全部平台，再按原优先级挑第一个匹配，避免 5 次串行往返
    const results = await Promise.all(tasks);
    for (const matched of results) {
      if (matched !== null) {
        return matched;
      }
    }
    return null;
  }

  private static pickBest(list: SongInfo[], song: SongInfo): SongInfo | null {
    const target = songKey(song);
    const singer = firstSinger(song.singer);
    for (const item of list) {
      if (songKey(item) !== target) {
        continue;
      }
      if (singer.length === 0 || item.singer.indexOf(singer) >= 0 || singer.indexOf(firstSinger(item.singer)) >= 0) {
        return item;
      }
    }
    return null;
  }

  /**
   * v2.45：MusicFree 插件「按名重搜」替补候选。v2.49：候选改为健康度感知。
   *
   * 洛雪来源的歌（source=wy / kw / qq / …）只带平台 id，MusicFree 插件的
   * getMediaSource() 认不出；插件上报的 platforms 又是 'mf:<实例id>'，
   * trySources 的平台过滤把它们全挡在候选池外。直接把原歌丢给插件必然取链失败
   * （v2.40 已确认的约束），所以这里不改候选池，而是走真实重搜：
   *   歌名 + 首歌手 → 每个可搜索插件 search() → pickBest 严格同名匹配
   *   → 拿回插件自己那首歌（带 mfRaw 原始 mediaItem）。
   * 之后交给既有的 trySources：第一道 mfRaw 守卫会精确只放行产出它的插件，
   * getMediaSource() 拿到自己的对象就能出链。整个链路不伪造、不张冠李戴。
   *
   * v2.49 三处优化（都收敛在本方法内，不动候选池 / 阶段顺序 / mfRaw 门槛）：
   *  1) 候选从 mfSearchSources().slice() 换成 mfFallbackSources()：按自检 health
   *     排序，ok 优先、error 垫底但不排除，让「已验证能出链」的插件先占名额。
   *  2) 排除「产出这首歌、刚才取链已经失败」的那个插件（source 以 'mf:' 开头时）。
   *     再问同一个插件一次几乎必然还是失败（同一个中转 / 版权限制），白占名额。
   *  3) 先排除再取 MF_FALLBACK_MAX，保证 6 个名额全是有效候选，不被原插件吃掉一个。
   *
   * 只在原平台失败后、跨平台换源之前调用，正常播放不额外发请求。
   */
  private async findMusicFreeAlternatives(song: SongInfo): Promise<SongInfo[]> {
    if (song.source === 'local' || song.name.trim().length === 0) {
      return [];
    }
    const originInst = song.source.indexOf('mf:') === 0 ? song.source.substring(3) : '';
    const plugins: SourceItem[] = [];
    for (const item of this.sources.mfFallbackSources()) {
      if (originInst.length > 0 && item.id === originInst) {
        continue;
      }
      plugins.push(item);
      if (plugins.length >= MF_FALLBACK_MAX) {
        break;
      }
    }
    if (plugins.length === 0) {
      return [];
    }
    const keyword = song.name + ' ' + firstSinger(song.singer);
    const tasks: Array<Promise<SongInfo | null>> = [];
    for (const item of plugins) {
      tasks.push(this.sources.searchMusicFree(item.id, keyword, 1)
        .then((list: SongInfo[]): SongInfo | null => Resolver.pickBest(list, song))
        .catch((): SongInfo | null => null));
    }
    const hits = await Promise.all(tasks);
    const out: SongInfo[] = [];
    for (const hit of hits) {
      // 必须带 mfRaw：没有原始 mediaItem 的候选等于又回到「平台 id 硬问插件」
      if (hit !== null && hit.mfRaw !== undefined && hit.mfRaw.length > 0) {
        out.push(hit);
      }
    }
    return out;
  }

  /**
   * v2.49：跨平台换源出来的平台歌（source=wy / kw / …）只能由洛雪脚本取链，
   * MusicFree 插件认的是自己的 mfRaw 原始对象（v2.40 已确认硬问平台 id 取不到链）。
   * 所以洛雪音源一个都没启用时，findAlternative 并发搜 5 个内置平台 API 注定落空，
   * 纯拖慢失败路径 —— 直接跳过并如实记一条。只判断「有没有启用的洛雪侧音源」，
   * 不细究它声明了哪些平台（trySources 自己会做平台过滤），避免误跳过。
   */
  private hasEnabledLxSource(): boolean {
    for (const item of this.sources.enabled()) {
      if (item.kind !== 'musicfree') {
        return true;
      }
    }
    return false;
  }

  private buildMusicInfo(song: SongInfo, quality: string): SongInfo {
    const id = song.id.length > 0 ? song.id : song.songmid;
    const info: SongInfo = {
      id: id,
      songmid: song.songmid.length > 0 ? song.songmid : id,
      hash: song.hash.length > 0 ? song.hash : id,
      name: song.name,
      singer: song.singer,
      album: song.album,
      albumName: song.albumName ?? song.album,
      musicrid: song.musicrid !== undefined && song.musicrid.length > 0 ? song.musicrid : ('MUSIC_' + id),
      interval: song.interval,
      source: song.source,
      duration: song.duration,
      cover: song.cover,
      lyric: song.lyric,
      url: song.url,
      quality: quality,
      albumId: song.albumId,
      copyrightId: song.copyrightId,
      lyricUrl: song.lyricUrl,
      trcUrl: song.trcUrl,
      fee: song.fee,
      // MusicFree 插件自己的原始 mediaItem：getMediaSource() 认的是它，
      // 丢掉这字段就等于拿五平台 id 去问插件，必然取链失败。
      mfRaw: song.mfRaw
    };
    return info;
  }

  /** 各音源声明支持的音质合集 */
  private availableQualities(song: SongInfo): string[] {
    const available: string[] = [];
    for (const item of this.sources.enabled()) {
      if (item.platforms.length > 0 && item.platforms.indexOf(song.source) < 0) {
        continue;
      }
      for (const q of item.qualities) {
        const n = normalizeQuality(q);
        if (available.indexOf(n) < 0) {
          available.push(n);
        }
      }
    }
    return available;
  }

  /**
   * 降质链：请求音质优先，只往下回退，最多 3 档。
   * 旧版把 QUALITY_ORDER 全塞进来，请求 320k 时还会去试 flac24bit/flac（升质毫无意义），
   * 而每个档位都要把全部音源跑一遍，是「点一首歌等很久」的主因之一。
   */
  private qualityChain(song: SongInfo, quality: string): string[] {
    const available = this.availableQualities(song);
    const floor = qualityRank(quality);
    const chain: string[] = [];
    if (quality.length > 0) {
      chain.push(quality);
    }
    for (const q of QUALITY_ORDER) {
      if (chain.length >= 3) {
        break;
      }
      if (chain.indexOf(q) >= 0 || qualityRank(q) > floor) {
        continue;
      }
      if (available.length > 0 && available.indexOf(q) < 0) {
        continue;
      }
      chain.push(q);
    }
    // 128k 是所有音源都能给的兜底档，确保链路里一定有一档
    if (chain.indexOf('128k') < 0) {
      chain.push('128k');
    }
    return chain;
  }

  /**
   * 严格链：只要「不差于请求音质」的档位。
   * 请求无损时绝不去试 320k/128k，因为试了也没用——拿到也会被校验挡回去，
   * 白白多花几次网络往返。
   */
  private strictChain(song: SongInfo, quality: string): string[] {
    const available = this.availableQualities(song);
    // Hi-Res 和普通无损都算「无损」，flac 可以顶替 flac24bit
    const floor = isLossless(quality) ? 4 : qualityRank(quality);
    const chain: string[] = [];
    if (quality.length > 0) {
      chain.push(quality);
    }
    for (const q of QUALITY_ORDER) {
      // 扩充音质全集后无损档变多，给严格链设个上限，避免每首歌都把
      // master/atmos/hires 挨个问一遍拖慢取链
      if (chain.length >= 5) {
        break;
      }
      if (chain.indexOf(q) >= 0) {
        continue;
      }
      if (qualityRank(q) < floor) {
        continue;
      }
      if (available.length > 0 && available.indexOf(q) < 0) {
        continue;
      }
      chain.push(q);
    }
    return chain;
  }

  /**
   * 从探测结果反推真实音质。
   *
   * 请求无损而实际格式明确是 mp3/m4a 时，仍然要判成有损——这正是
   * 「选了无损却下到几兆」的根因。但「格式认不出来（unknown）」是另一回事：
   * 大量中转 API 统一回 application/octet-stream、链接也没有后缀，
   * 这时候只能按请求档位记，不能擅自降标。
   */
  private static actualQuality(requested: string, probe: ProbeResult): string {
    if (probe.format === 'flac') {
      // 只认「这是无损」，不再靠码率猜 24bit —— 猜错了就是虚标
      return 'flac';
    }
    const unknown = probe.format === 'unknown';
    if (isLossless(requested)) {
      if (unknown) {
        return requested;
      }
      return probe.kbps >= 256 ? '320k' : '128k';
    }
    if (probe.kbps >= 256) {
      return '320k';
    }
    if (probe.kbps >= 160) {
      return '192k';
    }
    if (probe.kbps > 0) {
      return '128k';
    }
    if (unknown) {
      return requested;
    }
    return requested === 'flac24bit' ? 'flac' : requested;
  }

  /**
   * 接口自报时长是否明显短于歌曲本身。
   *
   * 酷我的 `convert_url_with_sign` 对「免费试听 / 无版权」的歌，`code` 依然是 200、
   * `url` 也照给，但 `data.duration` 只有 10~30 秒。拿不到原曲时长时，
   * 不足 30 秒一律按片段处理。时长未知（0）则不下结论，交给文件体积校验。
   */
  private static isPreviewLength(got: number, want: number): boolean {
    if (got <= 0) {
      return false;
    }
    if (want > 0) {
      return got + 10 < want;
    }
    return got <= 30;
  }

  /**
   * 酷我公开直连（`convert_url_with_sign`，固定 128k mp3），最后的兜底。
   *
   * 这条链路有个坑：免费/无版权的歌，服务端返回的 `code` 仍是 200、`url` 也正常，
   * 但 `data.duration` 直接就是片段长度（实测 11 秒），音频里只有一句
   * 「酷我音乐免费听歌权限」的提示音。早先只校验 code/url，就会把这段提示音
   * 当成整首播出去。所以这里必须双重校验：接口自报时长 + 真实文件体积。
   */
  private async kuwoDirect(song: SongInfo, notes: FailNote[] | null = null): Promise<ResolveResult | null> {
    let rid = song.musicrid ?? '';
    if (rid.startsWith('MUSIC_')) {
      rid = rid.substring(6);
    }
    if (rid.length === 0 && song.source === 'kw') {
      rid = song.id;
    }
    if (rid.length === 0 || !/^\d+$/.test(rid)) {
      const list = await this.api.searchSongs('kw', song.name + ' ' + firstSinger(song.singer), 1);
      const matched = Resolver.pickBest(list, song);
      if (matched === null) {
        return null;
      }
      rid = matched.id;
    }
    const url = 'https://nmobi.kuwo.cn/mobi.s?f=web&source=kwplayer_ar_1.1.9_oppo_118980_320.apk' +
      '&type=convert_url_with_sign&rid=' + rid + '&br=128k';
    const text = await getText(url, '', 6000);
    const resp = JSON.parse(text) as KwDirectResp;
    let link = resp.data?.url ?? '';
    if (resp.code !== 200 || link.length === 0) {
      return null;
    }
    // 第一道：接口自己上报的时长就不是整首 —— 直接拒绝，别浪费一次探测
    const respDuration = resp.data?.duration ?? 0;
    if (Resolver.isPreviewLength(respDuration, song.duration)) {
      if (notes !== null) {
        notes.push({
          name: '酷我直连',
          text: '只给到 ' + respDuration.toString() + ' 秒试听片段（不是整首）',
          preferred: false
        });
      }
      return null;
    }
    const probe = await probeAudioEx(link, song.duration);
    if (!probe.ok) {
      // 「试听片段」是硬拒绝：宁可明确报「没有可用链接」，也不能把 11 秒的提示音当整首播。
      if (probe.reason.indexOf('试听') >= 0) {
        if (notes !== null) {
          notes.push({ name: '酷我直连', text: probe.reason, preferred: false });
        }
        return null;
      }
      // 其它失败（防盗链 403 / 探测超时 / 服务器不回 content-length）仍旧默认信任：
      // 这条链接本来就是 128k mp3，探测误报不该让最后的兜底彻底失效。
      if (Settings.get().verifyBeforeDownload()) {
        if (notes !== null) {
          notes.push({ name: '酷我直连', text: probe.reason, preferred: false });
        }
        return null;
      }
      return { url: link, from: '酷我直连', quality: '128k', format: 'mp3', kbps: 0, headers: {} };
    }
    link = probe.url;
    const probeFormat = probe.format.length > 0 ? probe.format : 'mp3';
    return { url: link, from: '酷我直连', quality: '128k', format: probeFormat, kbps: probe.kbps, headers: {} };
  }

  private cacheKey(song: SongInfo, quality: string): string {
    return song.source + '|' + song.id + '|' + song.songmid + '|' + quality;
  }

  private put(key: string, result: ResolveResult): void {
    if (this.cache.size >= CACHE_MAX) {
      let oldestKey = '';
      let oldest = Number.MAX_SAFE_INTEGER;
      this.cache.forEach((item: CacheItem, k: string) => {
        if (item.expireAt < oldest) {
          oldest = item.expireAt;
          oldestKey = k;
        }
      });
      if (oldestKey.length > 0) {
        this.cache.delete(oldestKey);
      }
    }
    const item: CacheItem = {
      url: result.url,
      from: result.from,
      quality: result.quality,
      format: result.format,
      kbps: result.kbps,
      headers: result.headers,
      altSong: result.altSong ?? null,
      expireAt: Date.now() + CACHE_TTL
    };
    this.cache.set(key, item);
  }

  static parseUrl(raw: string): LxUrlRaw {
    const out: LxUrlRaw = { url: '', headers: {} };
    if (raw.length === 0) {
      return out;
    }
    try {
      const parsed: Object = JSON.parse(raw);
      if (typeof parsed === 'string') {
        out.url = parsed as string;
        return out;
      }
      const rec = parsed as LxUrlRaw;
      out.url = rec.url !== undefined ? rec.url : '';
      out.headers = rec.headers !== undefined ? rec.headers : {};
      return out;
    } catch (e) {
      if (raw.startsWith('http')) {
        out.url = raw;
      }
      return out;
    }
  }

  private static short(e: Object): string {
    const text = e instanceof Error ? (e as Error).message : String(e);
    const explained = Resolver.explain(text);
    return explained.length > 40 ? explained.substring(0, 40) : explained;
  }
}

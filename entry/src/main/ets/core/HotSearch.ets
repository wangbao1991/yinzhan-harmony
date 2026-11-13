import { getJson } from './Http';

/**
 * 「大家都在搜」的真实数据源（v2.74）。
 *
 * 之前是 Constants.ets 里一条写死的 HOT_WORDS 常量（晴天 / 稻香 / …），所以几天
 * 甚至永远不变。这里改拉网易云官方热搜榜：
 *   GET https://music.163.com/api/search/hot?type=1&limit=10
 *   → {"code":200,"result":{"hots":[{"first":"…"},…]}}
 * 实测 2026-11-13 可用；注意 type=1 是必带参数，只带 limit 会回 400「参数错误」，
 * 旧的 /api/search/hot/web 与 /api/hotsearch/get 都已 404。
 *
 * 工程铁律「不造数」：请求失败或返回空时，绝不用写死的词顶上，也不编造热搜；
 * 保留上一次成功结果 + 明确的可重试提示。10 分钟内存缓存只做「别反复打云端」，
 * 不是把内容固定住 —— 进搜索页会按 TTL 自动刷新，右上角也能强制刷新。
 */
const HOT_URL: string = 'https://music.163.com/api/search/hot?type=1&limit=10';
const HOT_REFERER: string = 'https://music.163.com';
/** 10 分钟内重复进页复用缓存；超时后自动重新取 */
const HOT_TTL: number = 10 * 60 * 1000;
const HOT_MAX: number = 10;

interface HotItem {
  first?: string;
}

interface HotResult {
  hots?: HotItem[];
}

interface HotResp {
  code?: number;
  result?: HotResult;
}

export class HotSearch {
  private static instance: HotSearch = new HotSearch();
  static get(): HotSearch {
    return HotSearch.instance;
  }

  private words: string[] = [];
  private at: number = 0;
  private busy: boolean = false;
  private error: string = '';

  /** 上一次成功拉到的真实热搜词（可能为空，调用方据此显示空态，不要自己补词） */
  cached(): string[] {
    return this.words.slice();
  }

  lastAt(): number {
    return this.at;
  }

  lastError(): string {
    return this.error;
  }

  isBusy(): boolean {
    return this.busy;
  }

  /** force=true 绕过 TTL，用于用户点「刷新」；在途锁避免并发重复请求 */
  async refresh(force: boolean = false): Promise<string[]> {
    if (this.busy) {
      return this.words.slice();
    }
    if (!force && this.words.length > 0 && Date.now() - this.at < HOT_TTL) {
      return this.words.slice();
    }
    this.busy = true;
    this.error = '';
    try {
      const resp = await getJson<HotResp>(HOT_URL, HOT_REFERER, 12000);
      let hots: HotItem[] = [];
      const r: HotResult | undefined = resp.result;
      if (r !== undefined && r.hots !== undefined) {
        hots = r.hots;
      }
      const list: string[] = [];
      for (const item of hots) {
        const raw: string | undefined = item.first;
        const w: string = raw !== undefined ? raw.trim() : '';
        if (w.length > 0 && list.indexOf(w) < 0) {
          list.push(w);
        }
        if (list.length >= HOT_MAX) {
          break;
        }
      }
      if (list.length === 0) {
        this.error = '热搜暂时为空，点此重试';
      } else {
        this.words = list;
        this.at = Date.now();
      }
    } catch (e) {
      // 网络失败 / JSON 异常：不动上一次成功数据，也不回退到写死词
      this.error = '暂时取不到热搜，点此重试';
    }
    this.busy = false;
    return this.words.slice();
  }
}

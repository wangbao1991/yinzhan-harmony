import { SheetInfo } from '../common/Models';

/**
 * 推荐歌单的候选池（发现页专用）。
 *
 * 为什么需要池：各平台的「推荐/分类歌单」接口都是按热度或固定顺序返回的，
 * 同一页反复请求永远是那几条，翻到第 4 页就开始重复。
 *
 * 池的做法：一次抓两批合并去重，用日期做种子洗牌打散顺序，展示时按批切片。
 * 跨天或超过 6 小时整池重建，下拉刷新换新种子。
 *
 * v1.6：以前「换一批」只是把游标 +8、到末尾绕回 0，池里就那 36~60 条，
 * 刷四五轮必然循环。现在 grow 成为换一批的主路径：向取数器要一批真正
 * 没看过的新数据插在游标之后并把游标移过去，advance 只在取不到时兜底。
 * 取数器靠单调递增的 fetchSeq 换分类 / 页码 / 每日推荐，shown 记住已经
 * 展示过的 platform+id，跨整池重建保留，优先给没看过的。
 */
const BASE_PAGES: number = 2;
const TTL_MS: number = 6 * 60 * 60 * 1000;

/** 取一页数据的回调：page 从 1 开始 */
export type SheetFetch = (page: number) => Promise<SheetInfo[]>;

export class SheetPool {
  private items: SheetInfo[] = [];
  /** 池的归属：平台 + 分类。换平台/换分类就换池，不能拿旧池凑数 */
  private key: string = '';
  private day: string = '';
  private builtAt: number = 0;
  private cursor: number = 0;
  /** 取数序号：单调递增，交给取数器换算成「分类 × 页码 / 每日推荐」 */
  private fetchSeq: number = 0;
  /** 已经展示过的条目，跨整池重建保留，用来优先给没看过的内容 */
  private shown: Set<string> = new Set();
  private building: boolean = false;
  private seed: number = 1;
  /** 请求序号：切平台/刷新时让上一轮建池作废 */
  private seq: number = 0;

  private dayKey(): string {
    const d = new Date();
    return d.getFullYear() + '-' + (d.getMonth() + 1) + '-' + d.getDate();
  }

  /** 池还能不能用：归属没变、还是同一天、没超过 6 小时 */
  valid(key: string): boolean {
    if (this.items.length === 0) {
      return false;
    }
    if (this.key !== key) {
      return false;
    }
    if (this.day !== this.dayKey()) {
      return false;
    }
    return Date.now() - this.builtAt < TTL_MS;
  }

  size(): number {
    return this.items.length;
  }

  /**
   * 建池。force=true 用于切平台/下拉刷新：必须立刻重建，不被进行中的请求挡住。
   * newSeed=true 时换用「当前时间」做种子——同一天下拉刷新也能真的换一批顺序，
   * 否则按日期算的种子不变，洗出来还是原来那个排列。
   */
  async build(key: string, fetch: SheetFetch, force: boolean = false, newSeed: boolean = false): Promise<boolean> {
    if (this.building && !force) {
      return false;
    }
    this.building = true;
    const seq = ++this.seq;
    // 换平台 / 换分类才算「换了一个池」，取数序号归零；同一池的刷新与跨天
    // 重建接着往后取，这样下拉刷新拿到的是新维度，而不是把头两页再看一遍。
    if (this.key !== key) {
      this.fetchSeq = 0;
    }
    if (newSeed) {
      this.seed = Math.floor(Date.now() / 1000) % 2147483647;
    } else {
      const day = Number.parseInt(this.dayKey().split('-').join(''));
      this.seed = Number.isNaN(day) ? 1 : day;
    }
    try {
      const promises: Promise<SheetInfo[]>[] = [];
      for (let p = 0; p < BASE_PAGES; p++) {
        const n = ++this.fetchSeq;
        promises.push(fetch(n).catch((): SheetInfo[] => []));
      }
      const results: SheetInfo[][] = await Promise.all(promises);
      if (seq !== this.seq) {
        return false;
      }
      const merged: SheetInfo[] = [];
      const seen = new Set<string>();
      for (let i = 0; i < results.length; i++) {
        const list: SheetInfo[] = results[i];
        if (list.length === 0) {
          continue;
        }
        for (const item of list) {
          const id: string = item.platform + item.id;
          if (seen.has(id)) {
            continue;
          }
          seen.add(id);
          merged.push(item);
        }
      }
      if (merged.length === 0) {
        // 一页都没拿到：保留原池，别清空（清空会让网格塌陷、滚动跳回顶部）
        return false;
      }
      this.shuffle(merged);
      this.items = merged;
      this.key = key;
      this.day = this.dayKey();
      this.builtAt = Date.now();
      this.cursor = 0;
      return true;
    } finally {
      if (seq === this.seq) {
        this.building = false;
      }
    }
  }

  /** 线性同余洗牌：同一颗种子顺序稳定，换种子整体换一遍 */
  private shuffle(list: SheetInfo[]): void {
    let seed = this.seed % 2147483647;
    if (seed <= 0) {
      seed += 2147483646;
    }
    for (let i = list.length - 1; i > 0; i--) {
      seed = (seed * 16807) % 2147483647;
      const j = seed % (i + 1);
      const tmp: SheetInfo = list[i];
      list[i] = list[j];
      list[j] = tmp;
    }
  }

  /** 当前游标处的这一批；末尾不足一批时从头补齐，网格不留半排空位 */
  view(batch: number): SheetInfo[] {
    if (this.items.length === 0) {
      return [];
    }
    if (this.cursor >= this.items.length) {
      this.cursor = 0;
    }
    let out: SheetInfo[] = this.items.slice(this.cursor, this.cursor + batch);
    if (out.length < batch && this.items.length > out.length) {
      out = out.concat(this.items.slice(0, Math.min(batch - out.length, this.items.length - out.length)));
    }
    for (const item of out) {
      this.shown.add(item.platform + item.id);
    }
    return out;
  }

  /** 游标还能不能往后走（还没绕回开头） */
  ahead(): boolean {
    return this.items.length > this.cursor + 1;
  }

  /** 池里剩余是否已经不够两批，该补货了 */
  nearEnd(batch: number): boolean {
    return this.items.length - this.cursor < batch * 2;
  }

  /** 推进一批；已经是最后一批就绕回开头（点了必须有内容，不能空着等网络） */
  advance(batch: number): SheetInfo[] {
    if (this.items.length === 0) {
      return [];
    }
    if (this.cursor + batch >= this.items.length) {
      this.cursor = 0;
    } else {
      this.cursor += batch;
    }
    return this.view(batch);
  }

  /**
   * 换一批的主路径：向取数器要下一批数据，优先挑没展示过的插在游标之后，
   * 并把游标直接移到这批新内容上返回。取不到新东西就返回空数组，
   * 由调用方回退到 advance（池内绕圈），保证点了不会空着等网络。
   *
   * 取数序号单调递增，具体抓哪个分类 / 哪一页 / 每日推荐由取数器决定；
   * 这里只负责按 platform+id 去重、把「没看过」排在前面、洗牌后插入。
   */
  async grow(fetch: SheetFetch, batch: number): Promise<SheetInfo[]> {
    const seq = this.seq;
    const n = ++this.fetchSeq;
    try {
      const list: SheetInfo[] = await fetch(n);
      if (seq !== this.seq || list.length === 0) {
        return [];
      }
      const inPool = new Set<string>();
      for (const item of this.items) {
        inPool.add(item.platform + item.id);
      }
      const brandNew: SheetInfo[] = [];
      const seenBefore: SheetInfo[] = [];
      for (const item of list) {
        const id: string = item.platform + item.id;
        if (inPool.has(id)) {
          continue;
        }
        inPool.add(id);
        if (this.shown.has(id)) {
          seenBefore.push(item);
        } else {
          brandNew.push(item);
        }
      }
      const insert: SheetInfo[] = brandNew.length > 0 ? brandNew : seenBefore;
      if (insert.length === 0) {
        return [];
      }
      this.shuffle(insert);
      // 追加到池尾并把游标移到这批新内容：用户每次点都看到刚抓到的 8 张；
      // 之前批次没展示完的留在池里，作为无网 / 取尽时的兜底内容。
      const start = this.items.length;
      this.items = this.items.concat(insert);
      this.cursor = start;
      return this.view(batch);
    } catch (e) {
      console.info('[pool] 换一批取数失败，回退池内: ' + String(e));
      return [];
    }
  }
}

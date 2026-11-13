/**
 * 发现页「板块流」数据模型（v2.56 · 发现页重做）
 *
 * 以前发现页把骨架写死在 UI 里：不管切到哪个平台，永远是
 * 「排行榜 / 推荐歌单」两个分段 + 分类胶囊 + 两列网格，平台之间只换数据不换版式。
 * 实际上四个平台官方发现页的板块构成完全不同：
 *   · 网易云：banner + 每日推荐 + 推荐新歌 + 独家放送 + 排行榜 + 歌单广场
 *   · QQ音乐：官方已去掉首页 banner，主打分组榜单（巅峰/地区/特色/全球）+ 歌单广场
 *   · 酷狗：banner + 精选歌单 + 新歌首发 + 带前三歌预览的热门榜单 + 热门歌手 + 歌单广场
 *   · 酷我：热门歌单 / 最新歌单 + 多分组榜单（官方/特色/场景/语言/全球）
 *
 * 现在改为「数据驱动」：core/DiscoverFeed.ets 实时拉各平台官方发现接口，
 * 按平台编排成 DiscoverSection[]（板块类型 + 顺序 + 条目全部来自数据），
 * UI 层只按 section.layout 分派渲染，不认识「平台」这个概念，也不写死板块数量。
 * 官方接口返回什么板块就渲染什么板块；某个接口挂了，那个板块自动缺席，不塞假数据。
 *
 * 为什么 item 是「扁平 + payload JSON」：
 * ArkTS 的 @Prop 对嵌套自定义对象数组深拷贝有限制，而板块卡片要作为独立
 * @Component 才能跟着 @State 刷新（@Builder 按值传参只在首次生效，工程踩过坑）。
 * 所以条目只放 string / number，点击时再从 payload 还原 SheetInfo / SongInfo / ArtistInfo。
 */

/** 板块布局：UI 只认这八种，新增板块不必改页面骨架 */
export const LAY_BANNER: number = 0;      // 大图横滑（官方 banner 位）
export const LAY_CARD_RAIL: number = 1;   // 方形封面卡横滑（歌单 / 专辑）
export const LAY_SONG_LIST: number = 2;   // 带序号的歌曲行（推荐新歌 / 新歌首发）
export const LAY_RANK_CARDS: number = 3;  // 两列榜单网格，带榜内前三歌预览
export const LAY_RANK_GROUP: number = 4;  // 分组榜单（QQ 四组 / 酷我五组）
export const LAY_ARTIST_RAIL: number = 5; // 圆形头像横滑（热门歌手）
export const LAY_BIG_CARD: number = 6;    // 大图横滑（独家放送 / 精选歌单）
export const LAY_SHEET_GRID: number = 7;  // 两列推荐歌单网格 + 换一批（SheetPool）

/** 条目点击行为 */
export const ACT_SHEET: number = 0;   // 打开歌单 / 榜单 / 专辑详情
export const ACT_SONG: number = 1;    // 直接播放歌曲
export const ACT_ARTIST: number = 2;  // 打开歌手页
export const ACT_SEARCH: number = 3;  // 官方页面无对应内容，跳搜索

/**
 * 一个板块条目。字段名兼顾了既有榜单卡的渲染（cover / coverFallback / trackCount），
 * 让 boardGrid 的「主封面失败切备用封面」链路原样复用，不新造一套封面逻辑。
 */
export class DiscoverItem {
  id: string = '';
  title: string = '';
  subtitle: string = '';
  cover: string = '';
  coverFallback: string = '';
  /** 右上角标：播放量 / 更新频率 / 类型标签 */
  badge: string = '';
  /** 榜单卡下方的榜内前三歌预览 */
  extra: string = '';
  /** 分组板块里的组名（LAY_RANK_GROUP） */
  group: string = '';
  /** 榜单歌曲数（榜单卡左下角沿用「N 首」） */
  trackCount: number = 0;
  action: number = ACT_SHEET;
  platform: string = '';
  /** SheetInfo.kind：rank / playlist / album */
  kind: string = '';
  /** SheetInfo / SongInfo / ArtistInfo 的 JSON 原文，点击时还原 */
  payload: string = '';
  /** ACT_SEARCH 时的搜索词 */
  keyword: string = '';

  constructor() {
  }
}

/**
 * 板块「更多 ›」描述：首页板块是官方发现页的橱窗预览，点更多进全量页看全部。
 *
 * 以前每个板块把 items 一次性铺完就没有然后了，条数被 URL 里的 limit / ein /
 * slice(0,8) 钉死，用户点板块标题也没有任何反应。这里把「去哪看全部」变成
 * 数据：source 交给 DiscoverFeed.more() 分派官方接口，rank 为真则直接复用既有
 * 平台榜单页（子榜 tab + 歌曲列表，本来就是官方榜单的完整视图）。
 * UI 只认这几个字段，不认平台，也不为某个板块单独写跳转分支。
 */
export class DiscoverMore {
  /** 数据源 key：'sheets' 歌单广场 / 'banner' 大图 / 'newsong' 新歌 / 'singers' 歌手 */
  source: string = '';
  /** 全量页标题（一般就是板块名） */
  title: string = '';
  /** 平台 id，交给官方接口取数 */
  platform: string = '';
  /** 默认分类 id；歌单类全量页用它切分类 */
  tagId: string = '';
  /** true = 走官方歌单广场分页接口「上拉看更多」；false = 官方该入口一次给全 */
  paged: boolean = true;
  /** 是否显示分类筛选胶囊 */
  tagged: boolean = false;
  /** 榜单类板块：直接进既有 rankboard 页，不新建全量页 */
  rank: boolean = false;
  /** paged=false 时把首页这一板块的 items 序列化带来，全量页竖排铺满即可 */
  snapshot: string = '';

  constructor() {
  }
}

/** 构造「更多」描述。快照类由编排层在 build() 里补 snapshot */
export function newDiscoverMore(source: string, title: string, platform: string,
  tagId: string, paged: boolean, tagged: boolean, rank: boolean): DiscoverMore {
  const m = new DiscoverMore();
  m.source = source;
  m.title = title;
  m.platform = platform;
  m.tagId = tagId;
  m.paged = paged;
  m.tagged = tagged;
  m.rank = rank;
  return m;
}

/** 板块全量页的导航参数（ArkTS 不接受裸对象字面量，统一包一层） */
export class DiscoverMoreParam {
  spec: DiscoverMore = new DiscoverMore();

  constructor(spec: DiscoverMore) {
    this.spec = spec;
  }
}

/** 一个发现板块 */
export class DiscoverSection {
  /** ForEach 的稳定 key，含平台前缀，切平台时整批重建 */
  key: string = '';
  title: string = '';
  /** 板块副标题，用来说明数据是否实时、来自官方哪个入口 */
  subtitle: string = '';
  layout: number = LAY_CARD_RAIL;
  items: DiscoverItem[] = [];
  /** 「更多 ›」去哪看全部；source 与 rank 都为空时标题右侧不出现入口 */
  more: DiscoverMore = new DiscoverMore();

  constructor() {
  }
}

export function newDiscoverItem(): DiscoverItem {
  return new DiscoverItem();
}

export function newDiscoverSection(key: string, title: string, subtitle: string,
  layout: number, items: DiscoverItem[]): DiscoverSection {
  const section = new DiscoverSection();
  section.key = key;
  section.title = title;
  section.subtitle = subtitle;
  section.layout = layout;
  section.items = items;
  return section;
}

/** 把「来自哪个官方入口」写进副标题，让实时读取这件事在界面上可见 */
export function officialNote(source: string): string {
  return '官方实时 · ' + source;
}

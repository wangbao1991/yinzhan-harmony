import {
  palette, Palette, FONT, RADIUS, FLOAT_SPACE, PAGE_PAD,
  glassCardBase, glassSurface, glassDepth, glassEdgeWidth, glassEdgeColor, glassShadow
} from '../../common/Constants';
import { SheetInfo, SheetTag } from '../../common/Models';
import {
  DiscoverItem, DiscoverSection, DiscoverMore,
  LAY_BANNER, LAY_CARD_RAIL, LAY_SONG_LIST, LAY_RANK_CARDS, LAY_RANK_GROUP,
  LAY_ARTIST_RAIL, LAY_BIG_CARD, LAY_SHEET_GRID
} from '../../common/Discover';
import { DISCOVER_PLATFORM_IDS, platformDef } from '../../common/Platform';
import { PlatformApi } from '../../core/PlatformApi';
import { DiscoverFeed } from '../../core/DiscoverFeed';
import { openDiscoverItem } from '../../core/DiscoverAction';
import { SheetPool } from '../../core/SheetPool';
import { App } from '../../core/App';
import { TabBarHider } from '../../core/UiBar';
import { EmptyView, LoadingBlock, GlassSheetCard, Cover, IconTap } from '../Common';

/** 一批展示多少张：两列网格，8 张正好四排，和既有「换一批」量对齐 */
const BATCH: number = 8;

/**
 * 发现筛选带专用胶囊：和首页 / 设置页同一套青绿液态玻璃。
 * 必须是独立 @Component：@Builder 按值传参只在首次调用生效，
 * 而平台 / 分类的选中态由 @State 驱动，用 @Prop 才会跟着刷新。
 */
@Component
struct GlassChip {
  @Prop text: string = '';
  @Prop active: boolean = false;
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;
  onTap: () => void = (): void => {
  };


  build() {
    if (this.active) {
      Text(this.text)
        .fontSize(FONT.callout)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FF191713')
        .padding({ left: 14, right: 14, top: 7, bottom: 7 })
        .borderRadius(RADIUS.pill)
        .backgroundColor(palette(this.isDark).primary)
        .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
        .shadow(glassShadow(this.isDark, this.lightLevel))
        .onClick(() => {
          this.onTap();
        })
    } else {
      Text(this.text)
        .fontSize(FONT.callout)
        .fontWeight(FontWeight.Normal)
        .fontColor(palette(this.isDark).text2)
        .padding({ left: 14, right: 14, top: 7, bottom: 7 })
        .borderRadius(RADIUS.pill)
        .backgroundColor(glassCardBase(this.isDark))
        .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
        .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
        .shadow(glassShadow(this.isDark, this.lightLevel))
        .onClick(() => {
          this.onTap();
        })
    }
  }
}

/**
 * 板块标题右侧的「更多 ›」入口。
 *
 * 原来是 `items.length + ' 项'` 的纯展示角标：既不是官方 UI，也点不动，
 * 还把「这一板块被接口 limit / slice 钉死的数量」暴露给用户，容易被当成上限。
 * 现在换成真正能点的入口，按 more 描述分派到全量页或既有榜单页。
 * 没有 more 描述的板块（例如接口挂掉后的空板块）不显示，不留死键。
 */
@Component
struct MoreChip {
  @Prop more: DiscoverMore = new DiscoverMore();
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;

  private p(): Palette {
    return palette(this.isDark);
  }


  build() {
    if (this.more.source.length > 0 || this.more.rank) {
      Row({ space: 2 }) {
        Text('更多')
          .fontSize(FONT.micro)
          .fontColor(this.p().text2)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(11)
          .fontColor([this.p().text2])
      }
      .padding({ left: 10, right: 9, top: 5, bottom: 5 })
      .borderRadius(RADIUS.pill)
      .backgroundColor(glassCardBase(this.isDark))
      .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
      .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
      .shadow(glassShadow(this.isDark, this.lightLevel))
      .onClick(() => {
        App.get().openDiscoverSection(this.more);
      })
    }
  }
}

/**
 * 一个「发现板块」的渲染器 —— 全页只认 layout，不认平台。
 *
 * 这是本次重做的核心：以前 DiscoverPage 把「排行榜 / 推荐歌单」两个分段、
 * 两列网格、分类胶囊全写死在 build() 里，四个平台共用一副骨架，只换数据。
 * 现在每块长什么样、有几块、按什么顺序，都由 core/DiscoverFeed.ets 实时编排的
 * DiscoverSection 决定；这里只按 section.layout 把 8 种布局分派出去。
 * 于是网易云（banner + 每日推荐 + 推荐新歌 + 独家放送 + 榜单 + 歌单广场）、
 * QQ（分组榜单打头、无 banner）、酷狗（多一个热门歌手 / 榜内前三歌）、
 * 酷我（歌单为主 + 五组榜单）自然长成四种不同的界面。
 */
@Component
struct SectionBlock {
  @Prop section: DiscoverSection = new DiscoverSection();
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;
  onItem: (item: DiscoverItem) => void = (item: DiscoverItem): void => {
  };

  private p(): Palette {
    return palette(this.isDark);
  }

  /** 不同板块的横滑卡宽度不同：大图 / 榜单组 / 普通歌单 */
  private cardW(): number {
    if (this.section.layout === LAY_BIG_CARD) {
      return 224;
    }
    if (this.section.layout === LAY_RANK_GROUP) {
      return 148;
    }
    return 132;
  }


  build() {
    Column({ space: 12 }) {
      // 板块标题 + 「官方实时 · 来源」副标题：让「实时读取」在界面上可见
      Row() {
        Column({ space: 3 }) {
          Text(this.section.title)
            .fontSize(FONT.headline)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.p().text)
          Text(this.section.subtitle)
            .fontSize(FONT.micro)
            .fontColor(this.p().text3)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        // 原来是「N 项」纯展示角标，现在换成能点进去看全部的「更多 ›」
        MoreChip({ more: this.section.more })
      }
      .width('100%')
      .padding({ left: 2, right: 2 })

      if (this.section.layout === LAY_BANNER) {
        this.bannerBody()
      } else if (this.section.layout === LAY_SONG_LIST) {
        this.songListBody()
      } else if (this.section.layout === LAY_RANK_CARDS) {
        this.boardGrid()
      } else if (this.section.layout === LAY_ARTIST_RAIL) {
        this.artistBody()
      } else {
        this.railBody()
      }
    }
    .width('100%')
    .padding({ left: 2, right: 2, top: 4, bottom: 4 })
  }

  /** 官方 banner 位：自动轮播大图，图上压标题与来源角标 */
  @Builder
  bannerBody() {
    Swiper() {
      ForEach(this.section.items, (card: DiscoverItem) => {
        Stack({ alignContent: Alignment.BottomStart }) {
          Cover({ uri: card.cover, fallbackUri: card.coverFallback, side: 0, radius: 16 })
          Column()
            .width('100%')
            .height('100%')
            .linearGradient({ angle: 180, colors: [['#00000000', 0.35], ['#B3000000', 1]] })
          Column({ space: 3 }) {
            Text(card.title)
              .fontSize(FONT.callout)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(card.subtitle)
              .fontSize(FONT.micro)
              .fontColor('#E6FFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding({ left: 14, right: 14, bottom: 12 })
        }
        .width('100%')
        .height(168)
        .borderRadius(16)
        .clip(true)
        .backgroundColor(glassCardBase(this.isDark))
        .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
        .shadow(glassShadow(this.isDark, this.lightLevel))
        .onClick(() => {
          this.onItem(card);
        })
      }, (card: DiscoverItem) => card.id)
    }
    .autoPlay(true)
    .interval(4200)
    .loop(true)
    .indicator(false)
    .width('100%')
    .height(168)
    .borderRadius(16)
    .clip(true)
  }

  /** 横滑封面卡：歌单 / 精选歌单 / 分组榜单（后者额外显示榜内前三歌） */
  @Builder
  railBody() {
    Scroll() {
      Row({ space: 12 }) {
        ForEach(this.section.items, (card: DiscoverItem) => {
          Column({ space: 6 }) {
            Stack({ alignContent: Alignment.TopEnd }) {
              Cover({
                uri: card.cover,
                fallbackUri: card.coverFallback,
                side: this.cardW(),
                radius: 12
              })
              if (card.badge.length > 0) {
                Text(card.badge)
                  .fontSize(9)
                  .fontColor('#FFFFFFFF')
                  .backgroundColor('#80000000')
                  .borderRadius(5)
                  .padding({ left: 5, right: 5, top: 2, bottom: 2 })
                  .margin({ top: 6, right: 6 })
              }
            }
            .width(this.cardW())
            .height(this.section.layout === LAY_BIG_CARD ? 126 : this.cardW())
            .borderRadius(12)
            .clip(true)

            Text(card.title)
              .fontSize(FONT.callout)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.p().text)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width(this.cardW())
            Text(card.subtitle)
              .fontSize(FONT.micro)
              .fontColor(this.p().text3)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width(this.cardW())
            if (card.extra.length > 0) {
              Text(card.extra)
                .fontSize(FONT.micro)
                .fontColor(this.p().text2)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width(this.cardW())
            }
          }
          .alignItems(HorizontalAlign.Start)
          .padding(8)
          .borderRadius(RADIUS.lg)
          .backgroundColor(glassCardBase(this.isDark))
          .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
          .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
          .shadow(glassShadow(this.isDark, this.lightLevel))
          .onClick(() => {
            this.onItem(card);
          })
        }, (card: DiscoverItem) => card.id)
      }
      .padding({ left: 2, right: 2, bottom: 2 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .edgeEffect(EdgeEffect.Spring)
  }

  /** 官方「新歌 / 推荐新歌」：带序号的歌曲行，点了直接播放 */
  @Builder
  songListBody() {
    Column({ space: 8 }) {
      // 首页橱窗只放前 8 条，完整列表交给「更多 ›」全量页（不再出现「写 12 只画 8」）
      ForEach(this.section.items.slice(0, 8), (card: DiscoverItem, idx: number) => {
        Row({ space: 11 }) {
          Text((idx + 1).toString())
            .fontSize(FONT.callout)
            .fontWeight(FontWeight.Medium)
            .fontColor(idx < 3 ? this.p().primary : this.p().text3)
            .width(20)
            .textAlign(TextAlign.Center)
          Cover({ uri: card.cover, side: 46, radius: 9 })
          Column({ space: 3 }) {
            Text(card.title)
              .fontSize(FONT.callout)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.p().text)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(card.subtitle)
              .fontSize(FONT.micro)
              .fontColor(this.p().text3)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          if (card.badge.length > 0) {
            Text(card.badge)
              .fontSize(FONT.micro)
              .fontColor(this.p().text3)
          }
        }
        .width('100%')
        .padding(10)
        .borderRadius(RADIUS.lg)
        .backgroundColor(glassCardBase(this.isDark))
        .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
        .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
        .shadow(glassShadow(this.isDark, this.lightLevel))
        .onClick(() => {
          this.onItem(card);
        })
      }, (card: DiscoverItem) => card.id)
    }
    .width('100%')
  }

  /** 官方榜单：两列封面网格 + 榜内前三歌预览 + 「N 首」角标 + 下沿聚光 */
  @Builder
  boardGrid() {
    Grid() {
      ForEach(this.section.items, (board: DiscoverItem) => {
        GridItem() {
          Column({ space: 6 }) {
            Stack({ alignContent: Alignment.BottomStart }) {
              Cover({ uri: board.cover, fallbackUri: board.coverFallback, side: 0, radius: 14 })
              Column()
                .width('100%')
                .height('100%')
                .linearGradient({
                  angle: 135,
                  colors: [
                    ['rgba(255,255,255,0.36)', 0],
                    ['rgba(255,255,255,0.10)', 0.26],
                    ['rgba(255,255,255,0)', 0.56],
                    ['rgba(255,255,255,0)', 1]
                  ]
                })
              Column()
                .width('100%')
                .height('100%')
                .linearGradient({ angle: 180, colors: [['#00000000', 0.4], ['#8C000000', 1]] })
              Column()
                .width('100%')
                .height('26%')
                .linearGradient({ angle: 180, colors: glassDepth(this.isDark, this.lightLevel) })
              if (board.trackCount > 0) {
                Text(board.trackCount.toString() + ' 首')
                  .fontSize(10)
                  .fontColor('#E6FFFFFF')
                  .margin({ left: 10, bottom: 8 })
              }
            }
            .width('100%')
            .aspectRatio(1)
            .borderRadius(14)
            .clip(true)

            Text(board.title)
              .fontSize(FONT.callout)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.p().text)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .padding({ left: 2, right: 2 })
            Text(board.extra.length > 0 ? board.extra : board.subtitle)
              .fontSize(FONT.micro)
              .fontColor(this.p().text3)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .padding({ left: 2, right: 2 })
          }
          .width('100%')
          .padding(8)
          .borderRadius(RADIUS.lg)
          .alignItems(HorizontalAlign.Start)
          .backgroundColor(glassCardBase(this.isDark))
          .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
          .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
          .shadow(glassShadow(this.isDark, this.lightLevel))
          .onClick(() => {
            this.onItem(board);
          })
        }
      }, (board: DiscoverItem) => board.id)
    }
    .columnsTemplate('1fr 1fr')
    .columnsGap(14)
    .rowsGap(18)
    .width('100%')
    .height(Math.ceil(this.section.items.length / 2) * 240)
    .scrollBar(BarState.Off)
  }

  /** 官方「热门歌手」：圆形头像横滑 */
  @Builder
  artistBody() {
    Scroll() {
      Row({ space: 16 }) {
        ForEach(this.section.items, (card: DiscoverItem) => {
          Column({ space: 8 }) {
            Cover({ uri: card.cover, fallbackText: card.title, side: 72, radius: 36 })
            Text(card.title)
              .fontSize(FONT.callout)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.p().text)
              .maxLines(1)
              .textAlign(TextAlign.Center)
              .width(84)
            Text(card.subtitle)
              .fontSize(9)
              .fontColor(this.p().text3)
              .maxLines(1)
              .textAlign(TextAlign.Center)
              .width(84)
          }
          .alignItems(HorizontalAlign.Center)
          .padding(10)
          .borderRadius(RADIUS.lg)
          .backgroundColor(glassCardBase(this.isDark))
          .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
          .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
          .shadow(glassShadow(this.isDark, this.lightLevel))
          .onClick(() => {
            this.onItem(card);
          })
        }, (card: DiscoverItem) => card.id)
      }
      .padding({ left: 2, right: 2 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
  }
}

/**
 * 发现（v2.56 重做）：由 DiscoverFeed 实时编排的板块流。
 *
 * 页面顶部没有标题栏：分割线以上只留平台 / 分类筛选与搜索入口，
 * 内容直接顶到状态栏下沿。刷新仍走下拉（Refresh）。
 * 板块本身不再是「排行榜 / 推荐歌单」两个写死分段，而是按平台从官方
 * 发现接口实时拉取的一组 DiscoverSection，ForEach 逐个交给 SectionBlock 渲染。
 */
@Component
export struct DiscoverPage {
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;
  @StorageProp('topSafe') topSafe: number = 24;
  /** 默认发现平台。常驻一级页不会重建，设置页改完靠广播推过来 */
  @StorageProp('discoverPlatform') @Watch('onPlatformBroadcast') broadcastPlatform: string = '';
  @StorageProp('tabIndex') @Watch('onTabIndexChange') shellTab: number = 0;
  @StorageProp('foregroundAt') @Watch('onAppForeground') foregroundAt: number = 0;

  /** 动态板块流：唯一的内容数据源，平台切换时整批替换 */
  @State sections: DiscoverSection[] = [];
  /** 推荐歌单池（既有「换一批」机制）：只服务 LAY_SHEET_GRID 板块 */
  @State sheets: SheetInfo[] = [];
  @State tags: SheetTag[] = [];
  @State tagId: string = '全部';
  @State platform: string = 'wy';
  @State loading: boolean = false;
  @State hasMore: boolean = true;
  @State swapping: boolean = false;
  @State message: string = '';
  @State refreshing: boolean = false;

  private api: PlatformApi = new PlatformApi();
  private feed: DiscoverFeed = new DiscoverFeed();
  private recPool: SheetPool = new SheetPool();
  /** 请求序号：切平台时让上一次的异步结果作废，避免旧数据盖掉新数据 */
  private requestSeq: number = 0;
  /** 板块流有效期：回前台 / 切回本 Tab 时超时就悄悄重拉，保证「实时」 */
  private feedAt: number = 0;
  private platforms: string[] = DISCOVER_PLATFORM_IDS;

  aboutToDisappear(): void {
    TabBarHider.get().reset();
  }

  aboutToAppear(): void {
    this.platform = this.safePlatform(App.get().settings.discoverPlatform());
    if (this.broadcastPlatform !== this.platform) {
      AppStorage.setOrCreate('discoverPlatform', this.platform);
    }
    this.load(false);
  }

  private safePlatform(id: string): string {
    return this.platforms.indexOf(id) >= 0 ? id : 'wy';
  }

  onPlatformBroadcast(): void {
    const id = this.safePlatform(this.broadcastPlatform);
    if (id === this.platform) {
      return;
    }
    this.platform = id;
    this.tags = [];
    this.load(true);
  }

  private p(): Palette {
    return palette(this.isDark);
  }

  private poolKey(): string {
    return this.platform + '|' + this.tagId;
  }

  onTabIndexChange(): void {
    if (this.shellTab === 1) {
      this.checkStale();
    }
  }

  onAppForeground(): void {
    if (this.shellTab === 1) {
      this.checkStale();
    }
  }

  /** 板块流超过 5 分钟就重拉；推荐池自己带 TTL，这里只管官方板块 */
  private checkStale(): void {
    if (this.sections.length === 0) {
      return;
    }
    if (Date.now() - this.feedAt < 5 * 60 * 1000) {
      return;
    }
    this.load(true, true);
  }

  /**
   * 取数器。参数 n 是 SheetPool 给出的单调递增序号，不再是「页码」：
   * 同一个 page 反复请求永远是那几条静态热门，必须把 n 摊到
   * 「每日推荐 / 分类 / 页码」多个维度上才刷得出新歌单。
   */
  private sheetFetcher(): (n: number) => Promise<SheetInfo[]> {
    const platform = this.platform;
    const tags: string[] = [];
    for (const t of this.tags) {
      tags.push(t.id);
    }
    return (n: number): Promise<SheetInfo[]> => this.nextFeedPage(platform, tags, n);
  }

  private async nextFeedPage(platform: string, tags: string[], n: number): Promise<SheetInfo[]> {
    if (platform === 'wy' && n % 6 === 1) {
      const daily = await this.api.homeSheets('wy', 1);
      if (daily.length > 0) {
        return daily;
      }
    }
    if (platform === 'kg') {
      return this.api.sheetsByTag('kg', '全部', ((n - 1) % 20) + 1);
    }
    return this.feedByTag(platform, tags, n);
  }

  private async feedByTag(platform: string, tags: string[], n: number): Promise<SheetInfo[]> {
    const cats: string[] = [];
    for (const id of tags) {
      cats.push(id);
    }
    if (cats.length === 0) {
      cats.push(platform === 'kw' ? 'hot' : '10000000');
    }
    const idx: number = (n - 1) % cats.length;
    const tagId: string = idx >= 0 && idx < cats.length ? cats[idx] : cats[0];
    const page: number = 1 + Math.floor((n - 1) / cats.length);
    return this.api.sheetsByTag(platform, tagId, page);
  }

  /**
   * 取数据：并发拉「官方板块流」与「推荐歌单池」。
   * 板块流按平台完全不同；某个官方接口挂了，那块自动缺席，不塞假数据。
   */
  private async load(keep: boolean, freshSeed: boolean = false): Promise<void> {
    const seq = ++this.requestSeq;
    if (!keep) {
      this.loading = true;
      this.sections = [];
    }
    this.message = '';
    try {
      const built = await this.feed.build(this.platform);
      if (seq !== this.requestSeq) {
        return;
      }
      this.sections = built;
      this.feedAt = Date.now();
      await this.loadSheets(seq, freshSeed);
    } catch (e) {
      if (seq === this.requestSeq) {
        this.message = '加载失败，请检查网络后重试。';
      }
    }
    if (seq === this.requestSeq) {
      this.loading = false;
    }
  }

  private async loadSheets(seq: number, freshSeed: boolean): Promise<void> {
    if (this.tags.length === 0) {
      const tags = await this.api.sheetTags(this.platform);
      if (seq !== this.requestSeq) {
        return;
      }
      this.tags = tags;
      if (tags.length > 0) {
        this.tagId = tags[0].id;
      }
    }
    const key = this.poolKey();
    if (!freshSeed && this.recPool.valid(key)) {
      this.showBatch();
      return;
    }
    const ok = await this.recPool.build(key, this.sheetFetcher(), true, freshSeed);
    if (seq !== this.requestSeq) {
      return;
    }
    if (!ok && this.recPool.size() === 0) {
      return;
    }
    this.showBatch();
  }

  private showBatch(): void {
    this.sheets = this.recPool.view(BATCH);
    this.hasMore = this.recPool.size() > BATCH;
  }

  private async nextBatch(): Promise<void> {
    if (this.swapping) {
      return;
    }
    if (this.recPool.size() === 0) {
      await this.load(true);
      return;
    }
    this.swapping = true;
    try {
      const fresh = await this.recPool.grow(this.sheetFetcher(), BATCH);
      this.sheets = fresh.length > 0 ? fresh : this.recPool.advance(BATCH);
      this.hasMore = true;
    } finally {
      this.swapping = false;
    }
  }

  private async pullRefresh(): Promise<void> {
    this.refreshing = true;
    await this.load(true, true);
    this.refreshing = false;
  }

  private switchPlatform(id: string): void {
    if (this.platform === id) {
      return;
    }
    this.platform = id;
    App.get().settings.setDiscoverPlatform(id);
    this.tags = [];
    this.load(true);
  }

  /** 板块条目点击：与全量页共用 core/DiscoverAction 的还原逻辑，音源引擎零改动 */
  private openItem(item: DiscoverItem): void {
    openDiscoverItem(item);
  }

  /**
   * 筛选带：平台胶囊（+ 推荐歌单分类）+ 全局搜索入口。
   * 没有「排行榜 / 推荐歌单」写死分段了 —— 板块由 sections 数据决定。
   */
  @Builder
  filters() {
    Column({ space: 10 }) {
      Row() {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.clock'))
            .fontSize(15)
            .fontColor([this.p().primary])
          Text('官方发现 · 实时更新')
            .fontSize(FONT.caption)
            .fontColor(this.p().text2)
        }
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .borderRadius(RADIUS.pill)
        .backgroundColor(glassCardBase(this.isDark))
        .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
        .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
        .shadow(glassShadow(this.isDark, this.lightLevel))
        Blank()
        IconTap({
          icon: $r('sys.symbol.magnifyingglass'),
          iconSize: 21,
          color: this.p().text2,
          paddingSize: 8,
          onTap: () => {
            App.get().openSearch('');
          }
        })
      }
      .width('100%')

      Scroll() {
        Row({ space: 8 }) {
          ForEach(this.platforms, (id: string) => {
            GlassChip({
              text: platformDef(id).short,
              active: this.platform === id,
              onTap: () => {
                this.switchPlatform(id);
              }
            })
          }, (id: string) => id)

          if (this.tags.length > 1) {
            Divider()
              .vertical(true)
              .height(20)
              .color(this.isDark ? 'rgba(255,255,255,0.22)' : 'rgba(96,150,140,0.32)')
              .margin({ left: 2, right: 2 })
            ForEach(this.tags, (tag: SheetTag) => {
              GlassChip({
                text: tag.name,
                active: this.tagId === tag.id,
                onTap: () => {
                  if (this.tagId !== tag.id) {
                    this.tagId = tag.id;
                    this.load(true);
                  }
                }
              })
            }, (tag: SheetTag) => tag.id)
          }
        }
        .padding({ top: 2, bottom: 2 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
    }
    .width('100%')
    .padding({ top: 6, bottom: 10 })
  }

  /** LAY_SHEET_GRID 板块：沿用既有 SheetPool「换一批」机制 */
  @Builder
  sheetGrid() {
    Column({ space: 4 }) {
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
        ForEach(this.sheets, (sheet: SheetInfo) => {
          GlassSheetCard({
            sheet: sheet,
            cardWidth: 140,
            onTap: () => {
              App.get().openSheet(sheet);
            }
          })
            .margin({ bottom: 18 })
        }, (sheet: SheetInfo) => sheet.platform + sheet.id)
      }
      .width('100%')

      if (this.hasMore) {
        Button(this.swapping ? '正在找新歌单…' : '换一批')
          .fontSize(FONT.callout)
          .fontColor(this.p().text2)
          .backgroundColor(glassCardBase(this.isDark))
          .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
          .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
          .shadow(glassShadow(this.isDark, this.lightLevel))
          .borderRadius(RADIUS.pill)
          .height(38)
          .width('60%')
          .enabled(!this.swapping)
          .onClick(() => {
            this.nextBatch();
          })
          .margin({ top: 4, bottom: 20 })
      }
    }
    .width('100%')
  }


  build() {
    Column() {
      this.filters()

      if (this.loading && this.sections.length === 0 && this.sheets.length === 0) {
        Column() {
          LoadingBlock({ text: '正在读取官方发现内容' })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.message.length > 0 && this.sections.length === 0 && this.sheets.length === 0) {
        Column() {
          EmptyView({
            icon: $r('sys.symbol.discover'),
            title: '这里还没有内容',
            hint: this.message,
            action: '重试',
            onAction: () => {
              this.load(false);
            }
          })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Refresh({ refreshing: $$this.refreshing }) {
          Scroll() {
            Column({ space: 22 }) {
              ForEach(this.sections, (section: DiscoverSection) => {
                if (section.layout === LAY_SHEET_GRID) {
                  Column({ space: 12 }) {
                    Row() {
                      Column({ space: 3 }) {
                        Text(section.title)
                          .fontSize(FONT.headline)
                          .fontWeight(FontWeight.Bold)
                          .fontColor(this.p().text)
                        Text(section.subtitle)
                          .fontSize(FONT.micro)
                          .fontColor(this.p().text3)
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)
                      MoreChip({ more: section.more })
                    }
                    .width('100%')
                    .padding({ left: 2, right: 2 })
                    this.sheetGrid()
                  }
                  .width('100%')
                  .padding({ left: 2, right: 2, top: 4, bottom: 4 })
                } else {
                  SectionBlock({
                    section: section,
                    onItem: (item: DiscoverItem): void => {
                      this.openItem(item);
                    }
                  })
                }
              }, (section: DiscoverSection) => section.key)
            }
            .width('100%')
            .padding({ top: 4, bottom: FLOAT_SPACE + 16 })
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .onScrollFrameBegin((offset: number, state: ScrollState) => {
            TabBarHider.get().feed(offset);
            return { offsetRemain: offset };
          })
        }
        .layoutWeight(1)
        .onRefreshing(() => {
          this.pullRefresh();
        })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: PAGE_PAD, right: PAGE_PAD, top: this.topSafe + 8 })
    .backgroundColor('#00000000')
  }
}

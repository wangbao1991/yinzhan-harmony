import {
  palette, Palette, FONT, RADIUS, PAGE_PAD, FLOAT_SPACE,
  glassCardBase, glassSurface, glassEdgeWidth, glassEdgeColor, glassShadow
} from '../../common/Constants';
import { SheetTag } from '../../common/Models';
import {
  DiscoverItem, DiscoverMore, DiscoverMoreParam
} from '../../common/Discover';
import { DiscoverFeed } from '../../core/DiscoverFeed';
import { openDiscoverItem } from '../../core/DiscoverAction';
import { App } from '../../core/App';
import { TabBarHider } from '../../core/UiBar';
import { EmptyView, LoadingBlock, Cover, PageBar, Chip } from '../Common';

/**
 * 板块全量页（v2.56 · 发现页「更多 ›」的落点）。
 *
 * 首页发现页是官方发现页的橱窗预览，每个板块只放前 6/12/18/19 条；
 * 这里按 DiscoverMore 描述继续从官方接口取「看全部」：
 *   · 歌单广场类：sheetsByTag(platform, tag, page) 上拉分页 + 分类切换；
 *   · 榜单类：发现页直接进既有 rankboard 页，不落到这里；
 *   · 快照类（banner / 新歌 / 独家 / 歌手）：官方该入口一次给全，竖排铺满。
 *
 * 渲染的仍是 DiscoverItem，点击复用 DiscoverAction.openDiscoverItem，
 * 与首页板块流完全一致；音源引擎、详情页、路由数量都不因此改变。
 */
@Component
export struct DiscoverSectionPage {
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;
  @StorageProp('topSafe') topSafe: number = 24;

  @State spec: DiscoverMore = new DiscoverMore();
  @State items: DiscoverItem[] = [];
  @State tags: SheetTag[] = [];
  @State tagId: string = '';
  @State page: number = 1;
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State hasMore: boolean = false;
  @State message: string = '';

  private feed: DiscoverFeed = new DiscoverFeed();
  private loaded: boolean = false;
  private reqSeq: number = 0;

  private p(): Palette {
    return palette(this.isDark);
  }

  /** 板块标题下的副标题：把「已加载多少 / 还能不能更多」如实显示出来 */
  private statusText(): string {
    if (this.loading) {
      return '官方实时 · 正在读取';
    }
    if (this.items.length === 0) {
      return '官方实时 · ' + this.spec.source;
    }
    return '官方实时 · 已加载 ' + this.items.length.toString() + ' 项' +
      (this.hasMore ? ' · 上拉看更多' : ' · 已是全部');
  }

  private async loadFirst(): Promise<void> {
    const seq = ++this.reqSeq;
    this.loading = true;
    this.loadingMore = false;
    this.message = '';
    this.page = 1;
    this.hasMore = false;
    let first: DiscoverItem[] = [];
    try {
      if (this.spec.paged) {
        first = await this.feed.more(this.spec, 1, this.tagId);
        if (this.spec.tagged) {
          const tags = await this.feed.moreTags(this.spec);
          if (seq !== this.reqSeq) {
            return;
          }
          this.tags = tags;
        }
      } else {
        first = this.feed.snapshotItems(this.spec);
      }
    } catch (e) {
      first = [];
    }
    if (seq !== this.reqSeq) {
      return;
    }
    this.items = first;
    this.hasMore = this.spec.paged && first.length > 0;
    if (first.length === 0) {
      this.message = this.spec.paged ? '官方暂时没有返回内容，下拉刷新或稍后再试。' : '这个板块暂时没有内容。';
    }
    // 与发现页同款：只在仍是当前请求时收口，切分类 / 快速返回不会把新请求的加载态抹掉
    if (seq === this.reqSeq) {
      this.loading = false;
    }
  }

  /** 上拉到底：只给歌单广场类翻页，快照类官方一次给全，没有下一页 */
  private async loadMore(): Promise<void> {
    if (!this.spec.paged || !this.hasMore || this.loading || this.loadingMore) {
      return;
    }
    this.loadingMore = true;
    const seq = this.reqSeq;
    const next = this.page + 1;
    let list: DiscoverItem[] = [];
    try {
      list = await this.feed.more(this.spec, next, this.tagId);
    } catch (e) {
      list = [];
    }
    if (seq !== this.reqSeq) {
      this.loadingMore = false;
      return;
    }
    const fresh: DiscoverItem[] = [];
    for (const it of list) {
      let dup = false;
      for (const old of this.items) {
        if (old.platform === it.platform && old.id === it.id && old.title === it.title) {
          dup = true;
          break;
        }
      }
      if (!dup) {
        fresh.push(it);
      }
    }
    if (fresh.length === 0) {
      this.hasMore = false;
    } else {
      const merged: DiscoverItem[] = [];
      for (const it of this.items) {
        merged.push(it);
      }
      for (const it of fresh) {
        merged.push(it);
      }
      this.items = merged;
      this.page = next;
    }
    this.loadingMore = false;
  }

  private switchTag(id: string): void {
    if (id === this.tagId) {
      return;
    }
    this.tagId = id;
    this.loadFirst();
  }

  @Builder
  tagRow() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(this.tags, (tag: SheetTag) => {
          Chip({
            text: tag.name,
            active: this.tagId === tag.id,
            onTap: () => {
              this.switchTag(tag.id);
            }
          })
        }, (tag: SheetTag) => tag.id)
      }
      .padding({ top: 2, bottom: 2 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
  }

  /** 两列封面卡网格：歌单 / 榜单 / 大图 / 歌手全量都用它 */
  @Builder
  cardGrid() {
    Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
      ForEach(this.items, (item: DiscoverItem) => {
        Column({ space: 6 }) {
          Stack({ alignContent: Alignment.TopEnd }) {
            Cover({ uri: item.cover, fallbackUri: item.coverFallback, side: 0, radius: 12 })
            if (item.badge.length > 0) {
              Text(item.badge)
                .fontSize(9)
                .fontColor('#FFFFFFFF')
                .backgroundColor('#80000000')
                .borderRadius(5)
                .padding({ left: 5, right: 5, top: 2, bottom: 2 })
                .margin({ top: 6, right: 6 })
            }
          }
          .width('100%')
          .aspectRatio(1)
          .borderRadius(12)
          .clip(true)

          Text(item.title)
            .fontSize(FONT.callout)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.p().text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(item.subtitle)
            .fontSize(FONT.micro)
            .fontColor(this.p().text3)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          if (item.extra.length > 0) {
            Text(item.extra)
              .fontSize(FONT.micro)
              .fontColor(this.p().text2)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
        }
        .width('47%')
        .padding(8)
        .borderRadius(RADIUS.lg)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor(glassCardBase(this.isDark))
        .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
        .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
        .shadow(glassShadow(this.isDark, this.lightLevel))
        .onClick(() => {
          openDiscoverItem(item);
        })
        .margin({ bottom: 14 })
      }, (item: DiscoverItem) => item.platform + item.kind + item.id + item.title)
    }
    .width('100%')
  }

  /** 新歌 / 新歌首发：带序号的歌曲行，点了直接播放 */
  @Builder
  songList() {
    Column({ space: 8 }) {
      ForEach(this.items, (item: DiscoverItem, idx: number) => {
        Row({ space: 11 }) {
          Text((idx + 1).toString())
            .fontSize(FONT.callout)
            .fontWeight(FontWeight.Medium)
            .fontColor(idx < 3 ? this.p().primary : this.p().text3)
            .width(20)
            .textAlign(TextAlign.Center)
          Cover({ uri: item.cover, side: 46, radius: 9 })
          Column({ space: 3 }) {
            Text(item.title)
              .fontSize(FONT.callout)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.p().text)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(item.subtitle)
              .fontSize(FONT.micro)
              .fontColor(this.p().text3)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          if (item.badge.length > 0) {
            Text(item.badge)
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
          openDiscoverItem(item);
        })
      }, (item: DiscoverItem, idx: number) => item.platform + item.id + idx.toString())
    }
    .width('100%')
  }


  build() {
    NavDestination() {
      Column() {
        PageBar({
          title: this.spec.title,
          subtitle: this.statusText(),
          showSearch: true,
          onBack: () => {
            App.get().back();
          },
          onSearch: () => {
            App.get().openSearch('');
          }
        })
        if (this.tags.length > 1) {
          this.tagRow()
        }
        if (this.loading && this.items.length === 0) {
          Column() {
            LoadingBlock({ text: '正在读取官方内容' })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.items.length === 0 && this.message.length > 0) {
          Column() {
            EmptyView({
              icon: $r('sys.symbol.music_note_list'),
              title: '这里还没有内容',
              hint: this.message,
              action: '重试',
              onAction: () => {
                this.loadFirst();
              }
            })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll() {
            Column({ space: 4 }) {
              if (this.spec.source === 'newsong') {
                this.songList()
              } else {
                this.cardGrid()
              }
              if (this.loadingMore) {
                LoadingBlock({ text: '正在加载更多' })
              }
              if (!this.hasMore && this.items.length > 0) {
                Text('已经到底啦 · 官方该入口的全部内容')
                  .fontSize(FONT.micro)
                  .fontColor(this.p().text3)
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .margin({ top: 6, bottom: 6 })
              }
              Row().height(FLOAT_SPACE + 12)
            }
            .width('100%')
            .padding({ top: 10 })
          }
          .width('100%')
          .layoutWeight(1)
          .align(Alignment.Top)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .onScrollFrameBegin((offset: number, state: ScrollState) => {
            TabBarHider.get().feed(offset);
            return { offsetRemain: offset };
          })
          .onReachEnd(() => {
            this.loadMore();
          })
        }
      }
      .width('100%')
      .height('100%')
      .padding({ left: PAGE_PAD, right: PAGE_PAD, top: this.topSafe })
      .backgroundColor('#00000000')
    }
    .hideTitleBar(true)
    .onBackPressed(() => App.get().consumeBackIfQueueOpen())
    .onReady((ctx: NavDestinationContext) => {
      const param = ctx.pathInfo.param as DiscoverMoreParam;
      if (param !== undefined && param !== null && !this.loaded) {
        this.loaded = true;
        this.spec = param.spec;
        this.tagId = param.spec.tagId;
        this.loadFirst();
      }
    })
  }
}

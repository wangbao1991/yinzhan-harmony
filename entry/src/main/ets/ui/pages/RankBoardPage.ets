import {
  palette, Palette, RADIUS, FONT, PAGE_PAD, PAGE_BOTTOM, MINI_BAR_SPACE,
  glassCardBase
} from '../../common/Constants';
import { SongInfo, SheetInfo, RankParam, newSheet } from '../../common/Models';
import { platformShort } from '../../common/Platform';
import { PlatformApi } from '../../core/PlatformApi';
import { RankCache } from '../../core/RankCache';
import { App } from '../../core/App';
import { TabBarHider } from '../../core/UiBar';
import { EmptyView, SongRow, Chip, ImmersiveBar } from '../Common';
import { SongMenu } from '../SongMenu';

/** 骨架屏每行标题条的宽度，长短不一才有「真在排版」的感觉 */
const SKEL_W: string[] = ['72%', '58%', '66%', '80%', '54%', '70%', '62%', '76%', '48%', '68%'];

/**
 * 平台榜单页（沉浸式）：标题浮在内容上方、列表从标题后穿过（参考软件同款）。
 * 子榜 tab 随列表一起滚动，不占常驻空间。
 */
@Component
export struct RankBoardPage {
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('topSafe') topSafe: number = 24;
  @State platform: string = 'kg';
  @State boards: SheetInfo[] = [];
  @State boardIndex: number = 0;
  @State songs: SongInfo[] = [];
  @State loading: boolean = true;
  @State message: string = '';
  @State menuShow: boolean = false;
  @State menuSong: SongInfo = {
    id: '', songmid: '', hash: '', name: '', singer: '', album: '', interval: '',
    source: '', duration: 0, cover: '', lyric: '', url: '', quality: ''
  };
  private api: PlatformApi = new PlatformApi();
  private loaded: boolean = false;
  private reqSeq: number = 0;

  private p(): Palette {
    return palette(this.isDark);
  }

  private currentBoard(): SheetInfo {
    if (this.boardIndex >= 0 && this.boardIndex < this.boards.length) {
      return this.boards[this.boardIndex];
    }
    return newSheet('', '');
  }

  private async loadBoards(): Promise<void> {
    this.hydrate();
    await this.refresh();
  }

  /** 进页面先把缓存铺满：命中就不出加载态，避免白屏/转圈闪一下 */
  private hydrate(): void {
    const boards = RankCache.anyBoards(this.platform);
    if (boards === null || boards.length === 0) {
      return;
    }
    this.boards = boards;
    this.boardIndex = 0;
    const songs = RankCache.anySongs(this.platform, boards[0].id);
    if (songs !== null) {
      this.songs = songs;
      this.loading = false;
    }
  }

  private async refresh(): Promise<void> {
    // 已经有内容（来自缓存）就静默刷新，别把列表清空重来
    const hadContent = this.songs.length > 0;
    if (!hadContent) {
      this.loading = true;
    }
    this.message = '';
    let boards: SheetInfo[] = [];
    try {
      // 已有缓存就不强制打网络（榜单一天才更新），没有才走一次网络
      boards = await this.api.ranks(this.platform, this.boards.length === 0);
    } catch (e) {
      boards = [];
    }
    if (boards.length === 0) {
      if (!hadContent) {
        this.loading = false;
        this.message = platformShort(this.platform) + ' 暂未提供公开榜单';
      }
      return;
    }
    // 后台刷新不打断用户当前选中的子榜
    const keep = this.currentBoard().id;
    let index = 0;
    if (keep.length > 0) {
      for (let i = 0; i < boards.length; i++) {
        if (boards[i].id === keep) {
          index = i;
          break;
        }
      }
    }
    this.boards = boards;
    this.boardIndex = index;
    await this.loadSongs(hadContent);
  }

  private async loadSongs(silent: boolean = false): Promise<void> {
    const seq = ++this.reqSeq;
    if (!silent) {
      this.loading = true;
    }
    this.message = '';
    try {
      const list = await this.api.sheetSongs(this.currentBoard());
      if (seq !== this.reqSeq) {
        return;
      }
      // 刷新失败时不要把已有内容清掉
      if (list.length > 0 || this.songs.length === 0) {
        this.songs = list;
      }
      if (list.length === 0 && this.songs.length === 0) {
        this.message = '这个榜单暂时拿不到歌曲';
      }
    } catch (e) {
      if (seq === this.reqSeq && this.songs.length === 0) {
        this.message = '加载失败，请检查网络后重试';
      }
    }
    if (seq === this.reqSeq) {
      this.loading = false;
    }
  }

  private pickBoard(index: number): void {
    if (index === this.boardIndex) {
      return;
    }
    this.boardIndex = index;
    // 切子榜同样先看缓存，命中就直接换内容，不转圈
    const cached = RankCache.anySongs(this.platform, this.currentBoard().id);
    if (cached !== null) {
      this.songs = cached;
      this.loading = false;
      this.message = '';
    }
    this.loadSongs(cached !== null);
  }

  /** 「播放全部」：开始播放并展开播放页 */
  private playAll(index: number): void {
    if (this.songs.length === 0) {
      App.get().toast('这个榜单还没有歌曲');
      return;
    }
    App.get().playAndOpen(this.songs.slice(), index);
  }

  /**
   * 点单曲：留在榜单里播，不跳播放页。
   * 这样底部迷你条会立刻显示这首并可直接控播，方便接着往下挑；
   * 以前和「播放全部」共用 playAndOpen，点一行就被顶到播放页，列表上下文全丢了。
   */
  private playFrom(index: number): void {
    if (this.songs.length === 0) {
      return;
    }
    App.get().play(this.songs.slice(), index);
  }

  private openMenu(song: SongInfo): void {
    this.menuSong = song;
    this.menuShow = true;
  }

  @Builder
  boardChips() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(this.boards, (board: SheetInfo, index: number) => {
          Chip({
            text: board.name,
            active: this.boardIndex === index,
            onTap: () => {
              this.pickBoard(index);
            }
          })
        }, (board: SheetInfo) => board.id + board.platform)
      }
      .padding({ top: 6, bottom: 6 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
  }

  @Builder
  menuSheet() {
    SongMenu({
      song: this.menuSong,
      kind: 'rank',
      playlistId: '',
      onDone: () => {
        this.menuShow = false;
      }
    })
  }

  /** 首屏还没有歌曲时的骨架，比一片空白 + 转圈更像「马上就来」 */
  @Builder
  rankSkeleton() {
    Column() {
      ForEach(SKEL_W, (w: string, index: number) => {
        Row({ space: 12 }) {
          Column()
            .width(18)
            .height(10)
            .borderRadius(5)
            .backgroundColor(this.p().cardAlt)
          Column({ space: 7 }) {
            Column()
              .width(w)
              .height(11)
              .borderRadius(6)
              .backgroundColor(this.p().cardAlt)
            Column()
              .width('34%')
              .height(9)
              .borderRadius(5)
              .backgroundColor(this.p().cardAlt)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .height(46)
        .alignItems(VerticalAlign.Center)
      }, (w: string, index: number) => w + index.toString())
    }
    .width('100%')
    .padding({ top: 8 })
    .opacity(0.7)
  }


  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Top }) {
        // 内容层：全屏滚动，顶部留出标题的高度，滚动时从标题后穿过
        Column() {
          if (this.loading && this.songs.length === 0) {
            // 子榜已知就先铺出来，只有歌曲还在路上，别让整页空着
            if (this.boards.length > 0) {
              this.boardChips()
            }
            this.rankSkeleton()
          } else if (this.songs.length === 0) {
            EmptyView({
              icon: $r('sys.symbol.music_note_list'),
              title: '这里还没有歌',
              hint: this.message,
              action: '重新加载',
              onAction: () => {
                this.loadBoards();
              }
            })
          } else {
            List() {
              ListItem() {
                Row() {
                  Row({ space: 6 }) {
                    SymbolGlyph($r('sys.symbol.play_fill')).fontSize(14).fontColor(['#FF191713'])
                    Text('播放全部').fontSize(FONT.callout).fontWeight(FontWeight.Medium).fontColor('#FF191713')
                  }
                  .height(38)
                  .padding({ left: 18, right: 20 })
                  .borderRadius(RADIUS.pill)
                  .backgroundColor(this.p().primary)
                  .onClick(() => {
                    this.playAll(0);
                  })
                }
                .width('100%')
                .justifyContent(FlexAlign.Start)
              }
              .margin({ top: 4, bottom: 4 })

              // 子榜 tab：随内容滚动（参考软件同款）
              ListItem() {
                this.boardChips()
              }

              ForEach(this.songs, (song: SongInfo, index: number) => {
                ListItem() {
                  SongRow({
                    song: song,
                    index: index + 1,
                    showIndex: true,
                    showQuality: false,
                    rankTop: 3,
                    active: App.get().isCurrent(song),
                    playing: App.get().player.isPlaying(),
                    onTap: () => {
                      this.playFrom(index);
                    },
                    onMore: () => {
                      this.openMenu(song);
                    }
                  })
                }
                .padding({ left: 4, right: 4 })
              }, (song: SongInfo, index: number) => song.source + song.id + this.boardIndex.toString() + index.toString())

              ListItem() {
                Row().height(PAGE_BOTTOM + 20 + MINI_BAR_SPACE)
              }
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
        }
        .width('100%')
        .height('100%')
        .padding({ left: PAGE_PAD, right: PAGE_PAD, top: this.topSafe + 50 })
        .backgroundColor('#00000000')
        .bindSheet($$this.menuShow, this.menuSheet(), {
          height: SheetSize.FIT_CONTENT,
          dragBar: false,
          backgroundColor: glassCardBase(this.isDark)
        })

        // 悬浮标题：带渐变遮罩，点击穿透
        ImmersiveBar({
          title: platformShort(this.platform) + '排行榜',
          subtitle: this.loading ? '' : (this.boards.length > 0 ? this.currentBoard().name : ''),
          showSearch: true,
          onBack: () => {
            App.get().back();
          },
          // v2.54：在榜单里听到一首想找的歌，不必退回首页；空关键词进搜索页自己输
          onSearch: () => {
            App.get().openSearch('');
          }
        })
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    // 队列浮层压在本页之上时，第一次返回只收队列，第二次才退回上一级
    .onBackPressed(() => App.get().consumeBackIfQueueOpen())
    .onReady((ctx: NavDestinationContext) => {
      const param = ctx.pathInfo.param as RankParam;
      if (param !== undefined && param !== null && !this.loaded) {
        this.loaded = true;
        this.platform = param.platform;
        // 先同步铺缓存（首页其实已经拉过榜单列表了），再后台补最新数据
        this.hydrate();
        this.refresh();
      }
    })
  }
}

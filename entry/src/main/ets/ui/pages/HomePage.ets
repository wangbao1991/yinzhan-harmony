import {
  palette, Palette, RADIUS, FONT, PAGE_PAD, FLOAT_SPACE,
  glassCardBase, glassSurface, glassEdgeWidth, glassEdgeColor, glassShadow
} from '../../common/Constants';
import { NavParam, newSheet } from '../../common/Models';
import { dateText, nowText, withAlpha } from '../../common/Utils';
import { App } from '../../core/App';
import { TabBarHider } from '../../core/UiBar';
import { Library } from '../../core/Library';
import { WyFavSync } from '../../core/WyFavSync';
import { WyRecommendHub } from '../../core/WyRecommendHub';
import { WyRecommendSection } from '../WyRecommendSection';

/**
 * 我的音乐四宫格的一张卡。
 *
 * 必须是独立的 @Component：以前写成 `@Builder entryCard(item)` 按值传参，
 * ArkUI 的 @Builder 按值传参只在首次调用时生效，参数里的 `hint` 变了不会更新，
 * 于是「本地音乐 1 首」这种数字进来一次就再也不变（哪怕父组件 @State 已经更新）。
 * 改成 @Prop 单向同步后，父组件刷新就会带着卡片一起变。
 */
@Component
struct LibraryEntryCard {
  @Prop title: string = '';
  @Prop hint: string = '';
  @Prop icon: Resource = $r('sys.symbol.heart');
  @Prop tint: string = '#FF6F6960';
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;
  onOpen: () => void = (): void => {
  };


  build() {
    Column({ space: 10 }) {
      Stack() {
        SymbolGlyph(this.icon)
          .fontSize(20)
          .fontColor([this.tint])
      }
      .width(40)
      .height(40)
      .borderRadius(13)
      .backgroundColor(withAlpha(this.tint, 0.12))

      Column({ space: 3 }) {
        Text(this.title)
          .fontSize(FONT.callout)
          .fontWeight(FontWeight.Medium)
          .fontColor(palette(this.isDark).text)
        Text(this.hint)
          .fontSize(FONT.micro)
          .fontColor(palette(this.isDark).text3)
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .borderRadius(RADIUS.lg)
        .backgroundColor(glassCardBase(this.isDark))
    .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
    .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
    .shadow(glassShadow(this.isDark, this.lightLevel))
    .onClick(() => {
      this.onOpen();
    })
  }
}
/**
 * 首页：时钟问候 + 搜索 + 我的音乐四宫格 + 网易云实时推荐。
 *
 * 原来的「排行榜」「推荐歌单」整块移走了：那两块本来就一点开就跳「发现」，
 * 摆两份只是把首页撑得很长。现在发现页是独立一级入口，首页专心做「我的东西」，
 * 音乐库那一栏也就没存在必要了——四宫格搬到这儿；自建歌单板块已下线。
 *
 * v2.72 入口收口（按用户口径）：四宫格第四格由「下载管理」换成「歌单收藏」，
 * 四个方块图标统一排列；下载改到顶栏右侧小图标，导入歌单改到「歌单收藏」
 * 二级页标题栏。首页不再有通栏歌单收藏条与导入方卡，也不再挂导入面板。
 */
@Component
export struct HomePage {
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;
  @StorageProp('topSafe') topSafe: number = 24;
  @StorageProp('sourceCount') @Watch('onSourceChange') sourceCount: number = 0;
  /** 改首选、改名、启用/禁用都不改数量，用版本号兜住首页显示的当前音源名 */
  @StorageProp('sourceVersion') @Watch('onSourceChange') sourceVersion: number = 0;
  /**
   * 音源仓库是否初始化完成（App.startSources 结束后置 true）。
   * 冷启动首帧 sourceCount 仍是 @StorageProp 的默认值 0，若只按「数量为 0」
   * 判断，会先画出「还没有导入音源」横幅，等异步 init 写入真实数量再消失 ——
   * 即用户看到的「一闪而过」。用它门控：未就绪时不显示横幅。
   */
  @StorageProp('sourcesReady') @Watch('onSourceChange') sourcesReady: boolean = false;
  @State sourceName: string = '';
  /** v2.71：首页下拉刷新（刷新网易云实时推荐板块） */
  @State recRefreshing: boolean = false;
  /** v2.71：网易云登录 / 退出后，首页推荐板块要立刻重拉或清空 */
  @StorageProp('wyLoginVersion') @Watch('onWyLoginChange') wyLoginVersion: number = 0;

  // —— 我的音乐（原音乐库那套数据）——
  @State favoriteCount: number = 0;
  @State historyCount: number = 0;
  @State localCount: number = 0;
  @State downloadCount: number = 0;
  /** 收藏的「歌单」数量，和歌曲收藏分开统计；libraryVersion 一变就跟着刷新 */
  @State favoriteSheetCount: number = 0;
  @StorageProp('libraryVersion') @Watch('onLibraryChange') libraryVersion: number = 0;
  /** 本地导入 / 下载完成都不走 Library，各自一个版本号，否则两个数字永远停在首帧 */
  @StorageProp('localVersion') @Watch('onDataChange') localVersion: number = 0;
  @StorageProp('downloadVersion') @Watch('onDataChange') downloadVersion: number = 0;
  /** v2.65：应用回前台时对账一次，保证首页「歌单收藏 N 个」与账号一致 */
  @StorageProp('foregroundAt') @Watch('onAppForeground') foregroundAt: number = 0;
  private library: Library = Library.get();
  private listener: () => void = (): void => {
  };
  onOpenSearch: (keyword: string) => void = (keyword: string): void => {
  };

  aboutToAppear(): void {
    this.sourceName = App.get().sources.getActive()?.name ?? '未导入音源';
    this.listener = (): void => {
      this.refresh();
    };
    this.library.onChange(this.listener);
    this.refresh();
    // v2.71：进首页拉一次本人账号推荐；未登录时 hub 只清空并广播，不发请求
    WyRecommendHub.get().refresh().catch(() => {
    });
  }

  aboutToDisappear(): void {
    // 离开页面时恢复底栏
    TabBarHider.get().reset();
    this.library.offChange(this.listener);
  }

  onSourceChange(): void {
    this.sourceName = App.get().sources.getActive()?.name ?? '未导入音源';
  }

  onLibraryChange(): void {
    this.refresh();
  }

  /** 本地音乐 / 下载管理自己的版本号（二级页里导入、下载完成时推进） */
  onDataChange(): void {
    this.refresh();
  }

  /**
   * v2.65：回前台主动对账一次。用户在 APP 里收藏/取消收藏后切回来，
   * 首页计数和收藏页列表就能跟上；同步引擎自身带失败保护与并发锁，
   * 这里不用关心登录态、网络或在途状态。
   */
  private onAppForeground(): void {
    WyFavSync.get().reconcile().catch(() => {
    });
    // v2.71：切回前台重拉推荐，用户刚在平台 APP 里换过歌单/收藏也能立刻看到变化
    WyRecommendHub.get().refresh().catch(() => {
    });
  }

  /** v2.71：登录 / 退出后立刻重拉（未登录由 hub 清空），不留给下一次回前台 */
  private onWyLoginChange(): void {
    WyRecommendHub.get().refresh().catch(() => {
    });
  }

  /** v2.71：下拉刷新，与发现页同款 Refresh 双向绑定；等真实请求跑完再收起 */
  private async pullRefresh(): Promise<void> {
    this.recRefreshing = true;
    await WyRecommendHub.get().refresh();
    this.recRefreshing = false;
  }

  private refresh(): void {
    this.favoriteCount = this.library.getFavorites().length;
    this.historyCount = this.library.getHistory().length;
    this.localCount = App.get().local.count();
    this.downloadCount = App.get().downloads.doneCount();
    // 歌单收藏与歌曲收藏是两份数据，但共用 libraryVersion 广播
    this.favoriteSheetCount = this.library.getFavoriteSheets().length;
  }

  private p(): Palette {
    return palette(this.isDark);
  }


  private openEntry(key: string): void {
    if (key === 'favorites') {
      App.get().openSheet(this.library.toSheet('favorites', '', '我喜欢的音乐'));
      return;
    }
    if (key === 'history') {
      App.get().openSheet(this.library.toSheet('history', '', '最近播放'));
      return;
    }
    if (key === 'local') {
      const sheet = newSheet('local', 'local');
      sheet.name = '本地音乐';
      sheet.subtitle = this.localCount.toString() + ' 首 · 来自设备文件';
      sheet.trackCount = this.localCount;
      App.get().openSheet(sheet);
      return;
    }
    if (key === 'favoriteSheets') {
      App.get().openFavoriteSheets();
      return;
    }
    App.get().push('downloads', new NavParam());
  }

  @Builder
  topHeader() {
    Row() {
      Column({ space: 4 }) {
        Text(nowText())
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.p().text)
        Text(dateText() + ' · ' + this.sourceName)
          .fontSize(FONT.caption)
          .fontColor(this.p().text3)
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // v2.72：下载管理方块从四宫格移到顶栏右侧（图 2 标记处）。
      // 入口只此一处，复用 openEntry 的 downloads 分支，不新增路由、不重复 push。
      Stack() {
        SymbolGlyph($r('sys.symbol.arrow_down_circle'))
          .fontSize(20)
          .fontColor([this.p().primary])
      }
      .width(40)
      .height(40)
      .borderRadius(13)
      .backgroundColor(glassCardBase(this.isDark))
      .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
      .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
      .shadow(glassShadow(this.isDark, this.lightLevel))
      .onClick(() => {
        this.openEntry('downloads');
      })
    }
    .width('100%')
    .padding({ top: 8, bottom: 4 })
  }

  /**
   * 顶部搜索条：整行可点，点开进入搜索二级页。
   *
   * 这里刻意保持「整行一个 onClick」—— 曾试过在同一行右端再挂一个子按钮的
   * onClick，父子响应归属会出现歧义（点子按钮可能连带触发整行）。
   * 首页只负责把人送进搜索页，关键词由搜索页自己接。
   */
  @Builder
  searchBar() {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(17).fontColor([this.p().text3])
      Text('搜索音乐、歌手、专辑')
        .fontSize(FONT.body)
        .fontColor(this.p().text3)
        .layoutWeight(1)
      Text('搜索')
        .fontSize(FONT.callout)
        .fontColor(this.p().primary)
        .fontWeight(FontWeight.Medium)
    }
    .width('100%')
    .height(46)
    .padding({ left: 16, right: 16 })
    .borderRadius(RADIUS.pill)
    .backgroundColor(glassCardBase(this.isDark))
    .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
    .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
    .shadow(glassShadow(this.isDark, this.lightLevel))
    .shadow({ radius: 12, color: this.p().shadow, offsetY: 4 })
    .onClick(() => {
      this.onOpenSearch('');
    })
  }

  @Builder
  sourceBanner() {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.link')).fontSize(18).fontColor([this.p().primary])
      }
      .width(38)
      .height(38)
      .borderRadius(12)
      .backgroundColor(this.p().primarySoft)

      Column({ space: 3 }) {
        Text('还没有导入音源')
          .fontSize(FONT.callout)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.p().text)
        Text('导入一个洛雪音源脚本才能播放歌曲')
          .fontSize(FONT.micro)
          .fontColor(this.p().text3)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('去导入')
        .fontSize(FONT.caption)
        .fontColor('#FF191713')
        .backgroundColor(this.p().primary)
        .borderRadius(RADIUS.pill)
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .onClick(() => {
          App.get().push('sources', new NavParam());
        })
    }
    .width('100%')
    .padding(14)
    .borderRadius(RADIUS.lg)
    .backgroundColor(glassCardBase(this.isDark))
        .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
        .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
        .shadow(glassShadow(this.isDark, this.lightLevel))
  }

  @Builder
  quickGrid() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        LibraryEntryCard({
          title: '我喜欢',
          hint: this.favoriteCount.toString() + ' 首',
          // v2.79 图标风格统一：本格与「歌单收藏」原为实心填充爱心，深色面积约为
          // 线框描边图标的 2 倍，与「最近播放时钟 / 本地音乐文件夹」摆在一起显深；
          // 按用户口径改为空心线框爱心，四格全为描边风格，tint 不变、视觉深度归一。
          icon: $r('sys.symbol.heart'),
          tint: '#FF6F6960',
          onOpen: (): void => {
            this.openEntry('favorites');
          }
        })
        LibraryEntryCard({
          title: '最近播放',
          hint: this.historyCount.toString() + ' 首',
          icon: $r('sys.symbol.clock'),
          tint: '#FF6F6960',
          onOpen: (): void => {
            this.openEntry('history');
          }
        })
      }
      .width('100%')
      Row({ space: 12 }) {
        LibraryEntryCard({
          title: '本地音乐',
          hint: this.localCount.toString() + ' 首',
          icon: $r('sys.symbol.folder'),
          tint: '#FF6F6960',
          onOpen: (): void => {
            this.openEntry('local');
          }
        })
        LibraryEntryCard({
          // v2.72：第四格由「下载管理」换成「歌单收藏」，与其余三格同为方块图标；
          // 下载入口改到顶栏右侧，导入入口改到收藏页标题栏，首页入口统一成四个方块。
          // v2.78 配色统一：本格原先单独用品牌琥珀色（实心爱心 + 淡黄底），
          // 与「我喜欢 / 最近播放 / 本地音乐」三格灰褐不一致；按用户口径改为同一灰褐
          // #FF6F6960，四格图标与底色方块全部归一。Constants.ets 的品牌主色不动。
          // v2.79 图标风格统一：实心填充爱心比线框描边图标显深（深色面积约 2 倍），
          // 改为空心线框爱心，与时钟 / 文件夹同为描边风格，四格视觉深度一致。
          title: '歌单收藏',
          hint: this.favoriteSheetCount.toString() + ' 个歌单',
          icon: $r('sys.symbol.heart'),
          tint: '#FF6F6960',
          onOpen: (): void => {
            this.openEntry('favoriteSheets');
          }
        })
      }
      .width('100%')
    }
    .width('100%')
  }


  build() {
    Refresh({ refreshing: $$this.recRefreshing }) {
    Scroll() {
      Column({ space: 20 }) {
        // 顶部问候是页面身份、音源提示是状态引导，两者固定在最上方。
        this.topHeader()
        // 必须等 sourcesReady：音源仓库是异步 init 的，首帧 sourceCount 还是默认 0，
        // 未就绪就判断会把「还没有导入音源」横幅画出来又立刻消失（一闪而过）。
        if (this.sourcesReady && this.sourceCount === 0) {
          this.sourceBanner()
        }

        // v2.29：首页固定三块，不再做模块显隐 / 排序。
        // v2.72：四宫格第四格已是「歌单收藏」，不再有通栏条与导入方卡。
        this.searchBar()
        this.quickGrid()

        // v2.72：每日推荐横向轨铺满 30 首 + 为你推荐歌单横向轨，实时拉取。
        // 未登录时组件自己显示登录引导，不占假数据；刷新由 hub 统一广播。
        WyRecommendSection()

        Row()
          .height(FLOAT_SPACE)
      }
      .width('100%')
      .padding({ left: PAGE_PAD, right: PAGE_PAD, top: this.topSafe, bottom: 20 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .onScrollFrameBegin((offset: number, state: ScrollState) => {
      TabBarHider.get().feed(offset);
      return { offsetRemain: offset };
    })
    .backgroundColor('#00000000')
    }
    .width('100%')
    .height('100%')
    .onRefreshing(() => {
      this.pullRefresh();
    })
  }
}

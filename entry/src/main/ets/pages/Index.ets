import { common } from '@kit.AbilityKit';
import { curves, window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { palette, Palette, RADIUS, FONT, lightSense, LightSense } from '../common/Constants';
import { SearchParam } from '../common/Models';
import { withAlpha } from '../common/Utils';
import { App } from '../core/App';
import { ImportIntent } from '../core/ImportIntent';
import { TabBarHider } from '../core/UiBar';
import { SourceHost } from '../ui/SourceHost';
import { NavPager } from '../ui/NavPager';
import { BottomDock } from '../ui/BottomDock';
import { QueueOverlay } from '../ui/QueueOverlay';
import { HomePage } from '../ui/pages/HomePage';
import { DiscoverPage } from '../ui/pages/DiscoverPage';
import { DiscoverSectionPage } from '../ui/pages/DiscoverSectionPage';
import { RankBoardPage } from '../ui/pages/RankBoardPage';
import { SearchPage } from '../ui/pages/SearchPage';
import { SettingsPage } from '../ui/pages/SettingsPage';
import { SheetDetailPage } from '../ui/pages/SheetDetailPage';
import { ArtistPage } from '../ui/pages/ArtistPage';
import { DownloadsPage } from '../ui/pages/DownloadsPage';
import { FavoriteSheetsPage } from '../ui/pages/FavoriteSheetsPage';

import { SourcesPage } from '../ui/pages/SourcesPage';
import { PlaySettingsPage } from '../ui/pages/PlaySettingsPage';
import { AppearanceSettingsPage } from '../ui/pages/AppearanceSettingsPage';
import { DataSettingsPage } from '../ui/pages/DataSettingsPage';
import { WyAccountPage } from '../ui/pages/WyAccountPage';
import { PlayerPage } from '../ui/pages/PlayerPage';

/**
 * 翻页动画时长（ms）。
 * Swiper.duration、底栏指示器的补间、兜底定时器全部读这一个值——
 * 长度和曲线一致，指示器才会和页面「同时起步、同时收住」。
 */
const PAGE_ANIM_MS: number = 300;

/**
 * 一镜到底共享元素 id（官方 geometryTransition）。
 *
 * 底部迷你播放条与全屏播放页各自绑定它，二者互斥地在组件树上出现/消失。
 * 只在转场闭包内赋值、动画结束由 onFinish 清空：官方明确建议在 onFinish 中
 * 把 id 置空，防止页面快速连续点击、状态变量变化等非预期场景误触发共享元素转场，
 * 下一次触发前再设回所需值。
 */
const PLAYER_SHARED_ID: string = 'yinzhan_player_shared';

/**
 * 应用外壳。
 *
 * 结构：
 *  - 最底层 SourceHost：1 像素的隐藏 WebView，跑洛雪音源脚本
 *  - Navigation：三个一级页（首页 / 发现 / 设置）+ 二级页面（歌单/歌手/搜索/下载/音源）
 *  - 悬浮层：迷你播放条 + 胶囊标签栏
 *  - 全屏播放页：与迷你播放条同组件树的 geometryTransition 一镜到底展开
 */
@Entry
@Component
struct Index {
  @StorageProp('isDark') @Watch('syncSystemBar') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;
  @StorageProp('hasSong') hasSong: boolean = false;
  /**
   * 二级页栈深。0 = 在一级页，> 0 = 压着歌单/榜单/下载等页面。
   * 悬浮层据此决定是否显示底部标签栏（迷你条始终显示）。
   */
  @StorageProp('navDepth') navDepth: number = 0;
  @State ready: boolean = false;
  @State tab: number = 0;
  // 一级页横滑跟手、页签高亮/指示条/流光、MiniBar 展开收起全部由官方 HdsTabs
  // 原生接管（见 HdsNav.ets）；旧的 swipePos/tabsWidth/tabsController/barProgress/
  // barStyle 等自绘联动状态一并删除，不再需要。
  @State @Watch('syncSystemBar') playerShow: boolean = false;
  /** geometryTransition 绑定 id：只在转场闭包内赋值，onFinish 清空（官方建议） */
  @State playerGeomId: string = '';
  @State queueShow: boolean = false;
  @State topSafe: number = 24;
  @State bottomSafe: number = 16;
  @State toastText: string = '';
  @State toastVisible: boolean = false;
  @State stack: NavPathStack = new NavPathStack();
  /** 外部「用其它应用打开」的信号：热启动时 Ability 递增它触发这里 */
  @StorageProp('importIntentVersion') @Watch('onImportIntent') importVersion: number = 0;
  private toastTimer: number = -1;
  private appReady: boolean = false;
  private importBusy: boolean = false;

  aboutToAppear(): void {
    this.measureSafeArea();
    App.get().nav = this.stack;
    App.get().syncNavDepth();
    // 系统返回手势退二级页时不走 App.back()，这里把栈深补回来，
    // 否则回到一级页后标签栏会一直不出现。
    this.stack.setInterception({
      willShow: (from: NavDestinationContext | NavBar, to: NavDestinationContext | NavBar,
        operation: NavigationOperation, isAnimated: boolean): void => {
        App.get().syncNavDepth();
      },
      didShow: (from: NavDestinationContext | NavBar, to: NavDestinationContext | NavBar,
        operation: NavigationOperation, isAnimated: boolean): void => {
        App.get().syncNavDepth();
      }
    });
    App.get().openPlayerFn = (): void => {
      // 进播放页前先收掉队列浮层：不然退出播放页会看到一层旧浮层还压在上面
      this.queueShow = false;
      this.setPlayerShow(true);
    };
    App.get().openQueueFn = (): void => {
      this.queueShow = true;
    };
    // 二级页拿不到 Index 的 @State，这里注册一个「只收浮层」的关闭器。
    // v2.34：根 Stack 上有两类全局浮层 —— 全屏播放页 playerShow（v2.5 起是
    // 同组件树的普通 if 分支，不是独立模态、没有自己的返回回调）与队列浮层
    // queueShow。系统返回手势在二级页时只交给 NavDestination.onBackPressed、
    // 走不到 @Entry.onBackPress，所以这里必须按「播放页 → 队列」统一收，
    // 返回 true 拦住 Navigation pop；两类都没开才返回 false 放行退页。
    // 一级页 / 各二级页 / 顶栏箭头都走这一个判断，避免「一级页能收播放页、
    // 二级页却直接退页」的不一致（从详情页进播放页按返回会误退页）。
    App.get().closeQueueFn = (): boolean => {
      if (this.playerShow) {
        this.setPlayerShow(false);
        return true;
      }
      if (this.queueShow) {
        this.queueShow = false;
        return true;
      }
      return false;
    };
    App.get().toastFn = (message: string): void => {
      this.showToast(message);
    };
    // 列表里点歌失败（不跳播放页）时也要有反馈，不能静默停在那一行
    App.get().player.setErrorReporter((message: string): void => {
      this.showToast(message);
    });
    // 官方 HdsTabs 风格下，页签同步由 Tabs 原生管理；MiniBar 形态默认 EXPAND。
    AppStorage.setOrCreate('tabBarProgress', 0);
    // v2.29：移除默认启动页配置，冷启动固定落首页（tab 0）。
    this.switchTab(0);
    const context = getContext(this) as common.UIAbilityContext;
    App.get().init(context).then(() => {
      this.ready = true;
      this.appReady = true;
      this.measureSafeArea();
      App.get().player.restore().catch(() => {
        console.error('[Index] 恢复播放队列失败');
      });
      // 冷启动：Ability 在界面建好之前就收到了文件 URI，这里补消费一次
      this.consumeImportIntent();
    }).catch(() => {
      this.ready = true;
      this.appReady = true;
      this.consumeImportIntent();
    });
  }

  /** 热启动：应用已在后台，文件管理器再次拉起 */
  onImportIntent(): void {
    if (this.appReady) {
      this.consumeImportIntent();
    }
  }

  /**
   * 把外部传进来的 .js 读出来导入。必须等 App.init() 完成：
   * importCode 会立刻把脚本挂进 WebView 沙箱，沙箱没就绪会失败。
   */
  private async consumeImportIntent(): Promise<void> {
    if (this.importBusy) {
      return;
    }
    const uris = ImportIntent.take();
    if (uris.length === 0) {
      return;
    }
    this.importBusy = true;
    let ok = 0;
    let lastError = '';
    for (const uri of uris) {
      try {
        const code = ImportIntent.readText(uri);
        if (!ImportIntent.looksLikeScript(code)) {
          lastError = '不是文本脚本（可能选了其它类型的文件）';
          continue;
        }
        await App.get().sources.importCode(code, ImportIntent.fileName(uri));
        ok++;
      } catch (e) {
        lastError = e instanceof Error ? e.message : String(e);
      }
    }
    this.importBusy = false;
    if (ok > 0) {
      App.get().toast('已从文件导入 ' + ok.toString() + ' 个音源');
      App.get().openSources();
    } else {
      App.get().toast('导入失败：' + (lastError.length > 0 ? lastError : '读不到文件内容'));
    }
    // 导入期间又来了一批（多选/连续打开）
    if (ImportIntent.pending() > 0) {
      this.consumeImportIntent();
    }
  }

  /**
   * 一级页的返回键：先收浮层，再退二级页，最后才退出应用。
   * 二级页上的返回手势不走这里（被 Navigation 吃掉），
   * 所以另外在每个 NavDestination 挂了 onBackPressed，两边共用同一个浮层判断。
   */
  /**
   * 打开/收起全屏播放页 —— 官方 geometryTransition 一镜到底的标准入口。
   *
   * 三个要件，缺一不可：
   *  1. 状态切换必须放进 animateTo 动画闭包内，系统才会接管两形态的几何插值；
   *  2. 闭包里先把绑定 id 设回来（上一次转场结束时被 onFinish 清空了）；
   *  3. onFinish 再清空 id，避免快速连点 / 无关状态刷新误触发共享元素转场。
   *
   * 曲线用官方「图标（搜索框、头像）展开」案例的插值弹簧
   * curves.interpolatingSpring(0, 1, 342, 38)：系统按物理弹簧自定时长，
   * 收尾没有硬停，也不写死 duration —— 这是「丝滑」的关键。
   *
   * 原来直接赋值 playerShow 会走 bindContentCover 的系统默认滑入，
   * 迷你播放条不参与任何形变，自然谈不上「一镜到底」。
   */
  private setPlayerShow(show: boolean): void {
    if (this.playerShow === show) {
      return;
    }
    animateTo({
      curve: curves.interpolatingSpring(0, 1, 342, 38),
      onFinish: (): void => {
        this.playerGeomId = '';
        AppStorage.setOrCreate('playerGeomId', '');
      }
    }, (): void => {
      this.playerGeomId = PLAYER_SHARED_ID;
      // miniBarBuilder 在 HdsNav 组件内部，跨组件拿不到 Index 的 @State，
      // 用 AppStorage 把同一 id 传给它的根 Stack，形成小形态↔全屏页一镜到底。
      AppStorage.setOrCreate('playerGeomId', PLAYER_SHARED_ID);
      this.playerShow = show;
    });
  }

  onBackPress(): boolean {
    // v2.34：收浮层统一交给 consumeBackIfQueueOpen()（播放页 + 队列两类）。
    // 原来这里单独判 playerShow，与二级页 onBackPressed 只判队列不一致，删掉；
    // 现在一级页与所有二级页走同一个判断，行为一致。
    if (App.get().consumeBackIfQueueOpen()) {
      return true;
    }
    if (this.navDepth > 0) {
      App.get().back();
      return true;
    }
    return false;
  }

  /**
   * 播放页恒为深色，浅色系统下状态栏图标是深色的，压在暗背景上就看不见了。
   * 打开播放页时把系统栏图标切成浅色，收起时按主题恢复。
   */
  syncSystemBar(): void {
    const context = getContext(this) as common.UIAbilityContext;
    window.getLastWindow(context).then((win: window.Window) => {
      const dark = this.playerShow || this.isDark;
      const icon = dark ? '#FFF5F6F9' : '#FF111116';
      const properties: window.SystemBarProperties = {
        statusBarColor: '#00000000',
        statusBarContentColor: icon,
        navigationBarColor: '#00000000',
        navigationBarContentColor: icon
      };
      win.setWindowSystemBarProperties(properties).catch((err: BusinessError) => {
        console.warn('[Index] 设置系统栏样式失败 ' + JSON.stringify(err));
      });
    }).catch((err: BusinessError) => {
      console.warn('[Index] 获取窗口失败 ' + JSON.stringify(err));
    });
  }

  private measureSafeArea(): void {
    const context = getContext(this) as common.UIAbilityContext;
    window.getLastWindow(context).then((win: window.Window) => {
      const system = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      this.topSafe = px2vp(system.topRect.height) + 6;
      const indicator = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const bottom = px2vp(indicator.bottomRect.height);
      this.bottomSafe = bottom > 0 ? bottom : 16;
      // 各页面顶部栏读的是 AppStorage 里的 topSafe；以前只更新了这里的 @State，
      // 页面拿到的仍是默认 24，全屏布局下标题和返回键被顶进状态栏（系统手势区）里，
      // 点上去没反应，只能用系统返回手势。
      AppStorage.setOrCreate('topSafe', this.topSafe);
      AppStorage.setOrCreate('bottomSafe', this.bottomSafe);
    }).catch((err: BusinessError) => {
      console.warn('[Index] 读取安全区失败 ' + JSON.stringify(err));
    });
  }

  private switchTab(index: number): void {
    // 底栏页签 → NavPager（Swiper）翻页，两边都读 this.tab，闭环。
    this.tab = index;
    // 切页恢复底栏形态，新页面从完整布局开始。
    TabBarHider.get().reset();
    AppStorage.setOrCreate('tabIndex', index);
  }

  private showToast(message: string): void {
    if (message.length === 0) {
      return;
    }
    if (this.toastTimer !== -1) {
      clearTimeout(this.toastTimer);
    }
    this.toastText = message;
    this.toastVisible = true;
    this.toastTimer = setTimeout(() => {
      this.toastVisible = false;
      this.toastTimer = -1;
    }, 2000);
  }

  private p(): Palette {
    return palette(this.isDark);
  }

  private ls(): LightSense {
    return lightSense(this.lightLevel);
  }

  /** 单个光斑 */
  @Builder
  glow(size: number, color: string, alpha: number, x: string, y: string) {
    Column()
      .width(size)
      .height(size)
      .borderRadius(size / 2)
      .radialGradient({
        center: [size / 2, size / 2],
        radius: size / 2,
        colors: [[withAlpha(color, alpha), 0], [withAlpha(color, 0), 1]]
      })
      .blur(size / 9)
      .position({ x: x, y: y })
      .hitTestBehavior(HitTestMode.None)
  }

  /**
   * 背景氛围层：三团色光铺在页面底下。
   *
   * 这是「沉浸」能成立的前提——底部栏是毛玻璃，如果底下是纯色，
   * 模糊纯色还是纯色，肉眼完全看不出通透。有了这层，
   * 内容滚过去时玻璃后面才有颜色和形状在动。
   */
  @Builder
  ambience() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.p().bg)

      if (this.lightLevel > 0) {
        // 深色底上同样的透明度会显得过曝，按主题减一档
        this.glow(400, this.p().primary, (this.isDark ? 0.22 : 0.40) * this.ls().ambience, '-26%', '-18%')
        this.glow(320, this.p().accent, (this.isDark ? 0.14 : 0.28) * this.ls().ambience, '64%', '10%')
        this.glow(360, this.p().primary, (this.isDark ? 0.16 : 0.24) * this.ls().ambience, '2%', '68%')
      }
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  pageMap(name: string, param: Object) {
    if (name === 'sheet') {
      SheetDetailPage()
    } else if (name === 'rankboard') {
      RankBoardPage()
    } else if (name === 'discoverSection') {
      // 发现板块「更多 ›」的通用全量页：分页 / 分类 / 快照三类由参数决定
      DiscoverSectionPage()
    } else if (name === 'search') {
      // 搜索是二级页：底栏第二个位置让给「发现」，搜索从首页搜索框 / 歌手页推上来。
      // App.openSearch() 一直都在（歌手页也一直在调），但这里从来没注册过，
      // 所以那些入口点下去是没反应的——这次一并接上。
      NavDestination() {
        SearchPage({
          initialKeyword: this.searchParam(param).keyword,
          initialType: this.searchParam(param).type
        })
      }
      .hideTitleBar(true)
      .onBackPressed(() => App.get().consumeBackIfQueueOpen())
    } else if (name === 'artist') {
      ArtistPage()
    } else if (name === 'downloads') {
      DownloadsPage()
    } else if (name === 'sources') {
      SourcesPage()
    } else if (name === 'playSettings') {
      // 播放设置：组件内部自带 NavDestination 与返回拦截（弹层 → 退页）
      PlaySettingsPage()
    } else if (name === 'appearanceSettings') {
      // 外观（主题 + 歌词）：同样是自带 NavDestination 的二级页
      AppearanceSettingsPage()
    } else if (name === 'dataSettings') {
      // 数据管理（备份 / 恢复）：同样是自带 NavDestination 的二级页
      DataSettingsPage()
    } else if (name === 'wyAccount') {
      // 网易云账号（二维码 / Cookie 登录 + 本人账号推荐）：自带 NavDestination 的二级页
      WyAccountPage()
    } else if (name === 'favoriteSheets') {
      // 歌单收藏：和 sheet / artist 一样，组件内部自带 NavDestination 与返回拦截
      FavoriteSheetsPage()
    }
  }

  /** push 参数兜底：名字对不上时不至于把搜索页卡在空引用上 */
  private searchParam(param: Object): SearchParam {
    if (param instanceof SearchParam) {
      return param as SearchParam;
    }
    return new SearchParam('');
  }

  // ── 一级页内容 builder：作为 @BuilderParam 注入 HdsNav ──
  @Builder
  homeContent() {
    HomePage({
      onOpenSearch: (keyword: string): void => {
        App.get().openSearch(keyword);
      }
    })
      .width('100%')
      .height('100%')
  }

  @Builder
  discoverContent() {
    DiscoverPage()
      .width('100%')
      .height('100%')
  }

  @Builder
  settingsContent() {
    SettingsPage()
      .width('100%')
      .height('100%')
  }

  /**
   * 一级页翻页容器（只翻页）。
   * 底栏（页签胶囊 + 迷你播放条）已拆到根 Stack 的 BottomDock，见下方 build()。
   */
  @Builder
  tabContent() {
    NavPager({
      selected: this.tab,
      onChangeTab: (index: number): void => {
        this.tab = index;
        AppStorage.setOrCreate('tabIndex', index);
        TabBarHider.get().reset();
      },
      content0: (): void => {
        this.homeContent();
      },
      content1: (): void => {
        this.discoverContent();
      },
      content2: (): void => {
        this.settingsContent();
      }
    })
      .width('100%')
      .height('100%')
  }

  @Builder
  playerCover() {
    PlayerPage({
      onClose: (): void => {
        this.setPlayerShow(false);
      }
    })
  }


  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 音源沙箱：铺满整屏但完全透明、不接收事件，保证 ArkWeb 不被降频
      SourceHost()

      Column() {
        if (!this.ready) {
          Column({ space: 14 }) {
            LoadingProgress().width(34).height(34).color(this.p().primary)
            Text('音栈')
              .fontSize(FONT.body)
              .fontColor(this.p().text3)
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else {
          Navigation(this.stack) {
            Stack({ alignContent: Alignment.Bottom }) {
              // 氛围光在最底层，页面滚动容器已改透明，能透出来
              this.ambience()

              Column() {
                this.tabContent()
              }
              .width('100%')
              .height('100%')
              // 顶部安全区由各页面自己按 AppStorage['topSafe'] 留白，
              // 这里再加一层会叠成双份（标题被推得过低，返回键反而贴近状态栏）。
              //
              // 迷你条 + 标签栏以前放在这里：Navigation 的根内容在压入二级页后
              // 整块被 NavDestination 盖住，所以榜单/歌单/歌手这些页面上
              // 完全看不到「当前播放」那一栏。现在提到外层 Stack（见下方）。
            }
            .width('100%')
            .height('100%')
          }
          .hideTitleBar(true)
          .hideToolBar(true)
          .mode(NavigationMode.Stack)
          .navDestination(this.pageMap)
          .backgroundColor('#00000000')
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.p().bg)

      /*
       * 全局悬浮底栏（在 Navigation 之外，所以二级页也看得见）：
       *   页签胶囊：只在一级页显示（BottomDock 内部按 navDepth 判断）
       *   迷你播放条：只要队列里有歌就显示，进歌单/榜单也还在
       * 两者左右并排、一方展开另一方收起，宽度由 BottomDock 自己算，不会挤出屏幕。
       * 启动那一下不画，避免盖在「音栈」加载页上。
       */
      if (this.ready) {
        BottomDock({
          onChangeTab: (index: number): void => {
            this.switchTab(index);
          }
        })
          .width('100%')
          .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
      }

      // 队列面板：自绘浮层，不用 bindSheet。
      // 历史上同节点挂 bindContentCover 与 bindSheet 会互相顶掉（列表按钮能弹、
      // 点歌曲却进不去播放页），所以一直是普通节点叠层。播放页现已改走同组件树
      // 共享元素转场，队列仍保持自绘：顺带保住玻璃透视与遮罩的一致性。
      if (this.queueShow) {
        // 跟播放页同一个外壳：贴底 70% 的不透明 Column 已经去掉，
        // 换成悬浮玻璃卡片（四边留白 + 圆角 30），两个入口长得一模一样
        QueueOverlay({
          onClose: (): void => {
            this.queueShow = false;
          }
        })
          .transition(TransitionEffect.OPACITY.animation({ duration: 160 }))
      }

      // 轻提示
      if (this.toastVisible) {
        Column() {
          Text(this.toastText)
            .fontSize(FONT.callout)
            .fontColor('#FFFFFFFF')
            .backgroundColor('#E6323340')
            .borderRadius(RADIUS.pill)
            .padding({ left: 18, right: 18, top: 10, bottom: 10 })
            .maxLines(3)
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .padding({ left: 40, right: 40 })
        .margin({ bottom: this.bottomSafe + 160 })
        .transition(TransitionEffect.OPACITY.animation({ duration: 180 }))
        .hitTestBehavior(HitTestMode.None)
      }

      // ── 一镜到底「大形态」：全屏播放页 ──
      // 与上面的迷你播放条同处一棵组件树、互斥出现，绑定同一个 id。
      // 不再用 bindContentCover：那是独立模态窗口，系统默认滑入动画会与
      // 共享元素动画叠加（官方明确要求「配置了共享元素转场的页面须关闭
      // 默认转场，否则效果异常」），而且跨模态拿不到组件内隐式共享元素的
      // 几何连续性。改成同树 if/else 后就是官方示例 1 的标准范式。
      if (this.playerShow) {
        Stack() {
          this.playerCover()
        }
        .width('100%')
        .height('100%')
        .geometryTransition(this.playerGeomId)
        .transition(TransitionEffect.OPACITY.animation({ duration: 180 }))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.p().bg)
  }
}

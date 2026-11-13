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
import { TabBar, MiniPlayer } from '../ui/Shell';
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
  /** 横滑连续位置（当前页 + 拖动比例），1:1 跟手，去重后才广播 */
  private swipeAt: number = 0;
  /** 手势空闲归位定时器：松手后收不到回调时兜底，把指示器落到整数页 */
  private swipeIdle: number = -1;
  /**
   * 是否处于手指拖动阶段。
   * 拖动中指示器必须零延迟（底栏动画时长读这个值），
   * 松手后的归位才允许补间——否则每帧目标都被缓动追一遍，
   * 观感就是「先蓄力、再冲刺」。
   */
  private dragging: boolean = false;
  /** 上一次落位的时刻：用来区分「新手势」和「松手后的残余回调」 */
  private settleTs: number = 0;
  /** Swiper 主轴长度（vp），用于把 currentOffset 换成页比例 */
  @State pageW: number = 0;
  /** 底栏收起进度 / 是否在播：收起后播放条要沉进底栏那一行 */
  @StorageProp('tabBarProgress') barProgress: number = 0;
  @StorageProp('hasSong') hasSong: boolean = false;
  /**
   * 二级页栈深。0 = 在一级页，> 0 = 压着歌单/榜单/下载等页面。
   * 悬浮层据此决定是否显示底部标签栏（迷你条始终显示）。
   */
  @StorageProp('navDepth') navDepth: number = 0;
  @State ready: boolean = false;
  @State tab: number = 0;
  /** 一级页容器：横滑切页 / 点底栏切页都走它 */
  private swiper: SwiperController = new SwiperController();
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
    // 指示器位置先落一个整数，避免首帧读到空值停在 0 之外
    AppStorage.setOrCreate('tabSwipe', 0);
    AppStorage.setOrCreate('tabDur', 0);
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
      }
    }, (): void => {
      this.playerGeomId = PLAYER_SHARED_ID;
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

  /**
   * 广播跟手位置：夹在 0~页数-1，变化太小就不写，避免每帧都触发重绘。
   *
   * 另外单帧最多走 0.5 格。正常拖动一帧走不到半格（那要 10000vp/s 以上的速度），
   * 所以这个限幅只在「基准页切换、currentOffset 重算」那种整格跳变时生效，
   * 把瞬移抹成快速追赶，不会出现指示器一下子蹦到最右边。
   */
  private pushSwipe(at: number): void {
    const v = Math.max(0, Math.min(2, at));
    // 一帧内跳超过 0.3 格（≈ 900vp/s 以上），只可能是基准页切换、
    // 索引和偏移量换了参照系，不是手指真正走出来的位移。
    // 这种值整帧丢掉等下一帧，绝不能「跟一半」——
    // 跟一半就是往回退半格，用户看到的就是那下回弹。
    if (Math.abs(v - this.swipeAt) > 0.3) {
      return;
    }
    if (Math.abs(v - this.swipeAt) < 0.002) {
      return;
    }
    this.swipeAt = v;
    AppStorage.setOrCreate('tabSwipe', v);
  }

  /** 进入拖动阶段：底栏据此把指示器动画时长切到 0，做到 1:1 跟手 */
  private beginDrag(): void {
    if (!this.dragging) {
      this.dragging = true;
      // 拖动阶段：补间时长 0，指示器位置直接等于手指位置
      AppStorage.setOrCreate('tabDur', 0);
    }
  }

  /**
   * 落到整数页。
   * 先退出拖动阶段再改位置，这样这一次位移走的是补间（平滑归位），
   * 而不是零时长的硬跳。
   */
  private settleSwipe(index: number): void {
    this.settleTs = Date.now();
    if (this.swipeIdle !== -1) {
      clearTimeout(this.swipeIdle);
      this.swipeIdle = -1;
    }
    if (this.dragging) {
      this.dragging = false;
    }
    // 先声明这一段要走多长，再改位置：底栏的 @Watch 触发时读到的就是新时长
    AppStorage.setOrCreate('tabDur', PAGE_ANIM_MS);
    const target = Math.max(0, Math.min(2, index));
    if (Math.abs(this.swipeAt - target) > 0.001) {
      this.swipeAt = target;
      AppStorage.setOrCreate('tabSwipe', target);
    }
  }

  /**
   * 接管：Swiper 决定翻页、动画开始的那一刻调用。
   *
   * 这是「停顿感」的正解。以前等 onAnimationEnd 才把指示器挪到目标页，
   * 于是页面在动的那 300ms 里指示器完全静止，等页面停住它才补过去——
   * 用户看到的就是「滑到一半停一下、然后突然窜过去」。
   * 现在动画一开始就拿到 targetIndex，立刻把位置改成目标值，
   * 底栏用 300ms + Friction（与 Swiper 完全同长同曲线）补间过去，两头同时收。
   */
  private beginRelease(target: number): void {
    this.settleTs = Date.now();
    if (this.swipeIdle !== -1) {
      clearTimeout(this.swipeIdle);
      this.swipeIdle = -1;
    }
    if (this.dragging) {
      this.dragging = false;
    }
    AppStorage.setOrCreate('tabDur', PAGE_ANIM_MS);
    // 这里无条件写：拖动最后一帧的残余误差（<0.001 格）也要拉正，
    // 否则指示器会永远差一丝，凑不到格子正中
    const to = Math.max(0, Math.min(2, target));
    this.swipeAt = to;
    AppStorage.setOrCreate('tabSwipe', to);
  }

  /**
   * 兜底归位。
   *
   * onGestureSwipe 只在手指拖动时回调，松手之后那段回弹/整页动画完全收不到，
   * 所以拖动一停就挂一个定时器。但**必须等到 Swiper 自己的动画跑完**：
   * 它的 duration 是 300ms，如果 120ms 就把指示器拉回旧页，
   * 动画结束时 onChange 再把页面翻过去，指示器就会「回弹一下、再蹦过去」。
   * 340ms 留出动画时间再加一点余量，正常情况已经在 onAnimationEnd 里落位，
   * 这里只是兜底。
   */
  private armSwipeIdle(): void {
    if (this.swipeIdle !== -1) {
      clearTimeout(this.swipeIdle);
    }
    this.swipeIdle = setTimeout((): void => {
      this.swipeIdle = -1;
      // 手指又按下去时不抢位置
      if (!this.dragging) {
        this.settleSwipe(this.tab);
      }
    }, PAGE_ANIM_MS + 220);
  }

  /**
   * 与 Shell 里的 TabBar 同一套口径。
   * 两种情况不收起：没有在播的歌（没有可合并的播放条）、
   * 压着二级页（这时底栏本来就不渲染，收起了没人接手）。
   */
  /**
   * 外壳播放条自己的分段进度。
   *
   * 底栏那边的收起是分层的（文字→图标→底板→圆按钮+胶囊），
   * 这条悬浮播放条也要错开：它在 0.06 就开始退，0.54 退干净，
   * 比底栏里的胶囊（0.46 才起步）早一点点，中间是低透明度的交叉，
   * 不是「上面一条突然消失、下面一条突然出现」。
   */
  private easeOutStage(v: number): number {
    return 1 - Math.pow(1 - v, 3);
  }

  private barStage(from: number, to: number): number {
    const c = this.shellCollapse();
    if (to <= from) {
      return c >= to ? 1 : 0;
    }
    return Math.max(0, Math.min(1, (c - from) / (to - from)));
  }

  private shellCollapse(): number {
    if (!this.hasSong || this.navDepth !== 0) {
      return 0;
    }
    return Math.max(0, Math.min(1, this.barProgress));
  }

  private switchTab(index: number): void {
    // 点底栏切页：交给 Swiper 走同一段过场，页面和指示器才会同步移动。
    // 首次进来 index 就等于当前 tab，这时只复位收起进度，不要去驱动容器。
    if (index !== this.tab) {
      this.tab = index;
      AppStorage.setOrCreate('tabSwipe', index);
      this.swiper.changeIndex(index);
    }
    // 切 Tab 恢复底栏，新页面从完整布局开始
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

  @Builder
  tabContent() {
    // 三个一级页常驻，只切换可见性。
    // 以前用 if / else if 按 tab 分支，切换时整棵子树销毁重建，
    // 首页每次回来都要重新拉榜单和最近播放（「正在加载今日推荐」那一下），
    // 搜索页的历史/结果和列表滚动位置也会丢。
    //
    // 第二个位次是「发现」：榜单和推荐歌单本来就是每天要看的东西，
    // 埋在首页「更多」里点两层才到，改成一级入口；搜索是一次性动作，
    // 让位给发现，改为从首页搜索框 push 二级页（见 pageMap 的 'search'）。
    // 「音乐库」已并入首页（四宫格 + 自建歌单），不再单独占位。
    //
    // 容器从 Stack 换成 Swiper：左右横滑就能切页，手势和页面位移都由它接管。
    // 三页仍然全程常驻（Swiper 不做懒加载），所以「切回来不重新拉数据」这条没有丢。
    Swiper(this.swiper) {
      HomePage({
        onOpenSearch: (keyword: string): void => {
          App.get().openSearch(keyword);
        }
      })
        .width('100%')
        .height('100%')

      DiscoverPage()
        .width('100%')
        .height('100%')

      SettingsPage()
        .width('100%')
        .height('100%')
    }
    .width('100%')
    .height('100%')
    .index(this.tab)
    .loop(false)
    .indicator(false)
    .duration(PAGE_ANIM_MS)
    .curve(Curve.Friction)
    // 跟手：用 onGestureSwipe 而不是 onContentDidScroll。
    // 这个回调的第一个参数明确是「手势开始前的页索引」（稳定基准），
    // extraInfo.currentOffset 是当前页相对主轴起点的偏移，单位 vp、左滑为负，
    // 两个都是能直接算的值，不依赖那个实测对不上的 position 比例。
    .onAreaChange((oldArea: Area, newArea: Area) => {
      const w = Number(newArea.width);
      if (w > 0 && Math.abs(w - this.pageW) > 0.5) {
        this.pageW = w;
      }
    })
    // 手指是否还在屏幕上，以触摸事件为准。
    // onGestureSwipe 在松手后的收尾阶段仍可能回调，那时给出的偏移量
    // 已经不是手指位置了；照着它走，指示器就会被拽回去（回弹）。
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) {
        this.beginDrag();
        if (this.swipeIdle !== -1) {
          clearTimeout(this.swipeIdle);
          this.swipeIdle = -1;
        }
      } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        // 松手：位置交给 onAnimationEnd 落位，这里只挂兜底
        this.armSwipeIdle();
      }
    })
    .onGestureSwipe((index: number, extra: SwiperAnimationEvent) => {
      // 手指不在屏幕上时的残余回调一律忽略。
      // 兜底：万一个别机型上 onTouch 没送到，距上次落位足够久也当成新手势，
      // 否则会退化成「完全不跟手」。
      if (!this.dragging) {
        if (Date.now() - this.settleTs > 400) {
          this.beginDrag();
        } else {
          return;
        }
      }
      const w = this.pageW > 0 ? this.pageW : 360;
      // 左滑 offset 为负 → at 变大：手指走到哪，指示器就跟到哪
      this.pushSwipe(index - extra.currentOffset / w);
    })
    // 动画「开始」就接管：拿到 targetIndex，指示器立刻朝目标补间。
    // 等 onAnimationEnd 才动，中间那 300ms 就是可见的停顿。
    .onAnimationStart((index: number, targetIndex: number, extraInfo: SwiperAnimationEvent) => {
      this.beginRelease(targetIndex);
    })
    // 结束只做兜底校正（正常情况下位置已经对齐，这里不会再动）。
    // 动画也可能被新的拖动打断，那时位置归手指管，不能拉回整数——
    // 拉了就是一次可见的回弹。
    .onAnimationEnd((index: number) => {
      if (!this.dragging) {
        this.settleSwipe(index);
      }
    })
    .onChange((index: number) => {
      this.tab = index;
      AppStorage.setOrCreate('tabIndex', index);
      // 拖动还没结束时不能硬写位置——那会把跟手值拉回整数，
      // 手指还按着、指示器却跳一下，就是「回弹一下再跳过去」的来源。
      // 拖动中交给 onAnimationEnd 落位；点按切页（非拖动）才直接跟随。
      if (!this.dragging) {
        this.swipeAt = index;
        AppStorage.setOrCreate('tabSwipe', index);
      }
      // 新页面从完整布局开始：上一个页面滚动收起的标签栏要复位
      TabBarHider.get().reset();
    })
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
       * 全局悬浮层（在 Navigation 之外，所以二级页也看得见）：
       *   - 迷你播放条：只要队列里有歌就显示，点了播放立刻出现，不再依赖当前在哪个页面
       *   - 胶囊标签栏：只在一级页显示（navDepth === 0），二级页留出整屏给内容
       * 启动那一下不画，避免盖在「音栈」加载页上。
       */
      if (this.ready) {
        Column() {
          // ── 一镜到底「小形态」：只在播放页未展开时留在树上 ──
          // geometryTransition 要求绑定同一 id 的两个组件一消失、一创建；
          // 让迷你条常驻、只在上面盖一层全屏页是无效的（两个节点同时在场）。
          // 大形态在根 Stack 末尾，二者绑定同一个 PLAYER_SHARED_ID。
          if (!this.playerShow) {
            // 收起时这条播放条「沉」进底栏那一行（底栏里的紧凑版接手）。
            // 淡出到 0.46 就退干净，之后才把高度收掉——
            // 以前两个窗口几乎同步，收到的过程中它还是半可见的，
            // 看着就是一条被压扁、内容被裁掉一半的播放条。
            Column() {
              MiniPlayer()
                .opacity(1 - this.barStage(0.06, 0.46))
                .translate({ y: -10 * this.easeOutStage(this.barStage(0.06, 0.46)) })
                // 左右各收 4：播放条比标签栏窄一圈，两层一宽一窄才分得出
                // 「小的浮在上面、大的托在下面」。同宽并排会看成一条被切成两截。
                .margin({ left: 4, right: 4 })
            }
            .width('100%')
            .height(58 * (1 - this.barStage(0.44, 0.62)))
            .clip(true)
            // 高度收到 0 后它还留在树上（为了保住淡出这段过渡），里面仍是一整套
            // 58 高的可点控件。clip 只裁绘制、不裁命中，所以要在外层整棵子树禁用，
            // 否则收起之后底栏上方会留一条看不见的「点哪都进播放页」的热区。
            .enabled(this.barStage(0.44, 0.62) < 0.5)
            .hitTestBehavior(this.barStage(0.44, 0.62) < 0.5 ? HitTestMode.Default : HitTestMode.None)
            // 官方共享元素：与全屏播放页绑定同一 id，系统自动把两者的
            // 宽高、位置插值到相同值并切换透明度，实现一镜到底。
            // OPACITY 转场保活，避免 if 分支切换时节点被立即销毁导致动画闪断；
            // clip(true) 让容器形变时走边缘裁剪，内部内容不被拉伸。
            .geometryTransition(this.playerGeomId)
            .transition(TransitionEffect.OPACITY.animation({ duration: 180 }))
          }
          if (this.navDepth === 0) {
            // 外层固定 62 高、底对齐：标签栏收起时只是自己变矮下沉，
            // 迷你播放条的位置完全不动。不包这一层的话整列会一起缩，
            // 播放条跟着上下晃 16vp，看着像整块在抖。
            Column() {
              TabBar({
                current: this.tab,
                total: 3,
                onSelect: (index: number): void => {
                  this.switchTab(index);
                }
              })
            }
            .width('100%')
            .height(62)
            .justifyContent(FlexAlign.End)
            // 8 → 12：两件玻璃之间留出能被看见的缝。
            // 缝太小的话投影落不下来，两层会贴成一块厚板，"浮"就没了。
            .margin({ top: 12 })
          }
        }
        .width('100%')
        .padding({ left: 14, right: 14, bottom: this.bottomSafe })
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

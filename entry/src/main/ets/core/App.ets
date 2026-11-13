import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { SongInfo, SheetInfo, SheetParam, ArtistInfo, ArtistParam, SearchParam, RankParam, NavParam } from '../common/Models';
import { DiscoverMore, DiscoverMoreParam } from '../common/Discover';
import { Store } from './Store';
import { Library } from './Library';
import { PlayStats } from './PlayStats';
import { SourceRepo } from './SourceRepo';
import { LxRunner } from './LxRunner';
import { Player } from './Player';
import { Downloader } from './Downloader';
import { LocalRepo } from './LocalRepo';
import { Settings } from './Settings';
import { WyAccount } from './WyAccount';
import { WyFavSync } from './WyFavSync';
import { FavSyncHub } from './FavSyncHub';
import { PrefKeys } from '../common/Constants';

/** 启动后等多久再跑自动自检：避让首屏绘制与冷启动的取链请求 */
const AUTO_CHECK_DELAY: number = 8000;
/** 两次自动自检的最小间隔：频繁重启不该反复向后端取链 */
const AUTO_CHECK_INTERVAL: number = 30 * 60 * 1000;

/**
 * 应用级门面：初始化顺序、导航栈、跨页面动作（播放/打开页面/轻提示）。
 * 页面只依赖这个类，避免互相 import 组件。
 */
export class App {
  private static instance: App = new App();
  static get(): App {
    return App.instance;
  }

  nav: NavPathStack | null = null;
  openPlayerFn: (() => void) | null = null;
  openQueueFn: (() => void) | null = null;
  /**
   * 只收起「全局浮层」、不碰页面栈。由 Index 注册（名字沿用历史，最初只收队列，
   * v2.34 起统一收全屏播放页 + 队列两类根级浮层）。
   * 二级页的 onBackPressed 拿它把第一次返回手势拦下来。
   * 返回 true = 本次返回已被浮层消费；false = 浮层都没开，可以继续退页。
   */
  closeQueueFn: (() => boolean) | null = null;
  toastFn: ((message: string) => void) | null = null;
  /** 音源沙箱（由界面里的隐藏 ArkWeb 页面驱动） */
  runner: LxRunner = new LxRunner();

  private context: common.UIAbilityContext | null = null;
  private started: boolean = false;
  private sourcesStarted: boolean = false;
  /** 自动自检每次冷启动最多触发一次 */
  private autoCheckStarted: boolean = false;

  library: Library = Library.get();
  sources: SourceRepo = SourceRepo.get();
  player: Player = Player.get();
  downloads: Downloader = Downloader.get();
  local: LocalRepo = LocalRepo.get();
  settings: Settings = Settings.get();

  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.started) {
      return;
    }
    this.started = true;
    this.context = context;
    await Store.get().init(context);
    // 网易云本人账号：Store 就绪后读回凭证并广播登录态，账号页 / 设置页首帧即用
    WyAccount.get().init();
    // v2.65：歌单收藏 ↔ 账号同步。先注册本地收藏变更钩子，再读回待同步队列；
    // 钩子必须在 Library.init 之前挂好也没关系（只在用户操作时才触发）。
    Library.wyFavHook = (sheet: SheetInfo, added: boolean): void => {
      WyFavSync.get().onLocalChange(sheet, added);
    };
    WyFavSync.get().init();
    // v1.0：歌单收藏 ↔ 网易云账号同步总门面（QQ / 酷狗账号引擎已连根删除）。
    FavSyncHub.get().init();
    // 外观：先落到 AppStorage，页面首帧就能用上
    AppStorage.setOrCreate('lightSense', this.settings.lightSense());
    // 音质偏好是全局值：播放取链、下载、设置页与播放页显示共用它
    AppStorage.setOrCreate('qualityPref', this.settings.quality());
    // 后台补到封面后 CoverRepo 递增它，封面组件订阅刷新
    AppStorage.setOrCreate('coverVersion', 0);
    this.library.init();
    // 统计层要在 Library 之后（要把旧播放历史并入已知歌曲）、Player 之前
    PlayStats.get().init();
    this.player.init(context);
    this.downloads.init(context);
    await this.local.init(context);
    this.player.setLocalPathProvider((song: SongInfo): string => {
      if (song.source === 'local') {
        return this.local.pathOf(song.id);
      }
      const task = this.downloads.find(song.id);
      if (task !== null && task.path.length > 0) {
        return App.playablePath(task.path);
      }
      return '';
    });
    // 沙箱可能比界面先就绪（比如冷启动很快），这里补一次
    if (this.runner.isReady()) {
      this.startSources().catch(() => {
        console.error('[App] 音源初始化失败');
      });
    }
  }

  /**
   * 音源沙箱就绪后才调用：把已启用的洛雪脚本一次性挂进 WebView。
   * 只做一次，之后切源/取链都不再重新执行脚本。
   */
  async startSources(): Promise<void> {
    if (this.sourcesStarted) {
      return;
    }
    const context = this.context;
    if (context === null) {
      return;
    }
    this.sourcesStarted = true;
    this.sources.attachRunner(this.runner);
    try {
      await this.sources.init(context);
      AppStorage.setOrCreate('sourcesReady', true);
      AppStorage.setOrCreate('sourceCount', this.sources.list().length);
      this.maybeAutoCheck();
    } catch (e) {
      // 失败允许下次重试
      this.sourcesStarted = false;
      throw new Error('音源初始化失败');
    }
  }

  /**
   * 启动自动自检（开关打开才跑）。
   *
   * 跑完整自检，和音源页里点「全部自检」是同一套结论 —— 只有一个模式，
   * 不会出现「这里通过、那里失败」。它在后台并发 3 个源跑，不阻塞播放；
   * 脚本级故障会短路，死源不会各耗三段时间。
   *
   * 两道闸：同一进程只跑一次；距上次不足 30 分钟跳过。自检是真实取链，
   * 连续重启应用不应该变成连续打后端。
   */
  private maybeAutoCheck(): void {
    if (this.autoCheckStarted || !this.settings.autoCheckSources()) {
      return;
    }
    this.autoCheckStarted = true;
    const last = Store.get().getNumber(PrefKeys.AUTO_CHECK_AT, 0);
    if (Date.now() - last < AUTO_CHECK_INTERVAL) {
      return;
    }
    setTimeout((): void => {
      Store.get().put(PrefKeys.AUTO_CHECK_AT, Date.now());
      this.sources.checkAll((): void => {
      }).then((): void => {
        // 结果只回写到音源卡片的状态上，不弹窗、不打断用户当前在做的事
        console.info('[App] 启动自检完成');
      }).catch((e: Error): void => {
        console.error('[App] 启动自检失败 ' + e.message);
      });
    }, AUTO_CHECK_DELAY);
  }

  /** 公共目录 URI 有时带 file:// 前缀，AVPlayer 的 fdSrc 需要真实路径 */
  static playablePath(path: string): string {
    if (path.startsWith('file://')) {
      const real = path.substring(7);
      try {
        if (fs.accessSync(real)) {
          return real;
        }
      } catch (e) {
        // 忽略
      }
      return path;
    }
    try {
      if (fs.accessSync(path)) {
        return path;
      }
    } catch (e) {
      return '';
    }
    return path;
  }

  /** 列表点播：只开始播放，不抢焦点（详情页「播放全部」用 playAndOpen） */
  play(list: SongInfo[], index: number): void {
    this.player.playQueue(list, index).catch(() => {
    });
  }

  /** 开始播放并直接打开播放页 */
  playAndOpen(list: SongInfo[], index: number): void {
    this.player.playQueue(list, index).catch(() => {
    });
    this.openPlayer();
  }

  playOne(song: SongInfo): void {
    this.play([song], 0);
  }

  openPlayer(): void {
    if (this.openPlayerFn !== null) {
      this.openPlayerFn();
    }
  }

  /** 直接弹出播放队列，不离开当前页面 */
  openQueue(): void {
    if (this.openQueueFn !== null) {
      this.openQueueFn();
    }
  }

  /**
   * 返回手势的统一入口。
   * 坑：Navigation 栈里有二级页时，系统返回手势会先被 NavPathStack 消费，
   * 根本走不到 @Entry 的 onBackPress —— 于是「二级页 + 根级浮层」按返回，
   * 浮层没被收起，页面却直接 pop 回一级页。现在每个 NavDestination 都挂
   * onBackPressed 调这里：先收浮层（true 拦住），浮层没了才放行退页（false）。
   * v2.34：根级浮层含「全屏播放页 + 队列」两类，统一在 closeQueueFn 里按
   * 优先级收，一级页 onBackPress 也走同一个判断，全站返回优先级一致。
   */
  consumeBackIfQueueOpen(): boolean {
    if (this.closeQueueFn !== null) {
      return this.closeQueueFn();
    }
    return false;
  }

  /**
   * v2.55：返回的单一优先级入口 —— 页内临时态 → 根级浮层。
   *
   * 页内临时态指「选择模式」这类一按返回就该收起来的本页状态（不涉及退页）。
   * 以前三个选择页各自在 onBackPressed / 顶栏箭头里写一份
   * `if (selectMode) { exitSelect(); return true; }`，新页面漏写就会
   * 选中一堆条目时按返回直接把页面退掉。现在顺序只在方法里定义一次：
   * 页面只负责说明「本页有什么临时态」，不再自己拼优先级。
   *
   * 返回 true = 本次返回已被消费（调用方不要再 pop）；false = 可以继续退页。
   */
  consumeBack(local: (() => boolean) | null): boolean {
    if (local !== null && local()) {
      return true;
    }
    return this.consumeBackIfQueueOpen();
  }

  toast(message: string): void {
    if (this.toastFn !== null) {
      this.toastFn(message);
    }
  }

  /**
   * 当前播放的是不是这一首。
   * 光比 id 不够：各平台 id 是各自编号，QQ 与网易云很容易撞号，
   * 会让另一个平台的同 id 歌在列表里被标成「正在播放」。
   */
  isCurrent(song: SongInfo): boolean {
    const cur: SongInfo = this.player.getSong();
    return cur.id === song.id && cur.source === song.source;
  }

  push(name: string, param: Object): void {
    if (this.nav !== null) {
      this.nav.pushPathByName(name, param);
      this.syncNavDepth();
    }
  }

  /**
   * 二级页栈深写进 AppStorage。
   * 外壳的悬浮层靠它决定是否显示底部标签栏：一级页显示，二级页让位给内容。
   * push / pop / 系统返回手势三条路径都会调到。
   */
  syncNavDepth(): void {
    AppStorage.setOrCreate('navDepth', this.nav === null ? 0 : this.nav.size());
  }

  openSheet(sheet: SheetInfo): void {
    this.push('sheet', new SheetParam(sheet));
  }

  openArtist(artist: ArtistInfo): void {
    this.push('artist', new ArtistParam(artist));
  }

  openSearch(keyword: string): void {
    this.push('search', new SearchParam(keyword));
  }

  /** 首页排行榜平台卡 → 平台榜单页（子榜 tab + 歌曲列表，参考软件同款） */
  openRankBoard(platform: string): void {
    this.push('rankboard', new RankParam(platform));
  }

  /**
   * 发现板块「更多 ›」统一入口：榜单类复用既有 rankboard 页，
   * 其余（歌单广场 / banner / 新歌 / 歌手）进通用板块全量页。
   * 页面只描述「看哪个板块的全部」，不认识平台接口。
   */
  openDiscoverSection(more: DiscoverMore): void {
    if (more.rank) {
      this.openRankBoard(more.platform);
      return;
    }
    this.push('discoverSection', new DiscoverMoreParam(more));
  }

  /** 外部导入完成 / 设置页「管理」共用：跳到音源管理 */
  openSources(): void {
    this.push('sources', new NavParam());
  }

  /** 首页「歌单收藏」入口：集中展示收藏的歌单 / 榜单 / 专辑 */
  openFavoriteSheets(): void {
    this.push('favoriteSheets', new NavParam());
  }


  /**
   * 顶栏返回箭头的统一入口。
   * v2.55：与系统返回共用 consumeBack 的同一套优先级（页内临时态 → 浮层 → 退页），
   * 页面把自己的临时态处理器作为 local 传进来，不再各写一遍「先判选择模式」。
   */
  back(local: (() => boolean) | null = null): void {
    // 顶栏返回箭头也走「先收浮层」：和手势返回保持同一套优先级，
    // 否则点箭头时队列还开着，人已经退回上一级了。
    if (this.consumeBack(local)) {
      return;
    }
    // size() 只算 push 进来的页面，不含 Navigation 根内容：
    // 二级页在栈里时 size() 就是 1，以前写成 > 1 导致返回键一直不响应
    // （只能靠系统返回手势，因为那条路径不走这里）。
    if (this.nav !== null && this.nav.size() > 0) {
      this.nav.pop();
      this.syncNavDepth();
    }
  }

  /** 播放「歌单/榜单/收藏」：统一入口，避免每个页面各写一遍 */
  playSheet(sheet: SheetInfo, songs: SongInfo[], index: number): void {
    if (songs.length === 0) {
      this.toast('这个列表还没有歌曲');
      return;
    }
    this.play(songs, index);
  }

  hasDownload(song: SongInfo): boolean {
    return this.downloads.has(song.id) || this.local.pathOf(song.id).length > 0;
  }
}

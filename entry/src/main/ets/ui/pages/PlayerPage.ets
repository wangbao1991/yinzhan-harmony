import { display, window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import {
  palette, Palette, RADIUS, FONT, qualityOptions, qualityLabel, inkSignalText,
  glassCardBase, glassSurface, glassEdgeWidth, glassEdgeColor, glassShadow
} from '../../common/Constants';
import { SongInfo, LyricLine, emptySong, formatTime } from '../../common/Models';
import { platformName } from '../../common/Platform';
import { withAlpha, audioFormat, seededGradient, firstSinger, stableId } from '../../common/Utils';
import { App } from '../../core/App';
import { Player } from '../../core/Player';
import { FailDetail } from '../../core/Resolver';
import { Library } from '../../core/Library';
import { SourceRepo } from '../../core/SourceRepo';
import { lyricIndexAt } from '../../core/Lrc';
import { LyricRepo, LyricCandidate } from '../../core/LyricRepo';
import { CoverRepo } from '../../core/CoverRepo';
import { Backdrop } from '../../core/Backdrop';
import { Cover, IconTap } from '../Common';
import { QueueOverlay } from '../QueueOverlay';


/**
 * 全屏播放页。
 *
 * 两屏：封面屏 / 歌词屏。封面屏轻点任意位置（或右下角的歌词按钮）
 * 切到歌词屏，歌词屏点顶部迷你封面或右上角箭头切回来。
 *
 * 之前点封面没反应，是 PanGesture 直接挂在 onClick 同一节点上把点击吃掉了，
 * 现在改用 GestureGroup(Parallel) 显式并列 Tap + Pan，并额外给一个可见按钮兜底。
 */
@Component
export struct PlayerPage {
  @StorageProp('topSafe') topSafe: number = 26;
  /** 屏幕底部安全区（手势条高度），自绘的队列浮层要自己让开 */
  @StorageProp('bottomSafe') bottomSafe: number = 16;
  @StorageProp('lightSense') lightLevel: number = 3;
  @StorageProp('lyricSize') lyricSize: number = 1;
  @StorageProp('libraryVersion') @Watch('onLibraryChange') libraryVersion: number = 0;
  @StorageProp('coverVersion') @Watch('onCoverVersion') coverVersion: number = 0;
  /**
   * 背景用的封面地址。必须落在 @State 上：
   * 后台补封面是异步的，首次进页面 displayCover() 还是空的；CoverRepo 补完广播 coverVersion，
   * 但 @Builder 里直接调 displayCover() 不是响应式依赖，页面不会重画——背景就永远停在兜底色（一片黑）。
   */
  @State coverUrl: string = '';
  /**
   * 屏幕逻辑尺寸（vp）。背景图必须按**数值**给宽高：
   * 整屏 `Image` 用 `width('100%').height('100%')` 时，百分比一路往上继承，
   * 在播放页这层会塌成 0，图根本不绘制——这是「封面从来没当过背景」的真因。
   */
  @State bgW: number = 0;
  @State bgH: number = 0;
  /** 屏幕物理像素，给背景图裁切用 */
  @State bgPxW: number = 0;
  @State bgPxH: number = 0;
  /**
   * 已经落盘的背景图（`file://` 路径）。
   * 封面网络图直接铺整屏在真机上一直不显示，所以这里先把它下载、按屏幕裁好、存成本地 JPEG，
   * 背景只读本地文件：尺寸正好一屏、不用放大、不用联网。
   */
  @State bgUri: string = '';
  /** 防止快速切歌时旧图的异步结果盖掉新图 */
  private bgToken: number = 0;
  /**
   * 系统主题。播放页自身的 `p()` 恒为深色（整页沉浸），
   * 但弹出的面板（音质 / 歌词 / 失败）要跟其它页面一致，所以这里单独拿一份。
   */
  @StorageProp('isDark') isDark: boolean = false;
  /** 下载状态变了（入队 / 完成 / 被删）要跟着改底部按钮，否则下完了还写着「下载」 */
  @StorageProp('downloadVersion') @Watch('onDownloadChange') downloadVersion: number = 0;
  /** none / waiting / running / done —— 底部下载按钮如实反映，不再一律写「下载」 */
  @State downloadState: string = 'none';
  /** 下滑收起时跟手的位移 */
  @State dragY: number = 0;
  @State song: SongInfo = emptySong();
  @State playing: boolean = false;
  @State loading: boolean = false;
  @State progressMs: number = 0;
  @State duration: number = 0;
  @State dragging: number = -1;
  @State mode: number = 1;
  @State quality: string = '320k';
  /** 全局音质偏好：在设置页改档位时，播放页的候选档与勾选也跟着变 */
  @StorageProp('qualityPref') @Watch('onQualityPref') qualityPref: string = '320k';
  @State actualQuality: string = '320k';
  @State lineIndex: number = -1;
  @State lyricLoading: boolean = false;
  @State lines: LyricLine[] = [];
  @State lyricSource: string = '';
  /**
   * 进播放页默认落在歌词屏——对齐参考软件：
   * 点迷你条进来看到的就是滚动歌词，想看封面再点顶部胶囊切回去。
   */
  @State showLyric: boolean = true;
  /** 用户手动滚歌词后暂停自动跟随，右下角出现「回到当前」 */
  @State followPaused: boolean = false;
  @State favorite: boolean = false;
  @State sourceFrom: string = '';
  /** v2.54：来源类型（normal / local / substitute / manual / switch），驱动来源行的标记显示 */
  @State sourceKind: string = 'normal';
  @State errorText: string = '';
  @State panel: number = 0;
  /** 失败面板（panel === 7）：逐条列出这次问了谁、为什么没成 */
  @State failDetails: FailDetail[] = [];
  @State failCount: number = 0;
  @State altCount: number = 0;
  /** 手动搜索歌词（panel === 6） */
  @State lyricKeyword: string = '';
  @State lyricCandidates: LyricCandidate[] = [];
  @State lyricSearching: boolean = false;
  @State lyricSearchHint: string = '';
  onClose: () => void = (): void => {
  };
  private player: Player = App.get().player;
  private scroller: Scroller = new Scroller();
  private listener: () => void = (): void => {
  };
  /** 程序化滚动标记，用来区分「自动跟」和「手动拖」 */
  private autoScroll: boolean = false;
  /** 本次触摸已经变成下滑手势，抬手时不要再当成点击切歌词 */
  private dragged: boolean = false;
  private followTimer: number = -1;
  private lyricRetried: boolean = false;

  /** 背景/主视觉用的封面：优先取后台补到的那张 */
  onQualityPref(): void {
    this.quality = this.qualityPref;
  }

  /** 音质选项：基础 5 档常驻 + 音源 inited 声明的扩展档 + 当前已选档 */
  private qualityOptionList(): string[] {
    const declared: string[] = SourceRepo.get().getQualities('');
    declared.push(this.quality);
    return qualityOptions(declared);
  }

  private displayCover(): string {
    const filled = CoverRepo.get().lookup(CoverRepo.keyOf(this.song));
    return filled.length > 0 ? filled : this.song.cover;
  }

  /** 把封面地址同步到 @State，封面补到之后背景才会真的重画 */
  private refreshCoverUrl(): void {
    const next = this.displayCover();
    if (next !== this.coverUrl) {
      this.coverUrl = next;
    }
  }

  onCoverVersion(): void {
    this.refreshCoverUrl();
    this.refreshBg();
  }

  /**
   * 量一次屏幕，给背景容器一个确定的数值尺寸。
   *
   * 两条路都试：`display` 是同步的，但个别机型/版本上不可用（拿到 0）；
   * `window.getWindowProperties().windowRect` 是外壳 `Index` 已经在用的路子，稳。
   * 只要拿到值，背景层就有一个数值锚点，不再依赖百分比推导。
   */
  private measureScreen(): void {
    try {
      const d = display.getDefaultDisplaySync();
      if (d.width > 0 && d.height > 0) {
        this.bgPxW = d.width;
        this.bgPxH = d.height;
        this.bgW = px2vp(d.width);
        this.bgH = px2vp(d.height);
      }
    } catch (e) {
      console.warn('[bg] display 取屏幕尺寸失败');
    }
    try {
      window.getLastWindow(getContext(this) as common.UIAbilityContext).then((win: window.Window) => {
        const rect = win.getWindowProperties().windowRect;
        if (rect.width > 0 && rect.height > 0) {
          this.bgPxW = rect.width;
          this.bgPxH = rect.height;
          this.bgW = px2vp(rect.width);
          this.bgH = px2vp(rect.height);
          this.refreshBg();
        }
      }).catch(() => {
        console.warn('[bg] window 取屏幕尺寸失败');
      });
    } catch (e) {
      console.warn('[bg] window 调用异常');
    }
  }

  /**
   * 生成/取用本地背景图。封面地址变了、尺寸拿到了，都要跑一遍。
   * 命中缓存同步返回，首帧就能显示；未命中则异步落盘，好了再刷一次界面。
   */
  private refreshBg(): void {
    const w = this.bgPxW > 0 ? this.bgPxW : Math.round(vp2px(this.bgW > 0 ? this.bgW : 376));
    const h = this.bgPxH > 0 ? this.bgPxH : Math.round(vp2px(this.bgH > 0 ? this.bgH : 809));
    // key 带 `b2`：背景图算法换过（加了模糊），旧缓存必须失效，否则还读老图
    const key = stableId(CoverRepo.keyOf(this.song) + '_' + w.toString() + 'x' + h.toString() + '_b2');
    const hit = Backdrop.get().cached(key);
    if (hit.length > 0) {
      this.bgUri = hit;
      return;
    }
    if (this.coverUrl.length === 0 || w <= 0 || h <= 0) {
      return;
    }
    const token = ++this.bgToken;
    Backdrop.get().build(key, this.coverUrl, w, h).then((path: string) => {
      if (token === this.bgToken && path.length > 0) {
        this.bgUri = path;
      }
    }).catch(() => {
    });
  }

  /** 背景图源：本地图优先，其次网络封面，最后透明占位 */
  private bgImage(): ResourceStr {
    if (this.bgUri.length > 0) {
      return this.bgUri;
    }
    if (this.coverUrl.length > 0) {
      return this.coverUrl;
    }
    return $r('app.media.bg_blank');
  }

  aboutToAppear(): void {
    try {
      Backdrop.get().init(getContext(this) as common.UIAbilityContext);
    } catch (e) {
      console.warn('[bg] 背景仓库初始化失败');
    }
    this.measureScreen();
    this.refreshCoverUrl();
    this.refreshBg();
    this.listener = (): void => {
      this.sync();
    };
    this.player.onChange(this.listener);
    this.sync();
    const stored = AppStorage.get<number>('lyricSize');
    if (stored !== undefined) {
      this.lyricSize = stored;
    }
    // 一进来就停在歌词屏；没歌词且没在拉就先补一次
    if (this.lines.length === 0 && !this.lyricLoading && !this.lyricRetried) {
      this.lyricRetried = true;
      this.player.retryLyric();
    }
  }

  aboutToDisappear(): void {
    this.player.offChange(this.listener);
    if (this.followTimer !== -1) {
      clearTimeout(this.followTimer);
      this.followTimer = -1;
    }
  }

  /**
   * 别处收藏 / 取消收藏（比如在「我喜欢」列表里移除当前这首）后，
   * 播放页的心形要跟着变，否则会一直停在打开时的状态。
   */
  onLibraryChange(): void {
    this.favorite = Library.get().isFavorite(this.song);
  }

  /**
   * 下载进度每秒会推好几次，但按钮文案只在「状态切换」时变
   * （下载 → 排队中 → 下载中 → 已下载），先比一次再赋值，
   * 避免为了一个文字让整页（含滚动歌词）跟着重建。
   */
  onDownloadChange(): void {
    const next = App.get().downloads.stateOf(this.song);
    if (next !== this.downloadState) {
      this.downloadState = next;
    }
  }

  /** 底部下载按钮：按真实状态说话，不再「已下载还写着下载，点了只弹一句已在本地」 */
  private tapDownload(): void {
    if (this.downloadState === 'done') {
      App.get().toast('这首歌已经在本地了');
      return;
    }
    if (this.downloadState === 'running' || this.downloadState === 'waiting') {
      App.get().toast('正在下载，进度在下载管理里看');
      return;
    }
    if (this.song.source === 'local') {
      App.get().toast('本地音乐不需要下载');
      return;
    }
    App.get().downloads.enqueue(this.song);
    App.get().toast('已加入下载队列');
  }

  private downloadLabel(): string {
    if (this.downloadState === 'done') {
      return '已下载';
    }
    if (this.downloadState === 'running') {
      return '下载中';
    }
    if (this.downloadState === 'waiting') {
      return '排队中';
    }
    return '下载';
  }

  private downloadIcon(): Resource {
    return this.downloadState === 'done'
      ? $r('sys.symbol.checkmark_circle_fill')
      : $r('sys.symbol.arrow_down_circle');
  }

  private openFailPanel(): void {
    this.failDetails = this.player.getFailDetails();
    this.failCount = this.player.getFailCandidateCount();
    this.altCount = this.player.getAlternateCount();
    this.panel = 7;
  }

  private sync(): void {
    const song = this.player.getSong();
    const changed = song.id !== this.song.id || song.source !== this.song.source;
    this.song = song;
    this.playing = this.player.isPlaying();
    this.loading = this.player.isLoading();
    this.progressMs = this.player.getPosition();
    this.duration = this.player.getDuration();
    this.mode = this.player.getMode();
    this.quality = this.player.getQuality();
    this.actualQuality = this.player.getActualQuality();
    this.sourceFrom = this.player.getSourceFrom();
    this.sourceKind = this.player.getSourceKind();
    this.errorText = this.player.getError();
    if (this.panel === 7) {
      // 面板开着时后台可能又失败了一次（比如换源重试），列表要跟上
      this.failDetails = this.player.getFailDetails();
      this.failCount = this.player.getFailCandidateCount();
      this.altCount = this.player.getAlternateCount();
    }
    const lyric = this.player.getLyric();
    this.lyricLoading = this.player.isLyricLoading();
    this.lines = lyric.lines;
    this.lyricSource = lyric.source;
    if (changed) {
      this.favorite = Library.get().isFavorite(song);
      this.downloadState = App.get().downloads.stateOf(song);
      this.lineIndex = -1;
      this.lyricRetried = false;
      this.followPaused = false;
      if (this.followTimer !== -1) {
        clearTimeout(this.followTimer);
        this.followTimer = -1;
      }
    }
    this.updateLine();
    this.refreshCoverUrl();
    this.refreshBg();
  }

  /** 逐帧跟着进度挪高亮；只有下标变了才滚动，避免每 100ms 抖一次 */
  private updateLine(): void {
    if (this.lines.length === 0 || this.lines[0].time < 0) {
      return;
    }
    const index = lyricIndexAt(this.lines, this.progressMs / 1000);
    if (index === this.lineIndex) {
      return;
    }
    this.lineIndex = index;
    if (index >= 0 && !this.followPaused) {
      this.jumpTo(index);
    }
  }

  /** 滚动到某一行；autoScroll 标记让 onScrollStart 知道这次不是用户拖的 */
  private jumpTo(index: number): void {
    if (this.lines.length === 0) {
      return;
    }
    const target = Math.max(0, Math.min(index, this.lines.length - 1));
    this.autoScroll = true;
    setTimeout((): void => {
      try {
        this.scroller.scrollToIndex(target, true, ScrollAlign.CENTER);
      } catch (e) {
        // 列表还没挂载时忽略
      }
      setTimeout((): void => {
        this.autoScroll = false;
      }, 380);
    }, 50);
  }

  private pauseFollow(): void {
    this.followPaused = true;
    if (this.followTimer !== -1) {
      clearTimeout(this.followTimer);
    }
    this.followTimer = setTimeout((): void => {
      this.followTimer = -1;
      this.followPaused = false;
      this.jumpTo(this.lineIndex);
    }, 3500);
  }

  private resumeFollow(): void {
    if (this.followTimer !== -1) {
      clearTimeout(this.followTimer);
      this.followTimer = -1;
    }
    this.followPaused = false;
    this.jumpTo(this.lineIndex);
  }

  private openLyric(): void {
    this.showLyric = true;
    if (this.lines.length === 0 && !this.lyricLoading && !this.lyricRetried) {
      this.lyricRetried = true;
      this.player.retryLyric();
      return;
    }
    this.jumpTo(this.lineIndex >= 0 ? this.lineIndex : 0);
  }

  private closeLyric(): void {
    this.showLyric = false;
  }

  private retryLyric(): void {
    this.lyricRetried = true;
    this.player.retryLyric();
    App.get().toast('正在重新找歌词');
  }

  /** 打开手动搜索歌词面板，预填当前歌名 + 首位歌手 */
  private openLyricSearch(): void {
    const singer = firstSinger(this.song.singer);
    this.lyricKeyword = this.song.name + (singer.length > 0 ? ' ' + singer : '');
    this.lyricCandidates = [];
    this.lyricSearching = false;
    this.lyricSearchHint = '';
    this.panel = 6;
  }

  private doLyricSearch(): void {
    const kw = this.lyricKeyword.trim();
    if (kw.length === 0) {
      App.get().toast('先输入歌名');
      return;
    }
    this.lyricSearching = true;
    this.lyricCandidates = [];
    this.lyricSearchHint = '';
    LyricRepo.get().search(kw).then((list: LyricCandidate[]): void => {
      this.lyricSearching = false;
      this.lyricCandidates = list;
      if (list.length === 0) {
        this.lyricSearchHint = '没搜到可用歌词，换个歌名或去掉歌手再试';
      }
    }).catch((): void => {
      this.lyricSearching = false;
      this.lyricSearchHint = '搜索失败，请检查网络后重试';
    });
  }

  private pickLyric(c: LyricCandidate): void {
    const doc = LyricRepo.get().applyManual(this.song, c.lrc, c.trans, c.source);
    this.player.setLyric(doc);
    this.panel = 0;
    App.get().toast('已应用歌词：' + c.source);
  }

  /**
   * 播放页恒为深色（白字 + 封面铺底）。
   *
   * 浅色页试过很多参数，结论是死结：浅色页要放深色字，就必须在封面上盖白，
   * 而背景本身就是封面——白盖得少，深色字糊在封面里；白盖得多，封面变白纸。
   * 只有「压暗 + 白字」能让封面和文字同时成立，这跟系统主题无关。
   */
  private p(): Palette {
    return palette(true);
  }

  /**
   * 压在封面背景上的小字统一色。
   * 深色主题的 text3 是 #5E6572，本来是给纯深底用的；播放页背景是放大的封面，
   * 上半屏亮度能到 160+，暗灰小字会直接糊掉。统一改用近白 + 暗色阴影。
   */
  private onBgSmall(): string {
    return withAlpha(this.p().text, 0.88);
  }

  private lyricFont(): number {
    // 四档整体上提：19 号在 6.7 寸屏上偏小，中文笔画密，小字会显得瘦而散
    const base: number[] = [18, 21, 24, 28];
    const size = Math.max(0, Math.min(3, this.lyricSize));
    return base[size];
  }

  /**
   * 歌词行高。
   *
   * 旧写法是 lineHeight = 字号 + 8，再叠 9vp 上下 padding：19 号字一行实际占 45vp，
   * 约 2.4 倍行距。眼睛要在屏幕上长距离跳跃，所以整屏看起来是一行一行「散着」的。
   * 中文正文 1.3~1.4 倍最舒服，再靠 padding 补一点呼吸感即可。
   */
  private lyricLineHeight(): number {
    return Math.round(this.lyricFont() * 1.34);
  }

  /**
   * 离当前行越远越淡。
   *
   * 旧写法非当前行统一 0.84，几乎和当前行一样亮，等于每行都是主角、没有焦点，
   * 读起来会累。这里按距离分四档，让视线自然收到正在唱的那一行。
   */
  private lyricAlpha(index: number): number {
    const d = Math.abs(index - this.lineIndex);
    if (d === 0) {
      return 1;
    }
    if (d === 1) {
      return 0.74;
    }
    if (d === 2) {
      return 0.56;
    }
    if (d === 3) {
      return 0.42;
    }
    // 四行以外继续变淡，形成上下「渐隐」，视线自然收在中间
    return 0.3;
  }

  private modeIcon(): Resource {
    if (this.mode === 0) {
      return $r('sys.symbol.arrow_right');
    }
    if (this.mode === 2) {
      return $r('sys.symbol.repeat_1');
    }
    if (this.mode === 3) {
      return $r('sys.symbol.shuffle');
    }
    return $r('sys.symbol.repeat');
  }

  private modeText(): string {
    if (this.mode === 0) {
      return '顺序播放';
    }
    if (this.mode === 2) {
      return '单曲循环';
    }
    if (this.mode === 3) {
      return '随机播放';
    }
    return '列表循环';
  }

  private ratio(): number {
    const total = this.duration > 0 ? this.duration : 1;
    const value = this.dragging >= 0 ? this.dragging * 1000 : this.progressMs;
    return Math.max(0, Math.min(1, value / total));
  }

  private seekTo(seconds: number): void {
    const ms = Math.max(0, Math.min(seconds * 1000, this.duration));
    this.player.seek(ms);
  }

  private toggleFavorite(): void {
    Library.get().toggleFavorite(this.song);
    // 回读而不是信任返回值：真实状态以 Library 为准，
    // 界面永远跟着「库里到底有没有」走，不会出现「已收藏但心是空的」
    this.favorite = Library.get().isFavorite(this.song);
    App.get().toast(this.favorite ? '已加入我喜欢的音乐' : '已取消收藏');
  }

  /**
   * 背景补充层 + 可读性罩层。
   *
   * 封面主绘制在 `build()` 根节点的 `.backgroundImage()` 上（见那里的注释）。
   * 这里只做两件事：
   * 1) 有封面时再叠两道"备份绘制"（容器背景 + Image 组件），位置完全重合，多画不会看出来；
   *    —— 注意**不能**在这里放不透明底色，否则会把根节点的背景图盖住；
   * 2) 没封面时给一层不透明渐变兜底；
   * 3) 最上面永远是一层很淡的竖向渐变，压住顶部状态栏和底部控件区的白字。
   */
  @Builder
  bgLayers() {
    if (this.bgUri.length > 0 || this.coverUrl.length > 0) {
      // 备份一：容器背景绘制
      Column()
        .width('100%')
        .height('100%')
        .backgroundImage(this.bgImage(), ImageRepeat.NoRepeat)
        .backgroundImageSize(ImageSize.Cover)

      // 备份二：组件绘制
      Image(this.bgImage())
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .draggable(false)
        .onError(() => {
          console.warn('[bg] 背景封面加载失败: ' + this.coverUrl);
        })
    } else {
      // 没封面：按歌名撒点的双色渐变，不透明
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 155,
          colors: [[seededGradient('lx')[0], 0], [seededGradient('lx')[1], 1]]
        })
    }

    // 可读性罩层：原来上半屏只压 3%~20% 黑，封面亮斑会把白字吃掉；
    // 现在全屏统一压到 ~40% 黑，底部仍按原渐变收深，封面色块依旧透得出来。
    Column()
      .width('100%')
      .height('100%')
      .linearGradient({
        angle: 180,
        colors: [['#75000000', 0], ['#6B000000', 0.3], ['#66000000', 0.62], ['#AD000000', 0.86],
          ['#E60B0C10', 1]]
      })
  }

  @Builder
  backdrop() {
    if (this.bgW > 0 && this.bgH > 0) {
      Stack() {
        this.bgLayers()
      }
      .width(this.bgW)
      .height(this.bgH)
      .clip(true)
    } else {
      Stack() {
        this.bgLayers()
      }
      .width('100%')
      .height('100%')
      .clip(true)
    }
  }

  @Builder
  topActions() {
    IconTap({
      icon: $r('sys.symbol.arrow_clockwise'),
      iconSize: 19,
      color: this.p().text2,
      paddingSize: 8,
      onTap: () => {
        this.player.reload();
        App.get().toast('正在重新取链，会按顺序试所有音源');
      }
    })
  }

  @Builder
  topBar() {
    Row({ space: 8 }) {
      IconTap({
        icon: $r('sys.symbol.chevron_down'),
        iconSize: 24,
        color: this.p().text,
        paddingSize: 8,
        onTap: () => {
          this.onClose();
        }
      })
      Column({ space: 2 }) {
        // v2.54：来源从「一行小字」变成「带标记的一行小字」。
        // 插件替补 / 手动换源 / 自动换源时，左边一根琥珀短竖线 ——
        // 用户听歌时抬眼就能看出「这条链接不是原平台给的」，不用去翻失败面板。
        Row({ space: 5 }) {
          if (this.sourceKind === 'substitute' || this.sourceKind === 'manual' ||
            this.sourceKind === 'switch') {
            Row()
              .width(2)
              .height(11)
              .borderRadius(1)
              .backgroundColor(this.p().primary)
          }
          Text(this.sourceFrom.length > 0 ? this.sourceFrom : (this.song.source.length > 0 ?
            platformName(this.song.source) : '音源'))
            .fontSize(FONT.micro)
            .fontColor(this.sourceKind === 'substitute' ? this.p().text : this.onBgSmall())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .textShadow({ radius: 8, color: '#B3000000', offsetX: 0, offsetY: 1 })
        }
        if (this.errorText.length > 0) {
          // 一行摘要放不下失败原因（十几个音源各有各的说法），
          // 这里只当入口，完整凭据在「详情」面板里逐条列
          Row({ space: 4 }) {
            Text(this.errorText)
              .fontSize(FONT.micro)
              .fontColor(this.p().danger)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Text('详情 ›')
              .fontSize(FONT.micro)
              .fontColor(this.p().danger)
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            this.openFailPanel();
          })
        }
        // 双页指示点：实心=当前屏，左点封面右点歌词，可直接点切换
        Row({ space: 5 }) {
          Column()
            .width(6)
            .height(6)
            .borderRadius(3)
            .backgroundColor(!this.showLyric ? this.p().text : withAlpha(this.p().text, 0.38))
            .onClick(() => {
              if (this.showLyric) {
                this.closeLyric();
              }
            })
          Column()
            .width(6)
            .height(6)
            .borderRadius(3)
            .backgroundColor(this.showLyric ? this.p().text : withAlpha(this.p().text, 0.38))
            .onClick(() => {
              if (!this.showLyric) {
                this.openLyric();
              }
            })
        }
        .margin({ top: 4 })
      }
      .alignItems(HorizontalAlign.Center)
      .layoutWeight(1)

      this.topActions()
    }
    .width('100%')
    .padding({ left: 6, right: 6 })
  }

  /* ------------------------- 封面屏 ------------------------- */
  @Builder
  coverPane() {
    Column({ space: 16 }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        Column()
          .width('100%')
          .height('100%')
          .borderRadius(28)
          .backgroundColor(withAlpha(this.p().text3, 0.08))
        Cover({ uri: this.song.cover, songId: CoverRepo.keyOf(this.song), side: 300, radius: 26, elevated: true, badge: '' })

        // 可见的歌词入口：手势万一是别的原因失效，这个按钮一定能点
        Row({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.text_alignleft'))
            .fontSize(13)
            .fontColor([this.onBgSmall()])
          Text('歌词')
            .fontSize(FONT.micro)
            .fontColor(this.onBgSmall())
        }
        .padding({ left: 10, right: 11, top: 6, bottom: 6 })
        .borderRadius(RADIUS.pill)
        .backgroundColor(withAlpha(this.p().bg, 0.72))
        .border({ width: 0.5, color: this.p().glassBorder })
        .margin({ right: 12, bottom: 12 })
        .stateStyles({
          normal: { .opacity(1).scale({ x: 1, y: 1 }) },
          pressed: { .opacity(0.8).scale({ x: 0.94, y: 0.94 }) }
        })
        .animation({ duration: 120, curve: Curve.EaseOut })
        .onClick(() => {
          this.openLyric();
        })
      }
      .width(300)
      .height(300)

      Column({ space: 6 }) {
        Text(this.song.name.length > 0 ? this.song.name : '暂无播放')
          .fontSize(23)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.p().text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
          .width('100%')
          .textShadow({ radius: 10, color: '#B3000000', offsetX: 0, offsetY: 1 })
        Row({ space: 6 }) {
          Text(this.song.singer.length > 0 ? this.song.singer : '未知歌手')
            .fontSize(FONT.callout)
            .fontColor(this.onBgSmall())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .textShadow({ radius: 8, color: '#B3000000', offsetX: 0, offsetY: 1 })
          if (this.song.album.length > 0) {
            Text('·').fontSize(FONT.callout).fontColor(this.onBgSmall())
            Text(this.song.album)
              .fontSize(FONT.callout)
              .fontColor(this.onBgSmall())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textShadow({ radius: 8, color: '#B3000000', offsetX: 0, offsetY: 1 })
          }
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')

      Row({ space: 6 }) {
        Text(qualityLabel(this.actualQuality))
          .fontSize(9)
          .fontColor(this.p().primary)
          .backgroundColor(this.p().primarySoft)
          .borderRadius(4)
          .padding({ left: 5, right: 5, top: 2, bottom: 2 })
        if (audioFormat(this.song.url).length > 0) {
          Text(audioFormat(this.song.url))
            .fontSize(9)
            .fontColor(this.onBgSmall())
            .border({ width: 0.5, color: this.p().line })
            .borderRadius(4)
            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
        }
      }
      .height(18)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .gesture(
      GestureGroup(GestureMode.Parallel,
        TapGesture({ count: 1, fingers: 1 })
          .onAction(() => {
            if (!this.dragged) {
              this.openLyric();
            }
          }),
        PanGesture({ direction: PanDirection.Down, distance: 16 })
          .onActionUpdate((event: GestureEvent) => {
            this.dragged = true;
            // 跟手必须零延迟：dragY 上不再挂 .animation()，
            // 否则每帧位移都被 160ms 缓动追一遍，手指和内容像隔着一层橡皮筋。
            this.dragY = event.offsetY > 0 ? event.offsetY : 0;
          })
          .onActionEnd(() => {
            const moved: number = this.dragY;
            if (moved > 110) {
              // 达到阈值：交给 Index 的共享元素转场收起。
              // 刻意不把 dragY 硬清零——否则会「先弹回原位、再开始收拢」，
              // 出现一次明显跳变；让转场从手指当前位置连续接手。
              this.onClose();
            } else {
              // 未达阈值：用显式 animateTo 回弹，而不是挂在属性上的动画。
              // 与 TabBar.onSwipe 同一套「跟手零延迟 / 收尾才补间」写法。
              animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, (): void => {
                this.dragY = 0;
              });
            }
            // 延后清零：抬手那一刻 Tap 的回调可能排在 Pan 之后
            setTimeout((): void => {
              this.dragged = false;
            }, 220);
          }),
        // 左滑切歌词（参考软件的分页方向），垂直滚动不受影响
        PanGesture({ direction: PanDirection.Horizontal, distance: 30 })
          .onActionEnd((event: GestureEvent) => {
            if (event.offsetX < -50 && !this.dragged) {
              this.openLyric();
            }
          })
      )
    )
  }

  /* ------------------------- 歌词屏 ------------------------- */
  @Builder
  lyricHeader() {
    Row({ space: 10 }) {
      Cover({ uri: this.song.cover, songId: CoverRepo.keyOf(this.song), side: 42, radius: 11 })
      Column({ space: 3 }) {
        Text(this.song.name.length > 0 ? this.song.name : '暂无播放')
          .fontSize(FONT.callout)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.p().text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textShadow({ radius: 8, color: '#B3000000', offsetX: 0, offsetY: 1 })
        Text((this.song.singer.length > 0 ? this.song.singer : '未知歌手') +
          (this.song.album.length > 0 ? ' · ' + this.song.album : ''))
          .fontSize(FONT.micro)
          .fontColor(this.onBgSmall())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textShadow({ radius: 8, color: '#B3000000', offsetX: 0, offsetY: 1 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 收藏与「更多」在底部动作栏已经有了，这里不再重复一份；
      // 头部只负责「点击收起歌词」，右侧给个小箭头表明可收起。
      SymbolGlyph($r('sys.symbol.chevron_down'))
        .fontSize(15)
        .fontColor([this.onBgSmall()])
        .padding({ left: 6, right: 4 })
    }
    .width('100%')
    .padding({ bottom: 6 })
    .onClick(() => {
      this.closeLyric();
    })
    .gesture(
      // 歌词屏也允许下滑收起：封面屏有跟手位移，这里列表要抢垂直滚动，只在头部小条上给
      PanGesture({ direction: PanDirection.Down, distance: 24 })
        .onActionEnd((event: GestureEvent) => {
          if (event.offsetY > 70) {
            this.onClose();
          }
        })
    )
  }

  @Builder
  lyricList() {
    List({ scroller: this.scroller }) {
      ListItem() {
        Row().height(96)
      }
      ForEach(this.lines, (line: LyricLine, index: number) => {
        ListItem() {
          Column({ space: 2 }) {
            Text(line.text)
              // 只大 1 号：中文 Bold 会让字形横向变宽，行宽一跳就显得整块在抖
              .fontSize(this.lineIndex === index ? this.lyricFont() + 1 : this.lyricFont())
              .fontWeight(this.lineIndex === index ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(withAlpha(this.p().text, this.lyricAlpha(index)))
              .textAlign(TextAlign.Center)
              .width('100%')
              .lineHeight(this.lyricLineHeight())
              // 阴影只用来在浅色封面上兜底可读性，radius 太大字会发虚
              .textShadow({ radius: 6, color: '#80000000', offsetX: 0, offsetY: 1 })
              .animation({ duration: 220, curve: Curve.EaseOut })
            if (line.trans.length > 0 && App.get().settings.showTrans()) {
              Text(line.trans)
                .fontSize(FONT.caption)
                .fontColor(withAlpha(this.p().text, this.lyricAlpha(index) * 0.92))
                .textAlign(TextAlign.Center)
                .width('100%')
                .lineHeight(Math.round(FONT.caption * 1.35))
                .textShadow({ radius: 6, color: '#80000000', offsetX: 0, offsetY: 1 })
                .animation({ duration: 220, curve: Curve.EaseOut })
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 3, bottom: 3 })
          .onClick(() => {
            if (line.time >= 0) {
              this.seekTo(line.time);
              this.lineIndex = index;
              this.resumeFollow();
            }
          })
        }
      }, (line: LyricLine, index: number) => index.toString() + '_' + line.time.toString())

      ListItem() {
        Row().height(120)
      }
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .onScrollStart(() => {
      // 用户自己拖的才暂停跟随；程序化滚动不打断
      if (!this.autoScroll) {
        this.pauseFollow();
      }
    })
  }

  @Builder
  lyricEmpty() {
    Column({ space: 10 }) {
      if (this.lyricLoading) {
        LoadingProgress().width(24).height(24).color(this.onBgSmall())
        Text('正在找歌词').fontSize(FONT.caption).fontColor(this.onBgSmall())
          .textShadow({ radius: 8, color: '#B3000000', offsetX: 0, offsetY: 1 })
      } else {
        SymbolGlyph($r('sys.symbol.text_alignleft')).fontSize(28).fontColor([this.onBgSmall()])
        Text('这首歌没找到歌词').fontSize(FONT.callout).fontColor(this.onBgSmall())
          .textShadow({ radius: 8, color: '#B3000000', offsetX: 0, offsetY: 1 })
        Text('可以试着重新拉一次，会挨个问音源和平台')
          .fontSize(FONT.caption)
          .fontColor(this.onBgSmall())
          .textShadow({ radius: 8, color: '#B3000000', offsetX: 0, offsetY: 1 })
          .textAlign(TextAlign.Center)
        Text('重新找歌词')
          .fontSize(FONT.caption)
          .fontColor(this.p().primary)
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .borderRadius(RADIUS.pill)
          .backgroundColor(this.p().primarySoft)
          .margin({ top: 4 })
          .onClick(() => {
            this.retryLyric();
          })
        Text('手动搜索歌词')
          .fontSize(FONT.caption)
          .fontColor(this.onBgSmall())
          .textShadow({ radius: 8, color: '#B3000000', offsetX: 0, offsetY: 1 })
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .margin({ top: 2 })
          .onClick(() => {
            this.openLyricSearch();
          })
      }
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .gesture(
      PanGesture({ direction: PanDirection.Horizontal, distance: 30 })
        .onActionEnd((event: GestureEvent) => {
          if (event.offsetX > 50) {
            this.closeLyric();
          }
        })
    )
  }

  @Builder
  lyricPane() {
    Column({ space: 6 }) {
      this.lyricHeader()

      if (this.lines.length === 0) {
        this.lyricEmpty()
      } else {
        Stack({ alignContent: Alignment.Bottom }) {
          this.lyricList()

          // 手动翻过歌词后，给一个回到当前句的出口
          if (this.followPaused && this.lineIndex >= 0) {
            Row({ space: 5 }) {
              SymbolGlyph($r('sys.symbol.arrow_down_circle'))
                .fontSize(12)
                .fontColor([this.p().primary])
              Text('回到当前')
                .fontSize(FONT.micro)
                .fontColor(this.p().primary)
            }
            .padding({ left: 12, right: 13, top: 7, bottom: 7 })
            .borderRadius(RADIUS.pill)
            .backgroundColor(glassCardBase(this.isDark))
            .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
            .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
            .shadow(glassShadow(this.isDark, this.lightLevel))
            .margin({ bottom: 8 })
            .transition(TransitionEffect.OPACITY.animation({ duration: 160 }))
            .onClick(() => {
              this.resumeFollow();
            })
          }
        }
        .width('100%')
        .layoutWeight(1)
        // 右滑回封面屏；列表垂直滚动是另一个方向，互不抢手势
        .gesture(
          PanGesture({ direction: PanDirection.Horizontal, distance: 30 })
            .onActionEnd((event: GestureEvent) => {
              if (event.offsetX > 50) {
                this.closeLyric();
              }
            })
        )
      }

      Row({ space: 6 }) {
        Text(this.lyricSource.length > 0 ? '歌词来自 ' + this.lyricSource : '无歌词来源')
          .fontSize(FONT.micro)
          .fontColor(this.onBgSmall())
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textShadow({ radius: 8, color: '#B3000000', offsetX: 0, offsetY: 1 })
        if (this.lyricSource.length > 0) {
          Text('重找')
            .fontSize(FONT.micro)
            .fontColor(this.onBgSmall())
            .textShadow({ radius: 8, color: '#B3000000', offsetX: 0, offsetY: 1 })
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .onClick(() => {
              this.retryLyric();
            })
        }
      }
      .width('100%')
      .padding({ bottom: 2 })
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  progressBar() {
    Column({ space: 2 }) {
      Slider({
        value: this.dragging >= 0 ? this.dragging : this.progressMs / 1000,
        min: 0,
        max: Math.max(1, this.duration / 1000),
        step: 0.5,
        style: SliderStyle.OutSet
      })
        .width('100%')
        .trackThickness(3)
        .selectedColor(this.p().primary)
        .trackColor(withAlpha(this.p().text, 0.30))
        .blockColor(this.p().primary)
        .blockSize({ width: 12, height: 12 })
        .onChange((value: number, mode: SliderChangeMode) => {
          if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
            this.dragging = value;
          } else {
            this.seekTo(value);
            this.dragging = -1;
          }
        })

      Row() {
        Text(formatTime(this.dragging >= 0 ? this.dragging : this.progressMs / 1000))
          .fontSize(FONT.micro)
          .fontColor(this.onBgSmall())
          .textShadow({ radius: 8, color: '#B3000000', offsetX: 0, offsetY: 1 })
        Blank()
        Text(formatTime(this.duration / 1000))
          .fontSize(FONT.micro)
          .fontColor(this.onBgSmall())
          .textShadow({ radius: 8, color: '#B3000000', offsetX: 0, offsetY: 1 })
      }
      .width('100%')
      .padding({ left: 4, right: 4 })
    }
    .width('100%')
  }

  @Builder
  controls() {
    Row() {
      this.modeButton()

      IconTap({
        icon: $r('sys.symbol.backward_end_fill'),
        iconSize: 26,
        color: this.p().text,
        paddingSize: 8,
        onTap: () => {
          this.player.prev();
        }
      })

      Stack({ alignContent: Alignment.Center }) {
        if (this.loading) {
          LoadingProgress().width(30).height(30).color(this.p().text)
        } else {
          SymbolGlyph(this.playing ? $r('sys.symbol.pause_circle_fill') : $r('sys.symbol.play_circle_fill'))
            .fontSize(62)
            .fontColor([this.p().text])
        }
      }
      .width(72)
      .height(72)
      .onClick(() => {
        this.player.toggle();
      })

      IconTap({
        icon: $r('sys.symbol.forward_end_fill'),
        iconSize: 26,
        color: this.p().text,
        paddingSize: 8,
        onTap: () => {
          this.player.next();
        }
      })

      this.queueButton()
    }
    .width('100%')
    .padding({ left: 8, right: 8 })
  }

  @Builder
  modeButton() {
    Column({ space: 3 }) {
      SymbolGlyph(this.modeIcon()).fontSize(19).fontColor([this.onBgSmall()])
      Text(this.modeText()).fontSize(8.5).fontColor(this.onBgSmall())
        .textShadow({ radius: 8, color: '#B3000000', offsetX: 0, offsetY: 1 })
    }
    .layoutWeight(1)
    .onClick(() => {
      this.player.cycleMode();
      App.get().toast(this.modeText());
    })
  }

  /**
   * 播放队列：位置就是原来「定时」那一格。
   * 定时和倍速都下线了，这一格空着不如给最常用的队列——
   * 顶栏那个列表图标也就不需要了，全页只留一个入口。
   */
  @Builder
  queueButton() {
    Column({ space: 3 }) {
      SymbolGlyph($r('sys.symbol.list_bullet')).fontSize(19).fontColor([this.onBgSmall()])
      Text('队列').fontSize(8.5).fontColor(this.onBgSmall())
        .textShadow({ radius: 8, color: '#B3000000', offsetX: 0, offsetY: 1 })
    }
    .layoutWeight(1)
    .onClick(() => {
      // 队列不走 bindSheet（那层容器自带不透明白底，玻璃永远透不出来），
      // 改成页面内自绘浮层；动画自己给，不然 if 切换是硬切
      animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, () => {
        this.panel = 4;
      });
    })
  }

  /**
   * 底部动作栏（歌词屏 / 封面屏共用一份）。
   *
   * 每个按钮都写成「无参 @Builder + 内部直接读 @State」。
   * 以前是一个 actionButton(icon, label, active, action) 的带参 Builder：参数按值
   * 拷贝进去，点完收藏 this.favorite 变了，Builder 内部拿到的还是旧值，界面就一直
   * 不飘红 —— 用户看到的是「点心心没反应」，其实早就收藏成功了。
   */
  @Builder
  bottomActions() {
    Row() {
      this.favButton()
      this.qualityButton()
      this.downloadButton()
      this.artistSearchButton()
    }
    .width('100%')
    .padding({ left: 10, right: 10, bottom: 4 })
  }

  /** 收藏：状态判断写在 Builder 内部，才能跟着 this.favorite 实时变红 */
  @Builder
  favButton() {
    Column({ space: 5 }) {
      SymbolGlyph(this.favorite ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
        .fontSize(19)
        .fontColor([this.favorite ? this.p().primary : this.onBgSmall()])
        .animation({ duration: 180, curve: Curve.EaseOut })
      Text(this.favorite ? '已收藏' : '收藏')
        .fontSize(9.5)
        .fontColor(this.favorite ? this.p().primary : this.onBgSmall())
        .maxLines(1)
        .textShadow({ radius: 8, color: '#B3000000', offsetX: 0, offsetY: 1 })
        .animation({ duration: 180, curve: Curve.EaseOut })
    }
    .layoutWeight(1)
    .onClick(() => {
      this.toggleFavorite();
    })
  }

  /** 音质：切完实时变标签，别停在旧档位 */
  @Builder
  qualityButton() {
    Column({ space: 5 }) {
      SymbolGlyph($r('sys.symbol.headphones')).fontSize(19).fontColor([this.onBgSmall()])
      Text(qualityLabel(this.actualQuality))
        .fontSize(9.5)
        .fontColor(this.onBgSmall())
        .maxLines(1)
        .textShadow({ radius: 8, color: '#B3000000', offsetX: 0, offsetY: 1 })
    }
    .layoutWeight(1)
    .onClick(() => {
      this.panel = 1;
    })
  }

  /** 下载：排队 / 进行中 / 已完成三种状态都要能当场变 */
  @Builder
  downloadButton() {
    Column({ space: 5 }) {
      SymbolGlyph(this.downloadIcon())
        .fontSize(19)
        .fontColor([this.downloadState === 'done' ? this.p().primary : this.onBgSmall()])
      Text(this.downloadLabel())
        .fontSize(9.5)
        .fontColor(this.downloadState === 'done' ? this.p().primary : this.onBgSmall())
        .maxLines(1)
        .textShadow({ radius: 8, color: '#B3000000', offsetX: 0, offsetY: 1 })
    }
    .layoutWeight(1)
    .onClick(() => {
      this.tapDownload();
    })
  }

  /**
   * 搜歌手：原来这里叫「更多」，点开是歌曲菜单，为了跳一次「查看歌手」得先开弹层。
   * 现在把那一步收掉 —— 直接拿当前歌的歌手名去搜索页自动搜，位置、图标沿用菜单里
   * 「查看歌手」的人像。多歌手合唱只取第一位，否则整串拿去搜基本搜不到结果。
   * 先 onClose 收起全屏播放页再 push，否则整屏播放浮层会把搜索结果盖在下面。
   */
  @Builder
  artistSearchButton() {
    Column({ space: 5 }) {
      SymbolGlyph($r('sys.symbol.person')).fontSize(19).fontColor([this.onBgSmall()])
      Text('搜歌手')
        .fontSize(9.5)
        .fontColor(this.onBgSmall())
        .maxLines(1)
        .textShadow({ radius: 8, color: '#B3000000', offsetX: 0, offsetY: 1 })
    }
    .layoutWeight(1)
    .onClick(() => {
      let singer = this.song.singer.trim();
      for (const sep of [' / ', ' /', '/ ', '/', '、', ',', '，', '&', ';', '；']) {
        const i = singer.indexOf(sep);
        if (i > 0) {
          singer = singer.substring(0, i).trim();
          break;
        }
      }
      if (singer.length === 0) {
        App.get().toast('这首歌没有歌手信息');
        return;
      }
      this.onClose();
      App.get().openSearch(singer);
    })
  }

  /** 手动搜索歌词：自动链路找不到时，自己指定歌名从各平台与歌词库里挑 */
  @Builder
  lyricSearchPanel() {
    Column({ space: 10 }) {
      Text('搜索歌词')
        .fontSize(FONT.headline)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.p().text)
        .width('100%')
      Text('自动找不到时，可以按歌名从各平台与歌词库重新找一份')
        .fontSize(FONT.caption)
        .fontColor(this.p().text3)
        .width('100%')
      TextInput({ text: this.lyricKeyword, placeholder: '歌名，可加歌手' })
        .fontSize(FONT.body)
        .fontColor(this.p().text)
        .placeholderColor(this.p().text3)
        .backgroundColor(glassCardBase(this.isDark))
        .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
        .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
        .shadow(glassShadow(this.isDark, this.lightLevel))
        .borderRadius(RADIUS.sm)
        .height(44)
        .width('100%')
        .onChange((value: string): void => {
          this.lyricKeyword = value;
        })
      Row({ space: 12 }) {
        Row() {
          Text('搜索').fontSize(FONT.callout).fontColor(Color.White)
        }
        .padding({ left: 20, right: 20, top: 9, bottom: 9 })
        .backgroundColor(this.p().primary)
        .borderRadius(RADIUS.pill)
        .onClick(() => {
          this.doLyricSearch();
        })
        if (this.lyricSearching) {
          LoadingProgress().width(20).height(20).color(this.p().primary)
        }
      }
      .width('100%')

      if (this.lyricSearching) {
        Text('正在跨平台搜索…').fontSize(FONT.caption).fontColor(this.p().text3).width('100%')
      } else if (this.lyricCandidates.length === 0) {
        Text(this.lyricSearchHint.length > 0 ? this.lyricSearchHint : '输入关键词后点搜索')
          .fontSize(FONT.caption)
          .fontColor(this.p().text3)
          .width('100%')
      } else {
        List({ space: 6 }) {
          ForEach(this.lyricCandidates, (c: LyricCandidate, index: number) => {
            ListItem() {
              Column({ space: 3 }) {
                Text(c.name)
                  .fontSize(FONT.body)
                  .fontColor(this.p().text)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(c.singer + ' · ' + c.source)
                  .fontSize(FONT.caption)
                  .fontColor(this.p().text3)
                  .maxLines(1)
                if (c.preview.length > 0) {
                  Text(c.preview)
                    .fontSize(FONT.micro)
                    .fontColor(this.p().text3)
                    .maxLines(1)
                }
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding({ left: 12, right: 12, top: 10, bottom: 10 })
              .backgroundColor(glassCardBase(this.isDark))
              .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
              .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
              .shadow(glassShadow(this.isDark, this.lightLevel))
              .borderRadius(RADIUS.md)
            }
            .onClick(() => {
              this.pickLyric(c);
            })
          }, (c: LyricCandidate, index: number): string => index.toString())
        }
        .height(320)
        .width('100%')
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 16, bottom: 26 })
    .backgroundColor(this.p().bg)
  }

  @Builder
  qualityPanel() {
    Column({ space: 6 }) {
      Text('音质')
        .fontSize(FONT.headline)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.p().text)
        .width('100%')
        .padding({ bottom: 4 })
      ForEach(this.qualityOptionList(), (item: string) => {
        Row({ space: 10 }) {
          Text(qualityLabel(item)).fontSize(FONT.body).fontColor(this.p().text).layoutWeight(1)
          Text(App.get().settings.qualityLabel(item)).fontSize(FONT.caption).fontColor(this.p().text3)
          if (this.quality === item) {
            SymbolGlyph($r('sys.symbol.checkmark')).fontSize(16).fontColor([this.p().primary])
          }
        }
        .width('100%')
        .height(50)
        .onClick(() => {
          this.quality = item;
          this.player.setQuality(item);
          this.panel = 0;
        })
      }, (item: string) => item)
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 16, bottom: 26 })
    .backgroundColor(this.p().bg)
  }

  /**
   * 失败面板：这次到底问了谁、各自为什么没成。
   *
   * 以前 errorText 是一行拼接出来的长字符串，播放页只能 maxLines(1) 截断，
   * 用户看到的就是「这首歌暂时取不到完整音频（…403…）」——既不知道有几个源参与，
   * 也不知道自己装的那几个源里到底谁还活着。这里改成逐条列，并把「还有几条链接没试」
   * 和「再试一次」放到一起，失败就不再是死路。
   */
  @Builder
  failPanel() {
    Column({ space: 14 }) {
      Column({ space: 6 }) {
        Text('这次为什么没播出来')
          .fontSize(FONT.headline)
          .fontColor(this.p().text)
          .width('100%')
        Text(this.altCount > 0
          ? ('共 ' + this.failCount.toString() + ' 个音源参与取链，另有 ' +
            this.altCount.toString() + ' 条其它音源给的链接还没试')
          : ('共 ' + this.failCount.toString() + ' 个音源参与取链，它们的返回如下'))
          .fontSize(FONT.caption)
          .fontColor(this.p().text3)
          .lineHeight(18)
          .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      if (this.failDetails.length === 0) {
        Text('没有留下取链失败记录：说明链接取到了，是播放器在准备阶段失败的（链接过期或防盗链校验）。换一条链接通常能恢复。')
          .fontSize(FONT.caption)
          .fontColor(this.p().text3)
          .lineHeight(19)
          .width('100%')
      } else {
        Scroll() {
          Column({ space: 8 }) {
            ForEach(this.failDetails, (item: FailDetail, index: number) => {
              Column({ space: 3 }) {
                Row({ space: 6 }) {
                  Text(item.name)
                    .fontSize(FONT.caption)
                    .fontColor(this.p().text)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                  if (item.preferred) {
                    Text('首选')
                      .fontSize(FONT.micro)
                      .fontColor(this.p().primary)
                      .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                      .backgroundColor(this.p().primarySoft)
                      .borderRadius(RADIUS.pill)
                  }
                }
                .width('100%')

                Text(item.text)
                  .fontSize(FONT.caption)
                  .fontColor(this.p().text3)
                  .lineHeight(18)
                  .width('100%')
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding(10)
              .backgroundColor(glassCardBase(this.isDark))
              .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
              .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
              .shadow(glassShadow(this.isDark, this.lightLevel))
              .borderRadius(RADIUS.sm)
            }, (item: FailDetail, index: number) => index.toString() + '_' + item.name)
          }
          .width('100%')
        }
        .constraintSize({ maxHeight: 330 })
        .scrollBar(BarState.Off)
      }

      Row({ space: 10 }) {
        Button(this.altCount > 0 ? ('换个音源再试（还有 ' + this.altCount.toString() + ' 条）') : '重新取链')
          .fontSize(FONT.callout)
          .fontColor('#FF191713')
          .backgroundColor(this.p().primary)
          .borderRadius(RADIUS.pill)
          .height(42)
          .layoutWeight(1)
          .onClick(() => {
            this.panel = 0;
            this.player.retryWithAnotherSource();
            App.get().toast(this.altCount > 0 ? '换到下一个音源给的链接' : '重新向所有音源取链');
          })
        Button('播放下一首')
          .fontSize(FONT.callout)
          .fontColor(this.p().text2)
          .backgroundColor(glassCardBase(this.isDark))
          .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
          .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
          .shadow(glassShadow(this.isDark, this.lightLevel))
          .borderRadius(RADIUS.pill)
          .height(42)
          .layoutWeight(1)
          .onClick(() => {
            this.panel = 0;
            this.player.next();
          })
      }
      .width('100%')

      /*
       * v2.54 诊断闭环：以前这里只有「换源 / 重取链 / 下一首」，
       * 用户想知道「我装的那几个源到底谁还活着」，只能自己退回设置页找音源管理 ——
       * v2.46 那个「自检、刷新都显示正常，为什么就是播不出来」的投诉，断点就在这一步。
       * 现在失败现场直接给出通往音源页的出口，App.openSources() 本来就有，只是没人调。
       */
      Row({ space: 4 }) {
        Text('查看音源状态')
          .fontSize(FONT.callout)
          .fontColor(inkSignalText(this.isDark))
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(12)
          .fontColor([inkSignalText(this.isDark)])
      }
      .height(40)
      .padding({ left: 12, right: 10 })
      .borderRadius(RADIUS.pill)
      .onClick(() => {
        this.panel = 0;
        App.get().openSources();
      })
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 10, bottom: 26 })
    // 自己铺底，不依赖 bindSheet 的 backgroundColor：FIT_CONTENT 下能用，
    // 换尺寸或换机型不保证生效，透出播放页黑底就变成深字压黑底。
    .backgroundColor(this.p().bg)
  }

  private closeQueue(): void {
    animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => {
      this.panel = 0;
    });
  }

  @Builder
  panelContent() {
    if (this.panel === 1) {
      this.qualityPanel()
    } else if (this.panel === 6) {
      this.lyricSearchPanel()
    } else if (this.panel === 7) {
      this.failPanel()
    }
  }


  build() {
    Stack() {
      this.backdrop()

      Column({ space: 8 }) {
        this.topBar()
        if (this.showLyric) {
          this.lyricPane()
        } else {
          this.coverPane()
        }
        Column({ space: 14 }) {
          this.progressBar()
          this.controls()
          // 两屏都保留底排动作：歌词屏也要能下载/换音质/收藏（对齐参考软件）
          this.bottomActions()
        }
        .width('100%')
        .padding({ bottom: 18 })
      }
      .width('100%')
      .height('100%')
      .padding({ left: 20, right: 20, top: this.topSafe })
      // 跟手阶段零延迟：这里刻意不挂 .animation()。
      // 属性动画的时长在渲染时读一次，与每帧变化的 dragY 叠加后
      // 表现为「原地卡住、然后硬跳」（TabBar.onSwipe 注释里记过同一个坑）。
      // 松手回弹改由 onActionEnd 里的 animateTo 显式补间。
      .translate({ y: this.dragY })

      // 队列浮层压在整页之上（含底排动作栏），所以不会出现「面板下面还露着按钮」。
      // 外壳用公共的 QueueOverlay，跟首页迷你条那个入口共用同一套尺寸和遮罩。
      if (this.panel === 4) {
        QueueOverlay({
          onClose: (): void => {
            this.closeQueue();
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    // 最后一道兜底：播放页是盖在首页上的整页浮层，根节点必须不透明，
    // 否则背景层任何一处失效都会让首页从底下透上来
    .backgroundColor('#0B0C10')
    /**
     * 背景最终落点：直接画在**根节点自己的背景层**上。
     *
     * 前面把封面放在子节点里（Stack → Column/Image），换了数值尺寸、换了 backgroundImage、
     * 换了 Image 组件，真机一律不显示；而同一张图放在 300 的小卡片里就正常。
     * 根节点的背景层不参与子组件测量，尺寸就是整屏，是这条链上唯一不依赖任何父级推导的位置——
     * 背景色、背景图、前景内容三层结构最简单，也最不容易被布局链路带塌。
     *
     * 没有封面时传 1×1 透明占位图（`bg_blank`），避免空字符串被当成非法资源。
     */
    .backgroundImage(this.bgImage(), ImageRepeat.NoRepeat)
    .backgroundImageSize(ImageSize.Cover)
    // 队列（panel 4）走页面内自绘浮层，不参与 bindSheet
    .bindSheet(this.panel > 0 && this.panel !== 4, this.panelContent(), {
      height: this.panel === 4 || this.panel === 6 ? SheetSize.LARGE : SheetSize.FIT_CONTENT,
      dragBar: false,
      backgroundColor: this.p().bg,
      onDisappear: () => {
        this.panel = 0;
        this.favorite = Library.get().isFavorite(this.song);
      }
    })
  }
}

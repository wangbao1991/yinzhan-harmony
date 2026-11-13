import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { SongInfo, emptySong, LyricDoc, emptyLyric, PlayMode } from '../common/Models';
import { PrefKeys } from '../common/Constants';
import { Resolver, FailDetail } from './Resolver';
import { LyricRepo } from './LyricRepo';
import { CoverRepo } from './CoverRepo';
import { Library } from './Library';
import { PlayStats } from './PlayStats';
import { Settings } from './Settings';
import { Store } from './Store';
import { MediaSessionService, PlaybackCommandHandler } from '../service/MediaSessionService';
import { AudioBackgroundTask } from '../service/AudioBackgroundTask';

const PAUSE_RELEASE_DELAY: number = 180000;
const PREPARE_TIMEOUT: number = 30000;
/**
 * 剩余多少毫秒开始预取下一首直链。取 60s 是因为懒人模式全源 + 升档的
 * 内部截止是 52s，提前 60s 起跑才能赶在切歌前把结果放进缓存；
 * 又比 15 分钟缓存 TTL 短得多，链接不会放到过期。
 */
const PRELOAD_LEAD_MS: number = 60000;
/** 播放器准备失败时，最多再换几条其它音源给的链接 */
const MAX_SOURCE_SWITCH: number = 3;

export class Player {
  private static instance: Player = new Player();
  static get(): Player {
    return Player.instance;
  }

  private player: media.AVPlayer | null = null;
  private queue: SongInfo[] = [];
  private index: number = -1;
  private current: SongInfo = emptySong();
  private playing: boolean = false;
  private loading: boolean = false;
  private position: number = 0;
  private duration: number = 0;
  private quality: string = '320k';
  /** 当前这首实际拿到的音质（可能低于设置里的偏好） */
  private actualQuality: string = '';
  private mode: PlayMode = PlayMode.LOOP_LIST;
  private errorText: string = '';
  private sourceFrom: string = '';
  /**
   * v2.54：这条链接是怎么来的，供播放页把「不是原平台给的」标出来。
   * normal 首选源 / local 本地文件 / substitute 插件替补 / manual 手动换源 / switch 自动换源
   * 只描述来源类型，不改 result.from 的文案生成。
   */
  private sourceKind: string = 'normal';
  private lyric: LyricDoc = emptyLyric();
  private lyricLoading: boolean = false;
  private token: number = 0;
  private listeners: Array<() => void> = [];
  private context: common.UIAbilityContext | null = null;
  private session: MediaSessionService = new MediaSessionService();
  private bgTask: AudioBackgroundTask = new AudioBackgroundTask();
  private localFile: fs.File | null = null;
  private failStreak: number = 0;
  /** 本首歌已经换过几条链接，防止坏链接无限重试 */
  private switchCount: number = 0;
  /** 当前正在播 / 刚失败的链接，换源时用它排除并给对应音源降权 */
  private lastUrl: string = '';
  private pendingSeek: number = 0;
  private pauseTimer: number = -1;
  private lastStatePush: number = 0;
  private lastPersist: number = 0;
  /** 播放中位置单独落盘的时间戳（整队列序列化太贵，不能 5 秒来一次） */
  private lastPosSave: number = 0;
  /** 冷启动恢复出来的「哪首、从哪继续」，由 playCurrent 消费一次 */
  private resumeKey: string = '';
  private resumeSeek: number = 0;
  private queueSignature: string = '';
  private prepareTimer: number = -1;
  /** 本首是否已触发过预加载，避免 timeUpdate 每帧重复发起 */
  private preloadDone: boolean = false;
  private resumeAfterInterrupt: boolean = false;
  private localPathProvider: ((song: SongInfo) => string) | null = null;
  private errorReporter: ((message: string) => void) | null = null;
  private initialized: boolean = false;

  /* ---------------- 初始化与订阅 ---------------- */
  init(context: common.UIAbilityContext): void {
    if (this.initialized) {
      return;
    }
    this.initialized = true;
    this.context = context;
    this.quality = Settings.get().quality();
    this.mode = Player.toMode(Store.get().getNumber(PrefKeys.PLAY_MODE, PlayMode.LOOP_LIST));
    const handler: PlaybackCommandHandler = {
      onPlayCommand: (): void => {
        this.play();
      },
      onPauseCommand: (): void => {
        this.pause();
      },
      onNextCommand: (): void => {
        this.next();
      },
      onPrevCommand: (): void => {
        this.prev();
      },
      onSeekCommand: (positionMs: number): void => {
        this.seek(positionMs);
      },
      onStopCommand: (): void => {
        this.pause();
      }
    };
    // 播控中心不是 ArkUI 组件，收不到 coverVersion；按需补全完成后由这里
    // 把补到的封面转交给 session，刷新通知栏/锁屏的 mediaImage。
    CoverRepo.get().addFilledListener((key: string, url: string): void => {
      const cur = this.current;
      if (cur.name.length > 0 && CoverRepo.keyOf(cur) === key) {
        this.session.refreshCover(cur, url).catch(() => {
        });
      }
    });
    this.session.init(context, handler).catch(() => {
      console.error('[Player] 播控中心初始化失败');
    });
  }

  setLocalPathProvider(provider: (song: SongInfo) => string): void {
    this.localPathProvider = provider;
  }

  onChange(listener: () => void): void {
    this.listeners.push(listener);
  }

  offChange(listener: () => void): void {
    this.listeners = this.listeners.filter((item: () => void): boolean => item !== listener);
  }

  private static toMode(value: number): PlayMode {
    if (value === 0) {
      return PlayMode.ORDER;
    }
    if (value === 2) {
      return PlayMode.LOOP_ONE;
    }
    if (value === 3) {
      return PlayMode.SHUFFLE;
    }
    return PlayMode.LOOP_LIST;
  }

  /** 上次广播的「歌 + 播放态」指纹，用来过滤掉高频的进度通知 */
  private lastTick: string = '';

  private notify(): void {
    for (const listener of this.listeners) {
      listener();
    }
    // 列表里的「正在播放」高亮靠这个刷新。
    // 进度更新每秒都会触发 notify，只有指纹变了才广播，避免整列表重建。
    const tick: string = String(this.current.source) + '_' + String(this.current.id) + '_' +
      (this.isPlaying() ? '1' : '0');
    if (tick !== this.lastTick) {
      this.lastTick = tick;
      AppStorage.setOrCreate('playerVersion', Date.now());
    }
  }

  /* ---------------- 状态读取 ---------------- */
  getSong(): SongInfo {
    return this.current;
  }

  getQueue(): SongInfo[] {
    return this.queue;
  }

  getIndex(): number {
    return this.index;
  }

  isPlaying(): boolean {
    return this.playing;
  }

  isLoading(): boolean {
    return this.loading;
  }

  getPosition(): number {
    return this.position;
  }

  getDuration(): number {
    return this.duration > 0 ? this.duration : this.current.duration * 1000;
  }

  getMode(): PlayMode {
    return this.mode;
  }

  getQuality(): string {
    return this.quality;
  }

  /** 实际音质；还没解析出来时回落到请求音质 */
  getActualQuality(): string {
    return this.actualQuality.length > 0 ? this.actualQuality : this.quality;
  }

  getError(): string {
    return this.errorText;
  }

  /**
   * 播放失败的出口。以前 errorText 只在播放页里显示，
   * 在列表点歌（不跳播放页）失败时界面上没有任何反馈——
   * 迷你条从转圈变回播放键，用户只会觉得"点了没反应"。外壳注册后弹轻提示。
   */
  setErrorReporter(reporter: (message: string) => void): void {
    this.errorReporter = reporter;
  }

  getSourceFrom(): string {
    return this.sourceFrom;
  }

  getSourceKind(): string {
    return this.sourceKind;
  }

  getLyric(): LyricDoc {
    return this.lyric;
  }

  isLyricLoading(): boolean {
    return this.lyricLoading;
  }

  hasSong(): boolean {
    return this.current.id.length > 0;
  }

  /* ---------------- 队列 ---------------- */
  async playQueue(list: SongInfo[], index: number): Promise<void> {
    if (list.length === 0 || index < 0 || index >= list.length) {
      return;
    }
    this.queue = list.slice();
    this.index = index;
    this.failStreak = 0;
    this.persistQueue(true);
    await this.playCurrent();
  }

  async playSong(song: SongInfo): Promise<void> {
    await this.playQueue([song], 0);
  }

  /** 下一首播放：插到当前曲目之后 */
  addNext(song: SongInfo): void {
    if (this.queue.length === 0 || this.index < 0) {
      this.playSong(song).catch(() => {
      });
      return;
    }
    this.queue.splice(this.index + 1, 0, song);
    this.persistQueue(true);
    this.notify();
  }

  addToQueue(songs: SongInfo[]): void {
    for (const song of songs) {
      this.queue.push(song);
    }
    this.persistQueue(true);
    this.notify();
  }

  /** 跳到队列中的某一首（队列面板点选用） */
  async jumpTo(index: number): Promise<void> {
    if (index < 0 || index >= this.queue.length) {
      return;
    }
    this.index = index;
    this.failStreak = 0;
    await this.playCurrent();
  }

  removeAt(index: number): void {
    if (index < 0 || index >= this.queue.length) {
      return;
    }
    this.queue.splice(index, 1);
    if (index < this.index) {
      this.index--;
    } else if (index === this.index) {
      if (this.queue.length === 0) {
        this.index = -1;
        this.current = emptySong();
        this.releasePlayer().catch(() => {
        });
      } else {
        // 删掉的正是正在播放的这首：原位置顶上来的就是「下一首」，直接播它。
        // 旧实现只在越界时才换歌，删队列中间那首会变成
        // 「队列里已经没这首了，界面上却还在放它，也找不到高亮行」。
        if (this.index >= this.queue.length) {
          this.index = 0;
        }
        this.playCurrent().catch(() => {
        });
      }
    }
    this.persistQueue(true);
    this.notify();
  }

  /* ---------------- 播放控制 ---------------- */
  async playCurrent(): Promise<void> {
    const song = this.queue[this.index];
    if (song === undefined) {
      return;
    }
    const token = ++this.token;
    this.current = song;
    PlayStats.get().onSongStart(song);
    // 冷启动恢复播放、或直接从播放页切歌时，也要确保缺封面的歌开始后台补全
    CoverRepo.get().ensure(song);
    this.playing = false;
    this.loading = true;
    this.errorText = '';
    this.sourceFrom = '';
    this.sourceKind = 'normal';
    this.switchCount = 0;
    this.lastUrl = '';
    const key: string = song.id + '@' + song.source;
    if (this.resumeKey.length > 0 && key === this.resumeKey && this.resumeSeek > 0) {
      // 冷启动恢复：接上次位置。与「自动续播」解耦，关掉自动续播后
      // 手动点播放也从上次位置继续，不然开关看起来像没生效
      this.pendingSeek = this.resumeSeek;
      this.position = this.resumeSeek;
    } else {
      this.position = 0;
    }
    this.resumeKey = '';
    this.resumeSeek = 0;
    this.duration = song.duration * 1000;
    this.preloadDone = false;
    this.lyric = emptyLyric();
    this.lyricLoading = true;
    this.notify();
    this.session.updateSong(song).catch(() => {
    });
    this.pushQueue();
    Library.get().addHistory(song);
    this.loadLyric(song, token);

    // 切歌瞬间就停掉上一首。取链是异步的，旧播放器必须在这里释放，
    // 不能等到 prepare()（那要等新链接就绪），否则取链那几秒里一直在放上一首。
    // 旧播放器的回调都带旧 token，token 已递增，不会污染新状态。
    // 总超时也从点击就开始算，覆盖「取链 + 播放器准备」整段，避免卡住时无限转圈。
    this.startPrepareTimer(token);
    await this.releasePlayer();
    if (token !== this.token) {
      return;
    }

    const localPath = this.resolveLocalPath(song);
    if (localPath.length > 0) {
      this.actualQuality = '';
      this.sourceFrom = '本地文件';
      this.sourceKind = 'local';
      await this.prepare('', localPath, token);
      return;
    }
    try {
      const result = await Resolver.get().resolve(song, this.quality);
      if (token !== this.token) {
        return;
      }
      this.actualQuality = result.quality;
      this.sourceFrom = result.from;
      this.lastUrl = result.url;
      // result.from 在插件替补时已由 Resolver 追加「· 插件替补」，这里只记类型
      this.sourceKind = result.altSong !== undefined ? 'substitute' : 'normal';
      if (result.altSong !== undefined) {
        this.sourceFrom = result.from + ' · ' + result.altSong.singer;
      }
      await this.prepare(result.url, '', token);
    } catch (e) {
      if (token !== this.token) {
        return;
      }
      const message = e instanceof Error ? (e as Error).message : String(e);
      this.handleFail(message);
    }
  }

  private resolveLocalPath(song: SongInfo): string {
    if (this.localPathProvider !== null) {
      const path = this.localPathProvider(song);
      if (path.length > 0) {
        return path;
      }
    }
    if (song.source === 'local' && song.url.length > 0 && song.url.startsWith('/')) {
      return song.url;
    }
    return '';
  }

  private async loadLyric(song: SongInfo, token: number): Promise<void> {
    this.lyricLoading = true;
    this.notify();
    const doc = await LyricRepo.get().get(song);
    if (token !== this.token) {
      return;
    }
    this.lyric = doc;
    this.lyricLoading = false;
    this.notify();
    this.session.setLyric(Player.toLrc(doc)).catch(() => {
    });
  }

  /** 把解析后的歌词还原成标准 LRC，交给播控中心按播放进度滚动 */
  private static toLrc(doc: LyricDoc): string {
    if (doc.plain || doc.lines.length === 0) {
      return '';
    }
    let out = '';
    for (const line of doc.lines) {
      if (line.time < 0 || line.text.length === 0) {
        continue;
      }
      out += '[' + LyricRepo.lrcTime(line.time) + ']' + line.text + '\n';
    }
    return out;
  }

  /** 手动搜索歌词选中后直接应用（不重跑自动链路） */
  setLyric(doc: LyricDoc): void {
    this.lyric = doc;
    this.lyricLoading = false;
    this.notify();
    this.session.setLyric(Player.toLrc(doc)).catch(() => {
    });
  }

  /**
   * 手动重新拉歌词。之前歌词页的空态只能干等，没有重试入口；
   * 清掉当前这首的缓存再走一次完整回退链（音源 → 平台 → LRCLIB）。
   */
  retryLyric(): void {
    const song = this.current;
    if (song.id.length === 0) {
      return;
    }
    LyricRepo.get().invalidate(song);
    this.lyric = emptyLyric();
    this.lyricLoading = true;
    this.notify();
    this.loadLyric(song, this.token);
  }

  async toggle(): Promise<void> {
    if (this.player === null) {
      if (this.current.id.length > 0) {
        await this.playCurrent();
      }
      return;
    }
    if (this.playing) {
      this.pause();
    } else {
      this.play();
    }
  }

  play(): void {
    if (this.player !== null) {
      this.player.play().catch(() => {
      });
      return;
    }
    if (this.current.id.length > 0) {
      this.playCurrent().catch(() => {
      });
    }
  }

  pause(): void {
    if (this.player !== null && this.playing) {
      this.player.pause().catch(() => {
      });
    }
  }

  seek(ms: number): void {
    if (this.player === null) {
      return;
    }
    const target = Math.max(0, Math.min(ms, this.getDuration()));
    try {
      this.player.seek(target);
      this.position = target;
      this.notify();
      this.pushState();
      // 拖完就退出也可能被系统直接回收，位置跟着存（拖动中按 800ms 节流）
      if (Date.now() - this.lastPosSave > 800) {
        this.lastPosSave = Date.now();
        this.persistPosition();
      }
    } catch (e) {
      console.warn('[Player] seek 失败 ' + String(e));
    }
  }

  /**
   * @param auto 自动切歌（失败重试 / 播完续播）。
   *   自动路径不能清零失败计数：handleFail 里刚 ++ 完，
   *   next() 又清零的话计数永远到不了 2，整个队列会以 0.9 秒一首无限跳，
   *   既不播也不报错。用户主动切歌才清零。
   */
  async next(auto: boolean = false): Promise<void> {
    if (this.queue.length === 0) {
      return;
    }
    if (!auto) {
      this.failStreak = 0;
    }
    if (this.mode === PlayMode.SHUFFLE) {
      this.index = this.randomIndex();
    } else {
      this.index = (this.index + 1) % this.queue.length;
    }
    await this.playCurrent();
  }

  async prev(auto: boolean = false): Promise<void> {
    if (this.queue.length === 0) {
      return;
    }
    if (!auto) {
      this.failStreak = 0;
    }
    if (this.mode === PlayMode.SHUFFLE) {
      this.index = this.randomIndex();
    } else {
      this.index = (this.index - 1 + this.queue.length) % this.queue.length;
    }
    await this.playCurrent();
  }

  /** 自动续播：顺序模式到最后一首就停 */
  private nextAuto(): void {
    if (this.mode === PlayMode.ORDER && this.index >= this.queue.length - 1) {
      this.playing = false;
      this.session.markIdle().catch(() => {
      });
      this.notify();
      return;
    }
    this.next(true).catch(() => {
    });
  }

  private randomIndex(): number {
    if (this.queue.length <= 1) {
      return 0;
    }
    let next = this.index;
    while (next === this.index) {
      next = Math.floor(Math.random() * this.queue.length);
    }
    return next;
  }

  setMode(mode: PlayMode): void {
    this.mode = mode;
    Store.get().put(PrefKeys.PLAY_MODE, mode);
    this.notify();
  }

  cycleMode(): void {
    let next = PlayMode.LOOP_LIST;
    if (this.mode === PlayMode.LOOP_LIST) {
      next = PlayMode.LOOP_ONE;
    } else if (this.mode === PlayMode.LOOP_ONE) {
      next = PlayMode.SHUFFLE;
    } else if (this.mode === PlayMode.SHUFFLE) {
      next = PlayMode.ORDER;
    } else {
      next = PlayMode.LOOP_LIST;
    }
    this.setMode(next);
  }

  setQuality(quality: string): void {
    // 落盘与全局广播必须在早退守卫之前：设置页摘要、播放页候选档直接读
    // qualityPref，若这里因为「内部值已相同」而 return，AppStorage 就不会更新，
    // 摘要会停在旧值。广播是幂等的，重复写同一个值不会触发多余取链。
    Settings.get().setQuality(quality);
    AppStorage.setOrCreate('qualityPref', quality);
    if (this.quality === quality) {
      return;
    }
    this.quality = quality;
    this.notify();
    if (this.current.id.length > 0 && this.current.source !== 'local') {
      this.reload();
    }
  }

  /** 播放页失败面板：上次取链问了哪些音源、各自为什么没成 */
  getFailDetails(): FailDetail[] {
    return Resolver.get().getLastFailure();
  }

  /** 上次取链实际参与的音源数 */
  getFailCandidateCount(): number {
    return Resolver.get().getLastCandidateCount();
  }

  /** 当前这首还剩几条「别的音源给过、还没试」的链接 */
  getAlternateCount(): number {
    if (this.current.id.length === 0) {
      return 0;
    }
    return Resolver.get().alternateCount(this.current);
  }

  /**
   * 失败面板上的「换个音源再试」。
   *
   * 有备用链接就直接换下一条 —— 取链时十几个源都给过地址，竞速只用了最快那条，
   * 重新把所有音源问一遍既慢又白添请求；只有备用池空了才真的重新取链。
   */
  retryWithAnotherSource(): void {
    if (this.current.id.length === 0) {
      return;
    }
    const alt = Resolver.get().takeAlternative(this.current, this.lastUrl);
    if (alt === null) {
      this.reload();
      return;
    }
    this.token++;
    const token = this.token;
    this.switchCount++;
    this.loading = true;
    this.playing = false;
    this.errorText = '';
    this.sourceFrom = alt.from + ' · 手动换源';
    this.sourceKind = 'manual';
    this.actualQuality = alt.quality;
    this.lastUrl = alt.url;
    this.notify();
    this.startPrepareTimer(token);
    this.releasePlayer().then((): void => {
      if (token === this.token) {
        this.prepare(alt.url, '', token).catch(() => {
        });
      }
    }).catch(() => {
    });
  }

  /** 重新取链（换音质 / 手动换源后） */
  reload(): void {
    if (this.current.id.length === 0) {
      return;
    }
    const resume = this.position;
    Resolver.get().clearCache();
    this.pendingSeek = resume;
    this.playCurrent().catch(() => {
    });
  }

  /* ---------------- AVPlayer ---------------- */
  private async prepare(url: string, localPath: string, token: number): Promise<void> {
    // 旧播放器已在 playCurrent 取链前释放，这里直接创建新实例
    let player: media.AVPlayer;
    try {
      player = await media.createAVPlayer();
    } catch (e) {
      this.handleFail('播放器初始化失败');
      return;
    }
    if (token !== this.token) {
      player.release();
      return;
    }
    this.player = player;
    try {
      player.audioRendererInfo = {
        usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
        rendererFlags: 0
      };
      player.audioInterruptMode = Settings.get().ignoreInterrupt() ?
        audio.InterruptMode.INDEPENDENT_MODE : audio.InterruptMode.SHARE_MODE;
    } catch (e) {
      console.warn('[Player] 音频流设置失败 ' + String(e));
    }
    player.on('stateChange', (state: media.AVPlayerState, reason: media.StateChangeReason) => {
      if (token !== this.token) {
        return;
      }
      if (state === 'initialized') {
        player.prepare().catch(() => {
          this.handleFail('音频准备失败');
        });
      } else if (state === 'prepared') {
        this.clearPrepareTimer();
        if (player.duration > 0) {
          this.duration = player.duration;
        }
        const resumeAt = this.pendingSeek;
        this.pendingSeek = 0;
        player.play().catch(() => {
          this.handleFail('播放失败');
        });
        if (resumeAt > 0 && Settings.get().rememberPosition()) {
          this.seek(resumeAt);
        }
      } else if (state === 'playing') {
        this.playing = true;
        this.loading = false;
        this.errorText = '';
        this.failStreak = 0;
        this.notify();
        this.onStarted();
        // 正常歌曲等「剩余 60s」再预取；只有时长始终未知（少数平台 duration=0）
        // 时才在开播兜底预取一次，否则没法计算剩余时间。
        if (this.duration <= 0) {
          this.prefetchNext();
        }
      } else if (state === 'paused') {
        this.playing = false;
        this.loading = false;
        this.notify();
        this.pushState();
        // 暂停是「用户此刻停在这里」的明确信号，位置要立刻落盘，
        // 不能等下一次 5 秒窗口（那之间被系统回收就白停了）
        this.persistPosition();
        this.persistQueue(false);
        PlayStats.get().flush();
        this.scheduleBackgroundStop();
      } else if (state === 'completed') {
        this.playing = false;
        // 一首歌自然播到结尾：记一次完播。必须在 nextAuto() 切歌之前取 this.current，
        // 否则统计到的是下一首。单曲循环走 seek(0) 不切歌，也算一次完整听完。
        PlayStats.get().onCompleted(this.current);
        this.notify();
        this.persistQueue(false);
        if (this.mode === PlayMode.LOOP_ONE) {
          this.seek(0);
          player.play().catch(() => {
          });
        } else {
          this.nextAuto();
        }
      } else if (state === 'error') {
        this.handleFail('播放出错（' + reason.toString() + '）');
      }
    });
    player.on('timeUpdate', (time: number) => {
      if (token !== this.token) {
        return;
      }
      this.position = time;
      PlayStats.get().onProgress(time, this.playing, this.current);
      if (this.duration === 0) {
        this.duration = player.duration;
      }
      // 弱网预加载：本首进入最后 60 秒时，提前把下一首的取链跑完写进缓存。
      // 每首只触发一次；切歌时 preloadDone 复位。关掉开关就完全不发预取请求。
      if (!this.preloadDone && this.duration > 0 && this.duration - time <= PRELOAD_LEAD_MS) {
        this.preloadDone = true;
        this.prefetchNext();
      }
      this.notify();
      const now = Date.now();
      if (now - this.lastStatePush > 1200) {
        this.lastStatePush = now;
        this.pushState();
      }
      if (now - this.lastPosSave > 5000) {
        this.lastPosSave = now;
        this.persistPosition();
      }
    });
    player.on('error', (err: BusinessError) => {
      console.error('[Player] error ' + (err.message ?? ''));
    });
    player.on('audioInterrupt', (event: audio.InterruptEvent) => {
      if (token !== this.token || Settings.get().ignoreInterrupt()) {
        return;
      }
      if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE ||
        event.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP) {
        this.resumeAfterInterrupt = this.playing;
        if (this.playing) {
          player.pause().catch(() => {
          });
        }
      } else if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_RESUME) {
        if (this.resumeAfterInterrupt) {
          this.resumeAfterInterrupt = false;
          player.play().catch(() => {
          });
        }
      }
    });
    try {
      if (localPath.length > 0) {
        const file = fs.openSync(localPath, fs.OpenMode.READ_ONLY);
        const size = fs.statSync(file.fd).size;
        this.localFile = file;
        player.fdSrc = { fd: file.fd, offset: 0, length: size };
      } else {
        player.url = url;
      }
    } catch (e) {
      this.handleFail('无效的播放链接');
    }
  }

  private startPrepareTimer(token: number): void {
    this.clearPrepareTimer();
    // 懒人模式要并发问所有音源 / 平台 / 插件，30s 会被总超时先掐断，
    // 导致「明明还有源没问完就报加载超时」。给它留出足够的寻源时间。
    const timeout: number = Settings.get().smartHunt() ? 60000 : PREPARE_TIMEOUT;
    this.prepareTimer = setTimeout(() => {
      if (token === this.token && this.loading && !this.playing) {
        this.handleFail('加载超时，请检查网络或换源');
      }
    }, timeout);
  }

  private clearPrepareTimer(): void {
    if (this.prepareTimer !== -1) {
      clearTimeout(this.prepareTimer);
      this.prepareTimer = -1;
    }
  }

  private handleFail(message: string): void {
    this.clearPrepareTimer();
    // 作废在途的异步取链：超时/失败后不能让稍后到达的结果又去 prepare 播放
    this.token++;
    const token = this.token;
    // 播放器阶段失败（prepare / 播放出错 / 加载超时）先换其它音源给的链接。
    // 取链时十几个音源都给了地址，竞速只用了最快那条；那条一旦播不了，
    // 以前就直接报错跳歌，用户看到的就是「只试了一个源」。
    if (this.switchCount < MAX_SOURCE_SWITCH && this.current.source !== 'local' &&
      this.lastUrl.length > 0) {
      const alt = Resolver.get().takeAlternative(this.current, this.lastUrl);
      if (alt !== null) {
        this.switchCount++;
        this.loading = true;
        this.playing = false;
        this.errorText = '';
        this.sourceFrom = alt.from + ' · 换源 ' + this.switchCount.toString() + '/' +
          MAX_SOURCE_SWITCH.toString();
        this.sourceKind = 'switch';
        this.actualQuality = alt.quality;
        this.lastUrl = alt.url;
        this.notify();
        this.startPrepareTimer(token);
        this.releasePlayer().then((): void => {
          if (token === this.token) {
            this.prepare(alt.url, '', token).catch(() => {
            });
          }
        }).catch(() => {
        });
        return;
      }
    }
    this.loading = false;
    this.playing = false;
    this.errorText = message;
    this.notify();
    this.session.markIdle().catch(() => {
    });
    // 懒人模式：全源 / 全平台都找过了，失败原因已经很明确，不能再静默跳歌 ——
    // 连跳两首才提示会让「所有音源都给不到 FLAC」这条信息根本传不到用户。
    // 这里停下并立刻报出原因，下一首由用户自己决定。
    if (!Settings.get().smartHunt() && this.failStreak < 2 && this.queue.length > 1) {
      // 还能再试下一首，先不打扰；真停下时再说明原因
      this.failStreak++;
      setTimeout(() => {
        // 必须走自动路径，否则 next() 会把 failStreak 抹掉，形成无限跳歌
        this.next(true).catch(() => {
        });
      }, 900);
    } else {
      this.failStreak = 0;
      if (this.errorReporter !== null) {
        this.errorReporter(message);
      }
    }
  }

  private onStarted(): void {
    if (this.pauseTimer !== -1) {
      clearTimeout(this.pauseTimer);
      this.pauseTimer = -1;
    }
    this.pushState();
    const context = this.context;
    if (context !== null) {
      this.bgTask.start(context).catch(() => {
      });
    }
  }

  private scheduleBackgroundStop(): void {
    if (this.pauseTimer !== -1) {
      clearTimeout(this.pauseTimer);
    }
    this.pauseTimer = setTimeout(() => {
      this.pauseTimer = -1;
      const context = this.context;
      if (context !== null && !this.playing) {
        this.bgTask.stop(context).catch(() => {
        });
      }
    }, PAUSE_RELEASE_DELAY);
  }

  private pushState(): void {
    this.session.updatePlaybackState(this.playing, this.position, this.getDuration()).catch(() => {
    });
  }

  private pushQueue(): void {
    if (this.queue.length === 0) {
      return;
    }
    const first = this.queue[0];
    const last = this.queue[this.queue.length - 1];
    const signature = this.queue.length.toString() + '|' + first.id + '|' + last.id + '|' + this.index.toString();
    if (signature === this.queueSignature) {
      return;
    }
    this.queueSignature = signature;
    this.session.updateQueue(this.queue, this.index).catch(() => {
    });
  }

  private prefetchNext(): void {
    if (!Settings.get().preloadNext()) {
      return;
    }
    if (this.queue.length <= 1 || this.index < 0) {
      return;
    }
    const nextIndex = (this.index + 1) % this.queue.length;
    const song = this.queue[nextIndex];
    if (song === undefined || song.id === this.current.id || song.source === 'local') {
      return;
    }
    Resolver.get().resolve(song, this.quality).catch(() => {
    });
  }

  private async releasePlayer(): Promise<void> {
    const player = this.player;
    this.player = null;
    const file = this.localFile;
    this.localFile = null;
    if (file !== null) {
      try {
        fs.closeSync(file);
      } catch (e) {
        // 已关闭
      }
    }
    if (player !== null) {
      // 先发 pause 让声音立刻断（不等 reset 走完），旧状态回调会被 token 守卫挡掉
      player.pause().catch(() => {
      });
      try {
        await player.reset();
        await player.release();
      } catch (e) {
        // 已释放
      }
    }
  }

  /* ---------------- 持久化 / 恢复 ---------------- */
  /**
   * 队列持久化只存 200 首（Preferences 不适合塞几十万字节）。
   * 旧实现固定取前 200 首、却存了整个队列的 index：播到第 250 首时退出，
   * 下次进来 index 被 restore() clamp 到 199 —— 当前曲目错位，队列看起来「跳回去了」。
   * 改成围绕当前曲目的滑动窗口，index 换算到窗口内，播到哪都还原得回来。
   */
  /**
   * 播放中每 5 秒只刷「播放位置」。
   * 以前这里调的是 persistQueue(false)，而它内部要求 `now - lastPersist >= 4000`，
   * 调用方却先把 lastPersist 更新成了 now —— 判断恒为 false，播放中一次都没落盘。
   * 结果：正常退出能记住进度，被系统回收 / 强杀后再进来，位置退回上次暂停点。
   * 这里只写 LAST_POS，不重写 200 首队列，避免每 5 秒一次大 JSON 序列化。
   */
  private persistPosition(): void {
    if (this.current.id.length === 0) {
      return;
    }
    Store.get().putLater(PrefKeys.LAST_POS, this.position);
    Store.get().flush();
  }

  private persistQueue(immediate: boolean): void {
    const now = Date.now();
    if (!immediate && now - this.lastPersist < 4000) {
      return;
    }
    this.lastPersist = now;
    const cap = 200;
    let start = 0;
    if (this.queue.length > cap) {
      start = Math.floor(this.index - cap / 2);
      if (start < 0) {
        start = 0;
      }
      const maxStart = this.queue.length - cap;
      if (start > maxStart) {
        start = maxStart;
      }
    }
    Store.get().putLater(PrefKeys.QUEUE, JSON.stringify(this.queue.slice(start, start + cap)));
    Store.get().putLater(PrefKeys.QUEUE_INDEX, this.index - start);
    if (this.current.id.length > 0) {
      Store.get().putLater(PrefKeys.LAST_SONG, JSON.stringify(this.current));
      Store.get().putLater(PrefKeys.LAST_POS, this.position);
    }
    // 四个键一次落盘，不再每个键各 flush 一次
    Store.get().flush();
  }

  async restore(): Promise<void> {
    if (this.current.id.length > 0) {
      return;
    }
    const text = Store.get().getString(PrefKeys.QUEUE, '[]');
    let list: SongInfo[] = [];
    try {
      list = JSON.parse(text) as SongInfo[];
    } catch (e) {
      list = [];
    }
    if (list.length === 0) {
      const last = Store.get().getString(PrefKeys.LAST_SONG, '');
      if (last.length > 0) {
        try {
          list = [JSON.parse(last) as SongInfo];
        } catch (e) {
          list = [];
        }
      }
    }
    if (list.length === 0) {
      return;
    }
    this.queue = list;
    this.index = Math.max(0, Math.min(Store.get().getNumber(PrefKeys.QUEUE_INDEX, 0), list.length - 1));
    this.current = list[this.index];
    this.duration = this.current.duration * 1000;
    const saved: number = Settings.get().rememberPosition() ? Store.get().getNumber(PrefKeys.LAST_POS, 0) : 0;
    // 恢复点落在最后 5 秒内就从 0 开始：否则一进应用就「播完」跳下一首，
    // 看起来像进度记错了，其实是记太准
    const usable: boolean = saved > 0 && (this.duration <= 0 || saved < this.duration - 5000);
    this.position = usable ? saved : 0;
    // 记下「哪首、从哪继续」：真正开始播时消费一次。
    // 不能只在自动续播分支里设 pendingSeek —— 关掉自动续播后手动点播放就没有进度了。
    this.resumeKey = usable ? (this.current.id + '@' + this.current.source) : '';
    this.resumeSeek = usable ? saved : 0;
    this.notify();
    this.session.updateSong(this.current).catch(() => {
    });
    this.pushQueue();
    if (Settings.get().autoPlay()) {
      await this.autoResume();
    }
  }

  /**
   * 冷启动自动续播。
   * 音源沙箱是界面里的 WebView，App.init 结束时脚本往往还没挂好：
   * 这时直接取链必然拿不到地址，失败两次就跳下一首——用户看到的是
   * 「续播了，但放的是另一首」。本地文件不需要音源，直接放；在线歌曲
   * 等 sourcesReady 再开播，等待期间显示准备中，最长 8 秒。
   */
  private async autoResume(): Promise<void> {
    const song: SongInfo = this.current;
    const token: number = this.token;
    if (this.resolveLocalPath(song).length === 0 && AppStorage.get<boolean>('sourcesReady') !== true) {
      this.loading = true;
      this.notify();
      await this.waitSourcesReady(8000);
      // 等待期间用户自己点了别的歌 / 点了播放：让那条路径负责，别在这里重复开播
      if (this.token !== token) {
        return;
      }
    }
    if (this.current.id !== song.id || this.current.source !== song.source) {
      return;
    }
    await this.playCurrent();
  }

  private waitSourcesReady(maxMs: number): Promise<void> {
    return new Promise<void>((resolve) => {
      const started: number = Date.now();
      const timer: number = setInterval(() => {
        if (AppStorage.get<boolean>('sourcesReady') === true || Date.now() - started >= maxMs) {
          clearInterval(timer);
          resolve();
        }
      }, 200);
    });
  }

  async shutdown(): Promise<void> {
    this.token++;
    this.persistQueue(true);
    this.playing = false;
    if (this.pauseTimer !== -1) {
      clearTimeout(this.pauseTimer);
      this.pauseTimer = -1;
    }
    await this.releasePlayer();
    const context = this.context;
    if (context !== null) {
      await this.bgTask.stop(context);
    }
    await this.session.destroy();
  }

  applyInterruptMode(): void {
    const player = this.player;
    if (player === null) {
      return;
    }
    try {
      player.audioInterruptMode = Settings.get().ignoreInterrupt() ?
        audio.InterruptMode.INDEPENDENT_MODE : audio.InterruptMode.SHARE_MODE;
    } catch (e) {
      console.warn('[Player] 切换打断模式失败');
    }
  }
}

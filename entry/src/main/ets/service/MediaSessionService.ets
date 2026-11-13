import { avSession } from '@kit.AVSessionKit';
import { image } from '@kit.ImageKit';
import { http } from '@kit.NetworkKit';
import { common, wantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SongInfo } from '../common/Models';
import { CoverRepo } from '../core/CoverRepo';

/**
 * 播控中心（系统媒体面板 / 锁屏 / 耳机线控）下发的控制指令。
 */
export interface PlaybackCommandHandler {
  onPlayCommand: () => void;
  onPauseCommand: () => void;
  onNextCommand: () => void;
  onPrevCommand: () => void;
  onSeekCommand: (positionMs: number) => void;
  onStopCommand: () => void;
}

/**
 * AVSession 封装：把当前歌曲信息、播放状态同步给系统播控中心，
 * 并接收播控中心发回的控制指令。
 */
export class MediaSessionService {
  private session: avSession.AVSession | null = null;
  private handler: PlaybackCommandHandler | null = null;
  private ready: boolean = false;
  private assetId: string = '';
  private pendingSong: SongInfo | null = null;
  private coverCache: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
  private context: common.UIAbilityContext | null = null;
  /** 每次切歌自增，用于丢弃迟到的旧封面请求，防止快速切歌时被旧结果覆盖 */
  private songToken: number = 0;
  private currentSong: SongInfo | null = null;
  /** 当前已成功写给播控中心的封面 URL，避免重复 set */
  private coverUrl: string = '';
  /** 「暂无封面」占位图：必须显式传 mediaImage，否则系统会沿用上一首的封面 */
  private placeholder: image.PixelMap | null = null;
  /** 最近一次下发的封面，回写时长/歌词时复用，避免重复下载 */
  private lastCover: image.PixelMap | null = null;
  /** 播放器 prepare 后才有真实时长；song.duration 为 0 的平台靠它补上总时长 */
  private durationMs: number = 0;
  /** 当前歌词（标准 LRC 全文），播控中心据此按进度滚动 */
  private lyricText: string = '';

  isActive(): boolean {
    return this.ready;
  }

  async init(context: common.UIAbilityContext, handler: PlaybackCommandHandler): Promise<void> {
    this.handler = handler;
    this.context = context;
    this.ensurePlaceholder();
    if (this.session !== null) {
      return;
    }
    try {
      const session = await avSession.createAVSession(context, 'YinZhan', 'audio');
      this.session = session;
      session.on('play', () => {
        this.firePlay();
      });
      session.on('pause', () => {
        this.firePause();
      });
      session.on('stop', () => {
        this.fireStop();
      });
      session.on('playNext', () => {
        this.fireNext();
      });
      session.on('playPrevious', () => {
        this.firePrev();
      });
      session.on('seek', (time: number) => {
        const handler0 = this.handler;
        if (handler0 !== null) {
          handler0.onSeekCommand(time);
        }
      });
      session.on('fastForward', (time?: number) => {
        const handler0 = this.handler;
        if (handler0 !== null) {
          handler0.onSeekCommand(time !== undefined ? time : 15000);
        }
      });
      session.on('rewind', (time?: number) => {
        const handler0 = this.handler;
        if (handler0 !== null) {
          handler0.onSeekCommand(time !== undefined ? time : 15000);
        }
      });
      try {
        const agent = await this.buildLaunchAgent(context);
        await session.setLaunchAbility(agent);
      } catch (e) {
        console.warn('[LX] setLaunchAbility 失败: ' + String(e));
      }
      await session.activate();
      this.ready = true;
      console.info('[LX] 播控中心会话已激活');
      const pending = this.pendingSong;
      if (pending !== null) {
        this.pendingSong = null;
        await this.updateSong(pending);
      }
    } catch (e) {
      const err = e as BusinessError;
      console.error('[LX] 播控中心会话创建失败: ' + err.code + ' ' + err.message);
    }
  }

  private firePlay(): void {
    const handler = this.handler;
    if (handler !== null) {
      handler.onPlayCommand();
    }
  }

  private firePause(): void {
    const handler = this.handler;
    if (handler !== null) {
      handler.onPauseCommand();
    }
  }

  private fireStop(): void {
    const handler = this.handler;
    if (handler !== null) {
      handler.onStopCommand();
    }
  }

  private fireNext(): void {
    const handler = this.handler;
    if (handler !== null) {
      handler.onNextCommand();
    }
  }

  private firePrev(): void {
    const handler = this.handler;
    if (handler !== null) {
      handler.onPrevCommand();
    }
  }

  private async buildLaunchAgent(context: common.UIAbilityContext): Promise<object> {
    const info: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: context.abilityInfo.bundleName,
          abilityName: 'EntryAbility'
        }
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    return await wantAgent.getWantAgent(info);
  }

  /** 更新播控中心展示的歌曲信息（标题 / 歌手 / 专辑 / 封面 / 时长） */
  async updateSong(song: SongInfo): Promise<void> {
    const session = this.session;
    if (session === null || !this.ready) {
      this.pendingSong = song;
      return;
    }
    const token = ++this.songToken;
    this.currentSong = song;
    this.coverUrl = '';
    this.lastCover = null;
    // 切歌先清空上一首的歌词与时长，等新数据回来再填
    this.lyricText = '';
    this.durationMs = song.duration > 0 ? song.duration * 1000 : 0;
    this.assetId = this.buildAssetId(song);

    // 阶段 1：立刻推送文字 + 显式封面。
    // setAVMetadata 是「部分字段」语义（官方注释：can fill in partially
    // supported properties），省略 mediaImage 系统会保留上一首的封面 ——
    // 这正是通知栏显示旧封面的根因。哪怕暂时没图也必须传占位图。
    await this.applyMetadata(token, song, this.placeholder);

    // 阶段 2：异步取真实封面，成功后再刷一次。切歌瞬间 song.cover 常常还是
    // 空的（CoverRepo 按需补全为异步），所以也查一次补全缓存；都没有就等
    // refreshCover() 在补全完成后回调。
    const url = this.coverUrlFor(song);
    if (url.length === 0) {
      return;
    }
    this.loadCover(url).then((cover: image.PixelMap | null): void => {
      if (cover === null || token !== this.songToken) {
        return;
      }
      this.coverUrl = url;
      this.applyMetadata(token, song, cover).catch(() => {
      });
    });
  }

  /** 后台按需补全拿到封面后，只刷新当前这首的播控中心封面 */
  async refreshCover(song: SongInfo, url: string): Promise<void> {
    const current = this.currentSong;
    if (current === null || !this.ready || url.length === 0 || this.coverUrl === url) {
      return;
    }
    if (CoverRepo.keyOf(current) !== CoverRepo.keyOf(song)) {
      return;
    }
    const token = this.songToken;
    const cover = await this.loadCover(url);
    if (cover === null || token !== this.songToken) {
      return;
    }
    this.coverUrl = url;
    await this.applyMetadata(token, current, cover);
  }

  /**
   * 歌词加载完成后把标准 LRC 全文交给播控中心，系统按播放进度自行滚动。
   * 切歌时 updateSong 会把 lyricText 清空，再下发即清除上一首的歌词。
   */
  async setLyric(lrc: string): Promise<void> {
    const current = this.currentSong;
    if (current === null || !this.ready) {
      return;
    }
    const text = lrc.length > 8192 ? lrc.substring(0, 8192) : lrc;
    if (text === this.lyricText) {
      return;
    }
    this.lyricText = text;
    await this.applyMetadata(this.songToken, current, this.lastCover);
  }

  /** 优先用歌曲自带封面，没有就查按需补全缓存 */
  private coverUrlFor(song: SongInfo): string {
    if (song.cover.length > 0) {
      return song.cover;
    }
    return CoverRepo.get().lookup(CoverRepo.keyOf(song));
  }

  /**
   * 每次都构造完整元数据再下发：mediaImage 恒定提供、lyric 显式清空，
   * 杜绝「部分字段」语义下沿用上一首的内容；token 校验让快速切歌时
   * 迟到的旧封面直接作废，不会把上一首的标题/封面盖回来。
   */
  private async applyMetadata(token: number, song: SongInfo,
    cover: image.PixelMap | null): Promise<void> {
    const session = this.session;
    if (session === null || !this.ready || token !== this.songToken) {
      return;
    }
    const fallback: image.PixelMap | string = this.placeholder ?? '';
    this.lastCover = cover;
    const metadata: avSession.AVMetadata = {
      assetId: this.assetId,
      title: song.name,
      artist: song.singer,
      album: song.album,
      // 优先用播放器实测时长：很多平台搜索/榜单条目的 duration 是 0，
      // 只写 song.duration 会让播控中心不显示总时长。
      duration: this.durationMs > 0 ? this.durationMs : (song.duration > 0 ? song.duration * 1000 : 0),
      lyric: this.lyricText,
      mediaImage: cover !== null ? cover : fallback
    };
    try {
      await session.setAVMetadata(metadata);
    } catch (e) {
      console.error('[LX] setAVMetadata 失败: ' + String(e));
    }
  }

  /** 把播放队列交给系统，播控中心因此可以显示上一首/下一首 */
  async updateQueue(list: SongInfo[], index: number): Promise<void> {
    const session = this.session;
    if (session === null || !this.ready || list.length <= 1) {
      return;
    }
    const items: avSession.AVQueueItem[] = [];
    const total = Math.min(list.length, 100);
    for (let i = 0; i < total; i++) {
      const item = list[i];
      const description: avSession.AVMediaDescription = {
        assetId: this.buildAssetId(item),
        title: item.name,
        artist: item.singer,
        albumTitle: item.album,
        duration: item.duration > 0 ? item.duration * 1000 : 0
      };
      const queueItem: avSession.AVQueueItem = {
        itemId: i,
        description: description
      };
      items.push(queueItem);
    }
    try {
      await session.setAVQueueItems(items);
    } catch (e) {
      console.warn('[LX] setAVQueueItems 未生效: ' + String(e));
    }
  }

  /** 同步播放状态与进度，系统据此刷新播控中心 */
  async updatePlaybackState(playing: boolean, positionMs: number, durationMs: number): Promise<void> {
    const session = this.session;
    if (session === null || !this.ready) {
      return;
    }
    const current = this.currentSong;
    // 播放器 prepare 后才有真实时长。duration=0 的平台（榜单/搜索条目常见）
    // 以前永远不显示总时长，这里检测到变化就补写回 metadata。
    if (durationMs > 0 && current !== null && Math.abs(durationMs - this.durationMs) > 800) {
      this.durationMs = durationMs;
      this.applyMetadata(this.songToken, current, this.lastCover).catch(() => {
      });
    }
    const position: avSession.PlaybackPosition = {
      elapsedTime: positionMs > 0 ? Math.floor(positionMs) : 0,
      updateTime: Date.now()
    };
    const state: avSession.AVPlaybackState = {
      state: playing ? avSession.PlaybackState.PLAYBACK_STATE_PLAY :
        avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
      speed: 1,
      position: position
    };
    try {
      await session.setAVPlaybackState(state);
    } catch (e) {
      console.warn('[LX] setAVPlaybackState 失败: ' + String(e));
    }
  }

  /** 播放器尚未就绪时，播控中心显示为停止 */
  async markIdle(): Promise<void> {
    const session = this.session;
    if (session === null || !this.ready) {
      return;
    }
    const state: avSession.AVPlaybackState = {
      state: avSession.PlaybackState.PLAYBACK_STATE_STOP,
      speed: 0,
      position: {
        elapsedTime: 0,
        updateTime: Date.now()
      }
    };
    try {
      await session.setAVPlaybackState(state);
    } catch (e) {
      console.warn('[LX] setAVPlaybackState 失败: ' + String(e));
    }
  }

  private buildAssetId(song: SongInfo): string {
    if (song.id.length > 0) {
      return song.source.length > 0 ? song.source + '_' + song.id : song.id;
    }
    return song.name + '_' + song.singer;
  }

  /** 生成「暂无封面」占位图：优先应用图标，失败则退到中性色纯色块 */
  private ensurePlaceholder(): void {
    if (this.placeholder !== null) {
      return;
    }
    try {
      if (this.context !== null) {
        const raw = this.context.resourceManager.getMediaByNameSync('app_icon');
        const buf = raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength) as ArrayBuffer;
        const src = image.createImageSource(buf);
        this.placeholder = src.createPixelMapSync();
        src.release().catch(() => {
        });
        return;
      }
    } catch (e) {
      console.warn('[LX] 占位封面读取失败: ' + String(e));
    }
    try {
      const size = 64;
      const colors = new ArrayBuffer(size * size * 4);
      const view = new Uint8Array(colors);
      for (let i = 0; i < size * size; i++) {
        view[i * 4] = 0x33;
        view[i * 4 + 1] = 0x33;
        view[i * 4 + 2] = 0x3A;
        view[i * 4 + 3] = 0xFF;
      }
      const opts: image.InitializationOptions = {
        size: { width: size, height: size },
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        editable: false
      };
      this.placeholder = image.createPixelMapSync(colors, opts);
    } catch (e) {
      console.warn('[LX] 占位封面生成失败: ' + String(e));
    }
  }

  /**
   * 拉取封面并转成 PixelMap；原 URL 失败时再试一次备用形态
   * （尺寸占位替换 / http↔https 互切）。仍失败返回 null，由调用方用占位图。
   */
  private async loadCover(url: string): Promise<image.PixelMap | null> {
    if (url.length === 0) {
      return null;
    }
    const cached = this.coverCache.get(url);
    if (cached !== undefined) {
      return cached;
    }
    let cover = await this.fetchPixelMap(url);
    if (cover === null) {
      const alt = CoverRepo.alternate(url);
      if (alt.length > 0 && alt !== url) {
        cover = await this.fetchPixelMap(alt);
      }
    }
    if (cover === null) {
      return null;
    }
    if (this.coverCache.size > 8) {
      this.coverCache.clear();
    }
    this.coverCache.set(url, cover);
    return cover;
  }

  private async fetchPixelMap(url: string): Promise<image.PixelMap | null> {
    const client = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        usingCache: true,
        connectTimeout: 8000,
        readTimeout: 8000
      };
      const response = await client.request(url, options);
      if (response.responseCode !== 200) {
        return null;
      }
      const buffer = response.result as ArrayBuffer;
      if (buffer === undefined || buffer.byteLength === 0) {
        return null;
      }
      const source = image.createImageSource(buffer);
      const pixelMap = await source.createPixelMap();
      await source.release();
      return pixelMap;
    } catch (e) {
      console.warn('[LX] 封面加载失败: ' + String(e));
      return null;
    } finally {
      client.destroy();
    }
  }

  /** 应用退出时释放会话 */
  async destroy(): Promise<void> {
    const session = this.session;
    this.session = null;
    this.ready = false;
    this.handler = null;
    if (session === null) {
      return;
    }
    try {
      session.off('play');
      session.off('pause');
      session.off('stop');
      session.off('playNext');
      session.off('playPrevious');
      session.off('seek');
      session.off('fastForward');
      session.off('rewind');
      await session.deactivate();
      await session.destroy();
    } catch (e) {
      console.warn('[LX] 会话释放失败: ' + String(e));
    }
  }
}

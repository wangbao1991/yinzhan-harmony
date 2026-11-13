/**
 * 数据模型（v4）
 *
 * 统一「歌曲 / 歌单 / 榜单 / 歌手 / 歌词 / 音源 / 下载 / 本地」的数据形状，
 * 所有网络层与 UI 层共用，避免各页面各自解释 JSON。
 */

/** 歌曲 */
export interface SongInfo {
  id: string;
  songmid: string;
  hash: string;
  name: string;
  singer: string;
  album: string;
  albumName?: string;
  /** 酷我 MUSIC_x */
  musicrid?: string;
  interval: string;
  /** 平台：kw / tx / wy / kg / mg / local */
  source: string;
  duration: number;
  cover: string;
  lyric: string;
  url: string;
  quality: string;
  /** 专辑 id（QQ 的 albumMid / 网易的 album id） */
  albumId?: string;
  /** 咪咕版权 id */
  copyrightId?: string;
  /** 咪咕歌词直链（搜索结果里自带，可直接下载 LRC 文本） */
  lyricUrl?: string;
  /** 咪咕翻译歌词直链 */
  trcUrl?: string;
  /** 是否 VIP / 付费（部分平台返回） */
  fee?: number;
  /**
   * MusicFree 音源：插件自己 search() 返回的原始 mediaItem 的 JSON 字符串。
   * 播放取链 / 取词时必须原样回传给插件的 getMediaSource() / getLyric()，
   * 否则插件拿不到 bvid、photo.id、manifest 等自定义字段，必然取链失败。
   */
  mfRaw?: string;
}

/** 歌单 / 榜单 / 专辑 / 歌手作品集 的统一描述 */
export interface SheetInfo {
  id: string;
  name: string;
  cover: string;
  description: string;
  /** 平台 id */
  platform: string;
  /** rank / playlist / album / artist / user / favorites / history / local / download */
  kind: string;
  trackCount: number;
  playCount: number;
  creator: string;
  updateTime: string;
  subtitle: string;
  /**
   * 封面备用 URL（可选）：主封面 404 / 是目录路径时切到这张真实图。
   * 酷我榜单 pic 常给死链，v9_pic2 是同响应里榜内歌曲的真实专辑封面。
   */
  coverFallback?: string;
  /** v2.44：MusicFree 插件自己的 sheetItem 原文，供 getMusicSheetInfo 回传 */
  mfRaw?: string;
}

/** 歌单标签 */
export interface SheetTag {
  id: string;
  name: string;
  hot: boolean;
}

/** 歌手 */
export interface ArtistInfo {
  id: string;
  name: string;
  avatar: string;
  platform: string;
  subtitle: string;
  /** v2.44：MusicFree 插件自己的 artistItem 原文，供 getArtistWorks 回传 */
  mfRaw?: string;
}

/** 分页歌曲 */
export interface PagedSongs {
  songs: SongInfo[];
  page: number;
  hasMore: boolean;
  total: number;
}

/** 平台定义 */
export interface PlatformDef {
  id: string;
  name: string;
  short: string;
  color: string;
  gradient: string;
}

/** 歌词行 */
export interface LyricLine {
  /** 秒 */
  time: number;
  text: string;
  trans: string;
}

/** 解析后的歌词 */
export interface LyricDoc {
  lines: LyricLine[];
  raw: string;
  hasTrans: boolean;
  source: string;
  /** 是否为纯文本（无时间轴） */
  plain: boolean;
}

export function emptyLyric(): LyricDoc {
  const doc: LyricDoc = {
    lines: [],
    raw: '',
    hasTrans: false,
    source: '',
    plain: false
  };
  return doc;
}

/**
 * 备份 / 恢复用的音源脚本条目。
 * 元数据与脚本正文一起带走，恢复时写回 files/sources/<id>.js 并重新挂载，
 * 否则「备份了音源」只是一句文案、恢复后全是脚本文件丢失的死链（铁律 2）。
 */
export interface SourceBackupItem {
  id: string;
  name: string;
  fileName: string;
  enabled: boolean;
  order: number;
  version: string;
  description: string;
  updateUrl: string;
  code: string;
  /** 协议类型；老备份没有该字段，恢复时按正文自动识别 */
  kind?: string;
  /** v2.43：脚本声明的动作（含 musicSearch）。老备份没有，恢复时靠 inited 上报 */
  actions?: string[];
  /** v2.43：MusicFree 插件可搜索能力。老备份由 actions 推导 */
  mfSearchable?: boolean;
}

/** 已导入音源（洛雪脚本） */
export interface SourceItem {
  id: string;
  name: string;
  fileName: string;
  /** 沙箱内的文件路径 */
  path: string;
  size: number;
  importedAt: number;
  enabled: boolean;
  /** 排序，越小越优先 */
  order: number;
  version: string;
  description: string;
  updateUrl: string;
  /** 脚本声明的平台 id */
  platforms: string[];
  /** 脚本声明的音质 */
  qualities: string[];
  /** 脚本声明支持的动作（musicUrl / musicSearch / lyric …） */
  actions: string[];
  /** 脚本装载状态：idle / ok / error / checking。只由装载链路写，自检不覆盖 */
  status: string;
  message: string;
  /** 上次自检结论：'' 未自检 / ok / error / checking。v2.43 与 status 分离，
   *  一次取链失败不再把已装载好的插件标成「不可用」 */
  health: string;
  checkedAt: number;
  latency: number;
  /** 自检时因脚本级错误提前跳过的平台数（0 = 三个平台都试过） */
  checkSkipped: number;
  /** 协议：'lx' = 洛雪音源脚本；'musicfree' = MusicFree CommonJS 插件 */
  kind: string;
  /** MusicFree 插件能否 search()（决定它是否出现在搜索源里） */
  mfSearchable: boolean;
}

/** 用户自建歌单 */
export interface UserPlaylist {
  id: string;
  name: string;
  cover: string;
  createdAt: number;
  updatedAt: number;
  songs: SongInfo[];
}

/** 本地音乐 */
export interface LocalSong {
  id: string;
  name: string;
  singer: string;
  album: string;
  duration: number;
  interval: string;
  filePath: string;
  size: number;
  addedAt: number;
  cover: string;
}

/** 下载任务 */
export interface DownloadTask {
  id: string;
  song: SongInfo;
  /** 用户请求的音质 */
  quality: string;
  /** 实际拿到的音质（可能被降级；空串表示还没解析出来） */
  actualQuality: string;
  /** 实际文件格式：flac / mp3 / m4a / ... */
  format: string;
  /** waiting / running / done / failed / paused */
  status: string;
  progress: number;
  received: number;
  total: number;
  path: string;
  error: string;
  createdAt: number;
}

/** 搜索结果 */
export interface SearchPage {
  songs: SongInfo[];
  page: number;
  hasMore: boolean;
}

/** 搜索类型 */
export enum SearchType {
  SONG = 0,
  SHEET = 1,
  ARTIST = 2
}

/** 播放模式 */
export enum PlayMode {
  ORDER = 0,
  LOOP_LIST = 1,
  LOOP_ONE = 2,
  SHUFFLE = 3
}

/** 取链结果 */
export interface ResolveResult {
  url: string;
  from: string;
  /** 实际音质（按真实格式和体积估算，不一定等于请求的） */
  quality: string;
  /** flac / mp3 / m4a / ogg / wav / unknown */
  format: string;
  /** 估算码率，0 表示拿不到 */
  kbps: number;
  headers: Record<string, string>;
  /** 跨平台换源时实际播放的歌曲（为空表示就是原曲） */
  altSong?: SongInfo;
}

/** 音源自检结果 */
export interface SourceHealth {
  sourceId: string;
  sourceName: string;
  ok: boolean;
  latency: number;
  message: string;
  platforms: string[];
  checkedAt: number;
}

/** 音源脚本 inited 上报的平台详情 */
export interface LxSourceDetail {
  id: string;
  name: string;
  qualitys: string[];
}

/** 洛雪脚本原始歌曲字段（宽容解析） */
export interface LxRawSong {
  id?: string;
  name?: string;
  songmid?: string;
  hash?: string;
  title?: string;
  singer?: string;
  artist?: string;
  album?: string;
  albumName?: string;
  albumId?: string;
  albumMid?: string;
  source?: string;
  duration?: number;
  interval?: string;
  cover?: string;
  pic?: string;
  img?: string;
  lyric?: string;
  url?: string;
  quality?: string;
  musicrid?: string;
  copyrightId?: string;
}

export interface LxListResult {
  list?: LxRawSong[];
  total?: number;
  limit?: number;
  page?: number;
}

export interface LxUrlResult {
  url?: string;
  type?: string;
  quality?: string;
}

export interface LxLyricResult {
  lyric?: string;
  tlyric?: string;
  lxlyric?: string;
}

/** 调用音源脚本的参数 */
export interface LxInvokeInfo {
  keyword?: string;
  page?: number;
  limit?: number;
  id?: string;
  quality?: string;
  type?: string;
  source?: string;
  musicInfo?: SongInfo;
  tag?: SheetTag;
  /** v2.44：详情页回传插件自己的 sheetItem / artistItem 原文 */
  mfRaw?: string;
}

/** 页面导航参数 */
export class RankParam {
  platform: string;

  constructor(platform: string) {
    this.platform = platform;
  }
}

export class SheetParam {
  sheet: SheetInfo;

  constructor(sheet: SheetInfo) {
    this.sheet = sheet;
  }
}

export class ArtistParam {
  artist: ArtistInfo;

  constructor(artist: ArtistInfo) {
    this.artist = artist;
  }
}

/** 无参数页面的占位参数（ArkTS 不接受裸对象字面量） */
export class NavParam {
  key: string;

  constructor(key: string = '') {
    this.key = key;
  }
}

export class SearchParam {
  keyword: string;
  type: number;

  constructor(keyword: string, type: number = 0) {
    this.keyword = keyword;
    this.type = type;
  }
}

export function newSong(source: string): SongInfo {
  return {
    id: '',
    songmid: '',
    hash: '',
    name: '',
    singer: '',
    album: '',
    interval: '',
    source: source,
    duration: 0,
    cover: '',
    lyric: '',
    url: '',
    quality: ''
  };
}

export function emptySong(): SongInfo {
  const song = newSong('');
  song.name = '暂无播放';
  song.singer = '选择一首歌曲开始';
  song.quality = '128k';
  return song;
}

export function newSheet(platform: string, kind: string): SheetInfo {
  return {
    id: '',
    name: '',
    cover: '',
    description: '',
    platform: platform,
    kind: kind,
    trackCount: 0,
    playCount: 0,
    creator: '',
    updateTime: '',
    subtitle: ''
  };
}

export function newSource(): SourceItem {
  return {
    id: '',
    name: '',
    fileName: '',
    path: '',
    size: 0,
    importedAt: 0,
    enabled: true,
    order: 0,
    version: '',
    description: '',
    updateUrl: '',
    platforms: [],
    qualities: [],
    actions: [],
    status: 'idle',
    message: '',
    health: '',
    checkedAt: 0,
    latency: 0,
    checkSkipped: 0,
    kind: 'lx',
    mfSearchable: false
  };
}

export function formatTime(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) {
    return '00:00';
  }
  const total = Math.floor(seconds);
  const m = Math.floor(total / 60);
  const s = total % 60;
  const mm = m < 10 ? '0' + m.toString() : m.toString();
  const ss = s < 10 ? '0' + s.toString() : s.toString();
  return mm + ':' + ss;
}

export function formatCount(value: number): string {
  if (value >= 100000000) {
    return (value / 100000000).toFixed(1) + '亿';
  }
  if (value >= 10000) {
    return (value / 10000).toFixed(1) + '万';
  }
  return value.toString();
}

export function intervalToSeconds(interval: string): number {
  const parts = interval.split(':');
  if (parts.length === 2) {
    return Number.parseInt(parts[0]) * 60 + Number.parseInt(parts[1]);
  }
  return 0;
}

export function secondsToInterval(seconds: number): string {
  if (seconds <= 0) {
    return '';
  }
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  const mm = m < 10 ? '0' + m.toString() : m.toString();
  const ss = s < 10 ? '0' + s.toString() : s.toString();
  return mm + ':' + ss;
}

/** 把洛雪脚本返回的原始对象补成 SongInfo（缺字段不报错） */
export function normalizeSong(raw: LxRawSong, defaultSource: string): SongInfo {
  const song = newSong(raw.source ?? defaultSource);
  const name = raw.name ?? raw.title ?? '';
  const singer = raw.singer ?? raw.artist ?? '';
  const id = raw.id ?? raw.songmid ?? raw.hash ?? '';
  song.id = id;
  song.songmid = raw.songmid ?? id;
  song.hash = raw.hash ?? '';
  song.musicrid = raw.musicrid ?? '';
  song.name = name;
  song.singer = singer;
  song.album = raw.album ?? raw.albumName ?? '';
  song.albumName = song.album;
  song.albumId = raw.albumId ?? raw.albumMid ?? '';
  song.copyrightId = raw.copyrightId ?? '';
  song.interval = raw.interval ?? '';
  song.duration = raw.duration !== undefined ? raw.duration : intervalToSeconds(song.interval);
  song.cover = raw.cover ?? raw.pic ?? raw.img ?? '';
  song.lyric = raw.lyric ?? '';
  song.url = raw.url ?? '';
  song.quality = raw.quality ?? '';
  return song;
}

/** 去重键：歌名 + 首位歌手，忽略大小写、空格和标点 */
export function songKey(song: SongInfo): string {
  const singer = song.singer.split('/')[0].split('&')[0];
  return normalizeText(song.name) + '|' + normalizeText(singer);
}

export function normalizeText(text: string): string {
  return text.toLowerCase().replace(/[\s()（）\[\]【】,，.。!！?？'"“”‘’\-_/·]/g, '');
}

/** 两位歌手名相似度（包含即视为同一首） */
export function sameSong(a: SongInfo, b: SongInfo): boolean {
  return normalizeText(a.name) === normalizeText(b.name);
}

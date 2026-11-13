import {
  SongInfo, SheetInfo, SheetTag, ArtistInfo, PagedSongs, newSong, newSheet,
  secondsToInterval, intervalToSeconds, normalizeText
} from '../common/Models';
import { getText, getJson, getJsonWith, UA, UA_MOBILE } from './Http';
import { platformName } from '../common/Platform';
import { RankCache } from './RankCache';

/* ============================ 通用工具 ============================ */

const WY_REF: string = 'https://music.163.com/';
/**
 * 网易云对匿名请求做降级：歌单详情只回前 10 首 tracks（trackIds 仍是全量）。
 * 带上这个固定 Cookie（不需要登录态）即可拿全量，实测 427 首的歌单直接返回 427 首。
 */
const WY_COOKIE: string = 'os=pc; appver=8.9.70; osver=Microsoft-Windows-10-Professional-build-19045-64bit; channel=netease;';
const TX_REF: string = 'https://y.qq.com/';
const KW_REF: string = 'https://www.kuwo.cn/';
const KG_REF: string = 'https://m.kugou.com/';
const MG_REF: string = 'https://m.music.migu.cn/';

export function htmlDecode(text: string): string {
  return text
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&#(\d+);/g, (match: string, code: string): string => {
      return String.fromCharCode(Number.parseInt(code));
    });
}

function fixCover(url: string): string {
  const value = (url ?? '').trim();
  if (value.length === 0) {
    return '';
  }
  if (value.startsWith('//')) {
    return 'https:' + value;
  }
  if (value.startsWith('http://')) {
    return 'https://' + value.substring(7);
  }
  // {size} 是酷狗/咪咕封面 URL 里的尺寸占位，没替换的话图片必然 404
  return value.split('{size}').join('240');
}

function kwCover(short: string): string {
  if (short.length === 0) {
    return '';
  }
  // web_albumpic_short 形如 120/s3s94/93/211513640.jpg，尺寸已经写在路径里。
  // 再插一层 /300/ 就是 404 —— 之前酷我全平台没封面就是这里。
  const path = short.startsWith('/') ? short.substring(1) : short;
  return 'https://img1.kuwo.cn/star/albumcover/' + path;
}

/** 酷我封面字段可能是短路径，也可能是完整 URL，两种都要能吃 */
function kwCoverValue(raw: string): string {
  const value = (raw ?? '').trim();
  if (value.length === 0) {
    return '';
  }
  if (value.startsWith('http') || value.startsWith('//')) {
    return fixCover(value);
  }
  return kwCover(value);
}

/** 拼进 JSON 字符串字面量时只需要处理会破坏结构的字符 */
function jsonEscape(text: string): string {
  return text.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/[\r\n\t]/g, ' ');
}

/** 轻量等待，用于给限流接口留出重试间隔 */
function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

/** 各平台共用的「多来源挑第一个非空封面」 */
function firstCover(values: string[]): string {
  for (const value of values) {
    const fixed = fixCover(value ?? '');
    if (fixed.length > 0) {
      return fixed;
    }
  }
  return '';
}

/**
 * 榜单封面 URL 是否像一个能加载的图片。
 *
 * 酷我 kbangserver 的 pic 字段不稳定：有的榜给的是目录路径
 * `http://img1.kuwo.cn/star/mboxAlbum/BangPic/`（以 / 结尾、无文件名），
 * 有的是 `.../au_26_30.jpg` 但服务器 404。目录路径塞进 Image 会先返回
 * application/octet-stream 再 onError 落到 ♪ —— 看起来就是「这个榜没封面」。
 * 这里只做「像不像图片 URL」的静态判断：路径末段必须带图片后缀，
 * 且不能是纯目录。真正的 404 仍由 Cover.onError 兜底。
 */
function looksLikeImageUrl(url: string): boolean {
  const value = (url ?? '').trim();
  if (value.length === 0 || !/^https?:\/\//.test(value)) {
    return false;
  }
  const path = value.split('?')[0].split('#')[0];
  const last = path.substring(path.lastIndexOf('/') + 1);
  return /\.(jpg|jpeg|png|webp|gif|bmp)$/i.test(last);
}

/** 补封面时按「歌名 + 歌手」确认是同一首，避免拿到同名不同人的图 */
/**
 * 歌名主体：去掉括号/方括号里的版本说明，以及「- Live / 伴奏 / Remastered」这类尾巴。
 * 只用于「是不是同一首」的判断，不改展示文案。
 */
function baseTitle(text: string): string {
  const stripped = text
    .replace(/[（(\[【][^）)\]】]*[）)\]】]/g, ' ')
    .replace(/\s*[-－–—]\s*(live|remaster(ed)?|demo|acoustic|instrumental|伴奏|纯音乐|片段|dj.*|.*?版)\s*$/i, ' ');
  const base = normalizeText(stripped);
  return base.length > 0 ? base : normalizeText(text);
}

function sameSong(song: SongInfo, name: string, singer: string): boolean {
  const want = baseTitle(song.name);
  const got = baseTitle(name);
  if (want.length === 0 || got.length === 0) {
    return false;
  }
  // 完全一致；或一方是另一方的主体（「我不难过」vs「我不难过 现场版」），
  // 但长度差不能太大，避免「爱我」误配「爱我别走」。
  const diff = Math.abs(want.length - got.length);
  const titleOk = want === got ||
    (want.length >= 4 && got.length >= 4 && diff <= 4 &&
      (want.indexOf(got) >= 0 || got.indexOf(want) >= 0));
  if (!titleOk) {
    return false;
  }
  const a = normalizeText(song.singer);
  const b = normalizeText(singer);
  return a.length === 0 || b.length === 0 || a.indexOf(b) >= 0 || b.indexOf(a) >= 0;
}

/* ============================ 酷我 ============================ */

interface KwRawItem {
  MUSICRID: string;
  NAME: string;
  ARTIST: string;
  ALBUM: string;
  DURATION: string;
  ALBUMID: string;
  PIC: string;
  PAY: string;
  MINFO: string;
}

/**
 * 酷我 r.s 返回的是「带内嵌未转义引号」的伪 JSON，直接 JSON.parse 会炸。
 * 这里按 {"AARTIST" 切块，再逐字段正则提取，稳定且不依赖字段顺序。
 */
function parseKwItems(text: string): KwRawItem[] {
  const list: KwRawItem[] = [];
  const starts: number[] = [];
  const marker = '{"AARTIST"';
  let pos = text.indexOf(marker);
  while (pos >= 0) {
    starts.push(pos);
    pos = text.indexOf(marker, pos + marker.length);
  }
  for (let i = 0; i < starts.length; i++) {
    const begin = starts[i];
    const end = i + 1 < starts.length ? starts[i + 1] : text.indexOf(']}', begin);
    const chunk = text.substring(begin, end > begin ? end : text.length);
    const pick = (key: string): string => {
      const re = new RegExp('"' + key + '":"([^"]*)"');
      const m = re.exec(chunk);
      return m !== null ? m[1] : '';
    };
    const item: KwRawItem = {
      MUSICRID: pick('MUSICRID'),
      NAME: pick('SONGNAME').length > 0 ? pick('SONGNAME') : pick('NAME'),
      ARTIST: pick('ARTIST'),
      ALBUM: pick('ALBUM'),
      DURATION: pick('DURATION'),
      ALBUMID: pick('ALBUMID'),
      PIC: pick('web_albumpic_short'),
      PAY: pick('PAY'),
      MINFO: pick('MINFO')
    };
    if (item.NAME.length > 0) {
      list.push(item);
    }
  }
  return list;
}

/** 空的分页结果，供各平台接口失败时统一返回 */
function emptyPaged(page: number): PagedSongs {
  return { songs: [], page: page, hasMore: false, total: 0 };
}

/**
 * 酷我歌手搜索（r.s?ft=artist）是单引号伪 JSON，不能用 JSON.parse。
 * 与 parseKwItems 同一套思路：按 {'AARTIST' 切块，再逐字段正则提取。
 * 实测 20 位歌手全部解析成功，字段稳定、不依赖字段顺序。
 */
function parseKwArtists(text: string): ArtistInfo[] {
  const list: ArtistInfo[] = [];
  const baseMatch = new RegExp("'BASEPICPATH':'([^']*)'").exec(text);
  const base: string = baseMatch !== null ? fixCover(baseMatch[1]) : '';
  const starts: number[] = [];
  const marker = "{'AARTIST'";
  let pos: number = text.indexOf(marker);
  while (pos >= 0) {
    starts.push(pos);
    pos = text.indexOf(marker, pos + marker.length);
  }
  for (let i = 0; i < starts.length; i++) {
    const begin = starts[i];
    const end = i + 1 < starts.length ? starts[i + 1] : text.length;
    const chunk = text.substring(begin, end);
    const pick = (key: string): string => {
      const re = new RegExp("'" + key + "':'([^']*)'");
      const m = re.exec(chunk);
      return m !== null ? m[1] : '';
    };
    const name: string = htmlDecode(pick('ARTIST'));
    const id: string = pick('ARTISTID');
    if (name.length === 0 || id.length === 0) {
      continue;
    }
    const pic: string = pick('PICPATH');
    const avatar: string = (base.length > 0 && pic.length > 0) ? fixCover(base + pic) : '';
    const songNum: string = pick('SONGNUM');
    const artist: ArtistInfo = {
      id: id,
      name: name,
      avatar: avatar,
      platform: 'kw',
      subtitle: songNum.length > 0 ? '酷我音乐 · ' + songNum + ' 首作品' : '酷我音乐'
    };
    list.push(artist);
  }
  return list;
}

/** QQ musicu.fcg 的 songInfo → SongInfo（字段与 client_search_cp 不同，单独转换） */
function txSongFromMusicu(item: TxMusicuItem): SongInfo {
  const song = newSong('tx');
  const info = item.songInfo;
  if (info === undefined) {
    return song;
  }
  const mid: string = info.mid ?? '';
  song.id = mid;
  song.songmid = mid;
  song.name = htmlDecode(info.name ?? '');
  const names: string[] = [];
  for (const one of info.singer ?? []) {
    names.push(htmlDecode(one.name ?? ''));
  }
  song.singer = names.join(' / ');
  song.album = htmlDecode(info.album?.name ?? '');
  song.albumName = song.album;
  const albumMid: string = info.album?.mid ?? '';
  song.albumId = albumMid;
  song.duration = info.interval ?? 0;
  song.interval = secondsToInterval(song.duration);
  if (albumMid.length > 0) {
    song.cover = 'https://y.gtimg.cn/music/photo_new/T002R300x300M000' + albumMid + '.jpg';
  }
  return song;
}

function kwSong(raw: KwRawItem): SongInfo {
  const song = newSong('kw');
  const id = raw.MUSICRID.replace('MUSIC_', '');
  song.id = id;
  song.songmid = id;
  song.musicrid = raw.MUSICRID;
  song.name = htmlDecode(raw.NAME);
  song.singer = htmlDecode(raw.ARTIST);
  song.album = htmlDecode(raw.ALBUM);
  song.albumName = song.album;
  song.albumId = raw.ALBUMID;
  song.duration = Number.parseInt(raw.DURATION);
  if (Number.isNaN(song.duration)) {
    song.duration = 0;
  }
  song.interval = secondsToInterval(song.duration);
  song.cover = kwCoverValue(raw.PIC);
  song.fee = raw.PAY === '0' ? 0 : 1;
  return song;
}

/** 酷我按 tag 搜索歌单的接口不稳定，这里提供一组固定分类，走「分类歌单」接口 */
interface KwTagDef {
  id: string;
  name: string;
}

const KW_TAGS: KwTagDef[] = [
  { id: 'hot', name: '热门' },
  { id: 'new', name: '新歌' },
  { id: 'rise', name: '飙升' }
];

/* ============================ QQ ============================ */

interface TxSmartItem {
  mid?: string;
  id?: string;
  name?: string;
  title?: string;
  singer?: string;
  pic?: string;
  interval?: number;
}

interface TxSmartGroup {
  itemlist?: TxSmartItem[];
}

interface TxSmartData {
  song?: TxSmartGroup;
  album?: TxSmartGroup;
  singer?: TxSmartGroup;
}

interface TxSmartResp {
  data?: TxSmartData;
}

/** client_search_cp 返回的歌曲：带 albummid，能直接拼官方封面 */
interface TxClientSong {
  songmid?: string;
  songname?: string;
  albummid?: string;
  albumname?: string;
  interval?: number;
  singer?: TxOldSinger[];
}

interface TxClientSongGroup {
  list?: TxClientSong[];
  totalnum?: number;
}

interface TxClientData {
  song?: TxClientSongGroup;
}

interface TxClientResp {
  code?: number;
  data?: TxClientData;
}

interface TxOldSinger {
  name?: string;
}

interface TxOldAlbum {
  name?: string;
  mid?: string;
}

interface TxOldSongData {
  songmid?: string;
  songname?: string;
  songid?: number;
  interval?: number;
  albumname?: string;
  albummid?: string;
  singer?: TxOldSinger[];
  album?: TxOldAlbum;
  mid?: string;
  name?: string;
  title?: string;
}

interface TxOldSongWrap {
  data?: TxOldSongData;
  mid?: string;
  name?: string;
  title?: string;
  interval?: number;
  singer?: TxOldSinger[];
  album?: TxOldAlbum;
}

function txSongFromOld(raw: TxOldSongWrap): SongInfo | null {
  const song = newSong('tx');
  let mid = '';
  let name = '';
  let interval = 0;
  let albumName = '';
  let albumMid = '';
  let singers: TxOldSinger[] = [];
  if (raw.data !== undefined) {
    mid = raw.data.songmid ?? '';
    name = raw.data.songname ?? '';
    interval = raw.data.interval ?? 0;
    albumName = raw.data.albumname ?? '';
    albumMid = raw.data.albummid ?? '';
    singers = raw.data.singer ?? [];
  } else {
    mid = raw.mid ?? '';
    name = raw.name ?? raw.title ?? '';
    interval = raw.interval ?? 0;
    albumName = raw.album?.name ?? '';
    albumMid = raw.album?.mid ?? '';
    singers = raw.singer ?? [];
  }
  if (mid.length === 0) {
    return null;
  }
  song.id = mid;
  song.songmid = mid;
  song.name = name;
  const names: string[] = [];
  for (const s of singers) {
    names.push(s.name ?? '');
  }
  song.singer = names.length > 0 ? names.join(' / ') : '';
  song.album = albumName;
  song.albumName = albumName;
  song.albumId = albumMid;
  song.duration = interval;
  song.interval = secondsToInterval(interval);
  if (albumMid.length > 0) {
    song.cover = 'https://y.gtimg.cn/music/photo_new/T002R300x300M000' + albumMid + '.jpg';
  }
  return song;
}

/* ============================ 网易云 ============================ */

interface WyArtist {
  id?: number;
  name?: string;
  /** 歌手头像：搜索 type=100 返回，img1v1Url 是 1:1 方图 */
  picUrl?: string;
  img1v1Url?: string;
}

interface WyAlbum {
  id?: number;
  name?: string;
  picId?: number;
  picUrl?: string;
  blurPicUrl?: string;
  pic?: number;
}

interface WySong {
  id?: number;
  name?: string;
  duration?: number;
  /** 新版接口（v6 / v3）用 dt（毫秒），老接口用 duration，两者都要认 */
  dt?: number;
  artists?: WyArtist[];
  ar?: WyArtist[];
  album?: WyAlbum;
  al?: WyAlbum;
  fee?: number;
}

interface WySearchResult {
  songs?: WySong[];
  songCount?: number;
  albums?: WyAlbum[];
  artists?: WyArtist[];
  playlists?: WyPlaylist[];
}

interface WySearchResp {
  /** 正常为 200；被风控时是 -462 且没有 result，这时不能当成「没搜到」 */
  code?: number;
  result?: WySearchResult;
}

interface WyPlaylist {
  id?: number;
  name?: string;
  coverImgUrl?: string;
  playCount?: number;
  trackCount?: number;
  description?: string;
  creator?: WyCreator;
  updateTime?: number;
  updateFrequency?: string;
}

interface WyCreator {
  nickname?: string;
}

interface WyTopResp {
  list?: WyPlaylist[];
}

interface WyPlaylistResp {
  playlists?: WyPlaylist[];
}

/** 每日推荐歌单（personalized）：字段和分类歌单不一样，没有 creator / coverImgUrl */
interface WyDailyItem {
  id?: number;
  name?: string;
  picUrl?: string;
  playCount?: number;
  trackCount?: number;
  copywriter?: string;
}

interface WyDailyResp {
  code?: number;
  result?: WyDailyItem[];
}

interface WyDetail {
  tracks?: WySong[];
  trackIds?: WyTrackId[];
  playlist?: WyPlaylist;
  coverImgUrl?: string;
}

interface WyTrackId {
  id?: number;
}

interface WyDetailResp {
  code?: number;
  playlist?: WyDetail;
}

interface WyOldPlaylistResp {
  code?: number;
  result?: WyDetail;
}

interface WySongDetailResp {
  songs?: WySong[];
}

function wySong(raw: WySong): SongInfo {
  const song = newSong('wy');
  song.id = (raw.id ?? 0).toString();
  song.songmid = song.id;
  song.name = raw.name ?? '';
  const artists = raw.ar ?? raw.artists ?? [];
  const names: string[] = [];
  for (const artist of artists) {
    names.push(artist.name ?? '');
  }
  song.singer = names.join(' / ');
  const album = raw.al ?? raw.album;
  song.album = album?.name ?? '';
  song.albumName = song.album;
  song.albumId = album?.id !== undefined ? album.id.toString() : '';
  // v6 / v3 接口给的是 dt（毫秒），老接口给 duration；
  // 只认 duration 会让歌单里所有歌时长都变成 0。
  song.duration = Math.floor((raw.dt ?? raw.duration ?? 0) / 1000);
  song.interval = secondsToInterval(song.duration);
  // 专辑详情 / 部分歌单返回里 al 为 null，封面只在 album.blurPicUrl 或顶层，
  // 所以这里把所有已知别名都试一遍，不要只认 picUrl。
  song.cover = firstCover([album?.picUrl ?? '', album?.blurPicUrl ?? '']);
  song.fee = raw.fee ?? 0;
  return song;
}

function wySheet(raw: WyPlaylist, kind: string): SheetInfo {
  const sheet = newSheet('wy', kind);
  sheet.id = (raw.id ?? 0).toString();
  sheet.name = raw.name ?? '';
  sheet.cover = fixCover(raw.coverImgUrl ?? '');
  sheet.description = raw.description ?? '';
  sheet.trackCount = raw.trackCount ?? 0;
  sheet.playCount = raw.playCount ?? 0;
  sheet.creator = raw.creator?.nickname ?? '网易云音乐';
  if (raw.updateTime !== undefined) {
    const d = new Date(raw.updateTime);
    sheet.updateTime = (d.getMonth() + 1).toString() + '月' + d.getDate().toString() + '日';
  }
  sheet.subtitle = raw.updateFrequency ?? '';
  return sheet;
}

/* ============================ 酷狗 ============================ */

interface KgSong {
  hash?: string;
  songname?: string;
  singername?: string;
  album_name?: string;
  album_id?: string;
  duration?: number;
  filesize?: number;
  filename?: string;
  authors?: KgAuthor[];
  /** 榜单接口自带的真实封面（含 {size} 占位） */
  album_sizable_cover?: string;
  /** 部分接口把封面放在这两个别名里 */
  sizable_cover?: string;
  cover?: string;
  trans_param?: KgTransParam;
}

interface KgTransParam {
  /** 搜索/榜单接口自带的真实封面（含 {size} 占位）。老 stdmusic/{album_id}.jpg 已退化为对所有 id 返回同一张兜底图 */
  union_cover?: string;
}

interface KgAuthor {
  author_name?: string;
}

interface KgData {
  info?: KgSong[];
  total?: number;
}

interface KgResp {
  data?: KgData;
}

interface KgRank {
  rankid?: number;
  rankname?: string;
  imgurl?: string;
  update_frequency?: string;
  songcount?: number;
}

interface KgRankResp {
  data?: KgRankData;
}

interface KgRankData {
  info?: KgRank[];
}

function kgSong(raw: KgSong): SongInfo {
  const song = newSong('kg');
  const hash = raw.hash ?? '';
  song.id = hash;
  song.songmid = hash;
  song.hash = hash;
  let name = raw.songname ?? '';
  let singer = raw.singername ?? '';
  // 榜单接口（v3/rank/song）没有 singername，歌手在 authors 数组里
  if (singer.length === 0 && raw.authors !== undefined) {
    const names: string[] = [];
    for (const author of raw.authors) {
      if (author.author_name !== undefined && author.author_name.length > 0) {
        names.push(author.author_name);
      }
    }
    singer = names.join('/');
  }
  if (name.length === 0 && raw.filename !== undefined) {
    const dash = raw.filename.indexOf(' - ');
    if (dash > 0) {
      singer = raw.filename.substring(0, dash);
      name = raw.filename.substring(dash + 3);
    } else {
      name = raw.filename;
    }
  }
  song.name = name;
  song.singer = singer;
  song.album = raw.album_name ?? '';
  song.albumName = song.album;
  song.albumId = raw.album_id ?? '';
  song.duration = raw.duration ?? 0;
  song.interval = secondsToInterval(song.duration);
  // 封面只认接口自带的真实封面（含日期路径），{size} 换成 240、http 升 https。
  // 老 CDN stdmusic/240/{album_id}.jpg 现在对任意 id 都返回同一张兜底图，
  // 与其给所有歌显示同一张假图，不如留空交给 CoverRepo 按需补真实封面。
  const cover = firstCover([
    raw.album_sizable_cover ?? '',
    raw.sizable_cover ?? '',
    raw.trans_param?.union_cover ?? '',
    raw.cover ?? ''
  ]);
  if (cover.length > 0) {
    song.cover = cover;
  }
  return song;
}

/* ============================ 咪咕 ============================ */

interface MgSinger {
  id?: string;
  name?: string;
}

interface MgAlbum {
  id?: string;
  name?: string;
}

interface MgImg {
  img?: string;
  imgSizeType?: string;
}

interface MgSong {
  id?: string;
  copyrightId?: string;
  name?: string;
  singers?: MgSinger[];
  albums?: MgAlbum[];
  duration?: number;
  lyricUrl?: string;
  trcUrl?: string;
  imgItems?: MgImg[];
  albumImgs?: MgImg[];
  img1?: string;
  img2?: string;
  img3?: string;
  cover?: string;
  toneFlag?: string;
}

interface MgSongResult {
  result?: MgSong[];
  totalCount?: string;
}

interface MgSingerResult {
  result?: MgSinger[];
}

interface MgAlbumResult {
  result?: MgAlbum[];
}

interface MgSearchResp {
  songResultData?: MgSongResult;
  singerResultData?: MgSingerResult;
  albumResultData?: MgAlbumResult;
}

function mgSong(raw: MgSong): SongInfo {
  const song = newSong('mg');
  song.id = raw.id ?? '';
  song.songmid = song.id;
  song.copyrightId = raw.copyrightId ?? '';
  // 咪咕搜索/歌单结果里直接带歌词直链，取词时不用再查一次
  song.lyricUrl = raw.lyricUrl ?? '';
  song.trcUrl = raw.trcUrl ?? '';
  song.name = raw.name ?? '';
  const names: string[] = [];
  if (raw.singers !== undefined) {
    for (const s of raw.singers) {
      names.push(s.name ?? '');
    }
  }
  song.singer = names.join(' / ');
  song.album = raw.albums !== undefined && raw.albums.length > 0 ? (raw.albums[0].name ?? '') : '';
  song.albumName = song.album;
  song.albumId = raw.albums !== undefined && raw.albums.length > 0 ? (raw.albums[0].id ?? '') : '';
  song.duration = raw.duration !== undefined ? Math.floor(raw.duration / 1000) : 0;
  if (song.duration === 0 && raw.duration !== undefined) {
    song.duration = Math.floor(raw.duration);
  }
  song.interval = secondsToInterval(song.duration);
  // imgItems 里同图多尺寸（imgSizeType 01/02/03），优先取大的；
  // 有些结果只有 img1/img2/img3 或 albumImgs，逐个兜底。
  const imgs: MgImg[] = raw.imgItems ?? raw.albumImgs ?? [];
  let picked = '';
  for (const size of ['03', '02', '01']) {
    for (const img of imgs) {
      if ((img.imgSizeType ?? '') === size && (img.img ?? '').length > 0) {
        picked = img.img ?? '';
        break;
      }
    }
    if (picked.length > 0) {
      break;
    }
  }
  if (picked.length === 0) {
    for (const img of imgs) {
      if ((img.img ?? '').length > 0) {
        picked = img.img ?? '';
        break;
      }
    }
  }
  song.cover = firstCover([picked, raw.img1 ?? '', raw.img2 ?? '', raw.img3 ?? '', raw.cover ?? '']);
  return song;
}

/* ============================ 搜索 / 发现 API ============================ */

interface KwSearchJson {
  abslist?: Object[];
}

interface KgSpecial {
  specialid?: number;
  specialname?: string;
  imgurl?: string;
  intro?: string;
  playcount?: number;
  songcount?: number;
  nickname?: string;
}

interface KgSpecialResp {
  data?: KgSpecialData;
}

/** 酷狗歌单广场（m.kugou.com/plist/index&json=true） */
interface KgPlistResp {
  plist?: KgPlistWrap;
}

interface KgPlistWrap {
  list?: KgPlistList;
}

interface KgPlistList {
  total?: number;
  info?: KgPlistItem[];
}

interface KgPlistItem {
  specialid?: number;
  specialname?: string;
  imgurl?: string;
  songcount?: number;
  playcount?: number;
  play_count_text?: string;
  username?: string;
  intro?: string;
  publishtime?: string;
}

interface KgSpecialData {
  info?: KgSpecial[];
}

interface TxDiss {
  dissid?: string;
  dissname?: string;
  imgurl?: string;
  listennum?: number;
  creator?: TxCreator;
}

interface TxCreator {
  name?: string;
}

interface TxDissData {
  list?: TxDiss[];
}

interface TxDissResp {
  data?: TxDissData;
}

/** QQ 歌单搜索（musicu SearchCgiService，search_type=3） */
interface TxPlItem {
  dissid?: string;
  dissname?: string;
  imgurl?: string;
  creator?: TxCreator;
  listennum?: number;
  song_count?: number;
  introduction?: string;
  modifytime?: string;
}

interface TxPlSearchGroup {
  list?: TxPlItem[];
}

interface TxPlSearchBody {
  songlist?: TxPlSearchGroup;
}

interface TxPlSearchData {
  code?: number;
  body?: TxPlSearchBody;
}

interface TxPlSearchReq {
  code?: number;
  data?: TxPlSearchData;
}

interface TxPlSearchResp {
  code?: number;
  req?: TxPlSearchReq;
}

interface KwRcm {
  id?: string;
  name?: string;
  img?: string;
  total?: string;
  listencnt?: string;
  uname?: string;
}

interface KwRcmData {
  data?: KwRcm[];
}

interface KwRcmResp {
  data?: KwRcmData;
}

/** 酷我歌单搜索（r.s 接口 ft=playlist）：这里 abslist 是合法 JSON，可整段解析 */
interface KwPlItem {
  playlistid?: string;
  DC_TARGETID?: string;
  name?: string;
  pic?: string;
  hts_pic?: string;
  nickname?: string;
  intro?: string;
  songnum?: string;
  playcnt?: string;
  tags?: string;
}

interface KwPlSearchResp {
  TOTAL?: string;
  abslist?: KwPlItem[];
}

interface TxTopItem {
  topId?: number;
  title?: string;
  frontPicUrl?: string;
  updateFrequency?: string;
}

interface TxTopGroup {
  groupName?: string;
  toplist?: TxTopItem[];
}

interface TxTopData {
  group?: TxTopGroup[];
}

interface TxTopReq {
  data?: TxTopData;
}

interface TxTopResp {
  req?: TxTopReq;
}

interface TxSongList {
  list?: TxOldSongWrap[];
}

interface TxBody {
  song?: TxSongList;
}

interface TxData {
  body?: TxBody;
}

interface TxReq {
  data?: TxData;
}

interface TxResp {
  req?: TxReq;
}

interface TxDissDetailData {
  songlist?: TxOldSongWrap[];
  dirinfo?: TxDiss;
}

interface TxDissDetailReq {
  data?: TxDissDetailData;
}

interface TxDissDetailResp {
  req?: TxDissDetailReq;
}

interface TxAlbumData {
  list?: TxOldSongWrap[];
  albumName?: string;
  albumMid?: string;
  singerName?: string;
}

interface TxAlbumResp {
  data?: TxAlbumData;
}

interface WyAlbumDetail {
  songs?: WySong[];
  album?: WyAlbum;
  picUrl?: string;
  blurPicUrl?: string;
}

interface WyAlbumResp {
  code?: number;
  /** /api/album/{id} 实际返回 {code, album:{songs, picUrl}}，旧代码读 resp.songs 永远为空 */
  album?: WyAlbumDetail;
  songs?: WySong[];
}

interface WyArtistDetail {
  artist?: WyArtist;
  hotSongs?: WySong[];
}

interface WyArtistResp {
  artist?: WyArtist;
  hotSongs?: WySong[];
}

interface KwBangResp {
  name?: string;
  num?: string;
  pic?: string;
  /** 榜单封面备份字段：pic 常给目录路径或 404，v9_pic2 是榜内歌曲的真实专辑封面 */
  v9_pic2?: string;
  info?: string;
  pub?: string;
  musiclist?: KwBangSong[];
}

interface KwBangSong {
  id?: string;
  name?: string;
  artist?: string;
  album?: string;
  albumid?: string;
  duration?: string;
  /** 只有榜单接口带：duration 字段在榜单里是排行数据，真实秒数在这里 */
  song_duration?: string;
  /** 榜单/歌单详情有时带封面，字段名在不同接口里不统一 */
  web_albumpic_short?: string;
  albumpic?: string;
  pic?: string;
}

/** 榜单/歌单接口若带了封面就当场用；实测酷我榜单 musiclist 通常一个图字段都没有，
 *  这时返回空，由 CoverRepo 在列表渲染时按 rid 异步补。 */
function kwBangCover(item: KwBangSong): string {
  return kwCoverValue(firstCover([
    item.web_albumpic_short ?? '', item.albumpic ?? '', item.pic ?? ''
  ]));
}

/** 酷我时长统一取值：榜单里 duration 是排行数据（3/8/9 这种），真时长在 song_duration；歌单接口相反。song_duration 有值且像秒数就优先 */
function kwDuration(item: KwBangSong): number {
  const real = item.song_duration ?? '';
  if (real.length > 0) {
    const value = Number.parseInt(real);
    if (!Number.isNaN(value) && value > 0) {
      return value;
    }
  }
  return Number.parseInt(item.duration ?? '0');
}

export class PlatformApi {
  /**
   * 按需补封面。酷我榜单/歌单、网易云专辑等接口本身不返回图片字段，
   * 列表渲染时由 CoverRepo 调用这里，按平台再查一次拿真实封面。
   * 只发一次轻量请求，失败返回空串，由调用方标记不再重复重试。
   */
  async fetchCover(song: SongInfo): Promise<string> {
    if (song.source === 'local' || song.name.trim().length === 0) {
      return '';
    }
    let own = '';
    try {
      if (song.source === 'kw') {
        own = await this.kwCoverBySearch(song);
      } else if (song.source === 'wy') {
        own = await this.wyCoverByDetail(song);
      } else if (song.source === 'tx') {
        own = await this.txCoverBySearch(song);
      } else if (song.source === 'kg') {
        own = await this.kgCoverBySearch(song);
      } else if (song.source === 'mg') {
        own = await this.mgCoverBySearch(song);
      }
    } catch (e) {
      own = '';
    }
    if (own.length > 0) {
      return own;
    }
    // 音源脚本来源的歌 source 往往不是 kw/wy/tx/kg/mg（自定义 id），
    // 或本平台补图接口这次没成功 —— 上面那些分支都拿不到图。
    // 用「歌名 + 歌手」去官方接口严格同名匹配取封面：专辑封面跨平台一致，
    // 是真实图而非造数。这是「播放正常但封面一直 ♪」的最后一条真实出路。
    try {
      return await this.coverByCrossSearch(song);
    } catch (e) {
      return '';
    }
  }

  /**
   * 跨平台按「歌名 + 歌手」严格同名匹配补封面。
   * 只认 sameSong 命中的结果，避免把别的歌的封面张冠李戴。
   * QQ client_search_cp 与酷狗 v3/search/song 都实测稳定、带封面字段，
   * 依次尝试，任一命中即返回。
   */
  private async coverByCrossSearch(song: SongInfo): Promise<string> {
    const keyword = this.coverKeyword(song);
    if (keyword.trim().length === 0) {
      return '';
    }
    // 1) QQ：albummid 可直接拼 y.gtimg.cn 官方封面
    try {
      const url = 'https://c.y.qq.com/soso/fcgi-bin/client_search_cp?w=' +
        encodeURIComponent(keyword) + '&format=json&p=1&n=8';
      const resp = await getJson<TxClientResp>(url, TX_REF, 5000);
      const items = resp.data?.song?.list ?? [];
      for (const item of items) {
        if (sameSong(song, item.songname ?? '', PlatformApi.txSingerText(item.singer ?? []))) {
          const cover = PlatformApi.txAlbumCover(item.albummid ?? '');
          if (cover.length > 0) {
            return cover;
          }
        }
      }
    } catch (e) {
      // 落到酷狗
    }
    // 2) 酷狗：album_sizable_cover / union_cover
    try {
      const url = 'https://mobiles.kugou.com/api/v3/search/song?format=json&keyword=' +
        encodeURIComponent(keyword) + '&page=1&pagesize=8';
      const resp = await getJson<KgResp>(url, KG_REF, 5000);
      const items = resp.data?.info ?? [];
      for (const item of items) {
        if (sameSong(song, item.songname ?? '', item.singername ?? '')) {
          const cover = firstCover([item.album_sizable_cover ?? '', item.trans_param?.union_cover ?? '']);
          if (cover.length > 0) {
            return cover;
          }
        }
      }
    } catch (e) {
      // 无更多兜底
    }
    return '';
  }

  private coverKeyword(song: SongInfo): string {
    const singer = song.singer.split('/')[0].split('&')[0].trim();
    return singer.length > 0 ? song.name + ' ' + singer : song.name;
  }

  private static txSingerText(singers: TxOldSinger[]): string {
    const names: string[] = [];
    for (const item of singers) {
      names.push(item.name ?? '');
    }
    return names.join(' / ');
  }

  private static txAlbumCover(albumMid: string): string {
    return albumMid.length > 0
      ? 'https://y.gtimg.cn/music/photo_new/T002R300x300M000' + albumMid + '.jpg'
      : '';
  }

  /** 酷我：榜单/歌单详情不含封面，用同一套 r.s 搜索按 rid 或歌名歌手补齐 */
  private async kwCoverBySearch(song: SongInfo): Promise<string> {
    const url = 'https://search.kuwo.cn/r.s?all=' + encodeURIComponent(this.coverKeyword(song)) +
      '&ft=music&itemset=web_2013&client=kt&pn=0&rn=8&rformat=json&encoding=utf8&mobi=1&vipver=1';
    const text = await getText(url, KW_REF, 5000);
    const items = parseKwItems(text);
    for (const item of items) {
      if (song.id.length > 0 && item.MUSICRID.replace('MUSIC_', '') === song.id) {
        const exact = kwCoverValue(item.PIC);
        if (exact.length > 0) {
          return exact;
        }
      }
    }
    for (const item of items) {
      if (sameSong(song, item.NAME, item.ARTIST)) {
        const matched = kwCoverValue(item.PIC);
        if (matched.length > 0) {
          return matched;
        }
      }
    }
    return '';
  }

  /** 网易云：单曲详情一定带 album.picUrl，用来补专辑/歌单里 al 为 null 的歌 */
  private async wyCoverByDetail(song: SongInfo): Promise<string> {
    if (song.id.length === 0) {
      return '';
    }
    const resp = await getJson<WySongDetailResp>(
      'https://music.163.com/api/song/detail?ids=%5B' + song.id + '%5D', WY_REF, 5000);
    const songs = resp.songs ?? [];
    if (songs.length === 0) {
      return '';
    }
    const album = songs[0].album ?? songs[0].al;
    return firstCover([album?.picUrl ?? '', album?.blurPicUrl ?? '']);
  }

  /** QQ：有 albumId 直接拼；否则按 songmid 去搜索里找 albummid */
  private async txCoverBySearch(song: SongInfo): Promise<string> {
    const albumId = song.albumId ?? '';
    if (albumId.length > 0) {
      return PlatformApi.txAlbumCover(albumId);
    }
    const url = 'https://c.y.qq.com/soso/fcgi-bin/client_search_cp?w=' +
      encodeURIComponent(this.coverKeyword(song)) + '&format=json&p=1&n=8';
    const resp = await getJson<TxClientResp>(url, TX_REF, 5000);
    const items = resp.data?.song?.list ?? [];
    for (const item of items) {
      if (song.songmid.length > 0 && item.songmid === song.songmid) {
        return PlatformApi.txAlbumCover(item.albummid ?? '');
      }
    }
    for (const item of items) {
      if (sameSong(song, item.songname ?? '', PlatformApi.txSingerText(item.singer ?? []))) {
        return PlatformApi.txAlbumCover(item.albummid ?? '');
      }
    }
    return '';
  }

  /** 酷狗：接口偶尔不给封面，按 hash / 歌名歌手去搜索里补 */
  private async kgCoverBySearch(song: SongInfo): Promise<string> {
    const url = 'https://mobiles.kugou.com/api/v3/search/song?format=json&keyword=' +
      encodeURIComponent(this.coverKeyword(song)) + '&page=1&pagesize=8';
    const resp = await getJson<KgResp>(url, KG_REF, 5000);
    const items = resp.data?.info ?? [];
    for (const item of items) {
      if (song.hash.length > 0 && (item.hash ?? '') === song.hash) {
        const exact = firstCover([item.album_sizable_cover ?? '', item.trans_param?.union_cover ?? '']);
        if (exact.length > 0) {
          return exact;
        }
      }
    }
    for (const item of items) {
      if (sameSong(song, item.songname ?? '', item.singername ?? '')) {
        const matched = firstCover([item.album_sizable_cover ?? '', item.trans_param?.union_cover ?? '']);
        if (matched.length > 0) {
          return matched;
        }
      }
    }
    return '';
  }

  /** 咪咕：搜索接口带 imgItems（同图多尺寸），按 copyrightId / 歌名歌手补 */
  private async mgCoverBySearch(song: SongInfo): Promise<string> {
    const url = 'https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/search_all.do' +
      '?ua=Android_migu&version=5.0.1&text=' + encodeURIComponent(this.coverKeyword(song)) +
      '&pageNo=1&pageSize=8&searchSwitch=%7B%22song%22:1,%22album%22:0,%22singer%22:0,%22playlist%22:0%7D';
    const resp = await getJson<MgSearchResp>(url, MG_REF, 5000);
    const items = resp.songResultData?.result ?? [];
    const cid = (song.copyrightId ?? '').length > 0 ? (song.copyrightId ?? '') : song.id;
    for (const item of items) {
      if (cid.length > 0 && (item.copyrightId ?? '') === cid) {
        const exact = mgSong(item).cover;
        if (exact.length > 0) {
          return exact;
        }
      }
    }
    for (const item of items) {
      const names: string[] = [];
      if (item.singers !== undefined) {
        for (const s of item.singers) {
          names.push(s.name ?? '');
        }
      }
      if (sameSong(song, item.name ?? '', names.join(' / '))) {
        const matched = mgSong(item).cover;
        if (matched.length > 0) {
          return matched;
        }
      }
    }
    return '';
  }

  /* ---------------- 搜索 ---------------- */
  async searchSongs(platform: string, keyword: string, page: number = 1): Promise<SongInfo[]> {
    if (keyword.trim().length === 0) {
      return [];
    }
    if (platform === 'kw') {
      return this.kwSearch(keyword, page);
    }
    if (platform === 'tx') {
      return this.txSearch(keyword, page);
    }
    if (platform === 'wy') {
      return this.wySearch(keyword, page);
    }
    if (platform === 'kg') {
      return this.kgSearch(keyword, page);
    }
    if (platform === 'mg') {
      return this.mgSearch(keyword, page);
    }
    return [];
  }

  /** 聚合搜索：并发 + 按歌名/歌手去重 + 交错排列，避免单平台刷屏 */
  async aggregate(platforms: string[], keyword: string): Promise<SongInfo[]> {
    const tasks: Promise<SongInfo[]>[] = [];
    for (const platform of platforms) {
      tasks.push(this.searchSongs(platform, keyword, 1).catch((): SongInfo[] => []));
    }
    const groups = await Promise.all(tasks);
    const seen: string[] = [];
    const merged: SongInfo[] = [];
    let max = 0;
    for (const group of groups) {
      max = Math.max(max, group.length);
    }
    for (let i = 0; i < max; i++) {
      for (const group of groups) {
        if (i >= group.length) {
          continue;
        }
        const song = group[i];
        const key = normalizeText(song.name) + '|' + normalizeText(song.singer.split('/')[0]);
        if (seen.indexOf(key) >= 0) {
          continue;
        }
        seen.push(key);
        merged.push(song);
        if (merged.length >= 80) {
          return merged;
        }
      }
    }
    return merged;
  }

  async searchSheets(platform: string, keyword: string, page: number = 1): Promise<SheetInfo[]> {
    if (platform === 'wy') {
      return this.wySearchSheets(keyword, page);
    }
    if (platform === 'kg') {
      return this.kgSearchSheets(keyword, page);
    }
    if (platform === 'kw') {
      return this.kwSearchSheets(keyword, page);
    }
    if (platform === 'mg') {
      return this.mgSearchSheets(keyword);
    }
    if (platform === 'tx') {
      return this.txSearchSheets(keyword, page);
    }
    return [];
  }

  async searchArtists(platform: string, keyword: string): Promise<ArtistInfo[]> {
    if (platform === 'wy') {
      return this.wySearchArtists(keyword);
    }
    if (platform === 'tx') {
      return this.txSearchArtists(keyword);
    }
    if (platform === 'kg') {
      return this.kgSearchArtists(keyword);
    }
    if (platform === 'mg') {
      return this.mgSearchArtists(keyword);
    }
    if (platform === 'kw') {
      return this.kwSearchArtists(keyword);
    }
    return [];
  }

  /* ---------------- 排行榜 ---------------- */
  /**
   * 平台榜单列表。首页 5 张卡片和榜单页都要用，缓存一份：
   * 榜单一天才更新，10 分钟内重复进入不再打网络（酷我那边十几个子榜要逐个请求）。
   */
  async ranks(platform: string, force: boolean = false): Promise<SheetInfo[]> {
    if (!force) {
      const hit = RankCache.freshBoards(platform);
      if (hit !== null) {
        return hit;
      }
    }
    const list = await this.ranksRaw(platform);
    RankCache.putBoards(platform, list);
    return list;
  }

  private async ranksRaw(platform: string): Promise<SheetInfo[]> {
    if (platform === 'wy') {
      return this.wyRanks();
    }
    if (platform === 'tx') {
      return this.txRanks();
    }
    if (platform === 'kw') {
      return this.kwRanks();
    }
    if (platform === 'kg') {
      return this.kgRanks();
    }
    return [];
  }

  /* ---------------- 歌单分类 ---------------- */
  async sheetTags(platform: string): Promise<SheetTag[]> {
    if (platform === 'wy') {
      const list: SheetTag[] = [];
      const cats: string[] = ['全部', '华语', '流行', '摇滚', '民谣', '电子', '说唱', '古风', '轻音乐', '影视原声', '爵士', '古典'];
      for (const name of cats) {
        const tag: SheetTag = { id: name, name: name, hot: name === '全部' || name === '华语' };
        list.push(tag);
      }
      return list;
    }
    if (platform === 'tx') {
      const all: SheetTag = { id: '10000000', name: '全部', hot: true };
      return [all];
    }
    if (platform === 'kw') {
      const hot: SheetTag = { id: 'hot', name: '热门', hot: true };
      const fresh: SheetTag = { id: 'new', name: '最新', hot: false };
      return [hot, fresh];
    }
    // 酷狗的歌单广场只有「全部」，按标签筛的那套接口带签名、拿不到，
    // 这里不造假分类，直接不给标签行，页面会只用全部 + 分页
    return [];
  }

  async sheetsByTag(platform: string, tagId: string, page: number = 1): Promise<SheetInfo[]> {
    if (platform === 'wy') {
      return this.wyPlaylists(tagId, page);
    }
    if (platform === 'tx') {
      return this.txPlaylists(page);
    }
    if (platform === 'kw') {
      return this.kwPlaylists(tagId, page);
    }
    if (platform === 'kg') {
      return this.kgPlaylists(page);
    }
    return [];
  }

  /**
   * 酷狗推荐歌单：m.kugou.com 的歌单广场，30 条一页，共 600 条。
   * 响应里每条都带整张歌单的歌曲数组（约 175KB/页），这里只取外层信息。
   */
  private async kgPlaylists(page: number): Promise<SheetInfo[]> {
    const url = 'https://m.kugou.com/plist/index&json=true&page=' + page.toString();
    const resp = await getJson<KgPlistResp>(url, KG_REF);
    const items = resp.plist?.list?.info ?? [];
    const list: SheetInfo[] = [];
    for (const item of items) {
      const id = item.specialid === undefined ? '' : item.specialid.toString();
      if (id.length === 0) {
        continue;
      }
      const sheet = newSheet('kg', 'playlist');
      sheet.id = id;
      sheet.name = item.specialname ?? '';
      sheet.cover = fixCover(item.imgurl ?? '');
      sheet.trackCount = item.songcount ?? 0;
      sheet.playCount = item.playcount ?? 0;
      sheet.creator = item.username ?? '酷狗音乐';
      sheet.description = item.intro ?? '';
      sheet.subtitle = item.play_count_text ?? '';
      const published: string = item.publishtime ?? '';
      if (published.length >= 10) {
        sheet.updateTime = published.slice(0, 10);
      }
      list.push(sheet);
    }
    return list;
  }

  /* ---------------- 歌单详情 ---------------- */
  /**
   * 歌单/榜单歌曲。榜单（kind === 'rank'）额外走一层内存缓存，
   * 切子榜、返回再进都能直接铺出来，force 时绕过缓存强制刷新。
   */
  async sheetSongs(sheet: SheetInfo, force: boolean = false): Promise<SongInfo[]> {
    if (sheet.kind !== 'rank') {
      return this.sheetSongsRaw(sheet);
    }
    if (!force) {
      const hit = RankCache.freshSongs(sheet.platform, sheet.id);
      if (hit !== null) {
        return hit;
      }
    }
    const list = await this.sheetSongsRaw(sheet);
    RankCache.putSongs(sheet.platform, sheet.id, list);
    return list;
  }

  private async sheetSongsRaw(sheet: SheetInfo): Promise<SongInfo[]> {
    if (sheet.platform === 'wy') {
      if (sheet.kind === 'album') {
        return this.wyAlbumSongs(sheet.id);
      }
      return this.wyPlaylistSongs(sheet.id);
    }
    if (sheet.platform === 'tx') {
      if (sheet.kind === 'album') {
        return this.txAlbumSongs(sheet.id);
      }
      if (sheet.kind === 'rank') {
        return this.txRankSongs(sheet.id);
      }
      return this.txPlaylistSongs(sheet.id);
    }
    if (sheet.platform === 'kw') {
      if (sheet.kind === 'rank') {
        return this.kwRankSongs(sheet.id);
      }
      return this.kwPlaylistSongs(sheet.id);
    }
    if (sheet.platform === 'kg') {
      if (sheet.kind === 'rank') {
        return this.kgRankSongs(sheet.id);
      }
      return this.kgSpecialSongs(sheet.id);
    }
    if (sheet.platform === 'mg') {
      return this.mgSheetSongs(sheet.id);
    }
    return [];
  }

  /**
   * 歌手作品（分页）。此前只实现了网易云且只取 hotSongs 50 首，其余平台直接返回空，
   * 于是详情页退化成「按歌手名搜第一页 30 条」——这就是用户看到的 30 / 50 首。
   * 实测各平台真实作品量：网易云 407、QQ 417、酷狗 680、酷我 472；咪咕无公开作品接口。
   */
  async artistSongs(artist: ArtistInfo, page: number = 1): Promise<PagedSongs> {
    const p: number = page < 1 ? 1 : page;
    try {
      if (artist.platform === 'wy') {
        return await this.wyArtistSongs(artist.id, p);
      }
      if (artist.platform === 'tx') {
        return await this.txArtistSongs(artist.id, p);
      }
      if (artist.platform === 'kg') {
        return await this.kgArtistSongs(artist.id, p);
      }
      if (artist.platform === 'kw') {
        return await this.kwArtistSongs(artist.id, p);
      }
    } catch (e) {
      console.info('[Platform] 歌手作品接口失败，回退按名搜索');
    }
    // 咪咕 / 未知平台：没有公开的「按歌手 ID 取作品」接口，交还给详情页兜底。
    return emptyPaged(p);
  }

  /* ---------------- 歌手作品：各平台真实接口 ---------------- */

  /** 网易云：/api/v1/artist/songs 按 offset 分页，每页 100，带 Cookie 规避匿名降级 */
  private async wyArtistSongs(id: string, page: number): Promise<PagedSongs> {
    const limit: number = 100;
    const offset: number = (page - 1) * limit;
    const url = 'https://music.163.com/api/v1/artist/songs?id=' + id +
      '&offset=' + offset.toString() + '&limit=' + limit.toString() +
      '&private_cloud=false&work_type=1';
    try {
      const resp = await getJsonWith<WyArtistSongsResp>(url, WY_REF, { 'Cookie': WY_COOKIE }, 15000);
      if (resp.code === 200 && (resp.songs ?? []).length > 0) {
        const list: SongInfo[] = [];
        for (const item of resp.songs ?? []) {
          list.push(wySong(item));
        }
        const total: number = resp.total ?? 0;
        return {
          songs: list, page: page, total: total,
          hasMore: (resp.more ?? false) && offset + list.length < total
        };
      }
    } catch (e) {
      console.info('[Platform] 网易云 v1 歌手作品失败，回退 hotSongs');
    }
    // 风控 / 失败兜底：老接口固定 50 首热门，仅首屏用，不假装还有下一页。
    if (page === 1) {
      try {
        const resp = await getJson<WyArtistResp>('https://music.163.com/api/artist/' + id, WY_REF);
        const list: SongInfo[] = [];
        for (const item of resp.hotSongs ?? []) {
          list.push(wySong(item));
        }
        return { songs: list, page: 1, total: list.length, hasMore: false };
      } catch (e) {
        return emptyPaged(1);
      }
    }
    return emptyPaged(page);
  }

  /** QQ：musicu.fcg 统一接口 GetSingerSongList，begin/num 分页，实测 totalNum 417 */
  private async txArtistSongs(mid: string, page: number): Promise<PagedSongs> {
    const num: number = 100;
    const begin: number = (page - 1) * num;
    const payload = '{"comm":{"ct":24,"cv":0},"req":{"module":"musichall.song_list_server",' +
      '"method":"GetSingerSongList","param":{"singerMid":"' + jsonEscape(mid) +
      '","order":1,"begin":' + begin.toString() + ',"num":' + num.toString() + '}}}';
    const url = 'https://u.y.qq.com/cgi-bin/musicu.fcg?format=json&data=' + encodeURIComponent(payload);
    const resp = await getJson<TxMusicuResp>(url, TX_REF);
    const data = resp.req?.data;
    const list: SongInfo[] = [];
    for (const item of data?.songList ?? []) {
      const song = txSongFromMusicu(item);
      if (song.id.length > 0) {
        list.push(song);
      }
    }
    const total: number = data?.totalNum ?? 0;
    return { songs: list, page: page, total: total, hasMore: begin + list.length < total && list.length > 0 };
  }

  /** 酷狗：/api/v3/singer/song，page/pagesize 分页，实测 total 680；歌名在 filename 里，kgSong 已支持拆分 */
  private async kgArtistSongs(id: string, page: number): Promise<PagedSongs> {
    const size: number = 100;
    const url = 'https://mobiles.kugou.com/api/v3/singer/song?singerid=' + id +
      '&page=' + page.toString() + '&pagesize=' + size.toString() + '&sort=0';
    const resp = await getJson<KgResp>(url, KG_REF);
    const list: SongInfo[] = [];
    for (const item of resp.data?.info ?? []) {
      const song = kgSong(item);
      if (song.id.length > 0) {
        list.push(song);
      }
    }
    const total: number = resp.data?.total ?? 0;
    return { songs: list, page: page, total: total, hasMore: page * size < total && list.length > 0 };
  }

  /** 酷我：r.s?artistid= 按 ID 取作品，pn 是页码、rn=30 稳定；响应是标准 JSON，parseKwItems 的双引号切块同样适用 */
  private async kwArtistSongs(id: string, page: number): Promise<PagedSongs> {
    const url = 'https://search.kuwo.cn/r.s?artistid=' + id +
      '&itemset=web_2013&client=kt&pn=' + (page - 1).toString() +
      '&rn=30&rformat=json&encoding=utf8&mobi=1&vipver=1';
    const text = await getText(url, KW_REF);
    const list: SongInfo[] = [];
    for (const item of parseKwItems(text)) {
      list.push(kwSong(item));
    }
    const m = new RegExp('"TOTAL":"([0-9]+)"').exec(text);
    const total: number = m !== null ? Number.parseInt(m[1]) : 0;
    return { songs: list, page: page, total: total, hasMore: (page - 1) * 30 + list.length < total && list.length > 0 };
  }

  /**
   * 酷我歌手搜索：r.s?ft=artist 返回的是单引号伪 JSON（JSON.parse 会失败），
   * 但与 parseKwItems 同类的「切块 + 逐字段正则」能稳定解析，不会把搜索页带崩。
   * 实测返回 20 位歌手，字段含 ARTIST / ARTISTID / PICPATH / SONGNUM / ALBUMNUM，
   * 头像 = 头部 BASEPICPATH + PICPATH，https 化后 200 可达。
   */
  private async kwSearchArtists(keyword: string): Promise<ArtistInfo[]> {
    const url = 'https://search.kuwo.cn/r.s?all=' + encodeURIComponent(keyword) +
      '&ft=artist&rformat=json&encoding=utf8&rn=20';
    const text = await getText(url, KW_REF);
    return parseKwArtists(text);
  }

  /* ================= 酷我实现 ================= */
  private async kwSearch(keyword: string, page: number): Promise<SongInfo[]> {
    const url = 'https://search.kuwo.cn/r.s?all=' + encodeURIComponent(keyword) +
      '&ft=music&itemset=web_2013&client=kt&pn=' + ((page - 1) * 30).toString() +
      '&rn=30&rformat=json&encoding=utf8&mobi=1&vipver=1';
    const text = await getText(url, KW_REF);
    const items = parseKwItems(text);
    const list: SongInfo[] = [];
    for (const item of items) {
      list.push(kwSong(item));
    }
    return list;
  }

  /**
   * 酷我没有「一次拿全部子榜」的接口，只能按 id 一个个取，所以页面能显示几个榜
   * 完全取决于这里写了几个 id —— 当初只写了 4 个自有主榜，用户看到的「酷我只有 4 个」
   * 就是这么来的，不是接口只返回 4 个、也不是解析丢数据。
   *
   * 实测 ksong.s 有 85 个有效 id，但其中一半是 2013~2017 的月份快照（5月新歌榜…）、
   * 停更的第三方合作榜、MV 榜，甚至还有「每日最新单曲」3 首的测试榜，全塞进来又长又旧。
   * 这里只挑 12 个「酷我」官方主榜 + 常青分类榜：都是 100~300 首、名字规范、
   * 非 MV 非月份非测试的歌曲榜。原来串行 await 实测 600ms；并发之后约等于最慢的一个，
   * 单个失败由 kwBoard 的 try/catch 兜成 null，不会拖垮整页。
   */
  private async kwRankList(): Promise<SheetInfo[]> {
    const ids: string[] = ['16', '93', '17', '26', '62', '22', '23', '63', '64', '104', '68', '116'];
    const jobs: Promise<SheetInfo | null>[] = [];
    for (const id of ids) {
      jobs.push(this.kwBoard(id));
    }
    const results = await Promise.all(jobs);
    const list: SheetInfo[] = [];
    for (const sheet of results) {
      if (sheet !== null) {
        list.push(sheet);
      }
    }
    return list;
  }

  private async kwBoard(id: string): Promise<SheetInfo | null> {
    try {
      const data = await getJson<KwBangResp>(
        'https://kbangserver.kuwo.cn/ksong.s?from=pc&fmt=json&pn=0&rn=1&type=bang&data=content&id=' + id +
        '&show_copyright_off=0&pcmp4=1&isbang=1', KW_REF);
      const sheet = newSheet('kw', 'rank');
      sheet.id = id;
      sheet.name = data.name ?? ('榜单 ' + id);
      // 榜单封面：pic 常给目录路径（无文件名）或 404，先看它像不像图片 URL，
      // 不像就用同响应里的 v9_pic2（榜内歌曲真实专辑封面，实测 200 可达）。
      // 两者都不像就留空，Cover 显示占位，不把死链塞进 Image 拖慢加载。
      const primary = fixCover(data.pic ?? '');
      const fallback = fixCover(data.v9_pic2 ?? '');
      sheet.cover = looksLikeImageUrl(primary) ? primary :
        (looksLikeImageUrl(fallback) ? fallback : '');
      // 主封面是「合法 .jpg 但服务器 404」时静态判断看不出来，
      // 把 v9_pic2 留作运行时备用，由 Cover.onError 自动切换。
      if (looksLikeImageUrl(fallback) && fallback !== sheet.cover) {
        sheet.coverFallback = fallback;
      }
      sheet.subtitle = data.info ?? '';
      sheet.description = data.info ?? '';
      sheet.trackCount = Number.parseInt(data.num ?? '0');
      sheet.creator = '酷我音乐';
      sheet.updateTime = data.pub ?? '';
      return sheet;
    } catch (e) {
      console.info('[Platform] 酷我榜单 ' + id + ' 获取失败');
      return null;
    }
  }

  private async kwRanks(): Promise<SheetInfo[]> {
    return this.kwRankList();
  }

  private async kwRankSongs(id: string): Promise<SongInfo[]> {
    const data = await getJson<KwBangResp>(
      'https://kbangserver.kuwo.cn/ksong.s?from=pc&fmt=json&pn=0&rn=100&type=bang&data=content&id=' + id +
      '&show_copyright_off=0&pcmp4=1&isbang=1', KW_REF);
    const list: SongInfo[] = [];
    const raw = data.musiclist ?? [];
    for (const item of raw) {
      const musicId = item.id ?? '';
      if (musicId.length === 0) {
        continue;
      }
      const song = newSong('kw');
      song.id = musicId;
      song.songmid = musicId;
      song.musicrid = 'MUSIC_' + musicId;
      song.name = htmlDecode(item.name ?? '');
      song.singer = htmlDecode(item.artist ?? '');
      song.album = htmlDecode(item.album ?? '');
      song.albumName = song.album;
      song.albumId = item.albumid ?? '';
      song.duration = kwDuration(item);
      if (Number.isNaN(song.duration)) {
        song.duration = 0;
      }
      song.interval = secondsToInterval(song.duration);
      song.cover = kwBangCover(item);
      list.push(song);
    }
    return list;
  }

  private async kwPlaylists(tagId: string, page: number): Promise<SheetInfo[]> {
    const order = tagId === 'new' ? 'new' : 'hot';
    const url = 'https://wapi.kuwo.cn/api/pc/classify/playlist/getRcmPlayList?pn=' + page.toString() +
      '&rn=18&order=' + order;
    const resp = await getJson<KwRcmResp>(url, KW_REF);
    const list: SheetInfo[] = [];
    const items = resp.data?.data ?? [];
    for (const pl of items) {
      const sheet = newSheet('kw', 'playlist');
      sheet.id = pl.id ?? '';
      sheet.name = pl.name ?? '';
      sheet.cover = fixCover(pl.img ?? '');
      sheet.trackCount = Number.parseInt(pl.total ?? '0');
      sheet.playCount = Number.parseInt(pl.listencnt ?? '0');
      sheet.creator = pl.uname ?? '酷我音乐';
      if (sheet.id.length > 0) {
        list.push(sheet);
      }
    }
    return list;
  }

  private async kwPlaylistSongs(id: string): Promise<SongInfo[]> {
    // rn 实测可放到 1000（445 首的歌单一次取全；pn 偏移不生效，只能靠大 rn）
    const url = 'https://nplserver.kuwo.cn/pl.svc?op=getlistinfo&pid=' + id +
      '&pn=0&rn=1000&encode=utf8&keyset=pl2012&identity=kuwo&pcmp4=1&vipver=1';
    const data = await getJson<KwBangResp>(url, KW_REF);
    const list: SongInfo[] = [];
    const raw = data.musiclist ?? [];
    for (const item of raw) {
      const musicId = item.id ?? '';
      if (musicId.length === 0) {
        continue;
      }
      const song = newSong('kw');
      song.id = musicId;
      song.songmid = musicId;
      song.musicrid = 'MUSIC_' + musicId;
      song.name = htmlDecode(item.name ?? '');
      song.singer = htmlDecode(item.artist ?? '');
      song.album = htmlDecode(item.album ?? '');
      song.albumName = song.album;
      song.albumId = item.albumid ?? '';
      song.duration = Number.parseInt(item.duration ?? '0');
      if (Number.isNaN(song.duration)) {
        song.duration = 0;
      }
      song.interval = secondsToInterval(song.duration);
      song.cover = kwBangCover(item);
      list.push(song);
    }
    return list;
  }

  /**
   * 酷我歌单搜索。r.s 接口把 ft 从 music 换成 playlist 就是歌单检索，
   * 返回同样的伪 JSON 结构，但这里的 abslist 是合法 JSON（可整段 parse）。
   * 条目字段：playlistid / name / pic / nickname / songnum / playcnt / tags / intro。
   */
  private async kwSearchSheets(keyword: string, page: number): Promise<SheetInfo[]> {
    const pn = (page - 1) * 30;
    const url = 'https://search.kuwo.cn/r.s?all=' + encodeURIComponent(keyword) +
      '&ft=playlist&itemset=web_2013&client=kt&pn=' + pn.toString() + '&rn=30' +
      '&rformat=json&encoding=utf8&mobi=1&vipver=1';
    const resp = await getJson<KwPlSearchResp>(url, KW_REF);
    const list: SheetInfo[] = [];
    const items = resp.abslist ?? [];
    for (const item of items) {
      const id = (item.playlistid ?? item.DC_TARGETID ?? '').trim();
      if (id.length === 0) {
        continue;
      }
      const sheet = newSheet('kw', 'playlist');
      sheet.id = id;
      sheet.name = htmlDecode(item.name ?? '');
      sheet.cover = fixCover(item.pic ?? item.hts_pic ?? '');
      sheet.description = htmlDecode(item.intro ?? '');
      const count = Number.parseInt(item.songnum ?? '');
      sheet.trackCount = Number.isNaN(count) ? 0 : count;
      const plays = Number.parseInt(item.playcnt ?? '');
      sheet.playCount = Number.isNaN(plays) ? 0 : plays;
      sheet.creator = item.nickname ?? '酷我音乐';
      // tags 形如「华语;经典」，换成中点分隔更适合一行小字
      sheet.subtitle = (item.tags ?? '').split(';').filter((tag: string): boolean => tag.trim().length > 0)
        .join(' · ');
      list.push(sheet);
    }
    return list;
  }

  /* ================= QQ 实现 ================= */
  private async txSearch(keyword: string, page: number): Promise<SongInfo[]> {
    // smartbox_new.fcg 的 song.itemlist 实测只有 docid/id/mid/name/singer，
    // 根本没有 pic / albummid —— 旧逻辑「item.pic 存在才设封面」等于永远不设，
    // 这就是 QQ 音乐搜索结果全都没有封面的根因。
    // client_search_cp 返回 albummid，可直接拼 y.gtimg.cn 官方封面，且支持翻页。
    try {
      const url = 'https://c.y.qq.com/soso/fcgi-bin/client_search_cp?w=' + encodeURIComponent(keyword) +
        '&format=json&p=' + page.toString() + '&n=30';
      const resp = await getJson<TxClientResp>(url, TX_REF);
      const items = resp.data?.song?.list ?? [];
      if (items.length > 0) {
        const list: SongInfo[] = [];
        for (const item of items) {
          const mid = item.songmid ?? '';
          if (mid.length === 0) {
            continue;
          }
          const song = newSong('tx');
          song.id = mid;
          song.songmid = mid;
          song.name = htmlDecode(item.songname ?? '');
          const names: string[] = [];
          for (const s of item.singer ?? []) {
            names.push(htmlDecode(s.name ?? ''));
          }
          song.singer = names.join(' / ');
          song.album = htmlDecode(item.albumname ?? '');
          song.albumName = song.album;
          song.albumId = item.albummid ?? '';
          song.duration = item.interval ?? 0;
          song.interval = secondsToInterval(song.duration);
          if (song.albumId.length > 0) {
            song.cover = 'https://y.gtimg.cn/music/photo_new/T002R300x300M000' + song.albumId + '.jpg';
          }
          list.push(song);
        }
        if (list.length > 0) {
          return list;
        }
      }
    } catch (e) {
      console.info('[Platform] QQ 新搜索接口失败，回退 smartbox');
    }
    if (page > 1) {
      return [];
    }
    const url = 'https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg?key=' + encodeURIComponent(keyword) +
      '&format=json&inCharset=utf8&outCharset=utf-8';
    const resp = await getJson<TxSmartResp>(url, TX_REF);
    const list: SongInfo[] = [];
    const items = resp.data?.song?.itemlist ?? [];
    for (const item of items) {
      const song = newSong('tx');
      const mid = item.mid ?? '';
      if (mid.length === 0) {
        continue;
      }
      song.id = mid;
      song.songmid = mid;
      song.name = htmlDecode(item.name ?? '');
      song.singer = htmlDecode(item.singer ?? '');
      if (item.pic !== undefined && item.pic.length > 0) {
        song.cover = fixCover(item.pic.replace('T002R180x180M000', 'T002R300x300M000'));
        const slash = song.cover.lastIndexOf('/');
        if (slash > 0) {
          const file = song.cover.substring(slash + 1);
          song.albumId = file.replace('T002R300x300M000', '').replace('.jpg', '');
        }
      }
      if (item.interval !== undefined) {
        song.duration = item.interval;
        song.interval = secondsToInterval(song.duration);
      }
      list.push(song);
    }
    return list;
  }

  private async txRanks(): Promise<SheetInfo[]> {
    const payload = '{"comm":{"ct":24},"req":{"method":"GetAll","module":"musicToplist.ToplistInfoServer","param":{}}}';
    const url = 'https://u.y.qq.com/cgi-bin/musicu.fcg?format=json&data=' + encodeURIComponent(payload);
    const resp = await getJson<TxTopResp>(url, TX_REF);
    const list: SheetInfo[] = [];
    const groups = resp.req?.data?.group ?? [];
    for (const group of groups) {
      const tops = group.toplist ?? [];
      for (const top of tops) {
        const sheet = newSheet('tx', 'rank');
        sheet.id = (top.topId ?? 0).toString();
        sheet.name = top.title ?? '';
        sheet.cover = fixCover(top.frontPicUrl ?? '');
        sheet.subtitle = group.groupName ?? '';
        sheet.creator = 'QQ音乐';
        sheet.updateTime = top.updateFrequency ?? '';
        list.push(sheet);
      }
    }
    return list;
  }

  private async txRankSongs(id: string): Promise<SongInfo[]> {
    const url = 'https://c.y.qq.com/v8/fcg-bin/fcg_v8_toplist_cp.fcg?topid=' + id +
      '&page=detail&type=top&song_begin=0&song_num=100&format=json&inCharset=utf8&outCharset=utf-8';
    const resp = await getJson<TxTopSongsResp>(url, TX_REF);
    const list: SongInfo[] = [];
    const raw = resp.songlist ?? [];
    for (const entry of raw) {
      const song = txSongFromOld(entry);
      if (song !== null) {
        list.push(song);
      }
    }
    return list;
  }

  private async txPlaylists(page: number): Promise<SheetInfo[]> {
    const sin = (page - 1) * 18;
    const url = 'https://c.y.qq.com/splcloud/fcgi-bin/fcg_get_diss_by_tag.fcg?picmid=1&rnd=0.1&g_tk=5381' +
      '&categoryId=10000000&sortId=5&sin=' + sin.toString() + '&ein=' + (sin + 18).toString() +
      '&format=json&inCharset=utf8&outCharset=utf-8';
    const resp = await getJson<TxDissResp>(url, TX_REF);
    const list: SheetInfo[] = [];
    const items = resp.data?.list ?? [];
    for (const item of items) {
      const sheet = newSheet('tx', 'playlist');
      sheet.id = item.dissid ?? '';
      sheet.name = item.dissname ?? '';
      sheet.cover = fixCover(item.imgurl ?? '');
      sheet.playCount = item.listennum ?? 0;
      sheet.creator = item.creator?.name ?? 'QQ音乐';
      if (sheet.id.length > 0) {
        list.push(sheet);
      }
    }
    return list;
  }

  private async txPlaylistSongs(id: string): Promise<SongInfo[]> {
    const payload = '{"comm":{"ct":24},"req":{"module":"music.srfDissInfo.aiDissInfo",' +
      '"method":"uniform_get_Dissinfo","param":{"disstid":' + id + ',"enc_host_uin":"","tag":1,"is_pc":1}}}';
    const url = 'https://u.y.qq.com/cgi-bin/musicu.fcg?format=json&data=' + encodeURIComponent(payload);
    const resp = await getJson<TxDissDetailResp>(url, TX_REF);
    const list: SongInfo[] = [];
    const raw = resp.req?.data?.songlist ?? [];
    for (const entry of raw) {
      const song = txSongFromOld(entry);
      if (song !== null) {
        list.push(song);
      }
    }
    return list;
  }

  private async txAlbumSongs(albumMid: string): Promise<SongInfo[]> {
    if (albumMid.length === 0) {
      return [];
    }
    const url = 'https://c.y.qq.com/v8/fcg-bin/fcg_v8_album_info_cp.fcg?albummid=' + albumMid + '&format=json';
    const resp = await getJson<TxAlbumResp>(url, TX_REF);
    const list: SongInfo[] = [];
    const raw = resp.data?.list ?? [];
    for (const entry of raw) {
      const song = txSongFromOld(entry);
      if (song !== null) {
        list.push(song);
      }
    }
    return list;
  }

  /**
   * QQ 歌单搜索。
   *
   * 老的 smartbox_new 只有 song / album / singer 三类，根本没有歌单，
   * 之前「歌单」页拿它当数据源，等于把专辑冒充歌单，关键词不是专辑名时就是一片空白。
   * 真正能搜歌单的是 musicu.fcg 的 SearchCgiService：search_type=3 返回
   * body.songlist.list，每条带 dissid（歌单详情直接用）、dissname、imgurl、
   * creator.name、song_count、listennum。
   */
  private async txSearchSheets(keyword: string, page: number): Promise<SheetInfo[]> {
    const payload = '{"comm":{"ct":"11","cv":"1003006","v":"1003006","os_ver":"10","uin":"0"},' +
      '"req":{"method":"DoSearchForQQMusicDesktop","module":"music.search.SearchCgiService",' +
      '"param":{"num_per_page":30,"page_num":' + page.toString() + ',"query":"' +
      jsonEscape(keyword) + '","search_type":3}}}';
    const url = 'https://u.y.qq.com/cgi-bin/musicu.fcg?format=json&data=' + encodeURIComponent(payload);
    const list: SheetInfo[] = [];
    let served = false;
    // 这个接口对短时间内的重复请求会回 req.code=2001（限流），隔一下再试一次基本能过
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        const resp = await getJson<TxPlSearchResp>(url, TX_REF, 12000);
        const code = resp.req?.code ?? -1;
        if (code === 0) {
          // code 0 但结构里没有 songlist，说明接口改版，同样按「不可用」处理走兜底
          served = resp.req?.data?.body?.songlist !== undefined;
          const items = resp.req?.data?.body?.songlist?.list ?? [];
          for (const item of items) {
            const id = (item.dissid ?? '').trim();
            if (id.length === 0) {
              continue;
            }
            const sheet = newSheet('tx', 'playlist');
            sheet.id = id;
            sheet.name = item.dissname ?? '';
            sheet.cover = fixCover(item.imgurl ?? '');
            sheet.description = htmlDecode((item.introduction ?? '').replace(/<br\s*\/?>/g, ' '));
            sheet.trackCount = item.song_count ?? 0;
            sheet.playCount = item.listennum ?? 0;
            sheet.creator = item.creator?.name ?? 'QQ音乐';
            sheet.updateTime = item.modifytime ?? '';
            list.push(sheet);
          }
          break;
        }
        console.info('[Platform] QQ 歌单搜索返回码 ' + code.toString());
      } catch (e) {
        console.info('[Platform] QQ 歌单搜索失败');
      }
      if (attempt === 0) {
        await delay(300);
      }
    }
    // 接口整体不可用（限流/改动）时退回专辑搜索，至少别给用户一片空白
    if (!served) {
      return this.txSearchAlbums(keyword);
    }
    return list;
  }

  /** 专辑搜索：smartbox 的 album 分组，只在歌单接口不可用时作为兜底 */
  private async txSearchAlbums(keyword: string): Promise<SheetInfo[]> {
    const resp = await getJson<TxSmartResp>(
      'https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg?key=' + encodeURIComponent(keyword) +
      '&format=json&inCharset=utf8&outCharset=utf-8', TX_REF);
    const list: SheetInfo[] = [];
    const items = resp.data?.album?.itemlist ?? [];
    for (const item of items) {
      const sheet = newSheet('tx', 'album');
      sheet.id = item.mid ?? '';
      sheet.name = item.name ?? '';
      sheet.cover = fixCover(item.pic ?? '');
      sheet.creator = item.singer ?? '';
      sheet.subtitle = '专辑';
      if (sheet.id.length > 0) {
        list.push(sheet);
      }
    }
    return list;
  }

  private async txSearchArtists(keyword: string): Promise<ArtistInfo[]> {
    const resp = await getJson<TxSmartResp>(
      'https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg?key=' + encodeURIComponent(keyword) +
      '&format=json&inCharset=utf8&outCharset=utf-8', TX_REF);
    const list: ArtistInfo[] = [];
    const items = resp.data?.singer?.itemlist ?? [];
    for (const item of items) {
      const artist: ArtistInfo = {
        id: item.mid ?? '',
        name: item.name ?? '',
        avatar: fixCover(item.pic ?? ''),
        platform: 'tx',
        subtitle: 'QQ音乐'
      };
      list.push(artist);
    }
    return list;
  }

  /* ================= 网易云实现 ================= */

  /**
   * 网易云搜索统一入口（单曲 / 歌单 / 歌手共用同一个接口，风控也一起中招）。
   *
   * v2.36 实测：老接口 `/api/search/get/web` 对匿名请求会间歇返回
   * `{"code":-462,"data":{"blockText":"验证成功后，可进行下一步操作哦~"}}`
   * （同一请求连发 8 次有 4 次被拦），没有 result。上层 `resp.result?.songs ?? []`
   * 直接得到空数组，搜索页就显示「没有找到结果」——三个 tab 一起空，
   * 而发现页的榜单 / 歌单详情走的是另外的接口，所以照常可用。
   *
   * `/api/v1/search/get` 三种 type 连测 8 次全部 200 且字段结构一致
   * （result.songs / playlists / artists，各 30 条）。改为主接口，
   * 老接口留作兜底，最多三次尝试；拿到风控码不当空结果，继续换路重试。
   */
  private async wySearchRaw(type: number, keyword: string, offset: number,
    limit: number): Promise<WySearchResp> {
    const q = 'csrf_token=&s=' + encodeURIComponent(keyword) + '&type=' + type.toString() +
      '&offset=' + offset.toString() + '&total=true&limit=' + limit.toString();
    const urls: string[] = [
      'https://music.163.com/api/v1/search/get?' + q,
      'https://music.163.com/api/search/get/web?' + q
    ];
    let lastError: string = '';
    for (let i = 0; i < 3; i++) {
      try {
        const resp = await getJson<WySearchResp>(urls[i % 2], WY_REF, 8000);
        // 真没搜到时 code=200 且 result 带空数组；只有缺 result 且非 200 才是风控
        if (resp.result !== undefined) {
          return resp;
        }
        if (resp.code !== undefined && resp.code !== 200) {
          lastError = '网易云返回 ' + resp.code.toString() + '（风控验证）';
          continue;
        }
        return resp;
      } catch (e) {
        lastError = String(e);
      }
    }
    throw new Error(lastError.length > 0 ? lastError : '网易云搜索暂时不可用');
  }

  private async wySearch(keyword: string, page: number): Promise<SongInfo[]> {
    const resp = await this.wySearchRaw(1, keyword, (page - 1) * 30, 30);
    const list: SongInfo[] = [];
    const songs = resp.result?.songs ?? [];
    for (const item of songs) {
      list.push(wySong(item));
    }
    return list;
  }

  private async wySearchSheets(keyword: string, page: number): Promise<SheetInfo[]> {
    const resp = await this.wySearchRaw(1000, keyword, (page - 1) * 30, 30);
    const list: SheetInfo[] = [];
    const playlists = resp.result?.playlists ?? [];
    for (const pl of playlists) {
      list.push(wySheet(pl, 'playlist'));
    }
    return list;
  }

  private async wySearchArtists(keyword: string): Promise<ArtistInfo[]> {
    const resp = await this.wySearchRaw(100, keyword, 0, 20);
    const list: ArtistInfo[] = [];
    const artists = resp.result?.artists ?? [];
    for (const item of artists) {
      const artist: ArtistInfo = {
        id: (item.id ?? 0).toString(),
        name: item.name ?? '',
        avatar: fixCover(item.img1v1Url ?? item.picUrl ?? ''),
        platform: 'wy',
        subtitle: '网易云音乐'
      };
      list.push(artist);
    }
    return list;
  }

  private async wyRanks(): Promise<SheetInfo[]> {
    const resp = await getJson<WyTopResp>('https://music.163.com/api/toplist/detail', WY_REF);
    const list: SheetInfo[] = [];
    const ranks = resp.list ?? [];
    for (const rank of ranks) {
      list.push(wySheet(rank, 'rank'));
    }
    return list;
  }

  /**
   * 首页推荐歌单的一页（page 从 1 起）。
   *
   * 为什么不能只调 sheetsByTag：各家的「歌单广场」都是按历史累计热度排的静态榜单，
   * 网易 playlist/list?order=hot 的第一名几年不变，酷我 / QQ 的也基本钉死。
   * 首页要的是「推荐」，所以网易先走 personalized（云音乐每日按口味重算的推荐位，
   * 匿名也能拿到），翻到底或失败再回退分类广场；其它平台仍用各自广场分页。
   */
  async homeSheets(platform: string, page: number): Promise<SheetInfo[]> {
    if (platform === 'wy') {
      try {
        const daily = await this.wyDailyPlaylists(page);
        if (daily.length > 0) {
          return daily;
        }
      } catch (e) {
        console.info('[Platform] 网易每日推荐不可用，回退分类歌单广场');
      }
      return this.wyPlaylists('全部', page);
    }
    const tags = await this.sheetTags(platform);
    const tagId = tags.length > 0 ? tags[0].id : '全部';
    return this.sheetsByTag(platform, tagId, page);
  }

  /** 网易云每日推荐歌单：30 条一页，按天轮换 */
  private async wyDailyPlaylists(page: number): Promise<SheetInfo[]> {
    const offset = (page - 1) * 30;
    const url = 'https://music.163.com/api/personalized/playlist?limit=30&offset=' + offset.toString();
    const resp = await getJson<WyDailyResp>(url, WY_REF);
    const list: SheetInfo[] = [];
    for (const item of resp.result ?? []) {
      const id = item.id === undefined ? '' : item.id.toString();
      if (id.length === 0) {
        continue;
      }
      const sheet = newSheet('wy', 'playlist');
      sheet.id = id;
      sheet.name = item.name ?? '';
      sheet.cover = fixCover(item.picUrl ?? '');
      sheet.description = item.copywriter ?? '';
      sheet.trackCount = item.trackCount ?? 0;
      sheet.playCount = item.playCount ?? 0;
      sheet.creator = '网易云音乐';
      list.push(sheet);
    }
    return list;
  }

  private async wyPlaylists(cat: string, page: number): Promise<SheetInfo[]> {
    const category = cat === '全部' ? '' : cat;
    const offset = (page - 1) * 18;
    const url = 'https://music.163.com/api/playlist/list?cat=' + encodeURIComponent(category) +
      '&order=hot&offset=' + offset.toString() + '&limit=18&total=true';
    const resp = await getJson<WyPlaylistResp>(url, WY_REF);
    const list: SheetInfo[] = [];
    const playlists = resp.playlists ?? [];
    for (const pl of playlists) {
      list.push(wySheet(pl, 'playlist'));
    }
    return list;
  }

  private async wyPlaylistSongs(id: string): Promise<SongInfo[]> {
    let tracks: WySong[] = [];
    let fallbackCover = '';
    // 主路径走老接口 /api/playlist/detail：匿名也返回全量 tracks（实测 427 首一次给全），
    // 既不受 v6 的 -462 风控影响，也不会被裁成前 10 首。
    try {
      const old = await getJsonWith<WyOldPlaylistResp>(
        'https://music.163.com/api/playlist/detail?id=' + id, WY_REF, { 'Cookie': WY_COOKIE }, 20000);
      tracks = old.result?.tracks ?? [];
      fallbackCover = fixCover(old.result?.coverImgUrl ?? '');
    } catch (e) {
      console.info('[Platform] 网易云歌单老接口失败，回退 v6');
    }
    if (tracks.length === 0) {
      tracks = await this.wyPlaylistSongsV6(id);
      if (tracks.length > 0) {
        fallbackCover = '';
      }
    }
    const list: SongInfo[] = [];
    for (const track of tracks) {
      const song = wySong(track);
      if (song.cover.length === 0 && fallbackCover.length > 0) {
        song.cover = fallbackCover;
      }
      list.push(song);
    }
    return list;
  }

  /**
   * v6 歌单详情作为兜底：匿名/降级时 tracks 只给前 10 首，
   * 但 trackIds 是全量，按 id 批量补齐。
   */
  private async wyPlaylistSongsV6(id: string): Promise<WySong[]> {
    let tracks: WySong[] = [];
    let filled: WySong[] = [];
    try {
      const resp = await getJsonWith<WyDetailResp>(
        'https://music.163.com/api/v6/playlist/detail?id=' + id + '&n=1000', WY_REF,
        { 'Cookie': WY_COOKIE });
      if (resp.code === undefined || resp.code === 200) {
        tracks = resp.playlist?.tracks ?? [];
        const rawIds = resp.playlist?.trackIds ?? [];
        const ids: number[] = [];
        for (const item of rawIds) {
          if (item.id !== undefined && item.id > 0) {
            ids.push(item.id);
          }
        }
        if (ids.length > tracks.length) {
          filled = await this.wySongsByIds(ids);
        }
      }
    } catch (e) {
      console.info('[Platform] 网易云歌单 v6 接口失败');
    }
    return filled.length > tracks.length ? filled : tracks;
  }

  /**
   * 按 trackIds 批量取歌：网易云匿名访问歌单详情只给前 10 首时的补全通道。
   * 每批 100 首（实测可用的批量上限附近），串行发避免触发风控，最后按原顺序重排。
   */
  private async wySongsByIds(ids: number[]): Promise<WySong[]> {
    const limit = 2000;
    const batch = 100;
    const got: WySong[] = [];
    for (let start = 0; start < ids.length && start < limit; start += batch) {
      const slice = ids.slice(start, start + batch);
      const parts: string[] = [];
      for (const item of slice) {
        parts.push(item.toString());
      }
      try {
        const resp = await getJson<WySongDetailResp>(
          'https://music.163.com/api/song/detail?ids=[' + parts.join(',') + ']', WY_REF);
        for (const song of resp.songs ?? []) {
          got.push(song);
        }
      } catch (e) {
        console.info('[Platform] 网易云批量取歌失败，保留已取到的部分');
      }
    }
    if (got.length === 0) {
      return [];
    }
    // 老接口返回顺序不保证与 ids 一致，按 trackIds 原顺序重排
    const byId = new Map<string, WySong>();
    for (const song of got) {
      byId.set((song.id ?? 0).toString(), song);
    }
    const ordered: WySong[] = [];
    for (const id of ids) {
      const hit = byId.get(id.toString());
      if (hit !== undefined) {
        ordered.push(hit);
      }
    }
    return ordered;
  }

  private async wyAlbumSongs(id: string): Promise<SongInfo[]> {
    const resp = await getJson<WyAlbumResp>('https://music.163.com/api/album/' + id, WY_REF);
    const album = resp.album;
    const songs = album?.songs ?? resp.songs ?? [];
    // 专辑里的 songs[].al 实测为 null，封面只在顶层 album.picUrl
    const cover = firstCover([
      album?.picUrl ?? '', album?.blurPicUrl ?? '', album?.album?.picUrl ?? ''
    ]);
    const list: SongInfo[] = [];
    for (const item of songs) {
      const song = wySong(item);
      if (song.cover.length === 0 && cover.length > 0) {
        song.cover = cover;
      }
      list.push(song);
    }
    return list;
  }

  /* ================= 酷狗实现 ================= */
  private async kgSearch(keyword: string, page: number): Promise<SongInfo[]> {
    const url = 'https://mobiles.kugou.com/api/v3/search/song?format=json&keyword=' + encodeURIComponent(keyword) +
      '&page=' + page.toString() + '&pagesize=30';
    const resp = await getJson<KgResp>(url, KG_REF);
    const list: SongInfo[] = [];
    const items = resp.data?.info ?? [];
    for (const item of items) {
      const song = kgSong(item);
      if (song.id.length > 0) {
        list.push(song);
      }
    }
    return list;
  }

  private async kgRanks(): Promise<SheetInfo[]> {
    const url = 'https://mobiles.kugou.com/api/v3/rank/list?parentid=0&apiver=2&plat=0&withsong=1';
    const resp = await getJson<KgRankResp>(url, KG_REF);
    const list: SheetInfo[] = [];
    const ranks = resp.data?.info ?? [];
    for (const rank of ranks) {
      const sheet = newSheet('kg', 'rank');
      sheet.id = (rank.rankid ?? 0).toString();
      sheet.name = rank.rankname ?? '';
      sheet.cover = fixCover((rank.imgurl ?? '').replace('{size}', '300'));
      sheet.subtitle = rank.update_frequency ?? '';
      sheet.trackCount = rank.songcount ?? 0;
      sheet.creator = '酷狗音乐';
      list.push(sheet);
    }
    return list;
  }

  private async kgRankSongs(id: string): Promise<SongInfo[]> {
    const url = 'https://mobiles.kugou.com/api/v3/rank/song?rankid=' + id + '&page=1&pagesize=100&apiver=2';
    const resp = await getJson<KgResp>(url, KG_REF);
    const list: SongInfo[] = [];
    const items = resp.data?.info ?? [];
    for (const item of items) {
      const song = kgSong(item);
      if (song.id.length > 0) {
        list.push(song);
      }
    }
    return list;
  }

  private async kgSearchSheets(keyword: string, page: number): Promise<SheetInfo[]> {
    const url = 'https://mobiles.kugou.com/api/v3/search/special?keyword=' + encodeURIComponent(keyword) +
      '&page=' + page.toString() + '&pagesize=20';
    const resp = await getJson<KgSpecialResp>(url, KG_REF);
    const list: SheetInfo[] = [];
    const items = resp.data?.info ?? [];
    for (const item of items) {
      const sheet = newSheet('kg', 'playlist');
      sheet.id = (item.specialid ?? 0).toString();
      sheet.name = item.specialname ?? '';
      sheet.cover = fixCover((item.imgurl ?? '').replace('{size}', '300'));
      sheet.description = item.intro ?? '';
      sheet.trackCount = item.songcount ?? 0;
      sheet.playCount = item.playcount ?? 0;
      sheet.creator = item.nickname ?? '酷狗音乐';
      if (sheet.id !== '0') {
        list.push(sheet);
      }
    }
    return list;
  }

  /**
   * 歌单详情。接口默认只给 100 首，长歌单一进去就少一截；
   * pagesize 实测可放到 1000（417 首的榜单一次取完，约 50~230ms），
   * 超过 1000 首的再补一页，最多 2000 首。
   * 注意：这里返回的条目没有 songname/singername，只有 filename「歌手 - 歌名」，
   * 由 kgSong 的兜底拆分补出名字与歌手。
   */
  private async kgSpecialSongs(id: string): Promise<SongInfo[]> {
    const list: SongInfo[] = [];
    const pageSize = 1000;
    for (let page = 1; page <= 2; page++) {
      const url = 'https://mobiles.kugou.com/api/v3/special/song?specialid=' + id +
        '&page=' + page.toString() + '&pagesize=' + pageSize.toString() + '&apiver=2';
      const resp = await getJson<KgResp>(url, KG_REF);
      const items = resp.data?.info ?? [];
      for (const item of items) {
        const song = kgSong(item);
        if (song.id.length > 0) {
          list.push(song);
        }
      }
      const total = resp.data?.total ?? 0;
      if (items.length < pageSize || (total > 0 && list.length >= total)) {
        break;
      }
    }
    return list;
  }

  private async kgSearchArtists(keyword: string): Promise<ArtistInfo[]> {
    const url = 'https://mobiles.kugou.com/api/v3/search/singer?keyword=' + encodeURIComponent(keyword) +
      '&page=1&pagesize=20';
    const resp = await getJson<KgSingerResp>(url, KG_REF);
    const list: ArtistInfo[] = [];
    const items = resp.data ?? [];
    for (const item of items) {
      const artist: ArtistInfo = {
        id: (item.singerid ?? 0).toString(),
        name: item.singername ?? '',
        // 实测 /api/v3/search/singer 只回 singername + singerid，没有 imgurl；
        // 真头像在 /api/v3/singer/info 的 imgurl（带 {size} 占位），下面并发补齐。
        // 不能按 singerid 拼 singerimg.kugou.com/uploadpic/softhead/400/<id>.jpg：
        // 实测不同 id 会返回同一张兜底图，所有歌手头像会变成一张脸。
        avatar: fixCover(item.imgurl ?? ''),
        platform: 'kg',
        subtitle: '酷狗音乐'
      };
      list.push(artist);
    }
    // 只补首屏可见的前 8 个，避免一次并发 20 个详情请求拖慢搜索。
    const tasks: Promise<string>[] = [];
    const limit: number = Math.min(list.length, 8);
    for (let i = 0; i < limit; i++) {
      tasks.push(this.kgSingerAvatar(list[i].avatar, list[i].id));
    }
    const avatars: string[] = await Promise.all(tasks);
    for (let i = 0; i < limit; i++) {
      list[i].avatar = avatars[i];
    }
    return list;
  }

  /** 酷狗歌手头像：搜索接口不给图，按 singerid 查详情拿 imgurl（fixCover 会替换 {size}） */
  private async kgSingerAvatar(current: string, id: string): Promise<string> {
    if (current.length > 0 || id.length === 0) {
      return current;
    }
    try {
      const url = 'https://mobiles.kugou.com/api/v3/singer/info?singerid=' + id;
      const resp = await getJson<KgSingerInfoResp>(url, KG_REF, 5000);
      return fixCover(resp.data?.imgurl ?? '');
    } catch (e) {
      return '';
    }
  }

  /* ================= 咪咕实现 ================= */
  private async mgSearch(keyword: string, page: number): Promise<SongInfo[]> {
    const url = 'https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/search_all.do?ua=Android_migu&version=5.0.1&text=' +
      encodeURIComponent(keyword) + '&pageNo=' + page.toString() +
      '&pageSize=30&searchSwitch=' + encodeURIComponent('{"song":1,"album":1,"singer":1,"playlist":1}');
    const resp = await getJson<MgSearchResp>(url, MG_REF);
    const list: SongInfo[] = [];
    const songs = resp.songResultData?.result ?? [];
    for (const item of songs) {
      list.push(mgSong(item));
    }
    return list;
  }

  private async mgSearchSheets(keyword: string): Promise<SheetInfo[]> {
    const url = 'https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/search_all.do?ua=Android_migu&version=5.0.1&text=' +
      encodeURIComponent(keyword) + '&pageNo=1&pageSize=20&searchSwitch=' + encodeURIComponent('{"playlist":1}');
    const resp = await getJson<MgPlaylistSearchResp>(url, MG_REF);
    const list: SheetInfo[] = [];
    const items = resp.playlistResultData?.result ?? [];
    for (const item of items) {
      const sheet = newSheet('mg', 'playlist');
      sheet.id = item.id ?? '';
      sheet.name = item.name ?? '';
      sheet.cover = fixCover(item.img ?? '');
      sheet.trackCount = item.musicNum ?? 0;
      sheet.creator = item.ownerName ?? '咪咕音乐';
      if (sheet.id.length > 0) {
        list.push(sheet);
      }
    }
    return list;
  }

  private async mgSearchArtists(keyword: string): Promise<ArtistInfo[]> {
    const url = 'https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/search_all.do?ua=Android_migu&version=5.0.1&text=' +
      encodeURIComponent(keyword) + '&pageNo=1&pageSize=20&searchSwitch=' + encodeURIComponent('{"singer":1}');
    const resp = await getJson<MgSingerSearchResp>(url, MG_REF);
    const list: ArtistInfo[] = [];
    const items = resp.singerResultData?.result ?? [];
    for (const item of items) {
      const artist: ArtistInfo = {
        id: item.id ?? '',
        name: item.name ?? '',
        // 实测 search_all.do 的 singerResultData 只回 id/name/highlightStr，没有 img；
        // 头像留空，由 Cover 的「歌手名首字」占位色块兜底。
        avatar: fixCover(item.img ?? ''),
        platform: 'mg',
        subtitle: '咪咕音乐'
      };
      list.push(artist);
    }
    return list;
  }

  private async mgSheetSongs(id: string): Promise<SongInfo[]> {
    // 咪咕歌单详情接口需要登录态，公开接口只能拿到列表信息，这里返回空而不是假数据
    return [];
  }
}

/* 补充的响应类型 */
interface TxTopSongsResp {
  songlist?: TxOldSongWrap[];
}

interface KgSinger {
  singerid?: number;
  singername?: string;
  imgurl?: string;
}

interface KgSingerResp {
  data?: KgSinger[];
}

interface KgSingerInfoData {
  imgurl?: string;
}

interface KgSingerInfoResp {
  data?: KgSingerInfoData;
}

interface MgPlaylist {
  id?: string;
  name?: string;
  img?: string;
  musicNum?: number;
  ownerName?: string;
}

interface MgPlaylistResult {
  result?: MgPlaylist[];
}

interface MgPlaylistSearchResp {
  playlistResultData?: MgPlaylistResult;
}

interface MgSingerItem {
  id?: string;
  name?: string;
  img?: string;
}

interface MgSingerResultWrap {
  result?: MgSingerItem[];
}

interface MgSingerSearchResp {
  singerResultData?: MgSingerResultWrap;
}

/* ============ 歌手作品 / 酷我歌手搜索 响应类型（v2.13） ============ */

interface WyArtistSongsResp {
  code?: number;
  songs?: WySong[];
  total?: number;
  more?: boolean;
}

interface TxMusicuSinger {
  name?: string;
}

interface TxMusicuAlbum {
  mid?: string;
  name?: string;
}

interface TxMusicuSongInfo {
  id?: number;
  mid?: string;
  name?: string;
  interval?: number;
  singer?: TxMusicuSinger[];
  album?: TxMusicuAlbum;
}

interface TxMusicuItem {
  songInfo?: TxMusicuSongInfo;
}

interface TxMusicuData {
  totalNum?: number;
  songList?: TxMusicuItem[];
}

interface TxMusicuReqBody {
  code?: number;
  data?: TxMusicuData;
}

interface TxMusicuResp {
  code?: number;
  req?: TxMusicuReqBody;
}

import { SongInfo, SheetInfo, newSong, newSheet, secondsToInterval } from '../common/Models';
import { wyPost, wyFixCover } from './WyApi';
import { WyAccount } from './WyAccount';

/**
 * 基于本人账号的网易云推荐数据。
 *
 * v2.64：这些接口都要求登录态（带 MUSIC_U Cookie），返回的是账号画像生成的
 * 每日推荐 / 我喜欢的音乐，而不是匿名兜底内容。统一转成工程的 SongInfo /
 * SheetInfo，点播走既有音源取链，core 取链/播放/下载一行不改。
 */

interface WyArtist { name?: string; }
interface WyAlbum { name?: string; picUrl?: string; blurPicUrl?: string; id?: number; }
interface WyRawSong {
  id?: number;
  name?: string;
  ar?: WyArtist[];
  artists?: WyArtist[];
  al?: WyAlbum;
  album?: WyAlbum;
  dt?: number;
  duration?: number;
  fee?: number;
  alias?: string[];
}
interface WyCreator { nickname?: string; userId?: number; }
interface WyRawSheet {
  id?: number;
  name?: string;
  picUrl?: string;
  coverImgUrl?: string;
  description?: string;
  trackCount?: number;
  playcount?: number;
  playCount?: number;
  creator?: WyCreator;
  updateTime?: number;
  copywriter?: string;
}
// ArkTS 严格模式禁止内联对象字面量当类型（arkts-no-obj-literals-as-types），
// 嵌套结构一律拆成具名 interface。
interface DailySongsData { dailySongs?: WyRawSong[]; }
interface DailySongsResp { code?: number; data?: DailySongsData; }
interface RecommendResp { code?: number; recommend?: WyRawSheet[]; }
interface UserPlaylistResp { code?: number; playlist?: WyRawSheet[]; }

function songOf(raw: WyRawSong): SongInfo {
  const song = newSong('wy');
  song.id = (raw.id ?? 0).toString();
  song.songmid = song.id;
  song.name = raw.name ?? '';
  const artists = raw.ar ?? raw.artists ?? [];
  const names: string[] = [];
  for (const a of artists) {
    names.push(a.name ?? '');
  }
  song.singer = names.join(' / ');
  const album = raw.al ?? raw.album;
  song.album = album?.name ?? '';
  song.albumName = song.album;
  song.albumId = album?.id !== undefined ? album.id.toString() : '';
  song.duration = Math.floor((raw.dt ?? raw.duration ?? 0) / 1000);
  song.interval = secondsToInterval(song.duration);
  song.cover = wyFixCover(album?.picUrl ?? album?.blurPicUrl ?? '');
  song.fee = raw.fee ?? 0;
  return song;
}

function sheetOf(raw: WyRawSheet, kind: string): SheetInfo {
  const sheet = newSheet('wy', kind);
  sheet.id = (raw.id ?? 0).toString();
  sheet.name = raw.name ?? '';
  sheet.cover = wyFixCover(raw.coverImgUrl ?? raw.picUrl ?? '');
  sheet.description = raw.description ?? raw.copywriter ?? '';
  sheet.trackCount = raw.trackCount ?? 0;
  sheet.playCount = raw.playCount ?? raw.playcount ?? 0;
  sheet.creator = raw.creator?.nickname ?? '网易云音乐';
  if (raw.updateTime !== undefined) {
    const d = new Date(raw.updateTime);
    sheet.updateTime = (d.getMonth() + 1).toString() + '月' + d.getDate().toString() + '日';
  }
  sheet.subtitle = raw.copywriter ?? '';
  return sheet;
}

async function post(path: string, data: Record<string, Object>): Promise<string> {
  const account = WyAccount.get();
  if (!account.isLoggedIn()) {
    return '';
  }
  const reply = await wyPost(path, data, account.cookie());
  return reply.ok ? reply.body : '';
}

export class WyRecommend {
  /** 每日推荐歌曲（本人账号画像，通常 30 首） */
  static async dailySongs(): Promise<SongInfo[]> {
    const body = await post('/weapi/v3/discovery/recommend/songs', {});
    if (body.length === 0) {
      return [];
    }
    try {
      const resp = JSON.parse(body) as DailySongsResp;
      const list = resp.data?.dailySongs ?? [];
      const out: SongInfo[] = [];
      for (const raw of list) {
        out.push(songOf(raw));
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  /** 每日推荐歌单（本人账号） */
  static async dailySheets(): Promise<SheetInfo[]> {
    const body = await post('/weapi/v1/discovery/recommend/resource', {});
    if (body.length === 0) {
      return [];
    }
    try {
      const resp = JSON.parse(body) as RecommendResp;
      const list = resp.recommend ?? [];
      const out: SheetInfo[] = [];
      for (const raw of list) {
        out.push(sheetOf(raw, 'playlist'));
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  /** 我的歌单（含「我喜欢的音乐」） */
  static async mySheets(): Promise<SheetInfo[]> {
    const account = WyAccount.get();
    const data: Record<string, Object> = {
      'uid': account.uid(),
      'limit': 50,
      'offset': 0
    };
    const body = await post('/weapi/user/playlist', data);
    if (body.length === 0) {
      return [];
    }
    try {
      const resp = JSON.parse(body) as UserPlaylistResp;
      const list = resp.playlist ?? [];
      const out: SheetInfo[] = [];
      for (const raw of list) {
        out.push(sheetOf(raw, 'user'));
      }
      return out;
    } catch (e) {
      return [];
    }
  }
}

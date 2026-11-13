import { SheetInfo, SongInfo } from '../common/Models';

/**
 * 榜单内存缓存（进程内，不落盘）。
 *
 * 背景：首页会一次性把 5 个平台的榜单列表拉一遍，用户点进「酷我排行榜」时
 * 榜单页又把同一份列表拉了一遍；酷我那边十几个子榜要逐个请求，实测光列表
 * 就要 600ms 左右，加上取歌，进页面先白屏一秒多。
 *
 * 这里把「平台 → 子榜列表」和「平台 + 子榜 → 歌曲」各存一份，页面进来先拿
 * 缓存铺满，再后台刷新，做到：返回再进不闪、切子榜不转圈、首屏只等取歌。
 */

class BoardEntry {
  list: SheetInfo[] = [];
  at: number = 0;
}

class SongEntry {
  list: SongInfo[] = [];
  at: number = 0;
}

/** 榜单列表一天才更新一次，10 分钟内直接复用 */
const BOARD_TTL: number = 10 * 60 * 1000;
/** 榜单歌曲实时性要求高一些，5 分钟 */
const SONG_TTL: number = 5 * 60 * 1000;
/** 上限，避免长时间使用后内存无限涨（一个榜单 100 首，30 个榜单约 3000 条） */
const MAX_BOARDS: number = 8;
const MAX_SONGS: number = 30;

export class RankCache {
  private static boards: Map<string, BoardEntry> = new Map<string, BoardEntry>();
  private static songs: Map<string, SongEntry> = new Map<string, SongEntry>();

  static keyOf(platform: string, boardId: string): string {
    return platform + '|' + boardId;
  }

  /** 新鲜的榜单列表；过期或没有返回 null */
  static freshBoards(platform: string): SheetInfo[] | null {
    const hit: BoardEntry | undefined = RankCache.boards.get(platform);
    if (hit === undefined || hit.list.length === 0) {
      return null;
    }
    if (Date.now() - hit.at > BOARD_TTL) {
      return null;
    }
    return hit.list;
  }

  /** 哪怕是旧的也返回，用于页面先把内容铺出来 */
  static anyBoards(platform: string): SheetInfo[] | null {
    const hit: BoardEntry | undefined = RankCache.boards.get(platform);
    if (hit === undefined || hit.list.length === 0) {
      return null;
    }
    return hit.list;
  }

  static putBoards(platform: string, list: SheetInfo[]): void {
    if (list.length === 0) {
      return;
    }
    if (RankCache.boards.size >= MAX_BOARDS && !RankCache.boards.has(platform)) {
      RankCache.boards.clear();
    }
    const entry = new BoardEntry();
    entry.list = list;
    entry.at = Date.now();
    RankCache.boards.set(platform, entry);
  }

  static freshSongs(platform: string, boardId: string): SongInfo[] | null {
    const key = RankCache.keyOf(platform, boardId);
    const hit: SongEntry | undefined = RankCache.songs.get(key);
    if (hit === undefined || hit.list.length === 0) {
      return null;
    }
    if (Date.now() - hit.at > SONG_TTL) {
      return null;
    }
    return hit.list;
  }

  static anySongs(platform: string, boardId: string): SongInfo[] | null {
    const key = RankCache.keyOf(platform, boardId);
    const hit: SongEntry | undefined = RankCache.songs.get(key);
    if (hit === undefined || hit.list.length === 0) {
      return null;
    }
    return hit.list;
  }

  static putSongs(platform: string, boardId: string, list: SongInfo[]): void {
    if (list.length === 0) {
      return;
    }
    const key = RankCache.keyOf(platform, boardId);
    if (RankCache.songs.size >= MAX_SONGS && !RankCache.songs.has(key)) {
      // 简单粗暴：满了就整体清一次，命中率靠前面的热度足够
      RankCache.songs.clear();
    }
    const entry = new SongEntry();
    entry.list = list;
    entry.at = Date.now();
    RankCache.songs.set(key, entry);
  }

  /** 换平台/换音源后手动清空 */
  static clear(): void {
    RankCache.boards.clear();
    RankCache.songs.clear();
  }
}

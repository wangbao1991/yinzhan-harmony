import { SongInfo, songKey } from '../common/Models';
import { PrefKeys } from '../common/Constants';
import { Store } from './Store';
import { Library } from './Library';

/**
 * 真实收听统计。
 *
 * 数据来源只有一处：播放器 AVPlayer 的 `timeUpdate` 回调里前后两帧的进度差。
 * 不做任何「每秒 +1」的模拟，也不靠 UI 页面的定时器——累计发生在播放回调里，
 * 所以切到别的页面、甚至锁屏后台播放，统计照样准确。
 *
 * v2.4 起界面层的「音栈·驿站」看板与「月·回响」报告页已整体下线，
 * 本统计层保留：数据继续在后台真实记录，暂不参与任何界面，供后续功能直接复用。
 *
 * 两套存储，各管各的时间尺度：
 *   - hours / artists / known / newDays：小时桶与全局集合，保留 31 天，对应短周期实时视图；
 *   - days / meta：按「本地天」归档的播放事件日志，保留 400 天（13 个月），
 *     对应按自然月的周期回顾。按日归档是必须的：回顾要能回看去年某月，
 *     而 31 天的小时桶留不住跨月数据。
 *
 * 真实性保障：
 *   - delta <= 0（回退/重播）或 delta > 3000ms（拖动进度条、卡顿跳变）一律不计；
 *   - 切歌帧不上报时长，只重置基准；
 *   - 暂停后 timeUpdate 不再触发，自然不累计；
 *   - 时间桶用「本地小时序号」而非 UTC，生物钟的 24 根柱才对得上本机时间。
 *
 * 数据量有上限：小时桶 31 天、日归档 400 天、歌曲元数据 3000 条、已知歌曲 3000 条，
 * 每次落盘前裁剪，不会随使用时间无限增长。
 */

interface SongMeta {
  key: string;
  name: string;
  singer: string;
  album: string;
  cover: string;
}

interface SongPlay {
  key: string;
  plays: number;
  ms: number;
  finished: number;
}

interface DayStat {
  /** 本地天序号 */
  day: number;
  /** 当日真实收听毫秒 */
  ms: number;
  /** 当日播放次数（每次切到一首歌 +1） */
  plays: number;
  /** 当日首次收听的新歌数 */
  newSongs: number;
  songs: SongPlay[];
  /** [当天小时 0~23, 该小时真实收听毫秒]：报告页「听歌时段」用，跨月也能算 */
  hourMs: Array<[number, number]>;
}

interface StatsData {
  hours: Array<[number, number]>;
  artists: Array<[string, number]>;
  known: string[];
  newDays: Array<[number, number]>;
  days: DayStat[];
  meta: SongMeta[];
}

/** 报告页用的榜单条目 */
export interface RankItem {
  key: string;
  name: string;
  singer: string;
  cover: string;
  plays: number;
  ratio: number;
}

/** 报告页用的整月聚合结果 */
export interface MonthReport {
  year: number;
  month: number;
  minutes: number;
  totalMs: number;
  plays: number;
  songCount: number;
  artistCount: number;
  activeDays: number;
  longestStreak: number;
  bestDayDate: number;
  bestDayPlays: number;
  topSongs: RankItem[];
  topArtists: RankItem[];
  topAlbum: RankItem;
  hourBars: number[];
  peakHour: number;
  dayCells: number[];
  daysInMonth: number;
  finishRate: number;
  repeatSongs: number;
  onceSongs: number;
  avgMinutes: number;
  newSongs: number;
  prevMinutes: number;
  hasData: boolean;
}

/** 年/月选择器的一项 */
export interface MonthOption {
  year: number;
  month: number;
  label: string;
}

interface SongAgg {
  key: string;
  plays: number;
  ms: number;
}

interface SimpleAgg {
  name: string;
  plays: number;
  cover: string;
}

const HOUR_MS: number = 3600000;
const DAY_MS: number = 86400000;
const DELTA_LIMIT: number = 3000;
const KEEP_HOURS: number = 31 * 24;
const KEEP_DAYS: number = 31;
/** 日归档保留 400 天 ≈ 13 个月，够回看去年同一个月 */
const KEEP_REPORT_DAYS: number = 400;
const MAX_KNOWN: number = 3000;
const MAX_META: number = 3000;
const FLUSH_GAP: number = 20000;

function emptyRank(): RankItem {
  return { key: '', name: '', singer: '', cover: '', plays: 0, ratio: 0 };
}

function firstArtist(singer: string): string {
  return singer.split('/')[0].split('&')[0].trim();
}

export class PlayStats {
  private static instance: PlayStats = new PlayStats();

  static get(): PlayStats {
    return PlayStats.instance;
  }

  private data: StatsData = { hours: [], artists: [], known: [], newDays: [], days: [], meta: [] };
  private loaded: boolean = false;
  private tzOffset: number = 0;
  private lastPos: number = -1;
  private lastSong: string = '';
  private lastFlush: number = 0;

  init(): void {
    if (this.loaded) {
      return;
    }
    this.loaded = true;
    this.tzOffset = -new Date().getTimezoneOffset() * 60000;
    try {
      const text = Store.get().getString(PrefKeys.PLAY_STATS, '');
      if (text.length > 0) {
        const d = JSON.parse(text) as StatsData;
        this.data.hours = d.hours instanceof Array ? d.hours : [];
        this.data.artists = d.artists instanceof Array ? d.artists : [];
        this.data.known = d.known instanceof Array ? d.known : [];
        this.data.newDays = d.newDays instanceof Array ? d.newDays : [];
        // 旧版本（v2.1）没有这两个字段，兼容成空数组，不要整个 data 丢弃
        this.data.days = d.days instanceof Array ? d.days : [];
        this.data.meta = d.meta instanceof Array ? d.meta : [];
      }
    } catch (e) {
      this.data = { hours: [], artists: [], known: [], newDays: [], days: [], meta: [] };
    }
    // 从旧版本升级：把已有的「最近播放」并入 known，
    // 否则下次听这些老歌会被误判成「今天探索到的新歌」。时长无法凭空补，保持为 0。
    if (this.data.known.length === 0) {
      for (const song of Library.get().getHistory()) {
        const key = songKey(song);
        if (key.length > 2 && this.data.known.indexOf(key) < 0) {
          this.data.known.push(key);
        }
      }
      this.save(true);
    }
  }

  /**
   * v2.22 备份恢复后重新读盘。统计层是单例、启动时只读一次；不重读的话
   * 恢复完界面仍用旧的内存数据。lastPos / lastSong 属于正在播放的进度基准，
   * 保持不动，避免恢复动作打断当前播放的累计。
   */
  reload(): void {
    this.loaded = false;
    this.init();
  }

  private localHour(ts: number): number {
    return Math.floor((ts + this.tzOffset) / HOUR_MS);
  }

  private localDay(ts: number): number {
    return Math.floor((ts + this.tzOffset) / DAY_MS);
  }

  private rangeStart(range: number): number {
    const now = Date.now();
    const day = this.localDay(now);
    if (range === 0) {
      return day * 24;
    }
    if (range === 1) {
      const mondayOffset = (new Date(now).getDay() + 6) % 7;
      return (day - mondayOffset) * 24;
    }
    return (day - (new Date(now).getDate() - 1)) * 24;
  }

  private rangeDayStart(range: number): number {
    return Math.floor(this.rangeStart(range) / 24);
  }

  /* ---------------- 埋点 ---------------- */

  private dayStat(day: number): DayStat {
    for (const d of this.data.days) {
      if (d.day === day) {
        return d;
      }
    }
    const fresh: DayStat = { day: day, ms: 0, plays: 0, newSongs: 0, songs: [], hourMs: [] };
    this.data.days.push(fresh);
    return fresh;
  }

  private songPlay(d: DayStat, key: string): SongPlay {
    for (const s of d.songs) {
      if (s.key === key) {
        return s;
      }
    }
    const fresh: SongPlay = { key: key, plays: 0, ms: 0, finished: 0 };
    d.songs.push(fresh);
    return fresh;
  }

  private metaOf(key: string): SongMeta | null {
    for (const m of this.data.meta) {
      if (m.key === key) {
        return m;
      }
    }
    return null;
  }

  /** 切到一首歌：重置进度基准，记一次播放，并把「从未听过」的歌记进当日新歌 */
  onSongStart(song: SongInfo): void {
    this.lastPos = -1;
    const key = songKey(song);
    this.lastSong = key;
    if (key.length <= 2) {
      return;
    }

    // 元数据只存一份，日归档里只留 key，避免 400 天 × 每首歌都重复长 URL
    if (this.metaOf(key) === null) {
      const meta: SongMeta = {
        key: key,
        name: song.name,
        singer: song.singer,
        album: song.albumName !== undefined && song.albumName.length > 0 ? song.albumName : song.album,
        cover: song.cover
      };
      this.data.meta.push(meta);
      if (this.data.meta.length > MAX_META) {
        this.data.meta = this.data.meta.slice(this.data.meta.length - 2000);
      }
    }

    const day = this.localDay(Date.now());
    const d = this.dayStat(day);
    d.plays += 1;
    const sp = this.songPlay(d, key);
    sp.plays += 1;

    if (this.data.known.indexOf(key) < 0) {
      this.data.known.push(key);
      if (this.data.known.length > MAX_KNOWN) {
        this.data.known = this.data.known.slice(this.data.known.length - 2000);
      }
      d.newSongs += 1;
      let hit = false;
      for (const item of this.data.newDays) {
        if (item[0] === day) {
          item[1] += 1;
          hit = true;
          break;
        }
      }
      if (!hit) {
        const entry: [number, number] = [day, 1];
        this.data.newDays.push(entry);
      }
    }
    this.trim();
    this.save(true);
  }

  /** 播放进度回调：只累计真实前进的那一小段 */
  onProgress(timeMs: number, playing: boolean, song: SongInfo): void {
    if (!playing) {
      this.lastPos = timeMs;
      return;
    }
    if (this.lastPos < 0) {
      this.lastPos = timeMs;
      return;
    }
    const delta = timeMs - this.lastPos;
    this.lastPos = timeMs;
    if (delta <= 0 || delta > DELTA_LIMIT) {
      return;
    }
    const key = songKey(song);
    if (key !== this.lastSong) {
      this.lastSong = key;
      return;
    }
    this.addTime(delta, song);
  }

  /**
   * 一首歌自然播到结尾（AVPlayer stateChange === 'completed'）。
   * 单曲循环也会走到这里；切歌导致的中断不算完播。
   */
  onCompleted(song: SongInfo): void {
    const key = songKey(song);
    if (key.length <= 2) {
      return;
    }
    const d = this.dayStat(this.localDay(Date.now()));
    const sp = this.songPlay(d, key);
    sp.finished += 1;
    this.save(true);
  }

  private addTime(delta: number, song: SongInfo): void {
    const now = Date.now();
    const hour = this.localHour(now);
    let hitHour = false;
    for (const item of this.data.hours) {
      if (item[0] === hour) {
        item[1] += delta;
        hitHour = true;
        break;
      }
    }
    if (!hitHour) {
      const entry: [number, number] = [hour, delta];
      this.data.hours.push(entry);
    }

    const artist = firstArtist(song.singer);
    if (artist.length > 0) {
      let hitArtist = false;
      for (const item of this.data.artists) {
        if (item[0] === artist) {
          item[1] += delta;
          hitArtist = true;
          break;
        }
      }
      if (!hitArtist) {
        const pair: [string, number] = [artist, delta];
        this.data.artists.push(pair);
      }
    }

    // 日归档：当天总时长、这首歌的时长、当天小时分布
    const day = this.localDay(now);
    const d = this.dayStat(day);
    d.ms += delta;
    const sp = this.songPlay(d, songKey(song));
    sp.ms += delta;
    const h = ((hour % 24) + 24) % 24;
    let hitDayHour = false;
    for (const item of d.hourMs) {
      if (item[0] === h) {
        item[1] += delta;
        hitDayHour = true;
        break;
      }
    }
    if (!hitDayHour) {
      const pair: [number, number] = [h, delta];
      d.hourMs.push(pair);
    }
    this.save(false);
  }

  /** 播放暂停 / 应用退到后台时立刻落盘，最多丢 20 秒节流窗口 */
  flush(): void {
    this.save(true);
  }

  private trim(): void {
    const hourCut = this.localHour(Date.now()) - KEEP_HOURS;
    const dayCut = this.localDay(Date.now()) - KEEP_DAYS;
    const reportCut = this.localDay(Date.now()) - KEEP_REPORT_DAYS;
    const hours: Array<[number, number]> = [];
    for (const item of this.data.hours) {
      if (item[0] >= hourCut) {
        hours.push(item);
      }
    }
    this.data.hours = hours;
    const days: Array<[number, number]> = [];
    for (const item of this.data.newDays) {
      if (item[0] >= dayCut) {
        days.push(item);
      }
    }
    this.data.newDays = days;
    const kept: DayStat[] = [];
    for (const d of this.data.days) {
      if (d.day >= reportCut) {
        kept.push(d);
      }
    }
    this.data.days = kept;
  }

  /**
   * 只序列化写盘的两种时机：
   *   - force：切歌 / 完播 / 暂停 / 初始化，立刻写；
   *   - 播放中：每 20 秒写一次。
   * 不再每帧 stringify 整份 400 天日志（那会明显拖 UI 线程）。
   */
  private save(force: boolean): void {
    this.trim();
    const now = Date.now();
    if (force || now - this.lastFlush > FLUSH_GAP) {
      Store.get().put(PrefKeys.PLAY_STATS, JSON.stringify(this.data));
      this.lastFlush = now;
    }
  }

  /* ---------------- 看板读取（v2.1 接口，保持不变） ---------------- */

  minutesInRange(range: number): number {
    const start = this.rangeStart(range);
    let ms = 0;
    for (const item of this.data.hours) {
      if (item[0] >= start) {
        ms += item[1];
      }
    }
    return ms / 60000;
  }

  todayMinutes(): number {
    return this.minutesInRange(0);
  }

  trendPoints(range: number): number[] {
    const width = range === 0 ? 1 : (range === 1 ? 7 : 30);
    const endBucket = Math.floor(this.localHour(Date.now()) / width);
    const raw: number[] = [];
    for (let i = 23; i >= 0; i--) {
      const bucket = endBucket - i;
      const from = bucket * width;
      const to = from + width;
      let ms = 0;
      for (const item of this.data.hours) {
        if (item[0] >= from && item[0] < to) {
          ms += item[1];
        }
      }
      raw.push(ms);
    }
    let max = 1;
    for (const v of raw) {
      if (v > max) {
        max = v;
      }
    }
    const out: number[] = [];
    for (const v of raw) {
      out.push(0.12 + Math.min(1, v / max) * 0.76);
    }
    return out;
  }

  hourBuckets(range: number): number[] {
    const start = this.rangeStart(range);
    const raw: number[] = [];
    for (let i = 0; i < 24; i++) {
      raw.push(0);
    }
    for (const item of this.data.hours) {
      if (item[0] >= start) {
        const h = ((item[0] % 24) + 24) % 24;
        raw[h] += item[1];
      }
    }
    let max = 1;
    for (const v of raw) {
      if (v > max) {
        max = v;
      }
    }
    const out: number[] = [];
    for (const v of raw) {
      out.push(v > 0 ? Math.max(0.10, v / max) : 0.06);
    }
    return out;
  }

  topArtist(): string {
    let name = '';
    let best = 0;
    for (const item of this.data.artists) {
      if (item[1] > best) {
        best = item[1];
        name = item[0];
      }
    }
    return name;
  }

  newSongsInRange(range: number): number {
    const start = this.rangeDayStart(range);
    let total = 0;
    for (const item of this.data.newDays) {
      if (item[0] >= start) {
        total += item[1];
      }
    }
    return total;
  }

  bucketIndexOf(range: number): number {
    const width = range === 0 ? 1 : (range === 1 ? 7 : 30);
    return Math.floor(this.localHour(Date.now()) / width);
  }

  hasAnyData(): boolean {
    return this.data.hours.length > 0;
  }

  /* ---------------- 报告读取（v2.2 新增） ---------------- */

  /** 最近 13 个月（含当前月），供年/月选择器使用 */
  availableMonths(): MonthOption[] {
    const now = new Date();
    const out: MonthOption[] = [];
    for (let i = 0; i < 13; i++) {
      const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
      const y = d.getFullYear();
      const m = d.getMonth() + 1;
      const label: string = y.toString() + ' 年 ' + m.toString() + ' 月';
      out.push({ year: y, month: m, label: label });
    }
    return out;
  }

  private monthDayStart(year: number, month: number): number {
    return Math.floor((new Date(year, month - 1, 1).getTime() + this.tzOffset) / DAY_MS);
  }

  private sumMinutes(from: number, to: number): number {
    let ms = 0;
    for (const d of this.data.days) {
      if (d.day >= from && d.day < to) {
        ms += d.ms;
      }
    }
    return ms / 60000;
  }

  private static addAgg(list: SimpleAgg[], name: string, plays: number, cover: string): void {
    for (const item of list) {
      if (item.name === name) {
        item.plays += plays;
        if (item.cover.length === 0 && cover.length > 0) {
          item.cover = cover;
        }
        return;
      }
    }
    list.push({ name: name, plays: plays, cover: cover });
  }

  /** 按自然月聚合出「月·回响」报告需要的全部数值 */
  reportOf(year: number, month: number): MonthReport {
    const start = this.monthDayStart(year, month);
    // month 传 12 时 Date(year, 12, 1) 会自动进到下一年 1 月，正好是月末
    const end = this.monthDayStart(year, month + 1);
    const dim = end - start;
    const dayCells: number[] = [];
    for (let i = 0; i < dim; i++) {
      dayCells.push(0);
    }
    const hourRaw: number[] = [];
    for (let i = 0; i < 24; i++) {
      hourRaw.push(0);
    }

    let totalMs = 0;
    let plays = 0;
    let newSongs = 0;
    let finished = 0;
    const songs: SongAgg[] = [];
    const artists: SimpleAgg[] = [];
    const albums: SimpleAgg[] = [];

    for (const d of this.data.days) {
      if (d.day < start || d.day >= end) {
        continue;
      }
      totalMs += d.ms;
      plays += d.plays;
      newSongs += d.newSongs;
      const idx = d.day - start;
      if (idx >= 0 && idx < dim) {
        dayCells[idx] = d.plays;
      }
      for (const hm of d.hourMs) {
        if (hm[0] >= 0 && hm[0] < 24) {
          hourRaw[hm[0]] += hm[1];
        }
      }
      for (const sp of d.songs) {
        finished += sp.finished;
        let hit = false;
        for (const agg of songs) {
          if (agg.key === sp.key) {
            agg.plays += sp.plays;
            agg.ms += sp.ms;
            hit = true;
            break;
          }
        }
        if (!hit) {
          songs.push({ key: sp.key, plays: sp.plays, ms: sp.ms });
        }
        const meta = this.metaOf(sp.key);
        const singer = meta !== null ? firstArtist(meta.singer) : '';
        const album = meta !== null ? meta.album : '';
        const cover = meta !== null ? meta.cover : '';
        if (singer.length > 0) {
          PlayStats.addAgg(artists, singer, sp.plays, cover);
        }
        if (album.length > 0) {
          PlayStats.addAgg(albums, album, sp.plays, cover);
        }
      }
    }

    songs.sort((a: SongAgg, b: SongAgg): number => b.plays - a.plays);
    artists.sort((a: SimpleAgg, b: SimpleAgg): number => b.plays - a.plays);
    albums.sort((a: SimpleAgg, b: SimpleAgg): number => b.plays - a.plays);

    const ratioOf = (p: number): number => plays > 0 ? Math.round(p / plays * 100) : 0;
    const topSongs: RankItem[] = [];
    for (let i = 0; i < songs.length && i < 3; i++) {
      const meta = this.metaOf(songs[i].key);
      topSongs.push({
        key: songs[i].key,
        name: meta !== null ? meta.name : songs[i].key,
        singer: meta !== null ? meta.singer : '',
        cover: meta !== null ? meta.cover : '',
        plays: songs[i].plays,
        ratio: ratioOf(songs[i].plays)
      });
    }
    const topArtists: RankItem[] = [];
    for (let i = 0; i < artists.length && i < 4; i++) {
      topArtists.push({
        key: artists[i].name,
        name: artists[i].name,
        singer: '',
        cover: artists[i].cover,
        plays: artists[i].plays,
        ratio: ratioOf(artists[i].plays)
      });
    }
    const topAlbum: RankItem = albums.length > 0 ? {
      key: albums[0].name,
      name: albums[0].name,
      singer: '',
      cover: albums[0].cover,
      plays: albums[0].plays,
      ratio: ratioOf(albums[0].plays)
    } : emptyRank();

    const hourBars: number[] = [];
    let hourMax = 1;
    let peakHour = -1;
    for (let i = 0; i < 24; i++) {
      if (hourRaw[i] > hourMax) {
        hourMax = hourRaw[i];
        peakHour = i;
      }
    }
    for (let i = 0; i < 24; i++) {
      hourBars.push(hourRaw[i] > 0 ? Math.max(0.10, hourRaw[i] / hourMax) : 0.05);
    }

    let activeDays = 0;
    let streak = 0;
    let longestStreak = 0;
    let bestDayDate = 0;
    let bestDayPlays = 0;
    for (let i = 0; i < dim; i++) {
      const v = dayCells[i];
      if (v > 0) {
        activeDays += 1;
        streak += 1;
        if (streak > longestStreak) {
          longestStreak = streak;
        }
        if (v > bestDayPlays) {
          bestDayPlays = v;
          bestDayDate = i + 1;
        }
      } else {
        streak = 0;
      }
    }

    let repeatSongs = 0;
    let onceSongs = 0;
    for (const agg of songs) {
      if (agg.plays >= 2) {
        repeatSongs += 1;
      } else {
        onceSongs += 1;
      }
    }

    const minutes = Math.round(totalMs / 60000);
    const prevStart = this.monthDayStart(year, month - 1);
    return {
      year: year,
      month: month,
      minutes: minutes,
      totalMs: totalMs,
      plays: plays,
      songCount: songs.length,
      artistCount: artists.length,
      activeDays: activeDays,
      longestStreak: longestStreak,
      bestDayDate: bestDayDate,
      bestDayPlays: bestDayPlays,
      topSongs: topSongs,
      topArtists: topArtists,
      topAlbum: topAlbum,
      hourBars: hourBars,
      peakHour: peakHour,
      dayCells: dayCells,
      daysInMonth: dim,
      // 单曲循环时 finished 可能超过 plays，完播率封顶 100
      finishRate: plays > 0 ? Math.min(100, Math.round(finished / plays * 100)) : 0,
      repeatSongs: repeatSongs,
      onceSongs: onceSongs,
      avgMinutes: activeDays > 0 ? Math.round(minutes / activeDays) : 0,
      newSongs: newSongs,
      prevMinutes: Math.round(this.sumMinutes(prevStart, start)),
      hasData: totalMs > 0 || plays > 0
    };
  }
}

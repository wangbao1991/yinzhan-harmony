import { SongInfo, LyricDoc, LyricLine, emptyLyric, LxInvokeInfo, SourceItem } from '../common/Models';
import { getJson, getText } from './Http';
import util from '@ohos.util';
import { parseLrc, looksLikeMarkup, looksLikeNonLyric } from './Lrc';
import { SourceRepo } from './SourceRepo';
import { Settings } from './Settings';
import { PlatformApi } from './PlatformApi';
import { firstSinger } from '../common/Utils';

/** 音源 / 歌词接口可能返回的歌词对象形态 */
interface LxLyricRaw {
  lyric?: string;
  tlyric?: string;
  lxlyric?: string;
  lrc?: string;
  trans?: string;
  lyricContent?: string;
  data?: LxLyricRaw;
  resource?: LxLyricRaw[];
}

interface WyLyricBody {
  lrc?: WyLyricText;
  tlyric?: WyLyricText;
  klyric?: WyLyricText;
}

interface WyLyricText {
  lyric?: string;
}

interface TxLyricResp {
  lyric?: string;
  trans?: string;
  retcode?: number;
}

interface KgCandidate {
  id?: string;
  accesskey?: string;
  song?: string;
  singer?: string;
  duration?: number;
}

interface KgSearchResp {
  candidates?: KgCandidate[];
}

interface KgDownloadResp {
  content?: string;
  fmt?: string;
}

interface KwLyricLine {
  lineLyric?: string;
  time?: string;
}

interface KwLyricData {
  lrclist?: KwLyricLine[];
}

interface KwLyricBody {
  data?: KwLyricData;
}

interface LrclibItem {
  id?: number;
  trackName?: string;
  artistName?: string;
  duration?: number;
  syncedLyrics?: string;
  plainLyrics?: string;
}

/** 咪咕搜索结果的歌曲条目（只取歌词相关字段） */
interface MgSong {
  id?: string;
  copyrightId?: string;
  name?: string;
  lyricUrl?: string;
  trcUrl?: string;
}

interface MgSongResult {
  result?: MgSong[];
}

interface MgSearchResp {
  songResultData?: MgSongResult;
}

/** 咪咕详情接口 resourceinfo.do 的条目 */
interface MgResourceItem {
  songId?: string;
  copyrightId?: string;
  songName?: string;
  singer?: string;
  lrcUrl?: string;
  trcUrl?: string;
}

interface MgResourceResp {
  code?: string;
  resource?: MgResourceItem[];
}

/** 手动搜索歌词的候选项 */
export interface LyricCandidate {
  name: string;
  singer: string;
  source: string;
  lrc: string;
  trans: string;
  preview: string;
}

interface DocRaceState {
  left: number;
  settled: boolean;
}

const SCRIPT_TIMEOUT: number = 3500;
const PLATFORM_TIMEOUT: number = 5000;
const LRCLIB_TIMEOUT: number = 5000;
const BATCH2_DEADLINE: number = 9000;
const MG_REF: string = 'https://m.music.migu.cn/';

/**
 * 歌词仓库：按来源可信度分三级，前者拿不到才走下一级。
 *
 * 第一级：本平台官方歌词（按 id / songmid / hash 精确取，唯一能保证词属于这首歌）
 * 第二级：官方真歌词 —— 本平台按「歌名 + 歌手」回查精确 id、其它平台同名严格匹配、LRCLIB
 * 第三级：音源脚本（按歌名去别的平台搜，来源最不可控，且返回值要过内容校验）
 *
 * v2.35 以前第二、三级混在一批里竞速，音源脚本先返回就会被采用：
 * 脚本偶尔把音频直链 / 接口错误页塞进 lyric 字段，播放页就显示一整屏网址，
 * 来源还标着「音源·聚合音源」。现在脚本降到最后，且所有非歌词文本一律丢弃。
 *
 * 更早是「音源 → 平台 → LRCLIB」全串行，且平台只覆盖 wy/tx/kg/kw：
 * 咪咕、qsvip、自定义源以及无 inited 上报的音源全部掉到国内基本不通的
 * LRCLIB，表现为「有的平台不显示歌词，重找也找不到」。
 */
export class LyricRepo {
  private static instance: LyricRepo = new LyricRepo();
  static get(): LyricRepo {
    return LyricRepo.instance;
  }

  private cache: Map<string, LyricDoc> = new Map<string, LyricDoc>();
  private max: number = 40;
  private sources: SourceRepo = SourceRepo.get();

  clear(): void {
    this.cache.clear();
  }

  /** 重新找歌词时用：只丢掉这一首的缓存，别把整个缓存冲掉 */
  invalidate(song: SongInfo): void {
    this.cache.delete(this.keyOf(song));
  }

  private keyOf(song: SongInfo): string {
    return song.source + '|' + song.id + '|' + song.songmid;
  }

  async get(song: SongInfo): Promise<LyricDoc> {
    const key = this.keyOf(song);
    const hit = this.cache.get(key);
    if (hit !== undefined) {
      return hit;
    }
    let doc = emptyLyric();

    // 第一优先：本平台官方歌词，按 id / songmid / hash 精确取，
    // 这是唯一能保证「词属于这首歌」的来源。以前它和音源脚本并发竞速，
    // 脚本按歌名去别的平台搜、先返回就被采用 —— 表现为「歌词是其他平台的」。
    if (LyricRepo.hasOfficial(song.source)) {
      doc = await this.fromPlatform(song);
    }

    // 第二优先：官方真歌词 —— 本平台按「歌名 + 歌手」回查一次，
    // 再用其它平台同名严格匹配，加 LRCLIB。以前音源脚本和官方词同批竞速，
    // 脚本按歌名去别的平台搜、先返回就被采用，甚至会把音频直链当歌词返回：
    // 表现为「不一定哪首歌，歌词区是一整屏网址，来源写着音源·聚合音源」。
    // 现在脚本降到最后，且脚本结果同样要过 looksLikeNonLyric 校验。
    if (doc.lines.length === 0) {
      const batch: Array<Promise<LyricDoc>> = [];
      batch.push(this.fromCrossPlatform(song));
      batch.push(this.fromLrclib(song));
      doc = await LyricRepo.withDeadline(batch, BATCH2_DEADLINE);
    }
    if (doc.lines.length === 0) {
      doc = await LyricRepo.withDeadline([this.fromScript(song)], SCRIPT_TIMEOUT + 1000);
    }

    if (doc.lines.length > 0) {
      if (this.cache.size >= this.max) {
        this.cache.clear();
      }
      this.cache.set(key, doc);
    }
    return doc;
  }

  /** 这些平台有按 id 精确取词的官方接口；qsvip / 自定义源只能走脚本或跨平台 */
  private static hasOfficial(source: string): boolean {
    return source === 'wy' || source === 'tx' || source === 'kg' || source === 'kw' || source === 'mg';
  }

  /** 手动选中的歌词：解析后写进这首歌的缓存，返回给播放页直接显示 */
  applyManual(song: SongInfo, lrc: string, trans: string, source: string): LyricDoc {
    const doc = parseLrc(lrc, trans);
    doc.source = source;
    const key = this.keyOf(song);
    if (this.cache.size >= this.max) {
      this.cache.clear();
    }
    this.cache.set(key, doc);
    return doc;
  }

  /**
   * 手动搜索歌词：并发查多个平台与 LRCLIB，返回可选用候选。
   * 与自动链路分开，允许歌名不同（翻唱、别名、纯音乐无词）时自己指定。
   */
  async search(keyword: string): Promise<LyricCandidate[]> {
    const kw = keyword.trim();
    if (kw.length === 0) {
      return [];
    }
    const api = new PlatformApi();
    const platforms: string[] = ['kw', 'wy', 'kg', 'tx'];
    const tasks: Array<Promise<LyricCandidate[]>> = [];
    for (const p of platforms) {
      tasks.push(this.searchOnePlatform(api, p, kw));
    }
    tasks.push(this.searchLrclib(kw));
    const groups = await Promise.all(tasks);
    const out: LyricCandidate[] = [];
    const seen: string[] = [];
    for (const group of groups) {
      for (const c of group) {
        const k = LyricRepo.normName(c.name) + '|' + c.source;
        if (seen.indexOf(k) >= 0) {
          continue;
        }
        seen.push(k);
        out.push(c);
        if (out.length >= 30) {
          return out;
        }
      }
    }
    return out;
  }

  private async searchOnePlatform(api: PlatformApi, platform: string,
    keyword: string): Promise<LyricCandidate[]> {
    try {
      const list = await api.searchSongs(platform, keyword, 1);
      const out: LyricCandidate[] = [];
      const take = Math.min(list.length, 3);
      for (let i = 0; i < take; i++) {
        const song = list[i];
        const doc = await this.platformDoc(song);
        if (doc.lines.length === 0) {
          continue;
        }
        let transLrc = '';
        for (const line of doc.lines) {
          if (line.trans.length > 0 && line.time >= 0) {
            transLrc += '[' + LyricRepo.lrcTime(line.time) + ']' + line.trans + '\n';
          }
        }
        out.push({
          name: song.name,
          singer: song.singer,
          source: doc.source.length > 0 ? doc.source : platform,
          lrc: doc.raw,
          trans: transLrc,
          preview: LyricRepo.preview(doc)
        });
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  private async searchLrclib(keyword: string): Promise<LyricCandidate[]> {
    try {
      const url = 'https://lrclib.net/api/search?track_name=' + encodeURIComponent(keyword);
      const list = await getJson<LrclibItem[]>(url, 'https://lrclib.net/', LRCLIB_TIMEOUT);
      if (!Array.isArray(list)) {
        return [];
      }
      const out: LyricCandidate[] = [];
      for (const item of list) {
        const lrc = item.syncedLyrics ?? item.plainLyrics ?? '';
        if (lrc.length === 0) {
          continue;
        }
        out.push({
          name: item.trackName ?? keyword,
          singer: item.artistName ?? '',
          source: 'LRCLIB',
          lrc: lrc,
          trans: '',
          preview: lrc.replace(/\[[^\]]*\]/g, '').trim().substring(0, 40)
        });
        if (out.length >= 8) {
          break;
        }
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  /* ---------------- 自动链路 ---------------- */

  /**
   * 音源脚本：并发问所有可用音源。
   * 旧版逐个 await 且要求 platforms/actions 都显式声明，而多数脚本只声明
   * musicUrl、甚至不上报 inited（platforms/actions 为空），于是整条路径从未生效。
   * 现在「未声明」视为能力未知，仍尝试一次；明确声明不含 lyric 才跳过。
   */
  private async fromScript(song: SongInfo): Promise<LyricDoc> {
    const runner = this.sources.getRunner();
    if (runner === null) {
      return emptyLyric();
    }
    const tasks: Array<Promise<LyricDoc>> = [];
    const active = this.sources.getActive();
    if (Settings.get().preferOnly()) {
      // 只认首选音源：歌词也只问首选，别家给的不算
      if (active !== null && this.scriptUsable(active, song)) {
        tasks.push(this.scriptOne(active, song));
      }
      if (tasks.length === 0) {
        return emptyLyric();
      }
      return await LyricRepo.firstDoc(tasks);
    }
    for (const item of this.sources.enabled()) {
      if (this.scriptUsable(item, song)) {
        tasks.push(this.scriptOne(item, song));
      }
    }
    if (tasks.length === 0) {
      return emptyLyric();
    }
    return await LyricRepo.firstDoc(tasks);
  }

  /** 音源是否可能给这首歌提供歌词：平台匹配、脚本已加载、没有明确声明「不提供歌词」 */
  private scriptUsable(item: SourceItem, song: SongInfo): boolean {
    const runner = this.sources.getRunner();
    if (runner === null || !runner.isLoaded(item.id)) {
      return false;
    }
    // MusicFree 插件出的歌只让它自己的 getLyric() 处理：洛雪脚本认不出
    // mfRaw 里的自定义 id，别的插件拿别人的 id 也认不出，试了只是白等超时。
    if (song.mfRaw !== undefined && song.mfRaw.length > 0 &&
      (item.kind !== 'musicfree' || song.source !== 'mf:' + item.id)) {
      return false;
    }
    if (item.platforms.length > 0 && item.platforms.indexOf(song.source) < 0) {
      return false;
    }
    if (item.actions.length > 0 && item.actions.indexOf('lyric') < 0) {
      return false;
    }
    return true;
  }

  private async scriptOne(item: SourceItem, song: SongInfo): Promise<LyricDoc> {
    const runner = this.sources.getRunner();
    if (runner === null) {
      return emptyLyric();
    }
    const info: LxInvokeInfo = { source: song.source, musicInfo: song };
    try {
      const raw = await runner.invoke(item.id, 'lyric', info, SCRIPT_TIMEOUT);
      return LyricRepo.toDoc(raw, '音源·' + item.name);
    } catch (e) {
      return emptyLyric();
    }
  }

  private async fromPlatform(song: SongInfo): Promise<LyricDoc> {
    try {
      return await this.platformDoc(song);
    } catch (e) {
      console.info('[Lyric] 平台歌词失败 ' + String(e));
      return emptyLyric();
    }
  }

  /** 按歌曲自身平台取官方歌词；跨平台同名匹配也复用这里 */
  private async platformDoc(song: SongInfo): Promise<LyricDoc> {
    if (song.source === 'wy') {
      return await this.wy(song);
    }
    if (song.source === 'tx') {
      return await this.tx(song);
    }
    if (song.source === 'kg') {
      return await this.kg(song);
    }
    if (song.source === 'kw') {
      return await this.kw(song);
    }
    if (song.source === 'mg') {
      return await this.mg(song);
    }
    return emptyLyric();
  }

  /**
   * 跨平台兜底：不看歌曲来自哪个平台，按「歌名 + 歌手」去有官方歌词接口的
   * 平台搜同名歌，用那边的歌词。这是 mg / qsvip / 自定义源能出歌词的关键。
   */
  private async fromCrossPlatform(song: SongInfo): Promise<LyricDoc> {
    if (song.source === 'local' || song.name.trim().length === 0) {
      return emptyLyric();
    }
    const keyword = song.name + ' ' + firstSinger(song.singer);
    const api = new PlatformApi();
    const platforms: string[] = ['kw', 'wy', 'kg', 'tx'];
    // 本平台按 id 精确取词失败时（接口偶发失败 / id 不是纯数字），
    // 先在本平台用「歌名 + 歌手」重新找一次精确 id —— 仍属本平台官方歌词，
    // 优先级高于去别的平台找同名歌。以前这里直接跳过本平台，
    // 于是酷我自己的歌只能靠音源脚本给词。
    const own = platforms.indexOf(song.source) >= 0 ? song.source : '';
    if (own.length > 0) {
      const ownDoc = await LyricRepo.withDeadline(
        [this.lyricViaPlatform(api, own, keyword, song)], 3000);
      if (ownDoc.lines.length > 0) {
        return ownDoc;
      }
    }
    const tasks: Array<Promise<LyricDoc>> = [];
    for (const p of platforms) {
      if (p === own) {
        continue;
      }
      tasks.push(this.lyricViaPlatform(api, p, keyword, song));
    }
    if (tasks.length === 0) {
      return emptyLyric();
    }
    return await LyricRepo.firstDoc(tasks);
  }

  private async lyricViaPlatform(api: PlatformApi, platform: string,
    keyword: string, original: SongInfo): Promise<LyricDoc> {
    try {
      const list = await api.searchSongs(platform, keyword, 1);
      if (list.length === 0) {
        return emptyLyric();
      }
      let best: SongInfo | null = null;
      let bestScore = 99;
      for (const item of list) {
        const score = LyricRepo.matchScore(original, item);
        if (score < bestScore) {
          bestScore = score;
          best = item;
        }
      }
      // 以前直接取 list[0]：搜「歌名 + 歌手」的第一条完全可能是另一首歌
      // （同名、翻唱、DJ 版），于是显示的其实是别处的歌词。
      // 现在歌名或歌手对不上就放弃，宁可这首没词，也不给错的。
      if (best === null || bestScore > 1) {
        return emptyLyric();
      }
      const doc = await this.platformDoc(best);
      if (doc.lines.length > 0) {
        doc.source = doc.source + '（同名匹配）';
      }
      return doc;
    } catch (e) {
      return emptyLyric();
    }
  }

  /**
   * 跨平台同名匹配打分：0 最可信，2 及以上直接放弃。
   * 歌名必须是同一主体；双方都有歌手时必须相交；时长差过大视为不同版本。
   */
  private static matchScore(original: SongInfo, item: SongInfo): number {
    const want = LyricRepo.normName(original.name);
    const got = LyricRepo.normName(item.name);
    if (want.length === 0 || got.length === 0) {
      return 9;
    }
    const diff = Math.abs(want.length - got.length);
    // 完全一致；或一方是另一方主体（「我不难过」vs「我不难过live」），
    // 但较短一方至少 3 个字、长度差不超过 4，避免短歌名互相误配。
    const titleOk = want === got ||
      (Math.min(want.length, got.length) >= 3 && diff <= 4 &&
        (want.indexOf(got) >= 0 || got.indexOf(want) >= 0));
    if (!titleOk) {
      return 9;
    }
    let score = 0;
    const a = firstSinger(original.singer).toLowerCase().replace(/\s/g, '');
    const b = firstSinger(item.singer).toLowerCase().replace(/\s/g, '');
    if (a.length > 0 && b.length > 0 && a.indexOf(b) < 0 && b.indexOf(a) < 0) {
      score += 2;   // 同名不同歌手：翻唱 / 其他人，基本可确定不是同一首
    }
    if (original.duration > 0 && item.duration > 0) {
      const d = Math.abs(original.duration - item.duration);
      if (d > 15) {
        score += 2;  // 时长差太多：DJ 版 / 现场版 / 剪辑版
      } else if (d > 8) {
        score += 1;
      }
    }
    return score;
  }

  /* ---------------- 各平台官方歌词 ---------------- */

  /** 酷我：移动端网页接口，按行返回 { lineLyric, time(秒) } */
  private async kw(song: SongInfo): Promise<LyricDoc> {
    let id = song.id.trim();
    if (!/^\d+$/.test(id)) {
      // 音源脚本常把 MUSIC_450444 这种 rid 塞进 musicrid / id，
      // 直接判非数字就跳过，等于本平台官方词链路整条失效。
      const rid = (song.musicrid ?? '').replace('MUSIC_', '').trim();
      if (/^\d+$/.test(rid)) {
        id = rid;
      } else if (/^\d+$/.test(song.songmid.trim())) {
        id = song.songmid.trim();
      }
    }
    if (!/^\d+$/.test(id)) {
      return emptyLyric();
    }
    const url = 'https://m.kuwo.cn/newh5/singles/songinfoandlrc?musicId=' + id;
    const body = await getJson<KwLyricBody>(url, 'https://m.kuwo.cn/', PLATFORM_TIMEOUT);
    const list = body.data?.lrclist ?? [];
    if (list.length === 0) {
      return emptyLyric();
    }
    let lrc = '';
    for (const line of list) {
      const seconds = Number.parseFloat(line.time ?? '');
      if (Number.isNaN(seconds)) {
        continue;
      }
      lrc += '[' + LyricRepo.lrcTime(seconds) + ']' + (line.lineLyric ?? '') + '\n';
    }
    if (lrc.length === 0) {
      return emptyLyric();
    }
    const doc = parseLrc(lrc);
    doc.source = '酷我歌词';
    return doc;
  }

  /** 秒 → [mm:ss.xx] LRC 时间标签 */
  static lrcTime(seconds: number): string {
    const total = Math.max(0, seconds);
    const m = Math.floor(total / 60);
    const s = Math.floor(total % 60);
    const cs = Math.floor((total - Math.floor(total)) * 100);
    const pad2 = (value: number): string => (value < 10 ? '0' : '') + value.toString();
    return pad2(m) + ':' + pad2(s) + '.' + (cs < 10 ? '0' : '') + cs.toString();
  }

  private async wy(song: SongInfo): Promise<LyricDoc> {
    if (!/^\d+$/.test(song.id)) {
      return emptyLyric();
    }
    const url = 'https://music.163.com/api/song/lyric?id=' + song.id + '&lv=1&kv=1&tv=-1';
    const body = await getJson<WyLyricBody>(url, 'https://music.163.com/', PLATFORM_TIMEOUT);
    const lyric = body.lrc?.lyric ?? '';
    const trans = body.tlyric?.lyric ?? '';
    const doc = parseLrc(lyric, trans);
    doc.source = '网易云歌词';
    return doc;
  }

  private async tx(song: SongInfo): Promise<LyricDoc> {
    const mid = song.songmid.length > 0 ? song.songmid : song.id;
    if (mid.length === 0) {
      return emptyLyric();
    }
    const url = 'https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=' + mid +
      '&format=json&nobase64=1&g_tk=5381';
    const body = await getJson<TxLyricResp>(url, 'https://y.qq.com/', PLATFORM_TIMEOUT);
    let lyric = body.lyric ?? '';
    let trans = body.trans ?? '';
    if (lyric.indexOf('[') < 0 && lyric.length > 0) {
      lyric = LyricRepo.base64Decode(lyric);
    }
    if (trans.indexOf('[') < 0 && trans.length > 0) {
      trans = LyricRepo.base64Decode(trans);
    }
    const doc = parseLrc(lyric, trans);
    doc.source = 'QQ音乐歌词';
    return doc;
  }

  private async kg(song: SongInfo): Promise<LyricDoc> {
    const hash = song.hash.length > 0 ? song.hash : song.id;
    if (hash.length === 0) {
      return emptyLyric();
    }
    const searchUrl = 'https://krcs.kugou.com/search?ver=1&man=yes&client=mobi&keyword=&duration=' +
      (song.duration > 0 ? song.duration.toString() : '') + '&hash=' + hash;
    const found = await getJson<KgSearchResp>(searchUrl, 'https://m.kugou.com/', PLATFORM_TIMEOUT);
    const candidates = found.candidates ?? [];
    if (candidates.length === 0) {
      return emptyLyric();
    }
    const first = candidates[0];
    const downloadUrl = 'https://lyrics.kugou.com/download?ver=1&client=pc&id=' + (first.id ?? '') +
      '&accesskey=' + (first.accesskey ?? '') + '&fmt=lrc&charset=utf8';
    const body = await getJson<KgDownloadResp>(downloadUrl, 'https://m.kugou.com/', PLATFORM_TIMEOUT);
    const content = body.content ?? '';
    if (content.length === 0) {
      return emptyLyric();
    }
    const doc = parseLrc(LyricRepo.base64Decode(content));
    doc.source = '酷狗歌词';
    return doc;
  }

  /** 咪咕：按 songId 取详情里的 lrcUrl，直接下载官方 LRC 文本 */
  private async mg(song: SongInfo): Promise<LyricDoc> {
    // 1) 搜索结果里自带的歌词直链，直接用
    const direct = (song.lyricUrl ?? '').trim();
    if (direct.length > 0) {
      const doc = await LyricRepo.mgLrc(direct, (song.trcUrl ?? '').trim());
      if (doc.lines.length > 0) {
        return doc;
      }
    }
    // 2) 详情接口：resourceinfo 按 songId 返回 lrcUrl / trcUrl（v3 的
    //    getLyric 接口已下线，现在只会 301 到首页并返回 HTML）
    const sid = song.id.trim();
    if (/^\d+$/.test(sid)) {
      try {
        const url = 'https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/resourceinfo.do?resourceId=' +
          sid + '&resourceType=2';
        const body = await getJson<MgResourceResp>(url, MG_REF, PLATFORM_TIMEOUT);
        const item = (body.resource ?? [])[0];
        if (item !== undefined) {
          const doc = await LyricRepo.mgLrc((item.lrcUrl ?? '').trim(), (item.trcUrl ?? '').trim());
          if (doc.lines.length > 0) {
            return doc;
          }
        }
      } catch (e) {
        // 落到搜索兜底
      }
    }
    // 3) 兜底：按「歌名 + 歌手」搜一次，copyrightId 必须精确相同
    return await this.mgBySearch(song);
  }

  private async mgBySearch(song: SongInfo): Promise<LyricDoc> {
    if (song.name.trim().length === 0) {
      return emptyLyric();
    }
    try {
      const keyword = song.name + ' ' + firstSinger(song.singer);
      const url = 'https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/search_all.do?ua=Android_migu' +
        '&version=5.0.1&pageNo=1&pageSize=20&searchSwitch=' + encodeURIComponent('{"song":1}') +
        '&text=' + encodeURIComponent(keyword);
      const body = await getJson<MgSearchResp>(url, MG_REF, PLATFORM_TIMEOUT);
      const list = body.songResultData?.result ?? [];
      const cid = (song.copyrightId ?? '').trim();
      let best: MgSong | null = null;
      for (const item of list) {
        if (cid.length > 0 && (item.copyrightId ?? '').trim() === cid) {
          best = item;
          break;
        }
      }
      // copyrightId 对不上就放弃：宁可这首没词，也不显示别人的歌词
      if (best === null) {
        return emptyLyric();
      }
      return await LyricRepo.mgLrc((best.lyricUrl ?? '').trim(), (best.trcUrl ?? '').trim());
    } catch (e) {
      return emptyLyric();
    }
  }

  /** 下载咪咕歌词直链并解析；transUrl 有值时合并翻译 */
  private static async mgLrc(lrcUrl: string, transUrl: string): Promise<LyricDoc> {
    if (lrcUrl.length === 0) {
      return emptyLyric();
    }
    try {
      const raw = await getText(lrcUrl, MG_REF, PLATFORM_TIMEOUT);
      if (raw.trim().length === 0) {
        return emptyLyric();
      }
      let trans = '';
      if (transUrl.length > 0) {
        try {
          trans = await getText(transUrl, MG_REF, PLATFORM_TIMEOUT);
        } catch (e) {
          trans = '';
        }
      }
      const doc = LyricRepo.toDoc(raw, '咪咕歌词');
      if (doc.lines.length === 0) {
        return doc;
      }
      if (trans.trim().length > 0 && !doc.hasTrans) {
        const merged = parseLrc(raw, trans);
        if (merged.hasTrans) {
          merged.source = '咪咕歌词';
          return LyricRepo.dropMgMeta(merged);
        }
      }
      return LyricRepo.dropMgMeta(doc);
    } catch (e) {
      return emptyLyric();
    }
  }

  /**
   * 咪咕歌词的固定噪声：首行「@migu music@」、开头「歌曲名 / 歌手名 / 专辑名」，
   * 以及纯音乐时「内容纯音乐，请欣赏。」重复几十行。只影响咪咕，别的平台不动。
   */
  private static dropMgMeta(doc: LyricDoc): LyricDoc {
    if (doc.lines.length === 0) {
      return doc;
    }
    const kept: LyricLine[] = [];
    let last = '';
    for (const line of doc.lines) {
      const text = line.text.trim();
      if (text.length === 0) {
        continue;
      }
      if (text.indexOf('@migu music@') >= 0) {
        continue;
      }
      if (/^(歌曲名|歌手名|专辑名)\s/.test(text)) {
        continue;
      }
      if (text === last) {
        continue;
      }
      last = text;
      kept.push(line);
    }
    doc.lines = kept;
    return doc;
  }

  /** LRCLIB 公共歌词库：国内可能不通，只作最后兜底 */
  private async fromLrclib(song: SongInfo): Promise<LyricDoc> {
    try {
      const url = 'https://lrclib.net/api/search?track_name=' + encodeURIComponent(song.name) +
        '&artist_name=' + encodeURIComponent(firstSinger(song.singer));
      const list = await getJson<LrclibItem[]>(url, 'https://lrclib.net/', LRCLIB_TIMEOUT);
      if (!Array.isArray(list) || list.length === 0) {
        return emptyLyric();
      }
      let best: LrclibItem | null = null;
      let bestScore = 999;
      for (const item of list) {
        if (item.syncedLyrics === undefined || item.syncedLyrics.length === 0) {
          continue;
        }
        let score = 0;
        if (item.trackName !== undefined && item.trackName !== song.name) {
          score += 1;
        }
        if (item.duration !== undefined && song.duration > 0) {
          score += Math.min(3, Math.abs(item.duration - song.duration) / 10);
        }
        if (score < bestScore) {
          bestScore = score;
          best = item;
        }
      }
      if (best === null) {
        return emptyLyric();
      }
      const picked: LrclibItem = best;
      const doc = parseLrc(picked.syncedLyrics ?? '');
      doc.source = 'LRCLIB';
      return doc;
    } catch (e) {
      return emptyLyric();
    }
  }

  /* ---------------- 工具 ---------------- */

  /** 把任意返回形态统一成 LyricDoc：JSON 对象 / JSON 字符串 / 纯 LRC 文本 */
  static toDoc(raw: string, source: string = ''): LyricDoc {
    const text = (raw ?? '').trim();
    if (text.length === 0) {
      return emptyLyric();
    }
    // 脚本对 lyric 的惯例是「没有就 return null」。序列化后是字符串 "null" / "undefined"，
    // 以前会一路落到下面的「当纯 LRC 处理」，结果歌词区只剩下一个 null。
    if (text === 'null' || text === 'undefined') {
      return emptyLyric();
    }
    let lyric = '';
    let trans = '';
    const head = text.charAt(0);
    if (head === '{' || head === '[') {
      try {
        const obj = JSON.parse(text) as LxLyricRaw;
        lyric = LyricRepo.pickLrc(obj);
        trans = obj.tlyric ?? obj.trans ?? '';
      } catch (e) {
        // 非法 JSON（错误提示、HTML）不能当歌词显示，交给下面的时间轴判断
      }
      // JSON 里没找到歌词字段，或解析失败，但正文含时间轴时按纯 LRC 处理
      if (lyric.length === 0 && /\[\d{1,3}:\d{1,2}/.test(text)) {
        lyric = text;
      }
    } else if (head === '"') {
      try {
        // JSON 的 null / 数字 / 布尔不是歌词，别把 "null" 当成一句词
        const val: Object = JSON.parse(text) as Object;
        lyric = typeof val === 'string' ? val as string : '';
      } catch (e) {
        lyric = text;
      }
    } else if (looksLikeMarkup(text)) {
      // HTML 错误页 / 跳转页 / 接口报错文本一律不能当歌词：
      // 以前咪咕接口 301 之后返回的 <!doctype html>… 就是这样整段显示出来的
      return emptyLyric();
    } else {
      // 日志式的接口报错（ERROR/BAD...)不是歌词；带时间轴的才是
      if (!/\[\d{1,3}:\d{1,2}/.test(text) && !/\[(ti|ar|al|by|offset|length|re|ve):/i.test(text)) {
        return emptyLyric();
      }
      lyric = text;
    }
    if (lyric.trim().length === 0 || looksLikeNonLyric(lyric)) {
      return emptyLyric();
    }
    const doc = parseLrc(lyric, trans);
    // 带时间轴的伪歌词（[00:12]http://...）也要挡住：逐行丢掉链接 / 报错行，
    // 一句真词都不剩就整份作废，不让音源脚本把播放直链画到歌词区。
    const kept: LyricLine[] = [];
    for (const line of doc.lines) {
      if (!LyricRepo.isLinkLine(line.text)) {
        kept.push(line);
      }
    }
    if (kept.length === 0) {
      return emptyLyric();
    }
    doc.lines = kept;
    if (source.length > 0) {
      doc.source = source;
    }
    return doc;
  }

  /** 单行是否是一条链接 / 音频直链 / 接口报错，用于逐行过滤 */
  private static isLinkLine(text: string): boolean {
    const s = text.toLowerCase();
    if (s.indexOf('http://') >= 0 || s.indexOf('https://') >= 0 ||
      s.indexOf('ftp://') >= 0 || s.indexOf('www.') >= 0) {
      return true;
    }
    return /\.(?:mgg|mp3|flac|m4a|aac|ogg|wav|ape|wma|m3u8|mp4)(?:\?|#|\s|$)/.test(s);
  }

  private static pickLrc(obj: LxLyricRaw): string {
    const a = obj.lyric ?? '';
    if (a.length > 0) {
      return a;
    }
    const b = obj.lxlyric ?? '';
    if (b.length > 0) {
      return b;
    }
    const c = obj.lrc ?? '';
    if (c.length > 0) {
      return c;
    }
    const d = obj.lyricContent ?? '';
    if (d.length > 0) {
      return d;
    }
    if (obj.data !== undefined) {
      const nested = LyricRepo.pickLrc(obj.data);
      if (nested.length > 0) {
        return nested;
      }
    }
    if (obj.resource !== undefined && obj.resource.length > 0) {
      return LyricRepo.pickLrc(obj.resource[0]);
    }
    return '';
  }

  private static normName(s: string): string {
    return s.toLowerCase().replace(/\s|\(|\)|（|）|-/g, '');
  }

  private static preview(doc: LyricDoc): string {
    for (const line of doc.lines) {
      if (line.text.length > 0) {
        return line.text.substring(0, 40);
      }
    }
    return '';
  }

  /** 取第一个非空结果；全部为空才返回空文档 */
  private static firstDoc(tasks: Array<Promise<LyricDoc>>): Promise<LyricDoc> {
    if (tasks.length === 0) {
      return Promise.resolve(emptyLyric());
    }
    const state: DocRaceState = { left: tasks.length, settled: false };
    return new Promise<LyricDoc>((resolve) => {
      for (const task of tasks) {
        const onDone = (doc: LyricDoc): void => {
          state.left--;
          if (!state.settled && doc.lines.length > 0) {
            state.settled = true;
            resolve(doc);
          } else if (state.left === 0 && !state.settled) {
            state.settled = true;
            resolve(emptyLyric());
          }
        };
        task.then(onDone, (): void => {
          onDone(emptyLyric());
        });
      }
    });
  }

  /** 总超时兜底：某条链路卡住时不能让歌词一直转圈 */
  private static withDeadline(tasks: Array<Promise<LyricDoc>>, ms: number): Promise<LyricDoc> {
    return new Promise<LyricDoc>((resolve) => {
      let done = false;
      const finish = (doc: LyricDoc): void => {
        if (done) {
          return;
        }
        done = true;
        resolve(doc);
      };
      const timer = setTimeout((): void => {
        finish(emptyLyric());
      }, ms);
      LyricRepo.firstDoc(tasks).then((doc: LyricDoc): void => {
        clearTimeout(timer);
        finish(doc);
      });
    });
  }

  static base64Decode(text: string): string {
    try {
      const helper = new util.Base64Helper();
      const bytes = helper.decodeSync(text);
      const decoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(bytes);
    } catch (e) {
      return text;
    }
  }
}

import {
  SheetInfo, SheetTag, SongInfo, ArtistInfo, newSheet, newSong, secondsToInterval, formatCount
} from '../common/Models';
import { getJson } from './Http';
import { PlatformApi } from './PlatformApi';
import {
  DiscoverItem, DiscoverSection, DiscoverMore, newDiscoverItem, newDiscoverSection,
  newDiscoverMore, officialNote,
  LAY_BANNER, LAY_CARD_RAIL, LAY_SONG_LIST, LAY_RANK_CARDS, LAY_RANK_GROUP,
  LAY_ARTIST_RAIL, LAY_BIG_CARD, LAY_SHEET_GRID,
  ACT_SHEET, ACT_SONG, ACT_ARTIST, ACT_SEARCH
} from '../common/Discover';

/**
 * 发现页「板块流」编排层（v2.56 · 发现页重做）。
 *
 * 职责：实时直连各音源平台**官方发现页接口**，把返回数据编排成 DiscoverSection[]。
 * UI 不认识平台，只按 section.layout 渲染；板块的种类、数量、顺序、标题全部来自这里。
 * 这样「不同平台不同 UI 分布」是数据的自然结果，不是 UI 里一堆 if (platform) 写死。
 *
 * 编排依据（2026-11-12 逐接口实测，全部匿名可用）：
 *   网易云  /api/banner/get、/api/personalized/playlist、/api/personalized/newsong、
 *           /api/personalized/privatecontent、/api/toplist/detail
 *   QQ音乐  musicu.fcg GetAll（分组榜单）、fcg_get_diss_by_tag（歌单广场）；
 *           官方客户端已去掉首页 banner，这里也不放
 *   酷狗    m.kugou.com/?json=true —— 一次返回 banner / 精选歌单 / 新歌 / 热门榜单 / 热门歌手
 *   酷我    getRcmPlayList?order=hot|new、bangMenu（5 个榜单分组）
 *
 * 铁律：任何板块接口失败就返回空数组让该板块**缺席**，绝不塞写死的兜底内容；
 * 点击一律还原成既有 SheetInfo / SongInfo / ArtistInfo，走原有详情页与音源取链，
 * 音源引擎（core/ 取链、播放、下载、账号）零改动。
 */

const WY_REF: string = 'https://music.163.com/';
const TX_REF: string = 'https://y.qq.com/';
const KG_REF: string = 'https://m.kugou.com/';
const KW_REF: string = 'https://www.kuwo.cn/';

/* ============================ 通用工具 ============================ */

function httpsUrl(raw: string): string {
  const v = (raw ?? '').trim();
  if (v.length === 0) {
    return '';
  }
  let out = v;
  if (out.indexOf('//') === 0) {
    out = 'https:' + out;
  } else if (out.indexOf('http://') === 0) {
    out = 'https://' + out.substring(7);
  }
  // 酷狗 / 咪咕封面里的尺寸占位；400 是实测可用档
  if (out.indexOf('{size}') >= 0) {
    out = out.split('{size}').join('400');
  }
  return out;
}

function firstNonEmpty(a: string, b: string): string {
  return a.length > 0 ? a : b;
}

function numText(v: number | undefined): string {
  return v === undefined ? '' : Math.floor(v).toString();
}

function countBadge(v: number | undefined): string {
  return v === undefined || v <= 0 ? '' : formatCount(v) + ' 播放';
}

/** 把歌单 / 榜单 / 专辑还原成详情页能用的 SheetInfo JSON */
function sheetPayload(platform: string, kind: string, id: string, name: string,
  cover: string, subtitle: string, trackCount: number): string {
  const sheet = newSheet(platform, kind);
  sheet.id = id;
  sheet.name = name;
  sheet.cover = cover;
  sheet.subtitle = subtitle;
  sheet.trackCount = trackCount;
  sheet.creator = '';
  return JSON.stringify(sheet);
}

/** 把官方新歌还原成可直接点播的 SongInfo JSON（取链仍走既有音源引擎） */
function songPayload(platform: string, id: string, name: string, singer: string,
  cover: string, album: string, duration: number, extraId: string, hash: string): string {
  const song = newSong(platform);
  song.id = id;
  song.songmid = id;
  song.hash = hash;
  song.name = name;
  song.singer = singer;
  song.album = album;
  song.albumName = album;
  song.albumId = extraId;
  song.cover = cover;
  song.duration = duration;
  song.interval = secondsToInterval(duration);
  return JSON.stringify(song);
}

function artistPayload(platform: string, id: string, name: string, avatar: string): string {
  const artist: ArtistInfo = {
    id: id, name: name, avatar: avatar, platform: platform, subtitle: ''
  };
  return JSON.stringify(artist);
}

/**
 * 歌单广场类「更多」：点进去走既有 sheetsByTag 官方分页接口，可带分类筛选。
 * 这是真正能「上拉看更多」的一类 —— 首页橱窗只放前 12/18/19 条，
 * 全量页按 page 一页页翻，官方歌单广场有几百条。
 */
function sheetsMore(title: string, platform: string, tagId: string, tagged: boolean): DiscoverMore {
  return newDiscoverMore('sheets', title, platform, tagId, true, tagged, false);
}

/** 官方该入口一次给全（banner / 新歌 / 独家 / 歌手）：全量页把首页 items 竖排铺满 */
function snapshotMore(title: string, platform: string, source: string): DiscoverMore {
  return newDiscoverMore(source, title, platform, '', false, false, false);
}

/** 榜单类「更多」：直接进既有 rankboard 页（子榜 tab + 歌曲列表，本就是官方榜单完整视图） */
function rankMore(title: string, platform: string): DiscoverMore {
  return newDiscoverMore('rank', title, platform, '', false, false, true);
}

/**
 * 建板块并挂上「更多 ›」描述。
 * snapshot 类把首页已拉到的 items 序列化进 more.snapshot，全量页不用再打一次网络；
 * 官方该入口本来就一次给全，没有「下一页」，重复请求只会拿到同一批。
 */
function section(key: string, title: string, source: string, layout: number,
  items: DiscoverItem[], spec: DiscoverMore): DiscoverSection[] {
  if (items.length === 0) {
    return [];
  }
  if (!spec.rank && !spec.paged && spec.snapshot.length === 0) {
    spec.snapshot = JSON.stringify(items);
  }
  const sec = newDiscoverSection(key, title, officialNote(source), layout, items);
  sec.more = spec;
  return [sec];
}

/* ============================ 官方接口响应（具名 interface，ArkTS 严格模式） ============================ */

interface WyBannerItem {
  pic?: string;
  title?: string;
  typeTitle?: string;
  targetType?: number;
  targetId?: number;
}
interface WyBannerResp { banners?: WyBannerItem[]; }
interface WyDailyItem {
  id?: number; name?: string; picUrl?: string; playCount?: number;
  trackCount?: number; copywriter?: string;
}
interface WyDailyResp { result?: WyDailyItem[]; }
interface WyArtist { name?: string; }
interface WyAlbum { name?: string; picUrl?: string; id?: number; }
interface WyNewsongSong {
  id?: number; name?: string; duration?: number; fee?: number;
  ar?: WyArtist[]; artists?: WyArtist[]; al?: WyAlbum; album?: WyAlbum;
}
interface WyNewsongItem {
  id?: number; name?: string; picUrl?: string; copywriter?: string; song?: WyNewsongSong;
}
interface WyNewsongResp { result?: WyNewsongItem[]; }
interface WyPrivateItem {
  id?: number; name?: string; picUrl?: string; sPicUrl?: string; copywriter?: string;
}
interface WyPrivateResp { result?: WyPrivateItem[]; }
interface WyTopItem {
  id?: number; name?: string; coverImgUrl?: string;
  updateFrequency?: string; trackCount?: number; playCount?: number;
}
interface WyTopResp { list?: WyTopItem[]; }

interface TxTop {
  topId?: number; title?: string; frontPicUrl?: string; updateFrequency?: string;
}
interface TxGroup { groupName?: string; toplist?: TxTop[]; }
interface TxTopData { group?: TxGroup[]; }
interface TxReqData { data?: TxTopData; }
interface TxTopResp { req?: TxReqData; }
interface TxCreator { name?: string; }
interface TxDissItem {
  dissid?: string; dissname?: string; imgurl?: string; listennum?: number; creator?: TxCreator;
}
interface TxDissData { list?: TxDissItem[]; }
interface TxDissResp { data?: TxDissData; }

interface KgBannerExtra { specialid?: number; specialname?: string; }
interface KgBanner {
  imgurl?: string; title?: string; type?: number; id?: number; extra?: KgBannerExtra;
}
interface KgAuthor { author_name?: string; }
interface KgNewSong {
  songname?: string; filename?: string; hash?: string; authors?: KgAuthor[];
  album_sizable_cover?: string; duration?: number; album_id?: string; audio_id?: number;
}
interface KgSpecial {
  specialid?: number; specialname?: string; imgurl?: string; playcount?: number;
  songcount?: number; play_count_text?: string; intro?: string; username?: string;
}
interface KgSpecialList { info?: KgSpecial[]; }
interface KgSpecialWrap { list?: KgSpecialList; }
interface KgRankSong { songname?: string; name?: string; author?: string; }
interface KgRank {
  rankid?: number; rankname?: string; img_9?: string; imgurl?: string; banner_9?: string;
  update_frequency?: string; play_times?: number; songinfo?: KgRankSong[];
}
interface KgRankWrap { list?: KgRank[]; }
interface KgSinger {
  singerid?: number; singername?: string; imgurl?: string; fanscount?: number;
}
interface KgHomeResp {
  banner?: KgBanner[]; data?: KgNewSong[]; special?: KgSpecialWrap;
  rank?: KgRankWrap; singers?: KgSinger[];
}

interface KwSheet {
  id?: string; name?: string; img?: string; listencnt?: string;
  total?: string; uname?: string;
}
interface KwSheetData { data?: KwSheet[]; }
interface KwSheetResp { data?: KwSheetData; }
interface KwMenuRank {
  sourceid?: string; id?: string; name?: string; pic?: string; pub?: string;
}
interface KwMenuGroup { name?: string; list?: KwMenuRank[]; }
interface KwMenuResp { data?: KwMenuGroup[]; }

/* ============================ 编排器 ============================ */

export class DiscoverFeed {
  private api: PlatformApi = new PlatformApi();

  /**
   * 全量页翻页：首页橱窗是官方发现页的一屏预览，这里按 page 继续从官方
   * 歌单广场接口往后取。SheetInfo 还原成 DiscoverItem 只是为了跟首页共用
   * 同一套卡片渲染与 openDiscoverItem 点击逻辑，音源引擎一行不动。
   * 失败返回空数组让全量页显示「没有更多了」，绝不塞假数据。
   */
  async more(spec: DiscoverMore, page: number, tagId: string): Promise<DiscoverItem[]> {
    if (spec.rank || !spec.paged || spec.source !== 'sheets') {
      return [];
    }
    const cat = tagId.length > 0 ? tagId : spec.tagId;
    let sheets: SheetInfo[] = [];
    try {
      sheets = await this.api.sheetsByTag(spec.platform, cat, page);
    } catch (e) {
      return [];
    }
    const out: DiscoverItem[] = [];
    for (const s of sheets) {
      const it = newDiscoverItem();
      it.id = s.id;
      it.title = s.name;
      it.subtitle = firstNonEmpty(s.creator, s.subtitle);
      it.cover = s.cover;
      it.badge = countBadge(s.playCount);
      it.trackCount = s.trackCount;
      it.platform = s.platform;
      it.action = ACT_SHEET;
      it.kind = s.kind;
      it.payload = JSON.stringify(s);
      out.push(it);
    }
    return out;
  }

  /** 快照类板块：把首页带过来的 items 还原，官方该入口一次给全，不重复打网络 */
  snapshotItems(spec: DiscoverMore): DiscoverItem[] {
    if (spec.snapshot.length === 0) {
      return [];
    }
    try {
      return JSON.parse(spec.snapshot) as DiscoverItem[];
    } catch (e) {
      return [];
    }
  }

  /** 全量页分类胶囊：直接用既有 sheetTags，酷狗 / QQ 只有「全部」就不显示筛选行 */
  async moreTags(spec: DiscoverMore): Promise<SheetTag[]> {
    if (!spec.tagged || spec.source !== 'sheets') {
      return [];
    }
    try {
      const tags = await this.api.sheetTags(spec.platform);
      return tags.length > 1 ? tags : [];
    } catch (e) {
      return [];
    }
  }

  /**
   * 产出当前平台的板块流。jobs 并发发起，按数组顺序收集；单个接口失败不影响其它板块。
   * 末尾追加一个 LAY_SHEET_GRID 占位板块，由页面用既有 SheetPool 填「换一批」推荐歌单。
   */
  async build(platform: string): Promise<DiscoverSection[]> {
    const jobs: Promise<DiscoverSection[]>[] = [];
    let poolTitle = '推荐歌单';
    if (platform === 'wy') {
      poolTitle = '歌单广场';
      jobs.push(this.wyBanner(), this.wyDaily(), this.wyNewsong(), this.wyPrivate(), this.wyRanks());
    } else if (platform === 'tx') {
      poolTitle = '为你推荐';
      jobs.push(this.txRankGroups(), this.txDiss());
    } else if (platform === 'kg') {
      poolTitle = '歌单广场';
      jobs.push(this.kgHome());
    } else {
      poolTitle = '推荐歌单';
      jobs.push(this.kwSheets('hot'), this.kwSheets('new'), this.kwRankGroups());
    }
    const grouped = await Promise.all(jobs);
    const out: DiscoverSection[] = [];
    for (const part of grouped) {
      for (const sec of part) {
        out.push(sec);
      }
    }
    const pool = newDiscoverSection(platform + '-pool', poolTitle,
      officialNote('推荐池 · 下拉刷新或点换一批'), LAY_SHEET_GRID, []);
    pool.more = sheetsMore('歌单广场', platform,
      platform === 'kw' ? 'hot' : (platform === 'tx' ? '10000000' : '全部'),
      platform === 'wy' || platform === 'kw');
    out.push(pool);
    return out;
  }

  /* ---------------- 网易云 ---------------- */

  private async wyBanner(): Promise<DiscoverSection[]> {
    try {
      const resp = await getJson<WyBannerResp>('https://music.163.com/api/banner/get?type=2', WY_REF);
      const items: DiscoverItem[] = [];
      for (const b of resp.banners ?? []) {
        const it = newDiscoverItem();
        const targetId = numText(b.targetId);
        const targetType = b.targetType ?? 0;
        it.id = targetId;
        it.title = firstNonEmpty(b.title ?? '', b.typeTitle ?? '');
        it.subtitle = b.typeTitle ?? '';
        it.cover = httpsUrl(b.pic ?? '');
        it.badge = b.typeTitle ?? '';
        it.platform = 'wy';
        // 官方 banner 的 targetType：10 专辑 / 1000 歌单；其余是活动页，App 内无对应容器，
        // 如实退化成「按标题搜索」，不构造会打开空详情页的假歌单。
        if (targetType === 10 && targetId.length > 0) {
          it.action = ACT_SHEET;
          it.kind = 'album';
          it.payload = sheetPayload('wy', 'album', targetId, it.title, it.cover, '', 0);
        } else if (targetType === 1000 && targetId.length > 0) {
          it.action = ACT_SHEET;
          it.kind = 'playlist';
          it.payload = sheetPayload('wy', 'playlist', targetId, it.title, it.cover, '', 0);
        } else {
          it.action = ACT_SEARCH;
          it.keyword = it.title;
        }
        items.push(it);
      }
      return section('wy-banner', '推荐', '首页 Banner', LAY_BANNER, items,
        snapshotMore('推荐', 'wy', 'banner'));
    } catch (e) {
      return [];
    }
  }

  private async wyDaily(): Promise<DiscoverSection[]> {
    try {
      const resp = await getJson<WyDailyResp>(
        'https://music.163.com/api/personalized/playlist?limit=12&offset=0', WY_REF);
      const items: DiscoverItem[] = [];
      for (const d of resp.result ?? []) {
        const id = numText(d.id);
        if (id.length === 0) {
          continue;
        }
        const it = newDiscoverItem();
        it.id = id;
        it.title = d.name ?? '';
        it.subtitle = firstNonEmpty(d.copywriter ?? '', numText(d.trackCount) + ' 首');
        it.cover = httpsUrl(d.picUrl ?? '');
        it.badge = countBadge(d.playCount);
        it.trackCount = d.trackCount ?? 0;
        it.platform = 'wy';
        it.action = ACT_SHEET;
        it.kind = 'playlist';
        it.payload = sheetPayload('wy', 'playlist', id, it.title, it.cover, '', it.trackCount);
        items.push(it);
      }
      return section('wy-daily', '每日推荐', '每日推荐歌单', LAY_CARD_RAIL, items,
        sheetsMore('歌单广场', 'wy', '全部', true));
    } catch (e) {
      return [];
    }
  }

  private async wyNewsong(): Promise<DiscoverSection[]> {
    try {
      const resp = await getJson<WyNewsongResp>(
        'https://music.163.com/api/personalized/newsong', WY_REF);
      const items: DiscoverItem[] = [];
      for (const r of resp.result ?? []) {
        const s = r.song;
        if (s === undefined) {
          continue;
        }
        const id = firstNonEmpty(numText(s.id), numText(r.id));
        if (id.length === 0) {
          continue;
        }
        const names: string[] = [];
        for (const a of s.ar ?? s.artists ?? []) {
          names.push(a.name ?? '');
        }
        const theAlbum = s.al ?? s.album;
        const it = newDiscoverItem();
        it.id = id;
        it.title = firstNonEmpty(r.name ?? '', s.name ?? '');
        it.subtitle = names.join(' / ');
        it.cover = httpsUrl(firstNonEmpty(r.picUrl ?? '', theAlbum?.picUrl ?? ''));
        it.badge = r.copywriter ?? '';
        it.platform = 'wy';
        it.action = ACT_SONG;
        it.payload = songPayload('wy', id, it.title, it.subtitle, it.cover,
          theAlbum?.name ?? '', Math.floor((s.duration ?? 0) / 1000),
          numText(theAlbum?.id), '');
        items.push(it);
      }
      return section('wy-newsong', '推荐新歌', '个性化新歌', LAY_SONG_LIST, items,
        snapshotMore('推荐新歌', 'wy', 'newsong'));
    } catch (e) {
      return [];
    }
  }

  private async wyPrivate(): Promise<DiscoverSection[]> {
    try {
      const resp = await getJson<WyPrivateResp>(
        'https://music.163.com/api/personalized/privatecontent', WY_REF);
      const items: DiscoverItem[] = [];
      for (const p of resp.result ?? []) {
        const it = newDiscoverItem();
        it.id = numText(p.id);
        it.title = p.name ?? '';
        it.subtitle = p.copywriter ?? '';
        it.cover = httpsUrl(firstNonEmpty(p.picUrl ?? '', p.sPicUrl ?? ''));
        it.badge = '独家';
        it.platform = 'wy';
        // 官方「独家放送」是视频 / 专题，应用内没有 Web 容器，如实走搜索
        it.action = ACT_SEARCH;
        it.keyword = it.title;
        items.push(it);
      }
      return section('wy-private', '独家放送', '独家放送', LAY_BIG_CARD, items,
        snapshotMore('独家放送', 'wy', 'banner'));
    } catch (e) {
      return [];
    }
  }

  private async wyRanks(): Promise<DiscoverSection[]> {
    try {
      const resp = await getJson<WyTopResp>('https://music.163.com/api/toplist/detail', WY_REF);
      const items: DiscoverItem[] = [];
      let n = 0;
      for (const t of resp.list ?? []) {
        if (n >= 10) {
          break;
        }
        const id = numText(t.id);
        if (id.length === 0) {
          continue;
        }
        const it = newDiscoverItem();
        it.id = id;
        it.title = t.name ?? '';
        it.subtitle = t.updateFrequency ?? '';
        it.cover = httpsUrl(t.coverImgUrl ?? '');
        it.badge = countBadge(t.playCount);
        it.trackCount = t.trackCount ?? 0;
        it.platform = 'wy';
        it.action = ACT_SHEET;
        it.kind = 'rank';
        it.payload = sheetPayload('wy', 'rank', id, it.title, it.cover,
          it.subtitle, it.trackCount);
        items.push(it);
        n += 1;
      }
      return section('wy-ranks', '排行榜', '官方榜单', LAY_RANK_CARDS, items,
        rankMore('排行榜', 'wy'));
    } catch (e) {
      return [];
    }
  }

  /* ---------------- QQ音乐（官方无首页 banner，以分组榜单打头） ---------------- */

  private async txRankGroups(): Promise<DiscoverSection[]> {
    try {
      const payload = '{"comm":{"ct":24},"req":{"method":"GetAll","module":"musicToplist.ToplistInfoServer","param":{}}}';
      const url = 'https://u.y.qq.com/cgi-bin/musicu.fcg?format=json&data=' + encodeURIComponent(payload);
      const resp = await getJson<TxTopResp>(url, TX_REF);
      const out: DiscoverSection[] = [];
      for (const g of resp.req?.data?.group ?? []) {
        const groupName = g.groupName ?? '榜单';
        const items: DiscoverItem[] = [];
        for (const t of g.toplist ?? []) {
          const id = numText(t.topId);
          if (id.length === 0) {
            continue;
          }
          const it = newDiscoverItem();
          it.id = id;
          it.title = t.title ?? '';
          it.subtitle = t.updateFrequency ?? '';
          it.cover = httpsUrl(t.frontPicUrl ?? '');
          it.badge = groupName;
          it.group = groupName;
          it.platform = 'tx';
          it.action = ACT_SHEET;
          it.kind = 'rank';
          it.payload = sheetPayload('tx', 'rank', id, it.title, it.cover, it.subtitle, 0);
          items.push(it);
        }
        for (const sec of section('tx-group-' + groupName, groupName, 'QQ音乐 · ' + groupName,
          LAY_RANK_GROUP, items, rankMore(groupName, 'tx'))) {
          out.push(sec);
        }
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  private async txDiss(): Promise<DiscoverSection[]> {
    try {
      const url = 'https://c.y.qq.com/splcloud/fcgi-bin/fcg_get_diss_by_tag.fcg?picmid=1&rnd=0.1&g_tk=5381' +
        '&categoryId=10000000&sortId=5&sin=0&ein=18&format=json&inCharset=utf8&outCharset=utf-8';
      const resp = await getJson<TxDissResp>(url, TX_REF);
      const items: DiscoverItem[] = [];
      for (const d of resp.data?.list ?? []) {
        const id = d.dissid ?? '';
        if (id.length === 0) {
          continue;
        }
        const it = newDiscoverItem();
        it.id = id;
        it.title = d.dissname ?? '';
        it.subtitle = d.creator?.name ?? '';
        it.cover = httpsUrl(d.imgurl ?? '');
        it.badge = countBadge(d.listennum);
        it.platform = 'tx';
        it.action = ACT_SHEET;
        it.kind = 'playlist';
        it.payload = sheetPayload('tx', 'playlist', id, it.title, it.cover, it.subtitle, 0);
        items.push(it);
      }
      return section('tx-diss', '歌单广场', '歌单广场', LAY_CARD_RAIL, items,
        sheetsMore('歌单广场', 'tx', '10000000', false));
    } catch (e) {
      return [];
    }
  }

  /* ---------------- 酷狗（首页接口一次给全五个板块） ---------------- */

  private async kgHome(): Promise<DiscoverSection[]> {
    try {
      const resp = await getJson<KgHomeResp>('https://m.kugou.com/?json=true', KG_REF);
      const out: DiscoverSection[] = [];

      // Banner：extra.specialid 是官方歌单 id，能真正打开详情页
      const banners: DiscoverItem[] = [];
      for (const b of resp.banner ?? []) {
        const it = newDiscoverItem();
        const specialId = numText(b.extra?.specialid);
        it.id = firstNonEmpty(specialId, numText(b.id));
        it.title = firstNonEmpty(b.title ?? '', b.extra?.specialname ?? '');
        it.subtitle = b.extra?.specialname ?? '';
        it.cover = httpsUrl(b.imgurl ?? '');
        it.badge = '精选';
        it.platform = 'kg';
        if (specialId.length > 0) {
          it.action = ACT_SHEET;
          it.kind = 'playlist';
          it.payload = sheetPayload('kg', 'playlist', specialId, it.title, it.cover, '', 0);
        } else {
          it.action = ACT_SEARCH;
          it.keyword = it.title;
        }
        banners.push(it);
      }
      for (const s of section('kg-banner', '推荐', '首页 Banner', LAY_BANNER, banners,
        snapshotMore('推荐', 'kg', 'banner'))) {
        out.push(s);
      }

      // 精选歌单（大图横滑）
      const specials: DiscoverItem[] = [];
      for (const sp of resp.special?.list?.info ?? []) {
        const id = numText(sp.specialid);
        if (id.length === 0) {
          continue;
        }
        const it = newDiscoverItem();
        it.id = id;
        it.title = sp.specialname ?? '';
        it.subtitle = firstNonEmpty(sp.intro ?? '', sp.username ?? '');
        it.cover = httpsUrl(sp.imgurl ?? '');
        it.badge = firstNonEmpty(sp.play_count_text ?? '', countBadge(sp.playcount));
        it.trackCount = sp.songcount ?? 0;
        it.platform = 'kg';
        it.action = ACT_SHEET;
        it.kind = 'playlist';
        it.payload = sheetPayload('kg', 'playlist', id, it.title, it.cover, '', it.trackCount);
        specials.push(it);
      }
      for (const s of section('kg-special', '精选歌单', '精选歌单', LAY_BIG_CARD, specials,
        sheetsMore('歌单广场', 'kg', '全部', false))) {
        out.push(s);
      }

      // 新歌首发
      const songs: DiscoverItem[] = [];
      for (const d of resp.data ?? []) {
        const hash = d.hash ?? '';
        const fid = numText(d.audio_id);
        const id = firstNonEmpty(hash, fid);
        if (id.length === 0) {
          continue;
        }
        const names: string[] = [];
        for (const a of d.authors ?? []) {
          names.push(a.author_name ?? '');
        }
        let name = d.songname ?? '';
        let singer = names.join(' / ');
        // 酷狗部分新歌只给 filename「歌手 - 歌名」
        if (name.length === 0 && (d.filename ?? '').length > 0) {
          const dash = (d.filename ?? '').indexOf(' - ');
          if (dash > 0) {
            singer = (d.filename ?? '').substring(0, dash);
            name = (d.filename ?? '').substring(dash + 3);
          } else {
            name = d.filename ?? '';
          }
        }
        const it = newDiscoverItem();
        it.id = id;
        it.title = name;
        it.subtitle = singer;
        it.cover = httpsUrl(d.album_sizable_cover ?? '');
        it.badge = (d.duration ?? 0) > 0 ? secondsToInterval(d.duration ?? 0) : '';
        it.platform = 'kg';
        it.action = ACT_SONG;
        it.payload = songPayload('kg', id, name, singer, it.cover, '',
          d.duration ?? 0, d.album_id ?? '', hash);
        songs.push(it);
      }
      for (const s of section('kg-newsong', '新歌首发', '首页新歌', LAY_SONG_LIST, songs,
        snapshotMore('新歌首发', 'kg', 'newsong'))) {
        out.push(s);
      }

      // 热门榜单：官方每个榜单自带榜内前三歌，做成封面卡下方的预览
      const ranks: DiscoverItem[] = [];
      let n = 0;
      for (const r of resp.rank?.list ?? []) {
        if (n >= 10) {
          break;
        }
        const id = numText(r.rankid);
        if (id.length === 0) {
          continue;
        }
        const previews: string[] = [];
        for (const sg of r.songinfo ?? []) {
          previews.push(firstNonEmpty(sg.songname ?? '', sg.name ?? ''));
        }
        const it = newDiscoverItem();
        it.id = id;
        it.title = r.rankname ?? '';
        it.subtitle = r.update_frequency ?? '';
        it.cover = httpsUrl(firstNonEmpty(r.img_9 ?? '', r.imgurl ?? ''));
        it.coverFallback = httpsUrl(r.banner_9 ?? '');
        it.badge = countBadge(r.play_times);
        it.extra = previews.slice(0, 3).join(' · ');
        it.platform = 'kg';
        it.action = ACT_SHEET;
        it.kind = 'rank';
        it.payload = sheetPayload('kg', 'rank', id, it.title, it.cover, it.subtitle, 0);
        ranks.push(it);
        n += 1;
      }
      for (const s of section('kg-ranks', '热门榜单', '热门榜单', LAY_RANK_CARDS, ranks,
        rankMore('热门榜单', 'kg'))) {
        out.push(s);
      }

      // 热门歌手（圆形头像横滑）
      const singers: DiscoverItem[] = [];
      for (const g of resp.singers ?? []) {
        const id = numText(g.singerid);
        if (id.length === 0) {
          continue;
        }
        const it = newDiscoverItem();
        it.id = id;
        it.title = g.singername ?? '';
        it.subtitle = countBadge(g.fanscount);
        it.cover = httpsUrl(g.imgurl ?? '');
        it.platform = 'kg';
        it.action = ACT_ARTIST;
        it.payload = artistPayload('kg', id, it.title, it.cover);
        singers.push(it);
      }
      for (const s of section('kg-singers', '热门歌手', '首页热门歌手', LAY_ARTIST_RAIL, singers,
        snapshotMore('热门歌手', 'kg', 'singers'))) {
        out.push(s);
      }

      return out;
    } catch (e) {
      return [];
    }
  }

  /* ---------------- 酷我（以歌单为主 + 多分组榜单） ---------------- */

  private async kwSheets(order: string): Promise<DiscoverSection[]> {
    try {
      const url = 'https://wapi.kuwo.cn/api/pc/classify/playlist/getRcmPlayList?pn=1&rn=18&order=' + order;
      const resp = await getJson<KwSheetResp>(url, KW_REF);
      const items: DiscoverItem[] = [];
      for (const d of resp.data?.data ?? []) {
        const id = d.id ?? '';
        if (id.length === 0) {
          continue;
        }
        const it = newDiscoverItem();
        it.id = id;
        it.title = d.name ?? '';
        it.subtitle = d.uname ?? '';
        it.cover = httpsUrl(d.img ?? '');
        const listens = Number.parseInt(d.listencnt ?? '0');
        it.badge = Number.isNaN(listens) ? '' : countBadge(listens);
        const total = Number.parseInt(d.total ?? '0');
        it.trackCount = Number.isNaN(total) ? 0 : total;
        it.platform = 'kw';
        it.action = ACT_SHEET;
        it.kind = 'playlist';
        it.payload = sheetPayload('kw', 'playlist', id, it.title, it.cover, '', it.trackCount);
        items.push(it);
      }
      const title = order === 'new' ? '最新歌单' : '热门歌单';
      const key = 'kw-sheets-' + order;
      return section(key, title, '推荐歌单 · ' + order, LAY_CARD_RAIL, items,
        sheetsMore('推荐歌单', 'kw', order, true));
    } catch (e) {
      return [];
    }
  }

  private async kwRankGroups(): Promise<DiscoverSection[]> {
    try {
      const resp = await getJson<KwMenuResp>(
        'https://wapi.kuwo.cn/api/www/bang/bang/bangMenu?from=pc', KW_REF);
      const out: DiscoverSection[] = [];
      for (const g of resp.data ?? []) {
        const groupName = g.name ?? '榜单';
        const items: DiscoverItem[] = [];
        for (const r of g.list ?? []) {
          // 详情页 kwRankSongs 用的是 sourceid（16/93/…），不是菜单里的 id（489927…）
          const id = r.sourceid ?? '';
          if (id.length === 0) {
            continue;
          }
          const it = newDiscoverItem();
          it.id = id;
          it.title = r.name ?? '';
          it.subtitle = r.pub ?? '';
          it.cover = httpsUrl(r.pic ?? '');
          it.badge = groupName;
          it.group = groupName;
          it.platform = 'kw';
          it.action = ACT_SHEET;
          it.kind = 'rank';
          it.payload = sheetPayload('kw', 'rank', id, it.title, it.cover, it.subtitle, 0);
          items.push(it);
        }
        for (const sec of section('kw-group-' + groupName, groupName, '酷我 · ' + groupName,
          LAY_RANK_GROUP, items, rankMore(groupName, 'kw'))) {
          out.push(sec);
        }
      }
      return out;
    } catch (e) {
      return [];
    }
  }
}

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import util from '@ohos.util';
import { SongInfo } from '../common/Models';
import { getJson } from './Http';

/**
 * 歌曲评论 · 统一数据层（v1.0 · 2026-11-14）。
 *
 * 设计原则（与工程其它链路一致）：
 *  1. 纯客户端直连官方匿名接口，零三方依赖、不经任何解析服务；
 *  2. 只支持实测可用的平台：wy / tx / kw / kg。咪咕（mg）评论接口已 301 下线且需登录，
 *     由 commentSupported() 直接拦掉，调用方隐藏入口，不伪造空列表、不做假功能；
 *  3. 任何失败（网络、风控、解析、空列表）都返回真实原因给 UI，
 *     绝不返回一条占位评论，也绝不缓存上次结果冒充成功；
 *  4. 各平台 id 体系不同，这里做必要的桥接：
 *     - tx：SongInfo.id 是 songmid，评论接口要数字 songid → client_search_cp 反查；
 *     - kg：SongInfo 只有 hash，评论接口要 childrenid(=audio_id) → getSongInfo.php 换一次；
 *     - wy：SongInfo.id 已是数字 songid；kw：SongInfo.id 已是 rid，都可直接用。
 *  5. 无限滚动（2026-11-14 追加）：官方热评接口大多**没有第二页**——
 *     wy 的 hotComments 固定最多 15 条且只在 offset=0 返回，tx 的 cmd=6 翻页参数
 *     实测无效（pagenum 0/1/2 返回同一批）。因此 hot 流设计成「热评批次置顶 +
 *     自动接续最新评论流」，与官方 App 的「精彩评论 + 最新评论」一致；
 *     调用方按 page 递增追加、按 id 去重即可一直往下刷。
 *
 * 接口实测记录（2026-11-14，沙箱直连）：
 *  - wy  GET  music.163.com/api/v1/resource/comments/R_SO_4_<id>        total=243042
 *  - tx  GET  c.y.qq.com/base/fcgi-bin/fcg_global_comment_h5.fcg          commenttotal=230665
 *  - kw  GET  comment.kuwo.cn/com.s  （comment.s / /comment 均已失效）     total=1746
 *  - kg  GET  gateway.kugou.com/mcomment/v1/cmtlist?...&childrenid=<audio_id>  count=54067
 *
 * 真机回归（2026-11-14）：QQ 评论字段大量为 null → 工具函数必须用 typeof 兜底；
 * 酷狗 POST 空 body 在鸿蒙网络库报 Parameter error → 改走 GET。详见对应代码注释。
 * 无限流回归（2026-11-14）：wy offset=0/20/40/100 均正常翻页；tx cmd=8 pagenum
 * 0/1/2 返回不同数据而 cmd=6 不翻页；kw 推荐 3 页 / 最新 88 页；kg p=1/2/3/10 均正常。
 */

/* ============================ 统一模型 ============================ */

export interface CommentInfo {
  id: string;
  user: string;
  avatar: string;
  content: string;
  likeCount: number;
  timeText: string;
  /** 被引用的回复内容，没有则为空串 */
  replyTo: string;
  hot: boolean;
}

export interface CommentPage {
  ok: boolean;
  /** false = 该平台不提供评论，调用方应隐藏入口，不要显示空白页 */
  supported: boolean;
  platform: string;
  total: number;
  comments: CommentInfo[];
  /** 失败时给用户看的真实原因 */
  error: string;
  /** 是否还有下一批；调用方触底时传 page+1 继续拉 */
  hasMore: boolean;
}

export function emptyCommentPage(platform: string): CommentPage {
  return {
    ok: false, supported: true, platform: platform, total: 0,
    comments: [], error: '', hasMore: false
  };
}

/** 咪咕歌直接隐藏评论入口；本地歌曲 / MusicFree 音源同样没有可查的评论区 */
export function commentSupported(song: SongInfo): boolean {
  const s: string = song.source;
  return s === 'wy' || s === 'tx' || s === 'kw' || s === 'kg';
}

export function commentPlatformName(source: string): string {
  if (source === 'wy') {
    return '网易云音乐';
  }
  if (source === 'tx') {
    return 'QQ 音乐';
  }
  if (source === 'kw') {
    return '酷我音乐';
  }
  if (source === 'kg') {
    return '酷狗音乐';
  }
  return '该平台';
}

/* ============================ 通用工具 ============================ */

const PAGE_SIZE: number = 20;

const WY_REF: string = 'https://music.163.com/';
const TX_REF: string = 'https://y.qq.com/';
const KW_REF: string = 'https://www.kuwo.cn/';
const KG_REF: string = 'https://m.kugou.com/';

function toBytes(text: string): Uint8Array {
  const encoder = util.TextEncoder.create('utf-8');
  return encoder.encodeInto(text);
}

function hexOf(bytes: Uint8Array): string {
  let out: string = '';
  for (let i = 0; i < bytes.length; i++) {
    const h: string = bytes[i].toString(16);
    out += h.length < 2 ? '0' + h : h;
  }
  return out;
}

/** 原生 MD5。酷狗 Android 签名只需要它，不引 crypto-js / 不碰 BigInt */
export function md5Hex(text: string): string {
  try {
    const md = cryptoFramework.createMd('MD5');
    md.updateSync({ data: toBytes(text) });
    const out = md.digestSync();
    return hexOf(out.data);
  } catch (e) {
    return '';
  }
}

/**
 * 只能用 typeof 兜底，不能只判 undefined。
 * 真机回归（2026-11-14）：QQ 音乐评论接口把 middlecommentcontent / avatarurl
 * 等字段大量返回 null，旧写法 str(null) 直接把 null 透出去，调用方读 .length
 * 就抛「Cannot read property length of null」，整个评论页变成报错。
 */
function str(v: string | undefined): string {
  return typeof v === 'string' ? v : '';
}

function num(v: number | undefined): number {
  return typeof v === 'number' && !Number.isNaN(v) ? v : 0;
}

/** 字符串型数字（酷我 like_num 是字符串） */
function numText(v: string | undefined): number {
  if (typeof v !== 'string' || v.length === 0) {
    return 0;
  }
  const n: number = Number.parseInt(v, 10);
  return Number.isNaN(n) ? 0 : n;
}

function isDigits(text: string): boolean {
  if (typeof text !== 'string' || text.length === 0) {
    return false;
  }
  for (let i = 0; i < text.length; i++) {
    const c: string = text.charAt(i);
    if (c < '0' || c > '9') {
      return false;
    }
  }
  return true;
}

/** 秒级 unix 时间戳 → 'MM-DD HH:mm' */
function unixTimeText(sec: number): string {
  if (sec <= 0) {
    return '';
  }
  const d: Date = new Date(sec * 1000);
  const mo: number = d.getMonth() + 1;
  const day: number = d.getDate();
  const hh: number = d.getHours();
  const mm: number = d.getMinutes();
  const p2 = (v: number): string => v < 10 ? '0' + v.toString() : v.toString();
  return p2(mo) + '-' + p2(day) + ' ' + p2(hh) + ':' + p2(mm);
}

/** '2024-07-23 21:21:35' → '2024-07-23 21:21'，异常值原样截断返回 */
function plainTimeText(raw: string | undefined): string {
  const v: string = str(raw);
  return v.length > 16 ? v.substring(0, 16) : v;
}

function firstSinger(singer: string): string {
  const parts: string[] = singer.split('/');
  return parts[0].split('&')[0].trim();
}

function failPage(platform: string, error: string): CommentPage {
  const p: CommentPage = emptyCommentPage(platform);
  p.error = error;
  return p;
}

/* ============================ 网易云 wy ============================ */

interface WyUser {
  nickname?: string;
  avatarUrl?: string;
}

interface WyItem {
  commentId?: number;
  content?: string;
  likedCount?: number;
  time?: number;
  user?: WyUser;
}

interface WyResp {
  code?: number;
  total?: number;
  hotComments?: WyItem[];
  comments?: WyItem[];
  more?: boolean;
}

/**
 * 网易云偶发 -462（接口侧限流），实测同一 URL 立即重试即可通过（20/20 成功），
 * 且连续翻页时随机出现。不重试的话用户「一直往下刷」会随机撞见错误卡片。
 * 最多 3 次：非 200 的 code 最后一次原样交出去如实报错；网络异常交外层统一兜底。
 */
async function wyFetch(url: string): Promise<WyResp> {
  for (let i = 0; i < 3; i++) {
    try {
      const resp: WyResp = await getJson<WyResp>(url, WY_REF, 12000);
      if (num(resp.code) === 200 || i === 2) {
        return resp;
      }
    } catch (e) {
      // ArkTS 严格模式禁止 throw 任意类型（arkts-limited-throw），
      // 沿用工程惯例 throw new Error，让外层 catch 按「读取失败」如实展示。
      if (i === 2) {
        throw new Error('网易云评论请求连续失败');
      }
    }
  }
  return {} as WyResp;
}

function wyItemToComment(raw: WyItem, hot: boolean): CommentInfo {
  const u: WyUser = raw.user ?? {} as WyUser;
  return {
    id: num(raw.commentId).toString(),
    user: str(u.nickname),
    avatar: str(u.avatarUrl),
    content: str(raw.content),
    likeCount: num(raw.likedCount),
    timeText: unixTimeText(num(raw.time)),
    replyTo: '',
    hot: hot
  };
}

async function wyComments(song: SongInfo, page: number, hot: boolean): Promise<CommentPage> {
  const platform: string = 'wy';
  if (!isDigits(song.id)) {
    return failPage(platform, '这首歌缺少网易云歌曲 ID，无法读取评论');
  }
  // 热评批次只在第 1 页：实测 hotComments 固定最多 15 条、offset>0 时为空，
  // 接口没有「热评第 2 页」。page>=2 起自动接续最新评论流，offset 从 0 重新开始。
  // 最新流则全程按 offset 翻页。这样「热评」也能一直往下刷。
  const hotBatch: boolean = hot && page === 1;
  const latestPage: number = hot ? page - 1 : page;
  const offset: number = hotBatch ? 0 : (latestPage - 1) * PAGE_SIZE;
  const url: string = 'https://music.163.com/api/v1/resource/comments/R_SO_4_' + song.id +
    '?limit=' + PAGE_SIZE.toString() + '&offset=' + offset.toString();
  try {
    const resp: WyResp = await wyFetch(url);
    if (num(resp.code) !== 200) {
      // 重试后仍失败（含 -462 持续限流）才如实告知，不要显示成「暂无评论」
      return failPage(platform, '网易云未返回评论（code ' + num(resp.code).toString() + '）');
    }
    let raws: WyItem[] = hotBatch ? (resp.hotComments ?? []) : (resp.comments ?? []);
    let effectiveHot: boolean = hotBatch;
    // 少数歌曲没有热评：直接用同一份响应里的最新评论兜底，别让首屏变成空白
    if (hotBatch && raws.length === 0) {
      raws = resp.comments ?? [];
      effectiveHot = false;
    }
    const list: CommentInfo[] = [];
    for (const raw of raws) {
      list.push(wyItemToComment(raw, effectiveHot));
    }
    const total: number = num(resp.total);
    const result: CommentPage = emptyCommentPage(platform);
    result.ok = true;
    result.total = total;
    result.comments = list;
    // 热评批次后面一定还有最新流可续刷；最新流按 more + 总数判断
    result.hasMore = hotBatch
      ? (total > 0 && list.length > 0)
      : (resp.more === true && list.length > 0 && offset + list.length < total);
    return result;
  } catch (e) {
    return failPage(platform, '读取网易云评论失败：' + String(e));
  }
}

/* ============================ QQ 音乐 tx ============================ */

interface TxSinger {
  name?: string;
}

interface TxSearchItem {
  songid?: number;
  songname?: string;
  singer?: TxSinger[];
}

interface TxSearchSong {
  list?: TxSearchItem[];
}

interface TxSearchData {
  song?: TxSearchSong;
}

interface TxSearchResp {
  code?: number;
  data?: TxSearchData;
}

interface TxItem {
  commentid?: string;
  nick?: string;
  avatarurl?: string;
  rootcommentcontent?: string;
  middlecommentcontent?: string;
  rootcommentnick?: string;
  praisenum?: number;
  time?: number;
}

interface TxBlock {
  commentlist?: TxItem[];
  commenttotal?: number;
}

interface TxResp {
  code?: number;
  comment?: TxBlock;
  hot_comment?: TxBlock;
}

/** mid → 数字 songid：评论接口只认 topid 数字，直接传 mid 会返回 commentlist: null */
async function txResolveId(song: SongInfo): Promise<string> {
  if (isDigits(song.id)) {
    return song.id;
  }
  const keyword: string = song.name + ' ' + firstSinger(song.singer);
  const url: string = 'https://c.y.qq.com/soso/fcgi-bin/client_search_cp?w=' +
    encodeURIComponent(keyword) + '&format=json&p=1&n=8';
  try {
    const resp: TxSearchResp = await getJson<TxSearchResp>(url, TX_REF, 10000);
    const items: TxSearchItem[] = resp.data?.song?.list ?? [];
    for (const item of items) {
      const id: number = num(item.songid);
      const nm: string = str(item.songname);
      // 同名才认，避免把翻唱 / 别的版本评论挂到这首歌上
      if (id > 0 && nm.length > 0 && nm === song.name) {
        return id.toString();
      }
    }
    // 严格同名没命中就退而求其次取第一条有 id 的结果
    for (const item of items) {
      if (num(item.songid) > 0) {
        return num(item.songid).toString();
      }
    }
  } catch (e) {
    // 落到下面统一报错
  }
  return '';
}

function txItemToComment(raw: TxItem, hot: boolean): CommentInfo {
  const middle: string = str(raw.middlecommentcontent);
  const root: string = str(raw.rootcommentcontent);
  const content: string = middle.length > 0 ? middle : root;
  const replyTo: string = middle.length > 0 && root.length > 0
    ? str(raw.rootcommentnick) + '：' + root
    : '';
  return {
    id: str(raw.commentid),
    user: str(raw.nick),
    avatar: str(raw.avatarurl),
    content: content,
    likeCount: num(raw.praisenum),
    timeText: unixTimeText(num(raw.time)),
    replyTo: replyTo,
    hot: hot
  };
}

async function txComments(song: SongInfo, page: number, hot: boolean): Promise<CommentPage> {
  const platform: string = 'tx';
  const topid: string = await txResolveId(song);
  if (topid.length === 0) {
    return failPage(platform, '没找到这首歌在 QQ 音乐的歌曲 ID，无法读取评论');
  }
  // 实测（2026-11-14）：cmd=6 的 pagenum 完全无效，0/1/2 返回同一批且 hot_comment 恒为 null；
  // 只有 cmd=8 能翻页，且 pagenum=0 的响应里带 15 条官方精选热评（hot_comment 块）。
  // 所以热评批次用 cmd=8&pagenum=0 取 hot_comment，之后接续最新评论流。
  const hotBatch: boolean = hot && page === 1;
  const pagenum: number = hotBatch ? 0 : (hot ? page - 2 : page - 1);
  const url: string = 'https://c.y.qq.com/base/fcgi-bin/fcg_global_comment_h5.fcg' +
    '?biztype=1&topid=' + topid + '&cmd=8' +
    '&pagenum=' + pagenum.toString() + '&pagesize=' + PAGE_SIZE.toString() +
    '&format=json&inCharset=utf8&outCharset=utf8';
  try {
    const resp: TxResp = await getJson<TxResp>(url, TX_REF, 12000);
    if (num(resp.code) !== 0) {
      return failPage(platform, 'QQ 音乐未返回评论（code ' + num(resp.code).toString() + '）');
    }
    const hotBlock: TxBlock = resp.hot_comment ?? {} as TxBlock;
    const newBlock: TxBlock = resp.comment ?? {} as TxBlock;
    const newRaws: TxItem[] = newBlock.commentlist ?? [];
    let block: TxBlock = hotBatch ? hotBlock : newBlock;
    let raws: TxItem[] = block.commentlist ?? [];
    let effectiveHot: boolean = hotBatch;
    // 真机实测：部分歌曲把 hot_comment 整个返回 null，评论仍在 comment 块里。
    // 这时降级展示同一份响应里的最新评论，别让「热评」页变成空白。
    if (hotBatch && raws.length === 0 && newRaws.length > 0) {
      block = newBlock;
      raws = newRaws;
      effectiveHot = false;
    }
    const list: CommentInfo[] = [];
    for (const raw of raws) {
      list.push(txItemToComment(raw, effectiveHot));
    }
    const total: number = num(newBlock.commenttotal) > 0
      ? num(newBlock.commenttotal) : num(block.commenttotal);
    const result: CommentPage = emptyCommentPage(platform);
    result.ok = true;
    result.total = total;
    result.comments = list;
    // 热评批次后面还有最新流；最新流按 pagenum + 总数判断
    result.hasMore = hotBatch
      ? newRaws.length > 0
      : (list.length > 0 && (pagenum + 1) * PAGE_SIZE < total);
    return result;
  } catch (e) {
    return failPage(platform, '读取 QQ 音乐评论失败：' + String(e));
  }
}

/* ============================ 酷我 kw ============================ */

interface KwReplyItem {
  msg?: string;
  u_name?: string;
}

interface KwItem {
  id?: string;
  msg?: string;
  u_name?: string;
  u_pic?: string;
  like_num?: string;
  time?: string;
  reply?: KwReplyItem;
}

interface KwResp {
  result?: string;
  total?: number;
  totalPage?: number;
  rows?: KwItem[];
}

function kwItemToComment(raw: KwItem, hot: boolean): CommentInfo {
  const reply: KwReplyItem = raw.reply ?? {} as KwReplyItem;
  const replyMsg: string = str(reply.msg);
  const replyTo: string = replyMsg.length > 0
    ? str(reply.u_name) + '：' + replyMsg
    : '';
  return {
    id: str(raw.id),
    user: str(raw.u_name),
    avatar: str(raw.u_pic),
    content: str(raw.msg),
    likeCount: numText(raw.like_num),
    timeText: plainTimeText(raw.time),
    replyTo: replyTo,
    hot: hot
  };
}

async function kwComments(song: SongInfo, page: number, hot: boolean): Promise<CommentPage> {
  const platform: string = 'kw';
  if (!isDigits(song.id)) {
    return failPage(platform, '这首歌缺少酷我歌曲 ID，无法读取评论');
  }
  // 热评批次取「推荐评论」第 1 页（20 条置顶），page>=2 起接续「最新评论」流。
  // 酷我推荐评论实测只有约 3 页 / 50 条，与其刷完就断，不如尽早接上 88 页的
  // 最新评论，让四个平台的「一直往下刷」体验一致。
  const hotBatch: boolean = hot && page === 1;
  const type: string = hotBatch ? 'get_rec_comment' : 'get_comment';
  const streamPage: number = hotBatch ? 1 : (hot ? page - 1 : page);
  const url: string = 'https://comment.kuwo.cn/com.s?type=' + type +
    '&uid=0&prod=newWeb&digest=15&sid=' + song.id +
    '&page=' + streamPage.toString() + '&rows=' + PAGE_SIZE.toString() + '&f=web';
  try {
    const resp: KwResp = await getJson<KwResp>(url, KW_REF, 12000);
    if (str(resp.result) !== 'ok') {
      return failPage(platform, '酷我未返回评论数据');
    }
    const raws: KwItem[] = resp.rows ?? [];
    const list: CommentInfo[] = [];
    for (const raw of raws) {
      list.push(kwItemToComment(raw, hotBatch));
    }
    const total: number = num(resp.total);
    const result: CommentPage = emptyCommentPage(platform);
    result.ok = true;
    result.total = total;
    result.comments = list;
    result.hasMore = hotBatch
      ? list.length > 0
      : (list.length > 0 && streamPage < num(resp.totalPage));
    return result;
  } catch (e) {
    return failPage(platform, '读取酷我评论失败：' + String(e));
  }
}

/* ============================ 酷狗 kg ============================ */

/** Android 端签名盐值（标准版），见 KuGouMusicApi util/helper.js */
const KG_SALT: string = 'OIlwieks28dk2k092lksi2UIkp';
const KG_CODE: string = 'fc4be23b4e972707f36b8a828a93ba8a';
const KG_APPID: string = '1005';
const KG_CLIENTVER: string = '20489';
const KG_MID: string = '9c3f5b1e7a2d4086bb0e5f7a3c1d9e204';

interface KgSongInfoResp {
  audio_id?: number;
  songName?: string;
}

interface KgCmtItem {
  id?: number;
  content?: string;
  user_name?: string;
  user_pic?: string;
  addtime?: string;
  reply_num?: number;
  pcontent?: string;
}

interface KgCmtResp {
  status?: number;
  err_code?: number;
  count?: number;
  list?: KgCmtItem[];
  msg?: string;
}

/** signature = MD5(salt + 按 key 排序的 key=value 串 + salt) */
function kgAndroidSign(params: Record<string, string>): string {
  const keys: string[] = Object.keys(params).sort();
  let joined: string = '';
  for (const key of keys) {
    joined += key + '=' + params[key];
  }
  return md5Hex(KG_SALT + joined + KG_SALT);
}

function kgItemToComment(raw: KgCmtItem, hot: boolean): CommentInfo {
  const parent: string = str(raw.pcontent);
  return {
    id: num(raw.id).toString(),
    user: str(raw.user_name),
    avatar: str(raw.user_pic),
    content: str(raw.content),
    likeCount: num(raw.reply_num),
    timeText: plainTimeText(raw.addtime),
    replyTo: parent,
    hot: hot
  };
}

/** hash → audio_id：评论接口的 childrenid 用的就是它 */
async function kgResolveAudioId(hash: string): Promise<string> {
  if (hash.length === 0) {
    return '';
  }
  const url: string = 'https://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=' + hash;
  try {
    const resp: KgSongInfoResp = await getJson<KgSongInfoResp>(url, KG_REF, 10000);
    const id: number = num(resp.audio_id);
    return id > 0 ? id.toString() : '';
  } catch (e) {
    return '';
  }
}

async function kgComments(song: SongInfo, page: number): Promise<CommentPage> {
  const platform: string = 'kg';
  let hash: string = typeof song.hash === 'string' ? song.hash : '';
  if (hash.length === 0) {
    hash = typeof song.id === 'string' ? song.id : '';
  }
  const audioId: string = await kgResolveAudioId(hash);
  if (audioId.length === 0) {
    return failPage(platform, '没查到这首歌的酷狗评论资源 ID，无法读取评论');
  }

  const clienttime: string = Math.floor(Date.now() / 1000).toString();
  const params: Record<string, string> = {
    'appid': KG_APPID,
    'clientver': KG_CLIENTVER,
    'clienttime': clienttime,
    'mid': KG_MID,
    'dfid': '-',
    'uuid': '0',
    'userid': '0',
    'token': '',
    'ver': '6',
    'need_show_image': '1',
    'p': page.toString(),
    'pagesize': PAGE_SIZE.toString(),
    'show_classify': '0',
    'show_hotword_list': '0',
    'extdata': '0',
    'code': KG_CODE,
    'childrenid': audioId
  };
  const signature: string = kgAndroidSign(params);
  if (signature.length === 0) {
    return failPage(platform, '本机 MD5 能力不可用，无法生成酷狗请求签名');
  }
  params['signature'] = signature;

  const keys: string[] = Object.keys(params);
  let query: string = '';
  for (let i = 0; i < keys.length; i++) {
    if (i > 0) {
      query += '&';
    }
    query += keys[i] + '=' + encodeURIComponent(params[keys[i]]);
  }
  const url: string = 'https://gateway.kugou.com/mcomment/v1/cmtlist?' + query;

  // 真机回归（2026-11-14）：POST + 空 extraData 在 HarmonyOS NetworkKit 上
  // 直接抛「Parameter error」，请求根本发不出去（沙箱 curl 测不出来）。
  // 该端点实测 GET 同样可用（截图歌曲 count=772 / 20 条，pagesize=20 正常），
  // 改走工程通用的 getJson，不再自己组装 POST。
  // 酷狗 cmtlist 没有热评/最新之分，p 天然可一直翻，hot 参数在此忽略。
  try {
    const resp: KgCmtResp = await getJson<KgCmtResp>(url, KG_REF, 12000);
    if (num(resp.status) !== 1 || num(resp.err_code) !== 0) {
      const msg: string = str(resp.msg);
      return failPage(platform, msg.length > 0
        ? '酷狗未返回评论：' + msg
        : '酷狗未返回评论（err_code ' + num(resp.err_code).toString() + '）');
    }
    const raws: KgCmtItem[] = resp.list ?? [];
    const list: CommentInfo[] = [];
    for (const raw of raws) {
      list.push(kgItemToComment(raw, false));
    }
    const total: number = num(resp.count);
    const result: CommentPage = emptyCommentPage(platform);
    result.ok = true;
    result.total = total;
    result.comments = list;
    result.hasMore = page * PAGE_SIZE < total;
    return result;
  } catch (e) {
    return failPage(platform, '读取酷狗评论失败：' + String(e));
  }
}

/* ============================ 分派入口 ============================ */

/**
 * 读取一批评论，供调用方追加到无限流。page 从 1 开始递增，hot 决定起始流。
 *  hot=true  ：page=1 是官方精选热评批次，page>=2 自动接续该平台的最新评论流
 *              （热评接口本身没有第二页，实测见各平台函数注释），所以能一直往下刷；
 *  hot=false ：全程按最新评论翻页。
 * 返回的 hasMore 表示「是否还有下一批」，调用方触底时传 page+1 继续拉。
 * 调用方必须检查 ok / error，失败时展示真实原因，不要拿空数组当成功。
 */
export async function fetchComments(song: SongInfo, page: number, hot: boolean): Promise<CommentPage> {
  if (!commentSupported(song)) {
    const p: CommentPage = emptyCommentPage(song.source);
    p.supported = false;
    p.error = '该平台暂不支持评论';
    return p;
  }
  const safePage: number = page < 1 ? 1 : page;
  if (song.source === 'wy') {
    return await wyComments(song, safePage, hot);
  }
  if (song.source === 'tx') {
    return await txComments(song, safePage, hot);
  }
  if (song.source === 'kw') {
    return await kwComments(song, safePage, hot);
  }
  return await kgComments(song, safePage);
}

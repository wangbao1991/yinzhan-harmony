/**
 * 导入歌单：把各平台分享出来的歌单 / 专辑链接（或纯 ID）解析成
 * PlatformApi.sheetSongsRaw() 认得的 platform + id + kind。
 *
 * 工程里本来就有「按平台 + ID 取歌单详情」的完整能力（wy/tx/kw/kg/mg 五平台），
 * 搜索页与发现页点歌单走的也是 App.openSheet(sheet)。所以导入一条外链不需要
 * 新写任何取数接口：解析出 id 后构造 SheetInfo 交给详情页即可。
 *
 * 这里刻意不用正则：ArkTS 对 RegExp 的动态构造支持有限，纯字符串扫描更稳，
 * 也方便在 Node 里逐平台复刻验证。
 */
import { platformName } from '../common/Platform';

/** 解析结果；name 是导入后展示用的兜底标题（用户可在面板里自定义） */
export interface PlaylistRef {
  platform: string;
  id: string;
  kind: string;
  name: string;
}

/** 与 PlatformApi.sheetSongsRaw 支持的五个平台严格对齐，别多列没有取数实现的平台 */
export const IMPORT_PLATFORM_IDS: string[] = ['wy', 'tx', 'kw', 'kg', 'mg'];

const ID_CHARS: string = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-';

function isIdChar(c: string): boolean {
  return c.length === 1 && ID_CHARS.indexOf(c) >= 0;
}

/** 从 start 起取一段连续的 ID 字符，遇到 / . ? & # 等分隔符自然停下 */
function takeId(s: string, start: number): string {
  let out: string = '';
  for (let i: number = start; i < s.length; i++) {
    const c: string = s.charAt(i);
    if (!isIdChar(c)) {
      break;
    }
    out += c;
  }
  return out;
}

/** 找 key= 之后的第一段 ID；长 key 必须排在前面，避免 'id=' 命中 'playlistid=' 的前缀 */
function afterKey(url: string, keys: string[]): string {
  for (const k of keys) {
    const i: number = url.indexOf(k);
    if (i >= 0) {
      const v: string = takeId(url, i + k.length);
      if (v.length > 0) {
        return v;
      }
    }
  }
  return '';
}

/** 找 /path/ 之后的第一段 ID（QQ / 酷狗 / 酷我 / 咪咕的分享链接是路径式） */
function afterPath(url: string, paths: string[]): string {
  for (const p of paths) {
    const i: number = url.indexOf(p);
    if (i >= 0) {
      const v: string = takeId(url, i + p.length);
      if (v.length > 0) {
        return v;
      }
    }
  }
  return '';
}

/** 分享文案常是「歌名 https://... 快来听」，把中间那段 URL 截出来 */
function extractUrl(text: string): string {
  const i: number = text.indexOf('http');
  if (i < 0) {
    return '';
  }
  let end: number = text.length;
  for (let j: number = i; j < text.length; j++) {
    const code: number = text.charCodeAt(j);
    const c: string = text.charAt(j);
    if (code <= 32 || code > 127 ||
      c === '"' || c === '\'' || c === ')' || c === ']' || c === '}' ||
      c === ',' || c === ';') {
      end = j;
      break;
    }
  }
  return text.substring(i, end).toLowerCase();
}

/** 链接自带平台时以域名为准；纯 ID / 短链识别不出，才用面板里手选的平台 */
function platformOf(url: string, fallback: string): string {
  if (url.indexOf('163.com') >= 0) {
    return 'wy';
  }
  if (url.indexOf('qq.com') >= 0) {
    return 'tx';
  }
  if (url.indexOf('kugou.com') >= 0) {
    return 'kg';
  }
  if (url.indexOf('kuwo.cn') >= 0) {
    return 'kw';
  }
  if (url.indexOf('migu.cn') >= 0) {
    return 'mg';
  }
  return fallback;
}

/**
 * 解析入口。识别不出 ID 返回 null，由 UI 提示用户「只粘贴 ID 并选平台」。
 * kind 只有 wy / tx 会落到 album（这两家 sheetSongsRaw 有专辑分支），
 * 其余平台一律按 playlist 走，避免把歌单 ID 喂给不存在的专辑接口。
 */
export function parsePlaylistInput(text: string, fallbackPlatform: string): PlaylistRef | null {
  const raw: string = text.trim();
  if (raw.length === 0) {
    return null;
  }
  const url: string = extractUrl(raw);
  const platform: string = platformOf(url, fallbackPlatform);
  if (IMPORT_PLATFORM_IDS.indexOf(platform) < 0) {
    return null;
  }

  let id: string = '';
  let kind: string = 'playlist';
  if (url.length > 0) {
    if (platform === 'wy') {
      id = afterPath(url, ['/playlist/', '/album/']);
      if (id.length === 0) {
        id = afterKey(url, ['playlistid=', 'id=']);
      }
    } else if (platform === 'tx') {
      id = afterPath(url, ['/playlist/', '/album/']);
      if (id.length === 0) {
        id = afterKey(url, ['dissid=', 'tid=', 'id=']);
      }
    } else if (platform === 'kg') {
      id = afterPath(url, ['/special/single/', '/special/', '/album/']);
      if (id.length === 0) {
        id = afterKey(url, ['pid=', 'id=']);
      }
    } else if (platform === 'kw') {
      id = afterPath(url, ['/playlist_detail/', '/playlist/', '/album/']);
      if (id.length === 0) {
        id = afterKey(url, ['pid=', 'id=']);
      }
    } else {
      id = afterPath(url, ['/playlist/', '/album/']);
      if (id.length === 0) {
        id = afterKey(url, ['pid=', 'id=']);
      }
    }
    if ((platform === 'wy' || platform === 'tx') && url.indexOf('album') >= 0) {
      kind = 'album';
    }
  }
  if (id.length === 0 && url.length === 0) {
    // 输入里没有链接：整段当纯 ID（粘贴「123456」这种）
    id = takeId(raw, 0);
  }
  if (id.length === 0) {
    return null;
  }

  const label: string = kind === 'album' ? '专辑' : '歌单';
  const shortId: string = id.length > 12 ? id.substring(0, 12) + '…' : id;
  const name: string = platformName(platform) + label + ' ' + shortId;
  const ref: PlaylistRef = { platform: platform, id: id, kind: kind, name: name };
  return ref;
}

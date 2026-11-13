import { PlatformDef } from './Models';

/** 支持的平台。搜索与发现都由应用直连官方接口，音源脚本只负责取播放地址。 */
export const PLATFORMS: PlatformDef[] = [
  { id: 'kw', name: '酷我音乐', short: '酷我', color: '#FFFFB300', gradient: '#FFFFD54F' },
  { id: 'tx', name: 'QQ音乐', short: 'QQ', color: '#FF31C27C', gradient: '#FF6FE3A8' },
  { id: 'wy', name: '网易云音乐', short: '网易云', color: '#FFE63B3B', gradient: '#FFFF7A7A' },
  { id: 'kg', name: '酷狗音乐', short: '酷狗', color: '#FF2CA2F9', gradient: '#FF6FC8FF' },
  { id: 'mg', name: '咪咕音乐', short: '咪咕', color: '#FFFF5C8A', gradient: '#FFFF9AB5' }
];

/**
 * 「发现」可用的平台。
 *
 * 咪咕的榜单和推荐歌单接口对匿名请求一直返空，页面上永远是空态，
 * 与其留一个点了没内容的胶囊，不如从发现里摘掉。
 * PLATFORMS 全表不动——搜索、歌单详情、音源仍然按它走。
 */
export const DISCOVER_PLATFORM_IDS: string[] = ['wy', 'tx', 'kw', 'kg'];

/** 发现页 / 设置页「默认发现平台」共用的平台清单 */
export function discoverPlatforms(): PlatformDef[] {
  const list: PlatformDef[] = [];
  for (const id of DISCOVER_PLATFORM_IDS) {
    list.push(platformDef(id));
  }
  return list;
}

export function platformDef(id: string): PlatformDef {
  for (const item of PLATFORMS) {
    if (item.id === id) {
      return item;
    }
  }
  return { id: id, name: id, short: id, color: '#FF8A8F99', gradient: '#FFB9BEC7' };
}

export function platformName(id: string): string {
  if (id === 'local') {
    return '本地';
  }
  // MusicFree 插件的 source 是 'mf:<音源id>'，不该在行内标签里露出一长串 id
  if (id.indexOf('mf:') === 0) {
    return 'MusicFree 音源';
  }
  return platformDef(id).name;
}

export function platformShort(id: string): string {
  if (id === 'local') {
    return '本地';
  }
  if (id.indexOf('mf:') === 0) {
    return 'MF';
  }
  return platformDef(id).short;
}

export function platformColor(id: string): string {
  if (id === 'local') {
    return '#FF12B76A';
  }
  if (id.indexOf('mf:') === 0) {
    return '#FF2E9C93';
  }
  return platformDef(id).color;
}

export function allPlatformIds(): string[] {
  const ids: string[] = [];
  for (const item of PLATFORMS) {
    ids.push(item.id);
  }
  return ids;
}

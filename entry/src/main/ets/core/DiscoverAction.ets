import { SheetInfo, SongInfo, ArtistInfo } from '../common/Models';
import {
  DiscoverItem, ACT_SHEET, ACT_SONG, ACT_ARTIST, ACT_SEARCH
} from '../common/Discover';
import { App } from './App';

/**
 * 板块条目的统一点击分派（v2.56 · 板块全量页接入）。
 *
 * 首页板块流与「更多 ›」全量页渲染的是同一批 DiscoverItem，点击行为必须一致，
 * 所以从 DiscoverPage 抽到这里共用一份，避免两处各写一遍还原逻辑。
 * 条目只带扁平字段 + payload JSON，这里还原成既有 SheetInfo / SongInfo /
 * ArtistInfo 再走原来的详情页与音源取链，音源引擎零改动。
 */
export function openDiscoverItem(item: DiscoverItem): void {
  if (item.action === ACT_SONG) {
    if (item.payload.length > 0) {
      try {
        App.get().playOne(JSON.parse(item.payload) as SongInfo);
      } catch (e) {
        App.get().openSearch(item.title);
      }
    }
    return;
  }
  if (item.action === ACT_ARTIST) {
    if (item.payload.length > 0) {
      try {
        App.get().openArtist(JSON.parse(item.payload) as ArtistInfo);
      } catch (e) {
        App.get().openSearch(item.title);
      }
    }
    return;
  }
  if (item.action === ACT_SEARCH) {
    App.get().openSearch(item.keyword.length > 0 ? item.keyword : item.title);
    return;
  }
  if (item.action === ACT_SHEET && item.payload.length > 0) {
    try {
      App.get().openSheet(JSON.parse(item.payload) as SheetInfo);
    } catch (e) {
      App.get().toast('这个内容暂时打不开');
    }
  }
}

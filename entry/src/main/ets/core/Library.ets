import { SongInfo, UserPlaylist, SheetInfo, newSheet, songKey } from '../common/Models';
import { PrefKeys } from '../common/Constants';
import { uuid } from '../common/Utils';
import { Store } from './Store';

/**
 * 音乐库：收藏、自建歌单、最近播放。
 * 收藏按「平台 + id」去重；最近播放按「歌名 + 歌手」跨平台合并——
 * 同一首歌不管从哪个平台播放，只保留最新一次的来源。
 */
export class Library {
  private static instance: Library = new Library();
  static get(): Library {
    return Library.instance;
  }

  /**
   * v2.65：wy 歌单收藏变更钩子。由 WyFavSync 在 App.init 里注册，
   * 用户收藏 / 取消收藏网易云歌单时把变更异步写到本人账号。
   * 用静态函数指针而不是 import WyFavSync，避免 Library ↔ WyFavSync 循环依赖。
   */
  static wyFavHook: ((sheet: SheetInfo, added: boolean) => void) | null = null;

  /**
   * v1.0：一个歌单归属哪个「账号同步平台」。歌单的 platform 用音源平台 id
   * （wy / tx / kg）；账号同步现在只处理 wy，tx / kg 歌单仍可本地收藏但不再同步云端账号。
   * 只有 wy / tx / kg 三个平台有本人账号，其它平台（kw / mg / local）返回空串。
   */
  static syncPlatform(sheet: SheetInfo): string {
    if (sheet.platform !== 'wy' && sheet.platform !== 'tx' && sheet.platform !== 'kg') {
      return '';
    }
    if (sheet.kind !== 'playlist' && sheet.kind !== 'user') {
      return '';
    }
    return Library.wyIsId(sheet.id) ? sheet.platform : '';
  }

  /** v2.66：某平台可同步歌单的纯数字 id（跨平台复用 wyIsId 判定） */
  static syncIdOf(sheet: SheetInfo): string {
    return Library.syncPlatform(sheet).length > 0 ? sheet.id : '';
  }

  /**
   * 能参与网易云账号同步的歌单：wy 平台 + 纯数字歌单 id + 可订阅 kind。
   * 返回归一化后的 id，其它情况返回空串。
   *
   * 为什么限制 kind：网易云账号的「收藏歌单」只含普通歌单，榜单 / 专辑 /
   * 歌手作品没有对应订阅实体，本地自建歌单更是纯本地数据，硬同步只会写坏账号。
   * 为什么只认纯数字 id：洛雪音源 / 本地导入的 id 可能是 mid、hash，
   * 拿去调 subscribe 必然失败。
   */
  static wySyncId(sheet: SheetInfo): string {
    if (sheet.platform !== 'wy') {
      return '';
    }
    if (sheet.kind !== 'playlist' && sheet.kind !== 'user') {
      return '';
    }
    return Library.wyIsId(sheet.id) ? sheet.id : '';
  }

  /** 纯数字字符串判定（不用正则，ArkTS 对动态 RegExp 支持有限） */
  static wyIsId(id: string): boolean {
    if (id.length === 0) {
      return false;
    }
    for (let i = 0; i < id.length; i++) {
      const c: number = id.charCodeAt(i);
      if (c < 48 || c > 57) {
        return false;
      }
    }
    return true;
  }

  private favorites: SongInfo[] = [];
  private playlists: UserPlaylist[] = [];
  private history: SongInfo[] = [];
  /** 收藏的歌单：平台歌单 / 榜单 / 专辑 / 歌手作品，与「歌曲收藏」分开存 */
  private favoriteSheets: SheetInfo[] = [];
  private listeners: Array<() => void> = [];
  private loaded: boolean = false;

  init(): void {
    if (this.loaded) {
      return;
    }
    this.loaded = true;
    this.favorites = this.readSongs(PrefKeys.FAVORITES);
    this.history = this.dedupeHistory(this.readSongs(PrefKeys.HISTORY));
    this.favoriteSheets = this.readSheets(PrefKeys.FAVORITE_SHEETS);
    const text = Store.get().getString(PrefKeys.PLAYLISTS, '[]');
    try {
      this.playlists = JSON.parse(text) as UserPlaylist[];
    } catch (e) {
      this.playlists = [];
    }
  }

  /**
   * v2.22 备份恢复后重新读盘。
   * 本类是单例、内存里四份数组只在启动时读一次；不重读的话设置页恢复成功、
   * 首页收藏数却还是旧值。重读完走一次 notify()，让所有订阅页面即时刷新。
   */
  reload(): void {
    this.loaded = false;
    this.init();
    this.notify();
  }

  private readSongs(key: string): SongInfo[] {
    const text = Store.get().getString(key, '[]');
    try {
      return JSON.parse(text) as SongInfo[];
    } catch (e) {
      return [];
    }
  }

  /** 读收藏歌单：宽容解析，脏数据不该让整个音乐库起不来 */
  private readSheets(key: string): SheetInfo[] {
    const text = Store.get().getString(key, '[]');
    try {
      const list = JSON.parse(text) as SheetInfo[];
      return Array.isArray(list) ? list : [];
    } catch (e) {
      return [];
    }
  }

  onChange(listener: () => void): void {
    this.listeners.push(listener);
  }

  offChange(listener: () => void): void {
    this.listeners = this.listeners.filter((item: () => void): boolean => item !== listener);
  }

  private notify(): void {
    for (const listener of this.listeners) {
      listener();
    }
    // 通知界面刷新（音乐库页、播放页收藏按钮等）
    AppStorage.setOrCreate('libraryVersion', Date.now());
  }

  /* ---------------- 收藏 ---------------- */
  getFavorites(): SongInfo[] {
    return this.favorites;
  }

  isFavorite(song: SongInfo): boolean {
    const key = Library.key(song);
    for (const item of this.favorites) {
      if (Library.key(item) === key) {
        return true;
      }
    }
    return false;
  }

  toggleFavorite(song: SongInfo): boolean {
    const key = Library.key(song);
    const index = this.favorites.findIndex((item: SongInfo): boolean => Library.key(item) === key);
    if (index >= 0) {
      this.favorites.splice(index, 1);
      this.saveFavorites();
      this.notify();
      return false;
    }
    this.favorites.unshift(song);
    if (this.favorites.length > 500) {
      this.favorites = this.favorites.slice(0, 500);
    }
    this.saveFavorites();
    this.notify();
    return true;
  }

  addFavorite(song: SongInfo): void {
    if (!this.isFavorite(song)) {
      this.favorites.unshift(song);
      if (this.favorites.length > 500) {
        this.favorites = this.favorites.slice(0, 500);
      }
      this.saveFavorites();
      this.notify();
    }
  }

  removeFavorite(song: SongInfo): void {
    const key = Library.key(song);
    this.favorites = this.favorites.filter((item: SongInfo): boolean => Library.key(item) !== key);
    this.saveFavorites();
    this.notify();
  }

  private saveFavorites(): void {
    Store.get().put(PrefKeys.FAVORITES, JSON.stringify(this.favorites));
  }

  /**
   * 清空收藏。
   * 和 `removeFavorite` 一样只动这一份列表：本地文件、下载缓存、播放队列都不碰，
   * 清空之后在播放页点一下心形还能重新收藏回来。
   */
  clearFavorites(): void {
    this.favorites = [];
    Store.get().put(PrefKeys.FAVORITES, '[]');
    this.notify();
  }

  /* ---------------- 收藏歌单 ---------------- */
  /**
   * 歌单唯一键：平台 + 类型 + id（id 为空时退回名字）。
   * 各平台歌单 id 会撞号（比如都从 1 开始），只比 id 会把网易云的榜当成 QQ 的。
   */
  static sheetKey(sheet: SheetInfo): string {
    const id = sheet.id.length > 0 ? sheet.id : sheet.name;
    return sheet.platform + '|' + sheet.kind + '|' + id;
  }

  getFavoriteSheets(): SheetInfo[] {
    return this.favoriteSheets;
  }

  isSheetFavorite(sheet: SheetInfo): boolean {
    const key = Library.sheetKey(sheet);
    for (const item of this.favoriteSheets) {
      if (Library.sheetKey(item) === key) {
        return true;
      }
    }
    return false;
  }

  /** 点一下切换收藏，返回切换后的状态；落盘后走统一 notify 广播 libraryVersion */
  toggleSheetFavorite(sheet: SheetInfo): boolean {
    const key = Library.sheetKey(sheet);
    const index = this.favoriteSheets.findIndex((it: SheetInfo): boolean => Library.sheetKey(it) === key);
    if (index >= 0) {
      this.favoriteSheets.splice(index, 1);
      this.saveFavoriteSheets();
      this.notify();
      // v2.65：本地乐观更新已完成，再把这次取消异步写到网易云账号。
      // hook 放在落盘/广播之后，云端失败也不会拖慢或回滚界面。
      Library.fireWyFavHook(sheet, false);
      return false;
    }
    const copy: SheetInfo = {
      id: sheet.id, name: sheet.name, cover: sheet.cover, description: sheet.description,
      platform: sheet.platform, kind: sheet.kind, trackCount: sheet.trackCount,
      playCount: sheet.playCount, creator: sheet.creator, updateTime: sheet.updateTime,
      subtitle: sheet.subtitle
    };
    this.favoriteSheets.unshift(copy);
    if (this.favoriteSheets.length > 300) {
      this.favoriteSheets = this.favoriteSheets.slice(0, 300);
    }
    this.saveFavoriteSheets();
    this.notify();
    Library.fireWyFavHook(sheet, true);
    return true;
  }

  /**
   * v2.65/v2.66：本地收藏变更 → 通知对应平台的同步引擎。
   * 方法名沿用历史（自检锁定调用点），v1.0 起只在 wy 歌单上触发账号同步钩子
   * 三个引擎；只有可订阅歌单（平台+纯数字 id+playlist/user）才往外发，
   * hook 未注册（单测 / 早期启动）时静默跳过，不影响本地收藏本身。
   */
  private static fireWyFavHook(sheet: SheetInfo, added: boolean): void {
    const plat = Library.syncPlatform(sheet);
    if (plat.length === 0) {
      return;
    }
    if (plat === 'wy' && Library.wyFavHook !== null && Library.wySyncId(sheet).length > 0) {
      Library.wyFavHook(sheet, added);
    }
  }

  /**
   * v2.65：本地「参与账号同步的 wy 歌单」id 快照（去重、按数字 id）。
   * 供同步引擎做差量比对；kind 差异（playlist / user）在这里被抹平。
   */
  wyFavoriteIds(): string[] {
    const out: string[] = [];
    for (const sheet of this.favoriteSheets) {
      const id = Library.wySyncId(sheet);
      if (id.length > 0 && out.indexOf(id) < 0) {
        out.push(id);
      }
    }
    return out;
  }

  /**
   * v2.65：应用一次云端对账结果 —— 只动 wy 可订阅歌单，其它平台收藏一律不碰。
   *
   * 关键约束：
   *  - **不会触发 wyFavHook**：这是云端回写，再往外发就成死循环了；
   *  - 按数字 id 匹配，不用 sheetKey：同一个歌单即便本地存成 user / playlist，
   *    也只保留一份，顺带自愈历史重复卡；
   *  - 一次过滤、一次落盘、一次 notify，避免多处 UI 收到半截状态；
   *  - 新增项统一由同步引擎构造成 kind='playlist'，详情页取歌走 wyPlaylistSongs。
   */
  applyWyFavSync(addSheets: SheetInfo[], removeIds: string[]): number {
    if (addSheets.length === 0 && removeIds.length === 0) {
      return 0;
    }
    const before = this.favoriteSheets.length;
    const kept: SheetInfo[] = [];
    /** 已经保留下来的 wy 同步 id：既防止云端重复加，也自愈历史重复卡 */
    const seen: string[] = [];
    for (const sheet of this.favoriteSheets) {
      const id = Library.wySyncId(sheet);
      if (id.length === 0) {
        // 非 wy 可同步项（其它平台 / 榜单 / 专辑 / 本地）：原样保留，一个不动
        kept.push(sheet);
        continue;
      }
      if (removeIds.indexOf(id) >= 0) {
        continue;
      }
      if (seen.indexOf(id) >= 0) {
        continue;
      }
      seen.push(id);
      kept.push(sheet);
    }

    // 云端新增的歌单补到最前；本地已有同 id 的不再重复加
    let added = 0;
    for (const sheet of addSheets) {
      const id = Library.wySyncId(sheet);
      if (id.length === 0 || seen.indexOf(id) >= 0 || removeIds.indexOf(id) >= 0) {
        continue;
      }
      const copy: SheetInfo = {
        id: sheet.id, name: sheet.name, cover: sheet.cover, description: sheet.description,
        platform: sheet.platform, kind: sheet.kind, trackCount: sheet.trackCount,
        playCount: sheet.playCount, creator: sheet.creator, updateTime: sheet.updateTime,
        subtitle: sheet.subtitle
      };
      kept.unshift(copy);
      seen.push(id);
      added++;
    }

    this.favoriteSheets = kept;
    if (this.favoriteSheets.length > 300) {
      this.favoriteSheets = this.favoriteSheets.slice(0, 300);
    }
    this.saveFavoriteSheets();
    this.notify();
    return added + Math.abs(before - this.favoriteSheets.length);
  }

  /**
   * v2.66：某平台本地「参与账号同步的歌单」id 快照（去重、纯数字 id）。
   * 供 QQ / 酷狗同步引擎做差量比对；kind 差异（playlist / user）在这里被抹平。
   */
  favSyncIds(platform: string): string[] {
    const out: string[] = [];
    for (const sheet of this.favoriteSheets) {
      if (Library.syncPlatform(sheet) !== platform) {
        continue;
      }
      const id = Library.syncIdOf(sheet);
      if (id.length > 0 && out.indexOf(id) < 0) {
        out.push(id);
      }
    }
    return out;
  }

  /**
   * v2.66：QQ / 酷狗云端对账结果回写 —— 只动指定平台的可同步歌单，其它平台一律不碰。
   *
   * 与 applyWyFavSync 同构（保留那个 wy 专用方法供既有引擎/自检），差别只在按
   * platform 过滤而非写死 wy。关键约束一致：
   *  - **不触发任何 hook**：这是云端回写，再往外发就成死循环；
   *  - 按纯数字 id 匹配，不用 sheetKey：同一个歌单本地存成 user / playlist 也只留一份；
   *  - 一次过滤、一次落盘、一次 notify，避免多处 UI 收到半截状态。
   */
  applyFavSync(platform: string, addSheets: SheetInfo[], removeIds: string[]): number {
    if (addSheets.length === 0 && removeIds.length === 0) {
      return 0;
    }
    const before = this.favoriteSheets.length;
    const kept: SheetInfo[] = [];
    const seen: string[] = [];
    for (const sheet of this.favoriteSheets) {
      const belongs = Library.syncPlatform(sheet) === platform;
      const id = belongs ? Library.syncIdOf(sheet) : '';
      if (!belongs || id.length === 0) {
        // 其它平台 / 本地 / 榜单 / 专辑：原样保留，一个不动
        kept.push(sheet);
        continue;
      }
      if (removeIds.indexOf(id) >= 0) {
        continue;
      }
      if (seen.indexOf(id) >= 0) {
        continue;
      }
      seen.push(id);
      kept.push(sheet);
    }

    let added = 0;
    for (const sheet of addSheets) {
      if (Library.syncPlatform(sheet) !== platform) {
        continue;
      }
      const id = Library.syncIdOf(sheet);
      if (id.length === 0 || seen.indexOf(id) >= 0 || removeIds.indexOf(id) >= 0) {
        continue;
      }
      const copy: SheetInfo = {
        id: sheet.id, name: sheet.name, cover: sheet.cover, description: sheet.description,
        platform: sheet.platform, kind: sheet.kind, trackCount: sheet.trackCount,
        playCount: sheet.playCount, creator: sheet.creator, updateTime: sheet.updateTime,
        subtitle: sheet.subtitle
      };
      kept.unshift(copy);
      seen.push(id);
      added++;
    }

    this.favoriteSheets = kept;
    if (this.favoriteSheets.length > 300) {
      this.favoriteSheets = this.favoriteSheets.slice(0, 300);
    }
    this.saveFavoriteSheets();
    this.notify();
    return added + Math.abs(before - this.favoriteSheets.length);
  }

  /**
   * v2.49：批量取消收藏歌单。keys 为 Library.sheetKey() 的结果。
   * 去重 → 一次过滤 → 一次落盘 → 一次 notify；不在外层循环单删（那会写盘 N 次、
   * 广播 N 轮，选择模式的勾选会被连续刷新打断）。返回实际移除数量。
   */
  removeSheetFavorites(keys: string[]): number {
    const kill: string[] = [];
    for (const key of keys) {
      if (kill.indexOf(key) < 0) {
        kill.push(key);
      }
    }
    if (kill.length === 0) {
      return 0;
    }
    const before = this.favoriteSheets.length;
    // v2.65：先记下被移除的 wy 歌单，落盘后逐个把「取消收藏」写到账号。
    // 放在 filter 之前取，过滤完数组里已经没有这些对象了。
    const removedWy: SheetInfo[] = [];
    for (const it of this.favoriteSheets) {
      // v2.66：收集所有「账号同步平台」被删的歌单（wy/qq/kg），由 fireWyFavHook 分发
      if (kill.indexOf(Library.sheetKey(it)) >= 0 && Library.syncIdOf(it).length > 0) {
        removedWy.push(it);
      }
    }
    this.favoriteSheets = this.favoriteSheets.filter(
      (it: SheetInfo): boolean => kill.indexOf(Library.sheetKey(it)) < 0);
    const removed = before - this.favoriteSheets.length;
    if (removed > 0) {
      this.saveFavoriteSheets();
      this.notify();
      for (const sheet of removedWy) {
        Library.fireWyFavHook(sheet, false);
      }
    }
    return removed;
  }

  /** 单删复用批量路径，避免两条实现以后行为分叉 */
  removeSheetFavorite(sheet: SheetInfo): void {
    this.removeSheetFavorites([Library.sheetKey(sheet)]);
  }

  private saveFavoriteSheets(): void {
    Store.get().put(PrefKeys.FAVORITE_SHEETS, JSON.stringify(this.favoriteSheets));
  }

  /* ---------------- 最近播放 ---------------- */
  getHistory(): SongInfo[] {
    return this.history;
  }

  addHistory(song: SongInfo): void {
    if (song.source === 'local' && song.id.length === 0) {
      return;
    }
    const key = this.histKeyOf(song);
    this.history = this.history.filter((item: SongInfo): boolean => this.histKeyOf(item) !== key);
    this.history.unshift(song);
    if (this.history.length > 200) {
      this.history = this.history.slice(0, 200);
    }
    Store.get().put(PrefKeys.HISTORY, JSON.stringify(this.history));
    // 以前这里只落盘不广播：播完一首回首页/音乐库，「最近播放」还是旧的。
    // 订阅了 libraryVersion 的页面（首页、音乐库、歌单页）靠这句才会重算。
    this.notify();
  }

  /** 历史去重键：歌名+歌手都有时用跨平台键，缺名字的退回平台键避免误合并 */
  private histKeyOf(song: SongInfo): string {
    if (song.name.length > 0 && song.singer.length > 0) {
      return songKey(song);
    }
    return Library.key(song);
  }

  /** 旧记录一次性合并：同名同歌手只留最新一条 */
  private dedupeHistory(list: SongInfo[]): SongInfo[] {
    const seen = new Set<string>();
    const out: SongInfo[] = [];
    for (const item of list) {
      const key = this.histKeyOf(item);
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      out.push(item);
    }
    return out;
  }

  /**
   * 移除单条播放记录。
   * 键必须和写入时用同一个 histKeyOf（歌名 + 歌手），否则同一首歌从别的平台
   * 播过一次，用平台键去删是删不掉的——列表里那条会像点了没反应。
   */
  removeHistory(song: SongInfo): void {
    const key = this.histKeyOf(song);
    this.history = this.history.filter((item: SongInfo): boolean => this.histKeyOf(item) !== key);
    Store.get().put(PrefKeys.HISTORY, JSON.stringify(this.history));
    this.notify();
  }

  clearHistory(): void {
    this.history = [];
    Store.get().put(PrefKeys.HISTORY, '[]');
    this.notify();
  }

  /* ---------------- 自建歌单 ---------------- */
  getPlaylists(): UserPlaylist[] {
    return this.playlists;
  }

  getPlaylist(id: string): UserPlaylist | null {
    for (const item of this.playlists) {
      if (item.id === id) {
        return item;
      }
    }
    return null;
  }

  createPlaylist(name: string): UserPlaylist {
    const list: UserPlaylist = {
      id: uuid(),
      name: name.trim().length > 0 ? name.trim() : '新建歌单',
      cover: '',
      createdAt: Date.now(),
      updatedAt: Date.now(),
      songs: []
    };
    this.playlists.unshift(list);
    this.savePlaylists();
    this.notify();
    return list;
  }

  renamePlaylist(id: string, name: string): void {
    const list = this.getPlaylist(id);
    if (list === null || name.trim().length === 0) {
      return;
    }
    list.name = name.trim();
    list.updatedAt = Date.now();
    this.savePlaylists();
    this.notify();
  }

  deletePlaylist(id: string): void {
    this.playlists = this.playlists.filter((item: UserPlaylist): boolean => item.id !== id);
    this.savePlaylists();
    this.notify();
  }

  addToPlaylist(id: string, song: SongInfo): boolean {
    const list = this.getPlaylist(id);
    if (list === null) {
      return false;
    }
    const key = Library.key(song);
    for (const item of list.songs) {
      if (Library.key(item) === key) {
        return false;
      }
    }
    list.songs.push(song);
    list.updatedAt = Date.now();
    if (list.cover.length === 0 && song.cover.length > 0) {
      list.cover = song.cover;
    }
    this.savePlaylists();
    this.notify();
    return true;
  }

  removeFromPlaylist(id: string, song: SongInfo): void {
    const list = this.getPlaylist(id);
    if (list === null) {
      return;
    }
    const key = Library.key(song);
    list.songs = list.songs.filter((item: SongInfo): boolean => Library.key(item) !== key);
    // 封面跟着当前第一首走。以前只在加歌时写一次，删光之后封面还挂在已删的那首上，
    // 首页就会出现「0 首」却顶着一张封面的样子。
    list.cover = list.songs.length > 0 ? list.songs[0].cover : '';
    list.updatedAt = Date.now();
    this.savePlaylists();
    this.notify();
  }

  isInPlaylist(id: string, song: SongInfo): boolean {
    const list = this.getPlaylist(id);
    if (list === null) {
      return false;
    }
    const key = Library.key(song);
    for (const item of list.songs) {
      if (Library.key(item) === key) {
        return true;
      }
    }
    return false;
  }

  addAllToPlaylist(id: string, songs: SongInfo[]): number {
    const list = this.getPlaylist(id);
    if (list === null) {
      return 0;
    }
    let added = 0;
    for (const song of songs) {
      const key = Library.key(song);
      let exists = false;
      for (const item of list.songs) {
        if (Library.key(item) === key) {
          exists = true;
          break;
        }
      }
      if (!exists) {
        list.songs.push(song);
        added++;
      }
    }
    list.updatedAt = Date.now();
    this.savePlaylists();
    this.notify();
    return added;
  }

  private savePlaylists(): void {
    Store.get().put(PrefKeys.PLAYLISTS, JSON.stringify(this.playlists));
  }

  /** 收藏/歌单/历史 统一转成 SheetInfo，方便复用歌曲列表页 */
  toSheet(kind: string, id: string, title: string): SheetInfo {
    const sheet = newSheet('local', kind);
    sheet.id = id;
    sheet.name = title;
    if (kind === 'favorites') {
      sheet.cover = this.favorites.length > 0 ? this.favorites[0].cover : '';
      sheet.trackCount = this.favorites.length;
      sheet.subtitle = this.favorites.length.toString() + ' 首 · 我喜欢的音乐';
      sheet.creator = '我';
    } else if (kind === 'history') {
      sheet.cover = this.history.length > 0 ? this.history[0].cover : '';
      sheet.trackCount = this.history.length;
      sheet.subtitle = this.history.length.toString() + ' 首 · 最近播放';
      sheet.creator = '我';
    } else {
      const list = this.getPlaylist(id);
      if (list !== null) {
        sheet.cover = list.cover;
        sheet.trackCount = list.songs.length;
        sheet.subtitle = list.songs.length.toString() + ' 首';
        sheet.creator = '我';
      }
    }
    return sheet;
  }

  songsOf(sheet: SheetInfo): SongInfo[] {
    if (sheet.kind === 'favorites') {
      return this.favorites;
    }
    if (sheet.kind === 'history') {
      return this.history;
    }
    const list = this.getPlaylist(sheet.id);
    return list === null ? [] : list.songs;
  }

  static key(song: SongInfo): string {
    return song.source + '|' + (song.id.length > 0 ? song.id : songKey(song));
  }
}

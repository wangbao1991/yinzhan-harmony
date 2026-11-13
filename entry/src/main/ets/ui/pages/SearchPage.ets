import {
  palette, Palette, RADIUS, FONT, PAGE_PAD, FLOAT_SPACE, PrefKeys,
  glassCardBase, glassSurface, glassEdgeWidth, glassEdgeColor, glassShadow
} from '../../common/Constants';
import { HotSearch } from '../../core/HotSearch';
import { SongInfo, SheetInfo, ArtistInfo, PlatformDef, SourceItem, emptySong, normalizeText } from '../../common/Models';
import { PLATFORMS, platformShort, platformColor } from '../../common/Platform';
import { PlatformApi } from '../../core/PlatformApi';
import { App } from '../../core/App';
import { SourceRepo } from '../../core/SourceRepo';
import { TabBarHider } from '../../core/UiBar';
import { Store } from '../../core/Store';
import { Cover, EmptyView, IconTap, LoadingBlock, GlassSheetCard, SongRow } from '../Common';
import { SongMenu } from '../SongMenu';

/**
 * 搜索：源选择器放在搜索框左侧（综合 = 全部源，或单个平台 / 单个 MusicFree 插件），
 * 结果统一平铺，行内标来源，靠源选择来收窄范围。
 *
 * 两条单曲链路：① 内置五平台直连官方接口搜，播放地址由洛雪音源提供；
 * ② v2.40 起 MusicFree 插件自己 search() 出歌、自己 getMediaSource() 取链，
 * 原始 mediaItem 通过 SongInfo.mfRaw 全程带回，不按歌名跨平台猜。
 * v2.44：歌单 / 歌手 = 平台官方接口 + MusicFree 插件 search('sheet' / 'artist')，
 * 插件没声明该搜索类型时如实返回空；点进歌单 / 歌手再走各自的详情接口，不伪造。
 */
@Component
export struct SearchPage {
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;
  @StorageProp('topSafe') topSafe: number = 24;
  /** 音源导入 / 启停 / 自检结束都会推版本号，MusicFree 搜索源要跟着刷新（铁律 9） */
  @StorageProp('sourceVersion') @Watch('onSourcesChanged') sourceVersion: number = 0;
  @StorageProp('sourcesReady') @Watch('onSourcesChanged') sourcesReady: boolean = false;
  @State keyword: string = '';
  @State type: number = 0;
  @State searched: boolean = false;
  @State loading: boolean = false;
  @State loadingMore: boolean = false;
  @State page: number = 1;
  @State finished: boolean = false;
  @State message: string = '';
  /**
   * v2.54：本次搜索里「没回来」的源。
   * 原来这些源失败后一律 catch 成空数组，界面只知道「没搜到」，
   * 用户会以为歌不存在，实际是那个源挂了 —— 这就是 A10「部分失败被吞」。
   */
  @State failedSources: string[] = [];
  @State faultExpanded: boolean = false;
  /** v2.54：idle 页那条说明太长，默认只露第一句，要看细节再展开 */
  @State idleTipOpen: boolean = false;
  @State songs: SongInfo[] = [];
  /** v2.25 同款合并：每个「歌名+歌手」键下的全部平台版本 */
  @State versionMap: Array<[string, SongInfo[]]> = [];
  @State expandedKey: string = '';
  @State sheets: SheetInfo[] = [];
  @State artists: ArtistInfo[] = [];
  /** 搜索源：'all' = 综合（全部平台），否则为单个平台 id 或 'mf:<音源id>' */
  @State source: string = 'all';
  /** 可作为搜索源的 MusicFree 插件 */
  @State mfSources: SourceItem[] = [];
  @State history: string[] = [];
  /** v2.74：来自官方接口的实时热搜，替代 Constants 里写死的 HOT_WORDS */
  @State hotWords: string[] = [];
  @State hotAt: number = 0;
  @State hotHint: string = '';
  @State hotBusy: boolean = false;
  @State menuShow: boolean = false;
  @State menuSong: SongInfo = emptySong();
  private api: PlatformApi = new PlatformApi();
  /** 每次搜索递增，用于丢弃过期响应 */
  private seq: number = 0;
  /**
   * 从 push 参数带进来的关键词：首页搜索框回车、歌手页点歌手名走的都是这条路。
   * 以前搜索占着底部 tab，只能靠 AppStorage 广播「pendingSearch」传词，
   * 现在搜索是二级页，参数随页面一起来，进页面就能直接看着结果。
   */
  initialKeyword: string = '';
  initialType: number = 0;

  aboutToDisappear(): void {
    TabBarHider.get().reset();
  }

  aboutToAppear(): void {
    this.history = this.readHistory();
    this.refreshMfSources();
    // v2.74：进页就按 TTL 刷新官方实时热搜（10 分钟内复用缓存，不反复打云端）
    this.loadHot(false);
    const saved = Store.get().getString(PrefKeys.SEARCH_SOURCE, 'all');
    this.source = this.isValidSource(saved) ? saved : 'all';
    if (this.initialKeyword.length > 0) {
      this.keyword = this.initialKeyword;
      this.type = this.initialType;
      this.search(true);
    }
  }

  /** 音源页导入 / 启停 / 自检后，可搜索的插件集合会变，搜索页常驻时也要同步 */
  onSourcesChanged(): void {
    this.refreshMfSources();
  }

  /** 重新拉取「已启用 + 就绪 + 声明了 search」的 MusicFree 插件，并清掉失效的选中源 */
  private refreshMfSources(): void {
    this.mfSources = App.get().sources.mfSearchSources();
    if (this.isMfSource(this.source) && !this.hasMfSource(this.source)) {
      this.source = 'all';
      Store.get().put(PrefKeys.SEARCH_SOURCE, 'all');
    }
  }

  /** v2.74：拉真实热搜；失败时只显示可重试提示，不用写死词顶上 */
  private async loadHot(force: boolean): Promise<void> {
    if (this.hotBusy) {
      return;
    }
    this.hotBusy = true;
    await HotSearch.get().refresh(force);
    this.hotWords = HotSearch.get().cached();
    this.hotAt = HotSearch.get().lastAt();
    this.hotHint = HotSearch.get().lastError();
    this.hotBusy = false;
  }

  private hotTime(): string {
    if (this.hotAt <= 0) {
      return '';
    }
    const d = new Date(this.hotAt);
    const h = d.getHours();
    const m = d.getMinutes();
    const hh = h < 10 ? '0' + h.toString() : h.toString();
    const mm = m < 10 ? '0' + m.toString() : m.toString();
    return hh + ':' + mm;
  }

  private p(): Palette {
    return palette(this.isDark);
  }

  private isMfSource(id: string): boolean {
    return id.indexOf('mf:') === 0 && id.length > 3;
  }

  private mfSourceKey(item: SourceItem): string {
    return 'mf:' + item.id;
  }

  private hasMfSource(id: string): boolean {
    const instId = id.substring(3);
    for (const item of this.mfSources) {
      if (item.id === instId) {
        return true;
      }
    }
    return false;
  }

  private isValidSource(id: string): boolean {
    if (id === 'all') {
      return true;
    }
    // 保存的插件源若已被删除 / 禁用 / 不再就绪，不能留在选中态（源合法性校验）
    if (this.isMfSource(id)) {
      return this.hasMfSource(id);
    }
    for (const item of PLATFORMS) {
      if (item.id === id) {
        return true;
      }
    }
    return false;
  }

  /**
   * 单曲搜索用的源集合：综合 = 五大平台 + 全部可搜索的 MusicFree 插件；
   * 单平台 / 单插件 = 只搜那一个。两类源平铺进同一份结果，由 SongInfo.source 区分。
   */
  private activeSources(): string[] {
    if (this.source !== 'all') {
      return [this.source];
    }
    const ids: string[] = [];
    for (const item of PLATFORMS) {
      ids.push(item.id);
    }
    for (const item of this.mfSources) {
      ids.push(this.mfSourceKey(item));
    }
    return ids;
  }

  /**
   * 歌单 / 歌手 tab 的平台源集合：选中插件源时为空（由 activeMfSources 接管），
   * 综合时返回五大平台，单平台时返回该平台。
   */
  private activePlatforms(): string[] {
    if (this.isMfSource(this.source)) {
      return [];
    }
    if (this.source === 'all') {
      const ids: string[] = [];
      for (const item of PLATFORMS) {
        ids.push(item.id);
      }
      return ids;
    }
    return [this.source];
  }

  /** v2.44：歌单 / 歌手 tab 的 MusicFree 插件源集合（与平台源并列） */
  private activeMfSources(): string[] {
    if (this.isMfSource(this.source)) {
      return [this.source];
    }
    if (this.source !== 'all') {
      return [];
    }
    const ids: string[] = [];
    for (const item of this.mfSources) {
      ids.push(this.mfSourceKey(item));
    }
    return ids;
  }

  /** 统一分派：'mf:' 前缀让插件自己 search()，其余走内置平台 API。
   *  v2.54：这里不再把异常吞成空数组 —— 吞掉之后上层分不清「没搜到」和「源挂了」。
   *  失败由每个调用点各自的 catch 接住并记名，成功结果照样合并。 */
  private searchSongsBySource(id: string, word: string, page: number): Promise<SongInfo[]> {
    if (this.isMfSource(id)) {
      return App.get().sources.searchMusicFree(id.substring(3), word, page);
    }
    return this.api.searchSongs(id, word, page);
  }

  /** 源 id → 界面显示名，失败提示要说清「是谁没回来」 */
  private sourceLabel(id: string): string {
    if (this.isMfSource(id)) {
      const instId = id.substring(3);
      for (const item of this.mfSources) {
        if (item.id === instId) {
          return item.name;
        }
      }
      return 'MusicFree 插件';
    }
    return platformShort(id);
  }

  private setSource(id: string): void {
    if (this.source === id) {
      return;
    }
    this.source = id;
    Store.get().put(PrefKeys.SEARCH_SOURCE, id);
    if (this.searched && this.keyword.trim().length > 0) {
      this.search(true);
    }
  }

  private readHistory(): string[] {
    const text = Store.get().getString(PrefKeys.SEARCH_HISTORY, '[]');
    try {
      return JSON.parse(text) as string[];
    } catch (e) {
      return [];
    }
  }

  private pushHistory(word: string): void {
    const list = this.history.filter((item: string): boolean => item !== word);
    list.unshift(word);
    this.history = list.slice(0, 12);
    Store.get().put(PrefKeys.SEARCH_HISTORY, JSON.stringify(this.history));
  }

  private clearHistory(): void {
    this.history = [];
    Store.get().put(PrefKeys.SEARCH_HISTORY, '[]');
  }

  private switchType(index: number): void {
    if (this.type === index) {
      return;
    }
    this.type = index;
    if (this.searched && this.keyword.trim().length > 0) {
      this.search(true);
    }
  }

  /**
   * v2.25 同款合并：按「歌名+歌手」把多平台结果收成一组，列表只显示一个代表版本，
   * 其余版本记进 versionMap 供展开后选版本播放。不再简单丢弃重复项——音源聚合器
   * 的优势正是同一首歌有多个可播版本。翻页时把已有分组带进来，跨页同款也会合并。
   */
  private mergeSongs(groups: SongInfo[][], reset: boolean): SongInfo[] {
    const keys: string[] = [];
    const versions: SongInfo[][] = [];
    if (!reset) {
      for (const item of this.versionMap) {
        keys.push(item[0]);
        const copy: SongInfo[] = [];
        for (const one of item[1]) {
          copy.push(one);
        }
        versions.push(copy);
      }
    }
    const out: SongInfo[] = [];
    let max = 0;
    for (const group of groups) {
      max = Math.max(max, group.length);
    }
    for (let i = 0; i < max; i++) {
      for (const group of groups) {
        if (i >= group.length) {
          continue;
        }
        const song = group[i];
        const key = this.songGroupKey(song);
        const at = keys.indexOf(key);
        if (at < 0) {
          const list: SongInfo[] = [song];
          keys.push(key);
          versions.push(list);
          out.push(song);
        } else {
          versions[at].push(song);
        }
      }
    }
    const pairs: Array<[string, SongInfo[]]> = [];
    for (let n = 0; n < keys.length; n++) {
      const pair: [string, SongInfo[]] = [keys[n], versions[n]];
      pairs.push(pair);
    }
    this.versionMap = pairs;
    return out;
  }

  private songGroupKey(song: SongInfo): string {
    return normalizeText(song.name) + '|' + normalizeText(song.singer.split('/')[0]);
  }

  private versionsOf(song: SongInfo): SongInfo[] {
    const key = this.songGroupKey(song);
    for (const item of this.versionMap) {
      if (item[0] === key) {
        return item[1];
      }
    }
    const only: SongInfo[] = [song];
    return only;
  }

  private async search(reset: boolean): Promise<void> {
    const word = this.keyword.trim();
    if (word.length === 0) {
      App.get().toast('输入点什么再搜');
      return;
    }
    const token = ++this.seq;
    if (reset) {
      this.searched = true;
      this.page = 1;
      this.finished = false;
      // 打断在途的分页请求：不清这个标志的话，旧请求作废后
      // 新的搜索结果永远滑不到下一页
      this.loadingMore = false;
      this.songs = [];
      this.sheets = [];
      this.artists = [];
      this.versionMap = [];
      this.expandedKey = '';
      this.message = '';
      this.failedSources = [];
      this.faultExpanded = false;
      this.pushHistory(word);
    }
    this.loading = true;
    const platforms = this.activePlatforms();
    try {
      if (this.type === 0) {
        const ids = this.activeSources();
        const tasks: Promise<SongInfo[]>[] = [];
        const fails: string[] = [];
        for (const id of ids) {
          tasks.push(this.searchSongsBySource(id, word, this.page).catch((): SongInfo[] => {
            fails.push(this.sourceLabel(id));
            return [];
          }));
        }
        const groups = await Promise.all(tasks);
        if (token !== this.seq) {
          return;
        }
        this.failedSources = fails;
        const list = this.mergeSongs(groups, reset);
        this.songs = reset ? list : this.songs.concat(list);
        this.finished = list.length === 0;
        if (this.songs.length === 0) {
          // v2.54：三段式 —— 发生了什么 / 影响什么 / 下一步做什么
          this.message = this.source === 'all'
            ? '五大平台和已启用的插件都没搜到。换个关键词，或换个源再试。'
            : '这个源没搜到。切到「综合」可以同时问所有源。';
        }
      } else if (this.type === 1) {
        const mfIds = this.activeMfSources();
        const tasks: Promise<SheetInfo[]>[] = [];
        const fails: string[] = [];
        for (const id of platforms) {
          tasks.push(this.api.searchSheets(id, word, 1).catch((): SheetInfo[] => {
            fails.push(this.sourceLabel(id));
            return [];
          }));
        }
        for (const id of mfIds) {
          tasks.push(App.get().sources.searchSheetsMusicFree(id.substring(3), word, 1)
            .catch((): SheetInfo[] => {
              fails.push(this.sourceLabel(id));
              return [];
            }));
        }
        const groups = await Promise.all(tasks);
        if (token !== this.seq) {
          return;
        }
        this.failedSources = fails;
        const list: SheetInfo[] = [];
        for (const group of groups) {
          for (const sheet of group) {
            list.push(sheet);
          }
        }
        this.sheets = list;
        this.finished = true;
        if (list.length === 0) {
          this.message = mfIds.length > 0 && platforms.length === 0
            ? '这个插件没有提供歌单搜索。切到平台源或「综合」再试。'
            : '平台源和已启用的插件都没返回歌单。换个关键词再试。';
        }
      } else {
        const mfIds = this.activeMfSources();
        const tasks: Promise<ArtistInfo[]>[] = [];
        const fails: string[] = [];
        for (const id of platforms) {
          tasks.push(this.api.searchArtists(id, word).catch((): ArtistInfo[] => {
            fails.push(this.sourceLabel(id));
            return [];
          }));
        }
        for (const id of mfIds) {
          tasks.push(App.get().sources.searchArtistsMusicFree(id.substring(3), word, 1)
            .catch((): ArtistInfo[] => {
              fails.push(this.sourceLabel(id));
              return [];
            }));
        }
        const groups = await Promise.all(tasks);
        if (token !== this.seq) {
          return;
        }
        this.failedSources = fails;
        const list: ArtistInfo[] = [];
        const seen: string[] = [];
        for (const group of groups) {
          for (const artist of group) {
            const key = normalizeText(artist.name);
            if (seen.indexOf(key) >= 0) {
              continue;
            }
            seen.push(key);
            list.push(artist);
          }
        }
        this.artists = list;
        this.finished = true;
        if (list.length === 0) {
          this.message = mfIds.length > 0 && platforms.length === 0
            ? '这个插件没有提供歌手搜索。切到平台源或「综合」再试。'
            : '平台源和已启用的插件都没返回歌手。换个关键词再试。';
        }
      }
    } catch (e) {
      if (token === this.seq) {
        this.message = '这次请求没成功，可能是网络不通。检查网络后点「重新搜索」。';
      }
    }
    if (token === this.seq) {
      this.loading = false;
    }
  }

  private async loadMore(): Promise<void> {
    if (this.loading || this.loadingMore || this.finished || this.type !== 0) {
      return;
    }
    this.loadingMore = true;
    const token = this.seq;
    const next = this.page + 1;
    const word = this.keyword.trim();
    try {
      const tasks: Promise<SongInfo[]>[] = [];
      for (const id of this.activeSources()) {
        // 单源失败不能连坐：原来每个 task 自带 catch，现在由这里接住
        tasks.push(this.searchSongsBySource(id, word, next).catch((): SongInfo[] => []));
      }
      const groups = await Promise.all(tasks);
      if (token !== this.seq) {
        // 这一次请求已作废（用户换了关键词/源）。这里不能直接 return：
        // loadingMore 会一直是 true，之后滑到底再也加载不出下一页。
        this.loadingMore = false;
        return;
      }
      const list = this.mergeSongs(groups, false);
      const fresh: SongInfo[] = [];
      for (const song of list) {
        let exists = false;
        for (const old of this.songs) {
          if (old.source === song.source && old.id === song.id) {
            exists = true;
            break;
          }
        }
        if (!exists) {
          fresh.push(song);
        }
      }
      if (fresh.length === 0) {
        this.finished = true;
      } else {
        this.page = next;
        this.songs = this.songs.concat(fresh);
      }
    } catch (e) {
      this.finished = true;
    }
    this.loadingMore = false;
  }

  private openMenu(song: SongInfo): void {
    this.menuSong = song;
    this.menuShow = true;
  }

  @Builder
  searchBar() {
    Row({ space: 8 }) {
      Row() {
        // 平台选择只保留下方那排 chips（带平台色点、一眼看全）。
        // 搜索框里再挂一个同名下拉，等于同一屏两套选平台的入口，还会各显示一份当前值。
        TextInput({ text: this.keyword, placeholder: '搜歌曲、歌手' })
          .fontSize(FONT.body)
          .fontColor(this.p().text)
          .placeholderColor(this.p().text3)
          .placeholderFont({ size: FONT.body })
          .backgroundColor('#00000000')
          .padding({ left: 14, right: 0 })
          .height(44)
          .layoutWeight(1)
          .enterKeyType(EnterKeyType.Search)
          .onChange((value: string) => {
            this.keyword = value;
          })
          .onSubmit(() => {
            this.search(true);
          })
        if (this.keyword.length > 0) {
          IconTap({
            icon: $r('sys.symbol.xmark_circle'),
            iconSize: 16,
            color: this.p().text3,
            paddingSize: 4,
            onTap: () => {
              this.keyword = '';
              this.searched = false;
              this.songs = [];
              this.sheets = [];
              this.artists = [];
              this.message = '';
            }
          })
        }
      }
      .layoutWeight(1)
      .height(44)
      .padding({ right: 8 })
      .borderRadius(RADIUS.pill)
      .backgroundColor(glassCardBase(this.isDark))
      .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
      .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
      .shadow(glassShadow(this.isDark, this.lightLevel))

      Text('搜索')
        .fontSize(FONT.callout)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FF191713')
        .backgroundColor(this.p().primary)
        .borderRadius(RADIUS.pill)
        .padding({ left: 16, right: 16, top: 11, bottom: 11 })
        .onClick(() => {
          this.search(true);
        })
    }
    .width('100%')
    .padding({ top: 6, bottom: 2 })
  }

  @Builder
  typeTabs() {
    Row({ space: 18 }) {
      this.typeTab('单曲', 0)
      this.typeTab('歌单', 1)
      this.typeTab('歌手', 2)
    }
    .width('100%')
    .padding({ left: 2 })
  }

  @Builder
  typeTab(text: string, index: number) {
    Column({ space: 5 }) {
      Text(text)
        .fontSize(FONT.body)
        .fontWeight(this.type === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.type === index ? this.p().text : this.p().text3)
      Row()
        .width(this.type === index ? 18 : 0)
        .height(3)
        .borderRadius(2)
        .backgroundColor(this.p().primary)
    }
    .onClick(() => {
      this.switchType(index);
    })
  }

  /** 横向源胶囊：综合 + 各平台 + 可搜索的 MusicFree 插件，单选 */
  @Builder
  sourceChips() {
    Scroll() {
      Row({ space: 8 }) {
        this.sourceChip('all', '综合')
        ForEach(PLATFORMS, (item: PlatformDef) => {
          this.sourceChip(item.id, item.short)
        }, (item: PlatformDef) => item.id)
        ForEach(this.mfSources, (item: SourceItem) => {
          this.mfSourceChip(item)
        }, (item: SourceItem) => 'mf:' + item.id)
      }
      .padding({ right: 4 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
  }

  /** MusicFree 插件源：MF 角标 + 插件名，不与平台色点混淆 */
  @Builder
  mfSourceChip(item: SourceItem) {
    Row({ space: 5 }) {
      Text('MF')
        .fontSize(9)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.source === this.mfSourceKey(item) ? this.p().primary : '#FFFFFFFF')
        .backgroundColor(this.source === this.mfSourceKey(item) ? '#FFFFFFFF' : this.p().accent)
        .borderRadius(4)
        .padding({ left: 4, right: 4, top: 1, bottom: 1 })
      Text(item.name.length > 10 ? item.name.substring(0, 10) + '…' : item.name)
        .fontSize(FONT.callout)
        .fontWeight(this.source === this.mfSourceKey(item) ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.source === this.mfSourceKey(item) ? '#FF191713' : this.p().text2)
        .maxLines(1)
    }
    .backgroundColor(this.source === this.mfSourceKey(item) ? this.p().primary : this.p().cardAlt)
    .borderRadius(RADIUS.pill)
    .padding({ left: 9, right: 14, top: 7, bottom: 7 })
    .onClick(() => {
      this.setSource(this.mfSourceKey(item));
    })
  }

  @Builder
  sourceChip(id: string, label: string) {
    Row({ space: 5 }) {
      if (id !== 'all') {
        Row()
          .width(5)
          .height(5)
          .borderRadius(3)
          .backgroundColor(this.source === id ? '#FFFFFFFF' : platformColor(id))
      }
      Text(label)
        .fontSize(FONT.callout)
        .fontWeight(this.source === id ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.source === id ? '#FF191713' : this.p().text2)
    }
    .backgroundColor(this.source === id ? this.p().primary : this.p().cardAlt)
    .borderRadius(RADIUS.pill)
    .padding({ left: id === 'all' ? 14 : 11, right: 14, top: 7, bottom: 7 })
    .onClick(() => {
      this.setSource(id);
    })
  }

  @Builder
  idleView() {
    Scroll() {
      Column({ space: 22 }) {
        if (this.history.length > 0) {
          Column({ space: 12 }) {
            Row() {
              Text('搜索历史')
                .fontSize(FONT.callout)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.p().text2)
                .layoutWeight(1)
              IconTap({
                icon: $r('sys.symbol.trash'),
                iconSize: 15,
                color: this.p().text3,
                paddingSize: 6,
                onTap: () => {
                  this.clearHistory();
                }
              })
            }
            .width('100%')

            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.history, (word: string) => {
                Text(word)
                  .fontSize(FONT.callout)
                  .fontColor(this.p().text2)
                  .backgroundColor(glassCardBase(this.isDark))
                  .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
                  .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
                  .shadow(glassShadow(this.isDark, this.lightLevel))
                  .borderRadius(RADIUS.pill)
                  .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                  .margin({ right: 8, bottom: 8 })
                  .onClick(() => {
                    this.keyword = word;
                    this.search(true);
                  })
              }, (word: string) => word)
            }
            .width('100%')
          }
          .width('100%')
        }

        Column({ space: 12 }) {
          Row({ space: 8 }) {
            Text('大家都在搜')
              .fontSize(FONT.callout)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.p().text2)
            Blank()
            if (this.hotAt > 0) {
              Text('更新于 ' + this.hotTime())
                .fontSize(FONT.micro)
                .fontColor(this.p().text3)
            }
            Text(this.hotBusy ? '获取中…' : '刷新')
              .fontSize(FONT.micro)
              .fontColor(this.p().primary)
              .padding({ left: 8, right: 4, top: 4, bottom: 4 })
              .onClick(() => {
                this.loadHot(true);
              })
          }
          .width('100%')

          if (this.hotWords.length === 0) {
            // v2.74 不造数：没拿到真实热搜就只给状态 + 可重试入口，绝不用写死词顶上
            Text(this.hotBusy ? '正在获取实时热搜…'
              : (this.hotHint.length > 0 ? this.hotHint : '暂无实时热搜，点「刷新」重试'))
              .fontSize(FONT.caption)
              .fontColor(this.p().text3)
              .width('100%')
              .padding({ top: 6, bottom: 6 })
              .onClick(() => {
                if (!this.hotBusy) {
                  this.loadHot(true);
                }
              })
          } else {
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.hotWords, (word: string, index: number) => {
                Row({ space: 5 }) {
                  Text((index + 1).toString())
                    .fontSize(FONT.micro)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(index < 3 ? this.p().accent : this.p().text3)
                  Text(word)
                    .fontSize(FONT.callout)
                    .fontColor(this.p().text)
                }
                .backgroundColor(glassCardBase(this.isDark))
                .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
                .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
                .shadow(glassShadow(this.isDark, this.lightLevel))
                .borderRadius(RADIUS.pill)
                .padding({ left: 12, right: 14, top: 8, bottom: 8 })
                .margin({ right: 8, bottom: 8 })
                .onClick(() => {
                  this.keyword = word;
                  this.search(true);
                })
              }, (word: string) => 'hot_' + word)
            }
            .width('100%')
          }
        }
        .width('100%')

        // v2.54：这段说明原来一整块摊在空态页上，把「搜索历史 / 大家都在搜」压到看不见。
        // 默认只留第一句（怎么选源），要了解取链与替补细节再展开。
        Column({ space: 8 }) {
          Row({ space: 6 }) {
            Text('小提示')
              .fontSize(FONT.caption)
              .fontColor(this.p().text3)
              .layoutWeight(1)
            Text(this.idleTipOpen ? '收起' : '展开')
              .fontSize(FONT.micro)
              .fontColor(this.p().text3)
          }
          .width('100%')
          .onClick(() => {
            this.idleTipOpen = !this.idleTipOpen;
          })

          Text('「综合」会搜五大平台，也会搜已导入且支持搜索的 MusicFree 音源（带 MF 角标）；' +
            '点某个源就只搜那一家。')
            .fontSize(FONT.caption)
            .fontColor(this.p().text3)
            .lineHeight(19)
            .width('100%')

          if (this.idleTipOpen) {
            Text('歌单 / 歌手由平台源和 MusicFree 插件共同提供，插件没实现该类型时该源不返回结果。' +
              '平台搜索的播放地址由洛雪音源提供，音源里没有的歌会自动换平台找同款，' +
              '实在找不到会明确告诉你。')
              .fontSize(FONT.caption)
              .fontColor(this.p().text3)
              .lineHeight(19)
              .width('100%')
          }
        }
        .width('100%')
        .padding(14)
        .borderRadius(RADIUS.md)
        .backgroundColor(glassCardBase(this.isDark))
        .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
        .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
        .shadow(glassShadow(this.isDark, this.lightLevel))
      }
      .width('100%')
      .padding({ top: 12, bottom: FLOAT_SPACE + 20 })
    }
    .width('100%')
    .layoutWeight(1)
    // 搜索历史/热词少时同样不该整体居中，与另外两个 Scroll 保持一致
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  /**
   * v2.54：部分失败提示条 —— 「N 个源本次没返回结果」，可展开看是哪几个。
   *
   * 综合搜索时一个源挂了，以前它的结果就是空数组，界面只剩「没搜到」，
   * 用户会以为这首歌全平台都没有。这里把失败显式说出来，成功结果照常展示。
   * 全部源都失败时按钮区已经换成「重新搜索」空态，不重复提示。
   */
  @Builder
  sourceFaultBar() {
    Column({ space: 6 }) {
      Row({ space: 7 }) {
        Row()
          .width(6)
          .height(6)
          .borderRadius(3)
          .backgroundColor(this.p().accent)
        Text(this.failedSources.length.toString() + ' 个源本次没返回结果')
          .fontSize(FONT.caption)
          .fontColor(this.p().text2)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.faultExpanded ? '收起' : '查看')
          .fontSize(FONT.micro)
          .fontColor(this.p().text3)
      }
      .width('100%')
      .onClick(() => {
        this.faultExpanded = !this.faultExpanded;
      })

      if (this.faultExpanded) {
        Text(this.failedSources.join(' · '))
          .fontSize(FONT.micro)
          .fontColor(this.p().text3)
          .lineHeight(17)
          .width('100%')
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 9, bottom: 9 })
    .borderRadius(RADIUS.sm)
    .backgroundColor(this.p().bgSoft)
    .border({ width: 1, color: this.p().line })
    .margin({ bottom: 8 })
  }

  /** 播放全部 + 已加载条数，放在列表上方 */
  @Builder
  playAllBar() {
    Row({ space: 10 }) {
      Row({ space: 5 }) {
        SymbolGlyph($r('sys.symbol.play_fill'))
          .fontSize(11)
          .fontColor(['#FF191713'])
        Text('播放全部')
          .fontSize(FONT.callout)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FF191713')
      }
      .backgroundColor(this.p().primary)
      .borderRadius(RADIUS.pill)
      .padding({ left: 14, right: 16, top: 7, bottom: 7 })
      .onClick(() => {
        if (this.songs.length > 0) {
          App.get().play(this.songs, 0);
        }
      })

      Text('已加载 ' + this.songs.length.toString() + ' 首')
        .fontSize(FONT.caption)
        .fontColor(this.p().text3)
      Blank()
    }
    .width('100%')
    .padding({ left: 4, top: 4, bottom: 2 })
  }

  @Builder
  songList() {
    List({ space: 0 }) {
      ForEach(this.songs, (song: SongInfo, index: number) => {
        ListItem() {
          Column() {
          SongRow({
            song: song,
            index: index + 1,
            showIndex: true,
            showQuality: false,
            active: App.get().isCurrent(song),
            playing: App.get().player.isPlaying(),
            onTap: () => {
              App.get().play(this.songs, index);
            },
            onMore: () => {
              this.openMenu(song);
            }
          })
          if (this.versionsOf(song).length > 1) {
            Row() {
              Text((this.versionsOf(song).length - 1).toString() + ' 个其它版本 · ' +
                (this.expandedKey === this.songGroupKey(song) ? '收起' : '展开选择'))
                .fontSize(11)
                .fontColor(this.p().primary)
            }
            .width('100%')
            .padding({ left: 44, top: 2, bottom: 6 })
            .onClick(() => {
              const k = this.songGroupKey(song);
              this.expandedKey = this.expandedKey === k ? '' : k;
            })

            if (this.expandedKey === this.songGroupKey(song)) {
              Column({ space: 2 }) {
                ForEach(this.versionsOf(song), (v: SongInfo, vi: number) => {
                  Row({ space: 8 }) {
                    Text(platformShort(v.source) + ' · ' + (v.quality.length > 0 ? v.quality : '标准'))
                      .fontSize(13)
                      .fontColor(this.p().text)
                      .layoutWeight(1)
                    Text(v.singer)
                      .fontSize(11)
                      .fontColor(this.p().text3)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  .width('100%')
                  .padding({ left: 44, right: 12, top: 8, bottom: 8 })
                  .backgroundColor(this.p().primarySoft)
                  .onClick(() => {
                    App.get().playOne(v);
                  })
                }, (v: SongInfo, vi: number) => v.source + '_' + v.id + '_' + vi.toString())
              }
              .width('100%')
            }
          }
          }
          .width('100%')
        }
        .padding({ left: 6, right: 6 })
      }, (song: SongInfo, index: number) => song.source + '_' + song.id + '_' + index.toString())

      if (this.loadingMore) {
        ListItem() {
          LoadingBlock({ text: '正在加载更多' })
        }
      }
      ListItem() {
        Row().height(FLOAT_SPACE + 12)
      }
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .onScrollFrameBegin((offset: number, state: ScrollState) => {
      TabBarHider.get().feed(offset);
      return { offsetRemain: offset };
    })
    .onReachEnd(() => {
      this.loadMore();
    })
  }

  @Builder
  sheetList() {
    Scroll() {
      Column() {
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
          ForEach(this.sheets, (sheet: SheetInfo) => {
            GlassSheetCard({
              sheet: sheet,
              cardWidth: 88,
              onTap: () => {
                App.get().openSheet(sheet);
              }
            })
            .margin({ bottom: 14 })
          }, (sheet: SheetInfo) => sheet.platform + sheet.id)
        }
        .width('100%')
        Row().height(FLOAT_SPACE)
      }
      .width('100%')
      .padding({ top: 14 })
    }
    .width('100%')
    .layoutWeight(1)
    // 与 artistList 同一根因：Scroll 内容短于视口时默认垂直居中，顶对齐修正
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .onScrollFrameBegin((offset: number, state: ScrollState) => {
      TabBarHider.get().feed(offset);
      return { offsetRemain: offset };
    })

  }

  @Builder
  artistList() {
    Scroll() {
      Column() {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.artists, (artist: ArtistInfo) => {
            Column({ space: 8 }) {
              Stack() {
                Cover({
                uri: artist.avatar,
                side: 88,
                radius: 44,
                badge: '',
                fallbackText: artist.name.length > 0 ? artist.name.substring(0, 1).toUpperCase() : ''
              })
              }
              .width(88)
              .height(88)

              Text(artist.name)
                .fontSize(FONT.callout)
                .fontColor(this.p().text)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width(88)
                .textAlign(TextAlign.Center)
              Text(platformShort(artist.platform))
                .fontSize(FONT.micro)
                .fontColor(this.p().text3)
            }
            .margin({ right: 12, bottom: 18 })
            .onClick(() => {
              App.get().openArtist(artist);
            })
          }, (artist: ArtistInfo) => artist.platform + artist.id + artist.name)
        }
        .width('100%')
        Row().height(FLOAT_SPACE)
      }
      .width('100%')
      .padding({ top: 14 })
    }
    .width('100%')
    .layoutWeight(1)
    // Scroll 用 layoutWeight 撑满剩余高度后，内容不足一屏时默认按
    // Alignment.Center 垂直居中：结果卡片会整体飘到页面中部，且结果越少
    // 上方空白越大（咪咕 4 条与 QQ 2 条起点能差出半屏）。显式顶对齐，
    // 让网格始终紧贴筛选栏下方，滚动行为不变。
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .onScrollFrameBegin((offset: number, state: ScrollState) => {
      TabBarHider.get().feed(offset);
      return { offsetRemain: offset };
    })
  }

  @Builder
  menuSheet() {
    SongMenu({
      song: this.menuSong,
      kind: '',
      playlistId: '',
      onDone: () => {
        this.menuShow = false;
      }
    })
  }


  build() {
    Column({ space: 12 }) {
      // 二级页：左侧返回键 + 大标题。搜索不再是底部一级入口，
      // 从首页搜索框 / 歌手页推上来，必须有明确的退出口。
      Row({ space: 2 }) {
        IconTap({
          icon: $r('sys.symbol.chevron_left'),
          iconSize: 26,
          color: this.p().text,
          paddingSize: 7,
          onTap: () => {
            App.get().back();
          }
        })
          .margin({ left: -7 })
        Text('搜索')
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.p().text)
        Blank()
      }
      .width('100%')
      .padding({ top: 6 })

      this.searchBar()
      this.typeTabs()
      this.sourceChips()

      if (!this.searched) {
        this.idleView()
      } else if (this.loading) {
        LoadingBlock({ text: '正在搜索' })
      } else if (this.type === 0 && this.songs.length === 0) {
        EmptyView({
          icon: $r('sys.symbol.magnifyingglass'),
          title: '没有找到结果',
          hint: this.message.length > 0 ? this.message : '换个关键词，或换个源再试。',
          action: '重新搜索',
          onAction: () => {
            this.search(true);
          }
        })
      } else if (this.type === 1 && this.sheets.length === 0) {
        EmptyView({
          icon: $r('sys.symbol.folder'),
          title: '没有找到歌单',
          hint: this.message,
          action: '重新搜索',
          onAction: () => {
            this.search(true);
          }
        })
      } else if (this.type === 2 && this.artists.length === 0) {
        EmptyView({
          icon: $r('sys.symbol.person'),
          title: '没有找到歌手',
          hint: this.message,
          action: '重新搜索',
          onAction: () => {
            this.search(true);
          }
        })
      } else if (this.type === 0) {
        if (this.failedSources.length > 0) {
          this.sourceFaultBar()
        }
        this.playAllBar()
        this.songList()
      } else if (this.type === 1) {
        if (this.failedSources.length > 0) {
          this.sourceFaultBar()
        }
        this.sheetList()
      } else {
        if (this.failedSources.length > 0) {
          this.sourceFaultBar()
        }
        this.artistList()
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: PAGE_PAD, right: PAGE_PAD, top: this.topSafe })
    .backgroundColor('#00000000')
    .bindSheet($$this.menuShow, this.menuSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: false,
      backgroundColor: glassCardBase(this.isDark)
    })
  }
}

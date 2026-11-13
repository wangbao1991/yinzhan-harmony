import {
  palette, Palette, RADIUS, FONT, PAGE_PAD, PAGE_BOTTOM, MINI_BAR_SPACE,
  glassCardBase, glassSurface, glassEdgeWidth, glassEdgeColor, glassShadow
} from '../../common/Constants';
import { SongInfo, ArtistInfo, ArtistParam, PagedSongs, emptySong, normalizeText } from '../../common/Models';
import { platformName } from '../../common/Platform';
import { PlatformApi } from '../../core/PlatformApi';
import { App } from '../../core/App';
import { TabBarHider } from '../../core/UiBar';
import { Cover, EmptyView, LoadingBlock, PageBar, SongRow, ImmersiveBar, Chip } from '../Common';
import { SongMenu } from '../SongMenu';

/** v2.31：歌手页专辑分组，全部来自 artistSongs 已返回的真实作品 */
interface AlbumGroup {
  key: string;
  name: string;
  cover: string;
  songs: SongInfo[];
}

/**
 * 专辑卡做成独立 @Component（不是带参 @Builder）：带参 @Builder 直接传 this 状态
 * 只会在首次生效，历史 v2.19 踩过；@Prop 单向同步则由父组件刷新带着一起重绘。
 */
@Component
struct AlbumCard {
  @Prop group: AlbumGroup = { key: '', name: '', cover: '', songs: [] };
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;
  onOpen: () => void = (): void => {
  };

  private p(): Palette {
    return palette(this.isDark);
  }


  build() {
    Row({ space: 12 }) {
      Cover({
        uri: this.group.cover,
        side: 54,
        radius: 10,
        fallbackText: this.group.name.length > 0 ? this.group.name.substring(0, 1).toUpperCase() : ''
      })
      Column({ space: 4 }) {
        Text(this.group.name)
          .fontSize(FONT.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.p().text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.group.songs.length.toString() + ' 首 · 已加载作品')
          .fontSize(FONT.caption)
          .fontColor(this.p().text3)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([this.p().text3])
    }
    .width('100%')
    .padding(10)
    .borderRadius(RADIUS.md)
    .backgroundColor(glassCardBase(this.isDark))
    .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
    .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
    .shadow(glassShadow(this.isDark, this.lightLevel))
    .onClick(() => {
      this.onOpen();
    })
  }
}

/**
 * 歌手页：优先用平台歌手接口拿作品，拿不到就退化成「按歌手名搜索再筛」。
 * 洛雪音源不提供歌手信息，所以这里不做音源依赖。
 */
@Component
export struct ArtistPage {
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;
  @StorageProp('topSafe') topSafe: number = 24;
  @State artist: ArtistInfo = { id: '', name: '', avatar: '', platform: '', subtitle: '' };
  @State songs: SongInfo[] = [];
  @State loading: boolean = true;
  @State message: string = '';
  @State menuShow: boolean = false;
  @State menuSong: SongInfo = emptySong();
  /** 分页：平台作品接口一次 100 首，滑到底继续加载，不再停在 30 / 50 首 */
  @State page: number = 1;
  @State hasMore: boolean = false;
  @State loadingMore: boolean = false;
  @State total: number = 0;
  /** v2.31：0 作品 / 1 专辑 */
  @State viewMode: number = 0;
  /**
   * v2.56：本次兜底搜索里没返回结果的平台。
   * 原来 12 个并发请求全部在 catch 后直接返回空数组，某个平台超时后
   * 结果里只是少了几首，用户以为「这位歌手就这些歌」——部分失败被吞成静默空。
   */
  @State failedSources: string[] = [];
  /** fetchSongs 内累积失败平台（非状态，避免并发写触发多次渲染） */
  private failedBuf: string[] = [];
  /** v2.31：非空 = 正在看某张专辑里的歌曲 */
  @State activeAlbum: string = '';
  /** v2.31：按已加载真实歌曲聚合出的专辑，load / loadMore 后重算 */
  @State albums: AlbumGroup[] = [];
  private api: PlatformApi = new PlatformApi();
  private loaded: boolean = false;

  private p(): Palette {
    return palette(this.isDark);
  }

  /** v2.56：底部「部分源没返回」的说明行，平台名走统一映射，不拼接原始 id */
  private failedLabel(): string {
    const names: string[] = [];
    for (const id of this.failedSources) {
      names.push(platformName(id));
    }
    return '有 ' + this.failedSources.length.toString() + ' 个源本次没返回结果（' +
      names.join('、') + '），这部分作品暂时看不到';
  }

  private async load(param: ArtistParam): Promise<void> {
    this.artist = param.artist;
    this.loading = true;
    this.message = '';
    this.page = 1;
    this.failedBuf = [];
    this.failedSources = [];
    try {
      const r = await this.fetchSongs(this.artist, 1);
      this.songs = r.songs;
      this.total = r.total;
      this.hasMore = r.hasMore;
      this.albums = this.buildAlbums(this.songs);
      this.failedSources = this.failedBuf.slice();
      if (this.songs.length === 0) {
        this.message = '没有拿到这位歌手的作品，可能是接口限制或名字不匹配';
      }
    } catch (e) {
      this.songs = [];
      this.albums = [];
      this.hasMore = false;
      this.failedSources = [];
      this.message = '加载失败，请检查网络后重试';
    }
    this.loading = false;
  }

  /** 滑到底继续取下一页，按 source+id 去重后追加 */
  private async loadMore(): Promise<void> {
    if (this.loading || this.loadingMore || !this.hasMore) {
      return;
    }
    this.loadingMore = true;
    const next: number = this.page + 1;
    this.failedBuf = [];
    try {
      const r = await this.fetchSongs(this.artist, next);
      if (r.songs.length > 0) {
        const merged: SongInfo[] = this.songs.slice();
        const seen: string[] = [];
        for (const old of merged) {
          seen.push(old.source + '|' + old.id);
        }
        for (const song of r.songs) {
          const key: string = song.source + '|' + song.id;
          if (seen.indexOf(key) < 0) {
            seen.push(key);
            merged.push(song);
          }
        }
        this.songs = merged;
        this.albums = this.buildAlbums(merged);
        this.page = next;
        this.total = r.total > 0 ? r.total : merged.length;
      }
      this.hasMore = r.hasMore;
      if (this.failedBuf.length > 0) {
        this.failedSources = this.failedBuf.slice();
      }
    } catch (e) {
      this.hasMore = false;
    }
    this.loadingMore = false;
  }

  /**
   * 首屏：先走各平台「按歌手 ID 取作品」接口（分页）；拿不到才退化为按名搜索。
   * 此前只有网易云一个平台取 hotSongs 50 首、其余平台退化成搜第 1 页 30 条，
   * 所以详情页长期只有 30 / 50 首，与歌手真实作品量（400~680 首）不符。
   */
  private async fetchSongs(artist: ArtistInfo, page: number): Promise<PagedSongs> {
    const empty: PagedSongs = { songs: [], page: page, hasMore: false, total: 0 };
    // v2.44：MusicFree 插件搜出来的歌手，走该插件的 getArtistWorks 取作品。
    // 插件源不参与「按歌名跨平台模糊搜」兜底，避免拿平台同名结果冒充插件作品。
    if (artist.platform.indexOf('mf:') === 0) {
      if (artist.id.length === 0) {
        return empty;
      }
      try {
        return await App.get().sources.artistSongsMusicFree(artist.platform.substring(3), artist, page);
      } catch (e) {
        return empty;
      }
    }
    if (artist.id.length > 0 && artist.platform.length > 0) {
      const r = await this.api.artistSongs(artist, page).catch((): PagedSongs => empty);
      if (r.songs.length > 0) {
        return r;
      }
    }
    // 兜底只在首屏做一次：咪咕等无公开作品接口的平台，并发取 3 页按名搜索再筛。
    if (page > 1) {
      return empty;
    }
    const name = artist.name;
    const targets: string[] = artist.platform.length > 0 ? [artist.platform, 'kw', 'tx', 'wy'] : ['kw', 'tx', 'wy', 'kg'];
    const key = normalizeText(name);
    const seen: string[] = [];
    const matched: SongInfo[] = [];
    const tasks: Promise<SongInfo[]>[] = [];
    for (const id of targets) {
      for (let p = 1; p <= 3; p++) {
        // v2.56：不再静默吞成空数组——记下是哪个平台没返回，页面底部如实说明
        tasks.push(this.api.searchSongs(id, name, p).catch((): SongInfo[] => {
          if (this.failedBuf.indexOf(id) < 0) {
            this.failedBuf.push(id);
          }
          return [];
        }));
      }
    }
    const groups = await Promise.all(tasks);
    for (const list of groups) {
      for (const song of list) {
        if (normalizeText(song.singer).indexOf(key) >= 0) {
          const sign = song.source + '|' + normalizeText(song.name);
          if (seen.indexOf(sign) < 0) {
            seen.push(sign);
            matched.push(song);
          }
        }
      }
    }
    return { songs: matched, page: 1, hasMore: false, total: matched.length };
  }

  /**
   * v2.31：把已加载的真实作品按专辑去重分组。
   * 工程没有「按歌手 ID 取专辑列表」的接口，这里只重新聚合 artistSongs 返回的歌曲：
   * 优先用 albumId（同平台内稳定），没有就用规范化专辑名；**没有专辑名的歌不计入**，
   * 不造「未知专辑」凑数。所以数字是「已加载作品中出现的专辑数」，会随上滑加载增长，
   * 不是歌手生涯全部专辑总数 —— 按铁律 2 不把局部统计写成真实总量。
   */
  private buildAlbums(list: SongInfo[]): AlbumGroup[] {
    const out: AlbumGroup[] = [];
    for (const song of list) {
      const name: string = (song.albumName ?? song.album ?? '').trim();
      if (name.length === 0) {
        continue;
      }
      const id: string = (song.albumId ?? '').trim();
      const key: string = song.source + '|' + (id.length > 0 ? id : name.toLowerCase());
      let found: number = -1;
      for (let i = 0; i < out.length; i++) {
        if (out[i].key === key) {
          found = i;
          break;
        }
      }
      if (found < 0) {
        const group: AlbumGroup = { key: key, name: name, cover: song.cover, songs: [] };
        group.songs.push(song);
        out.push(group);
      } else {
        out[found].songs.push(song);
        if (out[found].cover.length === 0 && song.cover.length > 0) {
          out[found].cover = song.cover;
        }
      }
    }
    return out;
  }

  /** 当前展开的专辑里的真实歌曲（播放队列就用这一组，不掺别组） */
  private currentAlbumSongs(): SongInfo[] {
    for (const g of this.albums) {
      if (g.key === this.activeAlbum) {
        return g.songs;
      }
    }
    return [];
  }

  /** 返回手势：先看专辑内歌曲 → 再回专辑列表 → 再回作品列表 → 最后才放行退页 */
  private consumeViewBack(): boolean {
    if (this.activeAlbum.length > 0) {
      this.activeAlbum = '';
      return true;
    }
    if (this.viewMode === 1) {
      this.viewMode = 0;
      return true;
    }
    return false;
  }

  private goBack(): void {
    if (App.get().consumeBackIfQueueOpen()) {
      return;
    }
    if (this.consumeViewBack()) {
      return;
    }
    App.get().back();
  }

  @Builder
  albumBackRow() {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize(14)
        .fontColor([this.p().primary])
      Text('返回专辑列表')
        .fontSize(FONT.callout)
        .fontColor(this.p().primary)
      Text('· ' + this.currentAlbumSongs().length.toString() + ' 首')
        .fontSize(FONT.caption)
        .fontColor(this.p().text3)
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 6, bottom: 10 })
    .onClick(() => {
      this.activeAlbum = '';
    })
  }

  private playAll(index: number): void {
    if (this.songs.length === 0) {
      App.get().toast('还没有可播放的歌曲');
      return;
    }
    App.get().playAndOpen(this.songs.slice(), index);
  }

  @Builder
  header() {
    Column({ space: 16 }) {
      Column({ space: 12 }) {
        Cover({
          uri: this.artist.avatar,
          side: 104,
          radius: 52,
          elevated: true,
          badge: '',
          fallbackText: this.artist.name.length > 0 ? this.artist.name.substring(0, 1).toUpperCase() : ''
        })
        Column({ space: 4 }) {
          Text(this.artist.name)
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.p().text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text((this.artist.platform.length > 0 ? platformName(this.artist.platform) + ' · ' : '') +
            (this.total > 0 ? this.total.toString() : this.songs.length.toString()) + ' 首作品 · ' +
            this.albums.length.toString() + ' 部专辑' +
            (this.hasMore ? ' · 上滑加载更多' : ''))
            .fontSize(FONT.caption)
            .fontColor(this.p().text3)
        }
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%')
      .padding({ top: 6, bottom: 4 })

      Column({ space: 8 }) {
        Row({ space: 8 }) {
          Chip({
            text: '作品 ' + (this.total > 0 ? this.total.toString() : this.songs.length.toString()),
            active: this.viewMode === 0,
            onTap: () => {
              this.viewMode = 0;
              this.activeAlbum = '';
            }
          })
          Chip({
            text: '专辑 ' + this.albums.length.toString(),
            active: this.viewMode === 1,
            onTap: () => {
              this.viewMode = 1;
              this.activeAlbum = '';
            }
          })
        }
        .width('100%')
        Text('专辑按已加载作品去重统计，上滑加载更多后会增加；不是歌手全部专辑总数')
          .fontSize(FONT.micro)
          .fontColor(this.p().text3)
          .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Row({ space: 10 }) {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.play_fill')).fontSize(15).fontColor(['#FF191713'])
          Text('播放全部').fontSize(FONT.callout).fontWeight(FontWeight.Medium).fontColor('#FF191713')
        }
        .height(42)
        .padding({ left: 20, right: 22 })
        .borderRadius(RADIUS.pill)
        .backgroundColor(this.p().primary)
        .onClick(() => {
          this.playAll(0);
        })

      }
      .width('100%')
    }
    .width('100%')
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
    NavDestination() {
      Stack({ alignContent: Alignment.Top }) {
      Column() {
        if (this.loading) {
          LoadingBlock({ text: '正在加载歌手作品' })
        } else if (this.songs.length === 0) {
          EmptyView({
            icon: $r('sys.symbol.person'),
            title: '没有找到作品',
            hint: this.message,
            action: '搜索这个名字',
            onAction: () => {
              App.get().openSearch(this.artist.name);
            }
          })
        } else {
          List() {
            ListItem() {
              this.header()
            }
            if (this.viewMode === 0) {
              ForEach(this.songs, (song: SongInfo, index: number) => {
                ListItem() {
                  SongRow({
                    song: song,
                    index: index + 1,
                    showIndex: true,
                    active: App.get().isCurrent(song),
                    playing: App.get().player.isPlaying(),
                    onTap: () => {
                      App.get().play(this.songs.slice(), index);
                    },
                    onMore: () => {
                      this.menuSong = song;
                      this.menuShow = true;
                    }
                  })
                }
                .padding({ left: 4, right: 4 })
              }, (song: SongInfo, index: number) => song.source + song.id + index.toString())
              if (this.loadingMore) {
                ListItem() {
                  LoadingBlock({ text: '正在加载更多' })
                }
              }
              // v2.56：部分平台没返回时如实说明，别让「少了几首」看起来像「就这些」
              if (this.failedSources.length > 0) {
                ListItem() {
                  Row({ space: 8 }) {
                    Column()
                      .width(3)
                      .height(16)
                      .borderRadius(2)
                      .backgroundColor(this.p().accent)
                      .accessibilityLevel('no')
                    Text(this.failedLabel())
                      .fontSize(FONT.micro)
                      .fontColor(this.p().text3)
                      .layoutWeight(1)
                      .lineHeight(17)
                  }
                  .width('100%')
                  .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                  .accessibilityText(this.failedLabel())
                }
                .padding({ left: 4, right: 4 })
              }
            } else if (this.activeAlbum.length === 0) {
              ForEach(this.albums, (g: AlbumGroup) => {
                ListItem() {
                  AlbumCard({
                    group: g,
                    onOpen: () => {
                      this.activeAlbum = g.key;
                    }
                  })
                }
                .padding({ left: 4, right: 4 })
              }, (g: AlbumGroup) => g.key)
            } else {
              ListItem() {
                this.albumBackRow()
              }
              .padding({ left: 4, right: 4 })
              ForEach(this.currentAlbumSongs(), (song: SongInfo, index: number) => {
                ListItem() {
                  SongRow({
                    song: song,
                    index: index + 1,
                    showIndex: true,
                    active: App.get().isCurrent(song),
                    playing: App.get().player.isPlaying(),
                    onTap: () => {
                      App.get().play(this.currentAlbumSongs().slice(), index);
                    },
                    onMore: () => {
                      this.menuSong = song;
                      this.menuShow = true;
                    }
                  })
                }
                .padding({ left: 4, right: 4 })
              }, (song: SongInfo, index: number) => song.source + song.id + index.toString())
            }
            ListItem() {
              Row().height(PAGE_BOTTOM + 20 + MINI_BAR_SPACE)
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
            // 专辑视图不触发作品翻页；回到作品视图再上滑继续加载
            if (this.viewMode === 0) {
              this.loadMore();
            }
          })

        }
      }
      .width('100%')
      .height('100%')
      .padding({ left: PAGE_PAD, right: PAGE_PAD, top: this.topSafe + 52 })
      .backgroundColor('#00000000')
      .bindSheet($$this.menuShow, this.menuSheet(), {
        height: SheetSize.FIT_CONTENT,
        dragBar: false,
        backgroundColor: glassCardBase(this.isDark)
      })

      ImmersiveBar({
        title: '歌手',
        subtitle: this.artist.name,
        showSearch: true,
        onBack: () => {
          this.goBack();
        },
        // v2.54：从歌手页可直接发起新搜索，不必退回首页
        onSearch: () => {
          App.get().openSearch('');
        }
      })
      }
    }
    .hideTitleBar(true)
    // 队列浮层压在本页之上时，第一次返回只收队列，第二次才退回上一级
    .onBackPressed(() => {
      if (App.get().consumeBackIfQueueOpen()) {
        return true;
      }
      return this.consumeViewBack();
    })
    .onReady((ctx: NavDestinationContext) => {
      const param = ctx.pathInfo.param as ArtistParam;
      if (param !== undefined && param !== null && !this.loaded) {
        this.loaded = true;
        this.load(param);
      }
    })
  }
}

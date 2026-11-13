import {
  palette, Palette, RADIUS, FONT, PAGE_PAD, PAGE_BOTTOM, MINI_BAR_SPACE,
  glassCardBase, glassSurface, glassEdgeWidth, glassEdgeColor, glassShadow
} from '../../common/Constants';
import { SongInfo, SheetInfo, SheetParam, newSheet, formatCount } from '../../common/Models';
import { platformName } from '../../common/Platform';
import { withAlpha } from '../../common/Utils';
import { PlatformApi } from '../../core/PlatformApi';
import { App } from '../../core/App';
import { TabBarHider } from '../../core/UiBar';
import { Library } from '../../core/Library';
import { Cover, EmptyView, LoadingBlock, PageBar, SelectionBar, SongRow, ImmersiveBar } from '../Common';
import { SongMenu } from '../SongMenu';

/**
 * 歌单 / 榜单 / 专辑 / 收藏 / 历史 / 本地 的通用详情页。
 *
 * 一次写、处处用：只要传进来一个 SheetInfo，页面按 kind 去找歌曲来源，
 * 其余交互（播放全部、批量下载、加歌单、移除）完全一样。
 */
@Component
export struct SheetDetailPage {
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;
  @StorageProp('topSafe') topSafe: number = 24;
  @StorageProp('libraryVersion') @Watch('onLibraryChange') libraryVersion: number = 0;
  /**
   * 「本地音乐」这个列表页属于 kind === 'local'，既不是收藏也不是自建歌单，
   * 但它同样要在导入文件后实时刷新。以前只订阅了 libraryVersion，
   * 而 LocalRepo 走的是 localVersion —— 导入完停在这一页，列表一直是旧的。
   */
  @StorageProp('localVersion') @Watch('onLibraryChange') localVersion: number = 0;
  @StorageProp('downloadVersion') @Watch('onLibraryChange') downloadVersion: number = 0;
  @State sheet: SheetInfo = newSheet('', '');
  @State songs: SongInfo[] = [];
  @State loading: boolean = true;
  @State message: string = '';
  @State menuShow: boolean = false;
  /** 本地音乐的多选删除：勾选态与已选 id（id 在本地库内唯一） */
  @State selectMode: boolean = false;
  @State selectedIds: string[] = [];
  @State menuSong: SongInfo = {
    id: '', songmid: '', hash: '', name: '', singer: '', album: '', interval: '',
    source: '', duration: 0, cover: '', lyric: '', url: '', quality: ''
  };
  /** 当前歌单是否已收藏：libraryVersion 一变由 onLibraryChange 同步，按钮即时跟上 */
  @State sheetFav: boolean = false;
  private api: PlatformApi = new PlatformApi();
  private loaded: boolean = false;
  /** 加载序号：连点「重新加载」或有在途请求时，只认最后一次的结果 */
  private loadSeq: number = 0;

  /**
   * 收藏 / 自建歌单 / 历史 存在本地库，platform 固定为 'local'。
   * 平台歌单的 platform 是 wy/tx/kw/kg/mg，kind 同样是 'playlist'，
   * 只按 kind 判断会把平台歌单当成本地歌单去 Library 里查，结果永远是空列表
   * （v4.0.33 前所有平台的推荐歌单点进去都是「这个列表暂时拿不到歌曲」）。
   */
  private isLocalList(sheet: SheetInfo): boolean {
    if (sheet.platform !== 'local') {
      return false;
    }
    return sheet.kind === 'favorites' || sheet.kind === 'history' || sheet.kind === 'playlist';
  }

  /**
   * 只有平台歌单 / 榜单 / 专辑 / 歌手作品能收藏。
   * 喜欢 / 历史 / 本地 / 下载这些本地列表不进收藏表 —— 与 SheetCard 右上角
   * 心形角标用的是同一套 sheetKey 口径，否则按钮亮着、卡片角标却不亮。
   */
  private canFavoriteSheet(): boolean {
    return !this.loading && this.sheet.platform.length > 0 &&
      this.sheet.platform !== 'local' && this.sheet.kind !== 'download';
  }

  /** 收藏按钮底色：已收藏是信号琥珀实色，未收藏沿用中性纸墨实色 (v2.52) */
  private favBtnGradient(): Array<[ResourceColor, number]> {
    if (this.sheetFav) {
      const on: Array<[ResourceColor, number]> = [['#FFE29A26', 0], ['#FFF3B044', 1]];
      return on;
    }
    return glassSurface(this.isDark, this.lightLevel);
  }

  onLibraryChange(): void {
    // 收藏 / 取消收藏歌单走的是同一个 libraryVersion 广播：
    // 本页按钮、首页计数、发现页与搜索页卡片角标、收藏列表页四处同时刷新。
    this.sheetFav = Library.get().isSheetFavorite(this.sheet);
    // 本地来源不重新打网络，直接从内存仓库重取一遍。
    // 旧实现只认 isLocalList，「本地音乐」(kind='local') 与「下载」(kind='download')
    // 都被漏掉，导入或下载完成后停在原页看不到新歌。
    if (this.isLocalList(this.sheet)) {
      this.songs = Library.get().songsOf(this.sheet).slice();
      // 头部封面跟着当前第一首走：删空后还挂着上一首的图，
      // 和首页那张卡是同一个毛病（Library 改了 cover，页面这份快照也得跟上）
      this.sheet.cover = this.songs.length > 0 ? this.songs[0].cover : '';
      return;
    }
    if (this.sheet.kind === 'local') {
      this.songs = App.get().local.toSongs();
      return;
    }
    if (this.sheet.kind === 'download') {
      this.songs = this.doneDownloads();
    }
  }

  private doneDownloads(): SongInfo[] {
    const list: SongInfo[] = [];
    for (const task of App.get().downloads.list()) {
      if (task.status === 'done') {
        list.push(task.song);
      }
    }
    return list;
  }

  private p(): Palette {
    return palette(this.isDark);
  }

  private async loadSheet(param: SheetParam): Promise<void> {
    const seq = ++this.loadSeq;
    this.sheet = param.sheet;
    // 进页首帧就把收藏按钮摆对，不等第一次广播
    this.sheetFav = Library.get().isSheetFavorite(param.sheet);
    this.loading = true;
    this.message = '';
    try {
      const list = await this.songsOf(this.sheet);
      if (seq !== this.loadSeq) {
        return;
      }
      this.songs = list;
      if (list.length === 0) {
        this.message = this.sheet.kind === 'local' ? '还没有导入本地音乐' :
          (this.sheet.kind === 'favorites' ? '还没有收藏歌曲，在播放页点心形按钮即可' :
            (this.sheet.kind === 'history' ? '还没有播放记录' : '这个列表暂时拿不到歌曲'));
      }
    } catch (e) {
      if (seq !== this.loadSeq) {
        return;
      }
      this.songs = [];
      this.message = '加载失败，请检查网络后重试';
    }
    if (seq === this.loadSeq) {
      this.loading = false;
    }
  }

  private async songsOf(sheet: SheetInfo): Promise<SongInfo[]> {
    if (this.isLocalList(sheet)) {
      return Library.get().songsOf(sheet).slice();
    }
    if (sheet.kind === 'local') {
      return App.get().local.toSongs();
    }
    if (sheet.kind === 'download') {
      return this.doneDownloads();
    }
    // v2.44：MusicFree 插件搜出来的歌单，交给该插件的 getMusicSheetInfo 取歌。
    // mfRaw 里是插件自己的 sheetItem 原文，song 由 toSong 带上 mfRaw，可直接播放。
    if (sheet.platform.indexOf('mf:') === 0) {
      try {
        const r = await App.get().sources.sheetSongsMusicFree(sheet.platform.substring(3), sheet, 1);
        return r.songs;
      } catch (e) {
        return [];
      }
    }
    return this.api.sheetSongs(sheet);
  }

  private playAll(index: number): void {
    if (this.songs.length === 0) {
      App.get().toast('这个列表还没有歌曲');
      return;
    }
    App.get().playAndOpen(this.songs.slice(), index);
  }

  private openMenu(song: SongInfo): void {
    this.menuSong = song;
    this.menuShow = true;
  }

  /* ---------------- 本地音乐：左滑删除 / 多选删除 ---------------- */

  private isLocalKind(): boolean {
    return this.sheet.kind === 'local';
  }

  /** 自建歌单：左滑是「移除」，只动歌单不动文件，和本地音乐的「删除」不是一回事 */
  private isPlaylistKind(): boolean {
    return this.sheet.platform === 'local' && this.sheet.kind === 'playlist';
  }

  /** 我喜欢 / 最近播放：左滑只是「从这份列表里去掉」，不碰文件、不碰播放队列 */
  private isFavKind(): boolean {
    return this.sheet.kind === 'favorites';
  }

  private isHistoryKind(): boolean {
    return this.sheet.kind === 'history';
  }

  /**
   * 能左滑的四种列表，语义各不相同：
   *   本地音乐 → 删文件（连带摘掉队列里的那条，不然下一首切到它会报错）
   *   自建歌单 → 移出歌单，文件不动
   *   我喜欢   → 取消收藏，文件、下载、队列都不动，播放页还能再收藏回来
   *   最近播放 → 删一条记录，同理
   * 动作在 swipeDelete 里按 kind 分发，谁都不能借用别人的分支。
   */
  private canSwipe(): boolean {
    return this.isLocalKind() || this.isPlaylistKind() || this.isFavKind() || this.isHistoryKind();
  }

  /**
   * 一键清空只给个人列表。
   * 平台歌单是别人维护的，本地音乐清空等于把导入的文件全删了——代价太大，不给。
   */
  private canClear(): boolean {
    return (this.isFavKind() || this.isHistoryKind()) && this.songs.length > 0;
  }

  private enterSelect(): void {
    this.selectedIds = [];
    this.selectMode = true;
  }

  private exitSelect(): void {
    this.selectMode = false;
    this.selectedIds = [];
  }

  /**
   * 页内临时态：选择模式下按返回先退出选择，第二次返回才交给浮层 / 退页。
   * v2.55：顺序由 App.consumeBack 统一定义，本页只声明「有这一层」。
   */
  private localBack(): boolean {
    if (!this.selectMode) {
      return false;
    }
    this.exitSelect();
    return true;
  }

  private toggleSelect(song: SongInfo): void {
    const next: string[] = this.selectedIds.slice();
    const at: number = next.indexOf(song.id);
    if (at >= 0) {
      next.splice(at, 1);
    } else {
      next.push(song.id);
    }
    this.selectedIds = next;
  }

  private toggleSelectAll(): void {
    if (this.selectedIds.length === this.songs.length) {
      this.selectedIds = [];
      return;
    }
    const all: string[] = [];
    for (const song of this.songs) {
      all.push(song.id);
    }
    this.selectedIds = all;
  }

  /**
   * 删歌时顺手摘掉播放队列里的同一条：
   * 不然文件已经删了，播放器还挂着它，下一首切到它就报「播放出错」。
   */
  private removeFromQueue(song: SongInfo): void {
    const queue: SongInfo[] = App.get().player.getQueue();
    for (let i = 0; i < queue.length; i++) {
      if (queue[i].id === song.id && queue[i].source === song.source) {
        App.get().player.removeAt(i);
        return;
      }
    }
  }

  private deleteOne(song: SongInfo): void {
    this.removeFromQueue(song);
    App.get().local.remove(song.id);
    const next: string[] = [];
    for (const id of this.selectedIds) {
      if (id !== song.id) {
        next.push(id);
      }
    }
    this.selectedIds = next;
    this.songs = App.get().local.toSongs();
    if (this.songs.length === 0) {
      // 全删光了：页面转空态，没有 toolbar 可点，选择模式必须自己退掉
      this.selectMode = false;
      this.selectedIds = [];
    }
    App.get().toast('已删除「' + song.name + '」');
  }

  private confirmDeleteSelected(): void {
    const count: number = this.selectedIds.length;
    if (count === 0) {
      App.get().toast('先勾选要删的歌');
      return;
    }
    AlertDialog.show({
      title: '删除本地音乐',
      message: '将删除 ' + count.toString() + ' 首的文件副本（仅应用内），手机里的原始文件不受影响。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: this.p().danger,
        action: () => {
          this.deleteSelected();
        }
      }
    });
  }

  private deleteSelected(): void {
    const ids: string[] = this.selectedIds.slice();
    if (ids.length === 0) {
      return;
    }
    for (const song of this.songs) {
      if (ids.indexOf(song.id) >= 0) {
        this.removeFromQueue(song);
      }
    }
    const removed: number = App.get().local.removeMany(ids);
    this.selectedIds = [];
    this.selectMode = false;
    this.songs = App.get().local.toSongs();
    App.get().toast('已删除 ' + removed.toString() + ' 首');
  }

  /**
   * 把一首歌移出自建歌单。
   * 只动歌单数据，本地文件和平台缓存都不碰 —— 和上面 deleteOne 是两条完全不同的路径，
   * 混用会把用户的本地文件一起删掉。
   */
  private removeFromPlaylistOne(song: SongInfo): void {
    Library.get().removeFromPlaylist(this.sheet.id, song);
    const key = Library.key(song);
    const next: SongInfo[] = [];
    for (const item of this.songs) {
      if (Library.key(item) !== key) {
        next.push(item);
      }
    }
    this.songs = next;
    this.sheet.trackCount = next.length;
    App.get().toast('已从歌单移除「' + song.name + '」');
  }

  @Builder
  swipeDelete(song: SongInfo) {
    Column({ space: 2 }) {
      SymbolGlyph(this.isLocalKind() ? $r('sys.symbol.trash') : $r('sys.symbol.minus_circle'))
        .fontSize(17)
        .fontColor(['#FFFFFFFF'])
      Text(this.isLocalKind() ? '删除' : '移除')
        .fontSize(FONT.micro)
        .fontColor('#FFFFFFFF')
    }
    .width(76)
    .height(56)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.p().danger)
    .borderRadius(12)
    .margin({ left: 8 })
    .onClick(() => {
      if (this.isLocalKind()) {
        this.deleteOne(song);
      } else if (this.isFavKind()) {
        this.removeFavoriteOne(song);
      } else if (this.isHistoryKind()) {
        this.removeHistoryOne(song);
      } else {
        this.removeFromPlaylistOne(song);
      }
    })
  }

  /**
   * 从「我喜欢」移除一首。
   * 只改收藏表：本地文件、下载缓存、正在播的队列都保持原样——
   * 取消收藏不等于不想听了，队列被顺手改掉会打断当前播放。
   */
  private removeFavoriteOne(song: SongInfo): void {
    Library.get().removeFavorite(song);
    this.refreshList();
    App.get().toast('已从我喜欢移除「' + song.name + '」');
  }

  /** 删一条播放记录：只影响这份历史，歌本身照样能播、能搜 */
  private removeHistoryOne(song: SongInfo): void {
    Library.get().removeHistory(song);
    this.refreshList();
    App.get().toast('已从最近播放移除「' + song.name + '」');
  }

  /**
   * 删完之后重取一遍，而不是在本地数组里 splice。
   * Library 的去重键（历史用「歌名+歌手」）和 SongRow 的 key 不是一回事，
   * 自己过滤容易漏掉同曲异平台的另一条，界面上就是「点了没反应」。
   */
  private refreshList(): void {
    this.songs = Library.get().songsOf(this.sheet).slice();
    this.sheet.cover = this.songs.length > 0 ? this.songs[0].cover : '';
    this.sheet.trackCount = this.songs.length;
    if (this.songs.length === 0) {
      // 删到空不能只剩一个空壳：补一句「怎么才会有歌」，否则空态一片白，
      // 用户会以为页面坏了（清空后尤其明显）。
      this.message = this.isFavKind() ? '还没有收藏歌曲，在播放页点心形按钮即可' : '还没有播放记录';
      this.selectMode = false;
      this.selectedIds = [];
    }
  }

  /** 清空是破坏性的，且一次抹掉整份列表，必须过确认 */
  private confirmClear(): void {
    const count: number = this.songs.length;
    if (count === 0) {
      return;
    }
    const what: string = this.isFavKind() ? '我喜欢' : '最近播放';
    AlertDialog.show({
      title: '清空' + what,
      message: this.isFavKind()
        ? '将移除 ' + count.toString() + ' 首收藏。只清空这个列表，不会删除本地文件，也不影响已下载的歌。'
        : '将清空 ' + count.toString() + ' 条播放记录。只影响这个列表，不会删除任何文件。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: this.p().danger,
        action: () => {
          this.clearAll();
        }
      }
    });
  }

  private clearAll(): void {
    if (this.isFavKind()) {
      Library.get().clearFavorites();
    } else {
      Library.get().clearHistory();
    }
    this.songs = [];
    this.sheet.cover = '';
    this.sheet.trackCount = 0;
    this.message = this.isFavKind() ? '还没有收藏歌曲，在播放页点心形按钮即可' : '还没有播放记录';
    this.selectMode = false;
    this.selectedIds = [];
    App.get().toast(this.isFavKind() ? '已清空我喜欢' : '已清空最近播放');
  }

  private downloadAll(): void {
    if (this.songs.length === 0) {
      return;
    }
    let count = 0;
    for (const song of this.songs) {
      if (!App.get().hasDownload(song) && song.source !== 'local') {
        App.get().downloads.enqueue(song);
        count++;
      }
    }
    App.get().toast(count > 0 ? '已加入 ' + count.toString() + ' 首到下载队列' : '这些歌都已经在本地了');
  }

  private async importLocal(): Promise<void> {
    const count = await App.get().local.importFromPicker();
    if (count > 0) {
      this.songs = App.get().local.toSongs();
      App.get().toast('已导入 ' + count.toString() + ' 首');
    }
  }

  @Builder
  head() {
    Column({ space: 16 }) {
      Row({ space: 14 }) {
        Stack({ alignContent: Alignment.BottomEnd }) {
          Cover({ uri: this.sheet.cover, fallbackUri: this.sheet.coverFallback ?? '', side: 96, radius: 18, elevated: true, badge: '♪' })
        }
        Column({ space: 6 }) {
          Text(this.sheet.name.length > 0 ? this.sheet.name : '未命名列表')
            .fontSize(21)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.p().text)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.subtitle())
            .fontSize(FONT.caption)
            .fontColor(this.p().text3)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')

      if (this.sheet.description.length > 0) {
        Text(this.sheet.description)
          .fontSize(FONT.caption)
          .fontColor(this.p().text3)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }


      Row({ space: 10 }) {
        // 多选态把播放入口收起来：这时点「播放全部」既会打断选择，又容易误触
        if (!this.selectMode) {
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

        Blank()

        // 平台歌单 / 榜单 / 专辑的「收藏」：状态由 sheetFav 驱动。
        // 点一下 toggleSheetFavorite 会广播 libraryVersion，本页按钮、首页计数、
        // 歌单卡角标、收藏列表页四处一起刷新，不会出现某处还停在旧状态。
        if (this.canFavoriteSheet() && !this.selectMode) {
          Row({ space: 5 }) {
            SymbolGlyph(this.sheetFav ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
              .fontSize(15)
              .fontColor([this.sheetFav ? '#FF191713' : this.p().primary])
            Text(this.sheetFav ? '已收藏' : '收藏')
              .fontSize(FONT.caption)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.sheetFav ? '#FF191713' : this.p().primary)
          }
          .height(42)
          .padding({ left: 14, right: 14 })
          .borderRadius(RADIUS.pill)
          .backgroundColor(glassCardBase(this.isDark))
          .linearGradient({ angle: this.sheetFav ? 135 : 180, colors: this.favBtnGradient() })
          .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
          .shadow(glassShadow(this.isDark, this.lightLevel))
          .onClick(() => {
            const on = Library.get().toggleSheetFavorite(this.sheet);
            this.sheetFav = on;
            // v2.66：按歌单所属平台提示同步目标。wy/qq/kg 的可订阅歌单都会异步
            // 写到本人账号，用户才知道「收藏」不只是本地动作；酷狗云端取消收藏
            // 受官方 RSA+AES 限制做不了，如实提示去 APP 端确认，绝不假装已同步。
            const plat = Library.syncPlatform(this.sheet);
            let target = '';
            if (plat === 'wy') {
              target = '网易云账号';
            } else if (plat === 'tx') {
              target = 'QQ音乐账号';
            } else if (plat === 'kg') {
              target = '酷狗账号';
            }
            if (plat === 'kg' && !on) {
              App.get().toast('已取消收藏，酷狗端请在 APP 内确认');
            } else if (target.length > 0) {
              App.get().toast(on ? '已收藏，正在同步到' + target : '已取消收藏，正在同步到' + target);
            } else {
              App.get().toast(on ? '已收藏这个歌单' : '已取消收藏');
            }
          })
        }

        if (!this.selectMode) {
          // 行尾图标做成 42 的玻璃圆，跟「播放全部」等高：以前 36 的小圆点
          // 摆在蓝色主按钮旁边明显小一圈，去掉随机播放后正好把这一排拉齐。
          Row() {
            if (this.sheet.kind === 'local') {
              SymbolGlyph($r('sys.symbol.folder_badge_plus'))
                .fontSize(20)
                .fontColor([this.p().text2])
            } else {
              SymbolGlyph($r('sys.symbol.arrow_down_circle'))
                .fontSize(20)
                .fontColor([this.p().text2])
            }
          }
          .width(42)
          .height(42)
          .justifyContent(FlexAlign.Center)
          .borderRadius(21)
          .backgroundColor(glassCardBase(this.isDark))
          .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
          .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
          .shadow(glassShadow(this.isDark, this.lightLevel))
          .onClick(() => {
            if (this.sheet.kind === 'local') {
              this.importLocal();
            } else {
              this.downloadAll();
            }
          })
        }

        // 我喜欢 / 最近播放：一键清空。同样是 42 的圆形，破坏性操作靠确认弹窗把关。
        if (this.canClear() && !this.selectMode) {
          Row() {
            SymbolGlyph($r('sys.symbol.trash'))
              .fontSize(20)
              .fontColor([this.p().danger])
          }
          .width(42)
          .height(42)
          .justifyContent(FlexAlign.Center)
          .borderRadius(21)
          .backgroundColor(withAlpha(this.p().danger, 0.10))
          .onClick(() => {
            this.confirmClear();
          })
        }

        // 本地音乐才有批量删除：平台歌单删不了，别给一个点不动的入口。
        // 胶囊也收成 42 高，和主按钮、行尾图标同一条基线。
        // v2.55：进入选择模式后入口收起，退出统一交给下方选择条的「取消」，
        // 与音源管理页 / 歌单收藏页一致（原来这里是「完成」，三页两种说法）。
        if (this.sheet.kind === 'local' && this.songs.length > 0 && !this.selectMode) {
          Text('选择')
            .fontSize(FONT.caption)
            .fontColor(this.p().text2)
            .height(42)
            .textAlign(TextAlign.Center)
            .padding({ left: 14, right: 14 })
            .backgroundColor(glassCardBase(this.isDark))
            .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
            .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
            .shadow(glassShadow(this.isDark, this.lightLevel))
            .borderRadius(RADIUS.pill)
            .onClick(() => {
              this.enterSelect();
            })
        }
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .borderRadius(RADIUS.lg)
    .backgroundColor(glassCardBase(this.isDark))
    .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
    .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
    .shadow(glassShadow(this.isDark, this.lightLevel))
  }

  private subtitle(): string {
    const parts: string[] = [];
    if (this.sheet.kind === 'local') {
      parts.push('本地文件');
    } else if (this.sheet.kind === 'favorites') {
      parts.push('我喜欢的音乐');
    } else if (this.sheet.kind === 'history') {
      parts.push('最近播放');
    } else if (this.sheet.platform === 'local' && this.sheet.kind === 'playlist') {
      parts.push('自建歌单');
    } else {
      parts.push(platformName(this.sheet.platform));
      if (this.sheet.creator.length > 0) {
        parts.push(this.sheet.creator);
      }
    }
    parts.push(this.songs.length.toString() + ' 首');
    if (this.sheet.playCount > 0) {
      parts.push(formatCount(this.sheet.playCount) + ' 次播放');
    }
    if (this.sheet.updateTime.length > 0) {
      parts.push(this.sheet.updateTime);
    }
    return parts.join(' · ');
  }

  @Builder
  menuSheet() {
    SongMenu({
      song: this.menuSong,
      // 平台歌单不是「我的歌单」，传 sheet 让菜单不出现「从歌单移除」
      kind: this.isLocalList(this.sheet) ? this.sheet.kind : 'sheet',
      playlistId: this.isLocalList(this.sheet) && this.sheet.kind === 'playlist' ? this.sheet.id : '',
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
          LoadingBlock({ text: '正在读取歌曲' })
        } else if (this.songs.length === 0) {
          EmptyView({
            icon: this.sheet.kind === 'local' ? $r('sys.symbol.folder') : $r('sys.symbol.music_note_list'),
            title: this.sheet.kind === 'local' ? '还没有本地音乐' : '这里还没有歌',
            hint: this.message,
            action: this.sheet.kind === 'local' ? '导入文件' : '重新加载',
            onAction: () => {
              if (this.sheet.kind === 'local') {
                this.importLocal();
              } else {
                this.loadSheet(new SheetParam(this.sheet));
              }
            }
          })
        } else {
          List() {
            ListItem() {
              Column({ space: 14 }) {
                this.head()
              }
              .width('100%')
              .padding({ bottom: 8 })
            }

            ForEach(this.songs, (song: SongInfo, index: number) => {
              // 本地音乐与自建歌单可左滑（一个删文件、一个移出歌单）；平台歌单没有这个能力
              if (this.canSwipe()) {
                ListItem() {
                  SongRow({
                    song: song,
                    index: index + 1,
                    showIndex: true,
                    selectMode: this.selectMode,
                    selected: this.selectedIds.indexOf(song.id) >= 0,
                    active: App.get().isCurrent(song),
                    playing: App.get().player.isPlaying(),
                    onTap: () => {
                      if (this.selectMode) {
                        this.toggleSelect(song);
                        return;
                      }
                      App.get().play(this.songs.slice(), index);
                    },
                    onMore: () => {
                      this.openMenu(song);
                    }
                  })
                }
                .padding({ left: 4, right: 4 })
                .swipeAction({
                  end: {
                    builder: () => {
                      this.swipeDelete(song);
                    },
                    actionAreaDistance: 84
                  },
                  edgeEffect: SwipeEdgeEffect.Spring
                })
              } else {
                ListItem() {
                  SongRow({
                    song: song,
                    index: index + 1,
                    showIndex: true,
                    rankTop: this.sheet.kind === 'rank' ? 3 : 0,
                    active: App.get().isCurrent(song),
                    playing: App.get().player.isPlaying(),
                    onTap: () => {
                      App.get().play(this.songs.slice(), index);
                    },
                    onMore: () => {
                      this.openMenu(song);
                    }
                  })
                }
                .padding({ left: 4, right: 4 })
              }
            }, (song: SongInfo, index: number) => song.source + song.id + index.toString())

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

          // v2.55：选择条从头部卡片挪到列表下方，与音源管理 / 歌单收藏同一位置、
          // 同一套 SelectionBar。原来是挤在 head 里跟着列表滚走的一排文字。
          if (this.selectMode) {
            SelectionBar({
              selectedCount: this.selectedIds.length,
              totalCount: this.songs.length,
              allSelected: this.selectedIds.length === this.songs.length && this.songs.length > 0,
              onCancel: (): void => {
                this.exitSelect();
              },
              onToggleAll: (): void => {
                this.toggleSelectAll();
              },
              onConfirm: (): void => {
                this.confirmDeleteSelected();
              }
            })

            // 给全局悬浮层（迷你播放条 + 胶囊标签栏）留白，选择条才不会被盖住
            Row().height(PAGE_BOTTOM + MINI_BAR_SPACE)
          }

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

      // 悬浮标题：列表从标题后穿过
      ImmersiveBar({
        title: this.sheet.kind === 'local' ? '本地音乐' : '',
        subtitle: this.loading ? '加载中' : this.songs.length.toString() + ' 首',
        showSearch: true,
        onBack: () => {
          // v2.55：与系统返回共用同一套优先级（选择模式 → 浮层 → 退页）
          App.get().back((): boolean => this.localBack());
        },
        // v2.54：歌单里看到想听的另一首，直接搜，不用退回首页
        onSearch: () => {
          App.get().openSearch('');
        }
      })
      }
    }
    .hideTitleBar(true)
    // 返回优先级：页内临时态（选择模式）→ 全局浮层 → 退页，顺序只在 App.consumeBack 定义
    .onBackPressed(() => App.get().consumeBack((): boolean => this.localBack()))
    .onReady((ctx: NavDestinationContext) => {
      const param = ctx.pathInfo.param as SheetParam;
      if (param !== undefined && param !== null && !this.loaded) {
        this.loaded = true;
        this.loadSheet(param);
      }
    })
    .onShown(() => {
      if (this.loaded && (this.sheet.kind === 'local' || this.sheet.kind === 'download')) {
        this.songs = this.sheet.kind === 'local' ? App.get().local.toSongs() : this.songs;
      }
    })
  }
}

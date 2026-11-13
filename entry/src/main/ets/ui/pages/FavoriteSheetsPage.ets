import {
  palette, Palette, FONT, RADIUS, PAGE_PAD, PAGE_BOTTOM, MINI_BAR_SPACE,
  glassCardBase
} from '../../common/Constants';
import { SheetInfo, NavParam, newSheet } from '../../common/Models';
import { platformShort } from '../../common/Platform';
import { App } from '../../core/App';
import { Library } from '../../core/Library';
import { TabBarHider } from '../../core/UiBar';
import { WyFavSync } from '../../core/WyFavSync';
import { FavSyncHub, FavSyncStatus } from '../../core/FavSyncHub';
import { parsePlaylistInput, PlaylistRef, IMPORT_PLATFORM_IDS } from '../../core/PlaylistImport';
import { EmptyView, GlassSheetCard, SelectionBar, ImmersiveBar } from '../Common';

/**
 * 歌单收藏：把 Library 里的收藏歌单集中展示出来。
 *
 * 数据不落在本页状态里，只在 libraryVersion 变化时从 Library 重取一份快照：
 * 详情页点「收藏 / 取消收藏」、本页退回收藏、别处移除，走的都是同一个广播，
 * 于是首页计数、发现页/搜索页卡片角标、详情页按钮、本页列表四处同时刷新。
 *
 * 视觉沿用发现页推荐歌单的 GlassSheetCard（青绿液态玻璃卡座）。
 * v2.62：顶部原来那张「歌单收藏 / N 个歌单」说明卡与标题栏信息重复、白占一屏，
 * 已整体移除；计数交给 ImmersiveBar 的 subtitle，进多选统一靠长按卡片。
 * 卡片传 titleLines: 2 固定标题区高度，避免一行 / 两行标题把同排卡片撑得一高一矮。
 */
@Component
export struct FavoriteSheetsPage {
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;
  @StorageProp('topSafe') topSafe: number = 24;
  /** toggleSheetFavorite / removeSheetFavorite 都会广播它，收藏状态实时跟上 */
  @StorageProp('libraryVersion') @Watch('onLibraryChange') libraryVersion: number = 0;
  @State sheets: SheetInfo[] = [];
  /** v2.49：选择模式，勾选的是 Library.sheetKey()（跨平台唯一键，不用 name 怕重名） */
  @State selectMode: boolean = false;
  @State selected: string[] = [];
  /**
   * v2.72：导入歌单面板从首页搬到本页标题栏右上角（图 3 标记处）。
   * 逻辑与首页逐字保持一致：链接 / ID、自定义名称、纯 ID 时的兜底平台。
   */
  @State importShow: boolean = false;
  @State importText: string = '';
  @State importName: string = '';
  @State importPlatform: string = 'wy';
  /** v2.65：账号同步状态（idle / syncing / ok / fail / guest），由 WyFavSync 广播 */
  @StorageProp('wyFavSyncState') syncState: string = 'idle';
  @StorageProp('wyFavSyncVersion') syncVersion: number = 0;
  /** 上次成功同步时间戳：订阅它，同步一完成状态条的时间就跟着刷新 */
  @StorageProp('wyFavSyncAt') syncAt: number = 0;
  /** 长按手势与点击可能同时上报，记下时间戳让抬手后的点击被忽略一次 */
  private lastLongPressAt: number = 0;

  aboutToAppear(): void {
    this.refresh();
    // 进页即对账：这是「在 APP 端收藏了，进来一定要能看到」的关键触发点。
    // 云端为准但失败不动本地，所以弱网/未登录时这一下是安全空操作。
    WyFavSync.get().reconcile().catch(() => {
    });
  }

  onLibraryChange(): void {
    this.refresh();
  }

  private refresh(): void {
    this.sheets = Library.get().getFavoriteSheets().slice();
    // 别处（详情页点取消收藏）移除了某个歌单时，把已失效的勾选一并清掉，
    // 否则「已选 N / M」会虚高、确认弹窗里还列着已经不存在的名字。
    if (this.selected.length > 0) {
      const alive: string[] = [];
      for (const key of this.selected) {
        if (this.sheets.some((s: SheetInfo): boolean => Library.sheetKey(s) === key)) {
          alive.push(key);
        }
      }
      this.selected = alive;
      if (this.sheets.length === 0) {
        this.selectMode = false;
      }
    }
  }

  private p(): Palette {
    return palette(this.isDark);
  }

  /* ---------------- v2.65 网易云账号同步状态条 ---------------- */

  /**
   * v2.67：文案统一由 FavSyncHub.label('all') 生成，收藏页不再自己拼状态。
   * 铁律：只要还有待同步项 / 失败 / 在途，就绝不出现「已与账号同步」。
   */
  private syncLabel(): string {
    return FavSyncHub.get().label('all');
  }

  /** 图标态也走同一份聚合，避免图标是转圈、文案却说已同步 */
  private syncVisual(): FavSyncStatus {
    return FavSyncHub.get().status('all');
  }

  /**
   * v2.68：状态条按需显示，同步完成后直接隐藏。
   *
   * 前台心跳每 12s 触发一次 reconcileAll()，每轮都会把引擎状态打回 syncing
   * 并广播。原来无条件渲染时，状态条会反复闪「正在与平台同步…」，看起来像
   * 一直没同步完；实际上文案后没有「· N 项未同步」尾巴，说明队列已清空、
   * 写云端已成功，只是被下一轮心跳又打回在途状态。
   *
   * 只在需要用户关注或操作时出现：未登录引导、首次同步在途、有待上传项、
   * 官方受限项、同步失败。已经成功同步过（at > 0）且无待办时整条隐藏。
   * 隐藏后手动同步入口仍在账号页与平台账号面板，前台心跳与进页对账不受影响。
   */
  private showSyncBar(): boolean {
    const v = this.syncVisual();
    if (!v.loggedIn || v.failed || v.auto > 0 || v.manual > 0) {
      return true;
    }
    if (v.at > 0) {
      return false;
    }
    return v.syncing || !v.clean;
  }

  /** 点状态条：三个账号都没登录先去账号页，否则等三平台全部对账完再报真实结论 */
  private onSyncTap(): void {
    if (!FavSyncHub.get().anyLoggedIn()) {
      App.get().push('wyAccount', new NavParam());
      return;
    }
    FavSyncHub.get().reconcileAllAwait().then(() => {
      App.get().toast(FavSyncHub.get().toastText('all'));
    }).catch(() => {
    });
  }

  @Builder
  syncBar() {
    Row({ space: 10 }) {
      // v2.67：图标 / 文案同源于一份聚合状态；@StorageProp 订阅的 version 由
      // broadcast 递增，保证状态条随每次对账 / 队列变化即时重绘。
      if (this.syncVisual().syncing) {
        LoadingProgress().width(16).height(16).color(this.p().primary)
      } else {
        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize(15)
          .fontColor([this.syncVisual().clean ? this.p().primary : this.p().text3])
      }
      Text(this.syncLabel())
        .fontSize(FONT.caption)
        .fontColor(this.p().text2)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (!this.syncVisual().syncing) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(13)
          .fontColor([this.p().text3])
      }
    }
    .width('100%')
    .height(44)
    .padding({ left: 14, right: 14 })
    .borderRadius(RADIUS.md)
    .backgroundColor(this.p().card)
    .border({ width: 1, color: this.p().line })
    .margin({ bottom: 12 })
    .onClick(() => {
      this.onSyncTap();
    })
  }

  /* ---------------- v2.49 多选批量删除 ---------------- */

  private isSelected(key: string): boolean {
    return this.selected.indexOf(key) >= 0;
  }

  private toggleSelect(key: string): void {
    const list = this.selected.slice();
    const index = list.indexOf(key);
    if (index >= 0) {
      list.splice(index, 1);
    } else {
      list.push(key);
    }
    this.selected = list;
  }

  private allSelected(): boolean {
    return this.sheets.length > 0 && this.selected.length === this.sheets.length;
  }

  private toggleAll(): void {
    if (this.allSelected()) {
      this.selected = [];
      return;
    }
    const list: string[] = [];
    for (const sheet of this.sheets) {
      list.push(Library.sheetKey(sheet));
    }
    this.selected = list;
  }

  /**
   * 进入多选。firstKey 非空时把这张歌单预选上 —— 长按哪张就从哪张开始，
   * 之后点其它卡片继续累加，底部仍有「全选」。
   */
  private enterSelect(firstKey: string = ''): void {
    if (this.sheets.length === 0) {
      App.get().toast('还没有可选择的歌单');
      return;
    }
    this.selected = firstKey.length > 0 ? [firstKey] : [];
    this.selectMode = true;
  }

  private exitSelect(): void {
    this.selectMode = false;
    this.selected = [];
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

  /** 长按卡片：以这张为起点进入多选，已在选择模式时不重复触发 */
  private onCardLongPress(sheet: SheetInfo): void {
    if (this.selectMode) {
      return;
    }
    this.lastLongPressAt = Date.now();
    this.enterSelect(Library.sheetKey(sheet));
  }

  /** 点卡片：选择模式切换勾选，否则进详情。两者不叠加，避免一次触摸被处理两次 */
  private onCardTap(sheet: SheetInfo): void {
    // 长按手势识别后抬手，部分机型仍会补一次 onClick —— 忽略掉，
    // 否则刚进多选就又把这张歌单的详情页打开了。
    if (Date.now() - this.lastLongPressAt < 600) {
      return;
    }
    if (this.selectMode) {
      this.toggleSelect(Library.sheetKey(sheet));
      return;
    }
    App.get().openSheet(sheet);
  }

  private confirmRemoveSelected(): void {
    const picked: SheetInfo[] = [];
    for (const sheet of this.sheets) {
      if (this.isSelected(Library.sheetKey(sheet))) {
        picked.push(sheet);
      }
    }
    if (picked.length === 0) {
      App.get().toast('先勾选要删除的歌单');
      return;
    }
    let names = '';
    for (let i = 0; i < picked.length && i < 3; i++) {
      names += (i > 0 ? '、' : '') + '「' + picked[i].name + '」';
    }
    if (picked.length > 3) {
      names += ' 等 ' + picked.length.toString() + ' 个';
    }
    AlertDialog.show({
      title: '取消收藏 ' + picked.length.toString() + ' 个歌单',
      message: '将从歌单收藏里移除 ' + names + '，只影响收藏列表，不会删除歌单本身或歌曲文件。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '移除',
        fontColor: this.p().danger,
        action: () => {
          const keys: string[] = [];
          for (const sheet of picked) {
            keys.push(Library.sheetKey(sheet));
          }
          const count = Library.get().removeSheetFavorites(keys);
          this.exitSelect();
          App.get().toast(count > 0 ? '已取消收藏 ' + count.toString() + ' 个歌单' : '这些歌单已经不在收藏里了');
        }
      }
    });
  }

  /**
   * v2.72：导入歌单面板（从首页整体搬来，图 3 标记处触发）。
   * 解析工作全在 core/PlaylistImport.ets，这里只收集输入、展示五个平台的
   * 手选胶囊（纯 ID 时兜底），不碰任何取数逻辑。
   */
  @Builder
  importSheet() {
    Column({ space: 12 }) {
      Text('导入歌单')
        .fontSize(FONT.headline)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.p().text)
        .width('100%')
      Text('粘贴网易云 / QQ音乐 / 酷我 / 酷狗 / 咪咕的歌单或专辑链接，也可以只填歌单 ID。导入后会加入「歌单收藏」并打开，之后随时能找回来。\n汽水音乐等平台暂不支持：官方没有匿名可用的公开歌单接口，取歌单需要扫码登录与签名，匿名只能拿到试听片段，与本应用的无损取链不兼容。')
        .fontSize(FONT.caption)
        .fontColor(this.p().text2)
        .lineHeight(18)
        .width('100%')

      TextInput({ text: this.importName, placeholder: '名称（可选，留空自动生成）' })
        .fontSize(FONT.body)
        .fontColor(this.p().text)
        .placeholderColor(this.p().text3)
        .backgroundColor(this.p().cardAlt)
        .borderRadius(RADIUS.md)
        .height(44)
        .width('100%')
        .onChange((value: string) => {
          this.importName = value;
        })

      TextArea({ text: this.importText, placeholder: 'https://music.163.com/#/playlist?id=...\n或直接粘贴歌单 ID' })
        .fontSize(FONT.caption)
        .fontColor(this.p().text)
        .placeholderColor(this.p().text3)
        .backgroundColor(this.p().cardAlt)
        .borderRadius(RADIUS.md)
        .height(88)
        .width('100%')
        .onChange((value: string) => {
          this.importText = value;
        })

      Text('链接里自带平台时以链接为准；只填 ID 时按这里选：')
        .fontSize(FONT.micro)
        .fontColor(this.p().text3)
        .width('100%')
      Row({ space: 6 }) {
        ForEach(IMPORT_PLATFORM_IDS, (id: string) => {
          Button(platformShort(id))
            .fontSize(FONT.caption)
            .fontColor(this.importPlatform === id ? '#FF191713' : this.p().text2)
            .backgroundColor(this.importPlatform === id ? this.p().primary : this.p().cardAlt)
            .borderRadius(RADIUS.pill)
            .height(32)
            .layoutWeight(1)
            .onClick(() => {
              this.importPlatform = id;
            })
        }, (id: string) => id)
      }
      .width('100%')

      Row({ space: 12 }) {
        Button('取消')
          .fontSize(FONT.callout)
          .fontColor(this.p().text2)
          .backgroundColor(this.p().cardAlt)
          .borderRadius(RADIUS.pill)
          .height(42)
          .layoutWeight(1)
          .onClick(() => {
            this.importShow = false;
          })
        Button('导入')
          .fontSize(FONT.callout)
          .fontColor('#FF191713')
          .backgroundColor(this.p().primary)
          .borderRadius(RADIUS.pill)
          .height(42)
          .layoutWeight(1)
          .onClick(() => {
            this.doImport();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 8, bottom: 8 })
  }

  /**
   * 解析 → 构造 SheetInfo → 加入歌单收藏 → 打开详情页。
   * 详情页本来就按「平台 + 歌单 ID」取歌，五个平台都现成，不用新写取数接口。
   * v2.72：从首页搬来，仓库访问改用单例 Library.get()（本页没有 this.library）。
   */
  private doImport(): void {
    const ref: PlaylistRef | null = parsePlaylistInput(this.importText, this.importPlatform);
    if (ref === null) {
      App.get().toast('没识别出歌单 ID：请粘贴完整链接，或只填 ID 并在下方选好平台');
      return;
    }
    const custom: string = this.importName.trim();
    const sheet: SheetInfo = newSheet(ref.platform, ref.kind);
    sheet.id = ref.id;
    sheet.name = custom.length > 0 ? custom : ref.name;
    sheet.subtitle = '导入的' + (ref.kind === 'album' ? '专辑' : '歌单');
    if (!Library.get().isSheetFavorite(sheet)) {
      Library.get().toggleSheetFavorite(sheet);
    }
    this.importShow = false;
    this.importText = '';
    this.importName = '';
    App.get().openSheet(sheet);
    App.get().toast('已导入到歌单收藏：' + sheet.name);
  }


  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Top }) {
        Column() {
          // v2.68：同步完成且无待办时整条隐藏，只有需要用户关注或操作才出现。
          // 未登录时仍然显示（保留「去登录」引导），空态不受影响。
          if (this.showSyncBar()) {
            this.syncBar()
          }
          if (this.sheets.length === 0) {
            EmptyView({
              icon: $r('sys.symbol.heart'),
              title: '还没有收藏的歌单',
              hint: '在歌单详情页点「收藏」，这里就能随时找回来',
              action: '',
              onAction: (): void => {
              }
            })
          } else {
            Scroll() {
              Column({ space: 12 }) {
                // v2.62：顶部说明卡已移除（与标题栏重复）。列表直接从这里开始，
                // 计数在 ImmersiveBar 的 subtitle，长按卡片进多选，见文件头注释。
                Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
                  ForEach(this.sheets, (sheet: SheetInfo) => {
                    Stack({ alignContent: Alignment.TopStart }) {
                      GlassSheetCard({
                        sheet: sheet,
                        cardWidth: 140,
                        // 标题区固定两行高：一行标题的「热歌榜」和两行标题的
                        // 「BBA专供…」占同样的高度，同排卡片与副标题才对齐。
                        titleLines: 2,
                        // v2.70：右上角心形角标就是收藏开关 —— 点一下直接切换，
                        // Library.toggleSheetFavorite 内部会按平台分发同步 hook，
                        // 把这次取消/收藏写到对应账号，不必再进歌单详情页操作。
                        // 选择模式下关掉：此时点卡片是「勾选」，不该被角标截走
                        // 变成取消收藏（与 SongRow 多选隐藏行内收藏同一约定）。
                        favTappable: !this.selectMode,
                        onFavTap: (): void => {
                          const on: boolean = Library.get().toggleSheetFavorite(sheet);
                          App.get().toast(on ? '已收藏' : '已取消收藏');
                        },
                        onTap: (): void => {
                          this.onCardTap(sheet);
                        }
                      })
                      // 选择模式下左上角叠勾选圈，整层不接触摸，点击仍交给卡片的 onTap。
                      if (this.selectMode) {
                        Stack() {
                          if (this.isSelected(Library.sheetKey(sheet))) {
                            SymbolGlyph($r('sys.symbol.checkmark'))
                              .fontSize(13)
                              .fontColor(['#FF191713'])
                          }
                        }
                        .width(24)
                        .height(24)
                        .borderRadius(12)
                        .backgroundColor(this.isSelected(Library.sheetKey(sheet)) ? this.p().primary : '#66000000')
                        .border({
                          width: 1.5,
                          color: this.isSelected(Library.sheetKey(sheet)) ? this.p().primary : '#CCFFFFFF'
                        })
                        .margin({ top: 12, left: 12 })
                        .hitTestBehavior(HitTestMode.None)
                      }
                    }
                    .opacity(this.selectMode && !this.isSelected(Library.sheetKey(sheet)) ? 0.62 : 1)
                    .margin({ bottom: 16 })
                    .gesture(
                      LongPressGesture({ repeat: false, duration: 400 })
                        .onAction(() => {
                          this.onCardLongPress(sheet);
                        })
                    )
                  // key 必须带选中态：只改 selected 而不改 key，ArkUI 会复用旧节点不重绘（v2.47 同款根因）
                  }, (sheet: SheetInfo) => Library.sheetKey(sheet) +
                    (this.selectMode && this.isSelected(Library.sheetKey(sheet)) ? '_s' : ''))
                }
                .width('100%')

                Row().height(PAGE_BOTTOM + MINI_BAR_SPACE + 20)
              }
              .width('100%')
            }
            .width('100%')
            .layoutWeight(1)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
            // 内容不足一屏时 Scroll 默认会垂直居中，显式顶对齐（v2.14 同款修正）
            .align(Alignment.Top)
            .onScrollFrameBegin((offset: number, state: ScrollState) => {
              TabBarHider.get().feed(offset);
              return { offsetRemain: offset };
            })
          }

          // v2.50：选择条固定在列表下方（全局迷你播放条 / 胶囊标签栏之上），
          // 不再挤在顶部说明卡下面；v2.55 换成公共 SelectionBar，与音源管理页同源。
          if (this.selectMode) {
            SelectionBar({
              selectedCount: this.selected.length,
              totalCount: this.sheets.length,
              allSelected: this.allSelected(),
              onCancel: (): void => {
                this.exitSelect();
              },
              onToggleAll: (): void => {
                this.toggleAll();
              },
              onConfirm: (): void => {
                this.confirmRemoveSelected();
              }
            })

            // 给全局悬浮层（迷你播放条 + 胶囊标签栏）留白，选择条才不会被盖住
            Row().height(PAGE_BOTTOM + MINI_BAR_SPACE)
          }
        }
        .width('100%')
        .height('100%')
        .padding({ left: PAGE_PAD, right: PAGE_PAD, top: this.topSafe + 52 })
        .backgroundColor('#00000000')

        ImmersiveBar({
          title: '歌单收藏',
          subtitle: this.sheets.length.toString() + ' 个',
          // v2.72：右上角「+ 导入歌单」（图 3 标记处）。默认关闭的顶栏动作，
          // 只有本页打开；点击拉起导入面板，选择模式下仍可用（与勾选语义不冲突）。
          showTrailing: true,
          trailingIcon: $r('sys.symbol.plus'),
          trailingLabel: '导入歌单',
          onTrailing: (): void => {
            this.importText = '';
            this.importName = '';
            this.importShow = true;
          },
          onBack: (): void => {
            // v2.55：与系统返回共用同一套优先级（选择模式 → 浮层 → 退页）
            App.get().back((): boolean => this.localBack());
          }
        })
      }
      .width('100%')
      .height('100%')
      .bindSheet($$this.importShow, this.importSheet(), {
        height: SheetSize.FIT_CONTENT,
        dragBar: false,
        backgroundColor: glassCardBase(this.isDark)
      })
    }
    .hideTitleBar(true)
    // 返回优先级：页内临时态（选择模式）→ 全局浮层 → 退页，顺序只在 App.consumeBack 定义
    .onBackPressed(() => App.get().consumeBack((): boolean => this.localBack()))
  }
}

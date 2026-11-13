import {
  palette, Palette, RADIUS, FONT,
  glassCardBase, glassSurface, glassEdgeWidth, glassEdgeColor, glassShadow
} from '../common/Constants';
import { SongInfo, SheetInfo, NavParam } from '../common/Models';
import { App } from '../core/App';
import { WyAccount } from '../core/WyAccount';
import { WyRecommendHub } from '../core/WyRecommendHub';
import { Cover, SectionHeader, GlassSheetCard } from './Common';

/** v2.73：每日推荐按「5 首一组」分页横滑，一组一页，30 首正好 6 页 */
const REC_PAGE_SIZE: number = 5;
/** 一页里 5 行 × 56vp + 卡片上下留白；Swiper 需要明确高度，不能靠子组件撑 */
const REC_PAGE_HEIGHT: number = 292;

/**
 * 首页的「网易云账号实时推荐」板块（v2.71 建，v2.73 改分页轨）。
 *
 * 数据不在这里拉：只订阅 WyRecommendHub 广播的 wyRecVersion，版本一变就重读
 * 同一份快照（铁律 9）。因此首页与账号页看到的是同一份真实数据，任一处刷新
 * 两处同时变化，不存在「首页写死一组、账号页另拉一组」。
 *
 * 实时体现在四处触发：进首页、回前台、登录 / 退出变化、首页下拉刷新或板块
 * 右上角「刷新」。板块头显示「更新于 HH:mm」，加载中 / 失败 / 空 / 未登录
 * 都有明确状态；未登录只给登录引导，绝不塞游客或示例数据（铁律 2）。
 *
 * v2.73 口径修正：用户要「5 个一排、可以滑动」，不是 v2.72 那种「每首一张
 * 小卡、单首连续横滑」。这里改成 Swiper 分页轨 —— 每一页就是一整块 5 首
 * 纵向列表（序号 + 封面 + 歌名/歌手 + 时长，与账号页原列表同款），30 首切成
 * 6 页，左右滑动按「组」翻页，页面下方显示「第 N / M 组 · 共 30 首」。
 * 点播仍传全量 songList + 全局下标，翻到任意一组都从正确的那首开始。
 * 卡片 / 封面 / 标题头复用公共组件与青绿玻璃四件套，不另造样式（铁律 8）。
 * 分组 key 带 wyRecVersion，刷新后强制重建，避免 ForEach 复用旧行不更新。
 */
@Component
export struct WyRecommendSection {
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;
  @StorageProp('wyRecVersion') @Watch('onHubChange') recVersion: number = 0;
  @State songList: SongInfo[] = [];
  @State sheetList: SheetInfo[] = [];
  @State loading: boolean = false;
  @State at: number = 0;
  @State hint: string = '';
  @State loggedIn: boolean = false;
  /** 当前分页下标，用于「第 N / M 组」提示；数据刷新时归零 */
  @State recPage: number = 0;

  aboutToAppear(): void {
    this.sync();
  }

  onHubChange(): void {
    this.sync();
  }

  private sync(): void {
    const hub = WyRecommendHub.get();
    this.songList = hub.songs().slice();
    this.sheetList = hub.sheets().slice();
    this.loading = hub.isLoading();
    this.at = hub.lastAt();
    this.hint = hub.hint();
    this.loggedIn = WyAccount.get().isLoggedIn();
    this.recPage = 0;
  }

  private p(): Palette {
    return palette(this.isDark);
  }

  private hhmm(): string {
    const d = new Date(this.at);
    const h = d.getHours();
    const m = d.getMinutes();
    const hh = h < 10 ? '0' + h.toString() : h.toString();
    const mm = m < 10 ? '0' + m.toString() : m.toString();
    return hh + ':' + mm;
  }

  private sub(): string {
    const base = '来自你本人账号';
    return this.at > 0 ? base + ' · 更新于 ' + this.hhmm() : base;
  }

  private doRefresh(): void {
    WyRecommendHub.get().refresh().catch(() => {
    });
  }

  /** 点播传全量 songList + 全局下标，翻到任意一组都从正确的那首开始 */
  private play(index: number): void {
    App.get().play(this.songList, index);
  }

  /** 30 首 → 6 页，不丢任何一首；不足 5 首的尾页按实际行数渲染 */
  private pageCount(): number {
    return Math.ceil(this.songList.length / REC_PAGE_SIZE);
  }

  private pageIndexes(): number[] {
    const out: number[] = [];
    const n = this.pageCount();
    for (let i = 0; i < n; i++) {
      out.push(i);
    }
    return out;
  }

  /** 未登录：只给入口，不画任何推荐内容，也不放示例数据 */
  @Builder
  guestCard() {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.person')).fontSize(18).fontColor([this.p().primary])
      }
      .width(38)
      .height(38)
      .borderRadius(12)
      .backgroundColor(this.p().primarySoft)

      Column({ space: 3 }) {
        Text('登录网易云账号').fontSize(FONT.callout).fontWeight(FontWeight.Medium).fontColor(this.p().text)
        Text('查看基于你听歌喜好的每日推荐与推荐歌单')
          .fontSize(FONT.micro)
          .fontColor(this.p().text3)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([this.p().text3])
    }
    .width('100%')
    .padding(14)
    .borderRadius(RADIUS.lg)
    .backgroundColor(glassCardBase(this.isDark))
    .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
    .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
    .shadow(glassShadow(this.isDark, this.lightLevel))
    .onClick(() => {
      App.get().push('wyAccount', new NavParam());
    })
  }


  build() {
    Column({ space: 12 }) {
      if (!this.loggedIn) {
        this.guestCard()
      } else {
        SectionHeader({
          title: '每日推荐',
          subtitle: this.sub(),
          action: this.loading ? '' : '刷新',
          onAction: (): void => {
            this.doRefresh();
          }
        })

        if (this.loading && this.songList.length === 0) {
          Row({ space: 8 }) {
            LoadingProgress().width(20).height(20).color(this.p().primary)
            Text('正在获取推荐…').fontSize(FONT.caption).fontColor(this.p().text3)
          }
          .width('100%')
          .height(64)
          .justifyContent(FlexAlign.Center)
        } else if (this.songList.length === 0) {
          Text(this.hint.length > 0 ? this.hint : '暂无推荐歌曲')
            .fontSize(FONT.caption)
            .fontColor(this.p().text3)
            .width('100%')
            .padding({ left: 14, top: 10, bottom: 10 })
        } else {
          // v2.73：Swiper 分页轨，每页一整块 5 首纵向列表（与账号页原列表同款），
          // 左右滑动按「组」翻页；不再每首一张小卡连续横滑。内联写而不用带参
          // @Builder，规避 ArkUI「按值传参不刷新」的老坑；分组 key 带版本号。
          Swiper() {
            ForEach(this.pageIndexes(), (page: number) => {
              Column() {
                ForEach(this.songList.slice(page * REC_PAGE_SIZE, (page + 1) * REC_PAGE_SIZE),
                  (song: SongInfo, row: number) => {
                    Row({ space: 10 }) {
                      Text((page * REC_PAGE_SIZE + row + 1).toString())
                        .fontSize(FONT.caption)
                        .fontColor(this.p().text3)
                        .width(18)
                      Cover({ uri: song.cover, songId: '', side: 40, radius: 8 })
                      Column({ space: 2 }) {
                        Text(song.name)
                          .fontSize(FONT.callout)
                          .fontColor(this.p().text)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                        Text(song.singer)
                          .fontSize(FONT.micro)
                          .fontColor(this.p().text3)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)
                      if (song.interval.length > 0) {
                        Text(song.interval).fontSize(FONT.micro).fontColor(this.p().text3)
                      }
                    }
                    .width('100%')
                    .height(56)
                    .padding({ left: 12, right: 12 })
                    .onClick(() => {
                      this.play(page * REC_PAGE_SIZE + row);
                    })

                    if (row < REC_PAGE_SIZE - 1 &&
                        page * REC_PAGE_SIZE + row < this.songList.length - 1) {
                      Divider().color(this.p().line).margin({ left: 40, right: 12 })
                    }
                  }, (song: SongInfo, row: number) =>
                    'homeRec_' + this.recVersion.toString() + '_' + song.id + '_' + row.toString())
              }
              .width('100%')
              .height('100%')
              .justifyContent(FlexAlign.Center)
              .borderRadius(RADIUS.lg)
              .backgroundColor(glassCardBase(this.isDark))
              .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
              .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
              .shadow(glassShadow(this.isDark, this.lightLevel))
              .clip(true)
            }, (page: number) => 'homeRecPage_' + this.recVersion.toString() + '_' + page.toString())
          }
          .loop(false)
          .indicator(false)
          .width('100%')
          .height(REC_PAGE_HEIGHT)
          .onChange((index: number) => {
            this.recPage = index;
          })

          // 页码提示：明确「5 首一组、可左右滑动、30 首都在」
          Row() {
            Text('第 ' + (this.recPage + 1).toString() + ' / ' + this.pageCount().toString() +
              ' 组 · 共 ' + this.songList.length.toString() + ' 首')
              .fontSize(FONT.micro)
              .fontColor(this.p().text3)
            Blank()
            Text('左右滑动换组')
              .fontSize(FONT.micro)
              .fontColor(this.p().text3)
          }
          .width('100%')
          .padding({ left: 4, right: 4 })
        }

        if (this.sheetList.length > 0) {
          Column({ space: 8 }) {
            SectionHeader({ title: '为你推荐歌单', subtitle: '每日更新' })
            Scroll() {
              Row({ space: 12 }) {
                ForEach(this.sheetList.slice(0, 8), (sheet: SheetInfo) => {
                  GlassSheetCard({
                    sheet: sheet,
                    cardWidth: 132,
                    titleLines: 2,
                    onTap: (): void => {
                      App.get().openSheet(sheet);
                    }
                  })
                }, (sheet: SheetInfo) => 'homeRecSheet_' + sheet.id)
              }
              .padding({ left: 2, right: 2, bottom: 4 })
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .width('100%')
          }
          .width('100%')
        }

        // 已有旧数据时，失败提示放在末尾，既如实说明又不遮住上次成功的内容
        if (this.hint.length > 0 && this.songList.length > 0) {
          Text(this.hint)
            .fontSize(FONT.micro)
            .fontColor(this.p().text3)
            .width('100%')
            .padding({ left: 2 })
        }
      }
    }
    .width('100%')
  }
}

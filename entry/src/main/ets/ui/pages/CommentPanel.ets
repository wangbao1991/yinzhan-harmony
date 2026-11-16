import { palette, Palette, FONT, SPACE, RADIUS } from '../../common/Constants';
import { SongInfo, newSong } from '../../common/Models';
import {
  CommentInfo, CommentPage, emptyCommentPage, fetchComments,
  commentPlatformName
} from '../../core/CommentApi';

/**
 * 歌曲评论面板（v1.0 · 2026-11-14）。
 *
 * 它是**组件不是路由**：播放页复用现成的 bindSheet 面板机制挂载，
 * 不往 Index.ets 的 pageMap 里加名字（selfcheck 把路由名精确锁在 12 个）。
 *
 * 入参全部用基本类型 @Prop，避免 ArkTS「@Builder 按值传参」那个坑；
 * songKey 由调用方在切歌 / 每次打开时更新，@Watch 触发重新拉取，
 * 保证面板不会残留上一首歌的评论。
 *
 * 无限滚动（2026-11-14）：用工程现成的 List + onReachEnd 触底加载，
 * 去掉翻页控件。每批追加而非替换、按 id 去重；
 * 官方热评没有第二页，由数据层在热评批次后自动接续最新评论流，所以能一直往下刷。
 *
 * 失败一律显示真实原因 + 重试，不用空数组冒充成功、不缓存旧结果；
 * 追加失败只影响底部，不清空已经读到的评论。
 */
@Component
export struct CommentPanel {
  @Prop source: string = 'wy';
  @Prop songId: string = '';
  @Prop songHash: string = '';
  @Prop songName: string = '';
  @Prop songSinger: string = '';
  @Prop @Watch('onSongKeyChange') songKey: string = '';

  @StorageProp('isDark') isDark: boolean = false;
  @State hot: boolean = true;
  /** 下一批页码，从 1 开始，成功后 +1。纯内部游标，不暴露给用户 */
  @State page: number = 1;
  @State loading: boolean = false;
  @State loadingMore: boolean = false;
  @State loadMoreError: string = '';
  @State result: CommentPage = emptyCommentPage('wy');
  /** 正在请求的版本号：快速切歌 / 切排序时只认最后一次结果，防止旧响应覆盖新数据 */
  private reqSeq: number = 0;
  /** 已出现过的评论 id：热评与最新流可能有交集，追加时去重 */
  private seen: Record<string, boolean> = {};

  private p(): Palette {
    return palette(this.isDark);
  }

  aboutToAppear(): void {
    this.reload(true);
  }

  private onSongKeyChange(): void {
    this.hot = true;
    this.resetInFlight();
    this.reload(true);
  }

  /** 打断在途请求：旧响应因 reqSeq 不匹配会被丢弃，不会被并发锁挡住 */
  private resetInFlight(): void {
    this.reqSeq += 1;
    this.loading = false;
    this.loadingMore = false;
  }

  private buildSong(): SongInfo {
    const song: SongInfo = newSong(this.source);
    song.id = this.songId;
    song.hash = this.songHash;
    song.name = this.songName;
    song.singer = this.songSinger;
    return song;
  }

  private keyOf(item: CommentInfo): string {
    return item.id.length > 0 ? item.id : item.user + '_' + item.content;
  }

  /** first=true 首屏重拉；first=false 触底追加 */
  private reload(first: boolean): void {
    if (this.loading || this.loadingMore) {
      return;
    }
    this.reqSeq += 1;
    const seq: number = this.reqSeq;
    this.loadMoreError = '';
    if (first) {
      this.loading = true;
      this.page = 1;
      this.seen = {};
      this.result = emptyCommentPage(this.source);
    } else {
      this.loadingMore = true;
    }
    fetchComments(this.buildSong(), this.page, this.hot).then((r: CommentPage): void => {
      if (seq !== this.reqSeq) {
        return;
      }
      if (!r.ok) {
        if (first) {
          this.result = r;
        } else {
          this.loadMoreError = r.error.length > 0 ? r.error : '评论读取失败，请检查网络';
        }
        this.loading = false;
        this.loadingMore = false;
        return;
      }
      const merged: CommentInfo[] = first ? [] : this.result.comments.slice();
      let added: number = 0;
      for (const item of r.comments) {
        const key: string = this.keyOf(item);
        if (this.seen[key] !== true) {
          this.seen[key] = true;
          merged.push(item);
          added += 1;
        }
      }
      // 追加却一条新的都没有 → 已到流末尾，停掉，避免 onReachEnd 反复触发死循环
      if (!first && added === 0) {
        r.hasMore = false;
      }
      r.comments = merged;
      this.result = r;
      this.page = this.page + 1;
      this.loading = false;
      this.loadingMore = false;
    }).catch((): void => {
      if (seq !== this.reqSeq) {
        return;
      }
      if (first) {
        this.result = emptyCommentPage(this.source);
        this.result.error = '评论读取失败，请检查网络后重试';
      } else {
        this.loadMoreError = '评论读取失败，请检查网络';
      }
      this.loading = false;
      this.loadingMore = false;
    });
  }

  private loadMore(): void {
    if (this.loading || this.loadingMore || !this.result.ok || !this.result.hasMore) {
      return;
    }
    if (this.result.error.length > 0) {
      return;
    }
    this.reload(false);
  }

  private switchSort(hot: boolean): void {
    if (this.hot === hot) {
      return;
    }
    this.hot = hot;
    this.resetInFlight();
    this.reload(true);
  }

  @Builder
  sortChip(label: string, hot: boolean) {
    Text(label)
      .fontSize(FONT.callout)
      .fontColor(this.hot === hot ? this.p().bg : this.p().text2)
      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
      .borderRadius(RADIUS.pill)
      .backgroundColor(this.hot === hot ? this.p().primary : this.p().cardAlt)
      .onClick(() => {
        this.switchSort(hot);
      })
  }

  @Builder
  commentRow(item: CommentInfo) {
    Column({ space: 7 }) {
      Row({ space: 10 }) {
        if (item.avatar.length > 0) {
          Image(item.avatar)
            .width(30)
            .height(30)
            .borderRadius(RADIUS.pill)
            .objectFit(ImageFit.Cover)
            .backgroundColor(this.p().cardAlt)
        } else {
          SymbolGlyph($r('sys.symbol.person'))
            .fontSize(26)
            .fontColor([this.p().text3])
        }
        Column({ space: 2 }) {
          Text(item.user.length > 0 ? item.user : '匿名用户')
            .fontSize(FONT.caption)
            .fontColor(this.p().text2)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (item.timeText.length > 0) {
            Text(item.timeText)
              .fontSize(FONT.micro)
              .fontColor(this.p().text3)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Row({ space: 3 }) {
          SymbolGlyph($r('sys.symbol.heart'))
            .fontSize(12)
            .fontColor([this.p().text3])
          Text(item.likeCount.toString())
            .fontSize(FONT.micro)
            .fontColor(this.p().text3)
        }
      }
      .width('100%')

      if (item.replyTo.length > 0) {
        Text(item.replyTo)
          .fontSize(FONT.caption)
          .fontColor(this.p().text3)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .padding({ left: 10, right: 10, top: 7, bottom: 7 })
          .backgroundColor(this.p().cardAlt)
          .borderRadius(RADIUS.sm)
      }

      Text(item.content)
        .fontSize(FONT.callout)
        .fontColor(this.p().text)
        .lineHeight(20)
        .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor(this.p().card)
    .borderRadius(RADIUS.md)
  }

  @Builder
  stateView() {
    if (this.loading) {
      Column({ space: 12 }) {
        LoadingProgress().width(28).height(28).color(this.p().primary)
        Text('正在读取评论…').fontSize(FONT.caption).fontColor(this.p().text3)
      }
      .width('100%')
      .height(180)
      .justifyContent(FlexAlign.Center)
    } else if (this.result.error.length > 0) {
      Column({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
          .fontSize(30)
          .fontColor([this.p().text3])
        Text(this.result.error)
          .fontSize(FONT.caption)
          .fontColor(this.p().text2)
          .textAlign(TextAlign.Center)
          .padding({ left: 24, right: 24 })
        Text('重试')
          .fontSize(FONT.callout)
          .fontColor(this.p().primary)
          .padding({ left: 20, right: 20, top: 8, bottom: 8 })
          .borderRadius(RADIUS.pill)
          .backgroundColor(this.p().primarySoft)
          .onClick(() => {
            this.reload(true);
          })
      }
      .width('100%')
      .height(200)
      .justifyContent(FlexAlign.Center)
    } else if (this.result.comments.length === 0) {
      Column({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.text_alignleft'))
          .fontSize(30)
          .fontColor([this.p().text3])
        Text('这首歌暂时没有评论')
          .fontSize(FONT.caption)
          .fontColor(this.p().text3)
      }
      .width('100%')
      .height(180)
      .justifyContent(FlexAlign.Center)
    }
  }

  /** 列表底部：加载中 / 已到底 / 追加失败可点重试 / 兜底手动加载 */
  @Builder
  footer() {
    ListItem() {
      Column({ space: 8 }) {
        if (this.loadingMore) {
          Row({ space: 8 }) {
            LoadingProgress().width(18).height(18).color(this.p().primary)
            Text('正在加载更多…')
              .fontSize(FONT.caption)
              .fontColor(this.p().text3)
          }
          .justifyContent(FlexAlign.Center)
        } else if (this.loadMoreError.length > 0) {
          Text(this.loadMoreError)
            .fontSize(FONT.caption)
            .fontColor(this.p().primary)
            .onClick(() => {
              this.reload(false);
            })
        } else if (!this.result.hasMore) {
          Text('已经到底了 · 共 ' + this.result.comments.length.toString() + ' 条')
            .fontSize(FONT.caption)
            .fontColor(this.p().text3)
        } else {
          Text('加载更多')
            .fontSize(FONT.caption)
            .fontColor(this.p().primary)
            .onClick(() => {
              this.loadMore();
            })
        }
      }
      .width('100%')
      .height(64)
      .justifyContent(FlexAlign.Center)
    }
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text('评论')
          .fontSize(FONT.headline)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.p().text)
        Text(commentPlatformName(this.source))
          .fontSize(FONT.caption)
          .fontColor(this.p().primary)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(RADIUS.pill)
          .backgroundColor(this.p().primarySoft)
        Blank()
        if (this.result.ok && this.result.total > 0) {
          Text(this.result.total.toString() + ' 条')
            .fontSize(FONT.caption)
            .fontColor(this.p().text3)
        }
      }
      .width('100%')

      if (this.songName.length > 0) {
        Text(this.songName + (this.songSinger.length > 0 ? ' · ' + this.songSinger : ''))
          .fontSize(FONT.caption)
          .fontColor(this.p().text3)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }

      Row({ space: 10 }) {
        this.sortChip('热评', true)
        this.sortChip('最新', false)
      }
      .width('100%')

      if (this.loading || this.result.error.length > 0 || this.result.comments.length === 0) {
        this.stateView()
      } else {
        List({ space: 10 }) {
          ForEach(this.result.comments, (item: CommentInfo, index: number) => {
            ListItem() {
              this.commentRow(item)
            }
          }, (item: CommentInfo, index: number) => item.id + '_' + item.user + '_' + index.toString())
          this.footer()
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .onReachEnd(() => {
          this.loadMore();
        })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 16, bottom: 26 })
    .backgroundColor(this.p().bg)
  }
}

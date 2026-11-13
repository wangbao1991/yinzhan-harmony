import {
  palette, Palette, RADIUS, FONT, PAGE_PAD, PAGE_BOTTOM, MINI_BAR_SPACE, qualityLabel,
  glassCardBase, glassSurface, glassEdgeWidth, glassEdgeColor, glassShadow, glassRowShadow
} from '../../common/Constants';
import { DownloadTask, emptySong } from '../../common/Models';
import { App } from '../../core/App';
import { CoverRepo } from '../../core/CoverRepo';
import { TabBarHider } from '../../core/UiBar';
import { Cover, EmptyView, IconTap, PageBar, ImmersiveBar } from '../Common';

function formatSize(bytes: number): string {
  if (bytes <= 0) {
    return '0 B';
  }
  if (bytes >= 1073741824) {
    return (bytes / 1073741824).toFixed(2) + ' GB';
  }
  if (bytes >= 1048576) {
    return (bytes / 1048576).toFixed(1) + ' MB';
  }
  if (bytes >= 1024) {
    return (bytes / 1024).toFixed(0) + ' KB';
  }
  return bytes.toString() + ' B';
}

/** 任务刚被移除、ListItem 还没来得及卸载时的占位，避免空引用闪烁 */
function placeholderTask(id: string): DownloadTask {
  return {
    id: id,
    song: emptySong(),
    quality: '',
    actualQuality: '',
    format: '',
    status: 'idle',
    progress: 0,
    received: 0,
    total: 0,
    path: '',
    error: '',
    createdAt: 0
  };
}

/**
 * 单个下载任务行：自己订阅 downloadVersion，进度实时。
 *
 * 为什么必须是独立组件（而不是页面的 @Builder）：
 * - key 拼 progress → 进度一变 ListItem 重建 → 左滑删除被弹回（第一版 bug）；
 * - key 只留 id + 换新对象引用 → 真机上 ArkUI 复用 ListItem 后不再把新的
 *   task 值交给按值传参的 @Builder，行内容冻结在首次快照（进度不实时）。
 * 两条路都绕不过 ForEach 的复用机制。正解是让每一行自己订阅进度广播
 * （Downloader 约 300ms 广播一次），按稳定 id 从实时数组取「此刻」的任务，
 * 完全不依赖 ForEach 是否把新值传进来。与 Common.ets 的 SongRow 用
 * (this.dlVersion + 1) >= 0 把行挂进依赖图是同一手法。
 */
@Component
struct DownloadTaskRow {
  @Prop taskId: string = '';
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;
  /** 进度广播触发本组件重绘；读一次把 dlVersion 挂进依赖图，避免订阅被优化掉 */
  @StorageProp('downloadVersion') dlVersion: number = 0;

  private p(): Palette {
    return palette(this.isDark);
  }

  /** 按稳定 id 取实时任务；开头读一次 dlVersion 建立依赖 */
  private task(): DownloadTask {
    if ((this.dlVersion + 1) < 0) {
      return placeholderTask(this.taskId);
    }
    for (const t of App.get().downloads.list()) {
      if (t.id === this.taskId) {
        return t;
      }
    }
    return placeholderTask(this.taskId);
  }

  private statusText(t: DownloadTask): string {
    if (t.status === 'running') {
      // Downloader 已把 progress 算成 0~100 的整数百分比（received*100/total）。
      // 这里不能再乘 100，否则 45% 会显示成 4500%。
      return formatSize(t.received) + (t.total > 0 ? ' / ' + formatSize(t.total) : '') +
        ' · ' + Math.round(t.progress).toString() + '%';
    }
    if (t.status === 'waiting') {
      return '排队中';
    }
    if (t.status === 'done') {
      const actual = t.actualQuality.length > 0 ? t.actualQuality : t.quality;
      let text = '已完成 · ' + qualityLabel(actual);
      if (t.actualQuality.length > 0 && t.actualQuality !== t.quality) {
        text += '（要的是' + qualityLabel(t.quality) + '）';
      }
      if (t.format.length > 0) {
        text += ' · ' + t.format.toUpperCase();
      }
      if (t.total > 0) {
        text += ' · ' + formatSize(t.total);
      }
      return text;
    }
    if (t.status === 'failed') {
      return t.error.length > 0 ? t.error : '下载失败';
    }
    return t.status;
  }


  build() {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        Cover({ uri: this.task().song.cover, songId: CoverRepo.keyOf(this.task().song), side: 48, radius: 10 })
        if (this.task().status === 'running') {
          Stack() {
            // value 用 0~100 的百分比本身，total=100；不要再乘 100。
            Progress({ value: this.task().progress, total: 100, type: ProgressType.Ring })
              .width(30)
              .height(30)
              .color(this.p().primary)
              .style({ strokeWidth: 2.5 })
          }
          .width(48)
          .height(48)
          .borderRadius(10)
          .backgroundColor('#66000000')
        }
      }

      Column({ space: 5 }) {
        Text(this.task().song.name)
          .fontSize(FONT.body)
          .fontColor(this.p().text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.MARQUEE })
          .marqueeOptions({ start: true, loop: -1, step: 2, fromStart: true })
          .width('100%')
        // 状态行随进度实时变化，若也做跑马灯会不停重置滚动位置，保持省略号
        Text(this.statusText(this.task()))
          .fontSize(FONT.caption)
          .fontColor(this.task().status === 'failed' ? this.p().danger :
            (this.task().status === 'done' ? this.p().text3 : this.p().text2))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.task().status === 'running' && this.task().total > 0) {
          Progress({ value: this.task().received, total: this.task().total, type: ProgressType.Linear })
            .width('100%')
            .height(3)
            .color(this.p().primary)
            .backgroundColor(this.p().cardAlt)
            .borderRadius(2)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.task().status === 'done') {
        IconTap({
          icon: $r('sys.symbol.play_fill'),
          iconSize: 18,
          color: this.p().primary,
          paddingSize: 6,
          onTap: () => {
            App.get().playOne(this.task().song);
          }
        })
      } else if (this.task().status === 'failed') {
        IconTap({
          icon: $r('sys.symbol.arrow_clockwise'),
          iconSize: 17,
          color: this.p().text2,
          paddingSize: 6,
          onTap: () => {
            App.get().downloads.retry(this.taskId);
          }
        })
      } else {
        IconTap({
          icon: $r('sys.symbol.xmark'),
          iconSize: 16,
          color: this.p().text3,
          paddingSize: 6,
          onTap: () => {
            App.get().downloads.cancel(this.taskId);
          }
        })
      }
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 10, bottom: 10 })
    .borderRadius(RADIUS.md)
    // 与歌曲列表同一套玻璃行卡：留间隙 + 轻投影，任务行也浮起来
    .margin({ top: 3, bottom: 5 })
    .backgroundColor(glassCardBase(this.isDark))
    .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
    .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
    .shadow(glassRowShadow(this.isDark))
  }
}

/**
 * 下载管理：进度、重试、取消、清空，以及固定保存目录。
 *
 * 文件固定落到公共 Download/<包名>/，不需要用户选择；
 * 公共目录不可写时自动回退应用内 music/，保证一定能落盘。
 */
@Component
export struct DownloadsPage {
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;
  @StorageProp('topSafe') topSafe: number = 24;
  @StorageProp('downloadVersion') @Watch('onChanged') downloadVersion: number = 0;
  @State tasks: DownloadTask[] = [];
  @State dirName: string = '';
  @State active: number = 0;
  @State done: number = 0;
  @State totalBytes: number = 0;

  aboutToDisappear(): void {
    TabBarHider.get().reset();
  }

  aboutToAppear(): void {
    this.refresh();
  }

  onChanged(): void {
    this.refresh();
  }

  /**
   * 只维护「有哪些任务」和顶部统计；行内容不在这里传。
   *
   * 下载中每 300ms 广播一次进度。key 拼 progress 会让 ListItem 被销毁重建
   * （左滑删除被弹回）；改成只认 id 后，ArkUI 又会复用 ListItem、不再把新的
   * task 值交给按值传参的 @Builder（进度冻结在首次快照）。两条路都绕不过
   * ForEach 的复用机制，所以行内容交给 DownloadTaskRow 自己订阅广播实时读取。
   */
  private refresh(): void {
    this.tasks = App.get().downloads.list().slice();
    this.dirName = App.get().downloads.getDirName();
    this.active = App.get().downloads.activeCount();
    this.done = App.get().downloads.doneCount();
    this.totalBytes = App.get().downloads.totalBytes();
  }

  /** 左滑删除按钮要按「此刻」的状态决定文案，不能拿 ForEach 缓存的旧 task */
  private liveOf(id: string): DownloadTask | null {
    for (const t of App.get().downloads.list()) {
      if (t.id === id) {
        return t;
      }
    }
    return null;
  }

  private p(): Palette {
    return palette(this.isDark);
  }

  private deleteOne(id: string): void {
    const live = this.liveOf(id);
    const name: string = live === null ? '' : live.song.name;
    App.get().downloads.remove(id);
    App.get().toast('已删除「' + name + '」');
  }

  /** 下载中/排队中的任务被删掉时按钮写「取消并删除」；状态按实时数据判，不用旧快照 */
  private stillActive(id: string): boolean {
    const live = this.liveOf(id);
    if (live === null) {
      return false;
    }
    return live.status === 'running' || live.status === 'waiting';
  }

  @Builder
  swipeDelete(id: string) {
    Column({ space: 2 }) {
      SymbolGlyph($r('sys.symbol.trash'))
        .fontSize(17)
        .fontColor(['#FFFFFFFF'])
      Text(this.stillActive(id) ? '取消并删除' : '删除')
        .fontSize(FONT.micro)
        .fontColor('#FFFFFFFF')
    }
    .width(84)
    .height(60)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.p().danger)
    .borderRadius(12)
    .margin({ left: 8 })
    .onClick(() => {
      this.deleteOne(id);
    })
  }

  @Builder
  statCard() {
    Column({ space: 14 }) {
      Row({ space: 12 }) {
        Column({ space: 3 }) {
          Text(this.active.toString())
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.p().primary)
          Text('进行中').fontSize(FONT.micro).fontColor(this.p().text3)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Column({ space: 3 }) {
          Text(this.done.toString())
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.p().success)
          Text('已完成').fontSize(FONT.micro).fontColor(this.p().text3)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Column({ space: 3 }) {
          Text(formatSize(this.totalBytes))
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.p().text)
          Text('占用空间').fontSize(FONT.micro).fontColor(this.p().text3)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      Divider().color(this.p().line)

      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.folder')).fontSize(16).fontColor([this.p().text2])
        Column({ space: 2 }) {
          Text('保存目录')
            .fontSize(FONT.micro)
            .fontColor(this.p().text3)
          Text(this.dirName)
            .fontSize(FONT.callout)
            .fontColor(this.p().text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('检测')
          .fontSize(FONT.callout)
          .fontColor(this.p().primary)
          .padding({ left: 8, right: 4 })
          .onClick(() => {
            App.get().downloads.refreshDir().then((tip: string) => {
              this.refresh();
              App.get().toast(tip);
            });
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .borderRadius(RADIUS.lg)
    .backgroundColor(glassCardBase(this.isDark))
    .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
    .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
    .shadow(glassShadow(this.isDark, this.lightLevel))
  }

  @Builder
  // 不能叫 toolbar：API 20 起 CustomComponent 新增了通用属性 toolbar(value: CustomBuilder)，
  // 同名会被判为「方法签名与基类属性冲突」，升到 API 26 编译直接报错。
  downloadsToolbar() {
    Row({ space: 8 }) {
      Text('共 ' + this.tasks.length.toString() + ' 个任务')
        .fontSize(FONT.caption)
        .fontColor(this.p().text3)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      // v2.55：删掉「选择」入口后，多选状态机与批量删除已无触发路径，
      // 一并清理（方案 A5 推荐做法）。这一行只留清理动作，删单条仍走左滑。
      if (this.done > 0) {
        Text('清除')
          .fontSize(FONT.caption)
          .fontColor(this.p().text2)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .backgroundColor(glassCardBase(this.isDark))
          .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
          .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
          .shadow(glassShadow(this.isDark, this.lightLevel))
          .borderRadius(RADIUS.pill)
          .onClick(() => {
            App.get().downloads.clearDone();
          })
      }
      if (this.tasks.length - this.done > 0) {
        Text('清空失败')
            .fontSize(FONT.caption)
            .fontColor(this.p().text2)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .backgroundColor(glassCardBase(this.isDark))
            .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
            .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
            .shadow(glassShadow(this.isDark, this.lightLevel))
            .borderRadius(RADIUS.pill)
            .onClick(() => {
              App.get().downloads.clearFailed();
            })
        }
    }
    .width('100%')
  }


  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Top }) {
      Column({ space: 14 }) {

        this.statCard()
        this.downloadsToolbar()

        if (this.tasks.length === 0) {
          EmptyView({
            icon: $r('sys.symbol.arrow_down_circle'),
            title: '还没有下载任务',
            hint: '在歌曲菜单里点「下载到本地」，离线也能听',
            action: '',
            onAction: () => {
            }
          })
        } else {
          List() {
            // key 只认 id，ListItem 稳定复用 → 左滑展开态不会被进度刷新弹回。
            // 行内容交给 DownloadTaskRow 自己订阅 downloadVersion 实时取数，
            // 不再经 ForEach 的按值传参（那样 key 稳定后行内容会冻结）。
            ForEach(this.tasks, (task: DownloadTask, index: number) => {
              ListItem() {
                DownloadTaskRow({ taskId: task.id })
              }
              .swipeAction({
                end: {
                  builder: () => {
                    this.swipeDelete(task.id);
                  },
                  actionAreaDistance: 92
                },
                edgeEffect: SwipeEdgeEffect.Spring
              })
            }, (task: DownloadTask) => task.id)
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

        }
      }
      .width('100%')
      .height('100%')
      .padding({ left: PAGE_PAD, right: PAGE_PAD, top: this.topSafe + 52 })
      .backgroundColor(this.p().bg)

      ImmersiveBar({
        title: '下载管理',
        subtitle: this.active > 0 ? this.active.toString() + ' 个进行中' : '没有进行中的任务',
        onBack: () => {
          App.get().back();
        }
      })
      }
    }
    .hideTitleBar(true)
    // 队列浮层压在本页之上时，第一次返回只收队列，第二次才退回上一级
    .onBackPressed(() => App.get().consumeBackIfQueueOpen())
  }
}

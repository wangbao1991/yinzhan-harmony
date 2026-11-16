import {
  palette, Palette, RADIUS, FONT, PAGE_PAD, PAGE_BOTTOM, MINI_BAR_SPACE,
  glassCardBase, glassSurface, glassEdgeWidth, glassEdgeColor, glassShadow, glassRowShadow
} from '../../common/Constants';
import { DownloadTask, emptySong } from '../../common/Models';
import { App } from '../../core/App';
import { CoverRepo } from '../../core/CoverRepo';
import { Downloader } from '../../core/Downloader';
import { TabBarHider } from '../../core/UiBar';
import { Cover, EmptyView, ImmersiveBar, SelectionBar } from '../Common';

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
 * 单个下载任务行：自己订阅两类广播，进度实时但只唤醒「正在下载」的行。
 *
 * v1.0 第四次返工：改成「单击 = 暂停/开始、长按 = 进入多选」。
 * 2026-11-16：完成的任务留在这里显示「已完成」（单击播放），不再进本地音乐；
 * 行重新支持左滑删除（记录与文件一起删），长按多选照旧。
 *
 * DD 组锁死的渲染收口结构一个没动：独立行组件、ForEach 稳定 task.id key、
 * 双信号（downloadVersion 低频 / downloadProgress 高频）、只有 running 行读高频、
 * byId() O(1) 取数。队列 200+ 首时滚动依然流畅。
 */
@Component
struct DownloadTaskRow {
  @Prop taskId: string = '';
  @Prop selectMode: boolean = false;
  @Prop selected: boolean = false;
  onRowTap: () => void = (): void => {
  };
  onRowLongPress: () => void = (): void => {
  };
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;
  /** 低频：状态 / 集合变化；读一次把 dlVersion 挂进依赖图，避免订阅被优化掉 */
  @StorageProp('downloadVersion') dlVersion: number = 0;
  /** 高频：仅进度数值变化；只有 running 行在 task() 里读它并挂进依赖图 */
  @StorageProp('downloadProgress') progressVersion: number = 0;

  private p(): Palette {
    return palette(this.isDark);
  }

  /** 按稳定 id 取「此刻」的实时任务（O(1) 索引）；两类广播依赖按状态分开挂 */
  private task(): DownloadTask {
    if ((this.dlVersion + 1) < 0) {
      return placeholderTask(this.taskId);
    }
    const live: DownloadTask | null = App.get().downloads.byId(this.taskId);
    if (live === null) {
      return placeholderTask(this.taskId);
    }
    // 高频进度依赖：只有「正在下载」的行读 progressVersion 把它挂进依赖图。
    if (live.status === 'running' && (this.progressVersion + 1) < 0) {
      return placeholderTask(this.taskId);
    }
    return live;
  }

  private statusText(t: DownloadTask): string {
    if (t.status === 'running') {
      return formatSize(t.received) + (t.total > 0 ? ' / ' + formatSize(t.total) : '') +
        ' · ' + Math.round(t.progress).toString() + '%';
    }
    if (t.status === 'waiting') {
      return '排队中';
    }
    if (t.status === 'paused') {
      return '已暂停 · 点一下继续';
    }
    if (t.status === 'failed') {
      return t.error.length > 0 ? t.error : '下载失败';
    }
    if (t.status === 'done') {
      return '已完成';
    }
    // 任务刚被移除、行还没卸载时会读到占位任务（status='idle'），
    // 不要把英文状态露给用户；留一个空格保持行高，避免删除瞬间行高跳一下
    return ' ';
  }

  build() {
    Row({ space: 12 }) {
      // 多选模式下的勾选圈（纯展示，行的点击统一由外层 Row 处理）
      if (this.selectMode) {
        Row() {
          if (this.selected) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(13)
              .fontColor(['#FFFFFFFF'])
          }
        }
        .width(20)
        .height(20)
        .borderRadius(10)
        .justifyContent(FlexAlign.Center)
        .border({ width: 1.5, color: this.selected ? this.p().primary : this.p().text3 })
        .backgroundColor(this.selected ? this.p().primary : Color.Transparent)
      }

      Stack({ alignContent: Alignment.Center }) {
        Cover({ uri: this.task().song.cover, songId: CoverRepo.keyOf(this.task().song), side: 48, radius: 10 })
        if (this.task().status === 'running') {
          Stack() {
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
        Text(this.statusText(this.task()))
          .fontSize(FONT.caption)
          .fontColor(this.task().status === 'failed' ? this.p().danger : this.p().text2)
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
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 10, bottom: 10 })
    .borderRadius(RADIUS.md)
    .margin({ top: 3, bottom: 5 })
    .backgroundColor(glassCardBase(this.isDark))
    .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
    .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
    .shadow(glassRowShadow(this.isDark))
    .opacity(this.selectMode && !this.selected ? 0.72 : 1)
    .onClick(() => {
      this.onRowTap();
    })
    .gesture(
      LongPressGesture({ repeat: false, duration: 400 })
        .onAction(() => {
          this.onRowLongPress();
        })
    )
  }
}

/**
 * 下载管理（v1.0 第四次返工 + 2026-11-16 口径修正）：只管任务队列。
 *
 * - 顶部工具条：全部暂停 / 全部开始 / 清除全部任务；
 * - 长按任意行进入多选：点行单选、右上角全选/取消全选、删除所选、取消；
 * - 左滑任意行：删除任务（记录 + 已下载文件一起删）；
 * - 单击任意行：进行中/排队中 → 暂停；已暂停 → 开始；失败 → 重新入队；已完成 → 播放；
 * - 下载完成的任务保留在本页，**不再登记进「本地音乐」**（用户要求：别占本地音乐）；
 * - 统计卡片 / 保存目录 / 同时下载 / 自动下载开关已整体搬到「数据管理」二级页。
 */
@Component
export struct DownloadsPage {
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;
  @StorageProp('topSafe') topSafe: number = 24;
  @StorageProp('downloadVersion') @Watch('onChanged') downloadVersion: number = 0;
  @State tasks: DownloadTask[] = [];
  @State active: number = 0;
  @State selectMode: boolean = false;
  @State selectedIds: string[] = [];
  /** 长按手势识别后抬手，部分机型仍会补一次 onClick，记时间戳忽略掉 */
  private lastLongPressAt: number = 0;

  aboutToDisappear(): void {
    TabBarHider.get().reset();
  }

  aboutToAppear(): void {
    this.refresh();
  }

  onChanged(): void {
    this.refresh();
  }

  /** 只由低频 downloadVersion 触发；高频进度走 downloadProgress，不进这里 */
  private refresh(): void {
    this.tasks = App.get().downloads.list().slice();
    this.active = App.get().downloads.activeCount();
    // 队列到上限时下载器会自动清最旧的记录+文件，这里必须让用户看到，不能静默删
    const trimmed: number = App.get().downloads.consumeTrimNotice();
    if (trimmed > 0) {
      App.get().toast('队列上限 ' + Downloader.capacity().toString() +
        ' 条，已清理最旧的 ' + trimmed.toString() + ' 条下载');
    }
    // 出队 / 清空后把已不存在的选中项剔掉，避免「已选 N」虚高。
    // 先建 Set 再过滤，O(n) 而不是每个选中项都 findIndex 一遍（O(n²)）
    if (this.selectedIds.length > 0) {
      const alive: Set<string> = new Set<string>();
      for (const task of this.tasks) {
        alive.add(task.id);
      }
      const kept: string[] = [];
      for (const id of this.selectedIds) {
        if (alive.has(id)) {
          kept.push(id);
        }
      }
      if (kept.length !== this.selectedIds.length) {
        this.selectedIds = kept;
      }
    }
  }

  private p(): Palette {
    return palette(this.isDark);
  }

  private isSelected(id: string): boolean {
    return this.selectedIds.indexOf(id) >= 0;
  }

  /** 接近队列上限（留 20 条余量）：提示用户更早的下载会被自动清理 */
  private nearLimit(): boolean {
    return this.tasks.length >= Downloader.capacity() - 20;
  }

  /** 已完成数量统一从下载器取，页面不另维护一套口径（否则两处容易漂移） */
  private doneCount(): number {
    return App.get().downloads.doneCount();
  }

  private toggleSelect(id: string): void {
    if (this.isSelected(id)) {
      this.selectedIds = this.selectedIds.filter((item: string): boolean => item !== id);
    } else {
      this.selectedIds = this.selectedIds.concat([id]);
    }
  }

  private enterSelect(id: string): void {
    this.selectMode = true;
    this.selectedIds = [id];
  }

  private exitSelect(): void {
    this.selectMode = false;
    this.selectedIds = [];
  }

  private toggleAll(): void {
    if (this.tasks.length > 0 && this.selectedIds.length === this.tasks.length) {
      this.selectedIds = [];
      return;
    }
    const all: string[] = [];
    for (const task of this.tasks) {
      all.push(task.id);
    }
    this.selectedIds = all;
  }

  private deleteSelected(): void {
    if (this.selectedIds.length === 0) {
      return;
    }
    const ids: string[] = this.selectedIds.slice();
    const count = App.get().downloads.removeMany(ids);
    this.exitSelect();
    App.get().toast('已删除 ' + count.toString() + ' 个任务及文件');
  }

  /**
   * 左滑删除单条：记录与已下载文件一起删（下载文件不由本地音乐托管，删记录不删文件就成了孤儿）。
   * 正在下载 / 排队中的行也能滑：remove 会先取消系统任务，临时文件由 run() 收尾清掉。
   */
  private deleteOne(id: string): void {
    const task: DownloadTask | null = App.get().downloads.byId(id);
    if (task === null) {
      return;
    }
    const done: boolean = task.status === 'done';
    App.get().downloads.remove(id);
    App.get().toast(done ? '已删除任务与文件' : '已删除任务');
  }

  private onRowTap(id: string): void {
    // 长按抬手后部分机型会补一次点击，忽略掉，别把刚进入的多选又切掉
    if (Date.now() - this.lastLongPressAt < 600) {
      return;
    }
    if (this.selectMode) {
      this.toggleSelect(id);
      return;
    }
    // 已完成行：点一下直接播本地文件（文件在下载目录，播放器按 song.id 取路径）
    const task: DownloadTask | null = App.get().downloads.byId(id);
    if (task !== null && task.status === 'done') {
      App.get().playOne(task.song);
      return;
    }
    App.get().downloads.toggle(id);
  }

  private onRowLongPress(id: string): void {
    this.lastLongPressAt = Date.now();
    if (!this.selectMode) {
      this.enterSelect(id);
    } else {
      this.toggleSelect(id);
    }
  }

  @Builder
  actionButton(label: string, danger: boolean, onTap: () => void) {
    Text(label)
      .fontSize(FONT.caption)
      .fontColor(danger ? this.p().danger : this.p().text2)
      .padding({ left: 6, right: 6, top: 8, bottom: 8 })
      .backgroundColor(glassCardBase(this.isDark))
      .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
      .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
      .shadow(glassShadow(this.isDark, this.lightLevel))
      .borderRadius(RADIUS.pill)
      .textAlign(TextAlign.Center)
      .maxLines(1)
      .layoutWeight(1)
      .onClick(onTap)
  }

  /** 左滑露出的删除按钮：红色块 + 垃圾桶，与歌单详情页的删除手势保持一致 */
  @Builder
  swipeDelete(taskId: string) {
    Column({ space: 2 }) {
      SymbolGlyph($r('sys.symbol.trash'))
        .fontSize(17)
        .fontColor(['#FFFFFFFF'])
      Text('删除')
        .fontSize(FONT.micro)
        .fontColor('#FFFFFFFF')
    }
    .width(72)
    .height(68)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.p().danger)
    .borderRadius(12)
    // 与行的 margin(3/5) 对齐，红块正好盖住整行高度，不露出上下两条缝
    .margin({ left: 8, top: 3, bottom: 5 })
    .onClick(() => {
      this.deleteOne(taskId);
    })
  }

  @Builder
  // 不能叫 toolbar：API 20 起 CustomComponent 新增了通用属性 toolbar(value: CustomBuilder)，
  // 同名会被判为「方法签名与基类属性冲突」，升到 API 26 编译直接报错。
  downloadsToolbar() {
    Column({ space: 8 }) {
      Row() {
        Text('共 ' + this.tasks.length.toString() + ' 个任务 · 已完成 ' + this.doneCount().toString())
          .fontSize(FONT.caption)
          .fontColor(this.p().text3)
          .layoutWeight(1)
        if (this.nearLimit()) {
          Text('接近上限，更早的会被自动清理')
            .fontSize(FONT.micro)
            .fontColor(this.p().danger)
        }
      }
      .width('100%')

      Row({ space: 8 }) {
        this.actionButton('全部暂停', false, () => {
          App.get().downloads.pauseAll();
          App.get().toast('已全部暂停');
        })
        this.actionButton('全部开始', false, () => {
          App.get().downloads.resumeAll();
          App.get().toast('已全部开始');
        })
        this.actionButton('清除全部任务', true, () => {
          App.get().downloads.clearAll();
          this.exitSelect();
          App.get().toast('已清除全部任务（文件一并删除）');
        })
      }
      .width('100%')
    }
    .width('100%')
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Top }) {
        Column({ space: 12 }) {
          if (this.selectMode) {
            SelectionBar({
              selectedCount: this.selectedIds.length,
              totalCount: this.tasks.length,
              allSelected: this.tasks.length > 0 && this.selectedIds.length === this.tasks.length,
              secondaryLabel: '',
              busy: false,
              onCancel: (): void => {
                this.exitSelect();
              },
              onToggleAll: (): void => {
                this.toggleAll();
              },
              onSecondary: (): void => {
              },
              onConfirm: (): void => {
                this.deleteSelected();
              }
            })
          } else {
            this.downloadsToolbar()
          }

          if (this.tasks.length === 0) {
            EmptyView({
              icon: $r('sys.symbol.arrow_down_circle'),
              title: '还没有下载任务',
              action: '',
              onAction: () => {
              }
            })
          } else {
            List() {
              // key 只认 id，ListItem 稳定复用；行内容交给 DownloadTaskRow 自己订阅广播实时取数
              ForEach(this.tasks, (task: DownloadTask) => {
                ListItem() {
                  DownloadTaskRow({
                    taskId: task.id,
                    selectMode: this.selectMode,
                    selected: this.isSelected(task.id),
                    onRowTap: (): void => {
                      this.onRowTap(task.id);
                    },
                    onRowLongPress: (): void => {
                      this.onRowLongPress(task.id);
                    }
                  })
                }
                .swipeAction({
                  end: {
                    builder: () => {
                      this.swipeDelete(task.id);
                    },
                    actionAreaDistance: 80
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
    .onBackPressed((): boolean => {
      if (this.selectMode) {
        this.exitSelect();
        return true;
      }
      // 队列浮层压在本页之上时，第一次返回只收队列，第二次才退回上一级
      return App.get().consumeBackIfQueueOpen();
    })
  }
}

/**
 * BottomDock.ets —— 一级页悬浮底栏：迷你播放条 + 页签栏，随上滑连续收缩。
 *
 * ── 形态与动作来自用户提供的参考录屏逐帧核对（华为音乐）──
 *
 *   ① 展开（静止）—— 两层，播放条在上、页签栏在下，两者等宽、左右对齐：
 *      ┌────────────────────────────────────────────┐
 *      │ ◉  歌名                     ⏵   ⏭   ☰      │  播放条 40vp
 *      │    歌手                                    │
 *      ├────────────────────────────────────────────┤  间距 6vp
 *      │     🏠          🏛          ⚙              │  页签栏 46vp
 *      │    首页        发现        设置             │  三格均分、图标上文字下
 *      └────────────────────────────────────────────┘
 *
 *   ② 收缩（上滑）—— 页签栏**原地**缩成一枚圆（46vp，只留当前页签图标），
 *      播放条**下移**到同一行、宽度吃掉左边让出的部分，两者中心对齐：
 *      ┌──────┐ ┌────────────────────────────┐
 *      │  🏠  │ │ ◉  歌名        ⏵  ⏭  ☰     │
 *      └──────┘ └────────────────────────────┘
 *
 * ── 关键：连续跟手，不是「到阈值播一段动画」──
 * 位置/尺寸全部由 p（0=展开, 1=完全收起）插值算出来，p 直接取
 * core/UiBar.ets 的 TabBarHider 逐帧进度（手指每滚 1vp 就更新一次，
 * 松手后由渲染端 springMotion 弹簧吸附）。因此手指动多少它就缩多少，
 * 松手则是带粘滞感的弹性归位，中间不会跳、不会停半截。
 *
 * 页签栏内容用两套并存的图层做交叉淡入淡出：三格文字层 opacity = 1-p，
 * 单枚居中图标层 opacity = p。宽度缩到 46 时三格层已被裁掉，只剩居中图标，
 * 观感就是参考里「文字隐去、图标留在圆里」。
 */

import { palette, Palette, FONT, INK_ON_SIGNAL } from '../common/Constants';
import { SongInfo } from '../common/Models';
import { App } from '../core/App';
import { Player } from '../core/Player';
import { CoverRepo } from '../core/CoverRepo';
import { TabBarHider } from '../core/UiBar';
import { Cover, IconTap } from './Common';
import { curves } from '@kit.ArkUI';

/** 一级页签定义。 */
interface DockTab {
  label: string;
  normal: Resource;
  active: Resource;
}

const DOCK_TABS: DockTab[] = [
  { label: '首页', normal: $r('sys.symbol.house'), active: $r('sys.symbol.house_fill') },
  { label: '发现', normal: $r('sys.symbol.discover'), active: $r('sys.symbol.discover') },
  { label: '设置', normal: $r('sys.symbol.gearshape'), active: $r('sys.symbol.gearshape_fill') }
];

/** 尺寸（vp），按参考录屏 336×720 的比例定，集中在这里方便整档微调。 */
class DockSize {
  /** 播放条高度 */
  static readonly MINI_H: number = 52;
  /** 播放条封面直径 */
  static readonly COVER: number = 30;
  /** 展开态页签栏高度 */
  static readonly TAB_H: number = 52;
  /** 收缩后页签圆的直径（与播放条、页签栏三者等高，收缩态中心对齐） */
  static readonly CIRCLE: number = 52;
  /** 展开态两行间距 */
  static readonly GAP: number = 6;
  /** 收缩态圆与播放条的间距 */
  static readonly FOLD_GAP: number = 8;
  /** 页签图标字号：展开态与收缩态共用，改这一个数两边同时变 */
  static readonly ICON: number = 18;
  /** 整条左右留白 */
  static readonly SIDE: number = 26;
  /** 滚动进度除以它才到 1：滑 50vp 就收满，跟手感更紧 */
  static readonly FULL_AT: number = 0.55;
}

/**
 * BottomDock —— 放在 Index 根 Stack 里（Navigation 之外），二级页也看得见播放条。
 * 页签部分自己按 navDepth 判断：二级页只留播放条。
 */
@Component
export struct BottomDock {
  /** 点页签回调到 Index（改 this.tab → NavPager 翻页）。 */
  onChangeTab?: (index: number) => void;

  @StorageProp('isDark') isDark: boolean = false;
  /** 当前一级页（Index.switchTab 写入，横滑也会回写）。 */
  @StorageProp('tabIndex') curTab: number = 0;
  /** 滚动进度 0~1，TabBarHider 分段下发（约 40Hz），经 onProgress 补间后驱动几何。 */
  @StorageProp('tabBarProgress') @Watch('onProgress') progress: number = 0;
  /**
   * 渲染真正使用的进度。
   * 广播值是 1/40 分段跳变的，这里用 60ms 线性补间把台阶接平 ——
   * 屏幕上是连续的，但 JS 线程不再每帧重跑一遍底栏的 build 与布局。
   */
  @State pv: number = 0;
  /** 二级页栈深，>0 时只留播放条。 */
  @StorageProp('navDepth') navDepth: number = 0;
  @StorageProp('bottomSafe') bottomSafe: number = 16;
  /** 一镜到底共享元素 id（Index 只在转场瞬间写入，平时是空串）。 */
  @StorageProp('playerGeomId') geomId: string = '';

  @State song: SongInfo = App.get().player.getSong();
  @State playing: boolean = false;
  @State loading: boolean = false;
  @State hasSong: boolean = false;
  /** 实测底栏宽度，用于本地算尺寸（不再依赖系统分配，永不溢出）。 */
  @State dockW: number = 336;

  private player: Player = App.get().player;
  private listener: () => void = (): void => {
  };

  aboutToAppear(): void {
    this.listener = (): void => {
      // 播放中 timeUpdate 每秒会走十次 notify，下面几行都是「同值赋值」，
      // ArkUI 判等后不会重绘；但 AppStorage 写入没有这层豁免，值没变就别碰。
      this.song = this.player.getSong();
      this.playing = this.player.isPlaying();
      this.loading = this.player.isLoading();
      const had: boolean = this.hasSong;
      this.hasSong = this.player.hasSong();
      if (had !== this.hasSong) {
        AppStorage.setOrCreate('hasSong', this.hasSong);
      }
    };
    this.player.onChange(this.listener);
    this.listener();
  }

  aboutToDisappear(): void {
    this.player.offChange(this.listener);
  }

  private p(): Palette {
    return palette(this.isDark);
  }

  /**
   * 把分段广播接成连续画面 —— 用可中断弹簧，不用补间。
   *
   * 广播端（TabBarHider）按 40Hz + 1/40 分段下发；这里每个新终点都起一段
   * springMotion：弹簧从当前值与当前速度出发平滑重定目标，段与段之间
   * 速度连续，屏幕上是「一根连续的弹性运动」，而不是一段段线性台阶。
   * 插值在渲染线程按原生帧率跑（120Hz 屏就是 120 帧过渡），JS 侧只在
   * 广播到达时重定一次目标 —— 这同时就是流畅优化的主削减项。
   *
   * 弹簧参数：response 0.24（跟手，不拖泥带水）、damping 0.86（临界附近，
   * 收尾带一丝粘滞感但不明显过冲；几何端 t() 本来就钳在 0~1，过冲无害）。
   *
   * 只有「复位」直接到位：目标归零且当前确实处在收起态（切页、进出二级页、
   * 点圆展开）。这种场景要的是干脆，弹簧反而会看到底栏「慢慢荡回去」。
   */
  onProgress(): void {
    const target: number = this.progress;
    if (Math.abs(target - this.pv) <= 0.0001) {
      return;
    }
    if (target <= 0.001 && this.pv > 0.2) {
      this.pv = 0;
      return;
    }
    animateTo({ curve: curves.springMotion(0.24, 0.86) }, (): void => {
      this.pv = target;
    });
  }

  /** 收缩插值参数：0=完全展开, 1=完全收起。二级页/无歌时恒为 0。 */
  private t(): number {
    if (!this.hasSong || this.navDepth > 0) {
      return 0;
    }
    return Math.min(1, Math.max(0, this.pv / DockSize.FULL_AT));
  }

  /**
   * 三格文字层的可见度：t≤0.45 线性淡出到 0。
   * 与 circleOpacity 的区间（0.55 起）完全不重叠，任何一帧都只有一层图标在场，
   * 不会出现「首页格的房子 + 居中的房子」两个图标同时挂在屏幕上的情况。
   */
  private gridOpacity(): number {
    const t: number = this.t();
    return t >= 0.45 ? 0 : 1 - t / 0.45;
  }

  /** 收缩圆里那枚图标的可见度：t 过 0.55 才淡入。 */
  private circleOpacity(): number {
    const t: number = this.t();
    return t <= 0.55 ? 0 : Math.min(1, (t - 0.55) / 0.45);
  }

  /**
   * 播放条专用的滞后参数：页签栏先收窄到小圆，播放条再滑下来并排。
   * 两个动作错开时序，重叠窗口只有几十毫秒；重叠时页签栏在下移的播放条之上，
   * 观感是「播放条从页签栏背后滑下来」，而不是两块硬挤在一起。
   */
  private tm(): number {
    return Math.max(0, Math.min(1, (this.t() - 0.2) / 0.8));
  }

  /** 可用宽度（已扣左右留白）。 */
  private innerW(): number {
    return Math.max(120, this.dockW - DockSize.SIDE * 2);
  }

  /** 页签栏宽度：展开态整宽 → 收缩成一枚圆。 */
  private tabW(): number {
    const w: number = this.innerW();
    const t: number = this.t();
    return w - (w - DockSize.CIRCLE) * t;
  }

  /** 页签栏纵向位置：展开在第二行，收缩后仍在最底（圆贴底）。 */
  private tabY(): number {
    if (this.navDepth > 0) {
      return 0;
    }
    if (!this.hasSong) {
      return 0;
    }
    return DockSize.MINI_H + DockSize.GAP;
  }

  /** 播放条纵向位置：0 → 与圆中心对齐（下移）。用滞后参数 tm。 */
  private miniY(): number {
    const tm: number = this.tm();
    const aligned: number = DockSize.MINI_H + DockSize.GAP + (DockSize.TAB_H - DockSize.MINI_H) / 2;
    return aligned * tm;
  }

  /** 播放条横向位置：0 → 让出圆 + 间距。 */
  private miniX(): number {
    const tm: number = this.tm();
    return DockSize.SIDE + (DockSize.CIRCLE + DockSize.FOLD_GAP) * tm;
  }

  /** 播放条宽度：整宽 → 吃掉圆让出的部分。 */
  private miniW(): number {
    const tm: number = this.tm();
    return this.innerW() - (DockSize.CIRCLE + DockSize.FOLD_GAP) * tm;
  }

  /** 底栏整块高度（固定，不随收缩变化，避免滚动时页面高度抖动）。 */
  private dockH(): number {
    if (this.navDepth > 0) {
      return this.hasSong ? DockSize.MINI_H : 0;
    }
    if (!this.hasSong) {
      return DockSize.TAB_H;
    }
    return DockSize.MINI_H + DockSize.GAP + DockSize.TAB_H;
  }

  /** 点收缩态里的圆：展回展开态（复位滚动进度，否则下一帧又被压回去）。 */
  private expandDock(): void {
    TabBarHider.get().reset();
  }

  private enterPlayer(): void {
    if (this.hasSong) {
      App.get().openPlayer();
    }
  }

  /**
   * 底栏表面（v1.3.0 起定版：实色，无模糊、无流光）。
   *
   * 历史上这里是「液态玻璃」：半透明底 + backgroundEffect 实时背景模糊 +
   * 跟手流光 + 按压充能。模糊采样的是「组件背后」的内容，底栏背后正是
   * 滚动中的列表 —— 每一帧都在变，实时模糊每帧重算，是全应用最大的
   * 掉帧源；流光还要再叠加逐帧渐变与横滑坐标广播。用户最终拍板：
   * 毛玻璃与流光整体去掉，流畅优先。
   *
   * 现在只剩三层纯静态绘制，滚动期间零重算：
   *   ① 实色底：深色 78% 石墨、浅色 90% 微暖近白（#F6F4EE 贴米色页面，
   *      纯白会变成一条 253 的白板，截图实测过）；
   *   ② 150° 斜向受光渐变：固定角度，顶缘一条亮线 + 底缘一点内阴影，
   *      给栏体体积感，角度不随任何状态变化；
   *   ③ 0.5vp 发丝边。
   */
  @Builder
  dockGlass(radius: number) {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .borderRadius(radius)
        .backgroundColor(this.isDark ? '#C71A1D24' : '#E6F6F4EE')
      Column()
        .width('100%')
        .height('100%')
        .borderRadius(radius)
        .linearGradient({
          angle: 150,
          colors: [
            // 顶缘高光：玻璃上沿要有一条亮线，弯起来才有球面感
            [dockAlpha('#FFFFFFFF', 0.46), 0],
            [dockAlpha('#FFFFFFFF', 0.12), 0.24],
            ['#00FFFFFF', 0.56],
            // 底缘内阴影：给栏体一点厚度，不然浮在内容上像贴纸
            [dockAlpha('#000000', this.isDark ? 0.12 : 0.05), 1]
          ]
        })
      Column()
        .width('100%')
        .height('100%')
        .borderRadius(radius)
        .border({ width: 0.5, color: dockAlpha(this.p().glassBorder, 0.55) })
    }
    .width('100%')
    .height('100%')
    // 背景层，别吃触摸
    .hitTestBehavior(HitTestMode.None)
  }

  // ── 页签栏 ──

  @Builder
  tabItem(item: DockTab, index: number) {
    Column({ space: 3 }) {
      SymbolGlyph(this.curTab === index ? item.active : item.normal)
        .fontSize(DockSize.ICON)
        .fontColor([this.curTab === index ? this.p().primary : this.p().text2])
      Text(item.label)
        .fontSize(10)
        .fontWeight(this.curTab === index ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.curTab === index ? this.p().primary : this.p().text2)
        .maxLines(1)
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .onClick((): void => {
      // 收缩态：三格已经被裁成只剩左边一枚圆，此时点它应该是「展开」，
      // 不是「切首页」。三格层 opacity 归零后**依然可命中**（ArkUI 的
      // opacity 不影响 hitTest），所以收缩态点在圆上会先落到第一格上 ——
      // 这里按进度分流，把命中接住转成展开。
      if (this.t() >= 0.42) {
        this.expandDock();
      } else if (this.onChangeTab && index !== this.curTab) {
        this.onChangeTab(index);
      }
    })
  }

  /**
   * 页签栏本体：宽度/圆角随 p 插值，内部两套图层交叉淡入。
   * 宽格式（三格文字）永远是整宽布局，靠外层 clip 裁切，所以收缩过程中
   * 不会出现「三格被压缩变形」的怪异画面，只是右侧被裁 + 整体淡出。
   */
  @Builder
  tabBar() {
    Stack({ alignContent: Alignment.Start }) {
      this.dockGlass(DockSize.TAB_H / 2 - 0.5)
      // 收缩时整块染成选中色：参考里收完之后是一枚橙色实心圆
      Column()
        .width('100%')
        .height('100%')
        .borderRadius(DockSize.TAB_H / 2 - 0.5)
        .backgroundColor(this.p().primary)
        .opacity(this.circleOpacity())
        .hitTestBehavior(HitTestMode.None)

      // 三格文字层：宽度锁定整宽，不随父容器收窄而挤压
      Row() {
        ForEach(DOCK_TABS, (item: DockTab, index: number) => {
          this.tabItem(item, index)
        }, (item: DockTab, index: number) => item.label)
      }
      .width(this.innerW())
      .height('100%')
      // 只在前半程可见：t≤0.45 时线性淡出，和下面的圆层完全不重叠
      .opacity(this.gridOpacity())

      // 收缩层：只留当前页签图标，居中
      Stack() {
        SymbolGlyph(DOCK_TABS[this.curTab].active)
          // 和展开态三格用同一个常量，收缩前后图标尺寸严格一致
          .fontSize(DockSize.ICON)
          .fontColor([INK_ON_SIGNAL])
      }
      .width('100%')
      .height('100%')
      // 只在后半程可见，避免和三格层同时出现（那会出现两个房子图标）
      .opacity(this.circleOpacity())
      // opacity 0 的容器在 ArkUI 里依然会命中：它压在三格 Row 上面，
      // 不设 None 的话三个页签永远点不动。
      .hitTestBehavior(HitTestMode.None)
    }
    .width(this.tabW())
    .height(DockSize.TAB_H)
    // 容器自身也要圆角：收缩到 44 宽时，clip 若按矩形裁，四个角会露出方块
    .borderRadius(DockSize.TAB_H / 2 - 0.5)
    .position({ x: DockSize.SIDE, y: this.tabY() })
    .clip(true)
    .onClick((): void => {
      if (this.t() > 0.5) {
        this.expandDock();
      }
    })
  }

  /**
   * 页签的命中层（不可见）。
   *
   * 为什么需要它：页签栏的视觉宽度会随收缩进度变窄，外层带 clip，
   * 一旦 t 稍微大于 0（滚动后尚未吸附回位的那一两百毫秒），
   * 右侧格子和中间格子的一部分已被裁掉 —— 裁掉的部分不响应触摸，
   * 于是「发现」会偶发点不中。
   *
   * 这层宽度恒为 innerW、不带 clip、只做 onClick，三个格子均分整宽。
   * opacity 0 的容器在 ArkUI 里照样能命中，所以视觉上一个像素都不多。
   */
  @Builder
  tabHit() {
    Row() {
      ForEach(DOCK_TABS, (item: DockTab, index: number) => {
        Column()
          .layoutWeight(1)
          .height('100%')
          .onClick((): void => {
            if (this.onChangeTab && index !== this.curTab) {
              this.onChangeTab(index);
            }
          })
      }, (item: DockTab, index: number) => 'hit_' + item.label)
    }
    .width(this.innerW())
    .height(DockSize.TAB_H)
    .position({ x: DockSize.SIDE, y: this.tabY() })
    .opacity(0)
    // 这层由调用方按进度**条件挂载**（见 build），命中开关不做动态切换。
    // 曾经写过「常驻挂载 + hitTestBehavior(t<0.5 ? Default : None)」，以为只是
    // 切一个纯属性、不建节点；实际 hitTestBehavior 在组件创建后**不随状态重算**，
    // 于是这一层在收缩态继续铺满整行吃掉点击 —— 点收缩后的播放条，事件落到
    // 三格命中层上，直接切到了「发现/设置」。这就是 v1.3.0/92 的真机回归。
  }

  // ── 播放条 ──

  /** 播放条内部：封面 + 歌名/歌手 + 播放/下一首/队列。 */
  @Builder
  miniInner() {
    Row({ space: 8 }) {
      Stack() {
        Cover({
          uri: this.song.cover,
          songId: CoverRepo.keyOf(this.song),
          side: DockSize.COVER,
          radius: DockSize.COVER / 2
        })
      }
      .width(DockSize.COVER)
      .height(DockSize.COVER)
      .clip(true)
      .borderRadius(DockSize.COVER / 2)

      /**
       * 歌名/歌手双行区。收起态（tm≥0.5，滚动中的瞬时形态）行为反转：
       * 歌手行隐藏、歌名放开两行并居中 —— 收起时横向被三键让出的宽度所限，
       * 单行只剩 3~4 个字，两行才是这 52vp 里信息量的正确用法。
       * 用 visibility/justifyContent 纯属性切换，不增删节点（滚动中 if 增删
       * 节点会顶一次布局，tabHit 那次「收到底顿一下」就是前车之鉴）。
       */
      Column({ space: 1 }) {
        Text(this.song.name.length > 0 ? this.song.name : '暂无播放')
          .fontSize(FONT.callout - 2)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.p().text)
          .maxLines(this.tm() >= 0.5 ? 2 : 1)
          .textAlign(this.tm() >= 0.5 ? TextAlign.Center : TextAlign.Start)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.song.singer.length > 0 ? this.song.singer : '选一首歌开始')
          .fontSize(FONT.micro)
          .fontColor(this.p().text3)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .visibility(this.tm() >= 0.5 ? Visibility.None : Visibility.Visible)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .justifyContent(this.tm() >= 0.5 ? FlexAlign.Center : FlexAlign.Start)

      // 三个键之间的间距＝命中区能不能分开：
      // IconTap 的 responseRegion 固定 48vp（见 Common.ets），热区**不受视觉尺寸约束**。
      // 以前 space 只有 2，而 20/16 图标的视觉盒是 32/28，两个 48 的热区互相压进去 18vp，
      // 点在「暂停」右半边会落到「下一首」上 —— 这就是误触的来源，不是错觉。
      //
      // 三枚图标统一 18vp（视觉盒 30＝18+6×2），热区收到 44（每侧外扩 7），缝给 14：
      //   暂停 [-7,37] ｜ 下一首 [37,81] ｜ 队列 [81,125]，两两相切，不重叠一点。
      // 尺寸必须统一：以前播放 20、后面两个 16，三个键一样重，只有播放看着大一号。
      Row({ space: 14 }) {
        if (this.loading) {
          LoadingProgress().width(18).height(18).color(this.p().text2)
        } else {
          IconTap({
            icon: this.playing ? $r('sys.symbol.pause') : $r('sys.symbol.play_fill'),
            iconSize: 18,
            color: this.p().text,
            paddingSize: 6,
            minHit: 44,
            label: this.playing ? '暂停' : '播放',
            onTap: (): void => {
              this.player.toggle();
            }
          })
        }
        IconTap({
          icon: $r('sys.symbol.forward_end_fill'),
          iconSize: 18,
          color: this.p().text,
          paddingSize: 6,
          minHit: 44,
          label: '下一首',
          onTap: (): void => {
            this.player.next();
          }
        })
        IconTap({
          icon: $r('sys.symbol.list_bullet'),
          iconSize: 18,
          color: this.p().text,
          paddingSize: 6,
          minHit: 44,
          label: '播放队列',
          onTap: (): void => App.get().openQueue()
        })
      }
    }
    .width('100%')
    .height('100%')
    // 右边由 8 加到 10：整组再往左让 2vp，离屏幕右缘（系统侧滑返回手势区）远一点
    .padding({ left: 6, right: 10 })
  }

  /**
   * 播放条本体：位置与宽度随 p 插值，从「独占整行」连续滑到「圆右边」。
   * 不挂 .animation，进度每帧来一次就重排一次，手指跟到哪缩到哪。
   */
  @Builder
  miniBar() {
    Stack({ alignContent: Alignment.TopStart }) {
      this.dockGlass(DockSize.MINI_H / 2 - 0.5)
      this.miniInner()
    }
    .width(this.miniW())
    .height(DockSize.MINI_H)
    .borderRadius(DockSize.MINI_H / 2 - 0.5)
    // 位移必须用 position —— 不要为了省重排换成 translate。
    // translate 是**图形变换**：只改绘制矩阵，命中测试仍按布局矩形走。收缩后
    // 播放条视觉上滑到页签圆右边，热区却还留在展开态那一行，表现就是
    // 「收缩态下三个键点了完全没反应」（v1.3.0 / 91 真机回归，上一版用
    // translate 替 position 省重排时引入）。position 参与布局，视觉与热区一致。
    // 这里每帧重排的范围只有底栏这一个 Stack（两个子节点），成本可忽略。
    .position({ x: this.miniX(), y: this.miniY() })
    // 不再 clip：内容按容器宽度布局，本来就不溢出；少一层裁剪就少一次离屏层重建
    // 一镜到底的小形态：与全屏播放页共用同一个 id。
    .geometryTransition(this.geomId)
    .onClick((): void => this.enterPlayer())
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.navDepth > 0) {
        // 二级页：没有页签栏，播放条独占整行
        if (this.hasSong) {
          Column() {
            this.miniBar()
          }
          .width('100%')
          .height(DockSize.MINI_H)
        }
      } else {
        // 先画播放条、后画页签栏：收缩过程中播放条会从页签栏背后滑下来，
        // 页签栏压在上层，画面不会出现两块硬挤在一起的毛刺。
        if (this.hasSong) {
          this.miniBar()
        }
        this.tabBar()
        // 命中层只在前半程挂载：三格在 t=0.45 已淡出，0.42 之后整层拆掉。
        // 拆（不是新建）发生在内容不可见之后，滚动里看不出顿挫；而「常驻 + 动态
        // 切 hitTestBehavior」会把收缩态的整行点击全吞掉（hitTestBehavior 不随
        // 状态重算），这是踩过的坑，别再合并回一行。
        if (this.t() < 0.42) {
          this.tabHit()
        }
      }
    }
    .width('100%')
    .height(this.dockH())
    .margin({ bottom: this.bottomSafe + 6 })
    // 实测宽度：屏幕宽度变化（折叠屏/旋转）时重新算，尺寸始终不溢出
    .onAreaChange((_old: Area, now: Area): void => {
      const w: number = Number(now.width);
      if (w > 0 && Math.abs(w - this.dockW) > 0.5) {
        this.dockW = w;
      }
    })
  }
}

/** 给 #RRGGBB / #AARRGGBB 色值换一个透明度，返回 #AARRGGBB。 */
function dockAlpha(hex: string, alpha: number): string {
  const a: number = Math.max(0, Math.min(255, Math.round(alpha * 255)));
  const h: string = hex.replace('#', '');
  const rgb: string = h.length === 8 ? h.substring(2) : h;
  return `#${a.toString(16).padStart(2, '0').toUpperCase()}${rgb.toUpperCase()}`;
}

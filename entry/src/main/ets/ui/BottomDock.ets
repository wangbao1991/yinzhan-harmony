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
 * 位置/尺寸全部由 p（0=展开, 1=完全收起）线性插值算出来，p 直接取
 * core/UiBar.ets 的 TabBarHider 逐帧进度（手指每滚 1vp 就更新一次，
 * 松手 180ms 吸附）。因此手指动多少它就缩多少，中间不会跳、不会停半截。
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
  /** 跟手流光的横向范围（一根窄光柱，约两个格子的宽度） */
  static readonly GLOW_W: number = 136;
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
  /** 滚动进度 0~1，TabBarHider 逐帧写入，直接当作收缩插值参数。 */
  @StorageProp('tabBarProgress') progress: number = 0;
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
  /** 横滑时手指的屏幕横坐标（Index 的 PanGesture 广播进来）。 */
  @StorageProp('swipeX') swipeX: number = -1;
  /** 1=手指在横滑，0=松手/未滑。 */
  @StorageProp('swipeOn') @Watch('onSwipeState') swipeOn: number = 0;
  /**
   * 按压深度 0..1。
   * 不是简单的开关：按下后它会在 260ms 内逐渐「充能」到 1，
   * 所以按住不放会越来越亮，快速扫过只来得及亮一半 —— 手指按得越实，光越深。
   */
  @State press: number = 0;
  /** 充能定时器 */
  private pressTimer: number = -1;

  private player: Player = App.get().player;
  private listener: () => void = (): void => {
  };

  aboutToAppear(): void {
    this.listener = (): void => {
      this.song = this.player.getSong();
      this.playing = this.player.isPlaying();
      this.loading = this.player.isLoading();
      this.hasSong = this.player.hasSong();
      AppStorage.setOrCreate('hasSong', this.hasSong);
    };
    this.player.onChange(this.listener);
    this.listener();
  }

  aboutToDisappear(): void {
    this.player.offChange(this.listener);
    this.stopPressTimer();
  }

  private p(): Palette {
    return palette(this.isDark);
  }

  /** 收缩插值参数：0=完全展开, 1=完全收起。二级页/无歌时恒为 0。 */
  private t(): number {
    if (!this.hasSong || this.navDepth > 0) {
      return 0;
    }
    return Math.min(1, Math.max(0, this.progress / DockSize.FULL_AT));
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

  /**
   * 横滑开始/结束：淡入 90ms，淡出 200ms。
   * 只动 opacity，不动位置 —— 位置每帧由 swipeX 直接算，不能带补间。
   */
  onSwipeState(): void {
    if (this.swipeOn > 0.5) {
      this.risePress();
    } else {
      this.fallPress();
    }
  }

  /**
   * 按压充能：按下瞬间先亮 55%，之后每 16ms 加一档，300ms 充到 1。
   * 快速扫过（比如 120ms）停在 0.73，光是偏薄的；
   * 按住慢慢拖，光就一路亮到最实、也张得最开。这就是「感应按压状态」。
   */
  private risePress(): void {
    if (this.pressTimer >= 0) {
      return;
    }
    // 按下瞬间先给 55%，保证轻扫也看得见；剩下的 45% 靠按住慢慢充
    this.press = Math.max(this.press, 0.55);
    this.pressTimer = setInterval((): void => {
      const next: number = Math.min(1, this.press + 16 / 300);
      this.press = next;
      if (next >= 1) {
        this.stopPressTimer();
      }
    }, 16);
  }

  /** 松手：200ms 内回落到 0，光同时淡出。 */
  private fallPress(): void {
    this.stopPressTimer();
    animateTo({ duration: 200, curve: Curve.Linear }, (): void => {
      this.press = 0;
    });
  }

  private stopPressTimer(): void {
    if (this.pressTimer >= 0) {
      clearInterval(this.pressTimer);
      this.pressTimer = -1;
    }
  }

  /** 光柱此刻的实际宽度：按得越实，光晕越散。 */
  private glowW(): number {
    return DockSize.GLOW_W * (0.86 + 0.22 * this.press);
  }

  /**
   * 高光带左边界（相对所在卡片）。
   * 直接取手指横坐标减半宽，没有任何平滑：手指在哪，光带中心就在哪。
   */
  private glowX(barLeft: number, barW: number): number {
    const raw: number = this.swipeX >= 0 ? this.swipeX : this.dockW / 2;
    // 手指超出底栏范围时把中心钳在两头，玻璃柱贴着边停下，不会整段跑出去
    const x: number = Math.max(barLeft, Math.min(barLeft + barW, raw));
    return x - barLeft - this.glowW() / 2;
  }

  /**
   * 受光面偏转角：手指在左半边时玻璃的高光面往左倒，右边往右倒。
   * 滑动时整条玻璃的受光方向跟着手指走，是「材质在动」而不是「图层在动」。
   */
  private glowTilt(): number {
    if (this.swipeOn <= 0.5) {
      return 0;
    }
    const c: number = this.dockW / 2;
    const k: number = Math.max(-1, Math.min(1, (this.swipeX - c) / Math.max(1, c)));
    return 10 * k;
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
   * 底栏玻璃（专用，比全局 HdsGlass 更透、光更强）。
   *
   * 「流光」靠两件事叠出来：
   *   ① 底色只留 20%~30% 不透明 + 背景模糊 —— 背后内容（专辑封面、图片）
   *      的颜色会透上来，页面一滚，底栏里的颜色就跟着流动；
   *   ② 150° 斜向受光面，角度随收缩进度转 30° —— 收缩那道手术刀式的变形里，
   *      高光会顺着胶囊扫过去，不是一张死贴图。
   *
   * 液态磨砂（v1.2.0 材质迭代）：把底色从 60% 降到 30%，模糊改由 backgroundEffect 承担，
   * 顺带把背后颜色的饱和度拉高（saturation）、整体微提亮（brightness），再用
   * adaptiveColor 取背后平均色 —— 这才是「玻璃」而不是「半透明塑料」的观感。
   * 通透版再降一档到 20%/30%，兜底 blurStyle 从 ULTRA_THICK 降到 REGULAR/THIN：
   * 系统材质本身带底色，两层叠着就会发闷，之前「看着还实」就是这个原因。
   * 旧 backgroundBlurStyle 保留作为兜底：两条路径任一失效，栏体依然是磨砂而非实色。
   */
  @Builder
  dockGlass(radius: number) {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .borderRadius(radius)
        // 20% / 30%：再透一档。60% → 30% → 现在，底色只负责「压一点点黑」，
        // 明暗几乎全交给背后内容和模糊，这才是玻璃；再高就又回到半透明塑料。
        .backgroundColor(this.isDark ? '#331A1D24' : '#4DFBFBFB')
        // 兜底材质必须同步降档：ULTRA_THICK/THICK 自带一层不透明底色，
        // 和上面的 backgroundEffect 一叠就会「实」，这是之前发闷的主因之一。
        .backgroundBlurStyle(this.isDark ? BlurStyle.COMPONENT_REGULAR : BlurStyle.COMPONENT_THIN)
        // 液态磨砂核心：大半径模糊 + 饱和度提升 + 微提亮 + 取背后平均色
        .backgroundEffect({
          radius: 30,
          saturation: this.isDark ? 1.9 : 1.6,
          // 透上去之后整体会略微发灰，提亮补回来一点，避免「脏」而不是「清」
          brightness: this.isDark ? 1.10 : 1.07,
          color: this.isDark ? '#0AFFFFFF' : '#00FFFFFF',
          adaptiveColor: AdaptiveColor.AVERAGE
        })
      Column()
        .width('100%')
        .height('100%')
        .borderRadius(radius)
        .linearGradient({
          // 基础 150°，收缩时再转 30°；横滑时按手指左右再偏 ±18°
          angle: 150 - 30 * this.t() + this.glowTilt(),
          colors: [
            // 顶缘高光更锐一档：玻璃上沿要有一条亮线，弯起来才有球面感
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
    // 玻璃只是背景，别吃触摸
    .hitTestBehavior(HitTestMode.None)
  }

  /**
   * 跟手流光。
   *
   * 形态是照参考录屏的像素量出来的，不是凭感觉：
   *   玻璃底色 RGB(41,44,45)，流光峰值 RGB(188,188,188) ≈ 69% 白；
   *   横向半宽只有 20vp 左右就衰减到 18%，纵向从栏顶到栏底几乎不衰减。
   * 也就是说它是一根「竖向光柱」——窄、亮、顶满整条玻璃，不是横向的柔光带。
   *
   * 所以这里只做一个横向渐变，纵向恒定：
   *   · 组件高度就是 100%，永远在框内，不存在超出被裁出现硬边的问题；
   *   · 纵向不衰减，光柱上下自然被页签栏的胶囊边缘切住，正是参考里的样子；
   *   · 峰值 66% 白，中心再收窄一档，让中间有「芯」，边缘快速消失。
   */
  @Builder
  glowLayer(barLeft: number, barW: number) {
    Column()
      .width(this.glowW())
      .height('100%')
      .linearGradient({
        angle: 90,
        colors: [
          // 比之前更散：尾部拖到 ±68vp 才归零，20vp 处还有 30%（原来 18%）
          ['#00FFFFFF', 0],
          ['#03FFFFFF', 0.0588],
          ['#0DFFFFFF', 0.1691],
          ['#24FFFFFF', 0.2794],
          ['#4DFFFFFF', 0.353],
          ['#99FFFFFF', 0.4265],
          ['#B0FFFFFF', 0.5],
          ['#99FFFFFF', 0.5735],
          ['#4DFFFFFF', 0.647],
          ['#24FFFFFF', 0.7206],
          ['#0DFFFFFF', 0.8309],
          ['#03FFFFFF', 0.9412],
          ['#00FFFFFF', 1]
        ]
      })
      .position({ x: this.glowX(barLeft, barW), y: 0 })
      // 亮度就是按压深度：轻扫只亮三成，按住不放会一路亮到最实
      .opacity(this.press)
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
      if (this.onChangeTab && index !== this.curTab) {
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
      // 高光带叠在玻璃上（收缩成橙色圆时也会被玻璃/橙色挡住一部分，属正常）
      this.glowLayer(DockSize.SIDE, this.tabW())
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

      Column({ space: 1 }) {
        Text(this.song.name.length > 0 ? this.song.name : '暂无播放')
          .fontSize(FONT.callout - 2)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.p().text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.song.singer.length > 0 ? this.song.singer : '选一首歌开始')
          .fontSize(FONT.micro)
          .fontColor(this.p().text3)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Row({ space: 2 }) {
        if (this.loading) {
          LoadingProgress().width(20).height(20).color(this.p().text2)
        } else {
          IconTap({
            icon: this.playing ? $r('sys.symbol.pause') : $r('sys.symbol.play_fill'),
            iconSize: 20,
            color: this.p().text,
            paddingSize: 6,
            label: this.playing ? '暂停' : '播放',
            onTap: (): void => {
              this.player.toggle();
            }
          })
        }
        IconTap({
          icon: $r('sys.symbol.forward_end_fill'),
          iconSize: 16,
          color: this.p().text,
          paddingSize: 6,
          label: '下一首',
          onTap: (): void => {
            this.player.next();
          }
        })
        IconTap({
          icon: $r('sys.symbol.list_bullet'),
          iconSize: 16,
          color: this.p().text,
          paddingSize: 6,
          label: '播放队列',
          onTap: (): void => App.get().openQueue()
        })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 6, right: 8 })
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
    .position({ x: this.miniX(), y: this.miniY() })
    .clip(true)
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
        // 命中层压在视觉层之上：展开态三个页签一定点得中
        if (this.t() < 0.5) {
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

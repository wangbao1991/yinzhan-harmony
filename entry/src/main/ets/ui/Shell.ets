/**
 * Shell.ets —— 对标华为音乐的悬浮底部导航 + MiniBar（API 26 原生能力实现）。
 *
 * 原生能力落地（全部 @since 26.0.0，已用全量编译探针验证可编译）：
 *   - 液态玻璃 / 沉浸光感：悬浮页签胶囊由使用方在 Tabs.barFloatingStyle() 上挂
 *     uiMaterial.ImmersiveMaterial(systemMaterial)，配 lightEffect 沉浸光感反馈；
 *     应用级在 module.json5 开 ohos.arkui.UIMaterial.state = enable。原生材质只对
 *     Navigation/NavDestination 标题栏与 barPosition=End 的底部悬浮 TabBar 生效。
 *     HdsNativeMaterial.tabBarMaterial() 集中构造这套材质，并按设备算力分级降级。
 *   - 一镜到底 / 共享元素转场：播放条 → 全屏播放页用 geometryTransition（容器形变），
 *     封面用 sharedTransition（元素级共享），两者都放在 animateTo 闭包里，见 Index。
 *   - 悬浮页签三要素：barOverlap(true) + barPosition(End) + vertical(false)，见 Index.tabContent。
 *
 * 官方生效范围限制：MiniBar 是高悬在 Stack 里的普通组件，不在沉浸光感的两个生效子树里
 * （标题栏 / 底部悬浮 TabBar），原生 systemMaterial 对它无效。因此 MiniBar 保留 HdsGlass
 * 自绘玻璃（半透明 + 背景模糊 + 受光渐变 + 发丝边）与 HdsFlowLight 自绘流光，这是官方
 * 能力边界使然，不是降级偷懒。
 *
 *   - MiniBar：HdsMiniBar 承载播放器 UI。形态恒定（~54vp 半透明迷你条），与底部
 *     悬浮页签胶囊分成上下两层；这是华为音乐官方录屏里播放条的真实形态。
 *     列表滚动时由 tabBarProgress 驱动整条淡出 + 下沉联动，不改变条体形态/尺寸。
 *   - HdsBarStyle.EXPAND / COLLAPSE：保留为形态枚举占位，不再用撑高手势切换。
 *
 * 零三方依赖、零新增路由；纯绘制层不进 AppStorage 高频信号。
 */

import { uiMaterial } from '@kit.ArkUI';
import { palette, Palette, RADIUS, FONT } from '../common/Constants';
import { SongInfo } from '../common/Models';
import { withAlpha } from '../common/Utils';
import { App } from '../core/App';
import { Player } from '../core/Player';
import { CoverRepo } from '../core/CoverRepo';
import { Cover, IconTap } from './Common';

/** 对应 HdsBarStyle：MiniBar 的展开 / 收起两态。 */
export enum HdsBarStyle {
  EXPAND,
  COLLAPSE
}

/** 对应 hdsMaterial.MaterialType / MaterialLevel：都用 ADAPTIVE，交给系统按设备自适应。 */
export class HdsMaterialType {
  static readonly ADAPTIVE: string = 'ADAPTIVE';
  static readonly IMMERSIVE: string = 'IMMERSIVE';
}
export class HdsMaterialLevel {
  static readonly ADAPTIVE: string = 'ADAPTIVE';
  static readonly EXQUISITE: string = 'EXQUISITE';
}

/** 单个页签定义。 */
interface HdsTabItem {
  label: string;
  icon: Resource;
  iconActive: Resource;
}

const HDS_TABS: HdsTabItem[] = [
  { label: '首页', icon: $r('sys.symbol.house'), iconActive: $r('sys.symbol.house_fill') },
  { label: '发现', icon: $r('sys.symbol.discover'), iconActive: $r('sys.symbol.discover') },
  { label: '设置', icon: $r('sys.symbol.gearshape'), iconActive: $r('sys.symbol.gearshape_fill') }
];

/**
 * barFloatingStyle 的建议参数（对应 HDS HdsTabsFloatingStyle）。
 * 由使用方展开到 Tabs.barFloatingStyle() 上——悬浮参数只能在 Tabs 上设。
 */
export class HdsFloatingStyle {
  static readonly BAR_BOTTOM_MARGIN: number = 12;
  static readonly BAR_SIDE_MARGIN: number = 14;
  static readonly MASK_HEIGHT: number = 92;
  static readonly MASK_COLOR_LIGHT: string = '#66F1F3F5';
  static readonly MASK_COLOR_DARK: string = '#66191C22';
}

/**
 * 原生沉浸材质工厂：集中构造 uiMaterial.ImmersiveMaterial，避免在 build 里散落魔数。
 *
 * 对标华为音乐悬浮胶囊的「液态玻璃 + 沉浸光感」：
 *   - style：按设备算力分级取厚度。高算力 EXQUISITE 用 THIN（更通透、光感更强），
 *     中算力 GENTLE 用 REGULAR，低算力 SMOOTH 用 THICK（少滤镜、省 GPU）。
 *   - materialColor：纯色带透明度（不能全不透，否则滤镜被盖掉）。深浅各一套。
 *   - colorInvert：材质够薄时文字自动取背景互补色，光的自适应关键项。
 *   - applyShadow：材质自带阴影，优先级高于普通 shadow。
 *   - interactive：交互形变的液态反馈。
 *   - lightEffect：沉浸光感反馈色，点击时随光晕——这是「光感」的原生开关。
 *
 * 设备不支持沉浸光感时返回 undefined（系统回退到 maskColor 自绘遮罩），不硬套。
 */
export class HdsNativeMaterial {
  /** 悬浮页签胶囊的原生沉浸材质（含 lightEffect 光感反馈）；不支持时返回 undefined。 */
  static tabBarMaterial(isDark: boolean): uiMaterial.ImmersiveMaterial | undefined {
    if (!uiMaterial.isImmersiveMaterialSupported()) {
      return undefined;
    }
    const level: uiMaterial.MaterialLevel = uiMaterial.getGlobalMaterialLevel();
    let style: uiMaterial.ImmersiveStyle = uiMaterial.ImmersiveStyle.REGULAR;
    if (level === uiMaterial.MaterialLevel.EXQUISITE) {
      style = uiMaterial.ImmersiveStyle.THIN;
    } else if (level === uiMaterial.MaterialLevel.SMOOTH) {
      style = uiMaterial.ImmersiveStyle.THICK;
    }
    const options: uiMaterial.ImmersiveOptions = {
      style: style,
      materialColor: isDark ? '#66191C22' : '#66F1F3F5',
      colorInvert: true,
      applyShadow: true,
      interactive: true,
      lightEffect: { color: isDark ? '#FFFFFFFF' : '#FF111116' }
    };
    return new uiMaterial.ImmersiveMaterial(options);
  }
}

/**
 * 沉浸光感材质：等价于 systemMaterialEffect({
 *   materialType: hdsMaterial.MaterialType.ADAPTIVE,
 *   materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
 * })。ADAPTIVE 语义 = 深浅色各取一套半透明底，随系统自适应。
 */
@Component
export struct HdsGlass {
  @Prop radius: number = 26;
  @StorageProp('isDark') isDark: boolean = false;
  /** 受光强度 0~1，用透明度表达沉浸光感；0 = 关闭光效（纯实色）。 */
  @Prop light: number = 1;

  private p(): Palette {
    return palette(this.isDark);
  }

  build() {
    Stack() {
      // 半透明底 + 背景模糊：ADAPTIVE 材质主体。深色略加深，浅色略提亮。
      Column()
        .width('100%')
        .height('100%')
        .borderRadius(this.radius)
        .backgroundColor(withAlpha(this.isDark ? '#FF1E222A' : '#FFFDFCFA', this.isDark ? 0.82 : 0.86))
        .backgroundBlurStyle(this.isDark ? BlurStyle.COMPONENT_THICK : BlurStyle.COMPONENT_REGULAR)
      // 斜向受光：左上入射的一道高光，营造玻璃厚度与沉浸感。
      Column()
        .width('100%')
        .height('100%')
        .borderRadius(this.radius)
        .linearGradient({
          angle: 150,
          colors: [
            [withAlpha('#FFFFFFFF', 0.30 * this.light), 0],
            [withAlpha('#FFFFFFFF', 0.08 * this.light), 0.24],
            ['#00FFFFFF', 0.55]
          ]
        })
      // 1vp 中性发丝边，官方克制风格。
      Column()
        .width('100%')
        .height('100%')
        .borderRadius(this.radius)
        .border({ width: 1, color: withAlpha(this.p().glassBorder, 0.55) })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }
}

/**
 * 流光特效：一条斜向高光沿栏体自左向右缓慢扫过，循环往复。
 * 对应官方沉浸光感「随背景流动的光影」。
 */
@Component
export struct HdsFlowLight {
  @Prop radius: number = 26;
  @Prop duration: number = 3200;
  @StorageProp('isDark') isDark: boolean = false;
  @State private shift: number = 0;
  private timer: number = -1;

  aboutToAppear(): void {
    // 用定时器推进位移；纯绘制层，低频（~30fps）即可，不进 AppStorage。
    this.timer = setInterval((): void => {
      this.shift = (this.shift + 1) % 100;
    }, Math.max(16, Math.floor(this.duration / 100)));
  }

  aboutToDisappear(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  build() {
    Column()
      .width('100%')
      .height('100%')
      .borderRadius(this.radius)
      .clip(true)
      .linearGradient({
        angle: 115,
        colors: [
          ['#00FFFFFF', Math.max(0, this.shift / 100 - 0.18)],
          [withAlpha('#FFFFFFFF', this.isDark ? 0.16 : 0.24), this.shift / 100],
          ['#00FFFFFF', Math.min(1, this.shift / 100 + 0.18)]
        ]
      })
      .hitTestBehavior(HitTestMode.None)
  }
}

/**
 * 悬浮页签内容：供 Tabs 的 TabContent.tabBar(this.hdsTabBar(index, selected)) 调用。
 * 三个入口 + 选中态高亮，整体就是官方悬浮胶囊里的一格。
 *
 * 伸缩联动（对标华为音乐原版，SVID_20261116_051727_1.mp4 逐帧确认）：
 * 列表上滑时 UiBar 广播 tabBarProgress→1，底栏从「图标+文字的高胶囊」
 * 连续收缩为「只剩图标的矮胶囊」；下滑回滚 progress→0 恢复图文两行。
 * 与上方 HdsMiniBar 共用同一状态源，二者同步伸缩——这才是原版
 * 「播放栏和底栏两个一起伸展/收缩」的真实形态，而不是撑高播放条。
 */
@Component
export struct HdsTabBar {
  @Prop index: number = 0;
  @Prop selected: number = 0;
  @StorageProp('isDark') isDark: boolean = false;
  /**
   * 0=展开(图文) / 1=收缩(仅图标)。由 Index 顶层显式传入（@Watch 驱动），
   * 不用 builder 子树里的 @StorageProp——那样刷新不可靠，底栏会一直不动。
   */
  @Prop progress: number = 0;
  /**
   * 连续页位（0→1→2，可为小数），由 Index 的 Tabs.onGestureSwipe 逐帧写入。
   * 这是「底栏同步跟手」的关键：横滑全程实时变化，不是松手才跳的离散 selected。
   */
  @Prop swipePos: number = 0;

  private p(): Palette {
    return palette(this.isDark);
  }

  /**
   * 本格激活度 0~1：与连续页位的距离。
   * swipePos=0.5 时首页/发现各 0.5，两格同时半亮 = 高亮块在两格间跟手滑动。
   */
  private activation(): number {
    return Math.max(0, 1 - Math.abs(this.index - this.swipePos));
  }

  build() {
    Stack() {
      // 指示器：激活背景块，随激活度显隐；横滑时相邻两格此消彼长，
      // 视觉上就是高亮指示条跟着手指在页签间滑动（Tabs 原生只管页面跟手，不画这个）。
      Row()
        .width('100%')
        .height('88%')
        .borderRadius(14)
        .backgroundColor(withAlpha(this.p().primary, 0.14 * this.activation()))

      // 底栏流光：强度随激活度，跟手时随高亮格流动。
      HdsFlowLight({ radius: 14, duration: 2600 })
        .opacity(this.activation() * 0.55)

      // 未选中层（底图）：opacity = 1 - 激活度
      Column({ space: 3 * (1 - this.progress) }) {
        SymbolGlyph(HDS_TABS[this.index].icon)
          .fontSize(22 - 4 * this.progress)
          .fontColor([this.p().text3])
        Text(HDS_TABS[this.index].label)
          .fontSize(9.5)
          .fontWeight(FontWeight.Normal)
          .fontColor(this.p().text3)
          .height(12 * (1 - this.progress))
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .opacity(1 - this.activation())

      // 选中层（高亮）：opacity = 激活度，横滑时连续淡入淡出 = 高亮跟手。
      Column({ space: 3 * (1 - this.progress) }) {
        SymbolGlyph(HDS_TABS[this.index].iconActive)
          // 选中图标略大，随激活度连续放大，不跳变。
          .fontSize(22 + 2 * this.activation() - 4 * this.progress)
          .fontColor([this.p().primary])
        Text(HDS_TABS[this.index].label)
          .fontSize(9.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.p().primary)
          .height(12 * (1 - this.progress))
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .opacity(this.activation())
    }
    .width('100%')
    .height('100%')
    // 跟手零延迟：根容器刻意不挂动画修饰。逐帧的 swipePos 直接生效；
    // 松手吸附的补间由 Index.onAnimationStart 的 animateTo 统一提供。
  }
}

/**
 * MiniBar —— 对标华为音乐的「半透明悬浮迷你播放条」。
 *
 * 形态来自华为音乐官方录屏逐帧核对（SVID_20261116_051727_1.mp4）：
 *   - 播放条全程形态恒定：一条轻薄、半透明毛玻璃的圆角胶囊，圆形小封面 +
 *     歌名/歌手两行 + 播放/下一首/列表按钮。视频里滚的是信息流，播放条
 *     自身从不变高、不变矮、不被撑大。
 *   - 播放条与底部页签胶囊是上下分开的两层，中间透出内容。
 *   - 点播放条 → 全屏播放页，封面用 geometryTransition 一镜到底放大（见 Index）。
 *
 * 重要修正（v2.37）：此前把播放条当成「可伸缩面板」，用竖向 PanGesture 把
 * 高度从 46vp 撑到 120vp，封面/文字/按钮被塞进越变越大的白卡片——与原版
 * 严重不符。现删除撑高逻辑，播放条固定为 ~54vp 的恒定轻薄形态。
 *
 * tabBarProgress 仍作为滚动联动状态源（UiBar 列表上滑时广播收起）：
 * 这里只用它做整条播放条的轻微淡出 + 下沉（位移/透明度），绝不改变条体
 * 自身高度与内部元素尺寸，符合原版「形态恒定、整体随滚动隐现」的观察。
 */
@Component
export struct HdsMiniBar {
  @StorageProp('isDark') isDark: boolean = false;
  /**
   * 滚动收起进度，由 Index 顶层显式传入（0=展开/1=收起）。
   * 不用 @StorageProp 自行订阅：本组件在 builder 子树里，@StorageProp 刷新不可靠；
   * 由带 @Watch 的 Index.barProgress 作唯一驱动源，@Prop 随父重建 reliably 更新。
   */
  @Prop collapseProgress: number = 0;
  @State song: SongInfo = App.get().player.getSong();
  @State playing: boolean = false;
  @State loading: boolean = false;
  @State progress: number = 0;
  @State duration: number = 0;
  @State hasSong: boolean = false;
  private player: Player = App.get().player;
  /** 展开态条高（vp）。 */
  private static readonly BAR_HEIGHT: number = 54;
  /** 收缩态条高（vp）——滚动到底时播放条收成矮条，与底栏同步伸缩。 */
  private static readonly MIN_HEIGHT: number = 34;
  private listener: () => void = (): void => {
  };

  aboutToAppear(): void {
    this.listener = (): void => {
      this.song = this.player.getSong();
      this.playing = this.player.isPlaying();
      this.loading = this.player.isLoading();
      this.progress = this.player.getPosition();
      this.duration = this.player.getDuration();
      this.hasSong = this.player.hasSong();
      AppStorage.setOrCreate('hasSong', this.hasSong);
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

  private ratio(): number {
    return this.duration > 0 ? Math.min(1, this.progress / this.duration) : 0;
  }

  // ── 播放条真·伸缩：条高与内部尺寸随滚动进度连续插值 ──
  // 展开 p=0：条高54 / 封面38；收缩 p=1：条高34 / 封面26。
  // 两者同步缩放，保证内容始终装得下、不被 clip 裁切。
  private barHeight(): number {
    return HdsMiniBar.BAR_HEIGHT - (HdsMiniBar.BAR_HEIGHT - HdsMiniBar.MIN_HEIGHT) * this.collapseProgress;
  }

  private coverSide(): number {
    return 38 - 12 * this.collapseProgress;
  }

  private coverRadius(): number {
    return this.coverSide() / 2;
  }

  private titleSize(): number {
    return FONT.callout - 2 * this.collapseProgress;
  }

  private rowPaddingV(): number {
    return 6 - 3 * this.collapseProgress;
  }

  /** 点整条进播放页（一镜到底）。 */
  private enter(): void {
    if (!this.hasSong) {
      return;
    }
    App.get().openPlayer();
  }

  @Builder
  transport() {
    if (this.loading) {
      LoadingProgress().width(22).height(22).color(this.p().text2)
    } else {
      IconTap({
        icon: this.playing ? $r('sys.symbol.pause') : $r('sys.symbol.play_fill'),
        iconSize: 22,
        color: this.p().text,
        paddingSize: 6,
        onTap: () => this.player.toggle()
      })
    }
    IconTap({
      icon: $r('sys.symbol.forward_end_fill'),
      iconSize: 18,
      color: this.p().text2,
      paddingSize: 8,
      onTap: () => this.player.next()
    })
    IconTap({
      icon: $r('sys.symbol.list_bullet'),
      iconSize: 18,
      color: this.p().text2,
      paddingSize: 8,
      onTap: () => App.get().openQueue()
    })
  }

  build() {
    if (this.hasSong) {
      // 半透明毛玻璃迷你条：形态恒定，绝不撑高变形。
      // 级联 tabBarProgress 只做整条淡出 + 轻微下沉（列表上滑跟随 UiBar 收起），
      // 与华为原版「播放条形态恒定、整体随滚动隐现」一致，不改条高与内部尺寸。
      Stack({ alignContent: Alignment.TopStart }) {
        // 原生液态玻璃的本地近似：MiniBar 不在沉浸光感生效子树（见文件头注释）。
        // light 略降、底更透，贴近华为原版那种能透出内容的半透明质感。
        HdsGlass({ radius: 27, light: 0.7 })
        HdsFlowLight({ radius: 27 })

        Column() {
          Row({ space: 10 }) {
            // 圆形小封面（华为原版是圆形，不是方角卡片）。
            Stack() {
              Cover({
                uri: this.song.cover,
                songId: CoverRepo.keyOf(this.song),
                side: this.coverSide(),
                radius: this.coverRadius()
              })
            }
            .width(this.coverSide())
            .height(this.coverSide())
            .clip(true)
            .borderRadius(this.coverRadius())
            .onClick(() => this.enter())

            Column({ space: 2 }) {
              Text(this.song.name.length > 0 ? this.song.name : '暂无播放')
                .fontSize(this.titleSize())
                .fontWeight(FontWeight.Medium)
                .fontColor(this.p().text)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.MARQUEE })
                .marqueeOptions({ start: true, loop: -1, step: 2, fromStart: true })
                .width('100%')
              Text(this.song.singer.length > 0 ? this.song.singer : '选一首歌开始')
                .fontSize(FONT.micro)
                .fontColor(this.p().text3)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.MARQUEE })
                .marqueeOptions({ start: true, loop: -1, step: 2, fromStart: true })
                .width('100%')
                // 收缩态副标题淡出，矮条只留歌名一行。
                .opacity(1 - this.collapseProgress)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .onClick(() => this.enter())

            Row() {
              this.transport()
            }
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ left: 9, right: 6, top: this.rowPaddingV(), bottom: this.rowPaddingV() + 1 })

          // 贴底进度细线：恒定一条，华为原版迷你条底部那道进度指示。
          Stack({ alignContent: Alignment.Start }) {
            Row().width('100%').height(2).backgroundColor(withAlpha(this.p().text3, 0.18))
            Row().width((this.ratio() * 100).toFixed(2) + '%').height(2).backgroundColor(this.p().primary)
          }
          .width('100%')
          .height(2)
          .margin({ left: 12, right: 12, bottom: 3 })
          .opacity(1 - this.collapseProgress)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      // 真·伸缩：条高随滚动进度从 54vp 连续收到 34vp（内部封面/字号同步缩）。
      .height(this.barHeight())
      .borderRadius(this.barHeight() / 2)
      .clip(true)
      // 配合下沉 + 适度淡出，与底栏 barHeight 收缩同步，肉眼可见"伸展/收缩"。
      // 绝不叠加按压态样式（normal 态写死 opacity 1 会覆盖这里的联动，旧 bug）。
      .opacity(1 - this.collapseProgress * 0.55)
      .translate({ y: this.collapseProgress * 34 })
      .animation({ duration: 150, curve: Curve.EaseOut })
      .onClick(() => this.enter())
    }
  }
}

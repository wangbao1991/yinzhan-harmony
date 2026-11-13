import {
  palette, Palette, RADIUS, FONT, lightSense, LightSense,
  glassSurface, glassDepth, glassEdgeWidth, glassEdgeColor, glassShadow, glassCardBase
} from '../common/Constants';
import { SongInfo } from '../common/Models';
import { withAlpha } from '../common/Utils';
import { App } from '../core/App';
import { Player } from '../core/Player';
import { CoverRepo } from '../core/CoverRepo';
import { TabBarHider } from '../core/UiBar';
import { Cover, IconTap } from './Common';

interface TabItemDef {
  label: string;
  icon: Resource;
  iconActive: Resource;
}

const TABS: TabItemDef[] = [
  { label: '首页', icon: $r('sys.symbol.house'), iconActive: $r('sys.symbol.house_fill') },
  { label: '发现', icon: $r('sys.symbol.discover'), iconActive: $r('sys.symbol.discover') },
  { label: '设置', icon: $r('sys.symbol.gearshape'), iconActive: $r('sys.symbol.gearshape_fill') }
];

/**
 * 形态切换的交互分界点（0~1 的收起进度）。
 *
 * 展开态内容图标在 0.34 已经退干净，所以到这条线就整层禁用它；
 * 收起态从同一条线开始接管——两边互补，中间不留「谁都能点」的空窗。
 * 视觉上的接力区间比这个更早/更晚，但那是绘画的事，和命中测试分开。
 */
const FORM_SWITCH: number = 0.34;

/**
 * 底部胶囊标签栏：三个入口 + 当前项高亮。
 * 「音乐库」不再单独占位——它的四宫格和自建歌单已经搬到首页，两边内容完全重叠，
 * 留一个 tab 只是让人多点一次。搜索同样不占位，从首页搜索框 push 二级页。
 * 外层半透明毛玻璃，浮在内容之上。
 */
@Component
export struct TabBar {
  @Prop current: number = 0;
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;
  /**
   * 滚动收起进度 0~1，由 core/UiBar 的 TabBarHider 写入。
   * 这个值以前只写不读——各页面 onScrollFrameBegin 都在 feed()，
   * 算了一整套跟手渐变，外壳却从来没消费，等于白算。
   */
  @StorageProp('tabBarProgress') progress: number = 0;
  /** 有没有在播的歌：没有可合并的播放条时，收起只剩一个圆按钮太怪，干脆不收起 */
  @StorageProp('hasSong') hasSong: boolean = false;
  /**
   * 横滑进度 = 当前页索引 + 拖动比例（0~1 的连续值）。
   * 由 Index 里 Swiper.onContentDidScroll 写入，指示器跟着手指走；
   * 松手后 Swiper 回弹，这个值也会跟着回到整数位，不需要自己补间。
   */
  @StorageProp('tabSwipe') @Watch('onSwipe') swipe: number = 0;
  /**
   * 这一段位移该走多长（ms），由 Index 在写位置之前先广播。
   *
   *   0   = 手指正在拖动，位置必须零延迟（1:1 跟手）
   *   300 = 翻页/点按/归位，用和 Swiper 同长同曲线补间
   *
   * 之所以单独广播一个时长，而不是在底栏里按「是否拖动中」自己判断：
   * 翻页动画是 Swiper 自己发的，手指可能还按在屏幕上，
   * 这时「拖动中」是个错误信号，会让指示器停在原地干等动画跑完。
   */
  @StorageProp('tabDur') dur: number = 0;
  /** 指示器当前落点。补间走本地状态，不用属性动画（见 onSwipe 注释） */
  @State pillAt: number = 0;
  /** 一级页数量，指示器宽度按它等分 */
  @Prop total: number = 3;
  onSelect: (index: number) => void = (index: number): void => {
  };

  aboutToAppear(): void {
    // 恢复上次停留的页时，指示器直接从该位置起步，不要从 0 补间过来
    this.pillAt = this.swipe;
  }

  /**
   * 位置一变，就在这里落到本地状态上。
   *
   * 不用 .animation()：属性动画的时长在渲染时读一次，
   * 而「时长从 0 变成 300」和「位置变化」发生在同一帧时，框架取哪一次不确定，
   * 实际表现是原地卡住、然后硬跳。改用 animateTo 显式指定这一段用多久：
   *   dur = 0   → 拖动中，立即赋值，零延迟跟手
   *   dur > 0   → 翻页/归位，用和 Swiper 同长同曲线补间，两头同时收
   */
  private onSwipe(): void {
    animateTo({ duration: this.dur > 0 ? this.dur : 0, curve: Curve.Friction }, () => {
      this.pillAt = this.swipe;
    });
  }

  /**
   * 收起系数 0~1，直接跟着手指走。
   *
   * 不是「整条缩窄」——那样只是变小，还是原来那条栏。
   * 参考软件是两种形态的切换：展开时是整条标签栏，
   * 收起时换成一个圆形按钮 + 一条播放胶囊，横向排满。
   */
  private collapse(): number {
    if (!this.hasSong) {
      return 0;
    }
    return Math.max(0, Math.min(1, this.progress));
  }

  /**
   * 把 0~1 的收起进度切成若干段，每段线性映射到 0~1。
   *
   * 这是「丝滑」的关键：所有元素都挂在同一个值上同步推进的话，
   * 看到的就是整块一起变淡、再整块变清晰，中间是两团半透明的糊影。
   * 错开之后才有层次——文字先走、图标跟上、底板最后溶解，
   * 圆按钮和播放条在后半段才浮现。
   */
  private stage(from: number, to: number): number {
    const c = this.collapse();
    if (to <= from) {
      return c >= to ? 1 : 0;
    }
    return Math.max(0, Math.min(1, (c - from) / (to - from)));
  }

  /** 收尾更快一点：形变起始慢、结束果断，手感比线性「利落」 */
  private easeOut(v: number): number {
    return 1 - Math.pow(1 - v, 3);
  }

  /**
   * 栏体高度：62 → 52。
   *
   * 之前是「只收右边、宽度 100%→64%」，问题是：收起态那排其实铺满整宽，
   * 右边界先缩回去、最后又要弹出来，左右本来就不对称；
   * 缩到一半时旧底板（62 高、宽）和新胶囊（52 高、窄）同时可见，
   * 看上去就是「胶囊套胶囊」，两层轮廓叠在一起。
   *
   * 现在宽度一动不动，只把整条往下收 10vp——一个栏体从头用到尾，
   * 形态变化交给里面的内容接力，轮廓始终只有一条。
   */
  private barH(): number {
    return 62 - 10 * this.easeOut(this.stage(0.0, 0.78));
  }

  /** 圆角恒等于半高：任何一步都是干净的胶囊，不会先方后圆 */
  private barR(): number {
    return this.barH() / 2;
  }

  private pillWidth(): string {
    return (100 / this.total).toFixed(3) + '%';
  }

  /**
   * 高亮跟着手指走：取最近的整数页，指针过半就换。
   * 只用 current 的话，拖动过程中指示器已经滑到下一格、图标却还是旧的，看着像两条线。
   */
  private active(): number {
    return Math.max(0, Math.min(this.total - 1, Math.round(this.pillAt)));
  }

  /** 指示器位置：整数索引 + 拖动比例，直接按百分比定位 */
  private pillX(): string {
    const at = Math.max(0, Math.min(this.total - 1, this.pillAt));
    return (at * 100 / this.total).toFixed(3) + '%';
  }

  private p(): Palette {
    return palette(this.isDark);
  }

  private ls(): LightSense {
    return lightSense(this.lightLevel);
  }

  private glassBlur(): BlurStyle {
    if (this.lightLevel <= 0) {
      return BlurStyle.NONE;
    }
    if (this.lightLevel === 1) {
      return BlurStyle.COMPONENT_THIN;
    }
    if (this.lightLevel >= 3) {
      return BlurStyle.COMPONENT_ULTRA_THICK;
    }
    return BlurStyle.COMPONENT_THICK;
  }


  build() {
    // 从头到尾只有一条栏体：展开是 62 高的三格标签栏，收起是 52 高的播放坞。
    // 宽度不动、只往下落 10vp，圆角始终等于半高——轮廓不会先缩窄再弹回，
    // 也不会出现「62 高的底板里还套着一条 52 高的胶囊」两层边线。
    //
    // 里面的内容按段接力，任何一刻只有一层内容在场：
    //   0.00~0.18  文字先退（图标还在，位置还没动）
    //   0.06~0.34  图标、选中指示器退干净
    //   0.34~0.66  紫色圆按钮放大浮现
    //   0.42~0.70  封面 + 歌名浮现
    //   0.52~0.78  播放 / 下一首 / 列表跟上（在 MiniPlayer 里错开）
    // 高光垫在最底层（以前用 overlay 盖在内容上，白渐变把封面糊成了半透明）。
    Stack({ alignContent: Alignment.BottomStart }) {
      // ── 高光层：垫底，不吃触摸 ──
      this.glassHighlight(999)
      // ── 底部聚光：厚度感的主体，同样是纯绘制层 ──
      this.depthLayer()

      // ── 底沿内高光：v2.52 墨栈退化为 1vp 中性发丝线，不再有白色反光带 ──
      // 纸墨表面不靠下沿聚光表达厚度，层级交给发丝线与留白。
      Row()
        .width('100%')
        .height(1)
        .margin({ bottom: 1.2 })
        .backgroundColor(this.p().line)
        .hitTestBehavior(HitTestMode.None)

      // ───────────── 展开态内容 ─────────────
      Stack({ alignContent: Alignment.TopStart }) {
        // 选中指示器：整条栏里唯一会横向移动的东西。
        // 宽度固定 1/3，位置 = 当前页 + 拖动比例，横滑时贴着手指走。
        Row()
          .width(this.pillWidth())
          .height(46)
          .borderRadius(RADIUS.pill)
          // 选中片本身也是一块小玻璃：斜向渐变 + 一圈亮边 + 自己的浅投影。
          // 纯 12% 平涂时它和栏体糊成一片，看不出「这块是浮在栏面上的」；
          // 加个 offsetY 3 的短影，它就从栏面上「贴」起来了一层。
          .linearGradient({
            angle: 145,
            colors: [
              [this.p().primarySoft, 0],
              [this.p().primarySoft, 1]
            ]
          })
          .border({ width: 1, color: this.p().glassBorder })
          .shadow({ radius: 6, color: 'rgba(27,26,24,0.10)', offsetY: 2 })
          .position({ x: this.pillX(), y: 8 })
          .opacity(1 - this.stage(0.0, 0.26))
          .hitTestBehavior(HitTestMode.None)

        Row() {
          ForEach(TABS, (item: TabItemDef, index: number) => {
            Column({ space: 3 }) {
              SymbolGlyph(this.active() === index ? item.iconActive : item.icon)
                .fontSize(22)
                .fontColor([this.active() === index ? this.p().primary : this.p().text3])
                .opacity(1 - this.stage(0.06, 0.34))
              Text(item.label)
                .fontSize(9.5)
                .fontWeight(this.active() === index ? FontWeight.Medium : FontWeight.Normal)
                .fontColor(this.active() === index ? this.p().primary : this.p().text3)
                .opacity(1 - this.stage(0.0, 0.18))
            }
            .layoutWeight(1)
            .height('100%')
            .justifyContent(FlexAlign.Center)
            .onClick(() => {
              this.onSelect(index);
            })
          }, (item: TabItemDef) => item.label)
        }
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')
      // ── 交互开关：必须整棵子树一起关 ──
      // 两个形态在像素上完全重叠，只关自己（hitTestBehavior）是不够的：
      // 它只让「这一层」不参与命中，里面的子节点照样能点。
      // 于是展开态点「发现」会落到收起态播放坞的歌名区（进播放页），
      // 点「设置」会落到坞里那三个控制键（上一首/播放/列表）。
      // enabled 会连同整棵子树一起禁用，才是真正的「这一层不在场」。
      .enabled(this.collapse() < FORM_SWITCH)
      .hitTestBehavior(this.collapse() < FORM_SWITCH ? HitTestMode.Default : HitTestMode.None)

      // ───────────── 收起态内容 ─────────────
      // 不再是「圆按钮 + 一条独立胶囊」两个物件：
      // 圆按钮内嵌在这条 52 高的栏体里（四边各留 4），右边直接排播放信息。
      // 这样左右是同一个外轮廓，视觉重心不会被一枚实心紫圆拽偏。
      Row({ space: 8 }) {
        Stack() {
          SymbolGlyph($r('sys.symbol.house_fill'))
            .fontSize(20)
            .fontColor([Color.White])
        }
        .width(44)
        .height(44)
        .borderRadius(22)
        // 实心按钮也要有"球面"：左上角一道白边、右下角一道暗边，
        // 再加一层自己的彩色投影。纯平涂的圆在玻璃栏体旁边会显得很假，
        // 像贴了一张圆形贴纸。
        .linearGradient({
          angle: 145,
          colors: [['#00FFFFFF', 0], ['#00FFFFFF', 1]]
        })
        .backgroundColor(this.p().primary)
        .border({ width: 1, color: this.p().glassBorder })
        .shadow({ radius: 6, color: 'rgba(27,26,24,0.10)', offsetY: 2 })
        .opacity(this.stage(0.28, 0.60))
        .scale({
          x: 0.72 + 0.28 * this.easeOut(this.stage(0.28, 0.60)),
          y: 0.72 + 0.28 * this.easeOut(this.stage(0.28, 0.60))
        })
        .onClick(() => {
          // 回首页 + 就地展开底栏：不用把手里的列表一路滚回顶部
          this.onSelect(0);
          TabBarHider.get().reset();
        })

        // 播放信息直接躺进这一行，自身不再画底板（栏体就是它的底板）
        MiniPlayer({ inline: true })
          .layoutWeight(1)
          .opacity(this.stage(0.36, 0.66))
          .translate({ y: 3 * (1 - this.easeOut(this.stage(0.36, 0.66))) })
      }
      .width('100%')
      .height('100%')
      .padding({ left: 4, right: 4 })
      .alignItems(VerticalAlign.Center)
      // 对称的另一半：展开态时这一层是完全透明的，但它的子节点（封面 / 歌名 /
      // 三个控制键）盖在三格标签的正上方，一碰就抢走点击。整层禁用才干净。
      .enabled(this.collapse() >= FORM_SWITCH)
      .hitTestBehavior(this.collapse() >= FORM_SWITCH ? HitTestMode.Default : HitTestMode.None)
    }
    .width('100%')
    .height(this.barH())
    .borderRadius(this.barR())
    // ── 纸墨表面的三件套（v2.52 去光化）──
    // 1) 表面：对角四段渐变，左上受光偏白、右下透出背景冷色。
    //    单色 rgba 平涂看不出厚度，压得再低也只是「雾」不是「玻璃」。
    //    这里不再叠 backgroundColor：渐变本身带 alpha，再压一层底会直接
    //    白回 0.8，把刚透出来的背景色又糊掉（关光感时渐变自带纯色，够用）。
    // 不再叠 backgroundBlurStyle：模糊材质和 linearGradient 抢同一个背景，
    // 渐变可能被整层盖掉（上一版「改了却没变化」的最大嫌疑）。
    // 兜底色保证即使渐变不绘制，整页也一眼看得出换过。
    .backgroundColor(glassCardBase(this.isDark))
    .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
    // 2) 轮廓：四边分开描边，上 1.0 亮、下 1.4 最亮、左右 0.9 半亮。
    //    光从斜上方来，玻璃下沿的反射永远比上沿厚——这一条边就是「厚度」。
    .border({
      width: glassEdgeWidth(this.lightLevel),
      color: glassEdgeColor(this.isDark, this.lightLevel)
    })
    // 3) 离地高度：影子往下压 16、散开 22，冷蓝黑。
    //    原来的 8vp 品牌色更像给栏体染了层淡紫，读不出「浮」。
    .shadow(glassShadow(this.isDark, this.lightLevel))
    .clip(true)
  }

  /**
   * 玻璃顶面的受光：只在最上面三成有一层薄白，往下迅速消失。
   *
   * 以前是 0→55% 一路压着 highlight 不放手，整条上半截被糊成一块白，
   * 通透感全没了——玻璃应该是「一眼看得穿，只在边上有点反光」。
   * 现在强度砍掉一半，剩下的立体感交给四边描边和底沿那道高光。
   */
  @Builder
  glassHighlight(radius: number) {
    Column()
      .width('100%')
      .height('100%')
      .borderRadius(radius)
      .linearGradient({
        angle: 168,
        colors: [
          [withAlpha('#FFFFFFFF', this.ls().highlight * 0.52), 0],
          [withAlpha('#FFFFFFFF', this.ls().highlight * 0.14), 0.26],
          ['#00FFFFFF', 0.56]
        ]
      })
      .hitTestBehavior(HitTestMode.None)
  }

  /** 底部聚光层：从下沿往上 36% 渐隐的一层白，玻璃厚度就长在这一层上 */
  @Builder
  depthLayer() {
    // 只占下沿 26%，不铺满：铺满的话整条下部都会被刷白，看着像奶白塑料
    Column()
      .width('100%')
      .height('26%')
      .linearGradient({ angle: 180, colors: glassDepth(this.isDark, this.lightLevel) })
      .hitTestBehavior(HitTestMode.None)
  }
}

/**
 * 迷你播放条：封面 / 歌名 / 播放暂停 / 下一首 / 队列。
 * 点击主体进入全屏播放页。
 */
@Component
export struct MiniPlayer {
  /**
   * 紧凑版：躺进底部收起态那一行，和圆形按钮并排。
   * 尺寸整体小一圈（52 高、封面 34、无进度线），玻璃参数与标签栏对齐。
   */
  @Prop inline: boolean = false;
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;
  /** 底栏收起进度：紧凑版里让三个控制键比封面/歌名晚一点出现，接力更顺 */
  @StorageProp('tabBarProgress') bar: number = 0;
  @State song: SongInfo = App.get().player.getSong();
  @State playing: boolean = false;
  @State loading: boolean = false;
  @State progress: number = 0;
  @State duration: number = 0;
  @State hasSong: boolean = false;
  private player: Player = App.get().player;
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
      // 底栏要靠它决定收不收起：没歌时没有可合并的播放条，收起只剩一个圆按钮
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

  private ls(): LightSense {
    return lightSense(this.lightLevel);
  }

  private glassBlur(): BlurStyle {
    if (this.lightLevel <= 0) {
      return BlurStyle.NONE;
    }
    if (this.lightLevel === 1) {
      return BlurStyle.COMPONENT_THIN;
    }
    if (this.lightLevel >= 3) {
      return BlurStyle.COMPONENT_ULTRA_THICK;
    }
    return BlurStyle.COMPONENT_THICK;
  }

  /**
   * 播放 / 下一首 / 队列。
   *
   * 三个键的触摸热区做成等宽（紧凑 28、展开 34），图标在各自格子里居中：
   * 以前是 20/16/17 各配 4 的 padding，热区 28/24/25，键与键的间距就不等，
   * 一排图标看着疏密不匀、实心的播放三角又格外重。
   * 现在三格等宽，图标视觉大小按「实心比描边显大」略作补偿。
   */
  @Builder
  transport() {
    if (this.loading) {
      LoadingProgress().width(22).height(22).color(this.p().text2)
    } else {
      IconTap({
        icon: this.playing ? $r('sys.symbol.pause') : $r('sys.symbol.play_fill'),
        iconSize: this.inline ? 20 : 22,
        color: this.p().text,
        paddingSize: this.inline ? 4 : 6,
        onTap: () => {
          if (!this.live()) {
            return;
          }
          this.player.toggle();
        }
      })
    }
    IconTap({
      icon: $r('sys.symbol.forward_end_fill'),
      iconSize: this.inline ? 17 : 18,
      color: this.p().text2,
      paddingSize: this.inline ? 5.5 : 8,
      onTap: () => {
        if (!this.live()) {
          return;
        }
        this.player.next();
      }
    })
    IconTap({
      icon: $r('sys.symbol.list_bullet'),
      iconSize: this.inline ? 17 : 18,
      color: this.p().text2,
      paddingSize: this.inline ? 5.5 : 8,
      onTap: () => {
        if (!this.live()) {
          return;
        }
        // 直接弹队列，和播放页顶栏那个同图标保持同一行为
        App.get().openQueue();
      }
    })
  }

  /** 底部聚光层：从下沿往上 36% 渐隐的一层白，玻璃厚度的来源 */
  @Builder
  depthLayer() {
    // 只占下沿 26%，不铺满：铺满的话整条下部都会被刷白，看着像奶白塑料
    Column()
      .width('100%')
      .height('26%')
      .linearGradient({ angle: 180, colors: glassDepth(this.isDark, this.lightLevel) })
      .hitTestBehavior(HitTestMode.None)
  }

  /** 玻璃顶面受光，和底部标签栏同一套参数 */
  @Builder
  glassHighlight(radius: number) {
    Column()
      .width('100%')
      .height('100%')
      .borderRadius(radius)
      .linearGradient({
        angle: 168,
        colors: [
          [withAlpha('#FFFFFFFF', this.ls().highlight * 0.52), 0],
          [withAlpha('#FFFFFFFF', this.ls().highlight * 0.14), 0.26],
          ['#00FFFFFF', 0.56]
        ]
      })
      .hitTestBehavior(HitTestMode.None)
  }

  private ratio(): number {
    if (this.duration <= 0) {
      return 0;
    }
    return Math.min(1, this.progress / this.duration);
  }

  /**
   * 紧凑版里控制键的浮现进度（0.52~0.78）。
   * 封面和歌名 0.42 就出来了，三个键晚半步跟上——
   * 一排内容从左往右依次长出来，比整条一起淡入更像「拼装」。
   * 展开态不受影响，始终是 1。
   */
  private controlStage(): number {
    if (!this.inline) {
      return 1;
    }
    const c = Math.max(0, Math.min(1, this.bar));
    return this.easeOut((c - 0.48) / 0.26);
  }

  private easeOut(v: number): number {
    const t = Math.max(0, Math.min(1, v));
    return 1 - Math.pow(1 - t, 3);
  }

  /** 点整条 / 封面 / 文字都进播放页。三处都绑，避免某层吞掉事件后整条死掉 */
  private enter(): void {
    if (!this.live()) {
      return;
    }
    App.get().openPlayer();
  }

  /**
   * 这一层现在算不算「在场」。
   *
   * 紧凑版和展开态的三格标签是同一块像素，展开时它整层透明地压在图标上。
   * 父层已经用 enabled 整棵关掉了，这里再兜一道：
   * 万一个别机型上禁用没生效，用户点「发现」也不会莫名其妙掉进播放页。
   */
  private live(): boolean {
    return !this.inline || this.bar >= 0.34;
  }


  build() {
    if (this.hasSong) {
      // 高光垫在内容下面：以前是 .overlay()，白渐变直接盖在封面和文字上，
      // 收起态的封面被冲成半透明灰（真机视频里尤其明显），和旁边纯黑的
      // 播放三角放一起，比例和层次都不对。改成 Stack 打底，画在内容之下。
      Stack({ alignContent: Alignment.TopStart }) {
        if (!this.inline) {
          this.glassHighlight(22)
          this.depthLayer()
        }
        Column() {
          Row({ space: this.inline ? 8 : 10 }) {
            Stack() {
              Cover({
                uri: this.song.cover,
                songId: CoverRepo.keyOf(this.song),
                side: this.inline ? 36 : 40,
                radius: 10
              })
            }
            .onClick(() => {
              this.enter();
            })
            Column({ space: 2 }) {
              Text(this.song.name.length > 0 ? this.song.name : '暂无播放')
                .fontSize(this.inline ? 13.5 : FONT.callout)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.p().text)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.MARQUEE })
                .marqueeOptions({ start: true, loop: -1, step: 2, fromStart: true })
                .width('100%')
              Text(this.song.singer.length > 0 ? this.song.singer : '选一首歌开始')
                .fontSize(this.inline ? 10.5 : FONT.micro)
                .fontColor(this.p().text3)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.MARQUEE })
                .marqueeOptions({ start: true, loop: -1, step: 2, fromStart: true })
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .onClick(() => {
              this.enter();
            })

            // 三个控制键比封面/歌名晚一步（0.52~0.78），一排内容从左往右长出来
            Row() {
              this.transport()
            }
            .opacity(this.controlStage())
          }
          .width('100%')
          .padding({
            left: this.inline ? 0 : 8,
            right: this.inline ? 4 : 6,
            top: this.inline ? 0 : 7,
            bottom: this.inline ? 0 : 7
          })

          // 进度细线（贴底）：紧凑版塞不进 52 高，直接省掉
          if (!this.inline) {
            Stack({ alignContent: Alignment.Start }) {
              Row()
                .width('100%')
                .height(2)
                .backgroundColor(withAlpha(this.p().text3, 0.18))
              Row()
                .width((this.ratio() * 100).toFixed(2) + '%')
                .height(2)
                .backgroundColor(this.p().primary)
            }
            .width('100%')
            .height(2)
            .margin({ bottom: 1 })
          }
        }
        .width('100%')
        .height(this.inline ? 52 : 58)
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .height(this.inline ? 52 : 58)
      .borderRadius(this.inline ? 26 : 22)
      // 紧凑版的底板由外层那只「栏体」提供，这里不能再画一层，
      // 否则收起过程中会看到两条圆角不一样的胶囊边线叠在一起。
      .backgroundColor(this.inline ? '#00000000' : glassCardBase(this.isDark))
      // v2.52 墨栈：中性实色底 + 1vp 等宽发丝边 + 中性紧投影，无发光无光晕。
      // 同样不叠 backgroundBlurStyle，避免模糊材质盖掉渐变。
      .linearGradient(this.inline ? {
        angle: 180,
        colors: [['#00000000', 0], ['#00000000', 1]]
      } : {
        angle: 180,
        colors: glassSurface(this.isDark, this.lightLevel)
      })
      .border(this.inline ? { width: 0 } : {
        width: glassEdgeWidth(this.lightLevel),
        color: glassEdgeColor(this.isDark, this.lightLevel)
      })
      .shadow(this.inline ? { radius: 0, color: '#00000000' } : glassShadow(this.isDark, this.lightLevel))
      .clip(true)
      .stateStyles({
        normal: { .opacity(1).scale({ x: 1, y: 1 }) },
        pressed: { .opacity(0.92).scale({ x: 0.985, y: 0.985 }) }
      })
      .animation({ duration: 120, curve: Curve.EaseOut })
      .onClick(() => {
        this.enter();
      })
    }
  }
}

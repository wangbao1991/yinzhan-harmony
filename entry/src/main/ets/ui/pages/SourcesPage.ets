import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { ImportIntent } from '../../core/ImportIntent';
import {
  palette, Palette, RADIUS, FONT, PAGE_PAD, PAGE_BOTTOM, MINI_BAR_SPACE,
  glassCardBase, glassSurface, glassEdgeWidth, glassEdgeColor, glassShadow
} from '../../common/Constants';
import { SourceItem } from '../../common/Models';
import { platformShort } from '../../common/Platform';
import { App } from '../../core/App';
import { Settings } from '../../core/Settings';
import { SourceRepo, HealthProgress, CheckSummary } from '../../core/SourceRepo';
import { EmptyView, LoadingBlock, PageBar, SelectionBar, TinyBadge, ImmersiveBar } from '../Common';

/**
 * 拖到屏幕上下边缘时的自动滚屏参数。
 * EDGE 是 List 可视区上下各留的一条触发带：手指进带即开始滚动，
 * 越靠边速度越快；TICK 按约 16ms 一帧推进，和 UI 帧率对齐。
 */
const AUTO_EDGE: number = 110;
const AUTO_MIN_SPEED: number = 3;
const AUTO_MAX_SPEED: number = 14;
const AUTO_TICK_MS: number = 16;

/**
 * 左滑区的一枚「信号琥珀」圆钮（v2.52 墨栈：中性实底 + 墨字）。
 *
 * 主体是青绿→蓝的 135° 斜向渐变，上面再叠一层纵向白渐变做「上沿弧光、
 * 中段通透、下沿宽反光」——和 Constants.glassSurface 同一套语言，只是收进
 * 一颗圆里。外圈半透明亮边 + 青蓝外投影，白图标居中，下方一行小字标功能。
 * 独立 @Component：@Prop 单向同步，主题/状态变化时按钮跟着重绘，不会像
 * 带参 @Builder 那样按值传参只生效一次。
 */
@Component
struct SourceSwipeButton {
  @Prop icon: Resource = $r('sys.symbol.checkmark_circle');
  @Prop label: string = '';
  /** 四枚按钮订阅同一份深浅色：配色只在这里算一次，不会各画各的 */
  @StorageProp('isDark') isDark: boolean = false;
  onTap: () => void = (): void => {
  };

  /**
   * v2.52：图标统一用墨色（onSignal），压在琥珀信号实底上。
   * v2.18 再淡一档：不透明度由 ~0.75/0.8 降到 ~0.41/0.46，色相往圆钮的
   * 青绿主色靠，图标轻得像从玻璃里透出来，不再和上沿弧光抢对比度。
   * 四枚共用这一个方法，深浅色都跟随全局，保持完全一致。
   */
  private iconColor(): string {
    // v2.52 墨栈：琥珀信号实底上的图标统一用墨色（onSignal 7.57:1），不再低饱和青蓝
    return '#FF191713';
  }

  /** 小字不再用纯白：亮玻璃上压深蓝近黑，深色玻璃上转淡蓝 */
  private labelColor(): string {
    // 小字压页面底，用中性次文字色
    return palette(this.isDark).text2;
  }


  build() {
    Column({ space: 3 }) {
      Stack() {
        // v2.52 墨栈：信号琥珀实体，饱和色相只占这一小块芯片
        Column()
          .width(40)
          .height(40)
          .borderRadius(20)
          .linearGradient({
            angle: 135,
            colors: [['#FFE29A26', 0], ['#FFF3B044', 1]]
          })
        // v2.52：发光层退场（透明），芯片就是一块纯琥珀信号面
        Column()
          .width(40)
          .height(40)
          .borderRadius(20)
          .linearGradient({
            angle: 180,
            // v2.52 墨栈：去光化，白色弧光高光层退场（全透明，保留节点）
            colors: [['#00FFFFFF', 0], ['#00FFFFFF', 1]]
          })
        // sys.symbol 里有的图标自带分层/多色绘制，只给一个 fontColor 时
        // 各层仍按自己的默认色与不透明度出图，四枚看起来就不是一个颜色。
        // 显式 SINGLE 强制整枚符号只吃第一色，再统一用 iconColor 压淡。
        SymbolGlyph(this.icon)
          .fontSize(19)
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          .fontColor([this.iconColor()])
      }
      .width(40)
      .height(40)
      .borderRadius(20)
      .border({ width: 1, color: palette(this.isDark).glassBorder })
      .shadow({ radius: 6, color: 'rgba(27,26,24,0.10)', offsetY: 2 })
      .clip(true)

      Text(this.label)
        .fontSize(9)
        .fontColor(this.labelColor())
    }
    .alignItems(HorizontalAlign.Center)
    .stateStyles({
      normal: { .opacity(1).scale({ x: 1, y: 1 }) },
      pressed: { .opacity(0.7).scale({ x: 0.9, y: 0.9 }) }
    })
    .animation({ duration: 120, curve: Curve.EaseOut })
    .onClick(() => {
      this.onTap();
    })
  }
}

/**
 * v2.53 包 1：自检结果区里的一条未通过记录。
 * 只做展示用，不改 SourceRepo 的 CheckFailItem，也不往磁盘写任何东西。
 */
interface CheckReportRow {
  name: string;
  message: string;
}

/**
 * v2.53 包 1：自检结论超过这个时长，界面要提示「结论可能已过时」。
 * 结论是真的，时间也是真的——不替用户判断还能不能用，只把时效说出来。
 */
const CHECK_STALE_MS: number = 24 * 60 * 60 * 1000;

/**
 * v2.53 包 1：状态形状四档。
 *
 * 《墨栈》规范 08 节硬条款要求「色相不得作为唯一编码」。v2.52 及以前只有一颗
 * 6vp 圆点，正常绿 / 未通过琥珀 / 小问题玫红全靠颜色区分，色觉缺陷或强光下
 * 就只剩「这行字有点颜色」。四档各配一个几何形状后，形状本身就能读出结论：
 *   实心圆 = 自检通过   实心三角 = 不可用 / 自检未通过
 *   空心方 = 自检中     空心圆 = 未检测
 *
 * 形状全部用 Shape + Path 自绘：不赌字体里有没有 ●✓△□ 这些字形（不同设备
 * 字体覆盖不一致会draw成豆腐块），也不新增任何色值——取色仍走 palette。
 */
enum SourceMark {
  PASS = 0,
  WARN = 1,
  WAIT = 2,
  IDLE = 3
}

/**
 * 形状判定必须与 statusText / statusColor 同源，否则会出现「形状说通过、
 * 文案说未通过」的自相矛盾。优先级也照抄 statusText：自检中 → 装载失败 →
 * 载入中 → 已载入（再看自检结论）→ 其它。
 */
function statusMark(item: SourceItem): SourceMark {
  if (item.health === 'checking') {
    return SourceMark.WAIT;
  }
  if (item.status === 'error') {
    return SourceMark.WARN;
  }
  if (item.status === 'checking') {
    return SourceMark.WAIT;
  }
  if (item.status === 'ok') {
    if (item.health === 'error') {
      return SourceMark.WARN;
    }
    if (item.health === 'ok') {
      return SourceMark.PASS;
    }
    return SourceMark.IDLE;
  }
  return SourceMark.IDLE;
}

/**
 * v2.53 包 1：把 checkedAt 时间戳翻成人话。
 *
 * checkedAt 从 v2.47 起就持久化、也进了 ForEach key，但界面从来没展示过，
 * 于是「这个源上次什么时候验的」只有磁盘知道。用户看到一颗绿点无法判断
 * 是三分钟前验的还是三天前验的。
 */
function relativeCheck(at: number, now: number): string {
  if (at <= 0) {
    return '';
  }
  const diff = now - at;
  if (diff < 60000) {
    return '刚刚';
  }
  const min = Math.floor(diff / 60000);
  if (min < 60) {
    return min.toString() + ' 分钟前';
  }
  const hour = Math.floor(min / 60);
  if (hour < 24) {
    return hour.toString() + ' 小时前';
  }
  return Math.floor(hour / 24).toString() + ' 天前';
}

/** 结论是否已经超过一天（只用于决定要不要提示「可能已过时」，不改任何判定） */
function checkStale(item: SourceItem, now: number): boolean {
  return item.checkedAt > 0 && now - item.checkedAt > CHECK_STALE_MS;
}

/** 状态行右侧的时间后缀；没自检过就不占位置 */
function checkLabel(item: SourceItem, now: number): string {
  if (item.checkedAt <= 0) {
    return '';
  }
  const rel = relativeCheck(item.checkedAt, now);
  if (rel.length === 0) {
    return '';
  }
  return checkStale(item, now) ? '上次自检 ' + rel + ' · 可能已过时' : '上次自检 ' + rel;
}

function statusColor(item: SourceItem, paletteRef: Palette): string {
  // v2.47：颜色必须跟着「上一次自检结论」走。
  // 之前 status 为 ok 时只把 error 降成灰字，用户看到一颗绿点 + 一句灰字，
  // 观感仍然是「正常」，于是「自检未通过」和「正常」同时出现在一张卡上。
  if (item.status === 'error') {
    return paletteRef.danger;
  }
  if (item.health === 'checking' || item.status === 'checking') {
    return paletteRef.primary;
  }
  if (item.status === 'ok') {
    if (item.health === 'error') {
      return paletteRef.accent;
    }
    if (item.health === 'ok') {
      return paletteRef.success;
    }
    // 装载好了但还没自检：中性色，不冒充「正常」
    return paletteRef.text2;
  }
  return paletteRef.text3;
}

function statusText(item: SourceItem): string {
  if (item.health === 'checking') {
    return '自检中…';
  }
  if (item.status === 'error') {
    // v2.43：这里只反映「脚本装载」失败。自检结论单独放说明行，
    // 不再把一次取链超时显示成「不可用」，也就不会逼用户逐个刷新。
    const msg = item.message.length > 0 ? item.message : '脚本未载入';
    return msg.length > 18 ? msg.substring(0, 18) + '…' : msg;
  }
  if (item.status === 'checking') {
    return '载入中…';
  }
  if (item.status === 'ok') {
    // v2.47：「正常」这句只留给真的自检通过的源。
    // 从没自检过写「已就绪 · 未自检」，自检没过写「自检未通过」，都不再说「正常」。
    if (item.health === 'error') {
      return '自检未通过';
    }
    if (item.health === 'ok') {
      return item.latency > 0 ? '正常 · ' + item.latency.toString() + 'ms' : '正常';
    }
    return '已就绪 · 未自检';
  }
  return '未载入';
}

/**
 * 音源管理。
 *
 * 洛雪音源就是一段 js，导入后落到应用沙箱、注入 WebView 沙箱执行。
 * 这里负责：导入 / 启停 / 排序（决定取链顺序）/ 自检 / 检查更新 / 删除。
 */
@Component
export struct SourcesPage {
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;
  @StorageProp('topSafe') topSafe: number = 24;
  @StorageProp('sourcesReady') sourcesReady: boolean = false;
  @State items: SourceItem[] = [];
  @State importing: boolean = false;
  @State activeId: string = '';
  @State menuShow: boolean = false;
  @State menuTarget: string = '';
  @State renameMode: boolean = false;
  @State renameName: string = '';
  /** 网络导入：sheet 里的第二个形态 */
  @State netMode: boolean = false;
  @State netUrl: string = '';
  @State netBusy: boolean = false;
  /** 导出 / 删除：多选模式（v2.48 起同时承担批量删除） */
  @State selectMode: boolean = false;
  @State selected: string[] = [];
  @State exporting: boolean = false;
  /** 批量删除进行中：卸载脚本是有 await 的，期间禁用两颗按钮避免重复提交 */
  @State removing: boolean = false;
  /** 从设置页搬进来的：当前首选概览 + 取链 / 下载选项 */
  @State activeName: string = '未设置';
  @State okCount: number = 0;
  /** v2.47：上次自检未通过的音源数（顶部汇总与卡片口径一致，不再只报「可用」） */
  @State failCount: number = 0;
  @State smartHunt: boolean = true;
  @State preferOnly: boolean = false;
  @State allowDowngrade: boolean = false;
  @State verifyBeforeDownload: boolean = false;
  @State autoFallback: boolean = true;
  /** 记住「这首歌上次是哪个源给的」，下次优先问它 */
  @State rememberSource: boolean = true;
  /** 重建全部音源（整页重置后重新注入），用于「都加载了但一个都没就绪」 */
  @State rebuilding: boolean = false;
  @State pendingCount: number = 0;
  /** 批量自检：逐平台试基准曲，结论与卡片上的单源自检一致 */
  @State checking: boolean = false;
  @State checkDone: number = 0;
  @State checkTotal: number = 0;
  /** 启动时自动跑一轮自检，结果只更新卡片状态 */
  @State autoCheckSources: boolean = false;
  /**
   * v2.53 包 1（L3 持久结果区）：批量自检的结论不再只活 2 秒 toast 里。
   *
   * 以前点「全部自检」，跑完一行 toast 一闪而过，中途切到别的页再回来就什么
   * 都不剩——用户只知道「刚才好像检过」。现在把 CheckSummary 摊开存成几个
   * 基础字段（不用嵌套对象，避免 ArkUI 对深层字段的刷新盲区），卡片上常驻
   * 一条可复查、可关闭的结果。
   */
  @State reportAt: number = 0;
  @State reportTotal: number = 0;
  @State reportOk: number = 0;
  @State reportSkipped: number = 0;
  @State reportFailed: CheckReportRow[] = [];
  @State reportClosed: boolean = false;
  /** 相对时间的基准：每 60 秒推进一次，「3 分钟前」会自己变成「4 分钟前」 */
  @State nowTs: number = Date.now();
  private clockTimer: number = -1;
  /** v2.51：7 项低频取链 / 下载选项默认收起，点折叠头展开 */
  @State settingsExpanded: boolean = false;
  /**
   * v2.56 响应式：操作行实测可用宽（vp）。0 表示还没量到，先按四列画，
   * 量到后如果每格不足 60vp 就自动换成 2×2 —— 不让「本地导入 / 网络导入 /
   * 全部自检 / 选择」在窄屏上被压成四个竖条。
   */
  @State actionW: number = 0;
  /** 系统字体放大倍率（EntryAbility 写入）：≥1.5 时按钮文字会溢出，强制 2×2 */
  @StorageProp('fontScale') fontScale: number = 1;
  /** 短长按拖动排序：整页同一时刻只允许一张卡处于拖动态 */
  @State dragActive: boolean = false;
  @State dragId: string = '';
  /** 拖动位移（手指 + 实测滚动补偿）：v2.19 起只用于算落位下标，不再承担绘制 */
  @State dragOffsetY: number = 0;
  /** 拖动中实时算出的目标下标：其它卡片据此顺次让位，松手按它落库 */
  @State dragToIndex: number = -1;
  private dragStartIndex: number = -1;
  /**
   * v2.19 拖动浮层：跟手那张卡搬到页面 Stack 顶层独立绘制，
   * 不再靠 ListItem 里的 .translate —— 后者改绘制不改布局槽位，
   * 列表一滚过显示区窗口整块就不画了（白块）。
   * 用长度 0/1 的数组存被拖项，避开 @State 联合类型的限制。
   */
  @State dragCards: SourceItem[] = [];
  /** 浮层相对页面 Stack 顶部的 y（vp）：只跟手指，不随列表滚动 */
  @State ghostY: number = 0;
  /** 按下瞬间被拖卡片相对页面 Stack 的 y */
  private ghostBaseY: number = 0;
  /** 页面最外层 Stack 在窗口坐标系中的 y，把 globalPosition 换算成 Stack 坐标 */
  private stackTop: number = 0;
  /** 各卡片当前在窗口坐标系中的顶部 y（卡片 onAreaChange 采集） */
  private cardTops: Map<string, number> = new Map<string, number>();
  /** 拖动起始时列表的实测滚动偏移，补偿量不再靠累加期望值 */
  private dragStartOffsetY: number = 0;
  /** 拖动收尾后短时间内压住 Tap，避免抬手被判成「点击设为首选」 */
  private suppressTap: boolean = false;
  /** 名称文字点开菜单的时刻：拦住同一次触摸顺带触发的「设为首选」 */
  private menuTapAt: number = 0;
  /** 每张音源卡的实测高度（按 id 存，不受 List 顶部工具条影响下标） */
  private cardHeights: Map<string, number> = new Map<string, number>();

  /**
   * 拖到屏幕上下边缘时的「自动滚屏」。
   *
   * v2.16 只能把卡片拖到当前可见的那几格：手指一顶到屏幕边缘，位移就
   * 不再增长，目标下标也停住，屏幕外的音源怎么都够不到。现在 List 绑
   * Scroller，手指进入上下边缘触发带后由定时器持续滚动，滚动补偿量
   * scrollAccum 与手指位移 panOffsetY 一起并入 dragOffsetY：
   *   - 被拖卡片 translate = panOffsetY + scrollAccum，列表往上滚多少，
   *     它就往下补多少，于是始终贴在手指底下，不会跟着列表跑掉；
   *   - 同一份位移继续喂给 dragTargetIndex，目标下标能越过当前视口，
   *     一路推进到列表端点，shiftY 的让位也跟着一路生效。
   */
  private listScroller: Scroller = new Scroller();
  /** 手指相对按下点的纵向位移（PanGesture.offsetY 的最新值） */
  private panOffsetY: number = 0;
  /** 自动滚动补偿量：v2.19 起每帧由 Scroller 实测偏移校正，不再是期望值累加 */
  private scrollAccum: number = 0;
  /** -1 向上滚 / 0 停 / 1 向下滚 */
  private autoDir: number = 0;
  /** 手指深入触发带的比例 0~1，越靠边滚得越快 */
  private autoDepth: number = 0;
  private autoTimer: number = -1;
  /** List 在窗口坐标系中的可视区域，用来判定「手指到边缘了没」 */
  private listTop: number = 0;
  private listH: number = 0;
  private settings: Settings = Settings.get();
  private repo: SourceRepo = SourceRepo.get();
  private listener: () => void = (): void => {
  };

  /** 页面是否还在前台：自检是长任务，离开页面后不再回写 @State */
  private alive: boolean = true;

  aboutToAppear(): void {
    this.alive = true;
    this.listener = (): void => {
      this.refresh();
    };
    this.repo.onChange(this.listener);
    this.smartHunt = this.settings.smartHunt();
    this.preferOnly = this.settings.preferOnly();
    this.allowDowngrade = this.settings.allowDowngrade();
    this.verifyBeforeDownload = this.settings.verifyBeforeDownload();
    this.autoFallback = this.settings.autoFallbackOnFailure();
    this.rememberSource = this.settings.rememberSource();
    this.autoCheckSources = this.settings.autoCheckSources();
    this.refresh();
    // v2.53：「上次自检 3 分钟前」要能自己走字，否则页面停一小时还写着「刚刚」
    this.clockTimer = setInterval((): void => {
      if (this.alive) {
        this.nowTs = Date.now();
      }
    }, 60000);
  }

  aboutToDisappear(): void {
    this.alive = false;
    if (this.clockTimer !== -1) {
      clearInterval(this.clockTimer);
      this.clockTimer = -1;
    }
    this.stopAutoScroll();
    this.repo.offChange(this.listener);
  }

  private refresh(): void {
    this.items = this.repo.list().slice();
    this.activeId = this.repo.getActiveId();
    const active = this.repo.find(this.activeId);
    this.activeName = active !== null ? active.name : '未设置';
    // v2.53：okCount 从「脚本装载成功」收紧成「真的自检通过」。
    // 原来的口径是 status==='ok'，于是没自检过的源也被算进「已就绪」，
    // 顶部数字看着挺好、卡片却写着「已就绪 · 未自检」——正是 v2.47 用户投诉的
    // 「没过却显示正常」的另一处残留。现在顶部与卡片用同一份判定。
    let ok = 0;
    for (const item of this.items) {
      if (item.status === 'ok' && item.health === 'ok') {
        ok++;
      }
    }
    this.okCount = ok;
    let fail = 0;
    for (const item of this.items) {
      if (item.health === 'error') {
        fail++;
      }
    }
    this.failCount = fail;
    const runner = this.repo.getRunner();
    let pending = 0;
    for (const item of this.items) {
      if (item.enabled && runner !== null && runner.isLoaded(item.id) && !runner.isInited(item.id)) {
        pending++;
      }
    }
    this.pendingCount = pending;
    // 刷新数据时同步推进相对时间基准，避免「刚自检完」还显示上一次的旧时间
    this.nowTs = Date.now();
  }

  private async checkAll(): Promise<void> {
    if (this.checking) {
      return;
    }
    let total = 0;
    for (const item of this.items) {
      if (item.enabled) {
        total++;
      }
    }
    if (total === 0) {
      App.get().toast('先启用至少一个音源');
      return;
    }
    this.checking = true;
    this.checkDone = 0;
    this.checkTotal = total;
    App.get().toast('开始自检：逐个音源按平台试基准曲，会比较慢');
    const summary: CheckSummary = await this.repo.checkAll((progress: HealthProgress) => {
      if (!this.alive) {
        return;
      }
      this.checkDone = progress.done;
      this.checkTotal = progress.total;
      this.refresh();
    });
    this.checking = false;
    this.refresh();
    // v2.53 L3：把这一轮结论摊成可复查的一段，而不是只丢一句 toast
    this.reportAt = summary.at;
    this.reportTotal = summary.total;
    this.reportOk = summary.ok;
    this.reportSkipped = summary.skipped;
    const rows: CheckReportRow[] = [];
    for (const fail of summary.failed) {
      rows.push({ name: fail.name, message: fail.message });
    }
    this.reportFailed = rows;
    this.reportClosed = false;
    // 措辞与卡片状态字典对齐：卡片写「正常 / 自检未通过」，toast 不另造词
    App.get().toast('自检完成：' + summary.ok.toString() + ' 个正常 · ' +
      summary.failed.length.toString() + ' 个自检未通过' +
      (summary.skipped > 0 ? ' · 跳过 ' + summary.skipped.toString() + ' 个平台' : ''));
  }

  private async rebuildAll(): Promise<void> {
    if (this.rebuilding) {
      return;
    }
    this.rebuilding = true;
    App.get().toast('正在重建音源沙箱，稍等…');
    await this.repo.reloadAll();
    this.rebuilding = false;
    this.refresh();
    App.get().toast(this.pendingCount === 0 ? '音源已全部就绪' : '仍有 ' + this.pendingCount.toString() + ' 个未就绪');
  }

  private p(): Palette {
    return palette(this.isDark);
  }

  /** 实际参与取链的音源数：只有「已启用 + 脚本已加载成功」的才会被问到 */
  private sourceStat(): string {
    const runner = this.repo.getRunner();
    let enabled = 0;
    let loaded = 0;
    let ready = 0;
    for (const item of this.items) {
      if (!item.enabled) {
        continue;
      }
      enabled++;
      if (runner !== null && runner.isLoaded(item.id)) {
        loaded++;
        // 「加载」只说明脚本没语法错误；真正能取链要等它上报 inited 平台清单
        if (runner.isInited(item.id)) {
          ready++;
        }
      }
    }
    return '已启用 ' + enabled.toString() + ' 个 · 已加载 ' + loaded.toString() +
      ' 个 · 已就绪 ' + ready.toString() + ' 个';
  }

  /** 与外部「打开方式」共用同一套读取逻辑（循环读，避免大脚本被截断） */
  private readText(uri: string): string {
    return ImportIntent.readText(uri);
  }

  private async importScript(): Promise<void> {
    if (this.importing) {
      return;
    }
    const context = getContext(this) as common.UIAbilityContext;
    this.importing = true;
    try {
      const viewPicker = new picker.DocumentViewPicker(context);
      const options = new picker.DocumentSelectOptions();
      // 一次最多 20 个：装了十几个源的人换一批时不用来回点四五次
      options.maxSelectNumber = 20;
      options.fileSuffixFilters = ['.js', '.txt'];
      const uris = await viewPicker.select(options);
      if (uris.length === 0) {
        this.importing = false;
        return;
      }
      let ok = 0;
      let lastError = '';
      for (const uri of uris) {
        const rawName = uri.substring(uri.lastIndexOf('/') + 1);
        let name = rawName;
        try {
          name = decodeURIComponent(rawName);
        } catch (e) {
          // 名字里没有百分号编码时 decode 会抛，保持原样即可
        }
        try {
          const code = this.readText(uri);
          if (code.trim().length === 0) {
            lastError = '「' + name + '」是空文件';
            continue;
          }
          await this.repo.importCode(code, name);
          ok++;
        } catch (e) {
          // 最常见的原因是选到了云盘 / 在线文件：picker 能列出它，
          // 但脚本要落盘到应用沙箱，读不出来。这里把原因说清楚，
          // 而不是统一报「导入失败」。
          const detail = e instanceof Error ? e.message : String(e);
          lastError = '「' + name + '」读取失败（' + detail + '），如果它在云盘请先下载到本机';
        }
      }
      this.refresh();
      if (ok > 0) {
        App.get().toast('已导入 ' + ok.toString() + ' 个音源');
      } else {
        App.get().toast(lastError.length > 0 ? lastError : '导入失败：没有读到脚本内容');
      }
    } catch (e) {
      App.get().toast('打开文件选择器失败');
    }
    this.importing = false;
  }

  /**
   * 网络导入：把链接里的脚本文本拉下来直接导入。
   * 支持一次粘贴多个链接（每行一个），逐个下载，成功的计入结果。
   */
  private async importFromNet(): Promise<void> {
    if (this.netBusy) {
      return;
    }
    const urls: string[] = [];
    for (const part of this.netUrl.split('\n')) {
      const url = part.trim();
      if (url.startsWith('http://') || url.startsWith('https://')) {
        urls.push(url);
      }
    }
    if (urls.length === 0) {
      App.get().toast('请粘贴 http / https 开头的脚本链接');
      return;
    }
    this.netBusy = true;
    let ok = 0;
    let lastError = '';
    for (const raw of urls) {
      const url = this.normalizeUrl(raw);
      try {
        const code = await SourceRepo.httpText(url);
        // 网页 / HTML 中转页（失效源）：只提示一次，别整段丢给音源沙箱执行
        if (SourceRepo.looksLikeWebPage(code)) {
          lastError = '链接返回的是网页或跳转页（该源可能已失效），请用脚本文件的 raw 直链';
          continue;
        }
        // MusicFree 订阅清单（plugins.json）：本身是 JSON，不是可执行脚本。
        // 展开成清单里的插件直链逐个下载导入，不要整段丢给音源沙箱执行。
        if (SourceRepo.isSubscription(code)) {
          const subs = SourceRepo.parseSubscription(code);
          let subOk = 0;
          let expired = 0;
          for (const sub of subs) {
            try {
              const pluginCode = await SourceRepo.httpText(this.normalizeUrl(sub));
              // 订阅里的单个插件也可能是失效的 HTML 中转页，跳过不计入成功
              if (SourceRepo.looksLikeWebPage(pluginCode) || pluginCode.trim().length < 100) {
                expired++;
                continue;
              }
              await this.repo.importCode(pluginCode, this.urlFileName(sub));
              subOk++;
            } catch (e2) {
              lastError = '订阅里的插件下载失败：' + (e2 instanceof Error ? e2.message : String(e2));
            }
          }
          ok += subOk;
          if (ok === 0 && expired > 0) {
            lastError = '订阅里的插件链接均已失效（返回网页），请换一个订阅源';
          }
          continue;
        }
        if (code.trim().length < 100) {
          lastError = '链接返回的内容不是音源脚本';
          continue;
        }
        await this.repo.importCode(code, this.urlFileName(url));
        ok++;
      } catch (e) {
        lastError = e instanceof Error ? e.message : '下载失败';
      }
    }
    this.netBusy = false;
    this.refresh();
    if (ok > 0) {
      this.netMode = false;
      this.netUrl = '';
      this.menuShow = false;
      App.get().toast('已从网络导入 ' + ok.toString() + ' 个音源');
    } else {
      App.get().toast(lastError.length > 0 ? lastError : '导入失败');
    }
  }

  /**
   * 常见的「网页版」链接自动转成 raw 直链：
   * GitHub 的 /blob/ 页面、jsDelivr 之外的形式都能直接下到脚本正文。
   */
  private normalizeUrl(url: string): string {
    const clean = url.trim();
    if (clean.indexOf('github.com/') >= 0 && clean.indexOf('/blob/') >= 0) {
      return clean.replace('github.com/', 'raw.githubusercontent.com/').replace('/blob/', '/');
    }
    return clean;
  }

  /** 从 URL 末段猜文件名：去掉 query、解码中文 */
  private urlFileName(url: string): string {
    let tail = url;
    const query = tail.indexOf('?');
    if (query >= 0) {
      tail = tail.substring(0, query);
    }
    const slash = tail.lastIndexOf('/');
    if (slash >= 0) {
      tail = tail.substring(slash + 1);
    }
    try {
      tail = decodeURIComponent(tail);
    } catch (e) {
      // 链接里没有合法转义，保留原样
    }
    return tail.length > 0 ? tail : '网络音源.js';
  }

  /** 卡片底部说明行：正常卡片沿用脚本描述，报错 / 无描述时给真实可操作提示 */
  private cardHint(item: SourceItem): string {
    if (item.status === 'error') {
      return '点名字可刷新 / 重新导入 / 删除；MusicFree 订阅请用「从网络导入」粘贴订阅链接';
    }
    if (item.health === 'error') {
      // v2.46：自检把真实结论写进 message（例如「取链失败：插件取链异常…」），
      // 优先如实展示，不再用一句笼统的「可能是网络 / 版权限制」盖掉具体原因。
      const reason = item.message.length > 0
        ? (item.message.length > 60 ? item.message.substring(0, 60) + '…' : item.message)
        : '本次自检未通过';
      return reason + '；脚本已就绪，仍会被搜索问到，可点「自检」重试';
    }
    if (item.description.length > 0) {
      return item.description;
    }
    if (item.kind === 'musicfree') {
      return 'MusicFree 插件 · 提供单曲搜索与播放地址';
    }
    return '洛雪音源脚本 · 提供播放地址与歌词';
  }

  /**
   * v2.56：音源卡信息区的读屏语句，按「{名称}，{角色}，{状态}」拼。
   * 卡片是列表里信息最密的一处（名称 / 首选 / 启用态 / 自检态 / 版本 / 平台），
   * 不合并的话读屏要点十几下才听得完。
   */
  private cardLabel(item: SourceItem): string {
    let text: string = item.name + '，音源，' + (item.enabled ? '已启用' : '已停用');
    if (this.activeId === item.id) {
      text += '，首选';
    }
    text += '，' + statusText(item);
    if (item.checkedAt > 0) {
      text += '，' + checkLabel(item, this.nowTs);
    }
    return text;
  }

  /* ---------------- 多选（导出 / 批量删除） ---------------- */

  private isSelected(id: string): boolean {
    return this.selected.indexOf(id) >= 0;
  }

  /** 音源卡：拖动中一圈品牌蓝高亮，选中态同样一圈，其余四边玻璃亮边；三个分支都是四边对象 */
  private sourceCardEdgeWidth(id: string): EdgeWidths {
    if (this.dragActive && this.dragId === id) {
      return { top: 2, right: 2, bottom: 2, left: 2 };
    }
    if (this.selectMode && this.isSelected(id)) {
      return { top: 1.5, right: 1.5, bottom: 1.5, left: 1.5 };
    }
    return glassEdgeWidth(this.lightLevel);
  }

  private sourceCardEdgeColor(id: string): EdgeColors {
    if (this.dragActive && this.dragId === id) {
      const c: string = this.p().primary;
      return { top: c, right: c, bottom: c, left: c };
    }
    if (this.selectMode && this.isSelected(id)) {
      const c: string = this.p().primary;
      return { top: c, right: c, bottom: c, left: c };
    }
    return glassEdgeColor(this.isDark, this.lightLevel);
  }

  private toggleSelect(id: string): void {
    const list = this.selected.slice();
    const index = list.indexOf(id);
    if (index >= 0) {
      list.splice(index, 1);
    } else {
      list.push(id);
    }
    this.selected = list;
  }

  private allSelected(): boolean {
    return this.items.length > 0 && this.selected.length === this.items.length;
  }

  private toggleAll(): void {
    if (this.allSelected()) {
      this.selected = [];
      return;
    }
    const list: string[] = [];
    for (const item of this.items) {
      list.push(item.id);
    }
    this.selected = list;
  }

  private enterSelect(): void {
    if (this.items.length === 0) {
      App.get().toast('还没有可选择的音源');
      return;
    }
    this.selected = [];
    this.selectMode = true;
  }

  private exitSelect(): void {
    this.selectMode = false;
    this.selected = [];
  }

  /**
   * 页内临时态：选择模式下按返回先退出选择，第二次返回才交给浮层 / 退页。
   * v2.55：顺序本身由 App.consumeBack 统一定义，本页只声明「有这一层」。
   */
  private localBack(): boolean {
    if (!this.selectMode) {
      return false;
    }
    this.exitSelect();
    return true;
  }

  /** 文件名兜底：去掉文件系统不认的字符，补 .js */
  private safeName(raw: string, fallback: string): string {
    let name = raw.trim().length > 0 ? raw.trim() : fallback.trim();
    if (name.length === 0) {
      name = '音源';
    }
    name = name.replace(/[\\/:*?"<>|]/g, '_');
    if (!name.toLowerCase().endsWith('.js')) {
      name = name + '.js';
    }
    return name;
  }

  /**
   * 导出勾选的音源：一次把文件名交给系统保存面板，用户只需选一个目录。
   * 返回的 uri 与文件一一对应，逐个把脚本原文写进去。
   */
  private async exportSelected(): Promise<void> {
    if (this.exporting) {
      return;
    }
    const list: SourceItem[] = [];
    for (const item of this.items) {
      if (this.isSelected(item.id)) {
        list.push(item);
      }
    }
    if (list.length === 0) {
      App.get().toast('先勾选要导出的音源');
      return;
    }
    const context = getContext(this) as common.UIAbilityContext;
    const names: string[] = [];
    const used: string[] = [];
    for (const item of list) {
      let name = this.safeName(item.fileName, item.name);
      if (used.indexOf(name) >= 0) {
        name = name.substring(0, name.length - 3) + '-' + (used.length + 1).toString() + '.js';
      }
      used.push(name);
      names.push(name);
    }
    this.exporting = true;
    try {
      const viewPicker = new picker.DocumentViewPicker(context);
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = names;
      options.fileSuffixChoices = ['.js'];
      const uris = await viewPicker.save(options);
      if (uris.length === 0) {
        this.exporting = false;
        return;
      }
      let ok = 0;
      for (let i = 0; i < uris.length && i < list.length; i++) {
        try {
          const code = this.readText(list[i].path);
          const file = fs.openSync(uris[i], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
          fs.writeSync(file.fd, code);
          fs.closeSync(file);
          ok++;
        } catch (e) {
          console.warn('[Source] 导出失败 ' + String(e));
        }
      }
      if (ok > 0) {
        App.get().toast('已导出 ' + ok.toString() + ' 个音源');
        this.exitSelect();
      } else {
        App.get().toast('导出失败，可能没有写入权限');
      }
    } catch (e) {
      App.get().toast('打开保存位置失败');
    }
    this.exporting = false;
  }

  /** 卡片实测高度取不到时用的兜底行高（含 List 的 12vp 间距） */
  private cardHeight(id: string): number {
    const h = this.cardHeights.get(id);
    return h !== undefined && h > 0 ? h + 12 : 132;
  }

  /**
   * 由手指纵向位移算出目标下标：从起始格中心出发，每跨一格累加
   * 「当前格半高 + 相邻格半高」这个中心距，位移达到就再跨一位。
   * 纯计算、不改状态，松手时只调用一次。cardHeight 已含 List 的 12vp 间距。
   */
  private dragTargetIndex(from: number, offsetY: number): number {
    const n = this.items.length;
    if (from < 0 || n === 0) {
      return from;
    }
    const down = offsetY > 0;
    const dist = down ? offsetY : -offsetY;
    let index = from;
    let acc = 0;
    while (true) {
      const next = down ? index + 1 : index - 1;
      if (next < 0 || next >= n) {
        break;
      }
      const need = this.cardHeight(this.items[index].id) / 2 + this.cardHeight(this.items[next].id) / 2;
      if (dist < acc + need) {
        break;
      }
      acc += need;
      index = next;
    }
    return index;
  }

  /**
   * 拖动中「其它卡片让位」的位移。
   *
   * 被拖卡片浮起后，from→to 之间的每张卡都朝 from 方向平移一格；视觉上就是
   * 参考视频里「上下音源跟着拖动一起移动」，而不是只有被拖的那张浮着、松手
   * 才一起跳到新位置。位移取被拖卡片与相邻卡片的实测高度：各卡高度不齐时
   * 这里只是预览，松手后 moveTo 按仓库顺序重排并重新测量，不会累积误差。
   */
  private shiftY(index: number): number {
    if (!this.dragActive) {
      return 0;
    }
    const from = this.dragStartIndex;
    const to = this.dragToIndex;
    if (from < 0 || to < 0 || to === from || index === from) {
      return 0;
    }
    // 被拖卡片从 from 被「抽走」，from→to 之间的每张卡都朝 from 方向平移一格。
    // 位移统一取被拖卡片的实测高度（含 12vp 间距）：各卡高度不齐时只是预览，
    // 松手后 moveTo 重排并重新测量，不会把这点的近似误差带进数据。
    const step: number = this.cardHeight(this.items[from].id);
    if (from < to && index > from && index <= to) {
      return -step;
    }
    if (from > to && index >= to && index < from) {
      return step;
    }
    return 0;
  }

  /**
   * 手指进入 List 上下边缘触发带时决定滚动方向与速度。
   * globalY 来自 PanGesture 的 fingerList[0].globalY，与 Area.globalPosition
   * 同属「当前窗口坐标系」，可以直接比较。
   */
  private updateAutoZone(globalY: number): void {
    if (!this.dragActive || this.listH <= 0) {
      return;
    }
    const bottom = this.listTop + this.listH;
    if (globalY < this.listTop + AUTO_EDGE) {
      this.autoDir = -1;
      this.autoDepth = (this.listTop + AUTO_EDGE - globalY) / AUTO_EDGE;
    } else if (globalY > bottom - AUTO_EDGE) {
      this.autoDir = 1;
      this.autoDepth = (globalY - (bottom - AUTO_EDGE)) / AUTO_EDGE;
    } else {
      this.autoDir = 0;
      this.autoDepth = 0;
    }
    this.autoDepth = Math.min(1, Math.max(0, this.autoDepth));
    if (this.autoDir === 0) {
      this.stopAutoScroll();
    } else {
      this.startAutoScroll();
    }
  }

  private startAutoScroll(): void {
    if (this.autoTimer !== -1) {
      return;
    }
    this.autoTimer = setInterval((): void => {
      this.autoScrollTick();
    }, AUTO_TICK_MS);
  }

  private stopAutoScroll(): void {
    if (this.autoTimer !== -1) {
      clearInterval(this.autoTimer);
      this.autoTimer = -1;
    }
    this.autoDir = 0;
    this.autoDepth = 0;
  }

  /** 一帧自动滚屏：推进列表、累加补偿量、同步目标下标 */
  private autoScrollTick(): void {
    if (!this.dragActive || this.autoDir === 0) {
      this.stopAutoScroll();
      return;
    }
    const n = this.items.length;
    const to = this.dragTargetIndex(this.dragStartIndex, this.panOffsetY + this.scrollAccum);
    const atTop = this.listScroller.currentOffset().yOffset <= 0.5;
    const atBottom = this.listScroller.isAtEnd();
    // 已到列表端点就停：再滚 scrollBy 也无效，补偿量继续累加只会把卡片拽出屏幕
    if ((this.autoDir < 0 && (to <= 0 || atTop)) || (this.autoDir > 0 && (to >= n - 1 || atBottom))) {
      this.stopAutoScroll();
      return;
    }
    const speed = AUTO_MIN_SPEED + (AUTO_MAX_SPEED - AUTO_MIN_SPEED) * this.autoDepth;
    const dy = this.autoDir * speed;
    this.listScroller.scrollBy(0, dy);
    this.syncDrag();
  }

  /**
   * v2.19：补偿量改读 Scroller 实测偏移，不再累加「期望滚动量」。
   * scrollBy 到端点、或 edgeEffect 弹簧回弹时实际滚动小于 dy，旧写法
   * scrollAccum 会一直高估，把 dragOffsetY 越推越大、落位下标跟着跑偏。
   */
  private measureScroll(): void {
    try {
      this.scrollAccum = this.listScroller.currentOffset().yOffset - this.dragStartOffsetY;
    } catch (err) {
      console.warn('[SourcesPage] 读取滚动偏移失败 ' + JSON.stringify(err));
    }
  }

  /** 手指位移 + 实测滚动补偿量统一并入逻辑位移，跨格时让位走补间 */
  private syncDrag(): void {
    this.measureScroll();
    this.dragOffsetY = this.panOffsetY + this.scrollAccum;
    const next = this.dragTargetIndex(this.dragStartIndex, this.dragOffsetY);
    if (next !== this.dragToIndex) {
      animateTo({ duration: 160, curve: Curve.EaseOut }, () => {
        this.dragToIndex = next;
      });
    }
  }

  /** ForEach 之前的固定 ListItem 数：scrollToIndex 用的是 ListItem 下标，不是 items 下标 */
  private listHeaderCount(): number {
    let c = this.selectMode ? 0 : 2; // 选择条已移出 List（v2.50）；非选择模式仍是 导入条 + 设置概览条
    if (!this.sourcesReady) {
      c += 1;
    }
    if (this.items.length === 0) {
      c += 1;
    }
    return c;
  }

  private beginDrag(item: SourceItem, index: number): void {
    if (this.selectMode) {
      return;
    }
    this.panOffsetY = 0;
    this.scrollAccum = 0;
    this.stopAutoScroll();
    this.dragStartIndex = index;
    this.dragId = item.id;
    this.dragCards = [item];
    this.dragOffsetY = 0;
    this.dragToIndex = index;
    this.dragActive = true;
    this.suppressTap = true;
    try {
      this.dragStartOffsetY = this.listScroller.currentOffset().yOffset;
    } catch (err) {
      this.dragStartOffsetY = 0;
    }
    // 卡片顶部（窗口坐标）减去页面 Stack 顶部，得到浮层在 Stack 里的起始 y。
    // 卡片能被按住说明它已布局，onAreaChange 必然采到 top；listTop 只作兜底。
    const top = this.cardTops.get(item.id);
    this.ghostBaseY = (top === undefined ? this.listTop : top) - this.stackTop;
    this.ghostY = this.ghostBaseY;
  }

  /** 松手：把起始项一次性移到目标下标，复原所有拖动状态 */
  private endDrag(): void {
    if (!this.dragActive) {
      return;
    }
    this.stopAutoScroll();
    const from = this.dragStartIndex;
    const to = this.dragTargetIndex(from, this.dragOffsetY);
    const id = this.dragId;
    this.dragActive = false;
    this.dragId = '';
    this.dragCards = [];
    this.dragOffsetY = 0;
    this.panOffsetY = 0;
    this.scrollAccum = 0;
    this.ghostY = 0;
    this.ghostBaseY = 0;
    this.dragStartOffsetY = 0;
    this.dragStartIndex = -1;
    this.dragToIndex = -1;
    if (from >= 0 && to >= 0 && to !== from) {
      this.repo.moveTo(id, to).then(() => {
        this.refresh();
        App.get().toast('已移到第 ' + (to + 1).toString() + ' 位');
        // 落位项可能已被自动滚屏推到视口外，重排后把它带回来
        setTimeout((): void => {
          try {
            this.listScroller.scrollToIndex(to + this.listHeaderCount(), true, ScrollAlign.CENTER);
          } catch (err) {
            console.warn('[SourcesPage] 滚动到落位项失败 ' + JSON.stringify(err));
          }
        }, 80);
      });
    }
    // Tap 的回调可能排在 Pan 之后，延后放开，避免抬手被当成点击
    setTimeout((): void => {
      this.suppressTap = false;
    }, 260);
  }

  private cancelDrag(): void {
    this.stopAutoScroll();
    this.dragActive = false;
    this.dragId = '';
    this.dragCards = [];
    this.dragOffsetY = 0;
    this.panOffsetY = 0;
    this.scrollAccum = 0;
    this.ghostY = 0;
    this.ghostBaseY = 0;
    this.dragStartOffsetY = 0;
    this.dragStartIndex = -1;
    this.dragToIndex = -1;
    setTimeout((): void => {
      this.suppressTap = false;
    }, 260);
  }

  private openMenu(item: SourceItem): void {
    this.menuTarget = item.id;
    this.menuTapAt = Date.now();
    // sheet 是三种形态复用同一个开关，进来必须先把另外两种清掉
    this.netMode = false;
    this.netUrl = '';
    this.renameMode = false;
    this.renameName = item.name;
    this.menuShow = true;
  }

  private targetItem(): SourceItem | null {
    return this.repo.find(this.menuTarget);
  }

  private async checkOne(id: string): Promise<void> {
    this.menuShow = false;
    App.get().toast('开始自检，会真实取一次播放地址');
    const item = await this.repo.check(id);
    this.refresh();
    // v2.53：与卡片状态字典同词——卡片写「正常」，toast 就不另说「自检通过」
    App.get().toast(item.name + (item.health === 'ok' ? ' 正常' : ' 自检未通过'));
  }

  private async updateOne(id: string): Promise<void> {
    this.menuShow = false;
    const item = this.repo.find(id);
    if (item === null || item.updateUrl.length === 0) {
      App.get().toast('这个音源没有声明更新地址');
      return;
    }
    App.get().toast('正在检查更新');
    try {
      const code = await this.repo.fetchUpdate(id);
      if (code.length < 100) {
        App.get().toast('没有拿到新版本');
        return;
      }
      const saved = await this.repo.importCode(code, item.fileName);
      this.refresh();
      App.get().toast('已更新到 ' + (saved.version.length > 0 ? saved.version : '最新版本'));
    } catch (e) {
      App.get().toast('检查更新失败');
    }
  }

  /** 左滑「刷新」：重新从本地脚本文件加载这一个音源，状态与元信息即时回写卡片 */
  private async reloadOne(id: string): Promise<void> {
    App.get().toast('正在刷新音源');
    try {
      const item = await this.repo.reload(id);
      this.refresh();
      App.get().toast(item === null ? '刷新失败，脚本文件可能已丢失' : '已刷新「' + item.name + '」');
    } catch (e) {
      App.get().toast('刷新失败');
    }
  }

  /** 左滑「导出」：只把这一个音源脚本交给系统保存面板，不依赖多选态 */
  private async exportOne(item: SourceItem): Promise<void> {
    if (this.exporting) {
      return;
    }
    const context = getContext(this) as common.UIAbilityContext;
    this.exporting = true;
    try {
      const viewPicker = new picker.DocumentViewPicker(context);
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [this.safeName(item.fileName, item.name)];
      options.fileSuffixChoices = ['.js'];
      const uris = await viewPicker.save(options);
      if (uris.length === 0) {
        this.exporting = false;
        return;
      }
      const file = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, this.readText(item.path));
      fs.closeSync(file);
      App.get().toast('已导出「' + item.name + '」');
    } catch (e) {
      App.get().toast('导出失败，可能没有写入权限');
    }
    this.exporting = false;
  }

  /** 当前首选音源概览：原设置页顶部的音源卡片搬到这里，交互仍靠点下方卡片切换 */
  /**
   * v2.56：单个动作按钮。四颗都写成无参 @Builder —— 带参 @Builder 按值拷贝，
   * `this.importing ? '导入中…' : '本地导入'` 会停在首次构建的旧值上（设置页
   * SettingArrowRow 注释记过同一个坑）。
   * 视觉高度 44，命中区用 responseRegion 补到 48（规范 08 节触控目标下限）。
   */
  @Builder
  actionLocal() {
    Button(this.importing ? '导入中…' : '本地导入')
      .fontSize(FONT.caption)
      // 收紧 Button 默认左右内边距，把宽度让给四字文案（v2.61 防 ellipsis）
      .padding({ left: 4, right: 4 })
      .fontColor('#FF191713')
      .backgroundColor(this.p().primary)
      .borderRadius(RADIUS.pill)
      .height(44)
      .layoutWeight(1)
      .enabled(!this.importing)
      .responseRegion({ x: 0, y: -2, width: '100%', height: 48 })
      .onClick(() => {
        this.importScript();
      })
  }

  @Builder
  actionNet() {
    Button('网络导入')
      .fontSize(FONT.caption)
      .padding({ left: 4, right: 4 })
      .fontColor(this.p().primary)
      .backgroundColor(this.p().primarySoft)
      .borderRadius(RADIUS.pill)
      .height(44)
      .layoutWeight(1)
      .enabled(!this.netBusy)
      .responseRegion({ x: 0, y: -2, width: '100%', height: 48 })
      .onClick(() => {
        this.netUrl = '';
        this.renameMode = false;
        this.netMode = true;
        this.menuShow = true;
      })
  }

  @Builder
  actionCheck() {
    Button(this.checking ? '自检中…' : '全部自检')
      .fontSize(FONT.caption)
      .padding({ left: 4, right: 4 })
      .fontColor(this.p().text2)
      .backgroundColor(this.p().cardAlt)
      .borderRadius(RADIUS.pill)
      .height(44)
      .layoutWeight(1)
      .enabled(!this.checking)
      .responseRegion({ x: 0, y: -2, width: '100%', height: 48 })
      .onClick(() => {
        this.checkAll();
      })
  }

  @Builder
  actionSelect() {
    Button('选择')
      .fontSize(FONT.caption)
      .padding({ left: 4, right: 4 })
      .fontColor(this.p().text2)
      .backgroundColor(this.p().cardAlt)
      .borderRadius(RADIUS.pill)
      .height(44)
      .layoutWeight(1)
      .enabled(this.items.length > 0)
      .responseRegion({ x: 0, y: -2, width: '100%', height: 48 })
      .onClick(() => {
        this.enterSelect();
      })
  }

  /** 每格可用宽 G=(W−3×8)/4 */
  private actionG(): number {
    return (this.actionW - 24) / 4;
  }

  /**
   * 2×2 的触发条件。
   *
   * v2.61 修「本地… / 网络… / 全部…」被 ellipsis 吃掉：旧阈值只按
   * 「4 个汉字 48vp」估，漏算了 Button 自身左右内边距和系统字号放大，
   * 实测 1.2~1.3 倍字号就溢出，却远没到旧的 1.5 倍门槛。
   * 现在按「4×12fp 文字 + 内边距 + 余量 ≈ 88vp」判，并把字号门槛降到 1.15。
   * 宽度还没量到时先画 2×2 —— 宁可多一行，也别先让用户看到被截断的四列。
   */
  private actionTwoRow(): boolean {
    if (this.fontScale >= 1.15) {
      return true;
    }
    if (this.actionW <= 0) {
      return true;
    }
    return this.actionG() < 88;
  }

  /**
   * v2.51 重设计：一行高频操作，等分裸排不套玻璃卡。
   * v2.56：窄屏 / 大字号降级 2×2，按钮不再被压成竖条；宽屏仍是四列。
   */
  @Builder
  actionBar() {
    Column({ space: 8 }) {
      if (this.actionTwoRow()) {
        Row({ space: 8 }) {
          this.actionLocal()
          this.actionNet()
        }
        .width('100%')

        Row({ space: 8 }) {
          this.actionCheck()
          this.actionSelect()
        }
        .width('100%')
      } else {
        Row({ space: 8 }) {
          this.actionLocal()
          this.actionNet()
          this.actionCheck()
          this.actionSelect()
        }
        .width('100%')
      }
    }
    .width('100%')
    // 只量一次宽度并缓存：每次 build 都写 @State 会触发无限重排
    .onAreaChange((_old: Area, now: Area) => {
      const w: number = Number(now.width);
      if (w > 0 && Math.abs(w - this.actionW) > 0.5) {
        this.actionW = w;
      }
    })
  }

  /** 列表分区标题：把「控制台 / 选项」和「音源卡片」在视觉上断开 */
  @Builder
  sectionTitle() {
    Row({ space: 8 }) {
      Text('已导入音源')
        .fontSize(FONT.callout)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.p().text)
      Text(this.items.length.toString() + ' 个')
        .fontSize(FONT.caption)
        .fontColor(this.p().text3)
      Text('长按卡片可拖动排序')
        .fontSize(FONT.micro)
        .fontColor(this.p().text3)
        .layoutWeight(1)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .padding({ left: 6, right: 6, top: 4, bottom: 2 })
  }

  /**
   * 折叠头摘要：只数「当前可见」的开关，分母跟着变。
   *
   * 懒人模式开启时，3 项旧取链配置在 smartResolve 路径里完全不读，已从列表隐藏；
   * 若还把它们算进分母 / 计数，会出现「明明只看到 4 行，却显示 5 / 7 项已开启」，
   * 用户会以为隐藏项还在生效。关闭懒人模式后 7 项全部恢复显示，分母同步回到 7。
   */
  private optionsSummary(): string {
    let n = 0;
    let total = 0;
    // 常驻可见的 4 项：懒人模式自身 + 下载前严格验音质 + 记住每首歌用的音源 + 启动时自动自检
    total += 4;
    if (this.smartHunt) {
      n++;
    }
    if (this.verifyBeforeDownload) {
      n++;
    }
    if (this.rememberSource) {
      n++;
    }
    if (this.autoCheckSources) {
      n++;
    }
    if (!this.smartHunt) {
      // 关闭懒人模式后，3 项旧取链配置重新出现，重新纳入统计
      total += 3;
      if (this.preferOnly) {
        n++;
      }
      if (this.allowDowngrade) {
        n++;
      }
      if (this.autoFallback) {
        n++;
      }
    }
    const head = n.toString() + ' / ' + total.toString() + ' 项已开启';
    const hint = this.smartHunt ? ' · 懒人模式已隐藏 3 项旧配置' : '';
    return head + hint + ' · ' + (this.settingsExpanded ? '点击收起' : '点击展开');
  }

  /** Hero 状态第三行：已启用音源数 */
  /** v2.53：脚本已就绪但还没自检过的源数（与卡片「已就绪 · 未自检」同一判定） */
  private countIdle(): number {
    let n = 0;
    for (const item of this.items) {
      if (item.status === 'ok' && item.health !== 'ok' && item.health !== 'error' &&
        item.health !== 'checking') {
        n++;
      }
    }
    return n;
  }

  private enabledCount(): number {
    let n = 0;
    for (const item of this.items) {
      if (item.enabled) {
        n++;
      }
    }
    return n;
  }

  /**
   * v2.51 重设计：音源状态控制台（Hero）。
   *
   * 原来是一段纯文字概览卡，和 7 个开关、说明、导入条一起平铺在长列表顶部，
   * 把音源卡顶到两三屏外。现在用一块青绿渐变「仪表芯片」做视觉焦点：
   * 左侧大号总数，右侧三行状态色点，底部一行当前首选，一屏内读懂全局。
   * 青绿渐变沿用左滑四枚圆钮的 135° 实体 + 180° 上沿弧光光学语言，
   * 玻璃四件套不变，深浅色 / 光感档位全部跟随全局。
   */
  @Builder
  sourceOverview() {
    Column({ space: 12 }) {
      Row({ space: 14 }) {
        // v2.52 墨栈：信号琥珀仪表芯片，中性实色无发光
        Stack() {
          Column()
            .width(72)
            .height(72)
            .borderRadius(RADIUS.lg)
            .linearGradient({
              angle: 135,
              colors: [['#FFE29A26', 0], ['#FFF3B044', 1]]
            })
          Column()
            .width(72)
            .height(72)
            .borderRadius(RADIUS.lg)
            .linearGradient({
              angle: 180,
              colors: [
                // v2.52 墨栈：仪表芯片不再叠白色弧光
                ['#00FFFFFF', 0],
                ['#00FFFFFF', 0.34],
                ['#00FFFFFF', 0.68],
                ['#00FFFFFF', 1]
              ]
            })
          Column({ space: 0 }) {
            Text(this.items.length.toString())
              .fontSize(FONT.display)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FF191713')
            Text('音源')
              .fontSize(FONT.micro)
              .fontColor('#FF191713')
          }
          .justifyContent(FlexAlign.Center)
        }
        .width(72)
        .height(72)
        .borderRadius(RADIUS.lg)
        .border({ width: 1, color: palette(this.isDark).glassBorder })
        .shadow({ radius: 8, color: 'rgba(27,26,24,0.10)', offsetY: 2 })
        .clip(true)

        Column({ space: 8 }) {
          // v2.53：概览与卡片走同一份状态字典——同样的形状、同样的颜色、
          // 同样的词。以前这里是三颗彩色圆点，和卡片上的圆点各说各话。
          Row({ space: 7 }) {
            this.markGlyph(SourceMark.PASS, this.p().success, 12)
            Text(this.okCount.toString() + ' 个自检通过')
              .fontSize(FONT.caption)
              .fontColor(this.p().text2)
          }
          Row({ space: 7 }) {
            this.markGlyph(SourceMark.WARN, this.p().accent, 12)
            Text(this.failCount.toString() + ' 个自检未通过')
              .fontSize(FONT.caption)
              .fontColor(this.p().text2)
          }
          Row({ space: 7 }) {
            this.markGlyph(SourceMark.IDLE, this.p().text2, 12)
            Text(this.countIdle().toString() + ' 个已就绪未自检')
              .fontSize(FONT.caption)
              .fontColor(this.p().text2)
          }
          Row({ space: 7 }) {
            // 这一行是配置计数、不是健康结论，所以用方点而不是四档形状，
            // 免得和「自检中」的空心方撞语义
            Row().width(7).height(7).borderRadius(1.5).backgroundColor(this.p().primary)
            Text(this.enabledCount().toString() + ' 个已启用')
              .fontSize(FONT.caption)
              .fontColor(this.p().text2)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')

      Row().width('100%').height(1).backgroundColor(this.p().line)

      Row({ space: 10 }) {
        Stack() {
          SymbolGlyph($r('sys.symbol.link'))
            .fontSize(15)
            .fontColor([this.p().primary])
        }
        .width(30)
        .height(30)
        .borderRadius(10)
        .backgroundColor(this.p().primarySoft)
        Text('当前首选')
          .fontSize(FONT.caption)
          .fontColor(this.p().text3)
        Text(this.activeName)
          .fontSize(FONT.callout)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.p().text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.items.length > 0) {
          TinyBadge({ text: '首选', color: this.p().primary })
        }
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

  /**
   * v2.53 包 1（L3 持久结果区）：本轮自检的结论。
   *
   * 只读这一轮拿到的 CheckSummary，不落盘、不改 SourceRepo——结论准不准仍由
   * 仓库负责，这里只负责「别让它一闪就没」。关掉后本轮不再出现，下次点
   * 「全部自检」再出新的一份。
   */
  @Builder
  checkReportCard() {
    if (this.reportAt > 0 && !this.reportClosed) {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          // 形状随「有没有未通过项」变，所以走静态 if/else 两条调用，
          // 不把 this.reportFailed.length 当实参传进 Builder——带参 Builder 是
          // 按值快照，参数里的业务状态变了不会自己重绘，只有父组件重绘才跟上。
          if (this.reportFailed.length > 0) {
            this.markGlyph(SourceMark.WARN, this.p().accent, 13)
          } else {
            this.markGlyph(SourceMark.PASS, this.p().success, 13)
          }
          Text('上次自检结果')
            .fontSize(FONT.callout)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.p().text)
            .layoutWeight(1)
          Text(relativeCheck(this.reportAt, this.nowTs))
            .fontSize(FONT.micro)
            .fontColor(this.p().text3)
          Stack() {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(12)
              .fontColor([this.p().text3])
          }
          .width(26)
          .height(26)
          .borderRadius(13)
          .responseRegion({ x: -11, y: -11, width: 48, height: 48 })
          .accessibilityText('关闭自检结果')
          .accessibilityLevel('yes')
          .onClick(() => {
            this.reportClosed = true;
          })
        }
        .width('100%')

        Text(this.reportSummary())
          .fontSize(FONT.micro)
          .fontColor(this.p().text2)
          .width('100%')
          .accessibilityText('上次自检结果，' + relativeCheck(this.reportAt, this.nowTs) + '，' +
            this.reportSummary())
          .accessibilityLevel('yes')

        if (this.reportFailed.length > 0) {
          Row().width('100%').height(1).backgroundColor(this.p().line)
          ForEach(this.reportFailed, (row: CheckReportRow) => {
            Row({ space: 8 }) {
              this.markGlyph(SourceMark.WARN, this.p().accent, 11)
              Text(row.name)
                .fontSize(FONT.micro)
                .fontColor(this.p().text)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ maxWidth: 100 })
              Text(row.message.length > 0 ? row.message : '本次自检未通过')
                .fontSize(FONT.micro)
                .fontColor(this.p().text3)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .width('100%')
            .accessibilityGroup(true)
            .accessibilityText(row.name + '，音源，自检未通过，' +
              (row.message.length > 0 ? row.message : '本次自检未通过'))
          }, (row: CheckReportRow) => this.reportAt.toString() + '|' + row.name + '|' + row.message)
        }
      }
      .width('100%')
      .padding(16)
      .borderRadius(RADIUS.lg)
      .backgroundColor(glassCardBase(this.isDark))
      .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
      .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
      .shadow(glassShadow(this.isDark, this.lightLevel))
    }
  }

  /** 结果区那一行汇总：与卡片状态字典同词，不另造「通过 / 失败」第二套口径 */
  private reportSummary(): string {
    let s = '通过 ' + this.reportOk.toString() + ' 个 · 未通过 ' +
      this.reportFailed.length.toString() + ' 个';
    if (this.reportSkipped > 0) {
      s += ' · ' + this.reportSkipped.toString() + ' 个平台因脚本错误跳过';
    }
    return s;
  }

  /**
   * v2.51 重设计：取链 / 下载开关默认收起，只留一条可点折叠头。
   *
   * 这些是低频配置，原来常驻在长列表顶部占掉近两屏，音源卡片被顶到两三屏之外。
   * 现在折叠头常驻显示「N / M 项已开启」，点一下才展开；展开后是统计说明 + 开关行。
   * M 随懒人模式变化：开启时 3 项旧取链配置被隐藏（改为一条说明）只剩 4 项，
   * 关闭时 7 项全部显示。开关逻辑、文案、Settings 读写一行未改。
   */
  @Builder
  sourceSettings() {
    Column({ space: 10 }) {
      // 折叠头（常驻）
      Row({ space: 12 }) {
        Stack() {
          SymbolGlyph($r('sys.symbol.gearshape'))
            .fontSize(16)
            .fontColor([this.p().primary])
        }
        .width(34)
        .height(34)
        .borderRadius(11)
        .backgroundColor(this.p().primarySoft)

        Column({ space: 2 }) {
          Text('音源选项')
            .fontSize(FONT.callout)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.p().text)
          Text(this.optionsSummary())
            .fontSize(FONT.micro)
            .fontColor(this.p().text3)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(14)
          .fontColor([this.p().text3])
          .rotate({ angle: this.settingsExpanded ? 180 : 0 })
      }
      .width('100%')
      .padding(14)
      .borderRadius(RADIUS.lg)
      .backgroundColor(glassCardBase(this.isDark))
      .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
      .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
      .shadow(glassShadow(this.isDark, this.lightLevel))
      .onClick(() => {
        this.settingsExpanded = !this.settingsExpanded;
      })

      // 展开后才渲染选项主体：统计说明 + 开关行（懒人模式下按条件隐藏 3 项并给出说明）
      if (this.settingsExpanded) {
        Column({ space: 8 }) {
          Text('取链与下载选项')
            .fontSize(FONT.caption)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.p().text3)
            .width('100%')
            .padding({ left: 14, top: 4 })

          Column({ space: 4 }) {
            Text(this.sourceStat())
              .fontSize(FONT.body)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.p().primary)
              .width('100%')
            Text('「已就绪」指音源已完成初始化（上报了可用平台），只有就绪的音源才会被问到；某条链接播放失败时会自动换到其它音源给的链接')
              .fontSize(FONT.micro)
              .fontColor(this.p().text3)
              .lineHeight(17)
              .width('100%')
            Text(this.checking
              ? ('正在自检 ' + this.checkDone.toString() + '/' + this.checkTotal.toString() +
                '，每个源按平台逐首试，请稍候')
              : '逐个音源按平台试基准曲，结论与卡片上的「自检」一致；这会真实取链，不要连点')
              .fontSize(FONT.micro)
              .fontColor(this.p().text3)
              .lineHeight(17)
              .width('100%')

            if (this.pendingCount > 0) {
              Row({ space: 8 }) {
                Text('有 ' + this.pendingCount.toString() + ' 个音源加载了但还没就绪')
                  .fontSize(FONT.micro)
                  .fontColor(this.p().text3)
                  .layoutWeight(1)
                Button(this.rebuilding ? '重建中…' : '重建')
                  .fontSize(FONT.micro)
                  .fontColor('#FF191713')
                  .backgroundColor(this.p().primary)
                  .borderRadius(RADIUS.pill)
                  .height(30)
                  .padding({ left: 14, right: 14 })
                  .enabled(!this.rebuilding)
                  .onClick(() => {
                    this.rebuildAll();
                  })
              }
              .width('100%')
              .margin({ top: 8 })
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          .borderRadius(RADIUS.lg)
          .backgroundColor(glassCardBase(this.isDark))
          .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
          .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
          .shadow(glassShadow(this.isDark, this.lightLevel))

          Column() {
            this.smartHuntRow()
            Divider().color(this.p().line).margin({ left: 16, right: 16 })
            if (this.smartHunt) {
              // 懒人模式走独立的 smartResolve，以下 3 项完全不参与取链，留着只会误导
              this.smartHuntHint()
            } else {
              this.preferOnlyRow()
              Divider().color(this.p().line).margin({ left: 16, right: 16 })
              this.downgradeRow()
            }
            Divider().color(this.p().line).margin({ left: 16, right: 16 })
            this.verifyRow()
            if (!this.smartHunt) {
              Divider().color(this.p().line).margin({ left: 16, right: 16 })
              this.fallbackRow()
            }
            Divider().color(this.p().line).margin({ left: 16, right: 16 })
            this.rememberRow()
            Divider().color(this.p().line).margin({ left: 16, right: 16 })
            this.autoCheckRow()
          }
          .width('100%')
          .borderRadius(RADIUS.lg)
          .backgroundColor(glassCardBase(this.isDark))
          .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
          .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
          .shadow(glassShadow(this.isDark, this.lightLevel))
          .clip(true)
        }
        .width('100%')
      }
    }
    .width('100%')
  }

  /**
   * 懒人模式：只认目标音质，一个源 / 平台 / 插件给不到就自动换下一个，
   * 全问过仍不达标就明确停止，绝不降到低音质。默认开。
   */
  @Builder
  smartHuntRow() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text('智能达标寻源（懒人模式）')
          .fontSize(FONT.body)
          .fontColor(this.p().text)
        Text(this.smartHunt
          ? '锁定你选的音质：源 / 平台给不到就自动换下一个；选无损 FLAC 全挂时，会自动升到 Hi-Res / 全景声 / 母带再找一遍（绝不往下降），全试过都不行就明确提示'
          : '关闭后回到旧取链：首选优先，拿不到时补位，仍不行才换平台找同款')
          .fontSize(FONT.micro)
          .fontColor(this.p().text3)
          .lineHeight(17)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.smartHunt })
        .selectedColor(this.p().primary)
        .onChange((on: boolean) => {
          this.smartHunt = on;
          this.settings.setSmartHunt(on);
          App.get().toast(on ? '已开启：按目标音质自动跨源寻找，绝不降质' : '已恢复旧取链方式');
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  /**
   * 懒人模式开启时，说明被隐藏的 3 项去哪了。
   *
   * 「只用首选音源 / 音质不足时自动降级 / 首选连续失败时自动补位」都是旧取链
   * 链路（resolve 的非 smartHunt 分支）的配置，懒人模式下那整段不执行，留着
   * 会让人以为调了有用。这里只做说明、不改任何值：
   *  - preferOnly 仍作用于歌词（LyricRepo 会读），所以不能说它彻底失效；
   *  - 关闭懒人模式后 3 项原样恢复，之前存的值不会被清空。
   */
  @Builder
  smartHuntHint() {
    Column({ space: 6 }) {
      Text('已隐藏 3 项旧取链配置')
        .fontSize(FONT.body)
        .fontColor(this.p().text)
      Text('「只用首选音源」「音质不足时自动降级」「首选连续失败时自动补位」只作用于旧取链方式；懒人模式是全源并发 + 绝不降质，这 3 项在取链时不会被读取，因此已隐藏。关闭懒人模式即可重新显示并调整，原先的设置会保留。')
        .fontSize(FONT.micro)
        .fontColor(this.p().text3)
        .lineHeight(17)
      Text('注意：「只用首选音源」仍作用于歌词，开启时歌词只问首选音源。')
        .fontSize(FONT.micro)
        .fontColor(this.p().text3)
        .lineHeight(17)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  @Builder
  preferOnlyRow() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text('只用首选音源')
          .fontSize(FONT.body)
          .fontColor(this.p().text)
        Text(this.preferOnly ? '首选拿不到这首歌就直接提示，绝不换成别的音源' :
          '首选优先，拿不到时其它已启用音源会并发补位，来源可能变化')
          .fontSize(FONT.micro)
          .fontColor(this.p().text3)
          .lineHeight(17)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.preferOnly })
        .selectedColor(this.p().primary)
        .onChange((on: boolean) => {
          this.preferOnly = on;
          this.settings.setPreferOnly(on);
          App.get().toast(on ? '只用首选音源取链（歌词也只问首选）' : '已恢复：首选拿不到时由其它音源补位');
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  @Builder
  downgradeRow() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text('音质不足时自动降级')
          .fontSize(FONT.body)
          .fontColor(this.p().text)
        Text('关闭时直接报错；打开后音源给不了目标音质才降到可用的最高档（实际音质会标注）')
          .fontSize(FONT.micro)
          .fontColor(this.p().text3)
          .lineHeight(17)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.allowDowngrade })
        .selectedColor(this.p().primary)
        .onChange((on: boolean) => {
          this.allowDowngrade = on;
          this.settings.setAllowDowngrade(on);
          App.get().toast(on ? '音源没有目标音质时会自动降到可用的最高档' : '音源没有目标音质时直接报错');
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  /**
   * 默认关闭，对齐洛雪官方「音源给什么链接就下什么」。
   * 打开会恢复下载前的 Range 探测：能挡住虚标，但中转 / 聚合接口常对探测
   * 请求回 403 / 404，本来能下的歌会被误判失败。
   */
  @Builder
  verifyRow() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text('下载前严格验音质')
          .fontSize(FONT.body)
          .fontColor(this.p().text)
        Text('默认关闭：不二次探测，落盘后验文件头；打开可挡虚标，但易被接口 403/404 误伤')
          .fontSize(FONT.micro)
          .fontColor(this.p().text3)
          .lineHeight(17)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.verifyBeforeDownload })
        .selectedColor(this.p().primary)
        .onChange((on: boolean) => {
          this.verifyBeforeDownload = on;
          this.settings.setVerifyBeforeDownload(on);
          App.get().toast(on ? '下载前会先探测链接（更严，但可能误伤）' : '已恢复：信任音源，落盘后验文件头');
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  /** 首选后端被封时，别让「只用首选音源」变成整首报错 */
  @Builder
  fallbackRow() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text('首选连续失败时自动补位')
          .fontSize(FONT.body)
          .fontColor(this.p().text)
        Text('首选连续被拒 / 超时后，临时让其它已启用音源参与，避免一个后端 403 就全部失败')
          .fontSize(FONT.micro)
          .fontColor(this.p().text3)
          .lineHeight(17)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.autoFallback })
        .selectedColor(this.p().primary)
        .onChange((on: boolean) => {
          this.autoFallback = on;
          this.settings.setAutoFallbackOnFailure(on);
          App.get().toast(on ? '首选连续失败时会临时允许补位' : '始终只认首选音源');
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  /** 歌 → 源亲和：减少同首歌反复全源竞速，也减少「这次是 A 给的、下次变 B」 */
  @Builder
  rememberRow() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text('记住每首歌用的音源')
          .fontSize(FONT.body)
          .fontColor(this.p().text)
        Text('再播同一首时先问上次给过它的音源，少一轮竞速；它给不出来时其它源照常补位')
          .fontSize(FONT.micro)
          .fontColor(this.p().text3)
          .lineHeight(17)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.rememberSource })
        .selectedColor(this.p().primary)
        .onChange((on: boolean) => {
          this.rememberSource = on;
          this.settings.setRememberSource(on);
          App.get().toast(on ? '会记住每首歌上次用的音源' : '不再记录，播放时重新竞速');
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  /** 启动自动自检：默认关，因为它是真实取链，会被后端风控放大成更多 403 */
  @Builder
  autoCheckRow() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text('启动时自动自检')
          .fontSize(FONT.body)
          .fontColor(this.p().text)
        Text('启动约 8 秒后在后台跑一轮完整自检，不阻塞播放；结果只更新下方音源卡片的状态，不弹窗。同一进程只跑一次，距上次不足 30 分钟会跳过')
          .fontSize(FONT.micro)
          .fontColor(this.p().text3)
          .lineHeight(17)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.autoCheckSources })
        .selectedColor(this.p().primary)
        .onChange((on: boolean) => {
          this.autoCheckSources = on;
          this.settings.setAutoCheckSources(on);
          App.get().toast(on ? '下次启动会在后台自检一轮，结果更新到音源卡片' : '启动时不再自动自检');
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  /**
   * v2.53 包 1：四档状态形状。
   *
   * 用 Shape + Path 自绘，16×16 视图坐标按 size 等比缩放，卡片上的 13vp 与
   * 概览里的 12vp 是同一套几何、同样的视觉重量。线宽写在视图坐标里，跟着
   * 尺寸一起缩，不会出现「小图标配粗线」的糊块。
   *
   * 三角用实心而不是描边：13vp 里再塞一个感叹号必然糊成一团，实心三角本身
   * 已经是「警告」最强的几何语义，配合右侧固定文案足够读懂。
   */
  @Builder
  markGlyph(mark: SourceMark, color: string, size: number) {
    Shape() {
      if (mark === SourceMark.PASS) {
        // 实心圆挖一个对勾：对勾用卡片底色描，视觉上等于在圆里「挖」出来
        Path()
          .commands('M8,1.6 A6.4,6.4 0 1,1 7.99,1.6 Z')
          .fill(color)
          .stroke(color)
          .strokeWidth(0.6)
        Path()
          .commands('M4.6,8.2 L6.9,10.6 L11.4,5.6')
          .fill(Color.Transparent)
          .stroke(this.p().card)
          .strokeWidth(2)
          .strokeLineCap(LineCapStyle.Round)
          .strokeLineJoin(LineJoinStyle.Round)
      } else if (mark === SourceMark.WARN) {
        Path()
          .commands('M8,1.2 L14.8,14 L1.2,14 Z')
          .fill(color)
          .stroke(color)
          .strokeWidth(1)
          .strokeLineJoin(LineJoinStyle.Round)
      } else if (mark === SourceMark.WAIT) {
        Path()
          .commands('M2.8,2.8 H13.2 V13.2 H2.8 Z')
          .fill(Color.Transparent)
          .stroke(color)
          .strokeWidth(1.6)
          .strokeLineJoin(LineJoinStyle.Round)
      } else {
        Path()
          .commands('M8,1.6 A6.4,6.4 0 1,1 7.99,1.6 Z')
          .fill(Color.Transparent)
          .stroke(color)
          .strokeWidth(1.6)
      }
    }
    .viewPort({ x: 0, y: 0, width: 16, height: 16 })
    .width(size)
    .height(size)
  }

  @Builder
  statusDot(item: SourceItem) {
    Row({ space: 6 }) {
      // v2.53：形状与颜色、文案三者同源判定，色相不再是唯一编码
      this.markGlyph(statusMark(item), statusColor(item, this.p()), 13)
      Text(statusText(item))
        .fontSize(FONT.micro)
        .fontColor(statusColor(item, this.p()))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
  }

  /**
   * 左滑露出的四枚青绿液态玻璃圆钮（参考图二），2×2 两行两列，
   * 顺序就是用户要的「自检、刷新、导出、删除」。
   *
   * 原来这里只有一个红色「删除」条、卡片右侧还挂一个 more 四宫格图标；
   * 现在图标去掉，四个动作全收进左滑区，删除仍走 confirmRemove 确认弹窗。
   * 选择模式下返回 0 宽：那时横向手势容易和多选冲突，误删代价也太大。
   */
  @Builder
  swipeActions(item: SourceItem) {
    if (this.selectMode) {
      Row().width(0).height('100%')
    } else {
      Column({ space: 3 }) {
        Row({ space: 3 }) {
          SourceSwipeButton({
            icon: $r('sys.symbol.checkmark_circle'),
            label: '自检',
            onTap: (): void => {
              this.checkOne(item.id);
            }
          })
          SourceSwipeButton({
            icon: $r('sys.symbol.arrow_clockwise'),
            label: '刷新',
            onTap: (): void => {
              this.reloadOne(item.id);
            }
          })
        }
        Row({ space: 3 }) {
          SourceSwipeButton({
            icon: $r('sys.symbol.arrow_right'),
            label: '导出',
            onTap: (): void => {
              this.exportOne(item);
            }
          })
          SourceSwipeButton({
            icon: $r('sys.symbol.trash'),
            label: '删除',
            onTap: (): void => {
              this.confirmRemove(item);
            }
          })
        }
      }
      .width(104)
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .padding({ left: 8, right: 8, top: 6, bottom: 6 })
      .borderRadius(RADIUS.lg)
      .backgroundColor(glassCardBase(this.isDark))
      .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
      .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
      .shadow(glassShadow(this.isDark, this.lightLevel))
      .margin({ left: 10 })
    }
  }

  /** 左滑删除前确认：脚本文件会被一起删掉，误删只能重新导入 */
  private confirmRemove(item: SourceItem): void {
    if (this.selectMode) {
      return;
    }
    AlertDialog.show({
      title: '删除音源',
      message: '将删除「' + item.name + '」并从已启用列表移除，脚本文件一并删除。',
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
          this.repo.remove(item.id).then(() => {
            this.refresh();
            App.get().toast('已删除「' + item.name + '」');
          });
        }
      }
    });
  }

  /**
   * 选择模式的批量删除（v2.48）：勾几个删几个，全选后一次删完。
   * 与左滑单删同样先弹确认——脚本文件会被 unlink，误删只能重新导入。
   * 文案按数量收敛，全选几十个时不会把整屏撑成一张名字清单。
   */
  private confirmRemoveSelected(): void {
    if (this.removing || this.exporting) {
      return;
    }
    const list: SourceItem[] = [];
    for (const item of this.items) {
      if (this.isSelected(item.id)) {
        list.push(item);
      }
    }
    if (list.length === 0) {
      App.get().toast('先勾选要删除的音源');
      return;
    }
    let names = '';
    for (let i = 0; i < list.length && i < 3; i++) {
      names += (i > 0 ? '、' : '') + '「' + list[i].name + '」';
    }
    if (list.length > 3) {
      names += ' 等 ' + list.length.toString() + ' 个';
    }
    AlertDialog.show({
      title: '删除 ' + list.length.toString() + ' 个音源',
      message: '将删除 ' + names + '，脚本文件一并删除，删除后只能重新导入。',
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
          const ids: string[] = [];
          for (const item of list) {
            ids.push(item.id);
          }
          this.removing = true;
          this.repo.removeMany(ids).then((count: number) => {
            this.removing = false;
            this.refresh();
            this.exitSelect();
            App.get().toast(count > 0 ? '已删除 ' + count.toString() + ' 个音源' : '这些音源已经不在了');
          }).catch(() => {
            this.removing = false;
            App.get().toast('删除失败，请重试');
          });
        }
      }
    });
  }

  /**
   * 点音源名字：选择模式下直接放行，交给整卡的 TapGesture 勾选。
   * 两者是同一次触摸、都会回调，这里再 toggle 一次会立刻又取消掉。
   */
  private onNameTap(item: SourceItem): void {
    if (this.selectMode || (this.dragActive && this.dragId === item.id)) {
      return;
    }
    this.openMenu(item);
  }

  /**
   * 音源卡内容主体：列表卡与拖动浮层共用同一份渲染，保证浮起的那张和原卡
   * 一模一样（名称 / 状态 / 开关 / 平台 / 音质 / 描述）。
   * 浮层里这张卡正是 dragId 对应项，名字点击与开关回调在拖动中直接短路，
   * 避免浮层接管触摸后误开菜单 / 误改开关。
   */
  @Builder
  cardBody(item: SourceItem) {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        if (this.selectMode) {
          Stack() {
            if (this.isSelected(item.id)) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(13)
                .fontColor(['#FF191713'])
            }
          }
          .width(22)
          .height(22)
          .borderRadius(11)
          .backgroundColor(this.isSelected(item.id) ? this.p().primary : Color.Transparent)
          .border({
            width: 1.5,
            color: this.isSelected(item.id) ? this.p().primary : this.p().text3
          })
        }
        Stack() {
          SymbolGlyph($r('sys.symbol.link'))
            .fontSize(17)
            .fontColor([item.enabled ? this.p().primary : this.p().text3])
        }
        .width(38)
        .height(38)
        .borderRadius(12)
        .backgroundColor(item.enabled ? this.p().primarySoft : this.p().cardAlt)

        Column({ space: 4 }) {
          Row({ space: 6 }) {
            Text(item.name)
              .fontSize(FONT.body)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.p().text)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
              // 右侧 more 图标已去掉；点名字进「重命名」等次要操作。
              // 选择模式下这里放行，交给整卡 Tap 勾选（见 onNameTap）。
              .onClick(() => {
                this.onNameTap(item);
              })
            if (this.activeId === item.id) {
              TinyBadge({ text: '首选', color: this.p().primary })
            }
          }
          .width('100%')

          Row({ space: 6 }) {
            this.statusDot(item)
            if (item.version.length > 0) {
              Text('v' + item.version)
                .fontSize(FONT.micro)
                .fontColor(this.p().text3)
            }
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        // v2.56：名称 + 首选徽标 + 状态形状/文案 + 版本合成一句播报
        .accessibilityGroup(true)
        .accessibilityText(this.cardLabel(item))
        .accessibilityDescription('点名称可重命名或删除，双击卡片设为首选')

        // 选择模式下右侧开关收起，整张卡片只负责勾选。
        if (!this.selectMode) {
          Toggle({ type: ToggleType.Switch, isOn: item.enabled })
            .selectedColor(this.p().primary)
            .accessibilityText(item.name + (item.enabled ? '，已启用' : '，已停用') + '，开关')
            .onChange((on: boolean) => {
              if (this.dragActive && this.dragId === item.id) {
                return;
              }
              if (on === item.enabled) {
                return;
              }
              this.repo.setEnabled(item.id, on).then(() => {
                this.refresh();
              });
            })
        }
      }
      .width('100%')

      if (item.platforms.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(item.platforms, (id: string) => {
            Text(platformShort(id))
              .fontSize(9)
              .fontColor(this.p().text2)
              .backgroundColor(this.p().cardAlt)
              .borderRadius(4)
              .padding({ left: 5, right: 5, top: 2, bottom: 2 })
              .margin({ right: 5, bottom: 4 })
          }, (id: string) => item.id + id)
          ForEach(item.qualities, (q: string) => {
            Text(q)
              .fontSize(9)
              .fontColor(this.p().primary)
              .backgroundColor(this.p().primarySoft)
              .borderRadius(4)
              .padding({ left: 5, right: 5, top: 2, bottom: 2 })
              .margin({ right: 5, bottom: 4 })
          }, (q: string) => item.id + q)
        }
        .width('100%')
      }

      // 报错卡片原先没有说明行，整体明显比正常卡片矮、局促（用户反馈「有点窄」）。
      // 现在完整错误单独成行且可换行，所有卡片都保留同一行说明，结构对齐。
      // v2.43：装载失败与自检失败都给一行如实说明，卡片结构保持一致。
      // 自检失败用中性色，不再冒充「脚本未能载入」误导用户逐个刷新。
      if (item.status === 'error' || item.health === 'error') {
        Text(item.message.length > 0 ? item.message :
          (item.status === 'error' ? '脚本未能载入' : '本次自检未通过'))
          .fontSize(FONT.micro)
          .fontColor(item.status === 'error' ? this.p().danger : this.p().text2)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      Text(this.cardHint(item))
        .fontSize(FONT.micro)
        .fontColor(this.p().text3)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      // v2.53：selfcheck 结论带时间戳。单独一行而不是塞进状态行——
      // 状态行宽度要同时容下形状、状态文案、版本号，再挤时间必然截断，
      // 而「上次什么时候验的」恰恰是不能被省略的信息。
      if (item.checkedAt > 0) {
        Text(checkLabel(item, this.nowTs))
          .fontSize(FONT.micro)
          .fontColor(checkStale(item, this.nowTs) ? this.p().accent : this.p().text3)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
    }
    .width('100%')
  }

  /**
   * 列表里的音源卡。
   *
   * v2.19：被拖卡片不再靠 .translate 浮起跟手 —— translate 只改绘制位置、
   * 不改 ListItem 布局槽位，而 List 只绘制「显示区 + cachedCount」窗口内的
   * item（且预加载节点默认不显示），自动滚屏把槽位推出去后整块就不画了，
   * 手指底下只剩白块。现在跟手那张改由页面 Stack 的 ghostLayer 独立绘制，
   * 这里只把原槽位隐藏；其余卡片照常 shiftY 让位。
   */
  @Builder
  sourceCard(item: SourceItem, index: number) {
    Column() {
      this.cardBody(item)
    }
    .width('100%')
    .padding(14)
    .borderRadius(RADIUS.lg)
    .backgroundColor(glassCardBase(this.isDark))
    .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
    .shadow(glassShadow(this.isDark, this.lightLevel))
    // 玻璃描边与选中/拖动蓝框合并成一次 border，避免后一次覆盖前一次
    .border({
      width: this.sourceCardEdgeWidth(item.id),
      color: this.sourceCardEdgeColor(item.id)
    })
    .opacity(this.dragActive && this.dragId === item.id ? 0 : 1)
    .translate({ y: this.dragActive && this.dragId === item.id ? 0 : this.shiftY(index) })
    .onAreaChange((_old: Area, now: Area) => {
      const h = Number(now.height);
      if (h > 0) {
        this.cardHeights.set(item.id, h);
        this.cardTops.set(item.id, Number(now.globalPosition.y));
      }
    })
    // 短按走显式 TapGesture；短长按（220ms）后由顺序手势组接管纵向拖动。
    // 不能把 PanGesture 直接和 onClick 挂同一节点，否则点击会被吃掉（PlayerPage 已踩过）。
    .gesture(
      GestureGroup(GestureMode.Parallel,
        TapGesture({ count: 1, fingers: 1 })
          .onAction(() => {
            // 点名字开菜单那一帧，别让整卡的 Tap 顺带把「设为首选」也做了
            if (!this.suppressTap && Date.now() - this.menuTapAt > 300) {
              this.onCardTap(item);
            }
          }),
        GestureGroup(GestureMode.Sequence,
          // Sequence 组里只有最后一个手势（Pan）能可靠触发 onActionEnd，
          // 长按上挂 onActionEnd 语义不可靠，兜底交给下方 onCancel
          LongPressGesture({ repeat: false, duration: 220 })
            .onAction(() => {
              this.beginDrag(item, index);
            }),
          PanGesture({ direction: PanDirection.Vertical, distance: 1 })
            .onActionUpdate((event: GestureEvent) => {
              if (this.dragActive && this.dragId === item.id) {
                this.panOffsetY = event.offsetY;
                // 浮层只跟手指：相对按下瞬间的槽位平移同样位移，
                // 不随 List 滚动，也就不需要任何滚动补偿。
                this.ghostY = this.ghostBaseY + event.offsetY;
                // 手指绝对 Y 决定要不要自动滚屏：拖到屏幕上下边缘时，
                // 定时器带着 List 一起走，目标下标就能越过当前可见区域。
                if (event.fingerList.length > 0) {
                  this.updateAutoZone(Number(event.fingerList[0].globalY));
                }
                this.syncDrag();
              }
            })
            .onActionEnd(() => {
              this.endDrag();
            })
            .onActionCancel(() => {
              this.cancelDrag();
            })
        )
          .onCancel(() => {
            this.cancelDrag();
          })
      )
    )
  }

  /** 跟手浮层里的卡片：和列表卡同内容，换成品牌蓝浮起描边 + 放大 + 重投影 */
  @Builder
  ghostCard(item: SourceItem) {
    Column() {
      this.cardBody(item)
    }
    .width('100%')
    .padding(14)
    .borderRadius(RADIUS.lg)
    .backgroundColor(glassCardBase(this.isDark))
    .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
    .shadow({ radius: 10, color: this.isDark ? '#66000000' : 'rgba(27,26,24,0.12)', offsetY: 4 })
    .border({ width: 2, color: this.p().primary })
    .scale({ x: 1.03, y: 1.03 })
    .opacity(0.96)
  }

  /**
   * 拖动浮层：挂在页面最外层 Stack 上，与 List 平级、覆盖其上。
   * 它是普通组件，不受 List 的布局窗口 / 预加载节点显示策略 / 槽位裁剪约束，
   * 列表滚到哪都按 position 照常绘制，白块从机制上不再可能出现。
   * HitTestMode.Transparent 不阻塞兄弟节点（下层 ListItem）的命中测试，
   * PanGesture 仍由原卡接收；浮层里的点击与开关已在 cardBody 里短路。
   */
  @Builder
  ghostLayer() {
    // 用 ForEach 把被拖项作为回调参数交给 ghostCard：builder 实参不含 this 状态，
    // 避免「按值传参只生效一次」；dragCards 只有 0/1 项，激活时才渲染出这一张。
    Column() {
      ForEach(this.dragCards, (item: SourceItem) => {
        this.ghostCard(item)
      }, (item: SourceItem) => item.id)
    }
    .width('100%')
    .padding({ left: PAGE_PAD, right: PAGE_PAD })
    .position({ x: 0, y: this.ghostY })
    .hitTestBehavior(HitTestMode.Transparent)
    .zIndex(20)
  }

  /** 短按卡片：选择模式下勾选，否则设为首选（逻辑与改造前的 onClick 一致） */
  private onCardTap(item: SourceItem): void {
    if (this.selectMode) {
      this.toggleSelect(item.id);
      return;
    }
    if (!item.enabled) {
      App.get().toast('先打开右侧开关启用这个音源');
      return;
    }
    this.repo.setActive(item.id);
    this.refresh();
    App.get().toast('播放/下载优先使用：' + item.name);
  }

  @Builder
  menuSheet() {
    Column({ space: 4 }) {
      if (this.netMode) {
        Column({ space: 14 }) {
          Text('从网络导入音源')
            .fontSize(FONT.headline)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.p().text)
            .width('100%')
          Text('粘贴音源脚本的直链（http / https）。支持一次多行，每行一个链接，会逐个下载导入。')
            .fontSize(FONT.caption)
            .fontColor(this.p().text2)
            .lineHeight(18)
            .width('100%')
          TextArea({ text: this.netUrl, placeholder: 'https://example.com/lx-source.js' })
            .fontSize(FONT.caption)
            .fontColor(this.p().text)
            .placeholderColor(this.p().text3)
            .backgroundColor(this.p().cardAlt)
            .borderRadius(RADIUS.md)
            .height(96)
            .width('100%')
            .onChange((value: string) => {
              this.netUrl = value;
            })
          Row({ space: 12 }) {
            Button('取消')
              .fontSize(FONT.callout)
              .fontColor(this.p().text2)
              .backgroundColor(this.p().cardAlt)
              .borderRadius(RADIUS.pill)
              .height(42)
              .layoutWeight(1)
              .onClick(() => {
                this.netMode = false;
                this.netUrl = '';
                this.menuShow = false;
              })
            Button(this.netBusy ? '导入中…' : '导入')
              .fontSize(FONT.callout)
              .fontColor('#FF191713')
              .backgroundColor(this.p().primary)
              .borderRadius(RADIUS.pill)
              .height(42)
              .layoutWeight(1)
              .enabled(!this.netBusy)
              .opacity(this.netBusy ? 0.6 : 1)
              .onClick(() => {
                this.importFromNet();
              })
          }
          .width('100%')
        }
        .width('100%')
        .padding({ left: 4, right: 4, top: 8 })
      } else if (this.renameMode) {
        Column({ space: 14 }) {
          Text('重命名音源')
            .fontSize(FONT.headline)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.p().text)
            .width('100%')
          TextInput({ text: this.renameName, placeholder: '音源名称' })
            .fontSize(FONT.body)
            .fontColor(this.p().text)
            .placeholderColor(this.p().text3)
            .backgroundColor(this.p().cardAlt)
            .borderRadius(RADIUS.md)
            .height(46)
            .onChange((value: string) => {
              this.renameName = value;
            })
          Row({ space: 12 }) {
            Button('返回')
              .fontSize(FONT.callout)
              .fontColor(this.p().text2)
              .backgroundColor(this.p().cardAlt)
              .borderRadius(RADIUS.pill)
              .height(42)
              .layoutWeight(1)
              .onClick(() => {
                this.renameMode = false;
              })
            Button('保存')
              .fontSize(FONT.callout)
              .fontColor('#FF191713')
              .backgroundColor(this.p().primary)
              .borderRadius(RADIUS.pill)
              .height(42)
              .layoutWeight(1)
              .onClick(() => {
                this.repo.rename(this.menuTarget, this.renameName).then(() => {
                  this.refresh();
                  this.menuShow = false;
                });
              })
          }
          .width('100%')
        }
        .width('100%')
        .padding({ left: 4, right: 4, top: 8 })
      } else {
        this.menuRow($r('sys.symbol.checkmark_circle'), '自检（真实取一次链接）', false, () => {
          this.checkOne(this.menuTarget);
        })
        this.menuRow($r('sys.symbol.arrow_clockwise'), '检查更新', false, () => {
          this.updateOne(this.menuTarget);
        })
        this.menuRow($r('sys.symbol.textformat'), '重命名', false, () => {
          this.renameMode = true;
        })
        // 排序入口已从菜单移除：改为在列表里短长按卡片后上下拖动
        Text('调整顺序：按住约 0.2 秒上下拖动；拖到屏幕上下边缘会自动滚动，可移到屏幕外的音源')
          .fontSize(FONT.caption)
          .fontColor(this.p().text3)
          .width('100%')
          .padding({ left: 4, right: 4, top: 10, bottom: 2 })
      }
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 14, bottom: 30 })
    .backgroundColor(glassCardBase(this.isDark))
    .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
    .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
    .shadow(glassShadow(this.isDark, this.lightLevel))
  }

  @Builder
  menuRow(icon: Resource, label: string, danger: boolean, action: () => void) {
    Row({ space: 14 }) {
      SymbolGlyph(icon).fontSize(18).fontColor([danger ? this.p().danger : this.p().text2])
      Text(label)
        .fontSize(FONT.body)
        .fontColor(danger ? this.p().danger : this.p().text)
        .layoutWeight(1)
    }
    .width('100%')
    .height(50)
    .onClick(() => {
      action();
    })
  }


  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Top }) {
      Column({ space: 14 }) {

        List({ space: 12, scroller: this.listScroller }) {
          if (!this.selectMode) {
            ListItem() {
              Column({ space: 12 }) {
                this.sourceOverview()
                // v2.53：自检结果紧跟概览——都是「这台机器现在什么状态」的答案
                this.checkReportCard()
                this.actionBar()
              }
              .width('100%')
            }
          }

          if (!this.selectMode) {
            ListItem() {
              Column({ space: 12 }) {
                this.sourceSettings()
                // 空态由下面的 EmptyView 负责引导，不再显示「已导入音源 0 个」
                if (this.items.length > 0) {
                  this.sectionTitle()
                }
              }
              .width('100%')
            }
          }

          if (!this.sourcesReady) {
            ListItem() {
              LoadingBlock({ text: '正在准备音源沙箱' })
            }
          }

          if (this.items.length === 0) {
            ListItem() {
              EmptyView({
                icon: $r('sys.symbol.link'),
                title: '还没有音源',
                hint: '从本机选一个洛雪音源脚本（.js），才能播放歌曲。可以一次选多个。',
                action: '本地导入',
                onAction: () => {
                  this.importScript();
                }
              })
            }
          } else {
            ForEach(this.items, (item: SourceItem, index: number) => {
              ListItem() {
                this.sourceCard(item, index)
              }
              // 左滑露出四枚玻璃圆钮：自检 / 刷新 / 导出 / 删除，删除仍带确认弹窗
              .swipeAction({ end: this.swipeActions(item) })
            }, (item: SourceItem) => item.id + '|' + item.status + '|' + item.health + '|' +
              item.checkedAt.toString() + '|' + item.enabled.toString() + '|' + item.order.toString() +
              (this.selectMode && this.isSelected(item.id) ? '_s' : ''))
            ListItem() {
              Row().height(PAGE_BOTTOM + MINI_BAR_SPACE)
            }
          }
        }
        .width('100%')
        .layoutWeight(1)
        .onAreaChange((_old: Area, now: Area) => {
          const h = Number(now.height);
          if (h > 0) {
            this.listH = h;
            this.listTop = Number(now.globalPosition.y);
          }
        })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        // v2.19：官方 cachedCount 是双参 (count, show)，show 默认 false ——
        // 单参 cachedCount(n) 只把 item「预布局」，预加载区默认不参与绘制。
        // 这正是 v2.18 加了 cachedCount(items.length + 8) 仍出现白块的原因：
        // 被拖卡片靠 .translate 离开自己的布局槽位后，布局窗口再大也不负责画它。
        // 现在跟手卡片改由页面 Stack 的 ghostLayer 独立绘制，彻底不依赖 List；
        // 这里保留大窗口 + show=true，是给「手势宿主 ListItem 不被回收」与
        // 「其余卡片 shiftY 让位跨屏时仍连续」兜底。音源最多几十条，开销可忽略。
        .cachedCount(this.items.length + 8, true)
        // 拖动激活后停用列表「手势」滚动：垂直手势只交给被拖卡片的 PanGesture。
        // 官方明确 false 不影响 Scroller 的 scrollBy / scrollToIndex，
        // 所以边缘自动滚屏仍能走控制器把屏幕外的音源带进视口。
        .enableScrollInteraction(!this.dragActive)

        // v2.50：选择条固定在列表下方（全局迷你播放条 / 胶囊标签栏之上），
        // 不再作为 List 的第一个 ListItem 跟着内容滚到屏幕外。
        // v2.55：换成公共 SelectionBar，音源页比另两页多一个「导出所选」。
        if (this.selectMode) {
          SelectionBar({
            selectedCount: this.selected.length,
            totalCount: this.items.length,
            allSelected: this.allSelected(),
            secondaryLabel: this.exporting ? '导出中…' : '导出所选',
            busy: this.removing,
            disabled: this.exporting,
            onCancel: (): void => {
              this.exitSelect();
            },
            onToggleAll: (): void => {
              this.toggleAll();
            },
            onSecondary: (): void => {
              this.exportSelected();
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
      .backgroundColor(this.p().bg)
      .bindSheet($$this.menuShow, this.menuSheet(), {
        height: SheetSize.FIT_CONTENT,
        dragBar: false,
        backgroundColor: glassCardBase(this.isDark)
      })

      ImmersiveBar({
        title: '音源管理',
        subtitle: this.items.length.toString() + ' 个音源',
        onBack: () => {
          // v2.55：与系统返回共用同一套优先级（选择模式 → 浮层 → 退页）
          App.get().back((): boolean => this.localBack());
        }
      })

      // v2.19：拖动浮层放在 Stack 最后（最上层），拖到顶部边缘时也不会被
      // ImmersiveBar 压住；它与 List 平级，不参与 List 的布局与裁剪。
      if (this.dragActive) {
        this.ghostLayer()
      }
      }
      .onAreaChange((_old: Area, now: Area) => {
        this.stackTop = Number(now.globalPosition.y);
      })
    }
    .hideTitleBar(true)
    // 返回优先级：页内临时态（选择模式）→ 全局浮层 → 退页，顺序只在 App.consumeBack 定义
    .onBackPressed(() => App.get().consumeBack((): boolean => this.localBack()))
  }
}

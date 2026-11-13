import {
  palette, Palette, RADIUS, SPACE, FONT, qualityLabel,
  glassCardBase, glassSurface, glassEdgeWidth, glassEdgeColor, glassShadow, glassRowShadow
} from '../common/Constants';
import { SongInfo, SheetInfo, formatCount, formatTime } from '../common/Models';
import { seededGradient, placeholderGradient, withAlpha } from '../common/Utils';
import { platformColor, platformShort } from '../common/Platform';
import { Library } from '../core/Library';
import { App } from '../core/App';
import { CoverRepo } from '../core/CoverRepo';

/* ============================ 封面 ============================ */
@Component
export struct Cover {
  @Prop @Watch('onUriChange') uri: string = '';
  /** 歌曲封面传 CoverRepo.keyOf(song)，缺图时订阅后台补全结果；歌单/歌手图留空 */
  @Prop @Watch('onSongIdChange') songId: string = '';
  /** 边长。传 <= 0 表示跟随外层容器（外层必须给定宽高，例如 width 100% + aspectRatio(1)） */
  @Prop side: number = 48;
  @Prop radius: number = 10;
  @Prop elevated: boolean = false;
  @Prop badge: string = '';
  /** 无图时的占位文字（如歌手名首字）；为空则退回 ♪ */
  @Prop fallbackText: string = '';
  /** 主封面加载失败时切换的备用 URL（如酷我榜单 v9_pic2）；为空则直接占位 */
  @Prop fallbackUri: string = '';
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('coverVersion') @Watch('onCoverVersion') coverVersion: number = 0;
  @State shownUri: string = '';
  @State failed: boolean = false;
  @State retried: boolean = false;
  /** 主封面已经判失败、当前显示备用 URL；coverVersion 刷新时据此保持备用，不弹回主图 */
  @State useFallback: boolean = false;

  /** 占位渐变种子：有图用图 URL，无图用占位文字，让不同项底色不同 */
  private gradientSeed(): string {
    if (this.shownUri.length > 0) {
      return this.shownUri;
    }
    return this.fallbackText.length > 0 ? this.fallbackText : 'lx';
  }

  aboutToAppear(): void {
    this.refreshUri();
  }

  onUriChange(): void {
    this.failed = false;
    this.retried = false;
    this.useFallback = false;
    this.refreshUri();
  }

  /**
   * 列表项复用 / 切歌时 songId 会变，但 uri 可能一直是空串。
   * 旧实现只监听 uri，导致「上一首补到的封面」留在组件里继续显示 ——
   * 这是封面错乱的主因。songId 一变先清空，再按新 key 取。
   */
  onSongIdChange(): void {
    this.shownUri = '';
    this.failed = false;
    this.retried = false;
    this.useFallback = false;
    this.refreshUri();
  }

  onCoverVersion(): void {
    this.refreshUri();
  }

  /** 后台补到封面后，Cover 主动去仓库里取，绕开 @Prop 副本不回写的问题 */
  private refreshUri(): void {
    const filled = this.songId.length > 0 ? CoverRepo.get().lookup(this.songId) : '';
    let next = filled.length > 0 ? filled : this.uri;
    // 主封面判过失败、且有备用 URL 时保持备用，不让 coverVersion 广播把它弹回死链
    if (this.useFallback && filled.length === 0 && this.fallbackUri.length > 0) {
      next = this.fallbackUri;
    }
    if (next !== this.shownUri) {
      this.failed = false;
      this.retried = false;
      this.shownUri = next;
    }
  }


  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 135,
          colors: [[placeholderGradient(this.gradientSeed())[0], 0],
            [placeholderGradient(this.gradientSeed())[1], 1]]
        })
      if (this.shownUri.length > 0 && !this.failed) {
        Image(this.shownUri)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .draggable(false)
          .onError(() => {
            // 主封面 404 / 假图：优先切到备用 URL（如酷我榜单 v9_pic2），
            // 切过就不再重复切，避免备用也坏时死循环。
            if (!this.useFallback && this.fallbackUri.length > 0 &&
                this.fallbackUri !== this.shownUri) {
              this.useFallback = true;
              this.failed = false;
              this.retried = false;
              this.shownUri = this.fallbackUri;
              return;
            }
            // 再给一次备用形态（尺寸占位 / 协议互切），仍失败才落到占位图
            if (!this.retried) {
              this.retried = true;
              const alt = CoverRepo.alternate(this.shownUri);
              if (alt.length > 0 && alt !== this.shownUri) {
                this.shownUri = alt;
                return;
              }
            }
            this.failed = true;
            // 接口给了图但是坏图（404/假图）：之前这里就永远 ♪ 了。
            // 让仓库按 key 强制重补一次，补到会广播 coverVersion 再刷新。
            if (this.songId.length > 0) {
              CoverRepo.get().refill(this.songId);
            }
          })
      } else {
        // 外层 Stack 用 BottomEnd 是为了把角标钉在右下角，但 alignContent 对
        // 所有子组件生效：占位文字若直接放这里会被一起推到右下角、再被圆形
        // clip 裁掉半边（咪咕无头像时「周」字就贴在圆右下）。这里自己铺满一层
        // 再居中，尺寸 100% 的容器不受 Stack 对齐影响，角标位置保持不变。
        Column() {
          Text(this.badge.length > 0 ? this.badge : (this.fallbackText.length > 0 ? this.fallbackText : '♪'))
            .fontSize(this.side > 0 ? this.side * 0.34 : 26)
            .fontColor('#CCFFFFFF')
            .fontWeight(FontWeight.Medium)
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
      if (this.badge.length > 0 && this.shownUri.length > 0 && !this.failed) {
        Text(this.badge)
          .fontSize(this.side > 0 ? Math.max(8, this.side * 0.16) : 11)
          .fontColor('#FFFFFFFF')
          .backgroundColor('#66000000')
          .borderRadius(4)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .margin({ right: 4, bottom: 4 })
      }
    }
    .width(this.side > 0 ? this.side : '100%')
    .height(this.side > 0 ? this.side : '100%')
    .borderRadius(this.radius)
    .clip(true)
    .border({ width: 0.8, color: withAlpha('#FFFFFFFF', this.isDark ? 0.10 : 0.35) })
    .shadow(this.elevated
      ? { radius: 22, color: this.isDark ? '#70000000' : '#240B1220', offsetY: 10 }
      : { radius: 0, color: '#00000000' })
  }
}

/* ============================ 图标按钮 ============================ */
@Component
export struct IconTap {
  @Prop icon: Resource = $r('sys.symbol.more');
  @Prop iconSize: number = 20;
  @Prop color: ResourceColor = '#FF6E7480';
  @Prop paddingSize: number = 8;
  @Prop filled: boolean = false;
  /**
   * v2.56：读屏名称。格式「{动作}」，例如「收藏这首歌」「返回」。
   * 留空表示装饰性图标，读屏按默认规则处理（不进焦点树）。
   */
  @Prop label: string = '';
  /**
   * v2.56：最小命中区（vp）。墨栈规范 08 节要求触控目标 ≥48×48。
   * 图标视觉尺寸只有 26–40vp，这里用 responseRegion 把热区扩到 48，
   * 视觉一个像素都不动 —— 扩的是命中范围，不是图标。
   */
  @Prop minHit: number = 48;
  onTap: () => void = (): void => {
  };

  /** 图标本体占位（视觉尺寸），不随热区变化 */
  private visualSize(): number {
    return this.iconSize + this.paddingSize * 2;
  }

  /** 热区向四周外扩的半径；视觉已达标时为 0 */
  private hitPad(): number {
    const d: number = this.minHit - this.visualSize();
    return d > 0 ? d / 2 : 0;
  }

  build() {
    Stack() {
      SymbolGlyph(this.icon)
        .fontSize(this.iconSize)
        .fontColor([this.color])
    }
    .width(this.iconSize + this.paddingSize * 2)
    .height(this.iconSize + this.paddingSize * 2)
    .borderRadius((this.iconSize + this.paddingSize * 2) / 2)
    .responseRegion({
      x: -this.hitPad(),
      y: -this.hitPad(),
      width: this.minHit,
      height: this.minHit
    })
    .accessibilityText(this.label)
    .accessibilityLevel(this.label.length > 0 ? 'yes' : 'auto')
    .stateStyles({
      normal: { .opacity(1).scale({ x: 1, y: 1 }) },
      pressed: { .opacity(0.55).scale({ x: 0.88, y: 0.88 }) }
    })
    .animation({ duration: 120, curve: Curve.EaseOut })
    .onClick(() => {
      this.onTap();
    })
  }
}

/* ============================ 分组标题 ============================ */
@Component
export struct SectionHeader {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop action: string = '';
  @StorageProp('isDark') isDark: boolean = false;
  onAction: () => void = (): void => {
  };

  private p(): Palette {
    return palette(this.isDark);
  }


  build() {
    Row() {
      Column({ space: 2 }) {
        Text(this.title)
          .fontSize(FONT.headline)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.p().text)
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .fontSize(FONT.caption)
            .fontColor(this.p().text3)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.action.length > 0) {
        Row({ space: 2 }) {
          Text(this.action).fontSize(FONT.callout).fontColor(this.p().text3)
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(12).fontColor([this.p().text3])
        }
        .onClick(() => {
          this.onAction();
        })
      }
    }
    .width('100%')
    .padding({ left: 2, right: 2 })
  }
}

/* ============================ 空状态 ============================ */
@Component
export struct EmptyView {
  @Prop icon: Resource = $r('sys.symbol.music_note_list');
  @Prop title: string = '这里空空如也';
  @Prop hint: string = '';
  @Prop action: string = '';
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;
  onAction: () => void = (): void => {
  };

  private p(): Palette {
    return palette(this.isDark);
  }


  build() {
    // 空态不再是一块空白：收成一张居中的玻璃卡座，悬浮感和主界面卡片一致
    Column() {
      Column({ space: SPACE.sm }) {
        Stack() {
          SymbolGlyph(this.icon)
            .fontSize(34)
            .fontColor([withAlpha(this.p().primary, 0.5)])
        }
        .width(76)
        .height(76)
        .borderRadius(38)
        .backgroundColor(withAlpha(this.p().primary, 0.10))
        .margin({ bottom: SPACE.xs })

        Text(this.title)
          .fontSize(FONT.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.p().text2)
        if (this.hint.length > 0) {
          Text(this.hint)
            .fontSize(FONT.callout)
            .fontColor(this.p().text3)
            .textAlign(TextAlign.Center)
        }
        if (this.action.length > 0) {
          Button(this.action)
            .fontSize(FONT.callout)
            .fontColor('#FF191713')
            .backgroundColor(this.p().primary)
            .borderRadius(RADIUS.pill)
            .height(40)
            .padding({ left: 22, right: 22 })
            .margin({ top: SPACE.xs })
            .onClick(() => {
              this.onAction();
            })
        }
      }
      .width('100%')
      .padding({ top: 34, bottom: 34, left: 18, right: 18 })
      .justifyContent(FlexAlign.Center)
      .borderRadius(RADIUS.lg)
      .backgroundColor(glassCardBase(this.isDark))
      .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
      .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
      .shadow(glassShadow(this.isDark, this.lightLevel))
    }
    .width('100%')
    .padding({ left: 6, right: 6, top: 24, bottom: 12 })
  }
}

/* ============================ 加载 ============================ */
@Component
export struct LoadingBlock {
  @Prop text: string = '加载中';
  @StorageProp('isDark') isDark: boolean = false;

  private p(): Palette {
    return palette(this.isDark);
  }


  build() {
    Row({ space: 10 }) {
      LoadingProgress().width(20).height(20).color(this.p().text3)
      Text(this.text).fontSize(FONT.caption).fontColor(this.p().text3)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 36, bottom: 36 })
  }
}

/* ============================ 胶囊 ============================ */
@Component
export struct Chip {
  @Prop text: string = '';
  @Prop active: boolean = false;
  @StorageProp('isDark') isDark: boolean = false;
  onTap: () => void = (): void => {
  };

  private p(): Palette {
    return palette(this.isDark);
  }


  build() {
    Text(this.text)
      .fontSize(FONT.callout)
      .fontWeight(this.active ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.active ? '#FF191713' : this.p().text2)
      .backgroundColor(this.active ? this.p().primary : this.p().cardAlt)
      .borderRadius(RADIUS.pill)
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .onClick(() => {
        this.onTap();
      })
  }
}

/* ============================ 歌单卡片 ============================ */
@Component
export struct SheetCard {
  @Prop sheet: SheetInfo = {
    id: '', name: '', cover: '', description: '', platform: '', kind: '',
    trackCount: 0, playCount: 0, creator: '', updateTime: '', subtitle: ''
  };
  @Prop cardWidth: number = 132;
  /**
   * 标题区固定行数高度。0 = 按内容自适应（发现页 / 搜索页保持原样）。
   * 歌单收藏页传 2：一行标题的「热歌榜」与两行标题的长名占同样高度，
   * 同排卡片的玻璃卡座、副标题才会齐平，不会出现「一短一长」。
   */
  @Prop titleLines: number = 0;
  @StorageProp('isDark') isDark: boolean = false;
  /** 收藏歌单后 Library 广播它，触发本卡重绘，右上角心形角标即时跟上 */
  @StorageProp('libraryVersion') favVersion: number = 0;
  /**
   * v2.70：仅歌单收藏页传 true —— 右上角心形角标升级为「可点按钮」，
   * 点一下直接切换收藏，不必再进歌单详情页。其它页面（发现/搜索/账号页）
   * 默认 false，角标仍是纯展示，视觉与行为都不变。
   */
  @Prop favTappable: boolean = false;
  onFavTap: () => void = (): void => {
  };
  onTap: () => void = (): void => {
  };

  private p(): Palette {
    return palette(this.isDark);
  }

  /** callout 14fp，两行按 20vp/行估；titleLines=0 时返回 0，等于不约束 */
  private titleMinHeight(): number {
    return this.titleLines > 0 ? this.titleLines * (FONT.callout + 6) : 0;
  }

  /** 平台歌单可收藏；本地列表（喜欢/历史/本地/下载）不在收藏表里，天然返回 false */
  private sheetFav(): boolean {
    return this.favVersion >= 0 && Library.get().isSheetFavorite(this.sheet);
  }


  build() {
    Column({ space: 8 }) {
      Stack({ alignContent: Alignment.TopStart }) {
        Cover({
          uri: this.sheet.cover,
          side: this.cardWidth,
          radius: 16,
          elevated: true,
          badge: platformShort(this.sheet.platform)
        })
        if (this.sheet.playCount > 0) {
          Row({ space: 3 }) {
            SymbolGlyph($r('sys.symbol.play_fill')).fontSize(9).fontColor(['#FFFFFFFF'])
            Text(formatCount(this.sheet.playCount)).fontSize(10).fontColor('#FFFFFFFF')
          }
          .backgroundColor('#4D000000')
          .borderRadius(8)
          .padding({ left: 6, right: 6, top: 3, bottom: 3 })
          .margin({ left: 8, top: 8 })
        }
        // 右上角「收藏」角标：订阅 libraryVersion，歌单详情页收藏后所有歌单卡同步亮起。
        // v2.70：favTappable（收藏页）时它不再是纯图标，而是可点按钮 —— 点一下
        // 直接切换收藏并触发对应平台的账号同步，不用再进歌单详情页去操控取消。
        // 外层满尺寸容器保持 HitTestMode.None：官方语义是「自身不响应、但子节点
        // 仍参与命中测试」，所以既不会挡住卡片其它区域的点击，角标自身又能收到点击。
        Stack({ alignContent: Alignment.TopEnd }) {
          if (this.sheetFav() || this.favTappable) {
            Stack() {
              if (this.sheetFav()) {
                SymbolGlyph($r('sys.symbol.heart_fill'))
                  .fontSize(this.favTappable ? 15 : 12).fontColor(['#FF191713'])
              } else {
                SymbolGlyph($r('sys.symbol.heart'))
                  .fontSize(this.favTappable ? 15 : 12).fontColor([palette(this.isDark).text2])
              }
            }
            .width(this.favTappable ? 32 : 24)
            .height(this.favTappable ? 32 : 24)
            .borderRadius(this.favTappable ? 16 : 12)
            .linearGradient({ angle: 135, colors: [['#FFE29A26', 0], ['#FFF3B044', 1]] })
            .border({ width: 1, color: palette(this.isDark).glassBorder })
            .shadow({ radius: 6, color: 'rgba(27,26,24,0.10)', offsetY: 2 })
            .margin({ top: 6, right: 6 })
            // 可点态给按压反馈，让「这是按钮」在手指按下的瞬间就可见
            .stateStyles({
              normal: { .scale({ x: 1, y: 1 }) },
              pressed: { .scale({ x: 0.86, y: 0.86 }) }
            })
            .animation({ duration: 120, curve: Curve.EaseOut })
            .onClick(() => {
              if (this.favTappable) {
                this.onFavTap();
              }
            })
            // Block：自身命中并阻塞祖先命中测试，点角标不会再冒泡触发卡片 onTap
            // 打开详情页；不可点态维持 None，角标区点击照常落到卡片上。
            .hitTestBehavior(this.favTappable ? HitTestMode.Block : HitTestMode.None)
          }
        }
        .width(this.cardWidth)
        .height(this.cardWidth)
        .hitTestBehavior(HitTestMode.None)
      }

      // 外面套一层 Column 并给最小高度：文本顶部对齐，一行 / 两行标题
      // 占同样高度；titleLines=0 时高度为 0，等价于原来的裸 Text。
      Column() {
        Text(this.sheet.name)
          .fontSize(FONT.callout)
          .fontColor(this.p().text)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .width('100%')
      .constraintSize({ minHeight: this.titleMinHeight() })
      .justifyContent(FlexAlign.Start)
      .alignItems(HorizontalAlign.Start)
      Text(this.sheet.subtitle.length > 0 ? this.sheet.subtitle :
        (this.sheet.trackCount > 0 ? this.sheet.trackCount.toString() + ' 首' : this.sheet.creator))
        .fontSize(FONT.micro)
        .fontColor(this.p().text3)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width(this.cardWidth)
    .alignItems(HorizontalAlign.Start)
    .stateStyles({
      normal: { .opacity(1).scale({ x: 1, y: 1 }) },
      pressed: { .opacity(0.78).scale({ x: 0.96, y: 0.96 }) }
    })
    .animation({ duration: 140, curve: Curve.EaseOut })
    .onClick(() => {
      this.onTap();
    })
  }
}

/**
 * 带青绿液态玻璃卡座的歌单卡。
 *
 * 发现页「推荐歌单」和搜索页「歌单」以前各写各的：发现页在调用处套了一层
 * 玻璃卡座，搜索页只有一个裸 SheetCard，于是同一张歌单卡在两个页面一个
 * 浮起来、一个贴在白底上。现在把卡座收进组件，两处只传 cardWidth，
 * 渲染代码只有这一份，以后改样式不会再漏掉其中一边。
 *
 * cardWidth 仍是封面边长；外层 padding(8) 额外占 16vp。
 * 两列用 140（总 156）、三列用 88（总 104），都塞得进约 320vp 的可用宽。
 */
@Component
export struct GlassSheetCard {
  @Prop sheet: SheetInfo = {
    id: '', name: '', cover: '', description: '', platform: '', kind: '',
    trackCount: 0, playCount: 0, creator: '', updateTime: '', subtitle: ''
  };
  @Prop cardWidth: number = 132;
  /** 透传给 SheetCard：0 = 自适应，>0 = 标题区固定行数高（同排卡片等高） */
  @Prop titleLines: number = 0;
  /**
   * v2.70：透传给 SheetCard 的「心形角标可点」开关。仅歌单收藏页传 true，
   * 让右上角心形直接切换收藏；发现页 / 搜索页默认 false，角标仍是纯展示，
   * 视觉与行为都不变。选中态（选择模式）由调用方临时关掉，避免误触。
   */
  @Prop favTappable: boolean = false;
  onFavTap: () => void = (): void => {
  };
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;
  onTap: () => void = (): void => {
  };


  build() {
    Column() {
      SheetCard({
        sheet: this.sheet,
        cardWidth: this.cardWidth,
        titleLines: this.titleLines,
        favTappable: this.favTappable,
        onFavTap: (): void => {
          this.onFavTap();
        },
        onTap: () => {
          this.onTap();
        }
      })
    }
    .padding(8)
    .borderRadius(RADIUS.lg)
    .backgroundColor(glassCardBase(this.isDark))
    .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
    .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
    .shadow(glassShadow(this.isDark, this.lightLevel))
  }
}

/* ==================== 歌单广场大卡片（双列网格） ==================== */
/**
 * 与 SheetCard 的区别：封面按父容器宽度自适应成 1:1 大图，
 * 播放量角标在左下角，标题固定两行，下面补「作者 · N首 · X次播放」。
 * 只展示接口真实返回的字段，缺哪个就省略哪个，不编造数字。
 */
@Component
export struct SheetGridCard {
  @Prop @Watch('onSheetChange') sheet: SheetInfo = {
    id: '', name: '', cover: '', description: '', platform: '', kind: '',
    trackCount: 0, playCount: 0, creator: '', updateTime: '', subtitle: ''
  };
  @StorageProp('isDark') isDark: boolean = false;
  @State imgFailed: boolean = false;
  onTap: () => void = (): void => {
  };

  onSheetChange(): void {
    this.imgFailed = false;
  }

  private p(): Palette {
    return palette(this.isDark);
  }

  private meta(): string {
    const parts: string[] = [];
    if (this.sheet.creator.length > 0) {
      parts.push(this.sheet.creator);
    }
    if (this.sheet.trackCount > 0) {
      parts.push(this.sheet.trackCount.toString() + '首');
    }
    if (this.sheet.playCount > 0) {
      parts.push(formatCount(this.sheet.playCount) + '次播放');
    }
    return parts.join(' · ');
  }


  build() {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.BottomStart }) {
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 135,
            colors: [[seededGradient(this.sheet.id.length > 0 ? this.sheet.id : 'lx')[0], 0],
              [seededGradient(this.sheet.id.length > 0 ? this.sheet.id : 'lx')[1], 1]]
          })
        if (this.sheet.cover.length > 0 && !this.imgFailed) {
          Image(this.sheet.cover)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .draggable(false)
            .onError(() => {
              this.imgFailed = true;
            })
        } else {
          Column() {
            Text('♪').fontSize(34).fontColor('#CCFFFFFF')
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        }
        if (this.sheet.playCount > 0) {
          Row({ space: 3 }) {
            SymbolGlyph($r('sys.symbol.play_fill')).fontSize(10).fontColor(['#FFFFFFFF'])
            Text(formatCount(this.sheet.playCount)).fontSize(11).fontColor('#FFFFFFFF')
          }
          .backgroundColor('#80000000')
          .borderRadius(10)
          .padding({ left: 7, right: 8, top: 3, bottom: 3 })
          .margin({ left: 8, bottom: 8 })
        }
      }
      .width('100%')
      .aspectRatio(1)
      .borderRadius(12)
      .clip(true)
      .border({ width: 0.8, color: withAlpha('#FFFFFFFF', this.isDark ? 0.10 : 0.35) })

      Text(this.sheet.name)
        .fontSize(FONT.callout)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.p().text)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .height(38)

      Text(this.meta().length > 0 ? this.meta() : ' ')
        .fontSize(FONT.micro)
        .fontColor(this.p().text3)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .stateStyles({
      normal: { .opacity(1).scale({ x: 1, y: 1 }) },
      pressed: { .opacity(0.78).scale({ x: 0.97, y: 0.97 }) }
    })
    .animation({ duration: 140, curve: Curve.EaseOut })
    .onClick(() => {
      this.onTap();
    })
  }
}

/* ============================ 歌曲行 ============================ */
@Component
export struct SongRow {
  @Prop song: SongInfo = {
    id: '', songmid: '', hash: '', name: '', singer: '', album: '', interval: '',
    source: '', duration: 0, cover: '', lyric: '', url: '', quality: ''
  };
  @Prop index: number = -1;
  @Prop showCover: boolean = true;
  @Prop showQuality: boolean = true;
  /** 需要隐藏行内平台小标时置 false（比如外层已经标明来源） */
  @Prop showSource: boolean = true;
  /** 列表里显示左侧序号（搜索页对齐主流播放器） */
  @Prop showIndex: boolean = false;
  /** 榜单前 N 名用强调色标名次，0 表示不标 */
  @Prop rankTop: number = 0;
  /**
   * 行内收藏按钮。之前收藏只能走「行尾 ⋮ → 菜单」，
   * 是列表里最高频的动作却要两次点击，这里提到行内。
   */
  @Prop showFavorite: boolean = true;
  /** 收藏变化后刷新，靠 Library 的全局版本号广播 */
  @StorageProp('libraryVersion') libVersion: number = 0;
  /**
   * 本行收藏按钮的点击脉冲：点心形时先弹大再回弹，既给即时动画反馈，
   * 又是一个必定被 build 读取的 @State —— 与 libVersion 一起把这一行
   * 挂进依赖图，保证点一下图标立刻重绘，不必等广播绕一圈。
   */
  @State favScale: number = 1;
  /** 多选模式（本地音乐的批量删除）：显示勾选圈，隐藏序号/收藏/更多 */
  @Prop selectMode: boolean = false;
  @Prop selected: boolean = false;
  /**
   * 播放器广播。之前 active 由父页面在 build 时算好传进来，
   * 切歌后父页面不重建，高亮就停在原来那首上。
   */
  @StorageProp('playerVersion') playerVersion: number = 0;
  @Prop active: boolean = false;
  @Prop playing: boolean = false;
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;
  /** v2.30：下载完成后 Downloader 广播它，行尾按钮据此从「下载」回退成「更多」 */
  @StorageProp('downloadVersion') dlVersion: number = 0;
  onTap: () => void = (): void => {
  };
  onMore: () => void = (): void => {
  };

  aboutToAppear(): void {
    // 酷我榜单/歌单等接口本身不带封面，渲染到这一行时再按需补，不拖慢列表加载
    CoverRepo.get().ensure(this.song);
  }

  private p(): Palette {
    return palette(this.isDark);
  }

  /** 是否是当前播放的这首（平台 + id 一起比，不同平台会重 id） */
  private isCurrent(): boolean {
    if (this.song.id.length === 0) {
      return this.active;
    }
    const cur: SongInfo = App.get().player.getSong();
    return cur.id === this.song.id && cur.source === this.song.source;
  }

  private isPlayingNow(): boolean {
    return this.isCurrent() && App.get().player.isPlaying();
  }

  /** 序号颜色：正在播放 > 榜单前三 > 常规灰 */
  private rankColor(): ResourceColor {
    if (this.isCurrent()) {
      return this.p().primary;
    }
    if (this.rankTop > 0 && this.index > 0 && this.index <= this.rankTop) {
      return this.p().accent;
    }
    return this.p().text3;
  }

  private isTopRank(): boolean {
    return this.rankTop > 0 && this.index > 0 && this.index <= this.rankTop;
  }

  private isFav(): boolean {
    // libVersion（跨页广播）与 favScale（本行点击脉冲）都必须被读取，
    // ArkUI 才会把这行纳入依赖图；否则 Library.notify() 改了库、toast 也弹了，
    // 心形仍停在旧状态 —— v2.17 用户反馈的「提示已收藏但不实时反馈」根因。
    // 与 SheetCard.sheetFav() 里 favVersion >= 0 的写法同一手法。
    return (this.libVersion + this.favScale) >= 0 && Library.get().isFavorite(this.song);
  }

  /**
   * v2.56：一行的读屏语句，按「{名称}，{角色}，{状态}」拼。
   * 读屏用户听到的是「晴天，周杰伦，歌曲，叶惠美，4:29，正在播放」，
   * 而不是歌名 / 平台角标 / 歌手 / 专辑 / 时长五段碎片。
   */
  private rowLabel(): string {
    const who: string = this.song.singer.length > 0 ? this.song.singer : '未知歌手';
    let text: string = this.song.name + '，' + who + '，歌曲';
    if (this.song.album.length > 0) {
      text += '，' + this.song.album;
    }
    if (this.song.interval.length > 0) {
      text += '，' + this.song.interval;
    }
    if (this.isCurrent()) {
      text += this.isPlayingNow() ? '，正在播放' : '，已暂停';
    }
    return text;
  }

  private toggleFav(): void {
    const added = Library.get().toggleFavorite(this.song);
    // 点一下先弹大再回弹：即时动画反馈 + 触发本行重绘，
    // 图标 heart<->heart_fill、颜色 accent<->text3 在同一帧跟上。
    animateTo({ duration: 140, curve: Curve.EaseOut }, () => {
      this.favScale = 1.28;
    });
    setTimeout((): void => {
      animateTo({ duration: 180, curve: Curve.EaseOut }, () => {
        this.favScale = 1;
      });
    }, 150);
    App.get().toast(added ? '已收藏' : '已取消收藏');
  }

  /**
   * v2.30：行尾下载按钮只在「网络歌曲且本地还没有」时出现。
   * 读 dlVersion 把这一行挂进依赖图，下载完成后立即回退，
   * 与 isFav() 读 libVersion 是同一手法。
   */
  private canDownload(): boolean {
    return (this.dlVersion + 1) >= 0 &&
      this.song.source !== 'local' && this.song.source.length > 0 &&
      !App.get().hasDownload(this.song);
  }

  /**
   * v2.45：已下载态。与 canDownload 互斥（一个 !hasDownload、一个 hasDownload），
   * 读 dlVersion 把这一行挂进依赖图，下载完成广播后图标立刻从「下载」翻成「已下载」。
   * 之前 canDownload 变 false 会直接落到 else 的 more 四宫格，看不出下载已完成。
   */
  private isDownloaded(): boolean {
    return (this.dlVersion + 1) >= 0 &&
      this.song.source !== 'local' && this.song.source.length > 0 &&
      App.get().hasDownload(this.song);
  }

  /** 行尾下载：与 SongMenu 的「下载到本地」同一套真实动作，点了就入队 */
  private download(): void {
    if (App.get().hasDownload(this.song)) {
      App.get().toast('这首歌已经在本地了');
      return;
    }
    App.get().downloads.enqueue(this.song);
    App.get().toast('已加入下载队列');
  }


  build() {
    Row({ space: 12 }) {
      // 多选态：用勾选圈顶掉序号位，行尾的收藏/更多一并收起，避免一次误触变成收藏
      if (this.selectMode) {
        Stack({ alignContent: Alignment.Center }) {
          if (this.selected) {
            SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
              .fontSize(22)
              .fontColor([this.p().primary])
          } else {
            Column()
              .width(20)
              .height(20)
              .borderRadius(10)
              .border({ width: 1.2, color: withAlpha(this.p().text3, 0.7) })
          }
        }
        .width(24)
        .height(24)
        .margin({ left: 2 })
      }
      if (this.showIndex && !this.selectMode) {
        Text(this.index > 0 ? this.index.toString() : '')
          .fontSize(this.isTopRank() ? FONT.body : FONT.caption)
          .fontWeight(this.isTopRank() ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(this.rankColor())
          .width(16)
          .textAlign(TextAlign.Center)
      }
      if (this.index > 0 && !this.showCover && !this.showIndex && !this.selectMode) {
        Text(this.index.toString())
          .fontSize(this.isTopRank() ? FONT.headline : FONT.callout)
          .fontWeight(this.isTopRank() ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(this.rankColor())
          .width(24)
          .textAlign(TextAlign.Center)
      }
      if (this.showCover) {
        Stack({ alignContent: Alignment.Center }) {
          Cover({ uri: this.song.cover, songId: CoverRepo.keyOf(this.song), side: 48, radius: 10 })
          if (this.isCurrent()) {
            Stack() {
              SymbolGlyph(this.isPlayingNow() ? $r('sys.symbol.waveform') : $r('sys.symbol.pause'))
                .fontSize(18)
                .fontColor(['#FFFFFFFF'])
            }
            .width(48)
            .height(48)
            .borderRadius(10)
            .backgroundColor('#59000000')
          }
        }
      }

      Column({ space: 4 }) {
        Row({ space: 5 }) {
          // 长歌名不再截断成省略号：MARQUEE 只在文本溢出时横向循环滚动，
          // 短歌名保持静止。maxLines 在 MARQUEE 下被忽略、clip 默认开启，
          // 其余字号 / 字重 / 颜色 / 当前播放态高亮全部沿用原来的 Text 样式。
          Text(this.song.name)
            .fontSize(FONT.body)
            .fontWeight(this.isCurrent() ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.isCurrent() ? this.p().primary : this.p().text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.MARQUEE })
            .marqueeOptions({ start: true, loop: -1, step: 2, fromStart: true })
            .layoutWeight(1)
          if (this.showSource && this.song.source !== 'local' && this.song.source.length > 0) {
            Text(platformShort(this.song.source))
              .fontSize(9)
              .fontColor(platformColor(this.song.source))
              .border({ width: 0.5, color: withAlpha(platformColor(this.song.source), 0.4) })
              .borderRadius(4)
              .padding({ left: 3, right: 3, top: 1, bottom: 1 })
          }
        }
        .width('100%')

        // 副标题合成一段：原来「歌手 / · / 专辑」三段 Text 各自截断，
        // 改成跑马灯会互相挤压、溢出判定不稳。合并后「歌手 · 专辑」整行滚动，
        // 视觉与原来完全一致，读屏仍走上面 rowLabel() 的合成语句。
        Row({ space: 4 }) {
          Text((this.song.singer.length > 0 ? this.song.singer : '未知歌手') +
            (this.song.album.length > 0 ? ' · ' + this.song.album : ''))
            .fontSize(FONT.caption)
            .fontColor(this.p().text3)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.MARQUEE })
            .marqueeOptions({ start: true, loop: -1, step: 2, fromStart: true })
            .layoutWeight(1)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      // v2.56：歌名 / 歌手 / 专辑 / 时长合成一条语句播报，避免逐个 Text 碎片刷屏
      .accessibilityGroup(true)
      .accessibilityText(this.rowLabel())
      .accessibilityDescription('双击播放')
      .onClick(() => {
        this.onTap();
      })

      if (this.showQuality && this.song.quality.length > 0 && this.song.quality !== 'local') {
        Text(qualityLabel(this.song.quality))
          .fontSize(9)
          .fontColor(this.p().text3)
          .border({ width: 0.5, color: this.p().line })
          .borderRadius(4)
          .padding({ left: 3, right: 3, top: 1, bottom: 1 })
      }
      if (this.song.interval.length > 0) {
        Text(this.song.interval)
          .fontSize(FONT.micro)
          .fontColor(this.p().text3)
      }
      if (this.showFavorite && !this.selectMode) {
        Stack() {
          IconTap({
            icon: this.isFav() ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'),
            iconSize: 18,
            color: this.isFav() ? this.p().accent : this.p().text3,
            paddingSize: 4,
            label: this.isFav() ? '取消收藏，' + this.song.name : '收藏，' + this.song.name,
            onTap: () => {
              this.toggleFav();
            }
          })
        }
        .scale({ x: this.favScale, y: this.favScale })
      }
      if (!this.selectMode) {
        // v2.30：可下载的网络歌曲行尾直接给「下载」按钮（点了就入队）。
        // v2.45：下载完成后不再悄悄回退成 more 四宫格，而是显示「已下载」勾选态，
        // 与播放页 downloadIcon() 同一个符号 + 主色，点了如实提示已在本地；
        // 本地音乐 / 来源为空仍保持「更多」菜单。长按整行始终弹完整 SongMenu。
        if (this.canDownload()) {
          IconTap({
            icon: $r('sys.symbol.arrow_down_circle'),
            iconSize: 18,
            color: this.p().text3,
            paddingSize: 4,
            label: '下载，' + this.song.name,
            onTap: () => {
              this.download();
            }
          })
        } else if (this.isDownloaded()) {
          IconTap({
            icon: $r('sys.symbol.checkmark_circle_fill'),
            iconSize: 18,
            color: this.p().primary,
            paddingSize: 4,
            label: '已下载，' + this.song.name,
            onTap: () => {
              App.get().toast('这首歌已经在本地了');
            }
          })
        } else {
          IconTap({
            icon: $r('sys.symbol.more'),
            iconSize: 18,
            color: this.p().text3,
            paddingSize: 4,
            label: '更多操作，' + this.song.name,
            onTap: () => {
              this.onMore();
            }
          })
        }
      }
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 9, bottom: 9 })
    .borderRadius(RADIUS.md)
    // 行间留出间隙 + 一层轻投影，卡片才像浮在页面上而不是平铺的白板
    .margin({ top: 3, bottom: 5 })
    .backgroundColor(glassCardBase(this.isDark))
    .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
    .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
    .shadow(glassRowShadow(this.isDark))
    // 按压反馈只改不透明度与缩放，不碰 backgroundColor —— 否则会把整块玻璃渐变盖成纯色
    .stateStyles({
      normal: { .opacity(1).scale({ x: 1, y: 1 }) },
      pressed: { .opacity(0.82).scale({ x: 0.985, y: 0.985 }) }
    })
    .animation({ duration: 120, curve: Curve.EaseOut })
    .gesture(
      LongPressGesture({ repeat: false, duration: 400 })
        .onAction(() => {
          // 多选态长按不弹单曲菜单，否则一按就把选择流程打断
          if (this.selectMode) {
            return;
          }
          this.onMore();
        })
    )
    .onClick(() => {
      this.onTap();
    })
  }
}

/* ============================ 顶栏 ============================ */
/**
 * v2.54：顶栏可选的搜索动作。
 *
 * 搜索不占一个新路由、也不占一个一级 Tab —— 它只是把已经存在的 App.openSearch()
 * 提到每个二级页的顶栏上，让「人在榜单页 / 歌单详情里想搜一首歌」不必先退回首页。
 * 默认关闭，只有显式传 showSearch 的页面才出现按钮，其他页面视觉一行未变。
 */
@Component
export struct PageBar {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop transparent: boolean = false;
  @Prop showSearch: boolean = false;
  /**
   * v2.72：顶栏右上角可选动作按钮。默认关闭 —— 只有显式传 showTrailing 的页面
   * 才多这一个图标，其它二级页顶栏一字不改（不新增路由、不动返回链）。
   * 收藏页用它承载「导入歌单」，图标与回调都由宿主页面决定。
   */
  @Prop showTrailing: boolean = false;
  @Prop trailingIcon: Resource = $r('sys.symbol.plus');
  @Prop trailingLabel: string = '';
  @StorageProp('isDark') isDark: boolean = false;
  onBack: () => void = (): void => {
  };
  onSearch: () => void = (): void => {
  };
  onTrailing: () => void = (): void => {
  };

  private p(): Palette {
    return palette(this.isDark);
  }


  build() {
    Row({ space: 6 }) {
      IconTap({
        icon: $r('sys.symbol.chevron_left'),
        iconSize: 24,
        color: this.p().text,
        paddingSize: 8,
        label: '返回',
        onTap: () => {
          this.onBack();
        }
      })
      Column({ space: 1 }) {
        if (this.title.length > 0) {
          Text(this.title)
            .fontSize(FONT.headline)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.p().text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .fontSize(FONT.micro)
            .fontColor(this.p().text3)
            .maxLines(1)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      // v2.56：标题 + 副标题是一条信息，读屏不必分两段停顿
      .accessibilityGroup(true)
      .accessibilityText(this.subtitle.length > 0
        ? this.title + '，' + this.subtitle
        : this.title)

      if (this.showSearch) {
        IconTap({
          icon: $r('sys.symbol.magnifyingglass'),
          iconSize: 21,
          color: this.p().text2,
          paddingSize: 8,
          label: '搜索',
          onTap: () => {
            this.onSearch();
          }
        })
      }
      // v2.72：右上角可选动作（收藏页的「导入歌单」）。默认不渲染，
      // 与搜索按钮并列时各占一个 48vp 热区，互不遮挡。
      if (this.showTrailing) {
        IconTap({
          icon: this.trailingIcon,
          iconSize: 21,
          color: this.p().text2,
          paddingSize: 8,
          label: this.trailingLabel,
          onTap: () => {
            this.onTrailing();
          }
        })
      }
    }
    .width('100%')
    .height(52)
    .padding({ left: 6, right: 12 })
    .backgroundColor(this.transparent ? '#00000000' : this.p().bg)
  }
}

/* ============================ 播放中的小动画 ============================ */
@Component
export struct PlayingBars {
  @Prop active: boolean = false;
  @Prop barColor: ResourceColor = '#FFE29A26';
  @State phase: number = 0;
  private bars: number[] = [0, 1, 2];
  private timer: number = -1;

  aboutToAppear(): void {
    this.timer = setInterval(() => {
      this.phase = (this.phase + 1) % 4;
    }, 260);
  }

  aboutToDisappear(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer);
    }
  }

  build() {
    Row({ space: 2 }) {
      ForEach(this.bars, (i: number) => {
        Column()
          .width(2.5)
          .height(this.active ? (6 + ((this.phase + i) % 3) * 4) : 6)
          .borderRadius(2)
          .backgroundColor(this.barColor)
          .animation({ duration: 240, curve: Curve.EaseInOut })
      }, (i: number) => i.toString())
    }
    .height(16)
    .alignItems(VerticalAlign.Center)
  }
}

/* 统一的小徽标 */
@Component
export struct TinyBadge {
  @Prop text: string = '';
  @Prop color: string = '#FF6E7480';
  build() {
    Text(this.text)
      .fontSize(9)
      .fontColor(this.color)
      .backgroundColor(withAlpha(this.color, 0.1))
      .borderRadius(4)
      .padding({ left: 4, right: 4, top: 1, bottom: 1 })
  }
}

/* ======================= 选择模式的统一操作条 ======================= */
/**
 * v2.55：音源管理 / 歌单收藏 / 歌单详情三处原来各写一份选择条，文案、间距、
 * 禁用条件都不同（音源页两排两个按钮、收藏页一个按钮、详情页挤在头部卡片里
 * 且不在列表下方）。这里收成一套：上排「取消 / 已选 N / M / 全选」，
 * 下排「[次要动作] + 删除所选」，位置固定由调用方摆在列表下方（v2.50 定稿）。
 *
 * 空选与忙态一律禁用删除（不靠调用方各写一遍 enabled），视觉同时压到 0.45。
 */
@Component
export struct SelectionBar {
  /** 已选数量 */
  @Prop selectedCount: number = 0;
  /** 当前列表总数，用于「已选 N / M」 */
  @Prop totalCount: number = 0;
  /** 是否已全选：决定右侧按钮是「全选」还是「取消全选」 */
  @Prop allSelected: boolean = false;
  /** 次要动作文案（音源页「导出所选」）；留空则不渲染该按钮 */
  @Prop secondaryLabel: string = '';
  /** 正在执行删除 */
  @Prop busy: boolean = false;
  @Prop busyLabel: string = '删除中…';
  /** 非删除类的临时禁用（如音源页导出中） */
  @Prop disabled: boolean = false;
  onCancel: () => void = (): void => {
  };
  onToggleAll: () => void = (): void => {
  };
  onSecondary: () => void = (): void => {
  };
  onConfirm: () => void = (): void => {
  };
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;

  private p(): Palette {
    return palette(this.isDark);
  }

  private blocked(): boolean {
    return this.selectedCount <= 0 || this.busy || this.disabled;
  }


  build() {
    Column({ space: 10 }) {
      Row({ space: 12 }) {
        Text('取消')
          .fontSize(FONT.callout)
          .fontColor(this.p().text2)
          .height(44)
          .textAlign(TextAlign.Center)
          .padding({ left: 6, right: 6 })
          .accessibilityText('取消选择')
          .accessibilityLevel('yes')
          .onClick(() => {
            this.onCancel();
          })
        Text('已选 ' + this.selectedCount.toString() + ' / ' + this.totalCount.toString())
          .fontSize(FONT.caption)
          .fontColor(this.p().text3)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Text(this.allSelected ? '取消全选' : '全选')
          .fontSize(FONT.callout)
          .fontColor(this.p().primary)
          .height(44)
          .textAlign(TextAlign.Center)
          .padding({ left: 6, right: 6 })
          .accessibilityText(this.allSelected
            ? '取消全选，已选 ' + this.selectedCount.toString() + ' 项'
            : '全选，共 ' + this.totalCount.toString() + ' 项')
          .accessibilityLevel('yes')
          .onClick(() => {
            this.onToggleAll();
          })
      }
      .width('100%')

      Row({ space: 10 }) {
        if (this.secondaryLabel.length > 0) {
          Button(this.secondaryLabel)
            .fontSize(FONT.caption)
            .fontColor(this.p().primary)
            .backgroundColor(this.p().primarySoft)
            .borderRadius(RADIUS.pill)
            .height(44)
            .layoutWeight(1)
            .enabled(!this.blocked())
            .opacity(this.blocked() ? 0.45 : 1)
            .responseRegion({ x: 0, y: -2, width: '100%', height: 48 })
            .onClick(() => {
              this.onSecondary();
            })
        }
        Button(this.busy ? this.busyLabel : '删除所选')
          .fontSize(FONT.caption)
          .fontColor('#FFFFFFFF')
          .backgroundColor(this.blocked() ? this.p().text3 : this.p().danger)
          .borderRadius(RADIUS.pill)
          .height(44)
          .layoutWeight(1)
          .enabled(!this.blocked())
          .opacity(this.blocked() ? 0.45 : 1)
          .responseRegion({ x: 0, y: -2, width: '100%', height: 48 })
          .accessibilityText(this.busy
            ? this.busyLabel
            : '删除所选，' + this.selectedCount.toString() + ' 项')
          .onClick(() => {
            this.onConfirm();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 14, top: 10, bottom: 10 })
    .borderRadius(RADIUS.lg)
    .backgroundColor(glassCardBase(this.isDark))
    .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
    .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
    .shadow(glassShadow(this.isDark, this.lightLevel))
  }
}

/* 沉浸式二级页的悬浮头部：标题浮在内容上方，列表从标题后穿过（参考主流播放器）。
   背景从页面底色渐变到透明保证可读，点击穿透让下面的列表行仍可点。 */
@Component
export struct ImmersiveBar {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  /** v2.54：透传给 PageBar，让沉浸式二级页也能一步发起搜索 */
  @Prop showSearch: boolean = false;
  /** v2.72：右上角可选动作，透传给 PageBar；默认关闭，其它页面零影响 */
  @Prop showTrailing: boolean = false;
  @Prop trailingIcon: Resource = $r('sys.symbol.plus');
  @Prop trailingLabel: string = '';
  onBack: () => void = (): void => {
  };
  onSearch: () => void = (): void => {
  };
  onTrailing: () => void = (): void => {
  };
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('topSafe') topSafe: number = 24;

  private p(): Palette {
    return palette(this.isDark);
  }


  build() {
    Column() {
      PageBar({
        title: this.title,
        subtitle: this.subtitle,
        transparent: true,
        showSearch: this.showSearch,
        showTrailing: this.showTrailing,
        trailingIcon: this.trailingIcon,
        trailingLabel: this.trailingLabel,
        onBack: (): void => {
          this.onBack();
        },
        onSearch: (): void => {
          this.onSearch();
        },
        onTrailing: (): void => {
          this.onTrailing();
        }
      })
    }
    .width('100%')
    .padding({ top: this.topSafe - 6, bottom: 30 })
    .linearGradient({
      angle: 180,
      colors: [
        [this.p().bg, 0],
        [this.p().bg, 0.55],
        [withAlpha(this.p().bg, 0.0), 1]
      ]
    })
    .hitTestBehavior(HitTestMode.Transparent)
  }
}

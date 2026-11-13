import { palette, Palette, FONT } from '../common/Constants';
import { withAlpha } from '../common/Utils';
import { SongInfo } from '../common/Models';
import { App } from '../core/App';
import { Player } from '../core/Player';
import { IconTap, PlayingBars } from './Common';

/**
 * 播放队列面板。
 *
 * 全局唯一：迷你播放条的「列表」图标、播放页底排的队列按钮都落到这里，
 * 两处图标长得一样，行为也必须一样。
 *
 * 头部只留系统自带的关闭叉号：「清空」和它在右上角抢同一块地方，
 * 叠在一起像两个都点不动，而且清空队列这种不可撤销的动作用得也少。
 *
 * 打开时自动滚到「当前正在播的那一首」，序号写进标题——
 * 从歌单第 30 首点播后点开队列，要能立刻看到自己在哪，
 * 而不是从第 1 首开始手动往下滑。
 */
@Component
export struct QueueSheet {
  @StorageProp('isDark') isDark: boolean = false;
  @State playing: boolean = false;
  @State items: SongInfo[] = [];
  @State current: number = -1;
  onClose: () => void = (): void => {
  };
  private player: Player = App.get().player;
  private listener: () => void = (): void => {
  };
  private scroller: Scroller = new Scroller();
  /** 队列内容指纹，只有列表真的变了才换数组 */
  private fingerprint: string = '';
  private scrollTimer: number = -1;

  aboutToAppear(): void {
    this.listener = (): void => {
      this.playing = this.player.isPlaying();
      this.current = this.player.getIndex();
      const queue = this.player.getQueue();
      // 播放进度每秒都会触发一次通知，直接重建数组会让几百行的列表
      // 每秒全部重建一遍（滑动时明显发涩）。用指纹挡住纯进度变化。
      const parts: string[] = [];
      for (const item of queue) {
        parts.push(item.source + item.id);
      }
      const fp: string = queue.length.toString() + '#' + this.current.toString() + '#' + parts.join(',');
      if (fp !== this.fingerprint) {
        this.fingerprint = fp;
        this.items = queue.slice();
      }
    };
    this.player.onChange(this.listener);
    this.listener();
    // 面板刚升起时列表还没布局，延后一轮再滚
    this.scrollTimer = setTimeout(() => {
      this.scrollToCurrent(false);
    }, 180);
  }

  aboutToDisappear(): void {
    this.player.offChange(this.listener);
    if (this.scrollTimer !== -1) {
      clearTimeout(this.scrollTimer);
      this.scrollTimer = -1;
    }
  }

  private p(): Palette {
    return palette(this.isDark);
  }

  /** 滚到当前曲目上方留 2 行做上下文，别把它顶到屏幕最上沿 */
  private scrollToCurrent(smooth: boolean): void {
    if (this.current < 0 || this.items.length === 0) {
      return;
    }
    const target: number = Math.max(0, this.current - 2);
    try {
      this.scroller.scrollToIndex(target, smooth, ScrollAlign.START);
    } catch (err) {
      // 列表尚未挂载时忽略，打开动画结束后还会再滚一次
      console.warn('[QueueSheet] 滚动到当前曲目失败 ' + JSON.stringify(err));
    }
  }

  private subtitle(): string {
    if (this.items.length === 0) {
      return '0 首';
    }
    if (this.current >= 0 && this.current < this.items.length) {
      return '共 ' + this.items.length.toString() + ' 首 · 正在播放第 ' +
        (this.current + 1).toString() + ' 首';
    }
    return '共 ' + this.items.length.toString() + ' 首';
  }

  /**
   * 玻璃填充：浅色 50% 白，深色 48% 近黑。
   *
   * 之前写 72%：半透明白叠在深色封面上会显得几乎不透明，真机上就是一块白板，
   * 顶部高光（更白的渐变）压在白上根本看不出来。现在压到 50%：
   * 深色背景下能明显透出封面的色块和明暗走势，浅色背景下也能透出底下的
   * 搜索框、卡片轮廓，两个入口看起来都是同一块玻璃，而不是一块白板。
   * 这是通透和可读性的平衡点——再低，深灰正文在深封面上会掉到 4.5:1 以下。
   */
  private glassFill(): string {
    return this.isDark ? withAlpha('#101218', 0.48) : withAlpha('#FFFFFF', 0.50);
  }

  /** 投影偏冷、半径大：影子散得开才有"浮在页面上"的感觉，硬阴影会显脏 */
  private glassShadow(): string {
    return this.isDark ? withAlpha('#000000', 0.55) : withAlpha('#101322', 0.20);
  }


  build() {
    // 玻璃面板。
    //
    // 这里踩过三次坑，结论记在这：
    //   1. 不描边 —— 1px 亮线在浅色底上就是一条白框；
    //   2. 不铺顶部高光渐变 —— 第一行叠 60%+ 白，会在上沿拉出一条亮带，
    //      加上圆角裁切，看起来就是「边缘一圈」；
    //   3. 左右不留边距 —— 留 12vp 的话，外面那圈页面被遮罩压暗，
    //      白卡外侧就多出一个灰框，同样是一圈。
    // 所以现在只剩：半透明填充 + 背景磨砂 + 下方投影。边界靠明暗差，
    // 不靠任何一条画出来的线。
    Column() {
      Column({ space: 6 }) {
          Row() {
            Column({ space: 3 }) {
              Text('播放队列')
                .fontSize(FONT.headline + 2)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.p().text)
              Text(this.subtitle())
                .fontSize(FONT.micro)
                .fontColor(this.p().text2)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')
          .padding({ bottom: 6 })

          if (this.items.length === 0) {
            Column({ space: 6 }) {
              Text('队列是空的')
                .fontSize(FONT.caption)
                .fontColor(this.p().text2)
              Text('回到列表点一首歌就会填进来')
                .fontSize(FONT.micro)
                .fontColor(this.p().text2)
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else {
            List({ scroller: this.scroller }) {
              ForEach(this.items, (item: SongInfo, index: number) => {
                ListItem() {
                  Row({ space: 10 }) {
                    if (this.current === index) {
                      PlayingBars({ active: this.playing, barColor: this.p().primary })
                        .width(16)
                    } else {
                      Text((index + 1).toString())
                        .fontSize(FONT.micro)
                        .fontColor(this.p().text2)
                        .width(16)
                        .textAlign(TextAlign.Center)
                    }
                    Column({ space: 3 }) {
                      Text(item.name)
                        .fontSize(FONT.callout)
                        .fontColor(this.current === index ? this.p().primary : this.p().text)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.MARQUEE })
                        .marqueeOptions({ start: true, loop: -1, step: 2, fromStart: true })
                        .width('100%')
                      Text(item.singer)
                        .fontSize(FONT.micro)
                        .fontColor(this.p().text2)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.MARQUEE })
                        .marqueeOptions({ start: true, loop: -1, step: 2, fromStart: true })
                        .width('100%')
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)

                    IconTap({
                      icon: $r('sys.symbol.xmark'),
                      iconSize: 14,
                      color: this.p().text2,
                      paddingSize: 6,
                      onTap: () => {
                        this.player.removeAt(index);
                      }
                    })
                  }
                  .width('100%')
                  .height(52)
                  .onClick(() => {
                    // 点哪首就播哪首，播完顺手收起面板（原地听歌，不用再手动关）
                    this.player.jumpTo(index);
                    this.onClose();
                  })
                }
              }, (item: SongInfo, index: number) => item.source + item.id + '_' + index.toString())
            }
            .width('100%')
            .layoutWeight(1)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
            // 列表滚到顶/底时不把整块玻璃的圆角顶穿
            .clip(true)
          }
        }
      .width('100%')
      .height('100%')
      .padding({ left: 18, right: 18, top: 18, bottom: 16 })
      .width('100%')
      .layoutWeight(1)
      .backgroundColor(this.glassFill())
      .backdropBlur(34)
      // 四角同半径：之前只圆上面两角，底部是直角切边，和顶部对不上
      .borderRadius(28)
      .clip(true)
    }
    .width('100%')
    .height('100%')
    // 上、下各留 8vp 同宽的缝：卡片上下都是「圆角 + 露一条背景」，
    // 视觉上对称；左右仍为 0，避免两侧再出现一圈被夹住的背景。
    .padding({ top: 8, bottom: 8 })
    // 投影往下压，不往上扩：往上扩会在上沿再画出一圈灰边
    .shadow({ radius: 30, color: this.glassShadow(), offsetX: 0, offsetY: 10 })
  }
}

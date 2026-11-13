import { QueueSheet } from './QueueSheet';

/**
 * 播放队列的浮层外壳（首页迷你条 / 播放页底排 共用一份）。
 *
 * 为什么必须共用：以前两个入口各写各的 ——
 * 播放页是页面内自绘的玻璃浮层，首页却是「贴底 70% 高、只有顶角圆、不透明底色」的
 * 另一套。同一块队列，从播放页打开是半透明卡片，从首页打开就变成一块白板，
 * 用户一眼就能看出割裂。
 *
 * 现在两边都是：全屏点击热区 + 玻璃面板（86% 高、通栏、上两角圆 28）。
 * 卡片自己的颜色/磨砂/投影全在 QueueSheet 里，这里只负责摆位置。
 *
 * 注意这里不铺压暗色：卡片通栏之后，遮罩只会暴露在顶部那条 8vp 的缝里，
 * 那条缝被压暗就在卡片上沿画出一道横线，和「边缘一圈」是同一个毛病。
 */
@Component
export struct QueueOverlay {
  onClose: () => void = (): void => {
  };
  @StorageProp('bottomSafe') bottomSafe: number = 16;

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 只做点击热区，不再铺压暗色。
      //
      // 之前那层 14% 黑留在卡片外面：卡片左右缩进 12vp，这条缝被压暗后就成了
      // 白卡外的一圈灰框——用户连着两轮说的「边缘这一圈」其实是它，不是描边
      // （描边上一轮已经删了，像素采样确认过）。现在卡片通栏、遮罩清零，
      // 边缘不再有第二个亮度台阶，层次交给卡片自己的投影。
      Column()
        .width('100%')
        .height('100%')
        .onClick(() => {
          this.onClose();
        })

      QueueSheet({
        onClose: (): void => {
          this.onClose();
        }
      })
        .width('100%')
        .height('86%')
        .padding({ bottom: this.bottomSafe })
        .transition(
          TransitionEffect.OPACITY
            .combine(TransitionEffect.translate({ y: 90 }))
            .combine(TransitionEffect.scale({ x: 0.97, y: 0.97 }))
            .animation({ duration: 240, curve: Curve.FastOutSlowIn })
        )
    }
    .width('100%')
    .height('100%')
  }
}

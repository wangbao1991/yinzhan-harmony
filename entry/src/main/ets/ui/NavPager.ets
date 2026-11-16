/**
 * NavPager.ets —— 三个一级页的横向翻页容器（只翻页，不画底栏）。
 *
 * 原来是 HdsTabs，但它把悬浮页签和 MiniBar 的宽度分给自己算，实测会把播放条挤到
 * 屏幕外、页签栏裁成只剩一个圆。现在拆开：翻页交给 Swiper，底栏交给 BottomDock
 * （Index 根 Stack 里那层）。两者通过 Index.tab 双向同步。
 *
 * 用 Swiper 而不是 Tabs 的原因：
 *   - 不需要任何页签栏，Tabs 的 bar 即使高度设 0 也会参与布局计算；
 *   - Swiper 常驻三个页面（不懒加载），切回来不会重新拉数据、不丢滚动位置。
 */

/** 翻页动画时长，和 Index 里旧的 PAGE_ANIM_MS 保持一致。 */
const PAGE_ANIM_MS: number = 300;

@Component
export struct NavPager {
  /** 当前页（Index.tab）。外部改它 → Swiper 翻到对应页。 */
  @Prop selected: number = 0;
  /** 用户横滑或点了底栏页签后回调，Index 回写 this.tab 形成闭环。 */
  onChangeTab?: (index: number) => void;

  @BuilderParam content0: () => void = this.emptyContent;
  @BuilderParam content1: () => void = this.emptyContent;
  @BuilderParam content2: () => void = this.emptyContent;

  private swiper: SwiperController = new SwiperController();

  build() {
    Swiper(this.swiper) {
      Column() {
        this.content0()
      }
      .width('100%')
      .height('100%')

      Column() {
        this.content1()
      }
      .width('100%')
      .height('100%')

      Column() {
        this.content2()
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    // 受控：Index.tab 变化时翻到对应页，横滑结束再由 onChange 回写，不会互相顶。
    .index(this.selected)
    .loop(false)
    .indicator(false)
    .duration(PAGE_ANIM_MS)
    .curve(Curve.Friction)
    .onChange((index: number): void => {
      if (this.onChangeTab) {
        this.onChangeTab(index);
      }
    })
  }

  @Builder
  emptyContent() {
  }
}

/**
 * 底部标签栏跟手收起（对齐参考软件的丝滑版）。
 *
 * 不是「滑够阈值播一段动画」，而是连续渐变：
 * 手指每滚 1vp，标签栏就按比例变矮、变淡、下移，
 * 滚满 RANGE(90vp) 完全收起；往回滚按比例展开。
 * 松手（约 160ms 没有新滚动回调）后自动吸附到全开或全收，
 * 吸附用 180ms 补间，仍然由同一个 progress 驱动，不会跳变。
 *
 * 状态经 AppStorage('tabBarProgress')（0=展开，1=收起）广播给外壳；
 * 迷你播放条不参与，始终保留。
 */
export class TabBarHider {
  private static inst: TabBarHider = new TabBarHider();
  /** 滚满这么多元件位移(vp)就完全收起 */
  private static readonly RANGE: number = 90;
  /** 松手判定：这么久没有新滚动事件就认为停了 */
  private static readonly IDLE_MS: number = 160;
  private static readonly SETTLE_MS: number = 180;
  private acc: number = 0;
  private lastSent: number = -1;
  private idleTimer: number = -1;
  private settleTimer: number = -1;

  static get(): TabBarHider {
    return TabBarHider.inst;
  }

  /** 列表每帧滚动增量；正=手指上滑（收起），负=手指下滑（展开） */
  feed(delta: number): void {
    if (delta === 0) {
      return;
    }
    this.cancelSettle();
    this.acc = Math.max(0, Math.min(TabBarHider.RANGE, this.acc + delta));
    this.send(this.acc / TabBarHider.RANGE);
    // 滚动停止后吸附；惯性滚动期间 feed 持续触发，不会误判
    if (this.idleTimer !== -1) {
      clearTimeout(this.idleTimer);
    }
    this.idleTimer = setTimeout((): void => {
      this.idleTimer = -1;
      this.settle();
    }, TabBarHider.IDLE_MS);
  }

  /** 离开页面 / 切 Tab：直接恢复展开 */
  reset(): void {
    this.cancelSettle();
    if (this.idleTimer !== -1) {
      clearTimeout(this.idleTimer);
      this.idleTimer = -1;
    }
    this.acc = 0;
    this.send(0);
  }

  /** 松手吸附：过半收到底，否则展开 */
  private settle(): void {
    const from = this.acc / TabBarHider.RANGE;
    const target = from >= 0.5 ? 1 : 0;
    if (from === target) {
      return;
    }
    const start = Date.now();
    this.settleTimer = setInterval((): void => {
      const t = Math.min(1, (Date.now() - start) / TabBarHider.SETTLE_MS);
      const eased = 1 - Math.pow(1 - t, 3);
      const value = from + (target - from) * eased;
      this.acc = value * TabBarHider.RANGE;
      this.send(value);
      if (t >= 1) {
        this.cancelSettle();
      }
    }, 16);
  }

  private cancelSettle(): void {
    if (this.settleTimer !== -1) {
      clearInterval(this.settleTimer);
      this.settleTimer = -1;
    }
  }

  /** 精度压到千分之一，值没变就不广播，避免无意义刷新 */
  private send(value: number): void {
    const rounded = Math.round(value * 1000) / 1000;
    if (rounded === this.lastSent) {
      return;
    }
    this.lastSent = rounded;
    AppStorage.setOrCreate('tabBarProgress', rounded);
  }
}

/**
 * 底部标签栏跟手收起（对齐参考软件的丝滑版）。
 *
 * 不是「滑够阈值播一段动画」，而是连续渐变：
 * 手指每滚 1vp，标签栏就按比例变矮、变淡、下移，
 * 滚满 RANGE(180vp) 完全收起；往回滚按比例展开。
 * 松手（约 160ms 没有新滚动回调）后自动吸附到全开或全收，
 * 吸附用 180ms 补间，仍然由同一个 progress 驱动，不会跳变。
 *
 * 状态经 AppStorage('tabBarProgress')（0=展开，1=收起）广播给外壳；
 * 迷你播放条不参与，始终保留。
 */
export class TabBarHider {
  private static inst: TabBarHider = new TabBarHider();
  /**
   * 滚满这么多元件位移(vp)就完全收起。
   * 这个值就是「能看见多少过程」的唯一来源：一次快速上滑单帧位移约 15~30vp，
   * 行程 180 时一帧只推进 8%~17%，需要 6~12 帧才收满（约 100~200ms），
   * 全程跟手、手停即停，不需要任何补动画。
   */
  private static readonly RANGE: number = 180;
  /**
   * 显示进度的最大变化速率（每秒走完多少）。
   * 只做极端兜底：16ms 内允许走 0.224（约 40vp），正常滑动（单帧 15~30vp）
   * 完全碰不到这个上限，所以进度就是位移本身，不会滞后。
   * 只有一帧就甩出 40vp 以上的猛甩，才会被压一下，避免「一帧到底」。
   */
  private static readonly MAX_RATE: number = 14;
  /** 松手判定：这么久没有新滚动事件就认为停了（越小越跟手，越不会「松手后愣一下」） */
  private static readonly IDLE_MS: number = 60;
  /** 吸附时长：比原来长，收尾更缓，不「啪」一下到位 */
  private static readonly SETTLE_MS: number = 260;
  /** 吸附采样间隔：贴近屏幕刷新间隔，避免和 90/120Hz 不同步产生抖动 */
  private static readonly TICK_MS: number = 8;
  /** 判定「甩了一下」的速度阈值（vp/ms） */
  private static readonly FLING: number = 0.35;
  /** 目标进度累计值（由滚动位移直接算出，可以瞬间到底） */
  private acc: number = 0;
  /** 实际显示的进度：正常情况下就等于 acc/RANGE（纯跟手），仅极端猛甩时被压一档 */
  private shown: number = 0;
  /** 平滑后的滚动速度（vp/ms，正=收起方向），用于松手时判断甩向 */
  private vel: number = 0;
  private lastFeedAt: number = 0;
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
    // 速度平滑：单帧 delta 抖动很大，取加权平均再判方向
    const now: number = Date.now();
    const dt: number = Math.max(1, now - this.lastFeedAt);
    this.lastFeedAt = now;
    this.vel = this.vel * 0.7 + (delta / dt) * 0.3;
    this.acc = Math.max(0, Math.min(TabBarHider.RANGE, this.acc + delta));
    // 目标可以瞬间到位，显示值只能按速率追 —— 甩得再快也看得到收缩过程
    const goal: number = this.acc / TabBarHider.RANGE;
    const maxStep: number = TabBarHider.MAX_RATE * Math.min(64, dt) / 1000;
    const diff: number = goal - this.shown;
    const step: number = Math.max(-maxStep, Math.min(maxStep, diff));
    this.shown = Math.max(0, Math.min(1, this.shown + step));
    this.send(this.shown);
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
    this.shown = 0;
    this.vel = 0;
    this.send(0);
  }

  /**
   * 松手吸附。
   * 方向优先看甩动速度：快速上滑一定收起、快速下滑一定展开，
   * 只有慢慢拖到一半停住时才按 50% 位置判断 —— 这样不会出现
   * 「明明甩上去了又弹回来」的别扭感。
   * 曲线用 quartic ease-out：起始速度最大（松手瞬间就在动），收尾很长，
   * 观感是「顺着惯性滑进去」而不是「被推到位」。
   */
  private settle(): void {
    const from: number = this.shown;
    let target: number = from >= 0.5 ? 1 : 0;
    if (this.vel > TabBarHider.FLING) {
      target = 1;
    } else if (this.vel < -TabBarHider.FLING) {
      target = 0;
    }
    this.vel = 0;
    if (from === target) {
      return;
    }
    const start: number = Date.now();
    const dur: number = TabBarHider.SETTLE_MS;
    this.settleTimer = setInterval((): void => {
      const t: number = Math.min(1, (Date.now() - start) / dur);
      const eased: number = 1 - Math.pow(1 - t, 4);
      const value: number = from + (target - from) * eased;
      this.shown = value;
      this.acc = value * TabBarHider.RANGE;
      this.send(value);
      if (t >= 1) {
        this.cancelSettle();
      }
    }, TabBarHider.TICK_MS);
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

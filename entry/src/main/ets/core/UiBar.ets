/**
 * 底部标签栏跟手收起（对齐参考软件的丝滑版）。
 *
 * 不是「滑够阈值播一段动画」，而是连续渐变：
 * 手指每滚 1vp，标签栏就按比例变矮、变淡、下移，
 * 滚满 RANGE(180vp) 完全收起；往回滚按比例展开。
 * 松手（约 160ms 没有新滚动回调）后自动吸附到全开或全收：
 * 这里只决策终点，吸附动画由渲染端 springMotion 弹簧完成。
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
  /** 判定「甩了一下」的速度阈值（vp/ms） */
  private static readonly FLING: number = 0.35;
  /**
   * 广播粒度：进度只按 1/40 分段下发。
   * 渲染端（BottomDock）用 springMotion 弹簧接住分段，屏幕上仍是连续的，
   * 但 JS 线程重建底栏的次数从「每帧一次」降到「每 24ms 最多一次」。
   * 底栏几何最大行程约 52vp，1/40 步长对应 1.3vp，肉眼不可分辨。
   */
  private static readonly STEP: number = 40;
  /** 广播最小间隔(ms)：滚动中约 40Hz 下发，够跟手，又给 JS 线程留出空档 */
  private static readonly MIN_EMIT_MS: number = 24;
  /** 目标进度累计值（由滚动位移直接算出，可以瞬间到底） */
  private acc: number = 0;
  /** 实际显示的进度：正常情况下就等于 acc/RANGE（纯跟手），仅极端猛甩时被压一档 */
  private shown: number = 0;
  /** 平滑后的滚动速度（vp/ms，正=收起方向），用于松手时判断甩向 */
  private vel: number = 0;
  private lastFeedAt: number = 0;
  private lastSent: number = -1;
  private lastEmitAt: number = 0;
  private idleTimer: number = -1;

  static get(): TabBarHider {
    return TabBarHider.inst;
  }

  /** 列表每帧滚动增量；正=手指上滑（收起），负=手指下滑（展开） */
  feed(delta: number): void {
    if (delta === 0) {
      return;
    }
    // 速度平滑：单帧 delta 抖动很大，取加权平均再判方向
    const now: number = Date.now();
    // 首次滚动 / 长时间停滚后的第一帧，lastFeedAt 可能是 0 或很久以前，
    // 直接相减会得到 1e12 量级的 dt，maxStep 被放大到 0.896 —— 一帧就把底栏收满，
    // 表现是「一滚就到底、没有过程」。这里按一帧 16ms 兜底。
    const rawDt: number = now - this.lastFeedAt;
    const dt: number = rawDt > 0 && rawDt <= 100 ? rawDt : 16;
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
    // 滚动停止后吸附；惯性滚动期间 feed 持续触发，不会误判。
    // 原先每帧都要 clearTimeout + setTimeout 重挂一次，60~120Hz 下就是每秒上百次
    // 定时器增删；改成「只挂一次，回调里看时间戳决定续挂还是吸附」，
    // 行为完全等价，主线程上的定时器开销降一个量级。
    if (this.idleTimer === -1) {
      this.armIdle();
    }
  }

  /** 挂一次空闲检测；到点若还在滚（最近 IDLE_MS 内有 feed）就续挂 */
  private armIdle(): void {
    this.idleTimer = setTimeout((): void => {
      if (Date.now() - this.lastFeedAt < TabBarHider.IDLE_MS) {
        this.armIdle();
        return;
      }
      this.idleTimer = -1;
      this.settle();
    }, TabBarHider.IDLE_MS);
  }

  /** 离开页面 / 切 Tab：直接恢复展开 */
  reset(): void {
    if (this.idleTimer !== -1) {
      clearTimeout(this.idleTimer);
      this.idleTimer = -1;
    }
    this.acc = 0;
    this.shown = 0;
    this.vel = 0;
    // 复位后时间基准作废：下次 feed 会按「一帧」兜底，不会因 dt 巨大而一帧收满
    this.lastFeedAt = 0;
    this.send(0, true);
  }

  /**
   * 松手吸附：只做决策，不做动画。
   *
   * 方向优先看甩动速度：快速上滑一定收起、快速下滑一定展开，
   * 只有慢慢拖到一半停住时才按 50% 位置判断 —— 这样不会出现
   * 「明明甩上去了又弹回来」的别扭感。
   *
   * 以前这里用 16ms 定时器手搓 quartic 缓动：JS 60Hz 采样 → 1/40 分段 →
   * 24ms 节流 → 渲染端再来一层 45ms 线性补间，四层平滑叠出来是「阶梯滑入」，
   * 不是弹簧。现在终点一次性强发，弹簧动画由渲染端 springMotion 接手 ——
   * 原生帧率插值、可中断重定目标，这才是录屏里那种「顺滑粘滞」的质感；
   * JS 侧还省掉了每秒几十次的定时器与广播。
   */
  private settle(): void {
    let target: number = this.shown >= 0.5 ? 1 : 0;
    if (this.vel > TabBarHider.FLING) {
      target = 1;
    } else if (this.vel < -TabBarHider.FLING) {
      target = 0;
    }
    this.vel = 0;
    this.shown = target;
    this.acc = target * TabBarHider.RANGE;
    this.send(target, true);
  }

  /**
   * 广播进度：先按 1/STEP 分段，再按 MIN_EMIT_MS 节流。
   *
   * 为什么不在滚动里逐帧广播：底栏是常驻组件，一次广播就要跑一遍它的 build +
   * 重新布局。120Hz 的设备上一秒就是 120 次，而底栏这一秒的视觉变化其实只有
   * 「从展开到收起」一小段。把下发压到 40Hz，中间由渲染端补间，屏幕上看不出
   * 差别，JS 线程却省下三分之二的活 —— 卡顿主要就卡在这里。
   *
   * force=true 用在两个必须立刻生效的时刻：复位（0）和吸附结束（0 或 1）。
   */
  private send(value: number, force: boolean = false): void {
    const stepped: number = Math.round(value * TabBarHider.STEP) / TabBarHider.STEP;
    if (stepped === this.lastSent) {
      return;
    }
    const now: number = Date.now();
    if (!force && now - this.lastEmitAt < TabBarHider.MIN_EMIT_MS) {
      return;
    }
    this.lastSent = stepped;
    this.lastEmitAt = now;
    AppStorage.setOrCreate('tabBarProgress', stepped);
  }
}

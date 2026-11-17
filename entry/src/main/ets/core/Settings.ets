import {
  PrefKeys, ThemeMode, normalizeQuality,
  DOWNLOAD_CONCURRENCY_MIN, DOWNLOAD_CONCURRENCY_MAX, DOWNLOAD_CONCURRENCY_DEFAULT
} from '../common/Constants';
import { Store } from './Store';

/**
 * 全局设置。所有开关集中在这里，页面只读写这个类，避免散落的 key。
 */
export class Settings {
  private static instance: Settings = new Settings();
  static get(): Settings {
    return Settings.instance;
  }

  themeMode(): number {
    return Store.get().getNumber(PrefKeys.THEME_MODE, ThemeMode.SYSTEM);
  }

  setThemeMode(mode: number): void {
    Store.get().put(PrefKeys.THEME_MODE, mode);
  }

  autoPlay(): boolean {
    return Store.get().getBool(PrefKeys.AUTO_PLAY, false);
  }

  setAutoPlay(value: boolean): void {
    Store.get().put(PrefKeys.AUTO_PLAY, value);
  }

  rememberPosition(): boolean {
    return Store.get().getBool(PrefKeys.REMEMBER_POS, true);
  }

  setRememberPosition(value: boolean): void {
    Store.get().put(PrefKeys.REMEMBER_POS, value);
  }

  ignoreInterrupt(): boolean {
    return Store.get().getBool(PrefKeys.IGNORE_INTERRUPT, false);
  }

  setIgnoreInterrupt(value: boolean): void {
    Store.get().put(PrefKeys.IGNORE_INTERRUPT, value);
  }

  /** 玻璃质感强度：0 关 / 1 柔和 / 2 标准 / 3 强 */
  lightSense(): number {
    return Store.get().getNumber(PrefKeys.LIGHT_SENSE, 3);
  }

  setLightSense(level: number): void {
    Store.get().put(PrefKeys.LIGHT_SENSE, level);
  }

  /**
   * 流畅优先：关掉底栏实时背景模糊（backgroundEffect），只留半透明底色。
   * 默认关（保留玻璃观感）；低端机 / 掉帧场景打开后，滚动时不再每帧重算模糊。
   */
  perfMode(): boolean {
    return Store.get().getBool(PrefKeys.PERF_MODE, false);
  }

  setPerfMode(value: boolean): void {
    Store.get().put(PrefKeys.PERF_MODE, value);
    // 底栏是常驻一级页组件、不会重建：只落盘不广播的话要杀掉进程才生效。
    AppStorage.setOrCreate('perfMode', value);
  }

  quality(): string {
    return Store.get().getString(PrefKeys.QUALITY, '320k');
  }

  setQuality(value: string): void {
    Store.get().put(PrefKeys.QUALITY, value);
  }

  /** 音源拿不到目标音质时是否自动降级（默认关闭：宁可报错也不悄悄给低音质） */
  allowDowngrade(): boolean {
    return Store.get().getBool(PrefKeys.DOWNLOAD_DOWNGRADE, false);
  }

  setAllowDowngrade(value: boolean): void {
    Store.get().put(PrefKeys.DOWNLOAD_DOWNGRADE, value);
  }

  /**
   * 并行下载：同时最多跑几首（默认 3，范围 1~5）。
   * 读的时候也 clamp 一遍：旧版本 / 备份恢复可能写进来越界值或非整数，
   * 直接交给 Downloader 会让 pump() 的 while 判断出诡异行为。
   */
  downloadConcurrency(): number {
    const raw = Store.get().getNumber(PrefKeys.DOWNLOAD_CONCURRENCY, DOWNLOAD_CONCURRENCY_DEFAULT);
    const n = Math.round(raw);
    // 用 !(n >= MIN) 而不是 n < MIN：NaN / 脏值也会落到这里，回到最小档。
    if (!(n >= DOWNLOAD_CONCURRENCY_MIN)) {
      return DOWNLOAD_CONCURRENCY_MIN;
    }
    if (n > DOWNLOAD_CONCURRENCY_MAX) {
      return DOWNLOAD_CONCURRENCY_MAX;
    }
    return n;
  }

  setDownloadConcurrency(value: number): void {
    let n = Math.round(value);
    if (!(n >= DOWNLOAD_CONCURRENCY_MIN)) {
      n = DOWNLOAD_CONCURRENCY_MIN;
    }
    if (n > DOWNLOAD_CONCURRENCY_MAX) {
      n = DOWNLOAD_CONCURRENCY_MAX;
    }
    Store.get().put(PrefKeys.DOWNLOAD_CONCURRENCY, n);
  }

  /** 听够整首 2/3 时自动把当前歌曲加入下载队列（默认关，下载页开关控制） */
  autoDownloadOnPlay(): boolean {
    return Store.get().getBool(PrefKeys.AUTO_DOWNLOAD_ON_PLAY, false);
  }

  setAutoDownloadOnPlay(value: boolean): void {
    Store.get().put(PrefKeys.AUTO_DOWNLOAD_ON_PLAY, value);
  }

  /**
   * 下载前是否对音源链接做二次探测（默认关闭，对齐洛雪官方）。
   * 关闭时：音源给什么链接就下什么，下载完成后读文件头判断真实格式；
   * 开启时：沿用旧的 Range 探测 + 格式判定，能挡住虚标，但容易被中转接口的
   * 403 / 404 / 防盗链页误伤 —— 那正是「同样的音源安卓能下、我们报错」的主因之一。
   */
  /**
   * 启动时自动自检（默认关）。
   *
   * 为什么要开关而不是默认开：自检会真实向每个源取一次链，十几个源一起跑
   * 是一小波请求；后端刚被 403 时反复自检只会加深风控。交给用户按需打开。
   */
  autoCheckSources(): boolean {
    return Store.get().getBool(PrefKeys.AUTO_CHECK_SOURCES, false);
  }

  setAutoCheckSources(value: boolean): void {
    Store.get().put(PrefKeys.AUTO_CHECK_SOURCES, value);
  }

  /**
   * 是否记住「歌 → 音源」亲和关系。
   * 开启后同一首歌再播会先问上次给过它的音源，省掉一轮全源竞速；
   * 关掉只是不再学习，已有的记录保留，下次开启还能用。
   */
  rememberSource(): boolean {
    return Store.get().getBool(PrefKeys.REMEMBER_SOURCE, true);
  }

  setRememberSource(value: boolean): void {
    Store.get().put(PrefKeys.REMEMBER_SOURCE, value);
  }

  verifyBeforeDownload(): boolean {
    return Store.get().getBool(PrefKeys.VERIFY_BEFORE_DOWNLOAD, false);
  }

  setVerifyBeforeDownload(value: boolean): void {
    Store.get().put(PrefKeys.VERIFY_BEFORE_DOWNLOAD, value);
  }

  /**
   * 首选音源连续失败（403 / 404 / 超时等）时，临时放开其它音源补位（默认开）。
   * 用户仍可保留「只用首选音源」的取链偏好，但不至于因为一个后端被封就整首报错。
   */
  autoFallbackOnFailure(): boolean {
    return Store.get().getBool(PrefKeys.AUTO_FALLBACK_ON_FAILURE, true);
  }

  setAutoFallbackOnFailure(value: boolean): void {
    Store.get().put(PrefKeys.AUTO_FALLBACK_ON_FAILURE, value);
  }

  /**
   * 取链方式（默认「跟随补位」，与旧版一致）：
   *   false → 首选音源优先，拿不到再由其它已启用音源并发补位
   *   true  → 只认首选音源，它拿不到就直接报错，绝不中途换成别的音源
   * 用户看到的「音源来回变动」，就是补位这一步悄悄换了人。
   */
  preferOnly(): boolean {
    return Store.get().getString(PrefKeys.SOURCE_MODE, '') === 'strict';
  }

  setPreferOnly(value: boolean): void {
    Store.get().put(PrefKeys.SOURCE_MODE, value ? 'strict' : '');
  }

  /**
   * 智能达标寻源（懒人模式，默认开）。
   *
   * 开启后：播放 / 下载都锁定你选的目标音质，绝不降质；某个音源给不到这个音质
   * 就自动换下一个音源、下一个平台、下一个 MusicFree 插件，全问过仍不达标就明确
   * 停止（不会偷偷给 320k）。会接管「只用首选音源」与「音质不足自动降级」。
   * 关掉则完全回到旧的分阶段取链（首选 → 补位 → 插件替补 → 跨平台换源 → 直连）。
   */
  smartHunt(): boolean {
    return Store.get().getBool(PrefKeys.SMART_HUNT, true);
  }

  setSmartHunt(value: boolean): void {
    Store.get().put(PrefKeys.SMART_HUNT, value);
  }

  /** 剩余 N 秒预取下一首直链：弱网 / 懒人模式全源寻源时能明显减少切歌等待 */
  preloadNext(): boolean {
    return Store.get().getBool(PrefKeys.PRELOAD_NEXT, true);
  }

  setPreloadNext(value: boolean): void {
    Store.get().put(PrefKeys.PRELOAD_NEXT, value);
  }

  showTrans(): boolean {
    return Store.get().getBool(PrefKeys.SHOW_TRANS, true);
  }

  setShowTrans(value: boolean): void {
    Store.get().put(PrefKeys.SHOW_TRANS, value);
  }

  /** 0 小 / 1 标准 / 2 大 / 3 特大 */
  lyricSize(): number {
    return Store.get().getNumber(PrefKeys.LYRIC_SIZE, 1);
  }

  setLyricSize(value: number): void {
    Store.get().put(PrefKeys.LYRIC_SIZE, value);
  }


  discoverPlatform(): string {
    return Store.get().getString(PrefKeys.DISCOVER_PLATFORM, 'wy');
  }

  setDiscoverPlatform(value: string): void {
    Store.get().put(PrefKeys.DISCOVER_PLATFORM, value);
    // 设置页改完，发现页（现在是一级常驻页，不会重建）要能立刻跟着换平台。
    // 只落盘不广播的话，得杀掉进程重进才生效——和之前「收藏不飘红」同一类问题。
    AppStorage.setOrCreate('discoverPlatform', value);
  }

  /** 音质偏好：用户选了 flac 但音源没有时，Resolver 会自动降级 */
  qualityLabel(q: string): string {
    const n = normalizeQuality(q);
    if (n === 'master') {
      return '母带 · 需音源支持';
    }
    if (n === 'atmos_plus' || n === 'atmos') {
      return '全景声 · 需音源支持';
    }
    if (n === 'hires') {
      return 'Hi-Res · 需音源支持';
    }
    if (n === 'flac24bit') {
      return 'Hi-Res';
    }
    if (n === 'flac') {
      return '无损';
    }
    if (n === '320k') {
      return '高品质';
    }
    if (n === '192k') {
      return '标准';
    }
    return '流畅';
  }
}

import { common } from '@kit.AbilityKit';
import { request } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { SongInfo, DownloadTask, LyricDoc, LocalSong, newSong } from '../common/Models';
import {
  PrefKeys, qualityLabel, isLossless, DOWNLOAD_CONCURRENCY_DEFAULT
} from '../common/Constants';
import { safeFileName, uuid } from '../common/Utils';
import { Store } from './Store';
import { Resolver } from './Resolver';
import { Settings } from './Settings';
import { DownloadPath } from './DownloadPath';
import { AudioTag } from './AudioTag';
import { LyricRepo } from './LyricRepo';
import { LocalRepo } from './LocalRepo';
import { looksLikeMarkup, looksLikeNonLyric } from './Lrc';

/**
 * 完成 / 失败等后台离散事件的「广播合并窗口」（毫秒）。
 * 固定窗口（首个事件起表、到点统一广播，期间新事件只置 pending 不重置计时），
 * 避免连续完成把刷新无限推迟。150ms 内人眼无感，但把 N 次全表重建压成 1 次。
 * 落盘不走这个窗口：persist() 仍当场执行，已完成记录绝不因合并而延迟/丢失。
 */
const DOWNLOAD_COMMIT_WINDOW_MS: number = 150;

/**
 * 下载队列持久化上限。
 *
 * 完成项自 2026-11-16 起长期留在队列里，队列不再像以前那样「完成即出队」保持很小。
 * 整队列是一条 Preferences 字符串，每次完成都要 JSON.stringify + flushSync，
 * 条数越多这次同步写越慢（完成瞬间的卡顿来源之一），也可能撞系统的单值长度限制，
 * 所以保留 300 条的硬上限（与改造前一致，不引入新的写盘开销）。
 *
 * 超限时保留最近 300 条，把更早的**已完成 / 已失败**记录连同文件一起清掉 ——
 * 记录、界面、磁盘三者必须一致，否则会出现「文件还在、列表里没有、用户删不掉」
 * 的孤儿，正好违背「别占地方」的初衷。下载页在接近上限时会显式提示。
 */
const DOWNLOAD_PERSIST_MAX: number = 300;

/**
 * 下载中心
 *
 * - 任务队列并行下载：并发上限由设置项「同时下载几首」决定（默认 3，1~5），
 *   改设置时立即对排队任务补位，不用等当前这首跑完；取链按歌去重，互不阻塞。
 * - 固定写入公共 Download/<包名>/ 下的应用专属文件夹，不需要用户选目录
 * - 公共目录不可用时回退应用内 music/，保证一定能落盘，并如实显示实际路径
 * - 任务/进度/失败原因持久化，退出应用后记录还在
 */
export class Downloader {
  private static instance: Downloader = new Downloader();
  static get(): Downloader {
    return Downloader.instance;
  }

  private tasks: DownloadTask[] = [];
  /**
   * id → 任务 的 O(1) 索引。下载页每一行 build() 里要按 id 取十几次实时任务，
   * 旧版线性遍历整个队列，234 首时每行一次重绘就是 O(n²)。
   * 只在「任务集合结构变化」（入队 / 删除 / 清理 / init）时重建；
   * 进度、状态这类字段改动直接落在同一个 DownloadTask 对象上，索引天然实时，无需重建。
   */
  private taskIndex: Map<string, DownloadTask> = new Map<string, DownloadTask>();
  private indexDirty: boolean = true;
  private queue: string[] = [];
  private running: number = 0;
  /** 并行上限：不再写死 2，init() 从设置读回，setConcurrency() 可即时改 */
  private maxRunning: number = DOWNLOAD_CONCURRENCY_DEFAULT;
  private listeners: Array<() => void> = [];
  private context: common.UIAbilityContext | null = null;
  /**
   * 进度广播的全局节流时间戳。旧版把 lastNotify 放在每个任务的 run() 闭包里，
   * 3 首并发就各自每 300ms 广播一次 → 实际约 10 次/秒全局重绘。
   * 提到实例级，所有并发共享一个 300ms 窗口，整份队列最多约 3.3 次/秒。
   */
  private lastProgressNotify: number = 0;
  /**
   * 「下载完成」收尾的广播合并窗口。
   * 并发档位下几首歌常在相近时间完成，旧版每首完成都调一次 notify()：
   *   downloadVersion 广播 → 页面级 refresh() 全量 diff（list().slice +
   *   3 个 O(n) 统计 + ForEach 234 项全量比对）+ 所有常驻页连锁。
   * 3 首同时完成就是 3 次全表重建，全压在 UI 线程 —— 这正是「同时完成几个
   * 卡顿更明显」的叠加源。状态本身（task.status）仍立即改、persist() 仍当场
   * 落盘，内存与磁盘都是实时的；这里只把「广播」合并到 150ms 窗口里做一次。
   */
  private commitTimer: number = -1;
  private commitPending: boolean = false;
  /** 超限自动清理的待提示条数（下载页取走后清零，见 consumeTrimNotice） */
  private trimNotified: number = 0;
  /**
   * 完成收尾的串行链。
   * request.downloadFile 的 complete 回调之后，一首歌要做整文件搬移 +
   * AudioTag 整读整写（无损几十 MB）+ persist。第四次返工把这些大 IO 全改成
   * 异步 Promise，本链只负责排顺序、每首之间让出主线程一帧，UI 随时能插帧渲染；
   * 即便某一首的 IO 还没回来，也不会占住 UI 线程。
   */
  private finalizeChain: Promise<void> = Promise.resolve();
  /**
   * 已点「取消」的任务 id。
   * 系统下载任务在 progress/complete 回调里才看得到，光改 status 会被回调覆盖回 done，
   * 而且文件会照样落盘 —— 所以取消要留痕，回调里再核一次。
   */
  private cancelled: string[] = [];
  /**
   * 正在跑的系统下载任务（request.DownloadTask）。
   * 单击暂停/开始走原生 suspend()/restore()，进度不丢、不用重新取链，
   * 也不会和 run() 里那个等 complete 的 Promise 打架。
   */
  private activeDownloads: Map<string, request.DownloadTask> = new Map<string, request.DownloadTask>();
  /**
   * 主动结束 run() 里那个等 complete/fail 的 Promise。
   *「暂停中的任务被清除」时系统任务被删、不会再有 progress 回调，不 abort 的话
   * run() 永远不结束、finally 不跑，running 槽位会一直被占着（之后点下载没反应）。
   */
  private abortRun: Map<string, (e: Error) => void> = new Map<string, (e: Error) => void>();

  init(context: common.UIAbilityContext): void {
    this.context = context;
    // 并行上限从设置读回（旧版写死 2，用户升级后仍按自己设的档位跑）
    this.maxRunning = Settings.get().downloadConcurrency();
    // 固定下载目录：启动时只做本地探测，需要系统授权时留到首次下载
    // （那时界面一定在前台，比冷启动阶段拉起 picker 更可靠）
    DownloadPath.get().init(context);
    const text = Store.get().getString(PrefKeys.DOWNLOADS, '[]');
    try {
      this.tasks = JSON.parse(text) as DownloadTask[];
    } catch (e) {
      this.tasks = [];
    }
    this.indexDirty = true; // 冷启动反序列化成全新对象，标记重建 id 索引
    /**
     * 2026-11-16 用户口径（第三次纠正）：
     * ①「完成的歌不要放到本地音乐里，太占地方」→ 下载不再往 LocalRepo 登记；
     * ②「歌曲还在下载管理页」→ done 记录保留在队列里，作为「已下载」的唯一索引。
     * 文件只归固定下载目录，播放由本类 pathOf() 直接给路径。
     * 老版本自动登记进本地音乐的历史条目由 LocalRepo.detachExternal() 在启动时摘掉。
     */
    const kept: DownloadTask[] = [];
    let interrupted = 0;
    let missing = 0;
    let repaired = 0;
    for (const task of this.tasks) {
      if (task.status === 'done') {
        /**
         * 2026-11-16 审查修复：完成项长期留队后，记录可能指向一个已经不存在的文件
         * （用户在文件管理器里删了、旧版本从本地音乐删歌时连带删了、换机恢复等）。
         * 这种「已完成」点一下只会静默失败，还会让占用空间统计虚高 —— 启动时 stat 一次：
         * 文件不在就作废记录；在就把真实字节写回（老版本的记录 received 可能是 0）。
         */
        if (task.path.length === 0) {
          missing++;
          continue;
        }
        let size = -1;
        try {
          size = fs.statSync(task.path).size;
        } catch (e) {
          missing++;
          continue;
        }
        if (task.received !== size || task.total !== size) {
          task.received = size;
          task.total = size;
          repaired++;
        }
        kept.push(task);
        continue;
      }
      // 上次退出时还在下载的标记为失败，避免永远转圈；paused 保留供用户手动开始
      if (task.status === 'running' || task.status === 'waiting') {
        task.status = 'failed';
        task.error = '上次下载被中断';
        interrupted++;
      }
      kept.push(task);
    }
    this.tasks = kept;
    // 冷启动改过状态 / 丢过记录 / 修正过大小，都要落盘一次，否则下次启动还是老样子
    if (interrupted > 0 || missing > 0 || repaired > 0) {
      this.persist();
    }
    // 上次进程被杀时留在缓存的临时文件没人收尾，启动顺手清掉（下载目录里的成品不动）
    this.purgeTemp(context);
  }

  /**
   * 清理上次异常退出遗留的下载临时文件。
   *
   * 临时文件固定是 `cacheDir/dl_<taskId><ext>`（见 run() 里 tempPath 的拼法），
   * 正常完成 / 失败 / 取消都会在 run() 收尾里删掉；只有「进程被系统回收或用户划掉」
   * 会留下，缓存越攒越多。这里只删这个前缀，不碰缓存目录里的其它文件。
   */
  private purgeTemp(context: common.UIAbilityContext): void {
    let names: string[] = [];
    try {
      names = fs.listFileSync(context.cacheDir);
    } catch (e) {
      return;
    }
    for (const name of names) {
      if (name.indexOf('dl_') !== 0) {
        continue;
      }
      try {
        fs.unlinkSync(context.cacheDir + '/' + name);
      } catch (e) {
        // 单个文件删不掉不影响启动
      }
    }
  }

  onChange(listener: () => void): void {
    this.listeners.push(listener);
  }

  offChange(listener: () => void): void {
    this.listeners = this.listeners.filter((item: () => void): boolean => item !== listener);
  }

  /**
   * 低频广播：任务「状态 / 集合」变化（入队、开始、完成、失败、取消、删除、清理、并发档位）。
   * 触发页面级 refresh()（重建列表、刷新统计）与所有订阅 downloadVersion 的常驻页。
   * 这些是离散事件，一首歌生命周期里最多几次，不是高频源。
   */
  private notify(): void {
    for (const listener of this.listeners) {
      listener();
    }
    AppStorage.setOrCreate('downloadVersion', Date.now());
  }

  /**
   * 高频广播：仅「下载进度数值」变化，走独立信号 downloadProgress。
   *
   * 旧版把进度也塞进 notify() 的 downloadVersion，于是 progress 回调每 300ms
   * 就把下载页 refresh()（重建 this.tasks、触发 ForEach 全量 diff、4 个 O(n) 统计）、
   * 234 个行组件、以及首页 / 歌单页 / 播放页 / 所有歌曲行全部唤醒重绘一遍；
   * 3 首并发还各带一份局部节流，实际约 10 次/秒。这是「队列一大就掉帧」的主因。
   *
   * 现在：① 用实例级 lastProgressNotify 做全局 300ms 节流，并发不再放大；
   * ② 只广播 downloadProgress，downloadVersion 不变，页面级 refresh / ForEach diff
   *   不再被进度触发；③ 只有「正在下载」的行订阅 downloadProgress（见 DownloadTaskRow），
   *   排队中 / 已完成的行完全不挂这条高频依赖，一次广播只唤醒当前并发的那几行。
   */
  private notifyProgress(): void {
    const now = Date.now();
    if (now - this.lastProgressNotify < 300) {
      return;
    }
    this.lastProgressNotify = now;
    AppStorage.setOrCreate('downloadProgress', now);
  }

  /**
   * 后台完成 / 失败的「广播合并」入口。
   *
   * 旧版每首歌完成都立刻 notify()：downloadVersion 广播会叫醒页面级 refresh()
   * （list().slice + 3 个 O(n) 统计 + ForEach 全量 diff）以及所有常驻页。并发档位
   * 下几首常在相近时间落地，同一瞬间就做 3 次全表重建。现在只标脏，窗口末广播
   * 一次：状态字段与 persist() 都仍在完成那一刻当场执行（磁盘实时、零丢失），
   * 行组件按 id 取到的就是最新对象，用户不会看到「完成延迟」。
   */
  private scheduleCommit(): void {
    this.commitPending = true;
    if (this.commitTimer >= 0) {
      return; // 固定窗口：不因后续完成重置计时，避免连续完成把刷新无限推迟
    }
    this.commitTimer = setTimeout((): void => {
      this.commitTimer = -1;
      this.flushCommit();
    }, DOWNLOAD_COMMIT_WINDOW_MS);
  }

  private flushCommit(): void {
    if (!this.commitPending) {
      return;
    }
    this.commitPending = false;
    this.cancelCommitTimer();
    /**
     * 第五次性能返工：完成帧只做「一次」全局扇出。
     *
     * 旧版这里先 notifyNow() 发 localVersion、再 notify() 发 downloadVersion，
     * 两次 AppStorage.setOrCreate 各唤醒一遍所有常驻页 + 所有歌曲行（Common.ets
     * 每一行都靠 dlVersion 挂进依赖图）。这是「在其他界面也能感觉到顿挫」的来源之一。
     *
     * localVersion 的订阅方（首页 / 歌单详情）都同时订阅 downloadVersion，
     * 所以 downloadVersion 一次就够，localVersion 是冗余的第二次全扇出。
     * 2026-11-16 起下载不再写本地音乐，完成帧连 localVersion 都不需要补发，
     * 这里只发 downloadVersion 一次。
     */
    this.notify();
  }

  private cancelCommitTimer(): void {
    if (this.commitTimer >= 0) {
      clearTimeout(this.commitTimer);
      this.commitTimer = -1;
    }
  }

  /**
   * 应用切后台前调用：把合并窗口里挂起的状态刷新立刻补发一次。
   * 落盘本来就是当场做的、不依赖这里，这层只保证回到前台时列表一定是最新的。
   * 2026-11-16：下载不再写本地音乐，本地音乐没有「下载引起的变化」要补发，
   * 这里只保留下载队列自己的 flush（EntryAbility.onBackground 仍调本方法）。
   */
  flushPending(): void {
    this.flushCommit();
  }

  /** 让出主线程一帧：把连续几首的完成收尾摊到不同事件循环轮次，UI 能插帧 */
  private nextFrame(): Promise<void> {
    return new Promise<void>((resolve): void => {
      setTimeout((): void => {
        resolve();
      }, 0);
    });
  }

  /**
   * 完成收尾串行化：等前一首放行 + 让出一帧后再执行本首的重活。
   * 返回 Promise 供 run() await，异常仍由 run() 的 try/catch 兜住，
   * 取消痕迹清理与系统任务释放在 run() 的 finally 里照旧，行为等价。
   */
  private inFinalizeOrder(job: () => Promise<void>): Promise<void> {
    const previous: Promise<void> = this.finalizeChain;
    // job 现在是异步的：每一步大 IO 都 await 让出事件循环，UI 线程全程可渲染。
    const ordered: Promise<void> = previous
      .then((): Promise<void> => this.nextFrame())
      .then((): Promise<void> => job());
    // 单个任务失败不能断掉整条链，否则后续完成的歌会永远卡在排队里
    this.finalizeChain = ordered.catch((): void => {
    });
    return ordered;
  }

  /** 界面展示的固定下载目录（不再由用户选择） */
  getDirName(): string {
    return DownloadPath.get().displayPath();
  }

  /** 当前并行档位（下载管理页用来点亮选中的 Chip） */
  concurrency(): number {
    return this.maxRunning;
  }

  /** 队列条数上限（下载管理页在接近上限时提示「更早的会被自动清理」） */
  static capacity(): number {
    return DOWNLOAD_PERSIST_MAX;
  }

  /**
   * 设置「同时下载几首」，并让排队中的任务立刻补位启动。
   *
   * 关键在最后的 pump()：旧版 pump 只在入队 / 任务完成时触发，若只改上限不
   * 主动 pump，用户把 1 改到 5 之后还得干等当前这首跑完才见效，看起来像没生效。
   * 调小档位时无需中断正在跑的任务，pump() 自然不会再拉起新的，等 running 降下来即可。
   */
  setConcurrency(value: number): void {
    Settings.get().setDownloadConcurrency(value);
    this.maxRunning = Settings.get().downloadConcurrency();
    this.notify();
    this.pump();
  }

  /**
   * 某首歌当前的下载状态：none / waiting / running / done。
   *
   * 播放页底部按钮靠它决定写「下载」「排队中」「下载中」还是「已下载」——
   * 不区分的话，已经下好的歌也挂着「下载」二字，点下去只换来一句「已经在本地了」。
   */
  stateOf(song: SongInfo): string {
    // 2026-11-16：下载完成的歌不再登记进本地音乐，「已下载」只由队列里的 done 记录判定。
    // 手动导入的本地歌（source=local）仍查 LocalRepo，避免它被当成未下载。
    if (song.source === 'local' && LocalRepo.get().pathOf(song.id).length > 0) {
      return 'done';
    }
    if (this.find(song.id) !== null) {
      return 'done';
    }
    for (const task of this.tasks) {
      if (task.song.id !== song.id || task.song.source !== song.source) {
        continue;
      }
      if (task.status === 'running') {
        return 'running';
      }
      // paused 沿用 waiting 文案：播放页只认 done/running/waiting/none 四态
      if (task.status === 'waiting' || task.status === 'paused') {
        return 'waiting';
      }
    }
    return 'none';
  }

  /** 手动重新检测公共目录（设置页 / 下载管理页用），返回给用户的提示文本 */
  async refreshDir(): Promise<string> {
    await DownloadPath.get().retry();
    const path = DownloadPath.get();
    const tip = path.isFallback()
      ? '公共 Download 不可用，已改用应用内 music/'
      : '下载目录已就绪：' + path.displayPath();
    this.notify();
    return tip;
  }

  list(): DownloadTask[] {
    return this.tasks;
  }

  activeCount(): number {
    let count = 0;
    for (const task of this.tasks) {
      if (task.status === 'running' || task.status === 'waiting') {
        count++;
      }
    }
    return count;
  }

  /** 「已下载」数量：队列里的 done 记录（2026-11-16 起下载不再进本地音乐，两者已解耦） */
  doneCount(): number {
    let count = 0;
    for (const task of this.tasks) {
      if (task.status === 'done') {
        count++;
      }
    }
    return count;
  }

  /**
   * 已下载文件占用：取完成时 progress 回调记下的字节数（received 收尾即文件大小），
   * 不再去 LocalRepo 查，也避免为了统计对每个文件 statSync 一遍（几十首就是几十次同步 IO）。
   */
  totalBytes(): number {
    let total = 0;
    for (const task of this.tasks) {
      if (task.status === 'done') {
        total += task.received > 0 ? task.received : task.total;
      }
    }
    return total;
  }

  find(songId: string): DownloadTask | null {
    for (const task of this.tasks) {
      if (task.song.id === songId && task.status === 'done') {
        return task;
      }
    }
    return null;
  }

  pathOf(songId: string): string {
    const task = this.find(songId);
    if (task !== null && task.path.length > 0) {
      return task.path;
    }
    return LocalRepo.get().pathOf(songId);
  }

  has(songId: string): boolean {
    return this.find(songId) !== null || LocalRepo.get().pathOf(songId).length > 0;
  }

  /** 文件是否存在：accessSync 在文件缺失时抛异常，统一收口成布尔判断 */
  private static fileExists(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (e) {
      return false;
    }
  }

  /**
   * 接管老版本「下载完成自动进本地音乐」的遗留条目（2026-11-16 代码审查补）。
   *
   * 为什么必须有这一步：老版本有两种历史形态 ——
   *   ① 「完成即出队」那版：队列里没有 done 记录，只有本地音乐里的一条登记；
   *   ② 「完成留队 + 登记本地音乐」那版（本会话上一版）：两处都有。
   * 新版本启动时把它们从本地音乐摘掉（用户要求下载不要占本地音乐），
   * 形态 ② 队列里还有记录、不受影响；形态 ① 摘掉后歌就**彻底消失**了 ——
   * 本地音乐没有、下载页没有，文件还在沙箱里白占空间，用户没有任何入口能删。
   *
   * 所以 App.init 把摘下来的条目交到这里补成 done 记录：能看、能播、能左滑删。
   * 已存在同 id 记录（形态 ②）、文件已不存在、字段不全的都跳过，不重复补。
   */
  absorbLegacy(legacy: LocalSong[]): number {
    if (legacy.length === 0) {
      return 0;
    }
    let added = 0;
    for (const entry of legacy) {
      if (entry.filePath.length === 0 || entry.id.length === 0) {
        continue;
      }
      if (!Downloader.fileExists(entry.filePath)) {
        continue;
      }
      if (this.find(entry.id) !== null) {
        continue;
      }
      const song: SongInfo = newSong('local');
      song.id = entry.id;
      song.name = entry.name;
      song.singer = entry.singer;
      song.album = entry.album;
      song.duration = entry.duration;
      song.interval = entry.interval;
      song.cover = entry.cover;
      const dot: number = entry.filePath.lastIndexOf('.');
      const task: DownloadTask = {
        id: uuid(),
        song: song,
        quality: '',
        actualQuality: '',
        format: dot > 0 ? entry.filePath.substring(dot + 1) : '',
        status: 'done',
        progress: 100,
        received: entry.size,
        total: entry.size,
        path: entry.filePath,
        error: '',
        createdAt: entry.addedAt
      };
      // 队头是新任务，遗留记录按时间补在队尾，与「最早完成的在最下面」一致
      this.tasks.push(task);
      added++;
    }
    if (added === 0) {
      return 0;
    }
    this.indexDirty = true;
    this.persist();
    this.notify();
    console.info('[Download] 接管老版本下载遗留条目 ' + added.toString() + ' 首');
    return added;
  }

  /**
   * 单首入队：委托给批量入口，保证「单曲」与「批量」只有一条实现。
   * 行为与改造前完全一致（查重 → 落盘 → 广播 → 补位各一次），
   * 只是把重复逻辑收进 enqueueAll，避免两条路径日后分叉。
   */
  enqueue(song: SongInfo, quality: string = ''): void {
    this.enqueueAll([song], quality);
  }

  /**
   * 批量入队（v1.0 性能修复）：一次查重、一次落盘、一次广播、一次补位。
   *
   * 改造前 enqueueAll 只是 for 循环逐首调 enqueue，每首都做
   *   persist() → JSON.stringify(整个队列) + Store.put → flushSync() 同步刷盘
   *   notify()  → AppStorage 全局广播，触发所有订阅页 / 列表行重绘
   * 加 100 首 = 100 次同步磁盘 IO 压在 UI 线程 + 100 次全量重绘，
   * 再叠加 unshift 头插与线性查重的 O(n²) —— 这就是「一下子加几十上百首会巨卡」的根因。
   * 与 removeMany()（「只落盘一次、广播一次，避免删 20 条刷 20 遍列表」）对称：
   * 删除路径早就收口，添加路径漏了，这里补上。
   */
  enqueueAll(songs: SongInfo[], quality: string = ''): number {
    if (songs.length === 0) {
      return 0;
    }
    // 一次性建索引：排队 / 下载中 / 已暂停 / 已完成的歌不再重复入队（O(n) 一次，替代逐首线性查重）。
    // 已完成记录留在队列里，「已下载不重复下」靠这批 done 记录成立，不必再查本地音乐。
    const seen: Set<string> = new Set<string>();
    for (const task of this.tasks) {
      if (task.status === 'done' || task.status === 'running' ||
        task.status === 'waiting' || task.status === 'paused') {
        seen.add(task.song.id);
      }
    }
    // 音质档一批只取一次；单首走的也是这条路径，语义不变
    const preset: string = quality.length > 0 ? quality : Settings.get().quality();
    const fresh: DownloadTask[] = [];
    for (const song of songs) {
      if (song.source === 'local' || seen.has(song.id)) {
        continue;
      }
      seen.add(song.id); // 同一批里重复的 id 也只留一首
      const task: DownloadTask = {
        id: uuid(),
        song: song,
        quality: preset,
        actualQuality: '',
        format: '',
        status: 'waiting',
        progress: 0,
        received: 0,
        total: 0,
        path: '',
        error: '',
        createdAt: Date.now()
      };
      fresh.push(task);
      this.queue.push(task.id);
    }
    if (fresh.length === 0) {
      return 0;
    }
    // 队列按传入顺序补位（pump 用 shift，先下先加的），与改造前一致
    // 展示顺序保持「后入队的在最前」（原逐首 unshift 的效果），一次整体前插替代 O(n²) 搬移
    const head: DownloadTask[] = [];
    for (let i = fresh.length - 1; i >= 0; i--) {
      head.push(fresh[i]);
    }
    this.tasks = head.concat(this.tasks);
    this.indexDirty = true; // 队列结构变了，下次 byId 惰性重建索引
    // 收口：整批只落盘一次、只广播一次、只补位一次
    this.persist();
    this.notify();
    this.pump();
    return fresh.length;
  }

  private pump(): void {
    while (this.running < this.maxRunning && this.queue.length > 0) {
      const id = this.queue.shift();
      if (id === undefined) {
        break;
      }
      const task = this.byId(id);
      if (task === null || task.status !== 'waiting') {
        continue;
      }
      this.running++;
      this.run(task).catch(() => {
      }).finally(() => {
        this.running--;
        this.pump();
      });
    }
  }

  /**
   * O(1) 按 id 取「此刻」的实时任务。
   *
   * 下载页每一行 build() 里要按 id 取十几次（封面 uri / 歌名 / 状态 / 进度…），
   * 旧版线性遍历整份队列，234 首时每行一次重绘就是 O(n²)。改用 Map 索引：
   * 仅在任务「集合结构」变化（入队 / 删除 / 清理 / 冷启动）后惰性重建一次；
   * 进度、状态这类字段改动直接落在同一个 DownloadTask 对象上，索引指向的就是它，
   * 天然实时、无需重建。额外用长度校验兜底，避免将来新增结构变更点漏标脏。
   */
  byId(id: string): DownloadTask | null {
    if (this.indexDirty || this.taskIndex.size !== this.tasks.length) {
      this.rebuildIndex();
    }
    const hit = this.taskIndex.get(id);
    return hit === undefined ? null : hit;
  }

  private rebuildIndex(): void {
    this.taskIndex.clear();
    for (const task of this.tasks) {
      this.taskIndex.set(task.id, task);
    }
    this.indexDirty = false;
  }

  private async run(task: DownloadTask): Promise<void> {
    const context = this.context;
    if (context === null) {
      task.status = 'failed';
      task.error = '下载服务未初始化';
      return;
    }
    task.status = 'running';
    task.progress = 0;
    task.error = '';
    this.notify();
    let url = '';
    let headers: Record<string, string> = {};
    // 下载必须按真实音质校验：音源忽略 quality 参数偷偷回 128k 的情况非常普遍，
    // 不校验就会出现「选了无损、文件只有几兆」。
    try {
      const result = await Resolver.get().resolve(task.song, task.quality, true);
      url = result.url;
      headers = result.headers;
      task.actualQuality = result.quality;
      task.format = result.format;
    } catch (strictError) {
      // 取链期间被取消：别把「已取消」改写成音质/音源错误
      if (this.isCancelled(task.id)) {
        return;
      }
      // 懒人模式下「绝不降质」是硬约束：全源 / 全平台都问过仍不达标就是失败，
      // 不能再走 allowDowngrade 那条非严格重试（它会拿到低音质链接）。
      if (!Settings.get().allowDowngrade() || Settings.get().smartHunt()) {
        task.status = 'failed';
        task.error = strictError instanceof Error ? strictError.message : '音源给不了这个音质';
        this.persist();
        this.notify();
        return;
      }
      try {
        const result = await Resolver.get().resolve(task.song, task.quality, false);
        url = result.url;
        headers = result.headers;
        task.actualQuality = result.quality;
        task.format = result.format;
      } catch (e) {
        if (this.isCancelled(task.id)) {
          return;
        }
        task.status = 'failed';
        task.error = e instanceof Error ? e.message : '取链失败';
        this.persist();
        this.notify();
        return;
      }
    }
    if (task.actualQuality.length === 0) {
      task.actualQuality = task.quality;
    }
    if (task.actualQuality !== task.quality) {
      console.info('[Download] 音质降级：请求 ' + task.quality + '，实际 ' + task.actualQuality);
    }
    const ext = Downloader.extensionOf(url, task.format, isLossless(task.quality));
    // 默认信任音源时下载前不探测，文件名先按请求档位拟一个；写盘后验到真实格式会重算
    let fileName = Downloader.makeName(task.song) + ext;
    const tempPath = context.cacheDir + '/dl_' + task.id + ext;
    // 固定目录：不再逐首弹系统保存框，也不让用户选目录
    await DownloadPath.get().bootstrap();
    // 取链期间用户可能已经把任务删了：这时候再起下载，文件会凭空出现在下载目录
    if (this.isCancelled(task.id)) {
      return;
    }
    let downloadTask: request.DownloadTask | null = null;
    try {
      downloadTask = await request.downloadFile(context, {
        url: url,
        filePath: tempPath,
        // 不少音源要靠 Referer / Cookie 才给音频，丢掉就变成 403 或一段 html
        header: headers,
        enableMetered: true,
        enableRoaming: true,
        description: 'LX Music'
      });
      const live: request.DownloadTask = downloadTask;
      // 登记系统任务，供单击暂停/开始时调用原生 suspend()/restore()
      this.activeDownloads.set(task.id, live);
      await new Promise<void>((resolve, reject) => {
        // 登记主动中止通道：取消 / 清除全部任务时立刻放行 run()，释放并发槽位
        this.abortRun.set(task.id, (e: Error): void => {
          reject(e);
        });
        live.on('progress', (received: number, total: number) => {
          // 取消后立刻撤掉系统任务：只改本地状态的话，文件还会继续下完
          if (this.isCancelled(task.id)) {
            live.delete().catch(() => {
            });
            reject(new Error('已取消'));
            return;
          }
          task.received = received;
          task.total = total;
          task.progress = total > 0 ? Math.floor(received * 100 / total) : 0;
          // 只广播独立的进度信号：不碰 downloadVersion，页面级 refresh / ForEach 全量 diff
          // 不再被每 300ms 触发；节流下沉到 Downloader 实例级，3 并发不再放大到 10 次/秒。
          this.notifyProgress();
        });
        live.on('complete', () => {
          resolve();
        });
        live.on('fail', (code: number) => {
          reject(new Error('下载失败（' + code.toString() + '）'));
        });
      });
      // complete 有可能和「点取消」撞在同一瞬间：这时临时文件要清掉，不能算成功
      if (this.isCancelled(task.id)) {
        try {
          fs.unlinkSync(tempPath);
        } catch (err) {
          // 临时文件可能已被系统删除
        }
        return;
      }
      // 有些人只回一段 403/防盗链 HTML，downloadFile 仍然算「完成」。
      // 时长超过 1 分钟却不到 50KB 的，不可能是音频。
      if (Downloader.tooSmall(tempPath, task.song.duration)) {
        throw new Error('下载到的不是音频文件，已丢弃');
      }
      /**
       * 写盘后验文件头（替代下载前的 Range 探测）。
       * 洛雪官方不做二次验货；我们既想对齐「给什么就下什么」，又不能把 mp3
       * 静默存成 .flac。所以落盘后读 16 字节判真实容器：修正扩展名、修正
       * 实际音质，并把 HTML / JSON 错误页直接判失败。
       */
      const sniff = Downloader.sniffFormat(tempPath);
      if (sniff === 'html' || sniff === 'json') {
        throw new Error('下载到的不是音频文件（音源返回了错误页），已丢弃');
      }
      if (sniff !== 'unknown') {
        task.format = sniff;
        fileName = Downloader.makeName(task.song) + Downloader.extensionOf(url, sniff, false);
        if (isLossless(task.quality) && (sniff === 'mp3' || sniff === 'm4a' || sniff === 'ogg')) {
          task.actualQuality = '128k';
          console.info('[Download] 音源给的是 ' + sniff + ' 而非无损，已按真实格式保存并标注实际音质');
        }
      }
      /**
       * v1.0 完成收尾（第四次性能返工）：完成瞬间不再有任何同步大 IO。
       *
       * 前三版已经做了串行错峰、一次写全、广播合并，但装机后「完成时还是卡一下」：
       * 根因是链里每一段 IO 本身仍是同步的 —— copyFileSync(整文件) +
       * AudioTag 的 readSync/writeSync(整读整写) + 整队列 JSON.stringify/flushSync，
       * 即便让出一帧，单首无损大文件的一次同步读写也足够占住 UI 几十到几百毫秒。
       *
       * 现在：① 落盘改 moveFile(Promise)，跨分区回退 copyFile(Promise)；
       *       ② 标签 read/write 改 Promise 版，大 IO 全在系统线程池；
       *       ③ 每步 await 让出事件循环，UI 线程全程能插帧渲染；
       *       ④ 完成项只留在下载管理页，不登记本地音乐（2026-11-16 口径）；
       *       ⑤ 落盘仍当场做（磁盘实时、零丢失），只有页面级全量重建合并广播。
       * 排队期间可能又被取消，job 内重新核一次取消痕迹（temp 不能留、不能算完成）。
       */
      await this.inFinalizeOrder(async (): Promise<void> => {
        if (this.isCancelled(task.id)) {
          Downloader.cleanTemp(tempPath);
          return;
        }
        // ① 异步搬文件（不再 copyFileSync 整文件同步复制）
        const finalPath: string = await this.moveToTarget(tempPath, fileName);
        task.path = finalPath;
        // ② 一次写全：内置 LRC 随第一次 embed 写进去，避免整文件整读整写两遍
        const builtIn: string = Downloader.builtInLrc(task.song);
        try {
          await AudioTag.embed(finalPath, task.format, task.song, builtIn);
        } catch (e) {
          console.error('[Download] 写入歌曲信息失败（不影响下载）' + String(e));
        }
        // ③ 完成记录保留在下载管理页（2026-11-16）：不登记本地音乐，文件只归下载目录
        /**
         * 内嵌标签后文件长度会变（ID3/VORBIS 头被重写），progress 回调里的 received
         * 是搬移前的大小。这里以磁盘实际大小为准写回：数据页「占用空间」才不会
         * 因为最后一次 progress 没回调而显示 0，也不会少算标签体积。
         * 只做一次 statSync（元数据，不读文件内容），不违反「完成瞬间零同步大 IO」。
         */
        try {
          const size: number = fs.statSync(finalPath).size;
          task.received = size;
          task.total = size;
        } catch (e) {
          console.info('[Download] 读取文件大小失败 ' + String(e));
        }
        task.status = 'done';
        task.progress = 100;
        task.error = '';
        // ④ 落盘当场做（磁盘实时，绝不因合并而延迟/丢失）
        this.persist();
        this.scheduleCommit();
        // 歌词异步补齐：仅「没有内置词」时联网取词并二次 embed（异步 IO、天然错峰）
        this.embedLyricLater(finalPath, task.format, task.song);
      });
    } catch (e) {
      // 取消也会走到这里（progress 里 reject），别把「已取消」改写成失败原因
      if (this.isCancelled(task.id)) {
        try {
          fs.unlinkSync(tempPath);
        } catch (err) {
          // 临时文件可能不存在
        }
        return;
      }
      task.status = 'failed';
      task.error = e instanceof Error ? e.message : '下载失败';
      try {
        fs.unlinkSync(tempPath);
      } catch (err) {
        // 临时文件可能不存在
      }
      this.persist();
      this.notify();
    } finally {
      // DownloadTask 不 delete 会一直占着系统下载槽位，
      // 攒到上限之后新任务直接失败（表现为「点下载没反应」）
      if (downloadTask !== null) {
        downloadTask.delete().catch(() => {
        });
      }
      // 系统任务引用与中止通道随 run() 一起释放；暂停期间 run() 还挂着，这里不会提前删
      this.activeDownloads.delete(task.id);
      this.abortRun.delete(task.id);
      // run 已经结束，取消痕迹可以收了；留着会越攒越多
      this.cancelled = this.cancelled.filter((item: string): boolean => item !== task.id);
    }
  }

  /**
   * 搜索结果自带的 LRC（可直接内嵌）；不是 LRC / 是标记文本时返回空。
   * v1.0 性能收口：抽成静态方法，让完成收尾第一次 embed 就能一次写全，
   * 不必「先空词写一遍、再补词写第二遍」—— embed 是整文件整读整写，
   * 无损歌几十 MB，多写一遍就是多一次全量 IO + 整文件内存拷贝。
   */
  private static builtInLrc(song: SongInfo): string {
    return song.lyric.length > 0 && song.lyric.indexOf('[') >= 0 &&
      !looksLikeMarkup(song.lyric) && !looksLikeNonLyric(song.lyric) ? song.lyric : '';
  }

  /**
   * 歌词补齐（v1.0）。刻意不 await：LyricRepo 是多源带超时的网络链路，
   * 不能让它拖住「下载完成」这个状态；拿到词后再二次 embed 写 USLT / LYRICS。
   * embed 是幂等的（mp3 重建 ID3、flac 合并 VORBIS_COMMENT），不会叠出两份标签，
   * 也不会产生第二个文件 —— 下载目录里始终只有这一首歌的音频文件。
   *
   * 搜索结果自带 LRC 的场景已在完成收尾里随第一次 embed 一次写全，这里直接返回，
   * 只有「没有内置词」才联网取词并二次 embed（异步、自然错峰，不挤在完成那一帧）。
   */
  private embedLyricLater(path: string, format: string, song: SongInfo): void {
    if (Downloader.builtInLrc(song).length > 0) {
      return;
    }
    LyricRepo.get().get(song).then((doc: LyricDoc): void => {
      const lrc = Downloader.toLrcText(doc);
      if (lrc.length === 0) {
        return;
      }
      // embed 已改异步大 IO；失败只记日志，绝不影响下载结果
      AudioTag.embed(path, format, song, lrc).catch((e: Object): void => {
        console.error('[Download] 内嵌歌词失败（不影响下载）' + String(e));
      });
    }).catch(() => {
      // 取不到歌词是正常情况，不记错误
    });
  }

  /** 把解析后的歌词还原成标准 LRC 文本，写进同一个文件的 USLT / LYRICS */
  private static toLrcText(doc: LyricDoc): string {
    if (doc.lines.length === 0) {
      return '';
    }
    if (doc.plain) {
      let plain = '';
      for (const line of doc.lines) {
        if (line.text.length > 0) {
          plain += line.text + '\n';
        }
      }
      return plain;
    }
    let out = '';
    for (const line of doc.lines) {
      if (line.time < 0 || line.text.length === 0) {
        continue;
      }
      out += '[' + LyricRepo.lrcTime(line.time) + ']' + line.text;
      if (line.trans.length > 0) {
        out += ' / ' + line.trans;
      }
      out += '\n';
    }
    return out;
  }

  /** 文件明显小于音频下限：交给上层当失败处理，避免存下一个坏文件 */
  private static tooSmall(path: string, durationSec: number): boolean {
    if (durationSec < 60) {
      return false;
    }
    try {
      const stat = fs.statSync(path);
      return stat.size > 0 && stat.size < 50 * 1024;
    } catch (e) {
      return false;
    }
  }

  /**
   * 读文件头判定真实容器。返回 unknown 表示认不出（加密流 / 非标准中转封装），
   * 这时保留请求档位的扩展名，不擅自降标，也不擅自升标。
   */
  private static sniffFormat(path: string): string {
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(16);
      try {
        fs.readSync(file.fd, buf, { length: 16 });
      } finally {
        fs.closeSync(file);
      }
      const b = new Uint8Array(buf);
      if (b.length < 12) {
        return 'unknown';
      }
      if (b[0] === 0x66 && b[1] === 0x4C && b[2] === 0x61 && b[3] === 0x43) {
        return 'flac';                                   // fLaC
      }
      if (b[0] === 0x4F && b[1] === 0x67 && b[2] === 0x67 && b[3] === 0x53) {
        return 'ogg';                                    // OggS
      }
      if (b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 &&
        b[8] === 0x57 && b[9] === 0x41 && b[10] === 0x56 && b[11] === 0x45) {
        return 'wav';                                    // RIFF....WAVE
      }
      if ((b[0] === 0x49 && b[1] === 0x44 && b[2] === 0x33) ||
        (b[0] === 0xFF && (b[1] & 0xE0) === 0xE0)) {
        return 'mp3';                                    // ID3 或 MPEG 帧同步
      }
      if (b[4] === 0x66 && b[5] === 0x74 && b[6] === 0x79 && b[7] === 0x70) {
        return 'm4a';                                    // ....ftyp
      }
      if (b[0] === 0x3C) {
        return 'html';                                   // '<' 防盗链 / 错误页
      }
      if (b[0] === 0x7B) {
        return 'json';                                   // '{' 接口错误体
      }
      return 'unknown';
    } catch (e) {
      return 'unknown';
    }
  }

  /**
   * 写到固定目录（v1.0 第四次返工：整文件搬移改异步）。
   *
   * 旧版 tryWrite 用 copyFileSync 把 cache 里的临时文件同步复制成目标文件，
   * 无损歌几十 MB 就是几十 MB 的同步读+写压在 UI 线程上 —— 完成瞬间卡顿的最大单块。
   * 现在改用 moveFile(Promise)：同分区是元数据级 rename，跨分区由系统线程池搬运，
   * 全程 await 让出事件循环；失败再回退到 copyFile(Promise)（同样异步）。
   * 公共目录写不进去时仍回退应用内目录，保证下载结果可用。
   */
  private async moveToTarget(tempPath: string, fileName: string): Promise<string> {
    const path = DownloadPath.get();
    const primary = path.currentDir();
    const primaryTarget = primary + Downloader.uniqueName(primary, fileName);
    if (await Downloader.tryWriteAsync(tempPath, primaryTarget)) {
      return primaryTarget;
    }
    const fallback = path.fallbackDir();
    const fallbackTarget = fallback + Downloader.uniqueName(fallback, fileName);
    if (fallbackTarget !== primaryTarget && await Downloader.tryWriteAsync(tempPath, fallbackTarget)) {
      console.error('[Download] 公共目录写入失败，已保存到 ' + fallbackTarget);
      return fallbackTarget;
    }
    Downloader.cleanTemp(tempPath);
    throw new Error('无法写入下载文件（公共 Download 与应用内目录均失败）');
  }

  private static async tryWriteAsync(tempPath: string, targetPath: string): Promise<boolean> {
    try {
      const dir = targetPath.substring(0, targetPath.lastIndexOf('/'));
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      // moveFile 会连临时文件一起移走，不用再 unlink；大 IO 在 Promise 里完成
      await fs.moveFile(tempPath, targetPath);
      return true;
    } catch (e) {
      // 跨文件系统 / 权限差异导致 move 失败时，退回异步复制（同样不阻塞 UI 线程）
      try {
        await fs.copyFile(tempPath, targetPath);
        Downloader.cleanTemp(tempPath);
        return true;
      } catch (e2) {
        console.error('[Download] 写入失败 ' + targetPath + ' ' + String(e2));
        return false;
      }
    }
  }

  /** 同名文件不覆盖，自动加 (2) (3) */
  private static uniqueName(dir: string, fileName: string): string {
    try {
      if (!fs.accessSync(dir + fileName)) {
        return fileName;
      }
    } catch (e) {
      return fileName;
    }
    const dot = fileName.lastIndexOf('.');
    const base = dot > 0 ? fileName.substring(0, dot) : fileName;
    const ext = dot > 0 ? fileName.substring(dot) : '';
    for (let i = 2; i < 1000; i++) {
      const candidate = base + ' (' + i.toString() + ')' + ext;
      try {
        if (!fs.accessSync(dir + candidate)) {
          return candidate;
        }
      } catch (e) {
        return candidate;
      }
    }
    return uuid() + ext;
  }

  private static cleanTemp(tempPath: string): void {
    try {
      fs.unlinkSync(tempPath);
    } catch (e) {
      // 临时文件可能已不存在
    }
  }

  retry(id: string): void {
    const task = this.byId(id);
    if (task === null || task.status !== 'failed') {
      return;
    }
    // 取消过的任务要能重试成功：不清掉痕迹，回调一进来就又被当取消处理
    this.cancelled = this.cancelled.filter((item: string): boolean => item !== id);
    task.status = 'waiting';
    task.error = '';
    this.queue.push(task.id);
    this.persist();
    this.notify();
    this.pump();
  }

  private isCancelled(id: string): boolean {
    return this.cancelled.indexOf(id) >= 0;
  }

  /** 改状态但不落盘，供批量删除时统一收口 */
  private markCancelled(task: DownloadTask): void {
    if (!this.isCancelled(task.id)) {
      this.cancelled.push(task.id);
    }
    task.status = 'failed';
    task.error = '已取消';
    this.queue = this.queue.filter((item: string): boolean => item !== task.id);
    // 主动放行 run()：暂停中的系统任务被删后不会再有 progress 回调，
    // 不 abort 的话 run() 永远挂在 complete/fail 上，并发槽位再也放不出来
    const abort = this.abortRun.get(task.id);
    if (abort !== undefined) {
      abort(new Error('已取消'));
    }
  }

  /**
   * 取消任务。
   * 以前只处理 waiting，正在下载的那条点「×」完全没反应（进度条继续跑），
   * 现在 running 也一起取消：改状态 + 记进 cancelled，由 run() 里的回调收尾。
   */
  cancel(id: string): void {
    const task = this.byId(id);
    if (task === null) {
      return;
    }
    if (task.status === 'done' || task.status === 'failed') {
      return;
    }
    this.markCancelled(task);
    this.persist();
    this.notify();
  }

  /**
   * 单条摘除（不落盘、不广播，由调用方统一收口）。
   * 2026-11-16：下载不再登记进本地音乐，文件只有本队列一个引用方 —— 删记录必须一并删文件，
   * 否则任务没了、几十 MB 还躺在下载目录里，正是用户说的「太占地方」。
   * 还没下完的先取消，临时文件由 run() 的收尾逻辑清掉（这里不碰 temp）。
   */
  private dropOne(task: DownloadTask): void {
    // 还在下载的先取消，否则记录没了、后台还在写文件
    if (task.status === 'running' || task.status === 'waiting' || task.status === 'paused') {
      this.markCancelled(task);
    }
    if (task.path.length > 0 && (task.status === 'done' || task.status === 'failed')) {
      try {
        fs.unlinkSync(task.path);
      } catch (e) {
        console.info('[Download] 删除文件失败 ' + String(e));
      }
    }
    this.tasks = this.tasks.filter((item: DownloadTask): boolean => item.id !== task.id);
    this.indexDirty = true; // 队列结构变了，标记重建 id 索引
    this.queue = this.queue.filter((item: string): boolean => item !== task.id);
    // 这里不清 cancelled：run() 可能还在跑，清掉它就会把文件继续写下去。
    // 痕迹留到 run() 的 finally 里再收。
  }

  remove(id: string): void {
    const task = this.byId(id);
    if (task === null) {
      return;
    }
    this.dropOne(task);
    this.persist();
    this.notify();
  }

  /** 批量删除：只落盘一次、广播一次，避免删 20 条刷 20 遍列表 */
  removeMany(ids: string[]): number {
    if (ids.length === 0) {
      return 0;
    }
    let removed = 0;
    for (const id of ids) {
      const task = this.byId(id);
      if (task === null) {
        continue;
      }
      this.dropOne(task);
      removed++;
    }
    if (removed > 0) {
      this.persist();
      this.notify();
    }
    return removed;
  }

  /** 清「已完成」任务记录（当前页面无入口，保留给调用方）：连同文件一起删，避免留下孤儿占空间 */
  clearDone(): void {
    const before = this.tasks.length;
    for (const task of this.tasks) {
      if (task.status === 'done' && task.path.length > 0) {
        try {
          fs.unlinkSync(task.path);
        } catch (e) {
          console.info('[Download] 删除文件失败 ' + String(e));
        }
      }
    }
    this.tasks = this.tasks.filter((item: DownloadTask): boolean => item.status !== 'done');
    if (this.tasks.length === before) {
      return;
    }
    this.indexDirty = true;
    this.persist();
    this.notify();
  }

  clearFailed(): void {
    this.tasks = this.tasks.filter((item: DownloadTask): boolean => item.status !== 'failed');
    this.indexDirty = true; // 队列结构变了，标记重建 id 索引
    this.persist();
    this.notify();
  }

  /**
   * 单击一行：在「暂停 / 开始」之间切换。
   * running / waiting → 暂停；paused → 继续；failed → 重新入队（也算「开始」）。
   * done 留在本页展示「已完成」，不参与暂停/开始（页面侧另有提示）。
   */
  toggle(id: string): void {
    const task = this.byId(id);
    if (task === null) {
      return;
    }
    if (task.status === 'running' || task.status === 'waiting') {
      this.pause(id).catch((): void => {
      });
    } else if (task.status === 'paused') {
      this.resume(id).catch((): void => {
      });
    } else if (task.status === 'failed') {
      this.retry(id);
    }
  }

  /**
   * 暂停。优先用系统下载任务的原生 suspend()：进度与临时文件都保留，
   * 恢复时 restore() 接着下，不重新取链、不从头开始。
   * run() 里那个等 complete/fail 的 Promise 在 suspend 期间仍挂着（既不触发也不
   * 释放槽位），与 pump() 的 running 计数天然兼容，不需要重新跑一次 run()。
   */
  private async pause(id: string, silent: boolean = false): Promise<void> {
    const task = this.byId(id);
    if (task === null || (task.status !== 'running' && task.status !== 'waiting')) {
      return;
    }
    const live = this.activeDownloads.get(id);
    // 状态先落地，UI 立刻反馈；suspend 是异步系统动作，失败再降级
    task.status = 'paused';
    task.error = '';
    // waiting 的还留在 queue 里，pump 会因状态不符直接丢掉 id，主动移走、恢复时再补
    this.queue = this.queue.filter((item: string): boolean => item !== id);
    if (live !== undefined) {
      try {
        await live.suspend();
      } catch (e) {
        // 系统 suspend 不可用：取消本次系统任务并标暂停，恢复时重新入队
        this.markCancelled(task);
        task.status = 'paused';
        task.error = '';
        try {
          await live.delete();
        } catch (err) {
          // 任务可能已结束
        }
      }
    }
    if (!silent) {
      this.persist();
      this.notify();
    }
  }

  /** 开始（继续）：有系统任务就 restore 接着下，否则重新入队跑一次 run() */
  private async resume(id: string, silent: boolean = false): Promise<void> {
    const task = this.byId(id);
    if (task === null || task.status !== 'paused') {
      return;
    }
    const live = this.activeDownloads.get(id);
    // 清掉降级暂停可能留下的取消痕迹，避免新的 run() 一进来就被判取消
    this.cancelled = this.cancelled.filter((item: string): boolean => item !== id);
    let restored = false;
    if (live !== undefined) {
      try {
        await live.restore();
        restored = true;
      } catch (e) {
        restored = false;
      }
    }
    if (restored) {
      task.status = 'running';
      task.error = '';
    } else {
      // waiting 时暂停 / 冷启动恢复 / restore 失败：重新走一次 run()
      task.status = 'waiting';
      task.error = '';
      this.queue.push(task.id);
      this.pump();
    }
    if (!silent) {
      this.persist();
      this.notify();
    }
  }

  /** 全部暂停：并发挂起后只落盘一次、广播一次，避免 N 首刷 N 遍 */
  pauseAll(): void {
    const ids: string[] = [];
    for (const task of this.tasks) {
      if (task.status === 'running' || task.status === 'waiting') {
        ids.push(task.id);
      }
    }
    if (ids.length === 0) {
      return;
    }
    const jobs: Promise<void>[] = [];
    for (const id of ids) {
      jobs.push(this.pause(id, true));
    }
    const collect = (): void => {
      this.persist();
      this.notify();
    };
    Promise.all(jobs).then(collect).catch(collect);
  }

  /** 全部开始：并发恢复后只落盘一次、广播一次 */
  resumeAll(): void {
    const ids: string[] = [];
    for (const task of this.tasks) {
      if (task.status === 'paused') {
        ids.push(task.id);
      }
    }
    if (ids.length === 0) {
      return;
    }
    const jobs: Promise<void>[] = [];
    for (const id of ids) {
      jobs.push(this.resume(id, true));
    }
    const collect = (): void => {
      this.persist();
      this.notify();
    };
    Promise.all(jobs).then(collect).catch(collect);
  }

  /** 清除全部任务：取消在跑的 + 删掉所有已下载文件（下载不再进本地音乐，文件只有这里引用） */
  clearAll(): void {
    for (const task of this.tasks) {
      if (task.status === 'running' || task.status === 'waiting' || task.status === 'paused') {
        this.markCancelled(task);
        const live = this.activeDownloads.get(task.id);
        if (live !== undefined) {
          live.delete().catch((): void => {
          });
        }
      } else if (task.path.length > 0) {
        try {
          fs.unlinkSync(task.path);
        } catch (e) {
          console.info('[Download] 删除文件失败 ' + String(e));
        }
      }
    }
    this.queue = [];
    this.tasks = [];
    this.indexDirty = true;
    this.persist();
    this.notify();
  }

  private persist(): void {
    this.trimOverflow();
    Store.get().put(PrefKeys.DOWNLOADS, JSON.stringify(this.tasks));
  }

  /**
   * 队列超过持久化上限时，从**队尾**（最早入队/最早完成）开始裁掉已结束的任务。
   *
   * 为什么必须同时删文件：完成项不再登记本地音乐，文件只被这条记录引用。
   * 只裁记录不删文件 = 磁盘上留下永远看不到、也删不掉的孤儿，正好违背
   * 「别占地方」的初衷。进行中的任务绝不裁（会打断下载）。
   * 正在播放的那一首也绝不裁：播放器持有它的 fd，删了会当场断音且不可恢复，
   * 而这是用户在听的东西，比「少一条旧记录」重要得多。
   */
  private trimOverflow(): void {
    const overflow: number = this.tasks.length - DOWNLOAD_PERSIST_MAX;
    if (overflow <= 0) {
      return;
    }
    const playing: string = AppStorage.get<string>('playingLocalPath') ?? '';
    // 从队尾（最早入队 / 最早完成）往回数，凑够要裁的条数；进行中 / 正在播放的跳过不裁
    const drop: Set<string> = new Set<string>();
    for (let i = this.tasks.length - 1; i >= 0 && drop.size < overflow; i--) {
      const task = this.tasks[i];
      if (task.status !== 'done' && task.status !== 'failed') {
        continue;
      }
      if (playing.length > 0 && task.path === playing) {
        continue;
      }
      drop.add(task.id);
      if (task.path.length > 0) {
        try {
          fs.unlinkSync(task.path);
        } catch (e) {
          console.info('[Download] 清理旧记录时删除文件失败 ' + String(e));
        }
      }
    }
    if (drop.size === 0) {
      return;
    }
    const keep: DownloadTask[] = [];
    for (const task of this.tasks) {
      if (!drop.has(task.id)) {
        keep.push(task);
      }
    }
    this.tasks = keep;
    this.indexDirty = true; // 集合结构变了，重建 id 索引
    this.trimNotified += drop.size;
    console.warn('[Download] 队列超过 ' + DOWNLOAD_PERSIST_MAX.toString() +
      ' 条，已清理最旧的 ' + drop.size.toString() + ' 条下载记录及文件');
  }

  /**
   * 取走「上次自动清理了几条」的提示计数。
   * 自动清理会连文件一起删，属于不可恢复操作，不能只在日志里留痕：
   * 下载页每次刷新取一次，>0 就弹提示，让用户知道是队列上限触发的，而不是文件丢了。
   */
  consumeTrimNotice(): number {
    const count: number = this.trimNotified;
    this.trimNotified = 0;
    return count;
  }

  private static makeName(song: SongInfo): string {
    const name = song.singer.length > 0 ? song.name + ' - ' + song.singer : song.name;
    return safeFileName(name);
  }

  /**
   * 后缀按「真实格式」走，不按请求音质猜。
   * 以前请求 flac 就无脑补 .flac，即使下到的是 mp3，文件管理器里看着像无损。
   */
  private static extensionOf(url: string, format: string, losslessHint: boolean = false): string {
    if (format === 'flac') {
      return '.flac';
    }
    if (format === 'm4a') {
      return '.m4a';
    }
    if (format === 'ogg') {
      return '.ogg';
    }
    if (format === 'wav') {
      return '.wav';
    }
    if (format === 'mp3') {
      return '.mp3';
    }
    const lower = url.toLowerCase();
    const cut = lower.indexOf('?');
    const path = cut >= 0 ? lower.substring(0, cut) : lower;
    if (path.endsWith('.flac')) {
      return '.flac';
    }
    if (path.endsWith('.m4a') || path.endsWith('.mp4') || path.endsWith('.aac')) {
      return '.m4a';
    }
    if (path.endsWith('.ogg') || path.endsWith('.opus')) {
      return '.ogg';
    }
    if (path.endsWith('.wav')) {
      return '.wav';
    }
    // 探测认不出格式（中转 API 常回 octet-stream），但请求的是无损档时
    // 按 flac 存，别兜底成 .mp3 —— 否则无损文件会被写成错扩展名
    if (format === 'unknown' && losslessHint) {
      return '.flac';
    }
    return '.mp3';
  }
}

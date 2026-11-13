import { common } from '@kit.AbilityKit';
import { request } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { SongInfo, DownloadTask, LyricDoc } from '../common/Models';
import { PrefKeys, qualityLabel, isLossless } from '../common/Constants';
import { safeFileName, uuid } from '../common/Utils';
import { Store } from './Store';
import { Resolver } from './Resolver';
import { Settings } from './Settings';
import { DownloadPath } from './DownloadPath';
import { AudioTag } from './AudioTag';
import { LyricRepo } from './LyricRepo';
import { looksLikeMarkup, looksLikeNonLyric } from './Lrc';

/**
 * 下载中心
 *
 * - 任务队列 2 并发，先取链再落盘
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
  private queue: string[] = [];
  private running: number = 0;
  private maxRunning: number = 2;
  private listeners: Array<() => void> = [];
  private context: common.UIAbilityContext | null = null;
  /**
   * 已点「取消」的任务 id。
   * 系统下载任务在 progress/complete 回调里才看得到，光改 status 会被回调覆盖回 done，
   * 而且文件会照样落盘 —— 所以取消要留痕，回调里再核一次。
   */
  private cancelled: string[] = [];

  init(context: common.UIAbilityContext): void {
    this.context = context;
    // 固定下载目录：启动时只做本地探测，需要系统授权时留到首次下载
    // （那时界面一定在前台，比冷启动阶段拉起 picker 更可靠）
    DownloadPath.get().init(context);
    const text = Store.get().getString(PrefKeys.DOWNLOADS, '[]');
    try {
      this.tasks = JSON.parse(text) as DownloadTask[];
    } catch (e) {
      this.tasks = [];
    }
    // 上次退出时还在下载的，标记为失败，避免永远转圈
    for (const task of this.tasks) {
      if (task.status === 'running' || task.status === 'waiting') {
        task.status = 'failed';
        task.error = '上次下载被中断';
      }
    }
  }

  onChange(listener: () => void): void {
    this.listeners.push(listener);
  }

  offChange(listener: () => void): void {
    this.listeners = this.listeners.filter((item: () => void): boolean => item !== listener);
  }

  private notify(): void {
    for (const listener of this.listeners) {
      listener();
    }
    AppStorage.setOrCreate('downloadVersion', Date.now());
  }

  /** 界面展示的固定下载目录（不再由用户选择） */
  getDirName(): string {
    return DownloadPath.get().displayPath();
  }

  /**
   * 某首歌当前的下载状态：none / waiting / running / done。
   *
   * 播放页底部按钮靠它决定写「下载」「排队中」「下载中」还是「已下载」——
   * 不区分的话，已经下好的歌也挂着「下载」二字，点下去只换来一句「已经在本地了」。
   */
  stateOf(song: SongInfo): string {
    for (const task of this.tasks) {
      if (task.song.id !== song.id || task.song.source !== song.source) {
        continue;
      }
      if (task.status === 'done') {
        return 'done';
      }
      if (task.status === 'running') {
        return 'running';
      }
      if (task.status === 'waiting') {
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

  doneCount(): number {
    let count = 0;
    for (const task of this.tasks) {
      if (task.status === 'done') {
        count++;
      }
    }
    return count;
  }

  totalBytes(): number {
    let total = 0;
    for (const task of this.tasks) {
      if (task.status === 'done') {
        total += task.total;
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
    return task === null ? '' : task.path;
  }

  has(songId: string): boolean {
    return this.find(songId) !== null;
  }

  enqueue(song: SongInfo, quality: string = ''): void {
    if (song.source === 'local') {
      return;
    }
    const existing = this.find(song.id);
    if (existing !== null) {
      return;
    }
    for (const task of this.tasks) {
      if (task.song.id === song.id && (task.status === 'running' || task.status === 'waiting')) {
        return;
      }
    }
    const task: DownloadTask = {
      id: uuid(),
      song: song,
      quality: quality.length > 0 ? quality : Settings.get().quality(),
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
    this.tasks.unshift(task);
    this.queue.push(task.id);
    this.persist();
    this.notify();
    this.pump();
  }

  enqueueAll(songs: SongInfo[]): number {
    let count = 0;
    for (const song of songs) {
      this.enqueue(song);
      count++;
    }
    return count;
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

  private byId(id: string): DownloadTask | null {
    for (const task of this.tasks) {
      if (task.id === id) {
        return task;
      }
    }
    return null;
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
      await new Promise<void>((resolve, reject) => {
        let lastNotify = 0;
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
          const now = Date.now();
          if (now - lastNotify > 300) {
            lastNotify = now;
            this.notify();
          }
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
      task.path = this.copyToTarget(tempPath, fileName);
      /**
       * v1.0：把歌名 / 歌手 / 专辑写进音频文件本身。
       * 此前只体现在文件名和 App 自己的下载记录里，拷到别的设备就是「未知」。
       * 纯本地、零延迟；失败只记日志，绝不影响下载结果。
       */
      try {
        AudioTag.embed(task.path, task.format, task.song, '');
      } catch (e) {
        console.error('[Download] 写入歌曲信息失败（不影响下载）' + String(e));
      }
      // 歌词异步补齐：拿到 LRC 后再 embed 一次（幂等），歌词仍写进同一个文件
      this.embedLyricLater(task.path, task.format, task.song);
      task.status = 'done';
      task.progress = 100;
      task.error = '';
      this.persist();
      this.notify();
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
      // run 已经结束，取消痕迹可以收了；留着会越攒越多
      this.cancelled = this.cancelled.filter((item: string): boolean => item !== task.id);
    }
  }

  /**
   * 歌词补齐（v1.0）。刻意不 await：LyricRepo 是多源带超时的网络链路，
   * 不能让它拖住「下载完成」这个状态；拿到词后再二次 embed 写 USLT / LYRICS。
   * embed 是幂等的（mp3 重建 ID3、flac 合并 VORBIS_COMMENT），不会叠出两份标签，
   * 也不会产生第二个文件 —— 下载目录里始终只有这一首歌的音频文件。
   */
  private embedLyricLater(path: string, format: string, song: SongInfo): void {
    // 搜索结果自带 LRC 时直接用，省一次网络请求
    const builtIn = song.lyric.length > 0 && song.lyric.indexOf('[') >= 0 &&
      !looksLikeMarkup(song.lyric) && !looksLikeNonLyric(song.lyric) ? song.lyric : '';
    if (builtIn.length > 0) {
      try {
        AudioTag.embed(path, format, song, builtIn);
      } catch (e) {
        console.error('[Download] 内嵌歌词失败（不影响下载）' + String(e));
      }
      return;
    }
    LyricRepo.get().get(song).then((doc: LyricDoc): void => {
      const lrc = Downloader.toLrcText(doc);
      if (lrc.length === 0) {
        return;
      }
      try {
        AudioTag.embed(path, format, song, lrc);
      } catch (e) {
        console.error('[Download] 内嵌歌词失败（不影响下载）' + String(e));
      }
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

  /** 写到固定目录；公共目录写不进去时回退应用内，保证下载结果可用 */
  private copyToTarget(tempPath: string, fileName: string): string {
    const path = DownloadPath.get();
    const primary = path.currentDir();
    const primaryTarget = primary + Downloader.uniqueName(primary, fileName);
    if (Downloader.tryWrite(tempPath, primaryTarget)) {
      Downloader.cleanTemp(tempPath);
      return primaryTarget;
    }
    const fallback = path.fallbackDir();
    const fallbackTarget = fallback + Downloader.uniqueName(fallback, fileName);
    if (fallbackTarget !== primaryTarget && Downloader.tryWrite(tempPath, fallbackTarget)) {
      Downloader.cleanTemp(tempPath);
      console.error('[Download] 公共目录写入失败，已保存到 ' + fallbackTarget);
      return fallbackTarget;
    }
    throw new Error('无法写入下载文件（公共 Download 与应用内目录均失败）');
  }

  private static tryWrite(tempPath: string, targetPath: string): boolean {
    try {
      const dir = targetPath.substring(0, targetPath.lastIndexOf('/'));
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      // CREATE 不能少：目标文件本来就不存在，缺了它必然 ENOENT；
      // 父目录也要显式建，openSync 不会替你建目录
      const dest = fs.openSync(targetPath,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.copyFileSync(tempPath, dest.fd);
      } finally {
        fs.closeSync(dest);
      }
      return true;
    } catch (e) {
      console.error('[Download] 写入失败 ' + targetPath + ' ' + String(e));
      return false;
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

  /** 单条摘除（不落盘、不广播，由调用方统一收口） */
  private dropOne(task: DownloadTask): void {
    // 还在下载的先取消，否则记录没了、后台还在写文件
    if (task.status === 'running' || task.status === 'waiting') {
      this.markCancelled(task);
    }
    if (task.path.length > 0 && task.status === 'done') {
      try {
        fs.unlinkSync(task.path);
      } catch (e) {
        console.info('[Download] 删除文件失败 ' + String(e));
      }
    }
    this.tasks = this.tasks.filter((item: DownloadTask): boolean => item.id !== task.id);
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

  clearDone(): void {
    for (const task of this.tasks) {
      if (task.status === 'done' && task.path.length > 0) {
        try {
          fs.unlinkSync(task.path);
        } catch (e) {
          // 文件可能已被手动删除
        }
      }
    }
    this.tasks = this.tasks.filter((item: DownloadTask): boolean => item.status !== 'done');
    this.persist();
    this.notify();
  }

  clearFailed(): void {
    this.tasks = this.tasks.filter((item: DownloadTask): boolean => item.status !== 'failed');
    this.persist();
    this.notify();
  }

  private persist(): void {
    Store.get().put(PrefKeys.DOWNLOADS, JSON.stringify(this.tasks.slice(0, 300)));
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

  static qualityText(q: string): string {
    return qualityLabel(q);
  }
}

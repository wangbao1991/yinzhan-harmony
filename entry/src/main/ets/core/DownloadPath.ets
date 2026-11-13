import { bundleManager, common } from '@kit.AbilityKit';
import { fileUri, fileIo as fs, picker } from '@kit.CoreFileKit';

/**
 * 下载目录（固定，不需要用户选择）
 *
 * 参考 MusicFree 的 PathConst：公共 Download/<bundleName>/ 由系统以
 * DocumentPickerMode.DOWNLOAD 预置持久化授权，应用拿到真实路径后可直接 fs 读写；
 * 这个模式的 save 不弹目录选择框，目录被手动删掉时同样用它让系统重建。
 *
 * 授权/目录最终仍不可用时回退到应用内 filesDir/music/，保证下载一定能完成，
 * 并在界面上如实显示当前实际目录，不静默假装写到了公共 Download。
 */
export class DownloadPath {
  private static instance: DownloadPath = new DownloadPath();

  static get(): DownloadPath {
    return DownloadPath.instance;
  }

  private context: common.UIAbilityContext | null = null;
  private publicDir: string = '';
  private privateDir: string = '';
  private folderName: string = '';
  private task: Promise<void> | null = null;
  private fallback: boolean = false;
  private confirmed: boolean = false;

  init(context: common.UIAbilityContext): void {
    this.context = context;
    this.privateDir = context.filesDir + '/music/';
    DownloadPath.probeWritable(this.privateDir);
    this.publicDir = DownloadPath.resolvePublicDir();
    this.folderName = DownloadPath.lastSegment(this.publicDir);
    // 已经拿过持久化授权（或系统预置）时，纯 fs 探测就能确认，不必拉起系统界面
    if (this.publicDir.length > 0 && DownloadPath.probeWritable(this.publicDir)) {
      this.fallback = false;
      this.confirmed = true;
    }
  }

  /** 构造公共 Download/<包名>/ 的真实文件系统路径 */
  private static resolvePublicDir(): string {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      const uri = 'file://docs/storage/Users/currentUser/Download/' + info.name;
      const path = new fileUri.FileUri(uri).path;
      if (path.length > 0) {
        return path.endsWith('/') ? path : path + '/';
      }
    } catch (e) {
      console.error('[DownloadPath] 构造公共下载目录失败 ' + String(e));
    }
    return '';
  }

  /** 确保公共目录就绪。结果缓存，失败后也保留，避免每首下载都拉起系统界面 */
  bootstrap(): Promise<void> {
    if (this.task === null) {
      // 目录准备绝不能把下载任务卡在 running：任何异常都转成「用兜底目录」
      this.task = this.ensure().catch((e: Object) => {
        this.fallback = true;
        this.confirmed = true;
        console.error('[DownloadPath] 下载目录初始化异常 ' + String(e));
      });
    }
    return this.task;
  }

  /** 手动重新检测（设置页 / 下载管理页用） */
  async retry(): Promise<void> {
    this.task = null;
    this.confirmed = false;
    await this.bootstrap();
  }

  private async ensure(): Promise<void> {
    if (this.confirmed) {
      return;
    }
    // 真实探测可写性，不能只看目录在不在：目录存在却没权限一样写不进去
    if (this.publicDir.length > 0 && DownloadPath.probeWritable(this.publicDir)) {
      this.fallback = false;
      this.confirmed = true;
      return;
    }
    const created = await this.createViaDownloadMode();
    if (created && this.publicDir.length > 0 && DownloadPath.probeWritable(this.publicDir)) {
      this.fallback = false;
      this.confirmed = true;
      return;
    }
    this.fallback = true;
    this.confirmed = true;
    console.error('[DownloadPath] 公共下载目录不可用，改用应用内目录');
  }

  /** DOWNLOAD 模式：系统自动建 Download/<包名>/ 并授予持久化权限，免弹选择框 */
  private async createViaDownloadMode(): Promise<boolean> {
    if (this.context === null) {
      return false;
    }
    try {
      const viewPicker = new picker.DocumentViewPicker(this.context);
      const options = new picker.DocumentSaveOptions();
      options.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
      const uris = await viewPicker.save(options);
      for (const uri of uris) {
        try {
          // 该模式会在目录内预置一个空文件，清掉它
          const path = new fileUri.FileUri(uri).path;
          if (fs.accessSync(path)) {
            fs.unlinkSync(path);
          }
        } catch (e) {
          // 占位文件清理失败不影响目录可用性
        }
      }
      return uris.length > 0;
    } catch (e) {
      console.error('[DownloadPath] DOWNLOAD 模式授权失败 ' + String(e));
      return false;
    }
  }

  /** 当前实际写入目录（公共优先，失败回退应用内） */
  currentDir(): string {
    return this.isFallback() ? this.privateDir : this.publicDir;
  }

  fallbackDir(): string {
    return this.privateDir;
  }

  isFallback(): boolean {
    return this.fallback || this.publicDir.length === 0;
  }

  /** 界面展示用：给人看的短路径，不甩一长串 /storage/... */
  displayPath(): string {
    if (this.isFallback()) {
      return '应用内 music/（公共 Download 不可用）';
    }
    return 'Download/' + this.folderName + '/';
  }

  fullPath(): string {
    return this.currentDir();
  }

  /** 探测目录是否真能建文件（v4.0.20 只拼路径不建目录，是「保存不能用」的根因之一） */
  private static probeWritable(dir: string): boolean {
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      const probe = dir + '.lx_probe';
      const file = fs.openSync(probe, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.closeSync(file);
      try {
        fs.unlinkSync(probe);
      } catch (e) {
        // 探针文件删不掉不影响写入能力
      }
      return true;
    } catch (e) {
      console.error('[DownloadPath] 目录不可写 ' + dir + ' ' + String(e));
      return false;
    }
  }

  private static lastSegment(dir: string): string {
    const clean = dir.endsWith('/') ? dir.substring(0, dir.length - 1) : dir;
    const index = clean.lastIndexOf('/');
    return index >= 0 ? clean.substring(index + 1) : clean;
  }
}

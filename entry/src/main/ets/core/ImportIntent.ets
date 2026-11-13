import { Want } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

/**
 * 外部「选择打开方式」传进来的音源脚本。
 *
 * 文件管理器点 .js → 选本应用 → 系统用 ohos.want.action.viewData 拉起
 * EntryAbility，want.uri 就是那个文件的 URI（file://…）。
 * Ability 阶段 UI 还没建起来，不能直接调 importCode（音源沙箱未就绪），
 * 所以这里只负责「收下 URI」，等 App.init() 完成后由 Index 取走导入。
 */
export class ImportIntent {
  private static queue: string[] = [];

  /** onCreate / onNewWant 都会调；热启动靠 AppStorage 版本号通知页面 */
  static pushFromWant(want: Want): void {
    const uris = ImportIntent.extract(want);
    if (uris.length === 0) {
      return;
    }
    for (const uri of uris) {
      if (ImportIntent.queue.indexOf(uri) < 0) {
        ImportIntent.queue.push(uri);
      }
    }
    try {
      const old = AppStorage.get<number>('importIntentVersion') ?? 0;
      AppStorage.setOrCreate('importIntentVersion', old + 1);
    } catch (e) {
      // 冷启动早期 ArkUI 状态可能还没建好，忽略即可：
      // Index.aboutToAppear 里 App.init() 完成后会主动 take() 一次。
      console.info('[LX] 外部导入信号暂缓，等待界面就绪');
    }
  }

  /** 取走并清空待导入队列 */
  static take(): string[] {
    const out = ImportIntent.queue;
    ImportIntent.queue = [];
    return out;
  }

  static pending(): number {
    return ImportIntent.queue.length;
  }

  /** 从 Want 里把可能的文件 URI 都翻出来：单文件、多文件列表、分享面板 */
  private static extract(want: Want): string[] {
    const out: string[] = [];
    if (typeof want.uri === 'string') {
      ImportIntent.addUri(out, want.uri as string);
    }
    const params = want.parameters;
    if (params !== undefined && params !== null) {
      const keys: string[] = [
        'ohos.want.params.uriList', 'uriList', 'ability.params.stream',
        'ohos.want.params.shareUri', 'stream', 'uri'
      ];
      for (const key of keys) {
        const value = params[key];
        if (typeof value === 'string') {
          ImportIntent.addUri(out, value as string);
        } else if (Array.isArray(value)) {
          const list: Object[] = value as Object[];
          for (const item of list) {
            if (typeof item === 'string') {
              ImportIntent.addUri(out, item as string);
            }
          }
        }
      }
    }
    return out;
  }

  private static addUri(out: string[], value: string): void {
    if (value.length === 0) {
      return;
    }
    if (value.startsWith('file://') || value.startsWith('content://') ||
      value.startsWith('datashare://') || value.startsWith('/')) {
      out.push(value);
    }
  }

  /**
   * 读文件。picker 返回的和文件管理器传来的都是 file:// URI，
   * fileIo.openSync 可以直接吃 URI（系统给了临时读权限）。
   */
  static readText(uri: string): string {
    const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      const stat = fs.statSync(file.fd);
      const size = stat.size;
      if (size <= 0) {
        return '';
      }
      const buffer = new ArrayBuffer(size);
      let offset = 0;
      while (offset < size) {
        const got = fs.readSync(file.fd, buffer, { offset: offset, length: size - offset });
        if (got <= 0) {
          break;
        }
        offset += got;
      }
      const decoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(new Uint8Array(buffer, 0, offset));
    } finally {
      fs.closeSync(file);
    }
  }

  /** URI 末段当文件名；去 query、解百分号编码 */
  static fileName(uri: string): string {
    let tail = uri;
    const q = tail.indexOf('?');
    if (q >= 0) {
      tail = tail.substring(0, q);
    }
    const slash = tail.lastIndexOf('/');
    if (slash >= 0) {
      tail = tail.substring(slash + 1);
    }
    let name = tail;
    try {
      name = decodeURIComponent(tail);
    } catch (e) {
      // 没有合法转义就保留原样
    }
    return name.length > 0 ? name : '外部音源.js';
  }

  /**
   * 二进制保护：注册了 application/octet-stream 后，.hap 之类的文件
   * 也可能被系统列到我们的打开方式里，别把二进制当脚本导进去。
   */
  static looksLikeScript(text: string): boolean {
    if (text.length < 100) {
      return false;
    }
    const scan = text.substring(0, 2000);
    let bad = 0;
    for (let i = 0; i < scan.length; i++) {
      const code = scan.charCodeAt(i);
      if (code < 32 && code !== 10 && code !== 13 && code !== 9) {
        bad++;
      }
      if (code === 0) {
        return false;
      }
    }
    return bad < scan.length * 0.02;
  }
}

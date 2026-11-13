import { webview } from '@kit.ArkWeb';
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LxInvokeInfo } from '../common/Models';
import { cookieDomain } from '../common/Utils';
import { absoluteUrl } from './Http';

/** 脚本 inited 上报的平台 */
export interface LxPlatformInfo {
  id: string;
  name: string;
  qualitys: string[];
  actions: string[];
}

export interface LxInitedInfo {
  status: boolean;
  platforms: LxPlatformInfo[];
  error: string;
}

interface InitedPlatformRaw {
  name?: string;
  qualitys?: string[];
  actions?: string[];
}

interface InitedDataRaw {
  status?: boolean;
  sources?: Record<string, InitedPlatformRaw>;
}

interface NativeMessage {
  type: string;
  inst?: string;
  id?: string;
  url?: string;
  options?: LxHttpOptions;
  data?: Object;
  dataText?: string;
  error?: string;
  text?: string;
  event?: string;
  ok?: boolean;
  name?: string;
  version?: string;
  updateUrl?: string;
  kind?: string;
}

interface LxHttpOptions {
  method?: string;
  headers?: Record<string, string>;
  body?: string | Object;
  form?: string | Object;
  formData?: Object;
  timeout?: number;
  responseType?: string;
  binary?: boolean;
  /** 音源指定允许的最大重定向次数（官方源常见 follow_max: 5） */
  follow_max?: number;
}

interface HttpPayload {
  ok: boolean;
  status: number;
  data: string;
  error: string;
  headers: Record<string, string>;
  /** 响应体是 base64 编码的二进制，桥接层会还原成 Uint8Array */
  binary?: boolean;
}

interface PendingCall {
  resolve: (value: string) => void;
  reject: (reason: Error) => void;
  timer: number;
}

interface LoadWaiter {
  resolve: () => void;
  reject: (reason: Error) => void;
  timer: number;
}

/**
 * 原生桥：注入为 window.lxNative，脚本沙箱通过它回调 ArkTS。
 */
export class LxNativeBridge {
  private handler: (message: string) => void;

  constructor(handler: (message: string) => void) {
    this.handler = handler;
  }

  call(message: string): void {
    this.handler(message);
  }
}

/**
 * 音源运行时：一个隐藏的 ArkWeb 页面里同时驻留多个洛雪脚本实例。
 *
 * 为什么要多实例：
 *  - 切换音源不再重新执行脚本（重载一次要 0.3~2s，取链回退时体验很差）
 *  - 可以按「启用顺序」并发尝试多个音源
 *  - 音源自检可以一次跑完，而不是逐个串行
 */
export class LxRunner {
  private controller: webview.WebviewController | null = null;
  private ready: boolean = false;
  private pending: Map<string, PendingCall> = new Map<string, PendingCall>();
  private loadWaiters: Map<string, LoadWaiter> = new Map<string, LoadWaiter>();
  private seq: number = 0;
  private cookies: Map<string, string> = new Map<string, string>();
  private loaded: Set<string> = new Set<string>();
  /** 脚本执行完成的时刻：用于「inited 迟迟不来」时按宽限期放行 */
  private loadedAt: Map<string, number> = new Map<string, number>();
  /**
   * 已上报 inited 的实例。
   *
   * 这是洛雪协议的硬门禁：脚本执行完（loaded）只代表语法没错，
   * 真正能不能取链要等它把平台、音质、可用动作 `lx.send('inited', …)` 回来。
   * 「独家音源」这类要先请求 rconfig 拿到签名配置、再注册 handler 的脚本，
   * loaded 和 inited 之间隔着 2~8 秒；此时调 request 只会拿到
   * 「未注册 request 处理器」，白白耗掉一次取链并把它记成失败。
   */
  private inited: Set<string> = new Set<string>();
  private initedWaiters: Map<string, Array<(ok: boolean) => void>> = new Map<string, Array<(ok: boolean) => void>>();
  /** 执行失败的实例：即便 load() 晚于错误回调返回，也不能再被标记为可用 */
  private failed: Set<string> = new Set<string>();
  /** 当前默认实例（脚本里 window.lx 指向它，兼容少数直接读 window.lx 的脚本） */
  private activeInst: string = '';

  onInited: ((instId: string, info: LxInitedInfo) => void) | null = null;
  onLog: ((instId: string, text: string) => void) | null = null;
  onLoaded: ((instId: string, name: string, version: string, updateUrl: string, kind: string) => void) | null = null;
  onScriptError: ((instId: string, error: string) => void) | null = null;

  attach(controller: webview.WebviewController): void {
    this.controller = controller;
  }

  markReady(): void {
    this.ready = true;
    const waiters: LoadWaiter[] = [];
    this.loadWaiters.forEach((item: LoadWaiter) => {
      waiters.push(item);
    });
    this.loadWaiters.clear();
    for (const waiter of waiters) {
      clearTimeout(waiter.timer);
      waiter.resolve();
    }
  }

  isReady(): boolean {
    return this.ready;
  }

  isLoaded(instId: string): boolean {
    return this.loaded.has(instId);
  }

  /** 脚本是否已经上报 inited（平台/音质都已知，才谈得上取链） */
  isInited(instId: string): boolean {
    return this.inited.has(instId);
  }

  /** 脚本执行完成到现在过了多久（毫秒）；没加载过返回 -1 */
  loadedAgo(instId: string): number {
    const at = this.loadedAt.get(instId);
    if (at === undefined) {
      return -1;
    }
    return Date.now() - at;
  }

  /** 等某个实例上报 inited；超时返回 false（不抛错，交给调用方决定怎么提示） */
  waitInited(instId: string, timeoutMs: number): Promise<boolean> {
    if (this.inited.has(instId)) {
      return Promise.resolve(true);
    }
    if (!this.loaded.has(instId)) {
      return Promise.resolve(false);
    }
    return new Promise<boolean>((resolve) => {
      let done = false;
      const timer = setTimeout(() => {
        if (done) {
          return;
        }
        done = true;
        const list = this.initedWaiters.get(instId);
        if (list !== undefined) {
          this.initedWaiters.set(instId, list.filter((fn: (ok: boolean) => void): boolean => fn !== handler));
        }
        resolve(false);
      }, timeoutMs);
      const handler = (ok: boolean): void => {
        if (done) {
          return;
        }
        done = true;
        clearTimeout(timer);
        resolve(ok);
      };
      const list = this.initedWaiters.get(instId) ?? [];
      list.push(handler);
      this.initedWaiters.set(instId, list);
    });
  }

  private notifyInited(instId: string, ok: boolean): void {
    if (ok) {
      this.inited.add(instId);
    } else {
      this.inited.delete(instId);
    }
    const list = this.initedWaiters.get(instId);
    if (list === undefined) {
      return;
    }
    this.initedWaiters.delete(instId);
    for (const fn of list) {
      fn(ok);
    }
  }

  /**
   * 载入脚本。返回时脚本已同步执行完（inited 可能稍后才到，由 onInited 回调）。
   * kind：'lx' = 洛雪脚本（默认）、'musicfree' = MusicFree CommonJS 插件。
   * 桥接页也带自动识别兜底，这里显式传递是为了让导入时的判定成为唯一事实来源。
   */
  async load(instId: string, code: string, kind: string = 'lx'): Promise<void> {
    const ctrl = this.controller;
    if (ctrl === null) {
      throw new Error('音源运行环境尚未就绪');
    }
    if (!this.ready) {
      await this.waitReady(8000);
    }
    // 先卸载旧实例，避免 handlers 叠加
    this.loaded.delete(instId);
    this.failed.delete(instId);
    this.inited.delete(instId);
    this.loadedAt.delete(instId);
    const js = 'window.__load(' + JSON.stringify(instId) + ',' + JSON.stringify(code) + ',' +
      JSON.stringify(kind) + ')';
    try {
      await ctrl.runJavaScript(js);
    } catch (e) {
      throw new Error('音源脚本注入失败');
    }
    // 桥接页执行失败时会回传 type:'error'，此时不能把实例标记为可用。
    // activeInst 只在还没设置时取首个成功实例，不能每次 load 都覆盖——
    // 否则用户在音源页选的「首选」会被最后一个被加载的脚本顶掉。
    if (!this.failed.has(instId)) {
      this.loaded.add(instId);
      this.loadedAt.set(instId, Date.now());
      if (this.activeInst.length === 0) {
        this.activeInst = instId;
      }
    }
  }

  /**
   * 整页重置：清空页内所有实例与在途请求，回到「刚打开桥接页」的状态。
   *
   * 这是「单上下文 + 按需重建」里能安全先落地的一半：
   * 不对并发取链做重构，只提供「把沙箱擦干净再重新注入」的能力，
   * 用来修复脚本卡死 / handler 丢失 / 全局变量互相污染，
   * 此前这些情况只能靠杀进程重启 App。
   */
  async resetSandbox(): Promise<void> {
    const ctrl = this.controller;
    this.pending.forEach((call: PendingCall) => {
      clearTimeout(call.timer);
      call.reject(new Error('音源沙箱已重置'));
    });
    this.pending.clear();
    this.loaded.clear();
    this.inited.clear();
    this.loadedAt.clear();
    this.failed.clear();
    if (ctrl === null) {
      return;
    }
    try {
      await ctrl.runJavaScript('window.__reset()');
    } catch (e) {
      // 页面已销毁时忽略
    }
  }

  async unload(instId: string): Promise<void> {
    const ctrl = this.controller;
    this.loaded.delete(instId);
    this.inited.delete(instId);
    this.loadedAt.delete(instId);
    if (ctrl === null) {
      return;
    }
    try {
      await ctrl.runJavaScript('window.__unload(' + JSON.stringify(instId) + ')');
    } catch (e) {
      // 页面已销毁时忽略
    }
  }

  /**
   * 设置默认实例：把桥接页里的 window.lx / globalThis.lx 指回用户选的「首选」。
   * 桥接页的 window.lx 是全局单值，__load 每载入一个脚本就会覆盖一次；
   * 不纠正的话，脚本在异步回调里读 globalThis.lx 会读到别的音源实例（潜在串源）。
   */
  setActive(instId: string): void {
    if (instId.length === 0) {
      return;
    }
    this.activeInst = instId;
    const ctrl = this.controller;
    if (ctrl === null || !this.ready) {
      return;
    }
    ctrl.runJavaScript('window.__setActive(' + JSON.stringify(instId) + ')').catch(() => {
    });
  }

  getActive(): string {
    return this.activeInst;
  }

  private waitReady(timeoutMs: number): Promise<void> {
    if (this.ready) {
      return Promise.resolve();
    }
    return new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.loadWaiters.delete('__ready__');
        reject(new Error('音源沙箱启动超时'));
      }, timeoutMs);
      this.loadWaiters.set('__ready__', {
        resolve: () => {
          clearTimeout(timer);
          resolve();
        },
        reject: (err: Error) => {
          clearTimeout(timer);
          reject(err);
        },
        timer: timer
      });
    });
  }

  /**
   * 调用脚本的 request 处理器。
   * @param timeoutMs 超时，默认 20s；取链建议 18s，歌词 10s。
   */
  invoke(instId: string, action: string, info: LxInvokeInfo, timeoutMs: number = 20000): Promise<string> {
    const ctrl = this.controller;
    if (ctrl === null || !this.loaded.has(instId)) {
      return Promise.reject(new Error('音源未加载'));
    }
    const id = 'q' + (++this.seq).toString();
    const args = JSON.stringify({ source: info.source ?? '', action: action, info: info });
    const js = 'window.__emit(' + JSON.stringify(instId) + ',' + JSON.stringify(action) + ',' +
      JSON.stringify(id) + ',' + JSON.stringify(args) + ')';
    return new Promise<string>((resolve, reject) => {
      const timer = setTimeout(() => {
        const call = this.pending.get(id);
        if (call !== undefined) {
          this.pending.delete(id);
          call.reject(new Error('音源响应超时'));
        }
      }, timeoutMs);
      this.pending.set(id, { resolve: resolve, reject: reject, timer: timer });
      ctrl.runJavaScript(js).catch(() => {
        const call = this.pending.get(id);
        if (call !== undefined) {
          clearTimeout(call.timer);
          this.pending.delete(id);
          call.reject(new Error('音源调用失败'));
        }
      });
    });
  }

  /** 处理沙箱消息 */
  handleMessage(raw: string): void {
    let msg: NativeMessage;
    try {
      msg = JSON.parse(raw) as NativeMessage;
    } catch (e) {
      return;
    }
    const inst = msg.inst ?? '';
    switch (msg.type) {
      case 'ready':
        this.markReady();
        break;
      case 'loaded':
        this.failed.delete(inst);
        this.loaded.add(inst);
        if (this.onLoaded !== null) {
          this.onLoaded(inst, msg.name ?? '', msg.version ?? '', msg.updateUrl ?? '', msg.kind ?? 'lx');
        }
        break;
      case 'inited':
        this.handleInited(inst, msg.data);
        break;
      case 'log':
        if (this.onLog !== null) {
          this.onLog(inst, msg.text ?? '');
        }
        break;
      case 'error':
        this.loaded.delete(inst);
        this.failed.add(inst);
        this.notifyInited(inst, false);
        if (this.onScriptError !== null) {
          this.onScriptError(inst, msg.error ?? '音源运行错误');
        }
        break;
      case 'http':
        this.doHttp(msg);
        break;
      case 'result':
        this.handleResult(msg);
        break;
      case 'event':
        // updateAlert / showConfigView 等：音源发来的更新提示。当前不弹窗，
        // 转成日志，避免 send() 的自定义事件被静默丢弃。
        if (msg.event === 'updateAlert' && this.onLog !== null) {
          const data = msg.data as Record<string, Object> | undefined;
          const text = data !== undefined && data['log'] !== undefined ?
            String(data['log']) : '音源发布了更新提示';
          this.onLog(inst, '[音源更新] ' + text);
        }
        break;
      default:
        break;
    }
  }

  private handleInited(inst: string, data: Object | undefined): void {
    const info: LxInitedInfo = { status: false, platforms: [], error: '' };
    if (data === undefined || data === null) {
      this.notifyInited(inst, false);
      if (this.onInited !== null) {
        this.onInited(inst, info);
      }
      return;
    }
    try {
      const raw = data as InitedDataRaw;
      info.status = raw.status !== false;
      const sources = raw.sources;
      if (sources !== undefined && sources !== null) {
        const keys = Object.keys(sources);
        for (const key of keys) {
          const item = sources[key];
          const platform: LxPlatformInfo = {
            id: key,
            name: item.name !== undefined && item.name.length > 0 ? item.name : key,
            qualitys: [],
            actions: []
          };
          if (item.qualitys !== undefined) {
            for (const q of item.qualitys) {
              platform.qualitys.push(q);
            }
          }
          if (item.actions !== undefined) {
            for (const action of item.actions) {
              platform.actions.push(action);
            }
          }
          info.platforms.push(platform);
        }
      }
    } catch (e) {
      info.error = '音源信息解析失败';
    }
    // status=false 或一个平台都没报，说明它自己判断初始化失败 —— 同样不许取链
    this.notifyInited(inst, info.status && info.platforms.length > 0);
    if (this.onInited !== null) {
      this.onInited(inst, info);
    }
  }

  private handleResult(msg: NativeMessage): void {
    const id = msg.id ?? '';
    const call = this.pending.get(id);
    if (call === undefined) {
      return;
    }
    clearTimeout(call.timer);
    this.pending.delete(id);
    if (msg.ok === true) {
      call.resolve(msg.dataText ?? '{}');
    } else {
      call.reject(new Error(msg.error ?? '音源返回错误'));
    }
  }

  /* ---------------- HTTP 代理 ---------------- */
  /**
   * 脚本里的 request() 由这里代理到原生网络库。
   *
   * 与洛雪官方宿主对齐的三点（此前缺失，是「同样的脚本安卓能用、我们报错」的主因）：
   *  1) 默认 User-Agent：官方每个请求都带 `lx-music-mobile/${version}`。20 个音源里
   *     有 8 个完全不设 UA，靠宿主兜底；我们之前不补，等于让它们空 UA 裸奔，
   *     聚合接口直接 403 / 404。音源显式给了 UA 时仍以它的为准。
   *  2) 完整 method：官方支持 GET/POST/PUT/DELETE/HEAD/OPTIONS…，我们原先只认
   *     GET/POST/PUT，其余静默退化成 GET。
   *  3) 二进制响应：responseType:'arraybuffer' / binary:true 时按 ARRAY_BUFFER 取，
   *     base64 回传，桥接层还原成 Uint8Array。此前固定 STRING，这类脚本拿不到数据。
   */
  private doHttp(msg: NativeMessage): void {
    const id = msg.id ?? '';
    const inst = msg.inst ?? '';
    const url = msg.url ?? '';
    const opts: LxHttpOptions = msg.options ?? {};
    const client = http.createHttp();
    const method = (opts.method ?? 'GET').toUpperCase();
    const headers: Record<string, string> = {};
    if (opts.headers !== undefined) {
      const keys = Object.keys(opts.headers);
      for (const key of keys) {
        headers[key] = opts.headers[key];
      }
    }
    // 音源没写 UA 时补官方同款，避免被聚合接口当成裸请求拒绝
    let hasUa = false;
    let hasAccept = false;
    const headerKeys = Object.keys(headers);
    for (const key of headerKeys) {
      const lower = key.toLowerCase();
      if (lower === 'user-agent') {
        hasUa = true;
      } else if (lower === 'accept') {
        hasAccept = true;
      }
    }
    if (!hasUa) {
      headers['User-Agent'] = 'lx-music-mobile/1.7.0';
    }
    if (!hasAccept) {
      headers['Accept'] = '*/*';
    }
    // HarmonyOS 的 RequestMethod 没有 PATCH，用 POST + 覆盖头兼容
    if (method === 'PATCH') {
      headers['X-HTTP-Method-Override'] = 'PATCH';
    }
    const wantBinary = opts.binary === true ||
      String(opts.responseType ?? '').toLowerCase() === 'arraybuffer';
    // 简单 cookie jar：很多平台（酷我/QQ）要求带着首次响应的 cookie
    const domain = cookieDomain(url);
    const jar = this.cookies.get(domain);
    if (jar !== undefined && headers['Cookie'] === undefined && headers['cookie'] === undefined) {
      headers['Cookie'] = jar;
    }
    let body = '';
    if (typeof opts.body === 'string') {
      body = opts.body;
    } else if (opts.body !== undefined) {
      try {
        body = JSON.stringify(opts.body);
      } catch (e) {
        body = '';
      }
    }
    if (body.length === 0 && opts.form !== undefined) {
      body = LxRunner.toForm(opts.form);
      if (headers['Content-Type'] === undefined) {
        headers['Content-Type'] = 'application/x-www-form-urlencoded';
      }
    }
    const options: http.HttpRequestOptions = {
      method: LxRunner.requestMethod(method),
      header: headers,
      extraData: body,
      expectDataType: wantBinary ? http.HttpDataType.ARRAY_BUFFER : http.HttpDataType.STRING,
      usingCache: false,
      connectTimeout: 12000,
      readTimeout: opts.timeout !== undefined && opts.timeout > 0 ? Math.min(opts.timeout, 30000) : 20000
    };
    // 脚本里的 request 往往直接命中 http 地址，接口会 301 到 https；
    // 不跟随就会把一段 html 当成接口返回，脚本当场解析失败。
    // follow_max 由音源指定（官方源多为 5），不指定时沿用 4 次。
    const maxHop = opts.follow_max !== undefined && opts.follow_max > 0 ?
      Math.min(opts.follow_max, 10) : 4;
    const send = (target: string, hop: number): void => {
      client.request(target, options, (err: BusinessError, data: http.HttpResponse) => {
        if (!err && data.responseCode >= 300 && data.responseCode < 400) {
          const header = LxRunner.normalizeHeaders(data.header as Record<string, Object>);
          const location = header['location'] ?? '';
          client.destroy();
          if (location.length > 0 && hop < maxHop) {
            send(absoluteUrl(target, location), hop + 1);
            return;
          }
        }
        const payload: HttpPayload = { ok: false, status: 0, data: '', error: '', headers: {} };
        if (err) {
          payload.error = err.message ?? '网络请求失败';
        } else {
          payload.ok = true;
          payload.status = data.responseCode;
          if (wantBinary && typeof data.result !== 'string') {
            try {
              payload.data = LxRunner.toBase64(new Uint8Array(data.result as ArrayBuffer));
              payload.binary = true;
            } catch (encErr) {
              payload.data = '';
            }
          } else {
            payload.data = typeof data.result === 'string' ? data.result : String(data.result ?? '');
          }
          payload.headers = LxRunner.normalizeHeaders(data.header as Record<string, Object>);
          this.saveCookies(domain, payload.headers);
        }
        this.resolveHttp(inst, id, JSON.stringify(payload));
        client.destroy();
      });
    };
    send(url, 0);
  }

  /** 官方 request 的 method 全集；PATCH 已在 doHttp 里转成 POST + 覆盖头 */
  private static requestMethod(method: string): http.RequestMethod {
    switch (method) {
      case 'POST':
      case 'PATCH':
        return http.RequestMethod.POST;
      case 'PUT':
        return http.RequestMethod.PUT;
      case 'DELETE':
        return http.RequestMethod.DELETE;
      case 'HEAD':
        return http.RequestMethod.HEAD;
      case 'OPTIONS':
        return http.RequestMethod.OPTIONS;
      case 'TRACE':
        return http.RequestMethod.TRACE;
      case 'CONNECT':
        return http.RequestMethod.CONNECT;
      default:
        return http.RequestMethod.GET;
    }
  }

  /** ArrayBuffer → base64（不引三方库，跨 WebView 边界只能传字符串） */
  private static toBase64(bytes: Uint8Array): string {
    const table = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    let out = '';
    for (let i = 0; i < bytes.length; i += 3) {
      const a = bytes[i];
      const b = i + 1 < bytes.length ? bytes[i + 1] : 0;
      const c = i + 2 < bytes.length ? bytes[i + 2] : 0;
      const n = (a << 16) | (b << 8) | c;
      out += table.charAt((n >>> 18) & 63) + table.charAt((n >>> 12) & 63);
      out += i + 1 < bytes.length ? table.charAt((n >>> 6) & 63) : '=';
      out += i + 2 < bytes.length ? table.charAt(n & 63) : '=';
    }
    return out;
  }

  private static toForm(value: string | Object): string {
    if (typeof value === 'string') {
      return value;
    }
    const parts: string[] = [];
    const rec = value as Record<string, Object>;
    const keys = Object.keys(rec);
    for (const key of keys) {
      parts.push(encodeURIComponent(key) + '=' + encodeURIComponent(String(rec[key])));
    }
    return parts.join('&');
  }

  private static normalizeHeaders(header: Record<string, Object>): Record<string, string> {
    const out: Record<string, string> = {};
    const keys = Object.keys(header);
    for (const key of keys) {
      const value = header[key];
      if (typeof value === 'string') {
        out[key.toLowerCase()] = value;
      } else if (Array.isArray(value)) {
        const list: string[] = [];
        for (const item of value as Object[]) {
          list.push(String(item));
        }
        out[key.toLowerCase()] = list.join('; ');
      }
    }
    return out;
  }

  private saveCookies(domain: string, headers: Record<string, string>): void {
    const raw = headers['set-cookie'];
    if (raw === undefined || raw.length === 0) {
      return;
    }
    const parts = raw.split(/,(?=\s*[A-Za-z0-9_\-]+=)/);
    const list: string[] = [];
    for (const part of parts) {
      const pair = part.split(';')[0].trim();
      if (pair.length > 0) {
        list.push(pair);
      }
    }
    if (list.length === 0) {
      return;
    }
    const existing = this.cookies.get(domain);
    const merged = existing !== undefined && existing.length > 0 ? existing + '; ' + list.join('; ') : list.join('; ');
    this.cookies.set(domain, merged);
  }

  private resolveHttp(inst: string, id: string, payload: string): void {
    const ctrl = this.controller;
    if (ctrl === null) {
      return;
    }
    const js = 'window.__httpResolve(' + JSON.stringify(inst) + ',' + JSON.stringify(id) + ',' +
      JSON.stringify(payload) + ')';
    ctrl.runJavaScript(js).catch(() => {
    });
  }

  /** 取消某个实例的所有挂起调用（删除音源时避免悬挂） */
  cancelAll(instId: string): void {
    this.pending.forEach((call: PendingCall, key: string) => {
      clearTimeout(call.timer);
      call.reject(new Error('音源已卸载'));
    });
    this.pending.clear();
    this.loaded.delete(instId);
    this.inited.delete(instId);
    this.loadedAt.delete(instId);
  }
}

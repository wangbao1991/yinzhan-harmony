import { Store } from './Store';
import { PrefKeys } from '../common/Constants';
import { wyPost, normalizeCookie, cookieValue } from './WyApi';

/** 扫码轮询的一次结果 */
export interface WyQrState {
  /** 801 等待扫码 / 802 已扫码待确认 / 803 授权成功 / 800 过期 / 8821 风控 / -1 网络错 */
  code: number;
  message: string;
  nickname: string;
  /** 803 时是否已成功落盘凭证 */
  loggedIn: boolean;
}

/**
 * 网易云账号登录态（单例）。
 *
 * 凭证只存本机 Store（yinzhan_v1 preferences），不上传、不写进备份。
 * 登录态变化广播 AppStorage：wyLoginVersion / wyNick，
 * 供设置页入口、账号页响应式刷新（与 discoverPlatform 同一范式）。
 */
export class WyAccount {
  private static instance: WyAccount = new WyAccount();

  static get(): WyAccount {
    return WyAccount.instance;
  }

  private ready: boolean = false;
  private cookieText: string = '';
  private nickText: string = '';
  private uidNum: number = 0;
  private avatarText: string = '';
  private versionNum: number = 0;

  /**
   * App.init 里 Store 就绪后调用一次；重复调用只广播不重读。
   * 就绪守卫不能省：onForeground 的心跳可能早于 App.init 触发登录态读取，
   * 那时若把「空凭证」连同 ready=true 一起锁存，之后就再也不会重读，
   * 表现为每次重启都要重新粘 Cookie。
   */
  init(): void {
    if (!this.ready && Store.get().isReady()) {
      this.ready = true;
      const s = Store.get();
      this.cookieText = s.getString(PrefKeys.WY_COOKIE, '');
      this.nickText = s.getString(PrefKeys.WY_NICK, '');
      const uid = Number.parseInt(s.getString(PrefKeys.WY_UID, '0'));
      this.uidNum = Number.isNaN(uid) ? 0 : uid;
      this.avatarText = s.getString(PrefKeys.WY_AVATAR, '');
    }
    this.broadcast();
  }

  private broadcast(): void {
    AppStorage.setOrCreate('wyLoginVersion', this.versionNum);
    AppStorage.setOrCreate('wyNick', this.nickText);
  }

  isLoggedIn(): boolean {
    this.init();
    return this.cookieText.length > 0;
  }

  cookie(): string {
    this.init();
    return this.cookieText;
  }

  nick(): string {
    this.init();
    return this.nickText;
  }

  uid(): number {
    this.init();
    return this.uidNum;
  }

  avatar(): string {
    this.init();
    return this.avatarText;
  }

  version(): number {
    this.init();
    return this.versionNum;
  }

  /** 第 1 步：取二维码 unikey。二维码内容 = https://music.163.com/login?codekey=<unikey> */
  async qrKey(): Promise<string> {
    const data: Record<string, Object> = { 'type': 1 };
    const reply = await wyPost('/weapi/login/qrcode/unikey', data, '');
    if (!reply.ok) {
      return '';
    }
    try {
      const obj = JSON.parse(reply.body) as Record<string, Object>;
      const key = obj['unikey'];
      return typeof key === 'string' ? key : '';
    } catch (e) {
      return '';
    }
  }

  /** 第 2 步：轮询扫码状态。803 时从 set-cookie 提取 MUSIC_U/__csrf 落盘并拉用户信息 */
  async qrCheck(key: string): Promise<WyQrState> {
    const data: Record<string, Object> = { 'key': key, 'type': 1 };
    const reply = await wyPost('/weapi/login/qrcode/client/login', data, '');
    if (!reply.ok) {
      return { code: -1, message: reply.error.length > 0 ? reply.error : '网络请求失败', nickname: '', loggedIn: false };
    }
    let code = -1;
    let message = '';
    let nickname = '';
    try {
      const obj = JSON.parse(reply.body) as Record<string, Object>;
      const c = obj['code'];
      code = typeof c === 'number' ? c : -1;
      const m = obj['message'];
      message = typeof m === 'string' ? m : '';
      const n = obj['nickname'];
      nickname = typeof n === 'string' ? n : '';
    } catch (e) {
      return { code: -1, message: '响应解析失败', nickname: '', loggedIn: false };
    }

    if (code === 803) {
      const cookie = normalizeCookie(reply.setCookie);
      if (cookie.length === 0) {
        // 少数情况下凭证在响应体里以 cookie 字段回传，做一次兜底
        const fromBody = normalizeCookie(reply.body);
        if (fromBody.length === 0) {
          return { code: 803, message: '已确认，但没拿到登录凭证，请改用 Cookie 登录', nickname: nickname, loggedIn: false };
        }
        await this.adopt(fromBody);
      } else {
        await this.adopt(cookie);
      }
      return { code: 803, message: '登录成功', nickname: this.nickText, loggedIn: true };
    }
    return { code: code, message: message, nickname: nickname, loggedIn: false };
  }

  /** 手动 Cookie 登录：用户粘贴 MUSIC_U=... 或完整 Cookie 串 */
  async loginByCookie(raw: string): Promise<boolean> {
    const cookie = normalizeCookie(raw);
    if (cookie.length === 0) {
      return false;
    }
    return await this.adopt(cookie);
  }

  /** 落盘凭证并校验：查登录态拿昵称 / uid，成功才算登录 */
  private async adopt(cookie: string): Promise<boolean> {
    const data: Record<string, Object> = {};
    const reply = await wyPost('/weapi/w/nuser/account/get', data, cookie);
    if (!reply.ok) {
      return false;
    }
    let nick = '';
    let uid = 0;
    let avatar = '';
    try {
      const obj = JSON.parse(reply.body) as Record<string, Object>;
      const profile = obj['profile'] as Record<string, Object>;
      if (profile !== null && profile !== undefined) {
        const n = profile['nickname'];
        nick = typeof n === 'string' ? n : '';
        const u = profile['userId'];
        uid = typeof u === 'number' ? u : 0;
        const a = profile['avatarUrl'];
        avatar = typeof a === 'string' ? a : '';
      }
    } catch (e) {
      // 拿不到 profile 也允许以 Cookie 身份继续（推荐接口仍可用）
    }
    // account/get 匿名时回 account:null，此时拦截，避免把无效 Cookie 存成「已登录」
    if (uid === 0 && nick.length === 0 && cookieValue(cookie, 'MUSIC_U').length === 0) {
      return false;
    }
    this.cookieText = cookie;
    this.nickText = nick.length > 0 ? nick : '网易云用户';
    this.uidNum = uid;
    this.avatarText = avatar;
    const s = Store.get();
    s.put(PrefKeys.WY_COOKIE, cookie);
    s.put(PrefKeys.WY_NICK, this.nickText);
    s.put(PrefKeys.WY_UID, uid.toString());
    s.put(PrefKeys.WY_AVATAR, avatar);
    this.versionNum += 1;
    this.broadcast();
    return true;
  }

  /** 主动刷新一次登录态，Cookie 失效时返回 false（页面可提示重新登录） */
  async verify(): Promise<boolean> {
    this.init();
    if (this.cookieText.length === 0) {
      return false;
    }
    const data: Record<string, Object> = {};
    const reply = await wyPost('/weapi/w/nuser/account/get', data, this.cookieText);
    if (!reply.ok) {
      return false;
    }
    try {
      const obj = JSON.parse(reply.body) as Record<string, Object>;
      const profile = obj['profile'];
      return profile !== null && profile !== undefined;
    } catch (e) {
      return false;
    }
  }

  logout(): void {
    this.init();
    this.cookieText = '';
    this.nickText = '';
    this.uidNum = 0;
    this.avatarText = '';
    const s = Store.get();
    s.delete(PrefKeys.WY_COOKIE);
    s.delete(PrefKeys.WY_NICK);
    s.delete(PrefKeys.WY_UID);
    s.delete(PrefKeys.WY_AVATAR);
    this.versionNum += 1;
    this.broadcast();
  }
}

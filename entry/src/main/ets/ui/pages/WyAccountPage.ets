import {
  palette, Palette, RADIUS, FONT, PAGE_PAD, FLOAT_SPACE,
  glassCardBase, glassSurface, glassEdgeWidth, glassEdgeColor, glassShadow
} from '../../common/Constants';
import { SheetInfo } from '../../common/Models';
import { App } from '../../core/App';
import { WyAccount } from '../../core/WyAccount';
import { WyRecommend } from '../../core/WyRecommend';
import { WyRecommendHub } from '../../core/WyRecommendHub';
import { WyFavSync } from '../../core/WyFavSync';
import { FavSyncHub } from '../../core/FavSyncHub';
import { ImmersiveBar, SectionHeader, GlassSheetCard } from '../Common';

/**
 * 网易云账号（二级页）。v2.64 新增。
 *
 * 未登录：二维码扫码（QRCode 组件渲染 login?codekey=，2s 轮询 801/802/803/800）
 * + 手动粘贴 MUSIC_U Cookie 兜底（风控 / 无 App 扫码时）。
 * 已登录：展示本人头像 / 昵称、歌单收藏同步状态与「我的歌单」。
 *
 * v2.72：每日推荐 / 推荐歌单搬到首页做实时分页轨（WyRecommendHub 唯一数据源），
 * 账号页不再重复一份，只留账号头 + 同步卡；登录成功仍预热一次 hub。
 * v2.73：按用户新口径把「我的歌单」恢复到本页 —— 单独拉 /weapi/user/playlist
 * 真实数据（WyRecommend.mySheets）横向展示，不造数、不写死；每日推荐 /
 * 推荐歌单仍只在首页。账号头新增登录后头像（profile.avatarUrl 登录时已落盘），
 * 加载失败回退人形占位。底层 WyAccount / WyRecommend 接口一行未改。
 *
 * 凭证只由 WyAccount 落本机 Store，本页不碰 Cookie 明文、不上传、不进备份。
 * 返回链与其它二级页一致：顶栏与系统返回都走 App.consumeBack(null)。
 * 轮询用 setTimeout 递归而非 setInterval，aboutToDisappear 一定清干净，
 * 避免页面销毁后异步回调还在改 @State。
 *
 * 玻璃卡样式按工程惯例内联（@Builder 不能传 () => void 再调用，ArkUI 不支持）。
 */
@Component
export struct WyAccountPage {
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;
  @StorageProp('topSafe') topSafe: number = 24;
  /** 登录 / 退出后由 WyAccount 广播，触发本页重读登录态并重载推荐 */
  @StorageProp('wyLoginVersion') @Watch('onLoginChange') loginVersion: number = 0;
  /** v2.65：歌单收藏同步状态，账号页展示进度与结果。
   *  注意本页已有一个 syncState() 方法（同步登录态到 UI），变量名必须避开它。 */
  @StorageProp('wyFavSyncState') favSyncState: string = 'idle';
  @StorageProp('wyFavSyncVersion') favSyncVersion: number = 0;

  @State loggedIn: boolean = false;
  @State nickName: string = '';
  @State userId: number = 0;
  /** v2.73：登录后头像 URL（account/get 的 profile.avatarUrl，落盘在 WY_AVATAR） */
  @State avatarUrl: string = '';
  /** 头像加载失败时回退人形占位，不显示破图 */
  @State avatarFailed: boolean = false;
  /** v2.73：账号页恢复的「我的歌单」，真实拉取，不写死 */
  @State mySheets: SheetInfo[] = [];

  @State qrUrl: string = '';
  @State qrKey: string = '';
  @State qrMessage: string = '';
  @State qrBusy: boolean = false;
  @State qrExpired: boolean = false;

  @State cookieInput: string = '';
  @State cookieHint: string = '';
  @State cookieBusy: boolean = false;

  /**
   * v1.0：账号体系收口为仅网易云，QQ / 酷狗账号登录与同步引擎已连根删除。
   * 已收藏的 tx / kg 歌单不受影响（只删账号代码，不动用户数据、不删音源平台）。
   * v2.72：推荐三块已隐藏，本页不再订阅 wyRecVersion，只保留登录后预热 hub。
   */

  private stopped: boolean = false;
  private polling: boolean = false;
  private pollTimer: number = -1;

  private p(): Palette {
    return palette(this.isDark);
  }

  aboutToAppear(): void {
    this.stopped = false;
    this.syncState();
    if (this.loggedIn) {
      // v2.72：本页不展示推荐，但进页时预热一次 hub，切回首页立刻有实时内容
      WyRecommendHub.get().refresh().catch(() => {
      });
      // v2.73：本页独有「我的歌单」，进页拉一次真实数据
      this.loadMySheets();
    } else {
      this.startQr();
    }
  }

  aboutToDisappear(): void {
    this.stopped = true;
    this.stopPoll();
  }

  onLoginChange(): void {
    const was = this.loggedIn;
    this.syncState();
    if (this.loggedIn) {
      this.stopPoll();
      this.cookieHint = '';
      // v2.72：登录成功预热 hub（首页板块订阅同一份数据），不再本页拉推荐
      WyRecommendHub.get().refresh().catch(() => {
      });
      // v2.73：登录成功后重拉本页「我的歌单」
      this.loadMySheets();
      // v2.65：登录成功立刻对账，把账号里收藏的歌单补进「歌单收藏」，
      // 并重放退出登录前攒下的待同步操作。
      WyFavSync.get().onLoginSuccess();
    } else {
      if (was) {
        // 只清同步中间态，本地收藏一个不删；下次登录会重新对齐。
        WyFavSync.get().onLogout();
        // v2.73：退出登录立刻清掉上一账号的「我的歌单」，绝不跨账号残留
        this.mySheets = [];
        // 退出登录后重新给一张可扫的码，不用手动点刷新
        this.startQr();
      }
    }
  }

  private syncState(): void {
    const account = WyAccount.get();
    this.loggedIn = account.isLoggedIn();
    this.nickName = account.nick();
    this.userId = account.uid();
    // v2.73：account/get 的 profile.avatarUrl 在 adopt() 里已落盘 WY_AVATAR，
    // 这里读出来显示。老头像可能是 http 明文，统一换成 https 避免被系统拦。
    this.avatarUrl = account.avatar().replace('http://', 'https://');
    this.avatarFailed = false;
  }

  /**
   * v2.73：账号页恢复「我的歌单」。真实拉 /weapi/user/playlist，不写死、
   * 不造数；页面销毁后异步回来的结果一律丢弃，不改已销毁的 @State。
   * 每日推荐 / 推荐歌单仍只在首页，本页不订阅 wyRecVersion。
   */
  private async loadMySheets(): Promise<void> {
    if (!WyAccount.get().isLoggedIn()) {
      this.mySheets = [];
      return;
    }
    const list = await WyRecommend.mySheets();
    if (this.stopped) {
      return;
    }
    this.mySheets = list;
  }

  /* ---------------- 二维码扫码 ---------------- */

  private async startQr(): Promise<void> {
    if (this.stopped || this.loggedIn) {
      return;
    }
    this.stopPoll();
    this.qrBusy = true;
    this.qrExpired = false;
    this.qrMessage = '正在获取二维码…';
    this.qrUrl = '';
    const key = await WyAccount.get().qrKey();
    if (this.stopped) {
      return;
    }
    this.qrBusy = false;
    if (key.length === 0) {
      this.qrMessage = '获取二维码失败，请检查网络后点「刷新二维码」';
      return;
    }
    this.qrKey = key;
    // 二维码内容就是官方登录链接，网易云 App 扫一扫直接识别
    this.qrUrl = 'https://music.163.com/login?codekey=' + key;
    this.qrMessage = '请用网易云音乐 App 扫一扫';
    this.polling = true;
    this.scheduleNext(1200);
  }

  private scheduleNext(delay: number): void {
    if (this.stopped || !this.polling) {
      return;
    }
    this.pollTimer = setTimeout(() => {
      this.checkOnce();
    }, delay);
  }

  private async checkOnce(): Promise<void> {
    if (this.stopped || !this.polling || this.qrKey.length === 0) {
      return;
    }
    const state = await WyAccount.get().qrCheck(this.qrKey);
    if (this.stopped || !this.polling) {
      return;
    }
    if (state.code === 803) {
      this.stopPoll();
      if (state.loggedIn) {
        this.syncState();
        // 803 取证成功会广播 wyLoginVersion，onLoginChange 负责预热 hub
      } else {
        this.qrMessage = state.message;
      }
      return;
    }
    if (state.code === 800) {
      this.stopPoll();
      this.qrExpired = true;
      this.qrMessage = '二维码已失效，点「刷新二维码」重新获取';
      return;
    }
    if (state.code === 8821) {
      this.stopPoll();
      this.qrMessage = '扫码被风控拦截，请改用下方 Cookie 登录';
      return;
    }
    if (state.code === 802) {
      this.qrMessage = '已扫码，请在手机上确认登录';
    } else if (state.code === 801) {
      this.qrMessage = '请用网易云音乐 App 扫一扫';
    } else if (state.code === -1) {
      // -1 同时代表网络超时 / 解析失败 / HTTP 非 2xx：显示真实原因，不再一律说「网络异常」
      const reason = state.message.length > 0 ? state.message : '暂时取不到扫码状态';
      this.qrMessage = reason + '，正在重试…（也可改用下方 Cookie 登录）';
    }
    this.scheduleNext(2000);
  }

  private stopPoll(): void {
    this.polling = false;
    if (this.pollTimer >= 0) {
      clearTimeout(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  /* ---------------- Cookie 手动登录 ---------------- */

  private async doCookieLogin(): Promise<void> {
    if (this.cookieBusy || this.cookieInput.trim().length === 0) {
      return;
    }
    this.cookieBusy = true;
    this.cookieHint = '正在校验 Cookie…';
    const ok = await WyAccount.get().loginByCookie(this.cookieInput);
    if (this.stopped) {
      return;
    }
    this.cookieBusy = false;
    if (ok) {
      this.cookieHint = '';
      this.cookieInput = '';
      this.stopPoll();
      this.syncState();
      // loginByCookie 会广播 wyLoginVersion，onLoginChange 负责预热 hub
    } else {
      this.cookieHint = '没识别到有效的 MUSIC_U，或账号校验失败，请重新复制';
    }
  }

  private doLogout(): void {
    this.stopPoll();
    // v2.65：先停同步再退出，避免退出瞬间还有写云端的请求在途。
    WyFavSync.get().onLogout();
    WyAccount.get().logout();
    // logout 会广播 wyLoginVersion，onLoginChange 负责清空推荐并重新出码
  }

  /* ---------------- 视图 ---------------- */

  @Builder
  accountHeader() {
    Column() {
      Row({ space: 12 }) {
        // v2.73：登录后显示真实头像（圆形），无头像 / 加载失败回退人形占位。
        // 底层占位先画，网络图叠在上面，图裂了直接露出占位，不显示破图。
        Stack() {
          SymbolGlyph($r('sys.symbol.person'))
            .fontSize(30)
            .fontColor([this.p().primary])
          if (this.avatarUrl.length > 0 && !this.avatarFailed) {
            Image(this.avatarUrl)
              .width(48)
              .height(48)
              .objectFit(ImageFit.Cover)
              .draggable(false)
              .onError(() => {
                this.avatarFailed = true;
              })
          }
        }
        .width(48)
        .height(48)
        .borderRadius(24)
        .backgroundColor(this.p().primarySoft)
        .clip(true)

        Column({ space: 3 }) {
          Text(this.nickName.length > 0 ? this.nickName : '网易云用户')
            .fontSize(FONT.body)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.p().text)
          Text(this.userId > 0 ? 'UID ' + this.userId.toString() : '已登录 · 推荐基于你的账号')
            .fontSize(FONT.micro)
            .fontColor(this.p().text3)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Button('退出登录')
          .fontSize(FONT.caption)
          .fontColor(this.p().text2)
          .backgroundColor(this.p().cardAlt)
          .borderRadius(RADIUS.pill)
          .height(32)
          .padding({ left: 12, right: 12 })
          .onClick(() => {
            this.doLogout();
          })
      }
      .width('100%')
      .padding(16)
    }
    .width('100%')
    .borderRadius(RADIUS.lg)
    .backgroundColor(glassCardBase(this.isDark))
    .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
    .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
    .shadow(glassShadow(this.isDark, this.lightLevel))
    .clip(true)
  }

  /** v2.67：文案统一由聚合层生成，网易云视图只看 wy 这一路，绝不自己拼 tail */
  private syncLabel(): string {
    return FavSyncHub.get().label('wy');
  }

  private doSync(): void {
    // 触发全部平台对账，但本页结论只报 wy 这一路（用户在这个 Tab 关心的是网易云）
    FavSyncHub.get().reconcileAllAwait().then(() => {
      App.get().toast(FavSyncHub.get().toastText('wy'));
    }).catch(() => {
    });
  }

  @Builder
  syncCard() {
    Column() {
      Row({ space: 12 }) {
        if (FavSyncHub.get().status('wy').syncing) {
          LoadingProgress().width(22).height(22).color(this.p().primary)
        } else {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(22)
            .fontColor([FavSyncHub.get().status('wy').clean ? this.p().primary : this.p().text3])
        }
        Column({ space: 3 }) {
          Text('歌单收藏同步')
            .fontSize(FONT.body)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.p().text)
          Text(this.syncLabel())
            .fontSize(FONT.micro)
            .fontColor(this.p().text3)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Button(FavSyncHub.get().status('wy').syncing ? '同步中' : '同步')
          .fontSize(FONT.caption)
          .fontColor(this.p().text)
          .backgroundColor(this.p().cardAlt)
          .borderRadius(RADIUS.pill)
          .height(32)
          .padding({ left: 14, right: 14 })
          .enabled(!FavSyncHub.get().status('wy').syncing)
          .onClick(() => {
            this.doSync();
          })
      }
      .width('100%')
      .padding(16)
    }
    .width('100%')
    .borderRadius(RADIUS.lg)
    .backgroundColor(glassCardBase(this.isDark))
    .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
    .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
    .shadow(glassShadow(this.isDark, this.lightLevel))
    .clip(true)
  }

  /** v2.73：账号页独有的「我的歌单」横向轨，复用公共卡片，来自真实接口 */
  @Builder
  mySheetRail() {
    Column({ space: 8 }) {
      SectionHeader({ title: '我的歌单', subtitle: this.mySheets.length.toString() + ' 个' })
      if (this.mySheets.length === 0) {
        Text('暂无歌单，或登录状态已过期，可退出后重新登录')
          .fontSize(FONT.caption)
          .fontColor(this.p().text3)
          .width('100%')
          .padding({ left: 4, top: 6, bottom: 6 })
      } else {
        Scroll() {
          Row({ space: 12 }) {
            ForEach(this.mySheets, (sheet: SheetInfo) => {
              GlassSheetCard({
                sheet: sheet,
                cardWidth: 132,
                titleLines: 2,
                onTap: (): void => {
                  App.get().openSheet(sheet);
                }
              })
            }, (sheet: SheetInfo) => 'acctMy_' + sheet.platform + '_' + sheet.id)
          }
          .padding({ left: 2, right: 2, bottom: 4 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
      }
    }
    .width('100%')
  }

  @Builder
  loggedView() {
    Column({ space: 16 }) {
      this.accountHeader()
      this.syncCard()
      this.mySheetRail()
      // v2.73：我的歌单回到本页；每日推荐 / 推荐歌单仍只在首页实时展示
      Text('每日推荐与推荐歌单已在首页实时展示，我的歌单来自你本人账号。凭证仅保存在本机；歌单收藏会自动与账号对齐，退出登录后仍留在本机。')
        .fontSize(FONT.micro)
        .fontColor(this.p().text3)
        .lineHeight(17)
        .width('100%')
        .padding({ left: 14, right: 14, top: 4 })
      Row().height(FLOAT_SPACE)
    }
    .width('100%')
  }

  @Builder
  introCard() {
    Column() {
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.person')).fontSize(18).fontColor([this.p().primary])
          Text('登录网易云账号').fontSize(FONT.body).fontWeight(FontWeight.Medium).fontColor(this.p().text)
        }
        Text('用本人账号登录后，可获取基于你听歌喜好的每日推荐、私人歌单。支持二维码扫码与 Cookie 两种方式；凭证只保存在本机，不上传、不写入备份，可随时退出清除。')
          .fontSize(FONT.caption)
          .fontColor(this.p().text2)
          .lineHeight(19)
          .width('100%')
      }
      .width('100%')
      .padding(16)
    }
    .width('100%')
    .borderRadius(RADIUS.lg)
    .backgroundColor(glassCardBase(this.isDark))
    .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
    .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
    .shadow(glassShadow(this.isDark, this.lightLevel))
    .clip(true)
  }

  @Builder
  qrCard() {
    Column() {
      Column({ space: 12 }) {
        Text('方式一 · 扫码登录')
          .fontSize(FONT.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.p().text)
          .width('100%')

        // 白底衬一张卡，深浅色下二维码都能被 App 识别
        Stack({ alignContent: Alignment.Center }) {
          if (this.qrUrl.length > 0) {
            QRCode(this.qrUrl)
              .width(196)
              .height(196)
              .color('#16181C')
              .backgroundColor('#FFFFFFFF')
          } else {
            LoadingProgress().width(30).height(30).color(this.p().primary)
          }
        }
        .width(216)
        .height(216)
        .borderRadius(RADIUS.md)
        .backgroundColor('#FFFFFFFF')
        .padding(10)

        Text(this.qrMessage)
          .fontSize(FONT.caption)
          .fontColor(this.qrExpired ? '#C96A5B' : this.p().text2)
          .textAlign(TextAlign.Center)
          .width('100%')

        Button(this.qrBusy ? '获取中…' : '刷新二维码')
          .fontSize(FONT.caption)
          .fontColor(this.p().text)
          .backgroundColor(this.p().cardAlt)
          .borderRadius(RADIUS.pill)
          .height(34)
          .width('100%')
          .enabled(!this.qrBusy)
          .onClick(() => {
            this.startQr();
          })
      }
      .width('100%')
      .padding(16)
    }
    .width('100%')
    .borderRadius(RADIUS.lg)
    .backgroundColor(glassCardBase(this.isDark))
    .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
    .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
    .shadow(glassShadow(this.isDark, this.lightLevel))
    .clip(true)
  }

  @Builder
  cookieCard() {
    Column() {
      Column({ space: 10 }) {
        Text('方式二 · Cookie 登录')
          .fontSize(FONT.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.p().text)
          .width('100%')
        Text('扫码被风控或没有 App 时用：电脑浏览器登录 music.163.com，F12 → 应用 → Cookies，复制 MUSIC_U 的值（或整段 Cookie）粘贴到下方。')
          .fontSize(FONT.micro)
          .fontColor(this.p().text3)
          .lineHeight(17)
          .width('100%')
        TextInput({ text: this.cookieInput, placeholder: 'MUSIC_U=... 或完整 Cookie' })
          .fontSize(FONT.caption)
          .fontColor(this.p().text)
          .placeholderColor(this.p().text3)
          .backgroundColor(this.p().cardAlt)
          .borderRadius(RADIUS.md)
          .height(44)
          .width('100%')
          .onChange((value: string) => {
            this.cookieInput = value;
          })
        if (this.cookieHint.length > 0) {
          Text(this.cookieHint)
            .fontSize(FONT.micro)
            .fontColor(this.p().text2)
            .width('100%')
        }
        Button(this.cookieBusy ? '校验中…' : '用 Cookie 登录')
          .fontSize(FONT.caption)
          // primary 是 signal 琥珀实底，其上文字只用 onSignal 墨字（7.57:1）
          .fontColor('#FF191713')
          .backgroundColor(this.p().primary)
          .borderRadius(RADIUS.pill)
          .height(38)
          .width('100%')
          .enabled(!this.cookieBusy && this.cookieInput.trim().length > 0)
          .onClick(() => {
            this.doCookieLogin();
          })
      }
      .width('100%')
      .padding(16)
    }
    .width('100%')
    .borderRadius(RADIUS.lg)
    .backgroundColor(glassCardBase(this.isDark))
    .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
    .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
    .shadow(glassShadow(this.isDark, this.lightLevel))
    .clip(true)
  }

  @Builder
  guestView() {
    Column({ space: 16 }) {
      this.introCard()
      this.qrCard()
      this.cookieCard()
      Row().height(FLOAT_SPACE)
    }
    .width('100%')
  }


  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Top }) {
        Scroll() {
          Column({ space: 16 }) {
            // v1.0：只保留网易云，不再有平台切换条与 QQ / 酷狗账号面板
            if (this.loggedIn) {
              this.loggedView()
            } else {
              this.guestView()
            }
          }
          .width('100%')
          .padding({ left: PAGE_PAD, right: PAGE_PAD, top: this.topSafe + 52 })
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .backgroundColor(this.p().bg)

        ImmersiveBar({
          title: '网易云账号',
          subtitle: this.loggedIn
            ? (this.nickName.length > 0 ? this.nickName : '已登录')
            : '登录以开启个性化推荐',
          onBack: (): void => {
            App.get().back(null);
          }
        })
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .onBackPressed(() => App.get().consumeBack(null))
  }
}

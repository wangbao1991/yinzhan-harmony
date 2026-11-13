import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { Player } from '../core/Player';
import { ImportIntent } from '../core/ImportIntent';
import { FavSyncHub } from '../core/FavSyncHub';
import { Store } from '../core/Store';

/** 浅色主题下的窗口底色（与页面一致，保证圆角/异形屏不露白） */
const WINDOW_BG_LIGHT: string = '#FFF1EFEA';
/** 深色主题下的窗口底色 */
const WINDOW_BG_DARK: string = '#FF0F1116';
/** 系统栏图标色：浅色主题用深色图标，深色主题用浅色图标 */
const SYSTEM_BAR_ICON_LIGHT: string = '#FF111116';
const SYSTEM_BAR_ICON_DARK: string = '#FFF5F6F9';

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | null = null;
  private isDark: boolean = false;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 主题模式：0 跟随系统 / 1 浅色 / 2 深色（与设置页共用同一份偏好）
    let mode: number = 0;
    // 首帧就用上用户的光感设置，避免启动时从默认值跳一下
    let light: number = 3;
    try {
      const store = preferences.getPreferencesSync(this.context, { name: 'yinzhan_v1' });
      // v2.56 存档修复：Store 在 Ability 创建这一刻就同步就绪。onForeground 的心跳
      // 会早于 App.init() 触发登录态读取，晚到这里就会把空凭证用 ready=true 锁死，
      // 用户每次重启都得重新粘 Cookie。此处装配的实例与 App.init 同名，同一份数据。
      Store.get().attach(store);
      mode = store.getSync('v4_theme_mode', 0) as number;
      light = store.getSync('v4_light_sense', 3) as number;
    } catch (e) {
      console.warn('[LX] 读取主题偏好失败: ' + String(e));
    }
    AppStorage.setOrCreate('lightSense', light);
    // v2.56：系统字体倍率写入全局，操作行 / 选择条据此决定要不要降级 2×2。
    // config.fontSizeScale 是可选字段，缺省按 1 处理（标准字号）。
    const scale: number | undefined = this.context.config.fontSizeScale;
    AppStorage.setOrCreate('fontScale', scale === undefined ? 1 : scale);
    const app = this.context.getApplicationContext();
    if (mode === 1) {
      app.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    } else if (mode === 2) {
      app.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    } else {
      app.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    }
    this.isDark = mode === 2 ||
      (mode === 0 && this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    AppStorage.setOrCreate('isDark', this.isDark);
    AppStorage.setOrCreate('themeMode', mode);
    console.info('[LX] EntryAbility onCreate, dark=' + this.isDark + ', mode=' + mode);
    // 文件管理器「选择打开方式」→ 冷启动：want.uri 带着 .js 文件进来
    ImportIntent.pushFromWant(want);
  }

  /**
   * 应用已在后台（singleton）时被文件管理器再次拉起，走的是 onNewWant。
   * 只收 URI，真正导入由页面在 UI 就绪后执行。
   */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    ImportIntent.pushFromWant(want);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        console.error('[LX] loadContent failed: ' + JSON.stringify(err));
      } else {
        console.info('[LX] loadContent succeeded');
      }
    });
    windowStage.getMainWindow().then((win: window.Window) => {
      this.mainWindow = win;
      this.applyImmersiveLayout(win);
    }).catch((err: BusinessError) => {
      console.error('[LX] 获取主窗口失败: ' + JSON.stringify(err));
    });
  }

  /**
   * 系统深浅色切换时，同步应用内 token 与窗口外观。
   */
  onConfigurationUpdate(newConfig: Configuration): void {
    // v2.56：字体倍率变化要先于深浅色早退处理，否则「只调字号」会被直接 return 吞掉
    const scale: number | undefined = newConfig.fontSizeScale;
    AppStorage.setOrCreate('fontScale', scale === undefined ? 1 : scale);
    const dark = newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    if (dark === this.isDark) {
      return;
    }
    this.isDark = dark;
    AppStorage.setOrCreate('isDark', dark);
    const win = this.mainWindow;
    if (win !== null) {
      this.applyImmersiveLayout(win);
    }
  }

  /**
   * 全面屏（沉浸式）布局：
   * 1. 内容延伸到状态栏和底部手势条之后，由页面按避让区自行留白；
   * 2. 系统栏透明，图标颜色随主题反转；
   * 3. 窗口背景与页面同色，避免异形屏/圆角处露白。
   */
  private applyImmersiveLayout(win: window.Window): void {
    win.setWindowLayoutFullScreen(true).catch((err: BusinessError) => {
      console.error('[LX] 设置全屏布局失败: ' + JSON.stringify(err));
    });
    try {
      win.setWindowBackgroundColor(this.isDark ? WINDOW_BG_DARK : WINDOW_BG_LIGHT);
    } catch (err) {
      console.warn('[LX] 设置窗口背景失败: ' + JSON.stringify(err));
    }
    const icon = this.isDark ? SYSTEM_BAR_ICON_DARK : SYSTEM_BAR_ICON_LIGHT;
    const properties: window.SystemBarProperties = {
      statusBarColor: '#00000000',
      statusBarContentColor: icon,
      navigationBarColor: '#00000000',
      navigationBarContentColor: icon
    };
    win.setWindowSystemBarProperties(properties).catch((err: BusinessError) => {
      console.warn('[LX] 设置系统栏样式失败: ' + JSON.stringify(err));
    });
  }

  onWindowStageDestroy(): void {
    console.info('[LX] EntryAbility onWindowStageDestroy');
  }

  onDestroy(): void {
    console.info('[LX] EntryAbility onDestroy');
    // 应用退出：停掉前台实时对账定时器，避免定时器残留
    FavSyncHub.get().stopForegroundSync();
    // 应用退出：停止播放，释放播控中心会话与音频长时任务
    Player.get().shutdown().catch(() => {
      console.error('[LX] 播放器释放失败');
    });
  }

  /**
   * 回到前台。首页是常驻页面，从后台切回来不会重建，也就不会自动重新拉数据；
   * 这里发一个时间戳，让首页自己判断推荐池是不是放了太久（跨天/超 6 小时）。
   *
   * v2.67：同时开启「歌单收藏 ↔ 平台账号」的前台实时对账。第三方平台不给
   * 第三方 App 推送，纯客户端能做到的准实时上限就是前台周期性拉云端列表：
   * 用户在平台 APP 里改了收藏，停在音栈里十几秒内也会自动跟上。
   */
  onForeground(): void {
    AppStorage.setOrCreate('foregroundAt', Date.now());
    FavSyncHub.get().startForegroundSync();
  }

  /** 退到后台：停掉定时对账，不空耗网络与电量 */
  onBackground(): void {
    FavSyncHub.get().stopForegroundSync();
  }
}

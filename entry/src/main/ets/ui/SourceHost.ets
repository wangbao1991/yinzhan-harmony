import { webview } from '@kit.ArkWeb';
import { App } from '../core/App';
import { LxNativeBridge } from '../core/LxRunner';

/**
 * 音源沙箱宿主。
 *
 * 洛雪脚本必须在 Web 环境里跑（要 window / document / atob 等），
 * 这里放一个 1x1 的隐藏 Web 页常驻在界面最底层：
 *  - 页面里的 lx_bridge.html 负责脚本沙箱、多实例、RSA 与 Buffer 兼容层
 *  - 原生侧把 window.lxNative 注册成 JS 代理，双向通信
 *  - 页面一加载完就把已启用的音源一次性灌进去，之后切源零等待
 *
 * 只渲染 1 像素，不能是 0：0 尺寸时部分设备不会触发页面加载。
 */
@Component
export struct SourceHost {
  private controller: webview.WebviewController = new webview.WebviewController();
  private bridge: LxNativeBridge = new LxNativeBridge((message: string): void => {
    App.get().runner.handleMessage(message);
  });

  build() {
    Web({ src: $rawfile('lx_bridge.html'), controller: this.controller })
      .width('100%')
      .height('100%')
      .opacity(0.01)
      .hitTestBehavior(HitTestMode.None)
      .javaScriptAccess(true)
      .domStorageAccess(true)
      .fileAccess(true)
      .imageAccess(true)
      .onlineImageAccess(true)
      .mixedMode(MixedMode.All)
      .cacheMode(CacheMode.Default)
      .darkMode(WebDarkMode.Off)
      .onControllerAttached(() => {
        try {
          this.controller.registerJavaScriptProxy(this.bridge, 'lxNative', ['call']);
        } catch (e) {
          console.error('[SourceHost] 注册桥接失败 ' + String(e));
        }
      })
      .onPageEnd(() => {
        const runner = App.get().runner;
        runner.attach(this.controller);
        runner.markReady();
        App.get().startSources().catch(() => {
          console.error('[SourceHost] 音源初始化失败');
        });
      })
      .onErrorReceive(() => {
        console.error('[SourceHost] 沙箱页面加载失败');
      })
  }
}

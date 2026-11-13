import {
  palette, Palette, RADIUS, FONT, PAGE_PAD, FLOAT_SPACE,
  glassCardBase, glassSurface, glassEdgeWidth, glassEdgeColor, glassShadow
} from '../../common/Constants';
import { NavParam, PlatformDef } from '../../common/Models';
import { PLATFORMS, DISCOVER_PLATFORM_IDS, discoverPlatforms, platformName } from '../../common/Platform';
import { App } from '../../core/App';
import { Settings } from '../../core/Settings';
import { Chip } from '../Common';
import { SettingArrowRow } from '../SettingsCommon';

const APP_VERSION: string = '1.0';

/**
 * 设置主页：账号（置顶）、音源、播放、外观、发现、数据、关于。
 * v2.68：账号入口从「发现」分组抽出来，作为第一个分组置顶，单行直达 wyAccount
 * 二级页登录三平台账号；不新增一级页、不新增路由，账号页只承担平台登录。
 *
 * v2.62：把「播放」的 5 个选项收进「播放设置」二级页，把「外观」的主题与
 * 「歌词」整合成「外观」二级页；v2.63：把「数据」的备份 / 恢复也收进
 * 「数据管理」二级页。主页现在只留三个入口行——避免首屏一屏塞不下、
 * 选项一层层往下堆。二级页各自带 NavDestination + ImmersiveBar + 返回拦截，
 * 与「音源管理」一致。
 *
 * 行组件统一来自 SettingsCommon.ets（独立 @Component + @Prop）：不能用带参
 * @Builder，否则值变化不会触发行内重画（v1.7 的老坑）。
 * 当前音质只在「播放设置」二级页展示（音质偏好项 + 顶栏副标题），主页三个
 * 入口都是纯跳转、不重复显示值；所有开关仍直接落盘、改完即生效。
 *
 * 备份 / 恢复搬进「数据管理」后，恢复动作由 Backup.refreshAfterRestore() 统一
 * reload 单例并广播派生偏好；主页是常驻一级页不会重建，靠订阅 discoverPlatform
 * 这条广播重读设置，保证「默认发现平台」摘要恢复后即时刷新（DiscoverPage 同款）。
 */
@Component
export struct SettingsPage {
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;
  @StorageProp('topSafe') topSafe: number = 24;
  @StorageProp('libraryVersion') libraryVersion: number = 0;
  /** 恢复备份后由 Backup.refreshAfterRestore 广播，触发本页重读发现平台摘要 */
  @StorageProp('discoverPlatform') @Watch('onDiscoverPlatform') dpBroadcast: string = '';
  /** 网易云账号登录态：账号页登录 / 退出后广播，本页入口摘要即时刷新 */
  @StorageProp('wyNick') wyNick: string = '';
  @StorageProp('wyLoginVersion') wyLoginVersion: number = 0;
  /** 0 无 / 2 发现平台弹层（音质弹层已随「播放设置」搬进二级页） */
  @State sheetMode: number = 0;
  @State discoverPlatform: string = 'wy';
  // 音质偏好由「播放设置」二级页自己订阅 AppStorage，主页不跟踪、不显示，
  // 避免入口右侧再挂一个和二级页重复的「全景声」。
  private settings: Settings = Settings.get();

  aboutToAppear(): void {
    this.reload();
  }

  private reload(): void {
    // 咪咕已退出发现平台清单：老配置里存的 'mg' 要落回网易云，
    // 否则弹窗里一个胶囊都不选中，看起来像坏了
    const savedPlatform = this.settings.discoverPlatform();
    this.discoverPlatform = DISCOVER_PLATFORM_IDS.indexOf(savedPlatform) >= 0 ? savedPlatform : 'wy';
  }

  /** 恢复备份后刷新「默认发现平台」摘要：本页常驻不重建，只能靠广播触发 */
  onDiscoverPlatform(): void {
    this.reload();
  }

  private p(): Palette {
    return palette(this.isDark);
  }

  /**
   * v1.0：账号体系收口为仅网易云（QQ / 酷狗账号引擎已连根删除），摘要只反映网易云登录态。
   * v2.77：入口只显示「已登录 / 未登录」，不再把账号昵称明文挂在设置页
   * （昵称是网易云默认分配的用户名样式，容易被误认成内部标识或测试残留）。
   * wyNick 仍作为登录态信号被读取，保证登录 / 退出广播时本行即时刷新；
   * 真实昵称与头像由「网易云账号」二级页展示，不在列表摘要重复暴露。
   */
  private accountSummary(): string {
    return this.wyNick.length > 0 ? '已登录' : '未登录';
  }

  @Builder
  sectionTitle(text: string) {
    Text(text)
      .fontSize(FONT.caption)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.p().text3)
      .width('100%')
      .padding({ left: 14, top: 6 })
  }

  @Builder
  optionSheet() {
    this.platformSheet()
  }

  @Builder
  platformSheet() {
    Column({ space: 14 }) {
      Text('默认发现平台')
        .fontSize(FONT.headline)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.p().text)
        .width('100%')
      Text('打开「发现」先看哪个平台的榜单和歌单')
        .fontSize(FONT.caption)
        .fontColor(this.p().text3)
        .width('100%')
      // 只列发现里真能出内容的平台：咪咕接口返空，留在选项里就是选完什么都没有
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(discoverPlatforms(), (item: PlatformDef) => {
          Column() {
            Chip({
              text: item.name,
              active: this.discoverPlatform === item.id,
              onTap: () => {
                this.discoverPlatform = item.id;
                this.settings.setDiscoverPlatform(item.id);
                this.sheetMode = 0;
                App.get().toast('发现页默认看' + item.name);
              }
            })
          }
          .margin({ right: 8, bottom: 10 })
        }, (item: PlatformDef) => item.id)
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 18, bottom: 30 })
    .backgroundColor(glassCardBase(this.isDark))
    .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
    .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
    .shadow(glassShadow(this.isDark, this.lightLevel))
  }


  build() {
    Scroll() {
      Column({ space: 16 }) {
        Row() {
          Text('设置')
            .fontSize(32)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.p().text)
          Blank()
        }
        .width('100%')
        .padding({ top: 8 })

        // v2.68 账号栏置顶；v2.71 收口为仅网易云，入口标题与账号页保持一致
        this.sectionTitle('账号')
        Column() {
          SettingArrowRow({
            icon: $r('sys.symbol.person'),
            title: '网易云账号',
            value: this.accountSummary(),
            onTap: () => {
              App.get().push('wyAccount', new NavParam());
            }
          })
        }
        .width('100%')
        .borderRadius(RADIUS.lg)
        .backgroundColor(glassCardBase(this.isDark))
        .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
        .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
        .shadow(glassShadow(this.isDark, this.lightLevel))
        .clip(true)

        this.sectionTitle('音源')
        Column() {
          SettingArrowRow({
            icon: $r('sys.symbol.link'),
            title: '音源管理',
            value: '',
            onTap: () => {
              App.get().push('sources', new NavParam());
            }
          })
        }
        .width('100%')
        .borderRadius(RADIUS.lg)
        .backgroundColor(glassCardBase(this.isDark))
        .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
        .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
        .shadow(glassShadow(this.isDark, this.lightLevel))
        .clip(true)

        this.sectionTitle('播放')
        Column() {
          SettingArrowRow({
            icon: $r('sys.symbol.headphones'),
            title: '播放设置',
            value: '',
            onTap: () => {
              App.get().push('playSettings', new NavParam());
            }
          })
        }
        .width('100%')
        .borderRadius(RADIUS.lg)
        .backgroundColor(glassCardBase(this.isDark))
        .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
        .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
        .shadow(glassShadow(this.isDark, this.lightLevel))
        .clip(true)

        this.sectionTitle('外观')
        Column() {
          SettingArrowRow({
            icon: $r('sys.symbol.paintpalette'),
            title: '外观设置',
            value: '',
            onTap: () => {
              App.get().push('appearanceSettings', new NavParam());
            }
          })
        }
        .width('100%')
        .borderRadius(RADIUS.lg)
        .backgroundColor(glassCardBase(this.isDark))
        .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
        .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
        .shadow(glassShadow(this.isDark, this.lightLevel))
        .clip(true)

        this.sectionTitle('发现')
        Column() {
          SettingArrowRow({
            icon: $r('sys.symbol.discover'),
            title: '默认发现平台',
            value: platformName(this.discoverPlatform),
            onTap: () => {
              this.sheetMode = 2;
            }
          })
        }
        .width('100%')
        .borderRadius(RADIUS.lg)
        .backgroundColor(glassCardBase(this.isDark))
        .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
        .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
        .shadow(glassShadow(this.isDark, this.lightLevel))
        .clip(true)

        this.sectionTitle('数据')
        Column() {
          SettingArrowRow({
            icon: $r('sys.symbol.arrow_up_circle'),
            title: '数据管理',
            value: '',
            onTap: () => {
              App.get().push('dataSettings', new NavParam());
            }
          })
        }
        .width('100%')
        .borderRadius(RADIUS.lg)
        .backgroundColor(glassCardBase(this.isDark))
        .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
        .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
        .shadow(glassShadow(this.isDark, this.lightLevel))
        .clip(true)

        this.sectionTitle('关于')
        Column({ space: 10 }) {
          Row() {
            Text('版本').fontSize(FONT.body).fontColor(this.p().text).layoutWeight(1)
            Text('v' + APP_VERSION).fontSize(FONT.callout).fontColor(this.p().text3)
          }
          .width('100%')

          Divider().color(this.p().line)

          Text('音栈 · 鸿蒙原生音乐播放器。搜索与榜单直连各平台官方接口，' +
            '播放地址由洛雪音源脚本提供；默认开启「智能达标寻源」：按你选的音质自动跨音源、' +
            '跨平台找同款，绝不降到低音质，全找不到会明确提示。可在音源管理里关闭。')
            .fontSize(FONT.caption)
            .fontColor(this.p().text3)
            .lineHeight(19)
            .width('100%')
        }
        .width('100%')
        .padding(16)
        .borderRadius(RADIUS.lg)
        .backgroundColor(glassCardBase(this.isDark))
        .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
        .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
        .shadow(glassShadow(this.isDark, this.lightLevel))

        Row().height(FLOAT_SPACE)
      }
      .width('100%')
      .padding({ left: PAGE_PAD, right: PAGE_PAD, top: this.topSafe })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .backgroundColor('#00000000')
    .bindSheet(this.sheetMode > 0, this.optionSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: false,
      backgroundColor: glassCardBase(this.isDark),
      onDisappear: () => {
        this.sheetMode = 0;
      }
    })
  }
}

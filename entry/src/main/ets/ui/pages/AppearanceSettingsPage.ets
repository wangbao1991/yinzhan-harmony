import { common } from '@kit.AbilityKit';
import {
  palette, Palette, RADIUS, FONT, PAGE_PAD, FLOAT_SPACE,
  glassCardBase, glassSurface, glassEdgeWidth, glassEdgeColor, glassShadow
} from '../../common/Constants';
import { App } from '../../core/App';
import { Settings } from '../../core/Settings';
import { Chip, ImmersiveBar } from '../Common';
import { SettingSwitchRow, applyThemeMode } from '../SettingsCommon';

/**
 * 外观（二级页）：主题 + 歌词设置。
 *
 * v2.62：把设置主页的「外观」卡与「歌词」卡整合成一个二级界面，主页只留一个入口。
 * 主题三档仍直接改系统 ColorMode 并广播 isDark（与「从备份恢复」共用
 * SettingsCommon.applyThemeMode 单一实现）；光感四档迁移提示随主题一并搬来。
 * v2.80：青绿液态玻璃整套风格连根删除，本页「主题」分组只保留「模式」一行，
 * 两段风格说明文字一并移除；界面固定为纸墨，不再提供第二套主题切换。
 */
@Component
export struct AppearanceSettingsPage {
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;
  @StorageProp('topSafe') topSafe: number = 24;
  @State themeMode: number = 0;
  /** 光感四档移除的一次性提示（只在「曾选过非默认档且没看过」时出现） */
  @State lightNotice: boolean = false;
  @State showTrans: boolean = true;
  @State lyricSize: number = 1;
  private settings: Settings = Settings.get();

  aboutToAppear(): void {
    this.reload();
  }

  private reload(): void {
    this.themeMode = this.settings.themeMode();
    this.lightNotice = this.needLightNotice();
    this.showTrans = this.settings.showTrans();
    this.lyricSize = this.settings.lyricSize();
  }

  /**
   * 光感四档迁移提示只在「曾经真选过非默认档」且「没看过提示」时出现。
   * 默认值 3 说明从没动过这一项，弹了反而莫名其妙。
   */
  private needLightNotice(): boolean {
    return !this.settings.lightSenseNoticeSeen() && this.settings.lightSense() !== 3;
  }

  private p(): Palette {
    return palette(this.isDark);
  }

  private applyTheme(mode: number): void {
    this.themeMode = mode;
    applyThemeMode(mode, getContext(this) as common.UIAbilityContext);
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


  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Top }) {
        Scroll() {
          Column({ space: 16 }) {
            this.sectionTitle('主题')
            Column() {
              Row({ space: 8 }) {
                Text('模式')
                  .fontSize(FONT.body)
                  .fontColor(this.p().text)
                  .width(64)
                Row({ space: 8 }) {
                  Chip({
                    text: '跟随系统', active: this.themeMode === 0, onTap: () => {
                      this.applyTheme(0);
                    }
                  })
                  Chip({
                    text: '浅色', active: this.themeMode === 1, onTap: () => {
                      this.applyTheme(1);
                    }
                  })
                  Chip({
                    text: '深色', active: this.themeMode === 2, onTap: () => {
                      this.applyTheme(2);
                    }
                  })
                }
                .layoutWeight(1)
              }
              .width('100%')
              .height(56)
              .padding({ left: 16, right: 16 })

              // v2.80：青绿液态玻璃整套风格与两段说明文字一并去除，「主题」分组
              // 只保留「模式」（跟随系统 / 浅色 / 深色）这一行，界面固定为纸墨。
              // v2.52 墨栈：界面为不反光的纸墨表面，光感档位视觉归一为单一实色，
              // 不再提供玻璃质感选项。lightSense 符号与全站 @StorageProp 订阅保留（兼容回滚）。
              // v2.56：移除时没给任何提示，这里给老用户一条只出现一次的迁移说明。
              if (this.lightNotice) {
                Row({ space: 10 }) {
                  Column()
                    .width(3)
                    .height(30)
                    .borderRadius(2)
                    .backgroundColor(this.p().primary)
                    .accessibilityLevel('no')
                  Text('光感四档已取消：界面改为不反光的纸墨表面，深浅色仍按上面的「主题」走。')
                    .fontSize(FONT.caption)
                    .fontColor(this.p().text2)
                    .layoutWeight(1)
                    .lineHeight(18)
                  Text('知道了')
                    .fontSize(FONT.caption)
                    .fontColor(this.p().primary)
                    .height(44)
                    .textAlign(TextAlign.Center)
                    .padding({ left: 8, right: 8 })
                    .responseRegion({ x: 0, y: -6, width: '100%', height: 48 })
                    .accessibilityText('知道了，不再提示')
                    .accessibilityLevel('yes')
                    .onClick(() => {
                      this.lightNotice = false;
                      this.settings.setLightSenseNoticeSeen();
                    })
                }
                .width('100%')
                .padding({ left: 16, right: 10, top: 2, bottom: 6 })
                .accessibilityText('光感四档已取消：界面改为不反光的纸墨表面，深浅色仍按上面的主题设置')
              }
            }
            .width('100%')
            .borderRadius(RADIUS.lg)
            .backgroundColor(glassCardBase(this.isDark))
            .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
            .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
            .shadow(glassShadow(this.isDark, this.lightLevel))
            .clip(true)

            this.sectionTitle('歌词')
            Column() {
              Row({ space: 8 }) {
                Text('字号')
                  .fontSize(FONT.body)
                  .fontColor(this.p().text)
                  .width(64)
                Row({ space: 8 }) {
                  ForEach([0, 1, 2, 3], (size: number) => {
                    Chip({
                      text: ['小', '标准', '大', '特大'][size],
                      active: this.lyricSize === size,
                      onTap: () => {
                        this.lyricSize = size;
                        this.settings.setLyricSize(size);
                        AppStorage.setOrCreate('lyricSize', size);
                      }
                    })
                  }, (size: number) => size.toString())
                }
                .layoutWeight(1)
              }
              .width('100%')
              .height(56)
              .padding({ left: 16, right: 16 })

              Divider().color(this.p().line).margin({ left: 16, right: 16 })

              SettingSwitchRow({
                icon: $r('sys.symbol.textformat'),
                title: '显示翻译歌词',
                hint: '有翻译时在原文下方一起显示',
                value: this.showTrans,
                onChange: (on: boolean) => {
                  this.showTrans = on;
                  this.settings.setShowTrans(on);
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

            Row().height(FLOAT_SPACE)
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
          title: '外观',
          subtitle: '主题与歌词',
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

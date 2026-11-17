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
 * SettingsCommon.applyThemeMode 单一实现）。
 */
@Component
export struct AppearanceSettingsPage {
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;
  @StorageProp('topSafe') topSafe: number = 24;
  @State themeMode: number = 0;
  @State showTrans: boolean = true;
  @State lyricSize: number = 1;
  @State perfMode: boolean = false;
  private settings: Settings = Settings.get();

  aboutToAppear(): void {
    this.reload();
  }

  private reload(): void {
    this.themeMode = this.settings.themeMode();
    this.showTrans = this.settings.showTrans();
    this.lyricSize = this.settings.lyricSize();
    this.perfMode = this.settings.perfMode();
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

              // v2.52 墨栈：界面为不反光的纸墨表面，光感档位视觉归一为单一实色，
              // 不再提供玻璃质感选项。lightSense 符号与全站 @StorageProp 订阅保留（兼容回滚）。

              Divider().color(this.p().line).margin({ left: 16, right: 16 })

              SettingSwitchRow({
                icon: $r('sys.symbol.bolt'),
                title: '流畅优先',
                hint: '默认开启：关掉底栏毛玻璃与流光，滚动最顺',
                value: this.perfMode,
                onChange: (on: boolean) => {
                  this.perfMode = on;
                  this.settings.setPerfMode(on);
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

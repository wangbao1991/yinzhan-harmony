import {
  palette, Palette, RADIUS, FONT, PAGE_PAD, FLOAT_SPACE, qualityOptions, qualityLabel,
  glassCardBase, glassSurface, glassEdgeWidth, glassEdgeColor, glassShadow
} from '../../common/Constants';
import { App } from '../../core/App';
import { Settings } from '../../core/Settings';
import { SourceRepo } from '../../core/SourceRepo';
import { ImmersiveBar } from '../Common';
import { SettingArrowRow, SettingSwitchRow } from '../SettingsCommon';

/**
 * 播放设置（二级页）：音质偏好 + 4 个播放行为开关。
 *
 * v2.62：从设置主页的「播放」分组整体搬来，主页只留一个「播放设置」入口。
 * 所有开关仍直接落盘、改完即生效，不做「保存」按钮。
 * 返回链与音源管理 / 歌单收藏一致：NavDestination + ImmersiveBar +
 * onBackPressed 统一走 App.consumeBack（页内弹层 → 根级浮层 → 退页）。
 */
@Component
export struct PlaySettingsPage {
  @StorageProp('isDark') isDark: boolean = false;
  @StorageProp('lightSense') lightLevel: number = 3;
  @StorageProp('topSafe') topSafe: number = 24;
  /** 全局音质偏好是唯一数据源：本页「音质偏好」项 + 顶栏副标题、弹层勾选、
   * 播放页、下载都读 AppStorage。设置主页入口不再重复显示当前音质。 */
  @StorageProp('qualityPref') qualityPref: string = '320k';
  @State autoPlay: boolean = false;
  @State rememberPos: boolean = true;
  @State ignoreInterrupt: boolean = false;
  @State preloadNext: boolean = true;
  /** 0 无 / 1 音质弹层 */
  @State sheetMode: number = 0;
  private settings: Settings = Settings.get();

  aboutToAppear(): void {
    this.reload();
  }

  private reload(): void {
    this.autoPlay = this.settings.autoPlay();
    this.rememberPos = this.settings.rememberPosition();
    this.ignoreInterrupt = this.settings.ignoreInterrupt();
    this.preloadNext = this.settings.preloadNext();
  }

  /** 音质选项：基础 5 档常驻 + 音源 inited 声明的扩展档 + 当前已选档 */
  private qualityOptionList(): string[] {
    const declared: string[] = SourceRepo.get().getQualities('');
    declared.push(this.qualityPref);
    return qualityOptions(declared);
  }

  private p(): Palette {
    return palette(this.isDark);
  }

  /** 本页临时态只有音质弹层：开着时先收弹层，别直接退页 */
  private localBack(): boolean {
    if (this.sheetMode > 0) {
      this.sheetMode = 0;
      return true;
    }
    return false;
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
  qualitySheet() {
    Column({ space: 8 }) {
      Text('选择音质')
        .fontSize(FONT.headline)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.p().text)
        .width('100%')
      Text('播放时会自动降级保证能出声；下载严格按所选音质，拿不到就报错。母带 / 全景声等档位只在音源声明支持后出现')
        .fontSize(FONT.caption)
        .fontColor(this.p().text3)
        .width('100%')

      Column() {
        ForEach(this.qualityOptionList(), (item: string) => {
          Row({ space: 10 }) {
            Text(qualityLabel(item))
              .fontSize(FONT.body)
              .fontColor(this.p().text)
              .layoutWeight(1)
            Text(this.settings.qualityLabel(item))
              .fontSize(FONT.caption)
              .fontColor(this.p().text3)
            if (this.qualityPref === item) {
              SymbolGlyph($r('sys.symbol.checkmark')).fontSize(16).fontColor([this.p().primary])
            }
          }
          .width('100%')
          .height(50)
          .padding({ left: 4, right: 4 })
          .onClick(() => {
            App.get().player.setQuality(item);
            this.sheetMode = 0;
          })
        }, (item: string) => item)
      }
      .width('100%')
      .padding({ top: 6, bottom: 18 })
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 18 })
    .backgroundColor(glassCardBase(this.isDark))
    .linearGradient({ angle: 180, colors: glassSurface(this.isDark, this.lightLevel) })
    .border({ width: glassEdgeWidth(this.lightLevel), color: glassEdgeColor(this.isDark, this.lightLevel) })
    .shadow(glassShadow(this.isDark, this.lightLevel))
  }


  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Top }) {
        Scroll() {
          Column({ space: 16 }) {
            this.sectionTitle('音质')
            Column() {
              SettingArrowRow({
                icon: $r('sys.symbol.headphones'),
                title: '音质偏好',
                value: qualityLabel(this.qualityPref),
                onTap: () => {
                  this.sheetMode = 1;
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

            this.sectionTitle('播放行为')
            Column() {
              SettingSwitchRow({
                icon: $r('sys.symbol.play_circle'),
                title: '启动时自动续播',
                hint: '打开后进入应用就接着放上次那首',
                value: this.autoPlay,
                onChange: (on: boolean) => {
                  this.autoPlay = on;
                  this.settings.setAutoPlay(on);
                }
              })
              Divider().color(this.p().line).margin({ left: 16, right: 16 })
              SettingSwitchRow({
                icon: $r('sys.symbol.clock'),
                title: '记住播放进度',
                hint: '下次打开从上次的位置继续',
                value: this.rememberPos,
                onChange: (on: boolean) => {
                  this.rememberPos = on;
                  this.settings.setRememberPosition(on);
                }
              })
              Divider().color(this.p().line).margin({ left: 16, right: 16 })
              SettingSwitchRow({
                icon: $r('sys.symbol.arrow_down_circle'),
                title: '弱网预加载下一首',
                hint: '本首剩 60 秒时提前取好下一首链接，切歌少等待',
                value: this.preloadNext,
                onChange: (on: boolean) => {
                  this.preloadNext = on;
                  this.settings.setPreloadNext(on);
                }
              })
              Divider().color(this.p().line).margin({ left: 16, right: 16 })
              SettingSwitchRow({
                icon: $r('sys.symbol.speaker_wave_2'),
                title: '忽略音频打断',
                hint: '来电/其他应用播放时不被暂停',
                value: this.ignoreInterrupt,
                onChange: (on: boolean) => {
                  this.ignoreInterrupt = on;
                  this.settings.setIgnoreInterrupt(on);
                  App.get().player.applyInterruptMode();
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
        .bindSheet(this.sheetMode > 0, this.qualitySheet(), {
          height: SheetSize.FIT_CONTENT,
          dragBar: false,
          backgroundColor: glassCardBase(this.isDark),
          onDisappear: () => {
            this.sheetMode = 0;
          }
        })

        ImmersiveBar({
          title: '播放设置',
          subtitle: qualityLabel(this.qualityPref),
          onBack: (): void => {
            App.get().back((): boolean => this.localBack());
          }
        })
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .onBackPressed(() => App.get().consumeBack((): boolean => this.localBack()))
  }
}

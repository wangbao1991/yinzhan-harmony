import { common } from '@kit.AbilityKit';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { palette, Palette, FONT, ThemeMode } from '../common/Constants';
import { Settings } from '../core/Settings';

/**
 * 设置主页与两个二级设置页共用的「入口行 / 开关行 / 主题应用」。
 *
 * 坑（v1.7 修复）：这些行必须是独立 @Component + @Prop，不能是带参 @Builder。
 * ArkUI 里 @Builder 参数按值拷贝，父组件 @State / @StorageProp 变化时 Builder
 * 内部拿到的仍是首次构建的旧副本，于是「选完音质回到设置页，摘要还停在 128K」，
 * 只有重启让页面重建、参数重新求值才对。改成 @Component 后 @Prop 与父组件
 * 建立单向同步，父状态一变子组件立刻刷新。
 *
 * v2.62：设置主页把「播放」「外观」「歌词」收成两个二级页，三个页面都要用
 * 同一套行组件，故从 SettingsPage.ets 抽到这里，避免复制三份、也避免哪天
 * 只改了其中一份导致三页表现不一致。
 */
@Component
export struct SettingArrowRow {
  @Prop icon: Resource = $r('sys.symbol.chevron_right');
  @Prop title: string = '';
  @Prop value: string = '';
  @StorageProp('isDark') isDark: boolean = false;
  onTap: () => void = (): void => {};

  private p(): Palette {
    return palette(this.isDark);
  }


  build() {
    Row({ space: 12 }) {
      SymbolGlyph(this.icon).fontSize(18).fontColor([this.p().text2])
      Text(this.title).fontSize(FONT.body).fontColor(this.p().text).layoutWeight(1)
      if (this.value.length > 0) {
        Text(this.value)
          .fontSize(FONT.callout)
          .fontColor(this.p().text3)
          .maxLines(1)
          .constraintSize({ maxWidth: 150 })
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(13).fontColor([this.p().text3])
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 14 })
    // 整行一条语句，读屏不再逐个念「箭头图标 / 标题 / 当前值 / 右箭头」
    .accessibilityGroup(true)
    .accessibilityText(this.title + '，设置项' +
      (this.value.length > 0 ? '，当前 ' + this.value : ''))
    .accessibilityDescription('双击打开')
    .onClick(() => {
      this.onTap();
    })
  }
}

@Component
export struct SettingSwitchRow {
  @Prop icon: Resource = $r('sys.symbol.chevron_right');
  @Prop title: string = '';
  @Prop hint: string = '';
  @Prop value: boolean = false;
  @StorageProp('isDark') isDark: boolean = false;
  onChange: (on: boolean) => void = (on: boolean): void => {};

  private p(): Palette {
    return palette(this.isDark);
  }


  build() {
    Row({ space: 12 }) {
      SymbolGlyph(this.icon).fontSize(18).fontColor([this.p().text2])
      Column({ space: 3 }) {
        Text(this.title).fontSize(FONT.body).fontColor(this.p().text)
        if (this.hint.length > 0) {
          Text(this.hint).fontSize(FONT.micro).fontColor(this.p().text3)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .accessibilityGroup(true)
      .accessibilityText(this.title + (this.hint.length > 0 ? '，' + this.hint : '') +
        '，' + (this.value ? '已开启' : '已关闭'))

      Toggle({ type: ToggleType.Switch, isOn: this.value })
        .selectedColor(this.p().primary)
        .accessibilityText(this.title + '，开关')
        .onChange((on: boolean) => {
          this.onChange(on);
        })
    }
    .width('100%')
    .height(this.hint.length > 0 ? 62 : 52)
    .padding({ left: 16, right: 16 })
  }
}

/**
 * 应用深浅色模式：写偏好 + 切系统 ColorMode + 广播 isDark。
 * 设置主页「从备份恢复」与外观页三档 Chip 共用同一入口，避免两处各写一份
 * 导致「恢复了备份但主题没跟着变」。
 */
export function applyThemeMode(mode: number, context: common.UIAbilityContext): void {
  Settings.get().setThemeMode(mode);
  const app = context.getApplicationContext();
  if (mode === ThemeMode.LIGHT) {
    app.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    AppStorage.setOrCreate('isDark', false);
  } else if (mode === ThemeMode.DARK) {
    app.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    AppStorage.setOrCreate('isDark', true);
  } else {
    app.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    const dark = context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    AppStorage.setOrCreate('isDark', dark);
  }
}

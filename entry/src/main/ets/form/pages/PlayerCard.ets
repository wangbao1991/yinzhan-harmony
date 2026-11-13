/**
 * 桌面服务卡片页面（v2.23，2*2 / 2*4）。
 *
 * ArkTS 卡片的组件与通用属性集合比普通页面窄，这里只用最稳的
 * Row / Column / Text + 基础背景、圆角、边框，避免 SymbolGlyph、
 * linearGradient 之类在卡片编译期可能被拒的写法。v2.52 墨栈：中性纸墨底 + 信号琥珀按钮。
 * 数据由 PlayerCardAbility 通过 formBindingData 注入 @LocalStorageProp。
 * 整卡点击走 router 动作拉起主界面，不做假播放控制。
 */
let storage: LocalStorage = new LocalStorage();

@Entry(storage)
@Component
struct PlayerCard {
  @LocalStorageProp('songName') songName: string = '音栈';
  @LocalStorageProp('singer') singer: string = '打开应用开始听歌';
  @LocalStorageProp('hint') hint: string = '未在播放';

  build() {
    Row() {
      Column({ space: 3 }) {
        Text(this.hint)
          .fontSize(10)
          .fontColor('#FF5C5851')
        Text(this.songName)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FF1B1A18')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.singer)
          .fontSize(11)
          .fontColor('#FF6F6960')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('▶')
        .fontSize(15)
        .fontColor('#FF191713')
        .width(34)
        .height(34)
        .borderRadius(17)
        .backgroundColor('#FFE29A26')
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor('#FFF7F5F0')
    .border({ width: 1, color: '#FF817E7A' })
    .borderRadius(14)
    .onClick(() => {
      postCardAction(this, {
        action: 'router',
        abilityName: 'EntryAbility',
        params: { fromCard: true }
      });
    })
  }
}

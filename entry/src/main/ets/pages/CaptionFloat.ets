@Entry
@Component
struct CaptionFloat {
  @LocalStorageLink('original') original: string = '';
  @LocalStorageLink('translation') translation: string = '等待语音输入...';

  build() {
    Column({ space: 3 }) {
      if (this.original.length > 0) {
        Text(this.original)
          .fontSize(12)
          .fontWeight(FontWeight.Regular)
          .fontColor('rgba(255, 255, 255, 0.70)')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
      }

      Text(this.translation.length > 0 ? this.translation : '正在聆听并翻译…')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Start)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding({
      left: 14,
      right: 14,
      top: 4,
      bottom: 4
    })
    .backgroundColor('rgba(18, 18, 22, 0.92)')
    .borderRadius(14)
    .border({ width: 1, color: 'rgba(255, 255, 255, 0.12)' })
  }
}

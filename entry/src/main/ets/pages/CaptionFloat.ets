@Entry
@Component
struct CaptionFloat {
  @LocalStorageLink('original') original: string = '';
  @LocalStorageLink('translation') translation: string = '';

  build() {
    Column({ space: 2 }) {
      if (this.original.length > 0) {
        Text(this.original)
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor('rgba(255, 255, 255, 0.82)')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
          .width('100%')
      }

      Text(this.translation.length > 0 ? this.translation : '正在聆听并翻译…')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width('100%')
    }
    .padding({
      left: 12,
      right: 12,
      top: 4,
      bottom: 4
    })
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height('100%')
    .backgroundColor('#B8000000')
    .borderRadius(16)
    .border({ width: 1, color: 'rgba(255, 255, 255, 0.10)' })
  }
}

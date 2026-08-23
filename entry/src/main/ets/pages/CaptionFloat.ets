@Entry
@Component
struct CaptionFloat {
  @LocalStorageLink('original') original: string = 'Waiting for audio...';
  @LocalStorageLink('translation') translation: string = '等待语音输入...';

  build() {
    Column({ space: 4 }) {
      if (this.original.length > 0) {
        Text(this.original)
          .fontSize(15)
          .fontWeight(FontWeight.Regular)
          .fontColor('rgba(255, 255, 255, 0.72)')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
      }

      Text(this.translation.length > 0 ? this.translation : '正在聆听并翻译…')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Start)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding({
      left: 16,
      right: 16,
      top: 10,
      bottom: 10
    })
    .backgroundColor('rgba(20, 20, 24, 0.88)')
    .borderRadius(16)
    .border({ width: 1, color: 'rgba(255, 255, 255, 0.12)' })
  }
}

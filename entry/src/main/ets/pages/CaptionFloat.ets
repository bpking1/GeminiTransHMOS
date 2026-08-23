@Entry
@Component
struct CaptionFloat {
  @LocalStorageLink('original') original: string = '';
  @LocalStorageLink('translation') translation: string = '';

  build() {
    Column({ space: 2 }) {
      if (this.original.length > 0) {
        Text(this.original)
          .fontSize(17)
          .fontColor(Color.White)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
          .width('100%')
      }

      Text(this.translation.length > 0 ? this.translation : '正在聆听并翻译…')
        .fontSize(16)
        .fontColor(Color.White)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width('100%')
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height('100%')
    .padding({ left: 10, right: 10 })
    .backgroundColor('#66000000')
  }
}

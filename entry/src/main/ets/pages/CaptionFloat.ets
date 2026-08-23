const captionScroller: Scroller = new Scroller();

@Entry
@Component
struct CaptionFloat {
  @StorageLink('caption_translation') translation: string = '';
  @StorageLink('caption_font_size') fontSize: number = 18;
  @StorageLink('caption_is_live') isLive: boolean = false;

  build() {
    Column() {
      if (this.translation.length > 0) {
        Scroll(captionScroller) {
          Column() {
            Text(this.translation)
              .width('100%')
              .fontSize(this.fontSize)
              .fontWeight(FontWeight.Bold)
              .fontColor('#111827')
              .lineHeight(this.fontSize * 1.38)
              .textAlign(TextAlign.Start)
              .wordBreak(WordBreak.BREAK_ALL)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None)
        .onAppear(() => {
          captionScroller.scrollEdge(Edge.Bottom);
        })
      } else {
        Text(this.isLive ? '正在聆听并实时翻译…' : 'Gemini 实时字幕已就绪')
          .width('100%')
          .fontSize(Math.max(12, this.fontSize - 2))
          .fontColor('#6B7280')
          .textAlign(TextAlign.Start)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .backgroundColor('rgba(255, 255, 255, 0.90)')
    .borderRadius(16)
    .border({
      width: 1,
      color: 'rgba(0, 0, 0, 0.08)'
    })
    .justifyContent(FlexAlign.End)
    .alignItems(HorizontalAlign.Start)
  }
}

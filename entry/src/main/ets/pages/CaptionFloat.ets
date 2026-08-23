const captionScroller: Scroller = new Scroller();

@Entry
@Component
struct CaptionFloat {
  @LocalStorageLink('translation') translation: string = '';
  @LocalStorageLink('fontSize') fontSize: number = 18;
  @LocalStorageLink('isLive') isLive: boolean = false;

  build() {
    Column() {
      if (this.translation.length > 0) {
        Scroll(captionScroller) {
          Column() {
            Text(this.translation)
              .width('100%')
              .fontSize(this.fontSize)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
              .lineHeight(this.fontSize * 1.38)
              .textAlign(TextAlign.Start)
              .textShadow({ radius: 6, color: '#FF000000', offsetY: 1 })
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
          .fontColor('#94A3B8')
          .textAlign(TextAlign.Start)
          .textShadow({ radius: 4, color: '#CC000000', offsetY: 1 })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .backgroundColor('#33000000')
    .justifyContent(FlexAlign.End)
    .alignItems(HorizontalAlign.Start)
  }
}

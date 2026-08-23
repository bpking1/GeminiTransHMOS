const captionScroller: Scroller = new Scroller();

@Entry
@Component
struct CaptionFloat {
  @LocalStorageLink('translation') translation: string = '';
  @LocalStorageLink('fontSize') fontSize: number = 18;
  @LocalStorageLink('isLive') isLive: boolean = false;
  @State isBgVisible: boolean = false;
  private hideTimer: number = -1;

  private onCardClicked(): void {
    if (this.isBgVisible) {
      this.isBgVisible = false;
      if (this.hideTimer !== -1) {
        clearTimeout(this.hideTimer);
        this.hideTimer = -1;
      }
    } else {
      this.isBgVisible = true;
      if (this.hideTimer !== -1) {
        clearTimeout(this.hideTimer);
      }
      this.hideTimer = setTimeout(() => {
        this.isBgVisible = false;
        this.hideTimer = -1;
      }, 3000);
    }
  }

  aboutToDisappear(): void {
    if (this.hideTimer !== -1) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
  }

  build() {
    Column() {
      if (this.translation.length > 0) {
        Scroll(captionScroller) {
          Column() {
            Text(this.translation)
              .width('100%')
              .fontSize(this.fontSize)
              .fontWeight(FontWeight.Bold)
              .fontColor('#000000')
              .lineHeight(this.fontSize * 1.38)
              .textAlign(TextAlign.Start)
              .textShadow({ radius: 4, color: '#CCFFFFFF', offsetY: 1 })
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
          .fontColor('#4B5563')
          .textAlign(TextAlign.Start)
          .textShadow({ radius: 4, color: '#CCFFFFFF', offsetY: 1 })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .backgroundColor(this.isBgVisible ? 'rgba(255, 255, 255, 0.85)' : '#00000000')
    .borderRadius(14)
    .border({
      width: this.isBgVisible ? 1 : 0,
      color: 'rgba(0, 0, 0, 0.12)'
    })
    .animation({ duration: 250 })
    .justifyContent(FlexAlign.End)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.onCardClicked();
    })
  }
}

import { common } from '@kit.AbilityKit';
import { AppSettings } from '../model/AppSettings';
import { FloatWindowManager } from '../service/FloatWindowManager';
import { SettingsStore } from '../service/SettingsStore';
import { SessionListener, SessionState, TranslationSession } from '../service/TranslationSession';
import { Log } from '../util/Logger';

@Entry
@Component
struct FloatingWindowPage {
  @State private outputText: string = '';
  @State private inputText: string = '';
  @State private statusText: string = '已就绪';
  @State private sessionState: SessionState = SessionState.IDLE;
  @State private showOriginal: boolean = true;
  @State private captionFontSize: number = 22;

  private lastTouchX: number = 0;
  private lastTouchY: number = 0;
  private isDragging: boolean = false;
  private readonly session: TranslationSession = TranslationSession.getInstance();
  private readonly scroller: Scroller = new Scroller();
  private readonly sessionListener: SessionListener = {
    onState: (state: SessionState, status: string): void => {
      this.sessionState = state;
      this.statusText = status;
    },
    onTranscript: (input: string, output: string): void => {
      this.inputText = input;
      this.outputText = output;
      setTimeout(() => {
        this.scroller.scrollEdge(Edge.Bottom);
      }, 20);
    },
    onError: (message: string): void => {
      this.statusText = `错误：${message}`;
    }
  };

  aboutToAppear(): void {
    this.session.addListener(this.sessionListener);
    this.loadSettings();
  }

  aboutToDisappear(): void {
    this.session.removeListener(this.sessionListener);
  }

  private async loadSettings(): Promise<void> {
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const settings: AppSettings = await SettingsStore.load(context);
      this.showOriginal = settings.showOriginal;
      this.captionFontSize = Math.max(16, Math.min(30, settings.captionFontSize - 2));
    } catch (e) {
      Log.warn(`FloatingWindowPage loadSettings: ${JSON.stringify(e)}`);
    }
  }

  private statusColor(): string {
    if (this.sessionState === SessionState.LIVE) {
      return '#34D399';
    }
    if (this.sessionState === SessionState.STARTING) {
      return '#FBBF24';
    }
    if (this.sessionState === SessionState.ERROR) {
      return '#F87171';
    }
    return '#9CA3AF';
  }

  build() {
    Column() {
      // 1. Top Drag Bar & Action Bar
      Row() {
        // Status indicator & drag hint
        Row() {
          Circle({ width: 8, height: 8 })
            .fill(this.statusColor())
            .margin({ right: 6 })
          Text('Gemini 实时字幕')
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor('#F3F4F6')
        }
        .layoutWeight(1)
        .height(32)
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            this.lastTouchX = event.touches[0].screenX;
            this.lastTouchY = event.touches[0].screenY;
            this.isDragging = true;
          } else if (event.type === TouchType.Move && this.isDragging) {
            const dx = event.touches[0].screenX - this.lastTouchX;
            const dy = event.touches[0].screenY - this.lastTouchY;
            this.lastTouchX = event.touches[0].screenX;
            this.lastTouchY = event.touches[0].screenY;
            FloatWindowManager.getInstance().moveWindow(dx, dy);
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.isDragging = false;
          }
        })

        // Font size control
        Row({ space: 4 }) {
          Text('A-')
            .fontSize(11)
            .fontColor('#D1D5DB')
            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
            .backgroundColor('#374151')
            .borderRadius(4)
            .onClick(() => {
              if (this.captionFontSize > 16) {
                this.captionFontSize -= 2;
              }
            })

          Text('A+')
            .fontSize(11)
            .fontColor('#D1D5DB')
            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
            .backgroundColor('#374151')
            .borderRadius(4)
            .onClick(() => {
              if (this.captionFontSize < 32) {
                this.captionFontSize += 2;
              }
            })
        }
        .margin({ right: 8 })

        // Clear text button
        if (this.outputText.length > 0 || this.inputText.length > 0) {
          Text('清空')
            .fontSize(11)
            .fontColor('#A78BFA')
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor('#2E1065')
            .borderRadius(4)
            .margin({ right: 8 })
            .onClick(() => {
              this.session.clearTranscripts();
            })
        }

        // Close floating window button
        Text('✕')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor('#9CA3AF')
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .onClick(async () => {
            await FloatWindowManager.getInstance().hide();
          })
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 6, bottom: 4 })
      .backgroundColor('#1E1B2E')
      .borderRadius({ topLeft: 16, topRight: 16 })

      // 2. Subtitle Transcript Scrollable Area
      Scroll(this.scroller) {
        Column() {
          Text(this.outputText.length > 0 ? this.outputText : '实时译文会显示在这里…')
            .width('100%')
            .fontSize(this.captionFontSize)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.outputText.length > 0 ? '#FFFFFF' : '#9CA3AF')
            .lineHeight(this.captionFontSize * 1.4)
            .copyOption(CopyOptions.LocalDevice)
            .margin({ bottom: this.showOriginal && this.inputText.length > 0 ? 8 : 0 })

          if (this.showOriginal && this.inputText.length > 0) {
            Text(this.inputText)
              .width('100%')
              .fontSize(Math.max(13, this.captionFontSize - 6))
              .fontColor('#A5B4FC')
              .lineHeight(Math.max(18, (this.captionFontSize - 6) * 1.35))
              .copyOption(CopyOptions.LocalDevice)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#D9110E1C')
    .borderRadius(16)
    .border({ width: 1, color: '#3730A3' })
    .shadow({ radius: 20, color: '#66000000', offsetY: 6 })
  }
}

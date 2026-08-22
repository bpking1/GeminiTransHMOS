import { common } from '@kit.AbilityKit';
import { AppSettings, languageName } from '../model/AppSettings';
import { SettingsStore } from '../service/SettingsStore';
import { Log } from '../util/Logger';
import {
  SessionListener,
  SessionState,
  TranslationSession
} from '../service/TranslationSession';

@Entry
@Component
struct Index {
  @State private sessionState: SessionState = SessionState.IDLE;
  @State private statusText: string = '准备就绪';
  @State private inputText: string = '';
  @State private outputText: string = '';
  @State private targetLanguage: string = 'zh';
  @State private audioSource: string = 'mic';
  @State private showOriginal: boolean = true;
  @State private captionFontSize: number = 25;
  @State private errorText: string = '';
  @State private settingsLoaded: boolean = false;

  private readonly session: TranslationSession = TranslationSession.getInstance();
  private settings: AppSettings = new AppSettings();
  private readonly pageScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.attachSessionListener();
  }

  onPageShow(): void {
    this.attachSessionListener();
    this.loadSettings();
  }

  aboutToDisappear(): void {
    this.session.setListener(undefined);
  }

  private attachSessionListener(): void {
    const listener: SessionListener = {
      onState: (state: SessionState, status: string): void => {
        Log.info(`Index onState: state=${state}, status=${status}`);
        this.sessionState = state;
        this.statusText = status;
        if (state !== SessionState.ERROR) {
          this.errorText = '';
        }
      },
      onTranscript: (input: string, output: string): void => {
        this.inputText = input;
        this.outputText = output;
        setTimeout(() => {
          this.pageScroller.scrollEdge(Edge.Bottom);
        }, 20);
      },
      onError: (message: string): void => {
        Log.error(`Index onError: ${message}`);
        this.errorText = message;
      }
    };
    this.session.setListener(listener);
  }

  private async loadSettings(): Promise<void> {
    this.settingsLoaded = false;
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.settings = await SettingsStore.load(context);
      this.targetLanguage = this.settings.targetLanguage;
      this.audioSource = this.settings.audioSource;
      this.showOriginal = this.settings.showOriginal;
      this.captionFontSize = this.settings.captionFontSize;
      this.settingsLoaded = true;
      Log.info(`Settings loaded: targetLang=${this.targetLanguage}, source=${this.audioSource}, hasApiKey=${this.settings.apiKey.length > 0}`);
    } catch (error) {
      Log.error(`Failed to load settings: ${JSON.stringify(error)}`);
      this.errorText = `读取设置失败：${JSON.stringify(error)}`;
    }
  }

  private async toggleSession(): Promise<void> {
    Log.info(`User clicked toggleSession. isActive=${this.session.isActive()}`);
    if (this.session.isActive()) {
      await this.session.stop();
      return;
    }
    if (!this.settingsLoaded) {
      await this.loadSettings();
    }
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await this.session.start(context, this.settings);
  }

  private async openSettings(): Promise<void> {
    Log.info('User navigating to SettingsPage');
    if (this.session.isActive()) {
      await this.session.stop();
    }
    try {
      await this.getUIContext().getRouter().pushUrl({ url: 'pages/SettingsPage' });
    } catch (error) {
      Log.error(`Failed to navigate to settings: ${JSON.stringify(error)}`);
    }
  }

  private statusColor(): string {
    if (this.sessionState === SessionState.LIVE) {
      return '#2BB673';
    }
    if (this.sessionState === SessionState.STARTING) {
      return '#F2A93B';
    }
    if (this.sessionState === SessionState.ERROR) {
      return '#E45858';
    }
    return '#A4A1B1';
  }

  private primaryButtonText(): string {
    if (this.sessionState === SessionState.LIVE) {
      return '停止翻译';
    }
    if (this.sessionState === SessionState.STARTING) {
      return '取消';
    }
    return '开始翻译';
  }

  @Builder
  private Header() {
    Row() {
      Column() {
        Text('实时翻译')
          .fontSize(27)
          .fontWeight(FontWeight.Bold)
          .fontColor('#171521')
        Text('Gemini Live · HarmonyOS 6')
          .fontSize(12)
          .fontColor('#817D91')
          .margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start)

      Blank()

      Button('设置')
        .height(44)
        .fontSize(15)
        .fontColor('#6654D9')
        .backgroundColor('#ECE9FB')
        .borderRadius(14)
        .padding({ left: 18, right: 18 })
        .onClick(() => {
          this.openSettings();
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private StatusPanel() {
    Column() {
      Row() {
        Circle({ width: 10, height: 10 })
          .fill(this.statusColor())
        Text(this.statusText)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#4A4657')
          .margin({ left: 9 })
          .maxLines(2)
        Blank()
        Text(`译为 ${languageName(this.targetLanguage)}`)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .backgroundColor('#725FF0')
          .borderRadius(12)
          .padding({ left: 11, right: 11, top: 6, bottom: 6 })
      }
      .width('100%')

      Row() {
        Button('麦克风')
          .layoutWeight(1)
          .height(42)
          .fontSize(14)
          .fontColor(this.audioSource === 'mic' ? '#FFFFFF' : '#6F6A7D')
          .backgroundColor(this.audioSource === 'mic' ? '#725FF0' : Color.Transparent)
          .borderRadius(12)
          .enabled(!this.session.isActive() && this.settingsLoaded)
          .onClick(() => {
            this.selectAudioSource('mic');
          })
        Button('系统内录')
          .layoutWeight(1)
          .height(42)
          .fontSize(14)
          .fontColor(this.audioSource === 'system' ? '#FFFFFF' : '#6F6A7D')
          .backgroundColor(this.audioSource === 'system' ? '#725FF0' : Color.Transparent)
          .borderRadius(12)
          .enabled(!this.session.isActive() && this.settingsLoaded)
          .onClick(() => {
            this.selectAudioSource('system');
          })
      }
      .width('100%')
      .padding(4)
      .margin({ top: 14 })
      .backgroundColor('#F0EEF7')
      .borderRadius(15)
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#FFFFFF')
    .borderRadius(22)
    .shadow({ radius: 22, color: '#160C1533', offsetY: 7 })
  }

  private async selectAudioSource(source: string): Promise<void> {
    if (this.session.isActive() || this.audioSource === source) {
      return;
    }
    this.audioSource = source;
    this.settings.audioSource = source;
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await SettingsStore.save(context, this.settings);
    } catch (error) {
      this.errorText = `保存音源失败：${JSON.stringify(error)}`;
    }
  }

  @Builder
  private TranscriptPanel() {
    Column() {
      Row() {
        Text('译文')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor('#725FF0')
        Blank()
        if (this.outputText.length > 0) {
          Text('长按文字可复制')
            .fontSize(11)
            .fontColor('#AAA6B5')
        }
      }
      .width('100%')

      Text(this.outputText.length > 0 ? this.outputText : '译文会实时显示在这里')
        .width('100%')
        .fontSize(this.captionFontSize)
        .fontWeight(this.outputText.length > 0 ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.outputText.length > 0 ? '#171521' : '#B9B5C2')
        .lineHeight(this.captionFontSize * 1.45)
        .copyOption(CopyOptions.LocalDevice)
        .margin({ top: 14, bottom: this.showOriginal ? 18 : 4 })

      if (this.showOriginal) {
        Divider()
          .color('#ECE9F0')
        Text('原文')
          .width('100%')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor('#8A8597')
          .margin({ top: 17 })
        Text(this.inputText.length > 0 ? this.inputText : '等待语音输入…')
          .width('100%')
          .fontSize(16)
          .fontColor(this.inputText.length > 0 ? '#716C7E' : '#BBB7C4')
          .lineHeight(24)
          .copyOption(CopyOptions.LocalDevice)
          .margin({ top: 9 })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .constraintSize({ minHeight: this.showOriginal ? 270 : 210 })
    .padding(20)
    .backgroundColor('#FFFFFF')
    .borderRadius(24)
    .shadow({ radius: 24, color: '#130C1530', offsetY: 8 })
  }

  @Builder
  private SourceTip() {
    if (this.audioSource === 'system') {
      Row() {
        Text('内录')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor('#725FF0')
          .padding({ left: 9, right: 9, top: 5, bottom: 5 })
          .backgroundColor('#EDEAFE')
          .borderRadius(10)
        Text('开始后需在系统弹窗中授权；部分应用会禁止被内录。')
          .layoutWeight(1)
          .fontSize(12)
          .fontColor('#706B7D')
          .lineHeight(19)
          .margin({ left: 10 })
      }
      .width('100%')
      .padding(14)
      .backgroundColor('#F2F0FA')
      .borderRadius(16)
    } else {
      Row() {
        Text('隐私')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor('#2A9B66')
          .padding({ left: 9, right: 9, top: 5, bottom: 5 })
          .backgroundColor('#E4F6EE')
          .borderRadius(10)
        Text('录音仅在翻译期间开启，应用进入后台会自动停止。')
          .layoutWeight(1)
          .fontSize(12)
          .fontColor('#706B7D')
          .lineHeight(19)
          .margin({ left: 10 })
      }
      .width('100%')
      .padding(14)
      .backgroundColor('#F2F0FA')
      .borderRadius(16)
    }
  }

  @Builder
  private BottomControls() {
    Column() {
      if (this.errorText.length > 0) {
        Text(this.errorText)
          .width('100%')
          .fontSize(13)
          .fontColor('#B53E3E')
          .backgroundColor('#FFF0F0')
          .borderRadius(13)
          .padding(12)
          .margin({ bottom: 10 })
      }

      Row() {
        Button('清空')
          .width(88)
          .height(56)
          .fontSize(16)
          .fontColor('#625D6E')
          .backgroundColor('#EEEAF5')
          .borderRadius(18)
          .enabled(this.inputText.length > 0 || this.outputText.length > 0)
          .onClick(() => {
            this.session.clearTranscripts();
          })

        Button(this.primaryButtonText())
          .layoutWeight(1)
          .height(58)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .backgroundColor(this.sessionState === SessionState.LIVE ? '#E05261' : '#725FF0')
          .borderRadius(19)
          .margin({ left: 12 })
          .onClick(() => {
            this.toggleSession();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: 12, bottom: 12 })
    .backgroundColor('#F9F8FC')
  }

  build() {
    Column() {
      Column() {
        this.Header()
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16, bottom: 12 })

      Scroll(this.pageScroller) {
        Column({ space: 16 }) {
          this.StatusPanel()
          this.TranscriptPanel()
          this.SourceTip()
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 4, bottom: 20 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)

      this.BottomControls()
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F7F6FC')
  }
}

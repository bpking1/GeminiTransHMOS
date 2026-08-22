import { common } from '@kit.AbilityKit';
import {
  AppSettings,
  LANGUAGES,
  LanguageItem,
  languageName
} from '../model/AppSettings';
import { SettingsStore } from '../service/SettingsStore';
import { Log } from '../util/Logger';

@Entry
@Component
struct SettingsPage {
  @State private apiKey: string = '';
  @State private apiBase: string = 'https://generativelanguage.googleapis.com';
  @State private targetLanguage: string = 'zh-Hans';
  @State private audioSource: string = 'mic';
  @State private playbackEnabled: boolean = false;
  @State private playbackVolume: number = 0.8;
  @State private showOriginal: boolean = true;
  @State private captionFontSize: number = 25;
  @State private saveStatus: string = '';
  @State private saving: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const settings: AppSettings = await SettingsStore.load(context);
      this.apiKey = settings.apiKey;
      this.apiBase = settings.apiBase;
      this.targetLanguage = settings.targetLanguage;
      this.audioSource = settings.audioSource;
      this.playbackEnabled = settings.playbackEnabled;
      this.playbackVolume = settings.playbackVolume;
      this.showOriginal = settings.showOriginal;
      this.captionFontSize = settings.captionFontSize;
      Log.info(`SettingsPage loaded: apiBase=${this.apiBase}, targetLang=${this.targetLanguage}, hasApiKey=${this.apiKey.length > 0}`);
    } catch (error) {
      Log.error(`SettingsPage load failed: ${JSON.stringify(error)}`);
      this.saveStatus = `读取设置失败：${JSON.stringify(error)}`;
    }
  }

  private async save(): Promise<void> {
    if (this.saving) {
      return;
    }
    this.saving = true;
    this.saveStatus = '';
    try {
      const settings: AppSettings = new AppSettings();
      settings.apiKey = this.apiKey;
      settings.apiBase = this.apiBase;
      settings.targetLanguage = this.targetLanguage;
      settings.audioSource = this.audioSource;
      settings.playbackEnabled = this.playbackEnabled;
      settings.playbackVolume = this.playbackVolume;
      settings.showOriginal = this.showOriginal;
      settings.captionFontSize = this.captionFontSize;

      Log.info(`Saving settings: apiBase=${settings.apiBase}, targetLang=${settings.targetLanguage}, source=${settings.audioSource}`);
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await SettingsStore.save(context, settings);
      this.saving = false;
      try {
        this.getUIContext().getRouter().back();
      } catch (error) {
        Log.error(`Failed to navigate back: ${JSON.stringify(error)}`);
      }
    } catch (error) {
      this.saving = false;
      Log.error(`Save settings failed: ${JSON.stringify(error)}`);
      this.saveStatus = `保存失败：${JSON.stringify(error)}`;
    }
  }

  private languageOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    for (let index = 0; index < LANGUAGES.length; index++) {
      options.push({ value: LANGUAGES[index].name });
    }
    return options;
  }

  private languageIndex(): number {
    for (let index = 0; index < LANGUAGES.length; index++) {
      if (LANGUAGES[index].code === this.targetLanguage) {
        return index;
      }
    }
    return 0;
  }

  @Builder
  private SectionHeader(title: string, subtitle: string) {
    Column() {
      Text(title)
        .width('100%')
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor('#201D2A')
      Text(subtitle)
        .width('100%')
        .fontSize(12)
        .fontColor('#888394')
        .lineHeight(18)
        .margin({ top: 4 })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .margin({ top: 8, bottom: 10 })
  }

  @Builder
  private FieldLabel(title: string, tip: string) {
    Column() {
      Text(title)
        .width('100%')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor('#3D3947')
      if (tip.length > 0) {
        Text(tip)
          .width('100%')
          .fontSize(11)
          .fontColor('#9994A2')
          .lineHeight(17)
          .margin({ top: 3 })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  private ConnectionCard() {
    Column({ space: 15 }) {
      this.FieldLabel('Gemini API Key', '密钥只保存在当前应用的本地偏好设置中')
      TextInput({ text: this.apiKey, placeholder: '输入 Google AI Studio API Key' })
        .type(InputType.Password)
        .showPasswordIcon(true)
        .height(50)
        .fontSize(15)
        .backgroundColor('#F4F2F8')
        .borderRadius(14)
        .padding({ left: 14, right: 14 })
        .onChange((value: string) => {
          this.apiKey = value;
        })

      Divider().color('#ECE9F1')

      this.FieldLabel('API Base URL', '可填写官方地址或兼容 Gemini Live 的自建代理')
      TextInput({ text: this.apiBase, placeholder: 'https://generativelanguage.googleapis.com' })
        .type(InputType.Normal)
        .height(50)
        .fontSize(14)
        .backgroundColor('#F4F2F8')
        .borderRadius(14)
        .padding({ left: 14, right: 14 })
        .onChange((value: string) => {
          this.apiBase = value;
        })

      Divider().color('#ECE9F1')

      this.FieldLabel('目标语言', 'Gemini 会自动识别输入语言')
      Select(this.languageOptions())
        .selected(this.languageIndex())
        .value(languageName(this.targetLanguage))
        .width('100%')
        .height(50)
        .font({ size: 15 })
        .fontColor('#393444')
        .selectedOptionFontColor('#725FF0')
        .backgroundColor('#F4F2F8')
        .borderRadius(14)
        .onSelect((index: number, value: string) => {
          const item: LanguageItem | undefined = LANGUAGES[index];
          if (item !== undefined) {
            this.targetLanguage = item.code;
          }
          console.info(`Selected language: ${value}`);
        })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(18)
    .backgroundColor('#FFFFFF')
    .borderRadius(22)
  }

  @Builder
  private AudioCard() {
    Column({ space: 15 }) {
      this.FieldLabel('音频来源', '系统内录会弹出鸿蒙系统授权窗口')
      Row() {
        Button('麦克风')
          .layoutWeight(1)
          .height(46)
          .fontColor(this.audioSource === 'mic' ? '#FFFFFF' : '#696474')
          .backgroundColor(this.audioSource === 'mic' ? '#725FF0' : Color.Transparent)
          .borderRadius(13)
          .onClick(() => {
            this.audioSource = 'mic';
          })
        Button('系统内录')
          .layoutWeight(1)
          .height(46)
          .fontColor(this.audioSource === 'system' ? '#FFFFFF' : '#696474')
          .backgroundColor(this.audioSource === 'system' ? '#725FF0' : Color.Transparent)
          .borderRadius(13)
          .onClick(() => {
            this.audioSource = 'system';
          })
      }
      .width('100%')
      .padding(4)
      .backgroundColor('#F1EFF6')
      .borderRadius(16)

      if (this.audioSource === 'system') {
        Text('内录使用 HarmonyOS 6 API 20 原生能力，并排除本应用播放的译音。能否采集取决于声音来源应用的安全策略。')
          .width('100%')
          .fontSize(12)
          .fontColor('#766F86')
          .lineHeight(19)
          .padding(12)
          .backgroundColor('#F4F1FF')
          .borderRadius(13)
      }

      Divider().color('#ECE9F1')

      Row() {
        Column() {
          Text('播放译文语音')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor('#3D3947')
          Text('实时播放 Gemini 返回的 24 kHz 语音')
            .fontSize(11)
            .fontColor('#9994A2')
            .margin({ top: 3 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.playbackEnabled })
          .selectedColor('#725FF0')
          .onChange((isOn: boolean) => {
            this.playbackEnabled = isOn;
          })
      }
      .width('100%')

      if (this.playbackEnabled) {
        Row() {
          Text('音量')
            .fontSize(14)
            .fontColor('#5F596A')
          Slider({
            value: this.playbackVolume * 100,
            min: 0,
            max: 100,
            step: 1,
            style: SliderStyle.OutSet
          })
            .layoutWeight(1)
            .selectedColor('#725FF0')
            .trackColor('#E1DDEA')
            .margin({ left: 12, right: 12 })
            .onChange((value: number) => {
              this.playbackVolume = value / 100;
            })
          Text(`${Math.round(this.playbackVolume * 100)}%`)
            .width(44)
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor('#725FF0')
            .textAlign(TextAlign.End)
        }
        .width('100%')
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(18)
    .backgroundColor('#FFFFFF')
    .borderRadius(22)
  }

  @Builder
  private DisplayCard() {
    Column({ space: 17 }) {
      Row() {
        Column() {
          Text('显示原文')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor('#3D3947')
          Text('在译文下方显示识别到的原始语音')
            .fontSize(11)
            .fontColor('#9994A2')
            .margin({ top: 3 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.showOriginal })
          .selectedColor('#725FF0')
          .onChange((isOn: boolean) => {
            this.showOriginal = isOn;
          })
      }
      .width('100%')

      Divider().color('#ECE9F1')

      this.FieldLabel('译文字号', '跟随系统缩放，并可在此微调')
      Row() {
        Slider({
          value: this.captionFontSize,
          min: 18,
          max: 34,
          step: 1,
          style: SliderStyle.OutSet
        })
          .layoutWeight(1)
          .selectedColor('#725FF0')
          .trackColor('#E1DDEA')
          .onChange((value: number) => {
            this.captionFontSize = value;
          })
        Text(`${Math.round(this.captionFontSize)}`)
          .width(42)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#725FF0')
          .textAlign(TextAlign.End)
      }
      .width('100%')

      Text('实时翻译示例文字')
        .width('100%')
        .fontSize(this.captionFontSize)
        .fontWeight(FontWeight.Bold)
        .fontColor('#24202E')
        .padding(14)
        .backgroundColor('#F5F3F9')
        .borderRadius(14)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(18)
    .backgroundColor('#FFFFFF')
    .borderRadius(22)
  }

  @Builder
  private Header() {
    Row() {
      Button('‹')
        .width(44)
        .height(44)
        .fontSize(31)
        .fontColor('#413B4B')
        .backgroundColor('#ECE9F2')
        .borderRadius(14)
        .onClick(() => {
          try {
            this.getUIContext().getRouter().back();
          } catch (error) {
            console.error(`Failed to navigate back: ${JSON.stringify(error)}`);
          }
        })
      Column() {
        Text('设置')
          .fontSize(25)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1B1822')
        Text('连接、音频与显示')
          .fontSize(12)
          .fontColor('#8B8695')
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 13 })
      Blank()
    }
    .width('100%')
  }

  build() {
    Column() {
      Column() {
        this.Header()
      }
        .width('100%')
        .padding({ left: 18, right: 18, top: 16, bottom: 10 })

      Scroll() {
        Column() {
          this.SectionHeader('连接与语言', '配置 Gemini Live 翻译服务')
          this.ConnectionCard()
          this.SectionHeader('音频', '选择适合手机使用场景的采集与播放方式')
          this.AudioCard()
          this.SectionHeader('显示', '调整字幕内容和阅读尺寸')
          this.DisplayCard()

          Text('提示：移动端直接保存 API Key 适合个人使用；正式分发时建议改用服务端签发的临时令牌。')
            .width('100%')
            .fontSize(11)
            .fontColor('#9994A2')
            .lineHeight(18)
            .margin({ top: 18, bottom: 24 })
        }
        .width('100%')
        .padding({ left: 18, right: 18 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)

      Column() {
        if (this.saveStatus.length > 0) {
          Text(this.saveStatus)
            .width('100%')
            .fontSize(12)
            .fontColor('#B53E3E')
            .margin({ bottom: 8 })
        }
        Button(this.saving ? '正在保存…' : '保存设置')
          .width('100%')
          .height(56)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .backgroundColor('#725FF0')
          .borderRadius(18)
          .enabled(!this.saving)
          .onClick(() => {
            this.save();
          })
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 10, bottom: 14 })
      .backgroundColor('#F7F6FC')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F7F6FC')
  }
}

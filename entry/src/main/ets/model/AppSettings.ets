export class LanguageItem {
  code: string;
  name: string;

  constructor(code: string, name: string) {
    this.code = code;
    this.name = name;
  }
}

export const LANGUAGES: LanguageItem[] = [
  new LanguageItem('en', '英语'),
  new LanguageItem('es', '西班牙语'),
  new LanguageItem('fr', '法语'),
  new LanguageItem('de', '德语'),
  new LanguageItem('it', '意大利语'),
  new LanguageItem('ja', '日语'),
  new LanguageItem('ko', '韩语'),
  new LanguageItem('zh', '中文'),
  new LanguageItem('vi', '越南语'),
  new LanguageItem('pt', '葡萄牙语'),
  new LanguageItem('ru', '俄语'),
  new LanguageItem('hi', '印地语'),
  new LanguageItem('ar', '阿拉伯语'),
  new LanguageItem('th', '泰语'),
  new LanguageItem('id', '印度尼西亚语'),
  new LanguageItem('tr', '土耳其语')
];

export function languageName(code: string): string {
  for (let index = 0; index < LANGUAGES.length; index++) {
    if (LANGUAGES[index].code === code) {
      return LANGUAGES[index].name;
    }
  }
  return code.toUpperCase();
}

export class AppSettings {
  apiKey: string = '';
  apiBase: string = 'https://generativelanguage.googleapis.com';
  targetLanguage: string = 'zh';
  audioSource: string = 'system';
  playbackEnabled: boolean = false;
  playbackVolume: number = 0.8;
  showOriginal: boolean = true;
  captionFontSize: number = 25;
  pipBgOpacity: number = 75;
  subtitleLineCount: number = 2;

  normalize(): void {
    this.apiKey = this.apiKey.trim();
    this.apiBase = this.apiBase.trim();
    if (this.apiBase.length === 0) {
      this.apiBase = 'https://generativelanguage.googleapis.com';
    }
    this.playbackVolume = Math.max(0, Math.min(1, this.playbackVolume));
    this.captionFontSize = Math.max(10, Math.min(36, Math.round(this.captionFontSize)));
    this.pipBgOpacity = Math.max(0, Math.min(100, Math.round(this.pipBgOpacity)));
    this.subtitleLineCount = Math.max(1, Math.min(5, Math.round(this.subtitleLineCount)));
    if (this.audioSource !== 'mic' && this.audioSource !== 'system') {
      this.audioSource = 'system';
    }
    if (this.targetLanguage === 'zh-Hans') {
      this.targetLanguage = 'zh';
    } else if (this.targetLanguage === 'pt-BR') {
      this.targetLanguage = 'pt';
    }
    let languageSupported: boolean = false;
    for (let index = 0; index < LANGUAGES.length; index++) {
      if (LANGUAGES[index].code === this.targetLanguage) {
        languageSupported = true;
        break;
      }
    }
    if (!languageSupported) {
      this.targetLanguage = 'zh';
    }
  }
}

import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { AppSettings } from '../model/AppSettings';

const STORE_NAME: string = 'gemini_live_translate_settings';

export class SettingsStore {
  static async load(context: common.UIAbilityContext): Promise<AppSettings> {
    const store: preferences.Preferences = await preferences.getPreferences(context, STORE_NAME);
    const settings: AppSettings = new AppSettings();

    settings.apiKey = store.getSync('api_key', '') as string;
    settings.apiBase = store.getSync(
      'api_base', 'https://generativelanguage.googleapis.com') as string;
    settings.targetLanguage = store.getSync('target_language', 'zh') as string;
    settings.audioSource = store.getSync('audio_source', 'system') as string;
    settings.playbackEnabled = store.getSync('playback_enabled', false) as boolean;
    settings.playbackVolume = store.getSync('playback_volume', 0.8) as number;
    settings.showOriginal = store.getSync('show_original', true) as boolean;
    settings.captionFontSize = store.getSync('caption_font_size', 25) as number;
    settings.pipBgOpacity = store.getSync('pip_bg_opacity', 75) as number;
    settings.subtitleLineCount = store.getSync('subtitle_line_count', 2) as number;
    settings.normalize();
    return settings;
  }

  static async save(context: common.UIAbilityContext, settings: AppSettings): Promise<void> {
    settings.normalize();
    const store: preferences.Preferences = await preferences.getPreferences(context, STORE_NAME);
    store.putSync('api_key', settings.apiKey);
    store.putSync('api_base', settings.apiBase);
    store.putSync('target_language', settings.targetLanguage);
    store.putSync('audio_source', settings.audioSource);
    store.putSync('playback_enabled', settings.playbackEnabled);
    store.putSync('playback_volume', settings.playbackVolume);
    store.putSync('show_original', settings.showOriginal);
    store.putSync('caption_font_size', settings.captionFontSize);
    store.putSync('pip_bg_opacity', settings.pipBgOpacity);
    store.putSync('subtitle_line_count', settings.subtitleLineCount);
    await store.flush();
  }
}

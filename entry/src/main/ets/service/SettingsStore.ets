import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { AppSettings } from '../model/AppSettings';

const STORE_NAME: string = 'gemini_live_translate_settings';

export class SettingsStore {
  static async load(context: common.UIAbilityContext): Promise<AppSettings> {
    const store: preferences.Preferences = await preferences.getPreferences(context, STORE_NAME);
    const settings: AppSettings = new AppSettings();

    settings.apiKey = await store.get('api_key', '') as string;
    settings.apiBase = await store.get(
      'api_base', 'https://generativelanguage.googleapis.com') as string;
    settings.targetLanguage = await store.get('target_language', 'zh') as string;
    settings.audioSource = await store.get('audio_source', 'system') as string;
    settings.playbackEnabled = await store.get('playback_enabled', false) as boolean;
    settings.playbackVolume = await store.get('playback_volume', 0.8) as number;
    settings.showOriginal = await store.get('show_original', true) as boolean;
    settings.captionFontSize = await store.get('caption_font_size', 25) as number;
    settings.pipBgOpacity = await store.get('pip_bg_opacity', 75) as number;
    settings.subtitleLineCount = await store.get('subtitle_line_count', 2) as number;
    settings.normalize();
    return settings;
  }

  static async save(context: common.UIAbilityContext, settings: AppSettings): Promise<void> {
    settings.normalize();
    const store: preferences.Preferences = await preferences.getPreferences(context, STORE_NAME);
    await store.put('api_key', settings.apiKey);
    await store.put('api_base', settings.apiBase);
    await store.put('target_language', settings.targetLanguage);
    await store.put('audio_source', settings.audioSource);
    await store.put('playback_enabled', settings.playbackEnabled);
    await store.put('playback_volume', settings.playbackVolume);
    await store.put('show_original', settings.showOriginal);
    await store.put('caption_font_size', settings.captionFontSize);
    await store.put('pip_bg_opacity', settings.pipBgOpacity);
    await store.put('subtitle_line_count', settings.subtitleLineCount);
    await store.flush();
  }
}

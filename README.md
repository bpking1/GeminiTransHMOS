# Gemini Live Translate（HarmonyOS 6 手机端）

这是桌面版实时翻译功能的 HarmonyOS 6 原生实现。工程采用 Stage 模型、ArkTS/ArkUI 和少量 C++ Native API，目标与最低 SDK 均为 `6.0.0(20)`。

## 已实现功能

- Gemini 3.5 Live Translate 实时语音翻译。
- 16 种常用目标语言，自动识别输入语言。
- 麦克风采集：16 kHz、单声道、PCM16，每 100 ms 发送一次。
- 系统内录：使用 HarmonyOS 6 API 20 的 OHAudio 播放采集授权接口，采集 `MEDIA` 并排除本应用声音；48 kHz 立体声会实时下混并转换为 16 kHz 单声道。
- 原文与译文实时字幕，支持长按复制、清空和字号调节。
- 可选播放 24 kHz PCM16 译文语音，并支持音量调节和打断清空。
- API Key、API Base URL、音源、目标语言和显示设置持久化。
- 进入后台自动停止采集、网络会话和音频播放，避免手机端后台误录音。

桌面端的悬浮 HUD、鼠标拖动/缩放和托盘菜单不适合手机，已改成顶部状态区、正文字幕卡和底部大尺寸操作按钮。当前 Gemini Live Translation 模型只支持音频翻译，不支持工具或系统指令，因此桌面版的“System prompt”没有出现在手机端。

## 环境要求

- 支持 HarmonyOS 6 的 DevEco Studio。
- 已安装 HarmonyOS SDK `6.0.0(20)`。
- HarmonyOS 6 真机。麦克风可在模拟器验证，但系统内录应在真机验证。
- Gemini API Key，可从 [Google AI Studio](https://aistudio.google.com/apikey) 获取。

## 运行

1. 在 DevEco Studio 中选择 **Open Project**，打开本目录 `harmonyos/`。
2. 等待 Hvigor 同步完成，并在 **Project Structure > Signing Configs** 配置自动签名。
3. 连接 HarmonyOS 6 手机，选择 `entry` 模块并运行。
4. 首次打开进入“设置”，填写 API Key、目标语言和音频来源后保存。
5. 返回首页点击“开始翻译”。麦克风模式会请求录音权限；系统内录模式会显示系统授权窗口。

系统内录能否取得声音还取决于声音来源应用的安全策略；银行、DRM 视频、通话等受保护场景可能拒绝被采集。Native 层使用 `MEDIA | EXCLUDING_SELF`，所以播放译文语音时不会再次把自身声音送给 Gemini。

本实现遵循手机端隐私优先策略，应用进入后台会自动停止翻译。翻译其他应用声音时，请使用系统分屏或视频小窗，让本应用保持在前台并保留可见的停止按钮。

## 工程结构

```text
harmonyos/
├── AppScope/                              # 应用级名称与图标
├── build-profile.json5                    # HarmonyOS 6 / API 20 产品配置
├── hvigor/                                # Hvigor 配置
└── entry/
    └── src/main/
        ├── cpp/
        │   ├── AudioPlaybackCapture.cpp   # API 20 系统内录与线程安全环形缓冲
        │   └── CMakeLists.txt
        ├── ets/
        │   ├── entryability/              # 生命周期与后台停止策略
        │   ├── model/                     # 设置和语言列表
        │   ├── pages/                     # 手机首页、设置页
        │   └── service/
        │       ├── AudioCaptureService.ets
        │       ├── GeminiLiveClient.ets
        │       ├── PcmAudioPlayer.ets
        │       ├── SettingsStore.ets
        │       └── TranslationSession.ets
        ├── module.json5                   # INTERNET / MICROPHONE 权限
        └── resources/
```

## 协议与音频格式

客户端直接连接：

```text
wss://generativelanguage.googleapis.com/ws/
google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=...
```

会话模型为 `models/gemini-3.5-live-translate-preview`。输入是 16 kHz、单声道、16-bit little-endian PCM；输出是 24 kHz、单声道、16-bit little-endian PCM。

## 发布前安全建议

当前实现与桌面版一致，允许用户直接填写 API Key，适合个人使用和内部测试。若要公开发布，不建议把长期 API Key 放在客户端；应由自己的服务端签发短期 Gemini Live 临时令牌，并限制有效期、次数、模型与翻译配置。

## 官方接口参考

- [Google Gemini Live Translation](https://ai.google.dev/gemini-api/docs/live-api/live-translate)
- [OpenHarmony OHAudio 音频录制与系统内录样例](https://gitcode.com/openharmony/applications_app_samples/tree/master/code/DocsSample/Media/Audio/AudioCapturerSampleC)
- [HarmonyOS AudioCapturer 录音指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/using-audiocapturer-for-recording)

# VoiceInput

VoiceInput 是一款面向 Apple Silicon Mac 的离线语音输入应用。它保留原有的原生 macOS 菜单栏和底部语音胶囊界面，并使用从 CapsWriter for macOS 精简迁入的输入链路与 Qwen3-ASR MLX 后端。

长按 **Caps Lock** 开始录音，松开后识别并输入到当前光标位置；短按 **Caps Lock** 仍然切换大小写。

## 系统要求

- Apple Silicon（M1 及之后）
- macOS 14 或更高版本
- [uv](https://docs.astral.sh/uv/)：安装外置 Python 3.13 运行环境
- 约 2.3 GB 可用空间用于默认 8-bit 模型

VoiceInput 不支持 Intel Mac，也不会注册登录时自动启动。

## 安装

~~~bash
brew install uv
make install
~~~

安装命令会：

1. 在 ~/Library/Application Support/VoiceInput/Runtime 创建 Python 3.13 环境；
2. 安装 Qwen3-ASR、MLX、录音、快捷键和热词依赖；
3. 构建并安装 /Applications/VoiceInput.app；
4. 安装可选的 ~/.local/bin/voiceinput 诊断命令。

模型不会进入 Git 仓库或应用包。

## 安装模型

打开 VoiceInput，进入 **Settings… → Model**：

- **Qwen3-ASR 1.7B 8-bit**：默认，优先保证识别质量；
- **Qwen3-ASR 1.7B 4-bit**：占用更少内存；
- 中国大陆网络可勾选 **Use mainland China mirror**。

界面会显示下载进度。也可使用备用命令：

~~~bash
voiceinput install-model 8bit
voiceinput install-model 4bit --mirror
~~~

模型保存在：

~~~text
~/Library/Application Support/VoiceInput/Models/
~~~

## 首次授权

VoiceInput 需要以下系统权限：

- 麦克风：录音；
- 辅助功能：自动粘贴和键盘控制；
- 输入监控：捕获 remap 后的 Caps Lock 事件。

首次启动会请求麦克风和辅助功能权限。若菜单显示 **Permission required**，请打开：

**系统设置 → 隐私与安全性 → 辅助功能 / 输入监控**

启用 VoiceInput 后，从菜单选择 **Restart Engine**。不要同时运行旧 CapsWriter 与 VoiceInput；本项目不会自动停止或修改旧 CapsWriter。

## 使用

1. 手动打开 VoiceInput；后台 Qwen 模型会自动加载。
2. 菜单显示 **VoiceInput · Ready** 后，在任意输入框长按 **Caps Lock**。
3. 底部胶囊显示实时音量；松开后依次进入识别、可选 LLM 润色和自动粘贴。
4. 退出 VoiceInput 时，后台引擎同时退出并恢复原来的 Caps Lock 映射。

菜单提供：

- 启动、停止和重新启动引擎；
- 选择自动、中文、英文、西班牙语、意大利语或法语；
- 复制最近一次结果；
- 打开统一设置窗口；
- 权限异常时打开系统隐私设置。

## 设置

- **General**：语言、自动粘贴、中英文语气词清理；
- **Model**：模型选择、下载、镜像和移至废纸篓；
- **Hotwords**：使用“最终文本 | 别名1 | 别名2”格式管理热词，保存后即时生效；
- **LLM**：可选 OpenAI-compatible 润色，默认关闭。

LLM API Key 只保存在 macOS Keychain；配置文件和日志不会记录密钥。不开启 LLM 时，语音识别完全离线。

## 隐私和数据目录

- 录音只保存在内存中，识别结束即释放；
- 不建立长期转录历史；
- 引擎退出时清空状态文件中的最近文本；
- 日志不记录原始音频、完整转录文本或 API Key。

~~~text
~/Library/Application Support/VoiceInput/
├── Models/
├── Runtime/
├── State/
├── config.json
└── hotwords.txt

~/Library/Logs/VoiceInput/
└── engine.log
~~~

## 备用 CLI

正常使用无需终端。排错时可运行：

~~~bash
voiceinput start
voiceinput stop
voiceinput restart
voiceinput status
voiceinput doctor
~~~

## 开发

~~~bash
make build
make run
~~~

Swift 前端位于 Sources/VoiceInput/，精简 Python 内核位于 Engine/voiceinput_engine/。运行环境和模型始终位于仓库外。

## 开源归属

Caps Lock remap、F18 事件监听、音素热词纠错和 Qwen3-ASR MLX 接入基于 CapsWriter for macOS / CapsWriter-Offline 的 MIT 许可代码。完整归属和许可文本见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

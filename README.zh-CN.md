# Rotap

[English](README.md) | 简体中文

录下 Mac 正在播放的声音，也可以同时录麦克风。原生 macOS App，不装虚拟声卡，不改你的扬声器或耳机设置。

## 功能

- **三种录制内容**：仅系统声音、仅麦克风、系统声音 + 麦克风（混在同一个文件里）。
- **选择来源**：全部系统声音，或只录某一个正在发声的 App。
- **格式**：M4A（AAC）或 WAV（24-bit）。
- **波形**：录音时实时显示，录完后可以在波形上拖动定位播放。
- **不打扰播放**：用 Core Audio Process Tap 旁听，输出设备照常工作，你听到的声音不受影响。

## 下载

在 [Releases](https://github.com/max1874/Rotap/releases) 下载最新的 `Rotap-<版本>.dmg`，把 Rotap 拖进「应用程序」。安装包经过 Developer ID 签名和 Apple 公证。

需要 **macOS 26** 或更高版本。App 界面目前只有中文。

## 权限

| 权限 | 什么时候问 | 用来做什么 |
| --- | --- | --- |
| 录制系统音频 | 第一次录系统声音时 | 读取其他 App 播放的声音 |
| 麦克风 | 第一次录麦克风时 | 录你的声音 |

录音只写到本机（默认 `~/Music/Rotap`，可以在设置里改）。Rotap 不联网，不上传任何东西。

## 从源码构建

需要 Xcode 26 或更高版本。

```sh
make app          # 维护者用：Developer ID 签名，产物在 build/Rotap.app
```

没有维护者证书时，用 ad-hoc 签名构建：

```sh
xcodebuild -project Rotap.xcodeproj -scheme Rotap -configuration Release \
  -destination 'generic/platform=macOS' CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

ad-hoc 签名的 App 每次重新构建后，系统都会把它当成新 App 重新询问权限。

`make release` / `make install` 是维护者的发版流程（签名、公证、发布 Release），依赖本仓库之外的工具。

## 实现

- `Audio/AudioRecorder.swift`：Process Tap 和麦克风放进同一个私有聚合设备，共享时钟；实时 IO 线程只做混音，经无锁环形缓冲交给写入线程编码写盘。
- `Audio/Waveform.swift`：波形在录音时顺手生成，存在文件的扩展属性里，打开旧录音不用重新分析。
- `Views/WaveformLayers.swift`：波形用 Core Animation 图层绘制，录音时界面 CPU 占用很低。

## License

[MIT](LICENSE)

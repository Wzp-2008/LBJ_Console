# Recovery Classic SPP OTA

协议参考：2026-09-10 的 APPBLE.md 第六节。

- 固件取分享站 3470，`TIME / reverse=false`，UI 展示上传时间。
- Main 阶段仍连接 BLE，订阅 FFF1 并发送带完整 SHA-256 的 `OTA_START`。
- Main 返回 `receiving` 后会重启；这次 BLE 断开是正常的模式切换。
- Updater 不提供 BLE/GATT。APP 改用相同蓝牙地址连接标准 Classic SPP
  (`00001101-0000-1000-8000-00805F9B34FB`，服务名 `LBJ OTA SPP`)。
- 收到 SPP 的 `LBJ Train Warning Ready` 握手后，发送带 LF 的完整命令
  `OTA_START <文件大小> <sha256>`，不能发送单独的 `start`；正常情况下等待
  `receiving` 后再传固件。
- SPP 固件帧是 `OTAD | uint32_le(length) | uint32_le(crc32) | payload`，
  当前客户端每个 payload 最大 4096 字节；会把文件流整理为 4096 字节一块，
  最后一块按剩余长度发送。
- 同时只允许一个数据块在途。每次写入后必须收到并校验对应的累计 ACK，
  例如 `{"state":"ack","received":4096,"total":1710096}`，确认
  `received` 正确增加后才能发送下一块。最后一块 ACK 成功后才发送
  `FINISH\n`，并且必须收到 `success` 才算成功；ACK 后默认间隔 10 ms。
- ACK 超时会关闭 SPP 会话，不重发旧块；上层会新建 SPP 会话并从
  `OTA_START` 开始自动重试一次，仍失败则要求用户重新发起 OTA。设备返回
  `error`/`aborted` 时立即停止发送，不发送 `FINISH`。

Android 由 `ClassicSppChannelHandler.kt` 管理 RFCOMM socket。Windows 由
`flutter_classic_bluetooth` 直接通过 Flutter 插件调用系统 RFCOMM 实现。Windows
若返回 access denied，应先在系统蓝牙设置中配对。

普通 BLE 扫描仍不按名称或 Service 筛选。首次使用手动选择，完成 GATT 服务
发现后才保存 `specifiedDeviceAddress`；后续普通连接按地址自动重连。设备改名
只修改设备 NVS，不改变保存的地址。

日志同时输出 Flutter 控制台、DevTools 和系统临时目录下的
`LBJ-Console-BLE.log`。实机验收应覆盖 Main BLE → Updater SPP → Main BLE、
SPP 中断重试，以及 Windows 已配对/未配对两种错误路径。

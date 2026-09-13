# 冗余代码清理 · 施工说明

> **本文件是施工单，不是变更记录。** 下面列出的改动**尚未执行**，交由执行 agent 逐项完成。
> 本文档作者只做了只读检查，未改动任何源码。

**检查基线**：`lib/` 31 个文件 11355 行；`flutter analyze` → 0 issue；`flutter test` → 125 个测试全绿；
无孤儿文件、无悬空 import。因此冗余不在编译期可见层面，而在 analyzer 看不见的地方。

**关于行号**：文中的行号是检查时的行号，编辑后会漂移。每一项都给了**可搜索锚点**，请以锚点为准。
**关于复验**：P1/P2 每一项都给了复验命令，删除前请先跑一遍确认零引用仍成立。

---

## 0. 全局约束（先读这一节）

### 0.1 红线：以下内容看起来像死代码，但**不要删**

| 对象 | 原因 |
|---|---|
| `lib/services/file_share_api.dart`、`lib/services/http_download.dart` | **有真实调用方**（`app_update_service.dart:6-7`、`firmware_ota_service.dart:8-9`）。最初的正则拓扑扫描曾误报为孤儿，已纠正 |
| `pubspec.yaml` 的 `flutter_blue_plus` | 无 Dart 文件直接 import，但 `flutter_blue_plus_windows` 的入口 `export 'package:flutter_blue_plus/flutter_blue_plus.dart' hide FlutterBluePlus;` 把它 re-export 出来，全部 BLE 类型都从这里来 |
| `pubspec.yaml` 的 `sqlite3_flutter_libs` | 无 Dart import，但它是提供原生 sqlite3 库的插件，已注册进 `windows/flutter/generated_plugins.cmake`、`linux/...` 等 registrant；删了桌面端 SQLite 会在运行时挂 |
| `third_party/win_ble` 与 `dependency_overrides` | 必要的 fork（UTF-8/分片 IPC 修复，`PATCHES.md` 有记录），`test/ble_ota_test.dart:10` 直接引用其 `ipc_decoder.dart` |
| `recovery_ota.dart:305`、`recovery_ota.dart:507` 的 `control('CANCEL')` | 这是**失败/超时后的设备侧收尾**（有 `!success && !remoteFailure && !ackTimedOut` 守卫、且在 catch 内），不是用户取消。用户要求的是"OTA 一旦开始不允许**用户**取消"，这两处必须保留 |
| `TrainRecord.rssi`（字段/JSON/DB 列/`merge_service.dart:97`） | 用户明确决定：**不展示，但要保存**。不要加 UI，也不要删 |
| `assets/*.csv`、`assets/tray_icon.ico` | 四个资产全部在用（`loco_info_util.dart:16`、`train_type_util.dart:13`、`loco_type_util.dart:21` + `database_service.dart:1492`、`windows_tray_service.dart:28,30`） |
| `DatabaseService.getAllRecords()`、`deleteRecord()` | 生产代码零调用，但**测试在用**（`test/windows_platform_test.dart:57`、`test/crud_test.dart:62`）→ 归类为"测试专用 API"，保留 |
| `windows/runner/lbj_updater.cpp` 及 CMake 里的 `lbj_updater` target | Windows 更新器，`windows/CMakeLists.txt:81` 已接线，是活的 |
| `linux/` | 用户明确要求保留 |
| `LBJ_Console_output.json`（15.8 MB）、`keystore.jks` | 前者是 3 个测试的活夹具（gitignore 正确），后者由 CI 从 secret 生成（设计如此） |

### 0.2 每步之后必须验证

```bash
flutter analyze          # 必须 0 issue
flutter test             # 必须全绿
```

---

## 1. P0 —— 已明确决定，可直接执行

### P0-1 删除 `BLEService.cancelFirmwareOta()`

- 文件：`lib/services/ble_service.dart`，锚点 `Future<void> cancelFirmwareOta() async {`（当前 664-670 行）
- 现状：全仓零调用。它是唯一的"用户取消 OTA"入口（向 SPP transport 或 FFE1 写 `CANCEL`）
- 目标：整段删除
- 依据：**OTA 升级一旦开始不允许取消**
- 复验：`rg "cancelFirmwareOta" -g "*.dart"` → 应为 0 命中
- ⚠ 不要顺手删 `recovery_ota.dart` 里的 CANCEL（见 0.1）

### P0-2 删除 `BLEService.dispose()`

- 文件：`lib/services/ble_service.dart`，锚点 `void dispose() {`（当前 843-854 行，`BLEService` 类的最后一个方法）
- 现状：全仓零调用（没有 `BLEService().dispose()` 这类调用）；它是 7 个 `StreamController` 的唯一 `close()` 点
- 目标：整段删除。删除后单例生命周期与进程一致（本项目可接受）
- 复验：`rg "_bleService\.dispose|BLEService\(\)\.dispose" -g "*.dart"` → 0 命中
- ⚠ 别误删其它类的 `dispose()`（`history_screen.dart`、`main_screen.dart` 里有真正的 State.dispose）

### P0-3 删除 `app_settings` 的 21 个死配置列（用户已确认没有 < v19 的存量库）

- 文件：`lib/services/database_service.dart`
- **保留 6 列**：`id`、`specifiedDeviceAddress`、`backgroundServiceEnabled`、`notificationEnabled`、`mergeRecordsEnabled`、`hideUngroupableRecords`
- **删除这 21 列**（全仓零读写，唯一出现处是本文件的 schema 声明）：
  `deviceName`、`currentTab`、`historyEditMode`、`historySelectedRecords`、`historyExpandedStates`、
  `historyScrollPosition`、`historyScrollOffset`、`settingsScrollPosition`、`mapCenterLat`、`mapCenterLon`、
  `mapZoomLevel`、`mapRailwayLayerVisible`、`mapRotation`、`mapType`、`searchOrderList`、`autoConnectEnabled`、
  `hideTimeOnlyRecords`、`groupBy`、`timeWindow`、`mapTimeFilter`、`mapSettingsTimestamp`

施工步骤（**三处必须同步改，漏一处会让 `_rebuildSettingsTable` 的 insert 报"no such column"**；本次因为要连 `_rebuildSettingsTable` 一起删，所以只需同步前两处）：

1. `_createSettingsTable()` 的 `CREATE TABLE` DDL（锚点 `CREATE TABLE IF NOT EXISTS $appSettingsTable`）→ 只留 6 列
2. `_defaultSettings()`（锚点 `Map<String, dynamic> _defaultSettings() {`）→ 只留 `id` 与 5 个活列
3. **删除** `_settingsColumns`（锚点 `static const List<String> _settingsColumns`）与 `_rebuildSettingsTable()`（锚点 `Future<void> _rebuildSettingsTable(Database db) async {`），以及 `_onUpgrade` 里的 `if (oldVersion < 19) { await _rebuildSettingsTable(db); }`
4. **删除**只添加死列的迁移分支（它们 ALTER 出来的列没有任何读取方）：
   - `if (oldVersion < 2)` → `hideTimeOnlyRecords`
   - `if (oldVersion < 4)` → `mapTimeFilter`（含 `_columnExists` 判断）
   - `if (oldVersion < 5)` → `mapType`
   - `if (oldVersion < 7)` → `mapSettingsTimestamp`
5. **保留**其余全部迁移分支：`oldVersion < 6`（`hideUngroupableRecords`，活列）、`< 10`/`< 11`/`< 12`/`< 13`/`< 14`/`< 15`、`== 15`、`< 17`、`< 18`
6. 不要写破坏性迁移去 `DROP COLUMN`：已存在的库物理上留着的多余列无害（SQLite 允许多余列，且无人读）

- 验收：新库执行 `PRAGMA table_info(app_settings)` → 恰好 6 列
- 依据：用户确认"没有 v19 的库需要升级，死列可以删"

### P0-4 删除指向不存在文件的 proguard 引用（保留代码最小化）

- 文件：`android/app/build.gradle.kts`，锚点 `proguardFiles(`
- 现状：第 47-50 行 `proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")`，而 `android/app/proguard-rules.pro` **从不存在**（`git log --all -- android/app/proguard-rules.pro` 为空，即从未入库）
- 目标：**删除整个 `proguardFiles(...)` 块**（连同最后的逗号）
- **保留** `isMinifyEnabled = true` 与 `isShrinkResources = true` —— 这就是用户要的"代码最小化"；AGP 在开启 minify 时默认使用 `proguard-android-optimize.txt`，行为不变
- 依据：用户"proguard 干脆就删了，不要了，但是其所附带的代码最小化还是需要的"
- 验收：`flutter build apk --release` 通过（需 `KEYSTORE_PASSWORD`/`KEY_ALIAS`/`KEY_PASSWORD` 环境变量与根目录 `keystore.jks`），且生成 `build/app/outputs/mapping/release/mapping.txt`（有 mapping.txt 即证明 R8 真的跑了）

### P0-5 删除 `ios/`、`macos/`、`web/`（保留 `linux/`）

- 现状：CI 只构建 Android + Windows；`tool/release_build.dart:5` 也只接受这两个平台。ios 45 / macos 28 / web 7 个跟踪文件，没有任何构建目标
- 目标：删除这三个目录（保留 `linux/`）
- 同步修改 `pubspec.yaml` 的 `flutter_launcher_icons`（锚点 `flutter_launcher_icons:`）：删掉 `ios: true` 一行（`android: true` 与 `windows: generate: true` 保留；该块没有 macos 项）
- ⚠ **不要**因为删了 ios/macos 目录就去删 Dart 侧的平台分支：
  - `background_service.dart` 的 `IosConfiguration(...)` 是 `FlutterBackgroundService.configure` 的**必需参数**，删了编译不过
  - `notification_service.dart:35,40-41` 的 `DarwinInitializationSettings` 若为可选参数可一并删，**以编译结果为准**，编译器报错就保留
  - `sqflite_initializer.dart` 的 `kIsWeb` 早退：可留（廉价守卫）可删，执行者自行判断
- 不要重新执行 `flutter create --platforms=ios,macos,web` 把这些目录生成回来
- 验收：`git status` 里三者显示为删除；`flutter analyze` + `flutter test` 仍通过

### P0-6 `history_screen` 定位路径 Android/Windows 统一

- 文件：`lib/screens/history_screen.dart`，锚点 `final locationSettings = AndroidSettings(`（当前 1230 行）
- 现状：用的是 Android 专有的 `AndroidSettings(..., forceLocationManager: true)`，但 Windows 也走这条 `_getCurrentLocation` 路径
- 目标：改为平台中立的 `LocationSettings(accuracy: LocationAccuracy.high)`（去掉 `forceLocationManager`）
- 依据：用户"history_screen 在 Android 和 Windows 上走统一路径"
- 验收：两端"定位到我的位置"都能拿到坐标（Android 真机 + Windows 各验一次）

### P0-7 修 `.gitignore` 的裸 `linux` / `windows` 模式

- 文件：`.gitignore`，第 22 行 `linux`、第 23 行 `windows`
- 现状：这两条裸模式会**静默忽略**这两个目录下的任何新文件。实测：`git check-ignore --no-index -v windows/runner/x.cpp` → 命中 `.gitignore:23:windows`。现有 19 个 `windows/` 跟踪文件是规则之前入库的，纯属侥幸
- 目标：删除这两行（`flutter/ephemeral/` 已在第 24 行单独覆盖；`windows/` 是 CI 构建目标、`linux/` 按要求保留）
- 可选顺带清理重复模式：`*.jks`×3、`*.keystore`×3、`*.iml`×2、`local.properties`×2、`.gradle`×2、`.externalNativeBuild`×2、`.idea/*`×4

### P0-8 删除 `msix` 依赖与 `msix_config` 块

- 文件：`pubspec.yaml`，第 53 行 `msix: ^3.16.12`，第 134-140 行 `msix_config:` 整块
- 现状：全仓零调用 —— CI、`tool/release_build.dart`、README、OTA_RECOVERY 都没有 `dart run msix:create`
- 目标：两处都删；然后 `flutter pub get`，确认 `pubspec.lock` 里不再有 msix
- 注意：`msix_config.logo_path: assets/icon.png` 是 `assets/icon.png` 的引用之一，但该文件还被 `flutter_launcher_icons` 使用，**文件本身保留**

### P0-9 `deleteMapState`：保留并接线（这是"漏接线"，不是死代码）

**结论与依据**：`record_map_states` 以 `<uniqueId>_record_map`、`<groupKey>_group_map` 为键持久化。
单条删除（`deleteRecord`）、批量删除（`deleteRecords`）、清空（`deleteAllRecords`）三条路径**只清记录表、FTS 与合并缓存，从不清地图状态**；
只有设置页"清空数据"额外调了 `clearAllMapStates()`（`settings_screen.dart:849`）。
所以删除记录会留下孤儿地图状态行 → `deleteMapState` 属于**漏接线**，应当保留并接上。

**施工**（文件 `lib/services/map_state_service.dart`）：

1. 删除 `factory MapStateService() => instance;`（锚点 `factory MapStateService() => instance;`）—— 全仓只用 `.instance`
2. 在 `MapStateService._internal()` 里订阅已存在的删除通知 API：
   ```dart
   MapStateService._internal() {
     // 记录可能从任意路径被删除；地图状态以记录 id 为键，随记录一起清理。
     DatabaseService.instance.onRecordDeleted(_onRecordsDeleted);
   }

   void _onRecordsDeleted(List<String> deletedIds) {
     for (final id in deletedIds) {
       unawaited(deleteMapState(getSingleRecordMapKey(id)));
     }
   }
   ```
   说明：`DatabaseService.onRecordDeleted`（`database_service.dart:1165`）已存在且被三条删除路径调用（`:732`、`:752`、`:1134`），现有消费者是 `history_screen.dart:141`。`MapStateService` 本来就 import 了 `database_service.dart`，方向一致，无循环依赖。
3. **只在收到非空 id 列表时处理**：空列表代表 `deleteAllRecords`，已由 `settings_screen.dart:849` 的显式 `await clearAllMapStates()` 覆盖 —— 不要在订阅里再处理一次，避免双份逻辑
4. `deleteMapState` 同时清内存缓存与 DB，所以用它（而不是直接删表）能避免 `_memoryCache` 残留

- 验收：展开一张卡片让地图状态落库 → 删除该记录 → `SELECT count(*) FROM record_map_states WHERE key='<uniqueId>_record_map'` = 0

---

## 2. P1 —— 已验证零引用的死代码（逐条复验后可执行）

> 全部为"全仓标识符检索后仅剩声明处"的死公共 API。analyzer 不报是因为它们是 public。
> 每一项都给出复验命令；**复验命令返回 0 命中才删**。

| # | 文件 | 锚点（当前行号） | 说明 | 复验 |
|---|---|---|---|---|
| P1-1 | `lib/services/ble_service.dart` | `final StreamController<String> _statusController`(38-39)、`Stream<String> get statusStream`(53)、5 处 `_statusController.add(`(146/181/213/257/794) | 无任何监听者，5 次 add 全是 no-op；`close()` 只在 P0-2 要删的 dispose 里 | `rg "statusStream\|_statusController" -g "*.dart"` |
| P1-2 | `lib/services/ble_service.dart` | `Object? lastError;`(354)、`lastError = e;`(368) | 循环只可能经 `rethrow`(370) 退出（末轮必命中 `attempt >= attempts-1`），故 374 行的 `throw lastError ?? ...` 仅在 `attempts<=0` 时可达 → `lastError` 写后无人读。删除两个 lastError 语句，把 374 行简化为 `throw Exception('discoverServices failed');`（保留 throw 以满足编译路径） | `rg "lastError" lib/services/ble_service.dart` |
| P1-3 | `lib/services/ble_service.dart` | `_otaControlCharacteristic = otaControl;`(472) | 与 462 行同值的重复赋值；删 472 行 | 读 455-475 行确认 |
| P1-4 | `lib/services/ble_service.dart` | `String? get deviceAddress => connectedDeviceAddress;`(819)、`bool get isScanning => FlutterBluePlus.isScanningNow;`(837) | 零引用。真身在 `connectedDeviceAddress`(831) 与 177 行的 `FlutterBluePlus.isScanningNow` | `rg "\.deviceAddress\|\.isScanning\b" -g "*.dart"` |
| P1-5 | `lib/services/notification_service.dart` | `_settingsController`(27-28)、`settingsStream`(29)、5 处 add(60/88/97/102/189)、`cancelAllNotifications()`(196-198)、`dispose()`(200-202) | 零监听 / 零调用 | `rg "settingsStream\|_settingsController\|cancelAllNotifications" -g "*.dart"` |
| P1-6 | `lib/services/background_service.dart` | `setForegroundMode`(212-220) + `service.on('setAsForeground')`(93-95) + `service.on('setAsBackground')`(97-99) | `setForegroundMode` 零调用，而它是这两个消息的唯一发送方 → 两个监听器运行时永不触发。三处一起删。**保留** `service.on('stopService')`(102)（由 `stopService()`(203) 驱动） | `rg "setForegroundMode\|setAsForeground\|setAsBackground" -g "*.dart"` |
| P1-7 | `lib/services/background_service.dart` | 两个 `const AndroidNotificationChannel channel = AndroidNotificationChannel(`(51-59 与 115-123) | 逐字相同（同一组常量与参数）→ 提为文件级 `const` 单一来源，两处引用 | 逐字比对两段 |
| P1-8 | `lib/services/database_service.dart` | `Future<bool> deleteExportFile(String filePath)`(1508-1519) | 零调用 | `rg "deleteExportFile" -g "*.dart"` |
| P1-9 | `lib/services/database_service.dart` | `try {`(69) … `} catch (e) { rethrow; }`(97-99) 包住 `_initDatabase` 主体 | catch 体只有 `rethrow`，纯 no-op（同文件其它 catch 都有 `developer.log`）→ 删 try/catch，保留函数体 | 读 68-100 行 |
| P1-10 | `lib/services/display_group_cache.dart` | `static Future<bool> isEmpty(DatabaseExecutor db)`(85-88) | 零调用，已被 `needsRebuild` 取代（注释自证） | `rg "DisplayGroupCache\.isEmpty\|GroupCache\.isEmpty" -g "*.dart"` |
| P1-11 | `lib/services/recovery_ota.dart` | `void _handleState(Map<String, dynamic> state, {required bool forward})`(433)、`if (forward) onState?.call(state);`(441)、调用点 `forward: false`(468) | `forward` 全仓唯一传参处就是 `:468` 且恒为 `false` → 删参数、删 441 行死分支、调用点去掉 `forward:` | `rg "forward:" -g "*.dart"` |
| P1-12 | `lib/models/merged_record.dart` | `bool containsRecordId(String uniqueId)`(34) | 零调用 | `rg "containsRecordId" -g "*.dart"` |
| P1-13 | `lib/models/train_record.dart` | `factory TrainRecord.fromJsonString`(85-88)、`Map<String, dynamic> toJson()`(90-92)、`TrainRecord copyWith({...})`(319-351) | 三者零调用。⚠ `map_state.dart` 的 `toJson`/`copyWith` 另有调用者（`map_state_service.dart:51`），别误删 | `rg "fromJsonString\|\.toJson\(\)\|copyWith" -g "*.dart"` |
| P1-14 | `lib/models/map_state.dart` | `MapState copyWith({...})`(32-44)、`operator ==`/`hashCode`/`toString`(46-64) | `MapState` 只作 `Map<String, MapState>` 的 value 与局部变量，无 `==` 比较、无 Set、无字符串插值 → 四处重写永不执行 | `rg "MapState" -g "*.dart"` |
| P1-15 | `lib/util/loco_type_util.dart` | `String? getLocoTypeByLocoNumber(String locoNumber)`(38-41) | 零调用（需要类型名时直接 `queryTypeNameAndId(locoNo)?.$1`） | `rg "getLocoTypeByLocoNumber" -g "*.dart"` |
| P1-16 | `lib/util/loco_type_util.dart` | `bool get isInitialized`(110) + `_isInitialized` 字段 | 唯一读者是 `test/windows_platform_test.dart:92` 的一句 print；`initialize()`(36) 已把同一个 future 交给调用方。删 getter + 字段，并把该测试行改成 `await util.initialize();` | `rg "isInitialized" -g "*.dart"` |

---

## 3. P2 —— 重复实现合并（建议放在同一个 PR，逐项单独提交更安全）

| # | 位置 | 重复量 | 施工建议 |
|---|---|---|---|
| P2-1 | `lib/screens/history_screen.dart:1741-1880`（`_DelayedMapWithMarker`）vs `1882-2011`（`_DelayedMultiMarkerMap`） | ≈100 行 | `_initializeMapState` / `_onCameraMove` / `dispose` / 蓝点 currentUserLocation Marker / `TileLayer`（同一 urlTemplate + userAgentPackageName）逐字相同。合并为一个接收 `List<LatLng>` 的组件；两处调用点各传一个列表（单点=长度 1）。差异只有：mapKey 工厂（`getSingleRecordMapKey` vs `getMergedRecordMapKey`）、多标记版多一句 `_mapController.move(widget.center, widget.zoom)` 与 `minZoom/maxZoom: 8/18`，以及单标记版的 `_isInitializing` 分支 |
| P2-2 | `lib/screens/main_screen.dart:277-372` / `421-529` / `560-630` | ≈100 行 | 三个进度对话框骨架相同：`var x = false; var progress = 0.0;` + `showDialog(barrierDismissible: false)` + `StatefulBuilder` + `PopScope(canPop: !installing)` + `AlertDialog` + 条件 `Column(LinearProgressIndicator(value: progress), SizedBox(height:12), Text('...${(progress*100).toStringAsFixed(0)}%'))` + 两个 `if (!downloading)` 按钮（含同一个"暂不更新"）+ try/catch + SnackBar + `BleDiagnostics.log`。抽 `showOtaProgressDialog({title, detail, actionLabel, onInstall, onState})` |
| P2-3 | `lib/screens/settings_screen.dart` 锚点 `CircularProgressIndicator(),`（607/680/749/785/837，另有 284/1024 是内联进度不是模态）与三个"取消/继续"确认框（645/714/809） | ≈70 行 | 5 处 `AlertDialog(content: Row(children:[CircularProgressIndicator(), SizedBox(width:16), Text('正在…')]))` 逐字相同只换文案；3 处确认框结构一致。抽 `_showBlockingDialog(String message)` 与 `_confirm(String title, String content, {bool destructive})` |
| P2-4 | `lib/screens/history_screen.dart:887-965` vs `1262-1321` | ≈40 行 | 卡片外壳重复：`color: isSelected && _isEditMode ? Color(0xFF2E2E2E) : Color(0xFF1E1E1E)`、`RoundedRectangleBorder(borderRadius: 8.0, side: BorderSide(color: ... Colors.blue : transparent, width: 2.0))`、`onLongPress` 里的 `if (!_isEditMode) setEditMode(true); widget.onSelectionChanged();`。抽 `_buildSelectableCard(...)` |
| P2-5 | `lib/screens/history_screen.dart:1126-1204` vs `1516-1586` | ≈40 行 | 地图容器与"最优缩放"计算重复（`_mapOptimalZoom` / `_mapCalculating` 判断 → `.then/.catchError` → 未算出时 228 高 Loading Column）。抽 `_buildMapSection({positions, center, mapId, groupKey, height})` |
| P2-6 | `lib/services/firmware_ota_service.dart:89-99` vs `116-126` | 11 行逐字 | `installUpdate` 与 `installSppUpdate` 的"下载 + SHA256"前奏完全相同（`onState({'state':'downloading'})` → `getDownloadUrl` → `Directory(systemTemp/LBJConsole/firmware_update)` → `HttpDownload.download` → `sha256.bind(firmware.openRead())`）。抽 `_fetchFirmware(update, onProgress) → (File, String digest)` |
| P2-7 | `lib/services/app_update_service.dart:166-182` vs `lib/services/firmware_ota_service.dart:59-67,149-156` | 4 个 helper | `_fileId`（`item['id'] ?? item['fileId']`）与 `_uploadTime`（`time/uploadTime/createdAt`）逐字相同；`_fileName`/`_extension` 一端抽成函数、一端内联重写。上移到 `file_share_api.dart`（已是共享层），两处私有拷贝删掉 |
| P2-8 | `lib/services/recovery_ota.dart:132-183`（`RecoveryOta`）vs `427-454`（`_runSppTransfer`） | 两套 | `emit`/`_emit` 完全等价；`waitFor`/`_wait` 是同一个 20ms 轮询循环（只差 `error`/`_error` 字段名）；`handleState`/`_handleState` 重复 error/aborted → `StateError('${otaErrorLabel(code)} ($code)')` 分支。另 `:359-363` 与 `:456-460` 重复 `total <= 0` 与 `RegExp(r'^[0-9a-fA-F]{64}$')` 校验。抽一个内部 helper/mixin 共用 |
| P2-9 | `lib/services/display_group_cache.dart:182-198`（`_addGroupToBatch`）vs `364-385`（`_insertPayload`） | 6 列 + 成员写 | 两者写同一组列与同一批成员行，只差"外部 Batch vs 自建 Batch"。让 `_insertPayload` 复用 `_addGroupToBatch`：`final batch = db.batch(); _addGroupToBatch(batch, group); await batch.commit(noResult: true);` |
| P2-10 | ⚠ **`loco_type_info.csv` 双加载器**：`lib/util/loco_type_util.dart:19-34` vs `lib/services/database_service.dart:1490-1506` | 两份 | 同一个 asset → `Map<String,String>` 实现两次，且都用 `split(',')` 手写解析，与 `lib/util/csv_parser.dart:1-3` 明确声明的"All CSV readers in the app use this implementation"冲突。抽一个无状态的 `parseLocoTypeMap(String csv)`（放在 `csv_parser.dart` 或 `loco_type_util.dart` 顶层）内部走 `parseCsvLine`；两处调用它。⚠ `database_service.dart:1487-1489` 的注释说明它**刻意不复用单例**以避开 init-order race —— 抽纯函数即可，不要引入单例依赖 |
| P2-11 | `lib/services/database_service.dart` | 多处 | ① `_rebuildFtsTable`(438-456) 把全表读进 Dart 逐行 insert，而 `importRawRecords`(1367-1373) 用一条 `INSERT INTO ... SELECT` → 统一用 SQL，删 Dart 侧循环；② `updateSettings`(1081-1086) 与 `setSetting`(1097-1102) 的"刷缓存 + 通知"尾部相同 → `setSetting` 内部 `return updateSettings({key: value})`；③ 900 分块逻辑 `getRecordsByUniqueIds`(948-952) 与 `display_group_cache.dart:387-392 _chunks` 重复 → 共享；④ 计数 SQL `countDisplayGroupsForTesting`(1232-1236) 与 `expectedDisplayTotalForTesting`(1252-1256) 相同 → 后者调前者 |
| P2-12 | `lib/screens/main_screen.dart:669-678`（`_setupConnectionListener`）vs `_ConnectionStatusWidget:42-53` | 双份连接态 | 父与子各自订阅同一个 `connectionStream` 维护 `_isConnected`。子组件改为接收 `isConnected`/`deviceStatus` 参数（它已经接收 `lastReceivedTime`）。**顺带修一个真 bug**：子组件 `:48` 的 `_deviceStatus = connected ? "已连接" : "未连接"` 会把 BLE 服务的详细状态（如"正在连接: X"）覆盖成三个字 |
| P2-13 | `lib/screens/settings_screen.dart:66-79` / `132-137` / `851-857` | 三处 | 同一组设置键列举三遍（加载 / 保存 / 清空重置），清空那份还把重置值写成字面量。收敛为 `_collectSettings()` + `_applySettings(Map)`（清空时传重置值） |

---

## 4. P3 —— 未决，**先不要动**（等拍板）

1. **三种坏值判定是否统一** —— 见附录 A 全文并列。三者严格度不同（`<NUL>`、`(`、`)`、纯 `-----` 的处理互不相同），合并会改变显示/通知行为，需先定语义
2. `lib/screens/main_screen.dart:875` `onSettingsChanged: () {}` 是空闭包 → `SettingsScreen.onSettingsChanged`（`settings_screen.dart:21,32`）与两处 `widget.onSettingsChanged?.call()`（`:138,799`）整条链无行为。删除（刷新实际由 `history_screen.dart:129` 自己订阅 DB 完成）还是保留待用？
3. `lib/themes/app_theme.dart:28-33`（`bottomNavigationBarTheme`）与 `:93-96`（`floatingActionButtonTheme`）：全仓没有 `BottomNavigationBar`/`FloatingActionButton`，主界面 `main_screen.dart:890` 用的是 M3 `NavigationBar`（读 `NavigationBarThemeData`）→ **这两个主题从未生效**。删掉，还是改成 `navigationBarTheme` 让底部导航真正吃到主题（会改变外观，`:891-892` 现在是硬编码）？
4. `lib/screens/settings_screen.dart:95-123` "有线救砖"按钮的唯一动作是弹"功能未实现" → 删入口还是保留占位？
5. `lib/services/file_share_api.dart:70,122-125,130-135` `FileSharePage.total` 只写不读，却带副作用（服务端返回非数字 total 会抛 `FileShareApiException`），两个调用方只用 `page.files` → 删字段 + 变宽容，还是保留校验？
6. `lib/screens/main_screen.dart:1121,1134,1178` `_ScanState.initial`/`finished` 只写不读（全文只比较 `scanning`）→ 换成 `bool _isScanning`？
7. `lib/screens/history_screen.dart:1084` `_formatLocoInfo(record) => record.formattedLocoDisplay;` 纯转发、仅一处调用 → 内联？
8. `lib/services/display_group_cache.dart:686` `|| group.members.isEmpty` 不可能独立成立（成员只在 `:673` 被 `clear()`，紧接 `:674` 就设了 `redirect`）→ 防御性冗余，删不删都行，价值极低
9. "公共但只在本文件内使用"的成员降为 private：`loco_info_util.dart:113 getLocoInfoDisplay`、`loco_type_util.dart:90 queryDisplayName`、`train_record.dart:43 normalizeDirection`、`loco_info_util.dart:135-151 class LocoInfo`、`app_theme.dart:103-105 textPrimary/textSecondary/textTertiary`
10. `rssi`：**按决定不动**。可选：在 `train_record.dart:21` 字段处加一行注释"仅持久化用于回溯，不展示"，防止下次检查又被当成死字段
11. `lib/services/sqflite_initializer.dart:11-19`：`kIsWeb` 早退（web 已按 P0-5 删除）与 `useBundledSqlite`（五个平台判断恒真，只有 Fuchsia 会走到 `if (!useBundledSqlite) return;`）实际上都不可达 → 可简化为 `if (_initialized) return;` + 直接执行 `sqfliteFfiInit()`。价值低、且会失去 Fuchsia 守卫，删不删都行
12. `test/merge_summary_test.dart:8-25` 自建的 `_rec({...})` 与 `test/helpers.dart:55 mkRecord({...})` 职责相同 → 可复用 `mkRecord`。但该文件刻意只 import model + service、不碰 DB，保留自建 helper 也合理，属低价值项
13. `test/ble_ota_test.dart`、`test/csv_import_test.dart`、`test/grid_breakpoints_test.dart` 未使用 `helpers.dart`：已确认是它们不需要 DB（单元测试），**不是**遗漏

---

## 5. 文档与仓库卫生修正

| # | 位置 | 问题 | 处理 |
|---|---|---|---|
| 5-1 | `README.md:30` | 写的 `train_info.csv` 不存在，实际资产是 `assets/train_number_info.csv`（消费者 `train_type_util.dart:13`） | 改文件名 |
| 5-2 | `OTA_RECOVERY.md:3` | 引用 "2026-09-10 的 APPBLE.md 第六节"，`APPBLE.md` 全仓不存在（`docs/` 也被 gitignore，目录本身不存在） | 改成不依赖该文件的表述，或补上 |
| 5-3 | `test/windows_platform_test.dart:3` | 引用 `DEVICE_TEST_REPORT D1/D2`，该文件不存在 | 去掉引用或补文档 |
| 5-4 | `lbjconsole.iml`（仓库根） | **已被 git 跟踪**，但 `.gitignore:1,42` 有 `*.iml`（忽略规则对已跟踪文件无效） | `git rm --cached lbjconsole.iml` |
| 5-5 | `android/key.properties` | 明文口令（`storePassword`/`keyPassword`/`keyAlias`），但**已是死配置**：`build.gradle.kts:38-40` 从环境变量读、`storeFile` 硬编码为 `../../keystore.jks` | 删除该文件；若该口令曾真实使用过，轮换它。（它被 `.gitignore:67` 忽略，从未入库） |
| 5-6 | `pubspec.yaml:42,45,47` | `geolocator_android`、`url_launcher_platform_interface`、`sqlite3` 三个直接声明在 Dart 侧零引用，均由其上游（`geolocator` / `url_launcher` / `sqflite_common_ffi`）传递引入 | 可删（代价只是失去显式钉版本）。**不要删** `sqlite3_flutter_libs` 与 `flutter_blue_plus`（见 0.1） |

---

## 6. 测试与 CI

| # | 问题 | 处理 |
|---|---|---|
| 6-1 | **`.github/workflows/flutter_build.yml` 完全不跑测试**：整个工作流的 `run:` 只有 `flutter pub get` ×2、一次 `base64 -d > keystore.jks`、以及 `dart run tool/release_build.dart` ×2，没有 `flutter test` → 2344 行测试在 CI 中零执行 | 两个 job 各加一步 `flutter test`（Android job 在 ubuntu 上即可跑 widget 测试） |
| 6-2 | `integration_test/`、`test/windows_platform_test.dart`、`lib/util/csv_parser.dart`、`lib/services/http_download.dart` **未入库** | `git add`，否则新克隆与 CI 都看不到它们（CI 加了 `flutter test` 后也跑不到 windows_platform_test） |
| 6-3 | `test/windows_platform_test.dart:19-20,39-42` 硬依赖 `X:\CSVTEST`；只在非 Windows 时 skip，Windows 上缺夹具会**硬失败**而不是 skip | 夹具不存在时 `markTestSkipped` |
| 6-4 | `test/windows_platform_test.dart:159-185` 最后一个测试**自证**：`hasBadge` 闭包定义在测试体内，测的不是生产代码 | 改为断言生产代码（`TrainRecord.hasDirectionValue`、`history_screen` 的真实显隐规则），或删除该测试 |
| 6-5 | `test/windows_platform_test.dart:161-176` 内联构造 `TrainRecord` | 改用 `test/helpers.dart:55 mkRecord(...)` |
| 6-6 | `test/database_perf_test.dart:26,31`、`hide_ungroupable_test.dart:117`、`pagination_test.dart:12` 三处各自引导 15.8 MB 样本 | 在 `test/helpers.dart` 抽 `initTestDbWithSampleData()` |
| 6-7 | `pagination_test.dart:80-105` 的 hideUngroupable 组与 `hide_ungroupable_test.dart:112-160` 重叠 | 删前者那一组（保留 pagination 自己的游标/keyset 组，不要删文件） |
| 6-8 | `test/merge_test.dart` 共 8 个测试（`:27,57,99,134,189,242,296,350`），每个 30-55 行，共用一套 `setUp` 与建库辅助 | 无需拆分。（更正：早前"两个 ~270 行巨型测试"的说法有误，实际是 8 个中等粒度测试） |
| 6-9 | **不要合并** `merge_test.dart` 与 `merge_summary_test.dart` | 二者不是重复：前者 8 个端到端 DB 分组测试（依赖 `helpers.dart` 建库），后者 ~20 个 `MergeService` 纯单元测试（只 import model + service），被测单位不同 |

---

## 7. 本地磁盘垃圾（未跟踪，不影响 git，纯占磁盘 ≈8.7 GB）

| 对象 | 大小 | 处理 |
|---|---|---|
| `android/java_pid34892.hprof` | **1.23 GB** | JVM 堆转储（`android/gradle.properties:1` 开了 `HeapDumpOnOutOfMemoryError`），直接删。是仓库磁盘占用的最大单项 |
| `.dart_tool/flutter_build` | 1.55 GB（**22 份**） | `flutter clean`。根因：`tool/release_build.dart:11-15` 每次生成随机 `LBJ_BUILD_HASH` 并作为 `--dart-define` 传入，dart-define 参与构建产物哈希 → **每次 release 构建都会新建一个 ~74 MB 缓存目录且永不回收**。可考虑构建收尾清 `build/`，或接受 |
| `.dart_tool/{devtest,audit-copy,audit_checks.dart,audit_checks.py,dup_scan.ps1,dup_scan2.ps1}` | 89 MB | 上次会话遗留的临时脚本与构建日志，删 |
| `build/`（含 `build/.cxx`） | 4.88 GB | `flutter clean`。`build/.cxx` 是被删原生构建的孤儿 |
| `windows/flutter/ephemeral` | 303 MB | `flutter clean` 覆盖 |
| `android/.gradle`、`android/.kotlin`（另有 70+ 个 `errors-*.log`） | 29 MB | 可删；已被 gitignore |
| `android/key.properties` | — | 见 5-5 |
| **保留** | — | `LBJ_Console_output.json`（活夹具）、`keystore.jks`（CI 从 secret 生成）、`third_party/win_ble/lib/assets/BLEServer.exe`（Windows BLE 必需） |

---

## 8. 验收清单

- [ ] `flutter analyze` → 0 issue
- [ ] `flutter test` → 全绿（现有 125 个；CI 里也要跑起来）
- [ ] `flutter pub get` 通过；`pubspec.lock` 中不再有 `msix`
- [ ] 新建库执行 `PRAGMA table_info(app_settings)` → 恰好 6 列
- [ ] 单条/批量删除记录后，`record_map_states` 无孤儿行（P0-9）
- [ ] `android/app/build.gradle.kts` 无 proguard 文件引用，`flutter build apk --release` 通过且生成 `mapping.txt`（证明最小化仍生效）
- [ ] `ios/`、`macos/`、`web/` 在 `git status` 中显示为删除，`linux/` 完整保留
- [ ] `.gitignore` 不再有裸 `linux`/`windows` 模式（`git check-ignore --no-index -v windows/runner/x.cpp` 应无输出）
- [ ] 冷启动手动回归：记录列表 / 分页 / 合并展开 / 地图卡片展开与相机记忆 / "定位到我的位置"（Android + Windows 各一次）/ 设置页保存 / 清空数据

---

## 附录 A —— 三种（其实是四种）坏值判定并列

> 供拍板：是否统一、统一到哪种严格度。**P3 未决项，先不要改。**

### A. `TrainRecord.isValidKeyValue` —— 严格（正向判定"有真内容"）

`lib/models/train_record.dart:201-226`

```dart
/// Whether a raw field value is clean enough to be used as a merge grouping
/// key. Mirrors [MergeService]'s "good value" rule: rejects empty, `<NUL>`,
/// `NA`, `NUL`, the per-character corruption markers `*` `(` `)`, and pure
/// dash/dot/placeholder runs, by requiring at least one alphanumeric or CJK
/// rune and none of those corruption markers. ...
static bool isValidKeyValue(String? value) {
  if (value == null) return false;
  final v = value.replaceAll('<NUL>', '').trim();
  if (v.isEmpty) return false;
  final upper = v.toUpperCase();
  if (upper == 'NA' || upper == 'NUL') return false;
  if (v.contains('*') || v.contains('(') || v.contains(')')) return false;
  return v.runes.any(_isContentRune);
}

static bool _isContentRune(int r) {
  if (r >= 0x30 && r <= 0x39) return true; // 0-9
  if (r >= 0x41 && r <= 0x5A) return true; // A-Z
  if (r >= 0x61 && r <= 0x7A) return true; // a-z
  if (r >= 0x4E00 && r <= 0x9FFF) return true; // CJK Unified Ideographs
  if (r >= 0x3400 && r <= 0x4DBF) return true; // CJK Extension A
  return false;
}
```

- 调用方：`train_record.dart:196 trainKey`、`:199 locoKey`、`:165 _isFieldMeaningful`（再被 `isTimeOnly` 169-193 使用）、`merge_service.dart:17 _isGoodValue`（合并摘要逐字段取值）
- 特点：`NA`/`NUL` 判定用 `toUpperCase()`；先剥离所有 `<NUL>`；含 `*`/`(`/`)` 任一即拒；要求至少一个"内容 rune"，所以纯 `-----`、`----.-`、`*****` 也会被拒

### B. `NotificationService._isValidValue` —— 宽松（黑名单）

`lib/services/notification_service.dart:178-185`

```dart
bool _isValidValue(String? value) {
  if (value == null || value.isEmpty) return false;
  final trimmed = value.trim();
  return trimmed.isNotEmpty &&
      trimmed != 'NUL' &&
      trimmed != 'NA' &&
      trimmed != '*';
}
```

- 调用方：`notification_service.dart:120-122`（发通知的门槛：train/route/directionText）、`:157,160,163,167,171`（正文逐字段拼接）
- 与 A 的差异：**不剥离 `<NUL>`**（`<NUL>` 会被当合法内容）、不检查 `(`/`)`、不检查纯占位串（`-----`、`----.-`、`*****` 合法），`NA`/`NUL` 比较**大小写敏感**（`na` 会被当合法）

### C. `history_screen._buildPositionAndSpeed` 内联三连 —— 逐字段定制

`lib/screens/history_screen.dart:1447-1469`

```dart
final routeStr = record.route.trim();
final position = record.position.trim();
final speed = record.speed.trim();
final isValidRoute =
    routeStr.isNotEmpty &&
    !routeStr.runes.every((r) => r == '*'.runes.first);
final isValidPosition =
    position.isNotEmpty &&
    !position.runes.every(
      (r) => r == '-'.runes.first || r == '.'.runes.first,
    ) &&
    position != "<NUL>";
final isValidSpeed =
    speed.isNotEmpty &&
    !speed.runes.every(
      (r) => r == '*'.runes.first || r == '-'.runes.first,
    ) &&
    speed != "NUL" &&
    speed != "<NUL>";
if (!isValidRoute && !isValidPosition && !isValidSpeed) {
  return const SizedBox.shrink();
}
```

- 用途：卡片里"线路 / 公里标 / 速度"整行的显隐
- 与 A/B 的差异：按字段用不同字符集（route 只查 `*`，position 查 `-`/`.`，speed 查 `*`/`-`），且**不检查 `(`/`)`**；`NUL` 判定大小写敏感（A 用 `toUpperCase()`）；`<NUL>` 只对 position 与 speed 查，route 不查

### D. `TrainRecord.isTimeOnly`（第四种规则集合，内部复用 A）

`lib/models/train_record.dart:169-193`：在 A 的基础上追加 `speed != 'NUL'`、`fullTrainNumber`/`train` 不含 `-----`、`trainType != '未知'`、`lbjClass != 'NA'`

### 差异速查

| 输入 | A `isValidKeyValue` | B `_isValidValue` | C history 行显隐 |
|---|---|---|---|
| `"<NUL>"` | false | **true** | position/speed: false；route: **true** |
| `"NA"` / `"NUL"` | false | false | **true**（C 完全不查这两个） |
| `"na"` | false | **true** | **true** |
| `"-----"` | false（无内容 rune） | **true** | route: **true** |
| `"----.-"` | false | **true** | position: false |
| `"*****"` | false（含 `*`） | **true** | **true** |
| `"24800(74"` | false（含 `(`） | **true** | **true** |
| `"85012"` | true | true | true |

---

## 附录 B —— 复验命令速查

> 正文表格里的 `rg "..." -g "*.dart"` 即 ripgrep；本机可用（`C:\Users\33572\.kimi-code\bin\rg.exe`）。若换环境不可用，用下面的 PowerShell 片段等价替代。

```powershell
# 全仓标识符复验（把 <Name> 换成要删的符号名）
Get-ChildItem -Recurse -Filter *.dart -File lib,test,integration_test,tool |
  Select-String -Pattern '<Name>' |
  ForEach-Object { "$($_.Path):$($_.LineNumber)  $($_.Line.Trim())" }

# flutter analyze：必须 0 issue
flutter analyze

# flutter test：必须全绿
flutter test

# 设置表列（新库）
# 在 sqlite 客户端里：PRAGMA table_info(app_settings);

# 确认 windows/linux 裸 gitignore 模式是否还在生效
git check-ignore --no-index -v windows/runner/x.cpp
git check-ignore --no-index -v linux/x.cc
```

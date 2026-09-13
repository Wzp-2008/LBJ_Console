// Windows 端平台相关行为的可复现验证（宿主 flutter test，不需要窗口/GPU）。
//
// 背景：桌面窗口渲染和 Flutter 工具连接不适合在单元测试中依赖，因此改用宿主测试覆盖
// "Windows 平台特有"的代码路径：
//   1) Windows 专有的"从盘符导入 CSV"（X:\CSVTEST 真实夹具）；
//   2) 该导入路径产生的方向编码 / 机车显示是否符合预期；
//   3) debug 构建的更新检查应直接跳过（appBuildHash == 'debug'）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lbjconsole/screens/settings_screen.dart';
import 'package:lbjconsole/services/app_update_service.dart';
import 'package:lbjconsole/util/loco_type_util.dart';

import 'helpers.dart';

const String _fixtureDrive = 'X';
const String _fixtureDir = 'X:\\CSVTEST';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Windows 平台 · 从盘符导入 CSV', () {
    setUp(() async {
      await initTestDb();
    });
    tearDown(() async {
      await disposeTestDatabase();
    });

    test('夹具存在且能被完整导入', () async {
      if (!Platform.isWindows) {
        markTestSkipped('仅 Windows 端适用');
        return;
      }
      if (!Directory(_fixtureDir).existsSync()) {
        markTestSkipped('缺少 Windows CSV 夹具：$_fixtureDir');
        return;
      }

      final result = await DatabaseService.instance.importCsvFromDrive(
        _fixtureDrive,
      );
      // ignore: avoid_print
      print(
        '导入结果: success=${result.success} files=${result.fileCount} '
        'records=${result.recordCount} msg=${result.message}',
      );
      expect(result.success, isTrue, reason: result.message);
      expect(result.fileCount, 1);
      expect(result.recordCount, 3);
      expect(await DatabaseService.instance.getRecordCount(), 3);

      final rows = await DatabaseService.instance.getAllRecords();
      final byTrain = {for (final r in rows) r.train: r};
      expect(byTrain.keys.toSet(), {'1234', '5678'});

      // 字段还原
      final up = byTrain['1234']!;
      expect(up.lbjClass, 'K');
      expect(up.speed, '80');
      expect(up.position, '195.7');
      expect(up.route, '京九线');
      expect(up.loco, '1041234');
      expect(up.locoType, '东风4'); // loco_type_info.csv: 104 → 东风4
      expect(up.positionInfo, '30°18.1522′ 120°10.9625′');
      expect(up.rssi, -70.0);

      // 方向编码：1=下行、3=上行，模型和 CSV 导入使用同一约定。
      // ignore: avoid_print
      print(
        '方向观察: CSV"上行"→direction=${up.direction} → directionText="${up.directionText}"',
      );
      expect(up.direction, 3, reason: 'CSV 映射：上行→3');
      expect(up.directionText, '上行');

      final down = byTrain['5678']!;
      // ignore: avoid_print
      print(
        '方向观察: CSV"下行"→direction=${down.direction} → directionText="${down.directionText}"',
      );
      expect(down.direction, 1, reason: 'CSV 映射：下行→1');
      expect(down.directionText, '下行');

      // 机车显示：等待共享初始化完成后验证三位车型前缀的编号截取规则。
      final util = LocoTypeUtil();
      await util.initialize();
      final display = LocoTypeUtil.formatLocoDisplay(up.locoType, up.loco);
      // ignore: avoid_print
      print('机车显示观察: loco=${up.loco} → "$display"（按类型表应为 东风4-1234）');
      expect(display, '东风4-1234');
    });

    test('不存在的盘符应返回失败而不是抛异常', () async {
      if (!Platform.isWindows) {
        markTestSkipped('仅 Windows 端适用');
        return;
      }
      final result = await DatabaseService.instance.importCsvFromDrive('Q');
      // ignore: avoid_print
      print('不存在盘符: success=${result.success} msg=${result.message}');
      expect(result.success, isFalse);
      expect(result.message, contains('目录不存在'));
    });
  });

  group('Windows 平台 · 更新检查', () {
    test('debug 构建（appBuildHash=debug）应直接判定无更新且不发请求', () async {
      expect(appBuildHash, 'debug', reason: '宿主测试为 debug 构建');
      final info = await AppUpdateService().checkForUpdate();
      // ignore: avoid_print
      print('checkForUpdate() → $info');
      expect(info, isNull);
    });

    test('PowerShell 更新脚本已作为 Windows 资源打包', () async {
      if (!Platform.isWindows) {
        markTestSkipped('仅 Windows 端适用');
        return;
      }

      final script = await rootBundle.loadString('assets/windows_updater.ps1');
      expect(script, contains('Expand-Archive'));
      expect(script, contains('ParentProcessId'));
      expect(script, contains('lbj_updater.exe'));
      expect(script, contains('robocopy.exe'));
    });
  });

  group('Windows 平台 · 设置页平台差异（控件树）', () {
    testWidgets('显示“从盘符导入 CSV”，隐藏“后台保活服务”', (tester) async {
      if (!Platform.isWindows) {
        markTestSkipped('仅 Windows 端适用');
        return;
      }
      // 说明：刻意不初始化数据库——宿主 widget test 使用假异步，真实 FFI 查询的 Future
      // 不会推进，而 SettingsScreen 首帧已用默认值渲染全部卡片（_settingsLoaded 只影响保存），
      // 因此"控件树是否包含某入口"这类结构断言是可靠的。
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await tester.pump(const Duration(milliseconds: 100));

      // Windows 专有项
      expect(
        find.text('从盘符导入 CSV'),
        findsOneWidget,
        reason: 'Windows 应显示 CSV 导入入口',
      );
      // Android/iOS 专有项应隐藏
      expect(
        find.text('后台保活服务'),
        findsNothing,
        reason: 'Windows 不应显示后台保活开关（settings_screen 用 Platform.isWindows 隐藏）',
      );
      // 两端共有项
      expect(find.text('通知服务'), findsOneWidget);
      expect(find.text('启用记录合并'), findsOneWidget);
      expect(find.text('隐藏不可分组记录'), findsOneWidget);
      expect(find.text('分享数据'), findsOneWidget);
      expect(find.text('导入数据'), findsOneWidget);
      expect(find.text('清空数据'), findsOneWidget);
      // ignore: avoid_print
      print('设置页控件树检查通过：有 CSV 导入 / 无后台保活服务');
    });
  });

  group('显示层规则（两端共用）', () {
    test('方向角标规则：1→下 / 3→上 / 0→无', () {
      final unknown = mkRecord(uniqueId: 'x0', receivedMs: 0);
      final down = mkRecord(uniqueId: 'x1', receivedMs: 0, direction: 1);
      final up = mkRecord(uniqueId: 'x3', receivedMs: 0, direction: 3);
      expect(unknown.hasDirectionValue, isFalse);
      expect(down.hasDirectionValue, isTrue);
      expect(up.hasDirectionValue, isTrue);
      expect(unknown.directionBadge, isNull);
      expect(down.directionBadge, '下');
      expect(up.directionBadge, '上');
    });
  });
}

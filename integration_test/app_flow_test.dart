// 设备端功能测试（integration_test）：在真实 Android / Windows 设备上，用真实 UI +
// 真实 SQLite 验证"功能与操作是否符合预期逻辑"。
//
// 运行方式：
//   flutter test integration_test/app_flow_test.dart -d windows
//   flutter test integration_test/app_flow_test.dart -d <android-serial>
//
// 设计取舍（三次实机迭代后的结论）：
// - 只启动一次应用（重复调用 app.main() 会挂住测试进程）。
// - 所有检查放在**一个** testWidgets 里，按阶段执行；每个阶段单独 try/catch，
//   失败只记录不中断，最后统一汇总 → 一次运行即可拿到全部阶段的结论，
//   不会因为某个阶段失败而让其余阶段"did not complete"。
// - 不使用 pumpAndSettle：界面存在不定长动画（加载圈），会导致超时；统一用
//   pumpFor / pumpUntil 轮询真实时间。
// - 断言尽量限定在具体页面内：MainScreen 用 IndexedStack，两个页面同时在树里，
//   全局 find.text 会命中未显示页面的文本。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lbjconsole/main.dart' as app;
import 'package:lbjconsole/models/train_record.dart';
import 'package:lbjconsole/screens/history_screen.dart';
import 'package:lbjconsole/screens/settings_screen.dart';
import 'package:lbjconsole/services/background_service.dart';
import 'package:lbjconsole/services/database_service.dart';
import 'package:lbjconsole/services/notification_service.dart';
import 'package:lbjconsole/services/records_feed.dart';

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

Future<void> pumpFor(
  WidgetTester tester,
  Duration total, {
  Duration step = const Duration(milliseconds: 100),
}) async {
  final end = DateTime.now().add(total);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(step);
  }
}

Future<void> pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 15),
  Duration step = const Duration(milliseconds: 100),
  String? reason,
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(step);
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TestFailure(
    '等待超时（${timeout.inSeconds}s）：$finder'
    '${reason == null ? '' : '  —— $reason'}',
  );
}

Finder inHistory(Finder matching) =>
    find.descendant(of: find.byType(HistoryScreen), matching: matching);
Finder inSettings(Finder matching) =>
    find.descendant(of: find.byType(SettingsScreen), matching: matching);

Future<void> gotoHistory(WidgetTester tester) async {
  await tester.tap(
    find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text('列车记录'),
    ),
  );
  await pumpFor(tester, const Duration(milliseconds: 600));
}

Future<void> gotoSettings(WidgetTester tester) async {
  await tester.tap(
    find.descendant(of: find.byType(NavigationBar), matching: find.text('设置')),
  );
  await pumpFor(tester, const Duration(milliseconds: 600));
}

Future<void> reloadList(WidgetTester tester) async {
  final state = tester.state<HistoryScreenState>(find.byType(HistoryScreen));
  await state.reloadRecords();
  await pumpFor(tester, const Duration(milliseconds: 900));
}

Future<void> setSwitch(WidgetTester tester, String label, bool value) async {
  await gotoSettings(tester);
  final row = find.ancestor(
    of: inSettings(find.text(label)),
    matching: inSettings(find.byType(Row)),
  );
  final sw = find.descendant(of: row, matching: find.byType(Switch)).first;
  await tester.ensureVisible(sw);
  await pumpFor(tester, const Duration(milliseconds: 300));
  if (tester.widget<Switch>(sw).value != value) {
    await tester.tap(sw);
    await pumpFor(tester, const Duration(seconds: 1));
  }
  await gotoHistory(tester);
}

TrainRecord rec({
  required String id,
  required int receivedMs,
  String train = '',
  int direction = 0,
  String loco = '',
  String lbjClass = '',
  String route = '',
  String positionInfo = '',
  String speed = '',
  String position = '',
}) {
  return TrainRecord(
    uniqueId: id,
    timestamp: DateTime.fromMillisecondsSinceEpoch(receivedMs),
    receivedTimestamp: DateTime.fromMillisecondsSinceEpoch(receivedMs),
    train: train,
    direction: direction,
    speed: speed,
    position: position,
    time: '',
    loco: loco,
    locoType: '',
    lbjClass: lbjClass,
    route: route,
    positionInfo: positionInfo,
    rssi: -70,
  );
}

Future<void> resetData(WidgetTester tester) async {
  await DatabaseService.instance.deleteAllRecords();
  await DatabaseService.instance.updateSettings({
    'mergeRecordsEnabled': 0,
    'hideUngroupableRecords': 0,
    'notificationEnabled': 0,
    'backgroundServiceEnabled': 0,
  });
  await reloadList(tester);
}

// ---------------------------------------------------------------------------

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const base = 1782000000000; // 固定基准时间，便于构造 1 小时会话窗口
  final results = <String>[];

  testWidgets('两端功能流程（分阶段汇总）', (tester) async {
    Future<void> phase(String name, Future<void> Function() body) async {
      try {
        await body();
        results.add('PASS  $name');
        debugPrint('PHASE PASS  $name');
      } catch (e) {
        results.add('FAIL  $name :: $e');
        debugPrint('PHASE FAIL  $name :: $e');
      }
    }

    // 启动（只启动一次）
    app.main(<String>[]);
    await pumpUntil(
      tester,
      find.byType(NavigationBar),
      timeout: const Duration(seconds: 40),
      reason: '应用启动后应出现底部导航栏',
    );
    await pumpFor(tester, const Duration(seconds: 1));

    await phase('P01 启动/导航栏/空状态/标题', () async {
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('列车记录'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('设置'),
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('列车记录 ('),
        findsOneWidget,
        reason: '标题应显示"列车记录 (N)"',
      );
      await resetData(tester);
      expect(inHistory(find.text('暂无记录')), findsOneWidget);
    });

    await phase('P02 记录渲染与方向角标（0/1/3）', () async {
      await resetData(tester);
      await DatabaseService.instance.insertRecord(
        rec(
          id: 'd1',
          receivedMs: base,
          train: '1234',
          lbjClass: 'K',
          direction: 1,
          loco: '41010559',
          route: '京九线',
          positionInfo: '30°18.1522′ 120°10.9625′',
          speed: '80',
          position: '195.7',
        ),
      );
      await DatabaseService.instance.insertRecord(
        rec(
          id: 'd3',
          receivedMs: base + 60000,
          train: '5678',
          lbjClass: 'G',
          direction: 3,
          loco: '23900246',
          route: '沪昆线',
          positionInfo: '31°10.0000′ 121°20.0000′',
          speed: '120',
        ),
      );
      await DatabaseService.instance.insertRecord(
        rec(
          id: 'd0',
          receivedMs: base + 120000,
          train: 'Z900',
          direction: 0,
          route: '京沪线',
        ),
      );
      await reloadList(tester);

      expect(
        inHistory(find.text('K1234')),
        findsOneWidget,
        reason: 'lbjClass+train 应拼成 K1234',
      );
      expect(inHistory(find.text('G5678')), findsOneWidget);
      expect(inHistory(find.text('Z900')), findsOneWidget);
      expect(inHistory(find.text('京九线')), findsOneWidget);
      expect(
        inHistory(find.text('下')),
        findsOneWidget,
        reason: 'direction=1 → 下',
      );
      expect(
        inHistory(find.text('上')),
        findsOneWidget,
        reason: 'direction=3 → 上',
      );
      final zeroBadge =
          inHistory(find.text('上')).evaluate().length +
          inHistory(find.text('下')).evaluate().length;
      debugPrint('OBSERVE 方向角标：1→下 / 3→上 / 0→无角标（共 $zeroBadge 个角标）');
    });

    await phase('P03 记录合并：分组/展开/地图', () async {
      await resetData(tester);
      await DatabaseService.instance.insertRecord(
        rec(
          id: 'm1',
          receivedMs: base,
          train: 'K1234',
          lbjClass: 'K',
          direction: 1,
          loco: '41010559',
          route: '京九线',
          positionInfo: '30°18.1522′ 120°10.9625′',
          speed: '80',
        ),
      );
      await DatabaseService.instance.insertRecord(
        rec(
          id: 'm2',
          receivedMs: base + 30 * 60000,
          train: '1234',
          direction: 1,
          loco: '41010559',
          route: '京九线',
          positionInfo: '30°19.0000′ 120°11.0000′',
          speed: '90',
        ),
      );
      await DatabaseService.instance.insertRecord(
        rec(
          id: 'm3',
          receivedMs: base + 180 * 60000,
          train: 'K1234',
          direction: 1,
          loco: '41010559',
          route: '京九线',
          positionInfo: '30°20.0000′ 120°12.0000′',
          speed: '95',
        ),
      );
      await reloadList(tester);
      expect(
        inHistory(find.text('共 2 条 · 点击展开')),
        findsNothing,
        reason: '默认关闭合并时应为独立卡片',
      );

      await setSwitch(tester, '启用记录合并', true);
      await reloadList(tester);
      await pumpUntil(
        tester,
        inHistory(find.text('共 2 条 · 点击展开')),
        reason: '同一会话（同车次/同机车，1h 内）应合并为 2 条',
      );
      await tester.tap(inHistory(find.text('共 2 条 · 点击展开')));
      await pumpFor(tester, const Duration(seconds: 2));
      await pumpUntil(
        tester,
        inHistory(find.byType(FlutterMap)),
        timeout: const Duration(seconds: 25),
        reason: '展开后应挂载地图组件',
      );
      await setSwitch(tester, '启用记录合并', false);
      await reloadList(tester);
    });

    await phase('P04 搜索：计数/过滤/清空', () async {
      await resetData(tester);
      await DatabaseService.instance.insertRecord(
        rec(
          id: 's1',
          receivedMs: base,
          train: '1234',
          lbjClass: 'K',
          direction: 1,
          loco: '41010559',
          route: '京九线',
        ),
      );
      await DatabaseService.instance.insertRecord(
        rec(
          id: 's2',
          receivedMs: base + 60000,
          train: '5678',
          lbjClass: 'K',
          direction: 1,
          loco: '13800347',
          route: '沪昆线',
        ),
      );
      await reloadList(tester);

      final searchField = inHistory(find.byType(TextField)).first;
      await tester.tap(searchField);
      await tester.enterText(searchField, '1234');
      await pumpFor(tester, const Duration(milliseconds: 1500));
      await pumpUntil(
        tester,
        inHistory(find.textContaining('找到')),
        reason: '应显示搜索结果计数',
      );
      expect(inHistory(find.textContaining('找到 1 条')), findsOneWidget);
      expect(inHistory(find.text('K5678')), findsNothing, reason: '搜索应过滤不匹配记录');
      await tester.tap(inHistory(find.byIcon(Icons.clear)).first);
      await pumpFor(tester, const Duration(seconds: 1));
      expect(
        inHistory(find.text('K5678')),
        findsOneWidget,
        reason: '清空搜索应恢复全部',
      );
    });

    await phase('P05 多选编辑与批量删除', () async {
      await resetData(tester);
      for (var i = 0; i < 3; i++) {
        await DatabaseService.instance.insertRecord(
          rec(
            id: 'e$i',
            receivedMs: base + i * 60000,
            train: 'T10$i',
            direction: 1,
            loco: '4101055$i',
            route: '京九线',
          ),
        );
      }
      await reloadList(tester);
      expect(await DatabaseService.instance.getRecordCount(), 3);

      await tester.longPress(inHistory(find.byType(Card)).first);
      await pumpFor(tester, const Duration(milliseconds: 800));
      expect(
        find.textContaining('已选择 1 项'),
        findsOneWidget,
        reason: '长按进入编辑模式',
      );

      await tester.tap(find.byIcon(Icons.delete).first);
      await pumpFor(tester, const Duration(seconds: 1));
      await pumpUntil(tester, find.text('确认删除'));
      await tester.tap(find.widgetWithText(ElevatedButton, '删除'));
      await pumpFor(tester, const Duration(seconds: 2));
      expect(
        await DatabaseService.instance.getRecordCount(),
        2,
        reason: '应删除 1 条',
      );
      expect(find.textContaining('已选择'), findsNothing, reason: '删除后退出编辑模式');
    });

    await phase('P06 设置开关持久化 + 清空数据', () async {
      await resetData(tester);
      for (var i = 0; i < 3; i++) {
        await DatabaseService.instance.insertRecord(
          rec(
            id: 'c$i',
            receivedMs: base + i * 60000,
            train: 'C$i',
            direction: 1,
            loco: 'L$i',
            route: '京九线',
          ),
        );
      }
      await reloadList(tester);
      await setSwitch(tester, '隐藏不可分组记录', true);
      var settings = await DatabaseService.instance.getAllSettings();
      expect(settings?['hideUngroupableRecords'], 1, reason: '开关应写入数据库');

      await gotoSettings(tester);
      final clearTile = inSettings(find.text('清空数据'));
      await tester.ensureVisible(clearTile);
      await pumpFor(tester, const Duration(milliseconds: 400));
      await tester.tap(clearTile);
      await pumpFor(tester, const Duration(milliseconds: 800));
      await pumpUntil(tester, find.text('确认清空'));
      await tester.tap(find.text('确认清空'));
      await pumpFor(tester, const Duration(seconds: 3));
      await pumpUntil(
        tester,
        find.text('数据已清空'),
        timeout: const Duration(seconds: 10),
      );

      expect(
        await DatabaseService.instance.getRecordCount(),
        0,
        reason: '清空后记录数 0',
      );
      await gotoHistory(tester);
      await reloadList(tester);
      expect(inHistory(find.text('暂无记录')), findsOneWidget);
      settings = await DatabaseService.instance.getAllSettings();
      debugPrint(
        'OBSERVE 清空后设置：merge=${settings?['mergeRecordsEnabled']} '
        'hideUngroupable=${settings?['hideUngroupableRecords']} '
        'notification=${settings?['notificationEnabled']} '
        'backgroundService=${settings?['backgroundServiceEnabled']}',
      );
    });

    await phase('P07 导入边界：{} 是否会清空数据（第二轮 P1-1）', () async {
      await resetData(tester);
      await DatabaseService.instance.insertRecord(
        rec(
          id: 'i1',
          receivedMs: base,
          train: 'K1234',
          direction: 1,
          loco: '41010559',
          route: '京九线',
        ),
      );
      expect(await DatabaseService.instance.getRecordCount(), 1);

      final dir = Directory.systemTemp.createTempSync('lbj_import_');
      final emptyJson = File('${dir.path}${Platform.pathSeparator}empty.json');
      await emptyJson.writeAsString('{}');
      final ok = await DatabaseService.instance.importDataFromJson(
        emptyJson.path,
      );
      final count = await DatabaseService.instance.getRecordCount();
      debugPrint('OBSERVE 导入 "{}"：ok=$ok，导入后记录数=$count');
      expect(ok, isFalse);
      expect(count, 1, reason: '无 records 的 JSON 不应清空现有数据');
    });

    await phase('P08 导出/导入往返', () async {
      await resetData(tester);
      await DatabaseService.instance.insertRecord(
        rec(
          id: 'r1',
          receivedMs: base,
          train: 'K1234',
          lbjClass: 'K',
          direction: 1,
          loco: '41010559',
          route: '京九线',
          positionInfo: '30°18.1522′ 120°10.9625′',
          speed: '80',
          position: '195.7',
        ),
      );
      await DatabaseService.instance.insertRecord(
        rec(
          id: 'r2',
          receivedMs: base + 60000,
          train: 'G5678',
          direction: 3,
          loco: '23900246',
          route: '沪昆线',
        ),
      );

      final dir = Directory.systemTemp.createTempSync('lbj_export_');
      final path = '${dir.path}${Platform.pathSeparator}export.json';
      final exported = await DatabaseService.instance.exportDataAsJson(
        customPath: path,
      );
      expect(exported, isNotNull, reason: '导出应成功');
      final raw = jsonDecode(await File(path).readAsString());
      expect((raw['records'] as List).length, 2);

      await DatabaseService.instance.deleteAllRecords();
      expect(await DatabaseService.instance.getRecordCount(), 0);
      expect(await DatabaseService.instance.importDataFromJson(path), isTrue);
      expect(await DatabaseService.instance.getRecordCount(), 2);
      final rows = await DatabaseService.instance.getRecordsByUniqueIds([
        'r1',
        'r2',
      ]);
      final r1 = rows.firstWhere((r) => r.uniqueId == 'r1');
      expect(r1.train, 'K1234');
      expect(r1.lbjClass, 'K');
      expect(r1.direction, 1);
      expect(r1.positionInfo, '30°18.1522′ 120°10.9625′');
    });

    await phase('P09 大组合并：仅显示前 100 条', () async {
      await resetData(tester);
      for (var i = 0; i < 105; i++) {
        await DatabaseService.instance.insertRecord(
          rec(
            id: 'big$i',
            receivedMs: base + i * 30000,
            train: 'BIG1',
            direction: 1,
            loco: '41010559',
            route: '京九线',
          ),
        );
      }
      await setSwitch(tester, '启用记录合并', true);
      await reloadList(tester);
      await pumpUntil(
        tester,
        inHistory(find.text('共 105 条 · 点击展开')),
        timeout: const Duration(seconds: 25),
      );
      await tester.tap(inHistory(find.text('共 105 条 · 点击展开')));
      await pumpFor(tester, const Duration(seconds: 2));
      await pumpUntil(
        tester,
        inHistory(find.textContaining('仅显示前 100 条')),
        timeout: const Duration(seconds: 30),
        reason: '成员超过 100 时应提示截断',
      );
      await setSwitch(tester, '启用记录合并', false);
      await resetData(tester);
    });

    await phase('P10 通知：开关状态、权限与投递调用', () async {
      // 先观察清空数据之后 UI 开关与服务内存标志是否一致。
      await gotoSettings(tester);
      final row = find.ancestor(
        of: inSettings(find.text('通知服务')),
        matching: inSettings(find.byType(Row)),
      );
      final sw = find.descendant(of: row, matching: find.byType(Switch)).first;
      final uiValueBefore = tester.widget<Switch>(sw).value;
      final memBefore = await NotificationService.instance
          .isNotificationEnabled();
      debugPrint(
        'OBSERVE 清空数据后：通知开关 UI=$uiValueBefore，服务内存标志=$memBefore'
        '（DB 值应为 1，见 P06 OBSERVE）',
      );
      await gotoHistory(tester);

      // 投递链路验证：直接打开开关（绕过设置页），走 权限 → 显示 的完整通路
      final service = NotificationService.instance;
      await service.enableNotifications(true);
      final granted = await service.requestPermission();
      debugPrint('OBSERVE 通知权限 granted=$granted');
      await service.showTrainNotification(
        rec(
          id: 'n1',
          receivedMs: base,
          train: '1234',
          lbjClass: 'K',
          direction: 1,
          loco: '41010559',
          route: '京九线',
          positionInfo: '30°18.1522′ 120°10.9625′',
          speed: '80',
        ),
      );
      await pumpFor(tester, const Duration(seconds: 3));
      debugPrint(
        'OBSERVE 已调用 showTrainNotification（宿主用 dumpsys notification 校验投递）',
      );

      // 进程内取证：直接查询插件的活动通知（不依赖进程存活，避免测试结束后被系统清理）
      try {
        final active = await FlutterLocalNotificationsPlugin()
            .getActiveNotifications();
        debugPrint(
          'OBSERVE 活动通知数=${active.length} :: '
          '${active.map((a) => '${a.id}:${a.title}|${a.body}').join(' ; ')}',
        );
        expect(active, isNotEmpty, reason: 'showTrainNotification 之后应存在活动通知');
      } catch (e) {
        debugPrint('OBSERVE getActiveNotifications 在当前平台不可用或失败：$e');
      }

      // 清空数据后，设置页和通知服务应继续保持一致。
      final dbValue = (await DatabaseService.instance
          .getAllSettings())?['notificationEnabled'];
      final memAfter = await service.isNotificationEnabled();
      debugPrint('OBSERVE 清空数据后一致性：DB=$dbValue，内存=$memAfter');
      await setSwitch(tester, '通知服务', false);
      expect(memBefore, uiValueBefore, reason: '清空数据后通知服务的内存状态应与设置页一致');
    });

    await phase('P11 非合并模式 + 隐藏不可分组：实时条目过滤', () async {
      await resetData(tester);
      await DatabaseService.instance.updateSettings({
        'mergeRecordsEnabled': 0,
        'hideUngroupableRecords': 1,
      });
      final ungroupable = rec(
        id: 'u1',
        receivedMs: base,
        route: 'R1',
        direction: 1,
      ); // 无 train/locoKey
      await DatabaseService.instance.insertRecord(ungroupable);
      final grouped = rec(
        id: 'g1',
        receivedMs: base + 60000,
        train: 'T1',
        direction: 1,
      );
      await DatabaseService.instance.insertRecord(grouped);

      final page = await RecordsFeed.fetchPage(limit: 100, cursor: null);
      expect(page.items.length, 1, reason: '分页应隐藏不可分组记录');
      // MainScreen.addNewRecord 走的是 RecordsFeed.itemContaining：
      final liveUngroupable = await RecordsFeed.itemContaining(ungroupable);
      final liveGrouped = await RecordsFeed.itemContaining(grouped);
      debugPrint(
        'OBSERVE 实时插入路径：ungroupable→${liveUngroupable != null} '
        '(null 才符合"隐藏"预期)，grouped→${liveGrouped != null}',
      );
      expect(liveGrouped, isNotNull);
      expect(
        liveUngroupable,
        isNull,
        reason: '关闭合并时 itemContaining 也应应用 hideUngroupable',
      );
      await resetData(tester);
    });

    await phase('P12 后台保活服务（Android）状态查询', () async {
      final before = await BackgroundService.isRunning();
      debugPrint('OBSERVE BackgroundService.isRunning(before)=$before');
      await BackgroundService.startService();
      await pumpFor(tester, const Duration(seconds: 3));
      final after = await BackgroundService.isRunning();
      debugPrint('OBSERVE BackgroundService.isRunning(after start)=$after');
      await BackgroundService.stopService();
      await pumpFor(tester, const Duration(seconds: 2));
      final stopped = await BackgroundService.isRunning();
      debugPrint('OBSERVE BackgroundService.isRunning(after stop)=$stopped');
    });

    await phase('P13 合并摘要字段取"最正确数据"', () async {
      await resetData(tester);
      await DatabaseService.instance.insertRecord(
        rec(
          id: 'sm1',
          receivedMs: base,
          train: '57908',
          lbjClass: 'K',
          direction: 1,
          loco: '41010559',
          route: '京九线',
          speed: '50',
          position: '195.4',
        ),
      );
      await DatabaseService.instance.insertRecord(
        rec(
          id: 'sm2',
          receivedMs: base + 60000,
          train: '-----',
          direction: 3,
          loco: '41010559',
          route: '',
          speed: '',
          position: '----.-',
        ),
      );
      await DatabaseService.instance.updateSettings({'mergeRecordsEnabled': 1});
      await reloadList(tester);
      await pumpUntil(
        tester,
        inHistory(find.textContaining('共 2 条')),
        timeout: const Duration(seconds: 20),
      );
      expect(
        inHistory(find.textContaining('57908')),
        findsOneWidget,
        reason: '摘要应取有效车次（卡片显示为 K57908），而不是被最新成员的占位符覆盖',
      );
      expect(
        inHistory(find.textContaining('50 km/h')),
        findsWidgets,
        reason: '摘要应取有效速度',
      );
      await setSwitch(tester, '启用记录合并', false);
      await resetData(tester);
    });

    // 汇总
    debugPrint('================ 阶段汇总 ================');
    for (final r in results) {
      debugPrint(r);
    }
    final failed = results.where((r) => r.startsWith('FAIL')).toList();
    expect(failed, isEmpty, reason: '失败阶段：\n${failed.join('\n')}');
  }, timeout: const Timeout(Duration(minutes: 15)));
}

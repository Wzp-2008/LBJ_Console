import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lbjconsole/services/classic_spp_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('lbjconsole/classic_spp');
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  var session = -1;
  var disconnectDuringOpen = false;
  Future<void> event(String method, int id, {List<int>? bytes}) async {
    final delivered = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(
        MethodCall(method, {
          'sessionId': id,
          if (bytes != null) 'data': Uint8List.fromList(bytes),
        }),
      ),
      (_) => delivered.complete(),
    );
    await delivered.future;
  }

  setUp(() {
    disconnectDuringOpen = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'connect') {
        session = (call.arguments as Map)['sessionId'] as int;
        if (disconnectDuringOpen) await event('disconnected', session);
      }
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('old Android SPP callbacks cannot corrupt a new session', () async {
    final first = await ClassicSppService.connectAndroidForTesting('old');
    final oldSession = session;
    // Closing before a consumer listens must not hang.
    await first.close().timeout(const Duration(seconds: 1));
    final second = await ClassicSppService.connectAndroidForTesting('new');
    final received = <List<int>>[];
    final subscription = second.data.listen(received.add);
    try {
      await event('data', oldSession, bytes: [1]);
      await event('disconnected', oldSession);
      await event('data', session, bytes: [2]);
      await Future<void>.delayed(Duration.zero);
      expect(second.isConnected, isTrue);
      expect(received, [
        [2],
      ]);
      expect(() => first.write([3]), throwsStateError);
      await event('disconnected', session);
      expect(second.isConnected, isFalse);
    } finally {
      await subscription.cancel();
      await second.close();
    }
  });

  test(
    'disconnect before Android connect reply cannot resurrect a dead link',
    () async {
      disconnectDuringOpen = true;
      await expectLater(
        ClassicSppService.connectAndroidForTesting('device'),
        throwsStateError,
      );
    },
  );
}

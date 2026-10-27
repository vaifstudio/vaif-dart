import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:vaif_client/vaif_client.dart';

void main() {
  test(
    'realtime sends auth frame, waits for ack, receives changes and unsubscribes',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final frames = <Map<String, dynamic>>[];
      final socketReady = Completer<WebSocket>();
      server.listen((request) async {
        expect(request.uri.path, '/realtime/ws');
        expect(request.uri.hasQuery, isFalse);
        final ws = await WebSocketTransformer.upgrade(request);
        socketReady.complete(ws);
        ws.listen((data) {
          final frame = jsonDecode(data as String) as Map<String, dynamic>;
          frames.add(frame);
          if (frame['type'] == 'auth') {
            ws.add(jsonEncode({'type': 'welcome', 'connectionId': 'conn'}));
          }
          if (frame['type'] == 'subscribe') {
            ws.add(
              jsonEncode({'type': 'subscribed', 'channel': frame['channel']}),
            );
          }
          if (frame['type'] == 'ping') ws.add(jsonEncode({'type': 'pong'}));
        });
      });
      final client = VaifClient(
        projectId: 'p',
        apiKey: 'key',
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      addTearDown(client.close);
      await client.auth.setSession('token');
      final sub = await client.realtime.subscribe('notes');
      expect(frames.first, {
        'type': 'auth',
        'apiKey': 'key',
        'accessToken': 'token',
      });
      expect(sub.channel, 'table:notes');
      final change = sub.changes.first;
      final ws = await socketReady.future;
      ws.add(
        jsonEncode({
          'type': 'db_change',
          'table': 'notes',
          'op': 'INSERT',
          'new': {'id': 'r'},
          'channels': ['table:notes'],
        }),
      );
      expect(
        (await change.timeout(const Duration(seconds: 2)))['op'],
        'INSERT',
      );
      await sub.unsubscribe();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(frames.last, {'type': 'unsubscribe', 'channel': 'table:notes'});
      client.realtime.disconnect();
      expect(client.realtime.isConnected, isFalse);
    },
  );

  test(
    'realtime surfaces auth refusal instead of claiming connected',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final ws = await WebSocketTransformer.upgrade(request);
        ws.listen((_) {
          ws.add(
            jsonEncode({
              'type': 'error',
              'code': 'TOKEN_INVALID',
              'message': 'refused',
            }),
          );
          unawaited(ws.close(4401));
        });
      });
      final client = VaifClient(
        projectId: 'p',
        apiKey: 'key',
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      addTearDown(client.close);
      await expectLater(
        client.realtime.connect(),
        throwsA(
          isA<VaifException>().having((e) => e.code, 'code', 'TOKEN_INVALID'),
        ),
      );
      expect(client.realtime.isConnected, isFalse);
    },
  );
}

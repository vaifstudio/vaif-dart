import 'dart:async';
import 'dart:convert';

import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:vaif_client/vaif_client.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class FakeSocket extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  final incoming = StreamController<dynamic>();
  final outgoing = StreamController<dynamic>();
  @override
  Stream<dynamic> get stream => incoming.stream;
  @override
  late final WebSocketSink sink = FakeSink(outgoing.sink);
  @override
  Future<void> get ready => Future.value();
  @override
  String? get protocol => null;
  @override
  int? get closeCode => null;
  @override
  String? get closeReason => null;
  void send(Map<String, Object?> message) => incoming.add(jsonEncode(message));
}

class FakeSink implements WebSocketSink {
  FakeSink(this.inner);
  final StreamSink<dynamic> inner;
  @override
  void add(dynamic data) => inner.add(data);
  @override
  void addError(Object error, [StackTrace? trace]) =>
      inner.addError(error, trace);
  @override
  Future<void> addStream(Stream<dynamic> stream) => inner.addStream(stream);
  @override
  Future<void> close([int? code, String? reason]) => inner.close();
  @override
  Future<void> get done => inner.done;
}

void main() {
  test(
    'WebSocket transport authenticates, waits for ack, routes changes and closes',
    () async {
      final socket = FakeSocket();
      final frames = <Map<String, dynamic>>[];
      final listener = socket.outgoing.stream.listen((dynamic frame) {
        final data = jsonDecode(frame as String) as Map<String, dynamic>;
        frames.add(data);
        if (data['type'] == 'auth') socket.send({'type': 'welcome'});
        if (data['type'] == 'subscribe') {
          socket.send({'type': 'subscribed', 'channel': data['channel']});
        }
      });
      addTearDown(listener.cancel);
      final client = RealtimeClient(
        baseUrl: 'https://api.test',
        apiKey: 'key',
        accessToken: () async => 'token',
        timeout: const Duration(seconds: 1),
        channelFactory: (uri) {
          expect(uri.toString(), 'wss://api.test/realtime/ws');
          return socket;
        },
      );
      addTearDown(client.disconnect);
      final sub = await client.subscribe('notes');
      expect(client.isConnected, isTrue);
      expect(frames.first, {
        'type': 'auth',
        'apiKey': 'key',
        'accessToken': 'token',
      });
      final event = sub.changes.first;
      socket.send({'type': 'db_change', 'table': 'other', 'op': 'UPDATE'});
      socket.send({
        'type': 'db_change',
        'table': 'notes',
        'op': 'INSERT',
        'record': {'id': 'r'},
        'channels': ['table:notes'],
      });
      expect((await event)['record'], {'id': 'r'});
      client.setAuth('refreshed');
      await Future<void>.delayed(Duration.zero);
      expect(frames.last, {'type': 'auth', 'accessToken': 'refreshed'});
      await sub.unsubscribe();
      await Future<void>.delayed(Duration.zero);
      expect(frames.last, {'type': 'unsubscribe', 'channel': 'table:notes'});
      client.disconnect();
      expect(client.isConnected, isFalse);
      await socket.incoming.close();
    },
  );

  test('WebSocket auth refusal propagates server code', () async {
    final socket = FakeSocket();
    final listener = socket.outgoing.stream.listen(
      (dynamic _) => socket.send({
        'type': 'error',
        'code': 'TOKEN_INVALID',
        'message': 'refused',
      }),
    );
    addTearDown(listener.cancel);
    final client = RealtimeClient(
      baseUrl: 'http://localhost:3017',
      apiKey: 'key',
      accessToken: () async => null,
      timeout: const Duration(seconds: 1),
      channelFactory: (_) => socket,
    );
    addTearDown(client.disconnect);
    await expectLater(
      client.connect(),
      throwsA(
        isA<VaifException>().having((e) => e.code, 'code', 'TOKEN_INVALID'),
      ),
    );
    expect(client.isConnected, isFalse);
    await socket.incoming.close();
  });

  test(
    'WebSocket never resolves subscribe before server acknowledgment',
    () async {
      final socket = FakeSocket();
      final listener = socket.outgoing.stream.listen((dynamic frame) {
        final data = jsonDecode(frame as String) as Map;
        if (data['type'] == 'auth') socket.send({'type': 'welcome'});
      });
      addTearDown(listener.cancel);
      final client = RealtimeClient(
        baseUrl: 'http://localhost:3017',
        apiKey: 'key',
        accessToken: () async => null,
        timeout: const Duration(milliseconds: 20),
        channelFactory: (_) => socket,
      );
      addTearDown(client.disconnect);
      await expectLater(
        client.subscribe('notes'),
        throwsA(isA<VaifTimeoutException>()),
      );
      client.disconnect();
      await socket.incoming.close();
    },
  );

  test('a binary frame is ignored and the connection keeps working', () async {
    final socket = FakeSocket();
    final listener = socket.outgoing.stream.listen((dynamic frame) {
      final data = jsonDecode(frame as String) as Map<String, dynamic>;
      if (data['type'] == 'auth') {
        socket.send({'type': 'welcome'});
        socket.incoming.add(<int>[1, 2, 3]);
      }
      if (data['type'] == 'subscribe') {
        socket.send({'type': 'subscribed', 'channel': data['channel']});
      }
    });
    addTearDown(listener.cancel);
    final client = RealtimeClient(
      baseUrl: 'https://api.test',
      apiKey: 'key',
      accessToken: () async => null,
      timeout: const Duration(seconds: 1),
      channelFactory: (_) => socket,
    );
    addTearDown(client.disconnect);

    final sub = await client.subscribe('notes');

    expect(sub.channel, 'table:notes');
    expect(client.isConnected, isTrue);
  });

  test('a token change during the handshake is sent once the server '
      'welcomes the connection', () async {
    final socket = FakeSocket();
    final frames = <Map<String, dynamic>>[];
    final authSent = Completer<void>();
    final listener = socket.outgoing.stream.listen((dynamic frame) {
      final data = jsonDecode(frame as String) as Map<String, dynamic>;
      frames.add(data);
      if (data['type'] == 'auth' && !authSent.isCompleted) authSent.complete();
    });
    addTearDown(listener.cancel);
    final client = RealtimeClient(
      baseUrl: 'https://api.test',
      apiKey: 'key',
      accessToken: () async => 't1',
      timeout: const Duration(seconds: 1),
      channelFactory: (_) => socket,
    );
    addTearDown(client.disconnect);

    final connecting = client.connect();
    await authSent.future;
    client.setAuth('t2');
    socket.send({'type': 'welcome'});
    await connecting;
    await pumpEventQueue();

    expect(frames, [
      {'type': 'auth', 'apiKey': 'key', 'accessToken': 't1'},
      {'type': 'auth', 'accessToken': 't2'},
    ]);
  });

  test('a failed token refresh during the handshake surfaces as the auth '
      'error', () async {
    final socket = FakeSocket();
    final client = RealtimeClient(
      baseUrl: 'https://api.test',
      apiKey: 'key',
      accessToken:
          () async =>
              throw VaifAuthException(
                'Invalid or expired refresh token',
                status: 401,
                code: 'UNAUTHORIZED',
              ),
      timeout: const Duration(seconds: 1),
      channelFactory: (_) => socket,
    );
    addTearDown(client.disconnect);

    await expectLater(
      client.connect(),
      throwsA(
        isA<VaifAuthException>()
            .having((e) => e.status, 'status', 401)
            .having((e) => e.code, 'code', 'UNAUTHORIZED'),
      ),
    );
    expect(client.isConnected, isFalse);
  });
}

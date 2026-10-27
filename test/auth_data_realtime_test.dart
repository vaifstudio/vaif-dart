// Covers scope-aware refresh, project-user auth, bulk writes and aggregates,
// and filtered realtime.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:vaif_client/vaif_client.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support.dart';

class FakeSocket extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  final incoming = StreamController<dynamic>();
  final outgoing = StreamController<dynamic>();
  @override
  Stream<dynamic> get stream => incoming.stream;
  @override
  late final WebSocketSink sink = _Sink(outgoing.sink);
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

class _Sink implements WebSocketSink {
  _Sink(this.inner);
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

/// A realtime server double that welcomes and acknowledges every subscribe.
({FakeSocket socket, List<Map<String, dynamic>> frames}) ackingSocket() {
  final socket = FakeSocket();
  final frames = <Map<String, dynamic>>[];
  socket.outgoing.stream.listen((dynamic frame) {
    final data = jsonDecode(frame as String) as Map<String, dynamic>;
    frames.add(data);
    if (data['type'] == 'auth') socket.send({'type': 'welcome'});
    if (data['type'] == 'subscribe') {
      socket.send({'type': 'subscribed', 'channel': data['channel']});
    }
  });
  return (socket: socket, frames: frames);
}

void main() {
  group('platform scope', () {
    test('sign-in does not ask for body refresh mode and refresh uses the '
        'platform cookie name', () async {
      final api =
          FakeApi()
            ..on('POST', '/auth/login', [
              jsonResponse(
                200,
                {'accessToken': 'a', 'expiresIn': 900},
                headers: {'set-cookie': 'refresh_token=plat; Path=/; HttpOnly'},
              ),
            ])
            ..on('POST', '/auth/refresh', [
              jsonResponse(
                200,
                {'accessToken': 'b', 'expiresIn': 900},
                headers: {
                  'set-cookie': 'refresh_token=plat2; Path=/; HttpOnly',
                },
              ),
            ]);
      final client = VaifClient(
        apiKey: key,
        baseUrl: base,
        httpClient: api.client,
        retry: fastRetry,
      );
      addTearDown(client.close);
      final signedIn = await client.auth.signIn('a@b.c', 'pw');
      expect(signedIn.session!.refreshToken, 'plat');
      expect(
        api.requests.first.headers.containsKey('x-vaif-refresh-mode'),
        isFalse,
      );
      final refreshed = await client.auth.refreshSession();
      expect(refreshed.refreshToken, 'plat2');
      expect(api.requests.last.headers['cookie'], 'refresh_token=plat');
      expect(
        api.requests.last.headers.containsKey('x-vaif-refresh-mode'),
        isFalse,
      );
    });

    test('a project cookie is not mistaken for the platform one', () async {
      final api =
          FakeApi()..on('POST', '/auth/login', [
            jsonResponse(
              200,
              {'accessToken': 'a'},
              headers: {'set-cookie': 'project_refresh_token=x; Path=/'},
            ),
          ]);
      final client = VaifClient(
        apiKey: key,
        baseUrl: base,
        httpClient: api.client,
      );
      addTearDown(client.close);
      expect(
        (await client.auth.signIn('a@b.c', 'pw')).session!.refreshToken,
        isNull,
      );
    });

    test('generated console-only operations name themselves and the project '
        'route, before any request, streamed or not', () async {
      final api = FakeApi();
      final client = VaifClient(
        apiKey: key,
        baseUrl: base,
        httpClient: api.client,
      );
      addTearDown(client.close);
      await expectLater(
        client.operations.postAuthSignup(body: {'email': 'a@b.c'}),
        throwsA(
          isA<VaifConsoleOnlyError>()
              .having((e) => e.method, 'method', 'postAuthSignup()')
              .having(
                (e) => e.message,
                'message',
                contains('postProjectsByProjectIdAuthSignup'),
              ),
        ),
      );
      await expectLater(
        client.operations.postAuthForgotPassword(body: {'email': 'a@b.c'}),
        throwsA(
          isA<VaifConsoleOnlyError>()
              .having((e) => e.method, 'method', 'postAuthForgotPassword()')
              .having(
                (e) => e.consoleUrl,
                'consoleUrl',
                'https://console.vaif.studio/forgot-password',
              ),
        ),
      );
      expect(api.requests, isEmpty);
    });

    test(
      'project-only auth helpers fail locally on a platform client',
      () async {
        final api = FakeApi();
        final client = VaifClient(
          apiKey: key,
          baseUrl: base,
          httpClient: api.client,
        );
        addTearDown(client.close);
        final calls = <Future<Object?> Function()>[
          () => client.auth.sendMagicLink('a@b.c'),
          () => client.auth.listOAuthProviders(),
          () => client.auth.sessions.list(),
          () => client.auth.sessions.revoke('s1'),
          () => client.auth.sessions.revokeAll(),
        ];
        for (final call in calls) {
          await expectLater(
            call(),
            throwsA(
              isA<VaifException>().having(
                (e) => e.code,
                'code',
                'PROJECT_ID_REQUIRED',
              ),
            ),
          );
        }
        expect(api.requests, isEmpty);
      },
    );
  });

  group('project-user auth', () {
    test('signing out during a refresh is not undone by the refresh', () async {
      final release = Completer<void>();
      final api =
          FakeApi()
            ..on('POST', authPath('refresh'), [
              (http.Request _) async {
                await release.future;
                return jsonResponse(200, {
                  'accessToken': 'new',
                  'refreshToken': 'r2',
                });
              },
            ])
            ..on('POST', authPath('logout'), [
              jsonResponse(200, {'ok': true}),
            ]);
      final client = makeClient(api);
      addTearDown(client.close);
      await client.auth.setSession('old', refreshToken: 'r1');
      final refreshing = client.auth.refreshSession();
      await Future<void>.delayed(Duration.zero);
      await client.auth.signOut();
      release.complete();
      await expectLater(
        refreshing,
        throwsA(
          isA<VaifAuthException>().having(
            (e) => e.code,
            'code',
            'SESSION_CHANGED',
          ),
        ),
      );
      expect(client.auth.session, isNull);
    });

    test('magic link asks for body refresh mode', () async {
      final api =
          FakeApi()..on('POST', authPath('magic/send'), [
            jsonResponse(200, {'ok': true}),
          ]);
      final client = makeClient(api);
      addTearDown(client.close);
      await client.auth.sendMagicLink('a@b.c', redirectUrl: 'app://magic');
      expect(bodyOf(api.requests.single), {
        'email': 'a@b.c',
        'redirectUrl': 'app://magic',
        'refreshMode': 'body',
      });
    });

    test(
      'email verification send needs a session; confirm sends the token',
      () async {
        final api =
            FakeApi()
              ..on('POST', authPath('verify-email/send'), [
                jsonResponse(200, {}),
              ])
              ..on('POST', authPath('verify-email/confirm'), [
                jsonResponse(200, {'ok': true, 'message': 'verified'}),
              ]);
        final client = makeClient(api);
        addTearDown(client.close);
        await expectLater(
          client.auth.sendEmailVerification(),
          throwsA(isA<VaifAuthException>()),
        );
        expect(api.requests, isEmpty);
        await client.auth.setSession('at');
        await client.auth.sendEmailVerification();
        expect(api.requests.single.headers['authorization'], 'Bearer at');
        await client.auth.confirmEmailVerification('tok');
        expect(bodyOf(api.requests.last), {'token': 'tok'});
      },
    );

    test(
      'OAuth providers and device sessions use the project routes',
      () async {
        final api =
            FakeApi()
              ..on('GET', authPath('oauth/providers'), [
                jsonResponse(200, {
                  'providers': [
                    {'provider': 'google', 'enabled': true},
                  ],
                }),
              ])
              ..on('GET', authPath('sessions'), [
                jsonResponse(200, {
                  'sessions': [
                    {'id': 's1'},
                  ],
                }),
              ])
              ..on('DELETE', authPath('sessions/a%2Fb'), [
                jsonResponse(200, {'ok': true, 'id': 'a/b'}),
              ])
              ..on('DELETE', authPath('sessions'), [
                jsonResponse(200, {'ok': true, 'revoked': 2, 'ids': []}),
              ]);
        final client = makeClient(api);
        await client.auth.setSession('at');
        addTearDown(client.close);
        expect(
          (await client.auth.listOAuthProviders()).single['provider'],
          'google',
        );
        expect((await client.auth.sessions.list()).single['id'], 's1');
        await client.auth.sessions.revoke('a/b');
        expect(api.requests.last.url.path, authPath('sessions/a%2Fb'));
        expect(await client.auth.sessions.revokeAll(), 2);
        expect(
          api.requests
              .skip(1)
              .every((r) => r.headers['authorization'] == 'Bearer at'),
          isTrue,
        );
      },
    );
  });

  group('bulk writes and aggregates', () {
    test('updateMany sends the equality filter in the body', () async {
      final api =
          FakeApi()..on('PATCH', dataPath('notes', '/bulk'), [
            jsonResponse(200, {
              'data': [
                {'id': 1},
              ],
              'count': 1,
            }),
          ]);
      final client = makeClient(api);
      addTearDown(client.close);
      final result = await client.from('notes').eq('done', false).updateMany({
        'done': true,
      });
      expect(result.count, 1);
      expect(result.data.single['id'], 1);
      expect(bodyOf(api.requests.single), {
        'data': {'done': true},
        'filter': {'done': 'false'},
      });
    });

    test(
      'deleteMany puts the filter in the query and returns deleted',
      () async {
        final api =
            FakeApi()..on('DELETE', dataPath('notes', '/bulk'), [
              jsonResponse(200, {
                'deleted': 3,
                'ids': [1, 2, 3],
              }),
            ]);
        final client = makeClient(api);
        addTearDown(client.close);
        expect(await client.from('notes').eq('owner', 'u 1').deleteMany(), 3);
        expect(api.requests.single.url.queryParameters, {
          'filter[owner]': 'u 1',
        });
      },
    );

    test(
      'bulk writes refuse an unfiltered or non-equality query locally',
      () async {
        final api = FakeApi();
        final client = makeClient(api);
        addTearDown(client.close);
        await expectLater(
          client.from('notes').deleteMany(),
          throwsArgumentError,
        );
        await expectLater(
          client.from('notes').updateMany({'a': 1}),
          throwsArgumentError,
        );
        await expectLater(
          client.from('notes').gt('id', 1).deleteMany(),
          throwsArgumentError,
        );
        await expectLater(
          client.from('notes').where({
            'OR': [
              {'field': 'a', 'value': 1},
            ],
          }).deleteMany(),
          throwsArgumentError,
        );
        await expectLater(
          client.from('notes').eq('a', 1).updateMany({}),
          throwsArgumentError,
        );
        expect(api.requests, isEmpty);
      },
    );

    test('sum, avg, min and max use the aggregate route', () async {
      final api =
          FakeApi()..on('GET', dataPath('orders', '/aggregate'), [
            jsonResponse(200, {
              'data': [
                {'value': 7},
              ],
            }),
            jsonResponse(200, {
              'data': [
                {'value': '2.5'},
              ],
            }),
            jsonResponse(200, {
              'data': [
                {'value': 'a'},
              ],
            }),
            jsonResponse(200, {'data': []}),
          ]);
      final client = makeClient(api);
      addTearDown(client.close);
      final orders = client.from('orders').eq('status', 'paid');
      expect(await orders.sum('total'), 7);
      expect(await orders.avg('total'), 2.5);
      expect(await orders.min('name'), 'a');
      expect(await orders.max('name'), isNull);
      expect(api.requests.map((r) => r.url.queryParameters['fn']).toList(), [
        'sum',
        'avg',
        'min',
        'max',
      ]);
      expect(api.requests.first.url.queryParameters, {
        'fn': 'sum',
        'column': 'total',
        'filter[status]': 'paid',
      });
      expect(() => orders.sum('bad col'), throwsArgumentError);
    });
  });

  group('realtime', () {
    test('filters and columns become the server channel', () async {
      final fake = ackingSocket();
      final client = RealtimeClient(
        baseUrl: 'https://api.test',
        apiKey: 'key',
        accessToken: () async => null,
        timeout: const Duration(seconds: 1),
        channelFactory: (_) => fake.socket,
      );
      addTearDown(client.disconnect);
      final sub = await client.subscribe(
        'notes',
        filters: const [
          RealtimeFilter('done', 'eq', false),
          RealtimeFilter('tag', 'in', ['a b', 'c']),
        ],
        columns: const ['id', 'body'],
      );
      expect(
        sub.channel,
        'table:notes?done.eq=false&tag.in=a%20b%2Cc&columns=id,body',
      );
      expect(fake.frames.last, {'type': 'subscribe', 'channel': sub.channel});
      expect(
        () => client.subscribe(
          'notes',
          filters: const [RealtimeFilter('x', 'like', 'a%')],
        ),
        throwsArgumentError,
      );
      expect(
        () => client.subscribe(
          'notes',
          filters: const [RealtimeFilter('x', 'eq', null)],
        ),
        throwsArgumentError,
      );
    });

    test('a change for two subscriptions reaches both, including the one '
        'not named in channel', () async {
      final fake = ackingSocket();
      final client = RealtimeClient(
        baseUrl: 'https://api.test',
        apiKey: 'key',
        accessToken: () async => null,
        timeout: const Duration(seconds: 1),
        channelFactory: (_) => fake.socket,
      );
      addTearDown(client.disconnect);
      final all = await client.subscribe('notes');
      final mine = await client.subscribe(
        'notes',
        filters: const [RealtimeFilter('owner', 'eq', 'u1')],
      );
      final a = all.changes.first;
      final b = mine.changes.first;
      fake.socket.send({
        'type': 'db_change',
        'table': 'notes',
        'op': 'INSERT',
        'channel': all.channel,
        'channels': [all.channel, mine.channel],
        'record': {'owner': 'u1'},
      });
      expect((await a.timeout(const Duration(seconds: 1)))['op'], 'INSERT');
      expect((await b.timeout(const Duration(seconds: 1)))['op'], 'INSERT');
    });

    test(
      'QueryBuilder.subscribe turns the chain into realtime filters',
      () async {
        final fake = ackingSocket();
        final api = FakeApi();
        final client = VaifClient(
          projectId: project,
          apiKey: key,
          baseUrl: base,
          httpClient: api.client,
          realtimeChannelFactory: (_) => fake.socket,
        );
        addTearDown(client.close);
        final sub =
            await client.from('notes').eq('owner', 'u1').gte('rank', 2).select([
              'id',
            ]).subscribe();
        expect(sub.channel, 'table:notes?owner.eq=u1&rank.gte=2&columns=id');
        await expectLater(
          client.from('notes').like('body', 'a%').subscribe(),
          throwsArgumentError,
        );
        expect(api.requests, isEmpty);
      },
    );

    test(
      'a non-fatal server error keeps the connection; a closing one ends it',
      () async {
        final fake = ackingSocket();
        final client = RealtimeClient(
          baseUrl: 'https://api.test',
          apiKey: 'key',
          accessToken: () async => null,
          timeout: const Duration(seconds: 1),
          channelFactory: (_) => fake.socket,
        );
        addTearDown(client.disconnect);
        final sub = await client.subscribe('notes');
        final errors = <Object>[];
        final done = Completer<void>();
        sub.changes.listen((_) {}, onError: errors.add, onDone: done.complete);
        fake.socket.send({
          'type': 'error',
          'error': 'RateLimited',
          'message': 'Too many messages.',
        });
        fake.socket.send({'type': 'error', 'code': 42, 'message': 7});
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(client.isConnected, isTrue);
        expect(errors, isEmpty);
        fake.socket.send({
          'type': 'error',
          'error': 'AuthRefreshFailed',
          'code': 'TOKEN_INVALID',
          'message': 'refused',
          'closeCode': 4401,
        });
        await done.future.timeout(const Duration(seconds: 1));
        expect(client.isConnected, isFalse);
        expect(
          errors.single,
          isA<VaifException>().having((e) => e.code, 'code', 'TOKEN_INVALID'),
        );
      },
    );

    test(
      'a channel factory that throws is a network error, not a crash',
      () async {
        final client = RealtimeClient(
          baseUrl: 'https://api.test',
          apiKey: 'key',
          accessToken: () async => null,
          timeout: const Duration(milliseconds: 50),
          channelFactory: (_) => throw const FormatException('bad'),
        );
        addTearDown(client.disconnect);
        await expectLater(
          client.connect(),
          throwsA(isA<VaifNetworkException>()),
        );
        // Outlive the welcome timeout: a leaked timer would fail the test.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(client.isConnected, isFalse);
      },
    );
  });
}

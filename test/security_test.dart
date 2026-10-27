// Guarantees about credentials and sessions that every VAIF SDK keeps: whose
// token a request carries, what a sign-out ends, and where credentials go.
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:vaif_client/vaif_client.dart';

import 'support.dart';

/// A [SessionStorage] that records its calls and fails on request.
class FakeStorage implements SessionStorage {
  final Map<String, String> values = {};
  final List<String> calls = [];
  int failReads = 0;
  int failWrites = 0;
  int failDeletes = 0;

  /// When set, the next write waits for it.
  Completer<void>? holdWrite;

  /// When set, the next read waits for it, then returns the value that was
  /// saved when the read started.
  Completer<void>? holdRead;

  /// The most calls that were running at the same time.
  int maxActive = 0;
  int _active = 0;

  Future<T> _track<T>(Future<T> Function() call) async {
    _active++;
    if (_active > maxActive) maxActive = _active;
    try {
      return await call();
    } finally {
      _active--;
    }
  }

  @override
  Future<String?> read(String key) => _track(() async {
    calls.add('read');
    final value = values[key];
    final hold = holdRead;
    holdRead = null;
    if (hold != null) await hold.future;
    if (failReads > 0) {
      failReads--;
      throw StateError('read failed');
    }
    return value;
  });

  @override
  Future<void> write(String key, String value) => _track(() async {
    calls.add('write');
    final hold = holdWrite;
    holdWrite = null;
    if (hold != null) await hold.future;
    if (failWrites > 0) {
      failWrites--;
      throw StateError('write failed');
    }
    values[key] = value;
  });

  @override
  Future<void> delete(String key) => _track(() async {
    calls.add('delete');
    if (failDeletes > 0) {
      failDeletes--;
      throw StateError('delete failed');
    }
    values.remove(key);
  });
}

VaifClient storageClient(
  FakeApi api,
  SessionStorage storage, {
  String baseUrl = base,
  String? projectId = project,
}) => VaifClient(
  projectId: projectId,
  apiKey: key,
  baseUrl: baseUrl,
  httpClient: api.client,
  retry: fastRetry,
  sessionStorage: storage,
);

final storageFailure = isA<VaifSessionStorageException>().having(
  (e) => e.code,
  'code',
  'SESSION_STORAGE_FAILED',
);

void main() {
  group('session identity', () {
    test('a request rejected with 401 after the user changed is not sent '
        'again with the new user\'s token', () async {
      final held = Completer<http.Response>();
      final api =
          FakeApi()
            ..on('POST', dataPath('todos'), [
              (http.Request _) => held.future,
              jsonResponse(201, {
                'data': {'id': 'row_b'},
              }),
            ])
            ..on('POST', authPath('logout'), [
              jsonResponse(200, {'ok': true}),
            ]);
      final client = makeClient(api);
      addTearDown(client.close);
      await client.auth.setSession('at_a', refreshToken: 'rt_a');

      final insert = client.from('todos').insert({'title': 'from A'});
      await pumpEventQueue();
      await client.auth.signOut();
      await client.auth.setSession('at_b', refreshToken: 'rt_b');
      held.complete(
        jsonResponse(401, {
          'error': 'UNAUTHORIZED',
          'message': 'Session revoked',
        }),
      );

      await expectLater(
        insert,
        throwsA(
          isA<VaifAuthException>().having((e) => e.status, 'status', 401),
        ),
      );
      final inserts = api.calls('POST', dataPath('todos'));
      expect(inserts, hasLength(1));
      expect(inserts.single.headers['authorization'], 'Bearer at_a');
    });

    test('a refresh for a new session does not wait on a refresh that '
        'started from the session before it', () async {
      final heldA = Completer<http.Response>();
      final api =
          FakeApi()
            ..on('POST', authPath('refresh'), [
              (http.Request _) => heldA.future,
              jsonResponse(200, {
                'accessToken': 'at_b2',
                'refreshToken': 'rt_b2',
                'expiresIn': 900,
              }),
            ])
            ..on('POST', authPath('logout'), [
              jsonResponse(200, {'ok': true}),
            ]);
      final client = makeClient(api);
      addTearDown(client.close);
      await client.auth.setSession('at_a', refreshToken: 'rt_a');

      final refreshA = client.auth.refreshSession();
      await pumpEventQueue();
      await client.auth.signOut();
      await client.auth.setSession('at_b', refreshToken: 'rt_b');
      final refreshB = await client.auth.refreshSession();

      expect(refreshB.accessToken, 'at_b2');
      expect(client.auth.session!.refreshToken, 'rt_b2');
      final refreshes = api.calls('POST', authPath('refresh'));
      expect(refreshes.map((r) => bodyOf(r)['refreshToken']), ['rt_a', 'rt_b']);

      heldA.complete(
        jsonResponse(200, {
          'accessToken': 'at_a2',
          'refreshToken': 'rt_a2',
          'expiresIn': 900,
        }),
      );
      await expectLater(
        refreshA,
        throwsA(
          isA<VaifAuthException>().having(
            (e) => e.code,
            'code',
            'SESSION_CHANGED',
          ),
        ),
      );
      expect(client.auth.session!.accessToken, 'at_b2');
    });
  });

  group('functions', () {
    test('a 401 the function returned is thrown to the caller, without a '
        'refresh or a second invocation', () async {
      final api =
          FakeApi()
            ..on('POST', '/functions/check/invoke', [
              jsonResponse(
                401,
                {'error': 'BAD_SIGNATURE'},
                headers: {'x-vaif-run-id': 'run_1'},
              ),
            ])
            ..on('POST', authPath('refresh'), [
              jsonResponse(200, {
                'accessToken': 'at_2',
                'refreshToken': 'rt_2',
                'expiresIn': 900,
              }),
            ]);
      final client = makeClient(api);
      addTearDown(client.close);
      await client.auth.setSession('at_1', refreshToken: 'rt_1');

      await expectLater(
        client.functions.invoke('check'),
        throwsA(
          isA<VaifAuthException>()
              .having((e) => e.status, 'status', 401)
              .having((e) => e.code, 'code', 'BAD_SIGNATURE')
              .having((e) => e.headers?['x-vaif-run-id'], 'run id', 'run_1'),
        ),
      );
      expect(api.calls('POST', '/functions/check/invoke'), hasLength(1));
      expect(api.calls('POST', authPath('refresh')), isEmpty);
      expect(client.auth.session!.accessToken, 'at_1');
    });

    test('a 401 from the API itself refreshes the session and invokes once '
        'more', () async {
      final api =
          FakeApi()
            ..on('POST', '/functions/check/invoke', [
              jsonResponse(401, {
                'error': 'UNAUTHORIZED',
                'message': 'Invalid or expired token',
              }),
              jsonResponse(
                200,
                {'ok': true},
                headers: {'x-vaif-run-id': 'run_2'},
              ),
            ])
            ..on('POST', authPath('refresh'), [
              jsonResponse(200, {
                'accessToken': 'at_2',
                'refreshToken': 'rt_2',
                'expiresIn': 900,
              }),
            ]);
      final client = makeClient(api);
      addTearDown(client.close);
      await client.auth.setSession('at_1', refreshToken: 'rt_1');

      final response = await client.functions.invoke('check');

      expect(response.data, {'ok': true});
      expect(
        api
            .calls('POST', '/functions/check/invoke')
            .map((r) => r.headers['authorization']),
        ['Bearer at_1', 'Bearer at_2'],
      );
    });
  });

  group('sign-out', () {
    test('signOut revokes the session with the refresh token after the '
        'access token expired', () async {
      final api =
          FakeApi()
            ..on('POST', authPath('logout'), [
              jsonResponse(200, {'ok': true}),
            ])
            ..on('POST', '/auth/logout', [
              jsonResponse(200, {'ok': true}),
            ]);
      final expired = DateTime.now().subtract(const Duration(minutes: 5));
      final project = makeClient(api);
      final platform = VaifClient(
        apiKey: key,
        baseUrl: base,
        httpClient: api.client,
      );
      addTearDown(project.close);
      addTearDown(platform.close);
      await project.auth.setSession(
        'at_p',
        refreshToken: 'rt_p',
        expiresAt: expired,
      );
      await platform.auth.setSession(
        'at_c',
        refreshToken: 'rt_c',
        expiresAt: expired,
      );

      await project.auth.signOut();
      await platform.auth.signOut();

      final projectLogout = api.calls('POST', authPath('logout')).single;
      expect(projectLogout.headers['authorization'], 'Bearer at_p');
      expect(bodyOf(projectLogout), {'refreshToken': 'rt_p'});
      expect(projectLogout.headers['cookie'], 'project_refresh_token=rt_p');
      // The platform route reads the refresh token from its cookie only.
      final platformLogout = api.calls('POST', '/auth/logout').single;
      expect(platformLogout.headers['authorization'], 'Bearer at_c');
      expect(platformLogout.headers['cookie'], 'refresh_token=rt_c');
      expect(project.auth.session, isNull);
      expect(platform.auth.session, isNull);
    });

    test('a refresh that finishes after signOut revokes the session the '
        'server issued to it', () async {
      final held = Completer<http.Response>();
      final api =
          FakeApi()
            ..on('POST', authPath('refresh'), [(http.Request _) => held.future])
            ..on('POST', authPath('logout'), [
              jsonResponse(200, {'ok': true}),
            ]);
      final client = makeClient(api);
      addTearDown(client.close);
      await client.auth.setSession('at_1', refreshToken: 'rt_1');

      final refreshing = client.auth.refreshSession();
      await pumpEventQueue();
      await client.auth.signOut();
      held.complete(
        jsonResponse(200, {
          'accessToken': 'at_2',
          'refreshToken': 'rt_2',
          'expiresIn': 900,
        }),
      );

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
      final logouts = api.calls('POST', authPath('logout'));
      expect(logouts, hasLength(2));
      expect(logouts.last.headers['authorization'], 'Bearer at_2');
      expect(bodyOf(logouts.last), {'refreshToken': 'rt_2'});
    });
  });

  group('signed storage URLs', () {
    test('a signed URL the API returns must use https, except on a loopback '
        'host', () async {
      final api =
          FakeApi()
            ..on('POST', '/storage/download-url', [
              jsonResponse(200, {'url': 'http://files.example.com/o?sig=x'}),
              jsonResponse(200, {'url': 'http://127.0.0.1:9000/o?sig=x'}),
            ])
            ..on('POST', '/storage/upload-url', [
              jsonResponse(200, {'url': 'http://files.example.com/o?sig=y'}),
              jsonResponse(200, {'url': 'http://localhost:9000/o?sig=y'}),
            ]);
      final client = makeClient(api);
      addTearDown(client.close);
      final insecure = throwsA(
        isA<VaifException>().having(
          (e) => e.code,
          'code',
          'INSECURE_STORAGE_URL',
        ),
      );

      await expectLater(client.storage.createSignedUrl('a.bin'), insecure);
      await expectLater(
        client.storage.createSignedUploadUrl('a.bin', sizeBytes: 1),
        insecure,
      );
      expect(
        await client.storage.createSignedUrl('a.bin'),
        'http://127.0.0.1:9000/o?sig=x',
      );
      expect(
        await client.storage.createSignedUploadUrl('a.bin', sizeBytes: 1),
        'http://localhost:9000/o?sig=y',
      );
    });

    test('a redirect from a signed link is followed only to https, without '
        'credentials', () async {
      final api =
          FakeApi()
            ..on('POST', '/storage/download-url', [
              jsonResponse(200, {'url': 'https://files.test/o/a?sig=x'}),
              jsonResponse(200, {'url': 'https://files.test/o/c?sig=x'}),
            ])
            ..on('GET', '/o/a', [
              http.Response(
                '',
                307,
                headers: {'location': 'http://files.example.com/o/b?sig=x'},
              ),
            ])
            ..on('GET', '/o/b', [
              http.Response.bytes([6, 6, 6], 200),
            ])
            ..on('GET', '/o/c', [
              http.Response(
                '',
                302,
                headers: {'location': 'https://cdn.test/o/d?sig=y'},
              ),
            ])
            ..on('GET', '/o/d', [
              http.Response.bytes([1, 2, 3], 200),
            ]);
      final client = makeClient(api);
      addTearDown(client.close);
      await client.auth.setSession('at_1', refreshToken: 'rt_1');

      await expectLater(
        client.storage.download('a.bin'),
        throwsA(
          isA<VaifException>().having(
            (e) => e.code,
            'code',
            'INSECURE_STORAGE_URL',
          ),
        ),
      );
      expect(api.calls('GET', '/o/b'), isEmpty);

      expect(await client.storage.download('c.bin'), [1, 2, 3]);
      final hop = api.calls('GET', '/o/d').single;
      expect(hop.url.toString(), 'https://cdn.test/o/d?sig=y');
      expect(hop.headers.containsKey('x-vaif-key'), isFalse);
      expect(hop.headers.containsKey('authorization'), isFalse);
    });

    test("a network error on a signed URL does not carry the URL's "
        'query', () async {
      Never reset(http.Request request) =>
          throw http.ClientException('Connection reset by peer', request.url);
      final api =
          FakeApi()
            ..on('POST', '/storage/download-url', [
              jsonResponse(200, {
                'url': 'https://files.test/o/a.bin?sig=secret',
              }),
            ])
            ..on('POST', '/storage/upload-url', [
              jsonResponse(200, {
                'url': 'https://files.test/o/b.bin?sig=secret',
              }),
            ])
            ..on('GET', '/storage/download', [
              http.Response(
                '',
                307,
                headers: {'location': 'https://files.test/o/a.bin?sig=secret'},
              ),
            ])
            ..on('GET', '/o/a.bin', [reset])
            ..on('PUT', '/o/b.bin', [reset]);
      final client = makeClient(api, retry: RetryPolicy.none);
      addTearDown(client.close);
      Matcher networkError(String cause) => throwsA(
        isA<VaifNetworkException>()
            .having((e) => '${e.cause}', 'cause', cause)
            .having((e) => '$e', 'toString()', isNot(contains('sig='))),
      );

      await expectLater(
        client.storage.download('a.bin'),
        networkError(
          'ClientException: Connection reset by peer, '
          'uri=https://files.test/o/a.bin',
        ),
      );
      await expectLater(
        client.operations.getStorageDownload(query: {'key': 'a.bin'}),
        networkError(
          'ClientException: Connection reset by peer, '
          'uri=https://files.test/o/a.bin',
        ),
      );
      await expectLater(
        client.storage.upload('b.bin', [1]),
        networkError(
          'ClientException: Connection reset by peer, '
          'uri=https://files.test/o/b.bin',
        ),
      );
      expect(api.calls('GET', '/o/a.bin'), hasLength(2));
      expect(api.calls('PUT', '/o/b.bin'), hasLength(1));
    });
  });

  group('redirects', () {
    test('no redirect carries the API key or the session token to another '
        'origin', () async {
      // Two loopback servers on different ports are two origins: the API,
      // and a host its redirects point at.
      final apiServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final otherServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => apiServer.close(force: true));
      addTearDown(() => otherServer.close(force: true));
      final apiOrigin = 'http://127.0.0.1:${apiServer.port}';
      final otherOrigin = 'http://127.0.0.1:${otherServer.port}';
      // Every request either server received: "<server> <path> <credentials>".
      final seen = <String>[];
      String credentials(HttpRequest request) => [
        for (final name in ['x-vaif-key', 'authorization', 'cookie'])
          if (request.headers.value(name) != null) name,
      ].join(',');
      Future<void> answer(
        HttpRequest request,
        int status, {
        String? location,
        List<int> bytes = const [],
        String? json,
      }) async {
        request.response.statusCode = status;
        if (location != null) {
          request.response.headers.set('location', location);
        }
        if (json != null) {
          request.response.headers.contentType = ContentType.json;
          request.response.write(json);
        } else {
          request.response.add(bytes);
        }
        await request.response.close();
      }

      apiServer.listen((request) async {
        seen.add('api ${request.uri.path} ${credentials(request)}');
        switch (request.uri.path) {
          case '/v1/data/$project/todos':
            await answer(request, 302, location: '$otherOrigin/steal');
          case '/storage/download-url':
            await answer(
              request,
              200,
              json: '{"url": "$otherOrigin/o/a?sig=x"}',
            );
          case '/storage/download':
            await answer(request, 307, location: '$otherOrigin/o/b?sig=x');
          case '/storage/echo':
            await answer(request, 200, bytes: [7]);
          default:
            await answer(request, 404);
        }
      });
      otherServer.listen((request) async {
        seen.add('other ${request.uri.path} ${credentials(request)}');
        switch (request.uri.path) {
          case '/o/a':
            // Back to the API's origin, as a link host might.
            await answer(request, 307, location: '$apiOrigin/storage/echo');
          case '/o/b':
            await answer(request, 200, bytes: [9]);
          default:
            await answer(request, 200, bytes: [6, 6, 6]);
        }
      });

      final client = VaifClient(
        projectId: project,
        apiKey: key,
        baseUrl: apiOrigin,
        retry: fastRetry,
      );
      addTearDown(client.close);
      await client.auth.setSession('at_1', refreshToken: 'rt_1');

      await expectLater(
        client.from('todos').list(),
        throwsA(isA<VaifException>().having((e) => e.status, 'status', 302)),
      );
      expect(await client.storage.download('a.bin'), [7]);
      expect(
        await client.operations.getStorageDownload(query: {'key': 'a.bin'}),
        [9],
      );

      expect(seen, [
        'api /v1/data/$project/todos x-vaif-key,authorization',
        'api /storage/download-url x-vaif-key,authorization',
        'other /o/a ',
        'api /storage/echo ',
        'api /storage/download x-vaif-key,authorization',
        'other /o/b ',
      ]);
    });
  });

  group('session storage', () {
    test('two clients for one project at different base URLs never restore '
        'each other\'s session', () async {
      final storage = FakeStorage();
      final api = FakeApi();
      final a = storageClient(api, storage, baseUrl: 'https://a.test');
      final b = storageClient(api, storage, baseUrl: 'https://b.test/');
      final platform = storageClient(
        api,
        storage,
        baseUrl: 'https://a.test',
        projectId: null,
      );
      addTearDown(a.close);
      addTearDown(b.close);
      addTearDown(platform.close);

      expect(
        a.auth.sessionStorageKey,
        'vaif_client.session|https://a.test|proj_123',
      );
      expect(
        b.auth.sessionStorageKey,
        'vaif_client.session|https://b.test|proj_123',
      );
      expect(
        platform.auth.sessionStorageKey,
        'vaif_client.session|https://a.test|',
      );

      await a.auth.setSession('at_a', refreshToken: 'rt_a');
      expect(await b.auth.loadSession(), isNull);
      expect(await platform.auth.loadSession(), isNull);
      final again = storageClient(api, storage, baseUrl: 'https://a.test');
      addTearDown(again.close);
      expect((await again.auth.loadSession())!.accessToken, 'at_a');
      expect(storage.values.keys, [
        'vaif_client.session|https://a.test|proj_123',
      ]);
    });

    test('a session saved under this client\'s key for another base URL is '
        'not restored', () async {
      final storage = FakeStorage();
      final api = FakeApi();
      final a = storageClient(api, storage, baseUrl: 'https://a.test');
      addTearDown(a.close);
      await a.auth.setSession('at_a', refreshToken: 'rt_a');
      // A storage that ignores keys hands every client the same value.
      final saved = storage.values.values.single;
      final b = storageClient(api, storage, baseUrl: 'https://b.test');
      addTearDown(b.close);
      storage.values[b.auth.sessionStorageKey] = saved;

      expect(await b.auth.loadSession(), isNull);
      expect(b.auth.session, isNull);
    });

    test('a new session that cannot be saved deletes the saved one, so the '
        'older session is not restored', () async {
      final storage = FakeStorage();
      final api =
          FakeApi()..on('POST', authPath('login'), [
            jsonResponse(200, {
              'accessToken': 'at_b',
              'refreshToken': 'rt_b',
              'expiresIn': 900,
            }),
          ]);
      final client = storageClient(api, storage);
      addTearDown(client.close);
      await client.auth.setSession('at_a', refreshToken: 'rt_a');
      expect(storage.values, hasLength(1));

      storage.failWrites = 1;
      final signedIn = await client.auth.signIn('b@example.com', 'pw');

      expect(signedIn.session!.accessToken, 'at_b');
      expect(client.auth.session!.accessToken, 'at_b');
      expect(storage.values, isEmpty);
      expect(client.auth.sessionStorageError, storageFailure);
      final next = storageClient(api, storage);
      addTearDown(next.close);
      expect(await next.auth.loadSession(), isNull);
    });

    test('a sign-in throws when its session cannot be saved and the older '
        'one cannot be deleted', () async {
      final storage = FakeStorage();
      final client = storageClient(FakeApi(), storage);
      addTearDown(client.close);
      await client.auth.setSession('at_a', refreshToken: 'rt_a');

      storage
        ..failWrites = 1
        ..failDeletes = 1;
      await expectLater(
        client.auth.setSession('at_b', refreshToken: 'rt_b'),
        throwsA(storageFailure),
      );
      expect(client.auth.session!.accessToken, 'at_b');
      expect(storage.calls, ['write', 'write', 'delete']);
    });

    test('signOut throws when the saved session cannot be deleted, and '
        'signOut again retries the delete', () async {
      final storage = FakeStorage();
      final api =
          FakeApi()..on('POST', authPath('logout'), [
            jsonResponse(200, {'ok': true}),
          ]);
      final client = storageClient(api, storage);
      addTearDown(client.close);
      await client.auth.setSession('at_a', refreshToken: 'rt_a');

      storage.failDeletes = 1;
      await expectLater(client.auth.signOut(), throwsA(storageFailure));
      expect(client.auth.session, isNull);
      expect(api.calls('POST', authPath('logout')), hasLength(1));
      expect(storage.values, hasLength(1));

      await client.auth.signOut();
      expect(storage.values, isEmpty);
      expect(client.auth.sessionStorageError, isNull);
      expect(api.calls('POST', authPath('logout')), hasLength(1));
    });

    test('storage calls run in the order the session changed', () async {
      final storage = FakeStorage();
      final api =
          FakeApi()
            ..on('POST', authPath('refresh'), [
              jsonResponse(200, {
                'accessToken': 'at_2',
                'refreshToken': 'rt_2',
                'expiresIn': 900,
              }),
            ])
            ..on('POST', authPath('logout'), [
              jsonResponse(200, {'ok': true}),
            ]);
      final client = storageClient(api, storage);
      addTearDown(client.close);
      await client.auth.setSession('at_1', refreshToken: 'rt_1');

      final slowWrite = Completer<void>();
      storage.holdWrite = slowWrite;
      await client.auth.refreshSession();
      final signingOut = client.auth.signOut();
      await pumpEventQueue();
      slowWrite.complete();
      await signingOut;

      expect(storage.calls, ['write', 'write', 'delete']);
      expect(storage.values, isEmpty);
    });

    test('loadSession restores a saved session without saving it again, and '
        'deletes one it cannot use', () async {
      final storage = FakeStorage();
      final api = FakeApi();
      final first = storageClient(api, storage);
      addTearDown(first.close);
      await first.auth.setSession(
        'at_1',
        refreshToken: 'rt_1',
        expiresAt: DateTime.utc(2030),
      );

      final second = storageClient(api, storage);
      addTearDown(second.close);
      final events = <AuthChangeEvent>[];
      second.auth.onAuthStateChange.listen((c) => events.add(c.event));
      final restored = await second.auth.loadSession();
      expect(restored!.accessToken, 'at_1');
      expect(restored.refreshToken, 'rt_1');
      expect(restored.expiresAt, DateTime.utc(2030));
      expect(second.auth.session, same(restored));
      await pumpEventQueue();
      expect(events, [AuthChangeEvent.signedIn]);
      expect(storage.calls, ['write', 'read']);

      final key = second.auth.sessionStorageKey;
      for (final unusable in [
        'not a session',
        '{"baseUrl": "$base", "projectId": "$project", '
            '"session": {"accessToken": "at", "expiresAt": "2030-01-01T00:00:00.000Z", '
            '"refreshToken": 7}}',
      ]) {
        storage.values[key] = unusable;
        final third = storageClient(api, storage);
        addTearDown(third.close);
        expect(await third.auth.loadSession(), isNull, reason: unusable);
        expect(storage.values, isEmpty, reason: unusable);
      }

      await first.auth.setSession('at_old', expiresAt: DateTime.utc(2020));
      final fourth = storageClient(api, storage);
      addTearDown(fourth.close);
      expect(await fourth.auth.loadSession(), isNull);
      expect(storage.values, isEmpty);

      storage.failReads = 1;
      final fifth = storageClient(api, storage);
      addTearDown(fifth.close);
      await expectLater(fifth.auth.loadSession(), throwsA(storageFailure));
    });

    test('a signOut during loadSession waits for the read, and the saved '
        'session it deletes is not restored', () async {
      final storage = FakeStorage();
      final api = FakeApi();
      final first = storageClient(api, storage);
      addTearDown(first.close);
      await first.auth.setSession(
        'at_saved',
        refreshToken: 'rt_saved',
        expiresAt: DateTime.utc(2030),
      );

      final client = storageClient(api, storage);
      addTearDown(client.close);
      final read = Completer<void>();
      storage.holdRead = read;
      final loading = client.auth.loadSession();
      await pumpEventQueue();
      final signingOut = client.auth.signOut();
      await pumpEventQueue();
      read.complete();
      await signingOut;

      expect(await loading, isNull);
      expect(client.auth.session, isNull);
      expect(storage.values, isEmpty);
      expect(storage.calls, ['write', 'read', 'delete']);
      expect(storage.maxActive, 1);
    });

    test('a sign-in and a sign-out during loadSession leave the client '
        'signed out, and the saved session is not restored', () async {
      final storage = FakeStorage();
      final api =
          FakeApi()..on('POST', authPath('logout'), [
            jsonResponse(200, {'ok': true}),
          ]);
      final first = storageClient(api, storage);
      addTearDown(first.close);
      await first.auth.setSession(
        'at_saved',
        refreshToken: 'rt_saved',
        expiresAt: DateTime.utc(2030),
      );

      final client = storageClient(api, storage);
      addTearDown(client.close);
      final read = Completer<void>();
      storage.holdRead = read;
      final loading = client.auth.loadSession();
      await pumpEventQueue();
      final signingIn = client.auth.setSession(
        'at_new',
        refreshToken: 'rt_new',
      );
      final signingOut = client.auth.signOut();
      await pumpEventQueue();
      read.complete();
      await signingIn;
      await signingOut;

      expect(await loading, isNull);
      expect(client.auth.session, isNull);
      expect(storage.values, isEmpty);
      expect(storage.calls, ['write', 'read', 'write', 'delete']);
      expect(storage.maxActive, 1);
      expect(api.calls('POST', authPath('logout')), hasLength(1));
    });

    test('session storage cannot be combined with a starting session, and '
        'loadSession needs it', () async {
      final api = FakeApi();
      expect(
        () => VaifClient(
          projectId: project,
          apiKey: key,
          baseUrl: base,
          httpClient: api.client,
          session: Session(accessToken: 'at', expiresAt: DateTime.utc(2030)),
          sessionStorage: FakeStorage(),
        ),
        throwsArgumentError,
      );
      final plain = makeClient(api);
      addTearDown(plain.close);
      await expectLater(plain.auth.loadSession(), throwsStateError);
    });
  });
}

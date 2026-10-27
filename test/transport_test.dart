import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:vaif_client/vaif_client.dart';
import 'package:vaif_client/src/transport.dart' show parseRetryAfter;

import 'support.dart';

void main() {
  group('construction', () {
    test('rejects plain http for remote hosts', () {
      expect(
        () => VaifClient(
          projectId: project,
          apiKey: key,
          baseUrl: 'http://api.vaif.studio',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('allows http for localhost and strips trailing slashes', () {
      final c = VaifClient(
        projectId: project,
        apiKey: key,
        baseUrl: 'http://localhost:3000//',
      );
      expect(c.baseUrl, 'http://localhost:3000');
      c.close();
    });

    test('rejects empty project id, empty key, bad timeout and queries', () {
      expect(() => VaifClient(projectId: '', apiKey: key), throwsArgumentError);
      expect(
        () => VaifClient(projectId: project, apiKey: ''),
        throwsArgumentError,
      );
      expect(
        () =>
            VaifClient(projectId: project, apiKey: key, timeout: Duration.zero),
        throwsArgumentError,
      );
      expect(
        () => VaifClient(
          projectId: project,
          apiKey: key,
          baseUrl: 'https://a.b/?x=1',
        ),
        throwsArgumentError,
      );
    });
  });

  test(
    'sends the key, version and user agent; no bearer when signed out',
    () async {
      final api =
          FakeApi()..on('GET', dataPath('todos'), [
            jsonResponse(200, {'data': [], 'count': 0}),
          ]);
      await makeClient(api).from('todos').list();
      final headers = api.requests.single.headers;
      expect(headers['x-vaif-key'], key);
      expect(headers['accept-versions'], 'v1');
      expect(headers['user-agent'], 'vaif-dart/1.0.0');
      expect(headers.containsKey('authorization'), isFalse);
    },
  );

  group('status mapping', () {
    final cases = <
      (int, Map<String, Object?>, TypeMatcher<VaifException>, String?)
    >[
      (
        400,
        {'error': 'BadRequest', 'code': 'INVALID_COLUMN', 'message': 'no col'},
        isA<VaifValidationException>(),
        'INVALID_COLUMN',
      ),
      (
        401,
        {'error': 'INVALID_CREDENTIALS', 'message': 'bad'},
        isA<VaifAuthException>(),
        'INVALID_CREDENTIALS',
      ),
      (
        403,
        {'error': 'FORBIDDEN', 'message': 'nope'},
        isA<VaifAuthException>(),
        'FORBIDDEN',
      ),
      (
        404,
        {'error': 'NOT_FOUND', 'message': 'Record not found'},
        isA<VaifNotFoundException>(),
        'NOT_FOUND',
      ),
      (
        409,
        {'error': 'CONFLICT', 'message': 'dupe'},
        isA<VaifConflictException>(),
        'CONFLICT',
      ),
      (422, {'message': 'bad entity'}, isA<VaifValidationException>(), null),
      (
        402,
        {'error': 'PAYMENT_REQUIRED', 'message': 'upgrade'},
        isA<VaifException>(),
        'PAYMENT_REQUIRED',
      ),
    ];
    for (final (status, body, matcher, code) in cases) {
      test('$status', () async {
        final api =
            FakeApi()..on('GET', dataPath('todos'), [
              jsonResponse(status, {...body, 'requestId': 'req_1'}),
            ]);
        final error = await makeClient(api)
            .from('todos')
            .list()
            .then<Object>((_) => 'no error', onError: (Object e) => e);
        expect(error, matcher);
        final e = error as VaifException;
        expect(e.status, status);
        expect(e.code, code);
        expect(e.requestId, 'req_1');
        expect(e.message, body['message']);
        expect(e.toString(), contains('status: $status'));
      });
    }

    test('falls back to x-request-id and the reason phrase', () async {
      final api =
          FakeApi()..on('GET', dataPath('todos'), [
            http.Response(
              '',
              418,
              headers: {'x-request-id': 'hdr_1'},
              reasonPhrase: 'Teapot',
            ),
          ]);
      final error = await makeClient(api)
          .from('todos')
          .list()
          .then<Object>((_) => 'no error', onError: (Object e) => e);
      expect(error, isA<VaifException>());
      expect((error as VaifException).requestId, 'hdr_1');
      expect(error.message, 'Teapot');
    });
  });

  group('retries', () {
    test('GET is retried on 503/502 and then succeeds', () async {
      final api =
          FakeApi()..on('GET', dataPath('todos'), [
            jsonResponse(503, {'error': 'Unavailable'}),
            http.Response('', 502),
            jsonResponse(200, {
              'data': [
                {'id': 1},
              ],
              'count': 1,
            }),
          ]);
      final result = await makeClient(api).from('todos').list();
      expect(api.requests, hasLength(3));
      expect(result.count, 1);
    });

    test('the retry budget is bounded', () async {
      final api =
          FakeApi()..on('GET', dataPath('todos'), [http.Response('', 500)]);
      await expectLater(
        makeClient(api).from('todos').list(),
        throwsA(isA<VaifServerException>()),
      );
      expect(api.requests, hasLength(fastRetry.maxRetries + 1));
    });

    test('POST is not replayed on 5xx', () async {
      final api =
          FakeApi()..on('POST', dataPath('todos'), [http.Response('', 503)]);
      await expectLater(
        makeClient(api).from('todos').insert({'title': 'x'}),
        throwsA(isA<VaifServerException>()),
      );
      expect(api.requests, hasLength(1));
    });

    test('POST is not replayed after a timeout', () async {
      final api =
          FakeApi()..on('POST', dataPath('todos'), [
            (http.Request r) async {
              await Future<void>.delayed(const Duration(milliseconds: 300));
              return jsonResponse(200, {
                'data': {'id': 1},
              });
            },
          ]);
      final client = makeClient(api, timeout: const Duration(milliseconds: 40));
      await expectLater(
        client.from('todos').insert({'title': 'x'}),
        throwsA(isA<VaifTimeoutException>()),
      );
      expect(api.requests, hasLength(1));
    });

    test('a GET timeout is retried and then thrown', () async {
      final api =
          FakeApi()..on('GET', dataPath('todos'), [
            (http.Request r) async {
              await Future<void>.delayed(const Duration(milliseconds: 200));
              return jsonResponse(200, {'data': [], 'count': 0});
            },
          ]);
      final client = makeClient(api, timeout: const Duration(milliseconds: 20));
      await expectLater(
        client.from('todos').list(),
        throwsA(isA<VaifTimeoutException>()),
      );
      expect(api.requests, hasLength(4));
    });

    test('network errors are typed and keep the cause', () async {
      final api =
          FakeApi()..on('GET', dataPath('todos'), [
            http.ClientException('dns failure'),
          ]);
      final error = await makeClient(api, retry: RetryPolicy.none)
          .from('todos')
          .list()
          .then<Object>((_) => 'no error', onError: (Object e) => e);
      expect(error, isA<VaifNetworkException>());
      expect(error, isNot(isA<VaifTimeoutException>()));
      expect(
        (error as VaifNetworkException).cause,
        isA<http.ClientException>(),
      );
    });

    test('a transport error that is not a ClientException is a '
        'VaifNetworkException too', () async {
      // dart:io errors that package:http passes through as they are: a TLS
      // handshake failure while connecting, a socket error while the body
      // is read.
      final client = VaifClient(
        projectId: project,
        apiKey: key,
        baseUrl: base,
        retry: RetryPolicy.none,
        httpClient: MockClient.streaming((request, _) async {
          if (request.url.path.endsWith('/notes')) {
            return http.StreamedResponse(
              Stream<List<int>>.error(
                const SocketException('Connection reset'),
              ),
              200,
            );
          }
          throw const HandshakeException('CERTIFICATE_VERIFY_FAILED');
        }),
      );
      addTearDown(client.close);

      await expectLater(
        client.from('todos').list(),
        throwsA(
          isA<VaifNetworkException>().having(
            (e) => e.cause,
            'cause',
            isA<HandshakeException>(),
          ),
        ),
      );
      await expectLater(
        client.from('notes').list(),
        throwsA(
          isA<VaifNetworkException>().having(
            (e) => e.cause,
            'cause',
            isA<SocketException>(),
          ),
        ),
      );
      await expectLater(
        client.operations.postAiCopilotChatStream(body: {'message': 'hi'}),
        throwsA(
          isA<VaifNetworkException>().having(
            (e) => e.cause,
            'cause',
            isA<HandshakeException>(),
          ),
        ),
      );
    });

    test('a GET network error is retried; a POST one is not', () async {
      final api =
          FakeApi()
            ..on('GET', dataPath('todos'), [
              http.ClientException('reset'),
              jsonResponse(200, {'data': [], 'count': 0}),
            ])
            ..on('POST', dataPath('todos'), [http.ClientException('reset')]);
      final client = makeClient(api);
      await client.from('todos').list();
      expect(api.calls('GET', dataPath('todos')), hasLength(2));
      await expectLater(
        client.from('todos').insert({'a': 1}),
        throwsA(isA<VaifNetworkException>()),
      );
      expect(api.calls('POST', dataPath('todos')), hasLength(1));
    });

    test('429 honors Retry-After and exposes it', () async {
      final sleeps = <Duration>[];
      final api =
          FakeApi()..on('GET', dataPath('todos'), [
            jsonResponse(
              429,
              {'error': 'RateLimited'},
              headers: {'retry-after': '7'},
            ),
          ]);
      final client = makeClient(
        api,
        retry: const RetryPolicy(maxRetries: 1, baseDelay: Duration.zero),
        sleeps: sleeps,
      );
      final error = await client
          .from('todos')
          .list()
          .then<Object>((_) => 'no error', onError: (Object e) => e);
      expect(error, isA<VaifRateLimitException>());
      expect(
        (error as VaifRateLimitException).retryAfter,
        const Duration(seconds: 7),
      );
      expect(sleeps, [const Duration(seconds: 7)]);
      expect(api.requests, hasLength(2));
    });
  });

  test('Retry-After parses seconds and HTTP dates', () {
    final now = DateTime.utc(2026, 9, 25, 12);
    expect(parseRetryAfter('2.5'), const Duration(milliseconds: 2500));
    expect(
      parseRetryAfter('Fri, 25 Sep 2026 12:00:30 GMT', now: now),
      const Duration(seconds: 30),
    );
    expect(
      parseRetryAfter('Fri, 25 Sep 2026 11:00:00 GMT', now: now),
      Duration.zero,
    );
    expect(parseRetryAfter('soon'), isNull);
    expect(parseRetryAfter(null), isNull);
  });

  test(
    'retry delay is exponential, capped, jittered and prefers Retry-After',
    () {
      const policy = RetryPolicy(
        baseDelay: Duration(seconds: 1),
        maxDelay: Duration(seconds: 5),
        multiplier: 2,
      );
      final r = Random(1);
      int ms(int attempt) => policy.delayFor(attempt, random: r).inMilliseconds;
      expect(ms(0), inInclusiveRange(1000, 1250));
      expect(ms(2), inInclusiveRange(4000, 5000));
      expect(ms(40), inInclusiveRange(5000, 6250));
      expect(ms(100000), inInclusiveRange(5000, 6250)); // overflow-safe
      expect(
        policy.delayFor(0, retryAfter: const Duration(seconds: 3)),
        const Duration(seconds: 3),
      );
      expect(
        policy.delayFor(0, retryAfter: const Duration(minutes: 1)),
        const Duration(seconds: 5),
      );
    },
  );

  test('custom headers are sent and cannot replace the API key', () async {
    final api =
        FakeApi()..on('GET', dataPath('todos'), [
          jsonResponse(200, {'data': [], 'count': 0}),
        ]);
    await makeClient(
      api,
      headers: {'X-App': 'demo', 'X-Vaif-Key': 'other'},
    ).from('todos').list();
    expect(api.requests.single.headers['x-app'], 'demo');
    expect(api.requests.single.headers['x-vaif-key'], key);
  });

  test('a non-JSON success body is a typed error', () async {
    final api =
        FakeApi()..on('GET', dataPath('todos'), [http.Response('<html>', 200)]);
    await expectLater(
      makeClient(api).from('todos').list(),
      throwsA(isA<VaifException>()),
    );
  });

  test('packageVersion matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(
      r'^version:\s*(\S+)',
      multiLine: true,
    ).firstMatch(pubspec)!.group(1);
    expect(packageVersion, version);
  });
}

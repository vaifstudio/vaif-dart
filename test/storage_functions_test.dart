import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:vaif_client/vaif_client.dart';

import 'support.dart';

const presigned = 'https://objects.test/bucket/key?X-Amz-Signature=abc';

void main() {
  late FakeApi api;
  late VaifClient client;

  setUp(() {
    api = FakeApi();
    client = makeClient(api);
  });

  group('storage', () {
    test(
      'upload mints a URL then PUTs the bytes without VAIF credentials',
      () async {
        api
          ..on('POST', '/storage/upload-url', [
            jsonResponse(200, {'url': presigned}),
          ])
          ..on('PUT', '/bucket/key', [
            http.Response('', 503),
            http.Response('', 200),
          ]);
        await client.auth.setSession('at_1', refreshToken: 'rt_1');

        final result = await client.storage.upload(
          'avatars/u1.png',
          utf8.encode('png!'),
          contentType: 'image/png',
          bucket: 'pics',
        );

        final mint = api.calls('POST', '/storage/upload-url').single;
        expect(bodyOf(mint), {
          'key': 'avatars/u1.png',
          'bucket': 'pics',
          'sizeBytes': 4,
          'contentType': 'image/png',
        });
        expect(mint.headers['authorization'], 'Bearer at_1');
        final puts = api.calls('PUT', '/bucket/key');
        expect(puts, hasLength(2), reason: 'the PUT is retried on 503');
        expect(puts.last.headers['content-type'], 'image/png');
        expect(puts.last.headers.containsKey('x-vaif-key'), isFalse);
        expect(puts.last.headers.containsKey('authorization'), isFalse);
        expect(puts.last.bodyBytes, utf8.encode('png!'));
        expect(result.size, 4);
        expect(result.bucket, 'pics');
      },
    );

    test('the metered mint is not retried', () async {
      api.on('POST', '/storage/upload-url', [http.Response('', 503)]);
      await expectLater(
        client.storage.upload('a.txt', [1]),
        throwsA(isA<VaifServerException>()),
      );
      expect(api.requests, hasLength(1));
    });

    test('a rejected PUT is typed with STORAGE_UPLOAD_FAILED', () async {
      api
        ..on('POST', '/storage/upload-url', [
          jsonResponse(200, {'url': presigned}),
        ])
        ..on('PUT', '/bucket/key', [
          http.Response('<Error>AccessDenied</Error>', 403),
        ]);
      await expectLater(
        client.storage.upload('a.txt', [1]),
        throwsA(
          isA<VaifException>().having(
            (e) => e.code,
            'code',
            'STORAGE_UPLOAD_FAILED',
          ),
        ),
      );
    });

    test('download reads the signed link the API issues, without VAIF '
        'credentials', () async {
      api
        ..on('POST', '/storage/download-url', [
          jsonResponse(200, {
            'ok': true,
            'url': 'https://files.test/o/a.bin?sig=x',
            'expiresIn': 600,
          }),
        ])
        ..on('GET', '/o/a.bin', [
          http.Response('', 503),
          http.Response.bytes(
            [1, 2, 3],
            200,
            headers: {'content-type': 'application/octet-stream'},
          ),
        ]);
      await client.auth.setSession('at_1', refreshToken: 'rt_1');

      final bytes = await client.storage.download('docs/a.bin', bucket: 'b');

      expect(bytes, Uint8List.fromList([1, 2, 3]));
      final mint = api.calls('POST', '/storage/download-url').single;
      expect(bodyOf(mint), {'key': 'docs/a.bin', 'bucket': 'b'});
      expect(mint.headers['authorization'], 'Bearer at_1');
      final reads = api.calls('GET', '/o/a.bin');
      expect(reads, hasLength(2), reason: 'the object GET is retried on 503');
      expect(reads.last.url.toString(), 'https://files.test/o/a.bin?sig=x');
      expect(reads.last.headers.containsKey('x-vaif-key'), isFalse);
      expect(reads.last.headers.containsKey('authorization'), isFalse);
    });

    test('a missing object is VaifNotFoundException; an API refusal sends no '
        'object request', () async {
      api
        ..on('POST', '/storage/download-url', [
          jsonResponse(200, {'url': 'https://files.test/o/missing.bin?sig=x'}),
          jsonResponse(403, {
            'error': 'POLICY_DENIED',
            'message': 'Denied by storage policy',
          }),
        ])
        ..on('GET', '/o/missing.bin', [
          http.Response('<Error><Code>NoSuchKey</Code></Error>', 404),
        ]);
      await expectLater(
        client.storage.download('docs/missing.bin'),
        throwsA(
          isA<VaifNotFoundException>().having((e) => e.status, 'status', 404),
        ),
      );
      await expectLater(
        client.storage.download('docs/secret.bin'),
        throwsA(
          isA<VaifAuthException>().having(
            (e) => e.code,
            'code',
            'POLICY_DENIED',
          ),
        ),
      );
      expect(api.calls('GET', '/o/missing.bin'), hasLength(1));
      expect(api.requests, hasLength(3));
    });

    test('a signed link that is not https is refused before any request to '
        'it', () async {
      api
        ..on('POST', '/storage/download-url', [
          jsonResponse(200, {'url': 'http://files.example.com/o?sig=x'}),
        ])
        ..on('POST', '/storage/upload-url', [
          jsonResponse(200, {'url': 'http://files.example.com/o?sig=x'}),
        ]);
      final insecure = throwsA(
        isA<VaifException>().having(
          (e) => e.code,
          'code',
          'INSECURE_STORAGE_URL',
        ),
      );
      await expectLater(client.storage.download('a.bin'), insecure);
      await expectLater(client.storage.upload('a.bin', [1]), insecure);
      expect(api.calls('GET', '/o'), isEmpty);
      expect(api.calls('PUT', '/o'), isEmpty);
      expect(api.requests, hasLength(2));
    });

    test('signed URLs', () async {
      api
        ..on('POST', '/storage/download-url', [
          jsonResponse(200, {'url': 'https://dl.test/x'}),
        ])
        ..on('POST', '/storage/upload-url', [
          jsonResponse(200, {'url': 'https://ul.test/x'}),
        ]);
      expect(
        await client.storage.createSignedUrl('x', bucket: 'b'),
        'https://dl.test/x',
      );
      expect(bodyOf(api.requests.last), {'key': 'x', 'bucket': 'b'});
      // The lifetime may be chosen; omitted, the project's default applies.
      expect(
        await client.storage.createSignedUrl('x', expiresIn: 3600),
        'https://dl.test/x',
      );
      expect(bodyOf(api.requests.last), {'key': 'x', 'expiresIn': 3600});
      expect(
        await client.storage.createSignedUploadUrl('x', sizeBytes: 10),
        'https://ul.test/x',
      );
      expect(bodyOf(api.requests.last), {'key': 'x', 'sizeBytes': 10});
      expect(
        await client.storage.createSignedUploadUrl(
          'y',
          sizeBytes: 3,
          contentType: 'text/plain',
        ),
        'https://ul.test/x',
      );
      expect(bodyOf(api.requests.last), {
        'key': 'y',
        'sizeBytes': 3,
        'contentType': 'text/plain',
      });
    });

    test('keys and sizes are validated before any request', () {
      expect(() => client.storage.download(''), throwsArgumentError);
      expect(() => client.storage.download('/abs'), throwsArgumentError);
      expect(() => client.storage.download('a/../b'), throwsArgumentError);
      expect(() => client.storage.download('a\nb'), throwsArgumentError);
      expect(() => client.storage.upload('a', []), throwsArgumentError);
      expect(
        () => client.storage.createSignedUploadUrl('a', sizeBytes: 0),
        throwsRangeError,
      );
      expect(
        () => client.storage.createSignedUploadUrl(
          'a',
          sizeBytes: maxUploadBytes + 1,
        ),
        throwsRangeError,
      );
      expect(api.requests, isEmpty);
    });
  });

  group('functions', () {
    test('invoke sends the envelope and decodes JSON', () async {
      api.on('POST', '/functions/hello%20world/invoke', [
        jsonResponse(200, {'greeting': 'hi'}, headers: {'x-fn': '1'}),
      ]);
      final res = await client.functions.invoke(
        'hello world',
        body: {'name': 'Ada'},
        method: 'put',
        path: '/greet',
        query: {'lang': 'en'},
        headers: {'x-trace': 't1'},
      );
      expect(bodyOf(api.requests.single), {
        'method': 'PUT',
        'path': '/greet',
        'query': {'lang': 'en'},
        'headers': {'x-trace': 't1'},
        'body': {'name': 'Ada'},
      });
      expect(res.status, 200);
      expect(res.data, {'greeting': 'hi'});
      expect(res.headers['x-fn'], '1');
    });

    test('text, binary and empty responses', () async {
      api.on('POST', '/functions/f/invoke', [
        http.Response(
          'plain',
          200,
          headers: {'content-type': 'text/plain; charset=utf-8'},
        ),
        http.Response.bytes(
          [9, 8],
          200,
          headers: {'content-type': 'image/png'},
        ),
        http.Response('', 204),
      ]);
      expect((await client.functions.invoke('f')).data, 'plain');
      final binary = await client.functions.invoke('f');
      expect(binary.bytes, Uint8List.fromList([9, 8]));
      final empty = await client.functions.invoke('f');
      expect(empty.status, 204);
      expect(empty.data, isNull);
      expect(bodyOf(api.requests.first), {'method': 'POST', 'path': '/'});
    });

    test(
      'errors are typed; invocations are replayed only when idempotent',
      () async {
        api
          ..on('POST', '/functions/missing/invoke', [
            jsonResponse(404, {
              'error': 'NOT_FOUND',
              'message': 'Function not found',
            }),
          ])
          ..on('POST', '/functions/flaky/invoke', [http.Response('', 503)]);
        await expectLater(
          client.functions.invoke('missing'),
          throwsA(isA<VaifNotFoundException>()),
        );
        await expectLater(
          client.functions.invoke('flaky'),
          throwsA(isA<VaifServerException>()),
        );
        expect(api.calls('POST', '/functions/flaky/invoke'), hasLength(1));
        await expectLater(
          client.functions.invoke('flaky', idempotent: true),
          throwsA(isA<VaifServerException>()),
        );
        expect(api.calls('POST', '/functions/flaky/invoke'), hasLength(1 + 4));
      },
    );

    test('arguments are validated', () {
      expect(() => client.functions.invoke(''), throwsArgumentError);
      expect(
        () => client.functions.invoke('f', method: 'TRACE'),
        throwsArgumentError,
      );
      expect(
        () => client.functions.invoke('f', path: 'nope'),
        throwsArgumentError,
      );
    });
  });
}

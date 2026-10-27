// What each call sends: console-only routes on a platform client, refresh
// and logout bodies, MFA, OAuth PKCE, range and count filters, storage
// bucket resolution and the generated operations.
import 'package:test/test.dart';
import 'package:vaif_client/vaif_client.dart';

import 'support.dart';

void main() {
  test(
    'platform signup and reset throw CONSOLE_ONLY before transport',
    () async {
      final api = FakeApi();
      final client = VaifClient(
        apiKey: key,
        baseUrl: base,
        httpClient: api.client,
      );
      addTearDown(client.close);
      await expectLater(
        client.auth.signUp('a@b.c', 'pw'),
        throwsA(
          isA<VaifConsoleOnlyError>()
              .having((e) => e.code, 'code', 'CONSOLE_ONLY')
              .having(
                (e) => e.consoleUrl,
                'consoleUrl',
                'https://console.vaif.studio/register',
              ),
        ),
      );
      await expectLater(
        client.auth.requestPasswordReset('a@b.c'),
        throwsA(
          isA<VaifConsoleOnlyError>().having(
            (e) => e.code,
            'code',
            'CONSOLE_ONLY',
          ),
        ),
      );
      expect(api.requests, isEmpty);
    },
  );

  test(
    'body refresh mode works without cookies and logout sends refresh token',
    () async {
      final api =
          FakeApi()
            ..on('POST', authPath('login'), [
              jsonResponse(200, {
                'accessToken': 'a',
                'refreshToken': 'r',
                'expiresIn': 900,
              }),
            ])
            ..on('POST', authPath('refresh'), [
              jsonResponse(200, {'accessToken': 'b', 'refreshToken': 's'}),
            ])
            ..on('POST', authPath('logout'), [
              jsonResponse(200, {'ok': true}),
            ]);
      final client = makeClient(api);
      addTearDown(client.close);
      expect(
        (await client.auth.signIn('a@b.c', 'pw')).session!.refreshToken,
        'r',
      );
      expect(api.requests.first.headers['x-vaif-refresh-mode'], 'body');
      expect((await client.auth.refreshSession()).refreshToken, 's');
      expect(bodyOf(api.requests[1]), containsPair('refreshToken', 'r'));
      await client.auth.signOut();
      expect(bodyOf(api.requests.last), containsPair('refreshToken', 's'));
    },
  );

  test(
    'all MFA management calls carry the session and correct bodies',
    () async {
      final api = FakeApi();
      for (final suffix in [
        'enroll-start',
        'enroll-confirm',
        'disable',
        'regenerate-codes',
      ]) {
        api.on('POST', authPath('mfa/$suffix'), [
          jsonResponse(200, {
            'ok': true,
            'backupCodes': ['backup'],
          }),
        ]);
      }
      final client = makeClient(api);
      await client.auth.setSession('at');
      addTearDown(client.close);
      await client.auth.mfa.enrollStart();
      await client.auth.mfa.enrollConfirm('enroll', '123456');
      await client.auth.mfa.disable('123456');
      expect((await client.auth.mfa.regenerateCodes('123456'))['backupCodes'], [
        'backup',
      ]);
      expect(
        api.requests.every((r) => r.headers['authorization'] == 'Bearer at'),
        isTrue,
      );
      expect(bodyOf(api.requests[1]), {
        'enrollToken': 'enroll',
        'code': '123456',
      });
      expect(bodyOf(api.requests.last), {'code': '123456'});
    },
  );

  test(
    'OAuth uses S256 PKCE, consumes matching state and handles MFA',
    () async {
      const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      final api =
          FakeApi()
            ..on('POST', authPath('oauth/google/start'), [
              jsonResponse(200, {'url': 'https://accounts.google.com/auth'}),
            ])
            ..on('POST', authPath('oauth/token'), [
              jsonResponse(200, {
                'mfaRequired': true,
                'challengeToken': 'challenge',
              }),
            ]);
      final client = makeClient(api);
      addTearDown(client.close);
      final start = await client.auth.getOAuthSignInUrl(
        provider: 'google',
        redirectUrl: 'app://callback',
        codeVerifier: verifier,
        state: 'state',
      );
      expect(start.codeVerifier, verifier);
      expect(bodyOf(api.requests.first), {
        'redirectUrl': 'app://callback',
        'state': 'state',
        'codeChallengeMethod': 'S256',
        'codeChallenge': 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      });
      await expectLater(
        client.auth.handleOAuthCallback(code: 'code', state: 'wrong'),
        throwsA(
          isA<VaifException>().having(
            (e) => e.code,
            'code',
            'OAUTH_STATE_MISMATCH',
          ),
        ),
      );
      expect(api.requests, hasLength(1));
      final result = await client.auth.handleOAuthCallback(
        code: 'code',
        state: start.state,
      );
      expect(result.challengeToken, 'challenge');
      expect(bodyOf(api.requests.last), {
        'code': 'code',
        'codeVerifier': verifier,
      });
      await expectLater(
        client.auth.handleOAuthCallback(code: 'code', state: start.state),
        throwsA(isA<VaifException>()),
      );
      expect(api.requests, hasLength(2));
    },
  );

  test(
    'range is inclusive and count serializes equality aggregate filters',
    () async {
      final api =
          FakeApi()
            ..on('GET', dataPath('notes'), [
              jsonResponse(200, {'data': [], 'count': 12}),
            ])
            ..on('GET', dataPath('notes', '/aggregate'), [
              jsonResponse(200, {
                'data': [
                  {'value': 12},
                ],
              }),
            ]);
      final client = makeClient(api);
      addTearDown(client.close);
      final query = client.from('notes').eq('done', false);
      await query.range(5, 9).list();
      expect(
        api.requests.first.url.queryParameters,
        containsPair('offset', '5'),
      );
      expect(
        api.requests.first.url.queryParameters,
        containsPair('limit', '5'),
      );
      expect(await query.count(), 12);
      expect(api.requests.last.url.queryParameters, {
        'fn': 'count',
        'filter[done]': 'false',
      });
      expect(() => query.range(-1, 3), throwsRangeError);
      await expectLater(query.gt('id', 2).count(), throwsArgumentError);
      expect(api.requests, hasLength(2));
    },
  );

  test(
    'storage resolves bucket names for paginated list and encoded delete',
    () async {
      final api =
          FakeApi()
            ..on('GET', '/storage/buckets', [
              jsonResponse(200, {
                'buckets': [
                  {'id': 'bucket-id', 'name': 'assets'},
                ],
              }),
            ])
            ..on('GET', '/buckets/bucket-id/files', [
              jsonResponse(200, {
                'files': [
                  {'key': 'a & b.txt', 'size': 2},
                ],
                'nextToken': 'next',
                'isTruncated': true,
              }),
            ])
            ..on('DELETE', '/buckets/bucket-id/files', [
              jsonResponse(200, {'ok': true}),
            ]);
      final client = makeClient(api);
      addTearDown(client.close);
      final listed = await client.storage.list(
        bucket: 'assets',
        prefix: 'a ',
        limit: 2,
        cursor: 'cursor',
      );
      expect(listed.files.single['key'], 'a & b.txt');
      expect(listed.nextCursor, 'next');
      expect(listed.hasMore, isTrue);
      expect(api.requests[1].url.queryParameters, {
        'prefix': 'a ',
        'maxKeys': '2',
        'continuationToken': 'cursor',
      });
      await client.storage.delete('a & b.txt', bucket: 'assets');
      expect(api.requests.last.url.queryParameters, {'key': 'a & b.txt'});
      expect(api.calls('GET', '/storage/buckets'), hasLength(1));
    },
  );

  test(
    'generated operations use transport auth, encoded path and deep query',
    () async {
      final api =
          FakeApi()..on('GET', '/projects/a%2Fb/api-keys', [
            jsonResponse(200, {'keys': []}),
          ]);
      final client = makeClient(api);
      await client.auth.setSession('token');
      addTearDown(client.close);
      await client.operations.getProjectsByProjectIdApiKeys(
        path: {'projectId': 'a/b'},
        query: {
          'filter': {'x': false},
          'tags': ['a', 'b'],
        },
      );
      expect(api.requests.single.url.toString(), contains('a%2Fb'));
      expect(api.requests.single.url.queryParametersAll['tags'], ['a', 'b']);
      expect(api.requests.single.url.queryParameters['filter[x]'], 'false');
      expect(api.requests.single.headers['authorization'], 'Bearer token');
      await expectLater(
        client.operations.getProjectsByProjectIdApiKeys(path: {}),
        throwsArgumentError,
      );
      expect(api.requests, hasLength(1));
    },
  );

  test(
    'generated platform signup and reset also enforce console only',
    () async {
      final api = FakeApi();
      final client = VaifClient(
        apiKey: key,
        baseUrl: base,
        httpClient: api.client,
      );
      addTearDown(client.close);
      await expectLater(
        client.operations.postAuthSignup(body: {'email': 'a@b.c'}),
        throwsA(isA<VaifConsoleOnlyError>()),
      );
      await expectLater(
        client.operations.postAuthForgotPassword(body: {'email': 'a@b.c'}),
        throwsA(isA<VaifConsoleOnlyError>()),
      );
      expect(api.requests, isEmpty);
    },
  );
}

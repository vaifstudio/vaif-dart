import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:vaif_client/vaif_client.dart';

import 'support.dart';

const user = {
  'id': 'u1',
  'email': 'ada@example.com',
  'phone': null,
  'provider': 'email',
  'metadata': <String, Object?>{},
};

http.Response loginResponse({
  String token = 'at_1',
  String refresh = 'rt_1',
  int expiresIn = 900,
}) => jsonResponse(
  200,
  {'ok': true, 'accessToken': token, 'expiresIn': expiresIn, 'user': user},
  headers: {
    'set-cookie':
        'project_refresh_token=$refresh; Max-Age=2592000; '
        'Path=/projects/$project/auth; HttpOnly; SameSite=Lax',
  },
);

void main() {
  late FakeApi api;
  late VaifClient client;

  setUp(() {
    api = FakeApi();
    client = makeClient(api);
  });

  tearDown(() => client.close());

  test(
    'signIn stores the session and the refresh cookie and emits signedIn',
    () async {
      api.on('POST', authPath('login'), [loginResponse()]);
      final events = <AuthChangeEvent>[];
      client.auth.onAuthStateChange.listen((c) => events.add(c.event));

      final result = await client.auth.signIn('ada@example.com', 'pw');

      expect(bodyOf(api.requests.single), {
        'email': 'ada@example.com',
        'password': 'pw',
      });
      expect(result.mfaRequired, isFalse);
      final session = client.auth.session!;
      expect(session.accessToken, 'at_1');
      expect(session.refreshToken, 'rt_1');
      expect(session.user!.email, 'ada@example.com');
      expect(session.expiresIn.inSeconds, inInclusiveRange(890, 900));
      await pumpEventQueue();
      expect(events, [AuthChangeEvent.signedIn]);
    },
  );

  test('signed-in requests carry the bearer token', () async {
    api
      ..on('POST', authPath('login'), [loginResponse()])
      ..on('GET', dataPath('todos'), [
        jsonResponse(200, {'data': [], 'count': 0}),
      ]);
    await client.auth.signIn('ada@example.com', 'pw');
    await client.from('todos').list();
    expect(
      api.calls('GET', dataPath('todos')).single.headers['authorization'],
      'Bearer at_1',
    );
  });

  test('MFA: signIn returns a challenge, verifyMfa completes it', () async {
    api
      ..on('POST', authPath('login'), [
        jsonResponse(200, {
          'ok': true,
          'mfaRequired': true,
          'challengeToken': 'ch_1',
        }),
      ])
      ..on('POST', authPath('mfa/verify'), [loginResponse(token: 'at_mfa')]);
    final result = await client.auth.signIn('ada@example.com', 'pw');
    expect(result.mfaRequired, isTrue);
    expect(result.challengeToken, 'ch_1');
    expect(client.auth.session, isNull);

    final session = await client.auth.verifyMfa('ch_1', '123456');
    expect(bodyOf(api.calls('POST', authPath('mfa/verify')).single), {
      'challengeToken': 'ch_1',
      'code': '123456',
    });
    expect(session.accessToken, 'at_mfa');
    expect(client.auth.session, same(session));
  });

  test('bad credentials throw VaifAuthException', () async {
    api.on('POST', authPath('login'), [
      jsonResponse(401, {
        'error': 'INVALID_CREDENTIALS',
        'message': 'Invalid email or password',
      }),
    ]);
    await expectLater(
      client.auth.signIn('ada@example.com', 'bad'),
      throwsA(
        isA<VaifAuthException>().having(
          (e) => e.code,
          'code',
          'INVALID_CREDENTIALS',
        ),
      ),
    );
    expect(client.auth.session, isNull);
  });

  test('signUp with a session, then a pending-verification answer', () async {
    api
      ..on('POST', authPath('signup'), [
        loginResponse(token: 'at_new'),
        jsonResponse(201, {
          'ok': true,
          'pendingVerification': true,
          'message': 'Check your email',
        }),
      ])
      ..on('POST', authPath('logout'), [
        jsonResponse(200, {'ok': true}),
      ]);
    final created = await client.auth.signUp(
      'new@example.com',
      'pw',
      metadata: {'plan': 'free'},
    );
    expect(created.session!.accessToken, 'at_new');
    expect(bodyOf(api.calls('POST', authPath('signup')).first)['metadata'], {
      'plan': 'free',
    });

    await client.auth.signOut();
    final pending = await client.auth.signUp('taken@example.com', 'pw');
    expect(pending.session, isNull);
    expect(pending.pendingVerification, isTrue);
    expect(pending.message, 'Check your email');
  });

  test('refresh is single-flight and rotates the refresh token', () async {
    api
      ..on('POST', authPath('login'), [loginResponse()])
      ..on('POST', authPath('refresh'), [
        (http.Request r) async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return loginResponse(token: 'at_2', refresh: 'rt_2');
        },
        loginResponse(token: 'at_3', refresh: 'rt_3'),
      ]);
    await client.auth.signIn('ada@example.com', 'pw');

    final sessions = await Future.wait(
      List.generate(10, (_) => client.auth.refreshSession()),
    );

    final refreshes = api.calls('POST', authPath('refresh'));
    expect(refreshes, hasLength(1));
    expect(refreshes.single.headers['cookie'], 'project_refresh_token=rt_1');
    expect(sessions.map((s) => s.accessToken).toSet(), {'at_2'});
    expect(client.auth.session!.refreshToken, 'rt_2');
    expect(client.auth.session!.user!.id, 'u1');

    await client.auth.refreshSession();
    expect(
      api.calls('POST', authPath('refresh')).last.headers['cookie'],
      'project_refresh_token=rt_2',
    );
  });

  test(
    'an expiring session is refreshed once before concurrent requests',
    () async {
      api
        ..on('POST', authPath('refresh'), [loginResponse(token: 'at_fresh')])
        ..on('GET', dataPath('todos'), [
          jsonResponse(200, {'data': [], 'count': 0}),
        ]);
      await client.auth.setSession(
        'at_old',
        refreshToken: 'rt_old',
        expiresAt: DateTime.now().add(const Duration(seconds: 5)),
      );

      await Future.wait([
        client.from('todos').list(),
        client.from('todos').list(),
      ]);

      expect(api.calls('POST', authPath('refresh')), hasLength(1));
      expect(
        api
            .calls('GET', dataPath('todos'))
            .map((r) => r.headers['authorization']),
        everyElement('Bearer at_fresh'),
      );
    },
  );

  test('a 401 triggers exactly one refresh and one retry', () async {
    api
      ..on('POST', authPath('refresh'), [loginResponse(token: 'at_new')])
      ..on('GET', authPath('me'), [
        jsonResponse(401, {
          'error': 'UNAUTHORIZED',
          'message': 'Invalid or expired token',
        }),
        jsonResponse(200, {'user': user}),
      ]);
    await client.auth.setSession('at_revoked', refreshToken: 'rt_1');
    final me = await client.auth.getUser();
    expect(me.id, 'u1');
    expect(
      api.calls('GET', authPath('me')).map((r) => r.headers['authorization']),
      ['Bearer at_revoked', 'Bearer at_new'],
    );
  });

  test('a failed refresh signs the user out', () async {
    api.on('POST', authPath('refresh'), [
      jsonResponse(401, {
        'error': 'UNAUTHORIZED',
        'message': 'Invalid or expired refresh token',
      }),
    ]);
    await client.auth.setSession(
      'at',
      refreshToken: 'rt_dead',
      expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
    );
    final events = <AuthChangeEvent>[];
    client.auth.onAuthStateChange.listen((c) => events.add(c.event));
    await expectLater(
      client.from('todos').list(),
      throwsA(isA<VaifAuthException>()),
    );
    expect(client.auth.session, isNull);
    await pumpEventQueue();
    expect(events, [AuthChangeEvent.signedOut]);
  });

  test('refresh without a refresh token fails fast', () async {
    await client.auth.setSession('at_only');
    await expectLater(
      client.auth.refreshSession(),
      throwsA(
        isA<VaifAuthException>().having(
          (e) => e.code,
          'code',
          'NO_REFRESH_TOKEN',
        ),
      ),
    );
    expect(api.requests, isEmpty);
  });

  test(
    'signOut revokes and clears, even when the token already expired',
    () async {
      api.on('POST', authPath('logout'), [
        jsonResponse(200, {'ok': true}),
        jsonResponse(401, {'error': 'UNAUTHORIZED'}),
      ]);
      await client.auth.setSession('at_1', refreshToken: 'rt_1');
      await client.auth.signOut();
      expect(api.requests.last.headers['authorization'], 'Bearer at_1');
      expect(client.auth.session, isNull);

      await client.auth.setSession('at_2', refreshToken: 'rt_2');
      await client.auth.signOut(); // 401 = already expired, not an error
      expect(client.auth.session, isNull);
      await client.auth.signOut(); // no session: no request
      expect(api.calls('POST', authPath('logout')), hasLength(2));
    },
  );

  test('getUser requires a session', () async {
    await expectLater(
      client.auth.getUser(),
      throwsA(
        isA<VaifAuthException>().having((e) => e.code, 'code', 'NOT_SIGNED_IN'),
      ),
    );
  });

  test('password reset calls', () async {
    api
      ..on('POST', authPath('forgot-password'), [
        jsonResponse(200, {'ok': true}),
      ])
      ..on('POST', authPath('reset-password'), [
        jsonResponse(200, {'ok': true}),
      ]);
    await client.auth.requestPasswordReset('ada@example.com');
    await client.auth.resetPassword('tok', 'new-pw');
    expect(bodyOf(api.requests[0]), {'email': 'ada@example.com'});
    expect(bodyOf(api.requests[1]), {'token': 'tok', 'password': 'new-pw'});
  });

  test(
    'sessions round-trip through JSON and keep tokens out of toString',
    () async {
      final session = Session(
        accessToken: 'at_secret',
        expiresAt: DateTime.utc(2026, 11, 14, 12),
        refreshToken: 'rt_secret',
        user: User.fromJson(user),
      );
      final restored = Session.fromJson(
        jsonDecode(jsonEncode(session.toJson())) as Map<String, dynamic>,
      );
      expect(restored.accessToken, 'at_secret');
      expect(restored.refreshToken, 'rt_secret');
      expect(restored.expiresAt, DateTime.utc(2026, 11, 14, 12));
      expect(restored.user!.email, 'ada@example.com');
      expect(session.toString(), isNot(contains('secret')));
      expect(() => Session.fromJson({'nope': 1}), throwsFormatException);

      await client.auth.restoreSession(restored);
      expect(client.auth.session, same(restored));
    },
  );

  test(
    'the refresh cookie is found among folded Set-Cookie values and decoded',
    () async {
      api.on('POST', authPath('login'), [
        jsonResponse(
          200,
          {'accessToken': 'at', 'expiresIn': 60},
          headers: {
            'set-cookie':
                'other=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Path=/,'
                'project_refresh_token=a%2Bb%3D; Path=/projects/$project/auth; HttpOnly',
          },
        ),
      ]);
      await client.auth.signIn('ada@example.com', 'pw');
      expect(client.auth.session!.refreshToken, 'a+b=');
    },
  );
}

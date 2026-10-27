/// End-to-end run against a real VAIF API.
///
/// Skipped unless these are set (use a throwaway project):
///
///     VAIF_IT_BASE_URL    e.g. http://127.0.0.1:3893
///     VAIF_IT_PROJECT_ID  project id
///     VAIF_IT_API_KEY     project key with crud + storage + functions scopes
///     VAIF_IT_TABLE       table with a text column "name" (default: sdk_items)
@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:vaif_client/vaif_client.dart';

final env = Platform.environment;
final baseUrl = env['VAIF_IT_BASE_URL'] ?? '';
final projectId = env['VAIF_IT_PROJECT_ID'] ?? '';
final apiKey = env['VAIF_IT_API_KEY'] ?? '';
final table =
    (env['VAIF_IT_TABLE'] ?? '').isEmpty ? 'sdk_items' : env['VAIF_IT_TABLE']!;
final enabled = baseUrl.isNotEmpty && projectId.isNotEmpty && apiKey.isNotEmpty;

final _random = Random.secure();
String hex(int n) =>
    List.generate(n, (_) => _random.nextInt(16).toRadixString(16)).join();

VaifClient makeClient() => VaifClient(
  projectId: projectId,
  apiKey: apiKey,
  baseUrl: baseUrl,
  timeout: const Duration(seconds: 20),
);

void main() {
  final skip = enabled ? false : 'VAIF_IT_* environment not set';

  test(
    'auth lifecycle: sign up, sign out, sign in, refresh rotation, revoke',
    () async {
      final email = 'dart-${hex(10)}@example.com';
      final password = 'Pw-${hex(24)}';
      final vaif = makeClient();
      addTearDown(vaif.close);

      final signedUp = await vaif.auth.signUp(
        email,
        password,
        metadata: {'sdk': 'dart'},
      );
      expect(signedUp.session, isNotNull);
      expect(
        signedUp.session!.refreshToken,
        isNotNull,
        reason: 'the API returned no refresh token',
      );

      await vaif.auth.signOut();
      expect(vaif.auth.session, isNull);

      await expectLater(
        vaif.auth.signIn(email, '$password-wrong'),
        throwsA(isA<VaifAuthException>()),
      );

      final result = await vaif.auth.signIn(email, password);
      expect(result.session, isNotNull);
      final me = await vaif.auth.getUser();
      expect(me.email, email);

      final first = vaif.auth.session!;
      final refreshed = await Future.wait(
        List.generate(3, (_) => vaif.auth.refreshSession()),
      );
      expect(
        refreshed.map((s) => s.accessToken).toSet(),
        hasLength(1),
        reason: 'single flight',
      );
      expect(refreshed.first.refreshToken, isNot(first.refreshToken));
      expect((await vaif.auth.getUser()).id, me.id);

      await vaif.auth.signOut();
      // The revoked refresh token must no longer work.
      await vaif.auth.setSession(
        refreshed.first.accessToken,
        refreshToken: refreshed.first.refreshToken,
      );
      await expectLater(
        vaif.auth.refreshSession(),
        throwsA(isA<VaifAuthException>()),
      );
      expect(vaif.auth.session, isNull);
    },
    skip: skip,
  );

  test('data: CRUD, filters and pagination', () async {
    final marker = hex(8);
    final vaif = makeClient();
    addTearDown(vaif.close);
    final rows = vaif.from(table);

    final created = await rows.insert({'name': '$marker-a'});
    expect(created['name'], '$marker-a');
    final more = await rows.insertMany([
      {'name': '$marker-b'},
      {'name': '$marker-c'},
    ]);
    expect(more, hasLength(2));

    expect((await rows.get(created['id'] as Object))['id'], created['id']);

    final mine = rows.like('name', '$marker-%');
    final listed = await mine.order('name').list();
    expect(listed.data.map((r) => r['name']), [
      '$marker-a',
      '$marker-b',
      '$marker-c',
    ]);
    expect(listed.count, 3);

    final page = await mine.order('name').paginate(page: 2, pageSize: 2);
    expect(page.total, 3);
    expect(page.data.map((r) => r['name']), ['$marker-c']);
    expect(page.hasNext, isFalse);

    final onlyB =
        await mine.eq('name', '$marker-b').select(['id', 'name']).list();
    expect(onlyB.count, 1);
    expect(onlyB.data.single.keys.toSet(), {'id', 'name'});

    final updated = await rows.update(created['id'] as Object, {
      'name': '$marker-z',
    });
    expect(updated['name'], '$marker-z');

    for (final row in [created, ...more]) {
      await rows.delete(row['id'] as Object);
    }
    await expectLater(
      rows.get(created['id'] as Object),
      throwsA(isA<VaifNotFoundException>()),
    );
    await expectLater(
      rows.eq('no_such_column', 1).list(),
      throwsA(
        isA<VaifValidationException>().having(
          (e) => e.code,
          'code',
          'INVALID_COLUMN',
        ),
      ),
    );
  }, skip: skip);

  test('storage: upload, download, signed URL, missing object', () async {
    final key = 'sdk-it/dart-${hex(16)}.txt';
    final payload = utf8.encode('hello from the dart sdk');
    final vaif = makeClient();
    addTearDown(vaif.close);

    final uploaded = await vaif.storage.upload(
      key,
      payload,
      contentType: 'text/plain',
    );
    expect(uploaded.size, payload.length);
    expect(await vaif.storage.download(key), payload);
    final url = await vaif.storage.createSignedUrl(key);
    expect(url, startsWith('http'));
    await expectLater(
      vaif.storage.download('sdk-it/missing-${hex(16)}.txt'),
      throwsA(isA<VaifNotFoundException>()),
    );
  }, skip: skip);

  test('functions: an unknown function is VaifNotFoundException', () async {
    final vaif = makeClient();
    addTearDown(vaif.close);
    await expectLater(
      vaif.functions.invoke('missing-${hex(8)}', body: {'x': 1}),
      throwsA(isA<VaifNotFoundException>()),
    );
  }, skip: skip);
}

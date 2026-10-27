import 'package:test/test.dart';
import 'package:vaif_client/vaif_client.dart';

import 'support.dart';

void main() {
  test('every client a VaifClient exposes can be named by its type', () {
    final client = makeClient(FakeApi());
    addTearDown(client.close);
    // Each declaration fails to compile if its type is not exported.
    final AuthClient auth = client.auth;
    final MfaClient mfa = client.auth.mfa;
    final AuthSessionsClient sessions = client.auth.sessions;
    final StorageClient storage = client.storage;
    final FunctionsClient functions = client.functions;
    final RealtimeClient realtime = client.realtime;
    final Operations operations = client.operations;
    final QueryBuilder query = client.from('todos');
    expect([
      auth,
      mfa,
      sessions,
      storage,
      functions,
      realtime,
      operations,
      query,
    ], everyElement(isNotNull));
  });
}

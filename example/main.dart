// A tour of vaif_client: auth, queries, realtime, storage and functions. The
// package has no Flutter or dart:io dependency, so this code runs on the Dart
// VM, in Flutter apps and in the browser.
//
// Pass your project ID and a publishable key (vk_pub_...) as compile-time
// values; the defaults below are placeholders, not credentials:
//
//   dart run -DVAIF_PROJECT_ID=<project id> -DVAIF_API_KEY=<vk_pub_ key> example/main.dart
//
// In a Flutter app, pass the same names with --dart-define.
import 'package:vaif_client/vaif_client.dart';

Future<void> main() async {
  final vaif = VaifClient(
    projectId: const String.fromEnvironment(
      'VAIF_PROJECT_ID',
      defaultValue: 'YOUR_PROJECT_ID',
    ),
    apiKey: const String.fromEnvironment(
      'VAIF_API_KEY',
      defaultValue: 'vk_pub_YOUR_KEY',
    ),
  );

  // Log auth state changes. To keep users signed in across restarts, give
  // the client a SessionStorage (see Persisting sessions in the README).
  final authEvents = vaif.auth.onAuthStateChange.listen((change) {
    print('auth: ${change.event.name}');
  });

  try {
    final signIn = await vaif.auth.signIn('ada@example.com', 'a password');
    if (signIn.mfaRequired) {
      await vaif.auth.verifyMfa(signIn.challengeToken!, '123456');
    }

    final todos = vaif.from('todos');
    final open =
        await todos.eq('done', false).order('created_at').range(0, 19).list();
    print('${open.count} open: ${open.data}');
    final created = await todos.insert({'title': 'Buy milk', 'done': false});
    await todos.update(created['id'] as Object, {'done': true});
    print('done: ${await todos.eq('done', true).count()}');

    // Live changes to the rows this chain selects.
    final sub = await todos.eq('done', false).subscribe();
    final changes = sub.changes.listen(
      (change) => print('change: ${change['op']}'),
    );

    await vaif.storage.upload(
      'notes/hello.txt',
      'hello'.codeUnits,
      contentType: 'text/plain',
    );
    print(
      await vaif.storage.createSignedUrl('notes/hello.txt', expiresIn: 300),
    );

    final reply = await vaif.functions.invoke(
      'hello_world',
      body: {'name': 'Ada'},
    );
    print('function: ${reply.status} ${reply.data}');

    await changes.cancel();
    await sub.unsubscribe();
    await vaif.auth.signOut();
  } on VaifException catch (error) {
    print('VAIF error: ${error.code ?? error.status} ${error.message}');
  } finally {
    await authEvents.cancel();
    vaif.close();
  }
}

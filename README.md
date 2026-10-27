# VAIF Studio SDK for Dart and Flutter

<!-- BEGIN GENERATED SDK STATUS: notice:dart -->
> `vaif_client` 1.0.0 is the version in this repository. The hosted API (`https://api.vaif.studio`) and console are not available yet.
<!-- END GENERATED SDK STATUS: notice:dart -->

`vaif_client` is the official Dart and Flutter client library for the
[VAIF Studio](https://vaif.studio) API: app-user authentication, database
queries, realtime changes, file storage, functions, and a generated method for
each API operation that has a typed response.

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Authentication and configuration](#authentication-and-configuration)
- [Auth](#auth)
- [Database queries](#database-queries)
- [Realtime](#realtime)
- [Storage](#storage)
- [Functions](#functions)
- [Generated API operations](#generated-api-operations)
- [Error handling](#error-handling)
- [Versioning](#versioning)
- [Support and security](#support-and-security)
- [License](#license)

## Requirements

- Dart 3.7 or later, or Flutter 3.29 or later.
- Platforms: Android, iOS, macOS, Windows, Linux, the web (JavaScript and
  WebAssembly) and server-side Dart. The package is pure Dart: it has no
  Flutter dependency and does not import `dart:io`, so one package serves
  every platform.
- Runtime dependencies: `http`, `http_parser`, `crypto` (PKCE) and
  `web_socket_channel` (realtime).

## Installation

`vaif_client` is not on pub.dev yet. Until it is, depend on this repository
with a Git dependency in your `pubspec.yaml`:

```yaml
dependencies:
  vaif_client:
    git:
      url: https://github.com/vaifstudio/vaif-dart.git
```

Then run `dart pub get`, or `flutter pub get` in a Flutter app. Pub records the
resolved commit in `pubspec.lock`; to pin a specific commit, add `ref:` with its
SHA under `git:`. Flutter apps use the same package; there is no separate
Flutter build.

## Quick start

```dart
import 'package:vaif_client/vaif_client.dart';

Future<void> main() async {
  final vaif = VaifClient(
    projectId: 'YOUR_PROJECT_ID',
    apiKey: 'vk_pub_YOUR_PUBLISHABLE_KEY',
  );

  try {
    final signIn = await vaif.auth.signIn('ada@example.com', 'her password');
    if (signIn.mfaRequired) {
      await vaif.auth.verifyMfa(signIn.challengeToken!, '123456');
    }

    final open = await vaif
        .from('todos')
        .eq('done', false)
        .order('created_at', descending: true)
        .limit(20)
        .list();
    print('${open.count} open todos: ${open.data}');

    await vaif.from('todos').insert({'title': 'Buy milk', 'done': false});
  } on VaifException catch (error) {
    print('${error.code ?? error.status}: ${error.message}');
  } finally {
    vaif.close();
  }
}
```

A longer example covering realtime, storage and functions is in
[`example/main.dart`](example/main.dart).

## Authentication and configuration

A client is created for one project with that project's API key. The key is
sent with every request in the `x-vaif-key` header; the signed-in user's access
token is sent as `Authorization: Bearer`.

- Use a publishable key (`vk_pub_...`) in apps. The project's row rules apply
  to its requests.
- A secret key (`vk_srv_...`) bypasses row rules. Use it only on servers you
  control, and never ship it in an app.

The project's keys are listed on its **Security > API Keys** page in the VAIF
Studio console.

```dart
final vaif = VaifClient(
  projectId: 'YOUR_PROJECT_ID',
  apiKey: 'vk_pub_YOUR_PUBLISHABLE_KEY',
  baseUrl: 'https://api.vaif.studio', // the default
  timeout: const Duration(seconds: 15), // per attempt; the default is 30 seconds
  retry: const RetryPolicy(maxRetries: 3), // or RetryPolicy.none
  headers: {'x-app-version': '1.4.2'}, // every API request; native and server only
  httpClient: myHttpClient, // optional; you close it
  session: savedSession, // optional; restores a persisted session
);
```

| Option | Default | Notes |
| --- | --- | --- |
| `projectId` | none | Your project's ID. Omit it only for a platform client (see below). |
| `apiKey` | required | Must not be empty. |
| `baseUrl` | `https://api.vaif.studio` | Must use `https`; `http` is accepted only for `localhost`, `127.0.0.1` and `::1`. |
| `timeout` | 30 seconds | Bounds each attempt, including reading the response body. A timed-out request is aborted when the HTTP client supports it. |
| `retry` | `RetryPolicy()` | See below. |
| `headers` | none | Added to every API request. In a browser, a header that the API's CORS policy does not allow, such as `x-app-version`, fails the preflight and with it every request, so set custom headers only on native platforms and servers. |
| `session` | none | A session to start with, for example one saved with `Session.toJson`. Cannot be combined with `sessionStorage`. |
| `sessionStorage` | none | Saves the session between launches; see [Persisting sessions](#persisting-sessions). |
| `httpClient` | an SDK-owned `http.Client` | Pass your own to control proxies or certificates; you close it. |

**Retries.** `GET`, `HEAD` and `OPTIONS` requests are retried on HTTP 429,
500, 502, 503 and 504, on timeouts and on network errors: up to 3 retries,
starting at 1 second and doubling to at most 30 seconds, plus up to 25% jitter.
A `Retry-After` header from the API takes precedence, capped at the same
maximum. Requests that change data are not replayed; `functions.invoke` accepts
`idempotent: true` when a replay is harmless.

Call `close()` when you are done with a client. It closes the realtime
connection, the auth state stream and the HTTP client the SDK created.

### Project clients and platform clients

With a `projectId`, `auth` signs in the users of your own app
(`/projects/:projectId/auth`). A client without `projectId` is a platform
client for VAIF Studio accounts. VAIF Studio accounts are created and their
passwords reset only in the console, so on a platform client `auth.signUp()`,
`auth.requestPasswordReset()`, and the generated `postAuthSignup()` and
`postAuthForgotPassword()` throw `VaifConsoleOnlyError` (code `CONSOLE_ONLY`)
before sending a request. Its `consoleUrl` is the console page to use instead.

A platform client refreshes its session, and ends it on the server once the
access token has expired, with the API's refresh cookie, which the SDK cannot
send from a browser. Use platform clients on native platforms and servers
only; in a browser, use a project client.

## Auth

```dart
final created = await vaif.auth.signUp('ada@example.com', 'her password',
    metadata: {'plan': 'free'});
if (created.pendingVerification) print(created.message);

final user = await vaif.auth.getUser();
await vaif.auth.requestPasswordReset('ada@example.com');
await vaif.auth.resetPassword(tokenFromEmail, 'her new password');
await vaif.auth.sendEmailVerification();
await vaif.auth.confirmEmailVerification(tokenFromEmail);
await vaif.auth.signOut(); // revokes the session on the server and clears it locally
```

Before each request, an access token that expires within 30 seconds is
refreshed first. When the API rejects a request's access token with a 401
response, the session is refreshed and the request is sent once more, but only
if the same user is still signed in: a request is never sent again with another
user's token. Concurrent refreshes of one session share one request, and the API
rotates the refresh token on every use. App-user auth receives the refresh token
in the response body, so refresh works on every platform, the web included.

`signOut()` clears the session locally first, so a refresh in flight cannot
restore it, and then asks the server to end it. The request carries the refresh
token as well as the access token, so it works after the access token has
expired; the server signs the user out of every session. A 401 from that request
is not reported as an error. A refresh that finishes after `signOut()` throws
`VaifAuthException` with code `SESSION_CHANGED` and ends the session the server
issued to it.

### Persisting sessions

By default the session is kept in memory, and the user signs in again after
the app restarts. To keep users signed in, give the client a `SessionStorage`.
The client then saves the session at every sign-in and token refresh, deletes
it at sign-out, and `auth.loadSession()` restores it at start-up. The saved
session contains the refresh token, so implement `SessionStorage` over the
platform's secure storage, for example with
[`flutter_secure_storage`](https://pub.dev/packages/flutter_secure_storage):

```dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:vaif_client/vaif_client.dart';

class SecureSessionStorage implements SessionStorage {
  const SecureSessionStorage(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

Future<VaifClient> createClient() async {
  final vaif = VaifClient(
    projectId: 'YOUR_PROJECT_ID',
    apiKey: 'vk_pub_YOUR_PUBLISHABLE_KEY',
    sessionStorage: const SecureSessionStorage(FlutterSecureStorage()),
  );
  await vaif.auth.loadSession(); // null when no session is saved
  return vaif;
}
```

The client saves the session under `auth.sessionStorageKey`, which names the
API base URL and the project, so clients for different projects, or for one
project at different base URLs such as staging and production, never restore
each other's session. Clients for the same project and base URL share the
saved session, so a server that acts for several users should not use session
storage.

Storage calls, including the read in `loadSession()`, run one at a time in the
order they are made, and a sign-in or sign-out made while `loadSession()` reads
the storage wins over the saved value. When a new session cannot be saved, it
stays signed in for this run of the app and the saved session is deleted, so
the next launch does not restore an older one; `auth.sessionStorageError`
records the failure. Sign-in calls, `setSession` and `restoreSession` throw
`VaifSessionStorageException` only when the older session could not be deleted
either. `signOut()` throws `VaifSessionStorageException` when the saved session
could not be deleted, after it has ended the session on the server; calling it
again retries the delete. A token refresh never fails because of the storage.

To keep the session somewhere else, listen to `onAuthStateChange`, save
`change.session?.toJson()`, and pass the session back with
`auth.restoreSession(Session.fromJson(...))` or the constructor's `session:`.

### Multi-factor authentication

```dart
final result = await vaif.auth.signIn('ada@example.com', 'her password');
if (result.mfaRequired) {
  await vaif.auth.verifyMfa(result.challengeToken!, codeFromUser);
}

final enrollment = await vaif.auth.mfa.enrollStart(); // enrollToken, otpauthUri, secret
await vaif.auth.mfa.enrollConfirm(enrollment['enrollToken'] as String, code);
await vaif.auth.mfa.regenerateCodes(code); // new backup codes
await vaif.auth.mfa.disable(code);
```

### Google and GitHub sign-in

OAuth sign-in uses PKCE (S256). Open the returned URL with your platform's
launcher, then pass the callback's `code` and `state` back:

```dart
final start = await vaif.auth.getOAuthSignInUrl(
    provider: 'google', redirectUrl: 'myapp://auth-callback');
await launchUrl(Uri.parse(start.url)); // for example with package:url_launcher

// When the app receives myapp://auth-callback?code=...&state=...
final signedIn = await vaif.auth.handleOAuthCallback(code: code, state: state);
```

The client keeps the PKCE verifier for each `state` and uses it once. Without
`codeVerifier:`, a callback whose `state` is unknown or already used throws
`VaifException` with code `OAUTH_STATE_MISMATCH`. If your app can be stopped
while the browser is open, save `start.state` and `start.codeVerifier` in secure
storage, check the callback's `state` against the saved one, and pass
`codeVerifier:` to `handleOAuthCallback`.
`listOAuthProviders()` returns the providers enabled for the project.

### Magic links and device sessions

```dart
await vaif.auth.sendMagicLink('ada@example.com', redirectUrl: 'myapp://magic');

final devices = await vaif.auth.sessions.list();
await vaif.auth.sessions.revoke(devices.first['id'] as String);
final revoked = await vaif.auth.sessions.revokeAll(); // every other session
```

The link opens `redirectUrl` with `access_token`, `expires_in` (seconds) and
`refresh_token` in the URL fragment. Pass them to `setSession`:

```dart
// link is the URL the app was opened with, such as myapp://magic#access_token=...
final params = Uri.splitQueryString(link.fragment);
await vaif.auth.setSession(
  params['access_token']!,
  refreshToken: params['refresh_token'],
  expiresAt: DateTime.now()
      .add(Duration(seconds: int.parse(params['expires_in']!))),
);
```

## Database queries

`vaif.from(table)` starts an immutable query builder, so a base query can be
reused:

```dart
final todos = vaif.from('todos');

final rows = await todos
    .select(['id', 'title'])
    .eq('owner', user.id)
    .gte('priority', 2)
    .inList('status', ['open', 'blocked'])
    .order('priority', descending: true)
    .range(0, 49)
    .list();
print('${rows.data.length} of ${rows.count}');

final page = await todos.eq('done', false).paginate(page: 2, pageSize: 20);
print('${page.total} total, next page: ${page.hasNext}');

final row = await todos.get('row-id'); // throws VaifNotFoundException if missing
final first = await todos.ilike('title', '%milk%').first(); // null if none

final inserted = await todos.insert({'title': 'Buy milk'});
final many = await todos.insertMany([{'title': 'Eggs'}, {'title': 'Bread'}]);
final saved = await vaif
    .from('contacts')
    .upsert({'email': 'ada@example.com', 'name': 'Ada'}, onConflict: ['email']);
final updated = await todos.update('row-id', {'done': true});
await todos.delete('row-id');
```

Filters are `eq`, `neq`, `gt`, `gte`, `lt`, `lte`, `like`, `ilike` and `inList`
(`in` is a Dart keyword). Filters on one builder are combined with AND; for OR,
pass a raw clause such as
`todos.where({'OR': [{'field': 'a', 'value': 1}, {'field': 'b', 'value': 2}]})`.
`DateTime` values are sent as ISO 8601 in UTC. `limit` accepts 1 to 1000, and
`range(from, to)` is inclusive.

Counts, aggregates and bulk writes use the API's aggregate and bulk routes:

```dart
final todos = vaif.from('todos');
final open = await todos.eq('done', false).count();
final total = await vaif.from('orders').eq('status', 'paid').sum('amount'); // also avg, min, max
final changed = await todos.eq('list', 'groceries').updateMany({'done': true});
final removed = await todos.eq('done', true).deleteMany();
```

Those routes match on equality only, so `count`, `sum`, `avg`, `min`, `max`,
`updateMany` and `deleteMany` accept only `eq` filters combined with AND and
throw `ArgumentError` before sending anything else. `updateMany` and
`deleteMany` also refuse to run without a filter.

## Realtime

```dart
final subscription = await vaif.from('todos').eq('list', 'groceries').subscribe();
final listener = subscription.changes.listen((change) {
  print('${change['op']} ${change['record']}'); // INSERT, UPDATE or DELETE
});

// Later:
await listener.cancel();
await subscription.unsubscribe();
```

`subscribe()` sends the builder's filters to the server as row filters (`eq`,
`neq`, `gt`, `gte`, `lt`, `lte` and `inList` on string, number or boolean
values) and `select()` as the columns to send. Any other filter throws
`ArgumentError` rather than streaming rows that `list()` would not return.
`vaif.realtime.subscribe('todos', filters: [...], columns: [...])` does the same
without a query builder.

The connection uses `wss`, or `ws` only for a local `http` base URL. It
authenticates with its first message, so credentials never appear in the URL;
`subscribe()` completes when the server acknowledges the subscription. The
connection follows token refreshes, including one that lands while it is
opening, and closes on sign-out. Frames that are not JSON text are ignored. It
does not reconnect automatically: when it drops, `changes` reports a
`VaifException` and closes, and you subscribe again to resume.

## Storage

```dart
await vaif.storage.upload('avatars/u1.png', pngBytes, contentType: 'image/png');
final Uint8List data = await vaif.storage.download('avatars/u1.png');
final downloadUrl =
    await vaif.storage.createSignedUrl('avatars/u1.png', expiresIn: 300);
final uploadUrl = await vaif.storage.createSignedUploadUrl('backups/db.zip',
    sizeBytes: size, contentType: 'application/zip');

final listing =
    await vaif.storage.list(bucket: 'avatars', prefix: 'u1/', limit: 100);
await vaif.storage.delete('avatars/u1.png', bucket: 'avatars');
```

`upload` asks the API for a presigned URL and then sends the bytes directly to
the object store with an HTTP `PUT`. `download` asks the API for a signed link,
as `createSignedUrl` does, and reads the bytes from it. The API key and session
token are never sent to a signed URL, and API requests never follow redirects,
so a redirect cannot carry them to another host either. A signed URL must use
https (http only on a loopback host): `createSignedUrl`,
`createSignedUploadUrl`, `upload` and `download` throw `INSECURE_STORAGE_URL`
for one that does not, before any request is made to it, and on native
platforms a read follows the object store's redirects only to such URLs (in a
browser, the browser follows them). The `PUT` and the read are retried on
transient errors; the request for an upload URL, which is metered, is not.
When a request to a signed URL fails at the network level, the
`VaifNetworkException` and its `cause` show the URL without its query string,
which holds the signature.

A signed upload URL is valid only for the given `sizeBytes` (1 byte to 5 GiB)
and, when given, `contentType`, so the `PUT` must send exactly those. `bucket:`
is optional for upload, download and signed URLs; without it the project's
default bucket is used. `list` and `delete` take a bucket name or ID and use
the storage management routes, which accept only a VAIF Studio account's
access token with a role in the project, not an app user's session or a
project key alone.

## Functions

```dart
final response = await vaif.functions.invoke('send-email',
    body: {'to': 'ada@example.com'});
print('${response.status} ${response.data}'); // JSON is decoded, text stays a String, other bytes are a Uint8List

final report = await vaif.functions.invoke('report',
    method: 'GET', path: '/daily', query: {'day': 'mon'});
```

A non-2xx response from the function throws the matching `VaifException`
subclass with the function's response in `body` and its headers in `headers`.
Invocations are not retried unless you pass `idempotent: true`.

The API sets an `x-vaif-run-id` header (`functionRunHeader`) on every response
a function produced. A 401 that carries it is the function's own answer: it is
thrown as a `VaifAuthException`, and the client neither refreshes the session
nor invokes the function again. A 401 without it means the API refused the
access token before the function ran; the client refreshes the session and
invokes the function once more.

## Generated API operations

`vaif.operations` has one method for each operation in the VAIF Studio API
contract that has a typed success response, except the staff-only operations:
775 in this version. The methods are generated from the API's
OpenAPI contract and are named after the HTTP method and path:

```dart
final keys = await vaif.operations.getProjectsByProjectIdApiKeys(
    path: {'projectId': 'YOUR_PROJECT_ID'});
```

Path values are URL-encoded, and required path parameters, query parameters
and bodies are checked before the request is sent. The session, retries and
errors work as for the rest of the client. JSON results are decoded to maps and
lists, and the streaming chat route returns the live `http.StreamedResponse`;
a failure while its body streams arrives on that stream as a
`VaifNetworkException`.
`getStorageDownload()` follows the API's redirect to the object's signed link,
without the client's credentials, and returns the bytes. A browser does not
expose that redirect to the page, so on the web the call fails with
`VaifNetworkException`; use `storage.download()`, which works on every
platform.

The `operations` table lists what is generated (775 methods).
`ungeneratedOperations` lists the other 168 operations with the reason: those
without a typed success response, and the 134 staff-only operations, listed
as `platform staff only`. The API answers the staff-only operations only for
VAIF platform staff: every operation under `/admin/*` and
`/auth/impersonate/*`, and those outside them: feature flags (`/flags`),
enterprise contract and invoice writes, Verament usage statistics
(`GET /ai/copilot/stats`) and documentation edits under `/docs`.

## Error handling

Failures reported by the API, the object store, the realtime server or the
network are thrown as `VaifException` or one of its subclasses:

| Type | Raised for |
| --- | --- |
| `VaifValidationException` | HTTP 400 and 422; `INVALID_REALTIME_URL` |
| `VaifAuthException` | HTTP 401 and 403; `NOT_SIGNED_IN`, `NO_REFRESH_TOKEN`, `SESSION_CHANGED` |
| `VaifNotFoundException` | HTTP 404; `BUCKET_NOT_FOUND` |
| `VaifConflictException` | HTTP 409 |
| `VaifRateLimitException` | HTTP 429, with `retryAfter` when the API sent `Retry-After` |
| `VaifServerException` | HTTP 5xx |
| `VaifNetworkException` | the request could not be completed |
| `VaifTimeoutException` | a request attempt or a realtime subscription exceeded its timeout (a `VaifNetworkException`) |
| `VaifConsoleOnlyError` | `CONSOLE_ONLY`: platform sign-up or password reset |
| `VaifSessionStorageException` | `SESSION_STORAGE_FAILED`: the `SessionStorage` failed to read, save or delete the session (see [Persisting sessions](#persisting-sessions)) |
| `VaifException` | any other status; `PROJECT_ID_REQUIRED`, `OAUTH_STATE_MISMATCH`, `CLOSED` (realtime connection closed), `STORAGE_UPLOAD_FAILED` (the object store refused an upload), `INSECURE_STORAGE_URL` (a signed storage URL from the API, or an object store's redirect, does not use https), and errors sent by the realtime server |

Each exception carries `message`, and when known `status`, `code` (the API's
machine-readable code, such as `INVALID_CREDENTIALS` or `INVALID_COLUMN`, or
one of the SDK's codes above), `details`, `requestId`, the decoded `body` and
the response `headers`.
Include `requestId` when you contact support about a failed request.

```dart
try {
  await vaif.from('todos').eq('priority', 1).list();
} on VaifRateLimitException catch (error) {
  print('Rate limited; retry after ${error.retryAfter}');
} on VaifAuthException catch (error) {
  print('Sign in again (${error.code})');
} on VaifException catch (error) {
  print('${error.status} ${error.code} ${error.message} ${error.requestId}');
}
```

Programming errors throw Dart's standard errors before any request is sent:
`ArgumentError` or `RangeError` for invalid arguments, such as a column name
that is not an identifier, `limit(0)`, an empty storage key, or a row ID,
session ID or function name that is `.` or `..`, and
`StateError` when the same realtime channel is subscribed to twice or
`auth.loadSession()` is called on a client without session storage.

## Versioning

`vaif_client` follows [Semantic Versioning 2.0.0](https://semver.org). The
public API is everything exported from `package:vaif_client/vaif_client.dart`.

A major release is required for a breaking change:

- removing or renaming an exported class, method, property or parameter,
  including a method on `vaif.operations`;
- changing a signature so that code that compiled before no longer compiles;
- changing documented behavior that callers depend on, such as the exception
  type or `code` thrown for a given failure, or the default retry and timeout
  behavior.

Minor releases add features in a backward-compatible way, such as new methods,
optional parameters, `operations` methods for new API operations, or error
codes. Patch releases contain backward-compatible fixes. A raised minimum Dart
SDK version ships in a minor release; pub keeps resolving the previous release
on older SDKs. Changes are listed in [CHANGELOG.md](CHANGELOG.md).

## Support and security

- Bugs and feature requests: open an issue in this repository. See
  [CONTRIBUTING.md](CONTRIBUTING.md).
- Questions about your VAIF Studio account or project: support@vaif.studio.
- Security vulnerabilities: do not open a public issue. Email
  security@vaif.studio as described in [SECURITY.md](SECURITY.md).

## License

`vaif_client` is released under the MIT License. See [LICENSE](LICENSE).

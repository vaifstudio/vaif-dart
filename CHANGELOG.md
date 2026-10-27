# Changelog

All notable changes to `vaif_client` are listed here. The package follows
[Semantic Versioning](https://semver.org).

## 1.0.0 (unreleased)

First release. No earlier version of `vaif_client` was published.

Requires Dart 3.7 or later (Flutter 3.29 or later). Runtime dependencies:
`crypto` 3.0.8, `http` 1.6.0, `http_parser` 4.1.2 and `web_socket_channel`
3.0.3 or later within their major versions.

### Client

- `VaifClient` for a project, sending the project key as `x-vaif-key`. The
  base URL must use https, except for `localhost`, `127.0.0.1` and `::1`.
- Per-attempt timeouts that cover the response body and abort the request, a
  configurable `RetryPolicy` (bounded exponential backoff with jitter that
  honors `Retry-After`; only `GET`, `HEAD` and `OPTIONS` are retried unless a
  call opts in), custom headers and an injectable `http.Client`.
- A typed `VaifException` hierarchy: validation, auth, not found, conflict,
  rate limit (with `retryAfter`), server, network and timeout. Exceptions
  carry the API's `code`, `details` and `requestId` when the API sends them,
  and the response `headers`.
- Pure Dart: no Flutter dependency and no `dart:io` import. The package
  compiles for the web (JavaScript and WebAssembly), and exports no name that
  Flutter's widgets library also exports, so both can be imported in one file.

### Auth

- App-user auth on `/projects/:projectId/auth`: `signUp`, `signIn` (with MFA
  challenges), `verifyMfa`, `refreshSession`, `signOut`, `getUser`,
  `requestPasswordReset`, `resetPassword`, `sendEmailVerification`,
  `confirmEmailVerification`, `sendMagicLink`, `setSession`,
  `restoreSession` and `onAuthStateChange`.
- Tokens refresh before they expire and once after a 401, and a request is
  sent again only for the user who sent it. Concurrent refreshes of one
  session share one request, the refresh token rotates on every use, and the
  refresh token is read from the response body so refresh works on the web. A
  sign-out during a refresh is never undone by it (`SESSION_CHANGED`), and the
  session that refresh received is ended on the server.
- `signOut` sends the refresh token with the access token, so the server ends
  the session after the access token has expired.
- `SessionStorage`: give the client one (for example over the platform's
  secure storage) and it saves every sign-in and refresh, deletes the saved
  session at sign-out, and restores it with `auth.loadSession()`. The key
  names the API base URL and the project. A session that cannot be saved
  deletes the saved one; when that delete also fails, the sign-in throws
  `VaifSessionStorageException`. `signOut` throws
  `VaifSessionStorageException` when the saved session could not be deleted.
  Storage calls run one at a time, and a sign-in or sign-out made while
  `loadSession` reads the storage wins over the saved value.
- `Session.toJson` and `Session.fromJson` for keeping a session elsewhere.
- `auth.mfa`: `enrollStart`, `enrollConfirm`, `verify`, `disable` and
  `regenerateCodes`.
- Google and GitHub sign-in with PKCE (S256): `getOAuthSignInUrl`,
  `handleOAuthCallback` (single-use state, `OAUTH_STATE_MISMATCH`) and
  `listOAuthProviders`.
- `auth.sessions`: `list`, `revoke` and `revokeAll`.
- A client without `projectId` refuses platform sign-up and password reset,
  including the generated `postAuthSignup()` and `postAuthForgotPassword()`,
  with `VaifConsoleOnlyError` (code `CONSOLE_ONLY`) before any request; VAIF
  Studio accounts are created and reset in the console.

### Database

- Immutable `QueryBuilder` on `/v1/data/:projectId/:table`: `eq`, `neq`, `gt`,
  `gte`, `lt`, `lte`, `like`, `ilike`, `inList`, raw `where`, `select`,
  `order`, `limit`, `offset`, `range`, `list`, `first`, `paginate`, `get`,
  `insert`, `insertMany`, `upsert`, `update` and `delete`. Rows are
  `Map<String, dynamic>`; `list` returns a `ListResult` and `paginate` a
  `PageResult`.
- Aggregates and bulk writes on the equality-only routes: `count`, `sum`,
  `avg`, `min`, `max`, `updateMany` and `deleteMany`. An unsupported filter,
  or a bulk write without a filter, throws before the request.
- Row IDs, session IDs, function names and the project ID are sent as one
  encoded path segment; `.` and `..` throw `ArgumentError`.

### Realtime

- `vaif.realtime.subscribe(table, filters:, columns:)` and
  `QueryBuilder.subscribe()` over `/realtime/ws`. The socket uses `wss`, or
  `ws` only for a loopback base URL; any other base URL throws
  `INVALID_REALTIME_URL` before a token is read or a socket is opened.
- Credentials are sent in the first message, never in the URL. `subscribe`
  waits for the server's acknowledgment, the socket re-authenticates after a
  token refresh (also one that lands during the handshake) and closes on
  sign-out. Binary and other non-JSON frames are ignored. Failures surface as
  `VaifException`s. There is no automatic reconnection.

### Storage

- `upload` (presigned `PUT` directly to the object store), `download` (reads
  a signed link the API issues), `createSignedUrl`,
  `createSignedUploadUrl` (signed for an exact size and, optionally, content
  type), `list` and `delete` (bucket by name or ID).
- Signed storage URLs receive no API key or session token, and must use https
  except on loopback hosts (`INSECURE_STORAGE_URL`), including the URLs
  `createSignedUrl` and `createSignedUploadUrl` return and the targets of an
  object store's redirects. API requests never follow redirects.
- A network error on a signed storage URL is a `VaifNetworkException` whose
  `cause` shows the URL without its query string, which holds the signature.

### Functions

- `functions.invoke` with method, path, query and headers, returning the
  decoded response. A 401 the function returned (`x-vaif-run-id` is set) is
  thrown as it is; only the API's own 401 refreshes the session and invokes
  once more.

### Generated operations

- `vaif.operations`: one method for each API operation with a typed success
  response, except the operations VAIF's own staff tools use (801 methods),
  generated from the API's OpenAPI contract. The 142 other
  operations, including the 108 that VAIF's own staff tools use (`/admin/*`
  and `/auth/impersonate/*`, listed as `platform staff only`), are in
  `ungeneratedOperations` with the reason. Path values are
  URL-encoded, required parameters and bodies are checked before sending,
  `getStorageDownload()` follows the API's redirect to the signed link (not
  on the web) and returns bytes, and the streaming chat route returns the live
  response, whose body stream reports failures as `VaifNetworkException`.

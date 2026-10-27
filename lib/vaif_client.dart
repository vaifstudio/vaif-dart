/// Official Dart and Flutter SDK for VAIF Studio.
///
/// App-user auth, table queries, realtime changes, file storage, functions
/// and a generated method for each API operation that has a typed response,
/// with per-attempt timeouts, bounded retries and typed exceptions.
///
/// ```dart
/// import 'package:vaif_client/vaif_client.dart';
///
/// final vaif = VaifClient(projectId: 'proj_123', apiKey: 'vk_pub_...');
/// await vaif.auth.signIn('ada@example.com', 'password');
/// final open = await vaif.from('todos').eq('done', false).list();
/// vaif.close();
/// ```
library;

export 'src/client.dart'
    show
        AuthChangeEvent,
        AuthClient,
        AuthSessionsClient,
        AuthStateChange,
        MfaClient,
        OAuthSignInResult,
        StorageListResult,
        FunctionsClient,
        QueryBuilder,
        StorageClient,
        VaifClient,
        defaultBaseUrl,
        defaultTimeout,
        functionRunHeader,
        maxLimit,
        maxUploadBytes,
        refreshCookieName;
export 'src/exceptions.dart';
export 'src/models.dart';
export 'src/retry.dart'
    show RetryPolicy, defaultRetryStatuses, replaySafeMethods;
export 'src/session_storage.dart';
export 'src/version.dart' show packageVersion;

export 'src/generated/operations.dart';
export 'src/operation.dart';
export 'src/realtime.dart';

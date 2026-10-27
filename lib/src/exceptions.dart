/// Typed exceptions thrown by the SDK.
///
/// Every failure surfaces as a [VaifException] subclass, so callers can catch
/// the base class or branch on the specific type. [VaifException.code]
/// carries the server's machine-readable error code (`INVALID_CREDENTIALS`,
/// `INVALID_COLUMN`, `NOT_FOUND`, ...) when the API sends one.
library;

/// Base class for every exception thrown by the SDK.
class VaifException implements Exception {
  /// Creates an exception with [message] and whatever else is known.
  VaifException(
    this.message, {
    this.status,
    this.code,
    this.details,
    this.requestId,
    this.body,
    this.headers,
    this.cause,
  });

  /// Human-readable description (the API's `message` when it sent one).
  final String message;

  /// HTTP status, when the failure came from an HTTP response.
  final int? status;

  /// Machine-readable error code from the API, when present.
  final String? code;

  /// Structured details from the API (for example validation issues).
  final Object? details;

  /// The API's request id (`requestId` in the body or `x-request-id`).
  final String? requestId;

  /// The decoded response body, for debugging.
  final Object? body;

  /// The response headers, with lowercase names, when the failure came from
  /// an HTTP response. A function's own response carries `x-vaif-run-id`.
  final Map<String, String>? headers;

  /// The underlying exception for network-level failures.
  final Object? cause;

  /// The exception's type name. Not `runtimeType`, which is minified on web.
  String get name => 'VaifException';

  @override
  String toString() {
    final parts = <String>[
      if (status != null) 'status: $status',
      if (code != null) 'code: $code',
      'message: $message',
      if (requestId != null) 'requestId: $requestId',
    ];
    return '$name(${parts.join(', ')})';
  }
}

/// The request was rejected as invalid (HTTP 400 / 422).
class VaifValidationException extends VaifException {
  /// Creates the exception for a 400 or 422 response.
  VaifValidationException(
    super.message, {
    super.status,
    super.code,
    super.details,
    super.requestId,
    super.body,
    super.headers,
  });

  @override
  String get name => 'VaifValidationException';
}

/// Authentication or authorization failed (HTTP 401 / 403), or no session.
class VaifAuthException extends VaifException {
  /// Creates the exception for a 401 or 403 response or a missing session.
  VaifAuthException(
    super.message, {
    super.status,
    super.code,
    super.details,
    super.requestId,
    super.body,
    super.headers,
  });

  @override
  String get name => 'VaifAuthException';
}

/// The resource does not exist (HTTP 404).
class VaifNotFoundException extends VaifException {
  /// Creates the exception for a 404 response.
  VaifNotFoundException(
    super.message, {
    super.status,
    super.code,
    super.details,
    super.requestId,
    super.body,
    super.headers,
  });

  @override
  String get name => 'VaifNotFoundException';
}

/// The request conflicts with current state (HTTP 409).
class VaifConflictException extends VaifException {
  /// Creates the exception for a 409 response.
  VaifConflictException(
    super.message, {
    super.status,
    super.code,
    super.details,
    super.requestId,
    super.body,
    super.headers,
  });

  @override
  String get name => 'VaifConflictException';
}

/// Too many requests (HTTP 429). [retryAfter] is set when the API sent one.
class VaifRateLimitException extends VaifException {
  /// Creates the exception for a 429 response.
  VaifRateLimitException(
    super.message, {
    this.retryAfter,
    super.status,
    super.code,
    super.details,
    super.requestId,
    super.body,
    super.headers,
  });

  /// How long the API asked the client to wait, from `Retry-After`.
  final Duration? retryAfter;

  @override
  String get name => 'VaifRateLimitException';
}

/// The server failed to handle the request (HTTP 5xx).
class VaifServerException extends VaifException {
  /// Creates the exception for a 5xx response.
  VaifServerException(
    super.message, {
    super.status,
    super.code,
    super.details,
    super.requestId,
    super.body,
    super.headers,
  });

  @override
  String get name => 'VaifServerException';
}

/// The request could not be completed at the network level.
class VaifNetworkException extends VaifException {
  /// Creates the exception; [cause] is the transport's error.
  VaifNetworkException(super.message, {super.cause});

  @override
  String get name => 'VaifNetworkException';
}

/// The request did not complete within its timeout.
class VaifTimeoutException extends VaifNetworkException {
  /// Creates the exception for an attempt that ran out of time.
  VaifTimeoutException(super.message, {super.cause});

  @override
  String get name => 'VaifTimeoutException';
}

/// The client's `SessionStorage` failed to read, save or delete the session.
///
/// [code] is `SESSION_STORAGE_FAILED`; [cause] is the storage's error.
class VaifSessionStorageException extends VaifException {
  /// Creates the exception; [cause] is the storage's error.
  VaifSessionStorageException(super.message, {super.cause})
    : super(code: 'SESSION_STORAGE_FAILED');

  @override
  String get name => 'VaifSessionStorageException';
}

/// Where a VAIF Studio account is created.
const String consoleSignUpUrl = 'https://console.vaif.studio/register';

/// Where a VAIF Studio password is reset.
const String consolePasswordResetUrl =
    'https://console.vaif.studio/forgot-password';

/// A VAIF Studio account is created, and its password reset, only in the
/// console, whose pages carry a bot check this client cannot pass.
///
/// A platform client (no `projectId`) throws this from `auth.signUp()` and
/// `auth.requestPasswordReset()`, and the generated `postAuthSignup()` and
/// `postAuthForgotPassword()` throw it, before any request. [code] is
/// `CONSOLE_ONLY`.
/// [consoleUrl] is the console page to send the person to. A project client
/// signs up and resets the users of your own app as usual.
class VaifConsoleOnlyError extends VaifException {
  VaifConsoleOnlyError._(this.method, String message, this.consoleUrl)
    : super(message, code: 'CONSOLE_ONLY');

  /// Platform sign-up. [method] names the call that refused; [ownApp] says
  /// how to sign up your own app's users instead.
  factory VaifConsoleOnlyError.signUp({
    String method = 'auth.signUp()',
    String ownApp = 'create the client with your projectId',
  }) => VaifConsoleOnlyError._(
    method,
    'Create your VAIF Studio account in the console at '
    '$consoleSignUpUrl. To sign up users of your own app, $ownApp.',
    consoleSignUpUrl,
  );

  /// Platform password reset.
  factory VaifConsoleOnlyError.passwordReset({
    String method = 'auth.requestPasswordReset()',
    String ownApp = 'create the client with your projectId',
  }) => VaifConsoleOnlyError._(
    method,
    'Reset your VAIF Studio password in the console at '
    '$consolePasswordResetUrl. To reset passwords for users of your '
    'own app, $ownApp.',
    consolePasswordResetUrl,
  );

  /// The SDK call that refused, e.g. `auth.signUp()`.
  final String method;

  /// The console page that does this instead.
  final String consoleUrl;

  @override
  String get name => 'VaifConsoleOnlyError';
}

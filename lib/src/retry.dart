/// Bounded retry policy with exponential backoff and jitter.
///
/// Only replay-safe methods (GET, HEAD, OPTIONS) are retried on 429 and 5xx
/// responses, timeouts and network errors. Mutating calls can opt in per
/// request (`idempotent: true`) when the caller knows a replay is harmless.
/// A POST that failed to connect is not retried: `package:http` does not say
/// whether the request left the device, so the SDK assumes it may have.
library;

import 'dart:math';

/// HTTP methods that are retried by default.
const Set<String> replaySafeMethods = {'GET', 'HEAD', 'OPTIONS'};

/// HTTP statuses treated as transient by default.
const Set<int> defaultRetryStatuses = {429, 500, 502, 503, 504};

final Random _random = Random();

/// How transient failures are retried.
class RetryPolicy {
  /// Creates a policy. [maxRetries] counts retries after the first attempt.
  const RetryPolicy({
    this.maxRetries = 3,
    this.baseDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.multiplier = 2.0,
    this.retryOn = defaultRetryStatuses,
    this.retryOnNetworkError = true,
  }) : assert(maxRetries >= 0, 'maxRetries must be >= 0'),
       assert(multiplier >= 1, 'multiplier must be >= 1');

  /// A policy that never retries.
  static const RetryPolicy none = RetryPolicy(maxRetries: 0);

  /// Retries after the first attempt (0 disables retries).
  final int maxRetries;

  /// Delay before the first retry.
  final Duration baseDelay;

  /// Cap on the exponential backoff before jitter, which can add up to 25%;
  /// also caps `Retry-After`.
  final Duration maxDelay;

  /// Exponential growth factor between retries.
  final double multiplier;

  /// HTTP statuses treated as transient.
  final Set<int> retryOn;

  /// Retry replay-safe requests on timeouts and network errors.
  final bool retryOnNetworkError;

  /// Retries allowed, never negative (asserts are stripped in release builds).
  int get budget => maxRetries < 0 ? 0 : maxRetries;

  /// The wait before retry number [attempt] (0-based).
  ///
  /// A positive [retryAfter] from the server wins, capped at [maxDelay].
  /// Otherwise the delay grows exponentially, is capped at [maxDelay], and
  /// gets up to 25% jitter so many clients do not retry in lockstep.
  Duration delayFor(int attempt, {Duration? retryAfter, Random? random}) {
    if (retryAfter != null && retryAfter > Duration.zero) {
      return retryAfter < maxDelay ? retryAfter : maxDelay;
    }
    final baseUs = baseDelay.inMicroseconds.toDouble();
    final capUs = maxDelay.inMicroseconds.toDouble();
    final raw = baseUs * pow(multiplier, attempt);
    final delay = raw.isFinite && raw < capUs ? raw : capUs;
    if (delay <= 0) return Duration.zero;
    final jitter = delay * (random ?? _random).nextDouble() * 0.25;
    return Duration(microseconds: (delay + jitter).round());
  }
}

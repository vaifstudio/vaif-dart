/// One API operation, as the generated table describes it.
class Operation {
  /// Creates an operation; the generated `operations` table holds them.
  const Operation({
    required this.method,
    required this.path,
    required this.pathParams,
    required this.requiredQuery,
    required this.transport,
    this.bodyKind,
    this.bodyRequired = false,
  });

  /// The HTTP method, in capitals.
  final String method;

  /// The path, with parameters in braces, such as `/projects/{projectId}`.
  final String path;

  /// The names of the path parameters.
  final List<String> pathParams;

  /// The names of the required query parameters.
  final List<String> requiredQuery;

  /// How the response is read: `json`, `binary` (bytes) or `sse` (a live
  /// stream).
  final String transport;

  /// The request body's kind (`json` or `binary`), or null for none.
  final String? bodyKind;

  /// Whether the operation requires a request body.
  final bool bodyRequired;
}

part of 'client.dart';

/// Largest object a single presigned PUT accepts.
const int maxUploadBytes = 5 * 1024 * 1024 * 1024;

String _checkKey(String key) {
  if (key.isEmpty) throw ArgumentError.value(key, 'key', 'must not be empty');
  if (key.startsWith('/') || key.split('/').contains('..')) {
    throw ArgumentError.value(
      key,
      'key',
      "must be relative and must not contain '..' segments",
    );
  }
  if (key.codeUnits.any((c) => c < 32)) {
    throw ArgumentError.value(
      key,
      'key',
      'must not contain control characters',
    );
  }
  return key;
}

/// Uploads, downloads and signs URLs for objects in the project's storage.
///
/// [bucket] is optional everywhere; when omitted the API uses the project's
/// default bucket. Keys are paths such as `avatars/u1.png`.
class StorageClient {
  StorageClient._(this._client);

  final VaifClient _client;

  static Map<String, String> _target(String key, String? bucket) => {
    'key': _checkKey(key),
    if (bucket != null && bucket.isNotEmpty) 'bucket': bucket,
  };

  /// Uploads an object (overwrites an existing object with the same key).
  ///
  /// Two steps: the API mints a presigned URL
  /// (`POST /storage/upload-url`, which also meters the bytes), then the
  /// bytes go straight to the object store with an HTTP PUT. The PUT is
  /// retried on transient failures; the mint is not, since it is metered.
  Future<UploadResult> upload(
    String key,
    List<int> data, {
    String contentType = 'application/octet-stream',
    String? bucket,
  }) async {
    if (data.isEmpty) {
      throw ArgumentError.value(data, 'data', 'must not be empty');
    }
    if (data.length > maxUploadBytes) {
      throw ArgumentError.value(
        data.length,
        'data',
        'upload() accepts at most 5 GiB',
      );
    }
    final url = await createSignedUploadUrl(
      key,
      sizeBytes: data.length,
      contentType: contentType,
      bucket: bucket,
    );
    await _client._transport.putPresigned(url, data, contentType);
    return UploadResult(key: key, bucket: bucket, size: data.length);
  }

  /// Downloads an object's bytes.
  ///
  /// Two steps: the API issues a signed link
  /// (`POST /storage/download-url`, as [createSignedUrl] does), and the
  /// bytes are read from that link without the API key or session token.
  /// Both steps work in a browser. Throws [VaifNotFoundException] when the
  /// object store reports the object missing (HTTP 404).
  Future<Uint8List> download(String key, {String? bucket}) async {
    final url = await createSignedUrl(key, bucket: bucket);
    final response = await _client._transport.getPresigned(url);
    return response.bodyBytes;
  }

  /// A time-limited download URL: [expiresIn] seconds when given (1 to
  /// 604800, capped at the project's maximum), else the project's default
  /// lifetime (10 minutes unless the project sets another).
  Future<String> createSignedUrl(
    String key, {
    String? bucket,
    int? expiresIn,
  }) async {
    if (expiresIn != null && (expiresIn < 1 || expiresIn > 604800)) {
      throw RangeError.range(expiresIn, 1, 604800, 'expiresIn');
    }
    final response = await _client._send(
      'POST',
      '/storage/download-url',
      json: <String, Object>{
        ..._target(key, bucket),
        if (expiresIn != null) 'expiresIn': expiresIn,
      },
      idempotent: true,
    );
    return _url(response);
  }

  /// A time-limited URL that accepts an HTTP PUT of the object's bytes.
  ///
  /// The URL is signed for exactly [sizeBytes] bytes and, when [contentType]
  /// is given, exactly that `Content-Type`: the PUT must send both as signed
  /// or the object store refuses it. The API checks the size against the
  /// bucket's and project's limits and the storage quota, and meters it.
  Future<String> createSignedUploadUrl(
    String key, {
    required int sizeBytes,
    String? contentType,
    String? bucket,
  }) async {
    if (sizeBytes < 1 || sizeBytes > maxUploadBytes) {
      throw RangeError.range(sizeBytes, 1, maxUploadBytes, 'sizeBytes');
    }
    final payload = <String, Object?>{
      ..._target(key, bucket),
      'sizeBytes': sizeBytes,
      if (contentType != null && contentType.isNotEmpty)
        'contentType': contentType,
    };
    final response = await _client._send(
      'POST',
      '/storage/upload-url',
      json: payload,
    );
    return _url(response);
  }

  final Map<String, String> _bucketIds = {};

  Future<String> _bucketId(String bucket) async {
    if (bucket.isEmpty) {
      throw ArgumentError.value(bucket, 'bucket', 'must not be empty');
    }
    if (RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(bucket)) {
      return bucket;
    }
    if (_bucketIds.containsKey(bucket)) return _bucketIds[bucket]!;
    final response = await _client._send(
      'GET',
      '/storage/buckets',
      query: {'projectId': _client.requiredProjectId},
    );
    final buckets = responseObject(response)['buckets'];
    if (buckets is List) {
      for (final b in buckets) {
        if (b is Map<String, dynamic> &&
            b['name'] is String &&
            b['id'] is String) {
          _bucketIds[b['name'] as String] = b['id'] as String;
        }
      }
    }
    return _bucketIds[bucket] ??
        (throw VaifNotFoundException(
          'Bucket not found',
          code: 'BUCKET_NOT_FOUND',
        ));
  }

  /// Lists the files in a bucket, given by name or ID.
  ///
  /// Uses the storage management routes, which accept only a VAIF Studio
  /// account's access token with a role in the project, not an app user's
  /// session or a project key alone.
  Future<StorageListResult> list({
    required String bucket,
    String? prefix,
    int? limit,
    String? cursor,
  }) async {
    if (limit != null && (limit < 1 || limit > 1000)) {
      throw RangeError.range(limit, 1, 1000, 'limit');
    }
    final id = await _bucketId(bucket);
    final response = await _client._send(
      'GET',
      '/buckets/${Uri.encodeComponent(id)}/files',
      query: {
        if (prefix != null) 'prefix': prefix,
        if (limit != null) 'maxKeys': '$limit',
        if (cursor != null) 'continuationToken': cursor,
      },
    );
    final body = responseObject(response);
    final files = body['files'];
    final folders = body['folders'];
    return StorageListResult(
      files:
          files is List
              ? [
                for (final f in files)
                  if (f is Map<String, dynamic>) f,
              ]
              : [],
      prefixes: folders is List ? folders.whereType<String>().toList() : [],
      nextCursor: body['nextToken'] as String?,
      hasMore: body['isTruncated'] == true,
    );
  }

  /// Deletes one object from a bucket, given by name or ID. Uses the same
  /// management routes as [list].
  Future<void> delete(String key, {required String bucket}) async {
    _checkKey(key);
    final id = await _bucketId(bucket);
    await _client._send(
      'DELETE',
      '/buckets/${Uri.encodeComponent(id)}/files',
      query: {'key': key},
    );
  }

  /// The signed URL in an API response. It must use https (http only for a
  /// loopback host), or `INSECURE_STORAGE_URL` is thrown.
  static String _url(http.Response response) {
    final body = responseJson(response);
    if (body is Map<String, dynamic>) {
      final url = body['url'];
      if (url is String && url.isNotEmpty) {
        signedStorageUri(url);
        return url;
      }
    }
    throw VaifException('The API response did not include a URL', body: body);
  }
}

/// A page of stored files, using the server's continuation token.
class StorageListResult {
  /// Creates a page; `StorageClient.list` returns these.
  const StorageListResult({
    required this.files,
    this.prefixes = const [],
    this.nextCursor,
    this.hasMore = false,
  });

  /// The files on this page, as the API describes them.
  final List<Map<String, dynamic>> files;

  /// The folder prefixes directly under the listed prefix.
  final List<String> prefixes;

  /// Pass as `cursor` to `list` for the next page; null on the last page.
  final String? nextCursor;

  /// Whether more files follow this page.
  final bool hasMore;
}

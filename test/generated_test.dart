import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:vaif_client/vaif_client.dart';

import 'support.dart';

class StreamingApi extends http.BaseClient {
  final chunks = StreamController<List<int>>();
  http.BaseRequest? request;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    this.request = request;
    return http.StreamedResponse(
      chunks.stream,
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }
}

/// The path of the API's OpenAPI contract, which the operations table is
/// generated from, or null. This package carries the generated table but not
/// the contract, so the contract test runs only when VAIF_API_CONTRACT names
/// it. A path that is set but does not exist fails the test.
final String? contractPath = Platform.environment['VAIF_API_CONTRACT'];

void main() {
  test(
    'generated table covers every contract route or records a skip reason',
    skip:
        contractPath == null
            ? "set VAIF_API_CONTRACT to the API's OpenAPI contract"
            : false,
    () {
      final bytes = File(contractPath!).readAsBytesSync();
      final spec = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final generated =
          File('lib/src/generated/operations.dart').readAsStringSync();
      expect(
        generated,
        contains(sha256.convert(bytes).toString().substring(0, 16)),
      );
      final routes =
          operations.values.map((op) => '${op.method} ${op.path}').toSet();
      expect(routes.length, operations.length);
      var total = 0;
      for (final entry in (spec['paths'] as Map).entries) {
        for (final method in (entry.value as Map).keys) {
          if (!{
            'get',
            'post',
            'put',
            'patch',
            'delete',
            'head',
            'options',
          }.contains(method)) {
            continue;
          }
          total++;
          final normalizedPath =
              (entry.key as String).length > 1
                  ? (entry.key as String).replaceFirst(RegExp(r'/$'), '')
                  : entry.key;
          final key = '${(method as String).toUpperCase()} $normalizedPath';
          expect(
            routes.contains(key) ||
                ungeneratedOperations.any((skip) => skip.startsWith('$key: ')),
            isTrue,
            reason: key,
          );
        }
      }
      // 943 operations in the contract: 801 generated and 142 not.
      expect(total, 943);
      expect(operations.length + ungeneratedOperations.length, total);
      for (final name in operations.keys) {
        expect(generated, contains('Future<Object?> $name('));
      }
    },
  );

  test('generated binary download follows the redirect and returns exact '
      'bytes', () async {
    final api =
        FakeApi()
          ..on('GET', '/storage/download', [
            http.Response(
              '',
              307,
              headers: {'location': 'https://files.test/o/a?sig=x'},
            ),
          ])
          ..on('GET', '/o/a', [
            http.Response.bytes([0, 255, 128], 200),
          ]);
    final client = makeClient(api);
    addTearDown(client.close);
    final name =
        operations.entries
            .singleWhere(
              (e) =>
                  e.value.path == '/storage/download' &&
                  e.value.method == 'GET',
            )
            .key;
    expect(name, 'getStorageDownload');
    expect(await client.operations.getStorageDownload(query: {'key': 'a'}), [
      0,
      255,
      128,
    ]);
    final read = api.calls('GET', '/o/a').single;
    expect(read.headers.containsKey('x-vaif-key'), isFalse);
    expect(read.headers.containsKey('authorization'), isFalse);
  });

  test(
    'generated SSE returns a live response without waiting for stream completion',
    () async {
      final api = StreamingApi();
      final client = VaifClient(
        projectId: project,
        apiKey: key,
        baseUrl: base,
        httpClient: api,
        timeout: const Duration(milliseconds: 100),
      );
      addTearDown(client.close);
      final value = await client.operations.postAiCopilotChatStream(
        body: {'message': 'hello'},
      );
      expect(value, isA<http.StreamedResponse>());
      final response = value! as http.StreamedResponse;
      final first = response.stream.first;
      api.chunks.add(utf8.encode('data: hello\n\n'));
      expect(utf8.decode(await first), 'data: hello\n\n');
      await api.chunks.close();
      expect(api.request!.headers['x-vaif-key'], key);
    },
  );

  test('an event stream that fails after its headers reports a '
      'VaifNetworkException', () async {
    final api = StreamingApi();
    final client = VaifClient(
      projectId: project,
      apiKey: key,
      baseUrl: base,
      httpClient: api,
    );
    addTearDown(client.close);
    final response =
        (await client.operations.postAiCopilotChatStream(
              body: {'message': 'hello'},
            ))!
            as http.StreamedResponse;
    final received = <List<int>>[];
    final failed = Completer<Object>();
    response.stream.listen(received.add, onError: failed.complete);

    api.chunks.add(utf8.encode('data: one\n\n'));
    api.chunks.addError(http.ClientException('Connection reset by peer'));

    final error = await failed.future;
    expect(error, isA<VaifNetworkException>());
    expect(
      (error as VaifNetworkException).cause,
      isA<http.ClientException>().having(
        (e) => e.message,
        'message',
        'Connection reset by peer',
      ),
    );
    expect(received.map(utf8.decode), ['data: one\n\n']);
    await api.chunks.close();
  });

  test('the generated file names no path, command or internal code of the '
      'source repository', () {
    final generated =
        File('lib/src/generated/operations.dart').readAsStringSync();
    final header = generated.split('\n').take(3).join('\n');
    expect(
      header,
      matches(
        RegExp(
          r'^// GENERATED CODE - DO NOT MODIFY BY HAND\.\n'
          r"// Generated by the VAIF Studio SDK generator from the VAIF Studio API's OpenAPI document\.\n"
          r'// Spec sha256:[0-9a-f]{16}; 801 operations generated, 142 not generated \(see ungeneratedOperations\)\.$',
        ),
      ),
    );
    for (final internal in ['apps/api', 'pnpm', 'scripts/', 'LEGACY_']) {
      expect(generated, isNot(contains(internal)), reason: internal);
    }
    expect(
      ungeneratedOperations,
      contains('POST /admin/admins: platform staff only'),
    );
  });

  test('no generated method calls a platform-staff route', () {
    final staffOnly = RegExp(r'^/(admin|auth/impersonate)(/|$)');
    expect(operations.length, 801);
    for (final entry in operations.entries) {
      expect(
        staffOnly.hasMatch(entry.value.path),
        isFalse,
        reason: '${entry.key} calls ${entry.value.method} ${entry.value.path}',
      );
    }
    expect(ungeneratedOperations.length, 142);
    final staff =
        ungeneratedOperations
            .where((op) => op.endsWith(': platform staff only'))
            .toList();
    expect(staff.length, 108);
    for (final op in ungeneratedOperations) {
      final path = op.split(' ')[1].replaceFirst(RegExp(r':$'), '');
      expect(
        staffOnly.hasMatch(path),
        op.endsWith(': platform staff only'),
        reason: op,
      );
    }
    expect(
      staff,
      contains('POST /auth/impersonate/token: platform staff only'),
    );

    // No source file names a staff route except in the list of operations
    // without a generated method. /auth/me/admin is a route of its own.
    final named = RegExp(r'''["'\s]/(admin|auth/impersonate)([/"'{.\s]|$)''');
    final listed = RegExp(r'^  "[A-Z]+ [^"]+: platform staff only",$');
    final files =
        Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .toList();
    expect(files.length, greaterThan(10));
    for (final file in files) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (named.hasMatch(lines[i]) && !listed.hasMatch(lines[i])) {
          fail(
            '${file.path}:${i + 1} names a platform-staff route: ${lines[i]}',
          );
        }
      }
    }
  });
}

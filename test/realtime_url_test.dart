import 'package:test/test.dart';
import 'package:vaif_client/vaif_client.dart';

/// The socket URL a [RealtimeClient] on [baseUrl] dials. The factory records
/// the URL and refuses, so no socket ever opens.
Future<Uri> dialedUri(String baseUrl) async {
  Uri? dialed;
  final client = RealtimeClient(
    baseUrl: baseUrl,
    apiKey: 'key',
    accessToken: () async => 'token',
    timeout: const Duration(milliseconds: 200),
    channelFactory: (uri) {
      dialed = uri;
      throw StateError('no socket in this test');
    },
  );
  await expectLater(client.connect(), throwsA(isA<VaifNetworkException>()));
  return dialed!;
}

/// Constructing a client on [baseUrl] must fail with INVALID_REALTIME_URL
/// before it can read a token or open a socket.
void expectRefused(String baseUrl) {
  var tokenReads = 0;
  var socketsOpened = 0;
  expect(
    () => RealtimeClient(
      baseUrl: baseUrl,
      apiKey: 'key',
      accessToken: () async {
        tokenReads++;
        return 'token';
      },
      timeout: const Duration(milliseconds: 200),
      channelFactory: (uri) {
        socketsOpened++;
        throw StateError('must not dial $uri');
      },
    ),
    throwsA(
      isA<VaifValidationException>().having(
        (e) => e.code,
        'code',
        'INVALID_REALTIME_URL',
      ),
    ),
  );
  expect(tokenReads, 0);
  expect(socketsOpened, 0);
}

void main() {
  group('realtime socket URL', () {
    test('https becomes wss in any case', () async {
      expect(
        (await dialedUri('https://api.example.com')).toString(),
        'wss://api.example.com/realtime/ws',
      );
      expect(
        (await dialedUri('HTTPS://api.example.com')).toString(),
        'wss://api.example.com/realtime/ws',
      );
      expect(
        (await dialedUri('Https://api.example.com:8443/v2')).toString(),
        'wss://api.example.com:8443/v2/realtime/ws',
      );
    });

    test('http becomes ws for localhost, 127.0.0.1 and ::1 only', () async {
      expect(
        (await dialedUri('http://localhost:3147')).toString(),
        'ws://localhost:3147/realtime/ws',
      );
      expect(
        (await dialedUri('HTTP://LOCALHOST:3147')).toString(),
        'ws://localhost:3147/realtime/ws',
      );
      expect(
        (await dialedUri('http://127.0.0.1:3147')).toString(),
        'ws://127.0.0.1:3147/realtime/ws',
      );
      expect(
        (await dialedUri('http://[::1]:3147')).toString(),
        'ws://[::1]:3147/realtime/ws',
      );
    });

    test('cleartext to any other host is refused before a token is read', () {
      expectRefused('http://api.example.com');
      expectRefused('HTTP://api.example.com');
      expectRefused('http://localhost.example.com');
      expectRefused('http://192.168.1.10:3147');
    });

    test('any scheme other than http(s) is refused', () {
      expectRefused('ftp://x');
      expectRefused('ws://localhost:3147');
      expectRefused('wss://api.example.com');
      expectRefused('api.example.com');
      expectRefused('https://');
    });

    test('a VaifClient on HTTPS in capitals dials wss', () async {
      Uri? dialed;
      final client = VaifClient(
        projectId: 'p',
        apiKey: 'key',
        baseUrl: 'HTTPS://api.example.com',
        timeout: const Duration(milliseconds: 200),
        realtimeChannelFactory: (uri) {
          dialed = uri;
          throw StateError('no socket in this test');
        },
      );
      addTearDown(client.close);
      await expectLater(
        client.realtime.connect(),
        throwsA(isA<VaifNetworkException>()),
      );
      expect(dialed.toString(), 'wss://api.example.com/realtime/ws');
    });
  });
}

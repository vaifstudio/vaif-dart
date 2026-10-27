import 'package:test/test.dart';
import 'package:vaif_client/vaif_client.dart';

import 'flutter_names.dart';

void main() {
  test('the SDK can be imported beside Flutter\'s widgets library', () {
    // Each name would be an ambiguous import if the SDK exported it.
    expect(const Row(), isA<Row>());
    expect(const Page(), isA<Page>());
    expect(
      const PageResult(data: [], total: 41, page: 2, pageSize: 20).pageCount,
      3,
    );
    expect(VaifClient, isNotNull);
  });
}

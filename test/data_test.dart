import 'dart:convert';

import 'package:test/test.dart';
import 'package:vaif_client/vaif_client.dart';

import 'support.dart';

void main() {
  late FakeApi api;
  late VaifClient client;

  setUp(() {
    api = FakeApi();
    client = makeClient(api);
  });

  test(
    'list sends filters, select, order and paging as query parameters',
    () async {
      api.on('GET', dataPath('todos'), [
        jsonResponse(200, {
          'data': [
            {'id': 1, 'title': 'a'},
          ],
          'count': 41,
        }),
      ]);
      final result =
          await client
              .from('todos')
              .eq('done', false)
              .gte('priority', 2)
              .inList('tag', ['x', 'y'])
              .select(['id', 'title'])
              .order('priority', descending: true)
              .order('id')
              .limit(10)
              .offset(20)
              .list();

      final q = api.requests.single.url.queryParameters;
      expect(jsonDecode(q['where']!), {
        'AND': [
          {'field': 'done', 'operator': 'eq', 'value': false},
          {'field': 'priority', 'operator': 'gte', 'value': 2},
          {
            'field': 'tag',
            'operator': 'in',
            'value': ['x', 'y'],
          },
        ],
      });
      expect(q['select'], 'id,title');
      expect(q['orderBy'], 'priority,id');
      expect(q['orderDir'], 'desc,asc');
      expect(q['limit'], '10');
      expect(q['offset'], '20');
      expect(result.count, 41);
      expect(result.data.single['title'], 'a');
    },
  );

  test(
    'a single filter is sent bare; DateTime values become ISO-8601 UTC',
    () async {
      api.on('GET', dataPath('events'), [
        jsonResponse(200, {'data': [], 'count': 0}),
      ]);
      await client
          .from('events')
          .lt('at', DateTime.utc(2026, 11, 14, 9, 30))
          .list();
      expect(jsonDecode(api.requests.single.url.queryParameters['where']!), {
        'field': 'at',
        'operator': 'lt',
        'value': '2026-11-14T09:30:00.000Z',
      });
    },
  );

  test('builders are immutable: a base query can be reused', () async {
    api.on('GET', dataPath('todos'), [
      jsonResponse(200, {'data': [], 'count': 0}),
    ]);
    final open = client.from('todos').eq('done', false);
    await open.eq('owner', 'u1').list();
    await open.list();
    final wheres =
        api.requests
            .map((r) => jsonDecode(r.url.queryParameters['where']!))
            .toList();
    expect((wheres[0] as Map)['AND'], hasLength(2));
    expect(wheres[1], {'field': 'done', 'operator': 'eq', 'value': false});
  });

  test(
    'where() adds a raw clause, like/ilike/neq/gt/lte map to operators',
    () async {
      api.on('GET', dataPath('t'), [
        jsonResponse(200, {'data': [], 'count': 0}),
      ]);
      await client
          .from('t')
          .where({
            'OR': [
              {'field': 'a', 'value': 1},
              {'field': 'b', 'value': 2},
            ],
          })
          .like('n', 'a%')
          .ilike('m', '%B')
          .neq('x', 1)
          .gt('y', 2)
          .lte('z', 3)
          .list();
      final tree =
          jsonDecode(api.requests.single.url.queryParameters['where']!) as Map;
      final ops = [
        for (final c in (tree['AND'] as List).skip(1)) (c as Map)['operator'],
      ];
      expect(ops, ['like', 'ilike', 'neq', 'gt', 'lte']);
      expect((tree['AND'] as List).first, contains('OR'));
    },
  );

  test(
    'first() asks for one row and returns null when there is none',
    () async {
      api.on('GET', dataPath('todos'), [
        jsonResponse(200, {
          'data': [
            {'id': 9},
          ],
          'count': 5,
        }),
        jsonResponse(200, {'data': [], 'count': 0}),
      ]);
      expect(await client.from('todos').first(), {'id': 9});
      expect(api.requests.first.url.queryParameters['limit'], '1');
      expect(await client.from('todos').first(), isNull);
    },
  );

  test('paginate computes limit/offset and page flags', () async {
    api.on('GET', dataPath('todos'), [
      jsonResponse(200, {
        'data': [
          {'id': 3},
        ],
        'count': 5,
      }),
    ]);
    final page = await client.from('todos').paginate(page: 2, pageSize: 2);
    final q = api.requests.single.url.queryParameters;
    expect(q['limit'], '2');
    expect(q['offset'], '2');
    expect(page.total, 5);
    expect(page.pageCount, 3);
    expect(page.hasNext, isTrue);
    expect(page.hasPrevious, isTrue);
  });

  test('CRUD uses the right paths, methods and bodies', () async {
    api
      ..on('GET', dataPath('todos', '/r%2F1'), [
        jsonResponse(200, {
          'data': {'id': 'r/1'},
        }),
      ])
      ..on('POST', dataPath('todos'), [
        jsonResponse(201, {
          'data': {'id': 2, 'title': 'x'},
        }),
      ])
      ..on('POST', dataPath('todos', '/bulk'), [
        jsonResponse(201, {
          'data': [
            {'id': 3},
            {'id': 4},
          ],
        }),
      ])
      ..on('PATCH', dataPath('todos', '/2'), [
        jsonResponse(200, {
          'data': {'id': 2, 'title': 'y'},
        }),
      ])
      ..on('DELETE', dataPath('todos', '/2'), [
        jsonResponse(200, {'ok': true}),
      ]);
    final todos = client.from('todos');

    expect(await todos.select(['id']).get('r/1'), {'id': 'r/1'});
    expect(api.requests.last.url.queryParameters['select'], 'id');

    expect(await todos.insert({'title': 'x'}), {'id': 2, 'title': 'x'});
    expect(bodyOf(api.requests.last), {'title': 'x'});
    expect(api.requests.last.headers['content-type'], 'application/json');

    expect(
      await todos.insertMany([
        {'title': 'a'},
        {'title': 'b'},
      ]),
      hasLength(2),
    );
    expect(jsonDecode(api.requests.last.body), hasLength(2));
    expect(await todos.insertMany([]), isEmpty);

    await todos.upsert({'slug': 's', 'title': 'x'}, onConflict: ['slug']);
    expect(bodyOf(api.requests.last), {
      'slug': 's',
      'title': 'x',
      '_upsert': true,
      '_conflict_columns': ['slug'],
    });

    expect(await todos.update(2, {'title': 'y'}), {'id': 2, 'title': 'y'});
    expect(api.requests.last.method, 'PATCH');

    await todos.delete(2);
    expect(api.requests.last.method, 'DELETE');
  });

  test(
    'a missing row is VaifNotFoundException; a bad column keeps its code',
    () async {
      api
        ..on('GET', dataPath('todos', '/nope'), [
          jsonResponse(404, {
            'error': 'NOT_FOUND',
            'message': 'Record not found',
          }),
        ])
        ..on('GET', dataPath('todos'), [
          jsonResponse(400, {
            'error': 'BadRequest',
            'code': 'INVALID_COLUMN',
            'message': 'no col',
          }),
        ]);
      await expectLater(
        client.from('todos').get('nope'),
        throwsA(isA<VaifNotFoundException>()),
      );
      await expectLater(
        client.from('todos').eq('ghost', 1).list(),
        throwsA(
          isA<VaifValidationException>().having(
            (e) => e.code,
            'code',
            'INVALID_COLUMN',
          ),
        ),
      );
    },
  );

  test('a response without a row is a typed error', () async {
    api.on('POST', dataPath('todos'), [
      jsonResponse(201, {'ok': true}),
    ]);
    await expectLater(
      client.from('todos').insert({'a': 1}),
      throwsA(isA<VaifException>()),
    );
  });

  test(
    'identifiers, limits and empty lists are validated before any request',
    () {
      expect(() => client.from('todos; drop'), throwsArgumentError);
      expect(() => client.from('todos').eq('a-b', 1), throwsArgumentError);
      expect(() => client.from('todos').order('1x'), throwsArgumentError);
      expect(() => client.from('todos').limit(0), throwsRangeError);
      expect(() => client.from('todos').limit(maxLimit + 1), throwsRangeError);
      expect(() => client.from('todos').offset(-1), throwsRangeError);
      expect(() => client.from('todos').inList('a', []), throwsArgumentError);
      expect(
        () => client.from('todos').upsert({'a': 1}, onConflict: []),
        throwsArgumentError,
      );
      expect(() => client.from('todos').paginate(page: 0), throwsRangeError);
      expect(api.requests, isEmpty);
    },
  );

  test('ids that are dot segments are refused before any request', () {
    final todos = client.from('todos');
    for (final id in ['.', '..']) {
      expect(() => todos.get(id), throwsArgumentError, reason: id);
      expect(() => todos.update(id, {'done': true}), throwsArgumentError);
      expect(() => todos.delete(id), throwsArgumentError, reason: id);
      expect(() => client.auth.sessions.revoke(id), throwsArgumentError);
      expect(() => client.functions.invoke(id), throwsArgumentError);
      expect(
        () => VaifClient(projectId: id, apiKey: key, baseUrl: base),
        throwsArgumentError,
      );
    }
    expect(api.requests, isEmpty);
  });

  test('the project id is URL-encoded in the path', () async {
    final c = VaifClient(
      projectId: 'a b',
      apiKey: key,
      baseUrl: base,
      httpClient: api.client,
      retry: fastRetry,
    );
    api.on('GET', '/v1/data/a%20b/todos', [
      jsonResponse(200, {'data': [], 'count': 0}),
    ]);
    await c.from('todos').list();
    expect(
      api.requests.single.url.toString(),
      startsWith('$base/v1/data/a%20b/todos'),
    );
  });
}

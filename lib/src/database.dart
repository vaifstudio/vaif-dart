part of 'client.dart';

final RegExp _identifierPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// Server-side cap on `limit` (larger values return `LIMIT_TOO_HIGH`).
const int maxLimit = 1000;

String _identifier(String value, String what) {
  if (!_identifierPattern.hasMatch(value)) {
    throw ArgumentError.value(
      value,
      what,
      'must be a SQL identifier (letters, digits, _)',
    );
  }
  return value;
}

class _Order {
  const _Order(this.column, this.descending);
  final String column;
  final bool descending;
}

/// Immutable, chainable query against one table (`/v1/data/:projectId/:table`).
///
/// Every filter method returns a new builder, so a base query can be reused:
///
/// ```dart
/// final open = vaif.from('todos').eq('done', false);
/// final page = await open.order('created_at', descending: true).limit(20).list();
/// ```
class QueryBuilder {
  QueryBuilder._(
    this._client,
    String table, {
    List<Map<String, Object?>> filters = const [],
    List<_Order> order = const [],
    List<String>? columns,
    int? limit,
    int? offset,
  }) : table = _identifier(table, 'table'),
       _filters = filters,
       _order = order,
       _columns = columns,
       _limit = limit,
       _offset = offset;

  final VaifClient _client;

  /// The table this query targets.
  final String table;
  final List<Map<String, Object?>> _filters;
  final List<_Order> _order;
  final List<String>? _columns;
  final int? _limit;
  final int? _offset;

  QueryBuilder _copy({
    List<Map<String, Object?>>? filters,
    List<_Order>? order,
    List<String>? columns,
    bool clearColumns = false,
    int? limit,
    int? offset,
  }) => QueryBuilder._(
    _client,
    table,
    filters: filters ?? _filters,
    order: order ?? _order,
    columns: clearColumns ? null : (columns ?? _columns),
    limit: limit ?? _limit,
    offset: offset ?? _offset,
  );

  // ------------------------------------------------------------- filters

  QueryBuilder _clause(String column, String operator, Object? value) => _copy(
    filters: [
      ..._filters,
      {
        'field': _identifier(column, 'column'),
        'operator': operator,
        'value': value,
      },
    ],
  );

  /// `column = value`.
  QueryBuilder eq(String column, Object? value) => _clause(column, 'eq', value);

  /// `column <> value`.
  QueryBuilder neq(String column, Object? value) =>
      _clause(column, 'neq', value);

  /// `column > value`.
  QueryBuilder gt(String column, Object? value) => _clause(column, 'gt', value);

  /// `column >= value`.
  QueryBuilder gte(String column, Object? value) =>
      _clause(column, 'gte', value);

  /// `column < value`.
  QueryBuilder lt(String column, Object? value) => _clause(column, 'lt', value);

  /// `column <= value`.
  QueryBuilder lte(String column, Object? value) =>
      _clause(column, 'lte', value);

  /// Case-sensitive SQL `LIKE` (`%` and `_` wildcards).
  QueryBuilder like(String column, String pattern) =>
      _clause(column, 'like', pattern);

  /// Case-insensitive `LIKE`.
  QueryBuilder ilike(String column, String pattern) =>
      _clause(column, 'ilike', pattern);

  /// `column IN (values)`. (`in` is a Dart keyword.)
  QueryBuilder inList(String column, List<Object?> values) {
    if (values.isEmpty) {
      throw ArgumentError.value(values, 'values', 'needs at least one value');
    }
    return _clause(column, 'in', List<Object?>.of(values));
  }

  /// Adds a raw clause, e.g. `{'OR': [{'field': 'a', 'value': 1}, ...]}`.
  /// Clauses are ANDed with the other filters on the builder.
  QueryBuilder where(Map<String, Object?> clause) =>
      _copy(filters: [..._filters, Map<String, Object?>.of(clause)]);

  // ----------------------------------------------------------- modifiers

  /// Returns only these columns (default: all).
  QueryBuilder select(List<String> columns) =>
      columns.isEmpty
          ? _copy(clearColumns: true)
          : _copy(columns: [for (final c in columns) _identifier(c, 'column')]);

  /// Sorts by [column]; call again to add secondary sort keys.
  QueryBuilder order(String column, {bool descending = false}) => _copy(
    order: [..._order, _Order(_identifier(column, 'column'), descending)],
  );

  /// At most [count] rows (1..[maxLimit]).
  QueryBuilder limit(int count) {
    if (count < 1 || count > maxLimit) {
      throw RangeError.range(count, 1, maxLimit, 'count');
    }
    return _copy(limit: count);
  }

  /// Skips the first [count] rows.
  QueryBuilder offset(int count) {
    if (count < 0) throw RangeError.value(count, 'count', 'must be >= 0');
    return _copy(offset: count);
  }

  /// Inclusive zero-based range, matching limit/offset pagination.
  QueryBuilder range(int from, int to) {
    if (from < 0 || to < from) throw RangeError('Expected 0 <= from <= to');
    return limit(to - from + 1).offset(from);
  }

  /// The filters as the flat `{field: value}` equality map the bulk and
  /// aggregate routes accept. Those routes match only `field = value`, so an
  /// `OR`/`NOT` clause, any other operator or a null/list value throws here
  /// instead of running a wider write or count than the chain says.
  Map<String, String> _equalityMap(String what) {
    final out = <String, String>{};
    void visit(Map<String, Object?> clause) {
      final and = clause['AND'];
      if (and is List) {
        for (final child in and) {
          if (child is! Map) throw ArgumentError('$what: invalid AND clause');
          visit(Map<String, Object?>.from(child));
        }
        return;
      }
      if (clause.containsKey('OR') || clause.containsKey('NOT')) {
        throw ArgumentError(
          '$what supports only equality filters (an AND of '
          'eq clauses); OR/NOT is not supported by the server',
        );
      }
      final field = clause['field'];
      final value = clause['value'];
      final operator = clause['operator'] ?? 'eq';
      if (field is! String || operator != 'eq') {
        throw ArgumentError(
          "$what supports only the 'eq' operator, got '$operator'",
        );
      }
      if (value == null || value is Map || value is List) {
        throw ArgumentError('$what needs a non-null scalar value for $field');
      }
      final name = _identifier(field, 'field');
      final text =
          value is DateTime ? value.toUtc().toIso8601String() : '$value';
      if (out.containsKey(name) && out[name] != text) {
        throw ArgumentError('$what: conflicting values for $field');
      }
      out[name] = text;
    }

    for (final clause in _filters) {
      visit(clause);
    }
    return out;
  }

  Map<String, String> _filterParams(String what) => {
    for (final entry in _equalityMap(what).entries)
      'filter[${entry.key}]': entry.value,
  };

  Future<Object?> _aggregate(String fn, [String? column]) async {
    final params = <String, String>{
      'fn': fn,
      if (column != null) 'column': _identifier(column, 'column'),
      ..._filterParams(fn),
    };
    final body = responseObject(
      await _client._send('GET', '$_base/aggregate', query: params),
    );
    final rows = _rows(body['data']);
    return rows.isEmpty ? null : rows.first['value'];
  }

  static num? _number(Object? value) =>
      value is num ? value : (value == null ? null : num.tryParse('$value'));

  /// Counts matching rows (`GET /:table/aggregate?fn=count`). The API's
  /// aggregate route matches equality filters only, so only an AND of
  /// equality filters can be counted; anything else throws [ArgumentError]
  /// before the request.
  Future<int> count() async => _number(await _aggregate('count'))?.toInt() ?? 0;

  /// Sum of [column] over the matching rows (0 when none match).
  Future<num> sum(String column) async =>
      _number(await _aggregate('sum', column)) ?? 0;

  /// Average of [column] over the matching rows (0 when none match).
  Future<num> avg(String column) async =>
      _number(await _aggregate('avg', column)) ?? 0;

  /// Smallest value of [column], or null when no rows match.
  Future<Object?> min(String column) => _aggregate('min', column);

  /// Largest value of [column], or null when no rows match.
  Future<Object?> max(String column) => _aggregate('max', column);

  /// Updates every row matching the filters (`PATCH /:table/bulk`) and
  /// returns the updated rows. Needs at least one equality filter: the
  /// server refuses an unfiltered bulk update, and this fails first.
  Future<ListResult> updateMany(Map<String, Object?> values) async {
    if (values.isEmpty) {
      throw ArgumentError.value(values, 'values', 'must not be empty');
    }
    final filter = _equalityMap('updateMany');
    if (filter.isEmpty) {
      throw ArgumentError('updateMany needs at least one eq() filter');
    }
    final body = responseObject(
      await _client._send(
        'PATCH',
        '$_base/bulk',
        json: {'data': values, 'filter': filter},
      ),
    );
    final data = _rows(body['data']);
    final count = body['count'];
    return ListResult(
      data: data,
      count: count is num ? count.toInt() : data.length,
    );
  }

  /// Deletes every row matching the filters (`DELETE /:table/bulk`) and
  /// returns how many were deleted. Needs at least one equality filter.
  Future<int> deleteMany() async {
    final params = _filterParams('deleteMany');
    if (params.isEmpty) {
      throw ArgumentError('deleteMany needs at least one eq() filter');
    }
    final body = responseObject(
      await _client._send('DELETE', '$_base/bulk', query: params),
    );
    final deleted = body['deleted'] ?? body['count'];
    return deleted is num ? deleted.toInt() : 0;
  }

  /// Subscribes to changes of the rows this chain selects: the filters
  /// become server-side realtime filters and [select] the columns sent.
  ///
  /// Realtime filters support an AND of `eq`, `neq`, `gt`, `gte`, `lt`,
  /// `lte` and `inList` with string, number or boolean values; anything else
  /// throws [ArgumentError], since dropping a filter would stream rows that
  /// [list] never returns. Order, limit and offset do not apply to changes.
  Future<RealtimeSubscription> subscribe() async {
    final filters = <RealtimeFilter>[];
    void visit(Map<String, Object?> clause) {
      final and = clause['AND'];
      if (and is List) {
        for (final child in and) {
          if (child is! Map) throw ArgumentError('invalid AND clause');
          visit(Map<String, Object?>.from(child));
        }
        return;
      }
      if (clause.containsKey('OR') || clause.containsKey('NOT')) {
        throw ArgumentError('Realtime filters cannot express OR/NOT');
      }
      final field = clause['field'];
      if (field is! String) {
        throw ArgumentError('Realtime filter needs a field');
      }
      filters.add(
        RealtimeFilter(
          field,
          (clause['operator'] ?? 'eq') as String,
          clause['value'],
        ),
      );
    }

    for (final clause in _filters) {
      visit(clause);
    }
    _client.requiredProjectId;
    return _client.realtime.subscribe(
      table,
      filters: filters,
      columns: _columns,
    );
  }

  // -------------------------------------------------------- serializing

  Map<String, String> _params({int? limit, int? offset}) {
    final params = <String, String>{};
    if (_filters.isNotEmpty) {
      final tree = _filters.length == 1 ? _filters.first : {'AND': _filters};
      params['where'] = jsonEncode(tree, toEncodable: toJsonEncodable);
    }
    final columns = _columns;
    if (columns != null && columns.isNotEmpty) {
      params['select'] = columns.join(',');
    }
    if (_order.isNotEmpty) {
      params['orderBy'] = _order.map((o) => o.column).join(',');
      params['orderDir'] = _order
          .map((o) => o.descending ? 'desc' : 'asc')
          .join(',');
    }
    final finalLimit = limit ?? _limit;
    final finalOffset = offset ?? _offset;
    if (finalLimit != null) params['limit'] = '$finalLimit';
    if (finalOffset != null) params['offset'] = '$finalOffset';
    return params;
  }

  String get _base =>
      '/v1/data/${Uri.encodeComponent(_client.requiredProjectId)}/$table';

  String _rowPath(Object id) => '$_base/${_pathSegment('$id', 'id')}';

  static List<Map<String, dynamic>> _rows(Object? data) =>
      data is List
          ? [
            for (final r in data)
              if (r is Map<String, dynamic>) r,
          ]
          : <Map<String, dynamic>>[];

  static Map<String, dynamic> _row(http.Response response) {
    final body = responseJson(response);
    if (body is Map<String, dynamic>) {
      final data = body['data'];
      if (data is Map<String, dynamic>) return data;
    }
    throw VaifException('The API response did not include a row', body: body);
  }

  // ----------------------------------------------------------- terminals

  /// Matching rows plus the total match count.
  Future<ListResult> list() async {
    final response = await _client._send('GET', _base, query: _params());
    final body = responseObject(response);
    final data = _rows(body['data']);
    final count = body['count'];
    return ListResult(
      data: data,
      count: count is num ? count.toInt() : data.length,
    );
  }

  /// The first matching row, or null.
  Future<Map<String, dynamic>?> first() async {
    final result = await _copy(limit: 1).list();
    return result.data.isEmpty ? null : result.data.first;
  }

  /// Offset pagination; [page] starts at 1.
  Future<PageResult> paginate({int page = 1, int pageSize = 20}) async {
    if (page < 1) throw RangeError.value(page, 'page', 'must be >= 1');
    if (pageSize < 1 || pageSize > maxLimit) {
      throw RangeError.range(pageSize, 1, maxLimit, 'pageSize');
    }
    final response = await _client._send(
      'GET',
      _base,
      query: _params(limit: pageSize, offset: (page - 1) * pageSize),
    );
    final body = responseObject(response);
    final data = _rows(body['data']);
    final total = body['count'];
    return PageResult(
      data: data,
      total: total is num ? total.toInt() : data.length,
      page: page,
      pageSize: pageSize,
    );
  }

  /// One row by primary key. Throws [VaifNotFoundException] if missing.
  Future<Map<String, dynamic>> get(Object id) async {
    final columns = _columns;
    final response = await _client._send(
      'GET',
      _rowPath(id),
      query:
          columns != null && columns.isNotEmpty
              ? {'select': columns.join(',')}
              : null,
    );
    return _row(response);
  }

  /// Inserts one row and returns it.
  Future<Map<String, dynamic>> insert(Map<String, Object?> values) async =>
      _row(await _client._send('POST', _base, json: values));

  /// Inserts rows in one request (all rows must share the same keys).
  Future<List<Map<String, dynamic>>> insertMany(
    List<Map<String, Object?>> rows,
  ) async {
    if (rows.isEmpty) return <Map<String, dynamic>>[];
    final response = await _client._send('POST', '$_base/bulk', json: rows);
    return _rows(responseObject(response)['data']);
  }

  /// Inserts, or updates the row that conflicts on [onConflict] columns.
  Future<Map<String, dynamic>> upsert(
    Map<String, Object?> values, {
    required List<String> onConflict,
  }) async {
    if (onConflict.isEmpty) {
      throw ArgumentError.value(
        onConflict,
        'onConflict',
        'needs at least one column',
      );
    }
    final payload = <String, Object?>{
      ...values,
      '_upsert': true,
      '_conflict_columns': [
        for (final c in onConflict) _identifier(c, 'onConflict'),
      ],
    };
    return _row(await _client._send('POST', _base, json: payload));
  }

  /// Updates one row by primary key and returns it.
  Future<Map<String, dynamic>> update(
    Object id,
    Map<String, Object?> values,
  ) async => _row(await _client._send('PATCH', _rowPath(id), json: values));

  /// Deletes one row by primary key.
  Future<void> delete(Object id) async {
    await _client._send('DELETE', _rowPath(id));
  }
}

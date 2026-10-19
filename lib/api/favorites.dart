import 'backend.dart';

class Favorite {
  const Favorite({
    required this.id,
    required this.name,
    required this.address,
    required this.latitude,
    required this.longitude,
    this.folderId,
    this.folderName,
    this.coordSystem = 'wgs84',
  });
  final String id, name, address, coordSystem;
  final String? folderId, folderName;
  String get displayName => name.isNotEmpty
      ? name
      : address.isNotEmpty
      ? address
      : coordinates;
  final double latitude, longitude;
  static Map<String, dynamic> validate(
    String name,
    String address,
    String latitude,
    String longitude,
  ) {
    final lat = double.tryParse(latitude.trim());
    final lon = double.tryParse(longitude.trim());
    if (address.trim().runes.length > 512) {
      throw ApiFailure('显示地址不能超过512字');
    }
    if (name.trim().runes.length > 128) {
      throw ApiFailure('名称不能超过128字');
    }
    if (lat == null || !lat.isFinite || lat < -90 || lat > 90) {
      throw ApiFailure('纬度须为 -90 至 90 的有效数字');
    }
    if (lon == null || !lon.isFinite || lon < -180 || lon > 180) {
      throw ApiFailure('经度须为 -180 至 180 的有效数字');
    }
    return {
      'name': name.trim().isEmpty ? null : name.trim(),
      'address': address.trim(),
      'latitude': lat,
      'longitude': lon,
      'coord_system': 'wgs84',
    };
  }

  factory Favorite.fromJson(Map<String, dynamic> json) {
    final lat = json['latitude'], lon = json['longitude'];
    if (json['id'] is! String ||
        (json['id'] as String).isEmpty ||
        (json['name'] != null && json['name'] is! String) ||
        (json['address'] != null && json['address'] is! String) ||
        lat is! num ||
        lon is! num) {
      throw ApiFailure('收藏夹响应格式不符');
    }
    if (!lat.isFinite ||
        lat < -90 ||
        lat > 90 ||
        !lon.isFinite ||
        lon < -180 ||
        lon > 180) {
      throw ApiFailure('收藏夹坐标无效');
    }
    return Favorite(
      id: '${json['id']}',
      name: json['name'] ?? '',
      address: json['address'] ?? '',
      latitude: lat.toDouble(),
      longitude: lon.toDouble(),
      coordSystem: '${json['coord_system'] ?? 'wgs84'}',
      folderId: json['folder_id'] as String?,
      folderName: json['folder_name'] as String?,
    );
  }
  String get coordinates => '$latitude, $longitude';
}

class FavoriteFolder {
  const FavoriteFolder({
    required this.id,
    required this.name,
    required this.count,
  });
  final String id, name;
  final int count;
  factory FavoriteFolder.fromJson(Map<String, dynamic> json) {
    if (json['id'] is! String ||
        (json['id'] as String).isEmpty ||
        json['name'] is! String ||
        json['favorite_count'] is! int ||
        (json['favorite_count'] as int) < 0) {
      throw ApiFailure('分类列表格式不符，请核对后端契约');
    }
    return FavoriteFolder(
      id: json['id'],
      name: json['name'],
      count: json['favorite_count'],
    );
  }
}

class FavoritePage<T> {
  const FavoritePage(
    this.items,
    this.total,
    this.hasMore,
    this.nextOffset, {
    this.uncategorizedCount = 0,
  });
  final List<T> items;
  final int total, nextOffset, uncategorizedCount;
  final bool hasMore;
}

class FavoriteWriteUncertain extends ApiFailure {
  FavoriteWriteUncertain() : super('保存结果尚未确认，请关闭并刷新列表核对，勿重复新增');
}

String favoriteError(Object error) {
  if (error is! ApiFailure) return '收藏服务响应异常，请刷新重试';
  return switch (error.statusCode) {
    401 => '登录会话已失效，请重新登录',
    403 => '当前账号无收藏管理权限，请联系管理员',
    404 => '地址或分类已不存在，列表已请求刷新',
    409 => '分类名称已存在，请刷新后使用已有分类或改名',
    422 => '名称、坐标或分类不符合后端规则，请检查输入',
    _ => error.message,
  };
}

class FavoritesApi {
  FavoritesApi(this.api) : _token = api.token, _origin = api.baseUrl;
  final BackendApi api;
  final String _token, _origin;
  static const path = '/api/v1/favorites';
  static const foldersPath = '/api/v1/favorite-folders';
  bool get current =>
      api.token == _token && api.baseUrl == _origin && _token.isNotEmpty;
  Future<Map<String, dynamic>> call(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) async {
    if (!current) throw ApiFailure('账号或服务已切换，请重新打开收藏');
    try {
      final transport = BackendApi(client: api.client)
        ..baseUrl = _origin
        ..token = _token
        ..isUserSession = api.isUserSession
        ..onSessionExpired = () async {
          if (current) await api.onSessionExpired?.call();
        };
      final value = await transport.call(
        method,
        path,
        query: query,
        body: body,
      );
      if (!current) throw ApiFailure('账号或服务已切换，请重新打开收藏');
      return value;
    } on ApiFailure catch (e) {
      if (method == 'POST' && e.statusCode == null) {
        throw FavoriteWriteUncertain();
      }
      rethrow;
    }
  }

  Future<Map<String, double>> resolvePlusCode(
    String raw, {
    Map<String, double>? reference,
  }) async {
    final code = raw.trim().toUpperCase();
    final separator = code.indexOf('+');
    final short = separator >= 0 && separator < 8;
    if (!RegExp(
          r'^[23456789CFGHJMPQRVWX0]{0,8}\+[23456789CFGHJMPQRVWX]{0,7}$',
        ).hasMatch(code) ||
        separator < 0 ||
        separator.isOdd ||
        (short && code.length - separator < 3)) {
      throw ApiFailure('请输入有效Plus Code，不能用城市名称代替参考坐标');
    }
    if (short &&
        (reference == null ||
            reference['latitude'] == null ||
            reference['longitude'] == null ||
            !reference['latitude']!.isFinite ||
            !reference['longitude']!.isFinite ||
            reference['latitude']!.abs() > 90 ||
            reference['longitude']!.abs() > 180)) {
      throw ApiFailure('短Plus Code需要明确WGS84参考纬度和经度，不能自动猜测位置');
    }
    if (!current) throw ApiFailure('账号或服务已切换，请重新打开收藏');
    final transport = BackendApi(client: api.client, baseUrl: _origin)
      ..token = _token
      ..isUserSession = api.isUserSession
      ..onSessionExpired = () async {
        if (current) await api.onSessionExpired?.call();
      };
    if (short) {
      final spec = await transport.call('GET', '/openapi.json', auth: false);
      if ((spec['components']
              as Map?)?['schemas']?['DestinationResolveRequest']?['properties']?['reference_coordinate'] ==
          null) {
        throw ApiFailure('当前后端尚未支持短码参考位置，请等待更新或使用完整Plus Code');
      }
    }
    final result = await transport.resolveDestination(
      code,
      requestId(),
      purpose: DestinationPurpose.favoritePreview,
      reference: short ? reference : null,
    );
    if (!current) throw ApiFailure('账号或服务已切换，已丢弃解析结果');
    final id = result['destination_id'] ?? result['request_id'];
    if (id is! String || id.isEmpty) throw ApiFailure('Plus Code解析引用缺失，未保存');
    final query = await call('GET', '/destinations/${Uri.encodeComponent(id)}');
    if (query['task_id'] != null) throw ApiFailure('收藏解析意外关联导航任务，已阻止保存并停止后续操作');
    if (!short &&
        (result['needs_confirmation'] == true ||
            query['needs_confirmation'] == true ||
            result['status'] == 'needs_clarification' ||
            query['status'] == 'needs_clarification')) {
      throw ApiFailure('解析需要更多位置确认，未保存收藏');
    }
    // Never treat the flattened first coordinate as a unique result.
    final previewCandidates = result['candidates'];
    if (previewCandidates is List && previewCandidates.length != 1) {
      throw ApiFailure('Plus Code未得到唯一有效坐标，未保存收藏');
    }
    final candidates = query['candidates'];
    if (candidates is! List ||
        candidates.length != 1 ||
        candidates.single is! Map) {
      throw ApiFailure('Plus Code未得到唯一有效坐标，未保存收藏');
    }
    final candidate = candidates.single as Map;
    final lat = candidate['latitude'], lon = candidate['longitude'];
    if (lat is! num ||
        lon is! num ||
        !lat.isFinite ||
        !lon.isFinite ||
        lat.abs() > 90 ||
        lon.abs() > 180 ||
        (candidate['coord_system'] != null &&
            candidate['coord_system'] != 'wgs84')) {
      throw ApiFailure('Plus Code解析坐标无效或非WGS84，未保存');
    }
    return {'latitude': lat.toDouble(), 'longitude': lon.toDouble()};
  }

  FavoritePage<T> parse<T>(
    Map<String, dynamic> result,
    int offset,
    T Function(Map<String, dynamic>) decode,
  ) {
    final items = result['items'],
        total = result['total'],
        more = result['has_more'];
    if (items is! List ||
        total is! int ||
        total < 0 ||
        more is! bool ||
        items.any((e) => e is! Map) ||
        (more && items.isEmpty)) {
      throw ApiFailure('收藏分页格式不符，请核对后端契约');
    }
    return FavoritePage(
      items.map((e) => decode(Map<String, dynamic>.from(e as Map))).toList(),
      total,
      more,
      offset + items.length,
      uncategorizedCount: result['uncategorized_count'] is int
          ? result['uncategorized_count']
          : 0,
    );
  }

  Future<FavoritePage<Favorite>> page({
    int offset = 0,
    String? folderId,
    String search = '',
  }) async => parse(
    await call(
      'GET',
      path,
      query: {
        'limit': '30',
        'offset': '$offset',
        'sort_by': 'created_at',
        'order': 'desc',
        'folder_id': ?folderId,
        if (search.trim().isNotEmpty) 'search': search.trim(),
      },
    ),
    offset,
    Favorite.fromJson,
  );
  Future<FavoritePage<FavoriteFolder>> folders({
    int offset = 0,
    String search = '',
  }) async => parse(
    await call(
      'GET',
      foldersPath,
      query: {
        'limit': '30',
        'offset': '$offset',
        'sort_by': 'name',
        'order': 'asc',
        if (search.trim().isNotEmpty) 'search': search.trim(),
      },
    ),
    offset,
    FavoriteFolder.fromJson,
  );
  Future<List<T>> collect<T>(
    Future<FavoritePage<T>> Function(int) fetch,
  ) async {
    final result = <T>[];
    var offset = 0;
    while (true) {
      final next = await fetch(offset);
      result.addAll(next.items);
      if (!next.hasMore) return result;
      offset = next.nextOffset;
      if (offset > 10000) throw ApiFailure('收藏分页过多，请使用搜索筛选');
    }
  }

  Future<List<Favorite>> list() => collect((offset) => page(offset: offset));
  Future<List<FavoriteFolder>> allFolders() =>
      collect((offset) => folders(offset: offset));
  Future<FavoriteFolder> getFolder(String id) async => FavoriteFolder.fromJson(
    await call('GET', '$foldersPath/${Uri.encodeComponent(id)}'),
  );
  Future<Favorite> get(String id) async =>
      Favorite.fromJson(await call('GET', '$path/${Uri.encodeComponent(id)}'));
  Future<Favorite> save(Map<String, dynamic> data, {String? id}) async {
    final validated = Favorite.validate(
      '${data['name'] ?? ''}',
      '${data['address'] ?? ''}',
      '${data['latitude'] ?? ''}',
      '${data['longitude'] ?? ''}',
    );
    if (data.containsKey('folder_id')) {
      validated['folder_id'] = data['folder_id'];
    }
    return Favorite.fromJson(
      await call(
        id == null ? 'POST' : 'PATCH',
        id == null ? path : '$path/${Uri.encodeComponent(id)}',
        body: validated,
      ),
    );
  }

  Future<Favorite> move(String id, String? folderId) async => Favorite.fromJson(
    await call(
      'PATCH',
      '$path/${Uri.encodeComponent(id)}',
      body: {'folder_id': folderId},
    ),
  );
  Future<FavoriteFolder> saveFolder(String name, {String? id}) async {
    final text = name.trim();
    if (text.isEmpty || text.runes.length > 64) throw ApiFailure('分类名称须为1～64字');
    return FavoriteFolder.fromJson(
      await call(
        id == null ? 'POST' : 'PATCH',
        id == null ? foldersPath : '$foldersPath/${Uri.encodeComponent(id)}',
        body: {'name': text},
      ),
    );
  }

  Future<void> deleteAt(String path, String id) async {
    try {
      final result = await call('DELETE', '$path/${Uri.encodeComponent(id)}');
      if (result['status'] != 'ok' || result['deleted_id'] != id) {
        throw ApiFailure('删除结果未确认，请刷新列表核对');
      }
    } on ApiFailure catch (e) {
      if (e.statusCode != 404) rethrow;
      // A repeated DELETE is already absent. Caller must refresh both lists.
    }
  }

  Future<void> delete(String id) => deleteAt(path, id);
  Future<void> deleteFolder(String id) => deleteAt(foldersPath, id);
}

import 'backend.dart';

class Favorite {
  const Favorite({
    required this.id,
    required this.name,
    required this.address,
    required this.latitude,
    required this.longitude,
    this.coordSystem = 'wgs84',
  });
  final String id, name, address, coordSystem;
  String get displayName => name.isEmpty ? address : name;
  final double latitude, longitude;
  static Map<String, dynamic> validate(
    String name,
    String address,
    String latitude,
    String longitude,
  ) {
    final lat = double.tryParse(latitude.trim());
    final lon = double.tryParse(longitude.trim());
    if (address.trim().isEmpty || address.trim().length > 500) {
      throw ApiFailure('请填写1～500字的地址');
    }
    if (name.trim().length > 100) {
      throw ApiFailure('名称不能超过100字');
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
        json['address'] is! String ||
        lat is! num ||
        lon is! num) {
      throw ApiFailure('收藏夹响应格式不符');
    }
    if (!lat.isFinite ||
        lat < -90 ||
        lat > 90 ||
        !lon.isFinite ||
        lon < -180 ||
        lon > 180 ||
        (json['address'] as String).trim().isEmpty) {
      throw ApiFailure('收藏夹坐标或地址无效');
    }
    return Favorite(
      id: '${json['id']}',
      name: json['name'] ?? '',
      address: json['address'],
      latitude: lat.toDouble(),
      longitude: lon.toDouble(),
      coordSystem: '${json['coord_system'] ?? 'wgs84'}',
    );
  }
  String get coordinates => '$latitude, $longitude';
}

class FavoritesApi {
  FavoritesApi(this.api);
  final BackendApi api;
  static const path = '/api/v1/favorites';
  Future<List<Favorite>> list() async {
    final records = <Favorite>[];
    var offset = 0;
    while (true) {
      final result = await api.call(
        'GET',
        path,
        query: {'limit': '100', 'offset': '$offset'},
      );
      final items = result['items'];
      final total = result['total'];
      if (items is! List ||
          total is! int ||
          total < 0 ||
          items.any((e) => e is! Map)) {
        throw ApiFailure('收藏夹列表格式不符，请核对后端契约');
      }
      records.addAll(
        items.map(
          (e) => Favorite.fromJson(Map<String, dynamic>.from(e as Map)),
        ),
      );
      offset += items.length;
      if (offset >= total) return records;
      if (items.isEmpty || offset > 10000) throw ApiFailure('收藏夹分页未完成，请重新加载');
    }
  }

  Future<Favorite> get(String id) async => Favorite.fromJson(
    await api.call('GET', '$path/${Uri.encodeComponent(id)}'),
  );

  Future<Favorite> save(Map<String, dynamic> data, {String? id}) async {
    final validated = Favorite.validate(
      '${data['name'] ?? ''}',
      '${data['address'] ?? ''}',
      '${data['latitude'] ?? ''}',
      '${data['longitude'] ?? ''}',
    );
    final result = await api.call(
      id == null ? 'POST' : 'PATCH',
      id == null ? path : '$path/${Uri.encodeComponent(id)}',
      body: validated,
    );
    return Favorite.fromJson(result);
  }

  Future<void> delete(String id) async {
    final result = await api.call('DELETE', '$path/${Uri.encodeComponent(id)}');
    if (result['status'] != 'ok' || result['deleted_id'] != id) {
      throw ApiFailure('删除结果未确认，请刷新收藏夹核对');
    }
  }
}

import 'dart:convert';
import 'dart:io';

/// Identity of one cache entry. Everything here is non-secret; the session
/// token is never part of a scope, a file name or a file body.
class LikedMusicScope {
  const LikedMusicScope({
    required this.origin,
    required this.account,
    required this.device,
  });
  final String origin, account, device;
  static const schema = 1;

  String get key => '$origin\n$account\n$device\nv$schema';
  @override
  bool operator ==(Object other) =>
      other is LikedMusicScope && other.key == key;
  @override
  int get hashCode => key.hashCode;

  Map<String, Object?> toJson() => {
    'origin': origin,
    'account': account,
    'device': device,
  };
}

/// Display metadata of the Owner favorite list as last published by the backend.
class LikedMusicSnapshot {
  LikedMusicSnapshot({
    required this.ownerKey,
    required this.playlistId,
    required this.revision,
    required this.etag,
    required this.syncedAt,
    required this.checkedAt,
    required this.tracks,
  });
  final String ownerKey, etag;
  final int playlistId, revision;
  final DateTime syncedAt, checkedAt;
  final List<Map<String, dynamic>> tracks;

  static const fields = [
    'song_id',
    'title',
    'artist',
    'album',
    'duration_ms',
    'cover_url',
    'fee',
    'playable',
  ];

  /// Only these white-listed fields ever reach disk.
  Map<String, Object?> toJson(LikedMusicScope scope) => {
    'schema': LikedMusicScope.schema,
    'scope': scope.toJson(),
    'owner_key': ownerKey,
    'playlist_id': playlistId,
    'revision': revision,
    'etag': etag,
    'synced_at': syncedAt.toUtc().toIso8601String(),
    'checked_at': checkedAt.toUtc().toIso8601String(),
    'tracks': [
      for (final t in tracks) {for (final f in fields) f: t[f]},
    ],
  };

  /// Returns null for anything that is not a perfectly valid entry of [scope].
  static LikedMusicSnapshot? fromJson(Object? value, LikedMusicScope scope) {
    try {
      if (value is! Map ||
          value['schema'] != LikedMusicScope.schema ||
          value['scope'] is! Map) {
        return null;
      }
      final s = value['scope'] as Map;
      if (s['origin'] != scope.origin ||
          s['account'] != scope.account ||
          s['device'] != scope.device) {
        return null;
      }
      final owner = value['owner_key'],
          etag = value['etag'],
          playlist = value['playlist_id'],
          revision = value['revision'],
          tracks = value['tracks'];
      final synced = DateTime.tryParse('${value['synced_at']}'),
          checked = DateTime.tryParse('${value['checked_at']}');
      if (owner is! String ||
          owner.isEmpty ||
          etag is! String ||
          playlist is! int ||
          playlist <= 0 ||
          revision is! int ||
          revision <= 0 ||
          tracks is! List ||
          tracks.length > LikedMusicStore.maxTracks ||
          synced == null ||
          checked == null) {
        return null;
      }
      final seen = <int>{};
      final rows = <Map<String, dynamic>>[];
      for (final raw in tracks) {
        if (raw is! Map) return null;
        final id = raw['song_id'];
        if (id is! int ||
            id <= 0 ||
            !seen.add(id) ||
            raw['title'] is! String ||
            raw['artist'] is! String ||
            raw['duration_ms'] is! int ||
            (raw['duration_ms'] as int) < 0 ||
            (raw['album'] != null && raw['album'] is! String) ||
            (raw['cover_url'] != null && raw['cover_url'] is! String) ||
            raw['fee'] is! int ||
            (raw['playable'] != null && raw['playable'] is! bool)) {
          return null;
        }
        rows.add({
          for (final f in fields) f: raw[f],
          'id': id,
          'source': 'netease',
        });
      }
      return LikedMusicSnapshot(
        ownerKey: owner,
        playlistId: playlist,
        revision: revision,
        etag: etag,
        syncedAt: synced,
        checkedAt: checked,
        tracks: rows,
      );
    } catch (_) {
      return null;
    }
  }
}

abstract class LikedMusicStore {
  static const maxTracks = 5000;
  static const maxBytes = 6 * 1024 * 1024;

  /// Process-wide default: real files only on the iPhone, memory elsewhere.
  static LikedMusicStore shared = Platform.isIOS
      ? FileLikedMusicStore.platformDefault()
      : MemoryLikedMusicStore();

  Future<LikedMusicSnapshot?> load(LikedMusicScope scope);
  Future<void> save(LikedMusicScope scope, LikedMusicSnapshot snapshot);
  Future<void> clear(LikedMusicScope scope);

  /// Logout / session loss / origin switch: nothing of any account is kept.
  Future<void> purgeAll();
}

class MemoryLikedMusicStore implements LikedMusicStore {
  final Map<String, String> _entries = {};
  @override
  Future<LikedMusicSnapshot?> load(LikedMusicScope scope) async {
    final raw = _entries[scope.key];
    if (raw == null) return null;
    final snap = LikedMusicSnapshot.fromJson(jsonDecode(raw), scope);
    if (snap == null) _entries.remove(scope.key);
    return snap;
  }

  @override
  Future<void> save(LikedMusicScope scope, LikedMusicSnapshot snapshot) async =>
      _entries[scope.key] = jsonEncode(snapshot.toJson(scope));
  @override
  Future<void> clear(LikedMusicScope scope) async => _entries.remove(scope.key);
  @override
  Future<void> purgeAll() async => _entries.clear();
}

/// One small JSON file per scope under the app's Caches directory
/// (excluded from iCloud backup, bounded in size, atomically replaced).
class FileLikedMusicStore implements LikedMusicStore {
  FileLikedMusicStore(this.directory);

  factory FileLikedMusicStore.platformDefault() {
    final home = Platform.environment['HOME'];
    final base = home == null || home.isEmpty
        ? Directory.systemTemp.path
        : '$home/Library/Caches';
    return FileLikedMusicStore(Directory('$base/myyaris_liked_music'));
  }

  final Directory directory;
  int _purgeEpoch = 0;

  /// Two FNV-1a 32 lanes: a stable, opaque file name. The exact scope is
  /// re-checked inside the file, so a collision can never cross accounts.
  static String _name(LikedMusicScope scope) {
    var a = 0x811c9dc5, b = 0x01000193;
    for (final byte in utf8.encode(scope.key)) {
      a = ((a ^ byte) * 0x01000193) & 0xFFFFFFFF;
      b = ((b ^ byte) * 0x811c9dc5) & 0xFFFFFFFF;
    }
    String hex(int v) => v.toRadixString(16).padLeft(8, '0');
    return 'liked_${hex(a)}${hex(b)}.json';
  }

  File _file(LikedMusicScope scope) =>
      File('${directory.path}/${_name(scope)}');

  @override
  Future<LikedMusicSnapshot?> load(LikedMusicScope scope) async {
    final file = _file(scope);
    try {
      if (!await file.exists()) return null;
      if (await file.length() > LikedMusicStore.maxBytes) {
        throw const FormatException('too large');
      }
      final snap = LikedMusicSnapshot.fromJson(
        jsonDecode(await file.readAsString()),
        scope,
      );
      if (snap == null) throw const FormatException('invalid');
      return snap;
    } catch (_) {
      // Corrupt or foreign entry: invalidate safely instead of trusting it.
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      return null;
    }
  }

  @override
  Future<void> save(LikedMusicScope scope, LikedMusicSnapshot snapshot) async {
    final epoch = _purgeEpoch;
    try {
      if (snapshot.tracks.length > LikedMusicStore.maxTracks) {
        await clear(scope);
        return;
      }
      final body = jsonEncode(snapshot.toJson(scope));
      if (utf8.encode(body).length > LikedMusicStore.maxBytes) {
        await clear(scope);
        return;
      }
      await directory.create(recursive: true);
      final file = _file(scope);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(body, flush: true);
      if (epoch != _purgeEpoch) {
        // Logout/purge happened while writing: a late write must leave nothing behind.
        await tmp.delete();
        return;
      }
      await tmp.rename(file.path);
    } catch (_) {
      // A cache write failure must never affect the visible list.
    }
  }

  @override
  Future<void> clear(LikedMusicScope scope) async {
    try {
      final file = _file(scope);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  @override
  Future<void> purgeAll() async {
    _purgeEpoch++;
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } catch (_) {}
  }
}

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'backend.dart';
import 'favorites.dart';

/// Server-backed browser. Identity and generation checks apply to every response.
class FavoriteLibrary extends ChangeNotifier {
  FavoriteLibrary(this.session) {
    identity = currentIdentity;
    session.addListener(accountChanged);
  }
  final BackendSession session;
  late String identity;
  String get currentIdentity => '${session.api.baseUrl}\n${session.api.token}';
  List<Favorite> items = [];
  List<FavoriteFolder> folders = [];
  String? folderId, error;
  String search = '';
  int total = 0,
      uncategorizedCount = 0,
      offset = 0,
      folderOffset = 0,
      epoch = 0;
  bool busy = false, moreBusy = false, folderMoreBusy = false, mutating = false;
  bool hasMore = false, foldersHaveMore = false, disposed = false;
  bool valid(int gen, String who) =>
      !disposed && gen == epoch && who == currentIdentity;
  void changed() {
    if (!disposed) notifyListeners();
  }

  void accountChanged() {
    if (currentIdentity == identity) return;
    identity = currentIdentity;
    epoch++;
    items = [];
    folders = [];
    folderId = null;
    search = '';
    error = null;
    total = uncategorizedCount = offset = folderOffset = 0;
    busy = moreBusy = folderMoreBusy = mutating = hasMore = foldersHaveMore =
        false;
    changed();
    if (session.userSignedIn && session.api.configured) unawaited(refresh());
  }

  Future<void> filter(String? id) async {
    folderId = id;
    await refresh();
  }

  Future<void> query(String text) async {
    search = text.trim();
    await refresh();
  }

  Future<void> refresh({String? notice}) async {
    final gen = ++epoch, who = identity, service = FavoritesApi(session.api);
    busy = true;
    moreBusy = folderMoreBusy = false;
    error = notice;
    // Clear stale filters/pages immediately, including late account responses.
    items = [];
    folders = [];
    hasMore = foldersHaveMore = false;
    offset = folderOffset = total = uncategorizedCount = 0;
    changed();
    try {
      final values = await Future.wait<Object>([
        service.page(folderId: folderId ?? 'uncategorized', search: search),
        service.folders(search: folderId == null ? search : ''),
        if (folderId != null && folderId != 'uncategorized')
          service.getFolder(folderId!),
      ]);
      if (!valid(gen, who)) return;
      final page = values[0] as FavoritePage<Favorite>;
      final groups = values[1] as FavoritePage<FavoriteFolder>;
      items = unique(page.items, (v) => v.id);
      total = page.total;
      offset = page.nextOffset;
      hasMore = page.hasMore;
      folders = unique([
        ...groups.items,
        if (values.length > 2) values[2] as FavoriteFolder,
      ], (v) => v.id);
      folderOffset = groups.nextOffset;
      foldersHaveMore = groups.hasMore;
      uncategorizedCount = groups.uncategorizedCount;
    } catch (e) {
      if (!valid(gen, who)) return;
      if (e is ApiFailure && e.statusCode == 404 && folderId != null) {
        folderId = null;
        await refresh(notice: favoriteError(e));
        return;
      }
      error = favoriteError(e);
    } finally {
      if (valid(gen, who)) {
        busy = false;
        changed();
      }
    }
  }

  static List<T> unique<T>(List<T> items, String Function(T) id) {
    final seen = <String>{};
    return items.where((v) => seen.add(id(v))).toList();
  }

  Future<void> more({bool groups = false}) async {
    if (busy ||
        mutating ||
        (groups ? folderMoreBusy || !foldersHaveMore : moreBusy || !hasMore)) {
      return;
    }
    final gen = epoch, who = identity, service = FavoritesApi(session.api);
    if (groups) {
      folderMoreBusy = true;
    } else {
      moreBusy = true;
    }
    changed();
    try {
      if (groups) {
        final page = await service.folders(
          offset: folderOffset,
          search: folderId == null ? search : '',
        );
        if (!valid(gen, who)) return;
        folders = unique([...folders, ...page.items], (v) => v.id);
        folderOffset = page.nextOffset;
        foldersHaveMore = page.hasMore;
        uncategorizedCount = page.uncategorizedCount;
      } else {
        final page = await service.page(
          offset: offset,
          folderId: folderId ?? 'uncategorized',
          search: search,
        );
        if (!valid(gen, who)) return;
        items = unique([...items, ...page.items], (v) => v.id);
        offset = page.nextOffset;
        hasMore = page.hasMore;
        total = page.total;
      }
    } catch (e) {
      if (!valid(gen, who)) return;
      if (e is ApiFailure && e.statusCode == 404) {
        folderId = null;
        await refresh(notice: favoriteError(e));
      } else {
        error = favoriteError(e);
      }
    } finally {
      if (valid(gen, who)) {
        if (groups) {
          folderMoreBusy = false;
        } else {
          moreBusy = false;
        }
        changed();
      }
    }
  }

  Future<void> removeFolder(FavoriteFolder folder) async =>
      mutate((service) async {
        await service.deleteFolder(folder.id);
        if (folderId == folder.id) folderId = 'uncategorized';
      });
  Future<void> remove(Favorite item) =>
      mutate((service) => service.delete(item.id));
  Future<void> move(Favorite item, String? id) => mutate((service) async {
    await service.move(item.id, id);
  });
  Future<void> mutate(Future<void> Function(FavoritesApi) action) async {
    if (mutating || busy) return;
    final who = identity;
    mutating = true;
    error = null;
    changed();
    try {
      await action(FavoritesApi(session.api));
      if (!disposed && who == currentIdentity) await refresh();
    } catch (e) {
      if (!disposed && who == currentIdentity) {
        if (e is ApiFailure && {404, 409}.contains(e.statusCode)) {
          await refresh(notice: favoriteError(e));
        } else {
          error = favoriteError(e);
        }
      }
    } finally {
      if (!disposed && who == currentIdentity) {
        mutating = false;
        changed();
      }
    }
  }

  @override
  void dispose() {
    disposed = true;
    epoch++;
    session.removeListener(accountChanged);
    super.dispose();
  }
}

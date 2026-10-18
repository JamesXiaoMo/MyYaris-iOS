import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'apple_map.dart';

class MapSearchPage extends StatefulWidget {
  const MapSearchPage({super.key, required this.controller});
  final AppleMapController controller;
  @override
  State<MapSearchPage> createState() => _MapSearchPageState();
}

class _MapSearchPageState extends State<MapSearchPage> {
  final query = TextEditingController();
  List<MapSelection>? results;
  String? error;
  bool busy = false;
  int epoch = 0;

  void changed(String _) {
    epoch++;
    unawaited(widget.controller.cancelSearch());
    setState(() {
      busy = false;
      results = null;
      error = null;
    });
  }

  Future<void> search() async {
    if (busy) return;
    final revision = ++epoch;
    setState(() {
      busy = true;
      error = null;
      results = null;
    });
    try {
      final value = await widget.controller.search(query.text);
      if (mounted && revision == epoch) setState(() => results = value);
    } catch (e) {
      if (mounted && revision == epoch) {
        setState(() {
          error = e is PlatformException
              ? e.message ?? '地图搜索失败，请重试'
              : e is FormatException
              ? e.message
              : '地图搜索暂不可用，请重试';
        });
      }
    } finally {
      if (mounted && revision == epoch) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    epoch++;
    unawaited(widget.controller.cancelSearch());
    query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('搜索地图地点')),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('map-search-query'),
                    controller: query,
                    maxLength: 100,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    onChanged: changed,
                    onSubmitted: (_) => search(),
                    decoration: const InputDecoration(
                      hintText: '地点或地址，例如麦当劳',
                      counterText: '',
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey('map-search-submit'),
                  tooltip: '搜索地点',
                  onPressed: busy ? null : search,
                  icon: const Icon(Icons.search),
                ),
              ],
            ),
          ),
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                error!,
                style: const TextStyle(color: Colors.orangeAccent),
              ),
            ),
          if (results?.isEmpty == true)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('未找到地点，可修改关键词或移动地图后重试'),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: results?.length ?? 0,
              itemBuilder: (context, index) {
                final point = results![index];
                return ListTile(
                  leading: const Icon(Icons.place_outlined),
                  title: Text(point.title),
                  subtitle: Text(point.address ?? ''),
                  onTap: () => Navigator.pop(context, point),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

import 'package:flutter/material.dart';
import 'backend.dart';
import 'playback_hub.dart';

/// The explicit output choice and the one pending transfer. Neither choice implies success.
class PlaybackTargetPicker extends StatelessWidget {
  const PlaybackTargetPicker({super.key, required this.session});
  final BackendSession session;

  Future<void> _act(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e is ApiFailure ? e.message : '播放操作失败，请重试')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: session,
    builder: (context, _) {
      final hub = session.hub, h = session.hub.handoff;
      return Column(
        children: [
          SegmentedButton<PlaybackTarget>(
            key: const ValueKey('playback-target'),
            segments: const [
              ButtonSegment(
                value: PlaybackTarget.phone,
                label: Text('本机'),
                icon: Icon(Icons.phone_iphone),
              ),
              ButtonSegment(
                value: PlaybackTarget.car,
                label: Text('车机'),
                icon: Icon(Icons.directions_car_outlined),
              ),
            ],
            selected: {hub.target},
            onSelectionChanged: hub.handoffActive || !hub.controlsReady
                ? null
                : (value) =>
                      _act(context, () => hub.selectTarget(value.single)),
          ),
          if (h != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Column(
                children: [
                  Text(
                    h.message,
                    key: const ValueKey('handoff-message'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13, color: Colors.white70),
                  ),
                  if (h.status == HandoffStatus.needsConfirmation ||
                      h.status == HandoffStatus.failed)
                    Wrap(
                      alignment: WrapAlignment.center,
                      children: [
                        TextButton(
                          key: const ValueKey('handoff-retry'),
                          onPressed: h.running
                              ? null
                              : () => _act(context, hub.retryHandoff),
                          child: const Text('重试确认'),
                        ),
                        TextButton(
                          key: const ValueKey('handoff-cancel'),
                          onPressed: () => _act(context, hub.cancelHandoff),
                          child: const Text('取消转移'),
                        ),
                      ],
                    )
                  else if (h.status == HandoffStatus.running)
                    const Padding(
                      padding: EdgeInsets.all(8),
                      child: LinearProgressIndicator(),
                    )
                  else
                    TextButton(
                      onPressed: hub.dismissHandoff,
                      child: const Text('知道了'),
                    ),
                ],
              ),
            ),
        ],
      );
    },
  );
}

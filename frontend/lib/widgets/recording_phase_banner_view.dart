import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/recording_phase.dart';
import '../providers/tracking_providers.dart';

// 収録の状態(開始準備中/収録中/停止処理中)を、収録タブに限らず常時上部に表示するバナー。
// idle時は何も表示しない。
class RecordingPhaseBannerView extends ConsumerWidget {
  const RecordingPhaseBannerView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = ref.watch(recordingPhaseProvider).value ?? RecordingPhase.idle;
    if (phase == RecordingPhase.idle) return const SizedBox.shrink();

    final (icon, message, color) = switch (phase) {
      RecordingPhase.starting => (Icons.hourglass_top, '収録の準備中です…', Colors.blueGrey),
      RecordingPhase.recording => (Icons.fiber_manual_record, '収録中です', Colors.green.shade700),
      RecordingPhase.stopping => (Icons.hourglass_bottom, '収録を停止処理中です…', Colors.blueGrey),
      RecordingPhase.idle => (Icons.info, '', Colors.grey)
    };

    return Material(
      color: color,
      child: InkWell(
        // stopping中(=保存/破棄が必要)のみタップで収録タブへ誘導し、保存/破棄画面を再表示する
        onTap: phase == RecordingPhase.stopping
          ? () => ref.read(trackingServiceProvider).resumePendingCompletion()
          : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(icon, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(message, style: const TextStyle(color: Colors.white, fontSize: 13))
              )
            ]
          )
        )
      )
    );
  }
}

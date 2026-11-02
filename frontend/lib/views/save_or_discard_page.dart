import 'dart:async';
import 'package:flutter/material.dart';
import '../models/move_method.dart';
import '../models/recording_session.dart';
import 'session_detail_view.dart';

// 収録停止後(通常の停止/強制停止/起動時リカバリ)に、保存/破棄を選ばせる全画面。
// セッション詳細画面をそのまま模した表示(セッション名は既定名、移動手段は未選択として空欄)の
// 下部に固定領域を置き、保存/破棄はどちらも確認ダイアログを挟んでから確定する。
// 閉じる(戻る)と保存/破棄は未確定のまま(RecordingPhase.stopping)残り、
// 収録タブのボタン/全タブ共通バナーからいつでも再表示できる。
// 表示は utils/save_or_discard_screen.dart の showSaveOrDiscardScreen() から行う
class SaveOrDiscardPage extends StatefulWidget {
  final RecordingSession session;
  final String? infoMessage;
  final Future<void> Function() onDiscard;
  final Future<void> Function(String sessionName, MoveMethod moveMethod) onSave;

  const SaveOrDiscardPage({
    super.key,
    required this.session,
    required this.onDiscard,
    required this.onSave,
    this.infoMessage,
  });

  @override
  State<SaveOrDiscardPage> createState() => _SaveOrDiscardPageState();
}

class _SaveOrDiscardPageState extends State<SaveOrDiscardPage> {
  // 移動手段の初期値(将来、オプションで「よく使う移動手段」を設定できるようにする想定)
  static const MoveMethod _initialMoveMethod = MoveMethod.walk;

  // 確定後の連打・多重確定を防ぐ
  bool _isCompleting = false;

  Future<void> _handleDiscardPressed() async {
    if (_isCompleting) return;

    final confirmed = await _showDiscardConfirmDialog(context);
    if (confirmed != true || !mounted) return;

    _complete(widget.onDiscard);
  }

  Future<void> _handleSavePressed() async {
    if (_isCompleting) return;

    final result = await _showSaveConfirmDialog(
      context,
      sessionStartedAt: widget.session.startedAt,
      initialMoveMethod: _initialMoveMethod,
    );
    if (result == null || !mounted) return;

    _complete(() => widget.onSave(result.sessionName, result.moveMethod));
  }

  void _complete(Future<void> Function() onComplete) {
    setState(() => _isCompleting = true);

    // TrackingService.completeSession()は、保存/破棄のDB反映・リモート同期を待たずに先に
    // 次の状態へ遷移する。起動時リカバリのキューに続きがある場合は、この呼び出しの中で
    // (最初のawaitより前に)次のセッションの画面がpushReplacementでこの画面を差し替えるため、
    // その場合はこちらからpopしない(差し替え済みの画面を閉じてしまわないよう isCurrent で判定)
    final completion = onComplete();
    if (mounted && (ModalRoute.of(context)?.isCurrent ?? false)) {
      Navigator.of(context).pop();
    }
    unawaited(completion);
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: '後で決める',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: SessionDetailTitle(
          name: defaultSessionName(session.startedAt, _initialMoveMethod),
          moveMethodLabel: null,
          startedAt: session.startedAt,
        ),
      ),
      body: SessionDetailBody(
        sessionId: session.sessionId,
        totalDistance: session.totalDistance,
        durationSeconds: session.elapsedSeconds,
        elevationGain: session.elevationGain,
        maxAltitude: session.maxAltitude,
        minAltitude: session.minAltitude,
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(top: BorderSide(color: Colors.grey.shade300)),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.infoMessage != null) ...[
                Text(
                  widget.infoMessage!,
                  style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
              ],
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                        side: const BorderSide(color: Colors.red),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: _isCompleting ? null : _handleDiscardPressed,
                      child: const Text('破棄', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: _isCompleting ? null : _handleSavePressed,
                      child: const Text('保存', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// 名前欄を空欄のまま保存した場合に使う既定のセッション名
String defaultSessionName(DateTime startedAt, MoveMethod moveMethod) {
  final timeStr = '${startedAt.month}/${startedAt.day} '
    '${startedAt.hour}:${startedAt.minute.toString().padLeft(2, '0')}:${startedAt.second.toString().padLeft(2, '0')}';
  return '$timeStrの${moveMethod.label}アクティビティ';
}

Future<bool?> _showDiscardConfirmDialog(BuildContext context) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return AlertDialog(
        title: const Text('セッション破棄'),
        content: const Text('このセッションを破棄しますか?\n破棄したセッションは元に戻せません。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('破棄'),
          ),
        ],
      );
    },
  );
}

typedef _SaveInput = ({String sessionName, MoveMethod moveMethod});

// 保存確認ダイアログ。セッション名・移動手段を入力させる(キャンセルでnull)。
// 名前欄は既定名をヒント文字として表示し、空欄のまま保存された場合はその既定名で保存する
Future<_SaveInput?> _showSaveConfirmDialog(
  BuildContext context, {
  required DateTime sessionStartedAt,
  required MoveMethod initialMoveMethod,
}) {
  final nameController = TextEditingController();
  MoveMethod selectedMethod = initialMoveMethod;

  return showDialog<_SaveInput>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: const Text('セッション保存'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: InputDecoration(
                    labelText: 'セッション名',
                    // 既定名は移動手段で変わるため、選択に合わせてヒント文字も追従させる
                    hintText: defaultSessionName(sessionStartedAt, selectedMethod),
                    // 既定名は長く1行だと省略されてしまうため、折り返して全体を見せる
                    hintMaxLines: 2,
                    floatingLabelBehavior: FloatingLabelBehavior.always,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<MoveMethod>(
                  initialValue: selectedMethod,
                  decoration: const InputDecoration(
                    labelText: '移動手段',
                    border: OutlineInputBorder(),
                  ),
                  items: MoveMethod.values.map((method) {
                    return DropdownMenuItem(
                      value: method,
                      child: Text(method.label),
                    );
                  }).toList(),
                  onChanged: (val) {
                    if (val != null) setState(() => selectedMethod = val);
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('キャンセル'),
              ),
              ElevatedButton(
                onPressed: () {
                  final inputName = nameController.text.trim();
                  Navigator.of(dialogContext).pop((
                    sessionName: inputName.isEmpty
                      ? defaultSessionName(sessionStartedAt, selectedMethod)
                      : inputName,
                    moveMethod: selectedMethod,
                  ));
                },
                child: const Text('保存'),
              ),
            ],
          );
        },
      );
    },
  );
}

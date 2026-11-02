import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/app_database.dart';
import '../models/move_method.dart';
import '../providers/tracking_providers.dart';
import 'session_detail_view.dart';


class SavedSessionsView extends ConsumerStatefulWidget {
  const SavedSessionsView({super.key});

  @override
  ConsumerState<SavedSessionsView> createState() => _SavedSessionsViewState();
}

class _SavedSessionsViewState extends ConsumerState<SavedSessionsView> {
  bool _isEditMode = false;

  Future<bool> _confirmDelete(Session session) async {
    return await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('セッションを削除しますか?'),
        content: Text('「${session.name}」を削除します。この操作は取り消せません。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('削除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    ) ?? false;
  }

  Future<void> _confirmAndDelete(Session session) async {
    final service = ref.read(trackingServiceProvider);
    if (await _confirmDelete(session)) {
      await service.deleteSession(session);
    }
  }

  Future<void> _showEditDialog(Session session) async {
    final nameController = TextEditingController(text: session.name);
    MoveMethod selectedMethod = session.moveMethod;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('セッションを編集'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      labelText: 'セッション名',
                      border: OutlineInputBorder()
                    )
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<MoveMethod>(
                    initialValue: selectedMethod,
                    decoration: const InputDecoration(
                      labelText: '移動手段',
                      border: OutlineInputBorder()
                    ),
                    items: MoveMethod.values.map((method) {
                      return DropdownMenuItem(
                        value: method,
                        child: Text(method.label)
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) setState(() => selectedMethod = val);
                    }
                  )
                ]
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('キャンセル'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    Navigator.of(dialogContext).pop();
                    final trimmedName = nameController.text.trim();
                    final service = ref.read(trackingServiceProvider);
                    await service.updateSessionInfo(
                      session: session,
                      sessionName: trimmedName.isEmpty ? session.name! : trimmedName,
                      moveMethod: selectedMethod,
                    );
                  },
                  child: const Text('保存'),
                )
              ]
            );
          }
        );
      }
    );
  }

  @override
  Widget build(BuildContext context) {
    // provider settings
    final completedSessions = ref.watch(sessionsStreamProvider);
    final service = ref.read(trackingServiceProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('保存済セッション一覧'),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: () => setState(() => _isEditMode = !_isEditMode),
            child: Text(_isEditMode ? '完了' : '編集', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
      body: completedSessions.when(
        loading: () => const SizedBox(
          height: 200,
          child: Center(child: CircularProgressIndicator())
        ),
        error: (err, stack) => Center(child: Text('エラーが発生しました\n$err')),
        data: (data) => SingleChildScrollView(
          padding: EdgeInsets.all(16),
          child: ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: data.length,
            itemBuilder: (context, index) {
              final session = data[index];
              return Dismissible(
                key: ValueKey(session.id),
                direction: DismissDirection.endToStart,
                background: Container(
                  color: Colors.redAccent,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: const Icon(Icons.delete, color: Colors.white),
                ),
                confirmDismiss: (direction) => _confirmDelete(session),
                onDismissed: (direction) => service.deleteSession(session),
                child: ListTile(
                  title: Text(session.name!),
                  subtitle: Text(session.startedAt.toString()),
                  leading: IconButton(
                    icon: Icon(session.isFavorite ? Icons.star_outlined: Icons.star_border_outlined),
                    onPressed: () => service.toggleFavorite(session)
                  ),
                  trailing: _isEditMode
                    ? IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                        onPressed: () => _confirmAndDelete(session),
                      )
                    : const Icon(Icons.arrow_right),
                  onTap: _isEditMode ? () => _showEditDialog(session) : () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (context) => SessionDetailView(session: session))
                    );
                  }
                ),
              );
            }
          )
        )
      )
    );
  }
}

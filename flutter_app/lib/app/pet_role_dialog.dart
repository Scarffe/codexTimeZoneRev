import 'dart:io';
import 'dart:async';

import '../services/desktop_monitor.dart';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../state/account_usage_controller.dart';

class PetRoleDialog extends StatefulWidget {
  const PetRoleDialog({super.key, required this.controller});
  final AccountUsageController controller;
  @override
  State<PetRoleDialog> createState() => _PetRoleDialogState();
}

class _PetRoleDialogState extends State<PetRoleDialog> {
  void _editorVisible(bool visible) {
    unawaited(
      DesktopMonitor.channel
          .invokeMethod<void>('roleEditor', visible)
          .catchError((Object _) {}),
    );
  }

  @override
  void initState() {
    super.initState();
    _editorVisible(true);
  }

  @override
  void dispose() {
    _editorVisible(false);
    super.dispose();
  }

  String name = '', author = '', outfit = '', source = '';
  String? message;
  bool importing = false;
  Future<void> _import() async {
    setState(() {
      importing = true;
      message = null;
    });
    try {
      if (name.trim().isEmpty) throw const FormatException('请先填写角色名称');
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(label: '透明 PNG', extensions: ['png']),
        ],
      );
      if (file == null) return;
      if (await file.length() > 8 * 1024 * 1024) {
        throw const FormatException('图片不能超过 8 MiB');
      }
      await widget.controller.roles.importPng(
        await file.readAsBytes(),
        name: name,
        author: author,
        outfit: outfit,
        source: source,
      );
      if (mounted) setState(() => message = '已导入并选择；仅改变外观，监控仍为 Codex。');
    } catch (e) {
      if (mounted) {
        setState(
          () => message = e is FormatException
              ? e.message.toString()
              : '导入失败，请检查 PNG 文件与目录权限。',
        );
      }
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  Widget _field(String label, ValueChanged<String> changed) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: FTextField(
      label: Text(label),
      control: FTextFieldControl.managed(onChange: (v) => changed(v.text)),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final library = widget.controller.roles;
    return Center(
      child: SizedBox(
        width: 500,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .85,
          ),
          child: FCard(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: ListenableBuilder(
                listenable: library,
                builder: (context, _) => SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('角色与本地立绘'),
                      const SizedBox(height: 12),
                      const Text('角色仅改变桌宠外观，不切换模型或监控账号。边缘形态保留简洁额度标记。'),
                      const SizedBox(height: 12),
                      FSelect<String>(
                        key: const ValueKey('pet-role-select'),
                        items: {
                          '默认鲸鱼': '',
                          for (final role in library.roles)
                            '${role.name} · ${role.id.substring(0, 6)}':
                                role.id,
                        },
                        control: FSelectControl.lifted(
                          value: library.current?.id ?? '',
                          onChange: (v) {
                            if (importing) return;
                            if (v != null) {
                              library.select(v.isEmpty ? null : v);
                            }
                          },
                        ),
                      ),
                      if (library.current case final role?) ...[
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 180,
                          child: Image.file(
                            File(library.imagePath),
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) =>
                                const Text('图片不可用，桌宠回退为鲸鱼'),
                          ),
                        ),
                        Text('作者：${role.author.isEmpty ? '未填写' : role.author}'),
                        Text('服装：${role.outfit.isEmpty ? '未填写' : role.outfit}'),
                        Text(
                          '来源 / 使用说明：${role.source.isEmpty ? '未填写' : role.source}',
                        ),
                      ],
                      const SizedBox(height: 16),
                      const Text('导入新角色'),
                      const SizedBox(height: 8),
                      _field('角色名称（必填）', (v) => name = v),
                      _field('作者', (v) => author = v),
                      _field('服装说明', (v) => outfit = v),
                      _field('来源链接 / 使用说明', (v) => source = v),
                      const Text(
                        '导入你有权使用的透明 PNG，最大 8 MiB、2048×2048。文件复制到本程序目录，不上传；本版不附带第三方立绘。',
                      ),
                      const SizedBox(height: 12),
                      FButton(
                        key: const ValueKey('import-pet-role'),
                        onPress: importing ? null : _import,
                        child: Text(importing ? '正在导入…' : '选择 PNG 并导入'),
                      ),
                      if (message != null) Text(message!),
                      if (library.error != null) Text(library.error!),
                      const SizedBox(height: 12),
                      FButton(
                        variant: FButtonVariant.outline,
                        onPress: () async {
                          await library.saved;
                          if (context.mounted) Navigator.of(context).pop();
                        },
                        child: const Text('完成'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

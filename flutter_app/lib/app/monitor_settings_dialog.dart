import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../state/account_usage_controller.dart';
import 'pet_role_dialog.dart';

class MonitorSettingsDialog extends StatelessWidget {
  const MonitorSettingsDialog({super.key, required this.controller});
  final AccountUsageController controller;
  @override
  Widget build(BuildContext context) => Center(
    child: SizedBox(
      width: 430,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .85,
        ),
        child: FCard(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: ListenableBuilder(
              listenable: controller,
              builder: (context, _) => SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('监控与提醒设置'),
                    const SizedBox(height: 12),
                    const Text('修改立即生效，并保存到当前程序文件夹。'),
                    const SizedBox(height: 12),
                    const Text('自动刷新间隔'),
                    FSelect<int>(
                      items: const {
                        '1 分钟': 60,
                        '2 分钟': 120,
                        '5 分钟': 300,
                        '10 分钟': 600,
                      },
                      control: FSelectControl.lifted(
                        value: controller.interval.inSeconds,
                        onChange: (v) {
                          if (v != null) {
                            controller.setInterval(Duration(seconds: v));
                          }
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text('低额度阈值（10% 时再提醒一次）'),
                    FSelect<int>(
                      key: const ValueKey('alert-threshold'),
                      items: const {'10%': 10, '20%': 20, '30%': 30},
                      control: FSelectControl.lifted(
                        value: controller.alertThreshold,
                        onChange: (v) =>
                            controller.configureAlerts(threshold: v),
                      ),
                    ),
                    const SizedBox(height: 12),
                    FButton(
                      key: const ValueKey('alerts-toggle'),
                      variant: FButtonVariant.outline,
                      onPress: () => controller.configureAlerts(
                        enabled: !controller.alertsEnabled,
                      ),
                      child: Text(
                        '低额度提醒：${controller.alertsEnabled ? '开启' : '关闭'}',
                      ),
                    ),
                    const SizedBox(height: 12),
                    FButton(
                      key: const ValueKey('reduced-motion'),
                      variant: FButtonVariant.outline,
                      onPress: () => controller.setReducedMotion(
                        !controller.reducedMotion,
                      ),
                      child: Text(
                        '减少动画：${controller.reducedMotion ? '开启' : '关闭'}',
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text('开启后保留静态状态与额度，不播放浮动或气泡动画。'),
                    const SizedBox(height: 12),
                    FButton(
                      key: const ValueKey('pet-roles'),
                      variant: FButtonVariant.outline,
                      onPress: () => showGeneralDialog<void>(
                        context: context,
                        barrierDismissible: true,
                        barrierLabel: '关闭角色面板',
                        pageBuilder: (_, _, _) =>
                            PetRoleDialog(controller: controller),
                      ),
                      child: const Text('角色与本地立绘'),
                    ),
                    const SizedBox(height: 12),
                    const Text('桌宠形态（记住最后一次选择）'),
                    FSelect<int>(
                      items: const {'边缘': 0, '紧凑': 1, '展开': 2},
                      control: FSelectControl.lifted(
                        value: controller.petMode,
                        onChange: (v) => controller.configurePet(mode: v),
                      ),
                    ),
                    const SizedBox(height: 12),
                    FButton(
                      variant: FButtonVariant.outline,
                      onPress: () => controller.configurePet(
                        visible: !controller.petVisible,
                      ),
                      child: Text('桌宠：${controller.petVisible ? '显示' : '隐藏'}'),
                    ),
                    const SizedBox(height: 12),
                    FButton(
                      key: const ValueKey('mute-cycle'),
                      variant: FButtonVariant.outline,
                      onPress:
                          !controller.canMuteCurrentCycle ||
                              controller.cycleMuted
                          ? null
                          : controller.muteCurrentCycle,
                      child: Text(
                        controller.cycleMuted ? '本轮已静音，重置后恢复' : '本轮额度周期不再提醒',
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text('按当前账号各额度窗口分别静音，重置后恢复；重启仍有效。查询失败或缓存过期时不弹低额度气泡。'),
                    if (controller.preferencesError != null)
                      Text(controller.preferencesError!),
                    const SizedBox(height: 12),
                    FButton(
                      onPress: () async {
                        await controller.settingsSaved;
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

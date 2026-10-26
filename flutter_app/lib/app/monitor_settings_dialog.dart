import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../state/account_usage_controller.dart';
import '../l10n/app_copy.dart';

class MonitorSettingsDialog extends StatelessWidget {
  const MonitorSettingsDialog({super.key, required this.controller});
  final AccountUsageController controller;
  @override
  Widget build(BuildContext context) {
    final copy = AppCopy.of(context);
    Widget buttonText(String value) => Flexible(child: Text(value));
    String state(bool value) =>
        copy.text(value ? 'monitor.settings.on' : 'monitor.settings.off');
    return Center(
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
                      Text(copy.text('monitor.settings.title')),
                      const SizedBox(height: 12),
                      Text(
                        controller.offlineTrial
                            ? copy.text('monitor.settings.offline')
                            : copy.text('monitor.settings.saved'),
                      ),
                      const SizedBox(height: 12),
                      FButton(
                        key: const ValueKey('reduced-motion'),
                        variant: FButtonVariant.outline,
                        onPress: () => controller.setReducedMotion(
                          !controller.reducedMotion,
                        ),
                        child: buttonText(
                          copy.text(
                            'monitor.settings.motion',
                            args: {'state': state(controller.reducedMotion)},
                          ),
                        ),
                      ),
                      Text(copy.text('monitor.settings.motionDescription')),
                      const SizedBox(height: 12),
                      Text(copy.text('monitor.settings.interval')),
                      FSelect<int>(
                        items: {
                          for (final minutes in [1, 2, 5, 10])
                            copy.text(
                              minutes == 1
                                  ? 'monitor.settings.minute'
                                  : 'monitor.settings.minutes',
                              args: {'count': minutes},
                            ): minutes * 60,
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
                      Text(copy.text('monitor.settings.threshold')),
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
                        child: buttonText(
                          copy.text(
                            'monitor.settings.quotaAlerts',
                            args: {'state': state(controller.alertsEnabled)},
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      FButton(
                        key: const ValueKey('session-alerts-toggle'),
                        variant: FButtonVariant.outline,
                        onPress: () => controller.configureSessionAlerts(
                          enabled: !controller.sessionAlertsEnabled,
                        ),
                        child: buttonText(
                          copy.text(
                            'monitor.settings.turnAlerts',
                            args: {
                              'state': state(controller.sessionAlertsEnabled),
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      FButton(
                        key: const ValueKey('session-alerts-mute'),
                        variant: FButtonVariant.outline,
                        onPress: !controller.sessionAlertsEnabled
                            ? null
                            : () => controller.configureSessionAlerts(
                                mute: !controller.sessionMuted,
                                unmute: controller.sessionMuted,
                              ),
                        child: buttonText(
                          controller.sessionMuted
                              ? copy.text('monitor.settings.unmuteTurns')
                              : copy.text('monitor.settings.muteTurns'),
                        ),
                      ),
                      Text(copy.text('monitor.settings.turnDescription')),
                      const SizedBox(height: 12),
                      FButton(
                        key: const ValueKey('mute-cycle'),
                        variant: FButtonVariant.outline,
                        onPress:
                            !controller.canMuteCurrentCycle ||
                                controller.cycleMuted
                            ? null
                            : controller.muteCurrentCycle,
                        child: buttonText(
                          controller.cycleMuted
                              ? copy.text('monitor.settings.cycleMuted')
                              : copy.text('monitor.settings.muteCycle'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(copy.text('monitor.settings.cycleDescription')),
                      if (controller.preferencesError != null)
                        Text(
                          _preferencesError(copy, controller.preferencesError!),
                        ),
                      const SizedBox(height: 12),
                      FButton(
                        onPress: () async {
                          await controller.settingsSaved;
                          if (context.mounted) Navigator.of(context).pop();
                        },
                        child: buttonText(copy.text('monitor.settings.done')),
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

String _preferencesError(AppCopy copy, String value) => switch (value) {
  '监控设置读取失败，已使用默认值；原文件未改动。' => copy.text('monitor.settings.loadFailed'),
  '监控偏好已生效，但保存失败；请检查文件夹写入权限。' => copy.text('monitor.settings.saveFailed'),
  _ => value,
};

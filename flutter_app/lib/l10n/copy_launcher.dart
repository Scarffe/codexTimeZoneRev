import 'copy_types.dart';

const launcherMessages = <String, AppMessage>{
  'launcher.settings': (zh: '启动设置', en: 'Launch settings'),
  'launcher.settingsDescription': (
    zh: '新进程使用此时区，系统时区保持不变。',
    en: 'New processes use this time zone. The system time zone stays unchanged.',
  ),
  'launcher.mode': (zh: '设置方式', en: 'Time zone mode'),
  'launcher.zone': (zh: '地区时区', en: 'Regional time zone'),
  'launcher.offset': (zh: '固定 UTC 偏移', en: 'Fixed UTC offset'),
  'launcher.zoneDescription': (
    zh: '搜索城市或时区；自动遵循当地夏令时。',
    en: 'Search for a city or time zone. Local daylight saving time applies automatically.',
  ),
  'launcher.offsetDescription': (
    zh: '不随夏令时变化；半小时地区请使用地区时区。',
    en: 'Unaffected by daylight saving time. Use a regional time zone for half-hour offsets.',
  ),
  'launcher.chooseClient': (zh: '选择客户端', en: 'Choose client'),
  'launcher.noClient': (
    zh: '未找到客户端，请选择 Codex 程序。',
    en: 'Client not found. Choose the Codex application.',
  ),
  'launcher.currentPath': (zh: '当前路径：{path}', en: 'Current path: {path}'),
  'launcher.skinCompatible': (
    zh: 'Dream Skin 兼容启动',
    en: 'Launch with Dream Skin support',
  ),
  'launcher.skinDescription': (
    zh: '保存后，在下次启动时应用皮肤。',
    en: 'Save to apply the skin on the next launch.',
  ),
  'launcher.openSkin': (zh: '打开 Dream Skin', en: 'Open Dream Skin'),
  'launcher.reapplySkin': (zh: '重新注入皮肤', en: 'Reapply skin'),
  'launcher.reapplyDescription': (
    zh: '重新注入仅适用于兼容启动的客户端；保持当前进程与时区。',
    en: 'Reapplying requires a client launched with skin support. The current process and time zone are retained.',
  ),
  'launcher.client': (zh: '客户端与皮肤', en: 'Client and skin'),
  'launcher.clientDescription': (
    zh: '选择程序并配置下次启动。',
    en: 'Choose an application and configure the next launch.',
  ),
  'launcher.repairDescription': (
    zh: '待修复版本：{package}\n仅修复当前版本的启动权限，保留原权限备份；完成后自动重试启动。需要 Windows 管理员确认。',
    en: 'Version to repair: {package}\nRepair launch permissions for this version and keep the original permission backup, then retry launch automatically. Windows administrator approval is required.',
  ),
  'launcher.launchLog': (zh: '启动日志：{path}', en: 'Launch log: {path}'),
  'launcher.repairing': (zh: '正在修复…', en: 'Repairing…'),
  'launcher.repair': (zh: '一键修复并重试', en: 'Repair and retry'),
  'launcher.launching': (zh: '正在启动…', en: 'Launching…'),
  'launcher.launch': (zh: '保存并启动', en: 'Save and launch'),
  'launcher.save': (zh: '保存设置', en: 'Save settings'),
  'launcher.shortcut': (zh: '创建快捷方式', en: 'Create shortcut'),
  'launcher.dirty': (zh: '未保存修改', en: 'Unsaved changes'),
  'launcher.preview': (zh: '演示模式', en: 'Preview mode'),
  'launcher.reload': (zh: '重新读取设置', en: 'Reload settings'),
  'launcher.network': (zh: '网络位置参考', en: 'Network location reference'),
  'launcher.networkCached': (
    zh: '上次查询结果 · 更新中',
    en: 'Previous query results · Updating',
  ),
  'launcher.networkDescription': (
    zh: '国内 / 国际独立查询 · 应用时区仅写入草稿',
    en: 'Separate domestic and international queries · Applying a time zone updates the draft only',
  ),
  'launcher.querying': (zh: '正在查询…', en: 'Querying…'),
  'launcher.refreshNetwork': (zh: '刷新网络信息', en: 'Refresh network info'),
  'launcher.domestic': (zh: '国内线路', en: 'Domestic route'),
  'launcher.international': (zh: '国际线路', en: 'International route'),
  'launcher.exitFirst': (
    zh: '启动前请完全退出正在运行的 Codex。本工具不会更改系统全局时区。',
    en: 'Fully quit Codex before launching. This tool leaves the system time zone unchanged.',
  ),
  'launcher.path': (zh: '客户端路径', en: 'Client path'),
  'launcher.pathHint': (
    zh: '留空时自动查找 Codex',
    en: 'Leave blank to find Codex automatically',
  ),
  'launcher.clock': (zh: '时间预览', en: 'Time preview'),
  'launcher.fixedOffset': (zh: '固定偏移', en: 'Fixed offset'),
  'launcher.validZone': (zh: '请选择有效时区', en: 'Choose a valid time zone'),
  'launcher.invalidZone': (zh: '无效时区', en: 'Invalid time zone'),
  'launcher.localClock': (zh: '本地时间 · {zone}', en: 'Local time · {zone}'),
  'launcher.copyIp': (zh: '复制 IP', en: 'Copy IP'),
  'launcher.copied': (zh: '已复制', en: 'Copied'),
  'launcher.copyFailed': (zh: '复制失败', en: 'Copy failed'),
  'launcher.queryLocation': (
    zh: '正在查询公网 IP 与位置…',
    en: 'Querying public IP and location…',
  ),
  'launcher.noNetwork': (zh: '暂无网络信息', en: 'No network info'),
  'launcher.applyZone': (zh: '应用识别时区', en: 'Apply detected time zone'),
  'launcher.unsupportedZone': (zh: '暂不支持此时区', en: 'Time zone not supported'),
  'launcher.status.loading': (
    zh: '正在读取设置并查找 Codex…',
    en: 'Reading settings and locating Codex…',
  ),
  'launcher.status.preview': (
    zh: '演示模式：系统操作已禁用。',
    en: 'Preview mode: system operations are disabled.',
  ),
  'launcher.status.chooseClient': (
    zh: '设置已读取，请选择 Codex 客户端。',
    en: 'Settings loaded. Choose the Codex client.',
  ),
  'launcher.status.detected': (
    zh: '设置已读取，客户端已自动找到。',
    en: 'Settings loaded. The client was found automatically.',
  ),
  'launcher.status.loadFailed': (
    zh: '读取设置失败，请重试。',
    en: 'Could not read settings. Try again.',
  ),
  'launcher.status.pathUpdated': (
    zh: '客户端路径已更新，尚未保存。',
    en: 'Client path updated. Changes are unsaved.',
  ),
  'launcher.status.pathFailed': (
    zh: '无法使用所选客户端路径。',
    en: 'The selected client path cannot be used.',
  ),
  'launcher.status.invalidZone': (
    zh: '时区设置无效。',
    en: 'Invalid time zone settings.',
  ),
  'launcher.status.noClient': (
    zh: '未找到 Codex，请选择程序路径。',
    en: 'Codex was not found. Choose the application path.',
  ),
  'launcher.status.saving': (zh: '正在保存设置…', en: 'Saving settings…'),
  'launcher.status.launching': (
    zh: '正在识别当前版本、检查身份并启动 Codex…',
    en: 'Detecting the current version, checking identity and launching Codex…',
  ),
  'launcher.status.repairing': (
    zh: '正在检查并修复，请确认 Windows 管理员提示…',
    en: 'Checking and repairing. Confirm the Windows administrator prompt…',
  ),
  'launcher.status.shortcut': (
    zh: '正在创建桌面快捷方式…',
    en: 'Creating desktop shortcut…',
  ),
  'launcher.status.openSkin': (
    zh: '正在打开 Dream Skin…',
    en: 'Opening Dream Skin…',
  ),
  'launcher.status.reapplySkin': (
    zh: '正在重新注入 Dream Skin…',
    en: 'Reapplying Dream Skin…',
  ),
  'launcher.status.cancelled': (
    zh: '已取消修复，未启动客户端。',
    en: 'Repair cancelled. The client was not launched.',
  ),
  'launcher.status.retrying': (
    zh: '身份检查通过，正在按所选时区重试启动…',
    en: 'Identity check passed. Retrying launch with the selected time zone…',
  ),
  'launcher.status.repairRequired': (
    zh: '当前客户端需要修复后才能启动。',
    en: 'The current client needs repair before it can launch.',
  ),
  'launcher.status.repairIdentity': (
    zh: '检测到当前 Codex 的包身份异常，已停止启动。可点击“一键修复并重试”，确认 Windows 管理员提示后继续。',
    en: 'The Codex package identity is invalid, so launch was stopped. Choose “Repair and retry” and confirm the Windows administrator prompt to continue.',
  ),
  'launcher.status.complete': (zh: '操作已完成。', en: 'Operation completed.'),
  'launcher.status.failed': (zh: '操作失败。', en: 'Operation failed.'),
  'launcher.status.validateZone': (
    zh: '请选择支持的地区时区。',
    en: 'Choose a supported regional time zone.',
  ),
  'launcher.status.validateOffset': (
    zh: '请选择 −12 至 +14 小时的 UTC 偏移。',
    en: 'Choose a UTC offset between −12 and +14 hours.',
  ),
  'launcher.status.copyFailed': (
    zh: '无法复制 IP。',
    en: 'Could not copy the IP address.',
  ),
  'launcher.status.zoneApplied': (
    zh: '已选择 {zone}，保存并启动后生效。',
    en: '{zone} selected. Save and launch to apply it.',
  ),
  'launcher.status.savedPath': (
    zh: '设置已保存到 {path}',
    en: 'Settings saved to {path}',
  ),
  'launcher.status.networkCacheFailed': (
    zh: '网络信息已更新，但无法保存缓存。',
    en: 'Network info updated, but the cache could not be saved.',
  ),
  'launcher.status.skinStarted': (
    zh: 'Dream Skin 已启动。',
    en: 'Dream Skin started.',
  ),
  'launcher.status.skinMacStarted': (
    zh: 'Dream Skin（macOS）已启动。',
    en: 'Dream Skin (macOS) started.',
  ),
  'launcher.status.skinApplied': (
    zh: 'Dream Skin 已完成皮肤应用和验证。',
    en: 'Dream Skin applied and verified the skin.',
  ),
  'launcher.status.skinRetained': (
    zh: 'Dream Skin 已完成皮肤应用和验证。当前客户端的时区保持不变。',
    en: 'Dream Skin applied and verified the skin. The current client time zone is unchanged.',
  ),
  'launcher.status.processStarted': (
    zh: 'Codex 进程已按所选时区启动；尚未确认客户端窗口就绪。',
    en: 'The Codex process started with the selected time zone. Client window readiness has not been confirmed.',
  ),
  'launcher.status.processSkinStarted': (
    zh: 'Codex 进程已按所选时区启动，Dream Skin 已应用；尚未确认客户端窗口就绪。',
    en: 'The Codex process started with the selected time zone and Dream Skin applied. Client window readiness has not been confirmed.',
  ),
  'launcher.status.macStarted': (
    zh: 'Codex 已按所选时区启动（Dream Skin 兼容启动未开启）。',
    en: 'Codex launched with the selected time zone (Dream Skin support is off).',
  ),
  'launcher.status.macSkinStarted': (
    zh: 'Codex 已按所选时区启动，Dream Skin 已验证应用。',
    en: 'Codex launched with the selected time zone and Dream Skin verified the skin.',
  ),
  'launcher.status.logWarning': (
    zh: '{summary}\n进程保持运行；日志记录不完整：{details}',
    en: '{summary}\nThe process remains running; logging was incomplete: {details}',
  ),
  'monitor.settings.title': (zh: '监控与提醒设置', en: 'Monitoring and alerts'),
  'monitor.settings.offline': (
    zh: '离线试用仅本次生效，不写入真实监控设置。',
    en: 'Offline trial changes last for this session and are not saved to live monitoring settings.',
  ),
  'monitor.settings.saved': (
    zh: '修改立即生效，并保存到当前程序文件夹。',
    en: 'Changes apply immediately and are saved in the current application folder.',
  ),
  'monitor.settings.on': (zh: '开启', en: 'On'),
  'monitor.settings.off': (zh: '关闭', en: 'Off'),
  'monitor.settings.motion': (
    zh: '减少动态效果：{state}',
    en: 'Reduce motion: {state}',
  ),
  'monitor.settings.motionDescription': (
    zh: '关闭悬停位移、光晕与点击波纹；系统减少动态效果设置也会生效。',
    en: 'Disable hover movement, glows and click ripples. The system reduce-motion setting also applies.',
  ),
  'monitor.settings.interval': (zh: '自动刷新间隔', en: 'Automatic refresh interval'),
  'monitor.settings.minute': (zh: '{count} 分钟', en: '{count} minute'),
  'monitor.settings.minutes': (zh: '{count} 分钟', en: '{count} minutes'),
  'monitor.settings.threshold': (
    zh: '低额度阈值（10% 时再提醒一次）',
    en: 'Low quota threshold (alert again at 10%)',
  ),
  'monitor.settings.quotaAlerts': (
    zh: '低额度提醒：{state}',
    en: 'Low quota alerts: {state}',
  ),
  'monitor.settings.turnAlerts': (
    zh: '回合结束提醒：{state}',
    en: 'Turn completion alerts: {state}',
  ),
  'monitor.settings.unmuteTurns': (zh: '取消回合提醒静音', en: 'Unmute turn alerts'),
  'monitor.settings.muteTurns': (
    zh: '回合提醒静音 15 分钟',
    en: 'Mute turn alerts for 15 minutes',
  ),
  'monitor.settings.turnDescription': (
    zh: '关注会话与未关注的所选会话共用开关和静音；只提醒观察期间的新完成事件，取消不发通知。回合完成不代表任务成功。',
    en: 'Followed sessions and the selected unfollowed session share these settings and mute state. Only new completions observed while monitoring trigger alerts; cancellations do not. A completed turn does not imply a successful task.',
  ),
  'monitor.settings.cycleMuted': (
    zh: '本轮已静音，重置后恢复',
    en: 'Muted until this quota cycle resets',
  ),
  'monitor.settings.muteCycle': (zh: '本轮额度周期不再提醒', en: 'Mute this quota cycle'),
  'monitor.settings.cycleDescription': (
    zh: '按当前账号各额度窗口分别静音，重置后恢复；重启仍有效。查询失败或缓存过期时不发低额度通知。',
    en: 'Mute each quota window for the current account until it resets. This survives restart. Failed queries and expired caches do not trigger low quota alerts.',
  ),
  'monitor.settings.loadFailed': (
    zh: '监控设置读取失败，已使用默认值；原文件未改动。',
    en: 'Monitoring settings could not be read. Defaults are in use; the original file is unchanged.',
  ),
  'monitor.settings.saveFailed': (
    zh: '监控偏好已生效，但保存失败；请检查文件夹写入权限。',
    en: 'Monitoring preferences applied but could not be saved. Check folder write permissions.',
  ),
  'monitor.settings.done': (zh: '完成', en: 'Done'),
  'monitor.info.closeDetails': (zh: '关闭详情', en: 'Close details'),
  'monitor.info.close': (zh: '关闭', en: 'Close'),
  'monitor.info.copy': (zh: '复制{label}', en: 'Copy {label}'),
  'monitor.info.fact': (zh: '{label}：{value}', en: '{label}: {value}'),
};

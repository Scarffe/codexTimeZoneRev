use ::windows::Win32::UI::Shell::FOLDERID_LocalAppData;
use super::{is_client_running, known_folder, process};
use crate::common::{tz, Settings};
use serde_json::{json, Value};
use std::{env, path::PathBuf};

fn discover() -> Result<PathBuf, String> {
    let user_install = known_folder(&FOLDERID_LocalAppData)
        .ok()
        .map(|path| path.join("Programs"));
    let system_installs = ["ProgramW6432", "ProgramFiles", "ProgramFiles(x86)"]
        .into_iter()
        .filter_map(env::var_os)
        .map(PathBuf::from);
    user_install
        .into_iter()
        .chain(system_installs)
        .filter(|path| path.is_absolute())
        .flat_map(|root| [root.join("Antigravity"), root.join("Google/Antigravity")])
        .find_map(|dir| {
            let executable = dir.join("Antigravity.exe");
            (dir.join("icudtl.dat").is_file() && executable.is_file()).then_some(executable)
        })
        .ok_or_else(|| "未在标准安装目录找到 Antigravity。请确认已安装 Antigravity 桌面应用。".into())
}

pub(super) fn launch(settings: &Settings) -> Result<Value, String> {
    let timezone = tz(settings)?;
    let executable = discover()?;
    // Other installations can still reuse the same running Electron instance.
    if is_client_running(&["antigravity.exe"], None)? {
        return Err("Antigravity 正在运行。请保存工作并完全退出 Antigravity 后重试。".into());
    }
    let mut child = process::Child::suspended(&executable, &[], &timezone)?;
    child.resume()?;
    if let Some(status) = child.exit_within(800)? {
        return Err(format!(
            "Antigravity 在启动后提前退出（退出代码 {status:#x}）。"
        ));
    }
    Ok(json!({
        "launched": true,
        "pid": child.id,
        "windowReadyVerified": false,
        "message": "已按所选时区启动 Antigravity 进程，窗口仍可能在加载。",
    }))
}

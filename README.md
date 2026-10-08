# KSU 前台监听与 Root 控制台（内测版）

此模块只检测指定应用是否进入前台，并以 Root 执行配置的 Shell 文件。

模块仓库自带 `.github/workflows/build-module.yml`。正式构建通过 GitHub Actions 完成，包括元数据校验、Shell 语法检查、ShellCheck、ZIP 完整性验证和 Artifact 上传。

## 运行方式

- KernelSU 在开机的 `late_start service` 阶段执行模块的 `service.sh`。
- `service.sh` 启动独立监听进程，不依赖 KernelSU 管理器 App 常驻后台。
- 管理器被划掉或强制停止后，已经启动的模块监听仍会运行。
- 轮询 Android 当前前台应用；目标应用每次进入前台时执行一次，停留期间不会重复。
- 目标应用位于后台时不触发，Root 请求也不会触发脚本。
- 监听器使用原子单实例锁，避免两个后台监听进程造成顺序重复执行。
- 提供脚本预输入台；每一行作为一次输入并附加回车，自动送入脚本标准输入。
- 应用进入前台后，以 Root 身份、从 `/` 目录执行指定 Shell 文件。

## 必要条件

需要 KernelSU 能正常运行模块的 `service.sh`。不需要 `sulog`，也不启用或读取 Root 事件日志。

## 安装与配置

1. 从 GitHub Actions 下载并在 KernelSU 管理器安装构建出的模块 ZIP。
2. 重启手机，使模块的 `service.sh` 自动启动。
3. 打开模块 WebUI，填写目标应用包名与 Shell 文件绝对路径。
4. 开启“启用监听”，保存配置。
5. 点击“打开应用”可立即测试；平时从桌面打开目标应用也会自动执行一次。

## 脚本预输入台

如果脚本会依次要求输入菜单数字、文字和确认内容，可在 WebUI 中逐行填写，例如：

```text
1
测试文字
y
```

模块执行时等效于依次输入 `1`、`测试文字`、`y`，每项后按一次回车。自动监听触发与手动执行共用同一份预输入配置。该功能适用于从标准输入读取内容的 Shell 脚本；需要真实 TTY、方向键或密码遮罩的交互程序不保证兼容。

## 脚本环境变量

触发脚本可以读取：

- `KSU_TRIGGER_TYPE=app_foreground`
- `KSU_TRIGGER_PACKAGE`：配置的目标包名。

## 日志

- 模块触发日志：`/data/adb/ksu_app_watcher/logs/trigger.log`
- 持久化配置：`/data/adb/ksu_app_watcher/config/`

## 安全说明

Root 控制台和触发脚本拥有不受限制的 Root 权限。请只选择和执行你完全信任的文件。模块不会使用无障碍服务，也不需要管理器 App 保持在后台；仅保留由 KernelSU 启动的轻量 Shell 监听进程。


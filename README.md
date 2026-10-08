# KSU Root监听与 Root 控制台 2.0

此模块按照 `wutong7891/KernelSU` 源码中的 `sulog` 与 Root 终端行为制作。

模块仓库自带 `.github/workflows/build-module.yml`。正式构建通过 GitHub Actions 完成，包括元数据校验、Shell 语法检查、ShellCheck、ZIP 完整性验证和 Artifact 上传。

## 运行方式

- KernelSU 在开机的 `late_start service` 阶段执行模块的 `service.sh`。
- `service.sh` 启动独立监听进程，不依赖 KernelSU 管理器 App 常驻后台。
- 管理器被划掉或强制停止后，已经启动的模块监听仍会运行。
- 监听目标应用发起的 `sucompat` 或 `ioctl_grant_root` 事件，按照应用 UID 匹配。
- WebUI 同时显示全部 Root 应用事件，可按类型筛选并搜索应用、UID、进程和命令。
- 提供脚本预输入台；每一行作为一次输入并附加回车，自动送入脚本标准输入。
- 命中事件后，以 Root 身份、从 `/` 目录执行指定 Shell 文件。

## 必要条件

此功能依赖你的定制 KernelSU 内核和 `ksud` 提供 `sulog` 功能。WebUI 会运行：

```sh
ksud feature check sulog
```

只有结果为 `supported` 才能开启真正的 Root 请求监听。普通官方 KernelSU 如果没有该功能，模块仍可使用 Root 文件浏览器、控制台和手动脚本执行，但不能捕获 Root 请求。

## 安装与配置

1. 从 GitHub Actions 下载并在 KernelSU 管理器安装构建出的模块 ZIP。
2. 重启手机，使模块的 `service.sh` 自动启动。
3. 打开模块 WebUI，填写目标应用包名与 Shell 文件绝对路径。
4. 建议保持“经典 SU 请求”和“ioctl Root 授权”开启。
5. 开启“启用监听”，保存配置。
6. 点击“打开应用”；当该应用请求 Root 时，模块会自动执行脚本。

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

- `KSU_SULOG_TYPE`：Root 事件类型。
- `KSU_SULOG_UID`：请求来源 UID。
- `KSU_SULOG_PID`：请求来源 PID。
- `KSU_SULOG_COMM`：进程名。
- `KSU_SULOG_FILE`：被执行文件。
- `KSU_SULOG_ARGV`：命令参数。
- `KSU_SULOG_PACKAGE`：配置的目标包名。

## 日志

- 内核 Root监听日志：`/data/adb/ksu/log/sulog-*.log`
- 模块触发日志：`/data/adb/modules/ksu_app_watcher/logs/trigger.log`

## 安全说明

Root 控制台和触发脚本拥有不受限制的 Root 权限。请只选择和执行你完全信任的文件。模块不会使用无障碍服务，也不需要管理器 App 保持在后台。


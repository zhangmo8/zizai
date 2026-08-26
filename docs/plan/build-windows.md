# Windows 构建说明

> 本仓库开发机为 macOS，无 Windows 构建环境；日常发布**不需要**本机跑 Windows 构建——
> 推 tag 后由 GitHub Actions（`.github/workflows/build.yml` 的 `windows` job）在
> `windows-latest` runner 上完成。本页仅用于：Windows 机器上**验证/调试** Windows 构建，
> 或本地打包验证 setup.exe 安装向导。

## 1. 前置要求（Windows 机器）

- **Windows 10/11**（x64）。
- **Flutter SDK 3.44.8**（与 CI 的 `FLUTTER_VERSION` 保持一致）：
  - 安装后运行 `flutter doctor`，确认 `flutter`、`dart` 无报错。
  - Windows 桌面支持：`flutter config --enable-windows-desktop`。
- **Visual Studio 2022**（17.8+），勾选工作负载 **「使用 C++ 的桌面开发」**（Desktop
  development with C++），Flutter 的 Windows 构建依赖 MSVC 工具链。
- **NSIS 3.x**（打包 setup.exe 向导用）：`choco install nsis -y`（需管理员 shell）；
  或用安装器直接安装。安装后 `makensis.exe` 需在 PATH 中（choco 安装的 NSIS 不会自动
  进 PATH，可手动加 `C:\Program Files (x86)\NSIS`）。
- 构建时**不要**与 CI 冲突：本地构建与 CI 互不干扰，但产物路径相同
  （`build/`），CI 在独立 runner 上，无冲突。

## 2. 构建 release 版

```powershell
# 仓库根目录（PowerShell）
flutter pub get
flutter build windows --release --dart-define=UPDATE_URL="https://<你的R2公开域名>/update.json"
```

- `UPDATE_URL` 与 CI 一致：正式发布时指向 `R2_PUBLIC_BASE/update.json`（见
  `docs/app/update.md` §5）；本地调试可用任意占位地址，甚至省略
  `--dart-define`（main.dart 会回退到内置默认值）。
- 产物：`build/windows/x64/runner/Release/`，可执行文件 `zi_zai.exe`。

## 3. 打包

### 3.1 zip（自更新用）

```powershell
cd build\windows\x64\runner\Release
powershell Compress-Archive -Path * -DestinationPath zizai-windows.zip
```

与 CI 的 `windows` job 一致；zip 内即 Release 目录全部文件（exe/dll/data）。

### 3.2 安装向导 setup.exe（NSIS，首次安装 + 自更新共用）

脚本：`tool/installer/windows/zi_zai_installer.nsi`（MUI2，按用户安装到
`%LOCALAPPDATA%\Programs\ZiZai`，免管理员；自更新走 `/S` 静默安装 +
「改名腾位」处理运行中文件锁）。

```bash
# Git Bash（或 CMD），仓库根目录；先把 NSIS 加进 PATH
app_version=<版本号，如 1.7.13>
mkdir -p build/installer
makensis \
  /DAPP_VERSION="${app_version}" \
  "/DSOURCE=$(pwd)/build/windows/x64/runner/Release" \
  "/DICON_SRC=$(pwd)/windows/runner/resources/app_icon.ico" \
  "/DOUT_DIR=$(pwd)/build/installer" \
  tool/installer/windows/zi_zai_installer.nsi
```

> **Git Bash 注意**：`/DXXX=...` 会被 MSYS2 当成路径改写，务必在执行前设置
> `MSYS2_ARG_CONV_EXCL="*"`（CI 同款处理），否则 makensis 收到被改写的参数。
> CMD/PowerShell 无此问题。

产物：`build/installer/zizai-<版本>-windows-setup.exe`。

## 4. 冒烟验证

- 双击 `zi_zai.exe` 或安装 setup.exe 后启动，确认能正常读写数据目录
  （`getApplicationSupportDirectory()` → `%APPDATA%\dev.zizai\zi_zai`，
  `zi-zai.db*` 与日志均在此）。
- 平台差异（`docs/app/README.md` §8）：
  - 外部富文本粘贴在 Windows 按**纯文本**（flutter_quill 的 HTML 剪贴板读取在
    Windows 会崩溃，已关闭），macOS 保留富文本。
  - Ctrl+S 全局保存、Ctrl+B 侧边栏等在 Windows 同样生效。
- 数据可迁移性：Windows 库文件 `zi-zai.db*` 与 macOS/Android 同构，可直接拷回验证。

## 5. 与 CI 的关系

- 日常发布：`git tag v<version> && git push origin v<version>` → `build.yml`
  `windows` job 自动构建 zip + setup.exe 并上传 R2。本机不需要 Windows。
- 本页流程仅在以下场景使用：Windows 机器上排查 Windows 专属问题、验证 setup.exe
  安装/卸载/自更新行为、或 CI 不可用时的应急打包。
- 本机产出物直接上传 R2 时，命名与目录必须与 CI 一致
  （`releases/<tag>/zizai-windows.zip`、`releases/<tag>/zizai-windows-setup.exe`；
  setup.exe 在 R2 上使用**无版本号**命名，本地 `zizai-<版本>-windows-setup.exe`
  上传时需改名），否则 `update.json` 与公开校验 URL 会 404
  （见 build.yml `windows` job 注释）。

## 6. 常见问题

| 现象 | 处理 |
|---|---|
| `flutter build windows` 报缺少 MSVC 工具链 | 装 VS2022「使用 C++ 的桌面开发」；`flutter doctor -v` 确认 `Visual Studio` 项为 ✔ |
| `makensis: command not found` | NSIS 未进 PATH（choco 装的默认在 `C:\Program Files (x86)\NSIS`，手动加入） |
| makensis 收到被改写的 `/D...` 参数 | Git Bash 下先 `export MSYS2_ARG_CONV_EXCL="*"` |
| 自更新提示文件被占用 | 安装器会先退出应用再「改名腾位」；若仍失败，确认没有残留 `zi_zai.exe` 进程 |
| setup.exe 被杀毒软件拦截 | 未签名自用包，Windows SmartScreen 提示时选「仍要运行」；正式分发建议签 EV 证书（超出本任务范围） |

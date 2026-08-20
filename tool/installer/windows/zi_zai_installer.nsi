; 字在 — Windows 安装向导（NSIS / MUI2）。
;
; 双用途：
;   1) 首次安装：用户双击 → 经典「下一步 → 安装 → 完成」向导。
;   2) 自更新：App 下载本安装包后用 /S 静默安装（应用会先退出，
;      安装器通过「改名腾位」处理运行中的 exe/dll 锁，完成后自动重启新版）。
;
; 构建：build/windows/x64/runner/Release/ 里的 Flutter 产物
;   + 本脚本 → setup.exe。
;
; 用法（CI 或本地，需先安装 NSIS，如 choco install nsis）：
;   makensis /DAPP_VERSION=1.4.0 \
;           tool\installer\windows\zi_zai_installer.nsi
; 编译时 NSIS 的工作目录为脚本所在目录（tool/installer/windows/），脚本内
; 相对路径均以它为基准，用 ..\..\..\ 前缀锚定到仓库根。CI 另会传入
; /DSOURCE /DICON_SRC /DOUT_DIR 绝对路径覆盖，双保险。
;
; 设计：
;   - 按用户安装到 %LOCALAPPDATA%\Programs\ZiZai（免管理员、免 UAC）
;   - 开始菜单 + 桌面快捷方式
;   - 注册表卸载项（控制面板可卸载）
;   - 卸载时删除数据目录由用户选择（默认保留用户数据）

Unicode true
ManifestDPIAware true

!include "MUI2.nsh"
!include "FileFunc.nsh"

; ── 常量 ──────────────────────────────────────────────
!define APP_NAME "字在"
!define APP_EXE "zi_zai.exe"
!define PUBLISHER "dev.zizai"
!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\ZiZai"

; 命令行传入（CI 注入），缺省兜底。
!ifndef APP_VERSION
  !define APP_VERSION "0.0.0"
!endif
; 编译期 NSIS 的工作目录即脚本所在目录（tool/installer/windows/），
; 相对路径用它向上三级（..\..\..\）锚定到仓库根；CI 用绝对路径 /D 覆盖。
!ifndef SOURCE
  !define SOURCE "..\..\..\build\windows\x64\runner\Release"
!endif
!ifndef ICON_SRC
  !define ICON_SRC "..\..\..\windows\runner\resources\app_icon.ico"
!endif
!ifndef OUT_DIR
  !define OUT_DIR "..\..\..\build\installer"
!endif

Name "${APP_NAME} ${APP_VERSION}"
OutFile "${OUT_DIR}/zizai-${APP_VERSION}-windows-setup.exe"
InstallDir "$LOCALAPPDATA\Programs\ZiZai"
InstallDirRegKey HKCU "${UNINST_KEY}" "InstallLocation"
RequestExecutionLevel user
BrandingText " "

; ── 向导页面 ─────────────────────────────────────────
!define MUI_ABORTWARNING
!define MUI_ICON "${ICON_SRC}"
!define MUI_UNICON "${ICON_SRC}"
!define MUI_FINISHPAGE_RUN "$INSTDIR\${APP_EXE}"
!define MUI_FINISHPAGE_RUN_TEXT "运行 ${APP_NAME}"
!define MUI_FINISHPAGE_SHOWREADME ""
!define MUI_WELCOMEPAGE_TITLE "欢迎安装 ${APP_NAME} ${APP_VERSION}"
!define MUI_WELCOMEPAGE_TEXT "本向导将引导你完成「${APP_NAME}」的安装。$\r$\n$\r$\n点击「下一步」继续。"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"

; ── 安装 ─────────────────────────────────────────────
Section "Install"
  SetOutPath "$INSTDIR"

  ; 自更新场景：应用正在运行，exe/dll 被占用。
  ; Windows 允许「重命名」正在运行的可执行文件（仅删除被禁止），
  ; 所以先把旧文件改名腾位，再拷新文件；运行中的旧文件删不掉就留待下次清理。
  Delete "$INSTDIR\${APP_EXE}.old"
  Delete "$INSTDIR\flutter_windows.dll.old"
  IfFileExists "$INSTDIR\${APP_EXE}" 0 +3
    Rename "$INSTDIR\${APP_EXE}" "$INSTDIR\${APP_EXE}.old"
    Rename "$INSTDIR\flutter_windows.dll" "$INSTDIR\flutter_windows.dll.old"
  File /r "${SOURCE}\*"
  Delete "$INSTDIR\${APP_EXE}.old"
  Delete "$INSTDIR\flutter_windows.dll.old"

  ; 开始菜单快捷方式
  CreateDirectory "$SMPROGRAMS\${APP_NAME}"
  CreateShortcut "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}"
  CreateShortcut "$SMPROGRAMS\${APP_NAME}\卸载 ${APP_NAME}.lnk" "$INSTDIR\uninstall.exe"

  ; 桌面快捷方式（用户可删）
  CreateShortcut "$DESKTOP\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}"

  ; 卸载器
  WriteUninstaller "$INSTDIR\uninstall.exe"

  ; 控制面板卸载项
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayName" "${APP_NAME}"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "${UNINST_KEY}" "Publisher" "${PUBLISHER}"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayIcon" "$INSTDIR\${APP_EXE}"
  WriteRegStr HKCU "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINST_KEY}" "UninstallString" "$INSTDIR\uninstall.exe"
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKCU "${UNINST_KEY}" "EstimatedSize" "$0"

  ; 自更新（静默 /S）完成后自动启动新版本。
  IfSilent 0 +2
    ExecShell "" "$INSTDIR\${APP_EXE}"
SectionEnd

; ── 卸载 ─────────────────────────────────────────────
Section "Uninstall"
  Delete "$INSTDIR\uninstall.exe"

  Delete "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk"
  Delete "$SMPROGRAMS\${APP_NAME}\卸载 ${APP_NAME}.lnk"
  RMDir "$SMPROGRAMS\${APP_NAME}"
  Delete "$DESKTOP\${APP_NAME}.lnk"

  RMDir /r "$INSTDIR"

  DeleteRegKey HKCU "${UNINST_KEY}"
SectionEnd

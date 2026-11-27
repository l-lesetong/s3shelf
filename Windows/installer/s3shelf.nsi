Unicode true
!include "LogicLib.nsh"
!include "WinVer.nsh"
!include "x64.nsh"

Name "s3Shelf"
OutFile "${SETUP}"
InstallDir "$LOCALAPPDATA\Programs\s3Shelf"
InstallDirRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\s3Shelf" "InstallLocation"
RequestExecutionLevel user
Icon "../S3Shelf/AppIcon.ico"
UninstallIcon "../S3Shelf/AppIcon.ico"
SetCompressor /SOLID lzma
VIProductVersion "${VERSION}.0"
VIAddVersionKey /LANG=2052 "ProductName" "s3Shelf"
VIAddVersionKey /LANG=2052 "FileDescription" "s3Shelf Windows 安装程序"
VIAddVersionKey /LANG=2052 "FileVersion" "${VERSION}"
VIAddVersionKey /LANG=2052 "ProductVersion" "${VERSION}"
VIAddVersionKey /LANG=2052 "Comments" "构建时间 ${BUILD_TIMESTAMP}"
VIAddVersionKey /LANG=2052 "LegalCopyright" "s3Shelf contributors"

Page directory
Page instfiles
UninstPage uninstConfirm
UninstPage instfiles
LoadLanguageFile "${NSISDIR}/Contrib/Language files/SimpChinese.nlf"

Function .onInit
  ${IfNot} ${AtLeastWin10}
  ${OrIfNot} ${AtLeastBuild} 14393
    MessageBox MB_OK|MB_ICONSTOP "s3Shelf 需要 Windows 10 1607、带桌面体验的 Windows Server 2016 或更新版本。" /SD IDOK
    SetErrorLevel 1
    Abort
  ${EndIf}
  ${If} ${RunningX64}
    SetRegView 64
  ${EndIf}
  ReadRegDWORD $0 HKLM "SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" "Release"
  SetRegView 32
  ${If} $0 U< 528040
    ReadRegDWORD $0 HKLM "SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" "Release"
  ${EndIf}
  ${If} $0 U< 528040
    MessageBox MB_YESNO|MB_ICONEXCLAMATION "请先安装 Microsoft .NET Framework 4.8 或更新版本，再运行 s3Shelf 安装程序。是否打开微软下载页面？" /SD IDNO IDNO no_download
    ExecShell "open" "https://dotnet.microsoft.com/download/dotnet-framework/net48"
    no_download:
    SetErrorLevel 1
    Abort
  ${EndIf}
FunctionEnd

Section "Install"
  SetShellVarContext current
  SetOutPath "$INSTDIR"
  !macro PayloadFile NAME
    File "${PAYLOAD}/${NAME}"
  !macroend
  !include "${PAYLOAD_LIST}"
  !macroundef PayloadFile
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateShortcut "$SMPROGRAMS\s3Shelf.lnk" "$INSTDIR\s3Shelf.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\s3Shelf" "DisplayName" "s3Shelf"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\s3Shelf" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\s3Shelf" "DisplayIcon" "$INSTDIR\s3Shelf.exe,0"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\s3Shelf" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\s3Shelf" "UninstallString" '$\"$INSTDIR\Uninstall.exe$\"'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\s3Shelf" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\s3Shelf" "NoRepair" 1
SectionEnd

Section "Uninstall"
  SetShellVarContext current
  !macro PayloadFile NAME
    Delete "$INSTDIR\${NAME}"
  !macroend
  !include "${PAYLOAD_LIST}"
  !macroundef PayloadFile
  Delete "$INSTDIR\Uninstall.exe"
  Delete "$SMPROGRAMS\s3Shelf.lnk"
  RMDir "$INSTDIR"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\s3Shelf"
SectionEnd

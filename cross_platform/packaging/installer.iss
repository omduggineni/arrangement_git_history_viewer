; Inno Setup script: wraps PyInstaller's onedir output (the exe plus its
; _internal folder) into a single Setup.exe, so users never see _internal.
;
; Build (after PyInstaller):
;   iscc /DAppVersion=0.1.0 packaging\installer.iss
; Output: dist\installer\Arrangement-Diff-Viewer-Setup.exe

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#define AppName "Arrangement Diff Viewer"
#define AppExe "Arrangement Diff Viewer.exe"

[Setup]
AppId={{6B0E3D52-7C1A-4E58-9A3F-2D8C4F1B7E90}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=Om Duggineni
; Per-user install by default (no admin prompt); the user can opt into all-users.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#AppExe}
SetupIconFile=..\packaging\icon.ico
OutputDir=..\dist\installer
OutputBaseFilename=Arrangement-Diff-Viewer-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; Flags: unchecked

[Files]
Source: "..\dist\{#AppName}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent

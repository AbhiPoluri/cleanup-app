; Inno Setup script for Cleanup — built by .github/workflows/installer.yml

; App version. Overridable from the workflow: ISCC.exe /DAppVer=x.y.z cleanup.iss
#ifndef AppVer
  #define AppVer "1.0.0"
#endif

[Setup]
; Stable AppId — NEVER change this. It ties every upgrade to the same install.
AppId={{D162E1AD-91AF-4DDE-AA53-F88E654084AC}
AppName=Cleanup
AppVersion={#AppVer}
AppPublisher=Abhiram Poluri
DefaultDirName={userpf}\Cleanup
DisableProgramGroupPage=yes
; per-user install — no admin prompt
PrivilegesRequired=lowest
OutputDir=Output
OutputBaseFilename=CleanupSetup
Compression=lzma2
SolidCompression=yes
UninstallDisplayIcon={app}\Cleanup.exe
WizardStyle=modern
; Clean in-place upgrades: matches the app's single-instance mutex so Inno
; detects a running copy and (interactively) prompts to close it; also asks
; Windows Restart Manager to shut it down. RestartApplications=no because the
; [Run] entries below handle relaunch.
AppMutex=CleanupSingleInstance
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "startmenuicon"; Description: "Create a &Start Menu shortcut"; GroupDescription: "Shortcuts:"
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked
Name: "startup"; Description: "Start Cleanup automatically when I &sign in"; GroupDescription: "Startup:"

[Files]
Source: "..\publish\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs

[Icons]
Name: "{userprograms}\Cleanup"; Filename: "{app}\Cleanup.exe"; Tasks: startmenuicon
Name: "{userdesktop}\Cleanup"; Filename: "{app}\Cleanup.exe"; Tasks: desktopicon
Name: "{userstartup}\Cleanup"; Filename: "{app}\Cleanup.exe"; Tasks: startup

[Run]
; Interactive install: offer a "Launch now" checkbox on the finished page.
Filename: "{app}\Cleanup.exe"; Description: "Launch Cleanup now"; Flags: nowait postinstall skipifsilent
; Silent install (the in-app updater upgrade path): relaunch automatically so the
; user is never left without the tray app. Guarded to silent-only so an interactive
; install doesn't double-launch alongside the finish-page checkbox above.
Filename: "{app}\Cleanup.exe"; Flags: nowait; Check: WizardSilent

[UninstallRun]
Filename: "taskkill"; Parameters: "/im Cleanup.exe /f"; Flags: runhidden; RunOnceId: "KillCleanup"

[Code]
// Belt-and-suspenders for silent upgrades: if the app is still running when a
// silent install starts (Restart Manager / AppMutex can miss a wedged process),
// force it closed so files aren't locked. A failed taskkill (nothing running)
// must NOT abort the install, so we ignore ResultCode entirely.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/im Cleanup.exe /f', '',
       SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := '';
end;

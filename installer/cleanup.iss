; Inno Setup script for Cleanup — built by .github/workflows/installer.yml

[Setup]
AppName=Cleanup
AppVersion=1.0.0
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
Filename: "{app}\Cleanup.exe"; Description: "Launch Cleanup now"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "taskkill"; Parameters: "/im Cleanup.exe /f"; Flags: runhidden; RunOnceId: "KillCleanup"

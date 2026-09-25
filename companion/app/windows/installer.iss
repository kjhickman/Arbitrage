#ifndef AppVersion
  #error Define AppVersion, e.g. iscc /DAppVersion=1.2.3 installer.iss
#endif

[Setup]
AppId={{6765B8CC-87DF-4820-A65E-04168117A025}
AppName=Arbitrage Companion
AppVersion={#AppVersion}
AppPublisher=kjhickman
AppPublisherURL=https://github.com/kjhickman/Arbitrage
DefaultDirName={autopf}\Arbitrage Companion
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=force
RestartApplications=no
UninstallDisplayName=Arbitrage Companion
UninstallDisplayIcon={app}\arbitrage-companion.exe
SetupIconFile=app.ico
OutputDir=..\..\target\release
OutputBaseFilename=Arbitrage-Companion-windows-x86_64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Files]
Source: "..\..\target\release\arbitrage-companion.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\Arbitrage Companion"; Filename: "{app}\arbitrage-companion.exe"

[Run]
Filename: "{app}\arbitrage-companion.exe"; Description: "Launch Arbitrage Companion"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/f /im arbitrage-companion.exe"; Flags: runhidden; RunOnceId: "StopCompanion"

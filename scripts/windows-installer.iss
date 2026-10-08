#define AppVersion GetVersionNumbersString(AddBackslash(SourcePath) + "..\build\windows\x64\runner\Release\sygnature.exe")

[Setup]
AppId=network.noosphere.sygnature.windows
AppName=Sygnature
AppVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\Sygnature
DefaultGroupName=Sygnature
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\build
OutputBaseFilename=Sygnature-Windows-x64-Setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\sygnature.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Sygnature"; Filename: "{app}\sygnature.exe"

[Run]
Filename: "{app}\sygnature.exe"; Description: "Launch Sygnature"; Flags: nowait postinstall skipifsilent

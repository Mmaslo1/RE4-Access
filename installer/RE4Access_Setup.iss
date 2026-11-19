; RE4 Access one-click installer. Build: ISCC.exe RE4Access_Setup.iss
; Source = the clean share folder made from build_tester_package.ps1 (no owner/ammo files).
#define Ver "0.27.0"
#define Src "C:\Users\micha\Downloads\RE4Access_Share_0.27.0"
#define GameDirName "RESIDENT EVIL 4  BIOHAZARD RE4"

[Setup]
AppId={{6E4C2B8A-5F1D-4C3E-9A7B-RE4ACCESS0001}
AppName=RE4 Access (Resident Evil 4 blind accessibility mod)
AppVersion={#Ver}
AppPublisher=RE4 Access
DefaultDirName={code:GetGameDir}
DirExistsWarning=no
AppendDefaultDirName=no
DisableProgramGroupPage=yes
DisableReadyPage=no
#ifndef Priv
#define Priv "admin"
#endif
PrivilegesRequired={#Priv}
OutputDir=C:\Users\micha\Downloads
OutputBaseFilename=RE4Access_Setup_{#Ver}
Compression=lzma2
SolidCompression=yes
UninstallFilesDir={app}\RE4Access_uninstall
UninstallDisplayName=RE4 Access {#Ver}
InfoAfterFile=AFTER_INSTALL.txt
WizardStyle=classic
SetupLogging=yes

[Messages]
SelectDirLabel3=Setup could not find Resident Evil 4 by itself. Please choose the game folder: the folder that contains re4.exe.
SelectDirBrowseLabel=Usually: C:\Program Files (x86)\Steam\steamapps\common\RESIDENT EVIL 4  BIOHAZARD RE4

[Files]
Source: "{#Src}\dinput8.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Src}\prism.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Src}\nvdaControllerClient64.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Src}\reframework\*"; DestDir: "{app}\reframework"; Flags: ignoreversion recursesubdirs
Source: "{#Src}\third-party\*"; DestDir: "{app}\third-party"; Flags: ignoreversion recursesubdirs
Source: "{#Src}\docs\*"; DestDir: "{app}\RE4Access_docs"; Flags: ignoreversion recursesubdirs
Source: "{#Src}\source\*"; DestDir: "{app}\RE4Access_docs\source"; Flags: ignoreversion recursesubdirs

[Run]
Filename: "notepad.exe"; Parameters: """{app}\RE4Access_docs\README_KEYS_AND_HELP.txt"""; Description: "Open the keys and help file now"; Flags: postinstall nowait skipifsilent

[Code]
function HasGame(Dir: String): Boolean;
begin
  Result := (Dir <> '') and FileExists(AddBackslash(Dir) + 're4.exe');
end;

function FindInSteamLibraries(): String;
var
  SteamPath, Vdf, Line, P: String;
  Lines: TArrayOfString;
  I, Q1, Q2: Integer;
begin
  Result := '';
  if not RegQueryStringValue(HKCU, 'Software\Valve\Steam', 'SteamPath', SteamPath) then
    if not RegQueryStringValue(HKLM, 'SOFTWARE\WOW6432Node\Valve\Steam', 'InstallPath', SteamPath) then
      exit;
  StringChangeEx(SteamPath, '/', '\', True);
  P := AddBackslash(SteamPath) + 'steamapps\common\{#GameDirName}';
  if HasGame(P) then begin Result := P; exit; end;
  Vdf := AddBackslash(SteamPath) + 'steamapps\libraryfolders.vdf';
  if not LoadStringsFromFile(Vdf, Lines) then exit;
  for I := 0 to GetArrayLength(Lines) - 1 do begin
    Line := Trim(Lines[I]);
    if Pos('"path"', Line) = 1 then begin
      Delete(Line, 1, 6);
      Q1 := Pos('"', Line);
      Delete(Line, 1, Q1);
      Q2 := Pos('"', Line);
      P := Copy(Line, 1, Q2 - 1);
      StringChangeEx(P, '\\', '\', True);
      P := AddBackslash(P) + 'steamapps\common\{#GameDirName}';
      if HasGame(P) then begin Result := P; exit; end;
    end;
  end;
end;

function FindGame(): String;
var
  P: String;
begin
  Result := '';
  if RegQueryStringValue(HKLM, 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 2050650', 'InstallLocation', P) and HasGame(P) then
  begin Result := P; exit; end;
  if RegQueryStringValue(HKLM64, 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 2050650', 'InstallLocation', P) and HasGame(P) then
  begin Result := P; exit; end;
  Result := FindInSteamLibraries();
end;

function GetGameDir(Param: String): String;
begin
  Result := FindGame();
  if Result = '' then
    Result := ExpandConstant('{commonpf32}\Steam\steamapps\common\{#GameDirName}');
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  { Skip the folder page when the game was found automatically. }
  Result := (PageID = wpSelectDir) and (FindGame() <> '');
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CurPageID = wpSelectDir) and not HasGame(WizardDirValue) then begin
    MsgBox('re4.exe is not in that folder. Please choose the Resident Evil 4 game folder, the one that contains re4.exe.', mbError, MB_OK);
    Result := False;
  end;
end;

function InitializeSetup(): Boolean;
begin
  Result := True;
  if FindGame() <> '' then
    MsgBox('Resident Evil 4 was found in:' + #13#10 + FindGame() + #13#10#13#10 +
      'Setup will install RE4 Access there. Please close the game first if it is running.', mbInformation, MB_OK);
end;


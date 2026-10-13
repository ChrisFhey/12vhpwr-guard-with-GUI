; Inno Setup 6.3+ script. Build with installer\build.ps1, which passes AppVersion
; and DistDir (the PyInstaller output).
;
; Binaries go to Program Files (admin-only), writable data to
; %ProgramData%\12VHPWR Guard (kept across upgrades). setup_helper.ps1 does the
; system configuration: stop/backup before files are replaced, task registration
; after, rollback if anything fails.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef DistDir
  #define DistDir "build\dist"
#endif

#define AppName "12VHPWR Guard"
#define GuardExe "12VHPWR-Guard.exe"
#define OverlayExe "12VHPWR-Guard-Overlay.exe"
#define OverlayLink "12VHPWR Guard Overlay"

[Setup]
; Never change AppId: upgrades find the existing install through it.
AppId={{7136155F-A046-4374-A0D4-0E83A09F46CC}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=12VHPWR Guard contributors
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\{#AppName}
; The guard runs elevated from here, so keep it in Program Files.
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
LicenseFile=..\LICENSE
OutputDir=Output
OutputBaseFilename=12VHPWR-Guard-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; Running processes are stopped by setup_helper.ps1, not Restart Manager.
CloseApplications=no
RestartApplications=no
SetupMutex=12VHPWRGuardSetup,Global\12VHPWRGuardSetup
SetupLogging=yes
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\guard\{#GuardExe}

[Tasks]
Name: overlayautostart; Description: "Start the overlay automatically at logon (all users)"

[InstallDelete]
; Replace the PyInstaller folders wholesale so files dropped by a newer build do
; not linger. Prepare has already backed them up.
Type: filesandordirs; Name: "{app}\guard"
Type: filesandordirs; Name: "{app}\overlay"
Type: files; Name: "{commonstartup}\{#OverlayLink}.lnk"

[Files]
Source: "{#DistDir}\12VHPWR-Guard\*"; DestDir: "{app}\guard"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#DistDir}\12VHPWR-Guard-Overlay\*"; DestDir: "{app}\overlay"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "setup_helper.ps1"; DestDir: "{app}\setup"; Flags: ignoreversion
Source: "..\guard\guard_task.ps1"; DestDir: "{app}\setup"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\guard\LICENSE"; DestDir: "{app}"; DestName: "LICENSE-guard-upstream"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\guard\README.md"; DestDir: "{app}"; DestName: "README-guard-upstream.md"; Flags: ignoreversion

[Icons]
; Startup items launch with the user's normal (non-elevated) token.
Name: "{autoprograms}\{#OverlayLink}"; Filename: "{app}\overlay\{#OverlayExe}"; WorkingDir: "{app}\overlay"
Name: "{commonstartup}\{#OverlayLink}"; Filename: "{app}\overlay\{#OverlayExe}"; WorkingDir: "{app}\overlay"; Tasks: overlayautostart

[Run]
; runasoriginaluser: never start the overlay with setup's admin rights.
Filename: "{app}\overlay\{#OverlayExe}"; Description: "Start the overlay now"; Flags: nowait postinstall runasoriginaluser; Check: ConfigureSucceeded

[Code]
var
  GuardStopped: Boolean;
  InstallSucceeded: Boolean;
  RestoreDone: Boolean;

function DataDir(): String;
begin
  Result := ExpandConstant('{commonappdata}\{#AppName}');
end;

function HelperLog(): String;
begin
  Result := DataDir() + '\setup.log';
end;

function RunHelper(const HelperDir, Action: String): Boolean;
var
  Params, GuardUser: String;
  ResultCode: Integer;
begin
  Params := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + HelperDir + '\setup_helper.ps1"' +
    ' -Action ' + Action +
    ' -InstallDir "' + ExpandConstant('{app}') + '"' +
    ' -DataDir "' + DataDir() + '"' +
    ' -LogFile "' + HelperLog() + '"';
  { /GuardUser=DOMAIN\name overrides the account the guard task runs as. }
  GuardUser := ExpandConstant('{param:GuardUser|}');
  if GuardUser <> '' then
    Params := Params + ' -UserId "' + GuardUser + '"';
  Result := Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Params, '',
    SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0);
  Log(Format('setup_helper %s: exit code %d', [Action, ResultCode]));
end;

function ConfigureSucceeded(): Boolean;
begin
  Result := InstallSucceeded;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  ExtractTemporaryFile('setup_helper.ps1');
  ExtractTemporaryFile('guard_task.ps1');
  { Set first: even a partly failed Prepare may have stopped the guard. }
  GuardStopped := True;
  if not RunHelper(ExpandConstant('{tmp}'), 'Prepare') then
    Result := 'Could not stop the running guard or back up the current installation. ' +
      'Nothing was replaced. Details: ' + HelperLog();
end;

procedure RestorePrevious();
begin
  if RestoreDone then
    Exit;
  RestoreDone := True;
  if not RunHelper(ExpandConstant('{tmp}'), 'Restore') then
    SuppressibleMsgBox('Restoring the previous installation failed. The guard may not be running. ' +
      'Re-run this setup or check ' + HelperLog(), mbCriticalError, MB_OK, IDOK);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    if RunHelper(ExpandConstant('{tmp}'), 'Configure') then
    begin
      InstallSucceeded := True;
      RunHelper(ExpandConstant('{tmp}'), 'Cleanup');
    end
    else
    begin
      RestorePrevious();
      SuppressibleMsgBox('Configuring the guard failed, so the previous installation (if any) was ' +
        'restored and restarted. Details: ' + HelperLog(), mbCriticalError, MB_OK, IDOK);
    end;
  end;
end;

procedure DeinitializeSetup();
begin
  { Cancelled or failed after Prepare stopped the guard: put the old one back. }
  if GuardStopped and not InstallSucceeded then
    RestorePrevious();
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
  begin
    if not RunHelper(ExpandConstant('{app}\setup'), 'Uninstall') then
      SuppressibleMsgBox('Could not fully remove the guard''s scheduled task. Check Task Scheduler for "{#AppName}". ' +
        'Details: ' + HelperLog(), mbError, MB_OK, IDOK);
    if FileExists(DataDir() + '\mitigation.active') then
      SuppressibleMsgBox('The guard was limiting the GPU when it was stopped. Restart Windows to ' +
        'return the GPU to its normal clocks and power limit.', mbInformation, MB_OK, IDOK);
  end;
  if CurUninstallStep = usPostUninstall then
  begin
    { Settings and logs are kept by default (and always on silent uninstall). }
    if DirExists(DataDir()) and not UninstallSilent() then
      if MsgBox('Also delete settings and logs in ' + DataDir() + '?', mbConfirmation,
        MB_YESNO or MB_DEFBUTTON2) = IDYES then
        DelTree(DataDir(), True, True, True);
  end;
end;

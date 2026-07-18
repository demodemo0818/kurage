; Kurage の Windows インストーラー定義 (Inno Setup 6)。
; tool\package_windows.ps1 から ISCC.exe に /D 定義付きで呼ばれる前提 (単体コンパイル不可):
;   StageDir       : kurage.exe ほか配布一式が入ったステージングフォルダ
;   AppVersion     : X.Y.Z[-pre] (表示用バージョン)
;   NumericVersion : X.Y.Z.BUILD (VersionInfo 用、数値 4 組)
;   OutputDir      : 出力先 (dist)
;   OutputBase     : 出力ファイル名 (拡張子なし)
;   RepoRoot       : リポジトリルート (アイコン参照用)

[Setup]
AppId={{A45EB0D9-43C0-4DB0-9649-457D550317A5}
AppName=Kurage
AppVersion={#AppVersion}
AppVerName=Kurage {#AppVersion}
AppPublisher=demodemo0818
AppPublisherURL=https://github.com/demodemo0818/kurage
AppSupportURL=https://github.com/demodemo0818/kurage/issues
VersionInfoVersion={#NumericVersion}
; 未署名のため UAC 昇格を要求しない「ユーザー単位インストール」にする
; ({autopf} は lowest では %LOCALAPPDATA%\Programs に解決される)
PrivilegesRequired=lowest
DefaultDirName={autopf}\Kurage
DefaultGroupName=Kurage
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBase}
SetupIconFile={#RepoRoot}\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\kurage.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "japanese"; MessagesFile: "compiler:Languages\Japanese.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Kurage"; Filename: "{app}\kurage.exe"
Name: "{autodesktop}\Kurage"; Filename: "{app}\kurage.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\kurage.exe"; Description: "{cm:LaunchProgram,Kurage}"; Flags: nowait postinstall skipifsilent

; アンインストール時、設定・アカウント (%APPDATA%\Kurage) とタイムラインキャッシュは
; 意図的に削除しない (ポータブル zip 版と共通のユーザーデータ。完全削除の手順は
; 同梱の「お読みください.txt」に記載)。

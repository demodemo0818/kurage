<#
.SYNOPSIS
  Kurage の Windows テスター配布用 zip を生成する。

.DESCRIPTION
  release ビルド → Release フォルダ一式 + VC++ ランタイム DLL を同梱 →
  dist\kurage-vX.Y.Z[-pre]-windows.zip を出力する。
  バージョンは pubspec.yaml の version: から取り (Android APK と同じ命名規則)、
  +BUILD は zip 名に含めない (タグと同じ vX.Y.Z[-pre])。

  未署名のため、テスターは初回 SmartScreen で「詳細情報」→「実行」が必要。
  詳細は RELEASING.md「Windows 配布」を参照。

.PARAMETER SkipBuild
  既存の Release ビルドをそのまま zip 化する (flutter build を再実行しない)。

.PARAMETER SkipInstaller
  Inno Setup によるインストーラー (dist\kurage-vX.Y.Z[-pre]-setup.exe) を生成しない。
  なお Inno Setup (ISCC.exe) が見つからない場合は指定しなくても警告してスキップする。

.EXAMPLE
  pwsh tool\package_windows.ps1
#>
[CmdletBinding()]
param(
  [switch]$SkipBuild,
  [switch]$SkipInstaller
)

$ErrorActionPreference = 'Stop'

# リポジトリルート = このスクリプトの 1 つ上の階層
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# --- 1. pubspec.yaml から version を取得 (X.Y.Z[-pre]+BUILD) -----------------
$m = Select-String -Path (Join-Path $root 'pubspec.yaml') -Pattern '^version:\s*(\S+)'
if (-not $m) { throw 'pubspec.yaml の version: を読めませんでした' }
$fullVersion = $m.Matches[0].Groups[1].Value          # 例: 0.8.2-alpha+15
$verNoBuild  = ($fullVersion -split '\+')[0]           # 例: 0.8.2-alpha
$tag         = "v$verNoBuild"                          # 例: v0.8.2-alpha
Write-Host "[package] version=$fullVersion -> $tag" -ForegroundColor Cyan

# --- 2. release ビルド -------------------------------------------------------
$releaseDir = Join-Path $root 'build\windows\x64\runner\Release'
if (-not $SkipBuild) {
  Write-Host '[package] flutter build windows --release ...' -ForegroundColor Cyan
  & flutter build windows --release
  if ($LASTEXITCODE -ne 0) { throw "flutter build windows --release が失敗 (exit $LASTEXITCODE)" }
}
$exe = Join-Path $releaseDir 'kurage.exe'
if (-not (Test-Path $exe)) {
  throw "kurage.exe が見つかりません: $releaseDir`n(BINARY_NAME=kurage でのビルドが必要。-SkipBuild を外して再実行)"
}

# --- 3. ステージングへコピー -------------------------------------------------
$stageRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("kurage_pkg_" + [guid]::NewGuid().ToString('N'))
$stage     = Join-Path $stageRoot "Kurage-$tag"        # zip 内のトップフォルダ名
New-Item -ItemType Directory -Path $stage -Force | Out-Null
try {
  Copy-Item -Path (Join-Path $releaseDir '*') -Destination $stage -Recurse -Force
  # 配布に不要なビルド中間生成物を除去 (import/export/static lib・デバッグシンボル)。
  # ランタイムには .dll / .exe / data\ だけが必要。
  Get-ChildItem -Path $stage -Include *.lib, *.exp, *.pdb -File -Recurse |
    Remove-Item -Force -ErrorAction SilentlyContinue

  # --- 4. VC++ ランタイム DLL を app-local 同梱 ------------------------------
  # テスターが VC++ 再頒布可能パッケージ未導入でも起動できるよう、exe の隣に置く。
  #
  # 【重要】同梱する CRT は **ビルドに使った MSVC ツールセット以上** でなければ
  # ならない。exe の隣に置いた msvcp140.dll は System32 より優先ロードされるため、
  # 古いものを掴ませると「起動はするが特定機能だけ落ちる」という厄介な壊れ方をする。
  # v1.2.0 の Windows 版で動画再生がクラッシュしたのがこれ (GitHub Issue #1):
  # GitHub Actions ランナーは VS2026 の Redist 配下に旧世代 (Microsoft.VC142.CRT /
  # 14.29) も同居させており、ソート無しの Select -First 1 がそれを掴む一方、
  # ビルドは VS2026 の 14.51 で行われていた。
  $crtNames = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
  $crtDir = $null
  $toolsetVersion = $null
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (Test-Path $vswhere) {
    $vsPath = & $vswhere -latest -products * -property installationPath 2>$null | Select-Object -First 1
    if ($vsPath) {
      # CMake (= flutter build windows) が既定で使うツールセットのバージョン。
      # 同梱 CRT の下限判定に使う。
      $defaultTxt = Join-Path $vsPath 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt'
      if (Test-Path $defaultTxt) { $toolsetVersion = (Get-Content $defaultTxt -Raw).Trim() }

      $redistRoot = Join-Path $vsPath 'VC\Redist\MSVC'
      # ...\<version>\x64\Microsoft.VC14x.CRT\msvcp140.dll (デスクトップ版) を探す。
      # onecore / spectre / store / debug_nonredist バリアントは通常のデスクトップ
      # アプリ向けではないので除外する (誤って onecore CRT を同梱すると一部 API で
      # 問題が出うる)。
      # 複数バージョンが同居している環境 (CI ランナー) で古いものを引かないよう、
      # **ファイルバージョン降順で最新を採る**。列挙順に依存させないこと。
      # 注: VersionInfo.FileVersion は文字列で、Microsoft 配布の DLL では
      # "14.29.30157.0 built by: cloudtest" のように接尾辞が付くことがあり
      # [version] にキャストできない。必ず数値フィールド (File*Part) を使う。
      $hit = Get-ChildItem -Path $redistRoot -Recurse -Filter 'msvcp140.dll' -ErrorAction SilentlyContinue |
             Where-Object {
               $_.FullName -match '\\x64\\' -and
               $_.FullName -notmatch '\\(onecore|spectre|store|debug_nonredist)\\'
             } |
             Sort-Object -Descending `
               @{ Expression = { $_.VersionInfo.FileMajorPart } },
               @{ Expression = { $_.VersionInfo.FileMinorPart } },
               @{ Expression = { $_.VersionInfo.FileBuildPart } },
               @{ Expression = { $_.VersionInfo.FilePrivatePart } } |
             Select-Object -First 1
      if ($hit) { $crtDir = $hit.DirectoryName }
    }
  }
  # フォールバック: System32 (VS 導入済みマシンには必ずある)
  if (-not $crtDir -and (Test-Path (Join-Path $env:WINDIR 'System32\msvcp140.dll'))) {
    $crtDir = Join-Path $env:WINDIR 'System32'
  }
  if ($crtDir) {
    # 選ばれた CRT がツールセットより古くないか検証する。古いまま zip を作ると
    # 実行時にしか気付けない壊れ方をするので、黙って続行せずここで止める。
    # 比較は Major.Minor まで (同一 Minor 内のビルド番号差は互換とみなす)。
    $crtInfo = (Get-Item (Join-Path $crtDir 'msvcp140.dll')).VersionInfo
    $crtVersion = '{0}.{1}.{2}.{3}' -f $crtInfo.FileMajorPart, $crtInfo.FileMinorPart,
                                       $crtInfo.FileBuildPart, $crtInfo.FilePrivatePart
    if ($toolsetVersion) {
      $tv = [version]$toolsetVersion
      $cv = [version]$crtVersion
      if ($cv.Major -lt $tv.Major -or ($cv.Major -eq $tv.Major -and $cv.Minor -lt $tv.Minor)) {
        throw @"
同梱しようとした VC++ ランタイムがビルドに使ったツールセットより古いため中断しました。
  ツールセット : $toolsetVersion
  CRT          : $crtVersion ($crtDir)
古い CRT を app-local 同梱すると、起動はできても実行時に機能単位でクラッシュします
(v1.2.0 の Windows 動画再生クラッシュ / GitHub Issue #1)。
VS Installer で「C++ 再頒布可能パッケージ」を最新に更新してから再実行してください。
"@
      }
    } else {
      Write-Warning 'MSVC ツールセットのバージョンを特定できなかったため、同梱 CRT の新旧チェックをスキップしました。'
    }
    foreach ($n in $crtNames) {
      $p = Join-Path $crtDir $n
      if (Test-Path $p) { Copy-Item $p -Destination $stage -Force }
      else { Write-Warning "VC++ ランタイムが見つかりません: $n (テスター環境で要 VC++ 再頒布可能パッケージ)" }
    }
    Write-Host "[package] VC++ ランタイム同梱元: $crtDir (CRT $crtVersion / toolset $toolsetVersion)" -ForegroundColor Cyan
  } else {
    Write-Warning 'VC++ ランタイム DLL の場所を特定できませんでした。zip に未同梱です (テスターは VC++ 再頒布可能パッケージの導入が必要)。'
  }

  # --- 5. テスター向け README を同梱 ----------------------------------------
  $readme = @"
Kurage $tag (Windows / ポータブル版)

【使い方】
  この中の kurage.exe をダブルクリックすると起動します。インストール不要です。
  フォルダごと好きな場所に置いて構いません。

【初回に「Windows によって PC が保護されました」と出たら】
  未署名アプリのため SmartScreen の警告が出ます。
  「詳細情報」をクリック →「実行」で起動できます (初回のみ)。

【データの保存場所】
  設定・アカウント・タイムラインのキャッシュは、この exe フォルダの中ではなく
  Windows のユーザーごとの場所に保存されます。そのため、別のフォルダにコピーして
  実行しても同じデータ (ログイン状態など) が引き継がれます。
    ・設定／アカウント       : %APPDATA%\Kurage
    ・タイムラインのキャッシュ : ドキュメント フォルダ内の timelinecache.hive
  ※ エクスプローラーのアドレス欄に %APPDATA%\Kurage と入力すると開けます。

【アンインストール (完全に消す場合)】
  1. このフォルダを削除
  2. %APPDATA%\Kurage フォルダを削除 (アカウント情報を残さないため)
  3. ドキュメント フォルダの timelinecache.hive と timelinecache.lock を削除
  ※ 2 を消すとログイン情報も消えます。残したい場合は 1 だけでも構いません。

ご質問・不具合報告はお手数ですが開発者までお願いします。
"@
  Set-Content -Path (Join-Path $stage 'お読みください.txt') -Value $readme -Encoding UTF8

  # --- 6. zip 化 ------------------------------------------------------------
  $distDir = Join-Path $root 'dist'
  New-Item -ItemType Directory -Path $distDir -Force | Out-Null
  $zipPath = Join-Path $distDir "kurage-$tag-windows.zip"
  if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
  Compress-Archive -Path $stage -DestinationPath $zipPath -CompressionLevel Optimal

  $zi = Get-Item $zipPath
  Write-Host ("[package] OK -> {0} ({1:N1} MB)" -f $zi.FullName, ($zi.Length / 1MB)) -ForegroundColor Green

  # --- 7. インストーラー生成 (Inno Setup、導入済み環境のみ) -------------------
  # GitHub Actions の windows ランナーにはプレインストール済み。ローカルに無い場合は
  # 警告してスキップする (winget install JRSoftware.InnoSetup で導入可)。
  if (-not $SkipInstaller) {
    $iscc = (Get-Command iscc.exe -ErrorAction SilentlyContinue).Source
    if (-not $iscc) {
      foreach ($cand in @(
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
      )) {
        if (Test-Path $cand) { $iscc = $cand; break }
      }
    }
    if ($iscc) {
      # VersionInfoVersion 用の数値 4 組 (X.Y.Z.BUILD)。prerelease suffix は落とす。
      $build = ($fullVersion -split '\+')[1]
      if (-not $build) { $build = '0' }
      $numeric = (($verNoBuild -split '-')[0]) + ".$build"
      $setupBase = "kurage-$tag-setup"
      Write-Host "[package] Inno Setup でインストーラー生成: $iscc" -ForegroundColor Cyan
      & $iscc /Qp "/DStageDir=$stage" "/DAppVersion=$verNoBuild" "/DNumericVersion=$numeric" `
        "/DOutputDir=$distDir" "/DOutputBase=$setupBase" "/DRepoRoot=$root" `
        (Join-Path $root 'tool\installer.iss')
      if ($LASTEXITCODE -ne 0) { throw "ISCC が失敗 (exit $LASTEXITCODE)" }
      $si = Get-Item (Join-Path $distDir "$setupBase.exe")
      Write-Host ("[package] OK -> {0} ({1:N1} MB)" -f $si.FullName, ($si.Length / 1MB)) -ForegroundColor Green
    } else {
      Write-Warning 'Inno Setup (ISCC.exe) が見つからないため、インストーラー生成をスキップしました (zip のみ)。'
    }
  }
}
finally {
  if (Test-Path $stageRoot) { Remove-Item $stageRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

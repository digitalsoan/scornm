<#
.SYNOPSIS
    Verified Android Direct-APK Release Publisher for SCORNM (digitalsoan/scornm).

.DESCRIPTION
    Channel boundary:
      - Google Play Store: AAB built and uploaded via scornm-app/publish_to_playstore.ps1 or deploy_playstore.yml.
      - Direct APK channel: Signed release APK published to an immutable GitHub Release tag
        v<versionName>+<versionCode> in digitalsoan/scornm, then verified before updating
        scornm-web/config/mobile_app_update.json.
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$SkipBuild,
    [string]$TestApkPath = "",
    [string]$ExpectedPackage = "com.scornm.app",
    [string]$ExpectedCertSha256 = "",
    [string]$SimulateBuildFailure = ""
)

$ErrorActionPreference = "Stop"

$AppDir = "E:\scornm-app"
$PubRepoDir = "E:\scornm"
$WebConfigPath = "E:\scornm-web\config\mobile_app_update.json"
$PubspecPath = Join-Path $AppDir "pubspec.yaml"

# Locate Android SDK build-tools (aapt2 / apksigner)
$SdkRoot = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { "C:\Android\sdk" }
$BuildToolsRoot = Join-Path $SdkRoot "build-tools"
$LatestBuildTools = Get-ChildItem -Path $BuildToolsRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
if (-not $LatestBuildTools) {
    throw "Android SDK build-tools not found under $BuildToolsRoot"
}
$Aapt2 = Join-Path $LatestBuildTools.FullName "aapt2.exe"
$Apksigner = Join-Path $LatestBuildTools.FullName "apksigner.bat"
if (-not (Test-Path $Aapt2) -or -not (Test-Path $Apksigner)) {
    throw "Required build-tools missing (aapt2.exe / apksigner.bat) in $($LatestBuildTools.FullName)"
}

# 1. Read expected version from pubspec.yaml
$PubspecContent = Get-Content -Path $PubspecPath -Raw
if ($PubspecContent -notmatch '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$') {
    throw "Could not parse version: <name>+<code> from $PubspecPath"
}
$VersionName = $Matches[1]
$VersionCode = [int]$Matches[2]
$TagName = "v$VersionName+$VersionCode"
$ImmutableApkUrl = "https://github.com/digitalsoan/scornm/releases/download/v$VersionName%2B$VersionCode/scornm.apk"

Write-Host "Target release: $ExpectedPackage $VersionName ($VersionCode) -> tag $TagName" -ForegroundColor Cyan

# 2. Build APK (or use provided TestApkPath in -SkipBuild/-DryRun mode)
$BuiltApk = Join-Path $AppDir "build\app\outputs\flutter-apk\app-release.apk"
if (-not $SkipBuild) {
    if ($SimulateBuildFailure -eq "1") {
        throw "Simulated Flutter APK build failure; aborting before touching $PubRepoDir\scornm.apk."
    }
    Push-Location $AppDir
    try {
        flutter build apk --release
        if ($LASTEXITCODE -ne 0) {
            throw "flutter build apk --release failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
} elseif ($TestApkPath -ne "") {
    $BuiltApk = $TestApkPath
}

if (-not (Test-Path $BuiltApk)) {
    throw "Built APK not found at $BuiltApk"
}

# 3. Stage into a temporary file first (never leave a stale or corrupt scornm.apk in E:\scornm)
$StageApk = Join-Path ([System.IO.Path]::GetTempPath()) ("scornm_stage_" + [System.Guid]::NewGuid().ToString("N") + ".apk")
Copy-Item -Force $BuiltApk $StageApk

try {
    $FileInfo = Get-Item $StageApk
    if ($FileInfo.Length -le 0) {
        throw "Zero-byte APK artifact detected at $BuiltApk ($($FileInfo.Length) bytes)."
    }

    # 4. Verify APK manifest (package, versionCode, versionName)
    $Badging = & $Aapt2 dump badging $StageApk 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "aapt2 dump badging failed: $($Badging -join "`n")"
    }
    $BadgingText = $Badging -join "`n"
    if ($BadgingText -notmatch "package:\s+name='([^']+)'\s+versionCode='([^']+)'\s+versionName='([^']+)'") {
        throw "Could not parse package/versionCode/versionName from aapt2 badging output."
    }
    $ActualPkg = $Matches[1]
    $ActualCode = [int]$Matches[2]
    $ActualName = $Matches[3]

    if ($ActualPkg -ne $ExpectedPackage) {
        throw "Package mismatch: expected '$ExpectedPackage', got '$ActualPkg'"
    }
    if ($ActualCode -ne $VersionCode -or $ActualName -ne $VersionName) {
        throw "Version mismatch: pubspec expects $VersionName+$VersionCode, APK has $ActualName+$ActualCode"
    }

    # 5. Verify APK signature & certificate digest
    $SigOut = & $Apksigner verify --print-certs $StageApk 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "apksigner verify failed: $($SigOut -join "`n")"
    }
    $SigText = $SigOut -join "`n"
    if ($SigText -notmatch 'Signer #1 certificate SHA-256 digest:\s*([0-9a-fA-F]{64})') {
        throw "Could not extract Signer #1 SHA-256 digest from apksigner output."
    }
    $ActualCertSha256 = $Matches[1].ToLowerInvariant()
    if ($ExpectedCertSha256 -ne "" -and $ActualCertSha256 -ne $ExpectedCertSha256.ToLowerInvariant()) {
        throw "Signing certificate mismatch: expected $ExpectedCertSha256, got $ActualCertSha256"
    }

    $ApkSha256 = (Get-FileHash -Path $StageApk -Algorithm SHA256).Hash.ToLowerInvariant()
    $ApkSize = $FileInfo.Length

    Write-Host "Verified APK: $ActualPkg $ActualName+$ActualCode | size=$ApkSize | sha256=$ApkSha256 | cert=$ActualCertSha256" -ForegroundColor Green

    if ($DryRun) {
        Write-Host "[DRY RUN] Would stage scornm.apk via Git LFS, create GitHub release $TagName, verify download, and update $WebConfigPath -> $ImmutableApkUrl" -ForegroundColor Yellow
        return
    }

    # 6. Copy verified APK to E:\scornm\scornm.apk and commit ONLY scornm.apk & .gitattributes via Git LFS
    Push-Location $PubRepoDir
    try {
        git lfs install --local | Out-Null
        Copy-Item -Force $StageApk (Join-Path $PubRepoDir "scornm.apk")
        git add .gitattributes scornm.apk
        $LfsTracked = git lfs ls-files
        if ($LASTEXITCODE -ne 0 -or ($LfsTracked -notmatch 'scornm\.apk')) {
            throw "Git LFS pointer verification failed for scornm.apk"
        }
        git commit -m "Release Android APK $TagName"
        if ($LASTEXITCODE -ne 0) {
            throw "git commit failed"
        }
        git push origin main
        if ($LASTEXITCODE -ne 0) {
            throw "git push origin main failed"
        }

        # 7. Create or update immutable GitHub Release and upload scornm.apk
        $ExistingTag = gh release view $TagName --repo digitalsoan/scornm --json tagName 2>$null
        if ($LASTEXITCODE -eq 0 -and $ExistingTag) {
            gh release upload $TagName scornm.apk --repo digitalsoan/scornm --clobber
        } else {
            gh release create $TagName scornm.apk --repo digitalsoan/scornm --title "SCORNM Android $TagName" --notes "Verified release build $VersionName ($VersionCode). SHA-256: $ApkSha256"
        }
        if ($LASTEXITCODE -ne 0) {
            throw "GitHub release upload failed for $TagName"
        }
    } finally {
        Pop-Location
    }

    # 8. Verify downloadable asset matches digest & size BEFORE updating mobile_app_update.json
    $VerifyFile = Join-Path ([System.IO.Path]::GetTempPath()) ("scornm_verify_" + [System.Guid]::NewGuid().ToString("N") + ".apk")
    try {
        Invoke-WebRequest -Uri $ImmutableApkUrl -OutFile $VerifyFile -UseBasicParsing
        $DownloadedSha = (Get-FileHash -Path $VerifyFile -Algorithm SHA256).Hash.ToLowerInvariant()
        $DownloadedSize = (Get-Item $VerifyFile).Length
        if ($DownloadedSha -ne $ApkSha256 -or $DownloadedSize -ne $ApkSize) {
            throw "Downloaded asset verification failed! Expected ($ApkSize, $ApkSha256), got ($DownloadedSize, $DownloadedSha)"
        }
    } finally {
        if (Test-Path $VerifyFile) { Remove-Item -Force $VerifyFile }
    }

    # 9. Update scornm-web/config/mobile_app_update.json atomically
    $Config = Get-Content -Path $WebConfigPath -Raw | ConvertFrom-Json
    $Config.latest_version = "$VersionName+$VersionCode"
    $Config.latest_build_number = $VersionCode
    $Config.apk_url = $ImmutableApkUrl
    $Config | Add-Member -NotePropertyName "apk_sha256" -NotePropertyValue $ApkSha256 -Force
    $Config | Add-Member -NotePropertyName "apk_size_bytes" -NotePropertyValue $ApkSize -Force
    $Config.published_at = (Get-Date -Format "yyyy-MM-dd")
    $Config | ConvertTo-Json -Depth 5 | Set-Content -Path $WebConfigPath -Encoding UTF8

    Write-Host "Published & verified $TagName and updated $WebConfigPath" -ForegroundColor Green
} finally {
    if (Test-Path $StageApk) { Remove-Item -Force $StageApk }
}

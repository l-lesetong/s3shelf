[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,
    [string]$Output = (Join-Path (Split-Path $PSScriptRoot -Parent) 'outputs'),
    [string]$MakeNSIS = 'makensis'
)

$ErrorActionPreference = 'Stop'
$project = Join-Path $PSScriptRoot 'S3Shelf/S3Shelf.csproj'
$Output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Output)
$null = New-Item -ItemType Directory -Path $Output -Force
$buildTime = [DateTimeOffset]::UtcNow.ToOffset([TimeSpan]::FromHours(8))
$buildTimestamp = $buildTime.ToString('yyyyMMdd-HHmmss-fff', [Globalization.CultureInfo]::InvariantCulture) + '+0800'
if ($Version) {
    $artifactId = $Version
} else {
    $projectXml = [xml](Get-Content -LiteralPath $project -Raw)
    $Version = $projectXml.SelectSingleNode('/Project/PropertyGroup/Version').InnerText
    $artifactId = $buildTimestamp
}

$msbuild = Get-Command msbuild -ErrorAction SilentlyContinue
$prefix = @()
if (-not $msbuild) {
    $msbuild = Get-Command dotnet
    $prefix = @('msbuild')
}
& $msbuild @prefix $project -restore -t:Build -p:Configuration=Release -p:RestoreLockedMode=true "-p:Version=$Version" -v:minimal
if ($LASTEXITCODE -ne 0) { throw "MSBuild failed with exit code $LASTEXITCODE." }

$release = Join-Path $PSScriptRoot 'S3Shelf/bin/Release/net48'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('s3shelf-' + [Guid]::NewGuid().ToString('N'))
$payload = Join-Path $scratch 's3Shelf'
$null = New-Item -ItemType Directory -Path $payload
try {
    Copy-Item -LiteralPath @((Join-Path $release 's3Shelf.exe'), (Join-Path $release 's3Shelf.exe.config')) -Destination $payload
    $assets = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'S3Shelf/obj/project.assets.json') -Raw | ConvertFrom-Json
    $packageEntries = $assets.targets.'.NETFramework,Version=v4.8'.PSObject.Properties | Sort-Object Name
    $notices = Join-Path $payload 'ThirdPartyNotices.txt'
    Set-Content -LiteralPath $notices -Value 's3Shelf includes the following NuGet packages.' -Encoding UTF8
    Add-Content -LiteralPath $notices -Value $packageEntries.Name -Encoding UTF8
    foreach ($name in @('AWS-LICENSE.txt', 'AWS-NOTICE.txt', 'Microsoft-LICENSE.txt')) {
        Add-Content -LiteralPath $notices -Value "`n$name`n" -Encoding UTF8
        Get-Content -LiteralPath (Join-Path $PSScriptRoot "S3Shelf/ThirdParty/$name") -Raw | Add-Content -LiteralPath $notices -Encoding UTF8
    }
    $seenNotices = @{}
    foreach ($package in $packageEntries) {
        $packagePath = $assets.libraries.PSObject.Properties[$package.Name].Value.path
        $packageDirectory = $assets.packageFolders.PSObject.Properties.Name | ForEach-Object { Join-Path $_ $packagePath } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -First 1
        if (-not $packageDirectory) { throw "Unable to locate NuGet package $($package.Name)." }
        foreach ($asset in $package.Value.runtime.PSObject.Properties) {
            if ($asset.Name -like '*.dll') {
                $binary = Join-Path $release (Split-Path $asset.Name -Leaf)
                Copy-Item -LiteralPath $binary -Destination $payload
            }
        }
        foreach ($notice in Get-ChildItem -LiteralPath $packageDirectory -File | Where-Object { $_.Name -match '^(license|notice|third-party-notices)(\.|$)' }) {
            $hash = (Get-FileHash -LiteralPath $notice.FullName).Hash
            if ($seenNotices.ContainsKey($hash)) { continue }
            $seenNotices[$hash] = $true
            Add-Content -LiteralPath $notices -Value "`n$($package.Name) / $($notice.Name)`n" -Encoding UTF8
            Get-Content -LiteralPath $notice.FullName -Raw | Add-Content -LiteralPath $notices -Encoding UTF8
        }
    }
    $files = Get-ChildItem -LiteralPath $payload -File | Sort-Object Name
    $list = Join-Path $scratch 'payload.nsh'
    $files | ForEach-Object { '!insertmacro PayloadFile "' + $_.Name + '"' } | Set-Content -LiteralPath $list -Encoding ASCII
    $base = "s3Shelf-$artifactId-Windows"
    $setup = Join-Path $scratch "$base-Setup.exe"
    $switch = if ([Environment]::OSVersion.Platform -eq 'Win32NT') { '/D' } else { '-D' }
    & $MakeNSIS "${switch}VERSION=$Version" "${switch}BUILD_TIMESTAMP=$buildTimestamp" "${switch}PAYLOAD=$payload" "${switch}PAYLOAD_LIST=$list" "${switch}SETUP=$setup" (Join-Path $PSScriptRoot 'installer/s3shelf.nsi')
    if ($LASTEXITCODE -ne 0) { throw "NSIS failed with exit code $LASTEXITCODE." }
    $zip = Join-Path $scratch "$base-Portable.zip"
    Compress-Archive -LiteralPath $payload -DestinationPath $zip
    Copy-Item -LiteralPath @($setup, $zip) -Destination $Output -Force
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force
}

$ErrorActionPreference = 'Stop'

$companionDir = Split-Path -Parent $PSScriptRoot

$pkgid = cargo pkgid --manifest-path "$companionDir/Cargo.toml" --package arbitrage-companion
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$version = ($pkgid -split '[#@]')[-1]

$iscc = (Get-Command iscc -ErrorAction SilentlyContinue)?.Source ?? "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
& $iscc /Qp "/DAppVersion=$version" "$companionDir/app/windows/installer.iss"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Output "Packaged Arbitrage Companion $version installer"

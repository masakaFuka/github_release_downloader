@echo off
setlocal
cd /d "%~dp0"

set /p "GITHUB_URL=github download URL: "

if "%GITHUB_URL%"=="" (
    echo No URL provided.
    pause
    exit /b 1
)

set "SCRIPT_FILE=%~f0"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
"$s = Get-Content -Raw -LiteralPath $env:SCRIPT_FILE; $p = $s.LastIndexOf(':POWERSHELL'); if ($p -lt 0) { exit 1 }; Invoke-Expression $s.Substring($p + 11)"

if errorlevel 1 (
    echo.
    echo Download failed.
    pause
    exit /b 1
)

pause
exit /b 0

:POWERSHELL

$ErrorActionPreference = 'Stop'
$url = $env:GITHUB_URL

try {
    $u = [Uri]$url
} catch {
    Write-Host 'Invalid URL.'
    exit 1
}

if ($u.Host -ne 'github.com') {
    Write-Host 'Only github.com URLs are supported.'
    exit 1
}

$name = [IO.Path]::GetFileName($u.AbsolutePath)

if (!$name) {
    Write-Host 'Could not get file name.'
    exit 1
}

if (!(Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    Write-Host 'curl.exe was not found.'
    exit 1
}

$out = Join-Path (Get-Location) $name
$tmp = "$out.part"

$probeMin = 5MB
$downloadMin = 5MB

$finalUrl = & curl.exe -4 -L --fail --silent --connect-timeout 5 --max-time 15 --range 0-0 -o NUL -w '%{url_effective}' $url

if ($LASTEXITCODE -ne 0 -or !$finalUrl) {
    Write-Host 'Could not resolve GitHub download host.'
    exit 1
}

try {
    $hostName = ([Uri]$finalUrl.Trim()).Host
} catch {
    Write-Host 'Could not resolve GitHub download host.'
    exit 1
}

Write-Host "Asset host: $hostName"

while ($true) {
    Write-Host
    Write-Host 'Checking routes...'

    $routes = @()

    Write-Host -NoNewline '  auto ... '

    $speed = & curl.exe -4 -L --fail --silent `
        --connect-timeout 3 `
        --max-time 5 `
        --range 0-8388607 `
        -o NUL `
        -w '%{speed_download}' `
        $url 2>$null

    if ($LASTEXITCODE -eq 0) {
        $speed = [double]$speed
    } else {
        $speed = 0
    }

    Write-Host ('{0:0.00} MiB/s' -f ($speed / 1MB))

    if ($speed -ge $probeMin) {
        $routes += [PSCustomObject]@{
            IP = ''
            Speed = $speed
        }
    }

    try {
        $ips = [Net.Dns]::GetHostAddresses($hostName) |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
            ForEach-Object { $_.IPAddressToString } |
            Select-Object -Unique
    } catch {
        $ips = @()
    }

    foreach ($ip in $ips) {
        Write-Host -NoNewline "  $ip ... "

        $speed = & curl.exe `
            --resolve "${hostName}:443:$ip" `
            -4 `
            -L `
            --fail `
            --silent `
            --connect-timeout 3 `
            --max-time 5 `
            --range 0-8388607 `
            -o NUL `
            -w '%{speed_download}' `
            $url 2>$null

        if ($LASTEXITCODE -eq 0) {
            $speed = [double]$speed
        } else {
            $speed = 0
        }

        Write-Host ('{0:0.00} MiB/s' -f ($speed / 1MB))

        if ($speed -ge $probeMin) {
            $routes += [PSCustomObject]@{
                IP = $ip
                Speed = $speed
            }
        }
    }

    if (!$routes) {
        Write-Host 'Nothing fast enough. Trying again...'
        Start-Sleep -Seconds 1
        continue
    }

    $routes = $routes | Sort-Object Speed -Descending

    foreach ($r in $routes) {
        if ($r.IP) {
            $route = $r.IP
        } else {
            $route = 'auto'
        }

        Write-Host
        Write-Host ('Downloading through {0} ({1:0.00} MiB/s)' -f $route, ($r.Speed / 1MB))

        $args = @(
            '-4'
            '-L'
            '--fail'
            '--show-error'
            '--connect-timeout', '6'
            '--speed-limit', [string][int64]$downloadMin
            '--speed-time', '10'
            '-C', '-'
            '-o', $tmp
            $url
        )

        if ($r.IP) {
            $args = @(
                '--resolve'
                "${hostName}:443:$($r.IP)"
            ) + $args
        }

        & curl.exe @args

        if ($LASTEXITCODE -eq 0) {
            Move-Item -Force $tmp $out

            Write-Host
            Write-Host "Downloaded: $out"

            exit 0
        }

        Write-Host "Download stopped on $route."
        Write-Host 'Trying another route...'
    }

    Write-Host
    Write-Host 'No route worked. Checking again...'
    Start-Sleep -Seconds 1
}

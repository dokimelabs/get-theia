# get-theia - the theia installer for Windows.
#   irm https://dokimelabs.github.io/get-theia/install.ps1 | iex
#
# Releases are private. The installer asks the release gate for a device
# code, you sign in with Google, GitHub or Microsoft in a browser, and once
# your identity is on the allowlist the gate hands back a short-lived link
# to the archive. The archive is sha256-verified, unpacked into its own
# versioned directory, run once (a broken build never takes the `theia`
# name), and only then becomes `current` (a junction: no admin needed);
# the user PATH gains %LOCALAPPDATA%\Programs\theia\current.
#
#   $env:THEIA_VERSION         install an exact release (default: the latest)
#   $env:THEIA_HOME            where releases live (%LOCALAPPDATA%\Programs\theia)
#   $env:THEIA_AUTH_URL        the release gate (default below)
#   $env:THEIA_NO_MODIFY_PATH  1: never touch the user PATH
#   $env:THEIA_SIGN_IN         1: sign in again even with a saved credential
#
# The sign-in also leaves an install credential in the theia directory's
# .credentials.json (the "install" member): the next run, and `theia
# update`, trade it for a link without a browser for as long as the
# identity stays on the allowlist.
#
# ASCII only: `irm | iex` on Windows PowerShell 5.1 decodes a page served
# without a charset as Latin-1, which would garble any other character.
#
# `irm | iex` runs a script in the caller's own scope, so everything below
# runs in a script block of its own: no variable outlives the install (a
# second run in the same window once reused the first run's download
# link), and a failure prints one line instead of an error record.
try {
& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue' # Invoke-WebRequest is slow with the bar
    # Windows PowerShell 5.1 on an older .NET may not offer TLS 1.2 by itself.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $AuthUrl = if ($env:THEIA_AUTH_URL) { $env:THEIA_AUTH_URL } else { 'https://get-theia.dokimelabs.workers.dev' }
    $Version = if ($env:THEIA_VERSION) { $env:THEIA_VERSION.TrimStart('v') } else { 'latest' }
    $Root = if ($env:THEIA_HOME) { $env:THEIA_HOME } else { Join-Path $env:LOCALAPPDATA 'Programs\theia' }
    $Releases = Join-Path $Root 'releases'
    $Current = Join-Path $Root 'current'
    $Lock = Join-Path $Root 'install.lock.d'
    $CredFile = Join-Path $Root '.credentials.json'
    $previous = $null
    if (Test-Path $Current) { $previous = Split-Path -Leaf ([string](Get-Item $Current).Target) }

    function Write-Step([string]$m) { Write-Host "==> $m" }
    function Fail([string]$m) { throw $m }

    if ($Version -ne 'latest' -and $Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$') {
        Fail "THEIA_VERSION must look like 1.2.3, got '$Version'"
    }

    # The OS architecture: RuntimeInformation where .NET has it (Windows
    # PowerShell 5.1 does not load the type, so it reads as nothing), else
    # the environment (PROCESSOR_ARCHITEW6432 names the OS under a 32-bit
    # shell).
    $osArch = $null
    try { $osArch = [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture } catch {}
    if (-not $osArch) { $osArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE } }
    $arch = switch ($osArch) {
        'X64' { 'amd64' }
        'AMD64' { 'amd64' }
        'Arm64' { 'arm64' }
        default { Fail "unsupported architecture '$osArch'" }
    }
    Write-Step "theia for windows/$arch"

    # Invoke-Gate posts JSON and returns the parsed answer, error statuses
    # included: the gate answers "authorization_pending" with a 400.
    function Invoke-Gate([string]$path, [hashtable]$body) {
        try {
            Invoke-RestMethod -Method Post -Uri "$AuthUrl$path" -ContentType 'application/json' -Body ($body | ConvertTo-Json -Compress) -TimeoutSec 30
        } catch {
            $resp = $_.ErrorDetails.Message
            if ($resp) { return $resp | ConvertFrom-Json }
            Fail "the release gate did not answer: $($_.Exception.Message)"
        }
    }

    # A saved install credential buys the link without a browser while the
    # identity stays on the allowlist; without one (or once the gate stops
    # accepting it) the device sign-in follows.
    # .credentials.json: other members are kept as they are; only
    # "install" belongs to the installers.
    function Read-Credentials {
        if (-not (Test-Path $CredFile)) { return [pscustomobject]@{} }
        try { return (Get-Content -Raw $CredFile | ConvertFrom-Json) } catch { return [pscustomobject]@{} }
    }
    function Save-Credentials($creds) {
        New-Item -ItemType Directory -Force -Path $Root | Out-Null
        $tmp = "$CredFile.tmp.$PID"
        Set-Content -Path $tmp -Value ($creds | ConvertTo-Json -Depth 8) -Encoding ascii
        Move-Item -Force $tmp $CredFile
    }

    $link = $null
    $cred = (Read-Credentials).install.token
    if ($cred -and $env:THEIA_SIGN_IN -ne '1') {
        $answer = Invoke-Gate '/install/refresh' @{ install_token = $cred; os = 'windows'; arch = $arch; version = $Version }
        $err = $answer.error
        if ($err -eq 'access_denied') { Fail "$($answer.error_description) - ask the dokimelabs team for access" }
        if ($err -eq 'no_release') { Fail "no release for windows/${arch}: $($answer.error_description)" }
        if ($err -eq 'invalid_token') {
            Write-Host 'warning: the saved sign-in is no longer valid; sign in again'
            $creds = Read-Credentials
            $creds.PSObject.Properties.Remove('install')
            Save-Credentials $creds
        } elseif (-not $err -and $answer.url) {
            $link = $answer
            Write-Step "signed in as $($link.identity) (saved sign-in)"
        }
    }
    if (-not $link) {
        $code = Invoke-Gate '/device/code' @{ os = 'windows'; arch = $arch; version = $Version }
        if (-not $code.device_code) { Fail "the release gate refused: $($code.error_description)" }
        Write-Host ''
        Write-Host '  Sign in to download theia:'
        Write-Host ''
        Write-Host "    $($code.verification_uri)"
        Write-Host ''
        Write-Host "  and enter the code  $($code.user_code)"
        Write-Host ''
        if (-not $env:SSH_CONNECTION) { try { Start-Process "$($code.verification_uri)?code=$($code.user_code)" } catch {} }

        $link = $null
        $deadline = (Get-Date).AddSeconds([int]$code.expires_in)
        while (-not $link -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds ([int]$code.interval)
            $answer = Invoke-Gate '/device/token' @{ device_code = $code.device_code }
            $err = $answer.error
            if ($err -eq 'authorization_pending') { continue }
            if ($err -eq 'access_denied') { Fail "$($answer.error_description) - ask the dokimelabs team for access" }
            if ($err -eq 'expired_token') { Fail 'the sign-in expired; run the installer again' }
            if ($err -eq 'no_release') { Fail "no release for windows/${arch}: $($answer.error_description)" }
            if ($err) { Fail "the release gate answered: $err" }
            $link = $answer
        }
        if (-not $link) { Fail 'the sign-in timed out; run the installer again' }
        Write-Step "signed in as $($link.identity)"
    }
    if ($link.install_token) {
        $creds = Read-Credentials
        $install = [pscustomobject]@{
            token      = $link.install_token
            identity   = $link.identity
            gate       = $AuthUrl
            expires_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + [int64]$link.install_expires_in
        }
        $creds | Add-Member -Force -NotePropertyName install -NotePropertyValue $install
        Save-Credentials $creds
    }
    if ($previous -and $previous -ne $link.version) { Write-Step "updating theia $previous -> $($link.version)" }
    elseif ($previous) { Write-Step "theia $($link.version) is already installed; installing it again" }

    function Format-Size([long]$b) {
        if ($b -lt 1024) { return "$b B" }
        if ($b -lt 1048576) { return '{0:0.0} KB' -f ($b / 1024) }
        return '{0:0.0} MB' -f ($b / 1048576)
    }
    function Format-Clock([double]$s) {
        $s = [int][Math]::Floor($s)
        if ($s -lt 60) { return "${s}s" }
        return '{0}m{1:00}s' -f [Math]::Floor($s / 60), ($s % 60)
    }

    # Save-Download <url> <file>. On a console, one line redrawn in place shows
    # a spinner, the elapsed time, what has arrived of the total and what is
    # left; reads are asynchronous, so the line keeps turning while the network
    # stalls. Redirected output gets a silent download.
    function Save-Download([string]$url, [string]$path) {
        if ([Console]::IsOutputRedirected) {
            Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing
            return
        }
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Timeout = 30000
        $resp = $req.GetResponse()
        $in = $resp.GetResponseStream()
        $out = [System.IO.File]::Create($path)
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $width = 0
        try {
            $total = $resp.ContentLength # -1 when the gate sends no length
            $buf = New-Object byte[] 65536
            $got = 0L
            $tick = 0
            while ($true) {
                $read = $in.ReadAsync($buf, 0, $buf.Length)
                $since = $clock.Elapsed.TotalSeconds
                while (-not $read.Wait(100)) {
                    # an async read has no timeout of its own
                    if ($clock.Elapsed.TotalSeconds - $since -gt 60) { Fail 'the download stalled for a minute; run the installer again' }
                    $tick++
                    $width = Write-ProgressLine $tick $clock $got $total $width
                }
                $n = $read.Result
                if ($n -le 0) { break }
                $out.Write($buf, 0, $n)
                $got += $n
                $tick++
                $width = Write-ProgressLine $tick $clock $got $total $width
            }
        } finally {
            $out.Close(); $in.Close(); $resp.Close()
            [Console]::Write("`r" + (' ' * $width) + "`r")
        }
        Write-Host "    $(Format-Size $got) in $(Format-Clock $clock.Elapsed.TotalSeconds)"
    }
    function Write-ProgressLine([int]$tick, $clock, [long]$got, [long]$total, [int]$width) {
        $spin = '|/-\'[$tick % 4]
        $line = "    $spin $(Format-Clock $clock.Elapsed.TotalSeconds)  $(Format-Size $got)"
        if ($total -gt 0) { $line += " / $(Format-Size $total)  $(Format-Size ([Math]::Max(0, $total - $got))) left" }
        [Console]::Write("`r" + $line.PadRight($width))
        return [Math]::Max($width, $line.Length)
    }

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("theia-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $archive = Join-Path $tmp $link.asset
        Write-Step "downloading $($link.asset)"
        Save-Download $link.url $archive
        $got = (Get-FileHash -Algorithm SHA256 -Path $archive).Hash.ToLowerInvariant()
        if ($got -ne $link.sha256) { Fail "checksum mismatch for $($link.asset) (want $($link.sha256), got $got)" }

        New-Item -ItemType Directory -Force -Path $Releases | Out-Null
        try { New-Item -ItemType Directory -Path $Lock | Out-Null } catch { Fail "another install is running (remove $Lock if it is not)" }
        $staging = Join-Path $Releases ".staging.$PID"
        try {
            if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
            Expand-Archive -Path $archive -DestinationPath $staging
            $exe = Join-Path $staging 'theia.exe'
            if (-not (Test-Path $exe)) { Fail "$($link.asset) has no theia.exe" }
            & $exe --version *> $null
            if ($LASTEXITCODE -ne 0) { Fail 'the downloaded theia does not run on this machine' }

            # The release directory is in place before `current` moves, so a
            # failure leaves the old junction working. The same build already
            # installed is kept as is (Windows holds a running exe, so it could
            # not be replaced while theia runs); a different one that is running
            # fails here, before anything changed.
            $release = Join-Path $Releases $link.version
            $old = Join-Path $release 'theia.exe'
            if ((Test-Path $old) -and (Get-FileHash $old).Hash -eq (Get-FileHash $exe).Hash) {
                Remove-Item -Recurse -Force $staging
            } else {
                if (Test-Path $release) {
                    try { Remove-Item -Recurse -Force $release } catch { Fail "could not replace $release (close any running theia and retry)" }
                }
                Move-Item $staging $release
            }
            if (Test-Path $Current) { (Get-Item $Current).Delete() } # the junction, never its target
            New-Item -ItemType Junction -Path $Current -Target $release | Out-Null
        } finally {
            if (Test-Path $staging) { Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue }
            Remove-Item -Force $Lock -ErrorAction SilentlyContinue
        }
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }

    # The user PATH is edited in the registry as written (%VARS% unexpanded,
    # its value kind kept): [Environment]::SetEnvironmentVariable would store
    # every entry expanded, as a plain string.
    function Add-UserPath([string]$dir) {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
        try {
            $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $entries = @($raw -split ';' | Where-Object { $_ })
            if ($entries -contains $dir) { return $false }
            $kind = if ($raw) { $key.GetValueKind('Path') } else { [Microsoft.Win32.RegistryValueKind]::ExpandString }
            $key.SetValue('Path', ((@($dir) + $entries) -join ';'), $kind)
        } finally { $key.Close() }
        # Tell running programs (Explorer, new terminals) that the environment
        # changed: setting any user variable broadcasts WM_SETTINGCHANGE.
        [Environment]::SetEnvironmentVariable('THEIA_INSTALLER', '1', 'User')
        [Environment]::SetEnvironmentVariable('THEIA_INSTALLER', $null, 'User')
        return $true
    }
    if ($env:THEIA_NO_MODIFY_PATH -eq '1') {
        $note = "$Current is not on PATH (THEIA_NO_MODIFY_PATH)"
    } elseif (Add-UserPath $Current) {
        $note = 'open a new terminal so PATH picks up theia'
    }
    if (($env:Path -split ';') -notcontains $Current) { $env:Path = "$Current;$env:Path" }
    & (Join-Path $Current 'theia.exe') --version *> $null
    if ($LASTEXITCODE -ne 0) { Fail "$Current\theia.exe does not run after install" }
    Write-Step "installed theia $($link.version) -> $Current\theia.exe"
    if ($note) { Write-Host "    $note" }
    Write-Host '    start with: theia'
}
} catch {
    Write-Host "error: $($_.Exception.Message)" -ForegroundColor Red
}

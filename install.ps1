# get-theia - first-stage installer for Windows (the install.sh contract,
# mirrored):
#
#   powershell -ExecutionPolicy Bypass -c "irm https://dokimelabs.github.io/get-theia/install.ps1 | iex"
#
# Authenticates against the private dokimelabs/theia-releases repository -
# GitHub SIGN-IN (RFC 8628 device flow, first-class) with a pasted PAT as
# the fallback ($env:THEIA_PAT for unattended installs) - resolves the
# latest RELEASE (or the $env:THEIA_VERSION pin, also the recovery lever:
# reinstalling any version over an existing install is supported and
# purges that version from the launcher cache), downloads, sha256-verifies
# the archive AND the unpacked payload manifest, RUN-verifies the staged
# binary BEFORE the install swaps (a broken artifact never captures the
# name), installs to %LOCALAPPDATA%\dokimelabs\theia\app, adds the USER
# PATH entry (no administrator), and stores the credential via the
# installed binary's own merge-preserving `theia setup --pat`.
# Idempotent; safe to re-run.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$REPO = 'dokimelabs/theia-releases'
$API  = "https://api.github.com/repos/$REPO"
# Mirrors BAKED_OAUTH_CLIENT_ID / install.sh DEVICE_CLIENT_ID (the
# registered dokimelabs "theia releases" GitHub App - Contents read-only on
# theia-releases alone; a client id is PUBLIC, and a GitHub App token
# carries the app's permission, never an OAuth scope).
$DEVICE_CLIENT_ID = if ($env:THEIA_OAUTH_CLIENT_ID) { $env:THEIA_OAUTH_CLIENT_ID } else { 'Iv23liXy3IWQ9kVHGLGD' }

function Fail($msg) { Write-Error "get-theia: $msg" }

# --- authentication ---------------------------------------------------
function Invoke-DeviceFlow {
    # RFC 8628 against github.com; returns the token or $null (any failure
    # falls back to the PAT prompt - sign-in problems must never strand an
    # install).
    try {
        $dc = Invoke-RestMethod -Method Post -Uri 'https://github.com/login/device/code' `
            -Headers @{ Accept = 'application/json' } `
            -Body @{ client_id = $DEVICE_CLIENT_ID }
    } catch { Write-Host "sign-in unavailable: $($_.Exception.Message)"; return $null }
    Write-Host ''
    Write-Host 'sign in with GitHub - open the page and enter the code:'
    Write-Host ''
    Write-Host "  $($dc.verification_uri)    code: $($dc.user_code)"
    Write-Host ''
    # mirrors SIGN_IN_ACCESS_NOTE in github-release-auth.ts
    Write-Host '  the GitHub page will say the app may "act on your behalf" - what it can'
    Write-Host "  actually reach is read-only release downloads from $REPO;"
    Write-Host '  it cannot read or change anything in your own repositories.'
    Write-Host ''
    $interval = [Math]::Max([int]$dc.interval, 5)
    $deadline = (Get-Date).AddSeconds([int]$dc.expires_in)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $interval
        try {
            $poll = Invoke-RestMethod -Method Post -Uri 'https://github.com/login/oauth/access_token' `
                -Headers @{ Accept = 'application/json' } `
                -Body @{ client_id = $DEVICE_CLIENT_ID; device_code = $dc.device_code;
                         grant_type = 'urn:ietf:params:oauth:grant-type:device_code' }
        } catch { continue }
        if ($poll.access_token) { Write-Host 'signed in'; return $poll.access_token }
        switch ($poll.error) {
            'authorization_pending' { }
            'slow_down'     { $interval += 5 }
            'access_denied' { Write-Host 'sign-in was declined on the GitHub page'; return $null }
            default         { Write-Host "sign-in failed: $($poll.error)"; return $null }
        }
    }
    Write-Host 'sign-in timed out'
    return $null
}

$PAT = $env:THEIA_PAT
if (-not $PAT) {
    # A console on stdin is the interactivity test (install.sh's `[ -t 0 ]`):
    # [Environment]::UserInteractive is FALSE inside Windows OpenSSH and
    # WinRM sessions even with a real console attached (probed on the lab
    # VM: pty -> IsInputRedirected=False, UserInteractive=False), so the old
    # test silently skipped sign-in for anyone installing over ssh.
    if (-not [Console]::IsInputRedirected) {
        $pick = Read-Host 'sign in with GitHub (recommended), or paste a PAT? [S/p]'
        if ($pick -notmatch '^[Pp]') { $PAT = Invoke-DeviceFlow }
        if (-not $PAT) {
            $sec = Read-Host "GitHub PAT for $REPO (input hidden)" -AsSecureString
            $PAT = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                   [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
        }
    }
}
if (-not $PAT) { Fail 'no credential - sign in interactively, or set THEIA_PAT (the releases repo is private)' }

$headers = @{ Authorization = "Bearer $PAT"; Accept = 'application/vnd.github+json' }

# --- resolve release (latest, or the THEIA_VERSION pin) ----------------
if ($env:THEIA_VERSION) {
    $want = 'v' + $env:THEIA_VERSION.TrimStart('v')
    Write-Host "resolving pinned release $want of $REPO..."
    try { $rel = Invoke-RestMethod -Uri "$API/releases/tags/$want" -Headers $headers }
    catch { Fail "release $want not found in $REPO (check the version and the credential)" }
} else {
    Write-Host "resolving latest release of $REPO..."
    try { $rel = Invoke-RestMethod -Uri "$API/releases/latest" -Headers $headers }
    catch { Fail "cannot reach $REPO (check the credential's repo access and network)" }
}
$TAG = $rel.tag_name; $VER = $TAG.TrimStart('v')
$ASSET = "theia-$TAG-windows-x86_64.tar.gz"
Write-Host "latest: $TAG -> $ASSET"

$tarAsset = $rel.assets | Where-Object name -eq $ASSET
$sumAsset = $rel.assets | Where-Object name -eq 'checksums.txt'
if (-not $tarAsset) { Fail "release $TAG carries no asset $ASSET" }
if (-not $sumAsset) { Fail "release $TAG carries no checksums.txt - refusing to install unverified" }

# --- download + verify --------------------------------------------------
$tmp = Join-Path $env:TEMP ("get-theia-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
    $dl = @{ Authorization = "Bearer $PAT"; Accept = 'application/octet-stream' }
    Write-Host "downloading $ASSET..."
    Invoke-WebRequest -Uri $tarAsset.url -Headers $dl -OutFile (Join-Path $tmp $ASSET)
    Invoke-WebRequest -Uri $sumAsset.url -Headers $dl -OutFile (Join-Path $tmp 'checksums.txt')
    $wantLine = Select-String -Path (Join-Path $tmp 'checksums.txt') -Pattern ([regex]::Escape($ASSET)) | Select-Object -First 1
    if (-not $wantLine) { Fail "checksums.txt has no entry for $ASSET" }
    $wantSha = ($wantLine.Line -split '\s+')[0].ToLower()
    $gotSha = (Get-FileHash -Algorithm SHA256 (Join-Path $tmp $ASSET)).Hash.ToLower()
    if ($wantSha -ne $gotSha) { Fail "checksum mismatch (want $wantSha, got $gotSha)" }
    Write-Host 'sha256 verified'

    # extract with the in-box bsdtar (System32 - reads .tar.gz natively)
    $x = Join-Path $tmp 'x'
    New-Item -ItemType Directory -Force $x | Out-Null
    & "$env:SystemRoot\System32\tar.exe" -xzf (Join-Path $tmp $ASSET) -C $x
    if ($LASTEXITCODE -ne 0) { Fail 'archive extraction failed' }
    $payload = Join-Path $x 'theia-win-x64'
    if (-not (Test-Path (Join-Path $payload 'theia.exe'))) { Fail "unexpected archive layout - no theia-win-x64\theia.exe" }

    # payload manifest (the kit's per-file sha256 sweep, THE-063's second gate)
    $manifest = Join-Path $x 'payload-sha256.txt'
    if (Test-Path $manifest) {
        Write-Host 'verifying payload manifest (sha256)...'
        $bad = 0; $n = 0
        foreach ($line in Get-Content $manifest) {
            if ($line.Trim() -eq '') { continue }
            $parts = $line -split '\s+', 2
            $f = Join-Path $x ($parts[1].Trim() -replace '/', '\')
            $n++
            if (-not (Test-Path $f)) { Fail "payload manifest names a missing file: $($parts[1])" }
            if ((Get-FileHash -Algorithm SHA256 $f).Hash.ToLower() -ne $parts[0].ToLower()) { $bad++ }
        }
        if ($bad -gt 0) { Fail "payload integrity failed ($bad of $n files)" }
        Write-Host "payload manifest: OK ($n files)"
    }

    # --- run-verify BEFORE the swap, then stage-then-swap ---------------
    $staged = & (Join-Path $payload 'theia.exe') version 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $staged) {
        Fail 'the downloaded binary does not run on this system - previous install (if any) left untouched'
    }
    $root = Join-Path $env:LOCALAPPDATA 'dokimelabs\theia'
    $dest = Join-Path $root 'app'
    New-Item -ItemType Directory -Force $root | Out-Null
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    Move-Item $payload $dest
    Write-Host "installed theia $TAG -> $dest"

    # --- PATH (user scope, no administrator) -----------------------------
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($null -eq $userPath) { $userPath = '' }
    if (($userPath -split ';') -notcontains $dest) {
        [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $dest).TrimStart(';'), 'User')
        Write-Host "PATH: added $dest (new terminals see the theia command)"
    } else { Write-Host "PATH: already carries $dest" }
    $env:Path = $dest + ';' + $env:Path

    # clear this version from the launcher cache: a corrupt cached copy
    # would otherwise keep resurfacing through --x-release / self update
    $cache = Join-Path $env:LOCALAPPDATA 'dokimelabs\theia\Cache\releases'
    if (Test-Path (Join-Path $cache $VER)) { Remove-Item -Recurse -Force (Join-Path $cache $VER) }

    # --- credential (merge-preserving: the binary owns the YAML) --------
    $exe = Join-Path $dest 'theia.exe'
    $cfgNew = Join-Path $env:APPDATA 'dokimelabs\theia\config.yaml'
    $cfgLegacy = Join-Path $env:USERPROFILE '.config\theia\config.yaml'
    $hasPat = (Test-Path $cfgNew) -and (Select-String -Path $cfgNew -Pattern 'pat:' -Quiet)
    if (-not $hasPat) { $hasPat = (Test-Path $cfgLegacy) -and (Select-String -Path $cfgLegacy -Pattern 'pat:' -Quiet) }
    if ($hasPat) {
        Write-Host 'kept existing user config (github.pat already present)'
    } else {
        & $exe setup --pat $PAT | Out-Null
        Write-Host 'stored the update credential (theia setup --pat)'
    }

    Write-Host ''
    & $exe version | ForEach-Object { Write-Host "installed version: $_" }
    Write-Host ''
    Write-Host 'done - try: theia version && theia doctor; then cd your project and run: theia'
    Write-Host '(the first AppContainer jail use asks once for an elevated setup - theia doctor names it)'
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

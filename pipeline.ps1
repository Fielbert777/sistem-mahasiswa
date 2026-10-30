<#
.SYNOPSIS
  Pipeline CI/CD Sistem Data Mahasiswa (3 container: frontend, backend, db).

.DESCRIPTION
  CI  : Validasi -> Lint & Unit Test Backend -> Lint Frontend -> Build Image -> Integration Test (staging)
  CD  : Build Image -> Deploy ke server lokal (production) -> Smoke Test -> (Rollback otomatis bila gagal)

  Dipakai langsung di mesin lokal, dan juga dipanggil oleh GitHub Actions
  (.github/workflows/ci-cd.yml) sehingga langkahnya identik di kedua tempat.

.EXAMPLE
  ./pipeline.ps1                 # CI + CD lengkap
  ./pipeline.ps1 -Mode ci        # hanya CI
  ./pipeline.ps1 -Mode cd        # hanya build + deploy
  ./pipeline.ps1 -SimulateDeployFailure   # uji mekanisme rollback
#>
[CmdletBinding()]
param(
    [ValidateSet('all', 'ci', 'cd')][string]$Mode = 'all',
    [string]$Version,
    [int]$StagingPort = 8081,
    [switch]$SimulateDeployFailure
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$ComposeFile = Join-Path $Root 'compose.yaml'
$RunDir = Join-Path $Root '.pipeline'
# Lokasi state deploy (env production + riwayat versi) harus persisten antar run.
$DeployDir = if ($env:MHS_DEPLOY_DIR) { $env:MHS_DEPLOY_DIR } else { Join-Path $Root '.deploy' }
$StagingProject = 'mhs-staging'
$ProdProject = 'mhs-prod'

New-Item -ItemType Directory -Force -Path $RunDir, $DeployDir | Out-Null
$env:BUILDKIT_PROGRESS = 'plain'

if (-not $Version) {
    $counterFile = Join-Path $RunDir 'build-number'
    $build = if (Test-Path $counterFile) { [int](Get-Content $counterFile) + 1 } else { 1 }
    Set-Content -Path $counterFile -Value $build
    $Version = "1.0.$build"
}
$env:APP_VERSION = $Version
$LogFile = Join-Path $RunDir "run-$Version.log"
$script:results = New-Object System.Collections.Generic.List[object]

# ---------------------------------------------------------------- helpers

function Write-Log([string]$Message, [string]$Color = 'Gray') {
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    Write-Host $line -ForegroundColor $Color
    Add-Content -Path $LogFile -Value $line -Encoding utf8
}

# Menjalankan perintah native (docker). Output lengkap masuk ke log; bila gagal, 40 baris terakhir ditampilkan.
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    Write-Log "> $Exe $($Arguments -join ' ')" 'DarkGray'
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($output) { Add-Content -Path $LogFile -Value $output -Encoding utf8 }
    if ($code -ne 0) {
        $output | Select-Object -Last 40 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow }
        throw "$Exe keluar dengan kode $code"
    }
    return $output
}

function Invoke-Compose([string]$Project, [string]$EnvFile, [string[]]$Arguments) {
    Invoke-Native 'docker' (@('compose', '-f', $ComposeFile, '-p', $Project, '--env-file', $EnvFile) + $Arguments)
}

function Invoke-Stage([string]$Name, [scriptblock]$Body) {
    Write-Log ''
    Write-Log "=== STAGE: $Name ===" 'Cyan'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $failure = $null
    try { & $Body } catch { $failure = $_.Exception.Message }
    $sw.Stop()
    $duration = '{0:N1}s' -f $sw.Elapsed.TotalSeconds
    $status = if ($failure) { 'FAILED' } else { 'SUCCESS' }
    $script:results.Add([pscustomobject]@{ Stage = $Name; Status = $status; Durasi = $duration })
    if ($failure) {
        Write-Log "Stage '$Name' GAGAL: $failure" 'Red'
        throw "Pipeline berhenti di stage '$Name'"
    }
    Write-Log "Stage '$Name' berhasil ($duration)" 'Green'
}

function Invoke-SmokeTest([string]$BaseUrl) {
    & (Join-Path $Root 'scripts/smoke-test.ps1') -BaseUrl $BaseUrl -ExpectedVersion $Version *>&1 | ForEach-Object {
        $text = "$_"
        $color = if ($text -match '\[FAIL\]') { 'Red' } elseif ($text -match '\[PASS\]') { 'Green' } else { 'Gray' }
        Write-Log "  $text" $color
    }
}

function New-EnvFile([string]$Path, [int]$Port) {
    $chars = [char[]]'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $password = -join (1..24 | ForEach-Object { $chars | Get-Random })
    @("DB_NAME=mahasiswa", "DB_USER=mhs", "DB_PASSWORD=$password", "FE_PORT=$Port") |
        Set-Content -Path $Path -Encoding ascii
}

function Write-ComposeLogs([string]$Project, [string]$EnvFile) {
    try { Invoke-Compose $Project $EnvFile @('ps', '-a') | Out-Null; Invoke-Compose $Project $EnvFile @('logs', '--no-color', '--tail', '50') | Out-Null }
    catch { Write-Log "Tidak bisa mengambil log container: $($_.Exception.Message)" 'DarkYellow' }
    Write-Log "Log container disimpan di $LogFile" 'DarkYellow'
}

# ---------------------------------------------------------------- stages

$StagingEnv = Join-Path $RunDir 'staging.env'
$ProdEnv = Join-Path $DeployDir 'prod.env'
$ProdPort = 8080

function Stage-Validate {
    Invoke-Stage 'Checkout & Validasi Konfigurasi' {
        foreach ($f in 'compose.yaml', 'backend/Dockerfile', 'backend/package-lock.json', 'frontend/Dockerfile', 'db/Dockerfile', 'scripts/smoke-test.ps1') {
            if (-not (Test-Path (Join-Path $Root $f))) { throw "File wajib tidak ditemukan: $f" }
        }
        Invoke-Native 'docker' @('version', '--format', 'Docker {{.Server.Version}}') | ForEach-Object { Write-Log $_ }
        New-EnvFile $StagingEnv $StagingPort
        Invoke-Compose $StagingProject $StagingEnv @('config', '--quiet') | Out-Null
        Write-Log "compose.yaml valid, versi build: $Version"
    }
}

function Stage-BackendTest {
    Invoke-Stage 'Lint & Unit Test Backend' {
        # --no-cache-filter memastikan lint & test benar-benar dijalankan ulang setiap pipeline.
        $out = Invoke-Native 'docker' @('build', '--target', 'test', '--no-cache-filter', 'test', '-t', "mhs-backend:test-$Version", (Join-Path $Root 'backend'))
        $out | Where-Object { $_ -match '# (tests|suites|pass|fail)|all files|^#\d+ .*\b(ok|not ok) \d+' } |
            ForEach-Object { Write-Log ("  " + ($_ -replace '^#\d+ [\d.]+ ', '')) }
        Invoke-Native 'docker' @('image', 'rm', "mhs-backend:test-$Version") | Out-Null
    }
}

function Stage-FrontendLint {
    Invoke-Stage 'Lint Frontend (HTMLHint + cek sintaks JS)' {
        $out = Invoke-Native 'docker' @('build', '--target', 'lint', '--no-cache-filter', 'lint', '-t', "mhs-frontend:lint-$Version", (Join-Path $Root 'frontend'))
        $out | Where-Object { $_ -match 'Scanned|no errors|errors? found' } | ForEach-Object { Write-Log ("  " + ($_ -replace '^#\d+ [\d.]+ ', '')) }
        Invoke-Native 'docker' @('image', 'rm', "mhs-frontend:lint-$Version") | Out-Null
    }
}

function Stage-Build {
    Invoke-Stage 'Build Image (frontend, backend, db)' {
        if (-not (Test-Path $StagingEnv)) { New-EnvFile $StagingEnv $StagingPort }
        Invoke-Compose $StagingProject $StagingEnv @('build') | Out-Null
        Invoke-Native 'docker' @('image', 'ls', '--filter', "reference=mhs-*:$Version", '--format', '{{.Repository}}:{{.Tag}}  {{.Size}}') |
            ForEach-Object { Write-Log "  image: $_" }
    }
}

function Stage-Integration {
    Invoke-Stage "Integration Test (staging :$StagingPort)" {
        try {
            Invoke-Compose $StagingProject $StagingEnv @('up', '-d', '--wait', '--wait-timeout', '180') | Out-Null
            Write-Log 'Ketiga container staging sehat (healthy)'
            Invoke-SmokeTest "http://localhost:$StagingPort"
        } catch {
            Write-ComposeLogs $StagingProject $StagingEnv
            throw
        } finally {
            # Staging selalu dibersihkan, termasuk volume database-nya.
            Invoke-Compose $StagingProject $StagingEnv @('down', '-v', '--remove-orphans') | Out-Null
            Write-Log 'Lingkungan staging dibersihkan'
        }
    }
}

function Stage-Deploy {
    $currentFile = Join-Path $DeployDir 'current-version'
    $previous = if (Test-Path $currentFile) { (Get-Content $currentFile -Raw).Trim() } else { $null }
    if (-not (Test-Path $ProdEnv)) {
        New-EnvFile $ProdEnv $ProdPort
        Write-Log "Deploy pertama: file env production dibuat di $ProdEnv" 'Yellow'
    }

    try {
        Invoke-Stage "Deploy ke Server Lokal (production :$ProdPort)" {
            Write-Log "Versi sebelumnya: $(if ($previous) { $previous } else { '(belum ada)' }) -> versi baru: $Version"
            Invoke-Compose $ProdProject $ProdEnv @('up', '-d', '--wait', '--wait-timeout', '180', '--remove-orphans') | Out-Null
            Invoke-Compose $ProdProject $ProdEnv @('ps', '--format', '{{.Service}}: {{.Status}}') | ForEach-Object { Write-Log "  $_" }
        }
        Invoke-Stage 'Smoke Test Production' {
            Invoke-SmokeTest "http://localhost:$ProdPort"
            if ($SimulateDeployFailure) { throw 'Kegagalan disimulasikan (-SimulateDeployFailure)' }
        }
        Set-Content -Path $currentFile -Value $Version
        Add-Content -Path (Join-Path $DeployDir 'history.log') -Value ('{0}  {1}  SUCCESS' -f (Get-Date -Format s), $Version)
    } catch {
        Write-ComposeLogs $ProdProject $ProdEnv
        Add-Content -Path (Join-Path $DeployDir 'history.log') -Value ('{0}  {1}  FAILED' -f (Get-Date -Format s), $Version)
        if ($previous -and $previous -ne $Version) {
            $env:APP_VERSION = $previous
            try {
                Invoke-Stage "Rollback ke versi $previous" {
                    Invoke-Compose $ProdProject $ProdEnv @('up', '-d', '--wait', '--wait-timeout', '180') | Out-Null
                    $health = Invoke-RestMethod -Uri "http://localhost:$ProdPort/api/health" -TimeoutSec 10
                    if ($health.version -ne $previous) { throw "versi berjalan $($health.version), seharusnya $previous" }
                    Write-Log "Production kembali berjalan di versi $previous" 'Yellow'
                }
            } finally {
                $env:APP_VERSION = $Version
            }
        } else {
            Write-Log 'Tidak ada versi sebelumnya untuk rollback' 'Yellow'
        }
        throw
    }
}

# ---------------------------------------------------------------- main

Write-Log "Pipeline CI/CD dimulai | mode=$Mode | versi=$Version" 'Cyan'
$exitCode = 0
try {
    Stage-Validate
    if ($Mode -in 'all', 'ci') {
        Stage-BackendTest
        Stage-FrontendLint
    }
    Stage-Build
    if ($Mode -in 'all', 'ci') { Stage-Integration }
    if ($Mode -in 'all', 'cd') { Stage-Deploy }
} catch {
    Write-Log $_.Exception.Message 'Red'
    $exitCode = 1
}

Write-Log ''
Write-Log '=== RINGKASAN PIPELINE ===' 'Cyan'
$script:results | Format-Table -AutoSize | Out-String -Width 120 | ForEach-Object { $_.TrimEnd() } | Write-Host
$script:results | Format-Table -AutoSize | Out-String -Width 120 | Add-Content -Path $LogFile -Encoding utf8
[pscustomobject]@{
    version  = $Version
    mode     = $Mode
    result   = if ($exitCode -eq 0) { 'SUCCESS' } else { 'FAILED' }
    finished = (Get-Date -Format s)
    stages   = $script:results
} | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $RunDir 'last-run.json') -Encoding utf8

if ($exitCode -eq 0) {
    Write-Log "PIPELINE BERHASIL - versi $Version" 'Green'
    if ($Mode -ne 'ci') { Write-Log "Aplikasi production: http://localhost:$ProdPort" 'Green' }
} else {
    Write-Log "PIPELINE GAGAL - lihat log: $LogFile" 'Red'
}
exit $exitCode

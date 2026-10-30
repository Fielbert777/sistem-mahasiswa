<#
.SYNOPSIS
  Smoke / integration test end-to-end melalui container frontend (Nginx -> backend -> database).
.EXAMPLE
  ./scripts/smoke-test.ps1 -BaseUrl http://localhost:8080 -ExpectedVersion 1.0.3
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BaseUrl,
    [string]$ExpectedVersion
)

$ErrorActionPreference = 'Stop'
$BaseUrl = $BaseUrl.TrimEnd('/')
$script:failed = 0

function Send-Request([string]$Method, [string]$Path, $Body) {
    $params = @{ Uri = "$BaseUrl$Path"; Method = $Method; UseBasicParsing = $true; TimeoutSec = 10 }
    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Compress)
        $params.ContentType = 'application/json; charset=utf-8'
    }
    try {
        $r = Invoke-WebRequest @params
        $json = $null
        if ($r.Content -and "$($r.Headers['Content-Type'])" -like 'application/json*') { $json = $r.Content | ConvertFrom-Json }
        return [pscustomobject]@{ Status = [int]$r.StatusCode; Json = $json; Content = "$($r.Content)"; Headers = $r.Headers }
    } catch {
        $resp = $_.Exception.Response
        if ($null -eq $resp) { throw }
        return [pscustomobject]@{ Status = [int]$resp.StatusCode; Json = $null; Content = ''; Headers = @{} }
    }
}

function Assert-That([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    } catch {
        $script:failed++
        Write-Host "  [FAIL] $Name -> $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "Smoke test terhadap $BaseUrl"

Test-Case 'Frontend menyajikan halaman HTML' {
    $r = Send-Request GET '/'
    Assert-That ($r.Status -eq 200) "status $($r.Status)"
    Assert-That ($r.Content -match 'Sistem Data Mahasiswa') 'judul halaman tidak ditemukan'
    Assert-That ("$($r.Headers['X-Content-Type-Options'])" -eq 'nosniff') 'security header hilang'
}

Test-Case 'Aset statis CSS & JS tersedia' {
    Assert-That ((Send-Request GET '/css/style.css').Status -eq 200) 'style.css tidak ada'
    Assert-That ((Send-Request GET '/js/app.js').Status -eq 200) 'app.js tidak ada'
}

Test-Case 'Health check: backend & database aktif' {
    $r = Send-Request GET '/api/health'
    Assert-That ($r.Status -eq 200) "status $($r.Status)"
    Assert-That ($r.Json.database -eq 'up') "database: $($r.Json.database)"
    if ($ExpectedVersion) {
        Assert-That ($r.Json.version -eq $ExpectedVersion) "versi berjalan $($r.Json.version), seharusnya $ExpectedVersion"
    }
}

Test-Case 'Data awal (seed) dari database terbaca' {
    $r = Send-Request GET '/api/mahasiswa'
    Assert-That ($r.Status -eq 200) "status $($r.Status)"
    Assert-That (@($r.Json).Count -ge 1) 'daftar mahasiswa kosong'
}

# NIM acak diawali 9 agar tidak bentrok dengan data asli.
$nim = '9' + (Get-Random -Minimum 10000000 -Maximum 99999999)
$created = $null

Test-Case 'CREATE: tambah mahasiswa -> 201' {
    $r = Send-Request POST '/api/mahasiswa' @{ nim = $nim; nama = 'Smoke Test'; jurusan = 'Pengujian'; angkatan = 2024 }
    Assert-That ($r.Status -eq 201) "status $($r.Status)"
    $script:created = $r.Json
}

Test-Case 'Validasi: NIM duplikat -> 409, data invalid -> 400' {
    $dup = Send-Request POST '/api/mahasiswa' @{ nim = $nim; nama = 'Duplikat'; jurusan = 'X'; angkatan = 2024 }
    Assert-That ($dup.Status -eq 409) "duplikat status $($dup.Status)"
    $bad = Send-Request POST '/api/mahasiswa' @{ nim = 'abc'; nama = ''; jurusan = ''; angkatan = 1 }
    Assert-That ($bad.Status -eq 400) "invalid status $($bad.Status)"
}

Test-Case 'READ & UPDATE: data tersimpan di PostgreSQL dan bisa diubah' {
    Assert-That ($null -ne $script:created) 'data belum dibuat'
    $id = $script:created.id
    $r = Send-Request GET "/api/mahasiswa/$id"
    Assert-That ($r.Json.nim -eq $nim) 'NIM tidak sesuai'
    $u = Send-Request PUT "/api/mahasiswa/$id" @{ nim = $nim; nama = 'Smoke Test Updated'; jurusan = 'Pengujian'; angkatan = 2025 }
    Assert-That ($u.Status -eq 200 -and $u.Json.nama -eq 'Smoke Test Updated') "update status $($u.Status)"
}

Test-Case 'DELETE: hapus data -> 204, lalu 404' {
    Assert-That ($null -ne $script:created) 'data belum dibuat'
    $id = $script:created.id
    Assert-That ((Send-Request DELETE "/api/mahasiswa/$id").Status -eq 204) 'delete gagal'
    Assert-That ((Send-Request GET "/api/mahasiswa/$id").Status -eq 404) 'data masih ada'
}

if ($script:failed -gt 0) { throw "$($script:failed) pemeriksaan smoke test GAGAL" }
Write-Host 'Semua pemeriksaan smoke test LULUS' -ForegroundColor Green

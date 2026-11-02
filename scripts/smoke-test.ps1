# Hindsight deploy - smoke test (Windows PowerShell 5.1+ / pwsh)
# Usage: & .\scripts\smoke-test.ps1
param(
  [string]$ApiUrl = "http://localhost:8888",
  [string]$CpUrl  = "http://localhost:9999",
  [string]$ComposeDir = (Resolve-Path "$PSScriptRoot/..").Path
)
$ErrorActionPreference = "Stop"
$script:fail = 0

function Check($name, [scriptblock]$body) {
  try { & $body; Write-Host "  [PASS] $name" -ForegroundColor Green }
  catch { Write-Host "  [FAIL] $name -> $_" -ForegroundColor Red; $script:fail++ }
}
function StatusOf($uri, $headers) {
  try {
    $r = Invoke-WebRequest -Uri $uri -Headers $headers -UseBasicParsing -TimeoutSec 20
    return [int]$r.StatusCode
  } catch {
    if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
    throw
  }
}

# Load secrets from .env
$envFile = Join-Path $ComposeDir ".env"
if (-not (Test-Path $envFile)) { throw "missing .env (copy .env.example)" }
$cfg = @{}
Get-Content $envFile | ForEach-Object {
  if ($_ -match '^\s*([A-Z0-9_]+)=(.*)$') { $cfg[$Matches[1]] = $Matches[2].Trim() }
}
$hermes  = $cfg["HERMES_API_KEY"]
$harness = $cfg["DEEPSEEK_HARNESS_API_KEY"]
if (-not $hermes -or -not $harness) { throw "HERMES_API_KEY / DEEPSEEK_HARNESS_API_KEY missing from .env" }

$H = @{ Authorization = "Bearer $hermes"; "Content-Type" = "application/json" }
$D = @{ Authorization = "Bearer $harness"; "Content-Type" = "application/json" }
$compose = Join-Path $ComposeDir "docker-compose.yml"

Write-Host "API $ApiUrl / Control Plane $CpUrl"

Check "GET /health = 200" {
  $s = StatusOf "$ApiUrl/health" @{}
  if ($s -ne 200) { throw "status $s" }
}

Check "unknown key -> 401" {
  $s = StatusOf "$ApiUrl/v1/default/banks" @{ Authorization = "Bearer nope" }
  if ($s -ne 401) { throw "expected 401, got $s" }
}

Check "hermes-agent lists banks" {
  $s = StatusOf "$ApiUrl/v1/default/banks" $H
  if ($s -ne 200) { throw "status $s" }
}

$docId = "smoke-" + [guid]::NewGuid().ToString("N").Substring(0,8)

Check "hermes-agent retain" {
  $payload = @{ items = @(@{ content = "The deployment codename is Sea Otter and the owner is hermes-agent."; document_id = $docId }) } | ConvertTo-Json -Depth 6
  $r = Invoke-RestMethod -Uri "$ApiUrl/v1/default/banks/smoke/memories" -Method Post -Headers $H -Body $payload -TimeoutSec 300
  if ($r.PSObject.Properties.Name -contains "success" -and -not $r.success) { throw "retain reported failure" }
}

function RecallCount($headers) {
  $payload = @{ query = "What is the deployment codename?" } | ConvertTo-Json
  try {
    $r = Invoke-RestMethod -Uri "$ApiUrl/v1/default/banks/smoke/memories/recall" -Method Post -Headers $headers -Body $payload -TimeoutSec 300
  } catch {
    # A tenant whose schema has no such bank gets 404 "Bank ... not found".
    # That is isolation working, not a failure.
    if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { return 0 }
    throw
  }
  $text = $r | ConvertTo-Json -Depth 8 -Compress
  if ($text -match "Sea Otter|deployment codename") { return 1 }
  return 0
}

Check "deepseek-harness is isolated from hermes-agent" {
  $n = RecallCount $D
  if ($n -gt 0) { throw "leak: deepseek-harness saw hermes-agent memories" }
}

Check "hermes-agent recalls its own memory" {
  $n = RecallCount $H
  if ($n -lt 1) { throw "recall returned nothing for its own data" }
}

Check "tenant schemas exist in Postgres" {
  $out = docker compose -f $compose exec -T db psql -U hindsight -d hindsight -tAc "select nspname from pg_namespace where nspname like 'user_%' order by 1" 2>&1 | Out-String
  if ($out -notmatch "user_hermes_agent") { throw "user_hermes_agent schema missing" }
  if ($out -notmatch "user_deepseek_harness") { throw "user_deepseek_harness schema missing" }
}

Check "worker health" {
  $out = docker compose -f $compose exec -T worker /app/api/.venv/bin/python -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8889/health', timeout=8).status)" 2>&1 | Out-String
  if ($out -notmatch "200") { throw "worker health: $out" }
}

Check "control plane reachable" {
  $s = StatusOf $CpUrl @{}
  if ($s -ne 200) { throw "status $s" }
}

Check "webhook sink reachable" {
  $s = StatusOf "http://localhost:8087/" @{}
  if ($s -ne 200) { throw "status $s" }
}

if ($script:fail -gt 0) { Write-Host "$($script:fail) check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host "All checks passed." -ForegroundColor Green

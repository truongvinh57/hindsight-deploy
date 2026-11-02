# Mint fresh bearer keys / secrets and print the lines to paste into .env
# Works on Windows PowerShell 5.1 (which has no RandomNumberGenerator.Fill) and on pwsh 7.
param([int]$Bytes = 24)

function Rand([int]$n) {
  $b = New-Object byte[] $n
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($b) } finally { $rng.Dispose() }
  ($b | ForEach-Object { $_.ToString("x2") }) -join ""
}

Write-Output "# paste into .env"
Write-Output ("POSTGRES_PASSWORD=" + (Rand $Bytes))
Write-Output ("HERMES_API_KEY=hk_" + (Rand $Bytes))
Write-Output ("DEEPSEEK_HARNESS_API_KEY=dk_" + (Rand $Bytes))
Write-Output ("HINDSIGHT_CP_ACCESS_KEY=" + (Rand 16))
Write-Output ("WEBHOOK_SECRET=whsec_" + (Rand 20))

Param(
  [string]$NetworkName = "vault-demo",
  [string]$ServerName = "vault-dev",
  [string]$Image = "hashicorp/vault:1.16",
  [string]$RootToken = "root"
)

$ErrorActionPreference = "Continue"

function Assert-Ok([string]$what) {
  if ($LASTEXITCODE -ne 0) {
    throw "$what (exit code $LASTEXITCODE)"
  }
}

function Write-Step([string]$msg) {
  Write-Host "`n=== $msg ===" -ForegroundColor Cyan
}

function Vault-Exec([string[]]$vaultArgs) {
  # Execute the Vault CLI inside the running Vault server container (fastest).
  # Suppress stdout so callers can reliably check the exit code.
  docker exec -e VAULT_ADDR="http://127.0.0.1:8200" -e VAULT_TOKEN=$RootToken $ServerName vault @vaultArgs 2>$null | Out-Null
  return $LASTEXITCODE
}

Write-Step "Checks"
$docker = Get-Command docker -ErrorAction SilentlyContinue
if ($null -eq $docker) {
  throw "Docker n'est pas installe. Installe Docker Desktop puis relance."
}

# Vérifier que le daemon Docker tourne (Docker Desktop démarré)
$serverVersion = & docker info --format '{{.ServerVersion}}' 2>&1
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$serverVersion)) {
  throw (@(
    "Docker est installe mais le daemon Docker n'est pas joignable.",
    "- Demarre Docker Desktop et attends l'etat 'Running'.",
    "- Verifie que le moteur Linux est actif (recommande pour Vault).",
    "- Puis relance.",
    "Detail Docker: $serverVersion"
  ) -join "`n")
}

Write-Step "(Optional) Create Docker network (if absent)"
docker network inspect $NetworkName *> $null 2>$null
if ($LASTEXITCODE -ne 0) {
  docker network create $NetworkName 2>$null | Out-Null
}

Write-Step "Start Vault in dev mode (container)"
# Nettoyage si un container du meme nom existe
$existing = docker ps -a --format "{{.Names}}" 2>$null | Where-Object { $_ -eq $ServerName }
if ($existing) {
  docker rm -f $ServerName 2>$null | Out-Null
}

# Lancement (dev mode = auto-unseal, stockage en memoire)
docker run -d --name $ServerName --network $NetworkName -p 8200:8200 `
  -e VAULT_DEV_ROOT_TOKEN_ID=$RootToken `
  -e VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:8200 `
  $Image server -dev 2>$null | Out-Null
Assert-Ok "Started Vault container '$ServerName'"

Write-Step "Wait for Vault to be ready"
$maxTries = 30
for ($i=1; $i -le $maxTries; $i++) {
  $exit = Vault-Exec @("status")
  if ($exit -eq 0) { break }
  Start-Sleep -Seconds 1
}
if ($i -gt $maxTries) {
  throw "Vault did not become ready. Ensure Docker Desktop is running, then retry."
}

Write-Step "Enable KV v2"
Vault-Exec @("secrets","enable","-path=kv","kv-v2") | Out-Null
Assert-Ok "Enable KV v2"

Write-Step "Write a secret (kv/app1)"
Vault-Exec @("kv","put","kv/app1","db_password=S3cret!","api_key=abc123") | Out-Null
Assert-Ok "Write kv/app1"

Write-Step "Read the secret (root)"
docker exec -e VAULT_ADDR="http://127.0.0.1:8200" -e VAULT_TOKEN=$RootToken $ServerName vault kv get kv/app1 2>$null | Out-Host
Assert-Ok "Read kv/app1 (root)"

Write-Step "Create policy app1-read"
$policyPath = Join-Path $PSScriptRoot "app1-read.hcl"
if (-not (Test-Path $policyPath)) {
  throw "Policy introuvable: $policyPath"
}
# Inject policy via stdin
Get-Content $policyPath -Raw | docker exec -i -e VAULT_ADDR="http://127.0.0.1:8200" -e VAULT_TOKEN=$RootToken $ServerName vault policy write app1-read - 2>$null
Assert-Ok "Write policy app1-read"

Write-Step "Create a limited token (app1-read)"
$tokenOut = docker exec -e VAULT_ADDR="http://127.0.0.1:8200" -e VAULT_TOKEN=$RootToken $ServerName vault token create -policy=app1-read -ttl=1h 2>$null
Assert-Ok "Create limited token"
$token = ($tokenOut | Select-String -Pattern '^token\s+\S+' | ForEach-Object { $_.ToString().Split()[-1] })
if (-not $token) {
  Write-Host $tokenOut
  throw "Impossible d'extraire le token."
}
Write-Host "`nTOKEN_LIMITED = $token" -ForegroundColor Yellow

Write-Step "Test: allowed read (kv/app1)"
docker exec -e VAULT_ADDR="http://127.0.0.1:8200" -e VAULT_TOKEN=$token $ServerName vault kv get kv/app1 2>$null | Out-Host
Assert-Ok "Read kv/app1 with limited token"

Write-Step "Test: denied write elsewhere (kv/other)"
# Expect non-zero exit code (permission denied)
docker exec -e VAULT_ADDR="http://127.0.0.1:8200" -e VAULT_TOKEN=$token $ServerName vault kv put kv/other foo=bar 2>$null
if ($LASTEXITCODE -eq 0) {
  Write-Host "ATTENTION: l'écriture a réussi (policy trop large ?)" -ForegroundColor Red
} else {
  Write-Host "OK: write denied as expected." -ForegroundColor Green
}

Write-Step "Done"
Write-Host "Vault is running in container '$ServerName' on http://127.0.0.1:8200" -ForegroundColor Green
Write-Host "Stop it with: docker rm -f $ServerName" -ForegroundColor Green

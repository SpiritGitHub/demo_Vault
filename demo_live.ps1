Param(
  [string]$NetworkName = "vault-demo",
  [string]$ServerName = "vault-dev",
  [string]$Image = "hashicorp/vault:1.16",
  [string]$RootToken = "root"
)

$ErrorActionPreference = "Stop"

function Step([string]$title, [string]$say) {
  Write-Host "`n=== $title ===" -ForegroundColor Cyan
  if ($say) {
    Write-Host "Say: $say" -ForegroundColor Yellow
  }
  [void](Read-Host "Press Enter to run")
}

function Vault([string[]]$vaultArgs) {
  docker exec -e VAULT_ADDR="http://127.0.0.1:8200" -e VAULT_TOKEN=$RootToken $ServerName vault @vaultArgs
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  throw "Docker is not installed. Install Docker Desktop first."
}

$serverVersion = docker info --format '{{.ServerVersion}}' 2>$null
$serverVersion = & docker info --format '{{.ServerVersion}}' 2>&1
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$serverVersion)) {
  throw (@(
    "Docker est installé mais le daemon Docker n'est pas joignable.",
    "Démarre Docker Desktop puis relance.",
    "Détail Docker: $serverVersion"
  ) -join "`n")
}

Step "(Optional) Pull image" "I pre-pull the Vault image to avoid waiting during the demo."
docker pull $Image

Step "Create network (if needed)" "I create a dedicated network for the demo containers."
docker network inspect $NetworkName *> $null 2>$null
if ($LASTEXITCODE -ne 0) { docker network create $NetworkName | Out-Null }

Step "Start Vault (dev mode)" "Vault dev mode is demo-only: in-memory, auto-unsealed, not production."
docker rm -f $ServerName 2>$null | Out-Null
docker run -d --name $ServerName --network $NetworkName -p 8200:8200 -e VAULT_DEV_ROOT_TOKEN_ID=$RootToken -e VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:8200 $Image server -dev | Out-Null

Step "Check status" "Now I prove Vault is up and unsealed."
Vault @("status")

Step "Enable KV v2" "KV is the simplest engine to store a static secret."
Vault @("secrets","enable","-path=kv","kv-v2")

Step "Write a secret" "I store a secret under kv/app1."
Vault @("kv","put","kv/app1","db_password=S3cret!","api_key=abc123")

Step "Read with root" "Root can read everything, but we never use root in real life."
Vault @("kv","get","kv/app1")

Step "Create policy" "I create a least-privilege policy: read-only on kv/app1."
$policyPath = Join-Path $PSScriptRoot "app1-read.hcl"
Get-Content $policyPath -Raw | docker exec -i -e VAULT_ADDR="http://127.0.0.1:8200" -e VAULT_TOKEN=$RootToken $ServerName vault policy write app1-read -

Step "Create limited token" "I mint a short-lived token for the app, with that policy only."
$tokenOut = docker exec -e VAULT_ADDR="http://127.0.0.1:8200" -e VAULT_TOKEN=$RootToken $ServerName vault token create -policy=app1-read -ttl=1h
$token = ($tokenOut | Select-String -Pattern '^token\s+\S+' | ForEach-Object { $_.ToString().Split()[-1] })
Write-Host "TOKEN_LIMITED=$token" -ForegroundColor Green

Step "Test allowed read" "With the limited token, reading kv/app1 works."
docker exec -e VAULT_ADDR="http://127.0.0.1:8200" -e VAULT_TOKEN=$token $ServerName vault kv get kv/app1

Step "Test denied write" "But writing elsewhere is denied: least privilege in action."
docker exec -e VAULT_ADDR="http://127.0.0.1:8200" -e VAULT_TOKEN=$token $ServerName vault kv put kv/other foo=bar

Write-Host "`nDone. Stop with: .\cleanup.ps1" -ForegroundColor Cyan

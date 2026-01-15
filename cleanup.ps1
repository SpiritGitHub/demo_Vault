Param(
  [string]$NetworkName = "vault-demo",
  [string]$ServerName = "vault-dev"
)

$ErrorActionPreference = "Continue"

Write-Host "Stopping/removing container: $ServerName" -ForegroundColor Cyan
docker rm -f $ServerName 2>$null | Out-Null

Write-Host "Removing network (optional): $NetworkName" -ForegroundColor Cyan
docker network rm $NetworkName 2>$null | Out-Null

Write-Host "Cleanup done." -ForegroundColor Green

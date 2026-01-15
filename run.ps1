Param(
  [switch]$SkipPull,
  [string]$Image = "hashicorp/vault:1.16"
)

$ErrorActionPreference = "Stop"

# Quick sanity checks
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  throw "Docker is not installed. Install Docker Desktop first."
}

# Ensure Docker Desktop/daemon is running
$serverVersion = docker info --format '{{.ServerVersion}}' 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($serverVersion)) {
  throw "Docker daemon is not running. Start Docker Desktop, then retry."
}

if (-not $SkipPull) {
  Write-Host "Pulling image $Image (skip with -SkipPull)..." -ForegroundColor Cyan
  docker pull $Image
  if ($LASTEXITCODE -ne 0) { throw "docker pull failed" }
}

Write-Host "Running Vault demo..." -ForegroundColor Cyan
& "$PSScriptRoot\demo_docker.ps1" -Image $Image

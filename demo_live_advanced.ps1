Param(
  [string]$NetworkName = "vault-demo",
  [string]$ServerName = "vault-dev",
  [string]$Image = "hashicorp/vault:1.16",
  [string]$RootToken = "root"
)

# Demo live avancee: pas-a-pas, plus explicatif.
# Notes:
# - Utilise Vault en mode dev (DEMO uniquement)
# - Utilise docker exec (rapide) au lieu de lancer plusieurs conteneurs CLI

$ErrorActionPreference = "Stop"

# Variables partagées entre étapes (script scope)
$script:limitedToken = $null
$script:ciphertext = $null
$script:wrappingToken = $null

function Header([string]$title) {
  Write-Host "`n=== $title ===" -ForegroundColor Cyan
}

function Infos([string]$objectif, [string]$comment) {
  if ($objectif) { Write-Host "Objectif    : $objectif" -ForegroundColor Yellow }
  if ($comment)  { Write-Host "Comment     : $comment" -ForegroundColor Yellow }
}

function Observation([string]$texte) {
  if ($texte) { Write-Host "Observation : $texte" -ForegroundColor Green }
}

function Pause([string]$prompt = "Appuie sur Entree pour continuer") {
  [void](Read-Host $prompt)
}

function Demo-Step(
  [string]$titre,
  [string]$objectif,
  [string]$comment,
  [scriptblock]$action,
  [string]$observation
) {
  Header $titre
  Infos $objectif $comment
  Pause "Appuie sur Entree pour executer"
  & $action
  Observation $observation
  Pause
}

function Ensure-Docker {
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker n'est pas installé. Installe Docker Desktop puis relance."
  }

  # Docker Desktop can be installed but the engine not running yet (common on Windows).
  # Capture stdout+stderr to display a helpful, actionable message.
  $serverVersion = & docker info --format '{{.ServerVersion}}' 2>&1
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$serverVersion)) {
    throw (@(
      "Docker est installe mais le daemon Docker n'est pas joignable.",
      "- Demarre Docker Desktop et attends l'etat 'Running'.",
      "- Verifie que tu es en mode 'Linux containers' (recommande pour Vault).",
      "- Puis relance le script.",
      "Detail Docker: $serverVersion"
    ) -join "`n")
  }
}

function Vault([string[]]$vaultArgs) {
  docker exec -e VAULT_ADDR="http://127.0.0.1:8200" -e VAULT_TOKEN=$RootToken $ServerName vault @vaultArgs
}

function Vault-AsToken([string]$token, [string[]]$vaultArgs) {
  docker exec -e VAULT_ADDR="http://127.0.0.1:8200" -e VAULT_TOKEN=$token $ServerName vault @vaultArgs
}

Ensure-Docker

Header "Sujet & plan de la demo"
Write-Host "Sujet: gerer et distribuer des secrets (mots de passe, API keys, tokens) sans les mettre en dur dans le code." -ForegroundColor Yellow
Write-Host "Objectif: montrer comment Vault centralise les secrets et controle l'acces via policies + tokens (moindre privilege)." -ForegroundColor Yellow
Write-Host "Plan:" -ForegroundColor Yellow
Write-Host "1) Demarrer Vault (mode dev)" -ForegroundColor Yellow
Write-Host "2) KV v2: ecriture, lecture, versioning" -ForegroundColor Yellow
Write-Host "3) Policies + tokens: moindre privilege, TTL, renew, revoke" -ForegroundColor Yellow
Write-Host "4) Audit: tracer les acces" -ForegroundColor Yellow
Write-Host "5) Transit: chiffrer/dechiffrer sans exposer les cles" -ForegroundColor Yellow
Write-Host "6) Response wrapping: livraison one-shot" -ForegroundColor Yellow
Pause

Demo-Step `
  "(Optionnel) Telecharger l'image Docker" `
  "Eviter l'attente pendant la demo" `
  "On fait un docker pull de l'image Vault" `
  { docker pull $Image | Out-Null } `
  "Si l'image est en cache, c'est instantane; sinon, telechargement une seule fois."

Demo-Step `
  "Reseau Docker (isolation)" `
  "Avoir un reseau dedie pour la demo" `
  "On verifie si le reseau existe, sinon on le cree" `
  {
    try {
      docker network inspect $NetworkName *> $null 2>$null
      if ($LASTEXITCODE -ne 0) { throw "not found" }
    } catch {
      docker network create $NetworkName | Out-Null
    }
  } `
  "Le reseau '$NetworkName' existe et pourra connecter nos conteneurs."

Demo-Step `
  "Demarrage de Vault (mode dev)" `
  "Lancer Vault localement pour la demo" `
  "Mode dev = in-memory, auto-unsealed, root token fixe (demo uniquement)" `
  {
    try { docker rm -f $ServerName 2>$null | Out-Null } catch {}
    docker run -d --name $ServerName --network $NetworkName -p 8200:8200 `
      -e VAULT_DEV_ROOT_TOKEN_ID=$RootToken `
      -e VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:8200 `
      $Image server -dev | Out-Null

    $maxTries = 30
    for ($i=1; $i -le $maxTries; $i++) {
      try {
        docker exec -e VAULT_ADDR="http://127.0.0.1:8200" -e VAULT_TOKEN=$RootToken $ServerName vault status 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { break }
      } catch {}
      Start-Sleep -Seconds 1
    }
    if ($i -gt $maxTries) {
      throw "Vault ne repond pas. Verifie Docker Desktop puis relance."
    }
  } `
  "Vault tourne et l'API est accessible sur http://127.0.0.1:8200"

Demo-Step `
  "Etat Vault (sealed/unsealed)" `
  "Verifier que Vault est UP et unsealed" `
  "On appelle 'vault status'" `
  { Vault @("status") } `
  "Tu dois voir Sealed=false. En prod, l'unseal est controle (Shamir/KMS/HSM)."

Demo-Step `
  "Lister les moteurs (secret engines)" `
  "Voir quels moteurs sont montes et a quels chemins" `
  "On liste les mounts via 'vault secrets list'" `
  { Vault @("secrets","list") } `
  "Chaque chemin (ex: kv/, transit/) correspond a un moteur et des usages differents."

Demo-Step `
  "Activer l'audit" `
  "Tracer les acces" `
  "On active un audit device file vers /tmp/audit.log" `
  { Vault @("audit","enable","file","file_path=/tmp/audit.log") } `
  "Vault loguera les requetes (sans exposer les secrets en clair)."

Demo-Step `
  "Activer KV v2" `
  "Stockage de secrets statiques avec versioning" `
  "On monte kv-v2 sur le chemin kv/" `
  { Vault @("secrets","enable","-path=kv","kv-v2") } `
  "On pourra ecrire/lire kv/app1 avec historique de versions."

Demo-Step `
  "Ecrire un secret (version 1)" `
  "Stocker un secret pour l'app app1" `
  "On fait un kv put sur kv/app1 (valeurs fictives)" `
  { Vault @("kv","put","kv/app1","db_password=S3cret!","api_key=abc123") } `
  "Tu dois voir version=1 dans les metadonnees."

Demo-Step `
  "Lire le secret" `
  "Recuperer le secret et ses metadonnees" `
  "On fait kv get sur kv/app1" `
  { Vault @("kv","get","kv/app1") } `
  "Tu vois data (valeurs) + metadata (created_time, version...)."

Demo-Step `
  "Mettre a jour (rotation) -> version 2" `
  "Simuler une rotation" `
  "On re-ecrit kv/app1 avec un nouveau mot de passe" `
  { Vault @("kv","put","kv/app1","db_password=S3cret-ROTATED!","api_key=abc123") } `
  "KV v2 cree une nouvelle version (pas d'ecrasement silencieux)."

Demo-Step `
  "Voir l'historique (metadata)" `
  "Verifier le versioning" `
  "On lit la metadata de kv/app1" `
  { Vault @("kv","metadata","get","kv/app1") } `
  "Observe current_version=2 et la liste des versions."

Demo-Step `
  "Lire une version precise" `
  "Montrer rollback/debug" `
  "On lit version 1 puis version 2" `
  {
    Write-Host "--- Version 1 ---" -ForegroundColor DarkGray
    Vault @("kv","get","-version=1","kv/app1")
    Write-Host "--- Version 2 ---" -ForegroundColor DarkGray
    Vault @("kv","get","-version=2","kv/app1")
  } `
  "Tu vois l'ancien db_password en v1, et le mot de passe rotate en v2."

Demo-Step `
  "Creer une policy (moindre privilege)" `
  "Autoriser uniquement la lecture du secret app1" `
  "On écrit une policy read-only sur kv/data/app1" `
  {
    $policyPath = Join-Path $PSScriptRoot "app1-read.hcl"
    Get-Content $policyPath -Raw | docker exec -i -e VAULT_ADDR="http://127.0.0.1:8200" -e VAULT_TOKEN=$RootToken $ServerName vault policy write app1-read - | Out-Null
    Vault @("policy","read","app1-read")
  } `
  "La policy definit ce que le token applicatif pourra faire."

Demo-Step `
  "Creer un token limite (TTL 2 minutes)" `
  "Donner un acces applicatif court et limite" `
  "On crée un token avec policy app1-read" `
  {
    $tokenJson = Vault @("token","create","-policy=app1-read","-ttl=2m","-format=json")
    $script:limitedToken = ($tokenJson | ConvertFrom-Json).auth.client_token
    Write-Host "TOKEN_LIMITED=$script:limitedToken" -ForegroundColor Green
  } `
  "Ce token represente l'identite de l'application (separee du root)."

Demo-Step `
  "Test acces (OK): read kv/app1" `
  "Verifier l'acces autorise" `
  "On lit avec le token applicatif" `
  { Vault-AsToken $script:limitedToken @("kv","get","kv/app1") } `
  "Lecture OK: l'app peut accéder à SON secret."

Demo-Step `
  "Test acces (KO): write interdit" `
  "Prouver le moindre privilege" `
  "On tente un write avec le token applicatif" `
  {
    try { Vault-AsToken $script:limitedToken @("kv","put","kv/app1","x=y") } catch {}
  } `
  "Attendu: erreur 403 permission denied (pas de droit d'ecriture)."

Demo-Step `
  "Inspecter le token (TTL, policies...)" `
  "Voir TTL, policies, renewable" `
  "On fait token lookup" `
  { Vault-AsToken $script:limitedToken @("token","lookup") } `
  "Observe ttl / expire_time / policies=[app1-read default]."

Demo-Step `
  "Renouveler le token" `
  "Prolonger un token renouvable" `
  "On fait token renew (self)" `
  { Vault-AsToken $script:limitedToken @("token","renew") } `
  "Le token_duration repart si renewable=true."

Demo-Step `
  "Revoquer le token" `
  "Couper l'acces immediatement" `
  "On revoke le token depuis root" `
  { Vault @("token","revoke",$script:limitedToken) } `
  "Le token devient invalide immediatement (meme s'il n'a pas expire)."

Demo-Step `
  "Verifier que le token ne marche plus" `
  "Prouver la revocation" `
  "On retente kv get" `
  {
    try { Vault-AsToken $script:limitedToken @("kv","get","kv/app1") } catch {}
  } `
  "Attendu: echec (token invalide / permission denied)."

Demo-Step `
  "Transit: activer + creer une cle" `
  "Chiffrement en tant que service" `
  "On active transit/ puis on cree app-key" `
  {
    Vault @("secrets","enable","transit")
    Vault @("write","-f","transit/keys/app-key")
  } `
  "Vault garde la cle; l'app ne gere pas de cle privee."

Demo-Step `
  "Transit: chiffrer" `
  "Chiffrer une donnee cote Vault" `
  "Transit attend du base64 (hello-vault)" `
  {
    $cipherJson = Vault @("write","-format=json","transit/encrypt/app-key","plaintext=aGVsbG8tdmF1bHQ=")
    $script:ciphertext = ($cipherJson | ConvertFrom-Json).data.ciphertext
    Write-Host "CIPHERTEXT=$script:ciphertext" -ForegroundColor Green
  } `
  "On recupere un ciphertext (vault:vX:...)."

Demo-Step `
  "Transit: dechiffrer" `
  "Recuperer la donnee sans exposer la cle" `
  "On envoie le ciphertext a Vault" `
  {
    if (-not $script:ciphertext) { throw "ciphertext manquant: exécute l'étape 'chiffrer' d'abord." }
    $plainJson = Vault @("write","-format=json","transit/decrypt/app-key","ciphertext=$script:ciphertext")
    $plaintextB64 = ($plainJson | ConvertFrom-Json).data.plaintext
    Write-Host "PLAINTEXT_BASE64=$plaintextB64" -ForegroundColor Green
  } `
  "Le plaintext est renvoye en base64 (ici hello-vault)."

Demo-Step `
  "Response wrapping (one-shot)" `
  "Livrer une reponse une seule fois" `
  "Vault renvoie un wrapping token au lieu du secret" `
  {
    $wrapJson = Vault @("kv","get","-wrap-ttl=60s","-format=json","kv/app1")
    $wrapObj = $wrapJson | ConvertFrom-Json
    $script:wrappingToken = $wrapObj.wrap_info.token
    Write-Host "WRAPPING_TOKEN=$script:wrappingToken" -ForegroundColor Green
  } `
  "Le wrapping token est a usage unique et expire rapidement."

Demo-Step `
  "Unwrap (1 fois)" `
  "Recuperer la reponse wrappee" `
  "On appelle vault unwrap" `
  {
    if (-not $script:wrappingToken) { throw "wrapping token manquant: exécute l'étape wrapping d'abord." }
    Vault @("unwrap",$script:wrappingToken)
  } `
  "On recupere le secret UNE seule fois."

Demo-Step `
  "Unwrap (2e fois -> echec)" `
  "Prouver le one-shot" `
  "On retente unwrap" `
  {
    try { Vault @("unwrap",$script:wrappingToken) } catch {}
  } `
  "Attendu: erreur, le token a deja ete consomme."

Demo-Step `
  "Audit: montrer un extrait" `
  "Voir la trace des actions" `
  "On affiche les dernieres lignes de /tmp/audit.log" `
  { docker exec $ServerName sh -lc "tail -n 20 /tmp/audit.log" 2>$null } `
  "On voit les endpoints et le resultat (allowed/denied) sans exposer les secrets en clair."

Header "Fin"
Write-Host "Demo terminee." -ForegroundColor Green
Write-Host "Nettoyage: .\\cleanup.ps1" -ForegroundColor Green

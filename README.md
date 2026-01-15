# HashiCorp Vault — Démo “gestion des secrets” (Docker)

Démo reproductible et **100% locale** pour illustrer les fondamentaux de la gestion des secrets avec HashiCorp Vault, sans installation de Vault sur la machine (Docker uniquement).

Objectifs :
- Démarrer Vault en mode démo (`-dev`)
- Stocker un secret via KV v2
- Appliquer le **moindre privilège** via une policy
- Créer un token applicatif limité (TTL)
- Prouver l'accès autorisé/refusé selon la policy

> Note sécurité : les valeurs utilisées (ex: `db_password=S3cret!`) sont **fictives** et présentes uniquement pour la démonstration.

## Prérequis
- Windows + PowerShell
- Docker Desktop installé et **démarré**

Vérification :
```powershell
docker version
```

## Quickstart (démo automatisée)
Depuis la racine du dépôt :
```powershell
.\run.ps1
```

La première exécution peut être plus longue (pull de l'image Docker). Pour éviter la latence le jour de la présentation :
```powershell
docker pull hashicorp/vault:1.16
```

Puis lancer en sautant le pull :
```powershell
.\run.ps1 -SkipPull
```

### Ce que la démo fait exactement
Le flux automatisé :
- Lance un conteneur Vault en mode `-dev` (in-memory, auto-unseal) sur `http://127.0.0.1:8200`
- Active KV v2 sur le chemin `kv/`
- Écrit un secret `kv/app1`
- Charge la policy `app1-read` (fichier HCL)
- Crée un token limité (TTL 1h) associé à cette policy
- Vérifie :
	- lecture autorisée sur `kv/app1`
	- écriture refusée sur `kv/other`

À la fin, le script affiche un `TOKEN_LIMITED = ...` (token applicatif) pour illustrer la séparation **admin vs application**.

## Démo “live” (pas-à-pas)
Pour une présentation orale, version interactive avec pauses et phrases à dire :
```powershell
.\demo_live.ps1
```

## Nettoyage
Arrêt/suppression du conteneur + du réseau Docker de démo :
```powershell
.\cleanup.ps1
```

## Structure du dossier
- [run.ps1](run.ps1) : point d'entrée (option `-SkipPull`)
- [demo_docker.ps1](demo_docker.ps1) : exécute la démo Vault via `docker exec`
- [demo_live.ps1](demo_live.ps1) : version interactive (présentation)
- [cleanup.ps1](cleanup.ps1) : nettoyage Docker
- [app1-read.hcl](app1-read.hcl) : policy Vault (read-only sur `kv/app1`)

## Limites (important pour un repo public)
- Le mode Vault `-dev` est **uniquement** pour la démo : pas de persistance, pas de TLS, root token statique.
- En production : TLS, audit, authentification (OIDC/Kubernetes/AppRole), politiques revues, haute dispo + sauvegardes.

## Troubleshooting
- Docker daemon non démarré : lancer Docker Desktop.
- Port 8200 occupé : exécuter `docker rm -f vault-dev` puis relancer.
- Première exécution lente : faire `docker pull hashicorp/vault:1.16` en amont.

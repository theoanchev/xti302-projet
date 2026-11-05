# Projet XTI302-CYB – Durcir un serveur Linux et le prouver

Contexte choisi : _à compléter (A, B ou C)_

## Environnement

| Élément | Choix |
|---|---|
| Hyperviseur | VirtualBox 7 (hôte Windows) |
| VM | `debian13-projet`, Debian 13.7 netinst officielle, installation minimale **sans interface graphique** (tâches : *serveur SSH* + *utilitaires usuels du système*) |
| Ressources | 2 vCPU, 2 Go RAM, disque système 20 Go (`/dev/sda`) |
| Disque sauvegardes | 2 Go (`/dev/sdb`), vide au snapshot |
| Réseau | Carte 1 NAT : SSH redirigé `127.0.0.1:2222 → 22` · Carte 2 réseau privé hôte : `enp0s8` (tests et scans depuis l'hôte, configurée par `installer.sh`) |
| Comptes à l'installation | root sans mot de passe (désactivé), utilisateur `theo` membre du groupe `sudo` |
| Snapshot | `vierge` : état juste après l'installation |
| Paquets | Dépôts Debian officiels uniquement (pas de Guest Additions) |

## Connexion depuis l'hôte

```powershell
& "$env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe" startvm debian13-projet --type headless
ssh -p 2222 theo@127.0.0.1
```

Revenir à l'état vierge : `powershell -ExecutionPolicy Bypass -File .\vm\restaurer-vierge.ps1`

## Installation et vérification

```bash
sudo ./installer.sh     # reconstruit toute la configuration depuis le snapshot vierge
sudo ./verifier.sh      # teste chaque exigence ([OK] / [KO])
```

## Arborescence

```
vm/                 outils côté hôte (restauration du snapshot)
config/             sshd_config.d, sudoers.d, nftables, fail2ban, journald, clés publiques
installer.sh  creer_comptes.sh  comptes.csv  analyse_logs.sh  sauvegarde.sh  verifier.sh   (à venir)
DOSSIER.md          (à venir)
```

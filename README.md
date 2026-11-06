# Projet XTI302-CYB – Durcir un serveur Linux et le prouver

Contexte choisi : **C – Laboratoire BioLab** (groupes technique, chercheurs, doctorants, invite ; les invités n'ont accès qu'en SFTP).

## Prérequis

- Hôte avec VirtualBox 7 et un client OpenSSH (Windows 10/11 : intégré)
- VM Debian 13 minimale restaurée sur le snapshot `vierge`
- Accès SSH à la VM avec un compte sudo (`theo`) le temps de lancer `installer.sh`

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
config/             sshd_config.d, sudoers.d, nftables, fail2ban, journald, apt, systemd (timer de sauvegarde), clés publiques
preuves/            sorties de commandes qui prouvent les exigences
installer.sh        installe et configure tout depuis le snapshot vierge
creer_comptes.sh    comptes, groupes, /srv et ACL (lit comptes.csv)
comptes.csv         liste des comptes du laboratoire
analyse_logs.sh     analyse des connexions SSH (seuil dans config/analyse-logs)
sauvegarde.sh       sauvegarde incrémentale de /srv et /etc sur le second disque
verifier.sh         teste chaque exigence ([OK] / [KO])
DOSSIER.md          tableau de conformité, choix techniques, défense, restauration
```

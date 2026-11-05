# Dossier – Projet XTI302-CYB : durcir un serveur Linux et le prouver

Contexte C – Laboratoire BioLab · Groupe : Théo, Adrien, El Yazid

> Sections marquées **(à compléter – Adrien)** ou **(à compléter – El Yazid)** : à remplir par la personne responsable de l'exigence.

## 1. Tableau de conformité

Références ANSSI : guide *Recommandations pour un usage sécurisé d'(Open)SSH* (DAT-NT-007, 2015), noté « SSH-Rn ».

| ID | Ce qui a été fait | Test (`verifier.sh`) | ANSSI |
|---|---|---|---|
| C1 | (à compléter – Adrien) | `test_C1` | |
| C2 | (à compléter – Adrien) | `test_C2` | |
| C3 | Fichier `config/sudoers.d/admins` (à compléter – El Yazid). `installer.sh` vérifie chaque fichier sudoers avec `visudo -c`, l'installe en root 0440, puis vide le groupe `sudo` du compte d'installation une fois les admins en place. Scripts lancés en root installés dans `/usr/local/sbin`, propriétaire root, 0755 | `test_C3`, `test_scripts_root` | |
| C4 | `passwd -l root` ; répertoires personnels en 0700 et `HOME_MODE 0700` pour les comptes futurs (dans `installer.sh`) | `test_C4` (à compléter – El Yazid) | |
| S1 | `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `AuthenticationMethods publickey` ; clés ed25519 | `test_S1` ; depuis l'hôte : `ssh -o PubkeyAuthentication=no` → « Permission denied (publickey) » | SSH-R17 |
| S2 | `PermitRootLogin no` ; comptes administrateurs nominatifs | `test_S2` ; depuis l'hôte : `ssh root@…` refusé | SSH-R21 |
| S3 | `AllowGroups acces_ssh` ; invités limités au SFTP (`Match Group invite`, `ForceCommand internal-sftp`, `PermitTTY no`) | `test_S3`, `test_S_invite` | SSH-R22, SSH-R24 |
| S4 | `MaxAuthTries 3`, `LoginGraceTime 30`, `ChannelTimeout session=10m`, `ClientAliveInterval 300` × `ClientAliveCountMax 2` | `test_S4` (2 tests) | |
| S5 | `/etc/ssh/sshd_config.d/10-durcissement.conf` (root, 0644) ; `installer.sh` lance `sshd -t` avant `systemctl reload ssh` et retire le fichier s'il est invalide | `test_S5` | |
| J1 | (à compléter – Adrien) | `test_J1` | |
| J2 | `/etc/nftables.conf` : table `inet filtre`, entrée `policy drop`, acceptées : connexions établies, boucle locale, TCP 22 ; transit `drop` ; service `nftables` activé au démarrage | `test_J2` (2 tests) ; depuis l'hôte : `nmap` ne voit que le port 22 | SSH-R27 (complément pare-feu) |
| J3 | (à compléter – Adrien) | `test_J3` | |
| J4 | (à compléter – El Yazid) | `test_J4` | |
| B1 | Second disque (2 Go) formaté une seule fois en ext4, étiquette `sauvegardes`, monté sur `/sauvegardes` par UUID dans `/etc/fstab` (`nodev,nosuid,noexec,nofail`). Script `sauvegarde.sh` : (à compléter – Adrien) | `test_B1_disque`, `test_B1` | |
| B2 | (à compléter – Adrien) | `test_B2` | |
| B3 | `/sauvegardes` : `root:admins`, 0750 (dans `installer.sh`) | `test_B3` (à compléter – Adrien) | |
| B4 | (à compléter – El Yazid) | `test_B4` | |
| D1 | Paquet `unattended-upgrades` ; `/etc/apt/apt.conf.d/20auto-upgrades` : liste des paquets et mises à jour de sécurité chaque jour ; minuteurs `apt-daily*` activés | `test_D1` | |
| D2 | (à compléter – El Yazid) | `test_D2` | |
| D3 | (à compléter – El Yazid) | `test_D3` | |

## 2. Choix techniques

### Accès SSH (Théo)
- **3 essais au lieu de 4** : un utilisateur légitime avec une clé réussit du premier coup. 3 laisse de la marge si plusieurs clés sont proposées. Au-delà, fail2ban (J1) bannit l'adresse.
- **10 minutes d'inactivité** (le sujet tolère 15) : une session oubliée ouverte est une porte d'entrée. `ChannelTimeout` ferme les sessions inactives ; `ClientAlive*` détecte les connexions mortes (client disparu), en 2 × 300 s.
- **`LoginGraceTime 30`** : limite les connexions laissées en attente d'authentification, qui occupent le serveur.
- **`AuthenticationMethods publickey`** : garantit S1 même si une autre option venait à réactiver le mot de passe.
- **Préfixe `10-`** : sshd retient la première valeur lue ; ce fichier est inclus en tête de `sshd_config`.
- **Clés ed25519** : plus récentes que les recommandations du guide ANSSI de 2015 (ECDSA, RSA ≥ 2048 bits), plus courtes et sans paramètre fragile.
- **Bonus** : `X11Forwarding`, `AllowTcpForwarding`, `AllowAgentForwarding` désactivés (SSH-R27, SSH-R28) ; `LogLevel VERBOSE` journalise l'empreinte de la clé utilisée (imputabilité, utile à J4).

### Pare-feu (Théo)
- **Pas de `flush ruleset`** : cela supprimerait aussi la table de fail2ban à chaque rechargement. On remplace uniquement notre table `inet filtre` (idiome `add table` + `delete table`). Testé : la table de fail2ban est conservée.
- **Boucle locale acceptée** : le trafic de la machine vers elle-même ne vient pas du réseau ; le bloquer casserait des services locaux sans gain de sécurité.
- **Pas d'ICMP entrant** : le sujet n'autorise que SSH. Conséquence assumée : le serveur ne répond pas au `ping`.
- **`inet`** : une seule table couvre IPv4 et IPv6.

### Disque de sauvegarde et `installer.sh` (Théo)
- **Le disque n'est formaté que s'il est vierge.** S'il porte déjà l'étiquette `sauvegardes`, il est réutilisé ; s'il contient autre chose, `installer.sh` refuse de l'effacer. Relancer le script ne détruit donc jamais les sauvegardes.
- **Montage par UUID** : le nom `/dev/sdb` peut changer d'un démarrage à l'autre. `nofail` : le serveur démarre même si le disque est absent.
- **Options `nodev,nosuid,noexec`** : rien d'exécutable ne doit être lancé depuis les sauvegardes.
- **Garde-fou SSH** : `installer.sh` refuse d'activer `AllowGroups acces_ssh` si aucun membre du groupe n'a de clé installée, pour ne pas s'enfermer dehors.
- **Ordre** : comptes avant SSH (le groupe et les clés doivent exister), pare-feu avant fail2ban (fail2ban ajoute sa table par-dessus).
- **Scripts lancés en root dans `/usr/local/sbin`, propriétaire root** : si `analyse_logs.sh` était modifiable par `support`, il suffirait d'y ajouter une ligne pour obtenir un shell root via sudo.

### `verifier.sh` (Théo)
- **Pas de `set -e`** : le script doit continuer après un test échoué pour tous les afficher.
- **Pas de `pipefail`** : avec `sshd -T | grep -q`, `grep` s'arrête dès qu'il trouve, `sshd` reçoit SIGPIPE et le test échouerait à tort. La configuration est donc lue une fois dans une variable.
- **`set -u` conservé** : une variable non définie est une erreur de programmation.

### Comptes, sudo, journaux, sauvegarde
(à compléter – Adrien et El Yazid)

## 3. Défense

| Attaque | Ce que la configuration rend plus difficile | Ce qu'elle ne couvre pas |
|---|---|---|
| Force brute SSH | Aucun mot de passe accepté, 3 essais par connexion, bannissement par fail2ban | Le vol de la clé privée sur le poste d'un administrateur |
| Vol d'un mot de passe | Inutile pour SSH (clés uniquement) ; root verrouillé et interdit | Une fois connecté avec une clé volée, le mot de passe sert encore pour `sudo` |
| Compte invité compromis | (à compléter – El Yazid) | |
| Doctorant curieux | (à compléter – El Yazid) | |
| Scan de ports | Seul le port 22 répond (J2) ; les autres paquets sont ignorés | Les failles éventuelles d'OpenSSH lui-même (d'où D1, mises à jour automatiques) |

## 4. Procédure de restauration d'une sauvegarde

(à compléter – Adrien et El Yazid)

## Sources
- [ANSSI – Recommandations pour un usage sécurisé d'(Open)SSH](https://messervices.cyber.gouv.fr/documents-guides/NT_OpenSSH.pdf)

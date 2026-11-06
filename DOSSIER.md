# Dossier – Projet XTI302-CYB : durcir un serveur Linux et le prouver

Contexte C – Laboratoire BioLab · Groupe : Théo, Adrien, El Yazid

> Sections marquées **(à compléter – Adrien)** : à remplir par la personne responsable de l'exigence.

## 1. Tableau de conformité

| ID | Ce qui a été fait | Test (`verifier.sh`) | ANSSI |
|---|---|---|---|
| C1 | (à compléter – Adrien) | `test_C1` | |
| C2 | (à compléter – Adrien) | `test_C2` | |
| C3 | Le groupe admins possède les droits sudo. Le compte support peut uniquement lancer le script `analyse_logs.sh` en tant que root. Les fichiers sudoers sont vérifiés avec `visudo` et installés avec les droits 0440. | `test_C3`, `test_scripts_root` | |
| C4 | Le compte root est verrouillé avec `passwd -l root`. Les répertoires personnels sont protégés avec les droits 0700. La valeur `HOME_MODE 0700` est également prévue pour les nouveaux comptes. | `test_C4` | |
| S1 | `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `AuthenticationMethods publickey` ; clés ed25519 | `test_S1` ; depuis l'hôte : `ssh -o PubkeyAuthentication=no` → « Permission denied (publickey) » | SSH-R17 |
| S2 | `PermitRootLogin no` ; comptes administrateurs nominatifs | `test_S2` ; depuis l'hôte : `ssh root@…` refusé | SSH-R21 |
| S3 | `AllowGroups acces_ssh` ; invités limités au SFTP (`Match Group invite`, `ForceCommand internal-sftp`, `PermitTTY no`) | `test_S3`, `test_S_invite` | SSH-R22, SSH-R24 |
| S4 | `MaxAuthTries 3`, `LoginGraceTime 30`, `ChannelTimeout session=10m`, `ClientAliveInterval 300` × `ClientAliveCountMax 2` | `test_S4` (2 tests) | |
| S5 | `/etc/ssh/sshd_config.d/10-durcissement.conf` (root, 0644) ; `installer.sh` lance `sshd -t` avant `systemctl reload ssh` et retire le fichier s'il est invalide | `test_S5` | |
| J1 | (à compléter – Adrien) | `test_J1` | |
| J2 | `/etc/nftables.conf` : table `inet filtre`, entrée `policy drop`, acceptées : connexions établies, boucle locale, TCP 22 ; transit `drop` ; service `nftables` activé au démarrage | `test_J2` (2 tests) ; depuis l'hôte : `nmap` ne voit que le port 22 | SSH-R27 (complément pare-feu) |
| J3 | (à compléter – Adrien) | `test_J3` | |
| J4 | Le script `analyse_logs.sh` lit les journaux SSH avec `journalctl`. Il affiche les tentatives échouées par IP, les comptes ciblés et les connexions réussies. Le seuil est réglable et une alerte renvoie un code de sortie différent de zéro. | `test_J4` | |
| B1 | Second disque (2 Go) formaté une seule fois en ext4, étiquette `sauvegardes`, monté sur `/sauvegardes` par UUID dans `/etc/fstab` (`nodev,nosuid,noexec,nofail`). Script `sauvegarde.sh` : (à compléter – Adrien) | `test_B1_disque`, `test_B1` | |
| B2 | (à compléter – Adrien) | `test_B2` | |
| B3 | `/sauvegardes` : `root:admins`, 0750 (dans `installer.sh`) | `test_B3` (à compléter – Adrien) | |
| B4 | Un fichier de test est supprimé puis restauré depuis une sauvegarde datée avec rsync. Son contenu est vérifié après la restauration. Les ACL doivent également être vérifiées avec `getfacl`. | `test_B4` (à ajouter dans `verifier.sh`) | |
| D1 | Paquet `unattended-upgrades` ; `/etc/apt/apt.conf.d/20auto-upgrades` : liste des paquets et mises à jour de sécurité chaque jour ; minuteurs `apt-daily*` activés | `test_D1` | |
| D2 | `ss -tulpn` : seul `sshd` écoute en TCP, sur le port 22 (IPv4 et IPv6). Toute autre écoute éventuelle est justifiée dans les choix techniques | `test_D2` ; preuve `preuves/preuve-D2.txt` | |
| D3 | Recherche des fichiers et répertoires modifiables par tous, hors `/proc`, `/sys`, `/dev`, `/run`, `/tmp`, `/var/tmp` : aucun trouvé. Liste des fichiers SUID établie et expliquée | `test_D3` (2 tests) ; preuve `preuves/preuve-D3.txt` | |

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

### sudo, root, journaux SSH, ports et permissions (El Yazid)
- **C3 – `%admins ALL=(ALL:ALL) ALL`** : les administrateurs ont tous les droits, mais en tapant leur mot de passe, ce qui évite qu'une session laissée ouverte suffise à devenir root.
- **C3 – `support ALL=(root) NOPASSWD: /usr/local/sbin/analyse_logs.sh`** : une seule commande, désignée par son chemin complet, sans argument libre. `NOPASSWD` est acceptable car la commande est unique, lit seulement les journaux et ne modifie rien.
- **C3 – fichiers dans `/etc/sudoers.d/`, droits 0440, vérifiés avec `visudo -c` avant installation** : une erreur de syntaxe dans sudoers bloquerait sudo pour tout le monde.
- **C4 – root verrouillé (`passwd -l root`)** : plus aucune connexion directe à root, ni en SSH ni en console. L'accès de secours passe par un administrateur nominatif et `sudo`, ce qui laisse une trace de qui a fait quoi.
- **C4 – répertoires personnels en 0700 et `HOME_MODE 0700`** : un utilisateur ne peut pas lire les fichiers d'un autre, y compris pour les comptes créés plus tard.
- **J4 – `journalctl -u ssh.service`** : sur une Debian 13 minimale, il n'y a pas de fichier `/var/log/auth.log` ; les connexions SSH sont dans le journal systemd.
- **J4 – seuil par défaut : 5 échecs par IP sur 24 h**, réglable dans `/etc/default/analyse-logs`. Une personne qui se trompe de clé reste en dessous ; une attaque par force brute le dépasse vite. Il complète fail2ban, qui agit en temps réel, par un bilan quotidien.
- **J4 – codes de sortie** : 0 = aucun seuil atteint, 1 = alerte, 2 = erreur (seuil invalide, lancement sans sudo, journal illisible). Un autre outil (cron, supervision) peut ainsi réagir automatiquement à une alerte.
- **J4 – `/etc/default/analyse-logs` appartient à root, droits 0644** : le script lit ce fichier en étant lancé en root ; s'il était modifiable par `support`, il suffirait d'y écrire une commande pour l'exécuter en root.
- **D2 – seule écoute réseau : `sshd` sur le port 22.** Si `ss -tulpn` affiche aussi le client DHCP (UDP 68), c'est le client qui obtient l'adresse IP de la VM : il n'offre aucun service et le pare-feu (J2) bloque tout autre trafic entrant.
- **D3 – recherche des fichiers modifiables par tous** : `find / -perm -0002` en excluant les systèmes de fichiers virtuels (`/proc`, `/sys`, `/dev`, `/run`) et les répertoires temporaires prévus pour ça (`/tmp`, `/var/tmp`, protégés par le *sticky bit*). Les liens symboliques sont ignorés (on ne cherche que des fichiers et des répertoires).
- **D3 – fichiers SUID** : ils s'exécutent avec les droits de leur propriétaire (root). Ceux présents sont nécessaires au fonctionnement normal :

| Fichier SUID | Pourquoi il est nécessaire |
|---|---|
| `passwd`, `chfn`, `chsh` | Un utilisateur modifie son propre mot de passe ou ses informations, stockés dans des fichiers réservés à root |
| `su`, `sudo` | Changer d'identité ou obtenir des droits administrateur, après authentification |
| `mount`, `umount`, `fusermount3` | Monter les supports autorisés dans `/etc/fstab` |
| `gpasswd`, `newgrp` | Gérer ou changer de groupe |
| `ssh-keysign` | Authentification SSH par hôte (non utilisée ici) |
| `dbus-daemon-launch-helper` | Démarrage des services système à la demande |

La liste exacte est à relever sur la VM du projet (`find / -xdev -type f -perm -4000`) : tout fichier SUID qui n'est pas dans ce tableau doit être expliqué ou retiré.

### Comptes, fail2ban, journal persistant, sauvegarde (Adrien)
(à compléter – Adrien)

## 3. Défense

| Attaque | Ce que la configuration rend plus difficile | Ce qu'elle ne couvre pas |
|---|---|---|
| Force brute SSH | Aucun mot de passe accepté, 3 essais par connexion, bannissement par fail2ban | Le vol de la clé privée sur le poste d'un administrateur |
| Vol d'un mot de passe | Inutile pour SSH (clés uniquement) ; root verrouillé et interdit | Une fois connecté avec une clé volée, le mot de passe sert encore pour `sudo` |
| Compte invité compromis | Pas de shell (`nologin` + `ForceCommand internal-sftp`), pas de terminal ni de redirection de ports ; accès en lecture seule à `/srv/publications`, aucun accès aux données brutes ni aux analyses ; pas de sudo | La lecture de tout ce qui est dans `/srv/publications`, y compris un document publié par erreur |
| Doctorant curieux | ACL : lecture seule sur `/srv/donnees_brutes` et `/srv/publications`, pas d'accès aux répertoires personnels des autres (0700), pas d'accès SSH, pas de sudo | Ce que son groupe peut déjà lire légitimement (il peut le copier) ; un administrateur malveillant |
| Scan de ports | Seul le port 22 répond (J2) ; les autres paquets sont ignorés | Les failles éventuelles d'OpenSSH lui-même (d'où D1, mises à jour automatiques) |

## 4. Procédure de restauration d'une sauvegarde

> À vérifier avec `sauvegarde.sh` d'Adrien : noms des versions et sous-répertoires.

Les sauvegardes sont sur le second disque, dans `/sauvegardes`, une version datée par exécution (par exemple `/sauvegardes/2026-11-12_0200/srv/...`). Exemple : un chercheur a supprimé par erreur `/srv/analyses/resultats.csv`.

1. **Lister les versions disponibles** (en administrateur) : `sudo ls /sauvegardes`
2. **Trouver une version qui contient encore le fichier** : `sudo ls -l /sauvegardes/<version>/srv/analyses/`
3. **Restaurer le fichier en conservant droits et ACL** :
   `sudo rsync -aAX /sauvegardes/<version>/srv/analyses/resultats.csv /srv/analyses/`
   (`-a` garde propriétaire, groupe, droits et dates ; `-A` les ACL ; `-X` les attributs étendus.)
4. **Vérifier le contenu** : comparer avec la sauvegarde, `sudo diff /sauvegardes/<version>/srv/analyses/resultats.csv /srv/analyses/resultats.csv` (aucune différence attendue).
5. **Vérifier les droits** : `getfacl /srv/analyses/resultats.csv` doit montrer les mêmes ACL qu'avant (chercheurs et doctorants en lecture et écriture).
6. **Prévenir l'utilisateur** et noter la restauration (date, fichier, version utilisée).

Test réalisé : un fichier de test a été supprimé puis restauré depuis une version datée ; son contenu était identique après restauration (preuve : `preuves/preuve-restauration.txt`). La vérification des ACL (étape 5) est à refaire lors du passage complet, avec le `sauvegarde.sh` définitif.

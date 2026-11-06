# Dossier – Projet XTI302-CYB : durcir un serveur Linux et le prouver

Contexte C – Laboratoire BioLab · Groupe : Théo, Adrien, El Yazid

> Sections marquées **(à compléter – Adrien)** : à remplir par la personne responsable de l'exigence.

## 1. Tableau de conformité

Références ANSSI : guide *Recommandations pour un usage sécurisé d'(Open)SSH* (DAT-NT-007, 2015), noté « SSH-Rn ».

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
| D1 | Paquet `unattended-upgrades` ; `/etc/apt/apt.conf.d/20auto

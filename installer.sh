#!/usr/bin/env bash
# installer.sh - reconstruit toute la configuration du serveur depuis le snapshot "vierge".
# Projet XTI302-CYB, contexte C (BioLab). Integration : Theo.
# Usage : sudo ./installer.sh   (depuis la racine du depot copie sur la VM)
# Idempotent : peut etre relance sans danger (aucune donnee effacee, pas de doublon).
#
# Ordre des etapes (chaque etape a besoin des precedentes) :
#   paquets -> reseau -> disque de sauvegarde -> comptes (C1, C2) -> sudo (C3)
#   -> root et homes (C4) -> SSH (S1-S5) -> pare-feu (J2) -> journal (J3)
#   -> fail2ban (J1, apres le pare-feu) -> mises a jour auto (D1)
#   -> scripts dans /usr/local/sbin -> planification de la sauvegarde (B2)

set -euo pipefail

DEPOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
readonly DEPOT
readonly POINT_SAUVEGARDE=/sauvegardes
readonly ETIQUETTE_SAUVEGARDE=sauvegardes

log()    { echo "[installer] $*"; }
erreur() { echo "[installer] ERREUR : $*" >&2; exit 1; }

# =============================== Verifications =================================
verifier_root() {
    [[ $EUID -eq 0 ]] || erreur "ce script doit etre lance en root (sudo ./installer.sh)"
}

# ==================== Paquets (depots Debian officiels uniquement) ===============
installer_paquets() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    # sudo (C3), acl (C2), openssh-server (S), nftables (J2), fail2ban (J1),
    # rsync (B1), unattended-upgrades (D1).
    apt-get install -y -q sudo acl openssh-server nftables fail2ban rsync unattended-upgrades
    log "paquets installes"
}

# ============== Reseau : carte 2 (reseau prive hote) pour les tests ==============
configurer_reseau() {
    local fichier=/etc/network/interfaces
    if ! grep -q '^iface enp0s8' "$fichier"; then
        printf '\n# Carte 2 : reseau prive hote (tests et scans depuis l hote)\nallow-hotplug enp0s8\niface enp0s8 inet dhcp\n' >> "$fichier"
        log "interface enp0s8 declaree"
    fi
    # ifup echoue si l'interface est deja active : ce n'est pas une erreur ici.
    ifup enp0s8 >/dev/null 2>&1 || true
}

# ===================== Second disque : sauvegardes (B1) ==========================
# Trouve le disque qui n'est PAS celui du systeme (le 2e disque de la VM).
trouver_disque_sauvegarde() {
    local disque_systeme
    disque_systeme="$(lsblk -no PKNAME "$(findmnt -no SOURCE /)")"
    lsblk -dn -o NAME,TYPE | awk -v sys="$disque_systeme" '$2 == "disk" && $1 != sys && !trouve { print "/dev/" $1; trouve = 1 }'
}

preparer_disque_sauvegarde() {
    local disque type_fs etiquette uuid
    # Deja pret (relance du script) : on ne touche a rien.
    if findmnt -n "$POINT_SAUVEGARDE" >/dev/null; then
        log "disque de sauvegarde deja monte sur $POINT_SAUVEGARDE"
        return 0
    fi
    disque="$(trouver_disque_sauvegarde)"
    [[ -n "$disque" ]] || erreur "aucun second disque trouve pour les sauvegardes"

    type_fs="$(blkid -o value -s TYPE "$disque" || true)"
    etiquette="$(blkid -o value -s LABEL "$disque" || true)"
    if [[ -z "$type_fs" ]]; then
        # Disque vierge : on le formate UNE seule fois.
        if [[ "$(lsblk -n -o NAME "$disque" | wc -l)" -gt 1 ]]; then
            erreur "$disque contient des partitions : formatage refuse"
        fi
        mkfs.ext4 -q -L "$ETIQUETTE_SAUVEGARDE" "$disque"
        log "$disque formate en ext4 (etiquette $ETIQUETTE_SAUVEGARDE)"
    elif [[ "$etiquette" != "$ETIQUETTE_SAUVEGARDE" ]]; then
        # Un systeme de fichiers inconnu : on refuse de l'effacer.
        erreur "$disque contient deja un systeme de fichiers ($type_fs) : formatage refuse"
    fi

    # Montage permanent par UUID (le nom sdb peut changer d'un demarrage a l'autre).
    uuid="$(blkid -o value -s UUID "$disque")"
    install -d -m 0700 "$POINT_SAUVEGARDE"
    if ! grep -q "UUID=$uuid" /etc/fstab; then
        echo "UUID=$uuid  $POINT_SAUVEGARDE  ext4  defaults,nodev,nosuid,noexec,nofail  0  2" >> /etc/fstab
    fi
    systemctl daemon-reload
    mount "$POINT_SAUVEGARDE"
    log "disque de sauvegarde monte sur $POINT_SAUVEGARDE"
}

# B3 : le repertoire de sauvegarde n'est accessible qu'aux administrateurs.
proteger_sauvegardes() {
    if getent group admins >/dev/null; then
        chown root:admins "$POINT_SAUVEGARDE"
        chmod 0750 "$POINT_SAUVEGARDE"
    else
        chown root:root "$POINT_SAUVEGARDE"
        chmod 0700 "$POINT_SAUVEGARDE"
    fi
}

# =================== Comptes, groupes, /srv, ACL, cles (Adrien) ===================
creer_comptes() {
    if [[ -f "$DEPOT/creer_comptes.sh" ]]; then
        bash "$DEPOT/creer_comptes.sh" "$DEPOT/comptes.csv"
        install -D -o root -g root -m 0644 "$DEPOT/comptes.csv" /usr/local/share/xti302/comptes.csv
        log "comptes crees"
    else
        log "creer_comptes.sh absent : etape sautee"
    fi
}

# ============================ sudo (C3, El Yazid) ================================
installer_sudoers() {
    local fichier
    shopt -s nullglob
    for fichier in "$DEPOT"/config/sudoers.d/*; do
        # visudo -c : une erreur de syntaxe dans sudoers casserait sudo pour tous.
        visudo -cq -f "$fichier" || erreur "syntaxe invalide dans $fichier"
        install -o root -g root -m 0440 "$fichier" /etc/sudoers.d/
        log "sudoers installe : $(basename "$fichier")"
    done
    shopt -u nullglob
}

# C3 : "aucun autre compte n'a sudo". Le compte cree a l'installation est dans
# le groupe sudo : on vide ce groupe, mais seulement si des admins existent
# deja, sinon on se retirerait tout acces administrateur.
# Membres du groupe admins : listes dans /etc/group OU ayant admins comme groupe principal
# (Linux ne liste pas dans /etc/group les comptes dont c'est le groupe principal).
membres_admins() {
    local gid
    gid="$(getent group admins | cut -d: -f3)"
    [[ -n "$gid" ]] || return 0
    { getent group admins | cut -d: -f4 | tr ',' '\n'
      getent passwd | awk -F: -v g="$gid" '$4 == g { print $1 }'; } | grep -v '^$' | sort -u
}

vider_groupe_sudo() {
    local admins membres utilisateur
    admins="$(membres_admins)"
    if [[ -z "$admins" || ! -e /etc/sudoers.d/admins ]]; then
        log "groupe admins vide ou sudoers admins absent : groupe sudo conserve"
        return 0
    fi
    membres="$(getent group sudo | cut -d: -f4 || true)"
    for utilisateur in ${membres//,/ }; do
        gpasswd -d "$utilisateur" sudo >/dev/null
        log "$utilisateur retire du groupe sudo"
    done
}

# ======================= Root et repertoires personnels (C4) =====================
verrouiller_root_et_homes() {
    passwd -l root >/dev/null
    local home
    shopt -s nullglob
    for home in /home/*/; do
        chmod 0700 "$home"
    done
    shopt -u nullglob
    # Les futurs comptes : home cree en 0700 (useradd lit HOME_MODE).
    if grep -q '^HOME_MODE' /etc/login.defs; then
        sed -i 's/^HOME_MODE.*/HOME_MODE\t0700/' /etc/login.defs
    else
        printf 'HOME_MODE\t0700\n' >> /etc/login.defs
    fi
    log "root verrouille, repertoires personnels en 0700"
}

# ======================== Garde-fou avant AllowGroups ============================
verifier_acces_ssh() {
    local ligne membres utilisateur home
    ligne="$(getent group acces_ssh)" \
        || erreur "le groupe acces_ssh n'existe pas : AllowGroups bloquerait tout le monde"
    membres="$(cut -d: -f4 <<< "$ligne")"
    for utilisateur in ${membres//,/ }; do
        home="$(getent passwd "$utilisateur" | cut -d: -f6)"
        if [[ -s "$home/.ssh/authorized_keys" ]]; then
            return 0
        fi
    done
    erreur "aucun membre de acces_ssh n'a de cle installee : SSH vous enfermerait dehors"
}

# ========================== SSH (S1 a S5, Theo) ==================================
configurer_ssh() {
    local conf installes=()
    verifier_acces_ssh
    install -d -o root -g root -m 0755 /etc/ssh/sshd_config.d
    for conf in "$DEPOT"/config/ssh/sshd_config.d/*.conf; do
        install -o root -g root -m 0644 "$conf" /etc/ssh/sshd_config.d/
        installes+=("/etc/ssh/sshd_config.d/$(basename "$conf")")
    done
    # S5 : on valide AVANT de recharger ; si la config est fausse, on la retire.
    if ! sshd -t; then
        rm -f "${installes[@]}"
        erreur "configuration SSH invalide (sshd -t) : fichiers retires, ssh non recharge"
    fi
    systemctl reload ssh
    log "SSH durci et recharge"
}

# ============================ Pare-feu (J2, Theo) =================================
configurer_parefeu() {
    # Verification de la syntaxe avant d'appliquer : un pare-feu casse peut couper SSH.
    nft -c -f "$DEPOT/config/nftables.conf" || erreur "config/nftables.conf invalide"
    install -o root -g root -m 0644 "$DEPOT/config/nftables.conf" /etc/nftables.conf
    systemctl enable --quiet nftables
    nft -f /etc/nftables.conf
    log "pare-feu nftables applique et active au demarrage"
}

# ========================= Journal persistant (J3, Adrien) =======================
configurer_journal() {
    if [[ -f "$DEPOT/config/journald.conf" ]]; then
        install -d -m 0755 /etc/systemd/journald.conf.d
        install -o root -g root -m 0644 "$DEPOT/config/journald.conf" /etc/systemd/journald.conf.d/persistant.conf
        systemctl restart systemd-journald
        log "journal persistant configure"
    else
        log "config/journald.conf absent : etape sautee"
    fi
}

# ========================= fail2ban (J1, Adrien) =================================
# Apres le pare-feu : fail2ban ajoute sa propre table nftables par-dessus.
configurer_fail2ban() {
    local conf trouve=0
    shopt -s nullglob
    for conf in "$DEPOT"/config/fail2ban/jail.d/*.conf; do
        install -o root -g root -m 0644 "$conf" /etc/fail2ban/jail.d/
        trouve=1
    done
    shopt -u nullglob
    if [[ $trouve -eq 1 ]]; then
        systemctl enable --quiet fail2ban
        systemctl restart fail2ban
        log "fail2ban configure"
    else
        log "config/fail2ban/jail.d/ vide : etape sautee"
    fi
}

# =================== Mises a jour de securite automatiques (D1, Theo) ============
configurer_mises_a_jour() {
    install -o root -g root -m 0644 "$DEPOT/config/apt/apt.conf.d/20auto-upgrades" /etc/apt/apt.conf.d/20auto-upgrades
    systemctl enable --quiet apt-daily.timer apt-daily-upgrade.timer
    log "mises a jour de securite automatiques activees"
}

# ============== Scripts lances en root : proprietaire root, 0755 =================
# Un script lance via sudo et modifiable par un utilisateur = elevation de
# privileges (il suffirait d'y ajouter une ligne). On les installe donc dans
# /usr/local/sbin, proprietaire root, modifiable par root seulement.
installer_scripts() {
    local script
    for script in analyse_logs.sh sauvegarde.sh verifier.sh; do
        if [[ -f "$DEPOT/$script" ]]; then
            install -o root -g root -m 0755 "$DEPOT/$script" "/usr/local/sbin/$script"
            log "script installe : /usr/local/sbin/$script"
        fi
    done
    # Seuil d'alerte de analyse_logs.sh (J4). Ce fichier est lu ("source") par un
    # script lance en root via sudo : il doit appartenir a root et n'etre
    # modifiable que par lui, sinon support pourrait y injecter des commandes.
    if [[ -f "$DEPOT/config/analyse-logs" ]]; then
        install -o root -g root -m 0644 "$DEPOT/config/analyse-logs" /etc/default/analyse-logs
        log "seuil d'alerte installe : /etc/default/analyse-logs"
    fi
}

# ================= Planification de la sauvegarde (B2, Adrien) ===================
planifier_sauvegarde() {
    local unite trouve=0
    shopt -s nullglob
    for unite in "$DEPOT"/config/systemd/*.service "$DEPOT"/config/systemd/*.timer; do
        install -o root -g root -m 0644 "$unite" /etc/systemd/system/
        trouve=1
    done
    shopt -u nullglob
    if [[ $trouve -eq 1 ]]; then
        systemctl daemon-reload
        systemctl enable --now --quiet sauvegarde.timer
        log "sauvegarde planifiee (sauvegarde.timer)"
        # Premiere sauvegarde tout de suite : verifier.sh (B1, B2, B4) a une version a controler.
        if systemctl start sauvegarde.service; then
            log "premiere sauvegarde effectuee"
        else
            log "premiere sauvegarde en echec : voir journalctl -u sauvegarde.service"
        fi
    else
        log "config/systemd/ vide : planification sautee"
    fi
}

main() {
    verifier_root
    installer_paquets
    configurer_reseau
    preparer_disque_sauvegarde
    creer_comptes              # avant SSH : cree acces_ssh et installe les cles
    proteger_sauvegardes       # apres les comptes : le groupe admins existe
    installer_sudoers
    vider_groupe_sudo
    verrouiller_root_et_homes
    configurer_ssh
    configurer_parefeu
    configurer_journal
    configurer_fail2ban        # apres le pare-feu
    configurer_mises_a_jour
    installer_scripts
    planifier_sauvegarde
    log "installation terminee - verifier avec : sudo verifier.sh"
}

main "$@"

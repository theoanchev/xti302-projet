#!/usr/bin/env bash
# installer.sh - reconstruit toute la configuration du serveur depuis le snapshot "vierge".
# Projet XTI302-CYB, contexte C (BioLab).
# Usage : sudo ./installer.sh   (depuis la racine du depot copie sur la VM)
# Idempotent : peut etre relance sans danger.

set -euo pipefail

# Dossier du depot, quel que soit l'endroit d'ou le script est lance.
DEPOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
readonly DEPOT

log()    { echo "[installer] $*"; }
erreur() { echo "[installer] ERREUR : $*" >&2; exit 1; }

# --- Verifications ---------------------------------------------------------------
verifier_root() {
    [[ $EUID -eq 0 ]] || erreur "ce script doit etre lance en root (sudo ./installer.sh)"
}

# --- Paquets (depots Debian officiels uniquement) -------------------------------
installer_paquets() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    # sudo : C3 ; acl : C2 (setfacl/getfacl) ; openssh-server : S1-S5.
    # A completer aux seances suivantes : nftables, fail2ban, rsync, unattended-upgrades.
    apt-get install -y -q sudo acl openssh-server
    log "paquets installes"
}

# --- Reseau : carte 2 (reseau prive hote) pour les tests depuis l'hote ----------
configurer_reseau() {
    local fichier=/etc/network/interfaces
    if ! grep -q '^iface enp0s8' "$fichier"; then
        printf '\n# Carte 2 : reseau prive hote (tests et scans depuis l hote)\nallow-hotplug enp0s8\niface enp0s8 inet dhcp\n' >> "$fichier"
        log "interface enp0s8 declaree"
    fi
    # ifup echoue si l'interface est deja active : ce n'est pas une erreur ici.
    ifup enp0s8 >/dev/null 2>&1 || true
}

# --- Comptes, groupes, /srv, ACL, cles (script d'azur424) -----------------------
creer_comptes() {
    if [[ -f "$DEPOT/creer_comptes.sh" ]]; then
        bash "$DEPOT/creer_comptes.sh" "$DEPOT/comptes.csv"
        log "comptes crees"
    else
        log "creer_comptes.sh absent : etape sautee"
    fi
}

# --- Garde-fou : ne jamais appliquer AllowGroups sans un membre qui a une cle -----
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

# --- S1 a S5 : durcissement SSH ---------------------------------------------------
configurer_ssh() {
    local conf installes=()
    verifier_acces_ssh
    install -d -o root -g root -m 0755 /etc/ssh/sshd_config.d
    for conf in "$DEPOT"/config/ssh/sshd_config.d/*.conf; do
        # Proprietaire root, lisible par tous, modifiable par root seulement.
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

main() {
    verifier_root
    installer_paquets
    configurer_reseau
    creer_comptes          # avant SSH : cree acces_ssh et installe les cles
    configurer_ssh
    log "installation terminee - lancer ensuite : sudo ./verifier.sh"
}

main "$@"

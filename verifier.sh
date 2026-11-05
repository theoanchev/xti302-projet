#!/usr/bin/env bash
# verifier.sh - teste chaque exigence du cahier des charges et affiche [OK] / [KO].
# Projet XTI302-CYB, contexte C (BioLab).
# Usage : sudo ./verifier.sh     Code de sortie : 0 si tout est conforme, 1 sinon.
# Ne modifie jamais le systeme (hors fichiers temporaires supprimes a la fin).
#
# Pas de "set -e" : le role du script est justement de lancer des commandes qui
# peuvent echouer. Pas de "pipefail" : "sshd -T | grep -q" ferait echouer le test
# quand grep s'arrete tot (sshd recoit SIGPIPE). On garde -u (variable non definie
# = erreur de programmation).
set -u

REUSSIS=0
TOTAL=0

ok() { REUSSIS=$((REUSSIS + 1)); TOTAL=$((TOTAL + 1)); echo "[OK] $1 $2"; }
ko() { TOTAL=$((TOTAL + 1)); echo "[KO] $1 $2"; }

verifier_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "verifier.sh doit etre lance en root (sudo ./verifier.sh)" >&2
        exit 2
    fi
}

# Configuration SSH effectivement appliquee (fichiers inclus, premiere valeur gagnante).
SSHD_CONF=""
charger_sshd() { SSHD_CONF="$(sshd -T 2>/dev/null)"; }

# Renvoie la valeur d'un parametre de "sshd -T" (en minuscules).
sshd_valeur() { awk -v cle="$1" '$1 == cle { $1 = ""; sub(/^ /, ""); print; exit }' <<< "$SSHD_CONF"; }

# =========================== Acces SSH (S1 a S5) ===============================

test_S1() {
    if [[ "$(sshd_valeur passwordauthentication)" == "no" \
       && "$(sshd_valeur kbdinteractiveauthentication)" == "no" \
       && "$(sshd_valeur pubkeyauthentication)" == "yes" ]]; then
        ok "S1" "authentification par cle uniquement (mot de passe refuse)"
    else
        ko "S1" "l'authentification par mot de passe n'est pas desactivee"
    fi
}

test_S2() {
    if [[ "$(sshd_valeur permitrootlogin)" == "no" ]]; then
        ok "S2" "connexion root refusee"
    else
        ko "S2" "PermitRootLogin vaut '$(sshd_valeur permitrootlogin)' (attendu : no)"
    fi
}

test_S3() {
    if [[ "$(sshd_valeur allowgroups)" == "acces_ssh" ]]; then
        ok "S3" "seul le groupe acces_ssh peut se connecter"
    else
        ko "S3" "AllowGroups vaut '$(sshd_valeur allowgroups)' (attendu : acces_ssh)"
    fi
}

test_S4() {
    local essais intervalle compteur
    essais="$(sshd_valeur maxauthtries)"
    if [[ -n "$essais" && "$essais" -le 4 ]]; then
        ok "S4" "au plus 4 essais d'authentification (MaxAuthTries $essais)"
    else
        ko "S4" "MaxAuthTries vaut '$essais' (attendu : 4 au plus)"
    fi
    intervalle="$(sshd_valeur clientaliveinterval)"
    compteur="$(sshd_valeur clientalivecountmax)"
    if [[ "$(sshd_valeur channeltimeout)" == *session=* \
       && "$intervalle" -gt 0 && $((intervalle * compteur)) -le 900 ]]; then
        ok "S4" "session inactive fermee en 15 min au plus"
    else
        ko "S4" "pas de fermeture des sessions inactives en 15 min au plus"
    fi
}

test_S5() {
    local fichiers mal_proteges
    fichiers="$(find /etc/ssh/sshd_config.d -maxdepth 1 -name '*.conf' 2>/dev/null | wc -l)"
    mal_proteges="$(find /etc/ssh/sshd_config.d -maxdepth 1 -name '*.conf' \( ! -user root -o -perm /022 \) 2>/dev/null)"
    if [[ "$fichiers" -ge 1 && -z "$mal_proteges" ]] && sshd -t 2>/dev/null; then
        ok "S5" "config dans /etc/ssh/sshd_config.d/, proprietaire root, valide (sshd -t)"
    else
        ko "S5" "config absente de sshd_config.d, mal protegee ou invalide"
    fi
}

# Contexte C : un compte du groupe invite n'a que le SFTP.
test_S_invite() {
    local gid invite
    gid="$(getent group invite | cut -d: -f3)"
    invite="$(awk -F: -v g="$gid" '$4 == g { print $1; exit }' /etc/passwd)"
    if [[ -z "$invite" ]]; then
        ko "S3" "aucun compte du groupe invite trouve"
        return
    fi
    if sshd -T -C "user=$invite,host=localhost,addr=127.0.0.1" 2>/dev/null \
        | grep -qi '^forcecommand internal-sftp'; then
        ok "S3" "le compte invite $invite est limite au SFTP"
    else
        ko "S3" "le compte invite $invite n'est pas limite au SFTP"
    fi
}

# ============ A completer : C1-C4, J1-J4, B1-B4, D1-D3 (une fonction par test) ============

main() {
    verifier_root
    charger_sshd
    test_S1
    test_S2
    test_S3
    test_S4
    test_S5
    test_S_invite
    echo "--- $REUSSIS / $TOTAL tests reussis"
    [[ $REUSSIS -eq $TOTAL ]] && exit 0 || exit 1
}

main "$@"

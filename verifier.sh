#!/usr/bin/env bash
# verifier.sh - teste les exigences du projet XTI302-CYB et affiche [OK] / [KO].
# Projet XTI302-CYB, contexte C (BioLab).
# Usage : sudo ./verifier.sh     Code de sortie : 0 si tout est conforme, 1 sinon.
# Le script ne modifie pas le systeme, sauf les fichiers temporaires supprimes a la fin.
#
# Pas de set -e : le script doit continuer apres un test echoue pour tous les afficher.
# Pas de pipefail : certaines commandes en pipeline peuvent recevoir SIGPIPE.
# On garde -u pour reperer les variables non definies.
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

# Renvoie la valeur d'un parametre de sshd -T.
sshd_valeur() {
    awk -v cle="$1" '$1 == cle { $1 = ""; sub(/^ /, ""); print; exit }' <<< "$SSHD_CONF"
}

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

# ========================= Journaux et defense (J2) ==============================

test_J2() {
    local regles
    regles="$(nft list ruleset 2>/dev/null)"
    if grep -q 'hook input priority filter; policy drop;' <<< "$regles" \
       && grep -q 'tcp dport 22' <<< "$regles" \
       && grep -q 'ct state established,related accept' <<< "$regles"; then
        ok "J2" "pare-feu : entree refusee par defaut, sauf SSH et connexions etablies"
    else
        ko "J2" "politique d'entree du pare-feu differente de drop + SSH + etablies"
    fi

    if systemctl is-enabled --quiet nftables && [[ -f /etc/nftables.conf ]]; then
        ok "J2" "pare-feu charge au demarrage (service nftables actif)"
    else
        ko "J2" "le pare-feu ne survivra pas a un redemarrage (nftables non active)"
    fi
}

# ======================== Mises a jour automatiques (D1) =========================

test_D1() {
    if dpkg -s unattended-upgrades >/dev/null 2>&1 \
       && apt-config dump | grep -q 'APT::Periodic::Unattended-Upgrade "1"' \
       && systemctl is-enabled --quiet apt-daily-upgrade.timer; then
        ok "D1" "mises a jour de securite automatiques (unattended-upgrades)"
    else
        ko "D1" "unattended-upgrades absent ou non active"
    fi
}

# ===================== Disque de sauvegarde (B1, preparation) ====================

test_B1_disque() {
    local source
    source="$(findmnt -n -o SOURCE /sauvegardes 2>/dev/null)"
    if [[ -n "$source" && "$(blkid -o value -s LABEL "$source")" == "sauvegardes" ]] \
       && grep -q '/sauvegardes' /etc/fstab \
       && [[ "$(findmnt -n -o TARGET /)" != "$(findmnt -n -o TARGET /sauvegardes)" ]]; then
        ok "B1" "second disque monte sur /sauvegardes, montage permanent (fstab)"
    else
        ko "B1" "/sauvegardes n'est pas le second disque monte de facon permanente"
    fi
}

# ============ Regle commune : scripts lances en root = proprietaire root =========

test_scripts_root() {
    local mauvais
    mauvais="$(find /usr/local/sbin -maxdepth 1 -name '*.sh' \( ! -user root -o -perm /022 \) 2>/dev/null)"
    if [[ -f /usr/local/sbin/verifier.sh && -z "$mauvais" ]]; then
        ok "C3" "scripts de /usr/local/sbin : proprietaire root, modifiables par root seulement"
    else
        ko "C3" "script(s) lances en root modifiables par un autre compte : $mauvais"
    fi
}

# ===================== Membre 3 : C3, C4, J4, B4, D2, D3 =====================

# C3 - Verification des droits sudo
test_C3() {
    local ADM="/etc/sudoers.d/admins"
    local SUP="/etc/sudoers.d/support"
    local RIGHTS COUNT

    if getent group admins >/dev/null &&
       grep -Fxq '%admins ALL=(ALL:ALL) ALL' "$ADM" 2>/dev/null &&
       grep -Fxq 'support ALL=(root) NOPASSWD: /usr/local/sbin/analyse_logs.sh' "$SUP" 2>/dev/null &&
       [[ "$(stat -c '%U:%G:%a' "$ADM" 2>/dev/null)" == "root:root:440" ]] &&
       [[ "$(stat -c '%U:%G:%a' "$SUP" 2>/dev/null)" == "root:root:440" ]] &&
       visudo -c >/dev/null 2>&1; then
        ok "C3" "fichiers sudoers admins et support valides"
    else
        ko "C3" "configuration sudoers incorrecte"
        return
    fi

    RIGHTS=$(sudo -l -U support 2>/dev/null || true)
    COUNT=$(printf '%s\n' "$RIGHTS" | grep -Ec '^[[:space:]]*\(root\) NOPASSWD:' || true)
    if [[ "$COUNT" -eq 1 ]] &&
       grep -Fq '/usr/local/sbin/analyse_logs.sh' <<< "$RIGHTS"; then
        ok "C3" "support limite au script analyse_logs.sh"
    else
        ko "C3" "droits sudo de support trop larges"
    fi
}

# C4 - Protection du compte root et des dossiers personnels
test_C4() {
    local ROOT_STATUS BAD_DIRS HOME_MODE
    ROOT_STATUS=$(passwd -S root 2>/dev/null | awk '{print $2}')
    BAD_DIRS=$(find /home -mindepth 1 -maxdepth 1 -type d ! -perm 0700 -print 2>/dev/null)
    HOME_MODE=$(awk '$1 == "HOME_MODE" {print $2}' /etc/login.defs)

    if [[ "$ROOT_STATUS" == "L" || "$ROOT_STATUS" == "LK" ]]; then
        ok "C4" "compte root verrouille"
    else
        ko "C4" "compte root non verrouille"
    fi

    if [[ -z "$BAD_DIRS" && "$HOME_MODE" == "0700" ]]; then
        ok "C4" "dossiers personnels et HOME_MODE proteges"
    else
        ko "C4" "permissions des dossiers personnels ou HOME_MODE incorrectes"
    fi
}

# J4 - Analyse des journaux SSH et test du seuil
test_J4() {
    local SCRIPT="/usr/local/sbin/analyse_logs.sh"
    local CONFIG="/etc/default/analyse-logs"
    local SEUIL=5
    local TMP RC_NORMAL RC_ALERT

    if [[ ! -x "$SCRIPT" ]] || ! bash -n "$SCRIPT" 2>/dev/null; then
        ko "J4" "script analyse_logs.sh absent ou invalide"
        return
    fi

    if [[ -r "$CONFIG" ]]; then
        source "$CONFIG"
    fi
    if ! [[ "$SEUIL" =~ ^[1-9][0-9]*$ ]]; then
        ko "J4" "seuil de detection invalide"
        return
    fi

    TMP=$(mktemp -d) || {
        ko "J4" "creation du dossier temporaire impossible"
        return
    }
    mkdir -p "$TMP/normal" "$TMP/alerte"

    cat > "$TMP/normal/journalctl" <<'MOCK'
#!/bin/sh
echo "Accepted publickey for testuser from 198.51.100.10 port 55000 ssh2"
MOCK

    {
        echo '#!/bin/sh'
        echo "cat <<'LOG'"
        for ((i=1; i<=SEUIL; i++)); do
            echo "Failed password for invalid user testadmin from 192.0.2.10 port $((41000+i)) ssh2"
        done
        echo "LOG"
    } > "$TMP/alerte/journalctl"

    chmod 700 "$TMP/normal/journalctl" "$TMP/alerte/journalctl"

    if PATH="$TMP/normal:$PATH" "$SCRIPT" > "$TMP/normal.txt" 2>&1; then
        RC_NORMAL=0
    else
        RC_NORMAL=$?
    fi

    if PATH="$TMP/alerte:$PATH" "$SCRIPT" > "$TMP/alerte.txt" 2>&1; then
        RC_ALERT=0
    else
        RC_ALERT=$?
    fi

    if [[ "$RC_NORMAL" -eq 0 ]] &&
       [[ "$RC_ALERT" -eq 1 ]] &&
       grep -Fq "testadmin" "$TMP/alerte.txt" &&
       grep -Fq "192.0.2.10" "$TMP/alerte.txt" &&
       grep -Fq "ALERTE" "$TMP/alerte.txt"; then
        ok "J4" "comptes cibles, IP et code retour 1 verifies"
    else
        ko "J4" "analyse des journaux ou detection du seuil incorrecte"
    fi

    rm -rf "$TMP"
}

# B4 - Verification non destructive de la restauration et des ACL
# Le test utilise une sauvegarde reelle du dossier de test /srv/xti302-b4-*/.
# Il restaure une copie dans /tmp : aucun fichier original n'est supprime.
test_B4() {
    local BASE="/backup/versions"
    local PREUVE="/backup/logs/preuve-B4.txt"
    local TMP SNAPSHOT SOURCE DEST
    local META_SOURCE META_RESTAUREE
    local -a VERSIONS=()
    local i

    if [[ "$(findmnt -n -o TARGET /backup 2>/dev/null)" != "/backup" ]] ||
       [[ ! -d "$BASE" ]]; then
        ko "B4" "disque de sauvegarde /backup absent ou non monte"
        return
    fi

    if [[ ! -r "$PREUVE" ]] ||
       ! grep -q 'RESULTAT : SUCCES' "$PREUVE" ||
       ! grep -q 'ACL' "$PREUVE"; then
        ko "B4" "preuve de restauration ou de verification ACL absente"
        return
    fi

    if ! command -v rsync >/dev/null 2>&1 || ! command -v getfacl >/dev/null 2>&1; then
        ko "B4" "rsync ou getfacl absent"
        return
    fi

    mapfile -t VERSIONS < <(find "$BASE" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
    if [[ "${#VERSIONS[@]}" -eq 0 ]]; then
        ko "B4" "aucune version de sauvegarde disponible"
        return
    fi

    # Recherche de la derniere version contenant le fichier de test B4.
    SNAPSHOT=""
    SOURCE=""
    for ((i=${#VERSIONS[@]} - 1; i>=0; i--)); do
        local CANDIDATE="$BASE/${VERSIONS[$i]}"
        local FOUND
        FOUND=$(find "$CANDIDATE/srv" -type f -path '*/xti302-b4-*/preuve-B4.txt' -print -quit 2>/dev/null)
        if [[ -n "$FOUND" ]]; then
            SNAPSHOT="$CANDIDATE"
            SOURCE="$FOUND"
            break
        fi
    done

    if [[ -z "$SOURCE" ]]; then
        ko "B4" "fichier de test B4 absent des sauvegardes"
        return
    fi

    TMP=$(mktemp -d) || {
        ko "B4" "creation du dossier temporaire impossible"
        return
    }
    DEST="$TMP/preuve-B4-restauree.txt"

    if getfacl -cp "$SOURCE" > "$TMP/acl-source" &&
       rsync -aHAX --numeric-ids "$SOURCE" "$DEST" &&
       cmp -s "$SOURCE" "$DEST" &&
       getfacl -cp "$DEST" > "$TMP/acl-restauree"; then
        META_SOURCE=$(stat -c '%u:%g:%a' "$SOURCE")
        META_RESTAUREE=$(stat -c '%u:%g:%a' "$DEST")
        if diff -q "$TMP/acl-source" "$TMP/acl-restauree" >/dev/null &&
           [[ "$META_SOURCE" == "$META_RESTAUREE" ]]; then
            ok "B4" "copie restauree depuis une sauvegarde, contenu et ACL verifies"
        else
            ko "B4" "permissions ou ACL differentes apres restauration"
        fi
    else
        ko "B4" "restauration depuis la sauvegarde impossible"
    fi

    rm -rf "$TMP"
}

# D2 - Verification des ports en ecoute
test_D2() {
    local LISTEN
    LISTEN=$(ss -H -lntup 2>/dev/null)
    if [[ -z "$LISTEN" ]]; then
        ko "D2" "aucun service en ecoute detecte"
        return
    fi

    if printf '%s\n' "$LISTEN" | awk '
    {
        addr=$5
        sub(/^.*:/, "", addr)
        if (addr != "22") {
            bad=1
        }
        count++
    }
    END {
        exit !(count > 0 && bad == 0)
    }'; then
        ok "D2" "seul le port SSH 22 est en ecoute"
    else
        ko "D2" "un autre port est en ecoute ou SSH est absent"
    fi
}

# D3 - Audit des permissions et des fichiers SUID
test_D3() {
    local WORLD_WRITABLE SUID_FILES SUID_COUNT

    WORLD_WRITABLE=$(find / \
        \( -path /proc -o -path /sys -o -path /dev -o \
           -path /run -o -path /tmp -o -path /var/tmp \) -prune -o \
        \( -type f -o -type d \) -perm -0002 -print 2>/dev/null)

    SUID_FILES=$(find / -xdev -type f -perm -4000 -print 2>/dev/null)
    SUID_COUNT=$(printf '%s\n' "$SUID_FILES" | grep -c . || true)

    if [[ -z "$WORLD_WRITABLE" ]]; then
        ok "D3" "aucun fichier dangereux accessible en ecriture par tous"
    else
        ko "D3" "fichiers accessibles en ecriture par tous detectes"
    fi

    if [[ "$SUID_COUNT" -gt 0 ]]; then
        ok "D3" "$SUID_COUNT fichiers SUID recenses"
    else
        ko "D3" "aucun fichier SUID recense"
    fi
}

# ================================ Bilan ==========================================

main() {
    verifier_root
    charger_sshd
    test_S1
    test_S2
    test_S3
    test_S4
    test_S5
    test_S_invite
    test_J2
    test_D1
    test_B1_disque
    test_scripts_root
    test_C3
    test_C4
    test_J4
    test_B4
    test_D2
    test_D3
    echo "--- $REUSSIS / $TOTAL tests reussis"
    [[ $REUSSIS -eq $TOTAL ]] && exit 0 || exit 1
}

main "$@"

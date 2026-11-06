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
CSV=""
for candidat in "$(dirname "$(readlink -f "$0")")/comptes.csv" ./comptes.csv /usr/local/share/xti302/comptes.csv; do
    [[ -r "$candidat" ]] && { CSV="$candidat"; break; }
done


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

# ============================ Sauvegarde (B1, B2, B3) : Adrien ============================

# Versions terminees de /sauvegardes, de la plus ancienne a la plus recente.
versions_sauvegarde() {
    find /sauvegardes -mindepth 1 -maxdepth 1 -type d \
        -name '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]' 2>/dev/null | sort
}

test_B1() {
    local erreurs="" versions derniere avant nb liens
    if [[ ! -x /usr/local/sbin/sauvegarde.sh ]] \
       || [[ -n "$(find /usr/local/sbin/sauvegarde.sh \( ! -user root -o -perm /022 \) 2>/dev/null)" ]]; then
        erreurs+=" sauvegarde.sh absent de /usr/local/sbin ou modifiable par un autre compte"
    fi
    mapfile -t versions < <(versions_sauvegarde)
    nb=${#versions[@]}
    if [[ $nb -lt 1 ]]; then
        erreurs+=" aucune version dans /sauvegardes"
    else
        derniere="${versions[$((nb - 1))]}"
        [[ -d "$derniere/srv" && -d "$derniere/etc" ]] || erreurs+=" la derniere version ne contient pas srv et etc"
        # ACL conservees : meme ACL sur /srv/analyses dans la source et dans la sauvegarde
        if [[ "$(getfacl -cp /srv/analyses 2>/dev/null)" != "$(getfacl -cp "$derniere/srv/analyses" 2>/dev/null)" ]]; then
            erreurs+=" ACL de /srv/analyses non conservees"
        fi
        # incremental : un fichier inchange est un lien dur entre deux versions
        if [[ $nb -ge 2 ]]; then
            avant="${versions[$((nb - 2))]}"
            liens="$(stat -c %h "$derniere/etc/debian_version" 2>/dev/null)"
            [[ "${liens:-1}" -ge 2 && "$(stat -c %i "$derniere/etc/debian_version" 2>/dev/null)" == "$(stat -c %i "$avant/etc/debian_version" 2>/dev/null)" ]] \
                || erreurs+=" sauvegarde non incrementale (fichier inchange recopie)"
        fi
    fi
    if [[ -z "$erreurs" ]]; then
        ok "B1" "sauvegarde de /srv et /etc : $nb version(s), ACL conservees, fichiers inchanges en liens durs"
    else
        ko "B1" "ecarts :$erreurs"
    fi
}

test_B2() {
    if systemctl is-enabled --quiet sauvegarde.timer \
       && systemctl is-active --quiet sauvegarde.timer \
       && [[ -n "$(journalctl -u sauvegarde.service --no-pager -q -n 1 2>/dev/null)" ]]; then
        ok "B2" "sauvegarde planifiee (sauvegarde.timer) et executions journalisees"
    else
        ko "B2" "timer inactif ou aucune execution dans le journal de sauvegarde.service"
    fi
}

test_B3() {
    local admin
    admin="$(getent group admins | cut -d: -f4 | cut -d, -f1)"
    if [[ "$(stat -c '%U:%G %a' /sauvegardes 2>/dev/null)" == "root:admins 750" ]] \
       && ! sudo -u mdubois test -r /sauvegardes 2>/dev/null \
       && sudo -u "$admin" test -r /sauvegardes 2>/dev/null; then
        ok "B3" "/sauvegardes accessible aux administrateurs seulement"
    else
        ko "B3" "/sauvegardes n'est pas en root:admins 750 ou est lisible par un non-administrateur"
    fi
}

# ================= Comptes et droits (C1, C2) : Adrien =================

# C1 : chaque compte de comptes.csv existe avec le bon groupe principal et les bons groupes secondaires.
test_C1() {
    local login _nom gp gs g erreurs=""
    if [[ -z "$CSV" ]]; then
        ko "C1" "comptes.csv introuvable (lancer verifier.sh depuis la racine du depot)"
        return
    fi
    while IFS=";" read -r login _nom gp gs; do
        [[ -n "$login" ]] || continue
        if ! id "$login" >/dev/null 2>&1; then
            erreurs+=" $login(absent)"
            continue
        fi
        [[ "$(id -gn "$login")" == "$gp" ]] || erreurs+=" $login(groupe principal != $gp)"
        for g in ${gs//,/ }; do
            id -nG "$login" | tr ' ' '\n' | grep -qx "$g" || erreurs+=" $login(pas dans $g)"
        done
    done < <(tail -n +2 "$CSV" | tr -d '\r')

    if [[ -z "$erreurs" ]]; then
        ok "C1" "tous les comptes de comptes.csv existent avec les bons groupes"
    else
        ko "C1" "ecarts :$erreurs"
    fi
}

# C2 : droits sur /srv (ce qui doit marcher ET ce qui doit etre refuse) + ACL par defaut.
test_C2() {
    local erreurs="" ligne user droit chemin attendu reel f
    local regles=(
        "mdubois:r:/srv/donnees_brutes:oui"
        "mdubois:w:/srv/donnees_brutes:oui"
        "ncarpentier:r:/srv/donnees_brutes:oui"
        "ncarpentier:w:/srv/donnees_brutes:non"
        "ymoreau:r:/srv/donnees_brutes:oui"
        "ymoreau:w:/srv/donnees_brutes:non"
        "invite1:r:/srv/donnees_brutes:non"
        "ncarpentier:w:/srv/analyses:oui"
        "ymoreau:w:/srv/analyses:oui"
        "mdubois:r:/srv/analyses:non"
        "invite1:r:/srv/analyses:non"
        "ncarpentier:w:/srv/publications:oui"
        "ymoreau:r:/srv/publications:oui"
        "ymoreau:w:/srv/publications:non"
        "invite1:r:/srv/publications:oui"
        "invite1:w:/srv/publications:non"
        "mdubois:r:/srv/publications:non"
    )

    for ligne in "${regles[@]}"; do
        IFS=: read -r user droit chemin attendu <<< "$ligne"
        if sudo -u "$user" test "-$droit" "$chemin" 2>/dev/null; then reel="oui"; else reel="non"; fi
        [[ "$reel" == "$attendu" ]] || erreurs+=" $user -$droit $chemin (attendu: $attendu)"
    done

    # ACL par defaut : un fichier cree plus tard doit heriter des droits du dossier.
    f="/srv/donnees_brutes/.test_c2_verifier"
    if sudo -u mdubois touch "$f" 2>/dev/null; then
        sudo -u ncarpentier test -r "$f" 2>/dev/null || erreurs+=" ACL par defaut : un chercheur ne lit pas un nouveau fichier"
        sudo -u ncarpentier test -w "$f" 2>/dev/null && erreurs+=" ACL par defaut : un chercheur ecrit dans un fichier de technique"
        rm -f "$f"
    else
        erreurs+=" technique ne peut pas creer de fichier dans donnees_brutes"
    fi

    if [[ -z "$erreurs" ]]; then
        ok "C2" "droits /srv conformes (autorises et refuses) et ACL par defaut actives"
    else
        ko "C2" "ecarts :$erreurs"
    fi
}


# ======================= Journaux et defense (J1, J3) : Adrien =======================

# J1 : fail2ban actif, jail sshd en marche et parametree, regles presentes dans nftables.
test_J1() {
    local maxretry bantime
    maxretry="$(fail2ban-client get sshd maxretry 2>/dev/null)"
    bantime="$(fail2ban-client get sshd bantime 2>/dev/null)"
    if systemctl is-active --quiet fail2ban \
       && systemctl is-enabled --quiet fail2ban \
       && fail2ban-client status sshd >/dev/null 2>&1 \
       && [[ "$maxretry" =~ ^[0-9]+$ && "$maxretry" -ge 1 && "$maxretry" -le 5 ]] \
       && [[ "$bantime" =~ ^[0-9]+$ && "$bantime" -ge 600 ]]; then
        ok "J1" "fail2ban protege SSH (jail sshd : $maxretry echecs, bannissement ${bantime}s)"
    else
        ko "J1" "fail2ban inactif, jail sshd absente ou mal parametree (maxretry='$maxretry' bantime='$bantime')"
    fi
    if nft list ruleset 2>/dev/null | grep -q 'f2b-table'; then
        ok "J1" "les regles de bannissement de fail2ban sont presentes dans nftables"
    else
        ko "J1" "la table nftables de fail2ban est absente (bannissement inefficace)"
    fi
}

# J3 : le journal systemd est conserve apres un redemarrage.
test_J3() {
    if grep -rqsE '^[[:space:]]*Storage=persistent' /etc/systemd/journald.conf /etc/systemd/journald.conf.d \
       && [[ -d /var/log/journal ]] \
       && find /var/log/journal -name '*.journal' 2>/dev/null | grep -q .; then
        ok "J3" "journal persistant (Storage=persistent, fichiers dans /var/log/journal)"
    else
        ko "J3" "le journal n'est pas persistant (il sera perdu au redemarrage)"
    fi
}

# ===================== El Yazid : C3, C4, J4, B4, D2, D3 =====================

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

# B4 - Restauration (non destructive) depuis la derniere sauvegarde : contenu et ACL.
# On restaure /srv/analyses de la derniere version dans un dossier temporaire,
# puis on compare le contenu avec la sauvegarde et les ACL avec l'original.
test_B4() {
    local versions derniere tmp
    mapfile -t versions < <(versions_sauvegarde)
    if [[ ${#versions[@]} -eq 0 ]]; then
        ko "B4" "aucune version dans /sauvegardes, restauration impossible"
        return
    fi
    derniere="${versions[-1]}"
    if [[ ! -d "$derniere/srv/analyses" ]]; then
        ko "B4" "/srv/analyses absent de la derniere version ($(basename "$derniere"))"
        return
    fi
    tmp="$(mktemp -d)" || { ko "B4" "creation du dossier temporaire impossible"; return; }
    if rsync -aAXH --numeric-ids "$derniere/srv/analyses/" "$tmp/analyses/" \
       && diff -r "$derniere/srv/analyses" "$tmp/analyses" >/dev/null \
       && [[ "$(getfacl -cp /srv/analyses 2>/dev/null)" == "$(getfacl -cp "$tmp/analyses" 2>/dev/null)" ]]; then
        ok "B4" "restauration de /srv/analyses depuis $(basename "$derniere") : contenu et ACL identiques"
    else
        ko "B4" "restauration echouee ou ACL differentes apres restauration"
    fi
    rm -rf "$tmp"
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
    test_C1
    test_C2
    test_C3
    test_scripts_root
    test_C4
    test_S1
    test_S2
    test_S3
    test_S4
    test_S5
    test_S_invite
    test_J1
    test_J2
    test_J3
    test_J4
    test_B1_disque
    test_B1
    test_B2
    test_B3
    test_B4
    test_D1
    test_D2
    test_D3
    echo "--- $REUSSIS / $TOTAL tests reussis"
    [[ $REUSSIS -eq $TOTAL ]] && exit 0 || exit 1
}

main "$@"

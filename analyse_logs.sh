#!/bin/bash
set -Eeuo pipefail

CONFIG="/etc/default/analyse-logs"
TMP=$(mktemp)
EVENTS=$(mktemp)

trap 'rm -f "$TMP" "$EVENTS"' EXIT

SEUIL=5
PERIODE="24 hours ago"

if [[ -r "$CONFIG" ]]; then
    source "$CONFIG"
fi

if ! [[ "$SEUIL" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERREUR : seuil invalide." >&2
    exit 2
fi

if [[ "$EUID" -ne 0 ]]; then
    echo "ERREUR : ce script doit être exécuté avec sudo." >&2
    exit 2
fi

if ! journalctl -u ssh.service --since "$PERIODE" \
    --no-pager -o cat > "$TMP"; then
    echo "ERREUR : impossible de lire les journaux SSH." >&2
    exit 2
fi

# Extraction des adresses IP et des comptes ciblés.
awk '
{
    ip = ""
    user = ""

    for (i = 1; i <= NF; i++) {

        if ($i == "Failed" &&
            ($(i+1) == "password" ||
             $(i+1) == "publickey" ||
             $(i+1) == "keyboard-interactive/pam")) {

            j = i + 3

            if ($(j) == "invalid" && $(j+1) == "user")
                j += 2

            user = $(j)

            if ($(j+1) == "from")
                ip = $(j+2)

            break
        }

        if ($i == "maximum" &&
            $(i+1) == "authentication" &&
            $(i+2) == "attempts") {

            for (j = i+1; j <= NF; j++) {
                if ($j == "for") {
                    k = j+1

                    if ($(k) == "invalid" && $(k+1) == "user")
                        k += 2

                    user = $(k)

                    if ($(k+1) == "from")
                        ip = $(k+2)

                    break
                }
            }
            break
        }
    }

    if (ip != "" && user != "")
        print ip "\t" user
}
' "$TMP" | sort > "$EVENTS"

echo "===== ANALYSE DES JOURNAUX SSH ====="
echo "Période : $PERIODE"
echo "Seuil : $SEUIL tentatives par IP"
echo

TOTAL=$(wc -l < "$EVENTS")

echo "===== TENTATIVES ECHOUEES ====="

ALERTE=0

if [[ "$TOTAL" -eq 0 ]]; then
    echo "Aucune tentative échouée détectée."
else
    awk -F '\t' '{count[$1]++}
    END {
        for (ip in count)
            print count[ip], ip
    }' "$EVENTS" | sort -rn |
    while read -r NOMBRE IP; do
        echo "$IP : $NOMBRE tentative(s)"
    done

    while read -r NOMBRE IP; do
        if (( NOMBRE >= SEUIL )); then
            ALERTE=1
            echo "ALERTE : seuil atteint pour $IP ($NOMBRE tentatives)"
        fi
    done < <(
        awk -F '\t' '{count[$1]++}
        END {
            for (ip in count)
                print count[ip], ip
        }' "$EVENTS"
    )
fi

echo
echo "===== COMPTES CIBLES ====="

if [[ "$TOTAL" -gt 0 ]]; then
    awk -F '\t' '{count[$2]++}
    END {
        for (user in count)
            print user, count[user]
    }' "$EVENTS" | sort
else
    echo "Aucun compte ciblé détecté."
fi

echo
echo "===== CONNEXIONS REUSSIES ====="

SUCCES=$(awk '/Accepted (publickey|password)/ {n++}
END {print n+0}' "$TMP")

echo "$SUCCES connexion(s) réussie(s)"

echo
echo "===== BILAN ====="

if (( ALERTE == 1 )); then
    echo "Résultat : ALERTE"
    exit 1
else
    echo "Résultat : AUCUN SEUIL ATTEINT"
    exit 0
fi

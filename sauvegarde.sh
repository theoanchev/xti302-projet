#!/usr/bin/env bash
# sauvegarde.sh - exigence B1 : sauvegarde incrementale de /srv et /etc sur le second disque.
# Chaque execution cree une version datee : /sauvegardes/AAAA-MM-JJ_HHMMSS.
# Les fichiers inchanges ne sont pas recopies : rsync --link-dest cree un lien dur vers
# la version precedente (aucun octet de plus sur le disque).
# Droits, ACL et attributs etendus sont conserves (-A -X).
# On garde au moins les 7 dernieres versions ; les plus anciennes sont supprimees.
# Lance par sauvegarde.timer (B2). Sortie dans le journal : journalctl -u sauvegarde.service
# Usage : sudo sauvegarde.sh
set -euo pipefail

readonly DEST="/sauvegardes"
readonly SOURCES=(/srv /etc)
readonly GARDER=7

log()    { echo "[sauvegarde] $*"; }
erreur() { echo "[sauvegarde] ERREUR : $*" >&2; exit 1; }

# --- Verifications de depart ----------------------------------------------------
verifier_prerequis() {
    [[ $EUID -eq 0 ]] || erreur "ce script doit etre lance en root (sudo)"
    command -v rsync >/dev/null || erreur "rsync n'est pas installe"
    # Sans ce controle, une sauvegarde lancee disque absent s'ecrirait sur le disque systeme.
    mountpoint -q "$DEST" || erreur "$DEST n'est pas un point de montage (second disque absent ?)"
}

# Versions terminees, de la plus ancienne a la plus recente (le nom contient la date).
lister_versions() {
    find "$DEST" -mindepth 1 -maxdepth 1 -type d \
        -name '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]' | sort
}

# --- Rotation : on garde les GARDER dernieres versions -------------------------------
supprimer_anciennes() {
    local versions v nb
    mapfile -t versions < <(lister_versions)
    nb=${#versions[@]}
    if (( nb > GARDER )); then
        for v in "${versions[@]:0:nb-GARDER}"; do
            rm -rf -- "$v"
            log "version supprimee : $(basename "$v")"
        done
        nb=$GARDER
    fi
    log "$nb version(s) conservee(s)"
}

main() {
    local versions derniere nouvelle tmp rc=0
    local options=(-aAXH --numeric-ids --relative)

    verifier_prerequis

    # Une seule sauvegarde a la fois.
    exec 9>/run/sauvegarde.lock
    flock -n 9 || erreur "une sauvegarde est deja en cours"

    # Restes d'une sauvegarde interrompue : jamais utilises comme reference.
    find "$DEST" -mindepth 1 -maxdepth 1 -type d -name '*.en_cours' -exec rm -rf {} +

    mapfile -t versions < <(lister_versions)
    derniere=""
    if (( ${#versions[@]} > 0 )); then
        derniere="${versions[-1]}"
        options+=(--link-dest="$derniere")
    fi

    nouvelle="$DEST/$(date +%F_%H%M%S)"
    tmp="$nouvelle.en_cours"
    install -d -m 0750 "$tmp"                      # B3 : acces restreint
    if getent group admins >/dev/null; then chgrp admins "$tmp"; fi

    log "debut : ${SOURCES[*]} -> $(basename "$nouvelle") (reference : $(basename "${derniere:-aucune}"))"
    rsync "${options[@]}" "${SOURCES[@]}" "$tmp/" || rc=$?
    # Code 24 = fichiers disparus pendant la copie (fichiers temporaires) : sans gravite.
    if (( rc != 0 && rc != 24 )); then
        rm -rf "$tmp"
        erreur "rsync a echoue (code $rc), version abandonnee"
    fi
    mv "$tmp" "$nouvelle"                          # la version n'existe qu'une fois complete
    log "version creee : $(basename "$nouvelle")"

    supprimer_anciennes
    log "terminee"
}

main "$@"

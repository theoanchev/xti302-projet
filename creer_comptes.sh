#!/usr/bin/env bash
# creer_comptes.sh - exigences C1 (comptes et groupes) et C2 (/srv et ACL)
# Contexte C : laboratoire BioLab
# Usage : sudo ./creer_comptes.sh [fichier.csv]
# Idempotent : on peut le relancer sans doublons ni erreurs.
set -euo pipefail

RACINE="$(dirname "$(readlink -f "$0")")"
CSV="${1:-$RACINE/comptes.csv}"
CLES="$RACINE/config/cles"

info()   { echo "[creer_comptes] $*"; }
erreur() { echo "[creer_comptes] ERREUR : $*" >&2; exit 1; }

# --- Vérifications de départ -------------------------------------------------
verifier_prerequis() {
  [[ $EUID -eq 0 ]] || erreur "ce script doit être lancé en root (sudo)"
  [[ -r "$CSV" ]] || erreur "fichier introuvable : $CSV"
  command -v setfacl >/dev/null || erreur "paquet acl manquant (apt install acl)"
  local entete
  # tr retire les \r (fichier créé sous Windows), sed retire un éventuel BOM UTF-8
  entete="$(head -n 1 "$CSV" | tr -d '\r' | sed '1s/^\xEF\xBB\xBF//')"
  [[ "$entete" == "login;nom;groupe_principal;groupes_secondaires" ]] \
    || erreur "en-tête invalide dans $CSV"
}

# --- C1 : groupes et comptes -------------------------------------------------
creer_groupe() {
  getent group "$1" >/dev/null || { groupadd "$1"; info "groupe créé : $1"; }
}

# vrai si le compte est membre de invite (groupe principal ou secondaire)
est_membre_invite() {
  [[ "$1" == "invite" || ",$2," == *",invite,"* ]]
}

installer_cle() {
  local login="$1" gp="$2" home="$3" cle="$CLES/$1.pub"
  if [[ ! -f "$cle" ]]; then
    info "pas de clé publique pour $login ($cle)"
    return 0
  fi
  install -d -m 700 -o "$login" -g "$gp" "$home/.ssh"
  install -m 600 -o "$login" -g "$gp" "$cle" "$home/.ssh/authorized_keys"
}

creer_utilisateur() {
  local login="$1" nom="$2" gp="$3" gs="$4" shell="/bin/bash" g home

  # particularité du contexte C : pas de shell interactif pour invite
  if est_membre_invite "$gp" "$gs"; then shell="/usr/sbin/nologin"; fi

  creer_groupe "$gp"
  for g in ${gs//,/ }; do creer_groupe "$g"; done

  if id "$login" &>/dev/null; then
    usermod -c "$nom" -g "$gp" -s "$shell" "$login"
    # -a : on AJOUTE aux groupes (on ne retire rien, ex. le groupe sudo d'un compte existant)
    [[ -z "$gs" ]] || usermod -a -G "$gs" "$login"
  else
    useradd -m -c "$nom" -g "$gp" -s "$shell" ${gs:+-G "$gs"} "$login"
    info "compte créé : $login"
  fi

  home="$(getent passwd "$login" | cut -d: -f6)"
  chmod 700 "$home"                      # home illisible par les autres (C4)
  installer_cle "$login" "$gp" "$home"
}

traiter_csv() {
  local login nom gp gs
  while IFS=';' read -r login nom gp gs; do
    [[ -n "$login" ]] || continue
    creer_utilisateur "$login" "$nom" "$gp" "$gs"
  done < <(tail -n +2 "$CSV" | tr -d '\r')
}

# --- C2 : répertoires de /srv et ACL ----------------------------------------
# Usage : preparer_repertoire <dossier> groupe:rw groupe:r ...
preparer_repertoire() {
  local dir="$1"; shift
  local entree groupe droits acces defaut

  mkdir -p "$dir"
  chown root:root "$dir"
  chmod 700 "$dir"            # "autres" = aucun droit ; les ACL ajoutent les droits voulus
  setfacl -R -b "$dir"        # repart d'une ACL vierge (idempotence)

  for entree in "$@"; do
    groupe="${entree%%:*}"
    droits="${entree##*:}"
    case "$droits" in
      rw) acces="rwX"; defaut="rwx" ;;
      r)  acces="r-X"; defaut="r-x" ;;
      *)  erreur "droits inconnus : $droits" ;;
    esac
    creer_groupe "$groupe"
    setfacl -R -m "g:$groupe:$acces" "$dir"       # droits sur l'existant
    setfacl -R -d -m "g:$groupe:$defaut" "$dir"   # ACL par défaut : fichiers futurs
  done
  setfacl -R -d -m "o::---" "$dir"                # les autres n'ont rien, même plus tard
  info "répertoire prêt : $dir"
}

main() {
  verifier_prerequis
  info "lecture de $CSV"
  traiter_csv
  preparer_repertoire /srv/donnees_brutes technique:rw chercheurs:r doctorants:r
  preparer_repertoire /srv/analyses       chercheurs:rw doctorants:rw
  preparer_repertoire /srv/publications   chercheurs:rw doctorants:r invite:r
  info "terminé"
}

main "$@"

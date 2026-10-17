#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <nom-du-bot>" >&2
  echo "Exemple: $0 claude-opus-5.5" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

bot_name=$1
if [[ ! $bot_name =~ ^[a-z0-9]+([.-][a-z0-9]+)*$ ]]; then
  echo "Nom invalide: utilise des minuscules, chiffres, points et tirets (ex. claude-opus-5.5)." >&2
  exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "La commande 'gh' est requise pour cloner axo-clash/template-rust." >&2
  exit 1
fi

clone_dir=template-rust
if [[ -e $clone_dir ]]; then
  echo "Le chemin '$clone_dir' existe déjà dans $(pwd). Supprime-le ou renomme-le avant de relancer le script." >&2
  exit 1
fi

if [[ -e bot-competitif.md || -L bot-competitif.md ]]; then
  echo "Le fichier 'bot-competitif.md' existe déjà dans $(pwd); il ne sera pas écrasé." >&2
  exit 1
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
prompt_source="$script_dir/../docs/prompts/bot-competitif.md"
if [[ ! -f $prompt_source ]]; then
  echo "Prompt introuvable: $prompt_source" >&2
  exit 1
fi

gh repo clone axo-clash/template-rust "$clone_dir"

# Vérifie tous les conflits avant de déplacer quoi que ce soit.
shopt -s dotglob nullglob
for source in "$clone_dir"/*; do
  [[ ${source##*/} == .git ]] && continue
  destination="./${source##*/}"
  if [[ -e $destination || -L $destination ]]; then
    echo "Le fichier ou dossier '$destination' existe déjà; aucun fichier du template n'a été déplacé." >&2
    echo "Le clone reste disponible dans '$clone_dir'." >&2
    exit 1
  fi
done

for source in "$clone_dir"/*; do
  [[ ${source##*/} == .git ]] && continue
  mv -- "$source" .
done

# Le .git du dépôt cloné ne doit pas devenir celui du dossier du bot.
rm -rf -- "$clone_dir"

# Personnalise l'introduction et les exemples d'identité, en conservant la
# variable shell NOM_BOT des commandes de publication.
sed \
  -e "s/Remplace \`NOM_BOT\` par le nom enregistré dans l’interface/Utilise le nom \`$bot_name\` enregistré dans l’interface/" \
  -e "s/\"NOM_BOT\"/\"$bot_name\"/g" \
  -e "s/\`NOM_BOT\`\./\`$bot_name\`./g" \
  "$prompt_source" > bot-competitif.md

echo "Template Rust et prompt installés dans $(pwd)."
echo "Nom du bot configuré: $bot_name"

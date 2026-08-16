#!/usr/bin/env bash
# Instala as skills de code review .NET para o Claude Code.
#
# Por padrao cria symlinks de ~/.claude/skills para este clone, de forma que
# "git pull" atualize as skills sem reinstalar.
#
# Uso:
#   ./install.sh                      # symlink no perfil do usuario
#   ./install.sh --copy               # copias independentes
#   ./install.sh --project /caminho   # instala em <projeto>/.claude/skills
#   ./install.sh --force              # substitui sem perguntar

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS=(designpatterns designpatterns-legacy)
MODE=symlink
PROJECT=""
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --copy)    MODE=copy; shift ;;
    --force)   FORCE=1; shift ;;
    --project) PROJECT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "opcao desconhecida: $1" >&2; exit 1 ;;
  esac
done

for s in "${SKILLS[@]}"; do
  if [[ ! -f "$REPO_ROOT/$s/SKILL.md" ]]; then
    echo "Nao encontrei $s/SKILL.md em $REPO_ROOT. Rode de dentro do clone." >&2
    exit 1
  fi
done

if [[ -n "$PROJECT" ]]; then
  [[ -d "$PROJECT" ]] || { echo "Caminho do projeto nao existe: $PROJECT" >&2; exit 1; }
  TARGET="$(cd "$PROJECT" && pwd)/.claude/skills"
  SCOPE="projeto em $PROJECT"
else
  TARGET="$HOME/.claude/skills"
  SCOPE="perfil do usuario"
fi

mkdir -p "$TARGET"

echo ""
echo "Instalando em: $TARGET"
echo "Escopo       : $SCOPE"
echo "Modo         : $MODE"
echo ""

for s in "${SKILLS[@]}"; do
  src="$REPO_ROOT/$s"
  dst="$TARGET/$s"

  if [[ -e "$dst" || -L "$dst" ]]; then
    if [[ -L "$dst" ]]; then kind="link para $(readlink "$dst")"; else kind="pasta"; fi
    if [[ $FORCE -eq 0 ]]; then
      read -r -p "  '$s' ja existe ($kind). Substituir? [s/N] " answer
      case "$answer" in
        [sSyY]*) ;;
        *) echo "  $s : mantido como estava"; continue ;;
      esac
    fi
    rm -rf "$dst"
  fi

  if [[ "$MODE" == symlink ]]; then
    ln -s "$src" "$dst"
    echo "  $s : symlink -> $src"
  else
    cp -R "$src" "$dst"
    echo "  $s : copiado"
  fi
done

echo ""
echo "Pronto. Abra o Claude Code e peca um review, ou use /designpatterns."
[[ "$MODE" == symlink ]] && echo "Como foi por symlink, 'git pull' neste clone atualiza as skills."
echo ""

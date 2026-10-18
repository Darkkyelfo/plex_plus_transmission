#!/usr/bin/env bash
set -Eeuo pipefail

# Execute como usuario comum com sudo: bash setup.sh
# Variaveis opcionais: DATA_ROOT, STACK_ROOT, TZ, ADMIN_USER, SKIP_UPGRADE=1
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DATA_ROOT="${DATA_ROOT:-/data}"
STACK_ROOT="${STACK_ROOT:-${DATA_ROOT}/docker/stacks}"
TZ="${TZ:-America/Recife}"
ADMIN_USER="${ADMIN_USER:-${SUDO_USER:-$(id -un)}}"

log() { printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"; }
fail() { printf '\n[ERRO] %s\n' "$*" >&2; exit 1; }
trap 'printf "\n[ERRO] Falha na linha %s. Confira a mensagem acima.\n" "$LINENO" >&2' ERR

[[ "$(id -u)" -eq 0 ]] || exec sudo --preserve-env=DATA_ROOT,STACK_ROOT,TZ,ADMIN_USER,SKIP_UPGRADE bash "$0" "$@"
[[ -f /etc/os-release ]] || fail 'Nao foi possivel identificar o sistema.'
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == ubuntu ]] || fail 'Este script suporta Ubuntu Server.'
[[ "$DATA_ROOT" == /* && "$STACK_ROOT" == /* ]] || fail 'DATA_ROOT e STACK_ROOT precisam ser caminhos absolutos.'
[[ "$DATA_ROOT" != / ]] || fail 'DATA_ROOT nao pode ser /.'
id "$ADMIN_USER" >/dev/null 2>&1 || fail "Usuario inexistente: $ADMIN_USER"
ADMIN_UID="$(id -u "$ADMIN_USER")"
ADMIN_GID="$(id -g "$ADMIN_USER")"
[[ "$ADMIN_UID" -ne 0 ]] || fail 'Execute como usuario comum com sudo (nao como root direto).'

log "Usuario: $ADMIN_USER ($ADMIN_UID:$ADMIN_GID) | Dados: $DATA_ROOT | Timezone: $TZ"
if ! mountpoint -q "$DATA_ROOT"; then
  log "AVISO: $DATA_ROOT nao e um ponto de montagem independente. Confira se os dados estao no disco desejado antes de prosseguir."
fi

log 'Atualizando indices e pacotes do Ubuntu...'
export DEBIAN_FRONTEND=noninteractive
apt-get update
if [[ "${SKIP_UPGRADE:-0}" != 1 ]]; then
  apt-get upgrade -y
fi
apt-get install -y ca-certificates curl gnupg openssh-server net-tools nano

log 'Habilitando servidor SSH...'
systemctl unmask ssh.service >/dev/null 2>&1 || true
systemctl enable --now ssh.service
systemctl is-active --quiet ssh.service || fail 'Servico SSH nao iniciou.'
# Nao alteramos sshd_config nem ativamos o firewall.
# Se UFW ja estiver ativo, liberamos a porta SSH antes de qualquer outra mudanca.
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  log 'UFW ativo: permitindo conexoes SSH...'
  ufw allow OpenSSH
fi

log 'Instalando Docker pelo repositorio oficial (se necessario)...'
install -m 0755 -d /etc/apt/keyrings
if [[ ! -s /etc/apt/keyrings/docker.asc ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
fi
ARCH="$(dpkg --print-architecture)"
CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
[[ -n "$CODENAME" ]] || fail 'Nao foi possivel identificar a versao do Ubuntu.'
printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/docker.asc\n' "$CODENAME" "$ARCH" > /etc/apt/sources.list.d/docker.sources
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

groupadd -f docker
usermod -aG docker "$ADMIN_USER"

log 'Criando estrutura persistente...'
install -d -m 0755 "$DATA_ROOT" "$DATA_ROOT/docker" "$DATA_ROOT/media"
for dir in \
  "$DATA_ROOT/docker/plex/config" \
  "$DATA_ROOT/docker/transmission/config" \
  "$DATA_ROOT/media/downloads" \
  "$DATA_ROOT/media/downloads/incomplete" \
  "$STACK_ROOT/plex" \
  "$STACK_ROOT/transmission"; do
  install -d -m 0750 "$dir"
done
# Nao alteramos recursivamente dados existentes, apenas a propriedade das pastas gerenciadas.
for dir in \
  "$DATA_ROOT/docker/plex/config" \
  "$DATA_ROOT/docker/transmission/config" \
  "$DATA_ROOT/media/downloads" \
  "$DATA_ROOT/media/downloads/incomplete" \
  "$STACK_ROOT" "$STACK_ROOT/plex" "$STACK_ROOT/transmission"; do
  chown "$ADMIN_UID:$ADMIN_GID" "$dir"
done
chmod 0750 "$DATA_ROOT/docker/plex/config" "$DATA_ROOT/docker/transmission/config" "$DATA_ROOT/media/downloads" "$DATA_ROOT/media/downloads/incomplete"

log 'Instalando arquivos Compose...'
install -m 0644 "$SCRIPT_DIR/plex/compose.yaml" "$STACK_ROOT/plex/compose.yaml"
install -m 0644 "$SCRIPT_DIR/transmission/compose.yaml" "$STACK_ROOT/transmission/compose.yaml"

# Solicita a senha somente na primeira instalacao; nunca a exibe no terminal.
ENV_FILE="$STACK_ROOT/.env"
if [[ ! -e "$ENV_FILE" ]]; then
  [[ -t 0 ]] || fail 'Primeira instalacao requer terminal interativo para informar a senha do Transmission.'
  printf '\nInforme a senha para o usuario transmission.\n'
  printf 'Use 8 a 128 caracteres: letras, numeros ou _ . @ - (sem espacos).\n'
  while true; do
    IFS= read -r -s -p 'Senha do Transmission: ' PASS
    printf '\n'
    if [[ ${#PASS} -lt 8 || ${#PASS} -gt 128 || ! "$PASS" =~ ^[a-zA-Z0-9_.@-]+$ ]]; then
      printf 'Senha invalida. Tente novamente.\n' >&2
      continue
    fi
    IFS= read -r -s -p 'Confirme a senha: ' PASS_CONFIRM
    printf '\n'
    if [[ "$PASS" != "$PASS_CONFIRM" ]]; then
      printf 'As senhas nao coincidem. Tente novamente.\n' >&2
      continue
    fi
    break
  done
  umask 077
  cat > "$ENV_FILE" <<ENVVARS
PUID=$ADMIN_UID
PGID=$ADMIN_GID
TZ=$TZ
DATA_ROOT=$DATA_ROOT
TRANSMISSION_USER=transmission
TRANSMISSION_PASS=$PASS
ENVVARS
  unset PASS PASS_CONFIRM
  chmod 0600 "$ENV_FILE"
else
  log "Preservando credenciais existentes: $ENV_FILE (a senha nao sera alterada)."
fi
chown "$ADMIN_UID:$ADMIN_GID" "$ENV_FILE" "$STACK_ROOT/plex/compose.yaml" "$STACK_ROOT/transmission/compose.yaml"
chmod 0600 "$ENV_FILE"

log 'Validando e iniciando Plex...'
docker compose --env-file "$ENV_FILE" -f "$STACK_ROOT/plex/compose.yaml" config --quiet
docker compose --env-file "$ENV_FILE" -f "$STACK_ROOT/plex/compose.yaml" -p media-plex up -d

log 'Validando e iniciando Transmission...'
docker compose --env-file "$ENV_FILE" -f "$STACK_ROOT/transmission/compose.yaml" config --quiet
docker compose --env-file "$ENV_FILE" -f "$STACK_ROOT/transmission/compose.yaml" -p media-transmission up -d

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
printf '\n===== INSTALACAO CONCLUIDA =====\n'
printf 'Plex:         http://%s:32400/web\n' "${IP:-IP_DO_SERVIDOR}"
printf 'Transmission: http://%s:9091\n' "${IP:-IP_DO_SERVIDOR}"
printf 'SSH:          ssh %s@%s (porta 22)\n' "$ADMIN_USER" "${IP:-IP_DO_SERVIDOR}"
printf 'Usuario Transmission: transmission\n'
printf 'Senha Transmission: consulte %s (TRANSMISSION_PASS)\n' "$ENV_FILE"
printf 'Downloads no host: %s/media/downloads\n' "$DATA_ROOT"
printf 'Midia no Plex: /media/downloads\n'
printf 'Composes: %s/{plex,transmission}/compose.yaml\n' "$STACK_ROOT"
printf '\nPara usar docker sem sudo, saia e entre novamente na sessao do usuario %s.\n' "$ADMIN_USER"
printf 'O servidor sera reiniciado automaticamente em 10 segundos.\n'
printf 'Configure uma biblioteca do Plex apontando para /media/downloads; misturar filmes e series pode prejudicar a identificacao.\n'

log 'Reiniciando o servidor em 10 segundos... (Ctrl+C para cancelar)'
sleep 10
sudo reboot

# Kit de implantacao: Ubuntu Server + Plex + Transmission

## Pre-requisitos
- Ubuntu Server amd64/arm64 suportado pelo repositorio oficial Docker, com internet.
- Usuario comum com permissao `sudo`.
- Espaco em disco no caminho `/data` (verifique `findmnt /data` e `df -h /data`).
- Portas 22/tcp (SSH), 32400/tcp (Plex), 9091/tcp (Transmission) e 51413/tcp+udp (peers) livres.

## Instalacao
Descompacte e, no diretorio `ubuntu-media-server`, execute:

```bash
bash setup.sh
```

O script pede sudo, atualiza pacotes, instala e habilita OpenSSH Server, instala `net-tools` e `nano`, instala Docker Engine e Compose, cria os diretorios, solicita e confirma a senha do Transmission na primeira instalacao, instala os dois Compose e sobe os containers.

Se quiser ignorar upgrade completo de pacotes (mantendo `apt update`):

```bash
SKIP_UPGRADE=1 bash setup.sh
```

Para outro disco/local de dados, configure antes da primeira instalacao:

```bash
DATA_ROOT=/srv/media bash setup.sh
```

**Nao use um diretorio de dados em disco removivel sem garantir montagem automatica antes do Docker iniciar.** O script avisa se `/data` nao for um ponto de montagem, mas nao altera o particionamento ou o `/etc/fstab`.

## Diretorios

```text
/data/
  docker/
    plex/config/
    transmission/config/
    stacks/
      .env
      plex/compose.yaml
      transmission/compose.yaml
  media/
    downloads/
      incomplete/
```

O Transmission grava em `/downloads` dentro do container, que corresponde a `/data/media/downloads` no host. No Plex a mesma pasta aparece como `/media/downloads`.

## Acesso
- SSH: `ssh SEU_USUARIO@IP_DO_SERVIDOR` (porta 22; usa a senha ou chave do usuario Ubuntu, nao a senha do Transmission).
- Plex: `http://IP_DO_SERVIDOR:32400/web`
- Transmission: `http://IP_DO_SERVIDOR:9091`
- Login Transmission: `transmission`; senha em `/data/docker/stacks/.env` (TRANSMISSION_PASS).

Para visualizar apenas a senha:

```bash
sudo grep '^TRANSMISSION_PASS=' /data/docker/stacks/.env
```

## Administracao

```bash
sudo docker ps
sudo docker logs -f plex
sudo docker logs -f transmission
sudo docker compose --env-file /data/docker/stacks/.env -f /data/docker/stacks/plex/compose.yaml -p media-plex pull
sudo docker compose --env-file /data/docker/stacks/.env -f /data/docker/stacks/plex/compose.yaml -p media-plex up -d
```

O mesmo vale para Transmission substituindo `plex` por `transmission` e `media-plex` por `media-transmission`.

## Observacoes
- O script nao modifica IP, roteador nem configura as bibliotecas do Plex automaticamente. Nao ativa o firewall; caso o UFW ja esteja ativo, permite OpenSSH. Outras regras de firewall existentes permanecem em vigor.
- Se o Transmission ja tiver configuracoes antigas, o diretorio padrao salvo no `settings.json` pode prevalecer. Ajuste pela interface web para `/downloads`.
- Plex nao garante classificar corretamente filmes e series misturados em uma unica pasta. Recomendacao oficial: bibliotecas e diretorios separados por tipo. A pasta unica foi mantida por preferencia de implantacao.
- Para acesso SSH remoto, confirme que a porta 22 esta liberada em eventuais firewalls externos. O script nao habilita login SSH de root nem autenticacao por senha se ela ja estiver desabilitada na configuracao existente.
- O Transmission tem senha para acesso web, mas o arquivo `.env` guarda a credencial em texto simples (permissao 0600). Nao publique a porta 9091 na internet.
- Membros do grupo `docker` possuem privilegios equivalentes a root; conceda acesso apenas a usuarios confiaveis.
- Os dados existentes nao sao movidos, apagados ou reorganizados. Faca backup de `/data/docker` e `/data/media`.
- A configuracao usa imagens `latest`; para implantacoes estritamente reproduziveis, fixe tags/digests testados.
- O script pressupoe que nao ha uma instalacao Docker conflitante de outra origem.

### Senha do Transmission

Na primeira instalacao, o instalador solicita a senha duas vezes, sem exibir os caracteres. Use 8 a 128 caracteres (letras, numeros, `_`, `.`, `@`, `-`). Em execucoes posteriores, a senha existente em `/data/docker/stacks/.env` e preservada. Para alterar a senha posteriormente, edite `TRANSMISSION_PASS` nesse arquivo e recrie o container Transmission.

## Reinicializacao automatica

Ao concluir a instalacao e iniciar os containers, o script reinicia o Ubuntu Server automaticamente apos 10 segundos. A conexao SSH sera interrompida. Pressione Ctrl+C durante a espera para cancelar.

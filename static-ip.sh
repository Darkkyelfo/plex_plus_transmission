#!/usr/bin/env bash
set -Eeuo pipefail
# Congela o IPv4 atual da interface que possui a rota padrao, mantendo gateway e DNS ativos.
[[ $EUID -eq 0 ]] || exec sudo bash "$0" "$@"
command -v netplan >/dev/null || { echo 'Erro: netplan nao instalado.' >&2; exit 1; }
command -v python3 >/dev/null || { echo 'Erro: python3 nao instalado.' >&2; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo 'Erro: modulo python3-yaml necessario (sudo apt install python3-yaml).' >&2; exit 1; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
# Detecta interface, endereco, gateway, DNS e o arquivo Netplan responsavel.
python3 - "$work" <<'PY'
import subprocess, json, os, sys, glob, ipaddress, re, yaml
out=sys.argv[1]
def cmd(*args): return subprocess.check_output(args,text=True).strip()
def j(*args): return json.loads(cmd(*args))
routes=j('ip','-j','-4','route','show','default')
routes=[r for r in routes if r.get('gateway') and r.get('dev')]
if len(routes)!=1: sys.exit('Erro: esperado exatamente um gateway IPv4 padrao. Verifique ip route.')
r=routes[0]; iface=r['dev']; gw=r['gateway']
addresses=[a for entry in j('ip','-j','-4','addr','show','dev',iface) for a in entry.get('addr_info',[]) if a.get('scope')=='global' and a.get('local')]
if len(addresses)!=1: sys.exit('Erro: esperado exatamente um IPv4 global na interface '+iface)
a=addresses[0]; address=f"{a['local']}/{a['prefixlen']}"
mac=open(f'/sys/class/net/{iface}/address').read().strip().lower()
# DNS especificos do link, com fallback para os resolvedores reais do sistema.
dns=[]
try:
    raw=cmd('resolvectl','dns',iface)
    for token in re.findall(r'(?<![\w:])(?:\d{1,3}(?:\.\d{1,3}){3}|[0-9a-fA-F:]{3,})(?![\w:])',raw):
        try:
            ip=ipaddress.ip_address(token)
            if not ip.is_loopback and not ip.is_unspecified and str(ip) not in dns: dns.append(str(ip))
        except ValueError: pass
except (FileNotFoundError,subprocess.CalledProcessError): pass
if not dns:
    for path in ('/run/systemd/resolve/resolv.conf','/etc/resolv.conf'):
        try:
            for line in open(path):
                m=re.match(r'^\s*nameserver\s+(\S+)',line)
                if m:
                    ip=ipaddress.ip_address(m.group(1).split('%')[0])
                    if not ip.is_loopback and not ip.is_unspecified and str(ip) not in dns: dns.append(str(ip))
        except (OSError,ValueError): pass
if not dns: sys.exit('Erro: nao foi possivel descobrir DNS reais. Nenhuma alteracao foi feita.')
# Encontra o ID netplan da interface, preservando SSID, senha Wi-Fi e demais ajustes.
found=[]
for path in glob.glob('/etc/netplan/*.yaml'):
    try: data=yaml.safe_load(open(path)) or {}
    except yaml.YAMLError as e: sys.exit(f'Erro ao ler {path}: {e}')
    for section in ('ethernets','wifis'):
        for key,config in (data.get('network',{}).get(section,{}) or {}).items():
            if not isinstance(config,dict): continue
            match=config.get('match',{}) or {}
            if key==iface or config.get('set-name')==iface or match.get('macaddress','').lower()==mac:
                found.append((path,section,key))
if len(found)!=1: sys.exit(f'Erro: encontrado(s) {len(found)} bloco(s) Netplan para {iface}. Configuracao complexa: revise manualmente.')
path,section,key=found[0]
with open(os.path.join(out,'params'),'w') as f:
    for value in (path,section,key,iface,address,gw,','.join(dns)): f.write(value+'\n')
print(f'Interface: {iface}\nIP: {address}\nGateway: {gw}\nDNS: {", ".join(dns)}\nNetplan: {path} ({section}.{key})')
PY
mapfile -t cfg < "$work/params"
path=${cfg[0]}; section=${cfg[1]}; key=${cfg[2]}; iface=${cfg[3]}; address=${cfg[4]}; gateway=${cfg[5]}; dns=${cfg[6]}
echo
read -r -p 'Deseja fixar este IP atual? [s/N] ' confirm
[[ "$confirm" =~ ^[sS]$ ]] || { echo 'Cancelado.'; exit 0; }
backup="${path}.backup-$(date +%Y%m%d-%H%M%S)"
cp -a -- "$path" "$backup"
# Modifica somente o bloco correspondente; guarda copia de seguranca.
python3 - "$path" "$section" "$key" "$address" "$gateway" "$dns" <<'PY'
import sys,yaml,os,tempfile
path,section,key,address,gw,dns=sys.argv[1:]
with open(path) as f: data=yaml.safe_load(f)
config=data['network'][section][key]
config['dhcp4']=False
config['addresses']=[address]
config['routes']=[{'to':'default','via':gw}]
config.pop('gateway4',None)
config['nameservers']={'addresses':dns.split(',')}
fd,tmp=tempfile.mkstemp(prefix='.netplan-',suffix='.yaml',dir=os.path.dirname(path))
try:
    with os.fdopen(fd,'w') as f: yaml.safe_dump(data,f,sort_keys=False,allow_unicode=True)
    os.chmod(tmp,0o600)
    os.replace(tmp,path)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY
chmod 600 "$path"
echo "Backup: $backup"
if ! netplan generate; then
  echo 'Erro de validacao: restaurando configuracao original.' >&2
  cp -a -- "$backup" "$path"
  exit 1
fi
cat <<'MSG'
ATENCAO: a rede sera reconfigurada. Se estiver conectado por SSH, a sessao pode cair.
O Netplan tentara reverter as mudancas caso nao sejam confirmadas em ate 120 segundos.
Confirme apenas se o SSH e a conectividade continuarem funcionando.
MSG
if netplan try --timeout 120; then
  echo 'IP fixo aplicado. Confira com: ip -4 addr; ip route; resolvectl status'
else
  echo 'Configuracao nao confirmada; restaurando arquivo original.' >&2
  cp -a -- "$backup" "$path"
  netplan generate || true
  netplan apply || true
  exit 1
fi

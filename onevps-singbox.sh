#!/usr/bin/env bash
# OneVPS sing-box edition — standalone deployment/maintenance script.
# Requires Linux + systemd, Python 3.8+, root for operations that change the VPS.
# Documentation: https://sing-box.sagernet.org/ (sing-box >= 1.14.0)
# Usage: sudo bash onevps-singbox.sh
#        sudo bash onevps-singbox.sh --check
#        sudo bash onevps-singbox.sh --acceptance
#        bash onevps-singbox.sh --self-test
# Surge Snell v5 QUIC proxy mode is not implemented by sing-box (official limitation).
# Surge Snell v6 requires a current Surge client (iOS 5.20+ / macOS 6.7+).
# A genuine VPS/network and DNS are required to validate public connectivity.
set -euo pipefail
umask 077
if ! command -v python3 >/dev/null 2>&1; then
  if (( EUID != 0 )); then echo 'Python 3 is required (run as root).' >&2; exit 1; fi
  if command -v apt-get >/dev/null; then apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y python3
  elif command -v dnf >/dev/null; then dnf install -y python3
  elif command -v yum >/dev/null; then yum install -y python3
  elif command -v zypper >/dev/null; then zypper --non-interactive install python3
  else echo 'Please install Python 3.8 or later first.' >&2; exit 1; fi
fi
export ONEVPS_SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
exec python3 /dev/fd/3 "$@" 3<<'PYTHON_APP'
import base64
import copy
import hashlib
import ipaddress
import json
import os
import pathlib
import re
import secrets
import shutil
import socket
import ssl
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import fcntl
from contextlib import contextmanager

if sys.version_info < (3, 8):
    sys.exit('Python >=3.8 is required')

ROOT = pathlib.Path(os.environ.get('ONEVPS_TEST_ROOT', '/'))
# ONEVPS_TEST_ROOT is exclusively for offline development testing; never used on actual deployment.
BASE = pathlib.Path('/etc/onevps-singbox')
META = BASE / 'nodes.json'
CONF = BASE / 'config.json'
LOCK = pathlib.Path('/run/lock/onevps-singbox.lock')
CADDY_SNIPPET = pathlib.Path('/etc/caddy/onevps-singbox.caddy')
CERTS = BASE / 'certs'
SERVICE = pathlib.Path('/etc/systemd/system/onevps-singbox.service')
TIMER_SERVICE = pathlib.Path('/etc/systemd/system/onevps-singbox-certs.service')
TIMER = pathlib.Path('/etc/systemd/system/onevps-singbox-certs.timer')
SCRIPT_INSTALLED = pathlib.Path('/usr/local/sbin/onevps-singbox')
UPDATE_URL = 'https://raw.githubusercontent.com/0nevps/OneVPS/main/onevps-singbox.sh'
REALM_BASE = pathlib.Path('/etc/onevps-singbox-realm')
REALM_BINARY = pathlib.Path('/usr/local/bin/onevps-sb-realm')
REALM_UNIT = pathlib.Path('/etc/systemd/system/onevps-sb-realm.service')
OWNER = 'onevps-sb'
SITE_ROOT = pathlib.Path('/var/lib/onevps/sites')
ORIGINAL_403_HTML = '<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width, initial-scale=1">\n<title>403 Forbidden</title>\n<link rel="preconnect" href="https://fonts.googleapis.com">\n<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>\n<link href="https://fonts.googleapis.com/css2?family=Outfit:wght@400;500;600;700;800&family=Noto+Sans+SC:wght@400;500;700&display=swap" rel="stylesheet">\n<style>\n*{box-sizing:border-box;margin:0;padding:0}\nhtml,body{height:100%}\n@keyframes floatA{0%,100%{transform:translateY(0)}50%{transform:translateY(-18px)}}\n@keyframes floatB{0%,100%{transform:translateY(0) rotate(-3deg)}50%{transform:translateY(-12px) rotate(3deg)}}\n@keyframes blob{0%,100%{transform:translate(0,0) scale(1)}50%{transform:translate(30px,-20px) scale(1.12)}}\n@keyframes pop{0%{transform:scale(.8);opacity:0}100%{transform:scale(1);opacity:1}}\n@keyframes blink{0%,90%,100%{transform:scaleY(1)}95%{transform:scaleY(.1)}}\n@keyframes shake{0%,100%{transform:rotate(0)}25%{transform:rotate(-12deg)}75%{transform:rotate(12deg)}}\n</style>\n</head>\n<body>\n<div style="position:relative;min-height:100vh;width:100%;overflow:hidden;background:radial-gradient(1200px 800px at 75% 15%, #241d33 0%, #181520 55%, #131019 100%);font-family:\'Outfit\',\'Noto Sans SC\',system-ui,sans-serif;color:#ece8f2;display:flex;align-items:center;justify-content:center;padding:48px 32px">\n  <div style="position:relative;z-index:2;display:flex;align-items:center;justify-content:center;max-width:760px;width:100%">\n    <div style="display:flex;flex-direction:column;gap:28px">\n      <div style="display:inline-flex;align-items:center;gap:10px;align-self:flex-start;padding:7px 14px;border-radius:999px;background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.1);font-size:13px;letter-spacing:.04em;color:#b9b2c9;font-weight:500">\n        <span style="width:8px;height:8px;border-radius:50%;background:#ff4d42;box-shadow:0 0 12px #ff4d42"></span>\n        HTTP 403 · FORBIDDEN\n      </div>\n      <div style="display:flex;align-items:baseline;gap:6px;font-weight:800;line-height:.85;font-size:clamp(96px,16vw,196px);letter-spacing:-.04em">\n        <span>4</span>\n        <span>0</span>\n        <span>3</span>\n      </div>\n      <div style="display:flex;flex-direction:column;gap:10px">\n        <h1 style="font-size:clamp(26px,3.4vw,40px);font-weight:700;letter-spacing:-.01em;line-height:1.15">Access Forbidden</h1>\n      </div>\n      <p style="font-size:16px;line-height:1.7;color:#b9b2c9;max-width:52ch">\n        You don\'t have permission to view this page. Try signing in again, or reach out if you think this is a mistake.\n      </p>\n    </div>\n  </div>\n</div>\n</body>\n</html>\n'
REALITY_TARGETS = ['www.cloudflare.com','www.amazon.com','www.paypal.com','www.ebay.com','www.microsoft.com','www.apple.com','www.samsung.com','gateway.icloud.com','www.lovelive-anime.jp','www.wikipedia.org','www.oracle.com','www.netflix.com']
PORTS = {'hysteria2': 'udp', 'ss2022': 'both'}
WS_TYPES = ('trojan-ws', 'vmess-ws')
TYPES = ('vless-reality', 'trojan-ws', 'vmess-ws', 'hysteria2', 'snell5', 'snell6', 'ss2022')
MIN_VERSION = (1, 14, 0)

class OneVPSException(Exception):
    pass

def fail(msg):
    raise OneVPSException(msg)

def log(message):
    print('[*]', message, flush=True)

def ok(message):
    print('[+]', message, flush=True)

def warn(message):
    print('[!]', message, file=sys.stderr, flush=True)

def command(argv, *, check=True, input=None, timeout=120, capture=True):
    try:
        p = subprocess.run([str(a) for a in argv], input=input, text=True,
                           stdout=subprocess.PIPE if capture else None,
                           stderr=subprocess.PIPE if capture else None, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as e:
        fail('Cannot run %s: %s' % (argv[0], e))
    if check and p.returncode:
        detail = (p.stderr or p.stdout or 'exit %d' % p.returncode).strip()
        # sing-box check errors can include secrets; don't print its full config/log.
        fail('%s failed: %s' % (argv[0], detail[:700] if not ('sing-box' in str(argv[0]) and 'check' in argv) else 'configuration check failed'))
    return p

def shell_status(argv):
    try:
        return subprocess.run([str(a) for a in argv], stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=20).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False

def sysctl(key):
    p = command(['sysctl','-n',key],check=False)
    return p.stdout.strip() if p.returncode == 0 else ''

def request(url, timeout=35):
    req = urllib.request.Request(url, headers={'User-Agent':'OneVPS-sing-box/1.0'})
    with urllib.request.urlopen(req, timeout=timeout) as f:
        return f.read()

def write_secure(path, data, mode=0o600, group=None):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=str(path.parent), prefix='.onevps-', delete=False) as f:
        tmp = pathlib.Path(f.name)
        try:
            f.write(data.encode() if isinstance(data, str) else data)
            f.flush(); os.fsync(f.fileno())
            os.chmod(tmp, mode)
            if group is not None:
                import grp
                os.chown(tmp, 0, grp.getgrnam(group).gr_gid)
        except Exception:
            tmp.unlink(missing_ok=True)
            raise
    os.replace(tmp, path)

def jdump(obj):
    return json.dumps(obj, indent=2, ensure_ascii=False, sort_keys=False) + '\n'

def read_meta():
    if not META.exists():
        return {'nodes': [], 'domains': []}
    obj = json.loads(META.read_text())
    if not isinstance(obj,dict) or not isinstance(obj.get('nodes'),list) or not isinstance(obj.get('domains',[]),list):
        fail('Invalid nodes.json; manually repair before continuing')
    return obj

def require_root():
    if os.geteuid() != 0: fail('Please run as root: sudo bash onevps-singbox.sh')
    if not shutil.which('systemctl'): fail('Only Linux systemd VPS is supported')

@contextmanager
def locked():
    BASE.mkdir(parents=True, exist_ok=True)
    LOCK.parent.mkdir(parents=True,exist_ok=True)
    with open(LOCK, 'a+') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield

def ask(question, default=None):
    suffix = (' [%s]' % default) if default is not None else ''
    response = input('%s%s: ' % (question, suffix)).strip()
    return response or (default if default is not None else '')

def confirm(question, default=False):
    v = ask(question + (' [Y/n]' if default else ' [y/N]'))
    return (v.lower() in ('y','yes')) if v else default

def validate_domain(domain):
    if len(domain)>253 or '.' not in domain: fail('Invalid domain')
    if not all(re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?',label)
               for label in domain.split('.')): fail('Invalid domain')
    return domain

def domain_prompt(question='Domain'):
    return validate_domain(re.sub(r'^https?://', '', ask(question).lower()).split('/')[0])

def valid_port(v):
    try:
        p = int(v)
    except (TypeError,ValueError):
        fail('Port must be a number')
    if not 1<=p<=65535: fail('Port outside 1..65535')
    return p

def valid_host(host):
    try:
        ipaddress.ip_address(host.strip('[]'))
        return host.strip('[]')
    except ValueError:
        return validate_domain(host.lower())

def name_prompt(default):
    name=ask('Node name',default)
    if not (1<=len(name)<=64) or any(ord(ch)<32 or ord(ch)==127 for ch in name): fail('Invalid node name')
    return name

def new_id():
    return secrets.token_hex(5)

def gen_secret():
    return secrets.token_urlsafe(28)

def pubip():
    for url in ('https://api.ipify.org','https://ipv4.icanhazip.com'):
        try:
            ip = request(url, 8).decode().strip()
            return str(ipaddress.ip_address(ip))
        except Exception:
            continue
    return valid_host(ask('Public server IP / hostname (automatic detection failed)'))

def ensure_owner():
    import pwd
    try:
        pwd.getpwnam(OWNER)
    except KeyError:
        command(['useradd','--system','--no-create-home','--shell','/usr/sbin/nologin',OWNER])
    import grp
    group = grp.getgrnam(OWNER).gr_gid
    BASE.mkdir(parents=True,exist_ok=True)
    os.chown(BASE,0,group)
    os.chmod(BASE,0o750)
    CERTS.mkdir(parents=True, exist_ok=True)
    os.chown(CERTS,0,group)
    os.chmod(CERTS,0o750)

def bin_path():
    return shutil.which('sing-box') or '/usr/bin/sing-box'

def version_tuple():
    path=shutil.which('sing-box')
    if not path: return None
    out=command([path,'version'],check=False)
    match=re.search(r'(?i)sing-box\s+version\s+v?(\d+)\.(\d+)\.(\d+)',out.stdout)
    return tuple(map(int,match.groups())) if match else None

def require_core():
    version=version_tuple()
    if not version or version<MIN_VERSION:
        fail('Requires sing-box >=1.14.0 (Snell support), install/update in menu 1')
    return version

def write_service():
    # Separate name prevents overwriting an unrelated sing-box.service installation.
    unit='''# Managed by OneVPS sing-box — do not edit manually
[Unit]
Description=OneVPS sing-box managed proxy
After=network-online.target nss-lookup.target
Wants=network-online.target
[Service]
Type=simple
User=onevps-sb
Group=onevps-sb
ExecStart=%s run -c %s
Restart=on-failure
RestartSec=4
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=strict
PrivateTmp=true
ReadWritePaths=/var/lib/onevps-singbox
[Install]
WantedBy=multi-user.target
''' % (bin_path(),CONF)
    pathlib.Path('/var/lib/onevps-singbox').mkdir(parents=True,exist_ok=True)
    command(['chown',OWNER+':'+OWNER,'/var/lib/onevps-singbox'])
    write_secure(SERVICE,unit,0o644)
    command(['systemctl','daemon-reload'])
    command(['systemctl','enable','onevps-singbox.service'])

def installed_script():
    src=pathlib.Path(os.environ.get('ONEVPS_SCRIPT_PATH',''))
    if not src.is_file(): fail('Launch from a saved .sh file (not a pipe) to install maintenance timer')
    text=src.read_text()
    if not text.startswith('#!/usr/bin/env bash') or 'PYTHON_APP' not in text:
        fail('Script does not look like a valid OneVPS sing-box file')
    write_secure(SCRIPT_INSTALLED,text,0o700)

def install_timer():
    installed_script()
    write_secure(TIMER_SERVICE,'''[Unit]
Description=Synchronize Caddy TLS certificates to OneVPS sing-box
After=network-online.target caddy.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/onevps-singbox --sync-certs
UMask=0077
''',0o644)
    write_secure(TIMER,'''[Unit]
Description=Regular OneVPS certificate renewal synchronization
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true
[Install]
WantedBy=timers.target
''',0o644)
    command(['systemctl','daemon-reload'])
    command(['systemctl','enable','--now','onevps-singbox-certs.timer'])

def ensure_runtime_dependencies():
    missing=[x for x in ('curl','openssl','ss') if not shutil.which(x)]
    if not missing:return
    log('Installing missing runtime tools: '+', '.join(missing))
    packages={'curl':'curl','openssl':'openssl','ss':'iproute2'}
    if shutil.which('apt-get'):
        command(['apt-get','update','-qq'],capture=False,timeout=180)
        command(['apt-get','install','-y']+[packages[x] for x in missing],capture=False,timeout=240)
    elif shutil.which('dnf') or shutil.which('yum'):
        manager=shutil.which('dnf') or shutil.which('yum')
        packages['ss']='iproute'
        command([manager,'install','-y']+[packages[x] for x in missing],capture=False,timeout=240)
    elif shutil.which('zypper'):
        command(['zypper','--non-interactive','install']+[packages[x] for x in missing],capture=False,timeout=240)
    if any(not shutil.which(x) for x in missing):
        fail('Runtime tools still missing: '+', '.join(x for x in missing if not shutil.which(x)))

def listening_ports(proto):
    if not shutil.which('ss'):return None
    argv=['ss','-H','-lnu' if proto=='udp' else '-lnt']
    res=command(argv,check=False)
    if res.returncode:return None
    ports=set()
    for line in res.stdout.splitlines():
        cols=line.split()
        if len(cols)>=5:
            try:ports.add(int(cols[3].rsplit(':',1)[1]))
            except (ValueError,IndexError):pass
    return ports

def assert_active_ports(nodes):
    for attempt in range(8):
        failures=[]
        tcp=listening_ports('tcp');udp=listening_ports('udp')
        if tcp is None or udp is None:
            warn('ss is unavailable; runtime socket verification skipped')
            return
        for n in nodes:
            if not n['enabled']:continue
            needed=('udp',) if n['type']=='hysteria2' else (('tcp','udp') if n['type']=='ss2022' else ('tcp',))
            for proto in needed:
                if n['port'] not in (udp if proto=='udp' else tcp):
                    failures.append('%s %s/%s'%(n['name'],n['port'],proto))
        if not failures:return
        if attempt<7:time.sleep(0.4)
    fail('Service is active but listener missing: '+', '.join(failures))

def install_core():
    require_root()
    with locked():
        ensure_runtime_dependencies()
        log('Installing/updating official stable sing-box package')
        # Official installer installs native packages when possible. It is fetched
        # separately and not executed from a pipe to simplify failure inspection.
        data=request('https://sing-box.app/install.sh')
        if not data.startswith(b'#!'): fail('Downloaded sing-box installer is not a shell script')
        with tempfile.TemporaryDirectory() as tmp:
            path=pathlib.Path(tmp)/'install.sh'; path.write_bytes(data)
            command(['sh',str(path)],capture=False,timeout=300)
        require_core()
        ensure_owner()
        # Do not disable/replace an existing standalone sing-box installation.
        if not META.exists():
            write_secure(META,jdump({'nodes':[],'domains':[]}),0o640,OWNER)
        if not CONF.exists():
            tmp=render_config(read_meta())
            check_core(tmp)
            write_secure(CONF,jdump(tmp),0o640,OWNER)
        write_service()
        install_timer()
        command(['systemctl','restart','onevps-singbox.service'])
        if not service_active(): fail('Service failed to start; inspect journalctl -u onevps-singbox')
        assert_active_ports(read_meta()['nodes'])
        ok('sing-box %s ready' % '.'.join(map(str,require_core())))

def service_active(name='onevps-singbox.service'):
    return shell_status(['systemctl','is-active','--quiet',name])

def check_core(config):
    require_core()
    with tempfile.NamedTemporaryFile('w',suffix='.json',dir=str(BASE),delete=False) as f:
        path=pathlib.Path(f.name); json.dump(config,f,ensure_ascii=False)
    try:
        p=command([bin_path(),'check','-c',str(path)],check=False,timeout=45)
        if p.returncode:
            # Never expose a candidate configuration or credentials in terminal/logs.
            fail('sing-box check rejected the proposed configuration; no changes applied')
    finally:
        path.unlink(missing_ok=True)

def socket_conflict(port,proto):
    # Both is used for Shadowsocks 2022, which listens on TCP and UDP.
    if proto=='both':return socket_conflict(port,'tcp') or socket_conflict(port,'udp')
    try:
        with socket.socket(socket.AF_INET,socket.SOCK_DGRAM if proto=='udp' else socket.SOCK_STREAM) as s:
            s.bind(('0.0.0.0',port))
        return False
    except OSError:
        return True

def check_port(port,proto,meta,except_id=None):
    port=valid_port(port)
    needed={'tcp','udp'} if proto=='both' else {proto}
    for n in meta['nodes']:
        if n['id']==except_id: continue
        occupied={'tcp','udp'} if n['type']=='ss2022' else ({'udp'} if n['type']=='hysteria2' else {'tcp'})
        if n.get('port')==port and needed & occupied:
            fail('Port %s already assigned to %s' %(port,n['name']))
    if socket_conflict(port,proto) and not (except_id and any(
            n['id']==except_id and n.get('port')==port for n in meta['nodes'])):
        fail('%s/%s is already occupied' % (port,proto))
    return port

def choose_port(meta,proto,proposed,except_id=None):
    while True:
        try:
            return check_port(ask('Listen port',str(proposed)),proto,meta,except_id)
        except OneVPSException as e: warn(str(e))

def random_port(meta,proto='tcp'):
    for _ in range(100):
        p=10000+secrets.randbelow(50000)
        try: return check_port(p,proto,meta)
        except OneVPSException: pass
    fail('Cannot find a free port')

def firewall_allow(port,proto):
    if shutil.which('ufw') and 'Status: active' in command(['ufw','status'],check=False).stdout:
        command(['ufw','allow','%s/%s'%(port,proto)],check=False)
    if shutil.which('firewall-cmd') and shell_status(['firewall-cmd','--state']):
        command(['firewall-cmd','--permanent','--add-port=%s/%s'%(port,proto)],check=False)
        command(['firewall-cmd','--reload'],check=False)
    warn('Also allow %s/%s in your cloud provider security group' % (port,proto))

def tls_cert_paths(domain):
    return str(CERTS/domain/'fullchain.pem'),str(CERTS/domain/'privkey.pem')

def validate_pem(cert,key,domain):
    if not pathlib.Path(cert).is_file() or not pathlib.Path(key).is_file(): return False
    try:
        if not shell_status(['openssl','x509','-in',cert,'-noout','-checkhost',domain]):return False
        if not shell_status(['openssl','x509','-in',cert,'-noout','-checkend','3600']):return False
        public_cert=command(['openssl','x509','-in',cert,'-pubkey','-noout']).stdout
        public_key=command(['openssl','pkey','-in',key,'-pubout']).stdout
        return public_cert==public_key
    except Exception:
        return False

def render_config(meta):
    ids=set(); tags=set(); ports=set()
    output={'log':{'level':'warn'},'inbounds':[],'outbounds':[{'type':'direct','tag':'direct'}],
            'route':{'rules':[{'action':'sniff'},
                              {'ip_is_private':True,'action':'reject'},
                              {'ip_cidr':['0.0.0.0/8','100.64.0.0/10','169.254.0.0/16','192.0.2.0/24','198.18.0.0/15','198.51.100.0/24','203.0.113.0/24','224.0.0.0/4','240.0.0.0/4','2001:db8::/32'], 'action':'reject'},
                              {'protocol':'bittorrent','action':'reject'}],
                     'final':'direct'}}
    for n in meta['nodes']:
        nid=n['id']; nt=n['type']; port=valid_port(n['port'])
        if not isinstance(n.get('name'),str) or not (1<=len(n['name'])<=64):fail('Invalid node name')
        if not isinstance(n.get('credential'),str) or not n['credential']:fail('Invalid credential')
        if not re.fullmatch(r'[0-9a-f]{10}',nid) or nid in ids: fail('Invalid/duplicate node ID')
        ids.add(nid)
        if nt not in TYPES: fail('Unsupported node type: '+str(nt))
        if not isinstance(n.get('enabled'),bool): fail('Invalid enabled flag')
        if not isinstance(n.get('users',[]),list): fail('Invalid users list')
        if n.get('users') and nt in ('snell5','snell6','ss2022') and not n.get('default_user_key'):
            fail('Invalid multi-user state: missing default_user_key')
        if not n['enabled']: continue
        protocols=('udp',) if nt=='hysteria2' else (('tcp','udp') if nt=='ss2022' else ('tcp',))
        for pproto in protocols:
            if (port,pproto) in ports: fail('Duplicate listen port')
            ports.add((port,pproto))
        tag='in-'+nid
        if tag in tags: fail('Duplicate tag')
        tags.add(tag)
        users=[{'id':'default','name':'default','credential':n.get('default_user_key',n['credential'])}]+n.get('users',[])
        names=set(); credentials=set()
        for u in users:
            if (not re.fullmatch(r'(default|u[a-zA-Z0-9_-]{1,32})',u['id']) or
                not isinstance(u.get('credential'),str) or not u['credential'] or
                u['id'] in names or u['credential'] in credentials): fail('Invalid or duplicate user credentials')
            names.add(u['id']); credentials.add(u['credential'])
        if nt=='ss2022':
            for key in [n['credential']]+([u['credential'] for u in users] if n.get('default_user_key') else []):
                try:
                    if len(base64.b64decode(key,validate=True))!=16:fail('SS2022 key must decode to 16 bytes')
                except (ValueError,base64.binascii.Error):fail('Invalid SS2022 base64 key')
        if nt=='vless-reality':
            ib={'type':'vless','tag':tag,'listen':'0.0.0.0','listen_port':port,
                'users':[{'name':u['id'],'uuid':u['credential'],'flow':'xtls-rprx-vision'} for u in users],
                'tls':{'enabled':True,'server_name':n['target'],'reality':{
                    'enabled':True,'handshake':{'server':n['target'],'server_port':443},
                    'private_key':n['private_key'],'short_id':[n['short_id']]}}}
        elif nt in WS_TYPES:
            ib={'type':'trojan' if nt=='trojan-ws' else 'vmess', 'tag':tag,
                'listen':'127.0.0.1','listen_port':port,
                'users':[({'name':u['id'],'password':u['credential']} if nt=='trojan-ws'
                           else {'name':u['id'],'uuid':u['credential'],'alterId':0}) for u in users],
                'transport':{'type':'ws','path':n['path']}}
        elif nt=='hysteria2':
            cert,key=tls_cert_paths(n['domain'])
            if not validate_pem(cert,key,n['domain']):
                fail('Hysteria2 certificate missing, expired, or invalid for '+n['domain'])
            ib={'type':'hysteria2','tag':tag,'listen':'0.0.0.0','listen_port':port,
                'users':[{'name':u['id'],'password':u['credential']} for u in users],
                'tls':{'enabled':True,'server_name':n['domain'],'certificate_path':cert,'key_path':key}}
        elif nt.startswith('snell'):
            version=6 if nt=='snell6' else 5
            psk=n['credential']
            if version==6 and not 12<=len(psk.encode())<=255: fail('Invalid Snell v6 PSK length')
            ib={'type':'snell','tag':tag,'listen':'0.0.0.0','listen_port':port,
                'version':version,'psk':psk}
            if n.get('default_user_key'):
                ib['users']=[{'name':u['id'],'userkey':u['credential']} for u in users]
            if version==5: ib['obfs_mode']=n.get('obfs_mode','none')
            else: ib['mode']=n.get('mode','default')
        else:  # Shadowsocks 2022 / Surge
            ib={'type':'shadowsocks','tag':tag,'listen':'0.0.0.0','listen_port':port,
                'method':'2022-blake3-aes-128-gcm','password':n['credential']}
            if n.get('default_user_key'):
                ib['users']=[{'name':u['id'],'password':u['credential']} for u in users]
        output['inbounds'].append(ib)
        # Independent auth_user routing: default user inherits node-level outbound.
        assignments=[]
        if n.get('default_outbound') is not None:
            if nt in ('snell5','snell6','ss2022') and not n.get('default_user_key'):
                assignments.append((None,n['default_outbound']))
            else:
                assignments.append(('default',n['default_outbound']))
        for u in users:
            if u.get('outbound') is not None:
                if nt not in ('snell5','snell6','ss2022') or n.get('default_user_key'):
                    assignments.append((u['id'],u['outbound']))
        if n.get('outbound') is not None and not (nt in ('snell5','snell6','ss2022') and not n.get('default_user_key') and n.get('default_outbound') is not None):
            assignments.append((None,n['outbound']))
        # Identity overrides before node-wide fallback, preserving per-user routing.
        assignments.sort(key=lambda x:x[0] is None)
        for who,link in assignments:
            route={'inbound':[tag]}
            if who is not None: route['auth_user']=[who]
            if link['type']=='direct':
                dest='direct'
            else:
                dest='out-'+nid+('-'+who if who else '-node')
                out=copy.deepcopy(link); out['tag']=dest
                output['outbounds'].append(out)
            route.update({'action':'route','outbound':dest})
            output['route']['rules'].append(route)
    return output

def ensure_site_content(domain):
    """Install the byte-for-byte original OneVPS 403 page; never overwrite user edits."""
    validate_domain(domain)
    # Explicitly set all ancestor permissions; the script-wide umask is 077.
    parent=SITE_ROOT.parent
    parent.mkdir(parents=True,exist_ok=True)
    site=SITE_ROOT/domain
    SITE_ROOT.mkdir(parents=True,exist_ok=True)
    site.mkdir(parents=True,exist_ok=True)
    for part in (parent,SITE_ROOT,site):
        os.chmod(part,0o755)
    index=site/'index.html'
    if not index.exists():
        write_secure(index,ORIGINAL_403_HTML,0o644)
    if index.is_symlink() or not index.is_file():
        fail('Invalid Caddy index.html: '+str(index))
    # Keep customized contents, but ensure the unprivileged Caddy account can read it.
    os.chmod(index,0o644)

def render_caddy(meta):
    domains={x:[] for x in meta.get('domains',[])}
    for n in meta['nodes']:
        if n.get('enabled') and (n['type'] in WS_TYPES or n['type']=='hysteria2'):
            domains.setdefault(n['domain'],[])
            if n['type'] in WS_TYPES: domains[n['domain']].append(n)
    output=['# Managed by OneVPS sing-box; regenerated after transactions.']
    for domain in sorted(domains):
        validate_domain(domain)
        output.append('%s {' % domain)
        output.append('    root * %s' % (SITE_ROOT/domain))
        for n in domains[domain]:
            if not re.fullmatch(r'/[A-Za-z0-9_-]{8,64}',n['path']): fail('Invalid WebSocket route')
            output.append('    handle %s {' % n['path'])
            output.append('        reverse_proxy 127.0.0.1:%d' % n['port'])
            output.append('    }')
        output.extend(['    handle {', '        error 403', '    }', '    handle_errors {',
                       '        rewrite * /index.html', '        file_server', '    }', '}'])
    return '\n'.join(output)+'\n'

def ensure_caddy_sites(meta):
    domains=set(meta.get('domains',[]))
    for n in meta['nodes']:
        if n.get('enabled') and n['type'] in (*WS_TYPES,'hysteria2'):
            domains.add(n['domain'])
    for domain in sorted(domains):
        ensure_site_content(domain)

def caddyfile():
    import shlex
    try:
        status=command(['systemctl','cat','caddy'],check=False).stdout
        for line in status.splitlines():
            if not line.startswith('ExecStart='):continue
            parts=shlex.split(line.split('=',1)[1])
            if '--config' in parts:
                i=parts.index('--config')
                candidate=pathlib.Path(parts[i+1])
                if '--adapter' in parts and parts[parts.index('--adapter')+1] != 'caddyfile':
                    fail('Caddy uses a non-Caddyfile adapter; refusing to modify its configuration')
                if candidate.is_absolute():return candidate
    except (IndexError,ValueError):pass
    return pathlib.Path('/etc/caddy/Caddyfile')

def needs_caddy(meta):
    return bool(meta.get('domains') or any(n.get('enabled') and n['type'] in (*WS_TYPES,'hysteria2') for n in meta['nodes']))

def install_caddy():
    if shutil.which('caddy'):return
    # Use maintained distro packages where possible; preserve all existing sites.
    if shutil.which('apt-get'):
        command(['apt-get','update','-qq'],capture=False,timeout=180)
        result=command(['apt-get','install','-y','caddy'],check=False,capture=False,timeout=240)
        if result.returncode:
            # Official Caddy Cloudsmith repository, same as the original OneVPS script.
            command(['apt-get','install','-y','debian-keyring','debian-archive-keyring',
                     'apt-transport-https','curl','gnupg','ca-certificates'],capture=False,timeout=240)
            key=pathlib.Path('/usr/share/keyrings/caddy-stable-archive-keyring.gpg')
            sources=pathlib.Path('/etc/apt/sources.list.d/caddy-stable.list')
            with tempfile.TemporaryDirectory() as tmp:
                raw=pathlib.Path(tmp)/'key.asc'
                raw.write_bytes(request('https://dl.cloudsmith.io/public/caddy/stable/gpg.key'))
                key.parent.mkdir(parents=True,exist_ok=True)
                command(['gpg','--batch','--yes','--dearmor','-o',str(key),str(raw)])
                os.chmod(key,0o644)
            old=sources.read_bytes() if sources.exists() else None
            try:
                write_secure(sources,request('https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt'),0o644)
                command(['apt-get','update','-qq'],capture=False,timeout=200)
                command(['apt-get','install','-y','caddy'],capture=False,timeout=240)
            except Exception:
                restore(sources,old,0o644)
                raise
    elif shutil.which('dnf'):
        result=command(['dnf','install','-y','caddy'],check=False,capture=False,timeout=240)
        if result.returncode:
            command(['dnf','install','-y','dnf-plugins-core'],capture=False,timeout=240)
            command(['dnf','copr','enable','-y','@caddy/caddy'],capture=False,timeout=180)
            command(['dnf','install','-y','caddy'],capture=False,timeout=240)
    elif shutil.which('yum'):
        result=command(['yum','install','-y','caddy'],check=False,capture=False,timeout=240)
        if result.returncode:
            command(['yum','install','-y','yum-plugin-copr'],capture=False,timeout=240)
            command(['yum','copr','enable','-y','@caddy/caddy'],capture=False,timeout=180)
            command(['yum','install','-y','caddy'],capture=False,timeout=240)
    elif shutil.which('zypper'):
        command(['zypper','--non-interactive','install','caddy'],capture=False,timeout=240)
    else:
        fail('Install Caddy using https://caddyserver.com/docs/install before adding TLS/WS nodes')
    if not shutil.which('caddy'):
        fail('Caddy executable unavailable after installation')

def ensure_caddy():
    install_caddy()
    cf=caddyfile()
    cf.parent.mkdir(parents=True,exist_ok=True)
    if not cf.exists(): write_secure(cf,'# Managed with OneVPS sing-box\n',0o644)
    if not CADDY_SNIPPET.exists():
        write_secure(CADDY_SNIPPET, '# Managed by OneVPS sing-box\n',0o644)
    data=cf.read_text()
    import_line='import '+str(CADDY_SNIPPET)
    if import_line not in data:
        # Warn on pre-existing Caddy host definitions: never silently re-use domain.
        data=data.rstrip()+'\n\n# OneVPS sing-box sites\n'+import_line+'\n'
        old=cf.read_bytes()
        write_secure(cf,data,0o644)
        if not caddy_check():
            write_secure(cf,old,0o644)
            fail('Caddyfile import validation failed; existing site untouched')
    command(['systemctl','enable','--now','caddy'])

def caddy_domains():
    # Detect host collisions in existing Caddy routes, including imported sites.
    if not shutil.which('caddy') or not caddyfile().is_file():return set()
    p=command(['caddy','adapt','--config',str(caddyfile()),'--adapter','caddyfile'],check=False)
    if p.returncode:return set()
    try:root=json.loads(p.stdout)
    except ValueError:return set()
    domains=set()
    def visit(v):
        if isinstance(v,dict):
            if isinstance(v.get('host'),list):
                domains.update(x for x in v['host'] if isinstance(x,str))
            for x in v.values():visit(x)
        elif isinstance(v,list):
            for x in v:visit(x)
    visit(root.get('apps',{}).get('http',{}).get('servers',{}))
    return domains

def caddy_check():
    if not shutil.which('caddy'): return False
    return shell_status(['caddy','validate','--config',str(caddyfile()),'--adapter','caddyfile'])

def caddy_reload():
    if not caddy_check(): fail('Caddy configuration validation failed')
    if service_active('caddy.service'):
        if shell_status(['systemctl','reload','caddy']): return
    command(['systemctl','restart','caddy'])
    if not service_active('caddy.service'): fail('Caddy did not start')

def apply(meta_new, *, caddy_change=True):
    """Atomic candidate validation + bounded service rollback. Caller holds lock."""
    require_core(); ensure_owner()
    config=render_config(meta_new)
    check_core(config)
    old_meta=META.read_bytes() if META.exists() else None
    old_conf=CONF.read_bytes() if CONF.exists() else None
    old_service_active=service_active()
    touch_caddy=caddy_change and (needs_caddy(meta_new) or CADDY_SNIPPET.exists())
    if touch_caddy:
        # Caddy must exist before any candidate uses it.
        ensure_caddy()
        ensure_caddy_sites(meta_new)
        old_caddy=CADDY_SNIPPET.read_bytes() if CADDY_SNIPPET.exists() else None
        proposed=render_caddy(meta_new)
        write_secure(CADDY_SNIPPET,proposed,0o644)
        if not caddy_check():
            restore(CADDY_SNIPPET,old_caddy,0o644)
            fail('Caddy candidate config rejected')
    try:
        write_secure(META,jdump(meta_new),0o640,OWNER)
        write_secure(CONF,jdump(config),0o640,OWNER)
        if not SERVICE.exists(): write_service()
        command(['systemctl','restart','onevps-singbox.service'])
        time.sleep(0.7)
        if not service_active(): fail('sing-box service failed to start')
        assert_active_ports(meta_new['nodes'])
        if touch_caddy: caddy_reload()
    except Exception as exc:
        restore(META,old_meta,0o640,OWNER)
        restore(CONF,old_conf,0o640,OWNER)
        if touch_caddy:
            restore(CADDY_SNIPPET,old_caddy,0o644)
            try: caddy_reload()
            except Exception: warn('Caddy rollback failed; manual recovery needed')
        try:
            if old_service_active: command(['systemctl','restart','onevps-singbox.service'])
            else: command(['systemctl','stop','onevps-singbox.service'])
        except Exception: warn('Service rollback did not complete; check systemctl status')
        fail('Change rolled back: '+str(exc))
    ok('Config verified; sing-box service active; changes applied')

def restore(path,data,mode,group=None):
    if data is None: path.unlink(missing_ok=True)
    else: write_secure(path,data,mode,group)

def check_dns(domain):
    try:
        records={i[4][0] for i in socket.getaddrinfo(domain,None)}
        log('DNS %s => %s' %(domain,', '.join(sorted(records))))
    except socket.gaierror: warn('DNS for %s not resolvable yet' %domain)

def cert_location_candidates(domain):
    # Prefer runtime Caddy environment; do not read arbitrary remote storage.
    root=pathlib.Path('/var/lib/caddy/.local/share/caddy')
    candidates=[root, pathlib.Path('/var/lib/caddy/caddy'),pathlib.Path('/root/.local/share/caddy')]
    if shutil.which('caddy'):
        try:
            adapted=command(['caddy','adapt','--config',str(caddyfile()),'--adapter','caddyfile']).stdout
            storage=json.loads(adapted).get('storage',{})
            if storage.get('module')=='file_system' and storage.get('root','').startswith('/'):
                candidates.insert(0,pathlib.Path(storage['root']))
        except Exception: pass
    # Add HOME/XDG_DATA_HOME from currently running caddy service.
    try:
        pid=int(command(['systemctl','show','-p','MainPID','--value','caddy']).stdout.strip())
        if pid>1:
            env=dict(item.split('=',1) for item in pathlib.Path('/proc/%s/environ'%pid).read_bytes().decode(errors='replace').split('\0') if '=' in item)
            if env.get('XDG_DATA_HOME','').startswith('/'):
                candidates.insert(0,pathlib.Path(env['XDG_DATA_HOME'])/'caddy')
            elif env.get('HOME','').startswith('/'):
                candidates.insert(0,pathlib.Path(env['HOME'])/'.local/share/caddy')
    except Exception: pass
    for base in candidates:
        root=base/'certificates'
        if not root.is_dir(): continue
        for issuer in root.iterdir():
            folder=issuer/domain
            yield folder/(domain+'.crt'),folder/(domain+'.key')

def deploy_cert(domain, *, restart=True):
    cert_dest,key_dest=map(pathlib.Path,tls_cert_paths(domain))
    for cert,key in cert_location_candidates(domain):
        if not validate_pem(str(cert),str(key),domain): continue
        data_cert=cert.read_bytes(); data_key=key.read_bytes()
        if cert_dest.exists() and key_dest.exists() and cert_dest.read_bytes()==data_cert and key_dest.read_bytes()==data_key:
            return True
        ensure_owner()
        old_c=cert_dest.read_bytes() if cert_dest.exists() else None
        old_k=key_dest.read_bytes() if key_dest.exists() else None
        cert_dest.parent.mkdir(parents=True,exist_ok=True)
        import grp
        os.chown(cert_dest.parent,0,grp.getgrnam(OWNER).gr_gid)
        os.chmod(cert_dest.parent,0o750)
        write_secure(cert_dest,data_cert,0o640,OWNER)
        write_secure(key_dest,data_key,0o640,OWNER)
        if not validate_pem(str(cert_dest),str(key_dest),domain):
            restore(cert_dest,old_c,0o640,OWNER);restore(key_dest,old_k,0o640,OWNER)
            fail('Certificate validation after deployment failed')
        if restart and service_active() and CONF.exists():
            try:
                command(['systemctl','restart','onevps-singbox.service'])
                if not service_active(): fail('Restart after certificate replacement failed')
            except Exception:
                restore(cert_dest,old_c,0o640,OWNER);restore(key_dest,old_k,0o640,OWNER)
                command(['systemctl','restart','onevps-singbox.service'],check=False)
                raise
        ok('Certificate deployed: '+domain)
        return True
    return False

def sync_certs(quiet=False):
    require_root()
    with locked():
        meta=read_meta(); domains=set(meta.get('domains',[]))
        domains.update(n['domain'] for n in meta['nodes'] if n['type']=='hysteria2')
        failed=[]
        for domain in sorted(domains):
            if not deploy_cert(domain): failed.append(domain)
        if failed and not quiet: warn('Certificate not ready for '+', '.join(failed))
        return 1 if failed else 0

def ensure_certificate(domain):
    check_dns(domain)
    with locked():
        meta=read_meta()
        if domain not in meta['domains']:
            new=copy.deepcopy(meta); new['domains'].append(domain)
            # Caddy site must be visible before issuance can happen; no running
            # service config is changed until a cert is available.
            ensure_owner();ensure_caddy()
            if domain in caddy_domains():
                fail('Domain already exists in Caddy configuration; refusing to override existing website: '+domain)
            old=CADDY_SNIPPET.read_bytes() if CADDY_SNIPPET.exists() else None
            ensure_caddy_sites(new)
            write_secure(CADDY_SNIPPET,render_caddy(new),0o644)
            if not caddy_check():
                restore(CADDY_SNIPPET,old,0o644)
                fail('Caddy failed to validate requested domain site')
            try: caddy_reload()
            except Exception:
                restore(CADDY_SNIPPET,old,0o644)
                caddy_reload()
                raise
            write_secure(META,jdump(new),0o640,OWNER)
        firewall_allow(80,'tcp');firewall_allow(443,'tcp')
        for _ in range(30):
            if deploy_cert(domain,restart=False): return
            time.sleep(2)
        fail('No valid ACME cert yet. Check DNS A/AAAA, ports 80/443 and journalctl -u caddy; rerun Certificates > Sync')

def choose_reality_target():
    requested=ask('Reality TLS 1.3 target (auto / hostname)','auto').lower()
    if requested!='auto':return validate_domain(requested)
    results=[]
    log('Probing candidate Reality TLS 1.3 targets (3 rounds per host)')
    for host in REALITY_TARGETS:
        timing=[]
        for attempt in range(3):
            start=time.monotonic()
            try:
                ctx=ssl.create_default_context()
                ctx.minimum_version=ssl.TLSVersion.TLSv1_3
                with socket.create_connection((host,443),timeout=3) as raw:
                    with ctx.wrap_socket(raw,server_hostname=host) as tls:
                        if tls.version()!='TLSv1.3':continue
                timing.append(time.monotonic()-start)
            except (OSError,ssl.SSLError):continue
        if len(timing)>=2:
            score=sorted(timing)[len(timing)//2]
            results.append((score,host))
    results.sort()
    if not results:
        fail('No reliable TLS 1.3 Reality target detected; rerun and manually choose an allowed hostname')
    for i,(latency,host) in enumerate(results[:6],1):
        print('%d) %-34s %.0f ms'%(i,host,latency*1000))
    selected=ask('Use fastest TLS 1.3 target?',results[0][1]).lower()
    return validate_domain(selected)

def gen_reality_keys():
    p=command([bin_path(),'generate','reality-keypair'])
    private=re.search(r'PrivateKey:\s*(\S+)',p.stdout,re.I)
    public=re.search(r'PublicKey:\s*(\S+)',p.stdout,re.I)
    if not private or not public:
        # Some sing-box builds print "PrivateKey" without stable capitalization/spaces.
        private=re.search(r'PrivateKey\s*[:=]\s*(\S+)',p.stdout,re.I)
        public=re.search(r'PublicKey\s*[:=]\s*(\S+)',p.stdout,re.I)
    if not private or not public: fail('Could not parse sing-box Reality keypair')
    return private.group(1),public.group(1)

def gen_uuid(): return str(uuid.uuid4())

def add_node(t):
    require_core()
    if t not in TYPES: fail('Unknown node type')
    meta=read_meta()
    name=name_prompt(t+'-'+secrets.token_hex(2))
    nid=new_id()
    node={'id':nid,'name':name,'type':t,'enabled':True,'users':[]}
    if t=='vless-reality':
        node['credential']=gen_uuid()
        preferred=443
        try: check_port(443,'tcp',meta)
        except OneVPSException: preferred=random_port(meta)
        node['port']=choose_port(meta,'tcp',preferred)
        print('Reality target options: '+', '.join(REALITY_TARGETS))
        node['target']=choose_reality_target()
        priv,pub=gen_reality_keys()
        node.update({'private_key':priv,'public_key':pub,'short_id':secrets.token_hex(8)})
        try:
            ctx=ssl.create_default_context()
            with socket.create_connection((node['target'],443),timeout=6) as s:
                with ctx.wrap_socket(s,server_hostname=node['target']) as ss:
                    if ss.version()!='TLSv1.3': warn('Reality target did not negotiate TLS 1.3')
        except Exception as exc: warn('Reality target probe unavailable: '+str(exc))
    elif t in WS_TYPES:
        node['credential']=gen_uuid() if t=='vmess-ws' else gen_secret()
        node['domain']=domain_prompt('DNS-only domain pointing at VPS')
        node['path']='/'+secrets.token_hex(12)
        node['port']=random_port(meta)
        ensure_certificate(node['domain'])
    elif t=='hysteria2':
        node['credential']=gen_secret()
        node['domain']=domain_prompt('DNS-only TLS domain')
        node['port']=choose_port(meta,'udp',24443)
        ensure_certificate(node['domain'])
    elif t=='snell5' or t=='snell6':
        node['credential']=gen_secret()
        node['port']=choose_port(meta,'tcp',random_port(meta))
        if t=='snell5': node['obfs_mode']=ask('Snell v5 HTTP obfs (none/http)','none')
        else: node['mode']=ask('Snell v6 shaping (default/unshaped)','default')
        if t=='snell5':
            warn('sing-box does not implement Snell v5 QUIC Proxy Mode; choose v6 for best Surge UDP compatibility')
        if t=='snell5' and node['obfs_mode'] not in ('none','http'): fail('Invalid obfs mode')
        if t=='snell6' and node['mode'] not in ('default','unshaped'): fail('Invalid shaping mode')
    else:
        node['credential']=base64.b64encode(secrets.token_bytes(16)).decode()
        node['port']=choose_port(meta,'both',random_port(meta,'both'))
    with locked():
        current=read_meta()
        check_port(node['port'],PORTS.get(t,'tcp'),current)
        current['nodes'].append(node)
        apply(current)
    if t not in WS_TYPES:
        firewall_allow(node['port'],'udp' if t=='hysteria2' else 'tcp')
        if t=='ss2022': firewall_allow(node['port'],'udp')
    link_output(node)

def link_output(n,u=None):
    u=u or {'name':'default','credential':n.get('default_user_key',n['credential'])}
    title=n['name'] if u['name']=='default' else n['name']+' / '+u['name']
    q=lambda v:urllib.parse.quote(str(v),safe='')
    t=n['type'];credential=u['credential'];port=n['port']
    if t=='vless-reality':
        host=pubip(); host='[%s]'%host if ':' in host and not host.startswith('[') else host
        link='vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&spx=%%2F&type=tcp#%s' % (
            credential,host,port,q(n['target']),q(n['public_key']),q(n['short_id']),q(title))
    elif t=='trojan-ws':
        link='trojan://%s@%s:443?security=tls&sni=%s&type=ws&host=%s&path=%s#%s' % (
            q(credential),n['domain'],q(n['domain']),q(n['domain']),q(n['path']),q(title))
    elif t=='vmess-ws':
        raw={'v':'2','ps':title,'add':n['domain'],'port':'443','id':credential,'aid':'0','scy':'auto','net':'ws',
             'type':'none','host':n['domain'],'path':n['path'],'tls':'tls','sni':n['domain']}
        link='vmess://'+base64.b64encode(json.dumps(raw,separators=(',',':')).encode()).decode()
    elif t=='hysteria2':
        link='hysteria2://%s@%s:%s/?sni=%s#%s' % (q(credential),n['domain'],port,q(n['domain']),q(title))
    elif t.startswith('snell'):
        host=pubip()
        if ':' in host and not host.startswith('['):host='['+host+']'
        version='6' if t=='snell6' else '5'
        name=re.sub(r'[^A-Za-z0-9_-]', '-', title)
        suffix=(', obfs=http' if n.get('obfs_mode')=='http' else '')
        suffix+=(', mode=unshaped' if n.get('mode')=='unshaped' else '')
        if n.get('default_user_key'):
            # The Surge policy manual does NOT document a `userkey=` parameter.
            # Provide an official sing-box client outbound instead of a fake Surge policy.
            outbound={'type':'snell','server':host.strip('[]'),'server_port':port,
                      'version':6 if t=='snell6' else 4,'psk':n['credential'],
                      'userkey':credential}
            if t=='snell5':outbound['obfs_mode']=n.get('obfs_mode','none')
            else:outbound['mode']=n.get('mode','default')
            link='sing-box client outbound (Surge multi-user userkey is undocumented):\n'+jdump(outbound)
        else:
            link='[Proxy]\n%s = snell, %s, %s, psk=%s, version=%s%s' % (name,host,port,n['credential'],version,suffix)
    else:
        host=pubip()
        if ':' in host and not host.startswith('['):host='['+host+']'
        # Shadowsocks AEAD-2022 (password is base64 16-byte key).
        actual_password=n['credential']+(':'+credential if n.get('default_user_key') else '')
        uri=base64.urlsafe_b64encode(('2022-blake3-aes-128-gcm:'+actual_password).encode()).decode().rstrip('=')
        link='ss://%s@%s:%s#%s' %(uri,host,port,q(title))
        surge_name=re.sub(r'[^A-Za-z0-9_-]', '-', title)
        link+='\n[Proxy]\n%s = ss, %s, %s, encrypt-method=2022-blake3-aes-128-gcm, password=%s, udp-relay=true' % (surge_name,host,port,actual_password)
    print('\n--- %s [%s] ---\n%s\n' %(title,t,link))
    return link

def show_nodes():
    for i,n in enumerate(read_meta()['nodes'],1):
        print('%d. %s | %s | %s:%s | %s | users:%s' % (
            i,n['name'],n['type'],n.get('domain',n.get('target','VPS')),n['port'],
            'ON' if n['enabled'] else 'OFF',1+len(n.get('users',[]))))

def select_node():
    meta=read_meta()
    if not meta['nodes']: fail('No nodes installed')
    show_nodes()
    answer=ask('Node number (0=back)','0')
    try: i=int(answer)-1
    except ValueError: return None
    if i<0 or i>=len(meta['nodes']): return None
    return meta['nodes'][i]['id']

def find_node(meta,nid):
    for node in meta['nodes']:
        if node['id']==nid: return node
    fail('Node was removed or ID is invalid')

def mutate(nid,modify):
    with locked():
        m=read_meta();n=find_node(m,nid)
        modify(n,m)
        apply(m)
        return copy.deepcopy(n)

def reset_credential(nid):
    previous=find_node(read_meta(),nid)
    if previous['type'] in ('snell5','snell6','ss2022') and previous.get('default_user_key'):
        if not confirm('Rotate shared server PSK/master key (ALL user links will change)?'):return
    def change(n,m):
        n['credential']=gen_uuid() if n['type'] in ('vless-reality','vmess-ws') else (
            base64.b64encode(secrets.token_bytes(16)).decode() if n['type']=='ss2022' else gen_secret())
    link_output(mutate(nid,change))

def change_port(nid):
    m=read_meta();n=find_node(m,nid)
    proto=PORTS.get(n['type'],'tcp')
    old=n['port'];new=choose_port(m,proto,old,nid)
    if new==old: return
    def modify(n,m):
        check_port(new,proto,m,nid);n['port']=new
    updated=mutate(nid,modify)
    if n['type'] not in WS_TYPES:
        if proto=='both':firewall_allow(new,'tcp');firewall_allow(new,'udp')
        else:firewall_allow(new,proto)
    link_output(updated)

def change_ws(nid,what):
    m=read_meta(); n=find_node(m,nid)
    if n['type'] not in WS_TYPES: fail('This operation is WS-only')
    if what=='path':
        new='/'+secrets.token_hex(12)
        mutate(nid,lambda n,m:n.update({'path':new}))
    else:
        new=domain_prompt('New DNS-only domain')
        ensure_certificate(new)
        mutate(nid,lambda n,m:n.update({'domain':new}))

def rotate_reality(nid,target=False):
    if target:
        dest=validate_domain(ask('New TLS target',REALITY_TARGETS[0]).lower())
        mutate(nid,lambda n,m:n.update({'target':dest}))
    else:
        priv,pub=gen_reality_keys()
        mutate(nid,lambda n,m:n.update({'private_key':priv,'public_key':pub,'short_id':secrets.token_hex(8)}))

def toggle(nid):
    mutate(nid,lambda n,m:n.update({'enabled':not n['enabled']}))

def delete_node(nid):
    with locked():
        m=read_meta(); n=find_node(m,nid)
        if not confirm('Delete node '+n['name']+' (cannot undo)?'):return
        m['nodes']=[x for x in m['nodes'] if x['id']!=nid]
        apply(m)

def new_user_secret(t):
    if t in ('vless-reality','vmess-ws'):return gen_uuid()
    if t=='ss2022':return base64.b64encode(secrets.token_bytes(16)).decode()
    return gen_secret()

def enter_multiuser(n):
    if n['type'] in ('snell5','snell6','ss2022') and not n.get('default_user_key'):
        n['default_user_key']=new_user_secret(n['type'])

def default_user(n):
    return {'id':'default','name':'default','credential':n.get('default_user_key',n['credential'])}

def user_menu(nid):
    while True:
        m=read_meta();n=find_node(m,nid)
        users=[default_user(n)]+n.get('users',[])
        print('\nUsers:')
        for i,u in enumerate(users): print('%d) %s [%s]'%(i+1,u['name'],u['id']))
        print('1) Add user  2) Delete user  3) Reset user credential  4) Show link  0) Back')
        choice=ask('Action','0')
        if choice=='0': return
        if choice=='1':
            name=name_prompt('user-'+secrets.token_hex(2))
            if n['type'] in ('snell5','snell6','ss2022') and not n.get('default_user_key'):
                warn('Multi-user mode changes the DEFAULT user link; Snell userkey is not documented by Surge. Use sing-box clients or separate Snell nodes for Surge.')
                if not confirm('Switch node to multi-user mode?'):continue
            def add(n,m):
                enter_multiuser(n)
                if any(u['name']==name for u in n.get('users',[])):fail('User name already exists')
                n.setdefault('users',[]).append({'id':'u'+secrets.token_hex(5),'name':name,
                    'credential':new_user_secret(n['type'])})
            mutate(nid,add)
        elif choice in ('2','3','4'):
            try: index=int(ask('User number'))-1;user=users[index];assert index>=0
            except (ValueError,IndexError,AssertionError):warn('Invalid user');continue
            if choice=='4': link_output(n,user)
            elif choice=='2':
                if user['id']=='default': warn('Cannot delete default user');continue
                if confirm('Delete user '+user['name']+'?'):
                    mutate(nid,lambda n,m:n.update({'users':[x for x in n['users'] if x['id']!=user['id']]}))
            else:
                if user['id']=='default':
                    if n.get('default_user_key'):
                        mutate(nid,lambda n,m:n.update({'default_user_key':new_user_secret(n['type'])}))
                    else:reset_credential(nid)
                else:
                    def reset(n,m):
                        next(x for x in n['users'] if x['id']==user['id'])['credential']=new_user_secret(n['type'])
                    mutate(nid,reset)
        else: warn('Invalid action')

def outbound_from_link(link):
    link=link.strip()
    if not link or any(ord(c)<33 for c in link): fail('Link contains invalid whitespace')
    url=urllib.parse.urlsplit(link)
    scheme=url.scheme.lower()
    if scheme not in ('ss','socks5','vless','vmess','snell'):fail('Supported outbound links: ss, socks5, vless, vmess, snell')
    if scheme=='vmess':
        raw=link[len('vmess://'):].split('#')[0]
        try:
            data=json.loads(base64.b64decode(raw+'='*((-len(raw))%4)))
            host=valid_host(data['add']);port=valid_port(data['port'])
            if str(data.get('aid',0))!='0' or data.get('tls')!='tls' or data.get('net') not in ('tcp','ws'):
                fail('VMess requires AEAD, TLS, and TCP/WS')
            result={'type':'vmess','server':host,'server_port':port,'uuid':str(uuid.UUID(data['id'])),
                    'security':data.get('scy','auto') or 'auto','alter_id':0,
                    'tls':{'enabled':True,'server_name':data.get('sni') or host}}
            if data['net']=='ws':
                result['transport']={'type':'ws','path':data.get('path') or '/',
                                     'headers':{'Host':data.get('host') or host}}
            return result
        except (KeyError,TypeError,ValueError) as e: fail('Invalid VMess link: '+str(e))
    try: host=url.hostname; port=valid_port(url.port);host=valid_host(host)
    except Exception: fail('Invalid outbound host/port')
    if url.scheme=='ss':
        auth=url.netloc.split('@')[0]
        try:
            if ':' in auth: raw=urllib.parse.unquote(auth)
            else: raw=base64.urlsafe_b64decode(auth+'='*((-len(auth))%4)).decode()
            method,pw=raw.split(':',1)
        except Exception: fail('Invalid Shadowsocks credentials')
        if method not in ('aes-128-gcm','aes-256-gcm','chacha20-ietf-poly1305',
                          '2022-blake3-aes-128-gcm','2022-blake3-aes-256-gcm'):
            fail('Unsupported Shadowsocks cipher')
        return {'type':'shadowsocks','server':host,'server_port':port,'method':method,'password':pw}
    if scheme=='socks5':
        out={'type':'socks','server':host,'server_port':port}
        if url.username:
            out.update({'username':urllib.parse.unquote(url.username),'password':urllib.parse.unquote(url.password or '')})
        return out
    q=urllib.parse.parse_qs(url.query,strict_parsing=True)
    single=lambda k,default=None: q[k][0] if k in q and len(q[k])==1 else default
    if scheme=='snell':
        version=int(single('version','6'))
        if version not in (4,5,6): fail('Only Snell v4/5/6 supported')
        out={'type':'snell','server':host,'server_port':port,'version':4 if version==5 else version,
             'psk':urllib.parse.unquote(url.username or '')}
        if not out['psk']: fail('Snell PSK required')
        if single('userkey'):out['userkey']=single('userkey')
        if version==6:out['mode']=single('mode','default')
        else:out['obfs_mode']=single('obfs','none')
        return out
    if scheme=='vless':
        try: identifier=str(uuid.UUID(urllib.parse.unquote(url.username or '')))
        except ValueError:fail('Invalid VLESS UUID')
        if single('security') not in ('tls','reality'):fail('Only TLS/Reality VLESS links supported')
        network=single('type','tcp')
        if network not in ('tcp','ws','grpc'):fail('Invalid VLESS transport')
        flow=single('flow','')
        if flow and (flow!='xtls-rprx-vision' or network!='tcp'):fail('Invalid Vision flow')
        tls={'enabled':True,'server_name':single('sni',host)}
        if single('security')=='reality':
            if not single('pbk'): fail('Reality public key required')
            tls['reality']={'enabled':True,'public_key':single('pbk'),'short_id':single('sid','')}
        if single('fp'):tls['utls']={'enabled':True,'fingerprint':single('fp')}
        out={'type':'vless','server':host,'server_port':port,'uuid':identifier,'tls':tls}
        if flow:out['flow']=flow
        if network=='ws':
            out['transport']={'type':'ws','path':single('path','/')}
            if single('host'):out['transport']['headers']={'Host':single('host')}
        elif network=='grpc':out['transport']={'type':'grpc','service_name':single('serviceName','')}
        return out
    fail('Unsupported link')

def apply_outbound_selection(n,scope,selected,value):
    """Match original OneVPS bulk/selected outbound override semantics."""
    if scope=='all':
        n.pop('default_outbound',None)
        for user in n.get('users',[]):user.pop('outbound',None)
        if value is None:n.pop('outbound',None)
        else:n['outbound']=copy.deepcopy(value)
        return
    available={'default'}|{u['id'] for u in n.get('users',[])}
    if scope!='selected' or not selected or len(selected)!=len(set(selected)) or not set(selected)<=available:
        fail('Invalid outbound user selection')
    if 'default' in selected:
        if value is None:n.pop('default_outbound',None)
        else:n['default_outbound']=copy.deepcopy(value)
    for u in n.get('users',[]):
        if u['id'] in selected:
            if value is None:u.pop('outbound',None)
            else:u['outbound']=copy.deepcopy(value)

def outbound_menu(nid):
    n=find_node(read_meta(),nid)
    users=[default_user(n)]+n.get('users',[])
    print('1) All users (overwrite individual overrides)')
    print('2) Selected users (multiple numbers, space separated)')
    selection=ask('Scope (1/2/0=back)','0')
    if selection=='0':return
    if selection not in ('1','2'):fail('Invalid scope')
    scope='all' if selection=='1' else 'selected'
    selected=[]
    if scope=='selected':
        for idx,u in enumerate(users,1):print('%d) %s [%s]'%(idx,u['name'],u['id']))
        ids=ask('User numbers, separated by spaces')
        if not re.fullmatch(r'[0-9]+(?: +[0-9]+)*',ids):fail('Invalid user selection')
        values=[int(x) for x in ids.split()]
        if len(values)!=len(set(values)) or any(x<1 or x>len(users) for x in values):
            fail('Invalid or duplicate user number')
        selected=[users[x-1]['id'] for x in values]
    print('1) Restore inherit (all users => direct default)  2) Explicit direct  3) Proxy link')
    action=ask('Outbound action (0=back)','0')
    if action=='0':return
    if action=='1':value=None
    elif action=='2':value={'type':'direct'}
    elif action=='3':value=outbound_from_link(ask('Proxy link'))
    else:fail('Invalid action')
    if not confirm('Apply outbound settings?'):return
    mutate(nid,lambda node,m:apply_outbound_selection(node,scope,selected,value))


def node_menu():
    while True:
        print('\n=== Nodes ===\n1) VLESS + REALITY + Vision\n2) Trojan + WS + Caddy\n3) VMess AEAD + WS + Caddy\n4) Hysteria2 + TLS (UDP)\n5) Snell v5 (Surge)\n6) Snell v6 (Surge)\n7) Shadowsocks 2022 (Surge)\n8) Manage nodes/users/outbound\n9) Show all links\n0) Back')
        choice=ask('Select','0')
        table={'1':'vless-reality','2':'trojan-ws','3':'vmess-ws','4':'hysteria2','5':'snell5','6':'snell6','7':'ss2022'}
        try:
            if choice in table:add_node(table[choice])
            elif choice=='8':manage_nodes()
            elif choice=='9':
                for n in read_meta()['nodes']:
                    link_output(n)
                    for u in n.get('users',[]):link_output(n,u)
            elif choice=='0':return
            else:warn('Invalid choice')
        except OneVPSException as e:warn(str(e))

def manage_nodes():
    nid=select_node()
    if not nid:return
    while True:
        try:n=find_node(read_meta(),nid)
        except OneVPSException:return
        print('\n=== '+n['name']+' ===')
        print('1) Change port  2) Reset default credential  3) Users  4) Outbound')
        print('5) Enable/disable  6) Delete node  7) Show links')
        if n['type']=='vless-reality':print('8) Rotate Reality keys  9) Change Reality target')
        elif n['type'] in WS_TYPES:print('8) Change WS domain  9) Rotate WS path  10) Rebuild Caddy routes')
        print('0) Back')
        choice=ask('Select','0')
        if choice=='0':return
        try:
            if choice=='1':change_port(nid)
            elif choice=='2':reset_credential(nid)
            elif choice=='3':user_menu(nid)
            elif choice=='4':outbound_menu(nid)
            elif choice=='5':toggle(nid)
            elif choice=='6':delete_node(nid);return
            elif choice=='7':
                link_output(n)
                for u in n.get('users',[]):link_output(n,u)
            elif choice=='8' and n['type']=='vless-reality':rotate_reality(nid)
            elif choice=='9' and n['type']=='vless-reality':rotate_reality(nid,True)
            elif choice=='8' and n['type'] in WS_TYPES:change_ws(nid,'domain')
            elif choice=='9' and n['type'] in WS_TYPES:change_ws(nid,'path')
            elif choice=='10' and n['type'] in WS_TYPES:
                with locked():apply(read_meta())
            else:warn('Invalid choice')
        except OneVPSException as e:warn(str(e))

def certificate_menu():
    while True:
        print('\n=== Certificates ===\n1) Apply for TLS certificate\n2) List domains / expiration\n3) Sync renewals now\n4) Caddy & cert timer status\n0) Back')
        c=ask('Select','0')
        try:
            if c=='0':return
            elif c=='1':ensure_certificate(domain_prompt())
            elif c=='2':
                for domain in read_meta().get('domains',[]):
                    cert,_=tls_cert_paths(domain)
                    if pathlib.Path(cert).exists():
                        result=command(['openssl','x509','-in',cert,'-noout','-enddate'],check=False).stdout.strip()
                        print(domain, result)
                    else:print(domain, '(pending)')
            elif c=='3':sync_certs()
            elif c=='4':
                command(['systemctl','--no-pager','status','caddy','onevps-singbox-certs.timer'],check=False,capture=False)
            else:warn('Invalid choice')
        except OneVPSException as e:warn(str(e))

def service_menu():
    while True:
        print('\n=== Service / network ===\n1) Restart and recheck sing-box\n2) Enable BBR\n3) Safe TCP tuning\n4) Show service status / logs\n0) Back')
        c=ask('Select','0')
        try:
            if c=='0':return
            elif c=='1':
                with locked(): apply(read_meta())
            elif c=='2':enable_bbr()
            elif c=='3':tune_tcp()
            elif c=='4':
                command(['systemctl','--no-pager','status','onevps-singbox.service'],check=False,capture=False)
                command(['journalctl','-u','onevps-singbox.service','-n','35','--no-pager'],check=False,capture=False)
            else:warn('Invalid choice')
        except OneVPSException as e:warn(str(e))

def ensure_runtime_fq_qdisc():
    """Original OneVPS behavior: change ONLY a simple pfifo_fast root."""
    if not shutil.which('ip') or not shutil.which('tc'):
        warn('ip/tc tools absent; default qdisc is configured but running interface unchanged')
        return
    route=command(['ip','route','get','1.1.1.1'],check=False)
    m=re.search(r'\bdev\s+(\S+)',route.stdout)
    if route.returncode or not m:
        warn('Cannot determine default interface; preserving current qdisc')
        return
    iface=m.group(1)
    q=command(['tc','qdisc','show','dev',iface],check=False)
    if q.returncode:return
    if re.search(r'^qdisc fq \S+ root',q.stdout,re.M):return
    if len(q.stdout.strip().splitlines())!=1 or not re.match(r'^qdisc pfifo_fast 0: root\b',q.stdout.strip()):
        warn('Preserved existing multiqueue/custom qdisc on '+iface)
        return
    filters=command(['tc','filter','show','dev',iface,'root'],check=False)
    if filters.returncode or filters.stdout.strip():
        warn('Preserved interface with unknown/active TC filters: '+iface)
        return
    change=command(['tc','qdisc','replace','dev',iface,'root','fq'],check=False)
    if change.returncode:warn('Could not change root qdisc to fq on '+iface)

def enable_bbr():
    if 'bbr' not in sysctl('net.ipv4.tcp_available_congestion_control').split():
        if shutil.which('modprobe'): command(['modprobe','tcp_bbr'],check=False)
    if 'bbr' not in sysctl('net.ipv4.tcp_available_congestion_control').split():fail('Kernel has no BBR support')
    if not confirm('Enable fq + BBR globally?'):return
    path=pathlib.Path('/etc/sysctl.d/99-onevps-singbox-bbr.conf')
    write_secure(path,'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n',0o644)
    command(['sysctl','-p',path],capture=False)
    ensure_runtime_fq_qdisc()
    ok('TCP congestion: %s / qdisc: %s'%(sysctl('net.ipv4.tcp_congestion_control'),sysctl('net.core.default_qdisc')))

def tune_tcp():
    if not confirm('Apply conservative TCP buffer/backlog tuning globally?'):return
    data=[]
    for key in ('tcp_rmem','tcp_wmem'):
        triplet=[int(x) for x in sysctl('net.ipv4.'+key).split()]
        if len(triplet)!=3 or not (0<triplet[0]<=triplet[1]<=triplet[2] and triplet[1]<=67108864):fail('Invalid '+key)
        data.append('net.ipv4.%s=%s %s 67108864'%(key,triplet[0],triplet[1]))
    conf='\n'.join(['net.core.rmem_max=67108864','net.core.wmem_max=67108864']+data+[
        'net.ipv4.tcp_fastopen=3','net.ipv4.tcp_mtu_probing=1',
        'net.ipv4.ip_local_port_range=10000 65535',
        'net.core.somaxconn=8192','net.ipv4.tcp_max_syn_backlog=8192',
        'net.ipv4.tcp_notsent_lowat=131072'])+'\n'
    path=pathlib.Path('/etc/sysctl.d/99-onevps-singbox-tune.conf')
    write_secure(path,conf,0o644)
    command(['sysctl','-p',path],capture=False)
    ok('TCP tuning applied')

# Independent optional Realm forwarding — retains the original script's relay feature.
def realm_endpoints():
    path=REALM_BASE/'config.json'
    if path.is_file():return json.loads(path.read_text())
    return {'log':{'level':'warn'},'endpoints':[]}

def install_realm():
    if REALM_BINARY.is_file() and REALM_UNIT.is_file():return
    if REALM_BASE.exists() or REALM_BINARY.exists() or REALM_UNIT.exists():fail('Existing/unmanaged Realm installation; refusing overwrite')
    arch={'x86_64':'x86_64-unknown-linux-musl','aarch64':'aarch64-unknown-linux-musl','armv7l':'armv7-unknown-linux-musleabihf'}.get(os.uname().machine)
    if not arch:fail('No official Realm build for this architecture')
    version='v2.9.6'
    asset='realm-'+arch+'.tar.gz'
    api=json.loads(request('https://api.github.com/repos/zhboner/realm/releases/tags/'+version))
    result=next((x for x in api['assets'] if x['name']==asset),None)
    if not result or not re.fullmatch(r'sha256:[0-9a-f]{64}',result.get('digest','')):fail('No trustworthy Realm asset hash')
    expected='https://github.com/zhboner/realm/releases/download/'+version+'/'+asset
    if result['browser_download_url']!=expected:fail('Unexpected Realm release URL')
    data=request(expected,timeout=90)
    if hashlib.sha256(data).hexdigest()!=result['digest'][7:]:fail('Realm download checksum mismatch')
    with tempfile.TemporaryDirectory() as tmp:
        archive=pathlib.Path(tmp)/asset;archive.write_bytes(data)
        with tarfile.open(archive,'r:gz') as tar:
            member=next((x for x in tar if x.name=='realm' and x.isfile()),None)
            if member is None:fail('Realm archive has no executable')
            path=pathlib.Path(tmp)/'realm'
            path.write_bytes(tar.extractfile(member).read());os.chmod(path,0o755)
            command([path,'--version'])
            write_secure(REALM_BINARY,path.read_bytes(),0o755)
    REALM_BASE.mkdir(parents=True,exist_ok=True)
    os.chmod(REALM_BASE,0o755)  # DynamicUser needs search permission (umask 077).
    write_secure(REALM_BASE/'config.json',jdump({'log':{'level':'warn'},'endpoints':[]}),0o644)
    write_secure(REALM_UNIT,'''# OneVPS sing-box managed realm
[Unit]
Description=OneVPS Realm TCP/UDP relay
After=network-online.target
Wants=network-online.target
[Service]
DynamicUser=true
ExecStart=%s -c %s
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
[Install]
WantedBy=multi-user.target
'''%(REALM_BINARY,REALM_BASE/'config.json'),0o644)
    command(['systemctl','daemon-reload'])

def realm_modify(candidate):
    os.chmod(REALM_BASE,0o755)  # Repair existing pre-fix installations, too.
    old=(REALM_BASE/'config.json').read_bytes()
    was_active=service_active('onevps-sb-realm.service')
    write_secure(REALM_BASE/'config.json',jdump(candidate),0o644)
    try:
        if candidate['endpoints']:
            command(['systemctl','enable','onevps-sb-realm'])
            command(['systemctl','restart','onevps-sb-realm'])
            if not service_active('onevps-sb-realm.service'):fail('Realm service did not start')
            if shutil.which('ss'):
                for _ in range(8):
                    tcp=listening_ports('tcp');udp=listening_ports('udp')
                    if all(valid_port(x['listen'].rsplit(':',1)[1]) in (tcp or set()) and
                       (not x.get('network',{}).get('use_udp') or valid_port(x['listen'].rsplit(':',1)[1]) in (udp or set()))
                       for x in candidate['endpoints']):break
                    time.sleep(0.4)
                else:fail('Realm is active but its configured TCP/UDP listener is missing')
        else:
            command(['systemctl','stop','onevps-sb-realm'],check=False)
            command(['systemctl','disable','onevps-sb-realm'],check=False)
    except Exception:
        write_secure(REALM_BASE/'config.json',old,0o644)
        if was_active: command(['systemctl','restart','onevps-sb-realm'],check=False)
        else:command(['systemctl','stop','onevps-sb-realm'],check=False)
        raise

def realm_menu():
    while True:
        print('\n=== Realm relay ===\n1) Install / add TCP(/UDP) relay\n2) List / status\n3) Delete relay\n4) Restart Realm\n5) Uninstall Realm\n0) Back')
        c=ask('Select','0')
        try:
            if c=='0':return
            if c=='1':
                port=valid_port(ask('Local port'))
                remote=valid_host(ask('Destination host/IP'))
                dstport=valid_port(ask('Destination port'))
                mode=ask('Transport tcp or both (TCP+UDP)','tcp')
                if mode not in ('tcp','both'):fail('Invalid relay mode')
                if socket_conflict(port,'tcp') or (mode=='both' and socket_conflict(port,'udp')):fail('Listen port occupied')
                if not confirm('Create unauthenticated relay on all interfaces?'):continue
                install_realm()
                m=realm_endpoints()
                if any(x['listen'].endswith(':'+str(port)) for x in m['endpoints']):fail('Duplicate relay port')
                remote='[%s]'%remote if ':' in remote else remote
                m['endpoints'].append({'listen':'0.0.0.0:'+str(port),'remote':remote+':'+str(dstport),
                                       'network':{'no_tcp':False,'use_udp':mode=='both'}})
                realm_modify(m)
                firewall_allow(port,'tcp')
                if mode=='both':firewall_allow(port,'udp')
            elif c=='2':
                for i,x in enumerate(realm_endpoints()['endpoints'],1):print(i,x['listen'],'->',x['remote'])
                if REALM_UNIT.exists():command(['systemctl','--no-pager','status','onevps-sb-realm'],check=False,capture=False)
            elif c=='3':
                if not REALM_UNIT.is_file():fail('Realm not installed')
                m=realm_endpoints()
                for i,x in enumerate(m['endpoints'],1):print(i,x['listen'],'->',x['remote'])
                idx=int(ask('Delete number'))-1
                if idx<0 or idx>=len(m['endpoints']):fail('Invalid index')
                if confirm('Delete relay?'):
                    del m['endpoints'][idx];realm_modify(m)
            elif c=='4':
                command(['systemctl','restart','onevps-sb-realm'])
            elif c=='5':
                if not REALM_UNIT.exists() or 'OneVPS sing-box managed realm' not in REALM_UNIT.read_text():fail('Not owned by OneVPS')
                if confirm('Uninstall managed Realm and its relay config?'):
                    command(['systemctl','disable','--now','onevps-sb-realm'],check=False)
                    REALM_UNIT.unlink();REALM_BINARY.unlink();shutil.rmtree(REALM_BASE)
                    command(['systemctl','daemon-reload'])
            else:warn('Invalid choice')
        except (OneVPSException, ValueError) as e:warn(str(e))

def update_self():
    current=pathlib.Path(os.environ.get('ONEVPS_SCRIPT_PATH',''))
    if not current.is_file() or current.is_symlink():
        fail('Launch from a saved script file to update it (not a pipe)')
    targets=[current]
    if SCRIPT_INSTALLED!=current and (SCRIPT_INSTALLED.exists() or SCRIPT_INSTALLED.is_symlink()):
        if not SCRIPT_INSTALLED.is_file() or SCRIPT_INSTALLED.is_symlink():
            fail('Installed maintenance script is not a regular file; refusing update')
        targets.append(SCRIPT_INSTALLED)
    with urllib.request.urlopen(UPDATE_URL,timeout=35) as response:
        if response.geturl()!=UPDATE_URL:fail('Repository download redirected; refusing update')
        content=response.read()
    if not content.startswith(b'#!/usr/bin/env bash') or b'PYTHON_APP' not in content:fail('Not a valid OneVPS script')
    with tempfile.TemporaryDirectory() as tmp:
        path=pathlib.Path(tmp)/'update.sh';path.write_bytes(content)
        command(['bash','-n',str(path)])
    print('SHA256: '+hashlib.sha256(content).hexdigest())
    if not confirm('Install this downloaded update?'):return
    original=[(target,target.read_bytes(),target.stat().st_mode&0o777) for target in targets]
    changed=[]
    try:
        for target,_,mode in original:
            changed.append(target)
            write_secure(target,content,mode)
    except BaseException as exc:
        rollback_errors=[]
        for target,old,mode in reversed(original[:len(changed)]):
            try:write_secure(target,old,mode)
            except Exception as rollback_exc:rollback_errors.append('%s: %s'%(target,rollback_exc))
        if rollback_errors:fail('Update failed; manual recovery required: '+', '.join(rollback_errors))
        fail('Update failed; previous scripts restored: '+str(exc))
    ok('Updated '+', '.join(map(str,targets))+'; restart this menu to use the new version')

def uninstall():
    if not confirm('Remove managed sing-box nodes, config and service? (Caddy/Realm untouched)'):return
    remove_package=confirm('Also remove the sing-box core package (only if no other service needs it)?')
    with locked():
        command(['systemctl','disable','--now','onevps-singbox'],check=False)
        command(['systemctl','disable','--now','onevps-singbox-certs.timer'],check=False)
        for p in (SERVICE,TIMER_SERVICE,TIMER): p.unlink(missing_ok=True)
        # Preserve Caddy and other sites; remove only managed import line.
        cf=caddyfile()
        if cf.is_file():
            line='import '+str(CADDY_SNIPPET)
            new='\n'.join(x for x in cf.read_text().splitlines() if x.strip()!=line)+'\n'
            write_secure(cf,new,0o644)
        if BASE.is_dir():shutil.rmtree(BASE)
        CADDY_SNIPPET.unlink(missing_ok=True)
        command(['systemctl','daemon-reload'])
        if shutil.which('caddy') and caddy_check():caddy_reload()
        if remove_package:
            # Do not break an independently running sing-box.service.
            if service_active('sing-box.service'):
                warn('sing-box.service belongs to another installation and is active; core retained')
            elif shutil.which('apt-get') and shell_status(['dpkg-query','-W','sing-box']):
                command(['apt-get','remove','-y','sing-box'],capture=False,timeout=240)
            elif (shutil.which('dnf') or shutil.which('yum')) and shell_status(['rpm','-q','sing-box']):
                command([(shutil.which('dnf') or shutil.which('yum')),'remove','-y','sing-box'],capture=False,timeout=240)
            elif shutil.which('zypper') and shell_status(['rpm','-q','sing-box']):
                command(['zypper','--non-interactive','remove','sing-box'],capture=False,timeout=240)
            else:
                warn('Core was not installed via a recognized sing-box package; left intact for safety')
        ok('Managed components removed; Caddy, Realm and sysctl retained')

def diagnostics():
    require_root()
    v=version_tuple()
    print('sing-box:',('.'.join(map(str,v)) if v else 'not installed'))
    print('Service:', 'active' if service_active() else 'inactive')
    print('Caddy:', 'active' if service_active('caddy.service') else 'inactive')
    m=read_meta();print('Nodes:',len(m['nodes']))
    if v and v>=MIN_VERSION:
        with locked():
            check_core(render_config(m))
            ok('sing-box config check passed')
    if CONF.is_file():
        cmd=command(['systemctl','show','-p','MainPID','--value','onevps-singbox.service'],check=False)
        pid=cmd.stdout.strip()
        print('MainPID:',pid)
        if service_active() and shutil.which('ss'):
            command(['ss','-lntup'],check=False,capture=False)
    # Check actual sockets by listening port and protocol, not just systemd status.
    if service_active() and shutil.which('ss'):
        sockets={}
        for proto,args in (('tcp',['ss','-H','-lnt']),('udp',['ss','-H','-lnu'])):
            result=command(args,check=False)
            found=set()
            for line in result.stdout.splitlines():
                columns=line.split()
                if len(columns)<5:continue
                endpoint=columns[3]
                try:found.add(int(endpoint.rsplit(':',1)[1]))
                except (ValueError,IndexError):pass
            sockets[proto]=found
        for node in m['nodes']:
            if not node['enabled']:continue
            for proto in (('udp',) if node['type']=='hysteria2' else ('tcp','udp') if node['type']=='ss2022' else ('tcp',)):
                if node['port'] not in sockets.get(proto,set()):
                    warn('Missing expected %s socket: %s:%s' %(proto,node['name'],node['port']))
    print('Note: cloud firewall, DNS, actual remote client traffic require verification from your VPS/network.')

def acceptance():
    """Production *VPS-local* checks; cannot replace a remote Surge connectivity test."""
    import http.client
    require_root()
    problems=[]
    def mark(name,yes,why=''):
        label='PASS' if yes else 'FAIL'
        print('[%s] %s%s'%(label,name,(': '+why) if why else ''))
        if not yes:problems.append(name)
    m=read_meta()
    mark('At least one enabled proxy node',any(n.get('enabled') for n in m['nodes']))
    version=version_tuple()
    mark('sing-box >= 1.14',bool(version and version>=MIN_VERSION))
    if version and version>=MIN_VERSION:
        try:check_core(render_config(m));mark('Official sing-box check',True)
        except OneVPSException:mark('Official sing-box check',False)
    mark('sing-box systemd service active',service_active())
    if m['nodes'] and not shutil.which('ss'):
        mark('ss socket inspection tool installed',False)
    listeners={}
    if shutil.which('ss'):
        for protocol,args in [('tcp',['ss','-H','-lnt']),('udp',['ss','-H','-lnu'])]:
            r=command(args,check=False)
            actual=set()
            if r.returncode==0:
                for line in r.stdout.splitlines():
                    words=line.split()
                    if len(words)<5:continue
                    try:actual.add(int(words[3].rsplit(':',1)[1]))
                    except (IndexError,ValueError):continue
            listeners[protocol]=actual
        for n in m['nodes']:
            if not n['enabled']:continue
            protocols=('udp',) if n['type']=='hysteria2' else (('tcp','udp') if n['type']=='ss2022' else ('tcp',))
            for proto in protocols:
                mark('%s %s/%s listener' %(n['name'],n['port'],proto),n['port'] in listeners[proto])
    domains=set(m.get('domains',[]))
    domains.update(n['domain'] for n in m['nodes'] if n['enabled'] and n['type'] in (*WS_TYPES,'hysteria2'))
    if domains:
        mark('Caddy active',service_active('caddy.service'))
        mark('Caddyfile validation',caddy_check())
        for domain in sorted(domains):
            path=SITE_ROOT/domain/'index.html'
            mark(domain+' custom HTML file',path.is_file())
            # Browser-equivalent TLS GET to loopback, retaining original Host/SNI.
            try:
                ctx=ssl.create_default_context()
                conn=http.client.HTTPSConnection(domain,443,context=ctx,timeout=9)
                conn._create_connection=lambda address,timeout=None,source_address=None: socket.create_connection(('127.0.0.1',443),timeout=timeout,source_address=source_address)
                conn.request('GET','/__onevps_403_acceptance_'+secrets.token_hex(8),headers={'Accept-Encoding':'identity'})
                response=conn.getresponse()
                body=response.read(2*1024*1024)
                mark(domain+' HTTPS 403 status + exact file body',
                     response.status==403 and path.is_file() and body==path.read_bytes())
                conn.close()
            except Exception as exc:
                mark(domain+' HTTPS 403 status + exact file body',False,str(exc)[:160])
        for n in m['nodes']:
            if n['enabled'] and n['type']=='hysteria2':
                cert,key=tls_cert_paths(n['domain'])
                mark(n['name']+' Hysteria2 certificate',validate_pem(cert,key,n['domain']))
    realm_cfg=REALM_BASE/'config.json'
    if realm_cfg.is_file():
        try:
            endpoints=realm_endpoints()['endpoints']
            if endpoints:
                mark('Realm service active',service_active('onevps-sb-realm.service'))
                mark('Realm config directory traversable',bool(REALM_BASE.stat().st_mode&0o005))
                for ep in endpoints:
                    port=valid_port(ep['listen'].rsplit(':',1)[1])
                    if listeners:
                        mark('Realm TCP %s listening'%port,port in listeners['tcp'])
                        if ep.get('network',{}).get('use_udp'):
                            mark('Realm UDP %s listening'%port,port in listeners['udp'])
        except Exception as exc:mark('Realm config parse',False,str(exc)[:120])
    print('\nExternal checks still required: cloud security-group access, public DNS, remote Surge/client handshake, UDP/QUIC traffic, and real ACME renewal.')
    if problems:
        warn('VPS-local acceptance failed: %d check(s)'%len(problems))
        return 1
    ok('VPS-local acceptance passed (external client acceptance NOT confirmed)')
    return 0

def main_menu():
    require_root()
    while True:
        print('\n╔════════════════════════════════════════╗\n║     OneVPS · sing-box / Surge Snell    ║\n╚════════════════════════════════════════╝')
        ver=version_tuple()
        print('Core:',('.'.join(map(str,ver)) if ver else 'not installed'),
              '| service:',('active' if service_active() else 'inactive'),
              '| nodes:',len(read_meta()['nodes']))
        print('1) Install / update sing-box (stable >=1.14)\n2) Nodes / users / outbound / share links\n3) Caddy TLS certificate management\n4) Realm relay\n5) Service / BBR / TCP tuning\n6) Update script\n7) Diagnostics\n8) VPS-local acceptance checks\n9) Uninstall managed sing-box\n0) Exit')
        try:
            c=ask('Select','0')
            if c=='0':return
            elif c=='1':install_core()
            elif c=='2':node_menu()
            elif c=='3':certificate_menu()
            elif c=='4':realm_menu()
            elif c=='5':service_menu()
            elif c=='6':update_self()
            elif c=='7':diagnostics()
            elif c=='8':acceptance()
            elif c=='9':uninstall()
            else:warn('Invalid choice')
        except (OneVPSException, urllib.error.URLError, PermissionError, OSError, json.JSONDecodeError, KeyboardInterrupt) as e:
            warn(str(e))

def _selftest():
    # Offline smoke tests. No internet, root access, or file mutations required.
    import unittest
    class Smoke(unittest.TestCase):
        def base(self,t):
            obj={'id':'0123456789','name':'test','type':t,'port':18888,'enabled':True,
                 'users':[],'credential':gen_uuid() if t in ('vless-reality','vmess-ws') else gen_secret()}
            if t=='vless-reality':obj.update({'target':'www.cloudflare.com','private_key':'priv','public_key':'pub','short_id':'0123456789abcdef'})
            if t in WS_TYPES:obj.update({'domain':'example.org','path':'/abcdefgh12345'})
            if t=='hysteria2':obj['domain']='example.org'
            if t=='ss2022':obj['credential']=base64.b64encode(secrets.token_bytes(16)).decode()
            return obj
        def test_update_self_replaces_both_scripts_or_restores_them(self):
            from unittest.mock import patch
            class Download:
                def __init__(self,data,url=UPDATE_URL):self.data=data;self.url=url
                def __enter__(self):return self
                def __exit__(self,*args):pass
                def geturl(self):return self.url
                def read(self):return self.data
            new=b"#!/usr/bin/env bash\nexec python3 /dev/fd/3 3<<'PYTHON_APP'\nprint('new')\nPYTHON_APP\n"
            with tempfile.TemporaryDirectory() as td:
                d=pathlib.Path(td);current=d/'current.sh';installed=d/'installed.sh'
                old_current=b'old current';old_installed=b'old installed'
                def reset():
                    current.write_bytes(old_current);installed.write_bytes(old_installed)
                    current.chmod(0o700);installed.chmod(0o755)
                reset()
                with patch.dict(os.environ,{'ONEVPS_SCRIPT_PATH':str(current)}),patch.dict(globals(),{'SCRIPT_INSTALLED':installed}),patch.object(urllib.request,'urlopen',return_value=Download(new)),patch.dict(globals(),{'confirm':lambda *a:True}):
                    update_self()
                    self.assertEqual(current.read_bytes(),new)
                    self.assertEqual(installed.read_bytes(),new)
                    self.assertEqual(current.stat().st_mode&0o777,0o700)
                    self.assertEqual(installed.stat().st_mode&0o777,0o755)
                    reset()
                    with patch.dict(globals(),{'confirm':lambda *a:False}):update_self()
                    self.assertEqual((current.read_bytes(),installed.read_bytes()),(old_current,old_installed))
                    real_write=write_secure
                    def fail_second(path,data,mode):
                        if path==installed and data==new:raise OSError('simulated write failure')
                        return real_write(path,data,mode)
                    with patch.dict(globals(),{'write_secure':fail_second}):
                        with self.assertRaisesRegex(OneVPSException,'previous scripts restored'):update_self()
                    self.assertEqual((current.read_bytes(),installed.read_bytes()),(old_current,old_installed))
                    with patch.object(urllib.request,'urlopen',return_value=Download(new,'http://example.org/script')):
                        with self.assertRaisesRegex(OneVPSException,'redirected'):update_self()
                    with patch.object(urllib.request,'urlopen',return_value=Download(b'#!/usr/bin/env bash\n# PYTHON_APP\nif\n')):
                        with self.assertRaises(OneVPSException):update_self()
                    with patch.object(urllib.request,'urlopen',side_effect=urllib.error.URLError('offline')):
                        with self.assertRaises(urllib.error.URLError):update_self()
                    self.assertEqual((current.read_bytes(),installed.read_bytes()),(old_current,old_installed))
                installed.unlink()
                with patch.dict(os.environ,{'ONEVPS_SCRIPT_PATH':str(current)}),patch.dict(globals(),{'SCRIPT_INSTALLED':installed,'confirm':lambda *a:True}),patch.object(urllib.request,'urlopen',return_value=Download(new)):
                    update_self()
                self.assertEqual(current.read_bytes(),new)
                self.assertFalse(installed.exists())
                reset()
                with patch.dict(os.environ,{'ONEVPS_SCRIPT_PATH':str(current)}),patch.dict(globals(),{'SCRIPT_INSTALLED':current,'confirm':lambda *a:True}),patch.object(urllib.request,'urlopen',return_value=Download(new)):
                    update_self()
                self.assertEqual(current.read_bytes(),new)
                with patch.dict(os.environ,{'ONEVPS_SCRIPT_PATH':'/dev/fd/999999'}):
                    with self.assertRaisesRegex(OneVPSException,'saved script file'):update_self()
        def test_inbounds(self):
            for t in ('vless-reality','trojan-ws','vmess-ws','snell5','snell6','ss2022'):
                with self.subTest(t=t):
                    obj=render_config({'nodes':[self.base(t)],'domains':[]})
                    self.assertEqual(len(obj['inbounds']),1)
                    self.assertEqual(obj['inbounds'][0]['tag'],'in-0123456789')
        def test_udp_and_collisions(self):
            a=self.base('ss2022')
            b=self.base('hysteria2')
            b['id']='abcdef1234'
            # UDP 18888 must be reserved by SS2022.
            with self.assertRaises(OneVPSException):
                render_config({'nodes':[a,b],'domains':[]})
            with self.assertRaises(OneVPSException):
                check_port(18888,'udp',{'nodes':[a]})
        def test_default_user_route(self):
            n=self.base('trojan-ws')
            n['default_outbound']={'type':'direct'}
            n['outbound']={'type':'socks','server':'example.org','server_port':1080}
            r=render_config({'nodes':[n],'domains':[]})['route']['rules']
            self.assertEqual(r[-2]['auth_user'],['default'])
            self.assertEqual(r[-2]['outbound'],'direct')
            self.assertNotIn('auth_user',r[-1])
        def test_caddy(self):
            n=self.base('trojan-ws')
            s=render_caddy({'nodes':[n],'domains':[]})
            self.assertIn('reverse_proxy 127.0.0.1:18888',s)
        def test_routes(self):
            n=self.base('vless-reality')
            n['outbound']={'type':'direct'}
            n['users']=[{'id':'u001','name':'guest','credential':gen_uuid(),'outbound':{'type':'socks','server':'127.0.0.1','server_port':1080}}]
            config=render_config({'nodes':[n],'domains':[]})
            self.assertEqual(config['route']['rules'][-2]['auth_user'],['u001'])
            self.assertEqual(config['route']['rules'][-1]['outbound'],'direct')
        def test_outbound(self):
            self.assertEqual(outbound_from_link('socks5://user:pass@127.0.0.1:1080')['type'],'socks')
            self.assertEqual(outbound_from_link('vless://'+gen_uuid()+'@example.com:443?security=tls&type=tcp')['type'],'vless')
        def test_tls_config(self):
            n=self.base('hysteria2')
            # Generates a temporary matching certificate, not a public ACME cert.
            with tempfile.TemporaryDirectory() as temp:
                cert=str(pathlib.Path(temp)/'cert.pem')
                key=str(pathlib.Path(temp)/'key.pem')
                command(['openssl','req','-x509','-newkey','rsa:2048','-nodes',
                         '-keyout',key,'-out',cert,'-days','1','-subj','/CN=example.org',
                         '-addext','subjectAltName=DNS:example.org'])
                global tls_cert_paths
                old=tls_cert_paths; tls_cert_paths=lambda domain:(cert,key)
                try:
                    generated=render_config({'nodes':[n],'domains':[]})
                    self.assertEqual(generated['inbounds'][0]['type'],'hysteria2')
                finally:tls_cert_paths=old
        def test_links(self):
            n=self.base('snell6')
            # public IP request overridden to eliminate internet requests
            global pubip
            old=pubip;pubip=lambda:'192.0.2.1'
            try:self.assertIn('version=6',link_output(n))
            finally:pubip=old
        def test_original_403_exact_and_filesystem_access(self):
            global SITE_ROOT
            previous=SITE_ROOT
            try:
                with tempfile.TemporaryDirectory() as td:
                    SITE_ROOT=pathlib.Path(td)/'onevps'/'sites'
                    ensure_site_content('example.org')
                    path=SITE_ROOT/'example.org'/'index.html'
                    self.assertEqual(path.read_bytes(),ORIGINAL_403_HTML.encode())
                    self.assertEqual(path.stat().st_mode&0o777,0o644)
                    for item in (SITE_ROOT.parent,SITE_ROOT,path.parent):
                        self.assertEqual(item.stat().st_mode&0o777,0o755)
                    path.write_text('USER CUSTOM INDEX')
                    ensure_site_content('example.org')
                    self.assertEqual(path.read_text(),'USER CUSTOM INDEX')
            finally:SITE_ROOT=previous
        def test_caddy_403_render_is_not_plain_text(self):
            n=self.base('vmess-ws')
            s=render_caddy({'nodes':[n],'domains':[]})
            self.assertIn('error 403',s)
            self.assertIn('handle_errors {',s)
            self.assertIn('rewrite * /index.html',s)
            self.assertIn('file_server',s)
            self.assertIn('root * /var/lib/onevps/sites/example.org',s)
            self.assertNotIn('respond "Forbidden"',s)
        def test_surge_ss2022_multiuser(self):
            n=self.base('ss2022')
            enter_multiuser(n)
            key=base64.b64encode(secrets.token_bytes(16)).decode()
            n['users']=[{'id':'uabcdef1234','name':'alice','credential':key,
                         'outbound':{'type':'socks','server':'example.org','server_port':1080}}]
            cfg=render_config({'nodes':[n],'domains':[]})
            ib=cfg['inbounds'][0]
            self.assertEqual(ib['password'],n['credential'])
            self.assertEqual(len(ib['users']),2)
            self.assertEqual(ib['users'][0]['name'],'default')
            self.assertEqual(cfg['route']['rules'][-1]['auth_user'],['uabcdef1234'])
            global pubip
            old=pubip;pubip=lambda:'192.0.2.1'
            try:
                link=link_output(n,n['users'][0]);self.assertIn(n['credential']+':'+key,link)
            finally:pubip=old
        def test_snell6_multiuser_no_false_surge_link(self):
            n=self.base('snell6')
            enter_multiuser(n)
            n['users']=[{'id':'uabcdef1234','name':'alice','credential':gen_secret(),
                         'outbound':{'type':'direct'}}]
            cfg=render_config({'nodes':[n],'domains':[]})
            self.assertEqual(cfg['inbounds'][0]['version'],6)
            self.assertEqual(cfg['inbounds'][0]['users'][0]['userkey'],n['default_user_key'])
            self.assertEqual(cfg['route']['rules'][-1]['auth_user'],['uabcdef1234'])
            global pubip
            old=pubip;pubip=lambda:'192.0.2.1'
            try:
                link=link_output(n,n['users'][0]);self.assertIn('"userkey":',link)
                self.assertNotIn('[Proxy]',link)
            finally:pubip=old
        def test_snell5_obfs_and_v6_shaping(self):
            a=self.base('snell5');a['obfs_mode']='http'
            b=self.base('snell6');b['mode']='unshaped';b['id']='abcdef1234';b['port']=18889
            cfg=render_config({'nodes':[a,b],'domains':[]})
            self.assertEqual(cfg['inbounds'][0]['obfs_mode'],'http')
            self.assertEqual(cfg['inbounds'][1]['mode'],'unshaped')
        def test_ss2022_rejects_invalid_key(self):
            n=self.base('ss2022');n['credential']='not-a-2022-base64-key'
            with self.assertRaises(OneVPSException):render_config({'nodes':[n],'domains':[]})
        def test_disable_removes_listener(self):
            n=self.base('vless-reality');n['enabled']=False
            self.assertEqual(render_config({'nodes':[n],'domains':[]})['inbounds'],[])
        def test_duplicate_user_identifier_rejected(self):
            n=self.base('trojan-ws')
            n['users']=[{'id':'default','name':'duplicate','credential':gen_secret()}]
            with self.assertRaises(OneVPSException):render_config({'nodes':[n],'domains':[]})
        def test_multi_ws_routes_one_domain(self):
            a=self.base('trojan-ws')
            b=self.base('vmess-ws');b['id']='abcdef1234';b['path']='/abcdefghijkl';b['port']=18889
            s=render_caddy({'nodes':[a,b],'domains':[]})
            self.assertEqual(s.count('example.org {'),1)
            self.assertEqual(s.count('reverse_proxy 127.0.0.1:'),2)
        def test_auth_user_node_fallback_order(self):
            n=self.base('ss2022');enter_multiuser(n)
            n['default_outbound']={'type':'direct'}
            n['outbound']={'type':'socks','server':'example.org','server_port':1080}
            cfg=render_config({'nodes':[n],'domains':[]})
            self.assertEqual(cfg['route']['rules'][-2]['auth_user'],['default'])
            self.assertNotIn('auth_user',cfg['route']['rules'][-1])
        def test_private_address_rules_precede_per_user_route(self):
            n=self.base('trojan-ws');n['outbound']={'type':'direct'}
            cfg=render_config({'nodes':[n],'domains':[]})
            self.assertEqual(cfg['route']['rules'][1]['action'],'reject')
            self.assertEqual(cfg['route']['rules'][3]['protocol'],'bittorrent')
            self.assertEqual(cfg['route']['rules'][-1]['outbound'],'direct')
        def test_caddy_disabled_ws_no_new_route(self):
            n=self.base('trojan-ws');n['enabled']=False
            s=render_caddy({'nodes':[n],'domains':['example.org']})
            self.assertIn('error 403',s)
            self.assertNotIn('reverse_proxy',s)
        def test_realm_dynamic_user_permissions(self):
            import io
            from unittest.mock import patch
            global REALM_BASE,REALM_BINARY,REALM_UNIT
            originals=(REALM_BASE,REALM_BINARY,REALM_UNIT)
            try:
                with tempfile.TemporaryDirectory() as td:
                    d=pathlib.Path(td)
                    REALM_BASE=d/'realmconf';REALM_BINARY=d/'realm';REALM_UNIT=d/'realm.service'
                    fake_bin=b'#!/bin/sh\nexit 0\n'
                    archive=io.BytesIO()
                    with tarfile.open(fileobj=archive,mode='w:gz') as t:
                        obj=tarfile.TarInfo('realm');obj.size=len(fake_bin)
                        t.addfile(obj,io.BytesIO(fake_bin))
                    raw=archive.getvalue()
                    asset='realm-x86_64-unknown-linux-musl.tar.gz'
                    api={'assets':[{'name':asset,'digest':'sha256:'+hashlib.sha256(raw).hexdigest(),
                         'browser_download_url':'https://github.com/zhboner/realm/releases/download/v2.9.6/'+asset}]}
                    def mocked_request(url,timeout=35):
                        return json.dumps(api).encode() if url.endswith('/v2.9.6') else raw
                    with patch.dict(globals(),{'request':mocked_request,
                             'command':lambda *a,**kw:subprocess.CompletedProcess([],0,'','')}):
                        install_realm()
                    self.assertEqual(REALM_BASE.stat().st_mode&0o777,0o755)
                    self.assertEqual((REALM_BASE/'config.json').stat().st_mode&0o777,0o644)
                    self.assertEqual(REALM_BINARY.stat().st_mode&0o777,0o755)
            finally:REALM_BASE,REALM_BINARY,REALM_UNIT=originals
        def test_apply_rolls_back_failed_restart(self):
            from unittest.mock import patch
            global META,CONF,CADDY_SNIPPET,OWNER
            originals=(META,CONF,CADDY_SNIPPET,OWNER)
            with tempfile.TemporaryDirectory() as td:
                d=pathlib.Path(td)
                META=d/'nodes.json';CONF=d/'config.json';CADDY_SNIPPET=d/'site.caddy';OWNER='root'
                initial={'nodes':[],'domains':[]}
                META.write_text(jdump(initial));CONF.write_text('{}\n');CADDY_SNIPPET.write_text('OLD_CADDY')
                n=self.base('trojan-ws')
                modified={'nodes':[n],'domains':[]}
                def fake_command(argv,**kw):
                    if len(argv)>1 and argv[0]=='systemctl' and argv[1]=='restart':
                        raise OneVPSException('simulated failed restart')
                    return subprocess.CompletedProcess(argv,0,'','')
                with patch.dict(globals(),{'require_core':lambda:MIN_VERSION,'ensure_owner':lambda:None,
                    'check_core':lambda c:None,'ensure_caddy':lambda:None,
                    'ensure_caddy_sites':lambda c:None,'caddy_check':lambda:True,
                    'caddy_reload':lambda:None,'service_active':lambda name='onevps-singbox.service':True,
                    'command':fake_command}):
                    with self.assertRaises(OneVPSException):apply(modified)
                self.assertEqual(json.loads(META.read_text()),initial)
                self.assertEqual(CONF.read_text(),'{}\n')
                self.assertEqual(CADDY_SNIPPET.read_text(),'OLD_CADDY')
            META,CONF,CADDY_SNIPPET,OWNER=originals
        def test_batch_outbound_overwrites_each_override(self):
            n=self.base('trojan-ws')
            n['outbound']={'type':'direct'}
            n['default_outbound']={'type':'socks','server':'example.org','server_port':1080}
            n['users']=[{'id':'uabcdef1234','name':'Alice','credential':gen_secret(),
                         'outbound':{'type':'direct'}}]
            proxy={'type':'socks','server':'example.org','server_port':18080}
            apply_outbound_selection(n,'all',[],proxy)
            self.assertEqual(n['outbound'],proxy)
            self.assertNotIn('default_outbound',n)
            self.assertNotIn('outbound',n['users'][0])
            cfg=render_config({'nodes':[n],'domains':[]})
            self.assertEqual(cfg['route']['rules'][-1]['inbound'],['in-0123456789'])
            self.assertNotIn('auth_user',cfg['route']['rules'][-1])
        def test_batch_outbound_selected_then_inherit(self):
            n=self.base('trojan-ws')
            n['users']=[{'id':'uabcdef1234','name':'Alice','credential':gen_secret()}]
            apply_outbound_selection(n,'selected',['default','uabcdef1234'],{'type':'direct'})
            self.assertEqual(n['default_outbound'],{'type':'direct'})
            self.assertEqual(n['users'][0]['outbound'],{'type':'direct'})
            apply_outbound_selection(n,'selected',['uabcdef1234'],None)
            self.assertNotIn('outbound',n['users'][0])
            self.assertIn('default_outbound',n)
            with self.assertRaises(OneVPSException):
                apply_outbound_selection(n,'selected',['default','default'],None)
    suite=unittest.defaultTestLoader.loadTestsFromTestCase(Smoke)
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful():sys.exit(1)

if __name__=='__main__':
    try:
        args=sys.argv[1:]
        if args==['--self-test']:_selftest()
        elif args==['--sync-certs']:sys.exit(sync_certs(quiet=True))
        elif args==['--check']:diagnostics()
        elif args==['--acceptance']:sys.exit(acceptance())
        elif args==['--version']:print('OneVPS sing-box edition 1.1; sing-box >=1.14.0')
        else:main_menu()
    except OneVPSException as e:
        warn(str(e));sys.exit(1)
PYTHON_APP

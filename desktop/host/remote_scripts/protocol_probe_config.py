# Runs only on the registered target. Resolved secrets and paths never leave it.
import os, pathlib, re, json, base64
try:
    import tomllib
except ImportError:
    print(json.dumps({'probe_error':'remote_probe_python_311_required'}));raise SystemExit

class ConfigFailure(Exception): pass

def runtime_environment(config_path):
    matches=[]
    for entry in pathlib.Path('/proc').iterdir():
        if not entry.name.isdigit(): continue
        try:
            if entry.stat().st_uid!=os.geteuid(): continue
            if not pathlib.Path(os.readlink(entry/'exe')).name.startswith('vhttpd'): continue
            args=(entry/'cmdline').read_bytes().decode().split('\0')
            if any(a.startswith('--workbench-') for a in args): continue
            configs=[args[i+1] for i,a in enumerate(args[:-1]) if a=='--config']
            configs += [a[len('--config='):] for a in args if a.startswith('--config=')]
            if len(configs)!=1: continue
            cwd=os.readlink(entry/'cwd')
            if os.path.realpath(os.path.join(cwd,configs[0]))!=os.path.realpath(config_path): continue
            data=(entry/'environ').read_bytes()
            if len(data)>1048576: raise ConfigFailure('remote_probe_runtime_environment_unavailable')
            matches.append(dict(item.split('=',1) for item in data.decode().split('\0') if '=' in item))
        except (OSError,UnicodeError): continue
    if len(matches)!=1: raise ConfigFailure('remote_probe_runtime_environment_unavailable')
    return matches[0]

def expand(value,root,environment):
    if not isinstance(value,str): raise ConfigFailure('remote_probe_reference_unavailable')
    for _ in range(32):
        if chr(36)+'{' not in value: return value
        match=re.search(r'\$\{([^{}]*)\}',value)
        if not match: break
        key,sep,default=match[1].partition(':-');key=key.strip()
        if key in ('config.dir','paths.root'): resolved=root
        elif re.fullmatch(r'env\.[A-Za-z_][A-Za-z0-9_]*',key):
            env=environment()
            if key[4:] in env: resolved=env[key[4:]]
            elif sep: resolved=default
            else: raise ConfigFailure('remote_probe_reference_unavailable')
        else: raise ConfigFailure('remote_probe_reference_unavailable')
        value=value[:match.start()]+resolved+value[match.end():]
        if len(value)>65536: break
    raise ConfigFailure('remote_probe_reference_unavailable')

def auth_header(options,resolve):
    kind=resolve(options.get('probe_auth_kind','bearer'))
    if kind in ('basic','digest'):
        user=resolve(options.get('probe_digest_username' if kind=='digest' else 'probe_basic_username',''));password=resolve(options.get('probe_digest_password' if kind=='digest' else 'probe_basic_password',''))
        if not user or not password or ':' in user or len(user)+len(password)>4096 or any(ord(c)<32 or ord(c)==127 for c in user+password):
            raise ConfigFailure('probe_basic_credential_unavailable')
        if kind=='digest':
            if any(ord(c)>126 for c in user+password): raise ConfigFailure('probe_digest_ascii_credentials_required')
            return '',[user,password],kind
        encoded=base64.b64encode((user+':'+password).encode()).decode()
        return 'Authorization: Basic '+encoded+'\r\n',[user,password,user+':'+password,encoded,'Basic '+encoded],kind
    if kind=='mtls':
        for key in ('probe_client_cert','probe_client_key'):
            value=resolve(options.get(key,''))
            if not value or len(value)>4096 or any(ord(c)<32 for c in value): raise ConfigFailure('probe_client_certificate_unavailable')
        return '',[],kind
    if kind not in ('bearer','api_key'): raise ConfigFailure('unsupported_probe_auth_kind')
    value=resolve(options.get('probe_bearer_token' if kind=='bearer' else 'probe_api_key',''))
    if not value or len(value)>4096 or any(ord(c)<=32 or ord(c)>=127 for c in value): raise ConfigFailure('probe_credential_unavailable')
    header='Authorization: Bearer '+value if kind=='bearer' else 'X-API-Key: '+value
    return header+'\r\n',[value,header.split(': ',1)[1]],kind

def resolve_probe_config(q):
    root_path=q['config_path'];sources=q['sources'];root=os.path.dirname(root_path)
    if not root_path.startswith('/') or root_path not in sources or len(sources)>32: raise ConfigFailure('remote_probe_configuration_unavailable')
    tables={'listeners':{},'adapters':{}};origins={'listeners':{},'adapters':{}};pipelines=[];control={};visited=set()
    def visit(path):
        nonlocal control
        if path in visited: raise ConfigFailure('remote_probe_configuration_ambiguous')
        visited.add(path);text=sources.get(path)
        if not isinstance(text,str) or len(text.encode())>65536: raise ConfigFailure('remote_probe_configuration_unavailable')
        if pathlib.Path(path).read_bytes().decode()!=text: raise ConfigFailure('remote_probe_configuration_changed')
        doc=tomllib.loads(text)
        if doc.get('version',2)!=2: raise ConfigFailure('remote_probe_v2_required')
        for name,entries in tables.items():
            for key,value in doc.get(name,{}).items():
                if key in entries: raise ConfigFailure('remote_probe_configuration_ambiguous')
                entries[key]=value;origins[name][key]=os.path.dirname(path)
        if doc.get('control'):
            if control: raise ConfigFailure('remote_probe_configuration_ambiguous')
            control=doc['control']
        pipelines.extend(doc.get('pipelines',[]))
        for child in doc.get('include',[]):
            if not isinstance(child,str) or chr(36)+'{' in child: raise ConfigFailure('remote_probe_include_reference_unsupported')
            visit(os.path.normpath(os.path.join(os.path.dirname(path),child)))
    visit(root_path)
    if visited!=set(sources): raise ConfigFailure('remote_probe_configuration_changed')
    env=None
    def environment():
        nonlocal env
        if env is None: env=runtime_environment(root_path)
        return env
    def resolve(value): return expand(value,root,environment)
    def listener_endpoint(id,protocol):
        l=tables['listeners'].get(id)
        if not l: raise ConfigFailure('unknown_business_listener')
        if control.get('listener','') in (id,'listener:'+id): raise ConfigFailure('admin_requests_forbidden')
        host=l.get('host','');port=l.get('port',0)
        if host not in ('','127.0.0.1','localhost','0.0.0.0','::1','::') or type(port)!=int or not 1<=port<=65535 or l.get('protocol','http') not in (('http','websocket') if protocol=='websocket' else ('http',)):
            raise ConfigFailure('http_loopback_listener_required')
        return l,dict(host='::1' if host in ('::','::1') else '127.0.0.1',port=port,secure=bool(l.get('tls',{}).get('enabled',False)))
    def routed(listener,adapter):
        return any(p.get('ingress')=='listener:'+listener and p.get('egress')=='adapter:'+adapter for p in pipelines)
    if q.get('options_only'):
        inventory=[]
        for id,l in sorted(tables['listeners'].items()):
            try: _,ep=listener_endpoint(id,'websocket')
            except ConfigFailure: continue
            auth=[];unavailable=[]
            for adapter,entry in sorted(tables['adapters'].items()):
                options=entry.get('options',{})
                if not routed(id,adapter) or not any(k in options for k in ('probe_bearer_token','probe_basic_username','probe_api_key','probe_client_cert','probe_digest_username')): continue
                try:
                    _,_,kind=auth_header(options,lambda value: expand(value,origins['adapters'][adapter],environment))
                    if kind=='mtls' and not ep['secure']: raise ConfigFailure('probe_client_certificate_requires_tls')
                    auth.append(dict(auth_ref=adapter,kind=kind,protocols=['stream'] if kind=='digest' else (['websocket'] if l.get('protocol')=='websocket' else ['stream','websocket','mcp'])))
                except ConfigFailure as e: unavailable.append(dict(auth_ref=adapter,failure=str(e)))
            tls=l.get('tls',{});certs=[tls.get('cert','')]+[c.get('cert','') for c in tls.get('certificates',[])]
            try:
                trust=any(expand(cert,origins['listeners'][id],environment) for cert in certs)
                names=[name for c in tls.get('certificates',[]) for name in c.get('hosts',[]) if isinstance(name,str) and chr(36)+'{' not in name]
            except ConfigFailure: trust=False;names=[]
            inventory.append(dict(listener=id,protocols=['websocket'] if l.get('protocol')=='websocket' else ['stream','websocket','mcp'],address_family='ipv6' if ep['host']=='::1' else 'ipv4',tls=ep['secure'],listener_certificate_available=trust,certificate_hosts=names,auth_refs=[a['auth_ref'] for a in auth],authentication=auth,unavailable_auth_refs=unavailable))
        return dict(source='remote_configuration',reference_resolution='remote_runtime_environment' if env is not None else 'configuration_literals',listeners=inventory),None
    a=q['args'];l,ep=listener_endpoint(a['listener'],a['protocol']);p=dict(a,**ep,authorization='',probe_secrets=[])
    if a.get('auth_ref'):
        adapter=a['auth_ref']
        if adapter not in tables['adapters']: raise ConfigFailure('unknown_probe_auth_ref')
        if not routed(a['listener'],adapter): raise ConfigFailure('probe_auth_ref_listener_mismatch')
        options=tables['adapters'][adapter].get('options',{});origin=origins['adapters'][adapter]
        resolved=lambda value: expand(value,origin,environment)
        p['authorization'],p['probe_secrets'],p['auth_kind']=auth_header(options,resolved)
        if p['auth_kind']=='digest':
            if a['protocol']!='stream': raise ConfigFailure('probe_digest_stream_get_required')
            p['digest_user']=resolved(options.get('probe_digest_username',''));p['digest_password']=resolved(options.get('probe_digest_password',''))
        if p['auth_kind']=='mtls':
            if not ep['secure']: raise ConfigFailure('probe_client_certificate_requires_tls')
            p['client_cert']=os.path.normpath(os.path.join(origin,resolved(options.get('probe_client_cert',''))))
            p['client_key']=os.path.normpath(os.path.join(origin,resolved(options.get('probe_client_key',''))))
            p['probe_secrets'] += [p['client_cert'],p['client_key']]
    if not ep['secure'] and (a.get('tls_trust','system')!='system' or a.get('tls_server_name')): raise ConfigFailure('probe_tls_listener_required')
    p['tls_name']=a.get('tls_server_name','');p['ca_file']=''
    if ep['secure'] and a.get('tls_trust')=='listener_certificate':
        tls=l.get('tls',{});cert=tls.get('cert','')
        for entry in tls.get('certificates',[]):
            if p['tls_name'] in entry.get('hosts',[]): cert=entry.get('cert','');break
        cert=expand(cert,origins['listeners'][a['listener']],environment)
        if not cert: raise ConfigFailure('probe_listener_certificate_unavailable')
        p['ca_file']=os.path.normpath(os.path.join(origins['listeners'][a['listener']],cert))
    return None,p

try:
    inventory,p=resolve_probe_config(q)
    if inventory is not None:
        print(json.dumps(inventory));raise SystemExit
except ConfigFailure as e:
    print(json.dumps({'probe_error':str(e)}));raise SystemExit
except Exception:
    print(json.dumps({'probe_error':'remote_probe_configuration_unavailable'}));raise SystemExit

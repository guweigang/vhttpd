# Embedded by Desktop; p is validated by the configuration-owning host before execution.
# Python stdlib is already required for remote environment management.
import socket, http.client, time, json, os, base64, hashlib, struct, ssl, re

host = p.get('host', '127.0.0.1')
if host not in ('127.0.0.1', '::1'):
    raise ValueError('configuration-selected loopback required')
authority = ('[::1]' if host == '::1' else host) + ':' + str(p['port'])

class ProbeFailure(Exception): pass

def tls_context():
    # Config-selected public certificate or system roots, never an insecure mode.
    ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    if p.get('ca_file'): ctx.load_verify_locations(cafile=p['ca_file'])
    else: ctx.load_default_certs()
    # Explicit context avoids environment-enabled TLS session key export.
    if p.get('client_cert'):
        try: ctx.load_cert_chain(p['client_cert'],p['client_key'],password=lambda: b'')
        except (OSError,ValueError,ssl.SSLError): raise ProbeFailure('probe_client_certificate_unavailable') from None
    return ctx

def connect():
    try: sock = socket.create_connection((host, p['port']), timeout=remaining())
    except OSError: raise ProbeFailure('probe_tcp_connect_failed') from None
    if p.get('secure'):
        try:
            sock = tls_context().wrap_socket(sock, server_hostname=p.get('tls_name') or host)
        except ProbeFailure:
            sock.close();raise
        except (ssl.SSLError, OSError, ValueError):
            sock.close()
            raise ProbeFailure('probe_tls_verification_failed') from None
    return sock

class ProbeHTTPConnection(http.client.HTTPConnection):
    def connect(self): self.sock = connect()

def reject_auth(status):
    if status in (401,403): raise ProbeFailure('probe_authentication_rejected_' + str(status))

start = time.monotonic()
deadline = start + p['timeout_ms'] / 1000

def remaining():
    return max(.001, deadline - time.monotonic())

def events(body):
    result = []
    for block in body.replace('\r\n', '\n').split('\n\n')[:-1]:
        data = [line[5:].lstrip(' ') for line in block.split('\n') if line.startswith('data:')]
        if data: result.append('\n'.join(data))
    return result

def digest_header(challenge,method,path):
    # One challenge, auth quality only; no auth-int, sess, userhash or downgrade.
    if len(challenge)>8192 or challenge.rstrip().endswith(',') or not challenge.startswith('Digest '): raise ProbeFailure('probe_digest_challenge_unsupported')
    tail=challenge[7:];fields={}
    pattern=r'\s*([A-Za-z][A-Za-z0-9_-]*)\s*=\s*("(?:[^"\\\r\n]|\\[ -~])*"|[A-Za-z0-9_-]+)\s*(?:,|$)'
    while tail:
        match=re.match(pattern,tail)
        if not match or match[1].lower() in fields: raise ProbeFailure('probe_digest_challenge_unsupported')
        value=match[2]
        if value.startswith('"'): value=re.sub(r'\\(.)',r'\1',value[1:-1])
        fields[match[1].lower()]=value;tail=tail[match.end():]
    algorithm=fields.get('algorithm','MD5').upper()
    if algorithm not in ('MD5','SHA-256') or 'auth' not in [v.strip() for v in fields.get('qop','').split(',')] or not fields.get('nonce') or 'realm' not in fields or fields.get('userhash','false')!='false' or fields.get('charset','UTF-8').upper()!='UTF-8':
        raise ProbeFailure('probe_digest_challenge_unsupported')
    if any(ord(c)<32 or ord(c)>126 for v in fields.values() for c in v): raise ProbeFailure('probe_digest_challenge_unsupported')
    def H(value): return hashlib.new('md5' if algorithm=='MD5' else 'sha256',value.encode()).hexdigest()
    def quote(value): return '"'+value.replace('\\','\\\\').replace('"','\\"')+'"'
    user=p['digest_user'];realm=fields['realm'];nonce=fields['nonce'];cnonce=os.urandom(16).hex()
    ha1=H(user+':'+realm+':'+p['digest_password']);ha2=H(method+':'+path)
    response=H(ha1+':'+nonce+':00000001:'+cnonce+':auth:'+ha2)
    header='Digest '+', '.join(k+'='+quote(v) for k,v in dict(username=user,realm=realm,nonce=nonce,uri=path,response=response,cnonce=cnonce).items())+', algorithm='+algorithm+', qop=auth, nc=00000001'
    if 'opaque' in fields: header+=', opaque='+quote(fields['opaque'])
    p['probe_secrets'] += [header,response,ha1,cnonce,nonce]
    return header

def request(method, body='', session='', digest=''):

    c = ProbeHTTPConnection(host, p['port'], timeout=remaining())
    headers = {'Accept': 'application/json, text/event-stream', 'Content-Type': 'application/json',
               'MCP-Protocol-Version': '2025-03-26', 'Connection': 'close'}
    if session: headers['Mcp-Session-Id'] = session
    if p.get('authorization'):
        name,value=p['authorization'].strip().split(': ',1)
        if name not in ('Authorization','X-API-Key'): raise ValueError('credential header')
        headers[name]=value
    if digest: headers['Authorization']=digest
    try:
        c.request(method, p['path'], body=body.encode(), headers=headers)
        r = c.getresponse()
        h = {}
        for k,v in r.getheaders():
            if k.lower() in h: raise ValueError('duplicate header')
            h[k.lower()] = v
        if sum(len(k)+len(v) for k,v in h.items()) > 16384: raise ValueError('headers')
        if p.get('auth_kind')=='digest' and not digest:
            if r.status!=401: raise ProbeFailure('probe_digest_challenge_required')
            value=digest_header(h.get('www-authenticate',''),method,p['path'])
            c.close()
            return request(method,body,session,value)
        reject_auth(r.status)
        data = bytearray()
        streaming = p['protocol'] == 'stream' or h.get('content-type','').split(';')[0].strip() == 'text/event-stream'
        if method != 'DELETE' and r.status not in (202,204):
            while len(data) < 65536:
                try:
                    if c.sock: c.sock.settimeout(remaining())
                    if time.monotonic() >= deadline: raise TimeoutError()
                    b = r.read1(1)
                except (TimeoutError, OSError):
                    if streaming and data: break
                    raise
                if not b: break
                data.extend(b)
                if streaming and (data.endswith(b'\n\n') or data.endswith(b'\r\n\r\n')):
                    ev=events(data.decode('utf-8',errors='replace'))
                    expected=json.loads(body).get('id',0) if p['protocol']=='mcp' and body else 0
                    if expected:
                        if any(event_id(e)==expected for e in ev): break
                        if len(ev)>=8: raise ValueError('mcp event limit')
                    elif len(ev)>=p['max_items']: break
            if len(data) >= 65536 and not streaming: raise ValueError('body limit')
        return r.status,h,data.decode('utf-8',errors='replace')
    finally:
        c.close()

def event_id(text):
    try: return json.loads(text).get('id',0)
    except Exception: return 0

def rpc(response, id):
    status,h,body=response
    if status != 200: raise ValueError('mcp status')
    t=h.get('content-type','').split(';')[0].strip()
    if t=='text/event-stream':
        ev=[e for e in events(body) if event_id(e)==id]
        if len(ev)!=1: raise ValueError('mcp event')
        body=ev[0]
    elif t!='application/json': raise ValueError('mcp content type')
    v=json.loads(body)
    if v.get('jsonrpc')!='2.0' or v.get('id')!=id or 'error' in v: raise ValueError('mcp rpc')
    return v['result']

def mcp_probe():
    r=request('POST',json.dumps(dict(jsonrpc='2.0',id=1,method='initialize',params=dict(protocolVersion='2025-03-26',capabilities={},clientInfo=dict(name='vhttpd-desktop-probe',version='1')))))
    sid=r[1].get('mcp-session-id','')
    if len(sid)>512 or any(ord(c)<=32 or ord(c)>=127 for c in sid): raise ValueError('session')
    try:
        init=rpc(r,1)
        if init.get('protocolVersion')!='2025-03-26': raise ValueError('version')
        ack=request('POST',json.dumps(dict(jsonrpc='2.0',method='notifications/initialized')),sid)
        if ack[0] not in (200,202,204): raise ValueError('ack')
        listing=rpc(request('POST',json.dumps(dict(jsonrpc='2.0',id=2,method='tools/list',params={})),sid),2)
        tools=listing['tools']
        if not isinstance(tools,list): raise ValueError('tools')
        names=[t['name'] for t in tools[:p['max_items']]]
        if any(not isinstance(n,str) or len(n)>256 for n in names): raise ValueError('name')
        return dict(protocol_version=init['protocolVersion'],session_created=bool(sid),tool_count=len(tools),tools=names,has_more='nextCursor' in listing or len(tools)>p['max_items'])
    finally:
        if sid:
            global deadline
            saved=deadline
            deadline=time.monotonic()+.5
            try: request('DELETE','',sid)
            except Exception: pass
            deadline=saved

def websocket_probe():
    s=connect()
    def exact(n):
        out=bytearray()
        while len(out)<n:
            s.settimeout(remaining())
            if time.monotonic()>=deadline: raise TimeoutError()
            b=s.recv(n-len(out))
            if not b: raise EOFError()
            out.extend(b)
        return bytes(out)
    def frame(op,data):
        mask=os.urandom(4)
        size=len(data)
        header=bytes([128|op,128|size]) if size<126 else bytes([128|op,254])+struct.pack('!H',size)
        s.sendall(header+mask+bytes(b^mask[i%4] for i,b in enumerate(data)))
    try:
        key=base64.b64encode(os.urandom(16)).decode()
        s.sendall(('GET '+p['path']+' HTTP/1.1\r\nHost: '+authority+'\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: '+key+'\r\nSec-WebSocket-Version: 13\r\n'+p.get('authorization','')+'\r\n').encode())
        header=bytearray()
        while not header.endswith(b'\r\n\r\n'):
            if len(header)>=16384: raise ValueError('headers')
            header.extend(exact(1))
        lines=header.decode('ascii').split('\r\n'); h={}
        reject_auth(int(lines[0].split()[1]))
        for line in lines[1:]:
            if ':' in line:
                k,v=line.split(':',1)
                if k.lower() in h: raise ValueError('duplicate header')
                h[k.lower()]=v.strip()
        accept=base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        if lines[0].split()[1]!='101' or h.get('sec-websocket-accept')!=accept or h.get('upgrade','').lower()!='websocket' or 'upgrade' not in [x.strip() for x in h.get('connection','').lower().split(',')]: raise ValueError('handshake')
        try:
            if p['message']: frame(1,p['message'].encode())
            messages=[]; closed=False
            for _ in range(16):
                if len(messages)>=p['max_items']: break
                try: first,second=exact(2)
                except (TimeoutError,EOFError,OSError): break
                if first&112 or second&128: raise ValueError('frame flags')
                op=first&15; size=second&127
                if size==127: raise ValueError('frame limit')
                if size==126: size=struct.unpack('!H',exact(2))[0]
                if size>4096 or (op>=8 and (size>125 or not first&128)): raise ValueError('frame limit')
                body=exact(size)
                if op==8: closed=True; break
                if op==9: frame(10,body); continue
                if op==10: continue
                if op!=1 or not first&128: raise ValueError('text frame required')
                messages.append(body.decode('utf-8'))
            return dict(handshake=True,sent=bool(p['message']),received_text=bool(messages),messages=messages,peer_closed=closed,sample_limit=len(messages)>=p['max_items'])
        finally:
            try: frame(8,b'\x03\xe8')
            except Exception: pass
    finally: s.close()

result={}; failure=''
try:
    if p['protocol']=='websocket': result=websocket_probe()
    elif p['protocol']=='mcp': result=mcp_probe()
    else:
        status,h,body=request('GET'); ev=events(body); t=h.get('content-type','').split(';')[0]
        result=dict(status=status,content_type=t,bytes=len(body.encode()),events=ev,sample=body,sample_limit=len(body.encode())>=65536 or len(ev)>=p['max_items'])
        if status!=200 or (t=='text/event-stream' and not ev): failure='http_status_or_no_complete_event'
except ProbeFailure as e:
    failure=str(e)
except Exception:
    failure={'stream':'http_stream_unavailable','websocket':'websocket_handshake_or_frame_unavailable','mcp':'mcp_initialize_or_tools_list_failed'}[p['protocol']]
output=dict(ok=not failure,protocol=p['protocol'],listener=p['listener'],source='business_protocol',address_family='ipv6' if host=='::1' else 'ipv4',tls=bool(p.get('secure')),tls_verified=bool(p.get('secure')) and failure not in ('probe_tls_verification_failed','probe_tcp_connect_failed','probe_client_certificate_unavailable'),auth_configured=bool(p.get('authorization') or p.get('auth_kind') in ('digest','mtls')),stage='tls' if failure in ('probe_tls_verification_failed','probe_client_certificate_unavailable') else 'connect' if failure=='probe_tcp_connect_failed' else 'authentication' if failure.startswith(('probe_authentication_rejected_','probe_digest_')) else 'protocol',elapsed_ms=int((time.monotonic()-start)*1000),failure=failure,result=result)
secrets=list(p.get('probe_secrets',[]))
header=p.get('authorization','').strip()
if header:
    value=header.split(': ',1)[1];secrets.append(value)
    if value.startswith('Bearer '): secrets.append(value[len('Bearer '):])
    if value.startswith('Basic '):
        encoded=value[len('Basic '):];decoded=base64.b64decode(encoded).decode()
        secrets += [encoded,decoded,*decoded.split(':',1)]
def redact(value):
    if isinstance(value,str):
        for secret in sorted(set(secrets),key=len,reverse=True):
            if secret: value=value.replace(secret,'<probe-credential>')
        return value
    if isinstance(value,list): return [redact(v) for v in value]
    if isinstance(value,dict): return {k:redact(v) for k,v in value.items()}
    return value
# Redact sampled application data without corrupting JSON keys or fixed diagnostics.
output['result']=redact(output['result'])
print(json.dumps(output))

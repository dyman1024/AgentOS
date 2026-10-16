#!/usr/bin/env python3
"""Bounded JSON RPC over virtio-vsock. This guest is untrusted by the host."""
import base64, json, os, select, signal, socket, subprocess, tempfile, threading, time, uuid
from oci import prepare_oci, cleanup_oci
MAX_BYTES = 2_000_000
WORKSPACE = '/workspace'
SERVICES = {}
SERVICE_LOCK = threading.Lock()
BACKEND = None
BACKEND_LOCK = threading.Lock()

def receive(conn):
    data = bytearray()
    while b'\n' not in data:
        chunk = conn.recv(65536)
        if not chunk: raise ValueError('Incomplete request')
        data.extend(chunk)
        if len(data) > MAX_BYTES: raise ValueError('Request too large')
    return json.loads(data.split(b'\n', 1)[0])

def path(value):
    candidate = os.path.realpath(os.path.join(WORKSPACE, value))
    if not candidate.startswith(WORKSPACE + '/') and candidate != WORKSPACE:
        raise ValueError('Path escapes workspace')
    return candidate

def backend_call(method, args):
    global BACKEND
    with BACKEND_LOCK:
        if method == 'backend.stop':
            if BACKEND:
                proc=BACKEND['process']
                if proc.poll() is None:
                    os.killpg(proc.pid,signal.SIGKILL);proc.wait()
                proc.stdin.close();proc.stdout.close();BACKEND['log'].close()
                if BACKEND.get('oci'): cleanup_oci()
                BACKEND=None
            return {'stopped':True}
        if method == 'backend.start':
            if BACKEND: raise ValueError('Stop the previous backend first')
            language=args['language']
            if language not in ['python','node','oci']: raise ValueError('Unsupported backend language')
            entry=path(args['entry'])
            log=tempfile.TemporaryFile()
            command=prepare_oci(entry) if language=='oci' else (['python3','-u',entry] if language=='python' else ['node',entry])
            proc=subprocess.Popen(command,cwd=os.path.dirname(entry),env={'PATH':'/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin','HOME':'/workspace','LANG':'C.UTF-8'},stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log,start_new_session=True)
            BACKEND={'process':proc,'log':log,'oci':language=='oci'}
            return {'running':True}
        if method != 'backend.invoke' or not BACKEND: raise ValueError('Backend is not running')
        proc=BACKEND['process'];request_id=str(uuid.uuid4())
        if proc.poll() is not None: raise ValueError('Backend exited')
        request=json.dumps({'id':request_id,'method':args['method'],'args':args.get('args',{})}).encode()+b'\n'
        if len(request)>1000000: raise ValueError('Backend request too large')
        # A stalled or corrupt backend is terminated; no replay of potentially mutating calls.
        try:
            deadline=time.monotonic()+20;sent=0
            os.set_blocking(proc.stdin.fileno(),False)
            while sent<len(request):
                remaining=deadline-time.monotonic()
                if remaining<=0 or not select.select([], [proc.stdin], [], remaining)[1]: raise TimeoutError('Backend stopped reading')
                sent+=os.write(proc.stdin.fileno(),request[sent:])
            response=bytearray()
            while b'\n' not in response:
                remaining=deadline-time.monotonic()
                if remaining<=0 or not select.select([proc.stdout], [], [], remaining)[0]: raise TimeoutError('Backend timed out')
                chunk=os.read(proc.stdout.fileno(),65536)
                if not chunk or len(response)+len(chunk)>1000000: raise ValueError('Invalid backend response')
                response.extend(chunk)
            value=json.loads(response.split(b'\n',1)[0])
            if value.get('id')!=request_id: raise ValueError('Backend response identity mismatch')
            if 'error' in value: raise ValueError(str(value['error'])[:2000])
            return value.get('result')
        except Exception:
            if proc.poll() is None:
                os.killpg(proc.pid,signal.SIGKILL);proc.wait()
            if BACKEND.get('oci'): cleanup_oci()
            raise

def handle(request):
    method, args = request['method'], request.get('args', {})
    if method.startswith('backend.'): return backend_call(method,args)
    if method == 'ping': return {'ready': True, 'networkInterfaces': os.listdir('/sys/class/net')}
    if method.startswith('service.'):
        name=args['name']
        if not isinstance(name,str) or not name.isascii() or not name.replace('-','').replace('_','').isalnum() or len(name)>64: raise ValueError('Invalid service name')
        with SERVICE_LOCK:
            entry=SERVICES.get(name)
            if method == 'service.start':
                if entry and entry['process'].poll() is None: raise ValueError('Service is already running')
                if len([s for s in SERVICES.values() if s['process'].poll() is None])>=8: raise ValueError('Service limit exceeded')
                command=args['cmd']
                if not isinstance(command,str) or len(command)>65536: raise ValueError('Invalid service command')
                log=tempfile.TemporaryFile()
                # Persistent services never inherit a per-command host capability.
                process=subprocess.Popen(['/bin/sh','-lc',command],cwd=path(args.get('cwd','.')),env={'PATH':'/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin','HOME':'/root','LANG':'C.UTF-8'},stdin=subprocess.DEVNULL,stdout=log,stderr=log,start_new_session=True)
                SERVICES[name]={'process':process,'log':log}
                return {'name':name,'pid':process.pid,'running':True}
            if not entry: raise ValueError('Unknown service')
            proc=entry['process']
            if method == 'service.stop' and proc.poll() is None:
                os.killpg(proc.pid,signal.SIGTERM)
                try:proc.wait(timeout=3)
                except subprocess.TimeoutExpired:os.killpg(proc.pid,signal.SIGKILL);proc.wait()
            log=entry['log'];size=os.fstat(log.fileno()).st_size
            tail=os.pread(log.fileno(),min(size,65536),max(0,size-65536)).decode('utf8','replace')
            return {'name':name,'running':proc.poll() is None,'exitCode':proc.poll(),'log':tail}
    if method == 'exec':
        command = args['cmd']
        if not isinstance(command, str) or len(command) > 65536: raise ValueError('Invalid command')
        timeout = min(max(int(args.get('timeout', 30)), 1), 120)
        env = {'PATH':'/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin','HOME':'/root','LANG':'C.UTF-8','AOS_RUN_TOKEN':(request.get('token') or '')}
        for key, value in args.get('env', {}).items():
            if key.startswith('AOS_') or '\x00' in key or not isinstance(value,str): raise ValueError('Invalid environment')
            env[key] = value
        with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
            proc = subprocess.Popen(['/bin/sh','-lc',command], cwd=path(args.get('cwd','.')),env=env,stdout=out,stderr=err,start_new_session=True)
            deadline=time.monotonic()+timeout
            limited=False
            while proc.poll() is None:
                if time.monotonic()>deadline or out.tell()+err.tell()>MAX_BYTES:
                    limited=True;os.killpg(proc.pid,signal.SIGKILL);break
                time.sleep(.025)
            proc.wait()
            # Child processes cannot keep the command's host authorization after its response.
            try: os.killpg(proc.pid,signal.SIGKILL)
            except ProcessLookupError: pass
            out.seek(0);err.seek(0)
            return {'stdout':out.read(MAX_BYTES).decode('utf8','replace'),'stderr':err.read(MAX_BYTES).decode('utf8','replace'),'exitCode':proc.returncode,'limited':limited}
    if method == 'fs.chunk':
        target=path(args['path']);data=base64.b64decode(args['base64'],validate=True);offset=args['offset']
        if not isinstance(offset,int) or offset<0 or offset+len(data)>200000000 or len(data)>512000: raise ValueError('Invalid archive chunk')
        os.makedirs(os.path.dirname(target),exist_ok=True)
        with open(target,'wb' if offset==0 else 'r+b') as f:
            if offset and os.fstat(f.fileno()).st_size!=offset: raise ValueError('Archive chunk offset mismatch')
            f.seek(offset);f.write(data)
        return {'bytes':len(data)}
    if method == 'fs.read':
        with open(path(args['path']),'rb') as f: data=f.read(MAX_BYTES+1)
        if len(data)>MAX_BYTES: raise ValueError('File too large')
        return {'base64':base64.b64encode(data).decode(),'text':data.decode('utf8','replace')}
    if method == 'fs.write':
        target=path(args['path']);data=args['text'].encode()
        if len(data)>MAX_BYTES: raise ValueError('File too large')
        os.makedirs(os.path.dirname(target),exist_ok=True)
        with open(target,'wb') as f:f.write(data)
        return {'bytes':len(data)}
    if method == 'fs.list':
        root=path(args.get('path','.'))
        return [{'name':name,'directory':os.path.isdir(os.path.join(root,name))} for name in sorted(os.listdir(root))[:1000]]
    raise ValueError('Unsupported guest method')

def serve(conn):
    with conn:
        conn.settimeout(150)
        try: response={'result':handle(receive(conn))}
        except Exception as error: response={'error':{'code':'vm_error','message':str(error)}}
        conn.sendall(json.dumps(response,ensure_ascii=False).encode()+b'\n')

os.makedirs(WORKSPACE,exist_ok=True)
def service_limits():
    while True:
        time.sleep(1)
        with SERVICE_LOCK:
            for entry in list(SERVICES.values())+([BACKEND] if BACKEND else []):
                proc=entry['process']
                try: oversized = os.fstat(entry['log'].fileno()).st_size > MAX_BYTES
                except (OSError, ValueError): continue  # The backend may have just stopped.
                if proc.poll() is None and oversized:
                    try:os.killpg(proc.pid,signal.SIGKILL)
                    except ProcessLookupError:pass
threading.Thread(target=service_limits,daemon=True).start()
listener=socket.socket(socket.AF_VSOCK,socket.SOCK_STREAM)
listener.bind((socket.VMADDR_CID_ANY,5201));listener.listen(8)
print('AGENTOS_VM_READY',flush=True)
while True:
    conn,_=listener.accept();threading.Thread(target=serve,args=(conn,),daemon=True).start()

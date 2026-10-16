"""OCI images are verified and unpacked only inside a dedicated, networkless guest."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile
import tempfile

MAX_ARCHIVE = 200_000_000
MANIFEST = 'application/vnd.oci.image.manifest.v1+json'

def read_json(path):
    if path.stat().st_size > 1_000_000: raise ValueError('OCI metadata too large')
    return json.loads(path.read_bytes())

def blob(layout, descriptor):
    digest = descriptor.get('digest', '')
    if not digest.startswith('sha256:') or len(digest) != 71 or any(c not in '0123456789abcdef' for c in digest[7:]):
        raise ValueError('OCI requires SHA-256 content addresses')
    target = layout / 'blobs' / 'sha256' / digest[7:]
    if not target.is_file() or target.stat().st_size != descriptor.get('size') or target.stat().st_size > MAX_ARCHIVE:
        raise ValueError('OCI blob size mismatch')
    with target.open('rb') as stream: actual = hashlib.file_digest(stream, 'sha256').hexdigest()
    if actual != digest[7:]: raise ValueError('OCI blob digest mismatch')
    return target

def verified_layout(archive, destination):
    """The outer image-layout tar must contain only bounded regular files and directories."""
    if archive.stat().st_size > MAX_ARCHIVE: raise ValueError('OCI archive too large')
    names = set(); total = 0
    with tarfile.open(archive, mode='r:') as stream:
        for member in stream:
            path = PurePosixPath(member.name)
            name = str(path)
            if path.is_absolute() or '..' in path.parts or any(ord(c) < 32 for c in name) or len(name)>2048:
                raise ValueError('Unsafe OCI archive path')
            if name == '.' and member.isdir(): continue
            if name in names or len(names) >= 10000 or not (member.isfile() or member.isdir()):
                raise ValueError('OCI archive contains duplicate, linked or unsupported entries')
            names.add(name); total += member.size
            if total > MAX_ARCHIVE: raise ValueError('OCI archive exceeds limits')
            target = destination / name
            if member.isdir(): target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with target.open('xb') as output, stream.extractfile(member) as source:
                    shutil.copyfileobj(source, output, 1_000_000)
    if read_json(destination/'oci-layout').get('imageLayoutVersion') != '1.0.0':
        raise ValueError('Unsupported OCI image-layout version')
    index = read_json(destination/'index.json')
    matches = [d for d in index.get('manifests', []) if d.get('annotations', {}).get('org.opencontainers.image.ref.name') == 'app']
    if len(matches) != 1 or matches[0].get('mediaType') != MANIFEST:
        raise ValueError('OCI archive must have one app tag pointing to a single-platform manifest')
    manifest = read_json(blob(destination, matches[0]))
    config = read_json(blob(destination, manifest['config']))
    if config.get('os') != 'linux' or config.get('architecture') != 'arm64':
        raise ValueError('OCI backend requires linux/arm64')
    layers = manifest.get('layers', [])
    if not 0 < len(layers) <= 128: raise ValueError('Invalid OCI layer count')
    for layer in layers:
        if layer.get('mediaType') not in ['application/vnd.oci.image.layer.v1.tar', 'application/vnd.oci.image.layer.v1.tar+gzip']:
            raise ValueError('Unsupported OCI layer encoding')
        blob(destination, layer)

def cleanup_oci():
    with tempfile.TemporaryFile() as output:
        try: subprocess.run(['runc','delete','--force','agentos-backend'],stdout=output,stderr=output,timeout=5)
        except (OSError, subprocess.TimeoutExpired): pass

def prepare_oci(entry):
    archive = Path(entry)
    bundle = archive.parent/'oci-bundle'
    cleanup_oci()
    if not bundle.exists():
        layout = Path(tempfile.mkdtemp(prefix='agentos-oci-'))
        try:
            verified_layout(archive, layout)
            with tempfile.TemporaryFile() as output:
                result = subprocess.run(['umoci','unpack','--image',str(layout)+':app',str(bundle)],stdout=output,stderr=output,timeout=45)
                if result.returncode:
                    output.seek(0)
                    raise ValueError('OCI unpack failed: '+output.read(2000).decode('utf8','replace'))
            configuration = read_json(bundle/'config.json')
            configuration['process']['terminal'] = False
            configuration['process']['noNewPrivileges'] = True
            configuration['linux']['resources'] = {'memory': {'limit': 768*1024*1024}, 'pids': {'limit': 128}}
            # The only persistent mount is guest-local storage; no host directory or socket exists.
            os.makedirs('/workspace/data',exist_ok=True)
            configuration.setdefault('mounts',[]).append({'destination':'/data','type':'bind','source':'/workspace/data','options':['rbind','rw','nosuid','nodev']})
            (bundle/'config.json').write_text(json.dumps(configuration))
        except Exception:
            shutil.rmtree(bundle,ignore_errors=True)
            raise
        finally: shutil.rmtree(layout,ignore_errors=True)
    return ['runc','run','--bundle',str(bundle),'agentos-backend']

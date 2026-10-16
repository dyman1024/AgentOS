"""Run in the Alpine arm64 image builder to create a tiny, local OCI integration fixture."""
import hashlib
import io
import json
from pathlib import Path
import tarfile

def tar_bytes(files):
    output=io.BytesIO()
    with tarfile.open(fileobj=output,mode='w') as tar:
        for name,(content,mode) in files.items():
            item=tarfile.TarInfo(name);item.size=len(content);item.mode=mode;item.mtime=0
            tar.addfile(item,io.BytesIO(content))
    return output.getvalue()

script=b'''#!/bin/busybox sh
n=0
while IFS= read -r line; do
  id=$(printf '%s' "$line" | /bin/busybox sed -n 's/.*"id": *"\\([^"]*\\)".*/\\1/p')
  case "$line" in *'"count"'*) n=$((n+1)); result=$n;; *) result=42;; esac
  printf '{"id":"%s","result":%s}\\n' "$id" "$result"
done
'''
files={'bin/busybox':(Path('/bin/busybox').read_bytes(),0o755),'server.sh':(script,0o755)}
for lib in Path('/lib').glob('*musl*.so*'): files['lib/'+lib.name]=(lib.read_bytes(),0o755)
layer=tar_bytes(files); blobs={}
def descriptor(data,kind):
    digest=hashlib.sha256(data).hexdigest();blobs['blobs/sha256/'+digest]=(data,0o644)
    return {'mediaType':kind,'digest':'sha256:'+digest,'size':len(data)}
config=json.dumps({'architecture':'arm64','os':'linux','config':{'Entrypoint':['/bin/busybox','sh','/server.sh'],'Env':['PATH=/bin'],'WorkingDir':'/'},'rootfs':{'type':'layers','diff_ids':['sha256:'+hashlib.sha256(layer).hexdigest()]}}).encode()
manifest=json.dumps({'schemaVersion':2,'mediaType':'application/vnd.oci.image.manifest.v1+json','config':descriptor(config,'application/vnd.oci.image.config.v1+json'),'layers':[descriptor(layer,'application/vnd.oci.image.layer.v1.tar')]}).encode()
reference=descriptor(manifest,'application/vnd.oci.image.manifest.v1+json');reference['annotations']={'org.opencontainers.image.ref.name':'app'}
blobs['index.json']=(json.dumps({'schemaVersion':2,'manifests':[reference]}).encode(),0o644)
blobs['oci-layout']=(b'{"imageLayoutVersion":"1.0.0"}',0o644)
Path('/output/backend.oci.tar').write_bytes(tar_bytes(blobs))
print('Created local linux/arm64 OCI test fixture')

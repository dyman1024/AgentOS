import hashlib
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parent.parent/'vm'))
from oci import verified_layout

class ImageLayoutTests(unittest.TestCase):
    def archive(self, directory, *, tamper=False, architecture='arm64', unsafe=False):
        files={}
        def descriptor(value, media):
            content=value if isinstance(value,bytes) else json.dumps(value).encode()
            digest=hashlib.sha256(content).hexdigest();files['blobs/sha256/'+digest]=content
            return {'digest':'sha256:'+digest,'size':len(content),'mediaType':media}
        manifest={'schemaVersion':2,'config':descriptor({'architecture':architecture,'os':'linux'},'application/vnd.oci.image.config.v1+json'), 'layers':[descriptor(b'layer fixture','application/vnd.oci.image.layer.v1.tar')]}
        ref=descriptor(manifest,'application/vnd.oci.image.manifest.v1+json')
        ref['annotations']={'org.opencontainers.image.ref.name':'app'}
        files['index.json']=json.dumps({'schemaVersion':2,'manifests':[ref]}).encode()
        files['oci-layout']=b'{"imageLayoutVersion":"1.0.0"}'
        if tamper: files['blobs/sha256/'+ref['digest'][7:]]=b'x'*ref['size']
        if unsafe: files['../escaped']=b'outside'
        path=directory/'image.tar'
        with tarfile.open(path,'w') as tar:
            for name,data in files.items():
                member=tarfile.TarInfo(name);member.size=len(data);tar.addfile(member,io.BytesIO(data))
        return path
    def verify(self, **options):
        with tempfile.TemporaryDirectory() as raw:
            directory=Path(raw);target=directory/'layout';target.mkdir()
            verified_layout(self.archive(directory,**options),target)
    def test_verifies_content_addressed_layout(self): self.verify()
    def test_rejects_digest_tampering(self):
        with self.assertRaisesRegex(ValueError,'digest mismatch'): self.verify(tamper=True)
    def test_rejects_other_architecture(self):
        with self.assertRaisesRegex(ValueError,'linux/arm64'): self.verify(architecture='amd64')
    def test_outer_tar_cannot_escape(self):
        with self.assertRaisesRegex(ValueError,'Unsafe'): self.verify(unsafe=True)

if __name__ == '__main__': unittest.main()

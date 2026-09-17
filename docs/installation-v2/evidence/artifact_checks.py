"""Read-only archive and assembled-app checks; never executes vendor code."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import struct
import zipfile

ROOT = Path(__file__).resolve().parents[3]
EVIDENCE = Path(__file__).resolve().parent

def tree_hash(root):
    digest = hashlib.sha256()
    paths = []
    for base, dirs, files in os.walk(root):
        dirs[:] = sorted(d for d in dirs if not d.startswith('.'))
        paths.extend(Path(base)/f for f in files if not f.startswith('.'))
    for path in sorted(paths):
        digest.update(path.relative_to(root).as_posix().encode()+b'\0')
        digest.update((b'symlink\0'+os.readlink(path).encode()) if path.is_symlink() else path.read_bytes())
        digest.update(b'\0')
    return digest.hexdigest()

for app in [ROOT/'.build/iossim/final-setup-payload-retest/IOSSim.app', EVIDENCE/'iossim-mount/IOSSim.app']:
    if not app.exists():
        print('MISSING', app)
        continue
    print('APP', str(app.relative_to(ROOT)), 'treeHash', tree_hash(app))
    for rel in ['Contents/Info.plist','Contents/Resources/BuildProvenance.plist']:
        print(rel, json.dumps(plistlib.loads((app/rel).read_bytes()), default=str))

resources = EVIDENCE/'vanish-mount/Vanish.app/Contents/Resources'
for ipa in sorted((resources/'vanish-ipa').glob('*.ipa')):
    with zipfile.ZipFile(ipa) as z:
        for info in z.namelist():
            if not info.endswith('Info.plist'):
                continue
            pl = plistlib.loads(z.read(info))
            exe = info.rsplit('/',1)[0]+'/'+pl.get('CFBundleExecutable','')
            if exe not in z.namelist():
                continue
            b = z.read(exe)
            if b[:4] != b'\xcf\xfa\xed\xfe':
                print('UNPARSED_MACHO',exe)
                continue
            pos=32
            result={'ipa':ipa.name,'path':exe,'sha256':hashlib.sha256(b).hexdigest(),'entitlements':None,'encrypted':None,'libraries':[]}
            for _ in range(struct.unpack_from('<I',b,16)[0]):
                cmd,size=struct.unpack_from('<II',b,pos)
                if cmd==0x2c:
                    result['encrypted']=bool(struct.unpack_from('<I',b,pos+16)[0])
                if cmd in (12,0x80000018,0x8000001f):
                    off=struct.unpack_from('<I',b,pos+8)[0]
                    result['libraries'].append(b[pos+off:pos+size].split(b'\0')[0].decode(errors='replace'))
                if cmd==0x1d:
                    off,length=struct.unpack_from('<II',b,pos+8)
                    sig=b[off:off+length]
                    if len(sig)>=12 and struct.unpack_from('>I',sig,0)[0]==0xfade0cc0:
                        for index in range(struct.unpack_from('>I',sig,8)[0]):
                            kind,offset=struct.unpack_from('>II',sig,12+8*index)
                            magic,blen=struct.unpack_from('>II',sig,offset)
                            if magic==0xfade7171:
                                result['entitlements']=plistlib.loads(sig[offset+8:offset+blen])
                pos+=size
            print(json.dumps(result,default=str))

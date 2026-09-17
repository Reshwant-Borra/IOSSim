"""Static metadata only. Does not execute vendor code or inspect user state."""
import hashlib
import json
from pathlib import Path
import plistlib
import re
import struct
import sys
import zipfile

OUT = Path(__file__).resolve().parent
ROOT = OUT / 'vanish-mount/Vanish.app/Contents'
def sha(data):
    return hashlib.sha256(data).hexdigest()
def archive():
    blob = (ROOT / 'Resources/app.asar').read_bytes()
    header = json.loads(blob[16:16+struct.unpack_from('<I', blob, 12)[0]])
    base = 8 + struct.unpack_from('<I', blob, 4)[0]
    entries = {}
    def walk(tree, prefix=''):
        for name, item in tree.items():
            path = prefix + name
            if 'files' in item:
                walk(item['files'], path + '/')
            else:
                entries[path] = item
    walk(header['files'])
    return blob, base, entries

if sys.argv[1] == 'inventory':
    rows = []
    for path in sorted(ROOT.rglob('*')):
        if path.is_file() and not path.is_symlink():
            rows.append({'path': str(path.relative_to(ROOT)), 'bytes': path.stat().st_size,
                         'sha256': sha(path.read_bytes())})
    blob, base, entries = archive()
    (OUT / 'vanish-bundle-inventory.json').write_text(json.dumps(rows, indent=2)+'\n')
    (OUT / 'vanish-asar-inventory.json').write_text(json.dumps(entries, indent=2)+'\n')
    print(json.dumps({'files':len(rows), 'bytes':sum(r['bytes'] for r in rows), 'asarEntries':len(entries)}))
    print('\n'.join(f'{name}: {item.get("size",0)}' for name,item in entries.items() if 'node_modules/' not in name))
elif sys.argv[1] == 'scan':
    blob, base, entries = archive()
    pattern = re.compile(sys.argv[2], re.I)
    for name, entry in entries.items():
        if 'offset' not in entry or entry.get('unpacked') or 'node_modules/' in name:
            continue
        content = blob[base+int(entry['offset']):base+int(entry['offset'])+entry['size']].decode(errors='replace')
        for number, line in enumerate(content.splitlines(),1):
            matches = sorted(set(m.group() for m in pattern.finditer(line)))
            if matches:
                print(f'{name}:{number}: '+', '.join(matches))
elif sys.argv[1] == 'context':
    blob, base, entries = archive()
    name = 'electron/dist/main/main.js'
    entry = entries[name]
    content = blob[base+int(entry['offset']):base+int(entry['offset'])+entry['size']].decode(errors='replace')
    pattern = re.compile(sys.argv[2], re.I)
    lines=content.splitlines()
    indices=set()
    for index,line in enumerate(lines):
        if pattern.search(line):
            indices.update(range(max(0,index-2),min(len(lines),index+4)))
    for index in sorted(indices)[:220]:
        line=lines[index]
        line=re.sub(r'eyJ[A-Za-z0-9_.-]{40,}', '[REDACTED]', line)
        print(f'{name}:{index+1}: {line[:500]}')
elif sys.argv[1] == 'ipa':
    for path in sorted((ROOT/'Resources/vanish-ipa').glob('*.ipa')):
        print(path.name, sha(path.read_bytes()))
        with zipfile.ZipFile(path) as z:
            for name in z.namelist():
                if name.endswith('Info.plist'):
                    data=plistlib.loads(z.read(name))
                    print(name, json.dumps(data, default=str))
                elif re.search('mobileprovision|entitlements|xctest|framework',name,re.I):
                    print('COMPONENT',name)
elif sys.argv[1] == 'packages':
    for path in sorted((ROOT/'Resources/python').rglob('*.dist-info/METADATA')):
        fields=[line for line in path.read_text(errors='replace').splitlines() if line.startswith(('Name:','Version:','License:','License-Expression:'))]
        print(' | '.join(fields))

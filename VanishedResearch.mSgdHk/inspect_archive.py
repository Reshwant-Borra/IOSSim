"""Read-only packaged-metadata inspection; never execute archive contents."""
import argparse, hashlib, json, pathlib, plistlib, re, struct, zipfile

ROOT = pathlib.Path('/Volumes/Vanish 1/Vanish.app/Contents/Resources')
def asar():
    blob = (ROOT / 'app.asar').read_bytes()
    header_size = struct.unpack_from('<I', blob, 4)[0]
    json_size = struct.unpack_from('<I', blob, 12)[0]
    header = json.loads(blob[16:16 + json_size])
    entries = {}
    def walk(tree, prefix=''):
        for name, item in tree.items():
            path = prefix + name
            if 'files' in item: walk(item['files'], path + '/')
            else: entries[path] = item
    walk(header['files'])
    return blob, 8 + header_size, entries

def clean(s):
    s = re.sub(r'eyJ[A-Za-z0-9_.-]{40,}', '[REDACTED_TOKEN]', s)
    s = re.sub(r'(?i)((?:password|token|secret|api.key)\s*[:=]\s*[\"\x27])[^\"\x27]{16,}', r'\1[REDACTED]', s)
    return s

p = argparse.ArgumentParser()
p.add_argument('mode', choices=['list', 'scan', 'read', 'ipa', 'packages', 'macho', 'inventory', 'strings'])
p.add_argument('--path', default='')
p.add_argument('--pattern', default='')
p.add_argument('--limit', type=int, default=100)
p.add_argument('--start', type=int, default=1)
args = p.parse_args()
if args.mode in ('list', 'scan', 'read'):
    blob, base, entries = asar()
    count = 0
    for name, entry in entries.items():
        if args.path and not re.search(args.path, name): continue
        if args.mode == 'list':
            if 'node_modules/' not in name or name.endswith('package.json'):
                print(name, entry.get('size', 0))
        elif not entry.get('unpacked') and 'offset' in entry:
            raw = blob[base + int(entry['offset']):base + int(entry['offset']) + entry['size']]
            text = raw.decode('utf-8', errors='replace')
            for line_no, line in enumerate(text.splitlines(), 1):
                if args.mode == 'read':
                    if args.start <= line_no < args.start + args.limit: print(f'{name}:{line_no}: {clean(line)}')
                    continue
                matches = list(re.finditer(args.pattern, line, re.I))
                if not matches: continue
                for match in matches[:4]:
                    print(f'{name}:{line_no}: {clean(line[max(0,match.start()-100):match.end()+190])}')
                    count += 1
                    if count >= args.limit: raise SystemExit
elif args.mode == 'ipa':
    for ipa in sorted((ROOT/'vanish-ipa').glob('*.ipa')):
        print('ARCHIVE', ipa.name, ipa.stat().st_size, hashlib.sha256(ipa.read_bytes()).hexdigest())
        with zipfile.ZipFile(ipa) as z:
            for name in z.namelist():
                if name.endswith('Info.plist'):
                    pl = plistlib.loads(z.read(name))
                    print(name, json.dumps(pl, default=str))
                if re.search(r'provision|entitlement|\.framework/|\.xctest/|\.appex/Info', name, re.I): print('COMPONENT', name)
elif args.mode == 'packages':
    for f in sorted((ROOT/'python/lib/python3.13/site-packages').glob('*.dist-info/METADATA')):
        lines = f.read_text(errors='replace').splitlines()
        print(f.parent.name, ' | '.join(x for x in lines if x.startswith(('Name:', 'Version:', 'License:', 'License-Expression:', 'Home-page:'))))
elif args.mode == 'strings':
    if args.path == 'sideloader':
        b=(ROOT/'sideloader/VanishSideloader').read_bytes()
    else:
        with zipfile.ZipFile(ROOT/'vanish-ipa/Vanish.ipa') as z: b=z.read('Payload/StikDebug.app/StikDebug')
    hits=[]
    for bs in re.findall(rb'[\x20-\x7e]{5,}',b):
        s=bs.decode('ascii')
        for m in re.finditer(args.pattern,s,re.I):
            hit=clean(s[max(0,m.start()-70):m.end()+150])
            if hit not in hits: hits.append(hit)
    print('UNIQUE_MATCHES',len(hits))
    for s in hits[:args.limit]: print(s)
elif args.mode == 'macho':
    for ipa in sorted((ROOT/'vanish-ipa').glob('*.ipa')):
        if args.path and not re.search(args.path,ipa.name): continue
        with zipfile.ZipFile(ipa) as z:
            name = 'Payload/StikDebug.app/StikDebug'
            b = z.read(name)
            print('MACHO', ipa.name, name, len(b), hashlib.sha256(b).hexdigest())
            if b[:4] != b'\xcf\xfa\xed\xfe':
                print('UNSUPPORTED HEADER', b[:4].hex()); continue
            ncmds = struct.unpack_from('<I', b, 16)[0]
            pos = 32
            for _ in range(ncmds):
                cmd, size = struct.unpack_from('<II', b, pos)
                if cmd in (12, 0x80000018, 0x8000001f, 13):
                    off = struct.unpack_from('<I', b, pos+8)[0]
                    print('DYLIB', b[pos+off:pos+size].split(b'\0')[0].decode(errors='replace'))
                if cmd == 2:
                    symoff,nsyms,stroff,strsize = struct.unpack_from('<IIII',b,pos+8)
                    names=[]
                    for j in range(nsyms):
                        idx=struct.unpack_from('<I',b,symoff+j*16)[0]
                        s=b[stroff+idx:b.find(b'\0',stroff+idx)].decode(errors='replace')
                        if re.search(args.pattern,s,re.I) and len(s)<260: names.append(s)
                    print('SYMBOLS_MATCHED',len(names))
                    for s in names[:args.limit]: print(clean(s))
                if cmd == 0x1d:
                    off, length = struct.unpack_from('<II', b, pos+8)
                    sig=b[off:off+length]
                    xml=re.search(b'<\\?xml.*?</plist>',sig,re.S)
                    print('ENTITLEMENTS', plistlib.loads(xml.group()) if xml else 'no XML entitlements found')
                pos+=size
            strs = (x.decode('ascii') for x in re.findall(rb'[\x20-\x7e]{5,}',b))
            hits=[]
            for s in strs:
                for m in re.finditer(args.pattern,s,re.I):
                    hits.append(clean(s[max(0,m.start()-70):m.end()+130]))
            print('STRINGS_MATCHED',len(hits))
            for s in hits[:args.limit]: print(s)
elif args.mode == 'inventory':
    out=pathlib.Path(__file__).parent
    app=ROOT.parent
    rows=[]
    for f in sorted(app.rglob('*')):
        if f.is_file() and not f.is_symlink():
            rows.append({'path':str(f.relative_to(app)),'bytes':f.stat().st_size,'sha256':hashlib.sha256(f.read_bytes()).hexdigest()})
    (out/'bundle-inventory.json').write_text(json.dumps(rows,indent=2)+'\n')
    blob,base,entries=asar()
    (out/'asar-inventory.json').write_text(json.dumps(entries,indent=2)+'\n')
    print('Inventory files',len(rows),'ASAR entries',len(entries),'Total bytes',sum(x['bytes'] for x in rows))

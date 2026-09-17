"""Read-only source/artifact inventory; outputs remain in this research directory.

Never reads credential stores, pairing material, or personal-team state.
"""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent

def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args]).decode()

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()

def capture():
    names = set(git('ls-files', '-z').split('\0'))
    names.update(git('ls-files', '--others', '--exclude-standard', '-z').split('\0'))
    files = []
    for name in sorted(names):
        if not name or name.startswith(('docs/installation-v2/', 'VanishedResearch.', '.iossim-personal-team/')):
            continue
        path = ROOT / name
        if path.is_symlink() or not path.is_file():
            continue
        if '.app/' in name or path.suffix in {'.zip', '.bundle', '.patch'}:
            continue
        files.append({'path': name, 'bytes': path.stat().st_size, 'sha256': digest(path)})
    result = {'root': str(ROOT), 'head': git('rev-parse', 'HEAD').strip(),
              'branch': git('branch', '--show-current').strip(),
              'status': git('status', '--porcelain=v1', '--untracked-files=normal'),
              'remotes': git('remote', '-v'), 'branches': git('branch', '-avv'),
              'tags': git('tag'), 'files': files}
    return result

if __name__ == '__main__':
    baseline = OUT / 'source-baseline.json'
    current = capture()
    if not baseline.exists():
        baseline.write_text(json.dumps(current, indent=2) + '\n')
        print(f'Captured {len(current["files"])} source/document hashes')
    else:
        prior = json.loads(baseline.read_text())
        now = {row['path']: row for row in current['files']}
        changed = [row['path'] for row in prior['files'] if now.get(row['path']) != row]
        print(json.dumps({'baselineFiles': len(prior['files']), 'changedOrMissing': changed,
                          'sameHead': prior['head'] == current['head'],
                          'sameBranch': prior['branch'] == current['branch']}, indent=2))

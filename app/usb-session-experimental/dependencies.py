"""Pinned sources only. Download/build as an ordinary user, never during install."""
import hashlib
import os
from pathlib import Path, PurePosixPath
import tarfile
import urllib.request

SOURCES = {
    'libusb-1.0.30.tar.bz2': ('https://github.com/libusb/libusb/releases/download/v1.0.30/libusb-1.0.30.tar.bz2', 'fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf'),
    'usbredir-0.15.0.tar.xz': ('https://www.spice-space.org/download/usbredir/usbredir-0.15.0.tar.xz', '6dc2a380277688a068191245dac2ab7063a552999d8ac3ad8e841c10ff050961'),
}

def obtain(cache, download=False):
    if not os.getuid() or not os.geteuid():
        raise RuntimeError('never root fetch/build')
    cache = Path(cache); cache.mkdir(parents=True, exist_ok=True)
    for name, (url, expected) in SOURCES.items():
        target = cache/name
        if not target.exists():
            if not download:
                raise RuntimeError('missing pinned archive; use --download as ordinary UID: '+name)
            with urllib.request.urlopen(url, timeout=60) as response:
                data=response.read(16*1024*1024+1)
            if len(data)>16*1024*1024 or hashlib.sha256(data).hexdigest()!=expected:
                raise RuntimeError('download checksum/size mismatch')
            with target.open('xb') as f:f.write(data)
        if target.is_symlink() or not target.is_file() or hashlib.sha256(target.read_bytes()).hexdigest()!=expected:
            raise RuntimeError('archive checksum/type mismatch: '+name)
    return cache

def extract(archive, destination):
    """Reject links, traversal, duplicates and file/parent collisions before writing."""
    destination = Path(destination)
    with tarfile.open(archive, 'r:*') as tar:
        members=tar.getmembers(); kinds={}; total=0
        for member in members:
            path=PurePosixPath(member.name)
            if path.is_absolute() or '..' in path.parts or not path.parts or not (member.isdir() or member.isfile()):
                raise ValueError('unsafe archive member')
            key=str(path)
            if key in kinds:raise ValueError('duplicate archive member')
            kinds[key]=member.isdir();total+=member.size
        if total>128*1024*1024 or len(members)>10000:raise ValueError('archive size bound')
        for key in kinds:
            if any(str(parent) in kinds and not kinds[str(parent)] for parent in PurePosixPath(key).parents):
                raise ValueError('file/parent collision')
        if destination.exists():raise ValueError('fresh extraction destination required')
        destination.mkdir(parents=True)
        for member in members:
            target=destination/member.name
            if member.isdir():target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with tar.extractfile(member) as src, target.open('xb') as dst:dst.write(src.read())
                target.chmod(0o755 if member.mode & 0o111 else 0o644)

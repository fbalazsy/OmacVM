# Third-party sources used by this opt-in build

## Apple Darwin ABI declaration

`activation/darwin_unique.h` and `helper/darwin_unique.h` retain an extracted
`proc_uniqidentifierinfo` declaration/flavor from Apple's
[xnu-12377.1.9 proc_info_private.h](https://github.com/apple-oss-distributions/xnu/blob/xnu-12377.1.9/bsd/sys/proc_info_private.h).
Copyright (c) 2005-2021 Apple Inc. The original notice and dated extraction
notice remain in both headers. These covered portions are **APSL-2.0**, not MIT;
the full license is included in [licenses/APSL-2.0.txt](licenses/APSL-2.0.txt).
The extracted modified source is supplied in this directory under that license.

Verified upstream raw header SHA-256:
`ccc01e88d5bf47bc9c3f5ba3a25c3e6202bbcd7b86aa967af31d714657571c3b`.
Upstream `APPLE_LICENSE` SHA-256:
`e5881019d8766c1e88a5fe1dbca4ba40c78011d41fcb18f6e9f50df60182685b`.
These are public source/license hashes, not local identity pins. This uses a
Darwin SPI; future OS ABI compatibility requires new platform acceptance.
No copied Apple executable or other vendor binary is distributed here.

## Downloaded LGPL libraries

No vendor source archive, executable, object or library is committed here.
`dependencies.py` fetches only the public pinned release archives below, as an
ordinary user, verifies SHA-256, and validates archive members before extraction.
The normal root installation is offline and never downloads or builds anything.

| Component | License | Public archive | SHA-256 |
| --- | --- | --- | --- |
| libusb 1.0.30 | LGPL-2.1-or-later | https://github.com/libusb/libusb/releases/download/v1.0.30/libusb-1.0.30.tar.bz2 | `fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf` |
| usbredir 0.15.0 host/parser | LGPL-2.1-or-later | https://www.spice-space.org/download/usbredir/usbredir-0.15.0.tar.xz | `6dc2a380277688a068191245dac2ab7063a552999d8ac3ad8e841c10ff050961` |

The build retains unmodified upstream source and its original notices. It
copies libusb's `COPYING` and usbredir's `COPYING.LIB` into the private build's
`licenses/` directory. usbredir tools may carry other licensing, but no such
tool is linked or distributed by this contribution. Original upstream authors
and copyright notices remain in the downloaded source.

The native helper links the LGPL libraries statically to avoid root loading
user-owned private dylibs. If distributing a built helper, comply with the LGPL
including the applicable corresponding source, license notices, and linkable
application object files/relink instructions so recipients can modify/relink
the libraries. The build retains `source/helper/build/*.o`, both static
libraries and the printed link command for that purpose. Re-link with the same
objects/system frameworks and a rebuilt compatible library, then ad-hoc sign
only the newly built standalone helper. A modified helper necessarily requires
a rebuilt hash-pinned supervisor and fresh administrator review/installation;
that is a local privilege decision, not a prohibition on modifying the library.

Private profiles/binaries/object files can embed private identity/path values.
Do not publish those as a convenience to satisfy a source offer: prepare an
appropriate reviewed non-personal distribution and its corresponding materials.
This proposal publishes source/build instructions only. The repository-level
third-party notices for runtime libusb/usbredir remain applicable separately.

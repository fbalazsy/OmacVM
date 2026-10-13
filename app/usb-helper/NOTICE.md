# Source and library notices

Native helper sources are distributed under the repository MIT license.

Statically linked libraries:

- libusb 1.0.30 — LGPL-2.1-or-later, https://libusb.info/ . Source release:
  https://github.com/libusb/libusb/releases/tag/v1.0.30
- usbredir 0.15.0 host/parser/filter — LGPL-2.1-or-later, Red Hat and contributors,
  https://www.spice-space.org/usbredir.html . The build does not incorporate the
  GPL standalone usbredir tools.

`build.py` verifies pinned upstream archives and writes complete corresponding
source archives and upstream COPYING texts to `OUT/relink/`, with all helper
application object files in an archive and an executable relinking recipe.
Redistribute this entire directory together with the helper. Reverse engineering
for debugging modifications to the LGPL libraries is not restricted. Replacing
libraries/relinking creates new bytes: ad-hoc sign and explicitly install that
new SHA release; never bypass the root protection policy with a mutable dylib.

The Darwin process-identifier SPI declaration follows Apple's
`xnu-12377.1.9/bsd/sys/proc_info_private.h` (APSL-2.0):
https://github.com/apple-oss-distributions/xnu/blob/xnu-12377.1.9/bsd/sys/proc_info_private.h
Only the required ABI declaration is used; no XNU implementation is linked.
Failure to return the exact structure size fails closed.

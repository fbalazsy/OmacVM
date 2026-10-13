# Administrator installation, upgrade and rollback contract

This is a bounded local developer procedure, not a general installer/updater.
It is never part of normal OmacVM installation. **Do not install fixture builds.**
No privileged action was validated by the ordinary-user fixture suite.

## Preconditions (all required)

1. Independently review the private physical profile, complete native source,
   dependency hashes/licenses, build commands and actual resulting binary hashes.
   Confirm the exact runtime is already available and compatible. A profile
   change, VM update, new argv, changed device descriptors or new CDHash is a
   new administrator decision, not an automatically trusted update.
2. Trust the administrator and pinned ordinary account as described in README.
   Exclude concurrent root installers/administrators during installation. The
   procedure does not arbitrate against a malicious root or hostile same-UID
   loaded code. Keep the ordinary output tree private (0700) and frozen during
   review; retain a separately recorded reviewed script hash and payload hashes.
3. Stop the session and wait for actual child reap/release; reconcile any
   `root_pending`, `UNCONFIRMED`, protected socket, manifest or unknown QMP
   ownership. The installer does not prove that an old session has stopped.
   Do not delete a socket or clear a quarantine just because its process seems
   absent. An uncertain root supervisor may intentionally keep running.
4. `/`, `/Library`, and `/Library/PrivilegedHelperTools` must already be real
   root-owned directories, without group/world write, special permission bits
   or ACLs. The installer refuses otherwise; it does not repair ancestors.
   Native runtime traverses ancestors with `openat`/`O_NOFOLLOW`, validates
   metadata and rejects write-granting ACLs. Do not use symlink substitutes.
5. Keep separately verified backups of any previous exact addon payloads,
   reviewed profile/build and relevant journals. There is no app replacement,
   launch job, sudoers grant, USB autostart or network fetch in this procedure.

## Review and install a physical build

Build entirely as the ordinary user. The resulting `install-reviewed.sh`
embeds the pinned UID, exact source/destination paths and the two *actual*
compiled hashes. Read it; compare those hashes with the reviewed binaries.
The helper's hash is also compiled into the supervisor. Do not edit the
script/hash/header to make a mismatched build pass.

Use an administrator-controlled root-owned 0700 staging directory under
protected ancestry. Copy the reviewed script there, remove inherited ACLs,
set root ownership and 0500 mode, then verify **the staged script's SHA-256
against the separately recorded reviewed digest** before executing that staged
copy with `/bin/bash` via explicit sudo. Do not execute a user-writable script
as root. These staging/verification steps are the administrator's responsibility;
no supplied command silently creates root trust from a runtime profile.

The script accepts no arguments or runtime configuration. It requires real
root execution via sudo from the compiled profile's ordinary UID. It copies
payload inputs into a fresh root-owned 0700 directory, verifies those staged
bytes and signatures, then publishes fixed filenames, sets `uchg`, and verifies
final hashes, signatures, ownership, modes, ACL absence and link count. It
executes neither payload while root. No Python, source compilation, network,
QMP, USB, service operation or app signing occurs in the root script.

Installed hierarchy:

| Target under `/Library/PrivilegedHelperTools` | Owner / mode / role |
| --- | --- |
| `org.omacvm.usb-session-experimental-helper` | root, 0555, one regular link, `uchg` |
| `org.omacvm.usb-session-experimental-activate` | root, 0555, one regular link, `uchg` |
| `org.omacvm.usb-session-experimental/` | root, 0711, no ACL |
| `.../run/` | root, 0711, no ACL; no ordinary unlink permission |
| `.../activation.lock` | native-created root 0600, stable arbitration/quarantine inode |
| `.../peer.conf` | native-created root 0400 immutable bounded generation manifest |
| `.../run/usb.sock` | native-created pinned ordinary UID/GID 0600, supervisor-owned inode lifecycle |

A complete identical installation is verified and returns without changing
anything. Existing different bytes, metadata or a partial install cause refusal.
Publication is not an atomic two-binary transaction: if a step fails, the
administrator must examine the partial state. The script never guesses which
old state is safe to remove and never overwrites rollback material.

After installation, compare the installed metadata and exact hashes with the
reviewed build, then use the ordinary-user controller's build/hash check and
native `--inspect` as part of a separately authorized acceptance. Do not use
successful install output as proof that USB or VM admission works. Real
acceptance needs a dedicated test VM/device and the negative identity tests,
normal-user guest reads, explicit stop/restart, unplug/replug, and crash/release
recovery. No firmware/calibration write is needed or authorized by these docs.

## Upgrade/removal/rollback responsibilities

* Obtain separate approval, stop the controller, confirm native supervisor and
  helper exit/reap, and reconcile every journal/QMP object first. `stop` failing
  is a blocker, not an instruction to kill arbitrary PIDs or delete files.
* An owned QMP object may be removed only with retained attribution and the
  confirmed release rules. Unknown create/delete outcomes require manual
  investigation on the exact VM; do not replay a mutation or delete by a
  matching label alone.
* Only after authority is resolved may the administrator remove immutable
  flags from **these exact two protected regular files**, archive/remove them,
  and remove known state entries with reviewed ownership/inode evidence.
  Never use recursive deletion, globbed removal, automatic stale unlink or
  unlink/recreate the arbitration lock to get past a refusal.
* Preserve quarantine and generation evidence until reconciled. If physical
  HID restoration is uncertain, leave the addon disabled and inspect the
  device/host separately. Closed handles are not proof of restored hardware.
* For rollback, verify and reinstall the previous *matched* helper/supervisor
  pair and its corresponding private profile/user controller. Do not mix
  old/new fd-handoff/release ABIs. Re-check actual installed hashes before
  any new activation. The app, runtime, netd and VM files are untouched by this
  addon; rollback must not change them as a side effect.
* If a partial install or unresolved authority cannot be proved safe, stop.
  There is intentionally no automatic uninstall/repair or force option.

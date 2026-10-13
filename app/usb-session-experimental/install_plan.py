"""Generate a reviewable offline install script, never execute it from Python."""
import hashlib
from pathlib import Path
import shlex
from profile import validate, BASE, NAMESPACE


def render(profile, helper, activator):
    validate(profile)
    if profile['kind'] != 'physical':
        raise ValueError('fixture profiles are not installable')
    helper=Path(helper).resolve(strict=True);activator=Path(activator).resolve(strict=True)
    values={'UID_PIN':str(profile['uid']), 'BASE':BASE, 'STATE':BASE+'/'+NAMESPACE,
            'HELPER':BASE+'/'+NAMESPACE+'-helper','ACTIVATE':BASE+'/'+NAMESPACE+'-activate',
            'HELPER_SOURCE':str(helper),'ACTIVATE_SOURCE':str(activator),
            'HELPER_SHA':hashlib.sha256(helper.read_bytes()).hexdigest(),
            'ACTIVATE_SHA':hashlib.sha256(activator.read_bytes()).hexdigest()}
    script='#!/bin/bash\n# Generated offline. Review bytes + hashes; execute only a protected copy.\nset -euo pipefail\nPATH=/usr/bin:/bin:/usr/sbin:/sbin\nexport PATH\numask 077\n'
    script+=''.join(key+'='+shlex.quote(value)+'\n' for key,value in values.items())
    return script+r'''
fail() { printf '%s\n' "$*" >&2; exit 1; }
[[ $# == 0 && $EUID == 0 && ${SUDO_UID:-} == "$UID_PIN" ]] || fail 'Explicit reviewed installation by pinned UID only'
secure_directory() {
  local p=$1 uid mode listing
  [[ -d $p && ! -L $p ]] || fail "Not a real directory: $p"
  uid=$(/usr/bin/stat -f %u "$p"); mode=$(/usr/bin/stat -f %OLp "$p")
  [[ $uid == 0 ]] && (( (8#$mode & 0022) == 0 && (8#$mode & 07000) == 0 )) || fail "Unprotected directory: $p"
  listing=$(/bin/ls -lde "$p")
  [[ $listing != *$'\n'* ]] || fail "Directory has ACL: $p; do not change ancestors automatically"
}
verify_hash() {
  local actual
  actual=$(/usr/bin/shasum -a 256 "$1"); actual=${actual%% *}
  [[ $actual == "$2" ]] || fail "SHA-256 mismatch: $1"
}
verify_payload() {
  local p=$1 expected=$2
  [[ -f $p && ! -L $p ]] || fail "Not a regular payload: $p"
  [[ $(/usr/bin/stat -f '%u:%OLp:%l' "$p") == '0:555:1' ]] || fail "Payload metadata mismatch: $p"
  [[ $(/usr/bin/stat -f %Sf "$p") == *uchg* ]] || fail "Missing immutable flag: $p"
  [[ $(/bin/ls -lde "$p") != *$'\n'* ]] || fail "Payload ACL found: $p"
  /usr/bin/codesign --verify --strict "$p"
  verify_hash "$p" "$expected"
}
for p in / /Library "$BASE"; do secure_directory "$p"; done
# Exact complete rerun is a read-only no-op. Partial or different install refuses.
if [[ -e $STATE || -L $STATE || -e $HELPER || -L $HELPER || -e $ACTIVATE || -L $ACTIVATE ]]; then
  secure_directory "$STATE"; secure_directory "$STATE/run"
  [[ $(/usr/bin/stat -f %OLp "$STATE") == 711 && $(/usr/bin/stat -f %OLp "$STATE/run") == 711 ]] || fail 'State mode mismatch'
  verify_payload "$HELPER" "$HELPER_SHA"; verify_payload "$ACTIVATE" "$ACTIVATE_SHA"
  printf '%s\n' 'Exact inert payload installation already present; nothing changed'
  exit 0
fi
stage=$(/usr/bin/mktemp -d "$BASE/.org.omacvm.usb-session.stage.XXXXXX")
trap '/bin/rm -f "$stage/helper" "$stage/activate"; /bin/rmdir "$stage"' EXIT
/bin/chmod -N "$stage"; /bin/chmod 0700 "$stage"; /usr/sbin/chown 0:0 "$stage"
# Copy untrusted user-side input into root staging; then verify staged bytes.
/usr/bin/install -o root -g wheel -m 0555 "$HELPER_SOURCE" "$stage/helper"
/usr/bin/install -o root -g wheel -m 0555 "$ACTIVATE_SOURCE" "$stage/activate"
for p in "$stage/helper" "$stage/activate"; do
  /bin/chmod -N "$p"
  /usr/bin/codesign --verify --strict "$p"
done
verify_hash "$stage/helper" "$HELPER_SHA"; verify_hash "$stage/activate" "$ACTIVATE_SHA"
/usr/bin/install -d -o root -g wheel -m 0711 "$STATE" "$STATE/run"
/bin/chmod -N "$STATE" "$STATE/run"
secure_directory "$STATE"; secure_directory "$STATE/run"
/bin/mv "$stage/helper" "$HELPER"
/bin/mv "$stage/activate" "$ACTIVATE"
/usr/bin/chflags uchg "$HELPER" "$ACTIVATE"
verify_payload "$HELPER" "$HELPER_SHA"; verify_payload "$ACTIVATE" "$ACTIVATE_SHA"
printf '%s\n' 'Installed inert payloads only. No launch job, authorization rule, app change or activation.'
'''

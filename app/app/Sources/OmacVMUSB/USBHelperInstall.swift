import Foundation

/// App-owned bootstrap, passed INLINE to the system authorization shell. No root
/// execution from the bundle or a user-writable script. The administrator trusts
/// this local account/app; SHA here proves staged bytes, not publisher identity.
public enum USBHelperInstall {
    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func appleScript(_ command: String) -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
        return "with timeout of 2147483647 seconds\ndo shell script \"" + escaped + "\" with administrator privileges\nend timeout"
    }
    public static func command(source: String, sha256: String, attempt: UUID, app: USBProcessIdentity) throws -> String {
        guard source.hasPrefix("/"), !source.utf8.contains(0), sha256.count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }), app.valid else {
            throw USBNativeError("Invalid privileged helper bootstrap input")
        }
        let root = USBNativeWire.root, release = root + "/releases/" + sha256
        let executable = release + "/omacvm-usb-helper"
        // Check every ancestor before using it. A private root staging directory
        // is hashed AFTER copying, then renamed into the immutable version path.
        // Existing releases are never replaced, executed on mismatch, or blindly removed.
        return """
        set -eu
        PATH=/usr/bin:/bin:/usr/sbin:/sbin
        LC_ALL=C
        export PATH LC_ALL
        unset PERL5LIB PERL5OPT ENV BASH_ENV CDPATH DYLD_LIBRARY_PATH DYLD_INSERT_LIBRARIES
        umask 077
        protected_dir() {
          [ ! -L "$1" ] && [ -d "$1" ] && [ "$(/usr/bin/stat -f %u "$1")" = 0 ] || exit 71
          mode=$(/usr/bin/stat -f %Lp "$1")
          [ $((0$mode & 022)) -eq 0 ] || exit 71
          # Root ownership/POSIX mode alone do not exclude cross-UID ACL writes.
          # Match native ancestry policy BEFORE using paths, never repair system ACLs.
          acl=$(/bin/ls -lde "$1") || exit 71
          printf '%s\\n' "$acl" | /usr/bin/awk '
            NR == 1 { next }
            $1 ~ /^[0-9]+:$/ && ($3 == "deny" || ($3 == "inherited" && $4 == "deny")) { next }
            { exit 1 }
          ' || exit 71
        }
        protected_dir /Library
        if [ ! -e /Library/PrivilegedHelperTools ] && [ ! -L /Library/PrivilegedHelperTools ]; then
          /usr/bin/install -d -o root -g wheel -m 0755 /Library/PrivilegedHelperTools
        fi
        protected_dir /Library/PrivilegedHelperTools
        for d in \(quote(root)) \(quote(root + "/releases")); do
          if [ ! -e "$d" ] && [ ! -L "$d" ]; then /usr/bin/install -d -o root -g wheel -m 0755 "$d"; fi
          protected_dir "$d"
          /bin/chmod -N "$d"
        done
        run=\(quote(root + "/run"))
        if [ ! -e "$run" ] && [ ! -L "$run" ]; then /usr/bin/install -d -o root -g wheel -m 0711 "$run"; fi
        protected_dir "$run"
        /bin/chmod -N "$run"
        /bin/chmod 0711 "$run"
        release=\(quote(release))
        executable=\(quote(executable))
        if [ ! -e "$release" ] && [ ! -L "$release" ]; then
          stage=$(/usr/bin/mktemp -d \(quote(root + "/releases/.stage.XXXXXXXX")))
          protected_dir "$stage"
          /usr/bin/install -o root -g wheel -m 0555 \(quote(source)) "$stage/omacvm-usb-helper"
          /bin/chmod -N "$stage/omacvm-usb-helper"
          digest=$(/usr/bin/shasum -a 256 "$stage/omacvm-usb-helper")
          [ "${digest%% *}" = \(quote(sha256)) ] || exit 72
          /bin/chmod 0755 "$stage"
          /bin/mv -n "$stage" "$release"
        fi
        protected_dir "$release"
        /bin/chmod -N "$release"
        [ ! -L "$executable" ] && [ -f "$executable" ] && [ "$(/usr/bin/stat -f %u:%Lp "$executable")" = 0:555 ] || exit 73
        # Reject ALLOW ACLs before chmod/hash/exec: stripping an unsafe leaf's
        # ACL cannot revoke writable descriptors already open on that inode.
        acl=$(/bin/ls -lde "$executable") || exit 73
        printf '%s\\n' "$acl" | /usr/bin/awk '
          NR == 1 { next }
          $1 ~ /^[0-9]+:$/ && ($3 == "deny" || ($3 == "inherited" && $4 == "deny")) { next }
          { exit 1 }
        ' || exit 73
        /bin/chmod -N "$executable"
        digest=$(/usr/bin/shasum -a 256 "$executable")
        [ "${digest%% *}" = \(quote(sha256)) ] || exit 74
        exec \(quote(executable)) --session \(quote(attempt.uuidString.lowercased())) \(app.uid) \(app.pid) \(app.startSec) \(app.startUsec) \(app.version)
        """
    }
}

"""Offline USBredir recipe tests; no downloads, QEMU build or guest starts.

Run with python3 app/runtime/Tests/usbredir/test-runtime.py.
Shell fragments are read, then executed in private temporary directories: never
source the build/packaging scripts, whose top-level code builds and publishes.
These tests do not establish that the complete source stack compiles.
"""
import io
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import unittest

RUNTIME = Path(__file__).resolve().parents[2]
BUILD = RUNTIME / "build-qemu-gpu-runtime.sh"
PREPARE = RUNTIME / "prepare-qemu-gpu-runtime.sh"


def shell_function(path, name):
    match = re.search(r"^" + re.escape(name) + r"\(\) \{\n.*?^\}",
                      path.read_text(), re.M | re.S)
    if not match:
        raise AssertionError(f"missing source function: {name}")
    return match.group(0)


def bash(script, *args, env=None):
    return subprocess.run(["/bin/bash", "-eu", "-o", "pipefail", "-c", script,
                           "usbredir-test", *map(str, args)],
                          text=True, capture_output=True, env=env, timeout=20)


class ArchiveValidation(unittest.TestCase):
    def test_only_safe_source_members_are_accepted(self):
        function = shell_function(BUILD, "validate_usbredir_archive")
        root = "usbredir-0.15.0"
        cases = {
            "valid": [(root, tarfile.DIRTYPE), (root + "/COPYING.LIB", tarfile.REGTYPE)],
            "empty": [],
            "dot-root": [(".", tarfile.DIRTYPE)],
            "absolute": [("/" + root + "/bad", tarfile.REGTYPE)],
            "traversal": [(root + "/../bad", tarfile.REGTYPE)],
            "wrong-root": [("other/file", tarfile.REGTYPE)],
            "symlink": [(root + "/link", tarfile.SYMTYPE)],
            "hardlink": [(root + "/link", tarfile.LNKTYPE)],
            "fifo": [(root + "/fifo", tarfile.FIFOTYPE)],
            "device": [(root + "/dev", tarfile.CHRTYPE)],
            "duplicate": [(root + "/file", tarfile.REGTYPE)] * 2,
            "case-collision": [(root + "/file", tarfile.REGTYPE),
                               (root + "/FILE", tarfile.REGTYPE)],
            "file-parent": [(root + "/file", tarfile.REGTYPE),
                            (root + "/file/child", tarfile.REGTYPE)],
            "root-file": [(root, tarfile.REGTYPE)],
            "dot": [(root + "/./file", tarfile.REGTYPE)],
            "control": [(root + "/line\nbreak", tarfile.REGTYPE)],
            "backslash": [(root + "/dir\\file", tarfile.REGTYPE)],
        }
        with tempfile.TemporaryDirectory(prefix="usbredir-archive-") as directory:
            archive = Path(directory) / "source.tar.xz"
            for name, members in cases.items():
                with self.subTest(name=name):
                    with tarfile.open(archive, "w:xz") as tar:
                        for filename, kind in members:
                            member = tarfile.TarInfo(filename)
                            member.type = kind
                            member.linkname = "../../outside" if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE) else ""
                            member.size = 1 if kind == tarfile.REGTYPE else 0
                            tar.addfile(member, io.BytesIO(b"x") if member.size else None)
                    result = bash(function + '\nvalidate_usbredir_archive "$1" "$2"', archive, root)
                    if name == "valid":
                        self.assertEqual(result.returncode, 0, result.stderr)
                    else:
                        self.assertNotEqual(result.returncode, 0, name)
                        self.assertIn("usbredir archive", result.stderr)
            archive.write_bytes(b"not an xz archive")
            result = bash(function + '\nvalidate_usbredir_archive "$1" "$2"', archive, root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("usbredir archive", result.stderr)


class SourceRecipe(unittest.TestCase):
    def test_pinned_private_build_and_test_before_qemu(self):
        source = BUILD.read_text()
        for token in (
            "usbredir_version=0.15.0",
            'usbredir_source_root="usbredir-$usbredir_version"',
            'usbredir_archive_name="$usbredir_source_root.tar.xz"',
            'usbredir_url="https://www.spice-space.org/download/usbredir/$usbredir_archive_name"',
            "usbredir_sha256=6dc2a380277688a068191245dac2ab7063a552999d8ac3ad8e841c10ff050961",
            'obtain_and_verify "usbredir source" "$usbredir_url" "$usbredir_sha256" "$usbredir_archive"',
            'validate_usbredir_archive "$usbredir_archive" "$usbredir_source_root"',
            'tar -xf "$usbredir_archive" -C "$source_parent"',
        ):
            self.assertIn(token, source)
        self.assertLess(source.index('obtain_and_verify "usbredir source"'),
                        source.index('validate_usbredir_archive "$usbredir_archive"'))
        self.assertLess(source.index('validate_usbredir_archive "$usbredir_archive"'),
                        source.index('tar -xf "$usbredir_archive"'))
        block = source[source.index('usbredir_root='):source.index('# Keep the exact graphics fixes')]
        for token in ('"$dependency_root/usbredir/$usbredir_version"',
                      'PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$pkg_config_libdir"',
                      '--prefix="$usbredir_root" --libdir=lib', '--wrap-mode=nodownload',
                      '-Dtools=disabled -Dtests=enabled',
                      '"$ninja" ${ninja_jobs[@]+"${ninja_jobs[@]}"} -C "$usbredir_build"',
                      'test -C "$usbredir_build" --no-rebuild', '--print-errorlogs',
                      '--num-processes "${OMARCHY_RUNTIME_BUILD_JOBS:-4}"',
                      'install -C "$usbredir_build" --no-rebuild',
                      'pkg_config_libdir="$usbredir_root/lib/pkgconfig:$pkg_config_libdir"',
                      'private_libraries="$usbredir_root/lib:$private_libraries"',
                      'require_private_pkg_version libusbredirparser-0.5 "$usbredir_version"'):
            self.assertIn(token, block)
        self.assertLess(block.index('test -C'), block.index('install -C'))
        self.assertIn('--source-usbredir "$usbredir_root/lib/libusbredirparser.1.dylib"', source)
        self.assertIn('--usbredir-license "$source_parent/$usbredir_source_root/COPYING.LIB"', source)

    def test_configure_enables_both_usb_transports_without_losing_features(self):
        source = BUILD.read_text()
        start = source.index('(\n  cd "$build_dir"', source.index('log "Configuring QEMU'))
        fragment = source[start:source.index('\nconfig_host=', start)]
        with tempfile.TemporaryDirectory(prefix="usbredir-configure-") as directory:
            root = Path(directory)
            (root / "build with spaces").mkdir()
            configure = root / "configure"
            configure.write_text('#!/bin/bash\nprintf "%s\\n" "$@"\nprintf "pkgpath=%s\\n" "$PKG_CONFIG_PATH"\nprintf "pkglib=%s\\n" "$PKG_CONFIG_LIBDIR"\n')
            configure.chmod(0o755)
            setup = ('build_dir="$1/build with spaces"; work_dir="$1/private prefix"; '
                     'macos_deployment_target=15.0; pkg_config_libdir="$1/private pc"; '
                     'private_libraries="$1/private libs"; ninja="$1/private ninja";\n')
            result = bash(setup + fragment, root)
            self.assertEqual(result.returncode, 0, result.stderr)
            arguments = result.stdout.splitlines()
            for flag in ('--enable-usb-redir', '--enable-libusb', '--enable-hvf',
                         '--enable-cocoa', '--enable-opengl', '--enable-virglrenderer',
                         '--enable-slirp', '--enable-sdl', '--enable-virtfs',
                         '--without-default-features', '--disable-download',
                         '--disable-containers', '--disable-tcg',
                         f'--prefix={root}/private prefix/install', f'--ninja={root}/private ninja',
                         'pkgpath=', f'pkglib={root}/private pc'):
                self.assertIn(flag, arguments)


class Packaging(unittest.TestCase):
    def test_parser_options_preserve_path_boundaries_and_reject_bad_arity(self):
        source = PREPARE.read_text()
        # Stop before any host checks, directory creation or downloads.
        prefix = source[:source.index('native_dir=')]
        probe = prefix + '\nprintf "parser=%s\\nlicense=%s\\n" "$source_usbredir" "$usbredir_license"\n'
        args = ['--source-usbredir', '/private prefix/parser.dylib',
                '--usbredir-license', '/private prefix/COPYING.LIB']
        result = bash(probe, *args)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(),
                         ['parser=/private prefix/parser.dylib', 'license=/private prefix/COPYING.LIB'])
        for bad in (['--source-usbredir'], ['--usbredir-license'],
                    ['--source-usbredir', ''], ['--usbredir-license', ''],
                    ['--source-usbredir', '--help'], ['--usbredir-license', '--help'],
                    args + ['--source-usbredir', '/second'],
                    args + ['--usbredir-license', '/second']):
            with self.subTest(args=bad):
                self.assertEqual(bash(probe, *bad).returncode, 64)

    def test_parser_and_license_require_absolute_regular_files(self):
        source = PREPARE.read_text()
        self.assertIn('[[ $source_usbredir == /*', source)
        start = source.index('[[ $source_usbredir == /*')
        fragment = source[start:source.index('[[ -n $source_virgl ]]', start)]
        script = ('source_usbredir=$1; usbredir_license=$2;\n' +
                  shell_function(PREPARE, 'die') + '\n' + fragment)
        with tempfile.TemporaryDirectory(prefix='usbredir-input-') as directory:
            root = Path(directory)
            parser, license_file = root / 'parser library', root / 'license text'
            parser.write_bytes(b'parser fixture')
            license_file.write_text('license fixture')
            link = root / 'link'; link.symlink_to(license_file)
            empty = root / 'empty'; empty.touch()
            for library, notice, valid in (
                (parser, license_file, True), (link, license_file, False),
                (root, license_file, False), ('relative', license_file, False),
                (root / 'missing', license_file, False), (parser, link, False),
                (parser, empty, False), (parser, root, False),
                (parser, 'relative', False), (parser, root / 'missing', False),
            ):
                with self.subTest(library=library, notice=notice):
                    result = bash(script, library, notice)
                    self.assertEqual(result.returncode == 0, valid, result.stderr)

    def test_packaging_stages_parser_and_requires_its_license(self):
        source = PREPARE.read_text()
        manifest = (RUNTIME / 'runtime-files.txt').read_text().splitlines()
        self.assertIn('lib/libusbredirparser.1.dylib', manifest)
        self.assertFalse(any('usbredirhost' in name or 'usbredirect' in name for name in manifest))
        start = source.index('install -m 0755 "$source_usbredir"')
        stage = source[start:source.index('install -m 0755 "$source_virgl"', start)]
        verify = shell_function(PREPARE, 'verify_runtime_tree')
        # Exercise the real file-set gate only; later Mach-O/signature/capability
        # gates need a built runtime and must not run against text fixtures.
        verify = verify[:verify.index('  for relative in "${runtime_files[@]}"; do')] + '\n}'
        helpers = '\n'.join((shell_function(PREPARE, 'die'),
                             shell_function(PREPARE, 'is_expected_runtime_file'), verify))
        setup = ('runtime_files=(lib/libusbredirparser.1.dylib); '
                 'vulkan_icds=(share/vulkan/icd.d/MoltenVK_icd.json); source_kosmickrisp=;\n')
        with tempfile.TemporaryDirectory(prefix='usbredir-stage-') as directory:
            root = Path(directory)
            runtime = root / 'runtime with spaces'
            (runtime / 'lib').mkdir(parents=True)
            parser, notice = root / 'parser', root / 'COPYING.LIB'
            parser.write_bytes(b'parser fixture'); notice.write_text('license fixture')
            result = bash('source_usbredir=$1; usbredir_license=$2; staged_runtime=$3;\n' + stage,
                          parser, notice, runtime)
            self.assertEqual(result.returncode, 0, result.stderr)
            packaged = runtime / 'lib/libusbredirparser.1.dylib'
            license_file = runtime / 'share/licenses/LICENSE.usbredir.txt'
            self.assertEqual(packaged.read_bytes(), parser.read_bytes())
            self.assertEqual(license_file.read_bytes(), notice.read_bytes())
            self.assertEqual(packaged.stat().st_mode & 0o777, 0o755)
            self.assertEqual(license_file.stat().st_mode & 0o777, 0o644)
            check = setup + helpers + '\nverify_runtime_tree "$1"'
            self.assertEqual(bash(check, runtime).returncode, 0)
            for invalid in ('missing', 'empty', 'directory', 'symlink'):
                license_file.unlink()
                if invalid == 'empty': license_file.touch()
                elif invalid == 'directory': license_file.mkdir()
                elif invalid == 'symlink': license_file.symlink_to(notice)
                result = bash(check, runtime)
                self.assertNotEqual(result.returncode, 0, invalid)
                if license_file.is_dir(): license_file.rmdir()
                elif license_file.exists() or license_file.is_symlink(): license_file.unlink()
                license_file.write_text('license fixture')
            # Extra host tools are never accepted into the runtime closure.
            (runtime / 'lib/libusbredirhost.1.dylib').write_bytes(b'extra')
            self.assertNotEqual(bash(check, runtime).returncode, 0)

    def test_parser_relocation_uses_existing_library_closure(self):
        source = PREPARE.read_text()
        self.assertIn('"$dependency_bundler" "$staged_runtime"', source)
        self.assertIn('for library in "$staged_runtime/lib"/*.dylib; do', source)
        self.assertIn('codesign --force --sign - "$library"', source)
        helper = RUNTIME / 'bundle-macho-dependencies.sh'
        fragment = shell_function(helper, 'canonical_dependency')
        script = ('bin_dir="/private runtime/bin"; lib_dir="/private runtime/lib";\n' +
                  fragment + '\ncanonical_dependency "$1" libusbredirparser.1.dylib')
        executable = bash(script, '/private runtime/bin/qemu-system-aarch64')
        library = bash(script, '/private runtime/lib/libusbredirparser.1.dylib')
        self.assertEqual(executable.returncode, 0, executable.stderr)
        self.assertEqual(library.returncode, 0, library.stderr)
        self.assertEqual(executable.stdout.strip(), '@executable_path/../lib/libusbredirparser.1.dylib')
        self.assertEqual(library.stdout.strip(), '@loader_path/libusbredirparser.1.dylib')

    def test_capability_gate_requires_redir_and_retains_host(self):
        source = PREPARE.read_text()
        start = source.index('  for device in \\\n', source.index('device_help=$("$qemu" -device help'))
        fragment = source[start:source.index('\n  done', start) + len('\n  done')]
        names = re.findall(r"'name \"([^\"]+)\"'", fragment)
        self.assertIn('usb-redir', names)
        self.assertIn('usb-host', names)
        script = shell_function(PREPARE, 'die') + '\ndevice_help=$1;\n' + fragment
        devices = '\n'.join(f'name "{name}"' for name in names)
        self.assertEqual(bash(script, devices).returncode, 0)
        for missing in ('usb-redir', 'usb-host'):
            result = bash(script, devices.replace(f'name "{missing}"', f'name "{missing}-other"'))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(missing, result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)

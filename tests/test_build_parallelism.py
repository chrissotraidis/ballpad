"""Command-level fixtures only: no compiler, download, engine or device is used."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / "scripts/native"


class BuildParallelismTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ballpad jobs ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.native = self.root / "scripts/native"
        self.native.mkdir(parents=True)
        for name in ("common.sh", "build.sh", "bootstrap.sh"):
            shutil.copyfile(NATIVE / name, self.native / name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.calls = self.root / "calls"
        self.env = os.environ.copy()
        self.env.pop("CMAKE_BUILD_PARALLEL_LEVEL", None)
        self.env.update(PATH=str(self.bin) + os.pathsep + self.env["PATH"],
                        BALLPAD_TEST_CALLS=str(self.calls))
        self.stub("sysctl", 'printf "sysctl %s\\n" "$*" >> "$BALLPAD_TEST_CALLS"; echo 16')
        for name in ("xcrun", "xcodebuild", "cmake", "ninja", "clang"):
            self.stub(name, 'printf "%s %s\\n" "' + name + '" "$*" >> "$BALLPAD_TEST_CALLS"')
        self.stub("otool", 'printf "LC_BUILD_VERSION\\nplatform %s\\n" "$BALLPAD_TEST_PLATFORM"')
        self.stub("git", 'echo "unexpected Git invocation" >&2; exit 91')

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)

    def run_bash(self, command, jobs=None, **extra):
        env = self.env.copy()
        if jobs is not None:
            env["CMAKE_BUILD_PARALLEL_LEVEL"] = jobs
        env.update(extra)
        return subprocess.run(["/bin/bash", "-c", command], env=env,
                              text=True, capture_output=True, timeout=10)

    def helper(self, jobs=None):
        return subprocess.run(
            ["/bin/bash", "-c", 'source "$1"; build_jobs', "fixture", str(self.native / "common.sh")],
            env=dict(self.env, **({"CMAKE_BUILD_PARALLEL_LEVEL": jobs} if jobs is not None else {})),
            text=True, capture_output=True, timeout=10)

    def test_explicit_limit_does_not_query_host_cpu_count(self):
        for jobs in ("1", "2", "8", "16"):
            with self.subTest(jobs=jobs):
                result = self.helper(jobs)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), jobs)
        self.assertFalse(self.calls.exists())

    def test_unset_or_empty_preserves_host_cpu_default(self):
        for jobs in (None, ""):
            with self.subTest(jobs=jobs):
                result = self.helper(jobs)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), "16")

    def test_invalid_limits_stop_both_entry_points_before_tools_or_outputs(self):
        for jobs in ("0", "-1", "02", "two", "2.5", " 2", "2 3"):
            for name, args in (("bootstrap.sh", "--platform device --fetch-only"),
                               ("build.sh", "--platform device --no-bootstrap")):
                with self.subTest(jobs=jobs, entry=name):
                    result = self.run_bash('/bin/bash "' + str(self.native / name) + '" ' + args, jobs)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("CMAKE_BUILD_PARALLEL_LEVEL must be a positive integer", result.stdout + result.stderr)
                    self.assertFalse(self.calls.exists())
                    self.assertFalse((self.root / "build").exists())

    def prepare_build(self, platform):
        (self.root / "work/native/strikers/smstrikers-port").mkdir(parents=True)
        for dependency in ("sdl3/" + platform, "ffmpeg/" + platform):
            (self.root / "build/native/deps" / dependency).mkdir(parents=True)
        for path in ("dawn/CMakeLists.txt", "zstd/build/cmake/CMakeLists.txt"):
            file = self.root / "build/native/deps/src" / path
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text("fixture\n")
        directory = self.root / "build/native" / (platform + "-release")
        directory.mkdir(parents=True)
        if platform == "macos":
            (directory / "strikers").write_text("fixture")
        else:
            app = directory / "BallpadStrikers.app"
            app.mkdir()
            (app / "BallpadStrikers").write_text("fixture")
            (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "BallpadStrikers"}))
        verify = self.native / "verify-clean.sh"
        verify.write_text('#!/bin/sh\nprintf "verify %s\\n" "$*" >> "$BALLPAD_TEST_CALLS"\n')
        verify.chmod(0o755)

    def assert_build(self, platform, jobs, expected):
        self.prepare_build(platform)
        result = self.run_bash('/bin/bash "' + str(self.native / "build.sh") +
                               '" --platform ' + platform + ' --no-bootstrap', jobs,
                               BALLPAD_TEST_PLATFORM={"macos": "1", "simulator": "7", "device": "2"}[platform])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls.read_text().splitlines()
        build = next(line for line in calls if line.startswith("cmake --build "))
        self.assertTrue(build.endswith(" -j " + expected), build)
        self.assertIn("verify --scope source", calls)
        self.assertLess(calls.index("verify --scope source"), calls.index(build))

    def test_device_build_forwards_explicit_limit_and_retains_source_check(self):
        self.assert_build("device", "2", "2")
        self.assertNotIn("sysctl", self.calls.read_text())

    def test_simulator_build_forwards_explicit_limit(self):
        self.assert_build("simulator", "3", "3")

    def test_manual_macos_build_preserves_host_count(self):
        self.assert_build("macos", None, "16")

    def test_failed_source_check_stops_before_cmake(self):
        self.prepare_build("device")
        (self.native / "verify-clean.sh").write_text('#!/bin/sh\nexit 19\n')
        result = self.run_bash('/bin/bash "' + str(self.native / "build.sh") +
                               '" --platform device --no-bootstrap', "2")
        self.assertEqual(result.returncode, 19, result.stdout + result.stderr)
        self.assertFalse(any(line.startswith("cmake ") for line in self.calls.read_text().splitlines()))

    def test_ffmpeg_make_forwards_the_resolved_limit(self):
        source = (self.native / "bootstrap.sh").read_text()
        function = source[source.index("prepare_ffmpeg() {"):source.index("# Dawn, from")]
        assignment = next(line for line in source.splitlines() if line.startswith("JOBS="))
        # Source the actual shared helpers and actual FFmpeg function, but stub
        # downloads, archive extraction, SDK/compiler and make in this scratch root.
        shell = 'source "' + str(self.native / "common.sh") + '"\n' + assignment + '\n' + function + r'''
platform_sysroot() { echo /fixture-sdk; }
sha256_of() { echo "$FFMPEG_SHA256"; }
curl() { :; }
tar() {
    mkdir -p "$work/ffmpeg-$FFMPEG_VERSION"
    printf '#!/bin/sh\nexit 0\n' > "$work/ffmpeg-$FFMPEG_VERSION/configure"
    chmod +x "$work/ffmpeg-$FFMPEG_VERSION/configure"
}
xcrun() { echo /fixture-clang; }
make() {
    printf 'make %s\n' "$*" >> "$BALLPAD_TEST_CALLS"
    if [ "$1" = install ]; then mkdir -p "$out"; fi
}
prepare_ffmpeg device
'''
        result = self.run_bash(shell, "2")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls.read_text().splitlines(), ["make -j2", "make install"])


if __name__ == "__main__":
    unittest.main()

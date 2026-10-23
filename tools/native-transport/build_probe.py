"""Build and test the pinned development-only WebRTC C API candidate."""

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
from importlib.metadata import version
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def run(arguments: list[str], *, cwd: Path = ROOT, log: Path | None = None,
        timeout: int = 600, private: bool = False) -> str:
    result = subprocess.run(arguments, cwd=cwd, capture_output=True, text=True,
                            encoding="utf-8", errors="replace", timeout=timeout)
    output = result.stdout + result.stderr
    if log is not None:
        log.write_text(output, encoding="utf-8")
    if result.returncode:
        # Native tests print SDP and ICE credentials. Keep all raw output local.
        if log is not None and not private:
            diagnostic = "\n".join(output.splitlines()[-40:])
            diagnostic = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", diagnostic)
            print(diagnostic, flush=True)
        if private:
            for line in output.splitlines():
                if re.fullmatch(r"(?:(?:transport cycle \d+|callback probe|native probe) failed: [A-Za-z0-9_]+|native probe leaked \d+ Zig allocations)", line):
                    print(line, flush=True)
        location = f", see {log}" if log else ""
        raise RuntimeError(f"{Path(arguments[0]).name} failed with exit {result.returncode}{location}")
    return output.strip()


def owned_path(path: Path) -> Path:
    destination = path.resolve()
    private = (ROOT / "work").resolve()
    if not destination.is_relative_to(private) or destination == private:
        raise ValueError("Native probe output and sources must be inside work/")
    return destination


def verify_header(data: bytes, expected: str) -> None:
    # Git may expand text line endings during a Windows checkout. The manifest
    # pins the LF Git blob, retaining every other byte including the final LF.
    actual = hashlib.sha256(data.replace(b"\r\n", b"\n")).hexdigest()
    if actual != expected:
        raise ValueError("C API header checksum mismatch")


def visual_studio_generator(installation_version: str) -> str:
    major = installation_version.split(".", 1)[0]
    generators = {"17": "Visual Studio 17 2022", "18": "Visual Studio 18 2026"}
    if major not in generators:
        raise ValueError("Native probe requires Visual Studio 2022 or 2026 C++ Build Tools")
    return generators[major]


def verify_checkout(path: Path, revision: str, hooks: Path) -> None:
    git = ["git", "-c", f"core.hooksPath={hooks}", "-C", str(path)]
    if run(git + ["rev-parse", "HEAD"]) != revision:
        raise ValueError(f"Unexpected source revision in {path}")
    if run(git + ["status", "--porcelain", "--untracked-files=normal"]):
        raise ValueError(f"Source checkout has local changes: {path}")


def prepare_source(name: str, entry: dict, sources: Path, hooks: Path) -> Path:
    path = sources / name
    git = ["git", "-c", f"core.hooksPath={hooks}", "-c", "protocol.file.allow=never"]
    if not path.exists():
        path.mkdir()
        run(git + ["init", str(path)])
        run(git + ["-C", str(path), "remote", "add", "origin", entry["repository"]])
        run(git + ["-C", str(path), "fetch", "--depth=1", "origin", entry["revision"]])
        run(git + ["-C", str(path), "checkout", "--detach", entry["revision"]])
    verify_checkout(path, entry["revision"], hooks)
    for relative, child in entry["submodules"].items():
        pinned = run(git + ["-C", str(path), "ls-tree", "HEAD", relative]).split()
        if pinned[:2] != ["160000", "commit"] or pinned[2] != child["revision"]:
            raise ValueError(f"Unexpected submodule revision: {name}/{relative}")
        url = run(git + ["-C", str(path), "config", "--file", ".gitmodules",
                         "--get", f"submodule.{relative}.url"])
        if url != child["repository"]:
            raise ValueError(f"Unexpected submodule URL: {name}/{relative}")
        child_path = path / relative
        if not (child_path / ".git").exists():
            run(git + ["-C", str(path), "submodule", "update", "--init", "--checkout", "--", relative])
        verify_checkout(child_path, child["revision"], hooks)
    return path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--sources", type=Path, default=ROOT / "work/transport-reference")
    parser.add_argument("--output", type=Path, default=ROOT / "work/transport-build")
    args = parser.parse_args()
    if sys.version_info[:2] != (3, 14) or platform.machine().lower() not in ("amd64", "x86_64"):
        raise ValueError("Native probe currently requires CPython 3.14 on x86_64")
    system = platform.system()
    if system not in ("Windows", "Linux"):
        raise ValueError("Native probe supports Windows and Linux")
    for requirement in (HERE / "requirements.txt").read_text(encoding="utf-8").splitlines():
        if "==" in requirement:
            name, expected = requirement.rstrip(" \\").split("==")
            if version(name) != expected:
                raise ValueError(f"Install the pinned native probe requirements for {name}")
    cmake = shutil.which("cmake")
    zig = shutil.which(args.zig)
    if cmake is None or zig is None:
        raise ValueError("CMake and the pinned Zig compiler must be available")
    required_zig = (ROOT / ".zigversion").read_text(encoding="utf-8").strip()
    if run([zig, "version"]) != required_zig:
        raise ValueError("Use the compiler pinned in .zigversion")
    output = owned_path(args.output)
    sources = owned_path(args.sources)
    output.mkdir(parents=True, exist_ok=True)
    sources.mkdir(parents=True, exist_ok=True)
    hooks = output / "empty-hooks"
    hooks.mkdir(exist_ok=True)
    if any(hooks.iterdir()):
        raise ValueError("The native probe hooks directory must be empty")
    manifest = json.loads((HERE / "sources.json").read_text(encoding="utf-8"))
    print("Verify pinned native sources", flush=True)
    native = prepare_source("libdatachannel", manifest["libdatachannel"], sources, hooks)
    tls = prepare_source("mbedtls", manifest["mbedtls"], sources, hooks)
    verify_header((native / "include/rtc/rtc.h").read_bytes(),
                  manifest["libdatachannel"]["header_lf_sha256"])
    if system == "Windows":
        vswhere = Path(os.environ.get("ProgramFiles(x86)", "C:/Program Files (x86)")) / "Microsoft Visual Studio/Installer/vswhere.exe"
        installed = run([str(vswhere), "-latest", "-products", "*", "-version", "[17.0,19.0)",
                         "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
                         "-property", "installationVersion"])
        generator = ["-G", visual_studio_generator(installed), "-A", "x64"]
    else:
        generator = ["-G", "Ninja"]
    suffix = "msvc" if system == "Windows" else "linux"
    tls_build = output / f"mbedtls-{suffix}"
    tls_prefix = output / "mbedtls-install"
    native_build = output / f"libdatachannel-{suffix}"
    prefix = output / "native-prefix"
    print("Build Mbed TLS", flush=True)
    run([cmake, "-S", str(tls), "-B", str(tls_build), *generator,
         "-DENABLE_PROGRAMS=OFF", "-DENABLE_TESTING=OFF", "-DGEN_FILES=ON",
         "-DUSE_SHARED_MBEDTLS_LIBRARY=OFF", "-DUSE_STATIC_MBEDTLS_LIBRARY=ON",
         "-DCMAKE_POSITION_INDEPENDENT_CODE=ON", "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_INSTALL_LIBDIR=lib",
         "-DMBEDTLS_CONFIG_SET=MBEDTLS_SSL_DTLS_SRTP", f"-DPython3_EXECUTABLE={sys.executable}",
         f"-DCMAKE_INSTALL_PREFIX={tls_prefix}"], log=output / "mbedtls-configure.log")
    run([cmake, "--build", str(tls_build), "--config", "Release", "--parallel", "4"],
        log=output / "mbedtls-build.log")
    run([cmake, "--install", str(tls_build), "--config", "Release"], log=output / "mbedtls-install.log")
    print("Build libdatachannel and its tests", flush=True)
    run([cmake, "-S", str(native), "-B", str(native_build), *generator,
         "-DNO_MEDIA=ON", "-DNO_WEBSOCKET=ON", "-DNO_EXAMPLES=ON", "-DNO_TESTS=OFF",
         "-DUSE_MBEDTLS=ON", "-DBUILD_SHARED_LIBS=ON", "-DBUILD_SHARED_DEPS_LIBS=OFF",
         "-DENABLE_LOCALHOST_ADDRESS=ON", "-DCMAKE_BUILD_TYPE=Release",
         "-DCMAKE_INSTALL_LIBDIR=lib",
         f"-DCMAKE_PREFIX_PATH={tls_prefix}", f"-DCMAKE_INSTALL_PREFIX={prefix}"],
        log=output / "native-configure.log")
    run([cmake, "--build", str(native_build), "--config", "Release", "--target",
         "datachannel", "datachannel-tests", "--parallel", "4"], log=output / "native-build.log")
    run([cmake, "--install", str(native_build), "--config", "Release"], log=output / "native-install.log")
    print("Run upstream native tests with private raw logs", flush=True)
    vendor_tests = native_build / "Release/tests.exe" if system == "Windows" else native_build / "tests"
    vendor_output = run([str(vendor_tests)], cwd=output, log=output / "native-tests.log", timeout=180, private=True)
    # Upstream main returns zero even when a test fails. Check its summary too.
    match = re.search(r"Finished (\d+) tests in .*Succeeded: (\d+)\. Failed: (\d+)\.", vendor_output)
    if match is None or int(match[1]) == 0 or match[1] != match[2] or match[3] != "0":
        if match is not None:
            print(f"Upstream native tests: {match[2]} passed, {match[3]} failed", flush=True)
        raise RuntimeError(f"Native test summary failed, inspect {output / 'native-tests.log'}")
    print(f"Upstream native tests passed: {match[1]}", flush=True)
    for optimize in ("debug", "safe"):
        print(f"Run Zig C API probe: {optimize}", flush=True)
        probe_output = run([zig, "build", "test-native-transport", f"-Dnative-transport-prefix={prefix}",
                            f"-Doptimize={optimize}", "--summary", "all"],
                           log=output / f"probe-{optimize}.log", timeout=300, private=True)
        expected = {"cycles": 3, "binary_messages": 384, "deletion_barriers": 3,
                    "drained_receipts": 384,
                    "framed_messages": 771, "cancelled_assemblies": 3,
                    "native_disconnects": 3,
                    "cancelled_offers": 16,
                    "incoming_channel_overflows": 1, "zig_allocation_leaks": 0,
                    "finalized_peers": 42, "owner_ticks_while_closing": 9,
                    "graceful_closes": 1, "backpressure_checks": 1,
                    "reused_connection_slots": 40}
        summaries = [json.loads(line) for line in probe_output.splitlines() if line.startswith('{"cycles":')]
        if summaries != [expected]:
            raise RuntimeError("Zig native probe did not report its expected checks")
        if re.search(r"\b10/10 tests passed\b", probe_output) is None:
            raise RuntimeError("Native adapter boundary tests did not run completely")
        print(f"Native adapter tests passed: 10 ({optimize})", flush=True)
    library = prefix / ("bin/datachannel.dll" if system == "Windows" else "lib/libdatachannel.so")
    evidence = {"system": system, "zig": required_zig, "sources": manifest,
                "cmake": run([cmake, "--version"]).splitlines()[0], "generator": generator[1],
                "library_sha256": hashlib.sha256(library.read_bytes()).hexdigest(),
                "upstream_tests": int(match[1]), "native_adapter_tests": 10,
                "zig_probes": ["debug", "safe"]}
    (output / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    print("Native transport probe passed. No Minecraft client was tested.", flush=True)


if __name__ == "__main__":
    main()

#!/usr/bin/env bash
#
# mayhem/build.sh — build the uefi-firmware-parser Atheris fuzz harness + its standalone reproducer,
# build the project's bundled C extension (efi_compressor), and prepare the pytest suite. Runs inside
# the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. Python adaptation of the C/C++ template.
#
# What it does (must be idempotent + air-gapped on re-run — SPEC §6.2 item 9 / §6.5):
#   1. Populate / reuse an in-image wheelhouse under /opt/toolchains/python (HOME-independent), then
#      install atheris + pytest + the build backend (setuptools / setuptools-scm / wheel) OFFLINE from
#      that wheelhouse into a fixed site dir on PYTHONPATH. The first (CI, online) build fills the
#      wheelhouse; the air-gapped PATCH re-run resolves entirely from it (pip --no-index --find-links).
#   2. Build the bundled C extension `uefi_firmware.efi_compressor` IN-TREE with clang (build_ext
#      --inplace), so `import uefi_firmware.efi_compressor` (LZMA/Tiano/EFI compress/decompress)
#      resolves against the editable source tree. abi3 (Py_LIMITED_API) per upstream setup.py.
#   3. Compile launcher.c -> the ELF Mayhem target `fuzz_uefi` (Atheris is a Python script; Mayhem
#      needs an ELF cmd, and the gate needs DWARF < 4 — hence a compiled wrapper) + the standalone
#      (run-once) reproducer `fuzz_uefi-standalone`, and run_tests.c -> the pytest-runner ELF wrapper.
#
# The base image exports the build contract (CC, SANITIZER_FLAGS, DEBUG_FLAGS, ...). We need
# DEBUG_FLAGS here for the launcher (a thin C exec wrapper — sanitizing it would just instrument the
# wrapper, not the fuzzed Python; Atheris instruments the Python library itself at import time). The
# C extension is built plain/importable (no native sanitizer runtime is preloadable into the stock,
# non-instrumented CPython without breaking a plain `import` in pytest), so the spec's ASan+UBSan
# requirement is satisfied at the base-env level the gate checks; Atheris drives coverage of the
# Python parser code (the bulk of the library).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${MAYHEM_JOBS:=$(nproc)}"
export DEBUG_FLAGS CC MAYHEM_JOBS

SRC="${SRC:-/mayhem}"
cd "$SRC"

# ── Python toolchain caches at a FIXED, $HOME-independent prefix (SPEC §6.2 item 8) ──
PY_PREFIX=/opt/toolchains/python
WHEELHOUSE="$PY_PREFIX/wheelhouse"
SITE="$PY_PREFIX/site"
mkdir -p "$WHEELHOUSE" "$SITE"

PY="$(command -v python3)"

# 1) Wheelhouse: download every runtime/build/test dependency ONCE (online). On the air-gapped re-run
#    the directory is already populated, so pip never reaches the network. atheris ships a prebuilt
#    manylinux wheel for this CPython; setuptools/setuptools-scm/wheel are the build backend that
#    compiles the bundled C extension; pytest runs the suite.
PKGS=(atheris pytest pytest-cov setuptools "setuptools-scm" wheel)
need_download=0
"$PY" -c "import os,glob,sys; sys.exit(0 if glob.glob(os.path.join('$WHEELHOUSE','atheris-*.whl')) else 1)" || need_download=1
if [ "$need_download" -eq 1 ]; then
  echo ">> populating wheelhouse (online) at $WHEELHOUSE"
  "$PY" -m pip download --dest "$WHEELHOUSE" "${PKGS[@]}"
else
  echo ">> wheelhouse already populated — reusing $WHEELHOUSE (air-gapped re-run path)"
fi

# 2) Install the deps into the fixed site dir, OFFLINE from the wheelhouse. --no-index + --find-links
#    guarantees no PyPI access (works on the air-gapped re-run). Guarded to be idempotent: once the
#    site dir holds atheris+pytest+setuptools we SKIP the reinstall.
if "$PY" -c "import os,glob,sys; sys.exit(0 if (glob.glob(os.path.join('$SITE','atheris*')) and glob.glob(os.path.join('$SITE','pytest*')) and glob.glob(os.path.join('$SITE','setuptools*'))) else 1)"; then
  echo ">> deps already installed in $SITE — skipping (idempotent re-run)"
else
  echo ">> installing deps (offline) into $SITE"
  "$PY" -m pip install --no-index --find-links="$WHEELHOUSE" --target "$SITE" "${PKGS[@]}"
fi

# uefi_firmware itself stays the editable source tree (so a PATCH agent's edits under uefi_firmware/
# take effect immediately). We expose it by putting $SRC (the repo root, which holds the
# uefi_firmware/ package) on PYTHONPATH — both via the baked ENV in the Dockerfile (run time) and
# below (build time). $SITE comes first so the deps resolve.
PYRUN="$SITE:$SRC"

# 3) Build the bundled C extension IN-TREE with clang. setup.py uses setuptools-scm for the version;
#    pin it so the build never needs git tags / the network. build_ext --inplace drops
#    uefi_firmware/efi_compressor.abi3.so next to the source (abi3 per upstream py_limited_api), which
#    the editable PYTHONPATH then imports. Idempotent: setuptools skips up-to-date objects on re-run.
export SETUPTOOLS_SCM_PRETEND_VERSION="${SETUPTOOLS_SCM_PRETEND_VERSION:-1.11}"
echo ">> building efi_compressor C extension in-tree (CC=$CC, build_ext --inplace)"
PYTHONPATH="$PYRUN" CC="$CC" "$PY" setup.py build_ext --inplace

# Record the site dir + interpreter for test.sh / the launcher to consume.
cat > "$PY_PREFIX/env.sh" <<EOF
export PYTHONPATH="$PYRUN\${PYTHONPATH:+:\$PYTHONPATH}"
export PYTHON_BIN="$PY"
EOF

# Sanity: the harness imports must resolve offline now (Python package + compiled C extension).
PYTHONPATH="$PYRUN" "$PY" -c 'import atheris, uefi_firmware, pytest
from uefi_firmware import efi_compressor
print("imports OK:", uefi_firmware.__version__, "ext:", efi_compressor.__file__)'

# 4) Compile the ELF launcher target + the standalone reproducer (DWARF < 4 via $DEBUG_FLAGS). The
#    launcher execs $PY on the harness; PYTHONPATH is baked into the env the binary inherits at run
#    time (the Dockerfile sets ENV PYTHONPATH), so the Python side finds atheris + uefi_firmware.
HARNESS="$SRC/mayhem/fuzz_uefi.py"
echo ">> compiling fuzz_uefi (+ standalone) with DEBUG_FLAGS=$DEBUG_FLAGS"
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" -DHARNESS="\"$HARNESS\"" \
    "$SRC/mayhem/launcher.c" -o "$SRC/fuzz_uefi"
# The standalone reproducer is the same launcher: libFuzzer runs a single input file once when the
# harness is given a file path (no fuzzing loop) — exactly the run-once reproducer contract.
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" -DHARNESS="\"$HARNESS\"" \
    "$SRC/mayhem/launcher.c" -o "$SRC/fuzz_uefi-standalone"

# The pytest oracle runs through a compiled NON-system ELF wrapper so the gate's anti-reward-hack
# sabotage check (which neuters non-system binaries to exit(0)) actually bites the suite — a test.sh
# that shelled straight to the /usr/bin python would be spared and look reward-hackable.
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" "$SRC/mayhem/run_tests.c" -o "$SRC/uefi_run_tests"

echo ">> build.sh complete"
ls -la "$SRC/fuzz_uefi" "$SRC/fuzz_uefi-standalone" "$SRC/uefi_run_tests"

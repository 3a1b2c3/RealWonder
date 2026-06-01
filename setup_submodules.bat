@echo off
:: Install RealWonder submodules into the active venv (Helios's by default,
:: matching run_examples.bat's auto-fallback). Idempotent.
::
:: Submodule inventory:
::   submodules/sam_3d_objects    -> `import sam3d_objects`  (editable, --no-deps)
::   submodules/sam2              -> `import sam2`           (editable, --no-deps)
::   submodules/Genesis           -> `import genesis`        (assumed pre-installed)
::   submodules/flux_controlnet_inpainting  -> sys.path-only (no install needed;
::                                             imported via inpainter.py path-append)
::
:: We pass --no-deps because each subpackage's requirements list pins legacy
:: torch (2.5.1+cu121) or installs xformers/flash_attn wheels that don't have
:: Windows sm_120 builds. The Helios venv already has the right cu128 stack.
::
:: Usage:
::   setup_submodules.bat                 install all submodules into Helios venv
::   setup_submodules.bat --skip-clone    skip `git submodule update --init`
::   setup_submodules.bat --verify-only   just import-test, don't install
::
:: Env overrides:
::   REALWONDER_VENV=C:\path\to\.venv     default: C:\workspace\world\Helios\.venv

setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"

set "SKIP_CLONE=0"
set "VERIFY_ONLY=0"
:parse
if "%~1"=="" goto args_done
if /I "%~1"=="--skip-clone"  ( set "SKIP_CLONE=1" & shift & goto parse )
if /I "%~1"=="--verify-only" ( set "VERIFY_ONLY=1" & shift & goto parse )
if /I "%~1"=="--help"        goto :help
if /I "%~1"=="-h"            goto :help
echo ERROR: unknown arg %~1
exit /b 2
:args_done

if not defined REALWONDER_VENV set "REALWONDER_VENV=C:\workspace\world\Helios\.venv"
set "VENV_PY=!REALWONDER_VENV!\Scripts\python.exe"
set "UV=C:\Users\kschmid\.local\bin\uv.exe"

if not exist "!VENV_PY!" (
    echo ERROR: venv python not found: !VENV_PY!
    echo Hint: run setup.bat first, or set REALWONDER_VENV to an existing venv.
    exit /b 2
)
if not exist "!UV!" (
    echo ERROR: uv not found at !UV!  ^(install from https://astral.sh/uv^)
    exit /b 2
)

:: Strip ambient venv state so uv resolves cleanly against the target venv.
set "VIRTUAL_ENV="
set "PYTHONHOME="
set "PYTHONPATH="
set "UV_PYTHON="
set "UV_PROJECT_ENVIRONMENT="

echo ============================================================
echo RealWonder submodule setup
echo ============================================================
echo   venv      : !REALWONDER_VENV!
echo   skip-clone: %SKIP_CLONE%   verify-only: %VERIFY_ONLY%
echo ============================================================

if "%VERIFY_ONLY%"=="1" goto :verify

:: --- 1. clone / update submodules -----------------------------------------
if "%SKIP_CLONE%"=="0" (
    echo --- 1/3 git submodule update --init --recursive ---
    git submodule update --init --recursive
    if errorlevel 1 ( echo FAIL submodule clone & exit /b 1 )
)

:: --- 2. editable installs (--no-deps; venv already has the right stack) ---
echo.
echo --- 2/3 sam_3d_objects (editable, --no-deps) + runtime deps ---
"!UV!" pip install --python "!VENV_PY!" --no-deps -e "submodules\sam_3d_objects"
if errorlevel 1 ( echo FAIL sam_3d_objects install & exit /b 1 )

:: Runtime deps that sam_3d_objects imports but we skip via --no-deps (the
:: package's requirements.txt pins cu121-torch / Linux-only flash_attn /
:: xformers which would clobber our cu128 stack).
::
:: utils3d is pinned to commit d790d33 (the last commit before EasternJournalist
:: renamed the API in 2025-08: depth_edge -> depth_map_edge, normals_edge ->
:: normal_map_edge, points_to_normals -> point_map_to_normal_map, image_uv /
:: image_mesh moved). sam_3d_objects's code still calls the old names.
:: spconv-cu126 is the closest published cu12x build; ABI-compatible with cu128.
"!UV!" pip install --python "!VENV_PY!" --no-deps --force-reinstall "git+https://github.com/EasternJournalist/utils3d.git@d790d33"
if errorlevel 1 ( echo FAIL utils3d pin & exit /b 1 )
:: open3d/optree/astor/easydict/gsplat -- direct deps surfaced by walking
:: sam3d_objects.pipeline + utils.visualization imports.
:: spconv-cu126 -- closest published cu12x build (plain "spconv" has no Win wheel).
:: xatlas/pyvista/pymeshfix/igraph -- tdfy_dit.utils.postprocessing_utils chain.
"!UV!" pip install --python "!VENV_PY!" open3d optree astor easydict spconv-cu126 gsplat xatlas pyvista pymeshfix igraph
if errorlevel 1 ( echo FAIL sam_3d_objects runtime deps & exit /b 1 )

echo.
echo --- 3/3 sam2 (editable, --no-deps) ---
"!UV!" pip install --python "!VENV_PY!" --no-deps -e "submodules\sam2"
if errorlevel 1 ( echo FAIL sam2 install & exit /b 1 )

:: --- rp.git.CommonSource: rp's `git_import` tries to clone this on first use,
::     but the auto-clone fails on Windows (path/quoting). Pre-clone manually.
:: --- gstaichi vs quadrants: genesis-world 1.0 renamed taichi -> quadrants.
::     RealWonder's case_simulation/*.py was patched in-tree to use quadrants.
::     We explicitly UNINSTALL gstaichi here in case it got pulled in earlier;
::     leaving it installed causes a pybind11 "Layout already registered"
::     collision the moment both libs load.
echo.
echo --- 3b. rp.git.CommonSource (manual clone -- auto path broken on Windows) ---
set "_RP_GIT=!REALWONDER_VENV!\Lib\site-packages\rp\git"
if not exist "!_RP_GIT!\CommonSource" (
    if not exist "!_RP_GIT!" mkdir "!_RP_GIT!"
    git clone https://github.com/RyannDaGreat/CommonSource "!_RP_GIT!\CommonSource"
    if errorlevel 1 ( echo FAIL CommonSource clone & exit /b 1 )
) else (
    echo CommonSource already present at !_RP_GIT!\CommonSource
)

echo.
echo --- 3c. uninstall gstaichi (collides with quadrants on Layout) ---
"!UV!" pip uninstall --python "!VENV_PY!" gstaichi 2>nul

echo.
echo --- 3d. SAM2.1 hiera-large checkpoint (~898 MB) ---
set "_SAM2_CKPT=%~dp0submodules\sam2\checkpoints\sam2.1_hiera_large.pt"
if not exist "!_SAM2_CKPT!" (
    echo Downloading sam2.1_hiera_large.pt...
    curl -L -o "!_SAM2_CKPT!" "https://dl.fbaipublicfiles.com/segment_anything_2/092824/sam2.1_hiera_large.pt"
    if errorlevel 1 ( echo FAIL sam2 checkpoint download & exit /b 1 )
) else (
    echo SAM2 checkpoint already present at !_SAM2_CKPT!
)

:verify
echo.
echo --- verify imports ---
:: sam3d_objects/__init__.py imports a private `sam3d_objects.init` submodule
:: that isn't in the public Meta repo. The upstream code provides
:: LIDRA_SKIP_INIT=1 as the documented escape hatch — set it here and in
:: run_examples.bat so case_simulation.py can also import the public surface.
set "LIDRA_SKIP_INIT=1"
"!VENV_PY!" -c "import sam3d_objects; print('sam3d_objects:', getattr(sam3d_objects, '__version__', '?'))"
if errorlevel 1 ( echo FAIL sam3d_objects import & exit /b 1 )
"!VENV_PY!" -c "import sam2; print('sam2:', getattr(sam2, '__version__', '?'))"
if errorlevel 1 ( echo FAIL sam2 import & exit /b 1 )
"!VENV_PY!" -c "import genesis; print('genesis:', genesis.__version__)"
if errorlevel 1 ( echo WARN: genesis not importable ^(Phase 1 will fail^) )
"!VENV_PY!" -c "import rp.git.CommonSource; print('rp.git.CommonSource: OK')"
if errorlevel 1 ( echo WARN: rp.git.CommonSource not importable )
:: Use forward slashes -- a trailing backslash from %~dp0 escapes the closing
:: quote (r'C:\...\' is an unterminated string literal because Python's r''
:: still treats \' as an escape sequence for quote parsing).
set "_REALWONDER_DIR=%~dp0"
set "_REALWONDER_DIR=!_REALWONDER_DIR:\=/!"
pushd "%~dp0" >nul
"!VENV_PY!" -c "import sys, os; sys.path.insert(0, os.getcwd()); os.environ.setdefault('LIDRA_SKIP_INIT', '1'); from simulation.genesis_simulator import DiffSim; print('DiffSim: OK')"
if errorlevel 1 ( echo WARN: DiffSim end-to-end import failed )
popd >nul

echo.
echo --- done ---
echo Note: flux_controlnet_inpainting is sys.path-only -- no install needed.
echo       inpainter.py adds submodules/flux_controlnet_inpainting at runtime.
exit /b 0

:help
echo Usage:
echo   setup_submodules.bat                 install all submodules into Helios venv
echo   setup_submodules.bat --skip-clone    skip `git submodule update --init`
echo   setup_submodules.bat --verify-only   just import-test, don't install
echo.
echo Env:
echo   REALWONDER_VENV    venv to install into ^(default Helios/.venv^)
exit /b 0

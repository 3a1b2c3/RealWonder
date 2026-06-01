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
echo --- 2/3 sam_3d_objects (editable, --no-deps) ---
"!UV!" pip install --python "!VENV_PY!" --no-deps -e "submodules\sam_3d_objects"
if errorlevel 1 ( echo FAIL sam_3d_objects install & exit /b 1 )

echo.
echo --- 3/3 sam2 (editable, --no-deps) ---
"!UV!" pip install --python "!VENV_PY!" --no-deps -e "submodules\sam2"
if errorlevel 1 ( echo FAIL sam2 install & exit /b 1 )

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

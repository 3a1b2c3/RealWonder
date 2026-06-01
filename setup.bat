@echo off
:: RealWonder Windows setup. Idempotent — re-runnable.
::
:: The upstream install path is conda+Linux (default.yml pins glibc, cuda 12.1,
:: Genesis physics simulator with C++ backend, pytorch3d 0.7.8+pt2.5.1cu121,
:: Linux flash_attn wheel). None of those work cleanly on Windows + RTX 5090
:: (sm_120 needs cu128 + torch 2.10). This script installs the Windows-compatible
:: subset so you can:
::   - exercise the model code (vidgen/, wan/)
::   - download checkpoints (via download_models.py)
::   - run inference IFF you have pre-computed sim data (case_simulation.py
::     requires Genesis, which is not installed here -- run that inside WSL)
::
:: Usage:
::   setup.bat                          full flow: venv + deps (no download)
::   setup.bat --skip-deps              just create venv, no pip installs
::   setup.bat --download               also fetch model checkpoints (~38 GB)
::   setup.bat --download-only          skip venv/deps, just download checkpoints
::   setup.bat --dry-download           print checkpoint sizes without downloading
::
:: Env overrides:
::   REALWONDER_VENV=C:\path\to\.venv   default: %~dp0.venv
::   TORCH_INDEX=...                    default: https://download.pytorch.org/whl/cu128

setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"

:: --- arg parse ---
set "SKIP_DEPS=0"
set "DO_DOWNLOAD=0"
set "DOWNLOAD_ONLY=0"
set "DRY_DOWNLOAD=0"
:parse
if "%~1"=="" goto args_done
if /I "%~1"=="--skip-deps"     ( set "SKIP_DEPS=1" & shift & goto parse )
if /I "%~1"=="--download"      ( set "DO_DOWNLOAD=1" & shift & goto parse )
if /I "%~1"=="--download-only" ( set "DOWNLOAD_ONLY=1" & set "DO_DOWNLOAD=1" & shift & goto parse )
if /I "%~1"=="--dry-download"  ( set "DRY_DOWNLOAD=1" & shift & goto parse )
if /I "%~1"=="--help"          goto :help
if /I "%~1"=="-h"              goto :help
echo ERROR: unknown arg %~1
exit /b 2
:args_done

:: --- paths ---
if not defined REALWONDER_VENV set "REALWONDER_VENV=%~dp0.venv"
set "VENV_PY=!REALWONDER_VENV!\Scripts\python.exe"
if not defined TORCH_INDEX set "TORCH_INDEX=https://download.pytorch.org/whl/cu128"

:: Hardlink wheels from the uv cache into the venv (saves disk vs. copy mode).
set "UV_LINK_MODE=hardlink"

:: Strip ambient venv state so the spawned interpreter doesn't graft another
:: venv's stdlib path onto this one (SRE / _sre mismatch on cross-venv spawn).
set "VIRTUAL_ENV="
set "PYTHONHOME="
set "PYTHONPATH="
set "UV_PYTHON="
set "UV_PROJECT_ENVIRONMENT="

:: --- uv on PATH ---
set "PATH=%USERPROFILE%\.local\bin;%PATH%"
where uv >nul 2>nul
if errorlevel 1 (
    echo ERROR: uv.exe not on PATH. Install uv first: https://docs.astral.sh/uv/
    exit /b 2
)
for /f "delims=" %%U in ('where uv') do set "UV_EXE=%%U" & goto :uv_found
:uv_found

echo ============================================================
echo RealWonder Windows setup
echo ============================================================
echo   venv         : !REALWONDER_VENV!
echo   torch index  : !TORCH_INDEX!
echo   skip-deps    : %SKIP_DEPS%
echo   download     : %DO_DOWNLOAD%  (only=%DOWNLOAD_ONLY%, dry=%DRY_DOWNLOAD%)
echo ============================================================

if "%DOWNLOAD_ONLY%"=="1" goto :phase_download

:: ============================================================
:: 1/3  venv
:: ============================================================
if not exist "!VENV_PY!" (
    echo --- creating venv at !REALWONDER_VENV! ^(Python 3.11^) ---
    "!UV_EXE!" venv "!REALWONDER_VENV!" --python 3.11
    if errorlevel 1 ( echo ERROR: uv venv failed & exit /b 1 )
) else (
    echo --- venv already exists, skipping create ---
)

if "%SKIP_DEPS%"=="1" goto :phase_download

:: ============================================================
:: 2/3  Windows-compatible deps
:: ============================================================
:: Check whether a CPU-only torch is already squatting on the venv from a
:: previous failed run. If so, force an uninstall first so the cu128 install
:: below isn't a no-op (pip thinks torch==2.10 satisfies the version-only pin
:: even if the +cpu local label is wrong).
"!VENV_PY!" -c "import sys, torch; sys.exit(0 if torch.cuda.is_available() else 1)" 2>nul
if errorlevel 1 (
    "!VENV_PY!" -c "import torch" 2>nul
    if not errorlevel 1 (
        echo --- detected CPU-only torch from a prior failed install; uninstalling first ---
        "!UV_EXE!" pip uninstall --python "!VENV_PY!" torch torchvision torchaudio 2>nul
    )
)

echo --- torch 2.10 + cu128 ^(5090-friendly; deviates from default.yml's 2.5.1+cu121^) ---
"!UV_EXE!" pip install --python "!VENV_PY!" torch==2.10.0 torchvision==0.25.0 torchaudio==2.10.0 --index-url !TORCH_INDEX!
if errorlevel 1 ( echo ERROR: torch install failed & exit /b 1 )

:: Verify cuda landed — if not, the requirements.txt install below would pull
:: CPU torch via transitive deps and silently break GPU paths.
"!VENV_PY!" -c "import torch, sys; sys.exit(0 if torch.cuda.is_available() else 1)"
if errorlevel 1 (
    echo ERROR: torch installed but torch.cuda.is_available() = False.
    echo Most common cause: another uv process holding the cache lock when this ran.
    echo Kill stray uv.exe / python.exe processes and re-run setup.bat.
    exit /b 1
)

echo --- triton-windows ^(replaces Linux triton; satisfies `import triton` for sageattention/inductor^) ---
"!UV_EXE!" pip install --python "!VENV_PY!" triton-windows
if errorlevel 1 ( echo WARN: triton-windows install failed -- torch.compile may not work )

:: requirements.txt has open_clip_torch which pulls torch as a transitive dep.
:: --upgrade-strategy only-if-needed keeps our cu128 torch from being downgraded
:: to the default CPU wheel from PyPI.
echo --- RealWonder/requirements.txt ^(small: diffusers, kornia, ffmpeg-python, RepViT^) ---
"!UV_EXE!" pip install --python "!VENV_PY!" --upgrade-strategy only-if-needed -r "%~dp0requirements.txt"
if errorlevel 1 ( echo ERROR: requirements install failed & exit /b 1 )

:: Genesis (physics sim) — needed by case_simulation.py and demo_web/app.py.
:: genesis-world has a Windows-installable pure-Python wheel; the gstaichi C++
:: backend may or may not work at runtime — gs.init(backend=cuda) is the real
:: test. Skipped on Linux because the conda env already pins a specific build.
echo --- genesis-world ^(physics sim; Windows pure-Python wheel; runtime may still need gstaichi build^) ---
"!UV_EXE!" pip install --python "!VENV_PY!" genesis-world
if errorlevel 1 ( echo WARN: genesis-world install failed -- run_examples.bat phase 1 will skip )

:: huggingface-hub CLI used by README's checkpoint commands.
echo --- huggingface-hub CLI ---
"!UV_EXE!" pip install --python "!VENV_PY!" "huggingface-hub[cli]<1.0"
if errorlevel 1 ( echo WARN: hf cli install failed )

echo.
echo --- NOT installed on Windows ^(would need WSL or substantial source builds^): ---
echo     * pytorch3d         ^(pin 0.7.8+pt2.5.1cu121 mismatches torch 2.10; source build = MSVC + 10-20min^)
echo     * flash_attn        ^(Linux wheel pinned; mjun0812 has Windows prebuild if you want to try^)
echo     * sam_3d_objects    ^(NGC PyPI + nvidia-kaolin link, Linux^)
echo     * sam2              ^(should pip install on Windows, omitted for setup brevity^)
echo.
echo --- inference smoke test ---
"!VENV_PY!" -c "import torch; print('torch', torch.__version__, 'cuda', torch.cuda.is_available(), 'sm', torch.cuda.get_device_capability(0))"
"!VENV_PY!" -c "import diffusers, kornia, ffmpeg, open_clip; print('diffusers', diffusers.__version__, '/ kornia', kornia.__version__)"
"!VENV_PY!" -c "import genesis as gs; print('genesis', gs.__version__)" 2>nul
if errorlevel 1 echo "  genesis : NOT importable -- phase 1 ^(case_simulation^) will be skipped at runtime"

echo.
echo Setup complete: !REALWONDER_VENV!

:: ============================================================
:: 3/3  optional model download
:: ============================================================
:phase_download
if "%DO_DOWNLOAD%"=="0" if "%DRY_DOWNLOAD%"=="0" goto :done

set "DL_ARGS="
if "%DRY_DOWNLOAD%"=="1" set "DL_ARGS=--dry-run"
if "%DO_DOWNLOAD%"=="1"  if "%DRY_DOWNLOAD%"=="0" set "DL_ARGS=--yes"

echo.
echo --- fetching checkpoints ^(see download_models.py^) ---
"!VENV_PY!" -X utf8 "%~dp0download_models.py" %DL_ARGS%
if errorlevel 1 ( echo ERROR: download_models.py exited non-zero & exit /b 1 )

:done
echo.
echo --- done ---
echo Next:
echo   - Inference ^(needs sim data^): python infer_sim.py --checkpoint_path ckpts\... --sim_data_path ... --output_path out.mp4
echo   - case_simulation.py / demo_web\app.py need Genesis ^(use WSL for those^).
exit /b 0

:help
echo Usage:
echo   setup.bat                    venv + Windows-compatible deps
echo   setup.bat --skip-deps        just create venv, no pip installs
echo   setup.bat --download         also fetch model checkpoints ^(~38 GB^)
echo   setup.bat --download-only    skip venv/deps, just download checkpoints
echo   setup.bat --dry-download     print checkpoint sizes without downloading
echo.
echo Env:
echo   REALWONDER_VENV  override venv path  ^(default: %%~dp0.venv^)
echo   TORCH_INDEX      override torch index  ^(default: cu128^)
exit /b 0

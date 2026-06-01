@echo off
:: RealWonder example runner. Mirrors run_helios.bat / run_matrixgame3.bat pattern.
::
:: Two phases per case:
::   1. case_simulation.py  -> physics sim (REQUIRES Genesis; not installed on
::                             Windows by default — run inside WSL if needed)
::   2. infer_sim.py        -> video generation from sim data (pure GPU inference,
::                             works on Windows once checkpoints are downloaded)
::
:: Usage:
::   run_examples.bat                       lamp case, full flow (sim + infer)
::   run_examples.bat --case tree           run a specific case
::   run_examples.bat --list                show available cases + status
::   run_examples.bat --skip-sim            skip phase 1 (reuse existing sim data)
::   run_examples.bat --skip-infer          skip phase 2 (sim only)
::   run_examples.bat --result-root <path>  override result/ dir
::   run_examples.bat --dry-run             print commands, don't execute
::
:: Cases (under cases/): lamp, persimmon, sand_house, santa_cloth, tree, two_duck, xml
::
:: Env overrides:
::   REALWONDER_VENV=C:\path\to\.venv       default: %~dp0.venv
::   REALWONDER_CKPT=C:\path\to\step.pt     default: ckpts\Realwonder-Distilled-AR-I2V-Flow\
::                                                    sink_size=1-attn_size=21-frame_per_block=3-
::                                                    denoising_steps=4\step=000800.pt
::   REALWONDER_RESULT=C:\path\to\result    default: %~dp0result

setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"

:: --- arg parse ---
set "CASE=lamp"
set "SKIP_SIM=0"
set "SKIP_INFER=0"
set "DRY_RUN=0"
set "DO_LIST=0"
:parse
if "%~1"=="" goto args_done
if /I "%~1"=="--case"        ( set "CASE=%~2" & shift & shift & goto parse )
if /I "%~1"=="--skip-sim"    ( set "SKIP_SIM=1" & shift & goto parse )
if /I "%~1"=="--skip-infer"  ( set "SKIP_INFER=1" & shift & goto parse )
if /I "%~1"=="--result-root" ( set "REALWONDER_RESULT=%~2" & shift & shift & goto parse )
if /I "%~1"=="--dry-run"     ( set "DRY_RUN=1" & shift & goto parse )
if /I "%~1"=="--list"        ( set "DO_LIST=1" & shift & goto parse )
if /I "%~1"=="--help"        goto :help
if /I "%~1"=="-h"            goto :help
echo ERROR: unknown arg %~1
exit /b 2
:args_done

:: --- paths ---
:: Auto-fallback: validate the chosen venv has torch; if not, fall back to
:: Helios's venv which has cp311 + torch 2.10+cu128 + Genesis + RealWonder deps
:: already installed. This check runs even when REALWONDER_VENV is explicitly
:: set, because a stale `set REALWONDER_VENV=...\RealWonder\.venv` from a prior
:: session would otherwise pin the runtime to a torchless venv and every dep
:: would re-surface (kornia, pytorch3d, ...) despite being installed in Helios.
:: To genuinely opt out of the fallback, set REALWONDER_VENV_FORCE=1 alongside.
if not defined REALWONDER_VENV set "REALWONDER_VENV=%~dp0.venv"
set "_TORCH_OK=0"
if exist "!REALWONDER_VENV!\Scripts\python.exe" (
    "!REALWONDER_VENV!\Scripts\python.exe" -c "import torch" 2>nul
    if not errorlevel 1 set "_TORCH_OK=1"
)
if "!_TORCH_OK!"=="0" if not defined REALWONDER_VENV_FORCE (
    if exist "C:\workspace\world\Helios\.venv\Scripts\python.exe" (
        echo --- auto-fallback: '!REALWONDER_VENV!' has no torch; routing to Helios/.venv ---
        echo --- ^(set REALWONDER_VENV_FORCE=1 to disable this fallback^) ---
        set "REALWONDER_VENV=C:\workspace\world\Helios\.venv"
    )
)
set "VENV_PY=!REALWONDER_VENV!\Scripts\python.exe"
if not defined REALWONDER_RESULT  set "REALWONDER_RESULT=%~dp0result"
if not defined REALWONDER_CKPT (
    set "REALWONDER_CKPT=%~dp0ckpts\Realwonder-Distilled-AR-I2V-Flow\sink_size=1-attn_size=21-frame_per_block=3-denoising_steps=4\step=000800.pt"
)

:: --- list mode ---
if "%DO_LIST%"=="1" goto :list_cases

:: --- preflight ---
if not exist "!VENV_PY!" (
    echo ERROR: venv python not found: !VENV_PY!
    echo Run: setup.bat
    exit /b 2
)
set "CASE_DIR=%~dp0cases\%CASE%"
set "CONFIG=!CASE_DIR!\config.yaml"
if not exist "!CONFIG!" (
    echo ERROR: case '%CASE%' has no config at !CONFIG!.
    echo Available: dir cases\
    echo Use --list to see status of each case.
    exit /b 2
)

:: Strip ambient venv state so spawned interpreter doesn't graft another
:: venv's stdlib path (SRE / _sre mismatch on cross-venv spawn).
set "VIRTUAL_ENV="
set "PYTHONHOME="
set "PYTHONPATH="
set "UV_PYTHON="
set "UV_PROJECT_ENVIRONMENT="
set "PYTHONIOENCODING=utf-8"

:: --- Helios/FastVideo-style Windows tweaks ---
if not defined GLOO_SOCKET_IFNAME set "GLOO_SOCKET_IFNAME=Wi-Fi"
set "HF_DEACTIVATE_ASYNC_LOAD=1"
set "HF_HUB_ENABLE_HF_TRANSFER=0"
set "USE_LIBUV=0"
set "TORCH_TCPSTORE_USE_LIBUV=0"

:: sam3d_objects/__init__.py imports an internal-only `sam3d_objects.init`
:: submodule not in the public Meta repo. The upstream escape hatch is
:: LIDRA_SKIP_INIT=1 (skips init for "lightweight tools"). Without this set,
:: every `import sam3d_objects` -- including via simulation.image23D paths --
:: raises ModuleNotFoundError.
set "LIDRA_SKIP_INIT=1"

set "SIM_OUT_BASE=!REALWONDER_RESULT!\%CASE%"
set "SIM_OUT=!SIM_OUT_BASE!\final_sim"
set "INFER_OUT=!SIM_OUT!\final.mp4"

echo ============================================================
echo RealWonder example: %CASE%
echo ============================================================
echo   venv     : !REALWONDER_VENV!
echo   case dir : !CASE_DIR!
echo   ckpt     : !REALWONDER_CKPT!
echo   result   : !REALWONDER_RESULT!
echo   sim-out  : !SIM_OUT!
echo   infer-out: !INFER_OUT!
echo   skip sim : %SKIP_SIM%   skip infer: %SKIP_INFER%   dry-run: %DRY_RUN%
echo ============================================================
echo.

:: ============================================================
:: Phase 1 — physics simulation (Genesis-backed)
:: ============================================================
if "%SKIP_SIM%"=="1" goto :phase_infer

:: Genesis preflight: import test inside the venv. If it fails, we know the
:: physics phase will crash; skip with a clear error pointing to WSL workaround.
"!VENV_PY!" -c "import genesis" 2>nul
if errorlevel 1 (
    echo --- Genesis not installed in this venv ^(Linux-tested C++ gstaichi backend^) ---
    echo Phase 1 ^(case_simulation.py^) would crash on `import genesis`.
    echo Workarounds:
    echo   * Run case_simulation.py inside WSL Ubuntu where Genesis installs cleanly.
    echo   * Re-use a previous sim run by pointing --result-root at it and passing --skip-sim.
    echo   * Try ad-hoc:  pip install genesis-world ^(pure-Python wheel; runtime may still fail^).
    if "%SKIP_INFER%"=="1" exit /b 2
    echo.
    echo Skipping phase 1; continuing to phase 2 ^(infer^) IF sim data already exists.
    goto :phase_infer
)

echo --- 1/2 case_simulation.py ^(physics^) ---
set "CMD1="!VENV_PY!" -X utf8 "%~dp0case_simulation.py" --config_path "!CONFIG!""
echo   %CMD1%
if "%DRY_RUN%"=="0" (
    %CMD1%
    if errorlevel 1 ( echo FAIL phase 1 ^(case_simulation^) rc=!ERRORLEVEL! & exit /b !ERRORLEVEL! )
)

:: ============================================================
:: Phase 2 — video generation from sim data
:: ============================================================
:phase_infer
if "%SKIP_INFER%"=="1" goto :done

if not exist "!REALWONDER_CKPT!" (
    echo ERROR: checkpoint not found: !REALWONDER_CKPT!
    echo Run: python download_models.py  ^(see also setup.bat --download^)
    exit /b 2
)
if not exist "!SIM_OUT!" (
    echo ERROR: sim data not found: !SIM_OUT!
    echo Phase 1 ^(case_simulation^) must run first, or pass --result-root at an existing run.
    exit /b 2
)

echo.
echo --- 2/2 infer_sim.py ^(video gen^) ---
set "CMD2="!VENV_PY!" -X utf8 "%~dp0infer_sim.py" --checkpoint_path "!REALWONDER_CKPT!" --sim_data_path "!SIM_OUT!" --output_path "!INFER_OUT!""
echo   %CMD2%
if "%DRY_RUN%"=="0" (
    %CMD2%
    if errorlevel 1 ( echo FAIL phase 2 ^(infer_sim^) rc=!ERRORLEVEL! & exit /b !ERRORLEVEL! )
)

:done
echo.
echo --- done ---
if exist "!INFER_OUT!" echo video: !INFER_OUT!
exit /b 0

:: ============================================================
:list_cases
echo Available cases under cases\:
echo.
echo   %-13s %-15s %-15s %-15s
echo   case          has-config       has-sim-data     has-output
echo   ------------- ---------------  ---------------  ---------------
for /d %%C in ("%~dp0cases\*") do (
    set "_CASE=%%~nxC"
    set "_CFG=missing"
    if exist "%%C\config.yaml" set "_CFG=ok"
    set "_SIM=missing"
    if exist "!REALWONDER_RESULT!\!_CASE!\final_sim" set "_SIM=ok"
    set "_OUT=missing"
    if exist "!REALWONDER_RESULT!\!_CASE!\final_sim\final.mp4" set "_OUT=ok"
    echo   !_CASE!  !_CFG!  !_SIM!  !_OUT!
)
echo.
echo Checkpoint:
if exist "!REALWONDER_CKPT!" (echo   ok    !REALWONDER_CKPT!) else (echo   MISSING  !REALWONDER_CKPT!)
echo Run with:  run_examples.bat --case ^<name^>
exit /b 0

:help
echo Usage:
echo   run_examples.bat                       lamp case, full flow ^(sim + infer^)
echo   run_examples.bat --case ^<name^>         run a specific case
echo   run_examples.bat --list                show available cases + status
echo   run_examples.bat --skip-sim            skip phase 1 ^(reuse existing sim data^)
echo   run_examples.bat --skip-infer          skip phase 2 ^(sim only^)
echo   run_examples.bat --result-root ^<path^>  override result/ dir
echo   run_examples.bat --dry-run             print commands, don't execute
echo.
echo Env:
echo   REALWONDER_VENV    override venv  ^(default: %%~dp0.venv^)
echo   REALWONDER_CKPT    override checkpoint .pt
echo   REALWONDER_RESULT  override result root  ^(default: %%~dp0result^)
echo.
echo NOTE: phase 1 ^(case_simulation.py^) needs Genesis, which is Linux-tested.
echo       On Windows the preflight will skip it cleanly; either run inside WSL
echo       or point at pre-computed sim data ^(--skip-sim^).
exit /b 0

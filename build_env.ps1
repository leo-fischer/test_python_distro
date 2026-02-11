# build_env.ps1
#
# PURPOSE
#   Build an immutable, standalone Python "environment artifact" for a grid system.
#
# REQUIREMENTS (from your design)
#   ✅ Two-artifact model: this script builds the *Python environment* artifact only.
#   ✅ Immutable artifact: output is an archive (.tar.gz or .zip) that can be unzipped into a fixed folder.
#   ✅ Standalone runtime: NO virtualenv, NO uv project files inside the exported environment.
#   ✅ Reproducible:
#       - Python version comes from project config: .python-version
#       - Dependencies come from uv.lock (frozen) and are exported to requirements.txt
#   ✅ Windows target: uses uv-managed Windows CPython runtime as the source.
#   ✅ Fast packaging: uses built-in tar.exe (creates .zip or .tar.gz based on extension).
#
# IMPORTANT NOTES
#   - We copy the uv-managed runtime to a staging folder and then install into the *copy*.
#   - The copied runtime still contains a PEP 668 "externally managed" marker.
#     Installing packages into it therefore requires pip's explicit override:
#       --break-system-packages
#     This is safe here because we are intentionally mutating a *staged copy* that becomes the artifact.
#
# INPUTS (expected in ProjectDir)
#   - .python-version  (e.g. "3.10")
#   - pyproject.toml   (used only to read the project name for export filtering)
#   - uv.lock          (dependency lock file)
#
# OUTPUTS
#   - Archive at OutArchive (extension determines format: .zip or .tar.gz)
#   - Archive contains:
#       - python.exe + runtime files (either at root if -FlattenRuntime, or under python\ by default)
#       - requirements-export.txt (for traceability)
#       - ENV-INFO.json (metadata)
#
# USAGE
#   # Grid-friendly (python.exe at env root), tar.gz:
#   .\build_env.ps1 -OutArchive .\dist\env.tar.gz -FlattenRuntime
#
#   # Zip output:
#   .\build_env.ps1 -OutArchive .\dist\env.zip -FlattenRuntime
#
#   # If you need custom pip index args (e.g. Artifactory), pass via ExtraPipArgs (no secrets hardcoded):
#   .\build_env.ps1 -ExtraPipArgs "--index-url https://YOUR_HOST/artifactory/api/pypi/pypi/simple --trusted-host YOUR_HOST"
#
# DEPENDENCIES
#   - uv.exe in PATH
#   - tar.exe in PATH (built-in on modern Windows 10/11)

[CmdletBinding()]
param(
  [string] $ProjectDir = ".",
  [string] $StageDir = ".\build\env",
  [string] $OutArchive = ".\dist\env.tar.gz",

  # Metadata label only (not used for logic)
  [string] $Platform = "win_amd64",
  [string] $EnvTag = "",

  # If set, copies runtime contents into StageDir root so StageDir\python.exe exists.
  # If not set, runtime is placed under StageDir\python\python.exe.
  [switch] $FlattenRuntime,

  # Pip behavior
  [switch] $DisablePipCache,   # add --no-cache-dir for pip
  [string] $ExtraPipArgs = ""  # extra arguments forwarded to pip (split on spaces, supports simple quotes)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Require-Command([string] $name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "Required command not found in PATH: $name"
  }
}

function Ensure-Dir([string] $path) {
  New-Item -Force -ItemType Directory $path | Out-Null
}

function Get-FileSha256([string] $path) {
  if ([string]::IsNullOrWhiteSpace($path)) { return $null }
  if (-not (Test-Path $path)) { return $null }
  return (Get-FileHash -Algorithm SHA256 $path).Hash.ToLowerInvariant()
}

function Try-GetGitSha([string] $dir) {
  if (Get-Command git -ErrorAction SilentlyContinue) {
    try {
      $sha = (git -C $dir rev-parse HEAD 2>$null).Trim()
      if ($sha) { return $sha }
    } catch { }
  }
  return $null
}

function Read-FirstLine([string] $path) {
  return (Get-Content -Path $path -TotalCount 1).Trim()
}

function Split-Args([string] $s) {
  # Simple splitter: handles tokens and basic double-quoted strings.
  if ([string]::IsNullOrWhiteSpace($s)) { return @() }
  $pattern = '("([^"\\]|\\.)*"|\S+)'
  $matches = [regex]::Matches($s, $pattern)
  $args = @()
  foreach ($m in $matches) {
    $v = $m.Value
    if ($v.StartsWith('"') -and $v.EndsWith('"')) { $v = $v.Substring(1, $v.Length-2) }
    $args += $v
  }
  return $args
}

function Create-ArchiveWithTar([string] $SourceDir, [string] $OutFile) {
  $outParent = Split-Path -Parent $OutFile
  if (-not [string]::IsNullOrWhiteSpace($outParent)) { Ensure-Dir $outParent }
  if (Test-Path $OutFile) { Remove-Item $OutFile -Force }

  Write-Host "==> Creating archive using tar: $OutFile"
  # -a chooses format from extension (.zip or .tar.gz)
  tar -a -c -f $OutFile -C $SourceDir .
}

function Get-ProjectNameFromPyproject([string] $projectDirAbs) {
  $pyproject = Join-Path $projectDirAbs "pyproject.toml"
  if (-not (Test-Path $pyproject)) { throw "pyproject.toml not found at: $pyproject" }

  $lines = Get-Content $pyproject -Encoding UTF8
  $inProject = $false
  foreach ($line in $lines) {
    $trim = $line.Trim()
    if ($trim -match '^\[project\]\s*$') { $inProject = $true; continue }
    if ($inProject -and $trim -match '^\[.*\]\s*$') { break }
    if ($inProject -and $trim -match '^\s*name\s*=\s*"(.*)"\s*$') { return $Matches[1] }
    if ($inProject -and $trim -match "^\s*name\s*=\s*'(.*)'\s*$") { return $Matches[1] }
  }
  throw "Could not find [project].name in pyproject.toml"
}

# ---- Preconditions ----
Require-Command "uv"
Require-Command "tar"

$ProjectDirAbs = (Resolve-Path $ProjectDir).Path

$LockPath  = Join-Path $ProjectDirAbs "uv.lock"
$PyVerPath = Join-Path $ProjectDirAbs ".python-version"

if (-not (Test-Path $PyVerPath)) { throw ".python-version not found at: $PyVerPath" }
if (-not (Test-Path $LockPath))  { throw "uv.lock not found at: $LockPath" }

$PythonVersion = Read-FirstLine $PyVerPath
if ([string]::IsNullOrWhiteSpace($PythonVersion)) { throw ".python-version is empty" }

$ProjectName = Get-ProjectNameFromPyproject $ProjectDirAbs

# Resolve stage/output paths (allow relative)
$StageDirAbs = $StageDir
if (-not [System.IO.Path]::IsPathRooted($StageDirAbs)) { $StageDirAbs = Join-Path (Get-Location) $StageDirAbs }

$OutAbs = $OutArchive
if (-not [System.IO.Path]::IsPathRooted($OutAbs)) { $OutAbs = Join-Path (Get-Location) $OutAbs }

# Clean stage
if (Test-Path $StageDirAbs) { Remove-Item $StageDirAbs -Recurse -Force }
Ensure-Dir $StageDirAbs

Write-Host "==> ProjectDir:      $ProjectDirAbs"
Write-Host "==> Project name:    $ProjectName"
Write-Host "==> Python version:  $PythonVersion (from .python-version)"
Write-Host "==> Lockfile:        $LockPath"
Write-Host "==> StageDir:        $StageDirAbs"
Write-Host "==> OutArchive:      $OutAbs"
Write-Host "==> Flatten runtime: $FlattenRuntime"

# 1) Install uv-managed Python (source runtime)
#    This does NOT modify system Python and does not put python.exe on PATH.
Write-Host "==> Ensuring uv-managed Python $PythonVersion is installed"
uv python install $PythonVersion | Out-Host

# 2) Locate the installed runtime directory (source)
Write-Host "==> Locating installed Python runtime (source)"
$PythonDir = (uv python dir).Trim()
if (-not (Test-Path $PythonDir)) { throw "uv python dir returned missing path: $PythonDir" }

$parts = $PythonVersion.Split(".")
if ($parts.Length -lt 2) { throw "Invalid Python version in .python-version: $PythonVersion" }
$mm = $parts[0] + "." + $parts[1]

$PyHome = Get-ChildItem $PythonDir -Directory |
  Where-Object { $_.Name -like ("cpython-" + $mm + "*") } |
  Select-Object -First 1
if (-not $PyHome) { throw "Could not find installed cpython-$mm* under: $PythonDir" }

$BasePyExe = Join-Path $PyHome.FullName "python.exe"
if (-not (Test-Path $BasePyExe)) { throw "python.exe not found at: $BasePyExe" }

Write-Host "==> Source runtime: $($PyHome.FullName)"
Write-Host "==> Source version: $((& $BasePyExe --version).Trim())"

# 3) Copy runtime into stage (we mutate the COPY, never the uv cache)
$StagePyExe = $null
if ($FlattenRuntime) {
  Write-Host "==> Copying runtime contents into stage root"
  Copy-Item (Join-Path $PyHome.FullName "*") $StageDirAbs -Recurse -Force
  $StagePyExe = Join-Path $StageDirAbs "python.exe"
} else {
  Write-Host "==> Copying runtime into stage\python"
  $StagePython = Join-Path $StageDirAbs "python"
  Copy-Item $PyHome.FullName $StagePython -Recurse -Force
  $StagePyExe = Join-Path $StagePython "python.exe"
}

if (-not (Test-Path $StagePyExe)) { throw "Staged python.exe not found at: $StagePyExe" }

# 4) Export requirements from uv.lock, excluding the local project itself.
#    Your uv requires --project <path>. We also:
#      - --frozen: refuse to change the lock
#      - --no-emit-workspace + --no-emit-package <project>: omit the project line (e.g. -e .)
#      - --no-hashes: avoid pip hash constraints (pip + local projects/hashes don't mix; we exclude the project anyway)
$ReqPath = Join-Path $StageDirAbs "requirements-export.txt"
Write-Host "==> Exporting pinned dependencies from uv.lock to: $ReqPath"

uv export --format requirements.txt --project $ProjectDirAbs --frozen `
  --no-emit-workspace --no-emit-package $ProjectName --no-hashes `
  --output-file $ReqPath | Out-Host

if (-not (Test-Path $ReqPath)) { throw "Export failed: $ReqPath not created" }

# 5) Install dependencies into the staged runtime.
#    The staged runtime still has a PEP 668 "externally managed" marker, so pip requires:
#      --break-system-packages
#    This is safe here because the staged runtime is disposable build output.
$pipCommon = @("--break-system-packages", "--no-warn-script-location")
if ($DisablePipCache) { $pipCommon += "--no-cache-dir" }
if (-not [string]::IsNullOrWhiteSpace($ExtraPipArgs)) { $pipCommon += (Split-Args $ExtraPipArgs) }

Write-Host "==> Installing dependencies into staged runtime via pip"
& $StagePyExe -m pip --version | Out-Host

# Export is already fully resolved/pinned; --no-deps prevents pip from re-resolving.
& $StagePyExe -m pip install -r $ReqPath --no-deps @pipCommon | Out-Host

# 6) Write artifact metadata for traceability
$builtAt  = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK")
$pyExact  = (& $StagePyExe -c "import sys; print(sys.version.split()[0])").Trim()
$gitSha   = Try-GetGitSha $ProjectDirAbs
$lockHash = Get-FileSha256 $LockPath
$reqHash  = Get-FileSha256 $ReqPath

$info = [ordered]@{
  artifact_type = "python_env_standalone"
  env_tag       = $EnvTag
  python        = $pyExact
  python_req    = $PythonVersion
  platform      = $Platform
  built_at      = $builtAt
  git_sha       = $gitSha
  uv_lock_sha256 = $lockHash
  exported_requirements_sha256 = $reqHash
  flattened_runtime = [bool]$FlattenRuntime
  pep668_override_used = $true
  uv_export = @{
    frozen = $true
    no_emit_workspace = $true
    no_emit_package = $ProjectName
    no_hashes = $true
  }
}

($info | ConvertTo-Json -Depth 8) | Out-File (Join-Path $StageDirAbs "ENV-INFO.json") -Encoding utf8

# 7) Sanity check: verify interpreter runs
Write-Host "==> Sanity check"
& $StagePyExe -c "import sys; print('OK:', sys.version)" | Out-Host

# 8) Create archive (fast) using tar
Create-ArchiveWithTar -SourceDir $StageDirAbs -OutFile $OutAbs

Write-Host ""
Write-Host "DONE"
Write-Host "  Archive: $OutAbs"
Write-Host "  Stage:   $StageDirAbs"
Write-Host "  Python:  $pyExact ($Platform)"
Write-Host "  Run path after unzip:"
if ($FlattenRuntime) {
  Write-Host "    <ENV_ROOT>\python.exe"
} else {
  Write-Host "    <ENV_ROOT>\python\python.exe"
}

# Runs test cases in throwaway containers: one image per matrix row, one
# container per (row, profile, case), strictly sequential.
#
#   pwsh test/run.ps1 [-Context <name>] [-Only <regex>] [-Row <regex>] [-KeepImages]
#   pwsh test/run.ps1 -ListRows
#
# The docker context comes from -Context or $env:DOTFILES_TEST_CONTEXT. The
# repo is baked into the image (COPY . /src) because a remote context cannot
# bind-mount local paths. -ListRows prints the row names as a JSON array (the
# CI matrix is built from it) and touches no docker host.
[CmdletBinding()]
param(
    [string]$Context = $env:DOTFILES_TEST_CONTEXT,
    [string]$Only = '',
    [Alias('Row')][string]$RowPattern = '',
    [switch]$KeepImages,
    [switch]$ListRows
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

# Matrix rows. Zsh/Git map to the Dockerfile build args WITH_ZSH/WITH_GIT.
# A row may narrow itself down: Profiles (default: minimal and server), Cases (a
# regex on the case name, default: all) and Env (variables set in the container).
# u20-ws is the workstation row: it pretends to be WSL1 (DF_PROC_VERSION_FILE
# points at a fixture) and runs only the cases that know that profile, because
# its install downloads python, opencode and opentofu. 80-migrate runs there in full: it
# needs git and the WSL1 pretence. r9 (no WSL) runs its profile case, offline; the other rows
# load the case and skip it.
$rows = @(
    @{ Name = 'u20-zsh';   Base = 'ubuntu:20.04';    Zsh = 1; Git = 1 }
    @{ Name = 'u20-nozsh'; Base = 'ubuntu:20.04';    Zsh = 0; Git = 1 }
    @{ Name = 'u22';       Base = 'ubuntu:22.04';    Zsh = 1; Git = 1 }
    @{ Name = 'u24-nogit'; Base = 'ubuntu:24.04';    Zsh = 1; Git = 0 }
    @{ Name = 'd12';       Base = 'debian:12';       Zsh = 1; Git = 1 }
    @{ Name = 'd13';       Base = 'debian:13';       Zsh = 1; Git = 1 }
    @{ Name = 'r9';        Base = 'rockylinux:9';    Zsh = 1; Git = 1 }
    @{ Name = 'u20-ws';    Base = 'ubuntu:20.04';    Zsh = 1; Git = 1
       Profiles = @('workstation'); Cases = '^(00|60|70|80)-'
       Env = @{ DF_PROC_VERSION_FILE = '/src/test/fixtures/proc-version-wsl1' } }
)
$defaultProfiles = @('minimal', 'server')

if ($ListRows) {
    ConvertTo-Json -Compress -InputObject @($rows | ForEach-Object { $_.Name })
    exit 0
}

$rows = @($rows | Where-Object { $_.Name -match $RowPattern })
if ($rows.Count -eq 0) {
    Write-Error "No matrix rows match -Row '$RowPattern'."
    exit 1
}

function Invoke-Docker {
    # Runs docker against the chosen context; returns exit code and output lines.
    param([string[]]$DockerArgs)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & docker --context $Context @DockerArgs 2>&1 | ForEach-Object { "$_" }
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output) }
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

function Write-Result {
    param([string]$Row, [string]$Profile, [string]$Case, [string]$Status)
    Write-Host ('{0,-10} | {1,-8} | {2,-14} | {3}' -f $Row, $Profile, $Case, $Status)
}

function Write-Indented {
    param([string[]]$Lines)
    foreach ($line in $Lines) { Write-Host "    $line" }
}

# --- Context guard -----------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Context)) {
    Write-Error 'No docker context: pass -Context or set $env:DOTFILES_TEST_CONTEXT.'
    exit 1
}
if ($Context -match '(?i)prod') {
    Write-Error "Refusing to run on docker context '$Context': name contains 'prod'."
    exit 1
}
$null = & docker context inspect $Context 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Docker context '$Context' does not exist."
    exit 1
}

# --- Case selection ----------------------------------------------------------
$cases = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'cases') -Filter '*.sh' |
    Where-Object { $_.BaseName -match $Only } |
    Sort-Object Name |
    ForEach-Object { $_.BaseName })
if ($cases.Count -eq 0) {
    Write-Error "No test cases match -Only '$Only'."
    exit 1
}

$failed = $false

try {
    Write-Host ('{0,-10} | {1,-8} | {2,-14} | {3}' -f 'row', 'profile', 'case', 'result')
    Write-Host ('-' * 52)

    foreach ($row in $rows) {
        $rowCases = @($cases | Where-Object { -not $row.ContainsKey('Cases') -or $_ -match $row.Cases })
        if ($rowCases.Count -eq 0) { continue }
        $rowProfiles = if ($row.ContainsKey('Profiles')) { $row.Profiles } else { $defaultProfiles }
        $tag = "dotfiles-test:$($row.Name)"
        $build = Invoke-Docker @(
            'build', '--quiet',
            '--label', 'dotfiles-test',
            '--build-arg', "BASE=$($row.Base)",
            '--build-arg', "WITH_ZSH=$($row.Zsh)",
            '--build-arg', "WITH_GIT=$($row.Git)",
            '--tag', $tag,
            '--file', (Join-Path $PSScriptRoot 'Dockerfile'),
            $repoRoot
        )
        if ($build.ExitCode -ne 0) {
            $failed = $true
            Write-Result $row.Name '-' 'image-build' 'FAIL'
            Write-Indented ($build.Output | Select-Object -Last 40)
            continue
        }

        foreach ($profile in $rowProfiles) {
            foreach ($case in $rowCases) {
                $runArgs = @('run', '--rm', '--memory', '768m', '--cpus', '1', '--label', 'dotfiles-test')
                if ($profile -eq 'minimal') {
                    # The minimal profile must work offline.
                    $runArgs += @('--network', 'none')
                }
                elseif ($env:GITHUB_TOKEN) {
                    # Value is read from the environment by docker; never printed.
                    $runArgs += @('-e', 'GITHUB_TOKEN')
                }
                if ($row.ContainsKey('Env')) {
                    foreach ($name in $row.Env.Keys) { $runArgs += @('-e', "$name=$($row.Env[$name])") }
                }
                $runArgs += @($tag, 'bash', '/src/test/run-case.sh', $case, $profile, $row.Name)

                $run = Invoke-Docker $runArgs
                if ($run.ExitCode -eq 0) {
                    Write-Result $row.Name $profile $case 'PASS'
                }
                else {
                    $failed = $true
                    Write-Result $row.Name $profile $case 'FAIL'
                    Write-Indented $run.Output
                }
            }
        }
    }
}
finally {
    if (-not $KeepImages) {
        # Only images this script tags; other images on the host are untouched.
        $images = Invoke-Docker @('images', '--format', '{{.Repository}}:{{.Tag}}', '--filter', 'reference=dotfiles-test:*')
        foreach ($image in $images.Output) {
            if ($image -like 'dotfiles-test:*') {
                $null = Invoke-Docker @('rmi', '--force', $image)
            }
        }
    }
}

if ($failed) { exit 1 }
exit 0

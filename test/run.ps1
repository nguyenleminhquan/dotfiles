# Runs test cases in throwaway containers: one image per matrix row, one
# container per (row, profile, case), strictly sequential.
#
#   pwsh test/run.ps1 [-Context <name>] [-Only <regex>] [-KeepImages]
#
# The docker context comes from -Context or $env:DOTFILES_TEST_CONTEXT. The
# repo is baked into the image (COPY . /src) because a remote context cannot
# bind-mount local paths.
[CmdletBinding()]
param(
    [string]$Context = $env:DOTFILES_TEST_CONTEXT,
    [string]$Only = '',
    [switch]$KeepImages
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

# Matrix rows. Zsh/Git map to the Dockerfile build args WITH_ZSH/WITH_GIT.
$rows = @(
    @{ Name = 'u20-zsh';   Base = 'ubuntu:20.04';    Zsh = 1; Git = 1 }
    @{ Name = 'u20-nozsh'; Base = 'ubuntu:20.04';    Zsh = 0; Git = 1 }
    @{ Name = 'u22';       Base = 'ubuntu:22.04';    Zsh = 1; Git = 1 }
    @{ Name = 'u24-nogit'; Base = 'ubuntu:24.04';    Zsh = 1; Git = 0 }
    @{ Name = 'r9';        Base = 'rockylinux:9';    Zsh = 1; Git = 1 }
)
$profiles = @('minimal', 'server')

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

        foreach ($profile in $profiles) {
            foreach ($case in $cases) {
                $runArgs = @('run', '--rm', '--memory', '768m', '--cpus', '1', '--label', 'dotfiles-test')
                if ($profile -eq 'minimal') {
                    # The minimal profile must work offline.
                    $runArgs += @('--network', 'none')
                }
                elseif ($env:GITHUB_TOKEN) {
                    # Value is read from the environment by docker; never printed.
                    $runArgs += @('-e', 'GITHUB_TOKEN')
                }
                $runArgs += @($tag, 'bash', '/src/test/run-case.sh', $case, $profile)

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

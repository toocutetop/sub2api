param(
    [ValidateRange(1, 65535)]
    [int]$Port = 9000
)

$ErrorActionPreference = 'Stop'

$composeFile = Join-Path $PSScriptRoot 'docker-compose.dev.yml'
$envFile = Join-Path $PSScriptRoot '.env'
$env:BIND_HOST = '127.0.0.1'
$env:SERVER_PORT = $Port.ToString()

function Invoke-DockerCompose {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

    & docker compose -f $composeFile @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "docker compose failed with exit code $LASTEXITCODE"
    }
}

function Wait-DockerReady {
    & docker info *> $null
    if ($LASTEXITCODE -eq 0) {
        return
    }

    $dockerDesktop = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
    if (-not (Test-Path -LiteralPath $dockerDesktop)) {
        throw 'Docker Desktop is unavailable. Install Docker Desktop, then run this script again.'
    }

    Write-Host '[Sub2API] Docker Desktop is not running; starting it...'
    Start-Process -FilePath $dockerDesktop -WindowStyle Hidden

    $deadline = (Get-Date).AddMinutes(2)
    do {
        Start-Sleep -Seconds 2
        & docker info *> $null
        if ($LASTEXITCODE -eq 0) {
            return
        }
    } while ((Get-Date) -lt $deadline)

    throw 'Docker Desktop did not become ready within 2 minutes.'
}

function Assert-PortAvailable {
    param([int]$CandidatePort)

    $excluded = & netsh interface ipv4 show excludedportrange protocol=tcp
    foreach ($line in $excluded) {
        if ($line -match '^\s*(\d+)\s+(\d+)') {
            $rangeStart = [int]$Matches[1]
            $rangeEnd = [int]$Matches[2]
            if ($CandidatePort -ge $rangeStart -and $CandidatePort -le $rangeEnd) {
                throw "Port $CandidatePort is reserved by Windows (TCP range $rangeStart-$rangeEnd)."
            }
        }
    }

    $listeners = Get-NetTCPConnection -State Listen -LocalPort $CandidatePort -ErrorAction SilentlyContinue
    if ($listeners) {
        $ownerList = ($listeners | Select-Object -ExpandProperty OwningProcess -Unique) -join ', '
        throw "Port $CandidatePort is occupied by PID(s): $ownerList."
    }
}

try {
    Write-Host '[Sub2API] Checking Docker...'
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw 'Docker was not found. Install or start Docker Desktop first.'
    }
    if (-not (Test-Path -LiteralPath $envFile)) {
        throw 'deploy/.env is missing. Create it from deploy/.env.example and configure the required secrets.'
    }

    Wait-DockerReady

    Write-Host '[Sub2API] Stopping the previous local stack...'
    Invoke-DockerCompose down --remove-orphans
    Assert-PortAvailable -CandidatePort $Port

    Write-Host '[Sub2API] Building and starting the current workspace...'
    Invoke-DockerCompose up -d --build --force-recreate

    Write-Host '[Sub2API] Waiting for the health check...'
    $deadline = (Get-Date).AddMinutes(3)
    $healthy = $false
    do {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 3
            $healthy = $response.StatusCode -eq 200
        } catch {
            $healthy = $false
        }

        if (-not $healthy) {
            Start-Sleep -Seconds 2
        }
    } while (-not $healthy -and (Get-Date) -lt $deadline)

    if (-not $healthy) {
        throw 'The service did not pass its health check within 3 minutes.'
    }

    Invoke-DockerCompose ps
    Write-Host ''
    Write-Host "[Sub2API] Ready: http://127.0.0.1:$Port"
    exit 0
} catch {
    Write-Host ''
    Write-Host "[Sub2API] Startup failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

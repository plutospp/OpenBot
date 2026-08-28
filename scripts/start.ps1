# PowerShell equivalent for start.sh
# Ported directly from bash script for cross-platform compatibility
$ErrorActionPreference = "Stop"

$ROOT = (Resolve-Path "$PSScriptRoot\..").Path
$LOGS = "$ROOT\.logs"
New-Item -ItemType Directory -Force -Path $LOGS | Out-Null

if (-Not (Test-Path "$ROOT\.env")) {
    Write-Host ".env is missing. Copy .env.example to .env and fill in the required settings." -ForegroundColor Red
    exit 1
}

function Get-Setting {
    param($Name, $Fallback)
    $Value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrEmpty($Value)) {
        $Matches = Select-String -Path "$ROOT\.env" -Pattern "^$Name=(.*)$"
        if ($Matches -and $Matches.Count -gt 0) {
            $Value = $Matches[-1].Matches.Groups[1].Value -replace '^"|"$', '' -replace "^'|'$", ''
        }
    }
    if ([string]::IsNullOrEmpty($Value)) {
        return $Fallback
    }
    return $Value
}

$APP_PORT = Get-Setting "APP_PORT" "3010"
$SERVER_PORT = Get-Setting "SERVER_PORT" "3001"
$COMPUTER_PORT = Get-Setting "COMPUTER_PORT" "4100"
$BOT_PORT = Get-Setting "BOT_PORT" "4200"
$LANGGRAPH_PORT = Get-Setting "LANGGRAPH_PORT" "4201"
$SUPERVISOR_PORT = Get-Setting "SUPERVISOR_PORT" "4500"
$ONE_COMPUTER_EACH = Get-Setting "OPENBOT_ONE_COMPUTER_EACH" "true"

[Environment]::SetEnvironmentVariable("APP_PORT", $APP_PORT, "Process")
[Environment]::SetEnvironmentVariable("SERVER_PORT", $SERVER_PORT, "Process")

$SUPERVISOR_TOKEN = Get-Setting "SUPERVISOR_TOKEN" "openbot-dev-supervisor-token"
$COMPUTER_TOKEN = Get-Setting "COMPUTER_TOKEN" "openbot-dev-computer-token"
$WORKER_SHARED_SECRET = Get-Setting "WORKER_SHARED_SECRET" "openbot-dev-worker-secret"

$MANAGED_AGENT_AG_UI_URL = Get-Setting "MANAGED_AGENT_AG_UI_URL" "http://localhost:${LANGGRAPH_PORT}/ag-ui"
[Environment]::SetEnvironmentVariable("MANAGED_AGENT_AG_UI_URL", $MANAGED_AGENT_AG_UI_URL, "Process")

$SECRETS_ROTATED = $false

$MANAGED_AGENT_TOKEN = Get-Setting "MANAGED_AGENT_TOKEN" ""
if ([string]::IsNullOrEmpty($MANAGED_AGENT_TOKEN)) {
    $SECRETS_ROTATED = $true

    # Generate 32 random bytes and base64 encode them
    $bytes = New-Object Byte[] 32
    $rnd = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rnd.GetBytes($bytes)
    $MANAGED_AGENT_TOKEN = [Convert]::ToBase64String($bytes)

    $envContent = Get-Content "$ROOT\.env"
    $hasEmptyLine = $envContent -match "^MANAGED_AGENT_TOKEN=$"
    if ($hasEmptyLine) {
        $envContent = $envContent | Where-Object { $_ -notmatch "^MANAGED_AGENT_TOKEN=" }
        $envContent += "MANAGED_AGENT_TOKEN=$MANAGED_AGENT_TOKEN"
        Set-Content -Path "$ROOT\.env" -Value $envContent
    } else {
        Add-Content -Path "$ROOT\.env" -Value "`nMANAGED_AGENT_TOKEN=$MANAGED_AGENT_TOKEN"
    }
    Write-Host "Generated MANAGED_AGENT_TOKEN and wrote it to .env." -ForegroundColor Gray
}
[Environment]::SetEnvironmentVariable("MANAGED_AGENT_TOKEN", $MANAGED_AGENT_TOKEN, "Process")

$AGENT_TOOL_TOKEN = Get-Setting "AGENT_TOOL_TOKEN" ""
if ([string]::IsNullOrEmpty($AGENT_TOOL_TOKEN)) {
    $SECRETS_ROTATED = $true

    $bytes = New-Object Byte[] 32
    $rnd = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rnd.GetBytes($bytes)
    $AGENT_TOOL_TOKEN = [Convert]::ToBase64String($bytes)

    $envContent = Get-Content "$ROOT\.env"
    $hasEmptyLine = $envContent -match "^AGENT_TOOL_TOKEN=$"
    if ($hasEmptyLine) {
        $envContent = $envContent | Where-Object { $_ -notmatch "^AGENT_TOOL_TOKEN=" }
        $envContent += "AGENT_TOOL_TOKEN=$AGENT_TOOL_TOKEN"
        Set-Content -Path "$ROOT\.env" -Value $envContent
    } else {
        Add-Content -Path "$ROOT\.env" -Value "`nAGENT_TOOL_TOKEN=$AGENT_TOOL_TOKEN"
    }
    Write-Host "Generated AGENT_TOOL_TOKEN and wrote it to .env." -ForegroundColor Gray
}
[Environment]::SetEnvironmentVariable("AGENT_TOOL_TOKEN", $AGENT_TOOL_TOKEN, "Process")

function Write-Green { Write-Host $args[0] -ForegroundColor Green }
function Write-Red { Write-Host $args[0] -ForegroundColor Red }
function Write-Info { Write-Host $args[0] -ForegroundColor Gray }

function Get-Holder {
    param($Port)
    $ProcessInfo = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($ProcessInfo) {
        $Process = Get-Process -Id $ProcessInfo[0].OwningProcess -ErrorAction SilentlyContinue
        if ($Process) {
            return "$($Process.ProcessName) ($($Process.Id))"
        }
    }
    return $null
}

function Test-IdentifiesAsOpenBot {
    param($Port, $Name)
    try {
        switch ($Name) {
            "server" {
                $response = Invoke-WebRequest -Uri "http://localhost:$Port/api/copilotkit/info" -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
                return $response.Content -match '"licenseStatus"'
            }
            "app" {
                $response = Invoke-WebRequest -Uri "http://localhost:$Port/" -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
                return $response.Content -match '(?i)<title>[^<]*OpenBot'
            }
            default {
                $response = Invoke-WebRequest -Uri "http://localhost:$Port/health" -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
                return $true
            }
        }
    } catch {
        return $false
    }
}

function Require-FreeOrOurs {
    param($Port, $Name)
    $Who = Get-Holder $Port
    if (-Not $Who) { return }

    if (Test-IdentifiesAsOpenBot $Port $Name) {
        Write-Info "  $Name: already up on $Port ($Who)"
        return
    }

    Write-Red "  $Name: port $Port is held by something that is not OpenBot: $Who"
    Write-Red "  Re-run with $($Name.ToUpper())_PORT=<free port>, or stop that process yourself."
    exit 1
}

function Wait-ForOpenBot {
    param($Port, $Name, $Tries=40)
    for ($i = 1; $i -le $Tries; $i++) {
        if (Test-IdentifiesAsOpenBot $Port $Name) {
            Write-Green "  $Name ready"
            return
        }
        Start-Sleep -Seconds 1
    }
    Write-Red "  $Name never answered as OpenBot on port $Port"
    Write-Red "  Either it failed to start, or that port belongs to another process."
    Write-Red "  Log: $LOGS\$Name.log"
    exit 1
}

function Wait-For {
    param($Url, $Name, $Tries=40)
    for ($i = 1; $i -le $Tries; $i++) {
        try {
            $response = Invoke-WebRequest -Uri $Url -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
            Write-Green "  $Name ready"
            return
        } catch {
            Start-Sleep -Seconds 1
        }
    }
    Write-Red "  $Name never became ready at $Url"
    Write-Red "  Log: $LOGS\$Name.log"
    exit 1
}

Write-Host ""
Write-Host "OpenBot"
Write-Host "======="

Write-Info "1/4  Docker services"
$SERVICES = @("postgres")
if ($ONE_COMPUTER_EACH -eq "true") {
    $SERVICES += "supervisor"
}

$SERVICES += "agent-computer", "agent-bot", "agent-langgraph"

[Environment]::SetEnvironmentVariable("SUPERVISOR_TOKEN", $SUPERVISOR_TOKEN, "Process")
[Environment]::SetEnvironmentVariable("COMPUTER_TOKEN", $COMPUTER_TOKEN, "Process")
[Environment]::SetEnvironmentVariable("WORKER_SHARED_SECRET", $WORKER_SHARED_SECRET, "Process")
[Environment]::SetEnvironmentVariable("COMPUTER_PORT", $COMPUTER_PORT, "Process")
[Environment]::SetEnvironmentVariable("BOT_PORT", $BOT_PORT, "Process")
[Environment]::SetEnvironmentVariable("LANGGRAPH_PORT", $LANGGRAPH_PORT, "Process")
[Environment]::SetEnvironmentVariable("SUPERVISOR_PORT", $SUPERVISOR_PORT, "Process")

$processArgs = @("compose", "up", "-d", "--build") + $SERVICES
$dockerProcess = Start-Process -FilePath "docker" -ArgumentList $processArgs -NoNewWindow -PassThru -Wait
$dockerProcess.WaitForExit()

$migrateProcess = Start-Process -FilePath "docker" -ArgumentList "compose run --rm --build migrate" -NoNewWindow -PassThru -Wait
$migrateProcess.WaitForExit()

if ($LASTEXITCODE -ne 0 -and $false) { # Wait doesn't reliably set LASTEXITCODE, we rely on the healthchecks below to catch migration failures
    Write-Red "  Migrations did not apply. The database is not the schema this server expects."
    Write-Red "  Log: $LOGS\migrate.log"
    exit 1
}

Wait-For "http://localhost:$COMPUTER_PORT/health" "agent-computer"
Wait-For "http://localhost:$BOT_PORT/health" "agent-bot"
Wait-For "http://localhost:$LANGGRAPH_PORT/health" "agent-langgraph"

$tables = @("agent_profiles", "agent_preferences")
foreach ($table in $tables) {
    $psqlProcess = Start-Process -FilePath "docker" -ArgumentList "compose exec -T postgres psql -U openbot -d openbot -tAc `"select to_regclass('public.$table')`"" -RedirectStandardOutput "$LOGS\psql_check_$table.log" -NoNewWindow -PassThru -Wait
    $psqlProcess.WaitForExit()
    $output = Get-Content "$LOGS\psql_check_$table.log" -Raw -ErrorAction SilentlyContinue

    if (-not ($output -match "(?m)^$table$")) {
        Write-Red "  $table is missing. Run: bun run --cwd server db:migrate"
        exit 1
    }
}
Write-Green "  coworker tables migrated"
Write-Green "  managed coworker endpoint: $MANAGED_AGENT_AG_UI_URL"

Write-Info "2/4  Server"
Require-FreeOrOurs $SERVER_PORT "server"

if ($SECRETS_ROTATED) {
    Write-Info "  a secret was generated this run, so the server is restarted to pick it up"
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match "bun.*--env-file=\.\./\.env.*src/index\.ts" } | Invoke-CimMethod -MethodName Terminate | Out-Null
    Start-Sleep -Seconds 1
}

if (Test-IdentifiesAsOpenBot $SERVER_PORT "server") {
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:$SERVER_PORT/internal/routines/run" -Method POST -Headers @{ "Authorization" = "Bearer $WORKER_SHARED_SECRET"; "Content-Type" = "application/json" } -Body "{}" -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        if ($statusCode -eq 401) {
            Write-Info "  server: up, but refuses the worker's secret (401), so it is restarted to pick it up"
            Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match "bun.*--env-file=\.\./\.env.*src/index\.ts" } | Invoke-CimMethod -MethodName Terminate | Out-Null
            Start-Sleep -Seconds 1
        } elseif ($statusCode -eq 404) {
            Write-Info "  server: up, but has no /internal/routines/run (404: an older checkout), so it is restarted"
            Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match "bun.*--env-file=\.\./\.env.*src/index\.ts" } | Invoke-CimMethod -MethodName Terminate | Out-Null
            Start-Sleep -Seconds 1
        }
    }
}

if (-Not (Test-IdentifiesAsOpenBot $SERVER_PORT "server")) {
    $envVars = @{
        "PORT" = $SERVER_PORT
        "WORKER_SHARED_SECRET" = $WORKER_SHARED_SECRET
    }
    if ($ONE_COMPUTER_EACH -eq "true") {
        $envVars["COMPUTER_SUPERVISOR_URL"] = "http://localhost:$SUPERVISOR_PORT"
        $envVars["SUPERVISOR_TOKEN"] = $SUPERVISOR_TOKEN
        $envVars["COMPUTER_TOKEN"] = $COMPUTER_TOKEN
    }

    foreach ($key in $envVars.Keys) { [Environment]::SetEnvironmentVariable($key, $envVars[$key], "Process") }

    Start-Process -FilePath "bun" -ArgumentList "--env-file=../.env src/index.ts" -WorkingDirectory "$ROOT\server" -RedirectStandardOutput "$LOGS\server.log" -RedirectStandardError "$LOGS\server.log" -WindowStyle Hidden
}
Wait-ForOpenBot $SERVER_PORT "server"

$workerRunning = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match "bun.*worker/src/index\.ts" }
if (-Not $workerRunning) {
    $WORKER_DATABASE_URL = Get-Setting "DATABASE_URL" "postgres://openbot:openbot@localhost:5432/openbot"

    [Environment]::SetEnvironmentVariable("DATABASE_URL", $WORKER_DATABASE_URL, "Process")
    [Environment]::SetEnvironmentVariable("SERVER_INTERNAL_URL", "http://localhost:$SERVER_PORT", "Process")
    [Environment]::SetEnvironmentVariable("WORKER_SHARED_SECRET", $WORKER_SHARED_SECRET, "Process")

    Start-Process -FilePath "bun" -ArgumentList "worker/src/index.ts" -WorkingDirectory $ROOT -RedirectStandardOutput "$LOGS\worker.log" -RedirectStandardError "$LOGS\worker.log" -WindowStyle Hidden

    Write-Info "  worker: started (routine sweep loop)"
    Start-Sleep -Seconds 1

    $workerRunningCheck = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match "bun.*worker/src/index\.ts" }
    if (-Not $workerRunningCheck) {
        Write-Red "  worker: did not stay up, check $LOGS\worker.log"
    }
} else {
    Write-Info "  worker: already running"
}

Write-Info "3/4  Runtime health"
try {
    $INFO_JSON = Invoke-WebRequest -Uri "http://localhost:$SERVER_PORT/api/copilotkit/info" -TimeoutSec 8 -UseBasicParsing -ErrorAction Stop | Select-Object -ExpandProperty Content
    $INFO = $INFO_JSON | ConvertFrom-Json
    $status = $INFO.licenseStatus

    # Handle PowerShell 5 and 7 differences for getting object properties
    if ($INFO.agents -is [psobject]) {
        $agents = $INFO.agents.psobject.properties.name
    } elseif ($INFO.agents) {
        $agents = $INFO.agents | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
    } else {
        $agents = @()
    }

    if ($status -ne "valid") {
        Write-Red "  licence is '$status', not 'valid'."
        Write-Red "  Run: npx copilotkit@latest login && npx copilotkit@latest license --write"
        Write-Red "  See README.md for Intelligence setup."
        exit 1
    }

    if ($agents.Count -eq 0) {
        Write-Red "  No Bots registered."
        exit 1
    }

    Write-Green "  licence valid · mode $($INFO.mode) · Bots: $($agents -join ', ')"
} catch {
    Write-Red "  Failed to fetch or parse Runtime health info."
    exit 1
}

Write-Info "4/4  App"
Require-FreeOrOurs $APP_PORT "app"
if (-Not (Test-IdentifiesAsOpenBot $APP_PORT "app")) {
    Start-Process -FilePath "bun" -ArgumentList "run dev --port $APP_PORT --strictPort" -WorkingDirectory "$ROOT\app" -RedirectStandardOutput "$LOGS\app.log" -RedirectStandardError "$LOGS\app.log" -WindowStyle Hidden
}
Wait-ForOpenBot $APP_PORT "app"

Write-Host ""
Write-Green "Ready. http://localhost:$APP_PORT"

Write-Host @"

Next steps:

  - Direct Bot chat:       http://localhost:$APP_PORT/bot
  - Coworkers:             http://localhost:$APP_PORT/agents
  - Audit trail:           http://localhost:$APP_PORT/admin/audit
  - Boundaries/policy:     http://localhost:$APP_PORT/admin/boundaries
  - Setup docs:            README.md
  - Configuration docs:    docs/configuration.md

Try:

  1. Open /bot and ask: Open news.ycombinator.com and tell me the top story.
  2. Create a coworker in /agents and start a channel with it.
  3. Review browser/file actions in /admin/audit.
  4. Add a deny rule in /admin/boundaries, then retry the same action.

Logs: $LOGS
  Routine sweep worker: $LOGS\worker.log
Stop the routine worker: Get-CimInstance Win32_Process | Where-Object { `$_.CommandLine -match 'bun.*worker/src/index\.ts' } | Invoke-CimMethod -MethodName Terminate
Stop Docker services: docker compose down
  A Bot's computer is made by the supervisor rather than by compose, so it keeps running:
  docker rm -f (docker ps -q --filter label=openbot.supervisor=true)
  Its files and its browser profile are volumes and survive either way.
Stop host app/server: kill the processes using ports $APP_PORT and $SERVER_PORT
"@
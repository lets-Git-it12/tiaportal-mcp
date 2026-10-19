# tiaportal-mcp 설치/빌드 스크립트 (Windows PowerShell 5.1 이상)
#
# 레포 없이 이 파일만 받아서 실행해도 된다. 빌드 도구(git, .NET)가 없는 PC는 관리자 PowerShell에서
# 실행해야 자동 설치된다 (아니면 설치 명령만 안내). 도구가 다 있으면 일반 PowerShell로 충분:
#   powershell -ExecutionPolicy Bypass -File .\install-tiaportal-mcp.ps1
# 한 줄로 받아서 실행:
#   powershell -ExecutionPolicy Bypass -Command "iwr https://raw.githubusercontent.com/p-7347/tiaportal-mcp/rebase/upstream-base/install/install-tiaportal-mcp.ps1 -OutFile $env:TEMP\install-tiaportal-mcp.ps1; & $env:TEMP\install-tiaportal-mcp.ps1"
#
# 하는 일:
#   1. 빌드 도구 점검, 없으면 winget으로 설치 (git, .NET SDK 8, .NET Framework 4.8 Developer Pack)
#      - 설치 중 Windows가 관리자 확인(UAC) 창을 띄우면 '예'를 눌러야 한다.
#   2. 설치된 TIA Portal 버전 감지 (V20/V21), 'Siemens TIA Openness' 그룹 가입 확인
#   3. 소스 받기 (clone 또는 pull) -> 그 TIA 버전에 맞게 빌드 -> --doctor 점검
#   4. MCP 클라이언트 등록 (Claude Desktop, Claude Code, Antigravity) 과 설정 예시 출력
# 서버는 읽기 전용으로 등록된다 (-AllowWrite 를 주면 쓰기 툴까지). 다시 실행해도 된다 (업데이트용).
#
# 옵션:
#   -TiaVersion 20|21     감지 대신 이 버전만 빌드 (기본: 설치된 버전을 감지해서 빌드.
#                         둘 다 있으면 둘 다 빌드하고 tiaportal-mcp-v20 / -v21 두 서버로 등록)
#   -InstallDir <폴더>     소스/빌드 위치 (기본 C:\Tools\tiaportal-mcp)
#   -NoInstall            빌드 도구를 자동 설치하지 않고 안내만
#   -AddToOpennessGroup   그룹에 없으면 관리자 권한으로 현재 사용자를 추가 (UAC 창이 뜬다)
#   -AllowWrite           쓰기 툴까지 등록 (--allow-write)
#   -NoRegister           MCP 클라이언트 등록 없이 빌드와 설정 예시 출력만

param(
    [int]$TiaVersion = 0,
    [string]$InstallDir = "C:\Tools\tiaportal-mcp",
    [string]$ServerName = "tiaportal-mcp",
    [string]$Repo = "https://github.com/p-7347/tiaportal-mcp.git",
    [string]$Branch = "rebase/upstream-base",
    [switch]$NoInstall,
    [switch]$AddToOpennessGroup,
    [switch]$AllowWrite,
    [switch]$NoRegister
)

$ErrorActionPreference = "Stop"
$problems = @()

function Step($text) { Write-Host ""; Write-Host "== $text" -ForegroundColor Cyan }
function Ok($text) { Write-Host "  OK  $text" -ForegroundColor Green }
function Warn($text) { Write-Host "  !!  $text" -ForegroundColor Yellow }
function Fail($text) { Write-Host "  XX  $text" -ForegroundColor Red; exit 1 }

function Run([string]$exe, [string[]]$arguments) {
    & $exe @arguments
    if ($LASTEXITCODE -ne 0) { Fail "'$exe $($arguments -join ' ')' 실패 (exit $LASTEXITCODE)" }
}

# winget 설치 직후에도 이 창에서 새 명령이 보이도록 PATH를 레지스트리에서 다시 읽는다.
# 설치 프로그램이 PATH를 늦게 고치거나 사용자 범위로 설치해도 찾도록, 기본 설치 폴더도 붙인다.
function Refresh-Path {
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $user = [Environment]::GetEnvironmentVariable("Path", "User")
    $known = @(
        "$env:ProgramFiles\Git\cmd",
        "$env:LOCALAPPDATA\Programs\Git\cmd",
        "$env:ProgramFiles\dotnet",
        "$env:LOCALAPPDATA\Microsoft\dotnet"
    ) | Where-Object { Test-Path $_ }
    $env:Path = (@($machine, $user) + $known) -join ";"
}

Refresh-Path
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$manualInstalls = @()
$hasWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)

# 후보 winget ID를 차례로 설치해 보고, 설치 뒤 $check 가 참이면 성공.
function Install-Tool([string]$name, [string[]]$wingetIds, [scriptblock]$check, [string]$manualUrl) {
    if (& $check) { Ok $name; return $true }

    # 관리자 권한 없이 실행하면 winget이 UAC 창을 띄워야 하는데, AI 도구 안이나 원격 셸처럼
    # 화면 없는 창에서는 그 창이 뜨지 않고 설치가 조용히 실패한다. 그래서 시도하지 않고 명령을 안내한다.
    if (-not $isAdmin -and -not $NoInstall -and $hasWinget) {
        Warn "$name 이(가) 없습니다. 관리자 권한이 아니라 자동 설치는 건너뜁니다."
        $script:manualInstalls += "winget install --id $($wingetIds[0]) -e --source winget --accept-package-agreements --accept-source-agreements"
        return $false
    }

    if ($NoInstall -or -not $hasWinget) {
        $why = if ($NoInstall) { "-NoInstall" } else { "winget 없음" }
        Warn "$name 이(가) 없습니다 ($why). 직접 설치: $manualUrl"
        return $false
    }

    foreach ($id in $wingetIds) {
        Write-Host "  ..  $name 설치 중 (winget $id). 관리자 확인 창이 뜨면 '예'를 누르세요."
        # '--source winget': 회사 PC에서 msstore 원본의 약관/인증서 문제로 설치 전체가 멈추는 일을 피한다.
        & winget install --id $id -e --source winget --silent --accept-package-agreements --accept-source-agreements | Out-Host
        $code = $LASTEXITCODE
        Refresh-Path
        if (& $check) { Ok "$name (방금 설치)"; return $true }
        Warn "winget $id 결과: exit $code"
    }

    Warn "$name 자동 설치에 실패했습니다. 직접 설치: $manualUrl"
    Warn "또는 PowerShell에서:  winget install --id $($wingetIds[0]) -e --source winget"
    return $false
}

# 1. 빌드 도구 ------------------------------------------------------------
Step "빌드 도구"
if (-not $hasWinget -and -not $NoInstall) {
    Warn "winget이 없어 자동 설치는 못 합니다 (Microsoft Store의 '앱 설치 관리자'가 winget입니다). 없는 도구는 안내 주소에서 직접 설치하세요."
}

$refAsm = "${env:ProgramFiles(x86)}\Reference Assemblies\Microsoft\Framework\.NETFramework\v4.8"

$okGit = Install-Tool "git" @("Git.Git") { [bool](Get-Command git -ErrorAction SilentlyContinue) } "https://git-scm.com/download/win"
$okSdk = Install-Tool ".NET SDK 8 이상" @("Microsoft.DotNet.SDK.8") {
    (Get-Command dotnet -ErrorAction SilentlyContinue) -and ((& dotnet --list-sdks 2>$null) -match '^([89]|\d\d)\.')
} "https://dotnet.microsoft.com/download/dotnet/8.0"
$okRef = Install-Tool ".NET Framework 4.8 Developer Pack" @("Microsoft.DotNet.Framework.DeveloperPack_4", "Microsoft.DotNet.Framework.DeveloperPack.4.8") {
    Test-Path $refAsm
} "https://dotnet.microsoft.com/download/dotnet-framework/thank-you/net48-developer-pack-offline-installer"

if ($manualInstalls.Count -gt 0) {
    Warn "Windows 시작 메뉴에서 PowerShell을 '관리자 권한으로 실행'으로 열고 아래 줄을 붙여넣으세요:"
    $manualInstalls | ForEach-Object { Write-Host "      $_" }
    Warn "또는 이 스크립트 자체를 관리자 PowerShell에서 실행하면 자동으로 설치합니다."
}

if (-not ($okGit -and $okSdk -and $okRef)) {
    Fail "빌드 도구가 모자랍니다. 위 안내대로 설치한 뒤 PowerShell을 새로 열고 이 스크립트를 다시 실행하세요."
}

# 2. TIA Portal 버전, Openness 그룹 -----------------------------------------
Step "TIA Portal"
function Test-Tia([int]$v) {
    $dir = "$env:ProgramFiles\Siemens\Automation\Portal V$v"
    (Test-Path "HKLM:\SOFTWARE\Siemens\Automation\_InstalledSW\TIAP$v") -or (Test-Path "$dir\PublicAPI\V$v")
}
$found = @(21, 20 | Where-Object { Test-Tia $_ })

if ($TiaVersion -eq 0) {
    if ($found.Count -eq 0) {
        Fail "TIA Portal V20/V21 설치를 찾지 못했습니다. 다른 위치에 설치했다면 -TiaVersion 20 또는 21 을 지정하세요."
    }
    # 둘 다 있으면 둘 다 빌드해서 두 서버로 등록한다.
    $TiaVersion = $found[0]
    $buildVersions = $found
    Ok ("TIA Portal 감지: " + (($found | ForEach-Object { "V$_" }) -join ", "))
    if ($found.Count -gt 1) { Warn "V20과 V21이 둘 다 있어 둘 다 빌드하고 $ServerName-v20, $ServerName-v21 두 서버로 등록합니다. 하나만 원하면 -TiaVersion 20 또는 21 로 다시 실행하세요." }
} elseif ($TiaVersion -ne 20 -and $TiaVersion -ne 21) {
    Fail "TiaVersion $TiaVersion 은 지원하지 않습니다. 20 또는 21을 쓰세요."
} elseif (Test-Tia $TiaVersion) {
    $buildVersions = @($TiaVersion)
    Ok "TIA Portal V$TiaVersion"
} else {
    $buildVersions = @($TiaVersion)
    Warn "TIA Portal V$TiaVersion 설치를 찾지 못했습니다. 빌드는 계속하지만 Openness DLL이 없으면 빌드가 실패합니다."
    $problems += "TIA Portal V$TiaVersion 없음"
}

$groupName = "Siemens TIA Openness"
if (((whoami /groups) -join "`n") -match $groupName) {
    Ok "'$groupName' 그룹"
} else {
    $addCmd = "net localgroup `"$groupName`" `"$env:USERDOMAIN\$env:USERNAME`" /add"
    if ($AddToOpennessGroup) {
        Write-Host "  ..  관리자 권한으로 그룹에 추가합니다. 관리자 확인 창이 뜨면 '예'를 누르세요."
        try {
            $p = Start-Process cmd.exe -ArgumentList "/c $addCmd" -Verb RunAs -Wait -PassThru
            if ($p.ExitCode -eq 0) { Ok "'$groupName' 그룹에 추가함" } else { Warn "그룹 추가 실패 (exit $($p.ExitCode))" }
        } catch { Warn "그룹 추가를 취소했거나 실패했습니다: $($_.Exception.Message)" }
        Warn "그룹 변경은 Windows 로그아웃 후 다시 로그인해야 적용됩니다."
    } else {
        Warn "현재 사용자가 '$groupName' 그룹에 없습니다 (또는 추가한 뒤 아직 다시 로그인하지 않았습니다)."
        Warn "관리자 PowerShell에서:  $addCmd"
        Warn "또는 이 스크립트를 -AddToOpennessGroup 으로 다시 실행. 그다음 Windows 로그아웃 후 다시 로그인."
    }
    $problems += "Openness 그룹 (추가 후 다시 로그인 필요)"
}

# 3. 소스 받기, 빌드 ------------------------------------------------------
Step "소스 받기 ($Repo, $Branch)"
if (Test-Path (Join-Path $InstallDir ".git")) {
    Run git @("-C", $InstallDir, "fetch", "origin", $Branch)
    Run git @("-C", $InstallDir, "checkout", $Branch)
    Run git @("-C", $InstallDir, "pull", "--ff-only", "origin", $Branch)
    Run git @("-C", $InstallDir, "submodule", "update", "--init", "--recursive")
} else {
    New-Item -ItemType Directory -Force -Path (Split-Path $InstallDir) | Out-Null
    Run git @("clone", "--recurse-submodules", "-b", $Branch, $Repo, $InstallDir)
}
Ok $InstallDir

$driver = Join-Path $InstallDir "third_party\S7CommPlusDriver\src\S7CommPlusDriver\S7CommPlusDriver.csproj"
$server = Join-Path $InstallDir "src\TiaMcpServer\TiaMcpServer.csproj"
Step "빌드 (처음에는 패키지 다운로드로 몇 분 걸릴 수 있음)"
Run dotnet @("build", $driver, "-c", "Debug", "-p:Platform=x64", "-p:TargetFrameworkVersion=v4.8", "-nologo", "-v", "q")

# 버전마다 exe가 따로 생긴다: V20은 bin\Release, V21은 bin\V21\Release.
$exes = @{}
foreach ($v in $buildVersions) {
    Step "빌드 (TIA V$v 용)"
    Run dotnet @("build", $server, "-c", "Release", "-p:TiaVersion=$v", "-nologo", "-v", "q")
    $binDir = if ($v -eq 20) { "src\TiaMcpServer\bin\Release" } else { "src\TiaMcpServer\bin\V$v\Release" }
    $exe = Get-ChildItem -Path (Join-Path $InstallDir $binDir) -Recurse -Filter "TiaMcpServer.exe" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $exe) { Fail "빌드는 끝났는데 $binDir 에서 TiaMcpServer.exe 를 찾지 못했습니다." }
    $exes[$v] = $exe.FullName
    Ok $exes[$v]

    Step "환경 점검 (V$v 용 TiaMcpServer.exe --doctor)"
    & $exes[$v] --tia-major-version $v --doctor
}
# 5. MCP 클라이언트 등록 --------------------------------------------------
# 한 버전만 빌드했으면 서버 이름은 그대로, 둘 다 빌드했으면 tiaportal-mcp-v20 / -v21 두 항목.
# 각 서버는 자기 버전의 TIA Portal에만 붙으므로, 열어 둔 TIA 버전의 서버를 쓰면 된다.
$servers = @()
foreach ($v in $buildVersions) {
    $vArgs = @("--tia-major-version", "$v")
    if ($AllowWrite) { $vArgs += "--allow-write" }
    $name = if ($buildVersions.Count -gt 1) { "$ServerName-v$v" } else { $ServerName }
    $servers += [pscustomobject]@{ Name = $name; Command = $exes[$v]; Args = $vArgs }
}
# 이전 실행이 다른 구성으로 등록한 항목은 지운다.
$oldNames = @($ServerName, "$ServerName-v20", "$ServerName-v21")
$mode = if ($AllowWrite) { "쓰기 툴 포함" } else { "읽기 전용" }

# mcpServers 형식 JSON 파일 하나에 이 서버 항목들을 넣는다 (기존 파일은 .bak 으로 백업).
function Register-JsonConfig([string]$cfg, [string]$label) {
    $json = $null
    if (Test-Path $cfg) {
        $raw = [IO.File]::ReadAllText($cfg)
        if ($raw.Trim()) {
            try { $json = $raw | ConvertFrom-Json }
            catch { Warn "$cfg 의 JSON을 읽지 못해 건너뜁니다. 파일 내용을 확인하세요."; return $false }
        }
        Copy-Item $cfg "$cfg.bak-$(Get-Date -Format yyyyMMdd_HHmmss)"
    }
    if (-not $json) { $json = [pscustomobject]@{} }
    if (-not $json.PSObject.Properties["mcpServers"]) {
        $json | Add-Member -NotePropertyName mcpServers -NotePropertyValue ([pscustomobject]@{})
    }
    foreach ($old in $oldNames) { $json.mcpServers.PSObject.Properties.Remove($old) }
    foreach ($s in $servers) {
        $entry = [pscustomobject]@{ command = $s.Command; args = $s.Args }
        $json.mcpServers | Add-Member -NotePropertyName $s.Name -NotePropertyValue $entry -Force
    }

    # BOM 없는 UTF-8로 저장 (BOM이 있으면 못 읽는 클라이언트가 있다)
    [IO.File]::WriteAllText($cfg, ($json | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
    Ok "$label 설정: $cfg (기존 파일은 .bak 으로 백업)"
    return $true
}

$registered = @()
if (-not $NoRegister) {
    Step "MCP 클라이언트 등록 ($mode): $(($servers | ForEach-Object { $_.Name }) -join ', ')"

    # Claude Desktop: 일반 설치와 Microsoft Store(MSIX) 설치 경로 둘 다 확인
    $configs = @("$env:APPDATA\Claude\claude_desktop_config.json")
    $configs += Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory -Filter "Claude_*" -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName "LocalCache\Roaming\Claude\claude_desktop_config.json" }
    foreach ($cfg in $configs) {
        if ((Test-Path (Split-Path $cfg)) -and (Register-JsonConfig $cfg "Claude Desktop")) { $registered += "Claude Desktop" }
    }

    # Antigravity: 사용자 폴더의 .gemini\antigravity\mcp_config.json
    $agDir = Join-Path $env:USERPROFILE ".gemini\antigravity"
    if ((Test-Path $agDir) -and (Register-JsonConfig (Join-Path $agDir "mcp_config.json") "Antigravity")) { $registered += "Antigravity" }

    # Claude Code: CLI가 있으면 사용자 범위로 등록
    if (Get-Command claude -ErrorAction SilentlyContinue) {
        foreach ($old in $oldNames) { & claude mcp remove $old --scope user 2>$null | Out-Null }
        foreach ($s in $servers) {
            $claudeArgs = @("mcp", "add", $s.Name, "--scope", "user", "--", $s.Command) + $s.Args
            & claude @claudeArgs
            if ($LASTEXITCODE -eq 0) { Ok "Claude Code (user scope): $($s.Name)"; $registered += "Claude Code" }
            else { Warn "Claude Code 등록 실패. 직접 실행: claude mcp add $($s.Name) --scope user -- `"$($s.Command)`" $($s.Args -join ' ')" }
        }
    }

    if ($registered.Count -eq 0) {
        Warn "Claude Desktop, Antigravity 설정 폴더도, claude 명령도 찾지 못했습니다. 아래 예시를 쓰는 MCP 클라이언트 설정에 넣으세요."
    }
}

# 다른 클라이언트용 설정 예시 (mcpServers 형식은 Claude Desktop, Antigravity, Cursor 등이 같다)
Step "MCP 설정 예시"
$example = [pscustomobject]@{ mcpServers = [pscustomobject]@{} }
foreach ($s in $servers) {
    $example.mcpServers | Add-Member -NotePropertyName $s.Name -NotePropertyValue ([pscustomobject]@{ command = $s.Command; args = $s.Args })
}
Write-Host ($example | ConvertTo-Json -Depth 5)

# 6. 마무리 안내 ----------------------------------------------------------
Step "다음 할 일"
Write-Host "  1. MCP 클라이언트를 완전히 종료했다가 다시 켜세요 (Claude Desktop은 트레이 아이콘까지)."
Write-Host "  2. TIA Portal 을 켜고 프로젝트를 연 다음 AI에게 'TIA Portal에 Connect 하고 GetProjectTree 해줘'라고 하세요."
if ($servers.Count -gt 1) { Write-Host "     V20 프로젝트는 $ServerName-v20, V21 프로젝트는 $ServerName-v21 서버의 툴을 쓰세요 (다른 버전 서버는 TIA를 찾지 못합니다)." }
Write-Host "  3. 처음 연결할 때 TIA Portal에 'Openness access' 창이 뜹니다. 'Yes to all'을 누르세요."
Write-Host "     (창이 안 보이면 작업 표시줄의 TIA Portal을 눌러 보세요.)"
if (-not $AllowWrite) {
    Write-Host "  - 읽기 전용입니다. 블록/태그를 바꾸는 툴은 숨겨져 있고, 필요하면 -AllowWrite 로 다시 실행하세요 (args에 --allow-write)."
}

if ($problems.Count -gt 0) {
    Write-Host ""
    Warn ("해결할 것: " + ($problems -join ", "))
}

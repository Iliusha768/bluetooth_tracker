$ErrorActionPreference = 'Stop'

$repository = 'Iliusha768/bluetooth_tracker'
$releaseBase = "https://github.com/$repository/releases/latest/download"
$archiveName = 'BatteryDock-win-x64.zip'
$hashName = "$archiveName.sha256"
$installDir = Join-Path $env:LOCALAPPDATA 'BatteryDock'
$exePath = Join-Path $installDir 'BatteryDock.exe'
$commandDir = Join-Path $env:LOCALAPPDATA 'BatteryDockCommand'
$commandPath = Join-Path $commandDir 'bluetoothdock.cmd'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runName = 'BatteryDock'

function Confirm-Change([string]$description) {
    Write-Host ''
    Write-Host $description
    $answer = Read-Host 'Продолжить? Введите yes или no'
    return $answer.Trim().ToLowerInvariant() -eq 'yes'
}

function Stop-InstalledApp {
    Get-CimInstance Win32_Process -Filter "Name = 'BatteryDock.exe'" |
        Where-Object { $_.ExecutablePath -and
            [string]::Equals($_.ExecutablePath, $exePath,
                [StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop }
}

function Download-File([string]$url, [string]$destination) {
    & curl.exe --fail --location --progress-bar --show-error --retry 2 --output $destination $url
    if ($LASTEXITCODE -ne 0) { throw "Не удалось скачать $url (код $LASTEXITCODE)." }
}

function Is-AutostartEnabled {
    $entry = Get-ItemProperty -Path $runKey -Name $runName -ErrorAction SilentlyContinue
    return $null -ne $entry -and $entry.$runName -eq ('"{0}"' -f $exePath)
}

function Set-Autostart([bool]$enabled) {
    if ($enabled) {
        New-Item -Path $runKey -Force | Out-Null
        New-ItemProperty -Path $runKey -Name $runName -PropertyType String `
            -Value ('"{0}"' -f $exePath) -Force | Out-Null
    } else {
        Remove-ItemProperty -Path $runKey -Name $runName -ErrorAction SilentlyContinue
    }
}

function Notify-PathChanged {
    if (-not ('BatteryDock.EnvironmentSignal' -as [type])) {
        Add-Type -Namespace BatteryDock -Name EnvironmentSignal -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint message, System.IntPtr wParam, string lParam, uint flags, uint timeout, out System.IntPtr result);
'@
    }
    $result = [IntPtr]::Zero
    [BatteryDock.EnvironmentSignal]::SendMessageTimeout(
        [IntPtr]0xffff, 0x1a, [IntPtr]::Zero, 'Environment', 2, 2000, [ref]$result) | Out-Null
}

function Add-CommandPath {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($userPath -split ';' | Where-Object { $_ })
    if (@($parts | Where-Object { $_.TrimEnd('\') -ieq $commandDir.TrimEnd('\') }).Count -eq 0) {
        [Environment]::SetEnvironmentVariable('Path', (($parts + $commandDir) -join ';'), 'User')
        Notify-PathChanged
    }
}

function Remove-CommandPath {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($userPath -split ';' | Where-Object {
        $_ -and $_.TrimEnd('\') -ine $commandDir.TrimEnd('\')
    })
    [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
    Notify-PathChanged
}

function Install-Command {
    New-Item -ItemType Directory -Path $commandDir -Force | Out-Null
    $launcher = @'
@echo off
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "%LOCALAPPDATA%\BatteryDock\manage.ps1"
exit /b %ERRORLEVEL%
'@
    Set-Content -LiteralPath $commandPath -Value $launcher -Encoding ASCII
    Add-CommandPath
}

function Install-App([bool]$enableAutostart) {
    $temporary = Join-Path $env:TEMP ("BatteryDock-" + [guid]::NewGuid().ToString('N'))
    $backup = "$installDir.backup.$([guid]::NewGuid().ToString('N'))"
    $swapped = $false
    New-Item -ItemType Directory -Path $temporary | Out-Null
    try {
        $archive = Join-Path $temporary $archiveName
        $hashFile = Join-Path $temporary $hashName
        Write-Host 'Скачиваю последнюю версию с GitHub Releases...'
        Download-File "$releaseBase/$archiveName" $archive
        Download-File "$releaseBase/$hashName" $hashFile

        $expected = (Get-Content -LiteralPath $hashFile -Raw -Encoding ASCII).Trim().ToLowerInvariant()
        if ($expected -notmatch '^[0-9a-f]{64}$') { throw 'Неверный формат контрольной суммы.' }
        $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { throw 'Контрольная сумма не совпала. Установка отменена.' }

        $staged = Join-Path $temporary 'app'
        Expand-Archive -LiteralPath $archive -DestinationPath $staged
        if (-not (Test-Path -LiteralPath (Join-Path $staged 'BatteryDock.exe') -PathType Leaf) -or
            -not (Test-Path -LiteralPath (Join-Path $staged 'manage.ps1') -PathType Leaf)) {
            throw 'В архиве не найдены BatteryDock.exe и manage.ps1.'
        }

        Stop-InstalledApp
        if (Test-Path -LiteralPath $installDir) {
            Move-Item -LiteralPath $installDir -Destination $backup
        }
        try {
            Move-Item -LiteralPath $staged -Destination $installDir
            $swapped = $true
            Install-Command
            Set-Autostart $enableAutostart
        }
        catch {
            if ($swapped -and (Test-Path -LiteralPath $installDir)) {
                Remove-Item -LiteralPath $installDir -Recurse -Force
            }
            if (Test-Path -LiteralPath $backup) {
                Move-Item -LiteralPath $backup -Destination $installDir
            }
            throw
        }

        if (Test-Path -LiteralPath $backup) {
            Remove-Item -LiteralPath $backup -Recurse -Force
        }
        Write-Host "Готово. Файлы установлены в $installDir."
        Write-Host 'Команда bluetoothdock доступна в новом окне PowerShell или CMD.'
        Write-Host 'Выберите пункт 1 в меню, чтобы запустить значки сейчас.'
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Recurse -Force
        }
    }
}

function Uninstall-App {
    Stop-InstalledApp
    Set-Autostart $false
    Remove-CommandPath
    # The launcher is still running. A short-lived helper removes it after this menu exits.
    $cleanup = Join-Path $env:TEMP ("BatteryDock-cleanup-" + [guid]::NewGuid().ToString('N') + '.ps1')
    $helper = @'
Start-Sleep -Seconds 2
$app = Join-Path $env:LOCALAPPDATA 'BatteryDock'
$command = Join-Path $env:LOCALAPPDATA 'BatteryDockCommand'
for ($attempt = 0; $attempt -lt 12; $attempt++) {
    try {
        if (Test-Path -LiteralPath $app) { Remove-Item -LiteralPath $app -Recurse -Force -ErrorAction Stop }
        if (Test-Path -LiteralPath $command) { Remove-Item -LiteralPath $command -Recurse -Force -ErrorAction Stop }
        break
    } catch { Start-Sleep -Milliseconds 500 }
}
Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
'@
    Set-Content -LiteralPath $cleanup -Value $helper -Encoding UTF8
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'RemoteSigned', '-File', ('"{0}"' -f $cleanup))
    Write-Host 'Автозапуск и команда отключены. Файлы удалятся через несколько секунд после закрытия меню.'
}

Write-Host 'Привет! BatteryDock показывает заряд подключённых Bluetooth-устройств на панели задач.'
while ($true) {
Write-Host "Установка: $(if (Test-Path -LiteralPath $exePath) { 'есть' } else { 'нет' })"
Write-Host "Автозапуск: $(if (Is-AutostartEnabled) { 'включён' } else { 'выключен' })"
Write-Host ''
Write-Host '1 — Запустить (или установить, если программы ещё нет)'
Write-Host '2 — Переустановить'
Write-Host '3 — Включить/выключить автозапуск'
Write-Host '4 — Полностью удалить'
Write-Host '0 — Выход'
$choice = Read-Host 'Выберите пункт (0-4)'
if ($null -eq $choice) { Write-Host 'Ввод закрыт.'; return }

try {
    switch ($choice.Trim()) {
        '1' {
            if (Test-Path -LiteralPath $exePath) {
                $running = @(Get-CimInstance Win32_Process -Filter "Name = 'BatteryDock.exe'" |
                    Where-Object { $_.ExecutablePath -and
                        [string]::Equals($_.ExecutablePath, $exePath,
                            [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
                if ($running) { Write-Host 'Программа уже запущена.' }
                else { Start-Process -FilePath $exePath; Write-Host 'Программа запущена.' }
                break
            }
            $autostartAnswer = Read-Host 'Включить автозапуск при входе в Windows? yes/no'
            if ($autostartAnswer.Trim().ToLowerInvariant() -notin @('yes', 'no')) {
                Write-Host 'Введите yes или no. Ничего не изменено.'
                break
            }
            if (Confirm-Change "Будет скачан выпуск из $repository и установлен в $installDir. Команда bluetoothdock добавится для вашего пользователя.") {
                Install-App ($autostartAnswer.Trim().ToLowerInvariant() -eq 'yes')
            } else { Write-Host 'Отменено.' }
        }
        '2' {
            if (-not (Test-Path -LiteralPath $exePath)) {
                Write-Host 'Программа ещё не установлена. Выберите пункт 1.'
                break
            }
            if (Confirm-Change "Программа будет закрыта и заменена последним выпуском из $repository. Текущая настройка автозапуска сохранится.") {
                Install-App (Is-AutostartEnabled)
            } else { Write-Host 'Отменено.' }
        }
        '3' {
            if (-not (Test-Path -LiteralPath $exePath)) {
                Write-Host 'Сначала установите программу.'
                break
            }
            $nextState = -not (Is-AutostartEnabled)
            $description = if ($nextState) { 'включён' } else { 'выключен' }
            if (Confirm-Change "Автозапуск будет $description для текущего пользователя.") {
                Set-Autostart $nextState
                Write-Host "Автозапуск $description."
            } else { Write-Host 'Отменено.' }
        }
        '4' {
            if (Confirm-Change "Будут удалены $installDir, команда bluetoothdock и запись автозапуска.") {
                Uninstall-App
                return
            } else { Write-Host 'Отменено.' }
        }
        '0' { Write-Host 'Выход.'; return }
        default { Write-Host 'Нет такого пункта. Ничего не изменено.' }
    }
}
catch {
    Write-Error "Ошибка: $($_.Exception.Message)"
    exit 1
}
}

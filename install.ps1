$ErrorActionPreference = 'Stop'

$repository = 'Iliusha768/bluetooth_tracker'
$releaseBase = "https://github.com/$repository/releases/latest/download"
$archiveName = 'BatteryDock-win-x64.zip'
$hashName = "$archiveName.sha256"
$installDir = Join-Path $env:LOCALAPPDATA 'BatteryDock'
$exePath = Join-Path $installDir 'BatteryDock.exe'
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
    & curl.exe --fail --location --silent --show-error --retry 2 --output $destination $url
    if ($LASTEXITCODE -ne 0) { throw "Не удалось скачать $url (код $LASTEXITCODE)." }
}

function Install-App {
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
        if (-not (Test-Path -LiteralPath (Join-Path $staged 'BatteryDock.exe') -PathType Leaf)) {
            throw 'В архиве не найден BatteryDock.exe.'
        }

        Stop-InstalledApp
        if (Test-Path -LiteralPath $installDir) {
            Move-Item -LiteralPath $installDir -Destination $backup
        }
        try {
            Move-Item -LiteralPath $staged -Destination $installDir
            $swapped = $true
            New-ItemProperty -Path $runKey -Name $runName -PropertyType String `
                -Value ('"{0}"' -f $exePath) -Force | Out-Null
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
        Start-Process -FilePath $exePath
        Write-Host "Готово. Программа запущена и будет запускаться при входе в Windows. Папка: $installDir"
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Recurse -Force
        }
    }
}

function Uninstall-App {
    Stop-InstalledApp
    Remove-ItemProperty -Path $runKey -Name $runName -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $installDir) {
        Remove-Item -LiteralPath $installDir -Recurse -Force
    }
    Write-Host 'Готово. Программа и её автозапуск удалены.'
}

Write-Host 'Привет! BatteryDock показывает заряд подключённых Bluetooth-устройств на панели задач.'
Write-Host ''
Write-Host '1 — Установить'
Write-Host '2 — Переустановить'
Write-Host '3 — Полностью удалить'
Write-Host '0 — Выход'
$choice = Read-Host 'Выберите пункт (0-3)'

try {
    switch ($choice.Trim()) {
        '1' {
            if (Test-Path -LiteralPath $exePath) {
                Write-Host 'Программа уже установлена. Выберите пункт 2 для переустановки.'
                break
            }
            if (Confirm-Change "Будет скачан выпуск из $repository, установлен в $installDir и добавлен автозапуск для вашего пользователя.") {
                Install-App
            } else { Write-Host 'Отменено.' }
        }
        '2' {
            if (-not (Test-Path -LiteralPath $exePath)) {
                Write-Host 'Программа ещё не установлена. Выберите пункт 1.'
                break
            }
            if (Confirm-Change "Программа будет закрыта и заменена последним выпуском из $repository. Папка: $installDir.") {
                Install-App
            } else { Write-Host 'Отменено.' }
        }
        '3' {
            if (Confirm-Change "Будут удалены $installDir и запись автозапуска BatteryDock для вашего пользователя.") {
                Uninstall-App
            } else { Write-Host 'Отменено.' }
        }
        '0' { Write-Host 'Выход.' }
        default { Write-Host 'Нет такого пункта. Ничего не изменено.' }
    }
}
catch {
    Write-Error "Ошибка: $($_.Exception.Message)"
    exit 1
}

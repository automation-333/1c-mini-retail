<#
.SYNOPSIS
  Собирает конфигурацию из исходников в чистую файловую базу, проверяет модули и прогоняет автотесты.

.DESCRIPTION
  1. Создаёт пустую файловую информационную базу в build\ib (старая удаляется).
  2. Загружает конфигурацию из src и обновляет структуру базы.
  3. Проверяет синтаксис модулей (сервер и тонкий клиент).
  4. Запускает автотесты в режиме 1С:Предприятие, протокол пишет в build\tests.txt и build\junit.xml.
  Код возврата: 0 если всё прошло, 1 если есть ошибки.

.EXAMPLE
  .\tools\build-and-test.ps1
  .\tools\build-and-test.ps1 -Platform "C:\Program Files\1cv8\8.3.27.1936\bin\1cv8.exe" -KeepBase
#>
param(
    [string]$Platform = '',
    [switch]$KeepBase,
    [string]$TelegramToken = '',
    [string]$TelegramChat = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$src = Join-Path $root 'src'
$build = Join-Path $root 'build'
$ib = Join-Path $build 'ib'

if (-not $Platform) {
    $Platform = Get-ChildItem 'C:\Program Files\1cv8\*\bin\1cv8.exe', 'C:\Program Files (x86)\1cv8\*\bin\1cv8.exe', 'C:\Program Files (x86)\1cv8t\*\bin\1cv8t.exe', 'C:\Program Files\1cv8t\*\bin\1cv8t.exe' -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $Platform -or -not (Test-Path $Platform)) { throw 'Не найдена платформа 1С. Укажите путь параметром -Platform.' }
Write-Host "Платформа: $Platform"

New-Item -ItemType Directory -Force $build | Out-Null

function Invoke-1C([string[]]$Arguments, [string]$Step) {
    $log = Join-Path $build "$Step.log"
    if (Test-Path $log) { Remove-Item $log -Force }
    $p = Start-Process -FilePath $Platform -ArgumentList ($Arguments + @('/DisableStartupDialogs', '/DisableStartupMessages', '/Out', "`"$log`"")) -PassThru -Wait -WindowStyle Hidden
    $text = if (Test-Path $log) { (Get-Content $log -Encoding Default | Where-Object { $_.Trim() }) -join "`n" } else { '' }
    [pscustomobject]@{ Code = $p.ExitCode; Log = $text }
}

$ok = $true

if (-not $KeepBase -or -not (Test-Path (Join-Path $ib '1Cv8.1CD'))) {
    Write-Host '== Создание чистой базы'
    if (Test-Path $ib) { Remove-Item $ib -Recurse -Force }
    $r = Invoke-1C @('CREATEINFOBASE', "File=`"$ib`"") 'create'
    if ($r.Code -ne 0) { Write-Host $r.Log; throw 'Не удалось создать базу' }
}

Write-Host '== Загрузка конфигурации из src'
$r = Invoke-1C @('DESIGNER', '/F', "`"$ib`"", '/LoadConfigFromFiles', "`"$src`"", '/UpdateDBCfg') 'load'
Write-Host $r.Log
if ($r.Code -ne 0) { throw 'Ошибка загрузки конфигурации' }

Write-Host '== Проверка модулей'
$r = Invoke-1C @('DESIGNER', '/F', "`"$ib`"", '/CheckModules', '-ThinClient', '-Server') 'check'
Write-Host $r.Log
if ($r.Code -ne 0) { $ok = $false }

if ($ok) {
    Write-Host '== Автотесты'
    $out = Join-Path $build 'tests.txt'
    $junit = Join-Path $build 'junit.xml'
    Remove-Item $out, $junit -ErrorAction SilentlyContinue
    $c = "autotest;out=$out;junit=$junit"
    if ($TelegramToken) { $c += ";token=$TelegramToken;chat=$TelegramChat" }
    $p = Start-Process -FilePath $Platform -ArgumentList @('ENTERPRISE', '/F', "`"$ib`"", '/DisableStartupDialogs', '/DisableStartupMessages', '/C', "`"$c`"") -PassThru
    if (-not $p.WaitForExit(600000)) { $p.Kill(); throw 'Автотесты не завершились за 10 минут' }
    if (Test-Path $out) {
        $res = Get-Content $out -Encoding UTF8
        $res | ForEach-Object { Write-Host $_ }
        if ($res[0] -notmatch 'PASSED') { $ok = $false }
    } else {
        Write-Host 'Протокол тестов не создан'
        $ok = $false
    }
}

if ($ok) { Write-Host '== УСПЕХ'; exit 0 } else { Write-Host '== ЕСТЬ ОШИБКИ'; exit 1 }

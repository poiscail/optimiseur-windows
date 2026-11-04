# Compile OptimiseurWindows.ps1 en OptimiseurWindows.exe (module PS2EXE requis :
#   Install-Module ps2exe -Scope CurrentUser)
Import-Module ps2exe -ErrorAction Stop
$src = Join-Path $PSScriptRoot 'OptimiseurWindows.ps1'
$out = Join-Path $PSScriptRoot 'OptimiseurWindows.exe'
Invoke-ps2exe -inputFile $src -outputFile $out -noConsole -requireAdmin -STA -x64 `
    -title 'Optimiseur Windows' -description 'Nettoyage et optimisation de Windows' -product 'Optimiseur Windows' `
    -company 'poiscail' -version '1.4.0.0' -copyright 'poiscail'

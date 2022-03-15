@echo off

odin run source/main.odin -opt:0 -subsystem:windows -out:odle.exe -verbose-errors -vet
REM odin build source/main.odin -subsystem:windows -out:odle.exe -verbose-errors
REM odin check source/main.odin -verbose-errors -vet

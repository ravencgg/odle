@echo off

odin run source/main.odin -debug -file -o:speed -subsystem:windows -out:odle.exe -vet
REM odin build source/main.odin -subsystem:windows -out:odle.exe -verbose-errors
REM odin check source/main.odin -verbose-errors -vet

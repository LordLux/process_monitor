@echo off
echo Building process_monitor FFI DLL manually...

REM Use cl.exe to compile directly
cl.exe /std:c++17 /MD /LD ^
    /DBUILDING_PROCESS_MONITOR_DLL ^
    /I"." ^
    process_monitor_api.cpp ^
    /link ^
    wbemuuid.lib ole32.lib oleaut32.lib ^
    /OUT:process_monitor.dll

if exist "process_monitor.dll" (
    echo FFI DLL built successfully!
    copy "process_monitor.dll" "..\..\example\build\windows\x64\runner\Debug\"
    echo DLL copied to example app directory
) else (
    echo Failed to build FFI DLL
)

echo.
pause
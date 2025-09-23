@echo off
echo Building process_monitor FFI DLL...

REM Create build directory
if not exist "ffi_build" mkdir ffi_build
cd ffi_build

REM Configure and build with CMake
cmake -G "Visual Studio 17 2022" -A x64 -S .. -B . -f FFICMakeLists.txt
cmake --build . --config Debug

REM Copy the DLL to the appropriate location
if exist "Debug\process_monitor.dll" (
    copy "Debug\process_monitor.dll" "..\..\..\example\build\windows\x64\runner\Debug\"
    echo FFI DLL built and copied successfully!
) else (
    echo Failed to build FFI DLL
)

pause
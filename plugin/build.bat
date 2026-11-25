@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul
cd /d "%~dp0"
cl /nologo /O2 /EHsc /MT /LD /std:c++17 /utf-8 /I prism\include REAccessSpeech.cpp /Fe:REAccessSpeech.dll ole32.lib oleaut32.lib user32.lib winmm.lib winhttp.lib

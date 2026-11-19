@echo off
cd /d "%~dp0"
server\bin\pw_server.exe --web-dir web --print-token %*

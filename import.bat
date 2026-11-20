@echo off
rem Import MyXPTracker's SavedVariables into data\myxptracker.db and refresh reports\level_report.md
rem Run after logging out of WoW (the game only writes the file on logout or /reload).
py -3 "%~dp0tools\import_sqlite.py" %*
pause

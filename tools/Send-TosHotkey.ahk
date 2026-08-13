#Requires AutoHotkey v2.0
#SingleInstance Force

keys := A_Args.Length >= 1 ? A_Args[1] : "^1"
label := A_Args.Length >= 2 ? A_Args[2] : "hotkey"
outFile := A_Args.Length >= 3 ? A_Args[3] : A_ScriptDir "\..\Analysis\ahk-tos-hotkey.csv"

result := "NotFound"
hwnd := ""
title := ""

for candidate in WinGetList("ahk_exe thinkorswim.exe") {
    candidateTitle := ""
    try candidateTitle := WinGetTitle("ahk_id " candidate)
    if (candidateTitle = "Main@thinkorswim [build 1992]") {
        hwnd := candidate
        title := candidateTitle
        try {
            WinRestore("ahk_id " hwnd)
            WinActivate("ahk_id " hwnd)
            WinWaitActive("ahk_id " hwnd, , 3)
            Send(keys)
            Sleep(700)
            result := "Sent"
        } catch as err {
            result := "Error: " err.Message
        }
        break
    }
}

outDir := RegExReplace(outFile, "\\[^\\]+$")
if (outDir != outFile)
    DirCreate(outDir)
if FileExist(outFile)
    FileDelete(outFile)
FileAppend('"Result","Label","Keys","Hwnd","Title"`r`n' Csv(result) "," Csv(label) "," Csv(keys) "," Csv(hwnd) "," Csv(title), outFile, "UTF-8")

Csv(value) {
    text := "" value
    text := StrReplace(text, '"', '""')
    return '"' text '"'
}

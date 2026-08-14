#Requires AutoHotkey v2.0
#SingleInstance Force
SetTitleMatchMode(3)

title := A_Args.Length >= 1 ? A_Args[1] : "Main@thinkorswim [build 1992]"
outFile := A_Args.Length >= 2 ? A_Args[2] : A_ScriptDir "\..\Analysis\ahk-focus-tos-main.csv"
result := "NotFound"
hwnd := ""
actualTitle := ""

try {
    hwnd := WinExist(title " ahk_exe thinkorswim.exe")
    if (hwnd) {
        WinRestore("ahk_id " hwnd)
        WinActivate("ahk_id " hwnd)
        WinWaitActive("ahk_id " hwnd, , 3)
        actualTitle := WinGetTitle("ahk_id " hwnd)
        result := "Activated"
    }
} catch as err {
    result := "Error: " err.Message
}

outDir := RegExReplace(outFile, "\\[^\\]+$")
if (outDir != outFile)
    DirCreate(outDir)
if FileExist(outFile)
    FileDelete(outFile)
FileAppend('"Result","Hwnd","Title"`r`n' Csv(result) "," Csv(hwnd) "," Csv(actualTitle), outFile, "UTF-8")

Csv(value) {
    text := "" value
    text := StrReplace(text, '"', '""')
    return '"' text '"'
}
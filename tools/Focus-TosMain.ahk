#Requires AutoHotkey v2.0
#SingleInstance Force

title := A_Args.Length >= 1 ? A_Args[1] : "Main@thinkorswim [build 1992]"
outFile := A_Args.Length >= 2 ? A_Args[2] : A_ScriptDir "\..\Analysis\ahk-focus-tos-main.csv"
result := "NotFound"
hwnd := ""

for candidate in WinGetList("ahk_exe thinkorswim.exe") {
    candidateTitle := ""
    try candidateTitle := WinGetTitle("ahk_id " candidate)
    if (InStr(candidateTitle, title) || InStr(candidateTitle, "Main@thinkorswim")) {
        hwnd := candidate
        try {
            WinRestore("ahk_id " hwnd)
            WinActivate("ahk_id " hwnd)
            WinWaitActive("ahk_id " hwnd, , 3)
            result := "Activated"
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
FileAppend('"Result","Hwnd","Title"`r`n' Csv(result) "," Csv(hwnd) "," Csv(hwnd ? WinGetTitle("ahk_id " hwnd) : ""), outFile, "UTF-8")

Csv(value) {
    text := "" value
    text := StrReplace(text, '"', '""')
    return '"' text '"'
}

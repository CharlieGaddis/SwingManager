#Requires AutoHotkey v2.0
#SingleInstance Force

hwnd := A_Args.Length >= 1 ? A_Args[1] : ""
x := A_Args.Length >= 2 ? Integer(A_Args[2]) : 500
y := A_Args.Length >= 3 ? Integer(A_Args[3]) : 80
outFile := A_Args.Length >= 4 ? A_Args[4] : A_ScriptDir "\..\Analysis\ahk-move-window-by-hwnd.csv"

result := "NotFound"
title := ""
w := ""
h := ""

try {
    title := WinGetTitle("ahk_id " hwnd)
    WinGetPos(,, &w, &h, "ahk_id " hwnd)
    WinMove(x, y,,, "ahk_id " hwnd)
    WinActivate("ahk_id " hwnd)
    result := "Moved"
} catch as err {
    result := "Error: " err.Message
}

outDir := RegExReplace(outFile, "\\[^\\]+$")
if (outDir != outFile)
    DirCreate(outDir)
if FileExist(outFile)
    FileDelete(outFile)
FileAppend('"Result","Hwnd","Title","X","Y","W","H"`r`n' Csv(result) "," Csv(hwnd) "," Csv(title) "," Csv(x) "," Csv(y) "," Csv(w) "," Csv(h), outFile, "UTF-8")

Csv(value) {
    text := "" value
    text := StrReplace(text, '"', '""')
    return '"' text '"'
}

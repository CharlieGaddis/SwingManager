#Requires AutoHotkey v2.0
#SingleInstance Force
CoordMode("Mouse", "Screen")

relX := A_Args.Length >= 1 ? Integer(A_Args[1]) : 0
relY := A_Args.Length >= 2 ? Integer(A_Args[2]) : 0
label := A_Args.Length >= 3 ? A_Args[3] : "click"
outFile := A_Args.Length >= 4 ? A_Args[4] : A_ScriptDir "\..\Analysis\ahk-tos-relative-click.csv"
clickCount := A_Args.Length >= 5 ? Integer(A_Args[5]) : 1
button := A_Args.Length >= 6 ? A_Args[6] : "Left"

hwnd := ""
title := ""
result := "NotFound"
absX := ""
absY := ""

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
            WinGetPos(&x, &y, &w, &h, "ahk_id " hwnd)
            absX := x + relX
            absY := y + relY
            MouseMove(0, 0, 0)
            Sleep(120)
            if (button = "Right")
                MouseClick("Right", absX, absY, clickCount)
            else
                MouseClick("Left", absX, absY, clickCount)
            Sleep(500)
            result := "Clicked"
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
FileAppend('"Result","Label","Hwnd","Title","RelX","RelY","AbsX","AbsY","ClickCount","Button"`r`n' Csv(result) "," Csv(label) "," Csv(hwnd) "," Csv(title) "," Csv(relX) "," Csv(relY) "," Csv(absX) "," Csv(absY) "," Csv(clickCount) "," Csv(button), outFile, "UTF-8")

Csv(value) {
    text := "" value
    text := StrReplace(text, '"', '""')
    return '"' text '"'
}

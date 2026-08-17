#Requires AutoHotkey v2.0
#SingleInstance Force
SetTitleMatchMode(3)
CoordMode("Mouse", "Screen")
outFile := A_Args.Length >= 1 ? A_Args[1] : A_ScriptDir "\..\Analysis\ahk-main-window-pos.csv"
hwnd := WinExist("Main@thinkorswim [build 1992] ahk_exe thinkorswim.exe")
result := "NotFound"
title := ""
x := ""
y := ""
w := ""
h := ""
if (hwnd) {
    title := WinGetTitle("ahk_id " hwnd)
    WinGetPos(&x, &y, &w, &h, "ahk_id " hwnd)
    result := "Found"
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
#Requires AutoHotkey v2.0
#SingleInstance Force

title := A_Args.Length >= 1 ? A_Args[1] : "Order Rules"
x := A_Args.Length >= 2 ? Integer(A_Args[2]) : 500
y := A_Args.Length >= 3 ? Integer(A_Args[3]) : 80
outFile := A_Args.Length >= 4 ? A_Args[4] : A_ScriptDir "\..\Analysis\ahk-move-window.csv"

result := "NotFound"
hwnd := ""
actualTitle := ""
w := ""
h := ""

for candidate in WinGetList() {
    candidateTitle := ""
    try candidateTitle := WinGetTitle("ahk_id " candidate)
    if (InStr(candidateTitle, title)) {
        hwnd := candidate
        actualTitle := candidateTitle
        try {
            WinGetPos(,, &w, &h, "ahk_id " hwnd)
            WinMove(x, y,,, "ahk_id " hwnd)
            WinActivate("ahk_id " hwnd)
            result := "Moved"
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
FileAppend('"Result","Hwnd","Title","X","Y","W","H"`r`n' Csv(result) "," Csv(hwnd) "," Csv(actualTitle) "," Csv(x) "," Csv(y) "," Csv(w) "," Csv(h), outFile, "UTF-8")

Csv(value) {
    text := "" value
    text := StrReplace(text, '"', '""')
    return '"' text '"'
}

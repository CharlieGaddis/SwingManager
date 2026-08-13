#Requires AutoHotkey v2.0
#SingleInstance Force
CoordMode("Mouse", "Screen")

x := A_Args.Length >= 1 ? Integer(A_Args[1]) : 0
y := A_Args.Length >= 2 ? Integer(A_Args[2]) : 0
direction := A_Args.Length >= 3 ? A_Args[3] : "Down"
count := A_Args.Length >= 4 ? Integer(A_Args[4]) : 1
label := A_Args.Length >= 5 ? A_Args[5] : "wheel"
outFile := A_Args.Length >= 6 ? A_Args[6] : A_ScriptDir "\..\Analysis\ahk-wheel.csv"

MouseMove(0, 0, 0)
Sleep(120)
MouseMove(x, y, 0)
Sleep(120)
if (direction = "Up")
    Send("{WheelUp " count "}")
else
    Send("{WheelDown " count "}")
Sleep(500)

outDir := RegExReplace(outFile, "\\[^\\]+$")
if (outDir != outFile)
    DirCreate(outDir)
if FileExist(outFile)
    FileDelete(outFile)
FileAppend('"Result","Label","X","Y","Direction","Count"`r`n"Sent",' Csv(label) "," Csv(x) "," Csv(y) "," Csv(direction) "," Csv(count), outFile, "UTF-8")

Csv(value) {
    text := "" value
    text := StrReplace(text, '"', '""')
    return '"' text '"'
}

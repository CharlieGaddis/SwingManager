#Requires AutoHotkey v2.0
#SingleInstance Force
CoordMode("Mouse", "Screen")

x := A_Args.Length >= 1 ? Integer(A_Args[1]) : 0
y := A_Args.Length >= 2 ? Integer(A_Args[2]) : 0
label := A_Args.Length >= 3 ? A_Args[3] : "absolute-click"
outFile := A_Args.Length >= 4 ? A_Args[4] : A_ScriptDir "\..\Analysis\ahk-absolute-click.csv"
clickCount := A_Args.Length >= 5 ? Integer(A_Args[5]) : 1
button := A_Args.Length >= 6 ? A_Args[6] : "Left"

MouseMove(0, 0, 0)
Sleep(120)
if (button = "Right")
    MouseClick("Right", x, y, clickCount)
else
    MouseClick("Left", x, y, clickCount)
Sleep(300)

outDir := RegExReplace(outFile, "\\[^\\]+$")
if (outDir != outFile)
    DirCreate(outDir)
if FileExist(outFile)
    FileDelete(outFile)
FileAppend('"Result","Label","X","Y","ClickCount","Button"`r`n"Clicked",' Csv(label) "," Csv(x) "," Csv(y) "," Csv(clickCount) "," Csv(button), outFile, "UTF-8")

Csv(value) {
    text := "" value
    text := StrReplace(text, '"', '""')
    return '"' text '"'
}

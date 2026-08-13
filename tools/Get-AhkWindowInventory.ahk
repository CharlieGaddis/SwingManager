#Requires AutoHotkey v2.0
#SingleInstance Force

outFile := A_Args.Length >= 1 ? A_Args[1] : A_ScriptDir "\..\Analysis\ahk-window-inventory.csv"
rows := ['"Hwnd","Title","ProcessName","Class","MinMax","X","Y","W","H"']

for hwnd in WinGetList() {
    title := ""
    proc := ""
    className := ""
    minMax := ""
    x := ""
    y := ""
    w := ""
    h := ""
    try title := WinGetTitle("ahk_id " hwnd)
    try proc := WinGetProcessName("ahk_id " hwnd)
    try className := WinGetClass("ahk_id " hwnd)
    try minMax := WinGetMinMax("ahk_id " hwnd)
    try WinGetPos(&x, &y, &w, &h, "ahk_id " hwnd)
    if (title != "" || proc ~= "i)(think|tos|java|schwab)" || className ~= "i)(SunAwt|Java|think|tos)") {
        rows.Push(Csv(hwnd) "," Csv(title) "," Csv(proc) "," Csv(className) "," Csv(minMax) "," Csv(x) "," Csv(y) "," Csv(w) "," Csv(h))
    }
}

outDir := RegExReplace(outFile, "\\[^\\]+$")
if (outDir != outFile)
    DirCreate(outDir)
try {
    if FileExist(outFile)
        FileDelete(outFile)
}
FileAppend(StrJoin(rows, "`r`n"), outFile, "UTF-8")

Csv(value) {
    text := "" value
    text := StrReplace(text, '"', '""')
    return '"' text '"'
}

StrJoin(values, sep) {
    result := ""
    for idx, value in values {
        if (idx > 1)
            result .= sep
        result .= value
    }
    return result
}

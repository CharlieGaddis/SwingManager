#Requires AutoHotkey v2.0
#SingleInstance Force

keys := A_Args.Length >= 1 ? A_Args[1] : "{Esc}"
label := A_Args.Length >= 2 ? A_Args[2] : "keys"
outFile := A_Args.Length >= 3 ? A_Args[3] : A_ScriptDir "\..\Analysis\ahk-global-keys.csv"

Send(keys)
Sleep(400)

outDir := RegExReplace(outFile, "\\[^\\]+$")
if (outDir != outFile)
    DirCreate(outDir)
if FileExist(outFile)
    FileDelete(outFile)
FileAppend('"Result","Label","Keys"`r`n"Sent",' Csv(label) "," Csv(keys), outFile, "UTF-8")

Csv(value) {
    text := "" value
    text := StrReplace(text, '"', '""')
    return '"' text '"'
}

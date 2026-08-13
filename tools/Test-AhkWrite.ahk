#Requires AutoHotkey v2.0
outFile := A_Args.Length >= 1 ? A_Args[1] : A_ScriptDir "\..\Analysis\ahk-write-test.txt"
DirCreate(RegExReplace(outFile, "\\[^\\]+$"))
FileAppend("hello from ahk", outFile, "UTF-8")

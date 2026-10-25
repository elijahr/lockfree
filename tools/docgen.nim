# tools/docgen.nim
## Automated Nim API documentation generator for Starlight.
## Extracts exported symbols, types, procs, templates, macros, and docstrings
## via Nim's built-in `nim jsondoc` compiler backend and outputs clean
## Markdown documentation for Starlight.

import std/[os, osproc, json, strutils, sequtils]

type DocEntry = object
  name: string
  entryType: string
  line: int
  col: int
  code: string
  description: string

proc parseEntries(jsonNode: JsonNode): seq[DocEntry] =
  result = @[]
  if not jsonNode.hasKey("entries"):
    return
  for item in jsonNode["entries"]:
    var entry: DocEntry
    entry.name = item{"name"}.getStr()
    entry.entryType = item{"type"}.getStr()
    entry.line = item{"line"}.getInt()
    entry.col = item{"col"}.getInt()
    entry.code = item{"code"}.getStr()
    entry.description = item{"description"}.getStr()
    result.add(entry)

proc renderCategory(title: string, entries: seq[DocEntry]): string =
  if entries.len == 0:
    return ""
  result.add("\n## " & title & "\n\n")
  for e in entries:
    result.add("### `" & e.name & "`\n\n")
    if e.code.len > 0:
      result.add("```nim\n" & e.code.strip() & "\n```\n\n")
    if e.description.len > 0:
      result.add(e.description.strip() & "\n\n")

proc generateModuleDoc(moduleName, jsonPath, outPath: string) =
  let data = parseFile(jsonPath)
  var content =
    "---\ntitle: \"" & moduleName & "\"\ndescription: \"API reference for " & moduleName &
    "\"\n---\n\n"

  let moduleDesc = data{"moduleDescription"}.getStr().strip()
  if moduleDesc.len > 0:
    content.add(moduleDesc & "\n\n")

  let entries = parseEntries(data)

  let types = entries.filterIt(it.entryType == "skType")
  let constants = entries.filterIt(it.entryType == "skConst")
  let procs = entries.filterIt(it.entryType in ["skProc", "skFunc"])
  let templates = entries.filterIt(it.entryType == "skTemplate")
  let macros = entries.filterIt(it.entryType == "skMacro")
  let iterators = entries.filterIt(it.entryType == "skIterator")

  content.add(renderCategory("Types", types))
  content.add(renderCategory("Constants", constants))
  content.add(renderCategory("Procedures & Functions", procs))
  content.add(renderCategory("Templates", templates))
  content.add(renderCategory("Macros", macros))
  content.add(renderCategory("Iterators", iterators))

  writeFile(outPath, content)
  echo "Generated API reference: ", outPath

proc generateIndex(modules: seq[string], outDir: string) =
  var content =
    "---\ntitle: \"API Reference\"\ndescription: \"Module index and public API documentation\"\n---\n\n"
  content.add("Public modules in this package:\n\n")
  for m in modules:
    content.add("- [" & m & "](./" & m & "/)\n")
  writeFile(outDir / "index.md", content)
  echo "Generated API index: ", outDir / "index.md"

proc main() =
  let srcDir = "src"
  let apiDocsDir = "docs/src/content/docs/api"
  let tmpJsonDir = getTempDir() / ("nim_docgen_" & $getCurrentProcessId())

  createDir(apiDocsDir)
  createDir(tmpJsonDir)
  defer:
    removeDir(tmpJsonDir)

  var modules: seq[string] = @[]

  for file in walkDirRec(srcDir):
    if file.endsWith(".nim") and not file.contains("private") and
        not file.contains("internal"):
      let rel = relativePath(file, srcDir)
      let moduleName = rel.changeFileExt("").replace($DirSep, "/")
      let jsonFile = tmpJsonDir / (splitPath(file).tail.changeFileExt("json"))

      echo "Extracting docstrings: ", file
      let cmd =
        "nim jsondoc --hints:off --warnings:off --outdir:" & quoteShell(tmpJsonDir) & " " &
        quoteShell(file)
      let (outp, code) = execCmdEx(cmd)
      if code != 0:
        echo "Warning: failed to extract docs for ", file, ": ", outp
        continue

      if fileExists(jsonFile):
        let targetDoc = apiDocsDir / rel.changeFileExt("md")
        createDir(parentDir(targetDoc))
        generateModuleDoc(moduleName, jsonFile, targetDoc)
        modules.add(moduleName)

  if modules.len > 0:
    generateIndex(modules, apiDocsDir)

if isMainModule:
  main()

## The global settings file: `$NEOPI_CONFIG_DIR/settings.json` (default
## `~/.neopi/settings.json`), beside the credential store. It currently holds
## one preference — whether the model's reasoning is hidden — and follows the
## credential store's discipline: the directory is resolved once, writes are
## atomic, and a malformed file is reported instead of being replaced.

import std/[json, os]
from neopi/authstore import configDir

type
  SettingsError* = object of CatchableError
    ## A settings failure the caller reports to the user: the file cannot be
    ## read or written, or its contents are not a settings object.

const
  settingsFileName = "settings.json"
    ## The settings file's name inside the global config directory.
  dirPermissions = {fpUserRead, fpUserWrite, fpUserExec}
    ## The config directory's permissions: owner-only.
  filePermissions = {fpUserRead, fpUserWrite}
    ## The settings file's permissions: owner-only.

proc settingsFilePath(): string =
  ## The settings file inside the credential store's config directory. The
  ## directory resolution comes from `authstore`, so both global files always
  ## live in the same place.
  configDir() / settingsFileName

proc readSettings(path: string): JsonNode =
  ## The settings object, or nil when the file is absent. A file that cannot
  ## be read or parsed raises `SettingsError`: unlike a missing preference,
  ## malformed contents are a problem the caller must report, not a default.
  if not fileExists(path):
    return nil
  var content: string
  try:
    content = readFile(path)
  except CatchableError as e:
    raise newException(SettingsError,
      "cannot read the settings file: " & path & ": " & e.msg)
  var node: JsonNode
  try:
    node = parseJson(content)
  except JsonParsingError as e:
    raise newException(SettingsError,
      "the settings file is not valid JSON: " & path & ": " & e.msg)
  if node.kind != JObject:
    raise newException(SettingsError,
      "the settings file is not a JSON object: " & path)
  node

proc writeSettings(path: string, node: JsonNode) =
  ## Write the settings file whole and owner-only. The new content lands in a
  ## temporary file beside the target and is renamed over it, so a reader never
  ## sees a half-written file and a failed write leaves the previous one
  ## intact. The temporary file is removed if the write cannot finish.
  let dir = configDir()
  let tmp = path & ".tmp"
  try:
    if not dirExists(dir):
      createDir(dir)
      setFilePermissions(dir, dirPermissions)
    if fileExists(tmp):
      removeFile(tmp)
    writeFile(tmp, "")
    setFilePermissions(tmp, filePermissions)
    writeFile(tmp, node.pretty & "\n")
    moveFile(tmp, path)
    setFilePermissions(path, filePermissions)
  except CatchableError as e:
    if fileExists(tmp):
      try:
        removeFile(tmp)
      except CatchableError:
        discard
    raise newException(SettingsError,
      "cannot write the settings file: " & path & ": " & e.msg)

proc loadHideThinking*(): bool =
  ## Whether the model's reasoning is hidden. `false` when the settings file
  ## or the `hideThinking` key is absent, because reasoning is visible by
  ## default. A malformed file, a non-object file, or a non-boolean preference
  ## raises `SettingsError`; the file is never rewritten by a read.
  let path = settingsFilePath()
  let node = readSettings(path)
  if node.isNil:
    return false
  let value = node{"hideThinking"}
  if value.isNil:
    return false
  if value.kind != JBool:
    raise newException(SettingsError,
      "hideThinking must be a boolean in: " & path)
  value.getBool()

proc saveHideThinking*(value: bool) =
  ## Persist whether the model's reasoning is hidden in the global settings
  ## file, preserving every other key the file carries. The write is atomic.
  ## A malformed existing file raises `SettingsError` and stays byte-identical:
  ## settings this module cannot read are not ours to discard.
  let path = settingsFilePath()
  var node = readSettings(path)
  if node.isNil:
    node = newJObject()
  node["hideThinking"] = %value
  writeSettings(path, node)

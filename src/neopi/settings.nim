## The global settings file: `$NEOPI_CONFIG_DIR/settings.json` (default
## `~/.neopi/settings.json`), beside the credential store. It holds two
## preferences — whether the model's reasoning is hidden, and the default model
## a fresh session starts on — and follows the credential store's discipline:
## the directory is resolved once, writes are atomic, and a malformed file is
## reported instead of being replaced.

import std/[json, options, os, strutils]
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

proc preference(node: JsonNode, path: string): Option[bool] =
  ## The `hideThinking` preference out of a settings object: none when the key
  ## is absent, the value when it is a boolean, and a `SettingsError` when it is
  ## anything else. ONE place decides the type, so a read and a write can never
  ## disagree about what counts as malformed — which is how a wrong-typed
  ## preference used to pass the read and then be overwritten by the write that
  ## followed it.
  if node.isNil:
    return none(bool)
  let value = node{"hideThinking"}
  if value.isNil:
    return none(bool)
  if value.kind != JBool:
    raise newException(SettingsError,
      "hideThinking must be a boolean in: " & path)
  some(value.getBool())

proc modelPreference(node: JsonNode, path: string): Option[string] =
  ## The `defaultModel` preference: none when the key is absent, the value when
  ## it is a `"<provider>/<modelId>"` string, and a `SettingsError` when it is
  ## anything else — a wrong type, or a string with no separator, which is a
  ## value this module cannot turn back into a provider and a model. ONE place
  ## decides, exactly the way the thinking preference does.
  if node.isNil:
    return none(string)
  let value = node{"defaultModel"}
  if value.isNil:
    return none(string)
  if value.kind != JString:
    raise newException(SettingsError,
      "defaultModel must be a string in: " & path)
  let text = value.getStr("")
  if text.find('/') < 0:
    raise newException(SettingsError,
      "defaultModel must be \"<provider>/<modelId>\" in: " & path)
  some(text)

proc validate(node: JsonNode, path: string) =
  ## Read EVERY preference once before a write, for the reason #32's
  ## verification earned the hard way: a file this module cannot read is
  ## reported and never rewritten, and that rule has to hold for each key — not
  ## only for the one the caller happens to be changing.
  discard preference(node, path)
  discard modelPreference(node, path)

proc splitDefaultModel*(value: string): tuple[provider, model: string] =
  ## The stored default as the pair a turn needs, split at the FIRST slash: a
  ## model id may carry slashes of its own (`openrouter/openai/gpt-5` is the
  ## provider `openrouter` and the model `openai/gpt-5`). A value without one is
  ## not a default and comes back as two empty strings — the LOAD refuses those
  ## already, so this only has to be total.
  let at = value.find('/')
  if at < 0:
    return ("", "")
  (value[0 ..< at], value[at + 1 .. ^1])

proc loadDefaultModel*(): string =
  ## The stored default model as `"<provider>/<modelId>"`, or "" when the
  ## settings file or the key is absent. A malformed file, a wrong-typed value
  ## or a value that is not `provider/model` raises `SettingsError`; a read
  ## never rewrites the file.
  let path = settingsFilePath()
  let stored = modelPreference(readSettings(path), path)
  if stored.isSome: stored.get else: ""

proc saveDefaultModel*(value: string) =
  ## Persist the default model, preserving every other key the file carries.
  ## The write is atomic, and a malformed EXISTING file raises `SettingsError`
  ## and stays byte-identical. A `value` this module could not read back is
  ## refused instead of written: half a default is worse than none.
  if value.find('/') < 0:
    raise newException(SettingsError,
      "a default model must be \"<provider>/<modelId>\": " & value)
  let path = settingsFilePath()
  var node = readSettings(path)
  validate(node, path)
  if node.isNil:
    node = newJObject()
  node["defaultModel"] = %value
  writeSettings(path, node)

proc loadHideThinking*(): bool =
  ## Whether the model's reasoning is hidden. `false` when the settings file or
  ## the `hideThinking` key is absent, because reasoning is visible by default.
  ## A malformed file, a non-object file, or a non-boolean preference raises
  ## `SettingsError`; the file is never rewritten by a read.
  let path = settingsFilePath()
  let stored = preference(readSettings(path), path)
  if stored.isSome: stored.get else: false

proc saveHideThinking*(value: bool) =
  ## Persist whether the model's reasoning is hidden in the global settings
  ## file, preserving every other key the file carries. The write is atomic, and
  ## a malformed EXISTING file raises `SettingsError` and stays byte-identical —
  ## malformed includes a preference of the wrong type, because settings this
  ## module cannot read are not ours to discard.
  let path = settingsFilePath()
  var node = readSettings(path)
  validate(node, path)
  if node.isNil:
    node = newJObject()
  node["hideThinking"] = %value
  writeSettings(path, node)

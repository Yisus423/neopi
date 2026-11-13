## Tests for the global settings file: `$NEOPI_CONFIG_DIR/settings.json` — the
## reasoning visibility preference, its default, and the discipline that keeps
## a malformed settings file reported instead of clobbered.
import std/[json, os]
import std/strutils
import neopi/authstore
import neopi/settings
import unittest2

proc freshConfig(name: string): string =
  ## A config directory that starts EMPTY: removed first, because a run that
  ## died mid-test would otherwise leave its settings behind for the next one.
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  putEnv("NEOPI_CONFIG_DIR", result)

proc settingsPath(): string =
  configDir() / "settings.json"

suite "the global settings":
  test "an absent file and an absent key both read as false":
    let dir = freshConfig("neopi-tp-settings-absent")
    try:
      check not loadHideThinking()
      check not fileExists(settingsPath())
      createDir(configDir())
      writeFile(settingsPath(), "{}")
      check not loadHideThinking()
    finally:
      if dirExists(dir):
        removeDir(dir)

  test "the thinking preference round-trips through the global file":
    let dir = freshConfig("neopi-tp-settings-roundtrip")
    try:
      saveHideThinking(true)
      check loadHideThinking()
      check parseFile(settingsPath())["hideThinking"].getBool
      saveHideThinking(false)
      check not loadHideThinking()
      check not parseFile(settingsPath())["hideThinking"].getBool
    finally:
      if dirExists(dir):
        removeDir(dir)

  test "the default model round-trips as pi's one string":
    # pi keeps it as ONE settings string, `"${provider}/${modelId}"`
    # (`settings-schema.ts:216`): one key cannot go half-written, and a model id
    # may carry slashes of its own, which is why the split is at the FIRST one.
    let dir = freshConfig("neopi-tp-settings-default")
    try:
      check loadDefaultModel() == ""
      check not fileExists(settingsPath())
      saveDefaultModel("openrouter/openai/gpt-5")
      check loadDefaultModel() == "openrouter/openai/gpt-5"
      check parseFile(settingsPath())["defaultModel"].getStr ==
        "openrouter/openai/gpt-5"
      check splitDefaultModel(loadDefaultModel()) ==
        (provider: "openrouter", model: "openai/gpt-5")
      # One file, two preferences: saving one never loses the other.
      saveHideThinking(true)
      check loadDefaultModel() == "openrouter/openai/gpt-5"
      check loadHideThinking()
      saveDefaultModel("groq/llama-3.3-70b")
      check loadDefaultModel() == "groq/llama-3.3-70b"
      check loadHideThinking()
    finally:
      if dirExists(dir):
        removeDir(dir)

  test "a default model this module cannot use is reported, not clobbered":
    let dir = freshConfig("neopi-tp-settings-default-bad")
    try:
      createDir(configDir())
      # A wrong TYPE and a string that is not `provider/model` are both values
      # this module cannot interpret, and settings it cannot read are not its
      # to discard.
      writeFile(settingsPath(), "{\"defaultModel\": 7}")
      var before = readFile(settingsPath())
      expect SettingsError:
        discard loadDefaultModel()
      expect SettingsError:
        saveDefaultModel("openrouter/openai/gpt-5")
      expect SettingsError:
        saveHideThinking(true)
      check readFile(settingsPath()) == before

      writeFile(settingsPath(), "{\"defaultModel\": \"gpt-5\"}")
      before = readFile(settingsPath())
      expect SettingsError:
        discard loadDefaultModel()
      expect SettingsError:
        saveDefaultModel("openrouter/openai/gpt-5")
      check readFile(settingsPath()) == before

      # And the write refuses to CREATE one it could not read back.
      writeFile(settingsPath(), "{}")
      expect SettingsError:
        saveDefaultModel("gpt-5")
      check readFile(settingsPath()) == "{}"
    finally:
      if dirExists(dir):
        removeDir(dir)

  test "a malformed file is reported and left byte-identical":
    let dir = freshConfig("neopi-tp-settings-malformed")
    try:
      createDir(configDir())
      writeFile(settingsPath(), "{oops")
      let before = readFile(settingsPath())
      expect SettingsError:
        discard loadHideThinking()
      expect SettingsError:
        saveHideThinking(true)
      check readFile(settingsPath()) == before
    finally:
      if dirExists(dir):
        removeDir(dir)

  test "saving leaves no temporary file behind":
    let dir = freshConfig("neopi-tp-settings-atomic")
    try:
      saveHideThinking(true)
      check fileExists(settingsPath())
      check not fileExists(settingsPath() & ".tmp")
    finally:
      if dirExists(dir):
        removeDir(dir)

  test "a wrong-typed preference is malformed and stays byte-identical":
    # Reported by the independent verification: the WRITE path validated only
    # that the file parses, so Ctrl+T silently rewrote a preference of the wrong
    # type — the module's own contract says a malformed file is never discarded.
    let dir = freshConfig("neopi-tp-settings-wrong-type")
    try:
      createDir(configDir())
      writeFile(settingsPath(), "{\"hideThinking\":\"yes\"}")
      let before = readFile(settingsPath())
      expect SettingsError:
        discard loadHideThinking()
      expect SettingsError:
        saveHideThinking(true)
      check readFile(settingsPath()) == before
    finally:
      if dirExists(dir):
        removeDir(dir)

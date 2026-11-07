## Tests for the global settings file: `$NEOPI_CONFIG_DIR/settings.json` — the
## reasoning visibility preference, its default, and the discipline that keeps
## a malformed settings file reported instead of clobbered.
import std/[json, os]
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

## Tests for the model a run STARTS on: the CLI's choice, the provider's own
## variable, the STORED default (the pair Ctrl+S writes) and the built-in one,
## in that order. The rule lives in `resolveStartModel` so it needs no argv.
import std/os
import neopi
import neopi/authstore
import neopi/settings
import unittest2

proc freshConfig(name: string): string =
  ## A config directory that starts EMPTY: a settings file left behind by a run
  ## that died mid-test would otherwise decide the next one's default.
  result = getTempDir() / name
  if dirExists(result):
    removeDir(result)
  putEnv("NEOPI_CONFIG_DIR", result)

suite "the model a run starts on":
  test "an explicit model wins over everything stored":
    let dir = freshConfig("neopi-tp-start-cli")
    try:
      saveDefaultModel("groq/stored-model")
      check resolveStartModel("openrouter", "cli-model", sawProvider = true) ==
        (provider: "openrouter", model: "cli-model")
    finally:
      if dirExists(dir):
        removeDir(dir)

  test "the provider's variable comes before the stored default":
    let dir = freshConfig("neopi-tp-start-env")
    try:
      saveDefaultModel("groq/stored-model")
      putEnv("OPENROUTER_MODEL", "env-model")
      check resolveStartModel("openrouter", "", sawProvider = true) ==
        (provider: "openrouter", model: "env-model")
    finally:
      delEnv("OPENROUTER_MODEL")
      if dirExists(dir):
        removeDir(dir)

  test "the stored default brings ITS provider when none was named":
    let dir = freshConfig("neopi-tp-start-stored")
    try:
      saveDefaultModel("groq/stored-model")
      check resolveStartModel("openrouter", "", sawProvider = false) ==
        (provider: "groq", model: "stored-model")
    finally:
      if dirExists(dir):
        removeDir(dir)

  test "a named provider does not borrow another provider's default":
    # The pair travels together: a model id means nothing outside the provider
    # it was picked in, so `--provider openrouter` with a groq default keeps
    # openrouter and falls through to the built-in model.
    let dir = freshConfig("neopi-tp-start-named")
    try:
      saveDefaultModel("groq/stored-model")
      check resolveStartModel("openrouter", "", sawProvider = true) ==
        (provider: "openrouter", model: DefaultModel)
    finally:
      if dirExists(dir):
        removeDir(dir)

  test "a stored default naming an unknown provider is skipped, not fatal":
    let dir = freshConfig("neopi-tp-start-unknown")
    try:
      saveDefaultModel("a-provider-the-table-lost/some-model")
      check resolveStartModel("openrouter", "", sawProvider = false) ==
        (provider: "openrouter", model: DefaultModel)
    finally:
      if dirExists(dir):
        removeDir(dir)

  test "no settings at all still starts on the built-in model":
    let dir = freshConfig("neopi-tp-start-empty")
    try:
      check resolveStartModel("openrouter", "", sawProvider = false) ==
        (provider: "openrouter", model: DefaultModel)
    finally:
      if dirExists(dir):
        removeDir(dir)

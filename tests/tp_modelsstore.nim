## Tests for the model-catalog cache: `$NEOPI_CONFIG_DIR/models-store.json`,
## pi's shape (`{"<providerId>": {"models": [{"id", "name"}], "checkedAt",
## "etag", "lastModified"}}`), owner-only, written atomically, and DISCARDED
## when it cannot be parsed — a cache is rebuilt, unlike a credential.
import std/[json, os, strutils, tables]
import neopi/authstore
import neopi/modelsstore
import neopi/primitives
import unittest2

proc freshConfig(name: string): string =
  ## A config directory that starts EMPTY, for the same reason the credential
  ## store's tests want one: a run that died mid-test leaves a file behind.
  result = getTempDir() / name
  removeDir(result)
  putEnv("NEOPI_CONFIG_DIR", result)

const ownerOnly = {fpGroupRead, fpGroupWrite, fpGroupExec, fpOthersRead,
  fpOthersWrite, fpOthersExec}

suite "the model catalog cache":
  test "modelsStorePath is models-store.json inside configDir":
    putEnv("NEOPI_CONFIG_DIR", "/tmp/neopi-modelsstore-dir")
    check modelsStorePath() == "/tmp/neopi-modelsstore-dir/models-store.json"
    check configDir() == "/tmp/neopi-modelsstore-dir"
    delEnv("NEOPI_CONFIG_DIR")
    check modelsStorePath().endsWith(".neopi" / "models-store.json")

  test "an absent file is an empty store, and reading creates nothing":
    let dir = freshConfig("neopi-modelsstore-absent")
    check loadModelsStore().entries.len == 0
    check not fileExists(modelsStorePath())
    check not dirExists(dir)

  test "an entry round-trips through pi's shape":
    discard freshConfig("neopi-modelsstore-roundtrip")
    var store = loadModelsStore()
    store.entries["openrouter"] = CatalogEntry(
      models: @[ModelInfo(id: "z-ai/glm-5.3", name: "GLM-5.3"),
                ModelInfo(id: "bare", name: "")],
      checkedAt: 1_700_000_000, etag: "W/\"abc\"",
      lastModified: "Tue, 01 Jan 2030 00:00:00 GMT")
    saveModelsStore(store)

    let node = parseFile(modelsStorePath())
    check node["openrouter"]["models"][0]["id"].getStr == "z-ai/glm-5.3"
    check node["openrouter"]["models"][0]["name"].getStr == "GLM-5.3"
    check node["openrouter"]["models"][1]["name"].getStr == ""
    check node["openrouter"]["checkedAt"].getInt == 1_700_000_000
    check node["openrouter"]["etag"].getStr == "W/\"abc\""
    check node["openrouter"]["lastModified"].getStr ==
      "Tue, 01 Jan 2030 00:00:00 GMT"

    let back = loadModelsStore()
    check back.entries.len == 1
    check back.entries["openrouter"].models.len == 2
    check back.entries["openrouter"].models[0] ==
      ModelInfo(id: "z-ai/glm-5.3", name: "GLM-5.3")
    check back.entries["openrouter"].checkedAt == 1_700_000_000
    check back.entries["openrouter"].etag == "W/\"abc\""
    check back.entries["openrouter"].lastModified ==
      "Tue, 01 Jan 2030 00:00:00 GMT"

  test "saving one provider's catalog keeps the others":
    discard freshConfig("neopi-modelsstore-rmw")
    var store = loadModelsStore()
    store.entries["openrouter"] =
      CatalogEntry(models: @[ModelInfo(id: "a", name: "A")], checkedAt: 1)
    saveModelsStore(store)
    # A second writer loads, adds and saves: a read-modify-write, not a reset.
    var again = loadModelsStore()
    again.entries["groq"] =
      CatalogEntry(models: @[ModelInfo(id: "b", name: "B")], checkedAt: 2)
    saveModelsStore(again)
    let both = loadModelsStore()
    check both.entries.len == 2
    check both.entries["openrouter"].models[0].id == "a"
    check both.entries["groq"].models[0].id == "b"

  test "the file and its directory are owner-only":
    discard freshConfig("neopi-modelsstore-modes")
    var store = loadModelsStore()
    store.entries["openrouter"] =
      CatalogEntry(models: @[ModelInfo(id: "a", name: "A")])
    saveModelsStore(store)
    let fileMode = getFilePermissions(modelsStorePath())
    check (fileMode * ownerOnly) == {}
    check fpUserRead in fileMode and fpUserWrite in fileMode
    let dirMode = getFilePermissions(configDir())
    check (dirMode * ownerOnly) == {}
    check fpUserExec in dirMode

  test "a malformed cache is discarded, not reported":
    discard freshConfig("neopi-modelsstore-malformed")
    createDir(configDir())
    writeFile(modelsStorePath(), "{oops")
    check loadModelsStore().entries.len == 0
    var store = loadModelsStore()
    store.entries["openrouter"] =
      CatalogEntry(models: @[ModelInfo(id: "a", name: "A")])
    saveModelsStore(store)          # the broken file is replaced, not kept
    check parseFile(modelsStorePath())["openrouter"]["models"][0]["id"].getStr ==
      "a"

  test "an entry that is not the cache's shape is skipped, not fatal":
    discard freshConfig("neopi-modelsstore-shape")
    createDir(configDir())
    writeFile(modelsStorePath(),
      """{"openrouter": {"models": [{"id": "a", "name": "A"},
            {"name": "no id"}, "junk"]},
          "groq": "not an object",
          "cerebras": {"models": "not an array"}}""")
    let store = loadModelsStore()
    check store.entries.hasKey("openrouter")
    check store.entries["openrouter"].models.len == 1
    check store.entries["openrouter"].models[0].id == "a"
    check not store.entries.hasKey("groq")
    check not store.entries.hasKey("cerebras")

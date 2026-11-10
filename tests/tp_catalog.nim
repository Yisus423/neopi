## Tests for the model-catalog policy: the configured providers, the cached list
## restored before a refresh, the display name lookup, and one provider's
## conditional refresh. Every provider response is canned; no test needs a
## network or an API key.
import std/[options, os, tables]
import neopi/authstore
import neopi/catalog
import neopi/modelsstore
import neopi/primitives
import neopi/provider
import neopi/wire
import unittest2

proc freshConfig(name: string): string =
  ## A config directory that starts EMPTY: removed first, because a run that
  ## died mid-test (a crash skips the `finally`) would otherwise leave its
  ## credentials behind for the next one to read.
  result = getTempDir() / name
  removeDir(result)
  putEnv("NEOPI_CONFIG_DIR", result)

proc clearKeyedProviderEnv() =
  ## The six keyed providers' environment must not leak into the expectations:
  ## the table's configuration state reads them.
  delEnv("OPENAI_API_KEY")
  delEnv("OPENROUTER_API_KEY")
  delEnv("DEEPSEEK_API_KEY")
  delEnv("GROQ_API_KEY")
  delEnv("TOGETHER_API_KEY")
  delEnv("CEREBRAS_API_KEY")

suite "the model catalog":
  test "configured providers list only what is configured, in table order":
    clearKeyedProviderEnv()
    let configuredDir = freshConfig("neopi-tp-catalog-configured")
    defer: removeDir(configuredDir)
    saveApiKey("openrouter", "sk-stored")
    var ids: seq[string]
    for spec in configuredProviders():
      ids.add spec.id
    check ids == @["openrouter", "ollama", "llamacpp"]

    let unconfiguredDir = freshConfig("neopi-tp-catalog-unconfigured")
    defer: removeDir(unconfiguredDir)
    ids = @[]
    for spec in configuredProviders():
      ids.add spec.id
    check ids == @["ollama", "llamacpp"]

  test "restoreCatalog restores each provider's cache in table order":
    clearKeyedProviderEnv()
    let dir = freshConfig("neopi-tp-catalog-restore")
    defer: removeDir(dir)
    saveApiKey("openrouter", "sk-stored")
    var store = loadModelsStore()
    store.entries["openrouter"] = CatalogEntry(models: @[
      ModelInfo(id: "z-ai/glm-5.3", name: "GLM-5.3"),
      ModelInfo(id: "openai/gpt-5", name: "GPT-5")])
    store.entries["ollama"] = CatalogEntry(models: @[
      ModelInfo(id: "qwen3", name: "Qwen 3")])
    saveModelsStore(store)

    let models = restoreCatalog()
    check models.len == 3
    check models[0] == ListedModel(provider: "openrouter", id: "z-ai/glm-5.3",
      name: "GLM-5.3")
    check models[1] == ListedModel(provider: "openrouter", id: "openai/gpt-5",
      name: "GPT-5")
    check models[2] == ListedModel(provider: "ollama", id: "qwen3", name: "Qwen 3")

  test "namesAmong answers one row's display name":
    let models = @[
      ListedModel(provider: "openrouter", id: "z-ai/glm-5.3", name: "GLM-5.3"),
      ListedModel(provider: "ollama", id: "qwen3", name: "Qwen 3")]
    check namesAmong(models, "openrouter", "z-ai/glm-5.3") == "GLM-5.3"
    check namesAmong(models, "openrouter", "missing") == ""
    check namesAmong(models, "ollama", "z-ai/glm-5.3") == ""

  test "refreshProvider persists a 200 catalog and returns it":
    clearKeyedProviderEnv()
    let dir = freshConfig("neopi-tp-catalog-refresh-200")
    defer: removeDir(dir)
    let fake = newFakeTransport()
    fake.canned(200, @["""{"data":[{"id":"model-a","name":"Model A"}]}"""],
      @[("ETag", "\"catalog-v1\"")])
    let spec = findProvider("openrouter").get

    let refresh = refreshProvider(spec, nil, fake)
    check refresh.provider == "openrouter"
    check refresh.error.len == 0
    check refresh.fetched.models.len == 1
    check refresh.fetched.models[0] == ModelInfo(id: "model-a", name: "Model A")

    let entry = loadModelsStore().entries["openrouter"]
    check entry.models.len == 1
    check entry.models[0] == ModelInfo(id: "model-a", name: "Model A")
    check entry.etag == "\"catalog-v1\""
    check entry.checkedAt > 0

  test "refreshProvider sends the stored validator and a 304 keeps the cache":
    clearKeyedProviderEnv()
    let dir = freshConfig("neopi-tp-catalog-refresh-304")
    defer: removeDir(dir)
    var store = loadModelsStore()
    store.entries["openrouter"] = CatalogEntry(
      models: @[ModelInfo(id: "cached-model", name: "Cached Model")],
      checkedAt: 1, etag: "W/\"stored\"")
    saveModelsStore(store)
    let fake = newFakeTransport()
    fake.canned(304, @[])

    let refresh = refreshProvider(findProvider("openrouter").get, nil, fake)
    check ("If-None-Match", "W/\"stored\"") in fake.calls[0].headers
    check refresh.error.len == 0
    check refresh.fetched.notModified

    let entry = loadModelsStore().entries["openrouter"]
    check entry.models.len == 1
    check entry.models[0] == ModelInfo(id: "cached-model", name: "Cached Model")
    check entry.etag == "W/\"stored\""
    check entry.checkedAt > 1

  test "a failing refresh reports the error and leaves the store untouched":
    clearKeyedProviderEnv()
    let dir = freshConfig("neopi-tp-catalog-refresh-error")
    defer: removeDir(dir)
    var store = loadModelsStore()
    store.entries["openrouter"] = CatalogEntry(
      models: @[ModelInfo(id: "cached-model", name: "Cached Model")],
      checkedAt: 1, etag: "W/\"stored\"")
    saveModelsStore(store)
    let fake = newFakeTransport()
    fake.canned(500, @["failed"])

    let refresh = refreshProvider(findProvider("openrouter").get, nil, fake)
    check refresh.error.len > 0
    let entry = loadModelsStore().entries["openrouter"]
    check entry.models.len == 1
    check entry.models[0] == ModelInfo(id: "cached-model", name: "Cached Model")
    check entry.etag == "W/\"stored\""
    check entry.checkedAt == 1

## The `/model` catalog policy: the model list is a cache with a network tail.
## Restore paints the cached rows instantly; the refresh then walks the
## configured providers and revalidates each one against the validators in its
## cache before persisting the answer.

import std/[tables, times]
import neopi/modelsstore
import neopi/primitives
import neopi/provider
import neopi/pump
import neopi/wire

type
  ListedModel* = object
    ## One row of the model catalog: the model and the provider that serves it.
    provider*: string
      ## The provider id that owns the model.
    id*: string
      ## The model id the wire addresses.
    name*: string
      ## The endpoint's display name, empty when it carries none.

  CatalogRefresh* = object
    ## One provider's refresh outcome: its id, the fetch that completed, and the
    ## error when the refresh failed.
    provider*: string
      ## The provider whose catalog was refreshed.
    fetched*: CatalogFetch
      ## The completed fetch, including the models and validators it returned.
    error*: string
      ## The failure message, empty when the refresh succeeded.

proc configuredProviders*(): seq[ProviderSpec] =
  ## The providers whose catalogs the picker shows: the table entries that are
  ## CONFIGURED, in the table's order. The credential is what configures a
  ## provider here — a stored one or the entry's variable.
  ##
  ## A keyless entry is NOT configured for merely existing. Pi's llama.cpp asks
  ## for the SERVER URL rather than a key, and neopi has nowhere to store one yet
  ## (ROADMAP, the end of the list); until it does, a keyless entry joins this
  ## list only once it has a credential of its own. Without the rule `/model`
  ## tried to refresh a local server nobody had pointed at and reported the
  ## connection failure as if the provider had answered.
  for spec in knownProviders():
    if providerState(spec) in {psStored, psEnv}:
      result.add spec

proc restoreCatalog*(): seq[ListedModel] =
  ## The cached catalog as rows: every configured provider's cached models, in
  ## provider-table order. A provider without a cached entry contributes no
  ## rows.
  let store = loadModelsStore()
  for spec in configuredProviders():
    for model in store.entries.getOrDefault(spec.id).models:
      result.add ListedModel(provider: spec.id, id: model.id, name: model.name)

proc namesAmong*(models: seq[ListedModel], provider, id: string): string =
  ## The display name of one catalog row, or an empty string when the catalog
  ## carries no such provider/model pair.
  for model in models:
    if model.provider == provider and model.id == id:
      return model.name
  ""

proc refreshProvider*(spec: ProviderSpec, pump: Pump,
    transport: Transport = nil): CatalogRefresh =
  ## Refresh one provider's catalog and persist the answer. The provider's
  ## cached validators make the request conditional; a `304` keeps the cached
  ## models, while a `200` replaces them. A failed refresh reports its error
  ## and leaves the cache untouched.
  result.provider = spec.id
  let entry = loadModelsStore().entries.getOrDefault(spec.id)

  # `var`, not `let`: setPump takes the provider mutably (the pump is the
  # provider's own field, so a refresh carries the frame's hook into the waits).
  var provider = newProvider(spec, credentialFor(spec), transport = transport)
  provider.setPump(pump)
  try:
    result.fetched = provider.fetchModels(entry.etag, entry.lastModified)
  except CatchableError as e:
    result.error = e.msg
    return

  let models = if result.fetched.notModified: entry.models else: result.fetched.models
  var freshStore = loadModelsStore()
  freshStore.entries[spec.id] = CatalogEntry(
    models: models,
    checkedAt: epochTime().int64,
    etag: result.fetched.etag,
    lastModified: result.fetched.lastModified)
  saveModelsStore(freshStore)

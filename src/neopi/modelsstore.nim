## The model-catalog cache: the `/model` picker's lists, kept in
## `$NEOPI_CONFIG_DIR/models-store.json` (default `~/.neopi/models-store.json`)
## in pi's shape — one entry per provider holding the catalog, when the last
## remote check COMPLETED, and the HTTP validators the endpoint offered, so the
## file stores how to REVALIDATE and not only the result.
##
## It is a cache, never a credential: a file this module cannot parse is
## discarded and rebuilt, and a single damaged entry drops only itself. The
## credential store REPORTS instead, because a key is not ours to throw away.
## The write is the credential store's atomic owner-only one — the same file
## discipline, one implementation.

import std/[json, options, os, tables]
import neopi/authstore
import neopi/primitives

type
  CatalogEntry* = object
    ## One provider's cached catalog and how to revalidate it. `checkedAt` is
    ## the unix time of the last COMPLETED remote check (0 = never), and `etag`
    ## and `lastModified` are the endpoint's validators stored verbatim: they go
    ## back as `If-None-Match` and `If-Modified-Since`, which is what makes the
    ## freshness a validator instead of a clock.
    models*: seq[ModelInfo]
    checkedAt*: int64
    etag*: string
    lastModified*: string

  ModelsStore* = object
    ## The cache file as a whole: one `CatalogEntry` per provider id, in the
    ## file's order. Load, change your provider's entry, save — that
    ## read-modify-write is what keeps the other providers' catalogs.
    entries*: OrderedTable[string, CatalogEntry]

const
  modelsStoreFileName = "models-store.json"
    ## The cache file's name inside the config directory (pi's name, the user's
    ## call: the same file pi writes).

proc modelsStorePath*(): string =
  ## The catalog cache: `models-store.json` inside `configDir()`. Reading it
  ## creates nothing.
  configDir() / modelsStoreFileName

proc parseEntry(node: JsonNode): Option[CatalogEntry] =
  ## One provider's entry, or `none` when it is not the cache's shape. A cache
  ## is best-effort here: a row that cannot be read is dropped, never fatal, and
  ## a models array is required because an entry without one says nothing.
  if node.isNil or node.kind != JObject:
    return none(CatalogEntry)
  let modelsNode = node{"models"}
  if modelsNode.isNil or modelsNode.kind != JArray:
    return none(CatalogEntry)
  var entry = CatalogEntry()
  for row in modelsNode:
    if row.isNil or row.kind != JObject:
      continue
    let id = row{"id"}
    if id.isNil or id.kind != JString or id.getStr("").len == 0:
      continue
    let name = row{"name"}
    entry.models.add ModelInfo(id: id.getStr(),
      name: if name.isNil or name.kind != JString: "" else: name.getStr())
  let checkedAt = node{"checkedAt"}
  if not checkedAt.isNil and checkedAt.kind == JInt:
    entry.checkedAt = checkedAt.getInt()
  let etag = node{"etag"}
  if not etag.isNil and etag.kind == JString:
    entry.etag = etag.getStr()
  let lastModified = node{"lastModified"}
  if not lastModified.isNil and lastModified.kind == JString:
    entry.lastModified = lastModified.getStr()
  some(entry)

proc parseStore(text: string): ModelsStore =
  ## The cache file's text → the store. Anything this module cannot read yields
  ## an EMPTY store (a cache is rebuilt); damage inside one entry drops only
  ## that entry.
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError:
    return ModelsStore()
  if node.kind != JObject:
    return ModelsStore()
  for providerId, entryNode in node:
    let entry = parseEntry(entryNode)
    if entry.isSome:
      result.entries[providerId] = entry.get()

proc toJsonNode(store: ModelsStore): JsonNode =
  ## The store as the file's JSON: pi's shape, with a validator written only
  ## when it exists (an absent one is absent, not an empty string).
  result = newJObject()
  for providerId, entry in store.entries:
    var models = newJArray()
    for model in entry.models:
      models.add %*{"id": model.id, "name": model.name}
    var node = newJObject()
    node["models"] = models
    if entry.checkedAt > 0:
      node["checkedAt"] = %entry.checkedAt
    if entry.etag.len > 0:
      node["etag"] = %entry.etag
    if entry.lastModified.len > 0:
      node["lastModified"] = %entry.lastModified
    result[providerId] = node

proc loadModelsStore*(): ModelsStore =
  ## The cache read from `models-store.json`, or an empty store when the file is
  ## absent or unreadable. Reading never creates the config directory.
  let path = modelsStorePath()
  if not fileExists(path):
    return ModelsStore()
  try:
    return parseStore(readFile(path))
  except CatchableError:
    return ModelsStore()

proc saveModelsStore*(store: ModelsStore) =
  ## Write the WHOLE store atomically and owner-only through the credential
  ## store's write: the previous file survives a failure, and a reader never
  ## sees a half-written one. The caller loads, changes and saves; nothing here
  ## merges, so a save is the complete state.
  writeNode(modelsStorePath(), configDir(), toJsonNode(store))

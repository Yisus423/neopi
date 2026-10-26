## The global credential store: the API keys `/login` installs, kept in
## `$NEOPI_CONFIG_DIR/auth.json` (default `~/.neopi/auth.json`) in pi's shape:
## `{"<providerId>": {"type": "api_key", "key": "..."}}`.
##
## One file for every project, owner-only, because a key is neither the
## session's nor the repository's. Every write is a read-modify-write, so saving
## one provider never loses another's key, and a file this module cannot parse
## is REPORTED rather than rewritten — the credentials it holds are not ours to
## discard.

import std/[json, options, os]

type
  AuthStoreError* = object of CatchableError
    ## A credential store failure the caller reports to the user: the write
    ## could not be completed, or the existing file is not a credential file.

const
  defaultConfigDirName = ".neopi"
    ## The config directory when `NEOPI_CONFIG_DIR` is not set.
  authFileName = "auth.json"
    ## The credential file's name inside that directory.
  dirPermissions = {fpUserRead, fpUserWrite, fpUserExec}
    ## The config directory's permissions: owner-only.
  filePermissions = {fpUserRead, fpUserWrite}
    ## The credential file's permissions: owner-only.

proc configDir*(): string =
  ## The directory the credentials live in: `$NEOPI_CONFIG_DIR` when set (the
  ## override the tests use, and the seam a portable install wants), else
  ## `~/.neopi`. Reading it creates nothing.
  let override = getEnv("NEOPI_CONFIG_DIR")
  if override.len > 0:
    return override
  getHomeDir() / defaultConfigDirName

proc authFilePath*(): string =
  ## The credential file: `auth.json` inside `configDir()`.
  configDir() / authFileName

proc parseNode(path: string): JsonNode =
  ## The credential file parsed, or nil when it is absent, unreadable, not
  ## JSON, or not a JSON object. A READ tolerates all of those (they mean "no
  ## credential"); a write does not, because it cannot preserve what it cannot
  ## read.
  if not fileExists(path):
    return nil
  try:
    let node = parseJson(readFile(path))
    if node.kind == JObject:
      return node
  except CatchableError:
    discard
  nil

proc writableNode(path: string): JsonNode =
  ## The credential file for a write: a missing file is an empty object (the
  ## first credential), and anything this module cannot parse raises instead of
  ## being replaced.
  if not fileExists(path):
    return newJObject()
  let node = parseNode(path)
  if node.isNil:
    raise newException(AuthStoreError,
      "the credential file is not a JSON object: " & path)
  node

proc writeNode(path, dir: string, node: JsonNode) =
  ## Write the credential file whole and owner-only: the new content lands in a
  ## temporary file beside the target and is renamed over it, so a reader never
  ## sees a half-written file and a failure leaves the previous one intact. The
  ## mode is applied to the EMPTY temporary file first, so the secret is never
  ## written to a readable one.
  if not dirExists(dir):
    # `createDir` takes no mode in this Nim: create it, then narrow it. The
    # directory holds one file, and it is narrowed before the secret is written.
    createDir(dir)
    setFilePermissions(dir, dirPermissions)
  let tmp = path & ".tmp"
  removeFile(tmp)
  writeFile(tmp, "")
  setFilePermissions(tmp, filePermissions)
  writeFile(tmp, node.pretty & "\n")
  moveFile(tmp, path)
  setFilePermissions(path, filePermissions)

proc loadApiKey*(providerId: string): Option[string] =
  ## The stored API key for `providerId`. `none` when the file is absent, is not
  ## a credential file, has no entry for the provider, or that entry is not an
  ## `api_key` credential with a non-empty key. Reading never creates the
  ## config directory and never rewrites the file.
  ##
  ## Every access is guarded because of a std/json trap: `node{key}` yields NIL
  ## for a missing key, not a `JNull` node, so a read that trusted it segfaults
  ## on the first missing entry (this module's own tests found it).
  let node = parseNode(authFilePath())
  if node.isNil:
    return none(string)
  let entry = node{providerId}
  if entry.isNil or entry.kind != JObject:
    return none(string)
  let credentialType = entry{"type"}
  if credentialType.isNil or credentialType.getStr("") != "api_key":
    return none(string)
  let naming = entry{"key"}
  if naming.isNil or naming.getStr("").len == 0:
    return none(string)
  some(naming.getStr())

proc saveApiKey*(providerId, apiKey: string) =
  ## Store `providerId`'s API key, preserving every other provider's entry. An
  ## empty id or key is rejected — a half credential is worse than none — and a
  ## file that is not a credential file raises instead of being replaced.
  if providerId.len == 0 or apiKey.len == 0:
    raise newException(AuthStoreError,
      "a credential needs a non-empty provider id and key")
  let path = authFilePath()
  let node = writableNode(path)
  node[providerId] = %*{"type": "api_key", "key": apiKey}
  writeNode(path, configDir(), node)

proc deleteApiKey*(providerId: string) =
  ## Drop `providerId`'s entry, preserving the rest. A missing file or a missing
  ## entry is a no-op (nothing to remove is not a failure); a file that is not a
  ## credential file raises, because it cannot be rewritten without discarding
  ## what it holds.
  if providerId.len == 0:
    raise newException(AuthStoreError, "a credential needs a provider id")
  let path = authFilePath()
  if not fileExists(path):
    return
  let node = writableNode(path)
  if not node.hasKey(providerId):
    return
  node.delete(providerId)
  writeNode(path, configDir(), node)

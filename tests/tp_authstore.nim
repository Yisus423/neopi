## Tests for the global credential store: `$NEOPI_CONFIG_DIR/auth.json` — pi's
## shape (`{"<providerId>": {"type": "api_key", "key": "..."}}`), owner-only
## modes, a read-modify-write that never loses another provider's key, and a
## malformed file that is REPORTED instead of clobbered (the keys it holds are
## not ours to throw away).
import std/[json, options, os, strutils]
import neopi/authstore
import unittest2

proc freshConfig(name: string): string =
  ## A config directory that starts EMPTY: removed first, because a run that
  ## died mid-test (a crash skips the `finally`) would otherwise leave its
  ## credentials behind for the next one to read.
  result = getTempDir() / name
  removeDir(result)
  putEnv("NEOPI_CONFIG_DIR", result)

const ownerOnly = {fpGroupRead, fpGroupWrite, fpGroupExec, fpOthersRead,
  fpOthersWrite, fpOthersExec}

suite "the credential store":
  test "configDir reads the override and defaults to ~/.neopi":
    putEnv("NEOPI_CONFIG_DIR", "/tmp/neopi-authstore-dir")
    check configDir() == "/tmp/neopi-authstore-dir"
    delEnv("NEOPI_CONFIG_DIR")
    check configDir().endsWith(".neopi")
    check authFilePath() == configDir() / "auth.json"

  test "an absent file has no credential, and reading creates nothing":
    let dir = freshConfig("neopi-authstore-absent")
    check loadApiKey("openrouter").isNone
    check not fileExists(authFilePath())
    check not dirExists(dir)

  test "a key round-trips through pi's shape":
    discard freshConfig("neopi-authstore-roundtrip")
    saveApiKey("openrouter", "sk-test")
    check loadApiKey("openrouter") == some("sk-test")
    let node = parseFile(authFilePath())
    check node["openrouter"]["type"].getStr == "api_key"
    check node["openrouter"]["key"].getStr == "sk-test"

  test "saving a second provider keeps the first":
    discard freshConfig("neopi-authstore-rmw")
    saveApiKey("openrouter", "sk-or")
    saveApiKey("groq", "sk-groq")
    check loadApiKey("openrouter") == some("sk-or")
    check loadApiKey("groq") == some("sk-groq")
    # A read-modify-write, not a file that starts over.
    check parseFile(authFilePath())["openrouter"]["key"].getStr == "sk-or"

  test "the file and its directory are owner-only":
    discard freshConfig("neopi-authstore-modes")
    saveApiKey("openrouter", "sk-test")
    let fileMode = getFilePermissions(authFilePath())
    check (fileMode * ownerOnly) == {}
    check fpUserRead in fileMode and fpUserWrite in fileMode
    let dirMode = getFilePermissions(configDir())
    check (dirMode * ownerOnly) == {}
    check fpUserExec in dirMode

  test "delete removes only that provider":
    discard freshConfig("neopi-authstore-delete")
    saveApiKey("openrouter", "sk-or")
    saveApiKey("groq", "sk-groq")
    deleteApiKey("openrouter")
    check loadApiKey("openrouter").isNone
    check loadApiKey("groq") == some("sk-groq")

  test "deleting what is not there is a no-op":
    discard freshConfig("neopi-authstore-delete-missing")
    deleteApiKey("openrouter")            # no file at all
    check loadApiKey("openrouter").isNone
    saveApiKey("groq", "sk-groq")
    let before = readFile(authFilePath())
    deleteApiKey("openrouter")
    check readFile(authFilePath()) == before

  test "a malformed file is reported, never clobbered":
    discard freshConfig("neopi-authstore-malformed")
    createDir(configDir())
    writeFile(authFilePath(), "{oops")
    check loadApiKey("openrouter").isNone
    expect AuthStoreError:
      saveApiKey("openrouter", "sk-test")
    check readFile(authFilePath()) == "{oops"
    expect AuthStoreError:
      deleteApiKey("openrouter")
    check readFile(authFilePath()) == "{oops"

  test "an entry that is not an api_key credential is not a key":
    discard freshConfig("neopi-authstore-shape")
    createDir(configDir())
    writeFile(authFilePath(),
      """{"openrouter": {"type": "oauth", "token": "x"},
          "groq": {"type": "api_key"}}""")
    check loadApiKey("openrouter").isNone
    check loadApiKey("groq").isNone

  test "an empty provider id or key is rejected":
    discard freshConfig("neopi-authstore-empty")
    expect AuthStoreError:
      saveApiKey("", "sk-test")
    expect AuthStoreError:
      saveApiKey("openrouter", "")
    check loadApiKey("openrouter").isNone

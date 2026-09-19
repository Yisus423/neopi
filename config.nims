import std/os

# Prefer sibling checkouts when developing in the niminal workspace.
for p in ["../nimgent/src"]:
  let abs = thisDir() / p
  if dirExists(abs):
    switch("path", abs)

# The project's own sources.
switch("path", thisDir() / "src")

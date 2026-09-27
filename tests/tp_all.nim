## Test dispatcher: runs every tp_*.nim suite. tp_real skips itself without an
## OPENROUTER_API_KEY.
import unittest2
import tp_provider
import tp_lua
import tp_fs
import tp_tools
import tp_expose
import tp_session
import tp_real

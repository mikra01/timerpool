import ospaths, strutils

task tests, "run timerpool tests":
  withDir thisDir():
    switch("threads","on")
    switch("run")
    setCommand "c", "tests/timerpool_test.nim"

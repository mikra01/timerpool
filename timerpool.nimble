# Package
version = "0.1.0"
author = "Michael Krauter"
description = "single thread Timerpool implementation in Nim for event purpose"
license = "MIT"
skipDirs = @["tests"]

# Dependencies
requires "nim >= 0.17.0"

task timerpool_tests, "running tests":
  exec "nim timerpool_tests"
# Package

version     = "0.10.1"
author      = "puffball1567"
description = "KoutenDB: ring-oriented NoSQL document/vector store for smaller working sets"
license     = "Apache-2.0"
srcDir      = "src"
bin         = @["kouten", "koutencli", "koutend", "koutenbench", "koutensim"]

# Dependencies

requires "nim >= 2.0.0"
requires "nimsodium >= 0.2.0"

task test, "Run the embedded KoutenDB test suite":
  exec "scripts/test_core.sh"

task smoke, "Run the KoutenDB smoke suite":
  exec "scripts/test_all_smoke.sh"

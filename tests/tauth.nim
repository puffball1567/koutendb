## kouten/auth の安全比較テスト

import std/[net, unittest]
import ../src/kouten/auth
import ../src/kouten/wire

suite "auth helpers":
  test "secureEqual matches equal strings":
    check secureEqual("secret", "secret")
    check secureEqual("", "")

  test "secureEqual rejects unequal strings and length mismatches":
    check not secureEqual("secret", "secreu")
    check not secureEqual("secret", "secret!")
    check not secureEqual("", "x")

  test "secret challenge response verifies only with matching inputs":
    let challenge = newChallengeHex()
    let response = secretResponseHex("alice", "password", challenge, "secret-key")
    check verifySecretResponse("alice", "password", challenge, response, "secret-key")
    check not verifySecretResponse("alice", "wrong", challenge, response, "secret-key")
    check not verifySecretResponse("alice", "password", challenge, response, "wrong-key")

suite "wire boundary helpers":
  test "peer configuration rejects empty hosts and invalid ports":
    expect ValueError:
      discard parsePeers(":7301")
    expect ValueError:
      discard parsePeers("127.0.0.1:0")
    expect ValueError:
      discard parsePeers("127.0.0.1:65536")
    expect ValueError:
      discard newClusterClient(@[])

  test "body reads reject impossible lengths before touching the socket":
    var socket: Socket = nil
    expect IOError:
      discard socket.readExact(-1)
    expect IOError:
      discard socket.readExact(MaxWireBodyBytes + 1)

  test "float vector decoding rejects inconsistent byte lengths":
    expect ValueError:
      discard bytesVec("abc", 1)
    expect ValueError:
      discard bytesVec("", -1)

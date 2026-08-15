# KoutenDB 状態 / ロードマップ

この文書は参考翻訳です。英語版 [koutendb-status.md](./koutendb-status.md) が正本であり、
この翻訳は遅れる可能性があります。

リリースチェックリスト: [release-checklist.md](./release-checklist.md)

## コア DB

| 機能 | 状態 | メモ |
|---|---|---|
| Embedded DB | 完了 | `open(dataDir=...)` とメモリ専用モード |
| put / get | 完了 | ring 指定 write と ID read |
| ORM foundation API | 完了 | `update`, JSON `patch`, `deleteById`, `listByRing`, `countByRing` の土台。driver 公開は未完 |
| Warp belt | PoC | WAL-backed delayed patch queue。retry / ack / dead-letter の最小状態を保持 |
| JSON document query | 完了 | GraphQL 風 selection |
| Vector retrieve | 完了 | ringで候補を削減した後に依存ライブラリ不要のExact評価を実行 |
| Ring / hierarchy | 完了 | `ring = "a/b/c"` と child-ring expansion |
| Galaxy isolation | 完了 | data dir / peer list / credential の境界 |
| Atlas / ring map | 完了 | `atlas()` と `kouten atlas` |
| Retrieval tuning profile | 完了 | amount / scope / depth |
| WASM browser embedded | v0.1 後の候補 | Browser state boundary / IndexedDB / OPFS |

## 永続化 / 運用

| 機能 | 状態 | メモ |
|---|---|---|
| Append-only WAL | 完了 | 通常は batched flush。strong durability は flush + fsync |
| Reopen recovery | 完了 | items / vectors / ring metadata / descriptions |
| Transaction | 完了 | Embedded atomic transaction |
| Cluster transaction landing | PoC | node0 landing。failure retry smoke あり |
| Compact | 完了 | live records から WAL を再構築 |
| Backup / restore | 完了 | compacted WAL backup と restore |
| Dump / import-jsonl | 完了 | NoSQL JSONL import rules |
| Crash recovery tests | 部分対応 | torn WAL tail、compact interruption、partial commit |
| Core test suite | 完了 | `scripts/test_core.sh` |
| Full smoke suite | 完了 | `scripts/test_all_smoke.sh` |
| Kubernetes manifests | 予定 | liveness/readiness, PVC, rolling restart |

## クラスタ / ネットワーク

| 機能 | 状態 | メモ |
|---|---|---|
| Static cluster | 完了 | `koutend --id --peers` |
| Deterministic locate | 完了 | `E(id,t) -> node` |
| Handoff / forwarder | PoC | slow tick integration あり |
| Driver-friendly wire | 完了 | `PUTR/GETID/QRYID` |
| Authn + secret key | 完了 | username/password/secret-key |
| Authz / RBAC | PoC | ring prefix authz と role matrix smoke |
| Wire fuzz smoke | 完了 | malformed frame cases |
| Dynamic membership | 予定 | 現在は static peers |
| TLS | 完了 | 標準TLS transportを実装済み。詳細は英語正本を参照 |

## Drivers / Bindings

| Target | 状態 | メモ |
|---|---|---|
| Nim API | 完了 | Native public API |
| C ABI | 完了 | ABI version / last error / put/get/retrieve/batch/atlas |
| Python | 公開済み | PyPI `koutendb` v0.2.1。Native TCP wire driver |
| Node.js / TypeScript / Bun | 公開済み | npm `koutendb` v0.1.5。Bun は実験的 |
| Rust | 公開済み | crates.io `koutendb` v0.1.6。詳細は英語正本を参照 |
| Go | リポジトリ内のみ | C ABI wrapper minimal。Go module と外部 driver repository は未公開 |
| PHP | 公開済み | Packagist `koutendb/koutendb` v0.1.3。Docker smoke あり |
| Swift / Kotlin | リポジトリ内のみ | wrapper と Docker smoke は実装済み。SwiftPM / Maven package は未公開 |
| C# | リポジトリ内のみ | generic wrapper は実装済み。NuGet package は未公開。Unity 公式 asset は別候補 |
| C++ | GitHub Release 公開済み | `koutendb-cpp` v0.1.3。Unreal 公式 asset は別候補 |
| React Native / WASM | v0.1 後の候補 | Browser / local state boundary |
| Driver discovery CLI | 完了 | `kouten driver list/info/install` が公式 driver metadata と setup command を表示。remote script は実行しない |
| Package publishing | 一部完了 | `nimble install koutendb`, `cargo add koutendb`, `npm install koutendb`, `composer require koutendb/koutendb`, `python3 -m pip install koutendb` が利用可能。その他のレジストリは今後 |

## Benchmarks / Demos

| 項目 | 状態 | メモ |
|---|---|---|
| Working-set bench | 完了 | scanned/query reduction |
| Memory-pressure bench | 完了 | candidate memory/query |
| RAG-style bench | 完了 | recall を維持し tokens/query を削減 |
| AI/RAG JSONL case study | 完了 | deterministic multi-ring JSONL corpus |
| PostgreSQL / Redis comparison | 完了 | 条件と制約つきの smoke/reference |
| Cluster failure retry smoke | 部分対応 | owner kill/restart retry |
| Multi-node cloud case study | 予定 | VM/AZ, latency, failover |

## Security / Safety

| 項目 | 状態 | メモ |
|---|---|---|
| Username/password auth | 完了 | koutend and driver path |
| Secret key gate | 完了 | ID/password だけでは不足にできる |
| nimsodium encryption primitive | 部分対応 | auth transport。範囲拡大余地あり |
| Galaxy isolation | 完了 | blast radius を galaxy で制限 |
| Backup encryption | 完了 | nimsodium secretbox |
| Threat model | Draft | [threat-model.md](./threat-model.md) |

## v0.1 後のロードマップ候補

これらは v0.2 以降の候補であり、すべてを v0.2.0 だけに入れるという意味ではありません。

- WASM browser embedded
- IndexedDB / OPFS persistence
- React hooks / browser state boundary
- React Native / WASM local state module
- Unity official asset
- Unreal official plugin
- language driver package publishing workflows

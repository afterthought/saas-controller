## Tasks

**Dex Epic**: `vfw14geb`
**Query**: `dex list vfw14geb`

### Dependency Graph

```
78gz5v9g: Extract shared compose lifecycle (lib/docker-compose.nix)
    ↓
    ├── s0vmqgy6: Refactor hello-world and zuplo providers  [blocked-by: 78gz5v9g]
    │
yxvd0eyw: Add three-layer secret composition (extraSecrets + auto-include)
    ↓
    amorhj0z: Add SA token swap (per-service injection)     [blocked-by: yxvd0eyw]
        ↓
        uulerxje: Create docker-compose provider (overlay)  [blocked-by: 78gz5v9g, amorhj0z]
```

### Task List

- [x] `78gz5v9g` — Extract shared compose lifecycle into `lib/docker-compose.nix`
  - Spec: `specs/docker-compose-base/spec.md`
  - Create `mkTailscaleSidecar`, `mkServeConfig`, `mkComposeLifecycle`
  - Library only — no provider changes yet

- [x] `s0vmqgy6` — Refactor hello-world and zuplo providers to use shared library
  - Spec: `specs/docker-compose-base/spec.md`
  - Blocked by: `78gz5v9g`
  - Replace inline sidecar/lifecycle code with library calls
  - Verify generated compose files are structurally identical

- [x] `yxvd0eyw` — Add three-layer secret composition with extraSecrets and auto-include
  - Spec: `specs/secret-composition/spec.md`
  - Add `secrets` option to environment submodule
  - Auto-include provider profiles in `mkServiceSecretspecToml`
  - First occurrence wins on duplicate names

- [x] `amorhj0z` — Add SA token swap with per-service secret injection
  - Spec: `specs/sa-token-swap/spec.md`
  - Blocked by: `yxvd0eyw`
  - Add `saToken`, `saTokensDir`, `toSASecretName`
  - Rewrite `sc up` from single re-exec to per-service subshells

- [x] `uulerxje` — Create docker-compose provider with compose overlay
  - Spec: `specs/docker-compose-base/spec.md`
  - Blocked by: `78gz5v9g`, `amorhj0z`
  - Accept pre-authored compose files, inject tailscale via overlay
  - Migration path for `__mac-nix` docker services

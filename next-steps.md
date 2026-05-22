# Resumo do trabalho no ambiente Vector (Nix / build / tooling)

Sessão focada em montar um ambiente de desenvolvimento e build do **Vector** com Nix, alinhar com o que o repositório já usa (`Makefile`, `prepare.sh`, CI) e destravar builds locais (musl, Alpine, Podman).

---

## Objetivo inicial

Criar um **`flake.nix`** com dependências para:

- `make build` / desenvolvimento Rust
- `make package-*-linux-musl-all` (binários musl → imagem Alpine)
- Fluxo parecido com o CI, sem depender só da máquina host

Depois: **`.envrc`**, regra no **`AGENTS.md`**, incluir **`cross`** e todas as ferramentas de `prepare.sh` (linhas 248–249), e discussão **CI vs local**.

---

## Arquivos criados ou alterados

| Arquivo | O que foi feito |
|---------|------------------|
| [`flake.nix`](flake.nix) | Dev shell Nix (estado atual abaixo) |
| [`flake.lock`](flake.lock) | Lock de `nixpkgs`, `flake-utils`, `rust-overlay` |
| [`.envrc`](.envrc) | `use flake` (direnv) |
| [`AGENTS.md`](AGENTS.md) | Seção **“Nix flake (required for shell commands)”** — agentes devem usar `nix develop -c …` |

**Não alterados:** `prepare.sh`, `Makefile`, workflows do GitHub (só referenciados).

---

## Evolução do `flake.nix` (o que foi tentado)

### 1. Primeira versão

- **Inputs:** `nixpkgs` 24.11, `flake-utils`, `rust-overlay`
- **Rust:** `rust-bin.fromRustupToolchainFile` → canal **1.92** (`rust-toolchain.toml`)
- **Libs nativas** espelhando `install-debian-build-deps.sh`: openssl, zlib, `cyrus_sasl`, libclang, cmake, mold, protobuf, autotools, etc.
- **Ferramentas via nixpkgs:** `cargo-nextest`, `cargo-deny`, `cargo-msrv`, `cargo-hack`, `cargo-llvm-cov`, `cargo-deb`, `cargo-binstall`, `wasm-pack`, `nodejs`, `nixfmt`
- **Problemas corrigidos:** nomes errados (`cyrus-sasl` → `cyrus_sasl`, `xxhash` → `xxHash`); `cross` não existe como `pkgs.cross` → uso de **`pkgs.cargo-cross`**

### 2. `cross` no flake

- Pacote Nix: **`cargo-cross` 0.2.5** (binário `cross`) — alinhado ao pin do `prepare.sh`
- Depois **removido** do modelo final (substituído por `prepare.sh`)

### 3. Todas as ferramentas de `REQUIRES_RUSTUP` / `REQUIRES_BINSTALL`

Tentativas:

- **Só nixpkgs:** várias versões **diferentes** do pin do `prepare.sh` (ex.: nextest 0.9.81 vs 0.9.95); **`dd-rust-license-tool`** e **`vdev`** **ausentes** no nixpkgs
- **Só rustup no Nix + `prepare.sh` no shellHook:** falhou — toolchain rustup do Nix sem componente **`cargo`** utilizável; `cargo install` quebrava
- **`prepare.sh` copiado para o store** (`${./scripts/environment/prepare.sh}`): quebrou caminho do **`binstall.sh`**
- **Modelo final (híbrido):** ver seção “Estado atual”

### 4. `.envrc` + direnv

- `use flake` → carrega shell ao entrar no diretório (`direnv allow` uma vez)
- Cache em `~/.cache/vector/prepare-<hash>` na primeira carga

---

## Estado atual do ambiente (como ficou)

### Dois perfis no flake

| Perfil | Uso |
|--------|-----|
| **`default`** | Dev completo: libs + Rust + `prepare` com todos os módulos cargo |
| **`build`** | Mínimo para cross-compile: mesmo base, `prepare --modules=cross` |

Comandos:

```bash
nix develop              # ou direnv na pasta do repo
nix develop --profile build
nix develop -c make build
VECTOR_FORCE_PREPARE=1 direnv reload   # reinstalar ferramentas cargo
```

### Camada 1 — Nix store (reproduzível)

**Rust (compilação):**

| Ferramenta | Origem | Versão / nota |
|------------|--------|----------------|
| `rustc`, `cargo`, `rustfmt`, `clippy` | `rust-overlay` + `rust-toolchain.toml` | **1.92.0** |
| `rustup` | nixpkgs | 1.27.1 — só para `cross` listar toolchains; **não** é o cargo principal |

**Bibliotecas / build nativo** (`nativeDeps`):

`pkg-config`, `openssl`, `zlib`, `cyrus_sasl`, `libclang`, `clang`, `xxHash`, `cmake`, `perl`, `python3`, `mold`, `protobuf`, `autoconf`, `automake`, `libtool`, `gnumake`, `git`, `curl`, `unzip`, `bash`

**Outros no shell:**

| Ferramenta | Origem | Uso |
|------------|--------|-----|
| `cargo-binstall` | nixpkgs | Usado pelo `prepare.sh` para instalar bins pinados |
| `nodejs_22` | nixpkgs | Ecossistema npm do repo |
| `nixfmt-rfc-style` | nixpkgs | Formatar `flake.nix` |

**Variáveis no `shellHook`:**

- `PKG_CONFIG_PATH`, `LIBCLANG_PATH`, `PROTOC`, `RUSTFLAGS` (+ mold), `OPENSSL_NO_VENDOR=1`
- `PATH` com `scripts/environment/npm-tools/node_modules/.bin` (markdownlint/prettier **se** `npm ci` já rodou lá)

**Não incluído no flake (comentado/removido):** `docker` — você usa **Podman** (`CONTAINER_TOOL=podman` no Makefile).

### Camada 2 — `prepare.sh` → `~/.cargo/bin` (mesmo fluxo do CI)

Na **primeira** entrada no shell (ou com `VECTOR_FORCE_PREPARE=1`), roda:

```text
./scripts/environment/prepare.sh --modules=cargo-deb,cross,cargo-nextest,cargo-deny,cargo-msrv,cargo-hack,cargo-llvm-cov,dd-rust-license-tool,wasm-pack,vdev
```

Instalação via **`cargo binstall`** (versões em `prepare.sh`), com `unset RUSTUP_TOOLCHAIN` durante o install para usar o **cargo do Nix**.

| Ferramenta | Versão pinada | Onde fica | Uso típico no Vector |
|------------|---------------|-----------|----------------------|
| `cargo-deb` | 2.9.3 | `~/.cargo/bin` | Pacotes `.deb` |
| `cross` | 0.2.5 | `~/.cargo/bin` | `make package-*-musl-all` |
| `cargo-nextest` | 0.9.95 | `~/.cargo/bin` | `make test` |
| `cargo-deny` | 0.19.0 | `~/.cargo/bin` | `make check-deny` |
| `cargo-msrv` | 0.18.4 | `~/.cargo/bin` | MSRV |
| `cargo-hack` | 0.6.43 | `~/.cargo/bin` | feature matrix |
| `cargo-llvm-cov` | 0.8.4 | `~/.cargo/bin` | coverage (+ `llvm-tools` via rustup no prepare) |
| `dd-rust-license-tool` | 1.0.6 | `~/.cargo/bin` | `make check-licenses` |
| `wasm-pack` | 0.13.1 | `~/.cargo/bin` | VRL WASM |
| `vdev` | 0.3.3 | `~/.cargo/bin` | `make check-clippy`, integração, release helpers |

**Ordem do `PATH` (importante):**

`rust-overlay/bin` → `~/.cargo/bin` → resto (após `source ~/.cargo/env`, o flake recoloca o toolchain Nix na frente).

**Fora do flake / prepare automático (módulos npm do `prepare.sh`):**

`markdownlint-cli2`, `prettier`, `datadog-ci` — precisam `npm ci` em `scripts/environment/npm-tools` ou `prepare.sh --modules=...`

**`cue` 0.16.1** (website) — não está no flake; CI instala à parte.

---

## Problemas encontrados no terminal (e soluções)

### `make package-x86_64-unknown-linux-musl-all` → `cross: No such file or directory`

- **Causa:** `cross` não estava no `PATH` (sem `prepare` / sem flake com `cross`)
- **Correção:** `prepare.sh --modules=cross` ou entrar no flake (que roda `prepare`)

### Imagem cross com **Podman** — OK

- `make cross-image-*` usa `CONTAINER_TOOL` (auto → podman se não houver docker)
- **`scripts/build-docker.sh`** ainda chama **`docker`/`docker buildx`** literalmente — para `make release-docker` precisa shim `docker=podman` ou comandos `podman` manuais

### `cross --version` + aviso rustup

- Com só rustup Nix: erro `rustup toolchain list` / cargo inexistente no toolchain
- **Solução final:** rust-overlay para cargo + rustup auxiliar + `cross` via binstall

---

## Fluxos discutidos (não implementados no repo)

### Imagem Alpine + registry privado

1. `make package-x86_64-unknown-linux-musl-all` (gera `.tar.gz` em `target/artifacts/`)
2. `distribution/docker/alpine/Dockerfile` (contexto = `target/artifacts/`)
3. Push: `scripts/build-docker.sh` com `REPOS=registry...`, `CHANNEL=custom`, ou `podman build` / `podman push` manual

### CI GitHub Actions vs local

- **CI:** fonte da verdade para merge (`.github/actions/setup` + `prepare.sh`)
- **Flake/direnv:** loop de dev rápido; complementa, não substitui o CI

---

## Ferramentas do Makefile / CI referenciadas (contexto)

| Ferramenta | No flake atual? | Como obter |
|------------|-----------------|------------|
| `make`, `bash` | host / nix shell | — |
| `cargo` / `rustc` | sim (rust-overlay) | Nix store |
| `cross` | sim (via prepare) | `~/.cargo/bin` |
| `vdev` | sim (via prepare) | `~/.cargo/bin` |
| `podman` | não | sistema |
| `docker` / buildx | não no flake | CI / shim |
| `protoc` | sim | nixpkgs `protobuf` |
| `mold` | sim | nixpkgs + `RUSTFLAGS` |
| Integração (`vdev int`) | `vdev` + **podman/docker** | container runtime no host |

---

## Comandos úteis de verificação

```bash
which rustc cargo cross vdev
rustc --version          # 1.92.0 (Nix)
cross --version          # 0.2.5 (~/.cargo)
vdev --version           # 0.3.3
ls ~/.cargo/bin/
nix flake check
```

---

## Próximos passos possíveis

- [ ] Empacotar **`vdev`** / **`dd-rust-license-tool`** só no Nix (sem `~/.cargo`) — mais hermético, mais trabalho de manutenção
- [ ] Adicionar **`podman`** no flake + adaptar `build-docker.sh` para respeitar `CONTAINER_TOOL`
- [ ] Workflow **GitHub Actions** para build/push Alpine no registry privado
- [ ] Incluir **`cue` 0.16.1** e módulos npm no flake ou documentar `prepare.sh --modules=cue,markdownlint-cli2`
- [ ] Completar `make package-x86_64-unknown-linux-musl-all` e validar `podman build` da imagem Alpine
- [ ] Commitar `flake.nix`, `flake.lock`, `.envrc` (e decidir se `next-steps.md` entra no repo)

---

**Em uma frase:** ficou um ambiente **híbrido** — **Nix** garante Rust 1.92 e libs nativas; **`prepare.sh` + cargo-binstall** instala no mesmo pin do CI as ferramentas da lista 248–249 em `~/.cargo/bin`; **direnv** carrega isso ao entrar no repo; o que falhou no meio foi confiar só em rustup Nix ou só em pacotes nixpkgs desatualizados para tudo.

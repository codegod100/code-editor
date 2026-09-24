# Low\* core for a freeq client

**Status: toolchain bootstrap only.** What is here is an XOR round-trip that
verifies in Low\*, extracts to C via KaRaMeL, compiles and runs. There is no IRC
client yet. The value in this directory is the version archaeology below, which
took longer than the code did.

## Why this exists

The Modal bot in the parent directory keeps a container alive purely to hold an
IRC socket. IRC channel membership *is* the connection — unlike Matrix there is
no server-side "joined" state — so the socket has to live somewhere, but it does
not have to live somewhere expensive. The plan is a small always-on client that
holds the connection and delegates each task to Modal.

freeq makes that unusually tractable: `irc.freeq.at:6697` speaks **plain IRC over
TLS**, no WebSocket. Connecting confirms the server advertises

```
sasl message-tags multi-prefix echo-message server-time batch
draft/chathistory ... freeq.at/msgsig freeq.at/act
```

so the whole task protocol is reachable over a line protocol. The certificate's
CN is `tech.blueyard.com` with `irc.freeq.at` in the SAN list, so verification
works if you check SANs rather than CN.

## What belongs in Low\*, and what does not

| Low\* | Plain C |
| --- | --- |
| IRCv3 line and tag parser — untrusted wire input, bounds | TLS (OpenSSL or BearSSL) |
| JCS (RFC 8785) canonicalization of the act tag map | sockets, event loop |
| Ed25519 — link HACL\*'s, already verified Low\* | HTTP to Modal, JSON of the reply |

The split is not dogma. `spec/act-signing-vectors.json` in the freeq repo says
every implementation "must reproduce canonical, kid, and sigTag byte-for-byte
from tags + target + id + seed, and must reach each negative's expected verdict."
That is a precise offline oracle for exactly the two middle rows, which is what
makes verification worth its cost here. TLS and socket plumbing get nothing from
it.

## The toolchain, and why it takes two F\* installs

Low\* is a *subset* of F\* — a C-like fragment defined by the `FStar.HyperStack`
memory model and `LowStar.Buffer`, extracted to C by KaRaMeL. It is not an old
version of F\*, and it is not deprecated: HACL\*/EverCrypt are written in it.

What changed is packaging, and it breaks the obvious "install F\* and go":

- F\* commit [`baf72ea`](https://github.com/FStarLang/FStar/commit/baf72eaaf88575280665c121a54a2a3e08847f08)
  (2026-02-23), titled *"Move Low\*-specific code to the FStarLang/LowStar
  repository"*, moved the Low\* stack out of F\*'s `ulib`.
- Current F\* (v2026.09.13) therefore has **no** `FStar.HyperStack`, no
  `LowStar.Buffer`. Its namespace list is full of `pulse.*` instead.
- [`FStarLang/LowStar`](https://github.com/FStarLang/LowStar) holds the libraries
  now and is maintained, but it pins F\* by submodule and expects a source build.
  Cloning it against current F\* still fails: `FStar.Monotonic.Heap` was dropped
  from `ulib` too, and it is in neither place.
- **v2026.03.24 is the last binary release whose `ulib` still contains both**
  `FStar.Monotonic.Heap` and `FStar.HyperStack`. By v2026.04.17 they are gone.
- That older release does **not** ship `krml`. The current one does.

Hence two installs: the old F\* verifies and extracts, the new one's `krml` turns
the result into C. The `Makefile` wires them together.

```bash
# the one that still has Low* in ulib
curl -L -o fstar-0324.tar.gz \
  https://github.com/FStarLang/FStar/releases/download/v2026.03.24/fstar-v2026.03.24-Linux-x86_64.tar.gz
mkdir -p ~/.local/opt/f0324 && tar xzf fstar-0324.tar.gz -C ~/.local/opt/f0324

# the one that ships krml
curl -L -o fstar.tar.gz \
  https://github.com/FStarLang/FStar/releases/download/v2026.09.13/fstar-v2026.09.13-Linux-x86_64.tar.gz
tar xzf fstar.tar.gz -C ~/.local/opt
```

Override `FSTAR_LOWSTAR` / `FSTAR_KRML` if you put them elsewhere. No OCaml or
opam is needed — `krml` ships prebuilt, which is the one thing that turned out
easier than expected.

## Run it

```bash
make verify   # proof only: liveness, bounds, modifies clause
make c        # -> cout/Smoke.c
make run      # link against c/main.c and execute
```

Expected output, the XOR being its own inverse:

```
FREEQ
freeq
```

## What the proof actually buys

[`src/Smoke.fst`](src/Smoke.fst) is deliberately trivial, but its signature is
the point:

```fstar
val xor_bytes:
    b:B.buffer U8.t
  -> len:U32.t{B.length b == U32.v len}
  -> i:U32.t{U32.v i <= U32.v len}
  -> k:U8.t
  -> Stack unit
      (requires fun h -> B.live h b)
      (ensures fun h0 _ h1 -> B.live h1 b /\ B.modifies (B.loc_buffer b) h0 h1)
```

The refinement ties `len` to the buffer's actual length and `i` to `len`, so no
caller can pass a length that walks off the end; `live` forbids use-after-free;
`modifies` pins down that nothing but `b` is touched. F\* discharges those before
a line of C exists. For a parser eating bytes off a socket, that is the whole
argument for doing this at all.

The generated C is unremarkable, which is the intended outcome:

```c
void Smoke_xor_bytes(uint8_t *b, uint32_t len, uint32_t i, uint8_t k)
{
  if (i < len)
  {
    b[i] = (uint32_t)b[i] ^ (uint32_t)k;
    Smoke_xor_bytes(b, len, i + 1U, k);
  }
}
```

## Next

1. JCS canonicalization in Low\*, checked against `spec/act-signing-vectors.json`
   byte-for-byte. Offline, no network, no Modal — and if it does not match,
   nothing downstream can work.
2. Ed25519 from HACL\*'s pre-extracted C, validated on the same vectors.
3. IRCv3 line and tag parser.
4. C driver: TLS, socket, event loop, and an HTTPS call to a proxy-auth'd Modal
   endpoint wrapping `run_prime_agent`.

Step 4 reintroduces a credential the in-Modal bot did not need — a Modal proxy
auth token on whatever box holds the socket — because the caller is genuinely
external this time.

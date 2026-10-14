<div align="center">

# NG-Opus-Gateway

### NG's free gateway — **Limited time only**

**One command. Then pick a client — Claude, Codex, Antigravity, or DSH —
and it installs, wires itself to the model, and hands you the API key.**

</div>

---

## What this is

A self-hosted gateway that exposes **`claude-sonnet-5-5`** to any OpenAI- or
Anthropic-compatible coding client on your machine. You run one command; it
sets up the gateway, asks which client you use, installs that client if you
don't already have it, connects it to the model, and prints the base URL and
API key.

It runs entirely on your own machine. No account, no sign-up, no dashboard —
and no keys to paste. The installer asks you for nothing.

> 🧠 **1,000,000-token context.** The gateway advertises a 1M context window to
> every client, so your coding sessions stay intact across large codebases and
> long refactors. (See "How requests are normalized" for what happens on the
> rare occasion a conversation outgrows it.)

> ⏳ **Limited time only.** This is a free, capacity-sharing gateway. When the
> upstream allowance is exhausted, it stops working. Enjoy it while it lasts.

## Quick start

Copy **one** line into your terminal. That's the whole setup.

**macOS**

```bash
curl -fsSL https://raw.githubusercontent.com/nidhish28guhan-netizen/NG-Opus-Gateway/main/install.sh | bash
```

**Windows (PowerShell)**

```powershell
irm https://raw.githubusercontent.com/nidhish28guhan-netizen/NG-Opus-Gateway/main/install.ps1 | iex
```

The installer will:

1. Download itself into `~/.ng-opus-gateway` (or `%USERPROFILE%\.ng-opus-gateway` on Windows)
2. Discover the model from the provider automatically — it asks you for **nothing**
3. Build an isolated Python environment and start the gateway on port `4002`
4. Ask which client to use:

```
   1) Claude Code
   2) Codex
   3) Antigravity
   4) DeepSeek Harness (DSH)
   5) All of the above
```

5. **Install** that client if it isn't already on your machine
6. **Wire** the model into it automatically
7. Print your base URL and API key

At the end you'll see something like:

```
  Base URL    http://127.0.0.1:4002
  LAN URL     http://192.168.x.x:4002  (other devices on your Wi-Fi)
  API key     NG-Claude-Anthropic
  Model       claude-sonnet-5-5
```

The gateway is set to auto-start on login, so after the first run you never
touch it again.

## Use it from another device

The gateway listens on `0.0.0.0:4002`, so any machine on the same Wi-Fi can
reach it. Use the **LAN URL** from the installer's output instead of
`127.0.0.1` — never `127.0.0.1` from a *different* machine, that points at
itself.

Point any OpenAI-compatible client at:

| Field | Value |
|---|---|
| Base URL | `http://<gateway-machine-ip>:4002/v1` |
| API key | `NG-Claude-Anthropic` |
| Model | `claude-sonnet-5-5` |
| Context | **1,000,000 tokens** |

Only the API key gates access — anyone on your Wi-Fi who has it can use the
gateway. Change `NG_GATEWAY_KEY` in `scripts/gateway.env` if you need to.

## What the installer wires up

| Client | How it's wired |
|---|---|
| **Claude Code** | installs via npm, writes `~/.claude/settings.json` (`ANTHROPIC_BASE_URL` + token) |
| **Codex** | installs via npm, writes `~/.codex/config.toml` with a custom provider |
| **Antigravity** | writes `~/.antigravity/settings.json`; the app is a manual download if absent |
| **DeepSeek Harness** | writes the `ng-gateway` provider route into the desktop profile |

For the two CLIs the installer is fully automatic. For the two GUI apps it
writes the config and tells you where it went — the app itself is a manual
download, because GUI apps can't be installed from a terminal reliably.

If a client doesn't pick up the written config, add a **custom OpenAI-compatible
provider** inside that app using the base URL and API key the installer printed.

## Requirements

- macOS or Windows
- Python 3.10+ (`python3` / `python`)
- **Node/npm** — only needed if you want the Claude Code or Codex CLIs installed

## Managing the gateway

**macOS**

```bash
cd ~/.ng-opus-gateway
./scripts/start-gateway.sh status     # running?
./scripts/start-gateway.sh logs       # tail the log
./scripts/start-gateway.sh stop       # stop
./scripts/start-gateway.sh restart    # restart
```

**Windows**

```powershell
cd $env:USERPROFILE\.ng-opus-gateway
.\scripts\start-gateway.ps1 -Status
.\scripts\start-gateway.ps1 -Logs
.\scripts\start-gateway.ps1 -Stop
```

## The upstream credentials

- This is a **free gateway**: the upstream key is committed in
  [`gateway/upstream.env`](gateway/upstream.env) so the whole thing runs with
  zero setup. Just run the one command and pick a client.
- It is **limited time** — the key can be rotated or revoked, and the gateway
  stops working when it does. That is by design.
- Forking? Replace the values in `gateway/upstream.env` with your own provider
  key, or drop a local `scripts/gateway.env` (git-ignored) to override it.

## How requests are normalized

The upstream behind this gateway is picky and rejects several otherwise-valid
requests with a bare `{"message":"Invalid request"}`. `gateway/ng_hook.py` runs
before every upstream call and fixes them:

1. **Reasoning tier** — clients send a thinking budget that maps to a tier the
   upstream refuses. The hook rewrites it to an accepted tier, and also rewrites
   the underlying thinking block, because the tier label is derived *after* the
   hook runs.
2. **Context overflow** — the upstream's 262,144-token budget covers input
   **and** output combined. A client sending the whole conversation plus a huge
   `max_completion_tokens` overflows it. The hook trims the oldest messages and
   caps the output budget so the sum always fits.

On long conversations this means the oldest messages are dropped and replies
get shorter. Start a fresh session to restore the full budget.

## Contact

Something broke, or the gateway stopped responding? Report it:

**<nidhish28guhan123@gmail.com>**

Send the error text, the client you were using, and the output of
`./scripts/start-gateway.sh logs` (macOS) or `.\scripts\start-gateway.ps1 -Logs`
(Windows). The more of that you include, the faster it gets fixed.

## License

MIT — see [LICENSE](LICENSE).

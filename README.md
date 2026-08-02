# aitext

[![ci](https://github.com/Ninodevo/aitext/actions/workflows/ci.yml/badge.svg)](https://github.com/Ninodevo/aitext/actions/workflows/ci.yml)

AI text transforms on a keyboard shortcut, anywhere in macOS.

Select text in any app, press **⇧⌃G**, and the selection is replaced by a corrected version. ⌘Z undoes it as a single edit. Fifteen transforms ship by default — fix grammar, rewrite clearer, shorten, translate, summarize, draft a reply, or press ⇧⌃I and type any instruction on the spot — and adding your own takes one command.

No menu-bar app, no background daemon, no Electron. Each hotkey is a native macOS Quick Action that pipes your selection through a shell script and writes the result back.

![demo](docs/demo.gif)

The same engine drives the hotkeys: select text in any app, press ⇧⌃G, and the selection is replaced in place — ⌘Z undoes it as one edit.

## Install

Requires macOS, [`jq`](https://jqlang.github.io/jq/) (`brew install jq`), and an [OpenAI API key](https://platform.openai.com/api-keys).

```bash
git clone https://github.com/Ninodevo/aitext.git
cd aitext
./install.sh
```

The installer checks prerequisites, writes the commands and prompts, builds all the Quick Actions, assigns the shortcuts, prompts you for your API key in a native secure-input dialog, and finishes with a live API call to prove it works end to end.

Your key goes to the **login Keychain** — never to a file in this repo, never to a dotfile, never into `ps` output. Re-running the installer is safe: prompts you've edited are kept unless you pass `--force`.

```bash
./install.sh --no-shortcuts   # don't touch keyboard shortcuts
./install.sh --no-key         # skip the key step
./install.sh --force          # overwrite edited prompts with the defaults
./install.sh --uninstall      # remove everything (keeps your prompts + key)
```

## The hotkeys

All shortcuts are **Shift + Control + letter**.

| Keys | Transform | Effect on your selection |
|---|---|---|
| ⇧⌃G | Fix grammar and spelling | replaced |
| ⇧⌃R | Rewrite clearer and tighter | replaced |
| ⇧⌃K | Shorten to ~half | replaced |
| ⇧⌃O | Make formal | replaced |
| ⇧⌃C | Make casual | replaced |
| ⇧⌃U | Convert to bullets | replaced |
| ⇧⌃D | Expand notes into prose | replaced |
| ⇧⌃J | **Translate (smart)** — EN→HR, anything else→EN | replaced |
| ⇧⌃T | Translate to English | replaced |
| ⇧⌃H | Translate to Croatian | replaced |
| ⇧⌃M | Commit message from a diff | replaced |
| ⇧⌃S | Summarize | **appends** a TL;DR, keeps the original |
| ⇧⌃Y | Draft a reply | **copies to clipboard**, selection untouched |
| ⇧⌃X | Explain this | **shows a dialog**, selection untouched |
| ⇧⌃I | **Ask** — type any instruction in a dialog | replaced |
| ⇧⌃L | **Clipboard** — pick a transform, run it on the clipboard | clipboard in, clipboard out |

macOS reserves seven ⇧⌃ letters for text selection — **A B E F N P V** — so avoid those when adding your own. (Source: `StandardKeyBinding.dict` in AppKit.)

## Commands

```bash
aitext-prompts                              # list every mode: model, output, prompt
aitext-prompts doctor                       # live-test every mode against its API
aitext-prompts edit grammar                 # open a prompt in $EDITOR
aitext-prompts test grammar                 # run sample text through it, see before/after
aitext-prompts set tldr model gpt-5.4-mini  # change one front-matter key
aitext-prompts new harsh "AI Make Blunt" shift+ctrl+j
aitext-prompts rm harsh

aitext-keys                                 # list shortcut bindings
aitext-keys set grammar shift+ctrl+j        # also accepts ⇧⌃J, ctrl-shift-j, '$^j'
aitext-keys unset explain

aitext-config                               # settings and where each came from
aitext-config sounds off                    # silence the audio cues
aitext-config test                          # hear them

aitext-log                                  # recent transforms (undo beyond ⌘Z)
aitext-log restore 1                        # put the latest ORIGINAL on the clipboard
aitext-log stats                            # per-mode calls, tokens, estimated cost
aitext-config set history off               # stop logging transforms

echo "some text" | aitext grammar                    # the dispatcher, standalone
echo "notes" | AITEXT_INSTRUCTION="to haiku" aitext ask   # scripted ask
```

## Writing prompts

Each transform is a markdown file in `~/.config/aitext/prompts/`. Front matter, then `---`, then the system prompt:

```markdown
model: gpt-5.4-nano
temperature: 0
---
You are a copy editor. Fix spelling, grammar, and punctuation. Keep the
author's voice — do not rewrite phrasing that is already correct.
```

| Key | Values | Default |
|---|---|---|
| `provider` | `openai`, `anthropic` | `openai` |
| `model` | a model id, or the aliases `cheap` / `smart` (retarget every aliased prompt at once: `aitext-config set model_smart …`) | `cheap` |
| `temperature` | `0`–`2`, OpenAI only; omit to use the API default | omitted |
| `output` | `replace`, `append`, `clipboard`, `notify`, `confirm` (preview + approve before replacing) | `replace` |
| `sounds` | `on`, `off` — overrides the global setting | inherits |
| `base_url` | any OpenAI-compatible endpoint (see below) | config / api.openai.com |
| `ask` | a question — makes the mode interactive: a dialog collects the instruction at invocation time | — |

Edits take effect on the next keypress — no reinstall. Every prompt gets this appended automatically, so you never repeat it:

> Return ONLY the resulting text. No preamble, no explanation, no surrounding quotes, no code fences. Preserve the input language, line breaks, markdown, code blocks, URLs and proper nouns.

**If a transform reports "no changes":** the model genuinely returned your text unchanged — the pipeline ran fine. Cheap models play it safe on badly garbled input (`gpt-5.4-nano` will capitalize `this a boea sstong` but won't guess at the broken words). Point that prompt at a stronger model if you want more: `aitext-prompts set grammar model gpt-5.6-luna`.

**A model gotcha worth knowing:** some models reject a non-default `temperature` (`gpt-5.6-luna` is one). If a transform silently returns your text unchanged with an alert about temperature, delete the `temperature:` line.

## Adding a transform

```bash
aitext-prompts new harsh "AI Make Blunt" shift+ctrl+j
aitext-prompts edit harsh
aitext-prompts test harsh "I was sort of wondering if maybe we could revisit this?"
```

That writes the prompt file, registers the Quick Action, binds the shortcut, and records it in `~/.config/aitext/hotkeys.conf` so a reinstall reproduces it.

## The clipboard service (⇧⌃L)

Text Services need a selection, and a few apps (some Electron apps, some browser fields) don't implement them properly. **⇧⌃L works anywhere**: it shows a chooser with every transform and runs the one you pick on the **clipboard**, writing the result back to the clipboard. Copy → ⇧⌃L → paste. Also scriptable: `aitext-clip grammar`.

## Cost

`aitext-log stats` shows your actual per-mode token usage and estimated spend. Roughly, for a 200-word paragraph in and out (~350 input / ~270 output tokens):

| Model | $/1M in / out | Per press | At 50/day |
|---|---|---|---|
| `gpt-5.4-nano` | $0.20 / $1.25 | $0.0004 | $0.62/mo |
| `gpt-5.6-luna` | $1 / $6 | $0.0020 | $3.05/mo |
| `claude-haiku-4-5` | $1 / $5 | $0.0017 | $2.55/mo |

Nothing here is expensive enough to choose on price. Choose on instruction-following instead: the failure that actually costs you is a model ignoring "return only the text" and pasting *"Here's the corrected version:"* into your document.

## Local models (optional)

Any OpenAI-compatible server works — Ollama, LM Studio, OpenRouter. Point one prompt at it:

```
base_url: http://localhost:11434/v1
model: llama3.1
---
Fix spelling and grammar. Change nothing else.
```

…or move every OpenAI-provider prompt at once:

```bash
aitext-config set openai_base_url http://localhost:11434/v1
```

With a custom endpoint no API key is required — your text never leaves the Mac. Run `aitext-prompts doctor` afterwards to confirm every mode still works.

## History

Every transform is logged to `~/.local/state/aitext/history.jsonl` (capped ~200 entries) so you can recover the original after ⌘Z is long gone: `aitext-log`, `aitext-log restore <n>`. **The log stores your text in plain text** — if you transform sensitive material, turn it off with `aitext-config set history off`.

## Anthropic (optional)

`explain` uses Claude. Add a key, or point the prompt at OpenAI instead:

```bash
security add-generic-password -s ANTHROPIC_API_KEY -a "$USER" -w 'sk-ant-...' -U
```

## How it works

- **Quick Actions are generated, not clicked.** A macOS Service is just a `.workflow` directory with `Info.plist` and `document.wflow`. `aitext-service` writes both directly — Automator.app is never involved.
- **Shortcuts are written to `~/Library/Preferences/pbs.plist`** under `NSServicesStatus`, keyed `"(null) - <Menu Name> - runWorkflowAsService"`, then flushed with `pbs -flush`. The installer backs the file up first.
- **`~/.config/aitext/hotkeys.conf` is the source of truth.** The installer seeds it once and reads it forever after; `aitext-prompts new/rm` keeps it in sync, so a mode you add by hand survives a reinstall.
- **Failures never damage your text.** Missing key, API error, network failure, empty response — each shows an alert explaining why and writes your original selection back unchanged. A copy also lands in `~/.local/state/aitext/last-input.txt`.
- **`install.sh` is generated** from `bin/`, `prompts/` and `hotkeys.conf` by `tools/build-installer.py`, so a fresh Mac needs exactly one file. Edit the sources, then rebuild:

```bash
./tools/build-installer.py
```

## Troubleshooting

**A shortcut does nothing.** Right-click the selection → Services. If the item is there and works, the app has its own binding on that key — pick another with `aitext-keys set <mode> <combo>`.

**Nothing appears under Services at all.** `/System/Library/CoreServices/pbs -flush`, then log out and back in. Electron apps (Slack, VS Code, Notion) cache the Services list longest.

**The text comes back unchanged with an alert.** That's the safety net. The alert says why — usually a missing key, a model your account can't reach, or a `temperature` the model rejects. `aitext-prompts doctor` tests every mode in one go.

**`jq not found`.** `brew install jq`. The dispatcher hardcodes a PATH because Automator runs with a minimal one.

## License

MIT — see [LICENSE](LICENSE).

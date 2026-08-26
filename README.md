# Text Transform

Paste text, pick a transformation, get the result back. Fix the grammar, make it shorter, translate it, rewrite it for work email — whatever you have written a prompt for.

The work is done by the coding agent you have already set up in Omarchy, through `omarchy default agent`. There is no API key to enter, no model to pick and no account to make: if `omarchy agent` starts something on your machine, this widget uses it.

## How it works

Type or paste into the top box, choose a transformation, and press the arrow (or Ctrl+Enter). The answer lands in the bottom box with a button to copy it.

A transform takes a few seconds. You do not have to sit and watch it: close the panel and carry on, and the arrows in the bar stay lit while the agent works. When the answer lands you get a notification, the icon stays lit, and the text is waiting in the panel next time you open it. The notification says only that it finished — your text stays out of it.

A transformation is just a name and a prompt. The name is what the dropdown shows; the prompt is what the agent is told to do with your text. Press the gear to edit them, add your own, or throw out the ones you never use.

Six come with it: fix grammar, make it shorter, make it longer, translate to English, make it professional, explain simply. They are a starting point, not the point — the plugin is worth having because you can write "rewrite this as a commit message" or "turn this into Dutch that does not read like a translation" and have it a keypress away.

## Requirements

- Omarchy Quattro (4.x)
- A default agent: `omarchy default agent claude` (or `codex`, `opencode`, `crush`, `pi`, `omp`, `grok`, `agy`, `copilot`, `ori`)
- `jq`, and `wl-copy` for the copy button — both standard on Omarchy

If no default agent is set, the panel says so instead of failing quietly.

## Supported agents

Every agent Omarchy offers has a non-interactive mode, and this plugin drives each one through its own:

| Agent | Runs as | Text goes in via |
| --- | --- | --- |
| Claude Code | `claude -p` | stdin |
| Codex | `codex exec --sandbox read-only` | stdin |
| OpenCode | `opencode run --format json` | stdin |
| Crush | `crush run -q` | stdin |
| Pi | `pi -p --no-tools` | stdin |
| Oh My Pi | `omp -p --no-tools` | stdin |
| Ori | `ori claude -p` (or `ori pi -p`) | stdin |
| Grok | `grok -p` | argument |
| Antigravity | `agy --sandbox -p` | argument |
| GitHub Copilot | `copilot -p --allow-all-tools` | argument |

Grok, Antigravity and Copilot have no way to take a prompt on stdin, so with those three your text is briefly visible in the process list to other accounts on the machine. The other seven never put it there. If that matters on your machine, pick one of the seven.

Ori is a launcher rather than an agent, so it needs Claude Code or Pi installed to have something to launch.

## Your text and the agent

The text is handed to the agent as one prompt, and the agent is told to treat everything between the markers as text rather than as instructions. That is not a guarantee — a language model can be talked into things — so the plugin narrows what an agent could do if it were:

- Every run happens in a fresh empty directory, so there is no project for the agent to read or write.
- Tools are switched off wherever the agent supports it (`--no-tools`, `--disallowedTools`, `--sandbox read-only`).
- Copilot's non-interactive mode insists on `--allow-all-tools`, so its shell and write tools are denied by name instead.

Text you paste is still sent to whatever service your agent talks to, and counted against your plan there. That is the trade: no key to configure, but also no local-only mode.

## Installing

```bash
omarchy plugin add https://github.com/jankeesvw/omarchy-text-transform
omarchy plugin enable jankeesvw.text-transform
omarchy bar move jankeesvw.text-transform --section right
```

A keybinding, if you want one:

```lua
o.bind("SUPER + T", "Text Transform", "omarchy-shell shell toggle jankeesvw.text-transform")
```

## Removing it

```bash
omarchy plugin remove jankeesvw.text-transform
```

That leaves one thing behind: the transformations you wrote, in `~/.config/omarchy-text-transform/transformations.json` (the directory is mode 700, the file 600, and only your account can read them). Nothing else is stored — the text you transform and the answers you get are never written to disk by this plugin. To delete the prompts too:

```bash
rm -rf ~/.config/omarchy-text-transform
```

## The script on its own

`bin/text-transform` works without the panel, which is handy for a keybinding or a script of your own. Everything goes in and out as JSON on stdin and stdout:

```bash
bin/text-transform agent
bin/text-transform list

printf '%s' '{"text":"hallo wereld","prompt":"Translate to English."}' \
  | bin/text-transform run
```

## Licence

MIT

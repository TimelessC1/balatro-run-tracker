# Run Tracker

A Balatro mod that records every run you finish and uploads it to a shared
leaderboard at
**[balatro-run-tracker.timelessc.workers.dev](https://balatro-run-tracker.timelessc.workers.dev)**,
where you can browse and filter everyone's runs.

It changes nothing about how the game plays. It only reads the run once it is
over.

## Install

1. Install [Lovely Injector](https://github.com/ethangreen-dev/lovely-injector)
   and [Steamodded](https://github.com/Steamodded/smods) first.
2. Download `RunTracker.zip` from
   [Releases](../../releases) and unzip it into your mods folder, so that you
   end up with `Mods/RunTracker/`:

   | System  | Mods folder |
   |---------|-------------|
   | Windows | `%APPDATA%\Balatro\Mods` |
   | macOS   | `~/Library/Application Support/Balatro/Mods` |
   | Linux   | `~/.local/share/Balatro/Mods` (or the Proton prefix) |

3. Start the game. That's it, there is nothing to configure.

## What gets recorded

For every finished run:

- Seed, win or loss, the ante and round you reached
- The blind you were on, its target, your score against it and the percentage
- Deck, stake, best hand, hands played, skips, money
- Every joker you were holding: name, edition, what it was contributing, and
  its **eternal / perishable / rental** stickers

Runs that include jokers from other mods are skipped, so the leaderboard only
compares base-game play.

## Your name on the board

You appear as a name plus a four-digit tag, like `TimelessC1#3665`. The tag is
generated once and never changes, so two players called the same thing don't
get mixed up.

The name is, in order: whatever you type in the config, your Steam name, your
Balatro profile name, or `Anonymous`. Change it in **Mods > Tracker > Config**.

## Privacy

- Your **SteamID is not sent**. What identifies you is `user_code`, a hash of
  it, which cannot be turned back into your account.
- Uploading can be switched off in the config tab. Runs are still saved
  locally.
- Your name tag and user code live in `run_tracker_identity.txt` in your
  Balatro save folder, so they survive reinstalling the mod. Delete that file
  and you become a new player.

## Local files

The mod writes these to your Balatro save folder:

| File | What it is |
|------|------------|
| `run_tracker_results.txt` | One readable line per run (see `example_results.txt`) |
| `run_tracker_log.jsonl` | The raw payload of every run, as a backup |
| `run_tracker_pending.jsonl` | Runs whose upload failed; retried on next launch |
| `run_tracker_identity.txt` | Your user code and name tag |

A failed upload is never lost: it is queued and retried when you next start the
game. Requests the server actively rejects are not retried, but the raw payload
is still in `run_tracker_log.jsonl`.

## Running your own server

Point the mod somewhere else by creating `RunTracker/settings.lua`:

```lua
return {
    endpoint = "https://your-worker.workers.dev/run",
    token    = "",        -- only if your server sets INGEST_TOKEN
}
```

Any value you leave out falls back to the default in `main.lua`. The file is
optional and is not shipped with the mod.

The endpoint receives a `POST` with a JSON body per run, and the seed button
asks for `GET /api/seeds/unbeaten?user_code=...`, expecting `{"seed":"XXXXXXXX"}`.

## Requirements

- Balatro 1.0.1
- Lovely Injector
- Steamodded 1.x

## License

MIT. See [LICENSE](LICENSE).

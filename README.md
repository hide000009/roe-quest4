# ROE Quest4

A [Windower](https://www.windower.net/) addon for **Final Fantasy XI** that accepts all 15 **Records of Eminence: Quest 4 — "Peculiar Foes"** （珍妙なモンスターを討伐せよ！ 1–15) objectives at once.

These are the monthly objectives that reward an A.M.A.N. Trove silver voucher （互助会引換券・銀） each. Re-accepting all 15 by hand every month is tedious — this addon does it with one command.

## Features

- One command accepts all 15 objectives (0.5s spacing, respects the 30-objective active limit)
- The 15 quest IDs (3789–3803) are built in — no setup, no learning step, works on every character and client as-is
- English chat messages (pure ASCII file, no encoding issues on the JP client)

## Install

1. Copy the `roe_quest4` folder into your Windower addons folder:
   `Windower4/addons/roe_quest4/roe_quest4.lua`
2. In game:
   ```
   //lua load roe_quest4
   ```

Requires the `packets` and `config` libraries that ship with Windower.

## Usage

```
//roe4 set        Accept all 15 quests on this character
//roe4 list       Show the quest IDs and which are currently active
//roe4 help       Show all commands
```

Other commands: `setall` (ask all clients to set at once — needs Windower IPC between your clients), `learn` / `add <id>` / `remove <id>` / `clear` (manage the ID list; not needed normally, the IDs are built in), `sync`, `ping`.

## How it works

Same method as the official ROE addon: accepting an objective is an outgoing `0x10C` packet carrying the quest ID, and the active objective list (max 30) arrives in incoming `0x111` packets. The addon only sends accepts for quests that are not already active, and stops with a warning if there are not enough free objective slots.

## Notes

- The quest IDs are the same for every character, so one copy of the file works for all your accounts.
- Tested by the author on the JP client with 6 characters.

## License

MIT — see [LICENSE](LICENSE).

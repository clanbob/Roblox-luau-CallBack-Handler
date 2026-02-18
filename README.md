# CallBack (Luau)

A mutation-safe callback dispatcher for Roblox/Luau.

This module supports three dispatcher styles:

1. **Global dispatcher** (`CallBack.New()`)
2. **Per-player dispatcher** (`CallBack.NewByPlayer()`, server-only)
3. **Per-instance dispatcher** (`CallBack.NewByInstance()`) 

---

## Installation

```lua
local CallBack = require(path.To.CallBack)
```

---

## Quick Start

### Global dispatcher

```lua
local Events = CallBack.New()

local connection = Events:Listen("Damage", false, function(amount, source)
	print("Damage:", amount, "from", source)
end)

Events:Fire("Damage", 25, "Trap")

connection:Disconnect()
Events:Destroy()
```

### Per-player dispatcher (server only)

```lua
local PlayerEvents = CallBack.NewByPlayer()

PlayerEvents:Listen(player, "InventoryUpdated", false, function(itemName)
	print(player.Name, "updated item", itemName)
end)

PlayerEvents:Fire(player, "InventoryUpdated", "Sword")
```

### Per-instance dispatcher

```lua
local InstEvents = CallBack.NewByInstance()

InstEvents:Listen(part, "Touched", false, function(hit)
	print("Part touched by", hit.Name)
end)

InstEvents:Fire(part, "Touched", workspace.Baseplate)
```

---

## API

### `CallBack.New()`
Creates a global dispatcher.

### `:Listen(caller_id: string, once: boolean, callback: (...any) -> ()) -> Listener`
Registers a listener for `caller_id`.

- `caller_id`: channel/group key
- `once`: if `true`, listener disconnects before first execution
- `callback`: function to run on fire

### `:Fire(caller_id: string, ...any)`
Dispatches all active listeners registered to `caller_id`.

### `:Destroy()`
Destroys all listeners and batches for this dispatcher.

---

### `CallBack.NewByPlayer()` (server only)
Creates a player-scoped dispatcher. Internally cleans up when `Players.PlayerRemoving` fires.

### `:Listen(player: Player, caller_id: string, once: boolean, callback: (...any) -> ()) -> Listener`
Registers a listener under one player + caller group.

### `:Fire(player: Player, caller_id: string, ...any)`
Fires listeners for a specific player and caller group.

### `:GetRegistered(player: Player)`
Returns the internal registry object for that player (if present).

### `:Destroy()`
Destroys all player registries and listeners.

---

### `CallBack.NewByInstance()`
Creates an instance-scoped dispatcher. By default, each instance registry auto-cleans on `Instance.Destroying`.

### `:Listen(instance: Instance, caller_id: string, once: boolean, callback: (...any) -> ()) -> Listener`
Registers a listener under one instance + caller group.

### `:Fire(instance: Instance, caller_id: string, ...any)`
Fires listeners for a specific instance and caller group.

### `:GetRegistered(instance: Instance)`
Returns the internal registry object for that instance (if present).

### `:UseCustomDestroyEventForInstance(instance: Instance, lock: boolean, event: RBXScriptSignal)`
Overrides cleanup signal for a specific instance.

- `instance`: registry owner
- `lock`: if `true`, the destroy event cannot be replaced later
- `event`: signal that triggers registry destruction

> Not available for `NewByPlayer()`; calling this for player dispatchers raises an error.

### `:Destroy()`
Destroys all instance registries and listeners.

---

## Listener object

Returned by every `:Listen(...)` call.

### `connection:Disconnect()`
Disconnects the listener.

### `connection:Fire(...any)`
Executes that specific listener callback asynchronously.

---

## Behavior guarantees

- Safe disconnect during fire cycles.
- Listeners added during an active `:Fire()` are queued for the next cycle.
- `once = true` listeners auto-disconnect before running.
- Callback execution is asynchronous (`task.spawn` via a shared runner coroutine).
- Callback errors are wrapped and surfaced with traceback via `warn`.

---

## Notes

- `CallBack.NewByPlayer()` should only be used on the server. If called on the client, the module warns and returns `nil`.
- Legacy aliases are still available: `NewByIstance` and `UseCustomDestroyEventForIstance`.

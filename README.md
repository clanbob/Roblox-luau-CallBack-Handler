# CallBack (Luau)

A mutation-safe callback dispatcher for Roblox/Luau projects.

This module gives you a consistent event-listener pattern with support for:

- **Global groups** (`CallBack.New()`)
- **Per-player groups** (`CallBack.NewByPlayer()`, server-only)
- **Per-instance groups** (`CallBack.NewByInstance()`)

It is designed to be safe when listeners are connected/disconnected while events are firing, and to automatically clean up instance/player-scoped registries.

---

## Table of contents

- [Installation](#installation)
- [Core concepts](#core-concepts)
- [Quick start](#quick-start)
- [API reference](#api-reference)
  - [`CallBack.New()`](#callbacknew)
  - [`CallBack.NewByPlayer()`](#callbacknewbyplayer-server-only)
  - [`CallBack.NewByInstance()`](#callbacknewbyinstance)
  - [Listener object](#listener-object)
- [Behavior details](#behavior-details)
- [Lifecycle and cleanup](#lifecycle-and-cleanup)
- [Best practices](#best-practices)
- [Troubleshooting](#troubleshooting)

---

## Installation

```lua
local CallBack = require(path.To.CallBack)
```

---

## Core concepts

### 1) Dispatcher
A dispatcher is the object returned by one of the factory methods:

- `CallBack.New()`
- `CallBack.NewByPlayer()`
- `CallBack.NewByInstance()`

You register callbacks on a dispatcher with `:Listen(...)` and trigger them with `:Fire(...)`.

### 2) Caller ID
`caller_id` is a string channel key (for example: `"Damage"`, `"InventoryUpdated"`, `"MatchEnded"`).

Listeners are grouped by this key, and only listeners in the same group are triggered by that key.

### 3) Listener connection
Every `:Listen(...)` call returns a **Listener** object. You can:

- stop it with `connection:Disconnect()`
- manually execute its callback with `connection:Fire(...)`

---

## Quick start

### Global dispatcher

```lua
local Events = CallBack.New()

local damageConnection = Events:Listen("Damage", false, function(amount, source)
	print("Took", amount, "damage from", source)
end)

Events:Fire("Damage", 25, "Trap")

damageConnection:Disconnect()
Events:Destroy()
```

### Per-player dispatcher (server only)

```lua
local PlayerEvents = CallBack.NewByPlayer()

local invConn = PlayerEvents:Listen(player, "InventoryUpdated", false, function(itemName)
	print(player.Name, "updated:", itemName)
end)

PlayerEvents:Fire(player, "InventoryUpdated", "Sword")
invConn:Disconnect()
```

### Per-instance dispatcher

```lua
local InstEvents = CallBack.NewByInstance()

InstEvents:Listen(part, "Touched", false, function(hit)
	print("Touched by", hit.Name)
end)

InstEvents:Fire(part, "Touched", workspace.Baseplate)
```

### One-time listener

```lua
local Events = CallBack.New()

Events:Listen("RoundStart", true, function()
	print("Runs only once")
end)

Events:Fire("RoundStart") -- runs callback
Events:Fire("RoundStart") -- does nothing (already disconnected)
```

---

## API reference

## `CallBack.New()`
Creates a global dispatcher.

### `:Listen(caller_id: string, once: boolean, callback: (...any) -> ()) -> Listener`
Registers a listener inside the `caller_id` group.

- `caller_id`: event/group key
- `once`: if `true`, disconnects before first execution
- `callback`: function to execute

### `:Fire(caller_id: string, ...any)`
Fires all active listeners for `caller_id`.

### `:Destroy()`
Destroys all listener groups and releases this dispatcher.

---

## `CallBack.NewByPlayer()` (server only)
Creates a player-scoped dispatcher.

### Server behavior
- Automatically hooks `Players.PlayerRemoving`
- Cleans all registries/listeners for the leaving player

### `:Listen(player: Player, caller_id: string, once: boolean, callback: (...any) -> ()) -> Listener`
Registers a listener for a specific player + caller group.

### `:Fire(player: Player, caller_id: string, ...any)`
Fires listeners for that player and caller group.

### `:GetRegistered(player: Player)`
Returns the internal registry object for that player (if registered).

### `:Destroy()`
Destroys all player registries managed by this dispatcher.

> If `CallBack.NewByPlayer()` is called on a client, the module warns and returns `nil`.

---

## `CallBack.NewByInstance()`
Creates an instance-scoped dispatcher.

Each instance gets its own registry under the dispatcher.

### Default cleanup
By default, instance registries auto-clean on `instance.Destroying`.

### `:Listen(instance: Instance, caller_id: string, once: boolean, callback: (...any) -> ()) -> Listener`
Registers a listener for a specific instance + caller group.

### `:Fire(instance: Instance, caller_id: string, ...any)`
Fires listeners for that instance and caller group.

### `:GetRegistered(instance: Instance)`
Returns the internal registry object for that instance (if registered).

### `:UseCustomDestroyEventForInstance(instance: Instance, lock: boolean, event: RBXScriptSignal)`
Overrides the destroy signal used to clean that instance registry.

- `instance`: registry owner
- `lock`: when `true`, prevents replacing this destroy signal later
- `event`: signal that triggers registry destruction

> This API is not valid for player dispatchers (`NewByPlayer()`).

### `:Destroy()`
Destroys all instance registries managed by this dispatcher.

---

## Listener object

Returned from any `:Listen(...)` call.

### `connection:Disconnect()`
Disconnects the listener.

### `connection:Fire(...any)`
Executes only that listener’s callback asynchronously.

---

## Behavior details

The module guarantees:

- **Mutation-safe firing**: listeners can disconnect while firing without corrupting iteration.
- **Pending-listener semantics**: listeners added during a `:Fire()` cycle are queued for the next cycle.
- **Once semantics**: `once = true` listeners disconnect before executing.
- **Async execution**: callbacks run asynchronously via `task.spawn`.
- **Error tracing**: callback errors are wrapped with traceback and warned.

---

## Lifecycle and cleanup

### Global dispatcher
- Manual lifecycle with `:Destroy()`.

### Player dispatcher
- Auto-clean by `PlayerRemoving`.
- Can still be manually destroyed with `:Destroy()`.

### Instance dispatcher
- Auto-clean by `Destroying` (or custom signal if configured).
- Can still be manually destroyed with `:Destroy()`.

---

## Best practices

- Use clear `caller_id` naming conventions (e.g. `"Combat.Damage"`, `"UI.Open"`).
- Keep callbacks small and fast; hand off heavy work to other tasks/systems.
- Save listener handles and disconnect when no longer needed.
- Prefer one dispatcher per system/domain rather than one giant global dispatcher.

---

## Troubleshooting

### Callback didn’t run
Check all of the following:
- `caller_id` matches exactly between `:Listen()` and `:Fire()`.
- You are firing on the same dispatcher instance where listener was registered.
- Listener was not already disconnected (`once = true` or manual `Disconnect()`).

### `NewByPlayer()` returned nil
You are likely calling it on a client. Create player dispatchers on the server only.

### Custom destroy event not replacing
If lock is true for that registry (`lock_event`), later replacements are ignored.

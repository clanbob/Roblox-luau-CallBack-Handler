# CallBack (Luau)

A mutation-safe callback/event dispatcher for Roblox Luau.

`CallBack` gives you a predictable way to register listeners, fire grouped events, and clean up listener state for:

- Global scopes (`CallBack.New()`)
- Player scopes (`CallBack.NewByPlayer()`)
- Instance scopes (`CallBack.NewByInstance()`)

This module is specifically designed to stay stable when listeners are added/removed while events are firing.

---

## Table of contents

- [Install](#install)
- [When to use this module](#when-to-use-this-module)
- [Mental model](#mental-model)
- [Quick start](#quick-start)
- [API reference](#api-reference)
  - [Global dispatcher (`New`)](#global-dispatcher-new)
  - [Player dispatcher (`NewByPlayer`)](#player-dispatcher-newbyplayer)
  - [Instance dispatcher (`NewByInstance`)](#instance-dispatcher-newbyinstance)
  - [Listener object](#listener-object)
- [Execution semantics](#execution-semantics)
- [Cleanup semantics](#cleanup-semantics)
- [Common patterns](#common-patterns)
- [Troubleshooting](#troubleshooting)
- [Performance notes](#performance-notes)

---

## Install

```lua
local CallBack = require(path.To.CallBack)
```

---

## When to use this module

Use `CallBack` when you want:

- **Grouped events** by string keys (`caller_id`)
- **Safe mutation during dispatch** (disconnect/subscribe while firing)
- **Scoped registries** by player or instance
- **Automatic cleanup** tied to player leaving or instance destroy signals

If you only need a single static callback with no lifecycle concerns, native `RBXScriptSignal` usage may be enough.

---

## Mental model

There are 4 core concepts:

1. **Dispatcher**: object returned by `New`, `NewByPlayer`, or `NewByInstance`.
2. **Group key (`caller_id`)**: channel name like `"Combat.Damage"`.
3. **Batch**: internal per-group container of listeners.
4. **Listener**: returned connection object with `Disconnect` and `Fire`.

`Fire` always targets one group (`caller_id`) at a time.

---

## Quick start

### 1) Global

```lua
local Events = CallBack.New()

local damageConn = Events:Listen("Combat.Damage", false, function(amount, source)
	print("Damage:", amount, "from", source)
end)

Events:Fire("Combat.Damage", 20, "Trap")
damageConn:Disconnect()
Events:Destroy()
```

### 2) Per-player (server only)

```lua
local PlayerEvents = CallBack.NewByPlayer()

local xpConn = PlayerEvents:Listen(player, "Progress.XP", false, function(amount)
	print(player.Name, "gained xp", amount)
end)

PlayerEvents:Fire(player, "Progress.XP", 50)
```

### 3) Per-instance

```lua
local InstEvents = CallBack.NewByInstance()

InstEvents:Listen(part, "Interact.Touch", false, function(hit)
	print("Touched by", hit.Name)
end)

InstEvents:Fire(part, "Interact.Touch", workspace.Baseplate)
```

### 4) One-shot listeners

```lua
local Events = CallBack.New()

Events:Listen("Round.Start", true, function()
	print("Runs only once")
end)

Events:Fire("Round.Start")
Events:Fire("Round.Start") -- no-op
```

---

## API reference

## Global dispatcher (`New`)

### `local events = CallBack.New()`
Creates a dispatcher not bound to player/instance ownership.

### `events:Listen(caller_id: string, once: boolean, callback: (...any) -> ()) -> Listener`
Registers one listener under a `caller_id` group.

- `caller_id`: logical event channel
- `once`: if true, disconnects before first callback execution
- `callback`: receives all arguments passed to `Fire`

### `events:Fire(caller_id: string, ...any)`
Fires all listeners in the group.

### `events:Destroy()`
Destroys all groups/listeners in this dispatcher.

---

## Player dispatcher (`NewByPlayer`)

### `local playerEvents = CallBack.NewByPlayer()`
Creates player-scoped registries.

> Server-only: calling on client warns and returns `nil`.

### `playerEvents:Listen(player, caller_id, once, callback) -> Listener`
Registers under `(player, caller_id)`.

### `playerEvents:Fire(player, caller_id, ...any)`
Fires only the specified player’s group.

### `playerEvents:GetRegistered(player)`
Returns the internal registry for that player (if it exists).

### `playerEvents:Destroy()`
Destroys all player registries owned by this dispatcher.

Automatic behavior:
- Hooks `Players.PlayerRemoving`
- Destroys all registries for that player on leave

---

## Instance dispatcher (`NewByInstance`)

### `local instEvents = CallBack.NewByInstance()`
Creates instance-scoped registries.

### `instEvents:Listen(instance, caller_id, once, callback) -> Listener`
Registers under `(instance, caller_id)`.

### `instEvents:Fire(instance, caller_id, ...any)`
Fires only that instance’s group.

### `instEvents:GetRegistered(instance)`
Returns internal registry for the instance.

### `instEvents:UseCustomDestroyEventForInstance(instance, lock, event)`
Overrides the default cleanup signal for that instance registry.

- `instance`: registry owner
- `lock`: if true, prevents future signal replacement
- `event`: `RBXScriptSignal` to trigger registry destroy

### `instEvents:Destroy()`
Destroys all instance registries owned by this dispatcher.

Default behavior:
- each registry cleans on `instance.Destroying`
- custom destroy signals can replace this per registry (unless locked)

---

## Listener object

Returned by every `Listen` call.

### `connection:Disconnect()`
Disconnects listener from its batch.

### `connection:Fire(...any)`
Runs only this callback asynchronously (does not fire the full group).

---

## Execution semantics

The module guarantees these semantics:

- **Mutation-safe firing**: disconnects during `Fire` are safe.
- **Pending listeners**: listeners added mid-fire execute next cycle.
- **`once` correctness**: once listeners disconnect before execution.
- **Async callbacks**: callbacks run via `task.spawn` on a shared runner coroutine.
- **Error reporting**: callback errors are `xpcall` wrapped and warned with traceback.

---

## Cleanup semantics

### Global dispatcher
Manual cleanup only (`Destroy`).

### Player dispatcher
Player removal triggers cleanup for that player registry.

### Instance dispatcher
Each registry owns its destroy hook.

Important detail: destroy hooks are tracked by **registry object**, not only by instance key. This allows separate registries that happen to point to the same instance to keep independent cleanup hooks.

---

## Common patterns

### Namespace your caller IDs
Use clear domains to avoid collisions:

- `"Combat.Damage"`
- `"UI.Menu.Open"`
- `"Quest.Completed"`

### Keep listeners lightweight
If callback work is heavy, queue deeper processing elsewhere.

### Store returned listeners
Always keep connection handles when lifecycle is shorter than dispatcher lifetime.

```lua
local conn = Events:Listen("Tick", false, onTick)
-- ... later
conn:Disconnect()
```

### Prefer scoped dispatchers where possible
- gameplay state per player → `NewByPlayer`
- object-local behavior → `NewByInstance`
- global systems → `New`

---

## Troubleshooting

### "My callback never runs"
Check:

- Same `caller_id` string in `Listen` and `Fire`
- Same dispatcher object instance used for both calls
- Listener wasn’t disconnected (manually or via `once`)
- Correct owner key (`player` or `instance`) for scoped dispatchers

### "NewByPlayer returned nil"
You are likely on the client. Create this dispatcher on server scripts.

### "Custom destroy event didn’t change"
The registry may be locked (`lock = true` was already applied).

### "I fired but listeners added inside callback didn’t run immediately"
Expected: listeners added during an active fire pass become pending and run on the next `Fire` cycle.

---

## Performance notes

- Listener dispatch is asynchronous and resilient, optimized for correctness under mutation.
- Cleanup uses reusable buffers in hot paths to reduce transient allocation churn.
- If profiling shows this module as hot, optimize caller patterns first (reduce redundant `Fire`s, avoid high-frequency over-broad groups).

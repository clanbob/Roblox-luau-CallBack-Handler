CALLBACK MODULE

Installation

local CallBack = require(path.To.CallBack)

GLOBAL DISPATCHER

  Create: local Events = CallBack.New()
  
  Listen: local connection = Events:Listen(caller_id: string, once: boolean, callback: (...) -> ())
  
  -   caller_id: string key used to group listeners
  -   once: if true, listener disconnects automatically before executing
  -   callback: function executed when Fire() is called
  
  Fire: Events:Fire(caller_id: string, ...)
  
  Destroy: Events:Destroy()
    -- destroys the event object

PER-PLAYER DISPATCHER (SERVER ONLY)

  -- auto cleans up when player leaves
  -- cant use custom destroy sginals
  
  Create: local PlayerEvents = CallBack.NewByPlayer()
  
  Listen: PlayerEvents:Listen(player: Player, caller_id: string, once: boolean, callback: callback: (...) -> ())
  
  Fire: PlayerEvents:Fire(player: Player, caller_id: string, ...)
  
  Get Registry: PlayerEvents:GetRegistered(player: Player)
    -- returns a registry for the player with method :Destroy
    :Destroy disconnects all listeners for that player
  
  Destroy: PlayerEvents:Destroy()

PER-INSTANCE DISPATCHER

  -- cleans up when istance is destroyed or from provided custom destroy signal
  
  Create: local InstEvents = CallBack.NewByIstance()
  
  Listen: InstEvents:Listen(instance: Instance, caller_id: string, once:boolean, callback: callback: (...) -> ())
  
  Fire: InstEvents:Fire(instance: Instance, caller_id: string, ...)
  
  Get Registry: InstEvents:GetRegistered(instance: Instance)
  -- returns a registry for the istance with method :Destroy
    :Destroy disconnects all listeners and resets the destroyed singal.
    if istance gets re-regristered it will resault to the default destroy sginal.
  
  Custom Destroy Event: InstEvents:UseCustomDestroyEventForIstance(instance: Instance, lock: boolean, event: RBXScriptSignal )
  
  -   instance: registry owner
  -   lock: if true, destroy event cannot be replaced
  -   event: signal that triggers registry destruction
  
  Destroy: InstEvents:Destroy()

LISTENER OBJECT

Returned from Listen().

  Methods: connection:Disconnect() connection:Fire(…)

BEHAVIOR GUARANTEES

  -   Disconnect() is safe during Fire()
  -   Listeners added during Fire() execute next cycle
  -   once = true auto-disconnects
  -   All callbacks execute asynchronously
  -   Errors include full traceback

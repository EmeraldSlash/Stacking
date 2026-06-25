--!strict

-- Stacking
-- 
-- https://github.com/EmeraldSlash/Stacking
--
-- Created by Rio Manson-Hay (@EmeraldSlash)
--
-- Version: 1 (2026-06-25)

-- Sets whether microprofiler labels are turned on or not.
local PRF_ON = true

--------------------------------------------------------------------------------
--
-- CORE API:
--
-- type Stack
-- Module.StackNew             (                             )->(Stack)
-- Stack:Evaluate              (DeltaTime, ValuesInitial     )->(Stack)
-- Stack:QueryValuesForPriority(Priority, ExcludeThisPriority)->({[Blendable]: Value})
-- Stack:ResetBlendables       (                             )->(Stack)
-- Stack:ResetBlocks           (                             )->(Stack)
-- Stack:Destroy               (                             )->(Stack)
--
-- type Blendable
-- Stack:BlendableNew(Blendable)->(Blendable)
-- |
-- Blendable.Blend     = (Low, High, Strength, Blendable)->(Value)
-- Blendable.Apply     = (Value, Stack, Blendable)->()
-- Blendable.Validate  = (Value)->(boolean)
-- Blendable.Default   = nil
-- Blendable.Transient = Blendable
--
-- type Block
-- Stack:BlockNew (Block )->(Block)
-- Block:SetActive(Active)->(Block)
-- Block:Destroy  (      )->(Block)
-- |
-- Block.Evaluate  = (Block, Context)->(ShouldStopEvaluating)
-- Block.Active    = boolean
-- Block.Priority  = {number}
-- Block.Strength  = number
-- Block.Transient = boolean
-- Block.Opaque    = boolean
--
-- type Context
-- Context:Read     (Blendable                              )->(Value, HasValue)
-- Context:Write    (Blendable, Value,           Overrides..)->(Value)
-- Context:AutoBlend(Blendable, Value, Strength, Overrides..)->(Value)
-- Context:AutoFlag (Blendable, Value, Strength, Overrides..)->(Value)
--
-- OPTIONAL HELPERS:
--
-- Module.Priorities         = {[Name]: Value}
-- Module.PriorityALowerThanB(APriority, BPriority          )->(IsLower)
-- Module.Blend              (Low, High, Strength, Blendable)->(Value)
-- Module.BlendFlag          (Low, High, Strength           )->(Value)
-- Module.TweenEvaluate      (Block, Ctx                    )->(Done)
--
-- Stack.Priorities          = Module.*
-- Stack.PriorityALowerThanB = Module.*
-- Stack.Blend               = Module.*
-- Stack.BlendFlag           = Module.*
-- Stack.TweenEvaluate       = Module.*
--
-- Context.Priorities          = Module.*
-- Context.PriorityALowerThanB = Module.*
-- Context.Blend               = Module.*
-- Context.BlendFlag           = Module.*
-- Context.TweenEvaluate       = Module.*
--
-- type BlockTween
-- Context:Tween             (BlockTween, Active          )->(Strength, Done)
-- Context:TweenGetInOutValue(BlockTween, Default, In, Out)->(Value)
--
-- type Stack_CameraModulePatch
-- Module.PatchCameraModuleManual(CameraModule, CameraInput): Stack_CameraModulePatch
-- Module.PatchCameraModuleAuto  (PlayerModule             ): Stack_CameraModulePatch
--
--------------------------------------------------------------------------------

local Module = {}

local LogService = game:GetService("LogService")
local CreateMetatable = function(): any local C = {}; C.__index = C; return C; end

local MetaStack: Stack = CreateMetatable()
local MetaBlock: Block = CreateMetatable()
local MetaCtx: Context = CreateMetatable()

-- Some priority helpers for common priorities.
--
-- Use them like `Priority = {Module.Priorities.Gameplay, 10}` to create a sub
-- priority of 10 for the gameplay priority.
--
Module.Priorities = {
   -- vv Min priority.
   Min = -math.huge;
   -- vv Default priority.
   Default = 0;
   -- vv Low priority.
   Low = 100;
   LowJuice = 200;
   -- vv Basic camera management e.g. attaching camera to a player character.
   Avatar = 300;
   AvatarJuice = 400;
   -- vv Temporary gameplay related camera management e.g. aiming or locking on to a
   -- target.
   Gameplay = 500;
   GameplayJuice = 600;
   -- vv Cinematic sequences that override all gameplay.
   Cinematic = 700;
   CinematicJuice = 800;
   -- vv UI effects such as screen blur, FOV changes, zooms.
   UI = 900;
   UIJuice = 1000;
   -- vv High priority.
   High = 1100;
   HighJuice = 1200;
   -- vv Max priority.
   Max = math.huge;
}
function Module.PriorityALowerThanB(APriority, BPriority)
	local Max = math.max(#APriority, #BPriority)
	local Result = false
	for Index = 1, Max do
		local AP = APriority[Index] or 0
		local BP = BPriority[Index] or 0
		if AP ~= BP then
			Result = AP < BP
			break
		end
	end
	return Result
end

-- MARK: Tween Helper

-- This is a helper for tweening blocks in/out, usable via methods on Ctx. Usage
-- example:
--[[
Stack:BlockNew({
   Evaluate = function(Block: Block, Ctx: Context, Stack: Stack)
      local Strength, Done = Ctx:Tween(Block.Tween, Block.Active)
		if not Done then
			-- vv Block is only transient when it's tweening out.
			Block.Transient = Ctx:TweenGetInOutValue(Block.Tween, false, nil, true)

			-- vv Block camera CFrame animates smoothly.
			Ctx:AutoBlend(Blendable_CameraCFrame, CFrame.identity, Strength)

			-- vv Block disables input when it is tweening in or already in, but not
			-- when tweening out.
			Ctx:AutoFlag(Blendable_DisableInput, Ctx:TweenGetInOutValue(Block.BlockTween, true, nil, false), Strength)
		end
      return Done;
   end;
})
--]]
export type BlockTween = {
	-- vv By default, the tween will animate both activation and deactivation
	-- transitions, and will use the same easing parameters for both.
	Duration: number?;
	EasingStyle: Enum.EasingStyle?;
	EasingDirection: Enum.EasingDirection?;
	EasingFunction: ((number, Enum.EasingStyle?, Enum.EasingDirection?)->(number))?;

	-- vv To disable a transition before or after, you can set its duration to 0.
	-- So to disable the activation transition (instant snap), you can set
	-- DurationIn = 0 for example.
   --
   -- NOTE: You don't have to rename all your values to In/Out etc, you can keep
	-- using the fields above for things you don't mind being the same for both
	-- directions. If an In/Out variant of a value is missing, the default value
	-- above will be used instead, or failing that, the other in/out value.
   --
	DurationIn: number?;
	DurationOut: number?;
	EasingStyleIn: Enum.EasingStyle?;
	EasingStyleOut: Enum.EasingStyle?;
	EasingDirectionIn: Enum.EasingDirection?;
	EasingDirectionOut: Enum.EasingDirection?;
	EasingFunctionIn: ((number, Enum.EasingStyle?, Enum.EasingDirection?)->(number))?;
	EasingFunctionOut: ((number, Enum.EasingStyle?, Enum.EasingDirection?)->(number))?;

	-- vv You can set this to prevent the tween from blocking Block
	-- deactivation. (So instead of tweening out it will just be removed
	-- immediately.)
	Cancelled: boolean?;
	-- vv If true, destroying will immediately removing the block.
	CancelOnDestroy: boolean?;

	-- vv Internal fields.
	Target: number?;
	Start: number?;
	Value: number?;
	Elapsed: number?;
   Progress: number?;
	Finished: boolean?;
}
function Module.TweenEvaluate(Block: Block, Ctx: Context)
	local Tween = Block.Tween :: BlockTween
	if Block.Destroyed and Tween.CancelOnDestroy then
		Tween.Cancelled = true
	end
	local Strength, Done = Ctx:Tween(Tween, Block.Active)
	Block.Strength = Strength
	if not Done and Block.TweenBlendables then
		for Blendable, Value in Block.TweenBlendables do
			Ctx:AutoBlend(Blendable, Value, Strength)
		end
	end
	return Done
end
do
	local TweenService = game:GetService("TweenService")
	local TweenService_GetValue = TweenService.GetValue
   function MetaCtx.TweenGetInOutValue<T>(Ctx: Context, BT: BlockTween, Default: T?, In: T?, Out: T?): T?
		if type(BT) ~= "table" then
         LogService:Error("Ctx:TweenGetInOutValue(): BlockTween argument is missing or invalid. Block \"{Id}\"\n{Traceback}", {
				Id = tostring(Ctx.Block.Id);
				Traceback = tostring(Ctx.Block.Traceback);
			})
      end
		local Result
		if Default ~= nil or
			In ~= nil or
			Out ~= nil
		then
			Result =
				if BT.Target == 0 then (
					-- ^ If we're transitioning out.
					if Out ~= nil then Out
					elseif Default ~= nil then Default
					else In)
				elseif BT.Progress < 1 then (
					-- ^ If we're transitioning in.
					if In ~= nil then In
					elseif Default ~= nil then Default
					else Out)
				else (
					-- ^ If we're not transitioning.
					if Default ~= nil then Default
					elseif In ~= nil then In
					else Out)
		end
		return Result
   end
   function MetaCtx.Tween(Ctx: Context, BT: BlockTween, Active: boolean?): (number, boolean)
      if type(BT) ~= "table" then
         LogService:Error("Ctx:Tween(): BlockTween argument is missing or invalid. Block \"{Id}\"\n{Traceback}", {
				Id = tostring(Ctx.Block.Id);
				Traceback = tostring(Ctx.Block.Traceback);
			})
      end
		local Target = if Active then 1 else 0
		if BT.Target ~= Target then
			BT.Target = Target
			BT.Start = BT.Value or 0
			BT.Elapsed = 0
		end
		assert(BT.Elapsed)
		BT.Elapsed += Ctx.DeltaTime
		local Duration =
			if Active then (BT.DurationIn or BT.Duration or BT.DurationOut or 1)
			else (BT.DurationOut or BT.Duration or BT.DurationIn or 1)
		-- The easing function may produce any value, so we need to keep the raw
		-- progress for checking state.
		local RawProgress =
			if Duration <= 0 then 1 else math.clamp(BT.Elapsed / Duration, 0, 1)
		local Progress = RawProgress
		if Progress > 0 and Progress < 1 then
			local EasingStyle =
				if Active then (BT.EasingStyleIn or BT.EasingStyle or BT.EasingStyleOut)
				else (BT.EasingStyleOut or BT.EasingStyle or BT.EasingStyleIn)
			local EasingDirection =
				if Active then (BT.EasingDirectionIn or BT.EasingDirection or BT.EasingDirectionOut)
				else (BT.EasingDirectionOut or BT.EasingDirection or BT.EasingDirectionIn)
			if BT.EasingFunction then
				Progress = BT.EasingFunction(Progress, EasingStyle, EasingDirection)
			else
				Progress = TweenService_GetValue(TweenService, Progress, EasingStyle, EasingDirection)
			end
		end
		BT.Progress = Progress
		BT.Value = math.lerp(BT.Start :: number, BT.Target :: number, Progress)

		local Finished = false
		if not Active then
			if ((RawProgress >= 1) and (BT.Target == 0)) or
				(BT.Cancelled)
			then
				Finished = true
			end
		end
		BT.Finished = Finished
		return BT.Value :: number, BT.Finished :: boolean
   end
end

--
-- MARK: Blendable
--
-- vv Blendables are how particular values get tracked by the stack system. Any
-- value you wish to be part of the system should be defined as a Blendable.
--[[
local B_CameraCFrame = Stack:BlendableNew<<CFrame>>({
   Default = CFrame.identity;
})
--]]
export type Blendable<T> = {
   -- vv Optional, can be used to store & look up the Blendable in the Stack
	-- using some unique name. If provided, it will be registered under this Id.
	-- The blendable will never be unregistered unless you do it manually, as
	-- Blendables are not intended to have lifetimes.
	Id: any?;

	-- vv This is the default value that will be blended from if there are no
	-- values in the stack below the current block. This is allowed to be nil (so
	-- long as the "unset"/"clean up" state is is equivalent to the "nil" state
	-- in the Apply function).
	--
	-- If you want to set the initial value for the stack before evaluating, you
	-- can do that by changing this field. (But it will persist after being
	-- overridden, so if you need an initial value that is weak and doesn't
	-- persist after it has been overidden, you should make a Block instead.)
	--
	Default: T?;

	-- vv If no Blend function is specified, then this will default to lerping
	-- (or fully replacing value if it is not a number, Vector3, or CFrame). Note
	-- that the low priority value may be nil!
	Blend: ((LowPriority: T?, HighPriority: T, HighStrength: number)->(T))?;

	-- vv This will be called once the value has finished being blended for all
	-- blocks. This should be used to "apply" the value, and it will be called
	-- redundantly every frame even if the value isn't changing.
	--
	-- IMPORTANT: If the blendable value was being applied with a non-nil value
	-- in the last frame, and is no longer applied in the current frame, then
	-- this function will be called with Value == nil so that it can do cleanup
	-- logic. Make sure to handle that case!!
	--
	Apply: ((Value: T?, Stack: Stack, Blendable: Blendable<T>)->())?;

	-- vv This will be called every time the Blendable value is written to check
	-- that the value is correct. If not, a warning will be printed and the write
	-- will be cancelled. Useful for debugging.
	Validate: ((Value: T?)->(boolean))?;

	-- vv If you wish this Blendable to support the Block.Transient field, you
	-- can enable that here by creating a "transient" copy of the Blendable and
	-- storing a reference to it in this field.
	--
	-- This Blendable needs only to be used as a table key by this module (the
	-- module will always read the Default value and Blend function from the
	-- canonical Blendable). So it is safe for this to just be an empty table.
	-- However:
	--
	-- 1) If you want to read from the Blendable in your own code, it's a good
	--    idea to set the Default field, and keep it in sync with the canonical
	--    Blendable.
	--
	-- 2) You can also set the Apply function so that the module will call it in
	--    the usual way after evaluating. (There are no guarantees about when the
	--    Apply function will run relative to other Blendable's Apply functions,
	--    so don't expect transient Blendables to have their Apply functions
	--    called after canonical blendables or something like that. There aren't
	--    distinct passes and there is no explicit ordering.)
	--
	Transient: Blendable<T>?;

	-- Set internally.
	Traceback: string?;
}
function MetaStack.BlendableNew<T>(Stack: Stack, Blendable: Blendable<T>): Blendable<T>
	Blendable.Traceback = debug.traceback(nil, 2);
   if Blendable.Id ~= nil then
      Blendable.Id = Blendable.Id
      if Stack.Block_ById[Blendable.Id] then
         LogService:Warn("Blendable \"{Id}\" is already registered!\n{Traceback}", {
            Id = Blendable.Id;
            Traceback = Blendable.Traceback;
         })
      end
      Stack.Block_ById[Blendable.Id] = Blendable
   end
   return Blendable
end
do
   local V3_Lerp = Vector3.zero.Lerp
   local CF_Lerp = CFrame.identity.Lerp
   function Module.Blend(Low: any, High: any, Strength: number?, Blendable: Blendable<any>): any
      local NewValue
      local Strength = math.clamp(Strength or 1, 0, 1)
      if Strength <= 0 then
         NewValue = Low
      elseif Blendable.Blend then
         NewValue = Blendable.Blend(Low, High, Strength)
      else
         local TypeH = typeof(High)
         if TypeH ~= typeof(Low) then
            NewValue = High
         elseif TypeH == "number" then
            NewValue = math.lerp(Low, High, Strength)
         elseif TypeH == "Vector3" then
            NewValue = V3_Lerp(Low, High, Strength)
         elseif TypeH == "CFrame" then
            NewValue = CF_Lerp(Low,  High, Strength)
         else
            NewValue = High
         end
      end
      return NewValue
   end
	function Module.BlendFlag(Low: any, High: any, Strength: number): any
		return if (Strength > 0) then (High or Low) else Low
	end
end

--
-- MARK: Stack
--
-- A Stack stores and managers your blended values and blocks. If you wish, you
-- can augment a Stack to contain references to "built-in"/easily shareable
-- Blendables or Blocks, or provide other functionality.
export type Stack = {

   -- Optional containers/storage of objects.
   Blendable_ById: {[any]: Blendable<any>},
   Block_ById: {[any]: Block};

   -- List of active blocks that are being evaluated every frame.
   Blocks_Active: {Block};

   -- Final blended values from the last time the stack was evaluated.
   Values: {[Blendable<any>]: any?};
   -- Final results per unique priority (via normalized priority string). Allows
   -- for querying what a particular block produced, or what can you "see" at a
   -- particular priority level. @TODO Maybe this should just be stored in the
   -- blocks themselves, since their existence is guaranteed until the next
   -- evaluation?
   Values_ByPriorityString: {[string]: {[Blendable<any>]: any?}};
   -- The initial values at the bottom of the stack. (This is empty by default
   -- unless you manually add base values before evaluating.)
   Values_Initial: {[Blendable<any>]: any?};

   -- Create a new Blendable.
   BlendableNew: <T>(Stack: Stack, Blendable: Blendable<T>)->(Blendable<T>);
   -- Create a new Block.
   BlockNew: (Stack: Stack, BlockBase: BlockBase)->(Block);

   -- Reset all blendables that have been applied by the stack.
   ResetBlendables: (Stack: Stack)->(Stack);
   -- Remove all blocks from the active list.
   ResetBlocks: (Stack: Stack)->(Stack);
   -- Runs all reset methods, also forgets all Blocks and Blendables registered
   -- by Id.
   Destroy: (Stack: Stack)->(Stack);

   -- Update the stack, blending all values and applying the results. Optionally
   -- takes a list of initial values for certain blendables.
   Evaluate: (Stack: Stack, DeltaTime: number)->(Stack);

   -- Queries the values that the stack had last frame at a particular priority,
   -- excluding values that were above that priority. Useful to avoid feedback
   -- e.g. when creating a lower priority block with an initial value based on
   -- stack's current values.
   QueryValuesForPriority: (Stack: Stack, Priority: {number}, ExcludeThisPriority: boolean?)->({[Blendable<any>]: any?});

   -- Static helper functions for convenience (call as functions instead of
   -- methods).
   Priorities: typeof(Module.Priorities);
   PriorityALowerThanB: typeof(Module.PriorityALowerThanB);
	Blend: typeof(Module.Blend);
	BlendFlag: typeof(Module.BlendFlag);
	TweenEvaluate: typeof(Module.TweenEvaluate);
}

function Module.StackNew(): Stack
   return setmetatable({
      Blendable_ById = {};
      Block_ById = {};
      Blocks_Active = {};
      Values = {};
      Values_ByPriorityString = {};
      Values_Initial = {};
   }, MetaStack) :: any
end
MetaStack.Priorities = Module.Priorities
MetaStack.PriorityALowerThanB = Module.PriorityALowerThanB
MetaStack.Blend = Module.Blend
MetaStack.BlendFlag = Module.BlendFlag
MetaStack.TweenEvaluate = Module.TweenEvaluate
-- NOTE: MetaStack.BlendableNew and MetaStack.BlockNew methods are defined near
-- their respective type definitions.
function MetaStack.ResetBlendables(Stack: Stack)
   local ValuesCloned = table.clone(Stack.Values)
   table.clear(Stack.Values)
   table.clear(Stack.Values_ByPriorityString)
   table.clear(Stack.Values_Initial)
   for Blendable in ValuesCloned do
      if Blendable.Apply then
         Blendable.Apply(nil, Stack, Blendable)
      end
   end
	return Stack
end
function MetaStack.ResetBlocks(Stack: Stack)
   table.clear(Stack.Blocks_Active)
	return Stack
end
function MetaStack.Destroy(Stack: Stack)
   Stack:ResetBlendables()
   Stack:ResetBlocks()
   table.clear(Stack.Blendable_ById)
   table.clear(Stack.Block_ById)
	return Stack
end
function MetaStack.QueryValuesForPriority(Stack: Stack, Priority: {number}, ExcludeThisPriority: boolean?): {[Blendable<any>]: any?}
	if type(Priority) == "number" then
		Priority = {Priority}
	end
	local HighestPriority = nil
	local HighestBlendValues = Stack.Values_Initial
	for PriorityString, BlendValues in Stack.Values_ByPriorityString do
		local ThisPriority = {}
		for _, Piece in string.split(PriorityString, ",") do
			ThisPriority[#ThisPriority+1] = tonumber(Piece) :: number
		end
		local Valid =
			if ExcludeThisPriority then (Module.PriorityALowerThanB(ThisPriority, Priority))
			else (not Module.PriorityALowerThanB(Priority, ThisPriority))
		if Valid then
			-- This is working on the assumption that the most recently added
			-- entries will be given lowest priority, and then the highest priority
			-- entries will be visited first because the table is being iterated
			-- in order they were added. That may not be true though. But this
			-- should suffice.
			if (not HighestPriority) or
				(not Module.PriorityALowerThanB(ThisPriority, HighestPriority))
			then
				HighestPriority = ThisPriority
				HighestBlendValues = BlendValues
			end
		end
	end
	return HighestBlendValues
end
-- NOTE: MetaStack.Evaluate method is defined later.

--
-- MARK: Block
--
-- Defines an individual block that can be placed on the camera stack.
--
-- vv This type is the user-provided specification for a camera block.
export type BlockBase = {
	-- vv Optional, can be used to store & look up the Block in the Stack using
	-- some unique name. If provided, it will be registered under this Id, and
	-- will be unregistered when the Block is destroyed.
	Id: any?;

	-- vv Store random stuff in here, that your Eval or Blender functions may
	-- want to access.
	UserData: {[any]: any};

	-- vv Higher values will evaluate last and will replace lower values. If a
	-- given priority number is not set, it will default to 0. Because this field
	-- is an array, it allows indefinite nesting of priorities:
	--
	-- e.g. {1, 2} is higher than {1, 1} and smaller than {2}.
	--
	Priority: {number};

	-- vv This function will be run every frame / stack evaluation, after the
	-- Block has been activated via Block:SetActive(true). It should never yield.
	--
	-- This function should check Block.Active == false to know when the user has
	-- requested a deactivation. It should return true if the Block is done (has
	-- been deactivated and/or no longer needs to run updates every frame), or
	-- false if it should continue running in future frames. If this function is
	-- not set, the Block will be done immediately if Block.Active == false.
	--
	-- This function can also modify any field in the Block, such as
	-- Block.Strength, Block.Transient, and Block.Opaque. (Note that changes to
	-- Block.Priority won't do anything until the next frame / stack evaluation.)
	--
	-- This function is given an evaluation Context (AKA Ctx) object as an
	-- argument, which it can use to read/write Blendable values.
	--
	-- There are two different kinds of stacking effects you may want:
	--
	-- "Absolute" effects: such as overriding a value. e.g. Moving the camera to
	-- a specific location for a cinematic. A simple absolute effect can be
	-- achieved with:
	--[[
	Ctx:Write(Blendable, Value)
	--]]
	--
	-- "Relative" effects: such as absolute effects that tween in/out, or
	-- temporary changes that modify the values below them. e.g. Camera shake,
	-- camera tweens. A simple relative effect can be achieved with:
	--[[
	Ctx:AutoBlend(Blendable, Value, Strength)
	--]]
	--
	-- If not provided, the Strength parameter will default to 1. Boolean flags
	-- that need only be toggled once to stay set forever (e.g. logical OR) can
	-- be set using:
	--[[
	Ctx:AutoFlag(B_DisableInput, Value, Strength)
	--]]
	-- And the flag will be raised so long as the provided Strength parameter is
	-- > 0 (defaults to 1).
	--
	-- If you don't want automatic blending, or want to apply transformations manually,
	-- you can read and write the values yourself:
	--
	--[[
	local LowerPriorityValue = Ctx:Read(CFrameBlendable)
	local HigherPriorityValue = LowerPriorityValue * CFrame.new(0, 10, 0)
	Ctx:Write(CFrameBlendable, HigherPriorityValue)
	--]]
	--
	-- Also, if you need a blend/lerp function that handles the common numeric
	-- data types and Blendables (which may define their own Blend functions),
	-- you can use this:
	--[[
	Module.Blend(LowPriorityValue, HighPriorityValue, Strength, Blendable).
	--]]
	--
	-- There are also two helper functions Ctx:Tween() and
	-- Ctx:TweenGetInOutValue() used for making smooth in/out transitions for a
	-- block. If you purely using the tween behavior without any extra logic, you
	-- can use the premade evaluate function Module.TweenEvaluate.
	--
	Evaluate: ((Block: Block, Ctx: Context)->(boolean))?;

	-- The following fields can be statically configured, or they can be written
	-- by the Evaluate function.
	--
	-- vv If true, the result values of this Block will be marked as transient,
	-- so that any Blendables which support transient application will be applied
	-- that way. The purpose of this is to allow values to be stacked in a way
	-- that avoids creating feedback in future evaluations.
	--
	-- For example, if you have camera shake that is being applied as a rotation
	-- on top of the player's Camera.CFrame, you want to avoid permanently
	-- committing the camera shake into Camera.CFrame, so that the camera shake
	-- does not stack with itself over time.
	--
	-- This system still respects the stacking behavior, and if a higher priority
	-- block takes over with Transient=false, this block will be replaced by the
	-- higher block (so it won't be layered on top), and the higher block may
	-- upgrade the "transient" value to a "persistent" value so that the higher
	-- blocker can blend with it (if the higher block is non-transient).
	--
	-- In order to use this feature, the usage code must set the
	-- Blendable.Transient field, i.e. it must give a canonical Blendable a
	-- reference to a "transient" copy of itself which can be written to
	-- separately. Then it must read the transient Blendable values separately
	-- and apply them in whatever way is needed.
	--
	Transient: boolean?;
	--
	-- vv If true, the result values of this block won't propagate upwards or
	-- be visible at all to higher blocks.
	Opaque: boolean?;
	--
	-- vv Defines the strength of how values in this block will be blended on top
	-- of whatever is beneath them. This is not directly used by the module and
	-- is only defined here for your convenience. Generally corresponds to what
	-- gets passed to Ctx:AutoBlend/Flag(), Module.Blend(), Module.BlendFlag(),
	-- and what gets returned by Ctx:Tween().
	Strength: number?;
	--
	-- vv Storage for BlockTween helper.
	Tween: BlockTween?; -- Info/state about the tween.
	TweenBlendables: {[Blendable<any>]: any}?; -- Values the user wants to apply.
}
-- vv This type is the initialized camera block which is ready to use.
export type Block = BlockBase & {
	-- vv The stack the block is inside of.
   Stack: Stack,

	-- vv Set to true when the Block should be in use. The Block may still be
	-- evaluating every frame even if this false however (e.g. if it wants to
	-- tween out).
	Active: boolean?;

	-- vv Set to true immediately when destroyed. We guarantee that if
	-- Destroyed==true then Active==false.
	Destroyed: boolean?;

	-- vv Debug info.
	Traceback: string;

	-- vv Writes the Active field.
   --
   -- If Active is being set to true, the Block will be put in the
	-- Stack.Blocks_Active array (the array of Blocks to be updated every frame).
   --
   -- If Active is being set to false, the Block won't be removed from the array
	-- immediately. Removal from the array is handled by the Stack:Evaluate()
	-- function when Block:Evaluate() returns true to indicate it is ready to be
	-- cleaned up.
   --
	SetActive: (Block: Block, Active: boolean)->(Block);

	-- vv Destroy the block, deactivating it and setting Destroyed = true, and
	-- unregistering its Id.
	Destroy: (Block: Block)->();

   -- vv Registers a BlockTween helper that automatically tweens in/out of
}
function MetaStack.BlockNew(Stack: Stack, Base: BlockBase): Block
   local Block: Block = (Base or {}) :: any
   Block.Traceback = debug.traceback(nil, 2)
   if Block.Id ~= nil then
      Block.Id = Block.Id
      if Stack.Block_ById[Block.Id] then
         LogService:Warn("Block ID \"{Id}\" has already been registered, it will be overwritten with the new block!\n{Traceback}", {
            id = Block.Id;
            Traceback = Block.Traceback;
         })
      end
      Stack.Block_ById[Block.Id] = Block
   end
   Block.Stack = Stack
   -- @TODO Should we validate all fields here? For better UX.
   if type(Block.Priority) ~= "table" and Block.Priority ~= nil then
      Block.Priority = {Block.Priority}
   end
   Block.UserData = Block.UserData or {}
   setmetatable(Block, MetaBlock)
   return Block
end
function MetaBlock.SetActive(Block, Active)
   if Active then
      if not Block.Active then
         Block.Active = true
         local Stack = Block.Stack
         if not table.find(Stack.Blocks_Active, Block) then
            Stack.Blocks_Active[#Stack.Blocks_Active+1] = Block
         end
      end
   else
      if Block.Active then
         Block.Active = false
      end
   end
   return Block
end
function MetaBlock.Destroy(Block)
   Block:SetActive(false)
   Block.Destroyed = true
   local Stack = Block.Stack
   if Stack.Block_ById[Block.Id] == Block then
      Stack.Block_ById[Block] = nil
   end
	return Block
end

-- MARK: Context
export type Context = {
   DeltaTime: number;
	Block: Block;
   DidWrite: boolean;
	BlendedValues: {[Blendable<any>]: any};
	BlendedValuesSet: {[Blendable<any>]: boolean};
	NewOpaque_ByBlendable: {[Blendable<any>]: boolean};
	WasOpaque_ByBlendable: {[Blendable<any>]: boolean};

	-- vv Read the current value of this Blendable from the stack. Also returns a
   -- boolean indicating whether a non-default value had been set for this
   -- Blendable or not (nil is a valid Blendable value, so this information has
   -- to checked separately from the value itself to be sure).
	Read: <T>(
		Ctx: Context,
		Blendable: Blendable<T>
	)->(T, boolean);
	-- vv Write a new value for this Blendable to the stack. This is a simple
	-- overwrite, no blending is performed. Returns the value that was written.
	Write: <T>(
		Ctx: Context,
		Blendable: Blendable<T>,
		Value: T,
		OverrideTransient: boolean?,
		OverrideOpaque: boolean?
	)->(T);
	-- vv Given a Blendable, write a new value for it, automatically blending it
	-- with the current value in the stack using Block.Strength as the blending
	-- factor. Returns the value that was written.
	AutoBlend: <T>(
		Ctx: Context,
		Blendable: Blendable<T>,
		Value: T,
		Strength: number?,
		OverrideTransient: boolean?,
		OverrideOpaque: boolean?
	)->(T);
	-- vv Given a Blendable, write a new value for it, logically ORing it with
	-- the value below it if Block.Strength > 0. Prefers the higher priority
	-- value if both are truthy.
	AutoFlag: <T>(
		Ctx: Context,
		Blendable: Blendable<T>,
		Value: T,
		Strength: number?,
		OverrideTransient: boolean?,
		OverrideOpaque: boolean?
	)->(T);

	-- vv Tween helpers.
	Tween: (Ctx: Context, Tween: BlockTween, Active: boolean?)->(number, boolean);
	TweenGetInOutValue: <T>(Ctx: Context, Tween: BlockTween, Default: T?, In: T?, Out: T?)->(T?);

   -- vv Static helper functions for convenience (call as functions instead of
   -- methods).
   Priorities: typeof(Module.Priorities);
   PriorityALowerThanB: typeof(Module.PriorityALowerThanB);
   Blend: typeof(Module.Blend);
	BlendFlag: typeof(Module.BlendFlag);
	TweenEvaluate: typeof(Module.TweenEvaluate);
}
MetaCtx.Priorities = Module.Priorities
MetaCtx.PriorityALowerThanB = Module.PriorityALowerThanB
MetaCtx.Blend = Module.Blend
MetaCtx.BlendFlag = Module.BlendFlag
MetaCtx.TweenEvaluate = Module.TweenEvaluate
function MetaCtx.Read<T>(
	Ctx: Context,
	Blendable: Blendable<T>
): (T, boolean)
	if type(Blendable) ~= "table" then
		LogService:Error("Ctx:Read(): Blendable argument is missing or invalid. Block \"{Id}\"\n{Traceback}", {
			Id = tostring(Ctx.Block.Id);
			Traceback = tostring(Ctx.Block.Traceback);
		})
	end
	local CanUseLow = not Ctx.WasOpaque_ByBlendable[Blendable]
	-- When reading, we always use the most recent value. So when
	-- transitioning from "full" to "rendering-only", the block will receive
	-- the previous "full" value. And when transitioning from "rendering-only"
	-- to "normal", the block will receive the previous "rendering-only"
	-- value, so the "rendering-only" value is being upgraded to "full"
	-- status.
	local Low = nil
	local HasLow = false
	if not HasLow then
		if CanUseLow then
			local BlendableTransient: any = Blendable.Transient
			if Ctx.BlendedValuesSet[BlendableTransient] then
				HasLow = true
				Low = Ctx.BlendedValues[BlendableTransient]
			end
		end
	end
	if not HasLow then
		if CanUseLow then
			if Ctx.BlendedValuesSet[Blendable] then
				HasLow = true
				Low = Ctx.BlendedValues[Blendable]
			end
		end
	end
	if not HasLow then
		Low = Blendable.Default
	end
	return Low, HasLow
end
function MetaCtx.Write<T>(
	Ctx: Context,
	Blendable: Blendable<T>,
	Value: T,
	OverrideTransient: boolean?,
	OverrideOpaque: boolean?
): T
	if type(Blendable) ~= "table" then
		LogService:Error("Ctx:Write(): Blendable argument is missing or invalid. Block \"{Id}\"\n{Traceback}", {
			Id = tostring(Ctx.Block.Id);
			Traceback = tostring(Ctx.Block.Traceback);
		})
	end
	local Valid = true
	if Blendable.Validate then
		Valid = Blendable.Validate(Value)
		if not Valid then
			LogService:Warn("Block \"{BlockId}\" gave Blendable \"{BlendableId}\" a value \"{Value}\" ({ValueType}) that failed the Validate function!\nBlendable:{BlendableTrace}\nBlock:{BlockTrace}", {
				BlockId = tostring(Ctx.Block.Id);
				BlockTrace = tostring(Ctx.Block.Traceback);
				BlendableId = tostring(Blendable.Id);
				BlendableTrace = tostring(Blendable.Traceback);
				Value = tostring(Value);
				ValueType = typeof(Value);
			})
		end
	end
	if Valid then
		local Transient
		if OverrideTransient ~= nil then
			Transient = if OverrideTransient then true else false
		else
			Transient = if Ctx.Block.Transient then true else false
		end

		-- When writing, we will always clear the rendering only value unless it
		-- is being used.
		local BlendableTransient: any = Blendable.Transient
		if not BlendableTransient then
			Ctx.BlendedValues[Blendable] = Value
			Ctx.BlendedValuesSet[Blendable] = true

		elseif Transient then
			Ctx.BlendedValues[BlendableTransient] = Value
			Ctx.BlendedValuesSet[BlendableTransient] = true

		else
			Ctx.BlendedValues[BlendableTransient] = nil
			Ctx.BlendedValuesSet[BlendableTransient] = nil

			Ctx.BlendedValues[Blendable] = Value
			Ctx.BlendedValuesSet[Blendable] = true
		end

		-- Track opaqueness and the presence of blendables.
		Ctx.WasOpaque_ByBlendable[Blendable] = nil
		if OverrideOpaque ~= nil then
			Ctx.NewOpaque_ByBlendable[Blendable] = if OverrideOpaque then true else false
		else
			Ctx.NewOpaque_ByBlendable[Blendable] = if Ctx.Block.Opaque then true else false
		end

		Ctx.DidWrite = true
	end
   return Value
end
function MetaCtx.AutoBlend<T>(
	Ctx: Context,
	Blendable: Blendable<T>,
	Value: T,
	Strength: number?,
	OverrideTransient: boolean,
	OverrideOpaque: boolean?
): T
	if type(Blendable) ~= "table" then
		LogService:Error("Ctx:AutoBlend(): Blendable argument is missing or invalid. Block \"{Id}\"\n{Traceback}", {
			Id = tostring(Ctx.Block.Id);
			Traceback = tostring(Ctx.Block.Traceback);
		})
	end
	local Low = Ctx:Read(Blendable)
	local NewValue = Ctx.Blend(Low, Value, Strength, Blendable)
	Ctx:Write(Blendable, NewValue, OverrideTransient, OverrideOpaque)
   return NewValue
end
function MetaCtx.AutoFlag<T>(
	Ctx: Context,
	Blendable: Blendable<T>,
	Value: T,
	Strength: number?,
	OverrideTransient: boolean?,
	OverrideOpaque: boolean?
): T
	if type(Blendable) ~= "table" then
		LogService:Error("Ctx:AutoFlag(): Blendable argument is missing or invalid. Block \"{Id}\"\n{Traceback}", {
			Id = tostring(Ctx.Block.Id);
			Traceback = tostring(Ctx.Block.Traceback);
		})
	end
	local Low = Ctx:Read(Blendable)
	local NewValue =
		if (Strength or 1) >= 1 then (Value or Low)
		else Low
	Ctx:Write(Blendable, NewValue, OverrideTransient, OverrideOpaque)
   return NewValue
end

--
-- MARK: Stack:Evaluate()
--
local Block_Unknown: Block = ({
	Id = "_UNKNOWN_BLOCK_FALLBACK";
	Traceback = "_UNKNOWN_BLOCK_FALLBACK";
} :: any)
table.freeze(Block_Unknown)

function MetaStack.Evaluate(Stack: Stack, DeltaTime: number)
	if PRF_ON then debug.profilebegin("StackEvaluate") end

   -- We sort the Blocks backwards, and then we iterate over them backwards, so
	-- in net they are being iterated over fowards.
	table.sort(Stack.Blocks_Active, function(A, B)
		return Module.PriorityALowerThanB(A.Priority, B.Priority)
	end)

   local Ctx: Context = setmetatable({}, MetaCtx) :: any

   Ctx.DeltaTime = DeltaTime

   Ctx.BlendedValues = {}
   Ctx.BlendedValuesSet = {}

	Ctx.WasOpaque_ByBlendable = {}
	Ctx.NewOpaque_ByBlendable = {}

	local BlendedValues_ByPriorityString = {}
	local BlendedValues_Initial = table.clone(Ctx.BlendedValues)

	local Index = #Stack.Blocks_Active
	while true do
		local IndexDidComplete = true

		local Thread = task.spawn(function()
			while Index > 0 do
				IndexDidComplete = false

				local Block = Stack.Blocks_Active[Index]
				Ctx.Block = Block
				Ctx.NewOpaque_ByBlendable = {}
            Ctx.DidWrite = false

				-- We take a copy of the priority just before running the evaluate
				-- function, in case the function tries to modify it.
				local Normalized = table.clone(Block.Priority)

            local Finished = true
            if Block.Evaluate then
               Finished = Block.Evaluate(Block, Ctx)
            else
               LogService:Warn("Block \"{Id}\" Evaluate function is missing, so it will be automatically deactivated.\n{Traceback}", {
                  Id = tostring(Block.Id);
                  Traceback = tostring(Block.Traceback);
               })
            end
            if Finished then
               Block.Active = false
               table.remove(Stack.Blocks_Active, Index)
            end

            if Ctx.DidWrite then
               -- Clean up blendables that were not set this block. (This table is
               -- being used to track whether blendables are being set or not in
               -- addition to whether they were actually Opaque or not.)
               for Blendable, WasOpaque in Ctx.WasOpaque_ByBlendable do
                  if WasOpaque then
                     Ctx.BlendedValues[Blendable] = nil
                     Ctx.BlendedValuesSet[Blendable] = nil

                     local BlendableTransient = Blendable.Transient
                     if BlendableTransient then
                        Ctx.BlendedValues[BlendableTransient] = nil
                        Ctx.BlendedValuesSet[BlendableTransient] = nil
                     end
                  end
               end

               -- Replace the previous "Was" table with the "New" table. (Actually clearing
               -- and swapping them for perf.)
               local Temp = Ctx.WasOpaque_ByBlendable
               Ctx.WasOpaque_ByBlendable = Ctx.NewOpaque_ByBlendable
               Ctx.NewOpaque_ByBlendable = Temp
               table.clear(Temp)

               -- Creates a normalized priority string (by removing all trailing
               -- 0s), which identifies a priority in a way such that identical
               -- priorities will have the same string value. It's kinda dumb to
               -- do this priority string generation every frame, but it's the
               -- only way to be sure really.
               for NIndex = #Normalized, 1, -1 do
                  if Normalized[NIndex] == 0 then
                     Normalized[NIndex] = nil
                  else
                     break
                  end
               end
               local PriorityString = table.concat(Normalized, ",")
               BlendedValues_ByPriorityString[PriorityString] = table.clone(Ctx.BlendedValues)
            end

				Index -= 1
				IndexDidComplete = true
			end
		end)

		-- If the thread completed then we can exit the loop.
		if IndexDidComplete then
			break

		-- If the thread doesn't complete immediately, deactivate the Block
		-- since there's something wrong with it.
		else
			local Block: Block = Stack.Blocks_Active[#Stack.Blocks_Active] or Block_Unknown
			Block.Active = false
			table.remove(Stack.Blocks_Active, Index)
			Index -= 1

			-- The Block evaluation yielded, so let's warn.
			local Status = coroutine.status(Thread)
			if Status == "suspended" then
				LogService:Warn("Block \"{Id}\" Evaluate function performed a yielding operation. Evaluate functions should never yield.\n{Traceback}", {
               Id = tostring(Block.Id);
               Traceback = tostring(Block.Traceback);
            })
			elseif Status == "dead" then
				LogService:Warn("Block \"{Id}\" Evaluate function threw an error or otherwise ended up dead.\n{Traceback}", {
               Id = tostring(Block.Id);
               Traceback = tostring(Block.Traceback);
            })
			else
				LogService:Warn("Block \"{Id}\" Evaluate function caused thread to have invalid status: {Status}.\n{Traceback}", {
               Id = tostring(Block.Id);
               Traceback = tostring(Block.Traceback);
               Status = tostring(Status);
            })
			end
		end
	end

	-- Apply values that are present. If they are set, they will be applied every
	-- frame. If they were set and become unset, the apply function will be
	-- called once with a nil argument.
	local Visited = {}
	for Blendable in Ctx.BlendedValuesSet do
		Visited[Blendable] = true
		if Blendable.Apply then
			Blendable.Apply(Ctx.BlendedValues[Blendable], Stack, Blendable)
		end
	end
	for Blendable, Value in Stack.Values do
		if (Value ~= nil) and (not Visited[Blendable]) then
			if Blendable.Apply then
				Blendable.Apply(nil, Stack, Blendable)
			end
		end
	end
	Stack.Values = Ctx.BlendedValues
	Stack.Values_ByPriorityString = BlendedValues_ByPriorityString
	Stack.Values_Initial = BlendedValues_Initial

	if PRF_ON then debug.profileend() end

	return Stack
end

--
-- MARK: Camera Module Patch
--
export type Stack_CameraModulePatch = Stack & {
   Camera: Camera;

   B_CFrame: Blendable<CFrame>;
   B_Focus: Blendable<CFrame>;
   B_CFrame_Transient: Blendable<CFrame>;
   B_Focus_Transient: Blendable<CFrame>;
	B_FOV: Blendable<number>;
   B_DisableInput: Blendable<boolean>;
   B_DisableOcclusionModule: Blendable<boolean>;
   B_DisableTransparencyController: Blendable<boolean>;

   PreStackCameraCFrame: CFrame;
   PreStackCameraFocus: CFrame;
   PreOcclusionCameraCFrame: CFrame;
   PreOcclusionCameraFocus: CFrame;
   PostUpdateCameraCFrame: CFrame;
   PostUpdateCameraFocus: CFrame;
   TransientCameraCFrame: CFrame;
   TransientCameraFocus: CFrame;
   DidApplyTransient: boolean;
}

function Module.PatchCameraModuleManual(CameraModule: any, CameraInput: any): Stack_CameraModulePatch
   local Stack = Module.StackNew() :: Stack_CameraModulePatch

	-- Provides the API and stores state.
   CameraModule.Stack = Stack

   -- Definitions for common values.
   Stack.PreStackCameraCFrame = CFrame.identity
   Stack.PreStackCameraFocus = CFrame.identity

   Stack.PreOcclusionCameraCFrame = CFrame.identity
   Stack.PreOcclusionCameraFocus = CFrame.identity

   Stack.PostUpdateCameraCFrame = CFrame.identity
   Stack.PostUpdateCameraFocus = CFrame.identity

   Stack.TransientCameraCFrame = CFrame.identity
   Stack.TransientCameraFocus = CFrame.identity

   Stack.DidApplyTransient = false

   -- MARK: > Blendables

   -- vv These are used internally for CFrames that affect rendering only and avoid
   -- creating feedback with the primary camera CFrame. You should only need to
   -- reference these if you need to query those rendering-only CFrames.
   Stack.B_CFrame_Transient = Stack:BlendableNew<<CFrame>>({})
   Stack.B_Focus_Transient = Stack:BlendableNew<<CFrame>>({})

   -- vv These are what you should be using in your own code, these are the
   -- built-in blendables which define the camera's CFrame and Focus. These
   -- Blendables' Default fields get set to the camera's pre-camera-stack values
   -- every frame before blending.
   Stack.B_CFrame = Stack:BlendableNew<<CFrame>>({
      Transient = Stack.B_CFrame_Transient;
		Validate = function(Value) return typeof(Value) == "CFrame" end;
   })
   Stack.B_Focus = Stack:BlendableNew<<CFrame>>({
      Transient = Stack.B_Focus_Transient;
		Validate = function(Value) return typeof(Value) == "CFrame" end;
   })
   -- vv This is a common, but optional, blendable. It is also a good example of
   -- a custom blendable.
   Stack.B_FOV = Stack:BlendableNew<<number>>({
      Default = 70;
      Apply = function(Value, _Stack, Blendable)
         local Stack = _Stack :: Stack_CameraModulePatch
         local ValueActual = Value or Blendable.Default or 70 -- Reset to whatever "unset" value we should have.
         if Stack.Camera.FieldOfView ~= ValueActual then
            Stack.Camera.FieldOfView = ValueActual
         end
      end;
		Validate = function(Value) return type(Value) == "number" end;
   })
   -- vv These define some other CameraModule control features. They are booleans
   -- combined with logical OR.
   Stack.B_DisableInput = Stack:BlendableNew<<boolean>>({
      Default = false;
      Blend = Module.BlendFlag;
   })
   Stack.B_DisableOcclusionModule = Stack:BlendableNew<<boolean>>({
      Default = false;
      Blend = Module.BlendFlag;
   })
   Stack.B_DisableTransparencyController = Stack:BlendableNew<<boolean>>({
      Default = false;
      Blend = Module.BlendFlag;
   })

   -- MARK: > Update
   CameraModule._UpdateOriginal = CameraModule.Update
   function CameraModule.Update(self, DeltaTime)
		if self.activeCameraController then
			local CurrentCamera = game.Workspace.CurrentCamera :: Camera
         Stack.Camera = CurrentCamera

			if Stack.DidApplyTransient then
				Stack.DidApplyTransient = false
				CurrentCamera.CFrame = Stack.PostUpdateCameraCFrame
				CurrentCamera.Focus = Stack.PostUpdateCameraFocus
			end

         -- NTOE: Ideally, we would disable input right here before updating
         -- mouse behavior. But unfortunately that would require splitting the
         -- stack evaluation into two passes, a gameplay logic pass and then an
         -- actual blending pass, and that's pretty inelegent. So we just accept
         -- that the new mouse behavior will take one frame to come into effect.

			self.activeCameraController:UpdateMouseBehavior()

			local NewCameraCFrame, NewCameraFocus =
				self.activeCameraController:Update(DeltaTime)

			-- Properties before camera stacker.
			Stack.PreStackCameraCFrame = NewCameraCFrame
			Stack.PreStackCameraFocus = NewCameraFocus

         -- Set default values for the blendables.
         Stack.B_CFrame.Default = NewCameraCFrame
         Stack.B_Focus.Default = NewCameraFocus
         -- The overrides must also be initialized to default values. We need to
         -- do this because even though the overrides' default values will never
         -- be read in this function, usage code may try to read them from
         -- Values_* tables, or in other arbitrary situations.
         Stack.B_CFrame_Transient.Default = NewCameraCFrame
         Stack.B_Focus_Transient.Default = NewCameraFocus

         Stack:Evaluate(DeltaTime)

			NewCameraCFrame = Stack.Values[Stack.B_CFrame] or Stack.B_CFrame.Default
			NewCameraFocus = Stack.Values[Stack.B_Focus] or Stack.B_Focus.Default

			-- Properties before occlusion module.
			Stack.PreOcclusionCameraCFrame = NewCameraCFrame
			Stack.PreOcclusionCameraFocus = NewCameraFocus

			if self.activeOcclusionModule and not Stack.Values[Stack.B_DisableOcclusionModule] then
				NewCameraCFrame, NewCameraFocus = self.activeOcclusionModule:Update(
					DeltaTime, NewCameraCFrame, NewCameraFocus)
			end
         CameraInput.setInputEnabled(not Stack.Values[Stack.B_DisableInput])

			-- Final properties.
			Stack.PostUpdateCameraCFrame = NewCameraCFrame
			Stack.PostUpdateCameraFocus = NewCameraFocus

			CurrentCamera.CFrame = NewCameraCFrame
			CurrentCamera.Focus = NewCameraFocus

			if self.activeTransparencyController and not Stack.Values[Stack.B_DisableTransparencyController] then
				self.activeTransparencyController:Update(DeltaTime)
			end

			if CameraInput.getInputEnabled() then
				CameraInput.resetInputForFrameEnd()
			end

			-- Apply rendering only properties.
         local CameraCFrame_Transient = Stack.Values[Stack.B_CFrame_Transient]
         local CameraFocus_Transient = Stack.Values[Stack.B_Focus_Transient]

			Stack.TransientCameraCFrame = CameraCFrame_Transient or NewCameraCFrame
			Stack.TransientCameraFocus = CameraFocus_Transient or NewCameraFocus

			if CameraCFrame_Transient then
				CurrentCamera.CFrame = CameraCFrame_Transient
				Stack.DidApplyTransient = true
			end
			if CameraFocus_Transient then
				CurrentCamera.Focus = CameraFocus_Transient
				Stack.DidApplyTransient = true
			end
		end
	end

   return Stack
end
function Module.PatchCameraModuleAuto(PlayerModule: ModuleScript): Stack_CameraModulePatch
   local CameraModule = require(PlayerModule:WaitForChild("CameraModule")) :: any
	local CameraInput = require(PlayerModule:WaitForChild("CameraModule"):WaitForChild("CameraInput")) :: any
   return Module.PatchCameraModuleManual(CameraModule, CameraInput)
end

return Module
--!strict

-- Camera Stacker
--
-- https://github.com/EmeraldSlash/CameraStacker
--
-- Created by Rio Manson-Hay (@EmeraldSlash)
--
-- Version: 5 (2026-05-14)

-- Sets whether microprofiler labels are turned on or not.
local PRF_ON = true

--------------------------------------------------------------------------------
--
-- API Summary:
--
--                (this module returns a function that patches the PlayerModule)
-- return: (PlayerModuleInstance)->()
--                     (the CameraStacker module gets patched into CameraModule)
-- CameraModule.CameraStacker = .
--
-- type Blendable              (defines a value that can be stacked and blended)
-- .P_***: number                                            (preset priorities)
-- .B_***: Blendable                                         (preset blendables)
-- .E_***: (CameraBlock, DeltaTime)->(boolean)               (preset evaluators)
--
-- type CameraBlockBase               (initalization table for the camera block)
-- .CameraBlockNew(CameraBlockBase)->CameraBlock
--
-- type CameraBlock (AKA CB)      (contains blendables, gets put into the stack)
-- CB:SetActive(IsActive)->CameraBlock
-- CB:Destroy()
-- CB.B_***: Blendable                                       (preset blendables)
-- CB.E_***: (CameraBlock, DeltaTime)->(boolean)             (preset evaluators)
-- type CameraBlockTweenInfo                          (storage & params E_Tween)
-- CB:SetEval_Tween(CameraBlockTweenInfo)->CameraBlock    (setup helper E_Tween)
--
--
-- .CB_ById: {[any]: CameraBlock}                            (optional registry)
-- .CBs_Active: {CameraBlock}                                        (the stack)
--
--                                                            (helper functions)
-- .PriorityALowerThanB(APriority, BPriority)->boolean
-- .QueryBlendValuesLastFrameForPriority(Priority, IncludeSelf)->{[Blendable]: any}
-- .Blend(LowPriorityValue, HighPriorityValue, Strength, Blendable)->(BlendedValue)

--                                   (reference specific values from last frame)
-- .BlendValuesLastFrame: {[Blendable]: any}
-- .BlendValuesLastFrame_ByPriorityString: {[string]: {[Blendable]: any}}
-- .BlendValuesLastFrame_Base: {[Blendable]: any}
--
--                             (reference camera cframe & focus from last frame)
-- .PreStackCameraCFrame: CFrame
-- .PreStackCameraFocus: CFrame
-- .PreOcclusionCameraCFrame: CFrame
-- .PreOcclusionCameraFocus: CFrame
-- .PostUpdateCameraCFrame: CFrame
-- .PostUpdateCameraFocus: CFrame
-- .PostOverrideCameraCFrame: CFrame
-- .PostOverrideCameraFocus: CFrame
-- .DidApplyRenderingOverride: boolean
--
--------------------------------------------------------------------------------

local CameraStacker = {}

--
-- Some priority helpers for common priorities.
--
-- Use them like `Priority = {CameraStacker.P_Gameplay, 10}` to create a sub
-- priority of 10 for the gameplay priority.
--
-- vv Min priority.
CameraStacker.P_Min = -math.huge
-- vv Default priority.
CameraStacker.P_Default = 0
-- vv Lowest priority.
CameraStacker.P_Low = 100
CameraStacker.P_LowJuice = 200
-- vv Basic camera management e.g. attaching camera to a player character.
CameraStacker.P_Avatar = 300
CameraStacker.P_AvatarJuice = 400
-- vv Temporary gameplay related camera management e.g. aiming or locking on to a
-- target.
CameraStacker.P_Gameplay = 400
CameraStacker.P_GameplayJuice = 500
-- vv UI effects such as screen blur, FOV changes, zooms.
CameraStacker.P_UI = 600
CameraStacker.P_UIJuice = 700
-- vv Cinematic sequences that override all gameplay.
CameraStacker.P_Cinematic = 800
CameraStacker.P_CinematicJuice = 900
-- vv Highest priority.
CameraStacker.P_High = 1000
CameraStacker.P_HighJuice = 1100
-- vv Max priority.
CameraStacker.P_Max = math.huge

--
-- Defines blendable values
--
export type Blendable<T> = {
	-- This is the default value that will be lerped. If not set, then the first
	-- available value in the stack will be used in full if strength > 0.
	Default: T?;

	-- If set, prevents this Blendable from blending with Blendables in lower
	-- priority CameraBlocks. (It will blend with the default value instead.)
	ExclusiveLo: boolean?;
	-- If set, prevents CameraBlocks above this one from using this Blendable for
	-- blending. (They will blend with the default instead, or the blendable
	-- will be removed.)
	ExclusiveHi: boolean?;
	-- Both of the above actually do pretty much the same thing for a Blendable
	-- on its own, however there is one subtle difference: if another CameraBlock
	-- that doesn't have this Blendable is higher priority than a CameraBlock
	-- with this Blendable, then IgnoreLo=true will allow this Blendable to
	-- propagate upwards/show up in the final result, whereas PropagateHi=true
	-- will prevent the Blendable from propagating upwards. This distinction is
	-- expected to be more useful when used in a CameraBlock as opposed to a
	-- Blendable.

	-- If no Blend function is specified, then this will default to lerping (or
	-- fully replacing value if it is not a number, Vector3, or CFrame).
	Blend: ((LowPriority: T, HighPriority: T, HighStrength: number)->(T))?;

	-- This will be called once the value has finished being blended for all
	-- blocks. This should be used to "apply" the value, and it will be called
	-- redundantly every frame even if the value isn't changing.
	--
	-- IMPORTANT: If the blendable value was being applied last frame, and is no
	-- longer applied in the current frame, then this function will be called
	-- with Value == nil so that it can do cleanup logic. Make sure to handle
	-- that case!!
	--
	Apply: ((Value: T?, CameraModule: any)->())?;
}

local function Def<T>(Value: T): T return Value end

-- These Blendables' default fields get set to the camera's pre-camera-stack
-- values every frame before blending.
CameraStacker.B_CFrame = Def<< Blendable<CFrame> >>({})
CameraStacker.B_Focus = Def<< Blendable<CFrame> >>({})

-- These are used internally for CFrames that affect rendering only and avoid
-- creating feedback with the primary camera CFrame. You should only need to
-- reference these if you need to query those rendering-only CFrames.
CameraStacker.B_CFrameOverride = Def<< Blendable<CFrame> >>({})
CameraStacker.B_FocusOverride = Def<< Blendable<CFrame> >>({})

-- These are examples of custom blendables you can create. And you can also just
-- use these directly.
CameraStacker.B_FOV = Def<< Blendable<number> >>({
	Default = 70;
	Apply = function(Value, CameraModule)
		Value = Value or 70 -- Reset to whatever "unset" value we should have.
		local Camera = game.Workspace.CurrentCamera
		if Camera.FieldOfView ~= Value then
			Camera.FieldOfView = Value
		end
	end;
})
--[[
CameraStacker.B_UpVector = Def<< Blendable<Vector3> >>({
	Default = Vector3.new(0, 1, 0);
	Apply = function(Value, CameraModule)
		if CameraModule.SetTargetUpVector then
			CameraModule:SetTargetUpVector(Value)
		end
	end;
})
CameraStacker.B_TransitionRate = Def<< Blendable<number>> >({
	Default = 0.15;
	Apply = function(Value, CameraModule)
		if CameraModule.SetTransitionRate then
			CameraModule:SetTransitionRate(Value)
		end
	end;
})
CameraStacker.B_SpinPart = Def<< Blendable<BasePart?> >>({
	Default = workspace.Terrain;
	Apply = function(Value, CameraModule)
		if CameraModule.SetSpinPart then
			CameraModule:SetSpinPart(Value)
		end
	end;
})
--]]

-- This is a helper for creating a tween evaluator. Usage example:
-- CameraStacker.CameraBlockNew({ ..CB.. }):SetEval_Tween({ ..CBTweenInfo.. })
--
type CameraBlockTweenInfo = {
	-- By default, the camera will animate both activation and deactivation
	-- transitions, and will use the same easing parameters for both.
	Duration: number?;
	EasingStyle: Enum.EasingStyle?;
	EasingDirection: Enum.EasingDirection?;
	EasingFunction: ((number, Enum.EasingStyle?, Enum.EasingDirection?)->(number))?;
	DisableInput: boolean?; -- Only when not transitioning, or as a fallback when transitioning.
	AffectRenderingOnly: boolean?;

	-- To disable a transition before or after, you can set its duration to 0. So
	-- to disable the activation transition (instant snap), you can set
	-- DurationIn = 0 for example. You don't have to rename all your values to
	-- In/Out etc, you can keep using the fields above for things you don't mind
	-- being the same for both directions.
	DurationIn: number?;
	DurationOut: number?;
	EasingStyleIn: Enum.EasingStyle?;
	EasingStyleOut: Enum.EasingStyle?;
	EasingDirectionIn: Enum.EasingDirection?;
	EasingDirectionOut: Enum.EasingDirection?;
	EasingFunctionIn: ((number, Enum.EasingStyle?, Enum.EasingDirection?)->(number))?;
	EasingFunctionOut: ((number, Enum.EasingStyle?, Enum.EasingDirection?)->(number))?;
	DisableInputIn: boolean?; -- Only when transitioning in.
	DisableInputOut: boolean?; -- Only when transitioning out.
	AffectRenderingOnlyIn: boolean?;
	AffectRenderingOnlyOut: boolean?;

	-- You can set this to prevent the tween from blocking deactivation. (So
	-- instead of tweening out it will just exit immediately.)
	Cancelled: boolean?;

	-- Cancelled will be set to true when the CB is destroyed. So destroying will
	-- cancel the tween.
	CancelOnDestroy: boolean?;

	-- Internal fields.
	Target: number?;
	Start: number?;
	Value: number?;
	Elapsed: number?;
}
do
	local TweenService = game:GetService("TweenService")
	local TweenService_GetValue = TweenService.GetValue

	local function TIQueryBoolean(TI, RawProgress, Normal, In, Out): boolean?
		local Result
		if Normal ~= nil or
			In ~= nil or
			Out ~= nil
		then
			Result =
				if TI.Target == 0 then (
					-- ^ If we're transitioning out.
					if Out ~= nil then Out
					elseif Normal ~= nil then Normal
					else In)
				elseif RawProgress < 1 then (
					-- ^ If we're transitioning in.
					if In ~= nil then In
					elseif Normal ~= nil then Normal
					else Out)
				else (
					-- ^ If we're not transitioning.
					if Normal ~= nil then Normal
					elseif In ~= nil then In
					else Out)
		end
		return Result
	end

	function CameraStacker.E_Tween(CB: CameraBlock, DeltaTime: number)
		local Finished = false
		local TI: CameraBlockTweenInfo = (CB :: any).TweenInfo
		local Target = if CB.Active then 1 else 0
		if TI.Target ~= Target then
			TI.Target = Target
			TI.Start = TI.Value or 0
			TI.Elapsed = 0
		end
		assert(TI.Elapsed)
		TI.Elapsed += DeltaTime
		local Duration =
			if CB.Active then (TI.DurationIn or TI.Duration or TI.DurationOut or 1)
			else (TI.DurationOut or TI.Duration or TI.DurationIn or 1)
		-- The easing function may produce any value, so we need to keep the raw
		-- progress for checking state.
		local RawProgress =
			if Duration <= 0 then 1 else math.clamp(TI.Elapsed / Duration, 0, 1)
		local Progress = RawProgress
		if Progress > 0 and Progress < 1 then
			local EasingStyle =
				if CB.Active then (TI.EasingStyleIn or TI.EasingStyle or TI.EasingStyleOut)
				else (TI.EasingStyleOut or TI.EasingStyle or TI.EasingStyleIn)
			local EasingDirection =
				if CB.Active then (TI.EasingDirectionIn or TI.EasingDirection or TI.EasingDirectionOut)
				else (TI.EasingDirectionOut or TI.EasingDirection or TI.EasingDirectionIn)
			if TI.EasingFunction then
				Progress = TI.EasingFunction(Progress, EasingStyle, EasingDirection)
			else
				Progress = TweenService_GetValue(TweenService, Progress, EasingStyle, EasingDirection)
			end
		end
		TI.Value = math.lerp(TI.Start :: number, TI.Target :: number, Progress)
		CB.Strength = TI.Value

		local DisableInput = TIQueryBoolean(
			TI, RawProgress, TI.DisableInput, TI.DisableInputIn, TI.DisableInputOut)
		if DisableInput ~= nil then
			CB.DisableInput = DisableInput :: any
		end
		local AffectRenderingOnly = TIQueryBoolean(
			TI, RawProgress, TI.AffectRenderingOnly, TI.AffectRenderingOnlyIn, TI.AffectRenderingOnlyOut)
		if AffectRenderingOnly ~= nil then
			CB.AffectRenderingOnly = AffectRenderingOnly :: any
		end

		if not CB.Active then
			if CB.Destroyed and TI.CancelOnDestroy then
				TI.Cancelled = true
			end
			if ((RawProgress >= 1) and (TI.Target == 0)) or (TI.Cancelled) then
				Finished = true
			end
		end
		return Finished
	end
end

--
-- Defines an individual block that can be placed on the camera stack
--
export type CameraBlockBase = {
	-- Optional, can be used to store & look up the CameraBlock using some unique
	-- name. If provided, it will be registered under this Id.
	Id: any?;

	-- Store random stuff in here.
	UserData: {[any]: any};

	-- Higher values will evaluate last and will replace lower values. If a given
	-- priority number is not set, it will default to 0. Allows indefinite
	-- nesting of priorities:
	--
	-- e.g. {1, 2} is higher than {1, 1} and smaller than {2}.
	--
	Priority: {number};

	-- @CameraStackerTODO: A big issue in the API rn is that's kinda dumb... It's
	-- confusing (and the implementation is a little bit inefficient) to have
	-- both Blendables and Blenders, even though the ergonomics are alright. And
	-- also it would just be really nice to have a single Blender function that
	-- can do all the blending for a whole CameraBlock - but this would need a
	-- granular "get previous value" and "write previous value" API which is not
	-- great. Something I could do, though, is have clearly separate Blenders and
	-- Values fields in the CameraBlock, and make the Blenders the canonical
	-- field for whether something gets applied or not. But this would make
	-- ergonomics worse... so it's not a great solution.

	-- Built-in and user-defined blendable values, such as camera cframe, focus,
	-- field of view.
	--
	-- This table is primarily useful for "absolute" effects such as moving the
	-- camera to a particular location or reaching a particular value.
	--
	Blendables: {[Blendable<any>]: any};

	-- Custom functions to blend this CB's Blendables with lower priority
	-- Blendables. Does not require the Blendable to be in the Blendables table.
	--
	-- This table is primarily useful for "relative" effects such as camera shake
	-- which need to make arbitrary decisions based on what lower priority
	-- blocks produce.
	--
	-- These functions will execute after Eval, so you can update relevant state
	-- first in Eval, then read it from these functions.
	--
	-- The ValueLow argument will be nil if the Blendable isn't available from the
	-- lower priority block, but you can expect it to be guaranteed for the
	-- built-in B_CFrame and B_Focus blendables (unless a lower priority block
	-- intentionally returns nil).
	--
	-- If you want to obtain the "ValueHigh" (AKA the current block's value), you
	-- can define a value in the Blendables table and use that in its
	-- corresponding Blend function. That scenario will work without issue and is
	-- officialy suppported. Alternatively, you just avoid putting stuff in the
	-- Blendables table and instead construct what you need from scratch or use
	-- intermediate values stored as custom fields in the block. Those
	-- alternatives may make more sense organizationally in many secnarios as
	-- they avoid mixing "absolute" and "relative" values.
	--
	Blenders: {[Blendable<any>]: (CB: CameraBlock, ValueLow: any?)->(any?)};

	-- These two fields behave the same as the corresponding Blendable fields,
	-- but will force their behavior for all Blendables consumed or produced by
	-- this CameraBlock. A quick way to say "this CameraBlock is exclusive".
	ExclusiveLo: boolean?;
	ExclusiveHi: boolean?;

	-- This function should take the CameraBlock and the DeltaTime, and update s
	-- the EVAL OUTPUT VALUES (defined below). This function will be run every
	-- frame, after the CB has been activated via CB:SetActive(true). It should
	-- check CB.Active == false to know when the user has requested a
	-- deactivation. It should return true if the CB is done (has been
	-- deactivated and/or no longer needs to run updates every frame), or false
	-- if it should continue running in future frames. If this function is not
	-- set, the CB will be done immediately if CB.Active == false. This function
	-- can also be used to arbitrarily modify the Blendables, Blenders,
	-- ExclusiveLo, and ExclusiveHi fields. But DO NOT MODIFY the Priority field.
	Eval: ((CB: CameraBlock, DeltaTime: number)->(boolean))?;

	-- EVAL OUTPUT VALUES (these can be statically configured if Eval is not
	-- defined or does not modify them)
	--
	-- Defines the strength of how values will be blended on top of whatever is
	-- beneath it. (Or whatever the blend function for a blendable property is.)
	-- This ONLY affects blending, it does not affect the camera stack behaviour.
	-- If this unset, it will default to 1. The use of this field is only
	-- required for blending without custom blend functions, as custom blend
	-- functions have a choice of whether to use this field or something else.
	Strength: number?;
	-- Defines whether camera input should be disabled or not. (Final per-frame
	-- result is the union of all camera blocks.)
	DisableInput: boolean?;
	-- Defines whether the camera occlusion module should be disabled or not.
	-- (Final per-frame result is the union of all camera blocks.)
	DisableOcclusion: boolean?;
	-- If true, the camera CFrame & focus output of this block will be applied to
	-- the camera after setting Camera.CFrame, and the original Camera.CFrame
	-- will be restored before the camera updates again. Useful for temporary
	-- effects layered on top of whatever camera is active and for which you wish
	-- to avoid feedback, e.g. screen shake.
	--
	-- This still respects the stacking behavior, and if a higher priority block
	-- takes over with AffectRenderingOnly=false, it will be replaced by the
	-- higher block (it won't be layered on top), and the higher block may
	-- upgrade the "rendering only" CFrame to a "full CFrame" so that the higher
	-- blocker can blend with it.
	--
	-- Code that wishes to query the values of CFrame/focus last frame will get
	-- the "full CFrame" by default if it uses .B_CFrame, so if it wants to query
	-- the "rendering only CFrame" then it can read .B_CFrameOverride first then
	-- fall back to .B_CFrame if it fails.
	--
	AffectRenderingOnly: boolean?;
}
export type CameraBlock = CameraBlockBase & {
	-- Set to true when should be in use. The CameraBlock may still be evaluation
	-- every frame even if this false however (if it wants to do a transition
	-- out animation).
	Active: boolean?;

	-- Set to true immediately when destroyed. We guarantee that if
	-- Destroyed==true then Active==false.
	Destroyed: boolean?;

	-- Debug info.
	Traceback: string;

	-- Commonly used constant values that are also stored inside CameraStacker.
	B_CFrame: Blendable<CFrame>;
	B_Focus: Blendable<CFrame>;
	B_CFrameOverride: Blendable<CFrame>;
	B_FocusOverride: Blendable<CFrame>;
	E_Tween: (CB: CameraBlock, DeltaTime: number)->(boolean);

	-- Setup E_Tween on this CameraBlock
	SetEval_Tween: (CB: CameraBlock, CBTweenInfo: CameraBlockTweenInfo)->(CameraBlock);

	-- Activate the CameraBlock, putting in the array of CameraBlocks to be
	-- updated every frame. If deactivating, it won't be removed from the array,
	-- instead it's more of a communication mechanism like "the user indicated
	-- they want this block to be deactivated".
	SetActive: (CB: CameraBlock, Active: boolean)->(CameraBlock);

	-- Destroy the block, deactivating it and setting Destroyed = true, and
	-- unregistering its Id.
	Destroy: (CB: CameraBlock)->();
}

CameraStacker.CB_ById = {} :: {[any]: CameraBlock};
CameraStacker.CBs_Active = {} :: {CameraBlock};

do
	local MetaCB: CameraBlock =
		(function(): any local C = {}; C.__index = C; return C end)()

	function CameraStacker.CameraBlockNew(Base: CameraBlockBase): CameraBlock
		local CB: CameraBlock = (Base or {}) :: any
		if CB.Id ~= nil then
			CB.Id = CB.Id
			if CameraStacker.CB_ById[CB.Id] then
				warn(debug.traceback(("CameraBlock ID \"%s\" is already registered!")
					:format(tostring(CB.Id))))
			end
			CameraStacker.CB_ById[CB.Id] = CB
		end
		-- Should we validate all fields here? For better UX.
		if type(CB.Priority) == "number" then
			CB.Priority = {CB.Priority}
		elseif type(CB.Priority) ~= "table" then
			CB.Priority = {}
		end
		CB.Blendables = CB.Blendables or {}
		CB.Blenders = CB.Blenders or {}
		CB.UserData = CB.UserData or {}
		CB.Traceback = debug.traceback(nil, 2)
		setmetatable(CB, MetaCB)
		return CB
	end

	MetaCB.B_CFrame = CameraStacker.B_CFrame
	MetaCB.B_Focus = CameraStacker.B_Focus
	MetaCB.B_CFrameOverride = CameraStacker.B_CFrameOverride
	MetaCB.B_FocusOverride = CameraStacker.B_FocusOverride
	MetaCB.E_Tween = CameraStacker.E_Tween
	function MetaCB.SetEval_Tween(CB: CameraBlock, CBTweenInfo: CameraBlockTweenInfo): CameraBlock
		CB.Eval = CB.E_Tween
		local CBA = CB :: any
		CBA.TweenInfo = CBTweenInfo
		return CB
	end

	function MetaCB.SetActive(CB, Active)
		if Active then
			if not CB.Active then
				CB.Active = true
				if not table.find(CameraStacker.CBs_Active, CB) then
					CameraStacker.CBs_Active[#CameraStacker.CBs_Active+1] = CB
				end
			end
		else
			if CB.Active then
				CB.Active = false
			end
		end
		return CB
	end

	function MetaCB.Destroy(CB)
		CB:SetActive(false)
		CB.Destroyed = true
		if CameraStacker.CB_ById[CB.Id] == CB then
			CameraStacker.CB_ById[CB] = nil
		end
	end
end

CameraStacker.BlendValuesLastFrame = {} :: {[Blendable<any>]: any};
CameraStacker.BlendValuesLastFrame_ByPriorityString = {} :: {[string]: {[Blendable<any>]: any}};
CameraStacker.BlendValuesLastFrame_Base = {} :: {[Blendable<any>]: any};

function CameraStacker.PriorityALowerThanB(APriority, BPriority)
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

-- This is a way for users to query camera cframe below a certain priority, so
-- if they're making static animations at or above a periority they can
-- correctly include/exclude certain influences when choosing the values to
-- start from.
function CameraStacker.QueryBlendValuesLastFrameForPriority(Priority: {number}, IncludeSelf: boolean?): {[Blendable<any>]: any}
	if type(Priority) == "number" then
		Priority = {Priority}
	end
	local HighestPriority = nil
	local HighestBlendValues = CameraStacker.BlendValuesLastFrame_Base
	for PriorityString, BlendValues in CameraStacker.BlendValuesLastFrame_ByPriorityString do
		local ThisPriority = {}
		for _, Piece in string.split(PriorityString, ",") do
			ThisPriority[#ThisPriority+1] = tonumber(Piece) :: number
		end
		local Valid =
			if IncludeSelf then (not CameraStacker.PriorityALowerThanB(Priority, ThisPriority))
			else (CameraStacker.PriorityALowerThanB(ThisPriority, Priority))
		if Valid then
			-- This is working on the assumption that the most recently added
			-- entries will be given lowest priority, and then the highest priority
			-- entries will be visited first because the table is being iterated
			-- in order they were added. That may not be true though. But this
			-- should suffice.
			if (not HighestPriority) or
				(not CameraStacker.PriorityALowerThanB(ThisPriority, HighestPriority))
			then
				HighestPriority = ThisPriority
				HighestBlendValues = BlendValues
			end
		end
	end
	return HighestBlendValues
end

--
-- Internal setup & evaluation logic
--

local function CameraStackerEvaluate(DeltaTime)
	if PRF_ON then debug.profilebegin("CameraStackerEvaluate") end

	local DisableInput = false
	local DisableOcclusion = false

	-- We sort the CBs backwards, and then we iterate over them backwards, so
	-- in net they are being iterated over fowards.
	table.sort(CameraStacker.CBs_Active, function(A, B)
		return CameraStacker.PriorityALowerThanB(A.Priority, B.Priority)
	end)

	local Index = #CameraStacker.CBs_Active
	while true do
		local IndexDidComplete = true

		local Thread = task.spawn(function()
			while Index > 0 do
				IndexDidComplete = false
				local CB = CameraStacker.CBs_Active[Index]
				if CB.Destroyed then
					CB.Active = false
				end
				local IsDone
				if CB.Eval then
					IsDone = CB.Eval(CB, DeltaTime)
					if IsDone == nil then
						warn(("CameraBlock.Eval returned nil, which could indicate a bug or incorrect usage. Please return a truthy or falsey value. Id: %s, Trace:\n%s")
							:format(tostring(CB.Id), CB.Traceback))
					end
				else
					IsDone = not CB.Active
				end
				if IsDone then
					CB.Active = false
					table.remove(CameraStacker.CBs_Active, Index)
				else
					if CB.DisableInput then
						DisableInput = true
					end
					if CB.DisableOcclusion then
						DisableOcclusion = true
					end
				end
				Index -= 1
				IndexDidComplete = true
			end
		end)

		-- If the thread completed then we can exit the loop.
		if IndexDidComplete then
			break
		-- If the thread doesn't complete immediately, deactivate the CameraBlock
		-- since there's something wrong with it.
		else
			local CB: CameraBlock = CameraStacker.CBs_Active[#CameraStacker.CBs_Active] or ({
				Id = "UNKNOWN_FALLBACK";
				Traceback = "UNKNOWN_FALLBACK";
			} :: any)
			CB.Active = false
			table.remove(CameraStacker.CBs_Active, Index)
			Index -= 1
			-- The CameraBlock evaluation yielded, so let's warn.
			local Status = coroutine.status(Thread)
			if Status == "suspended" then
				warn(("CameraBlock performed a yielding operation. It should never yield. Id: %s, Trace:\n%s")
					:format(tostring(CB.Id), CB.Traceback))
			elseif Status == "dead" then
				warn(("CameraBlock threw an error. Id: %s, Trace:\n%s")
					:format(tostring(CB.Id), CB.Traceback))
			else
				warn(("CameraBlock evaluation thread had invalid status: %s. Id: %s, Trace:\n%s")
					:format(tostring(Status), tostring(CB.Id), CB.Traceback))
			end
		end
	end

	if PRF_ON then debug.profileend() end
	return DisableInput, DisableOcclusion
end

local V3_Lerp = Vector3.zero.Lerp
local CF_Lerp = CFrame.identity.Lerp
function CameraStacker.Blend(Low: any, High: any, Strength: number?, Blendable: Blendable<any>): any
	local NewValue
	local Strength = math.clamp(Strength or 1, 0, 1)
	if Strength <= 0 then
		NewValue = Low
	elseif not Low then
		NewValue = High
	elseif Blendable.Blend then
		NewValue = Blendable.Blend(Low, High, Strength)
	else
		local TypeT = typeof(High)
		local TypeB = typeof(Low)
		if TypeT ~= TypeB then
			NewValue = High
		elseif TypeT == "number" then
			NewValue = math.lerp(Low, High, Strength)
		elseif TypeT == "Vector3" then
			NewValue = V3_Lerp(Low, High, Strength)
		elseif TypeT == "CFrame" then
			NewValue = CF_Lerp(Low,  High, Strength)
		else
			NewValue = High
		end
	end
	return NewValue
end

local function CameraStackerBlend(
	InputCFrame: CFrame,
	InputFocus: CFrame,
	CameraModule
): (CFrame, CFrame, CFrame?, CFrame?)
	if PRF_ON then debug.profilebegin("CameraStackerBlend") end

	CameraStacker.B_CFrame.Default = InputCFrame
	CameraStacker.B_Focus.Default = InputFocus

	-- The overrides must also be initialized to default values. We need to do
	-- this because even though the overrides' default values will never be read
	-- in this function, usage code may try to read them from
	-- BlendValuesLastFrame_* tables, or in other arbitrary situations.
	CameraStacker.B_CFrameOverride.Default = InputCFrame
	CameraStacker.B_FocusOverride.Default = InputCFrame

	local BlendedValues = {}
	local BlendedValues_ByPriorityString = {}
	local WasExclusiveHi_ByBlendable: {[Blendable<any>]: boolean} = {}

	local function UpdateBlendable(CB: CameraBlock, NewExclusiveHi_ByBlendable, Blendable)
		local CanUseLow =
			(not CB.ExclusiveLo) and
			(not Blendable.ExclusiveLo) and
			(not WasExclusiveHi_ByBlendable[Blendable])

		local BlendableOverride
		if Blendable == CameraStacker.B_CFrame then
			BlendableOverride = CameraStacker.B_CFrameOverride
		elseif Blendable == CameraStacker.B_Focus then
			BlendableOverride = CameraStacker.B_FocusOverride
		end

		local BlendableKey = Blendable
		if BlendableOverride then
			if CB.AffectRenderingOnly then
				BlendableKey = BlendableOverride
				local Existing = BlendedValues[BlendableOverride]
				BlendedValues[BlendableOverride] =
					if Existing ~= nil then Existing else BlendedValues[Blendable]
			else
				-- Here we enable smooth transitions between low priority "rendering
				-- only" / "override" blendables and high priority "full"
				-- blendables by upgrading the rendering only blendable to a full
				-- blendable.
				local LowRender = BlendedValues[BlendableOverride]
				if LowRender ~= nil then
					BlendedValues[Blendable] = LowRender
				end
			end
		end

		local Low = nil
		if CanUseLow then
			Low = BlendedValues[BlendableKey]
		end
		if Low == nil then
			Low = Blendable.Default
		end
		local NewValue
		local Blender = CB.Blenders[Blendable]
		if Blender then
			NewValue = Blender(CB, Low)
		else
			local High = CB.Blendables[Blendable]
			assert(High ~= nil)
			NewValue = CameraStacker.Blend(Low, High, CB.Strength, Blendable)
		end
		BlendedValues[BlendableKey] = NewValue
		WasExclusiveHi_ByBlendable[Blendable] = nil
		NewExclusiveHi_ByBlendable[Blendable] = if Blendable.ExclusiveHi then true else false
	end

	for Index = #CameraStacker.CBs_Active, 1, -1 do
		local CB = CameraStacker.CBs_Active[Index]
		local NewExclusiveHi_ByBlendable: {[Blendable<any>]: boolean} = {}

		for Blendable, High in CB.Blendables do
			UpdateBlendable(CB, NewExclusiveHi_ByBlendable, Blendable)
		end
		for Blendable in CB.Blenders do
			if not CB.Blendables[Blendable] then
				UpdateBlendable(CB, NewExclusiveHi_ByBlendable, Blendable)
			end
		end
		for Blendable, WasExclusiveHi in WasExclusiveHi_ByBlendable do
			local CanUseLow =
				(not CB.ExclusiveLo) and
				(not Blendable.ExclusiveLo) and
				(not WasExclusiveHi)

			if not CanUseLow then
				BlendedValues[Blendable] = nil
				if Blendable == CameraStacker.B_CFrame then
					BlendedValues[CameraStacker.B_CFrameOverride] = nil
				elseif Blendable == CameraStacker.B_Focus then
					BlendedValues[CameraStacker.B_FocusOverride] = nil
				end
			end
		end
		WasExclusiveHi_ByBlendable = NewExclusiveHi_ByBlendable

		-- Creates a normalized priority string (redundant 0s removed), which
		-- identifies a priority in a way such that identical priorities will have
		-- the same string value. It's kinda dumb to do this priority string
		-- generation every frame, but it's the only way to be sure really.
		local Normalized = table.clone(CB.Priority)
		for NIndex = #Normalized, 1, -1 do
			if Normalized[NIndex] == 0 then
				Normalized[NIndex] = nil
			else
				break
			end
		end
		local PriorityString = table.concat(Normalized, ",")
		BlendedValues_ByPriorityString[PriorityString] = table.clone(BlendedValues)
	end

	local Visited = {}
	for Blendable, Value in BlendedValues do
		Visited[Blendable] = Value
		if Blendable.Apply then
			Blendable.Apply(Value, CameraModule)
		end
	end
	for Blendable in CameraStacker.BlendValuesLastFrame do
		if Visited[Blendable] == nil then
			if Blendable.Apply then
				Blendable.Apply(nil, CameraModule)
			end
		end
	end
	CameraStacker.BlendValuesLastFrame = Visited
	CameraStacker.BlendValuesLastFrame_ByPriorityString = BlendedValues_ByPriorityString
	CameraStacker.BlendValuesLastFrame_Base = {
		[CameraStacker.B_CFrame] = CameraStacker.B_CFrame.Default;
		[CameraStacker.B_Focus] = CameraStacker.B_Focus.Default;
	}

	if PRF_ON then debug.profileend() end

	return
		BlendedValues[CameraStacker.B_CFrame] or CameraStacker.B_CFrame.Default,
		BlendedValues[CameraStacker.B_Focus] or CameraStacker.B_Focus.Default,
		BlendedValues[CameraStacker.B_CFrameOverride],
		BlendedValues[CameraStacker.B_FocusOverride]
end

CameraStacker.PreStackCameraCFrame = CFrame.identity
CameraStacker.PreStackCameraFocus = CFrame.identity

CameraStacker.PreOcclusionCameraCFrame = CFrame.identity
CameraStacker.PreOcclusionCameraFocus = CFrame.identity

CameraStacker.PostUpdateCameraCFrame = CFrame.identity
CameraStacker.PostUpdateCameraFocus = CFrame.identity

CameraStacker.PostOverrideCameraCFrame = CFrame.identity
CameraStacker.PostOverrideCameraFocus = CFrame.identity

CameraStacker.DidApplyRenderingOverride = false

-- @CameraStackerTODO: the CameraStacker can only be used on the
-- PlayerModule/default camera itself, but really it is a more generic system
-- that could be applied to any output, and the PlayerModule/camera part is just
-- a specal use case, so maybe those two components should be separated.

return function(PlayerModule: ModuleScript)

	local CameraModule = require(PlayerModule:WaitForChild("CameraModule")) :: any
	local CameraInput = require(PlayerModule:WaitForChild("CameraModule"):WaitForChild("CameraInput")) :: any

	-- Provides the API and stores state.
	CameraModule.CameraStacker = CameraStacker

	CameraModule._UpdateOriginal = CameraModule.Update
	function CameraModule.Update(self, DeltaTime)
		if self.activeCameraController then
			local CurrentCamera = game.Workspace.CurrentCamera :: Camera

			if CameraStacker.DidApplyRenderingOverride then
				CameraStacker.DidApplyRenderingOverride = false
				CurrentCamera.CFrame = CameraStacker.PostUpdateCameraCFrame
				CurrentCamera.Focus = CameraStacker.PostUpdateCameraFocus
			end

			local InputDisabled, AllowOcclusion = CameraStackerEvaluate(DeltaTime)
			CameraInput.setInputEnabled(not InputDisabled)
			self.activeCameraController:UpdateMouseBehavior()

			local NewCameraCFrame, NewCameraFocus =
				self.activeCameraController:Update(DeltaTime)

			-- Properties before camera stacker.
			CameraStacker.PreStackCameraCFrame = NewCameraCFrame
			CameraStacker.PreStackCameraFocus = NewCameraFocus

			local BlendedCFrame, BlendedFocus, BlendedCFrameOverride, BlendedFocusOverride =
				CameraStackerBlend(NewCameraCFrame, NewCameraFocus, CameraModule)

			NewCameraCFrame = BlendedCFrame
			NewCameraFocus = BlendedFocus

			-- Properties before occlusion module.
			CameraStacker.PreOcclusionCameraCFrame = NewCameraCFrame
			CameraStacker.PreOcclusionCameraFocus = NewCameraFocus

			if self.activeOcclusionModule and AllowOcclusion then
				NewCameraCFrame, NewCameraFocus = self.activeOcclusionModule:Update(
					DeltaTime, NewCameraCFrame, NewCameraFocus)
			end

			-- Final properties.
			CameraStacker.PostUpdateCameraCFrame = NewCameraCFrame
			CameraStacker.PostUpdateCameraFocus = NewCameraFocus

			CurrentCamera.CFrame = NewCameraCFrame
			CurrentCamera.Focus = NewCameraFocus

			if self.activeTransparencyController then
				self.activeTransparencyController:Update(DeltaTime)
			end

			if CameraInput.getInputEnabled() then
				CameraInput.resetInputForFrameEnd()
			end

			if BlendedCFrameOverride then
				CurrentCamera.CFrame = BlendedCFrameOverride
				CameraStacker.DidApplyRenderingOverride = true
			end
			if BlendedFocusOverride then
				CurrentCamera.Focus = BlendedFocusOverride
				CameraStacker.DidApplyRenderingOverride = true
			end
		end
	end
	
end
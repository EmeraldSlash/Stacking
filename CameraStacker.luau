--!strict

-- Camera Stacker
--
-- https://github.com/EmeraldSlash/CameraStacker
--
-- Created by Rio Manson-Hay (@EmeraldSlash)
--
-- Version: 6 (2026-05-29)

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
--                                                      (query helper functions)
-- .PriorityALowerThanB(APriority, BPriority)->boolean
-- .QueryBlendValuesLastFrameForPriority(Priority, IncludeSelf)->{[Blendable]: any}
--
--                                   (reference specific values from last frame)
-- .BlendValuesLastFrame: {[Blendable]: any}
-- .BlendValuesLastFrame_ByPriorityString: {[string]: {[Blendable]: any}}
-- .BlendValuesLastFrame_Base: {[Blendable]: any}
--
--                                                   (blending helper functions)
-- .Blend(LowPriorityValue, HighPriorityValue, Strength, Blendable)->(BlendedValue)
-- type BlendContext (AKA Ctx)
-- Ctx:Read(Blendable, ExclusiveLo)
-- Ctx:Write(Blendable, Value, ExclusiveLo, RenderingOnly)
-- Ctx:Existing(Blendable, ExclusiveLo, ExclusiveHi, RenderingOnly)
-- Ctx:Fresh(Blendable, Value, ExclusiveLo, ExclusiveHi, RenderingOnly)
--
--                             (reference camera cframe & focus from last frame)
-- .PreStackCameraCFrame: CFrame
-- .PreStackCameraFocus: CFrame
-- .PreOcclusionCameraCFrame: CFrame
-- .PreOcclusionCameraFocus: CFrame
-- .PostUpdateCameraCFrame: CFrame
-- .PostUpdateCameraFocus: CFrame
-- .RenderingOnlyCameraCFrame: CFrame
-- .RenderingOnlyCameraFocus: CFrame
-- .DidApplyRenderingOnly: boolean
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
-- Defining blendable values
--
-- vv Blendables are how blendable values get tracked by the camera stacker
-- system. There are some built-in Blendable values (for camera CFrame and
-- Focus), and you can create your own custom Blendables as well.
--
-- The built-in B_CFrame and B_Focus Blendables require non-nil blendable values
-- (as every frame the camera CFrame and Focus need to be set to some value),
-- but if you are using custom Blendables there is no restriction on whether
-- values can be nil or nit.
--
export type Blendable<T> = {
	-- vv This is the default value that will be blended from if there are no
	-- values in the stack below the current block. If you are making a custom
	-- Blendable, this is allowed to be nil.
	Default: T?;

	-- vv If set, prevents this Blendable from blending with Blendables in lower
	-- priority CameraBlocks. (It will blend with the default value instead.)
	ExclusiveLo: boolean?; -- Prevents using previous values.
	-- vv If set, prevents higher priority CameraBlocks from using this Blendable
	-- for blending. (They will blend with the default instead, or the blendable
	-- will be removed/unset.)
	ExclusiveHi: boolean?; -- Prevents propagation upwards.
	-- ^^ These fields are also available in CameraBlocks, where they will apply
	-- to all values in the CameraBlock instead of to individual Blendables,
	-- which is probably what you would prefer to use most of the time. I don't
	-- expect there to be many use cases where you would want to hardcode
	-- exclusivity into Blendables themselves, but it is supported nonetheless.

	-- vv If no Blend function is specified, then this will default to lerping
	-- (or fully replacing value if it is not a number, Vector3, or CFrame).
	Blend: ((LowPriority: T, HighPriority: T, HighStrength: number)->(T))?;

	-- vv This will be called once the value has finished being blended for all
	-- blocks. This should be used to "apply" the value, and it will be called
	-- redundantly every frame even if the value isn't changing.
	--
	-- IMPORTANT: If the blendable value was being applied with a non-nil value
	-- in the last frame, and is no longer applied in the current frame, then
	-- this function will be called with Value == nil so that it can do cleanup
	-- logic. Make sure to handle that case!!
	--
	Apply: ((Value: T?, CameraModule: any)->())?;

	-- vv If you wish this Blendable to support the AffectsRenderingOnly field
	-- (just like the built-in camera CFrame and Focus Blendables), you can
	-- enable that here by creating a copy of the Blendable that will be tracked
	-- separately and storing a reference to it in this field.
	--
	-- This Blendable needs only to be used as a table key by this module so
	-- technically it can just be an empty table. However, if your usage code
	-- wants to use it consider setting the Default field. And if you want to
	-- apply the rendering-only value, you can set the Apply function on it so
	-- that the module will call it in the usual way. (There are no guarantees
	-- about when the Apply function will run relative to other Blendable's Apply
	-- functions, so don't expect "rendering-only" Blendables to have their
	-- Apply functions called after "full" blendables.)
	--
	RenderingOnly: Blendable<T>?;
}

local function Def<T>(Value: T): T return Value end

-- vv These are used internally for CFrames that affect rendering only and avoid
-- creating feedback with the primary camera CFrame. You should only need to
-- reference these if you need to query those rendering-only CFrames.
CameraStacker.B_CFrame_RenderingOnly = Def<< Blendable<CFrame> >>({})
CameraStacker.B_Focus_RenderingOnly = Def<< Blendable<CFrame> >>({})

-- vv These are what you should be using in your own code, these are the
-- built-in blendables which define the camera's CFrame and Focus. These
-- Blendables' Default fields get set to the camera's pre-camera-stack values
-- every frame before blending.
CameraStacker.B_CFrame = Def<< Blendable<CFrame> >>({
	RenderingOnly = CameraStacker.B_CFrame_RenderingOnly;
})
CameraStacker.B_Focus = Def<< Blendable<CFrame> >>({
	RenderingOnly = CameraStacker.B_Focus_RenderingOnly;
})

-- vv These are examples of custom blendables you can create. And you can also
-- just use these directly.
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
	-- vv By default, the camera will animate both activation and deactivation
	-- transitions, and will use the same easing parameters for both.
	Duration: number?;
	EasingStyle: Enum.EasingStyle?;
	EasingDirection: Enum.EasingDirection?;
	EasingFunction: ((number, Enum.EasingStyle?, Enum.EasingDirection?)->(number))?;
	DisableInput: boolean?; -- Only when not transitioning, or as a fallback when transitioning.
	AffectRenderingOnly: boolean?;

	-- vv To disable a transition before or after, you can set its duration to 0.
	-- So to disable the activation transition (instant snap), you can set
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

	-- vv You can set this to prevent the tween from blocking CameraBlock
	-- deactivation. (So instead of tweening out it will just be removed
	-- immediately.)
	Cancelled: boolean?;

	-- vv If set, Cancelled will be set to true when the CB is destroyed. So
	-- destroying will cancel the tween.
	CancelOnDestroy: boolean?;

	-- vv Internal fields.
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
-- vv This type is the user-provided specification for a camera block.
export type CameraBlockBase = {
	-- vv Optional, can be used to store & look up the CameraBlock using some
	-- unique name. If provided, it will be registered under this Id.
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

	-- vv These two fields behave the same as the corresponding Blendable fields,
	-- but will force their behavior for all Blendables consumed or produced by
	-- this CameraBlock. A quick way to say "this CameraBlock is exclusive".
	ExclusiveLo: boolean?; -- Prevents using previous values.
	ExclusiveHi: boolean?; -- Prevents propagation upwards.

	-- vv (Frame ordering: 1st pass - state management & updates.) This function
	-- will be run every frame, after the CB has been activated via
	-- CB:SetActive(true). Ihis function should check CB.Active == false to know
	-- when the user has requested a deactivation. It should return true if the
	-- CB is done (has been deactivated and/or no longer needs to run updates
	-- every frame), or false if it should continue running in future frames. If
	-- this function is not set, the CB will be done immediately if CB.Active ==
	-- false.
	--
	-- This function should take the CameraBlock and the DeltaTime, and update
	-- the EVAL OUTPUT VALUES (defined further below). This function can actually
	-- be used to modify any field in the CB, excluding only the Priority field
	-- and internal fields.
	--
	Eval: ((CB: CameraBlock, DeltaTime: number)->(boolean))?;

	-- vv (Frame ordering: 2nd pass - blending.)
	--
	-- This table is primarily useful for "absolute" effects such as moving the
	-- camera to a particular location or reaching a particular value. (If you
	-- need "relative" effects - such as having granular control over blending,
	-- or dynamically referencing lower priority values, you should use the Blend
	-- function below.)
	--
	-- If you have an Eval function, it can write the blendable values it wants
	-- every frame to this table, then they will be applied in the blending pass.
	--
	-- Values in this table will be applied in the blending phase, if there is no
	-- Blender function (if there is a Blender function, then it can choose to
	-- read values from this table, or it can do something else). The
	-- BlendContext:Existing() method will also read from this table.
	--
	Blendables: {[Blendable<any>]: any};

	-- vv (Frame ordering: 2nd pass - blending.)
	--
	-- This function is primarily useful for "relative" effects such as camera
	-- shake or smooth transitions between different camera states.
	--
	-- This function will be run every frame in the blending stage, and should
	-- blend the values it wants to set with the values in the stack below it. It
	-- will be run after Eval, so Eval can update things and then this function
	-- can consume the results.
	--
	-- This function will completely take over the CameraBlock's blending
	-- process, so you will need to manually blend each Blendable, as things in
	-- the Blendables table above won't be automatically blended if this function
	-- is set.
	--
	-- To read and write Blendable values, this function must call methods on the
	-- BlendContext AKA Ctx object passed in as an argument:
	--[[
	local LowerPriorityValue = Ctx:Read(CFrameBlendable)
	local HigherPriorityValue = LowerPriorityValue * CFrame.new(0, 10, 0)
	Ctx:Write(CFrameBlendable, HigherPriorityValue)
	--]]
	-- And there is a helper function to quickly update a blendable in the
	-- default way:
	--[[
	Ctx:Existing(CFrameBlendable)
	--]]
	-- Or update it with a particular value:
	--[[
	Ctx:Fresh(CFrameBlendable, CFrame.new(100, 10, 250))
	--]]
	-- Also, if you need a blend/lerp function that handles most numeric data
	-- types and Blendables (which may define their own Blend functions), you can
	-- use this:
	--[[
	CameraStacker.Blend(LowPriorityValue, HighPriorityValue, Strength, Blendable).
	--]]
	--
	-- Finally, like the Eval function, this function can also return true in
	-- order to indicate that the CameraBlock is done. Moreover, it is allowed to
	-- change any of the values that the Eval function can change. However, the
	-- observable effects of all these things will be delayed until the next
	-- frame (unlike the Eval function whose effects will be immediate), because
	-- at this point in the frame we have already passed the point where the
	-- effects get applied, so if you need immediate responsiveness you should
	-- use the Eval function for that stuff. But, if you don't care about the
	-- responsiveness, it means you can just use this single function to do both
	-- eval & blending which is convenient!
	--
	Blender: ((Ctx: BlendContext, CB: CameraBlock, DeltaTime: number)->(boolean?))?;

	-- EVAL OUTPUT VALUES (these can be statically configured if Eval and Blend
	-- are not defined or do not modify them)
	--
	-- vv Defines the strength of how values in this block will be blended on top
	-- of whatever is beneath them. This ONLY affects value blending, it does
	-- not affect the logical camera stacking behaviour. If this unset, it will
	-- default to 1. This field gets used when you have Blendables that are
	-- blended automatically (e.g. you don't have a Blender function, or you
	-- don't call BlendContext:Existing/Fresh()), but if you are doing custom
	-- blending there is no requirement to use it.
	Strength: number?;
	--
	-- vv Defines whether camera input should be disabled or not. (Final
	-- per-frame result is the union of all camera blocks.)
	DisableInput: boolean?;
	--
	-- vv Defines whether the camera occlusion module should be disabled or not.
	-- (Final per-frame result is the union of all camera blocks.)
	DisableOcclusion: boolean?;
	--
	-- vv If true, the camera CFrame & focus output of this block will be applied
	-- to the camera after setting Camera.CFrame, and the original Camera.CFrame
	-- will be restored before the camera updates again. Useful for temporary
	-- effects layered on top of whatever camera is active and for which you wish
	-- to avoid feedback, e.g. screen shake.
	--
	-- This still respects the stacking behavior, and if a higher priority block
	-- takes over with AffectRenderingOnly=false, this block will be replaced by
	-- the higher block (so it won't be layered on top), and the higher block may
	-- upgrade the "rendering only" value to a "full" value so that the higher
	-- blocker can blend with it.
	--
	-- Code that wishes to query the values of CFrame/Focus last frame will get
	-- the "full CFrame" by default if it uses .B_CFrame, so if it wants to query
	-- the "rendering only CFrame" then it can read .B_CFrame_RenderingOnly first then
	-- fall back to .B_CFrame if it fails.
	--
	-- If you want to make custom Blendables be affected by this as well, you can
	-- use the Blendable.RenderingOnly field.
	--
	AffectRenderingOnly: boolean?;
}
-- vv This type is the initialized camera block which is ready to use.
export type CameraBlock = CameraBlockBase & {

	-- vv Set to true when should be in use. The CameraBlock may still be
	-- evaluating every frame even if this false however (e.g. if it wants to do
	-- a transition out animation).
	Active: boolean?;

	-- vv Set to true immediately when destroyed. We guarantee that if
	-- Destroyed==true then Active==false.
	Destroyed: boolean?;

	-- vv Debug info.
	Traceback: string;

	-- vv Commonly used constant values that are also stored inside
	-- CameraStacker.
	B_CFrame: Blendable<CFrame>;
	B_Focus: Blendable<CFrame>;
	B_CFrame_RenderingOnly: Blendable<CFrame>;
	B_Focus_RenderingOnly: Blendable<CFrame>;
	E_Tween: (CB: CameraBlock, DeltaTime: number)->(boolean);

	-- vv Setup E_Tween on this CameraBlock
	SetEval_Tween: (CB: CameraBlock, CBTweenInfo: CameraBlockTweenInfo)->(CameraBlock);

	-- vv Activate the CameraBlock, putting in the array of CameraBlocks to be
	-- updated every frame. If deactivating, it won't be removed from the array,
	-- instead it's more of a communication mechanism like "the user indicated
	-- they want this block to be deactivated".
	SetActive: (CB: CameraBlock, Active: boolean)->(CameraBlock);

	-- vv Destroy the block, deactivating it and setting Destroyed = true, and
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
		CB.UserData = CB.UserData or {}
		CB.Traceback = debug.traceback(nil, 2)
		setmetatable(CB, MetaCB)
		return CB
	end

	MetaCB.B_CFrame = CameraStacker.B_CFrame
	MetaCB.B_Focus = CameraStacker.B_Focus
	MetaCB.B_CFrame_RenderingOnly = CameraStacker.B_CFrame_RenderingOnly
	MetaCB.B_Focus_RenderingOnly = CameraStacker.B_Focus_RenderingOnly
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

export type BlendContext = {
	CB: CameraBlock;
	BlendedValues: {[Blendable<any>]: any};
	BlendedValuesSet: {[Blendable<any>]: boolean};
	NewExclusiveHi_ByBlendable: {[Blendable<any>]: boolean};
	WasExclusiveHi_ByBlendable: {[Blendable<any>]: boolean};

	Read: <T>(
		Ctx: BlendContext,
		Blendable: Blendable<T>,
		OverrideExclusiveLo: boolean?
	)->(T, boolean);
	Write: <T>(
		Ctx: BlendContext,
		Blendable: Blendable<T>,
		Value: T,
		OverrideExclusiveHi: boolean?,
		OverrideRenderingOnly: boolean?
	)->();
	Existing: <T>(
		Ctx: BlendContext,
		Blendable: Blendable<T>,
		OverrideExclusiveLo: boolean?,
		OverrideExclusiveHi: boolean?,
		OverrideRenderingOnly: boolean?
	)->();
	Fresh: <T>(
		Ctx: BlendContext,
		Blendable: Blendable<T>,
		Value: T,
		OverrideExclusiveLo: boolean?,
		OverrideExclusiveHi: boolean?,
		OverrideRenderingOnly: boolean?
	)->();
}
-- For perf reasons, we reuse the Ctx table and avoid using metatables.
local Ctx = {} :: BlendContext
function Ctx.Read<T>(
	Ctx: BlendContext,
	Blendable: Blendable<T>,
	OverrideExclusiveLo: boolean?
): (T, boolean)
	local CanUseLow = false
	if not Ctx.WasExclusiveHi_ByBlendable[Blendable] then
		if OverrideExclusiveLo ~= nil then
			CanUseLow = if OverrideExclusiveLo then true else false
		else
			CanUseLow =
				(not Ctx.CB.ExclusiveLo) and
				(not Blendable.ExclusiveLo)
		end
	end

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
			local BlendableRO: any = Blendable.RenderingOnly
			if Ctx.BlendedValuesSet[BlendableRO] then
				HasLow = true
				Low = Ctx.BlendedValues[BlendableRO]
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
function Ctx.Write<T>(
	Ctx: BlendContext,
	Blendable: Blendable<T>,
	Value: T,
	OverrideExclusiveHi: boolean?,
	OverrideRenderingOnly: boolean?
)
	local RenderingOnly
	if OverrideRenderingOnly ~= nil then
		RenderingOnly = if OverrideRenderingOnly then true else false
	else
		RenderingOnly = if Ctx.CB.AffectRenderingOnly then true else false
	end

	-- When writing, we will always clear the rendering only value unless it
	-- is being used.
	local BlendableRO: any = Blendable.RenderingOnly
	if not BlendableRO then
		Ctx.BlendedValues[Blendable] = Value
		Ctx.BlendedValuesSet[Blendable] = true

	elseif RenderingOnly then
		Ctx.BlendedValues[BlendableRO] = Value
		Ctx.BlendedValuesSet[BlendableRO] = true

	else
		Ctx.BlendedValues[BlendableRO] = nil
		Ctx.BlendedValuesSet[BlendableRO] = nil

		Ctx.BlendedValues[Blendable] = Value
		Ctx.BlendedValuesSet[Blendable] = true
	end

	-- Track exclusivity and the presence of blendables.
	Ctx.WasExclusiveHi_ByBlendable[Blendable] = nil
	if OverrideExclusiveHi ~= nil then
		Ctx.NewExclusiveHi_ByBlendable[Blendable] = if OverrideExclusiveHi then true else false
	else
		Ctx.NewExclusiveHi_ByBlendable[Blendable] = if Blendable.ExclusiveHi then true else false
	end
end
function Ctx.Existing<T>(
	Ctx: BlendContext,
	Blendable: Blendable<T>,
	OverrideExclusiveLo: boolean?,
	OverrideExclusiveHi: boolean?,
	OverrideRenderingOnly: boolean?
)
	local CB = Ctx.CB
	local Low = Ctx:Read(Blendable, OverrideExclusiveLo)
	local High = CB.Blendables[Blendable]
	local NewValue = CameraStacker.Blend(Low, High, CB.Strength, Blendable)
	Ctx:Write(Blendable, NewValue, OverrideExclusiveHi, OverrideRenderingOnly)
end
function Ctx.Fresh<T>(
	Ctx: BlendContext,
	Blendable: Blendable<T>,
	Value: T,
	OverrideExclusiveLo: boolean?,
	OverrideExclusiveHi: boolean?,
	OverrideRenderingOnly: boolean?
)
	local Low = Ctx:Read(Blendable, OverrideExclusiveLo)
	local NewValue = CameraStacker.Blend(Low, Value, CB.Strength, Blendable)
	Ctx:Write(Blendable, NewValue, OverrideExclusiveHi, OverrideRenderingOnly)
end

--
-- Internal setup & evaluation logic
--

local CB_Unknown: CameraBlock = ({
	Id = "UNKNOWN_FALLBACK";
	Traceback = "UNKNOWN_FALLBACK";
} :: any)
table.freeze(CB_Unknown)

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
			local CB: CameraBlock = CameraStacker.CBs_Active[#CameraStacker.CBs_Active] or CB_Unknown
			CB.Active = false
			table.remove(CameraStacker.CBs_Active, Index)
			Index -= 1

			-- The CameraBlock evaluation yielded, so let's warn.
			local Status = coroutine.status(Thread)
			if Status == "suspended" then
				warn(("CameraBlock Eval function performed a yielding operation. It should never yield. Id: %s, Trace:\n%s")
					:format(tostring(CB.Id), CB.Traceback))
			elseif Status == "dead" then
				warn(("CameraBlock Eval function threw an error. Id: %s, Trace:\n%s")
					:format(tostring(CB.Id), CB.Traceback))
			else
				warn(("CameraBlock Eval function caused thread to have invalid status: %s. Id: %s, Trace:\n%s")
					:format(tostring(Status), tostring(CB.Id), CB.Traceback))
			end
		end
	end

	if PRF_ON then debug.profileend() end
	return DisableInput, DisableOcclusion
end

local function CameraStackerBlend(
	InputCFrame: CFrame,
	InputFocus: CFrame,
	CameraModule,
	DeltaTime: number
): (CFrame, CFrame, CFrame?, CFrame?)
	if PRF_ON then debug.profilebegin("CameraStackerBlend") end

	CameraStacker.B_CFrame.Default = InputCFrame
	CameraStacker.B_Focus.Default = InputFocus

	-- The overrides must also be initialized to default values. We need to do
	-- this because even though the overrides' default values will never be read
	-- in this function, usage code may try to read them from
	-- BlendValuesLastFrame_* tables, or in other arbitrary situations.
	CameraStacker.B_CFrame_RenderingOnly.Default = InputCFrame
	CameraStacker.B_Focus_RenderingOnly.Default = InputFocus

	Ctx.BlendedValues = {
		[CameraStacker.B_CFrame] = InputCFrame;
		[CameraStacker.B_Focus] = InputFocus;
	}
	Ctx.BlendedValuesSet = {
		[CameraStacker.B_CFrame] = true;
		[CameraStacker.B_Focus] = true;
	}
	Ctx.WasExclusiveHi_ByBlendable = {}
	Ctx.NewExclusiveHi_ByBlendable = {}

	local BlendedValues_ByPriorityString = {}
	local BlendedValues_Base = table.clone(Ctx.BlendedValues)

	local Index = #CameraStacker.CBs_Active
	while true do
		local IndexDidComplete = true

		local Thread = task.spawn(function()
			while Index > 0 do
				IndexDidComplete = false

				local CB = CameraStacker.CBs_Active[Index]
				Ctx.CB = CB
				Ctx.NewExclusiveHi_ByBlendable = {}

				if CB.Blender then
					local Finished = CB.Blender(Ctx, CB, DeltaTime)
					if Finished then
						CB.Active = false
						table.remove(CameraStacker.CBs_Active, Index)
					end
				else
					for Blendable in CB.Blendables do
						Ctx:Existing(Blendable)
					end
				end

				-- Clean up blendables that were not set this block. (This table is
				-- being used to track whether blendables are being set or not in
				-- addition to whether they were actually ExclusiveHi or not.)
				for Blendable, WasExclusiveHi in Ctx.WasExclusiveHi_ByBlendable do
					local CanUseLow =
						(not CB.ExclusiveLo) and
						(not Blendable.ExclusiveLo) and
						(not WasExclusiveHi)

					if not CanUseLow then
						Ctx.BlendedValues[Blendable] = nil
						Ctx.BlendedValuesSet[Blendable] = nil

						local BlendableRO = Blendable.RenderingOnly
						if BlendableRO then
							Ctx.BlendedValues[BlendableRO] = nil
							Ctx.BlendedValuesSet[BlendableRO] = nil
						end
					end
				end

				-- Replace the previous "Was" table with the "New" table. (Actually clearing
				-- and swapping them for perf.)
				local Temp = Ctx.WasExclusiveHi_ByBlendable
				Ctx.WasExclusiveHi_ByBlendable = Ctx.NewExclusiveHi_ByBlendable
				Ctx.NewExclusiveHi_ByBlendable = Temp
				table.clear(Temp)

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
				BlendedValues_ByPriorityString[PriorityString] = table.clone(Ctx.BlendedValues)

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
			local CB: CameraBlock = CameraStacker.CBs_Active[#CameraStacker.CBs_Active] or CB_Unknown
			CB.Active = false
			table.remove(CameraStacker.CBs_Active, Index)
			Index -= 1

			-- The CameraBlock evaluation yielded, so let's warn.
			local Status = coroutine.status(Thread)
			if Status == "suspended" then
				warn(("CameraBlock Blend function performed a yielding operation. It should never yield. Id: %s, Trace:\n%s")
					:format(tostring(CB.Id), CB.Traceback))
			elseif Status == "dead" then
				warn(("CameraBlock Blend function threw an error. Id: %s, Trace:\n%s")
					:format(tostring(CB.Id), CB.Traceback))
			else
				warn(("CameraBlock Blend function caused thread to have invalid status: %s. Id: %s, Trace:\n%s")
					:format(tostring(Status), tostring(CB.Id), CB.Traceback))
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
			Blendable.Apply(Ctx.BlendedValues[Blendable], CameraModule)
		end
	end
	for Blendable, Value in CameraStacker.BlendValuesLastFrame do
		if (Value ~= nil) and (not Visited[Blendable]) then
			if Blendable.Apply then
				Blendable.Apply(nil, CameraModule)
			end
		end
	end
	CameraStacker.BlendValuesLastFrame = Visited
	CameraStacker.BlendValuesLastFrame_ByPriorityString = BlendedValues_ByPriorityString
	CameraStacker.BlendValuesLastFrame_Base = BlendedValues_Base

	local WarnAbout = {}
	if Ctx.BlendedValues[CameraStacker.B_CFrame] == nil then
		WarnAbout[#WarnAbout+1] = "B_CFrame"
		Ctx.BlendedValues[CameraStacker.B_CFrame] = InputCFrame
	end
	if Ctx.BlendedValues[CameraStacker.B_Focus] == nil then
		WarnAbout[#WarnAbout+1] = "B_Focus"
		Ctx.BlendedValues[CameraStacker.B_Focus] = InputFocus
	end
	if WarnAbout[1] then
		warn(("Required blendable value%s {%s} %s nil, %s being unset by a CameraBlock?"):format(
			if WarnAbout[2] then "s" else "",
			if WarnAbout[2] then "are" else "is",
			table.concat(WarnAbout, ","),
			if WarnAbout[2] then "are they" else "is it"))
	end

	if PRF_ON then debug.profileend() end

	return
		Ctx.BlendedValues[CameraStacker.B_CFrame],
		Ctx.BlendedValues[CameraStacker.B_Focus],
		Ctx.BlendedValues[CameraStacker.B_CFrame_RenderingOnly],
		Ctx.BlendedValues[CameraStacker.B_Focus_RenderingOnly]
end

CameraStacker.PreStackCameraCFrame = CFrame.identity
CameraStacker.PreStackCameraFocus = CFrame.identity

CameraStacker.PreOcclusionCameraCFrame = CFrame.identity
CameraStacker.PreOcclusionCameraFocus = CFrame.identity

CameraStacker.PostUpdateCameraCFrame = CFrame.identity
CameraStacker.PostUpdateCameraFocus = CFrame.identity

CameraStacker.RenderingOnlyCameraCFrame = CFrame.identity
CameraStacker.RenderingOnlyCameraFocus = CFrame.identity

CameraStacker.DidApplyRenderingOnly = false

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

			if CameraStacker.DidApplyRenderingOnly then
				CameraStacker.DidApplyRenderingOnly = false
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

			local BlendedCFrame, BlendedFocus, BlendedCFrame_RenderingOnly, BlendedFocus_RenderingOnly =
				CameraStackerBlend(NewCameraCFrame, NewCameraFocus, CameraModule, DeltaTime)

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

			-- Apply rendering only properties.
			CameraStacker.RenderingOnlyCameraCFrame = BlendedCFrame_RenderingOnly or NewCameraCFrame
			CameraStacker.RenderingOnlyCameraFocus = BlendedFocus_RenderingOnly or NewCameraFocus

			if BlendedCFrame_RenderingOnly then
				CurrentCamera.CFrame = BlendedCFrame_RenderingOnly
				CameraStacker.DidApplyRenderingOnly = true
			end
			if BlendedFocus_RenderingOnly then
				CurrentCamera.Focus = BlendedFocus_RenderingOnly
				CameraStacker.DidApplyRenderingOnly = true
			end
		end
	end
	
end
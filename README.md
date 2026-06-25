# Stacking

Library that provides flexible stacking behavior for any situation.

This system can handle pretty much anything you throw at it, so long as it's acceptable for the changes to be evaluated & applied within a single pass ordered evaluation.

This was originally designed to be used as a patch on Roblox's PlayerModule, but now it has been turned into a generic, reusable form with some extra helpers for doing the patching.

### Patching Info

Installation is done at runtime. All you need to do is require the module and call one of the patch functions.
Installing it on forked player scripts is recommended for stability, but you can use it on the latest dynamically updated PlayerModule if you really want to.

Here is some example code:
```luau
-- Installation at runtime.
local PlayerModule = game.Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule")
local Stacking = require(game.ReplicatedStorage.Share:WaitForChild("Stacking"))
Stacking.PatchPlayerModuleAuto(PlayerModule)

-- Usage.
local CameraModule = require(PlayerModule:WaitForChild("ControlModule"))
local Stack = CameraModule.Stack :: Stacking.Stack_CameraModulePatch
if Stack then

  -- Custom blendable property.
  local BlurEffect = Instance.new("BlurEffect")
  BlurEffect.Size = 0
  BlurEffect.Parent = workspace.CurrentCamera
  local B_Blur = Stack:BlendableNew<<number>>({
    Default = 0;
    Apply = function(Value)
      -- Value may be nil if the blendable is being unset (i.e. it was
      -- used last frame and is not used this frame.)
      BlurEffect.Size = Value or 0
    end;
  })

  local Block_Shake = Stack:BlockNew({
    -- Optional key to identify this block by and obtain it from other scripts.
    Id = "CameraShake";

    -- Use default priorities or use your own custom priorities, or mix both.
    -- Allows unlimited sub priorities.
    Priority = {Stack.Priorities.GameplayJuice, 10, 2};

    -- Prevent feedback by making the camera CFrame/focus changes invisible
    -- to the next frame.
    Transient = true;

    -- The main behavioural controller of this block, gets executed every frame.
    Evalulate = function(Block, Ctx)
      -- Let's only apply this block at strength based on math.sin() of current time.
      local Strength = (math.sin(tick()) + 1) / 2
      Ctx:AutoBlend(B_Blur, 24, Strength)
      -- Apply camera CFrame relative to the lower priority CFrame, in this case
      -- some dumb translational camera shake.
      local LowCFrame = Ctx:Read(Stack.B_CFrame)
      local ShakeDirection = CFrame.new(1, 1, 1)
      Ctx:Write(Stack.B_CFrame, LowCFrame * (ShakeDirection * Strength))

      local IsFinished = not Block.Active
      return IsFinished
    end;
  })
  
  -- Activate the camera block so that it starts running, then deactivate the
  -- camera shake after 3 seconds.
  Block_Shake:SetActive(true)
  task.wait(3)
  Block_Shake:SetActive(false)

  -- Let's create another camera block that runs a smooth transition tween instead.
  local Block_Shopkeeper = Stack:BlockNew({
    Id = "Shopkeeper";
    Priority = {Stack.Priorities.UI};
    Tween = {
      Duration = 0.5;
      EasingStyle = Enum.EasingStyle.Exponetial;
      EasingDirection = Enum.EasingDirection.Out;
    };
    Evaluate = function(Block, Ctx)
      local Strength, Done = Ctx:Tween(Block.Tween, Block.Active)
      if not Done then
        -- Ctx:TweenGetInOutValue() queries a value at different times in the
        -- tween's lifecycle e.g. when fully active, when going in, when going
        -- out.

        -- Prevent feedback when transitioning.
        Block.Transient = Ctx:TweenGetInOutValue(Block.Tween, false, true, true)

        -- Allow player to move the camera ONLY while transitioning out.
        Ctx:AutoFlag(Stack.B_DisableInput,
          Ctx:TweenGetInOutValue(Block.Tween, true, nil, false))

        -- Set values.
        Ctx:AutoBlend(Stack.B_CFrame, ShopkeeperCameraPart.CFrame, Strength)
        Ctx:AutoBlend(Stack.B_Focus, ShopkeeperCameraFocus.CFrame, Strength)
      end
      return Done
    end;
  })
  ShopkeeperHitboxEntered:Connect(function()
    Block_Shopkeeper:SetActive(true)
  end)
  ShopkeeperHitboxExited:Connect(function()
    Block_Shopkeeper:SetActive(false)
  end)
end
```

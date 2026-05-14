# CameraStacker
Roblox PlayerModule patch for flexible camera stacking.

This system can handle pretty much anything you throw at it, so long as it's acceptable for the changes to be evaluated & applied within the CameraModule's Update function.

Installation is done at runtime. All you need to do is require the module, and call the function it returns with the PlayerModule ModuleScript instance as the only argument.

Installing it on forked player scripts is recommended for stability, but you can use it on the latest dynamically updated PlayerModule if you really want to.

Two things on the to-do list: First, the current system of Blendables and Blends is a bit confusing (the ergonomics are alright but implementation and user communication are tough) - as the solution, I'd like to have clearly separate Blend and Values fields, and make Blends the canonical thing for whether something gets applied or not, possibly. Second, the CameraStacker can only be used on the PlayerModule/default camera itself, but really it is a more generic system that could be applied to any output, and the PlayerModule/camera part is just a specal use case, so maybe those two components should be separated.

Here is some example code (last updated for version 5):
```luau
-- Installation at runtime.
local PlayerModule = game.Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule")
local Patch_CameraStacker = require(game.ReplicatedStorage:WaitForChild("CameraStacker"))
Patch_CameraStacker(PlayerModule)

-- Usage.
local CameraModule = require(PlayerModule:WaitForChild("ControlModule"))
local CameraStacker = CameraModule.CameraStacker
if CameraStacker then

  -- Custom blendable property.
  local BlurEffect = Instance.new("BlurEffect")
  BlurEffect.Size = 0
  BlurEffect.Parent = workspace.CurrentCamera
  local B_Blur: CameraStacker.Blendable<number> = {
    Default = 0;
    Apply = function(Value)
      -- Value may be nil if the blendable is being unset because it was
      -- used last frame and not used this frame.
      BlurEffect.Size = Value or 0
    end;
  }

  local CameraBlock_Shake = CameraStacker.CameraBlockNew({
    -- Optional key to identify this block by and obtain it from other scripts.
    Id = "CameraShake";

    -- Use default priorities or use your own custom priorities, or mix both.
    -- Allows unlimited sub priorities.
    Priority = {CameraStacker.P_GameplayJuice, 10, 2};

    -- Set the "non-relative" / "absolute" blendable values this block uses.
    -- ("Relative" blendable values are handled by Blenders instead.)
    Blendables = {
      [B_Blur] = 24;
    };

    -- Prevent feedback by making the camera CFrame/focus changes invisible
    -- to the next frame.
    AffectRenderingOnly = true;

    -- The main behavioural controller of this block, gets executed every frame.
    Eval = function(CameraBlock, DeltaTime)
      -- Let's only apply this block at strength based on math.sin() of current time.
      CameraBlock.Strength = (math.sin(tick()) + 1) / 2

      -- You can ignore this, it is relevant to Blends's B_CFrame function below.
      --CameraBlock.Blendables[CameraStacker.B_CFrame] = CFrame.new(1, 1, 1)
      --CameraBlock.UserData.ShakeDirection = CFrame.new(1, 1, 1)
      
      -- Indicate when the block is done.
      local IsFinished = not CameraBlock.Active
      return IsFinished
    end;

    -- Custom blenders let us apply changes to blendables relative to lower
    -- priority blocks.
    Blenders = {
      [CameraStacker.B_CFrame] = function(CameraBlock, ValueLow)

        -- ValueLo for B_CFrame and B_Focus should be guaranteed, but may not be
        -- the case with other blendables if none have been set yet.
        assert(ValueLow)

        -- All valid approaches. But for the first one, it might be confusing
        -- for you if you start mixing "absolute" and "relative" blendable values!
        --local ShakeOirection = CameraBlock.Blendables[CameraStacker.B_CFrame]
        --local ShakeDirection = CameraBlock.UserData.ShakeDirection
        local ShakeDirection = CFrame.new(1, 1, 1)

        -- Apply some translational camera shake.
        return ValueLow * (ShakeDirection*CameraBlock.Strength)
      end
    };
  })
  
  -- Activate the camera block so that it starts running, then deactivate the
  -- camera shake after 3 seconds.
  CameraBlock_Shake:SetActive(true)
  task.wait(3)
  CameraBlock_Shake:SetActive(false)

  -- Let's create another camera block that runs a smooth transition tween instead.
  local CameraBlock_Shopkeeper = CameraStacker.CameraBlockNew({
    Id = "Shopkeeper";
    Priority = {CameraStacker.P_UI};
    Blendables = {
      [CameraStacker.B_CFrame] = ShopkeeperCameraPart.CFrame;
      [CameraStacker.B_Focus] = ShopkeeperFocusPart.CFrame;
    };
  -- Instead of defining an Eval function above, we use a helper to
  -- quickly produce the logic for an in/out transitioning tween.
  )}:SetEval_Tween({
    Duration = 0.5;
    EasingStyle = Enum.EasingStyle.Exponetial;
    EasingDirection = Enum.EasingDirection.Out;
    DisableInput = true;
    DisableInputOut = false; -- Allow player to move camera while transitioning out.
    AffectRenderingOnly = false;
    AffectRenderingOnlyIn = true; -- Prevent feedback when transitioning.
    AffectRenderingOnlyOut = true; -- Prevent feedback when transitioning.
  })
  ShopkeeperHitboxEntered:Connect(function()
    CameraBlock_Shopkeeper:SetActive(true)
  end)
  ShopkeeperHitboxExited:Connect(function()
    CameraBlock_Shopkeeper:SetActive(false)
  end)
end
```

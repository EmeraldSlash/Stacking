# CameraStacker
Roblox PlayerModule patch for flexible camera stacking.

This system can handle pretty much anything you throw at it, so long as it's acceptable for the changes to be evaluated & applied within the CameraModule's Update function.

Installation is done at runtime. All you need to do is require the module, and call the function it returns with the PlayerModule ModuleScript instance as the only argument.

Installing it on forked player scripts is recommended for stability, but you can use it on the latest dynamically updated PlayerModule if you really want to.

Currently there is one limitation: There is no way to have changes that occur without affecting the next frame's Camera.CFrame. So there might be feedback problems if trying to do something like camera shake. I'm currently figuring out how to handle that scenario.

Here is some example code (last updated for version 2):
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
      BlurEffect.Size = Value
    end;
  }

  local CameraBlock_Shake = CameraStacker.CameraBlockNew({
    -- Optional key to identify this block by and obtain it from other scripts.
    Id = "CameraShake";

    -- Use default priorities or use your own custom priorities, or mix both.
    -- Allows unlimited sub priorities.
    Priority = {CameraStacker.P_GameplayJuice, 10, 2};

    -- Set the "non-relative" / "absolute" blendable values this block uses.
    -- ("Relative" blendable values are handled by CustomBlends instead.)
    Blendables = {
      [B_Blur] = 24;
    };

    -- The main behavioural controller of this block, gets executed every frame.
    Eval = function(CameraBlock, DeltaTime)
      -- Let's only apply this block at strength based on math.sin() of current time.
      CameraBlock.Strength = (math.sin(tick()) + 1) / 2
      
      -- Indicate when the block is done.
      local IsFinished = not CameraBlock.Active
      return IsFinished
    end;

    -- Custom blends let us apply changes to blendables relative to lower priority
    -- blocks.
    Blends = {
      [CameraStacker.B_CFrame] = function(CameraBlock, ValueLow)

        -- ValueLo for B_CFrame and B_Focus should be guaranteed, but may not be
        -- the case with other blendables if none have been set yet.
        assert(ValueLow)

        -- All valid approaches. But for the first one, it might be confusing
        -- for you if you start mixing "absolute" and "relative" blendable values!
        --local ShakeOirection = CameraBlock.Blendables[CameraStacker.B_CFrame]
        --local ShakeDirection = CameraBlock.CustomShakeDirectionField
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
  local CameraBlock_Shopkeeper = CameraStacker.CameraBlocknew({
    Id = "Shopkeeper";
    Priority = {CameraStacker.P_UI};
    Blendables = {
      [CameraStacker.B_CFrame] = ShopkeeperCameraPart.CFrame;
      [CameraStacker.B_Focus] = ShopkeeperFocusPart.CFrame;
    };
    -- Instead of defining an Eval function above, we instead use a helper
    -- to quickly produce the logic for an in/out transitioning tween.
  )}:SetEval_Tween({
    Duration = 0.5;
    EasingStyle = Enum.EasingStyle.Exponetial;
    EasingDirection = Enum.EasingDirection.Out;
    DisableInput = true;
    DisableInputOut = false; -- Allow player to move camera while transitioning out.
  })
  ShopkeeperHitboxEntered:Connect(function()
    CameraBlock_Shopkeeper:SetActive(true)
  end)
  ShopkeeperHitboxExited:Connect(function()
    CameraBlock_Shopkeeper:SetActive(false)
  end)
end
```

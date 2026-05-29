# CameraStacker
Roblox PlayerModule patch for flexible camera stacking.

This system can handle pretty much anything you throw at it, so long as it's acceptable for the changes to be evaluated & applied within the CameraModule's Update function.

Installation is done at runtime. All you need to do is require the module, and call the function it returns with the PlayerModule ModuleScript instance as the only argument.

Installing it on forked player scripts is recommended for stability, but you can use it on the latest dynamically updated PlayerModule if you really want to.

Here is some example code (last updated for version 6):
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
      -- Value may be nil if the blendable is being unset (i.e. it was
      -- used last frame and is not used this frame.)
      BlurEffect.Size = Value or 0
    end;
  }

  local CameraBlock_Shake = CameraStacker.CameraBlockNew({
    -- Optional key to identify this block by and obtain it from other scripts.
    Id = "CameraShake";

    -- Use default priorities or use your own custom priorities, or mix both.
    -- Allows unlimited sub priorities.
    Priority = {CameraStacker.P_GameplayJuice, 10, 2};

    -- Prevent feedback by making the camera CFrame/focus changes invisible
    -- to the next frame.
    AffectRenderingOnly = true;

    -- Set the "non-relative" / "absolute" blendable values this block uses.
    -- ("Relative" blendable values are handled by Blenders instead.)
    Blendables = {
      [B_Blur] = 24;
    };

    -- The main behavioural controller of this block, gets executed every frame.
    Eval = function(CameraBlock, DeltaTime)
      -- Let's only apply this block at strength based on math.sin() of current time.
      CameraBlock.Strength = (math.sin(tick()) + 1) / 2

      local IsFinished = not CameraBlock.Active
      return IsFinished
    end;

    -- Controls how blendables get blended with lower priority blocks.
    -- Can also use it as the main behavioural controller if you want (not demonstrated here),
    -- but will have 1 frame of latency with some aspects of the behavioural control.
    Blender = function(Ctx, CameraBlock, DeltaTime)
      
      -- Automatically blend the blur specified above.
      Ctx:Existing(B_Blur)

      -- Apply camera CFrame relative to the lower priority CFrame, in this case
-     -- some dumb translational camera shake.
      local LowCFrame = Ctx:Read(CameraStacker.B_CFrame)
      local ShakeDirection = CFrame.new(1, 1, 1)
      Ctx:Write(CameraStacker.B_CFrame, LowCFrame * (ShakeDirection * CameraBlock.Strength))

    end;
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

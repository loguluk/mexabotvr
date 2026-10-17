-- =====================================================================
-- arm_hub.lua — Hub & Movement Controller (WebSocket -> Rednet & Redstone)
-- Modem side: left
-- =====================================================================

local BRIDGE_URL = "wss://lucky-dolls-post.loca.lt"
local PROTOCOL   = "vr_arm_data"
local MODEM_SIDE = "left"

if peripheral.getType(MODEM_SIDE) ~= "modem" then
    error("Hub: Ender Modem not found on side '" .. MODEM_SIDE .. "'!")
end

rednet.open(MODEM_SIDE)
print("Hub: Rednet opened on [" .. MODEM_SIDE .. "]. Waiting for VR Bridge...")
print("Hub: Type '0' in console to reset all angles to zero.")

-- Hub movement redstone sides (change if your motor wiring differs)
local MOVE_SIDES = {
    forward  = "front",
    back     = "back",
    right    = "right",
    left     = "left"
}

local function applyMovement(move_y, move_x)
    if move_y > 0.3 then
        redstone.setOutput(MOVE_SIDES.forward, true)
        redstone.setOutput(MOVE_SIDES.back, false)
    elseif move_y < -0.3 then
        redstone.setOutput(MOVE_SIDES.forward, false)
        redstone.setOutput(MOVE_SIDES.back, true)
    else
        redstone.setOutput(MOVE_SIDES.forward, false)
        redstone.setOutput(MOVE_SIDES.back, false)
    end

    if move_x > 0.3 then
        redstone.setOutput(MOVE_SIDES.right, true)
        redstone.setOutput(MOVE_SIDES.left, false)
    elseif move_x < -0.3 then
        redstone.setOutput(MOVE_SIDES.right, false)
        redstone.setOutput(MOVE_SIDES.left, true)
    else
        redstone.setOutput(MOVE_SIDES.right, false)
        redstone.setOutput(MOVE_SIDES.left, false)
    end
end

-- Console thread for zero-reset command ('0')
local function keyboardInput()
    while true do
        local input = read()
        if input == "0" then
            print("Hub: Broadcasting zero-reset (0) to all turtles...")
            local zeroPacket = textutils.serializeJSON({
                connected = true,
                reset_zero = true,
                left = { tracked = true, pitch = 0, yaw = 0, is_behind = false, yaw_reverse = false },
                right = { tracked = true, pitch = 0, yaw = 0, is_behind = false, yaw_reverse = false }
            })
            rednet.broadcast(zeroPacket, PROTOCOL)
        end
    end
end

-- Main bridge relay & movement thread
local function bridgeRelay()
    while true do
        local ws, err = http.websocket(BRIDGE_URL)
        if not ws then
            print("Hub: Failed to connect to bridge (" .. tostring(err) .. "). Retrying in 3s...")
            sleep(3)
        else
            print("Hub: Connected to VR Bridge! Relaying data...")
            while true do
                local msg = ws.receive()
                if msg == nil then
                    print("Hub: Connection to bridge lost.")
                    break
                end

                -- Parse joystick input for hub movement
                local data = textutils.unserializeJSON(msg)
                if type(data) == "table" and data.left_joystick then
                    local joy = data.left_joystick
                    applyMovement(joy.move_y or 0, joy.move_x or 0)
                end

                -- CRITICAL: Broadcast telemetry to arm and arm_yaw turtles!
                rednet.broadcast(msg, PROTOCOL)
            end
            pcall(function() ws.close() end)
            sleep(3)
        end
    end
end

parallel.waitForAll(bridgeRelay, keyboardInput)
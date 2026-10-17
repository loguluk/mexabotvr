-- =====================================================================
-- arm.lua — turtle #1: ARM/pitch axis.
-- Модем подключен: right
-- =====================================================================

local PROTOCOL         = "vr_arm_data"
local SIDE             = "left"    -- "left" или "right" (какую руку читаем)
local MODEM_SIDE       = "right"   -- Эндер-модем справа
local PITCH_MIN, PITCH_MAX = 0, 180

local ANGLE_METHOD_CANDIDATES = { "setAngle", "setTargetAngle", "setDesiredAngle", "setLimit" }

local function fail(msg)
    error("arm.lua: " .. msg, 0)
end

if peripheral.getType(MODEM_SIDE) ~= "modem" then
    fail("no modem found on side '" .. MODEM_SIDE .. "'. An Ender Modem is required.")
end
rednet.open(MODEM_SIDE)
print("arm.lua: rednet opened on side '" .. MODEM_SIDE .. "'")

local mechanism = peripheral.wrap("bottom")
if mechanism == nil then
    fail('no peripheral below the turtle. The ARM mechanism must be on the bottom side.')
end

local mechanism_type = peripheral.getType("bottom")
local angle_method_name = nil
for _, name in ipairs(ANGLE_METHOD_CANDIDATES) do
    if type(mechanism[name]) == "function" then
        angle_method_name = name
        break
    end
end
if angle_method_name == nil then
    local available = {}
    for _, name in ipairs(peripheral.getMethods("bottom")) do
        available[#available + 1] = name
    end
    fail("peripheral '" .. tostring(mechanism_type) ..
         "' has no angle-set method. Tried: " .. table.concat(ANGLE_METHOD_CANDIDATES, ", ") ..
         ". Available methods: " .. table.concat(available, ", ") ..
         ". Confirm the mechanism API in-world.")
end
print("arm.lua: mechanism '" .. tostring(mechanism_type) ..
      "', angle method: " .. angle_method_name)

local function parse_side(data)
    if type(data) ~= "table" then
        return nil, "no '" .. SIDE .. "' section in JSON"
    end
    if type(data.tracked) ~= "boolean" then
        return nil, "field 'tracked' is missing or not a boolean"
    end
    if not data.tracked then
        return { tracked = false }
    end
    if type(data.pitch) ~= "number" then
        return nil, "field 'pitch' is missing or not a number"
    end
    if data.pitch < PITCH_MIN or data.pitch > PITCH_MAX then
        return nil, "pitch " .. tostring(data.pitch) .. " out of range [" ..
                    PITCH_MIN .. ", " .. PITCH_MAX .. "]"
    end
    local is_behind = data.is_behind == true
    return { tracked = true, pitch = data.pitch, is_behind = is_behind }
end

local last_pitch = nil
local function hold_position(reason)
    redstone.setOutput("front", false)
    if last_pitch ~= nil then
        mechanism[angle_method_name](last_pitch)
        print("arm.lua: tracking lost (" .. reason .. ") — holding pitch=" ..
              tostring(last_pitch) .. ", front=false")
    else
        print("arm.lua: tracking lost (" .. reason .. ") — no valid pose yet, not touching the mechanism")
    end
end

local function run()
    print("arm.lua: listening for rednet protocol '" .. PROTOCOL .. "' (side '" .. SIDE .. "')")
    while true do
        local senderId, msg, protocol = rednet.receive(PROTOCOL)
        if protocol == PROTOCOL then
            local data = textutils.unserializeJSON(msg)
            if type(data) == "table" then
                if data.reset_zero == true then
                    mechanism[angle_method_name](0)
                    redstone.setOutput("front", false)
                    last_pitch = 0
                    print("arm.lua: reset to 0 degrees received.")
                else
                    local cmd, perr = parse_side(data[SIDE])
                    if cmd == nil then
                        print("arm.lua: invalid telemetry: " .. tostring(perr))
                    elseif not cmd.tracked then
                        hold_position("tracked=false")
                    else
                        mechanism[angle_method_name](cmd.pitch)
                        redstone.setOutput("front", cmd.is_behind)
                        last_pitch = cmd.pitch
                    end
                end
            end
        end
    end
end

run()
-- =====================================================================
-- arm_yaw.lua — turtle #2: yaw axis (bottom redstone output for reverse)
-- Модем подключен: left
-- =====================================================================

local PROTOCOL         = "vr_arm_data"
local SIDE             = "left"    -- "left" или "right" (какую руку читаем)
local MODEM_SIDE       = "left"    -- Эндер-модем слева
local YAW_MIN, YAW_MAX = 0, 180

local ANGLE_METHOD_CANDIDATES = { "setAngle", "setTargetAngle", "setDesiredAngle", "setLimit" }

local function fail(msg)
    error("arm_yaw.lua: " .. msg, 0)
end

if peripheral.getType(MODEM_SIDE) ~= "modem" then
    fail("no modem found on side '" .. MODEM_SIDE .. "'. An Ender Modem is required.")
end
rednet.open(MODEM_SIDE)
print("arm_yaw.lua: rednet opened on side '" .. MODEM_SIDE .. "'")

-- Автоматический поиск торсионной пружины (например, torsion_spring_1)
local springName = nil
for _, name in ipairs(peripheral.getNames()) do
    if string.match(name, "torsion_spring") then
        springName = name
        break
    end
end
if springName == nil then
    fail("no torsion spring peripheral found.")
end

local spring = peripheral.wrap(springName)
local spring_type = peripheral.getType(springName)
local angle_method_name = nil
for _, name in ipairs(ANGLE_METHOD_CANDIDATES) do
    if type(spring[name]) == "function" then
        angle_method_name = name
        break
    end
end

if angle_method_name == nil then
    fail("peripheral '" .. springName .. "' (" .. tostring(spring_type) ..
         ") has no angle-set method.")
end

print("arm_yaw.lua: peripheral '" .. springName .. "' (" .. tostring(spring_type) ..
      "), angle method: " .. angle_method_name)

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
    if type(data.yaw) ~= "number" then
        return nil, "field 'yaw' is missing or not a number"
    end

    local target_yaw = data.yaw
    if target_yaw < YAW_MIN then target_yaw = YAW_MIN end
    if target_yaw > YAW_MAX then target_yaw = YAW_MAX end

    local yaw_reverse = data.yaw_reverse == true
    return { tracked = true, yaw = target_yaw, yaw_reverse = yaw_reverse }
end

local last_yaw = nil
local function hold_position(reason)
    redstone.setOutput("bottom", false)
    if last_yaw ~= nil then
        spring[angle_method_name](last_yaw)
        print("arm_yaw.lua: tracking lost (" .. reason .. ") — holding yaw=" ..
              tostring(last_yaw) .. ", bottom=false")
    end
end

local function run()
    print("arm_yaw.lua: listening for rednet protocol '" .. PROTOCOL .. "' (side '" .. SIDE .. "')")
    while true do
        local senderId, msg, protocol = rednet.receive(PROTOCOL)
        if protocol == PROTOCOL then
            local data = textutils.unserializeJSON(msg)
            if type(data) == "table" then
                if data.reset_zero == true then
                    spring[angle_method_name](0)
                    redstone.setOutput("bottom", false)
                    last_yaw = 0
                    print("arm_yaw.lua: reset to 0 degrees received.")
                else
                    local cmd, perr = parse_side(data[SIDE])
                    if cmd == nil then
                        print("arm_yaw.lua: invalid telemetry: " .. tostring(perr))
                    elseif not cmd.tracked then
                        hold_position("tracked=false")
                    else
                        spring[angle_method_name](cmd.yaw)
                        -- Подаём редстоун-сигнал ВНИЗ (bottom) при повороте внутрь
                        redstone.setOutput("bottom", cmd.yaw_reverse)
                        last_yaw = cmd.yaw
                    end
                end
            end
        end
    end
end

run()
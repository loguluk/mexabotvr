import asyncio
import json
import math
import sys
import time

# ============================ SETTINGS ============================
BRIDGE_HOST = "0.0.0.0"       # Прослушивать все интерфейсы
BRIDGE_PORT = 8765            # Порт WebSocket для черепах

POLL_HZ          = 20         # Частота отправки данных (20 Гц)

# ==================== КАЛИБРОВКА ПОЗИЦИИ (X - влево/вправо) ====================
SHOULDER_X_LEFT  = -0.12      # Смещение базы левой руки относительно центра шлема
SHOULDER_X_RIGHT =  0.12      # Смещение базы правой руки относительно центра шлема

SHOULDER_Y_OFFSET = -0.15     
SHOULDER_Z_OFFSET = 0.05      
PITCH_Y_OFFSET    = 0.10      

VR_RETRY_DELAY_S  = 3.0       # Задержка повтора подключения к VR (с)
# ==================================================================

SIDES = ("left", "right")


def _clamp(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


def calculate_enhanced_angles(controller_pos, hmd_pos, hmd_yaw_deg=0.0, side="left"):
    shoulder_x_offset = SHOULDER_X_LEFT if side == "left" else SHOULDER_X_RIGHT
    
    base_x = hmd_pos[0] + shoulder_x_offset
    base_y = hmd_pos[1] + SHOULDER_Y_OFFSET
    base_z = hmd_pos[2] + SHOULDER_Z_OFFSET

    dx = controller_pos[0] - base_x
    dy = controller_pos[1] - base_y
    dz = controller_pos[2] - base_z

    # --- Pitch ---
    horizontal_dist = math.sqrt(dx * dx + dz * dz)
    corrected_dy = dy + PITCH_Y_OFFSET
    pitch_offset = math.degrees(math.atan2(corrected_dy, horizontal_dist))
    pitch = _clamp(90.0 + pitch_offset, 1.0, 180.0)

    # --- Yaw (с исправленной инверсией влево-вправо через знак минус) ---
    yaw_rad = math.radians(-hmd_yaw_deg)
    local_x = dx * math.cos(yaw_rad) - dz * math.sin(yaw_rad)
    local_z = dx * math.sin(yaw_rad) + dz * math.cos(yaw_rad)

    angle_from_center_deg = -math.degrees(math.atan2(local_x, -local_z))

    if side == "left":
        exact_yaw = -angle_from_center_deg - 30.0
    else:
        exact_yaw = angle_from_center_deg - 30.0

    if exact_yaw < 0:
        yaw_reverse = True
        exact_yaw = abs(exact_yaw)
    else:
        yaw_reverse = False

    yaw = _clamp(exact_yaw, 0.0, 180.0)
    is_behind = dz > 0.0

    return round(pitch, 1), round(yaw, 1), is_behind, yaw_reverse


class AxisSmoother:
    def __init__(self, alpha=0.35):
        self.alpha = alpha
        self._state = {}

    def smooth(self, key, value):
        if value is None:
            self._state.pop(key, None)
            return None
        prev = self._state.get(key)
        if prev is None:
            self._state[key] = value
            return value
        s = self.alpha * value + (1.0 - self.alpha) * prev
        self._state[key] = s
        return round(s, 1)


class PicoTracker:
    def __init__(self):
        self._vr = None
        self._announced = set()

    def try_init(self):
        try:
            import openvr
        except ImportError:
            print("[VR] Module 'openvr' not installed: pip install openvr", flush=True)
            return False

        if not openvr.isRuntimeInstalled():
            print("[VR] Waiting for OpenVR / SteamVR...", flush=True)
            return False

        if not openvr.isHmdPresent():
            print("[VR] Waiting for PICO Connect...", flush=True)
            return False

        for app_type_name in ("VRApplication_Background", "VRApplication_Utility"):
            app_type = getattr(openvr, app_type_name, None)
            if app_type is None:
                continue
            try:
                self._vr = openvr.init(app_type)
                print(f"[VR] OpenVR session opened ({app_type_name})", flush=True)
                return True
            except Exception:
                pass

        self._vr = None
        return False

    def ensure_running(self):
        if self._vr is not None:
            return True
        return self.try_init()

    def poll(self):
        import openvr
        try:
            poses = self._vr.getDeviceToAbsoluteTrackingPose(
                openvr.TrackingUniverseStanding, 0.0, openvr.k_unMaxTrackedDeviceCount)
        except Exception:
            self._vr = None
            return {}

        if poses is None:
            return {}

        out = {}
        unassigned = []
        left_idx = None

        for i, pose in enumerate(poses):
            if not pose.bPoseIsValid:
                continue
            cls = self._vr.getTrackedDeviceClass(i)
            m = pose.mDeviceToAbsoluteTracking
            pos = (m[0][3], m[1][3], m[2][3])

            if cls == openvr.TrackedDeviceClass_HMD:
                yaw = math.degrees(math.atan2(m[0][2], m[2][2]))
                out["hmd"] = (pos, yaw)
                self._announce(i, "HMD", pos)
            elif cls == openvr.TrackedDeviceClass_Controller:
                role = self._vr.getControllerRoleForTrackedDeviceIndex(i)
                if role == openvr.TrackedControllerRole_LeftHand:
                    out["left"] = pos
                    left_idx = i
                    self._announce(i, "left controller", pos)
                elif role == openvr.TrackedControllerRole_RightHand:
                    out["right"] = pos
                    self._announce(i, "right controller", pos)
                else:
                    unassigned.append(pos)

        if "left" not in out and len(unassigned) > 0:
            out["left"] = unassigned.pop(0)
            self._announce(99, "left controller (fallback)", out["left"])
        if "right" not in out and len(unassigned) > 0:
            out["right"] = unassigned.pop(0)
            self._announce(98, "right controller (fallback)", out["right"])

        # Считывание левого джойстика для хаба движения (как в твоей рабочей версии)
        move_x, move_y = 0.0, 0.0
        if left_idx is not None:
            try:
                res = self._vr.getControllerState(left_idx)
                state = res[1] if isinstance(res, tuple) else res
                if state:
                    move_x = state.rAxis[0].x
                    move_y = state.rAxis[0].y
            except Exception:
                pass

        out["left_joystick"] = {"move_x": round(move_x, 2), "move_y": round(move_y, 2)}
        return out

    def _announce(self, idx, name, pos):
        if name not in self._announced:
            self._announced.add(name)
            print(f"[VR] Device {idx}: {name} connected ({pos[0]:.2f}, {pos[1]:.2f}, {pos[2]:.2f})", flush=True)


def build_telemetry(vr_data, smoother, sides=SIDES):
    payload = {"connected": True}
    payload["left_joystick"] = vr_data.get("left_joystick", {"move_x": 0.0, "move_y": 0.0})
    
    hmd = vr_data.get("hmd")
    for side in sides:
        ctrl = vr_data.get(side)
        if hmd is None or ctrl is None:
            payload[side] = {"tracked": False, "pitch": None, "yaw": None,
                             "is_behind": False, "yaw_reverse": False}
            continue
        hmd_pos, hmd_yaw = hmd
        pitch, yaw, is_behind, yaw_reverse = calculate_enhanced_angles(ctrl, hmd_pos, hmd_yaw, side=side)
        payload[side] = {
            "tracked": True,
            "pitch": smoother.smooth(f"{side}.pitch", pitch),
            "yaw":   smoother.smooth(f"{side}.yaw", yaw),
            "is_behind": is_behind,
            "yaw_reverse": yaw_reverse,
        }
    return payload


async def run_bridge():
    try:
        import websockets
    except ImportError:
        print("[BRIDGE] Module 'websockets' not installed: pip install websockets", flush=True)
        sys.exit(1)

    clients = set()
    tracker = PicoTracker()
    smoother = AxisSmoother()
    next_vr_retry_at = 0.0

    async def handler(ws):
        clients.add(ws)
        peer = getattr(ws, "remote_address", "?")
        print(f"[BRIDGE] Turtle connected: {peer} (Total: {len(clients)})", flush=True)
        try:
            async for _ in ws:
                pass
        except Exception:
            pass
        finally:
            clients.discard(ws)
            print(f"[BRIDGE] Turtle disconnected: {peer}", flush=True)

    async def broadcaster():
        nonlocal next_vr_retry_at
        period = 1.0 / POLL_HZ
        while True:
            vr_data = {}
            if tracker._vr is not None:
                vr_data = tracker.poll()
            elif time.monotonic() >= next_vr_retry_at:
                tracker.ensure_running()
                next_vr_retry_at = time.monotonic() + VR_RETRY_DELAY_S

            payload = json.dumps(build_telemetry(vr_data, smoother))
            for ws in list(clients):
                try:
                    await ws.send(payload)
                except Exception:
                    clients.discard(ws)
            await asyncio.sleep(period)

    print(f"[BRIDGE] WebSocket Server: ws://{BRIDGE_HOST}:{BRIDGE_PORT}", flush=True)
    async with websockets.serve(handler, BRIDGE_HOST, BRIDGE_PORT):
        await broadcaster()


if __name__ == "__main__":
    try:
        asyncio.run(run_bridge())
    except KeyboardInterrupt:
        print("\n[BRIDGE] Stopped", flush=True)
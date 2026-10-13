"""Control Tuya smart bulbs: local LAN first, Tuya Cloud as fallback.

Reads the files `python -m tinytuya wizard` writes in this folder:
  devices.json  - device ids, names and local keys
  tinytuya.json - Tuya IoT Cloud API key/secret/region (only needed for cloud fallback)
"""
import colorsys
import json
import os

import tinytuya

HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name):
    path = os.path.join(HERE, name)
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return json.load(f)


class Bulb:
    def __init__(self, info, cloud):
        self.id = info["id"]
        self.name = info.get("name") or self.id
        self.cloud = cloud
        self.local = None
        if info.get("key"):
            self.local = tinytuya.BulbDevice(
                self.id,
                address=info.get("ip") or "Auto",
                local_key=info["key"],
                version=float(info.get("version") or 3.3),
            )
            self.local.set_socketTimeout(2)
            self.local.set_socketRetryLimit(1)

    def _try_local(self, fn):
        if not self.local:
            return False
        try:
            result = fn(self.local)
        except Exception:
            return False
        return not (isinstance(result, dict) and "Error" in result)

    def _cloud(self, commands):
        if not self.cloud:
            raise RuntimeError(f"{self.name}: unreachable on LAN and no cloud credentials")
        result = self.cloud.sendcommand(self.id, {"commands": commands})
        if not result.get("success"):
            raise RuntimeError(f"{self.name}: cloud error {result.get('msg', result)}")

    def power(self, on):
        if not self._try_local(lambda d: d.turn_on() if on else d.turn_off()):
            self._cloud([{"code": "switch_led", "value": on}])

    def brightness(self, percent):
        percent = max(1, min(100, int(percent)))
        if not self._try_local(lambda d: d.set_brightness_percentage(percent)):
            self._cloud([
                {"code": "work_mode", "value": "white"},
                {"code": "bright_value_v2", "value": percent * 10},
            ])

    def colour(self, r, g, b):
        if not self._try_local(lambda d: d.set_colour(r, g, b)):
            h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            self._cloud([
                {"code": "work_mode", "value": "colour"},
                {"code": "colour_data_v2",
                 "value": {"h": int(h * 360), "s": int(s * 1000), "v": max(10, int(v * 1000))}},
            ])


def load_bulbs():
    devices = _load("devices.json")
    if not devices:
        raise FileNotFoundError(
            "devices.json not found. Run `python -m tinytuya wizard` in this folder first.")
    cfg = _load("tinytuya.json")
    cloud = None
    if cfg and cfg.get("apiKey"):
        cloud = tinytuya.Cloud(apiRegion=cfg["apiRegion"], apiKey=cfg["apiKey"],
                               apiSecret=cfg["apiSecret"], apiDeviceID=cfg.get("apiDeviceID"))
    return [Bulb(d, cloud) for d in devices]

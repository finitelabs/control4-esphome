"""Answers Bluetooth passkey requests for devices whose passkey a client hands the proxy."""

import esphome.codegen as cg
from esphome.components import esp32_ble
import esphome.config_validation as cv
from esphome.const import CONF_ID
from esphome.core import CORE
import esphome.final_validate as fv
from esphome.helpers import IS_WINDOWS

AUTO_LOAD = ["esp32_ble"]
DEPENDENCIES = ["esp32", "api", "bluetooth_proxy"]
CODEOWNERS = ["@finitelabs"]

ble_passkey_ns = cg.esphome_ns.namespace("ble_passkey")
BLEPasskey = ble_passkey_ns.class_("BLEPasskey", cg.Component)

CONFIG_SCHEMA = cv.All(
    cv.Schema(
        {
            cv.GenerateID(): cv.declare_id(BLEPasskey),
            cv.GenerateID(esp32_ble.CONF_BLE_ID): cv.use_id(esp32_ble.ESP32BLE),
        }
    ).extend(cv.COMPONENT_SCHEMA),
    cv.only_on_esp32,
    cv.require_esphome_version(2026, 11, 0),
)


def _final_validate(config):
    full = fv.full_config.get()
    ble = full.get("esp32_ble") or {}
    # The appliance shows the passkey and expects it typed in, which needs both settings.
    if str(ble.get("io_capability", "none")) != "keyboard_only":
        raise cv.Invalid(
            "ble_passkey needs 'io_capability: keyboard_only' under 'esp32_ble:'"
        )
    if str(ble.get("auth_req_mode", "")) != "bond_mitm":
        raise cv.Invalid(
            "ble_passkey needs 'auth_req_mode: bond_mitm' under 'esp32_ble:'"
        )
    # Re-encrypting a bonded device erases its keys on some ESP-IDF releases. ESPHome
    # only builds its fix with the ESP-IDF toolchain on a non-Windows host.
    if not CORE.using_toolchain_esp_idf or IS_WINDOWS:
        raise cv.Invalid(
            "ble_passkey needs the ESP-IDF toolchain on a macOS or Linux build host, "
            "so ESPHome keeps a device's pairing when it reconnects"
        )
    if not (full.get("api") or {}).get("custom_services", False):
        raise cv.Invalid("ble_passkey needs 'custom_services: true' under 'api:'")
    return config


FINAL_VALIDATE_SCHEMA = _final_validate


async def to_code(config):
    var = cg.new_Pvariable(config[CONF_ID])
    await cg.register_component(var, config)
    parent = await cg.get_variable(config[esp32_ble.CONF_BLE_ID])
    esp32_ble.register_gap_event_handler(parent, var)
    esp32_ble.register_gattc_event_handler(parent, var)

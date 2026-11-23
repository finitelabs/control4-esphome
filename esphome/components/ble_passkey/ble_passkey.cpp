#include "ble_passkey.h"

#if defined(USE_ESP32) && defined(USE_API)

#include <cstdio>
#include <cstring>
#include <memory>

#include "esphome/core/hal.h"
#include "esphome/core/helpers.h"
#include "esphome/core/log.h"

namespace esphome::ble_passkey {

static const char *const TAG = "ble_passkey";

static bool parse_address(const std::string &text, uint8_t *out) {
  unsigned int b[6];
  if (text.size() != 17 ||
      std::sscanf(text.c_str(), "%2x:%2x:%2x:%2x:%2x:%2x", &b[0], &b[1], &b[2], &b[3], &b[4], &b[5]) != 6) {
    return false;
  }
  for (int i = 0; i < 6; i++)
    out[i] = static_cast<uint8_t>(b[i]);
  return true;
}

static bool parse_passkey(const std::string &text, uint32_t *out) {
  if (text.size() != 6)
    return false;
  uint32_t value = 0;
  for (char c : text) {
    if (c < '0' || c > '9')
      return false;
    value = value * 10 + static_cast<uint32_t>(c - '0');
  }
  *out = value;
  return true;
}

static void format_address(const uint8_t *address, char *buf) {
  std::snprintf(buf, 18, "%02X:%02X:%02X:%02X:%02X:%02X", address[0], address[1], address[2], address[3], address[4],
                address[5]);
}

static bool is_bonded(const uint8_t *address) {
  int count = esp_ble_get_bond_device_num();
  if (count <= 0)
    return false;
  std::unique_ptr<esp_ble_bond_dev_t[]> list(new esp_ble_bond_dev_t[count]);
  if (esp_ble_get_bond_device_list(&count, list.get()) != ESP_OK)
    return false;
  for (int i = 0; i < count; i++) {
    if (std::memcmp(list[i].bd_addr, address, 6) == 0)
      return true;
  }
  return false;
}

void BLEPasskey::setup() {
  for (int &conn_id : this->conn_ids_)
    conn_id = NO_CONNECTION;
  this->pref_ = global_preferences->make_preference<PasskeyTable>(fnv1_hash("ble_passkey_v1"));
  if (!this->pref_.load(&this->table_))
    this->table_ = PasskeyTable{};
  // These names are how a client tells that this proxy has the add-on.
  this->register_service(&BLEPasskey::on_set_, "ble_passkey_set", {"address", "passkey"});
  this->register_service(&BLEPasskey::on_clear_, "ble_passkey_clear", {"address"});
}

void BLEPasskey::dump_config() {
  uint8_t count = 0;
  for (auto &entry : this->table_.entries) {
    if (entry.used)
      count++;
  }
  ESP_LOGCONFIG(TAG, "BLE Passkey:\n  Devices: %u of %u", count, MAX_ENTRIES);
}

PasskeyEntry *BLEPasskey::find_(const uint8_t *address) {
  for (auto &entry : this->table_.entries) {
    if (entry.used && std::memcmp(entry.address, address, 6) == 0)
      return &entry;
  }
  return nullptr;
}

void BLEPasskey::save_() {
  if (!this->pref_.save(&this->table_)) {
    ESP_LOGW(TAG, "Could not save the passkey table");
    return;
  }
  global_preferences->sync();
}

void BLEPasskey::on_set_(std::string address, std::string passkey) {
  uint8_t bda[6];
  uint32_t value;
  if (!parse_address(address, bda)) {
    ESP_LOGW(TAG, "ble_passkey_set: address must look like AA:BB:CC:DD:EE:FF");
    return;
  }
  if (!parse_passkey(passkey, &value)) {
    ESP_LOGW(TAG, "ble_passkey_set: passkey must be 6 digits");
    return;
  }
  PasskeyEntry *entry = this->find_(bda);
  if (entry == nullptr) {
    for (auto &candidate : this->table_.entries) {
      if (!candidate.used) {
        entry = &candidate;
        break;
      }
    }
  }
  if (entry == nullptr) {
    ESP_LOGW(TAG, "ble_passkey_set: table full (%u devices); clear one first", MAX_ENTRIES);
    return;
  }
  std::memcpy(entry->address, bda, 6);
  entry->passkey = value;
  entry->used = true;
  this->save_();
  char buf[18];
  format_address(bda, buf);
  ESP_LOGD(TAG, "Passkey set for %s", buf);
}

void BLEPasskey::on_clear_(std::string address) {
  uint8_t bda[6];
  if (!parse_address(address, bda)) {
    ESP_LOGW(TAG, "ble_passkey_clear: address must look like AA:BB:CC:DD:EE:FF");
    return;
  }
  PasskeyEntry *entry = this->find_(bda);
  if (entry != nullptr) {
    this->conn_ids_[entry - this->table_.entries] = NO_CONNECTION;
    *entry = PasskeyEntry{};
    this->save_();
  }
  esp_ble_remove_bond_device(bda);
  char buf[18];
  format_address(bda, buf);
  ESP_LOGD(TAG, "Passkey and pairing cleared for %s", buf);
}

void BLEPasskey::gap_event_handler(esp_gap_ble_cb_event_t event, esp_ble_gap_cb_param_t *param) {
  switch (event) {
    case ESP_GAP_BLE_PASSKEY_REQ_EVT: {
      PasskeyEntry *entry = this->find_(param->ble_security.ble_req.bd_addr);
      if (entry == nullptr)
        return;  // Not ours: left to whatever else answers it.
      char buf[18];
      format_address(entry->address, buf);
      ESP_LOGD(TAG, "Answering the passkey request from %s", buf);
      esp_ble_passkey_reply(param->ble_security.ble_req.bd_addr, true, entry->passkey);
      break;
    }
    case ESP_GAP_BLE_AUTH_CMPL_EVT: {
      if (this->find_(param->ble_security.auth_cmpl.bd_addr) == nullptr)
        return;
      char buf[18];
      format_address(param->ble_security.auth_cmpl.bd_addr, buf);
      if (param->ble_security.auth_cmpl.success) {
        ESP_LOGD(TAG, "Encrypted link to %s (mode %d)", buf, param->ble_security.auth_cmpl.auth_mode);
      } else {
        ESP_LOGW(TAG, "Pairing with %s failed, reason 0x%02X", buf, param->ble_security.auth_cmpl.fail_reason);
      }
      break;
    }
    default:
      break;
  }
}

void BLEPasskey::gattc_event_handler(esp_gattc_cb_event_t event, esp_gatt_if_t gattc_if,
                                     esp_ble_gattc_cb_param_t *param) {
  switch (event) {
    case ESP_GATTC_CONNECT_EVT: {
      PasskeyEntry *entry = this->find_(param->connect.remote_bda);
      if (entry == nullptr)
        return;
      size_t index = entry - this->table_.entries;
      if (this->conn_ids_[index] == param->connect.conn_id)
        return;
      this->conn_ids_[index] = param->connect.conn_id;
      // Encrypting before the proxy's service search lets it see characteristics the
      // device shows only on an encrypted link. Needs a pairing from an earlier link.
      if (!is_bonded(param->connect.remote_bda))
        return;
      char buf[18];
      format_address(param->connect.remote_bda, buf);
      ESP_LOGD(TAG, "Encrypting the link to %s at connect", buf);
      esp_ble_set_encryption(param->connect.remote_bda, ESP_BLE_SEC_ENCRYPT);
      break;
    }
    case ESP_GATTC_DISCONNECT_EVT: {
      PasskeyEntry *entry = this->find_(param->disconnect.remote_bda);
      if (entry != nullptr)
        this->conn_ids_[entry - this->table_.entries] = NO_CONNECTION;
      break;
    }
    case ESP_GATTC_SEARCH_CMPL_EVT:
      // Logged so a bench run can tell whether the search finished before encryption did.
      ESP_LOGV(TAG, "Service search complete on conn %u", param->search_cmpl.conn_id);
      break;
    default:
      break;
  }
}

}  // namespace esphome::ble_passkey

#endif

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

static void set_security(uint8_t io_cap, uint8_t auth_req) {
  if (esp_ble_gap_set_security_param(ESP_BLE_SM_IOCAP_MODE, &io_cap, sizeof(io_cap)) != ESP_OK ||
      esp_ble_gap_set_security_param(ESP_BLE_SM_AUTHEN_REQ_MODE, &auth_req, sizeof(auth_req)) != ESP_OK) {
    ESP_LOGW(TAG, "Could not change the Bluetooth security settings");
  }
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
    int index = entry - this->table_.entries;
    if (this->active_ == index)
      this->finish_("passkey cleared");
    this->waiting_[index] = false;
    this->conn_ids_[index] = NO_CONNECTION;
    *entry = PasskeyEntry{};
    this->save_();
  }
  esp_ble_remove_bond_device(bda);
  char buf[18];
  format_address(bda, buf);
  ESP_LOGD(TAG, "Passkey and pairing cleared for %s", buf);
}

void BLEPasskey::start_next_() {
  if (this->active_ != NONE_ACTIVE)
    return;
  for (int index = 0; index < MAX_ENTRIES; index++) {
    if (this->waiting_[index]) {
      this->waiting_[index] = false;
      this->start_(index);
      return;
    }
  }
}

void BLEPasskey::start_(int index) {
  PasskeyEntry &entry = this->table_.entries[index];
  char buf[18];
  format_address(entry.address, buf);
  this->active_ = index;
  // Keyboard only with bonding and MITM, no Secure Connections: the devices this is for
  // fall back to an unauthenticated pairing and fail when Secure Connections is asked for.
  // Set only for this one encryption so every other device keeps the stack's settings.
  set_security(ESP_IO_CAP_IN, ESP_LE_AUTH_REQ_BOND_MITM);
  // A bonded device re-encrypts with its stored keys; a new one pairs with the passkey.
  bool bonded = is_bonded(entry.address);
  ESP_LOGD(TAG, "%s the link to %s at connect", bonded ? "Encrypting" : "Pairing", buf);
  if (esp_ble_set_encryption(entry.address, bonded ? ESP_BLE_SEC_ENCRYPT : ESP_BLE_SEC_ENCRYPT_MITM) != ESP_OK) {
    this->finish_("could not start encryption");
    return;
  }
  this->set_timeout("security", SECURITY_TIMEOUT_MS, [this]() { this->finish_("timed out"); });
}

void BLEPasskey::finish_(const char *reason) {
  if (this->active_ == NONE_ACTIVE)
    return;
  this->cancel_timeout("security");
  set_security(this->restore_io_cap_, this->restore_auth_req_);
  char buf[18];
  format_address(this->table_.entries[this->active_].address, buf);
  ESP_LOGD(TAG, "Done with %s: %s", buf, reason);
  this->active_ = NONE_ACTIVE;
  this->start_next_();
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
      if (this->active_ == NONE_ACTIVE ||
          std::memcmp(this->table_.entries[this->active_].address, param->ble_security.auth_cmpl.bd_addr, 6) != 0)
        return;
      if (param->ble_security.auth_cmpl.success) {
        this->encrypted_[this->active_] = true;
        ESP_LOGD(TAG, "Encryption finished %s the service search",
                 this->searched_[this->active_] ? "after" : "before");
        this->finish_("link encrypted");
      } else {
        ESP_LOGW(TAG, "Pairing failed, reason 0x%02X", param->ble_security.auth_cmpl.fail_reason);
        this->finish_("pairing failed");
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
      this->encrypted_[index] = false;
      this->searched_[index] = false;
      // Encrypting before the proxy's service search lets it see characteristics the
      // device shows only on an encrypted link.
      this->waiting_[index] = true;
      this->start_next_();
      break;
    }
    case ESP_GATTC_DISCONNECT_EVT: {
      PasskeyEntry *entry = this->find_(param->disconnect.remote_bda);
      if (entry == nullptr)
        return;
      int index = entry - this->table_.entries;
      this->conn_ids_[index] = NO_CONNECTION;
      this->waiting_[index] = false;
      if (this->active_ == index)
        this->finish_("disconnected");
      break;
    }
    case ESP_GATTC_SEARCH_CMPL_EVT:
      for (int index = 0; index < MAX_ENTRIES; index++) {
        if (this->table_.entries[index].used && this->conn_ids_[index] == param->search_cmpl.conn_id &&
            !this->searched_[index]) {
          this->searched_[index] = true;
          ESP_LOGD(TAG, "Service search finished %s encryption", this->encrypted_[index] ? "after" : "before");
        }
      }
      break;
    default:
      break;
  }
}

}  // namespace esphome::ble_passkey

#endif

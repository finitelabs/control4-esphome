#pragma once

#include "esphome/core/defines.h"

#if defined(USE_ESP32) && defined(USE_API)

#include <string>

#include <esp_gap_ble_api.h>
#include <esp_gattc_api.h>

#include "esphome/components/api/custom_api_device.h"
#include "esphome/core/component.h"
#include "esphome/core/preferences.h"

namespace esphome::ble_passkey {

static constexpr uint8_t MAX_ENTRIES = 8;
static constexpr int NO_CONNECTION = -1;
static constexpr int NONE_ACTIVE = -1;
static constexpr uint32_t SECURITY_TIMEOUT_MS = 30000;

struct PasskeyEntry {
  uint8_t address[6];
  uint32_t passkey;
  bool used;
} __attribute__((packed));

struct PasskeyTable {
  PasskeyEntry entries[MAX_ENTRIES];
} __attribute__((packed));

class BLEPasskey : public Component, public api::CustomAPIDevice {
 public:
  void setup() override;
  void dump_config() override;
  float get_setup_priority() const override { return setup_priority::AFTER_BLUETOOTH; }

  // The settings the stack had before the add-on, put back after each of its pairings.
  void set_restore_security(uint8_t io_cap, uint8_t auth_req) {
    this->restore_io_cap_ = io_cap;
    this->restore_auth_req_ = auth_req;
  }

  void gap_event_handler(esp_gap_ble_cb_event_t event, esp_ble_gap_cb_param_t *param);
  void gattc_event_handler(esp_gattc_cb_event_t event, esp_gatt_if_t gattc_if, esp_ble_gattc_cb_param_t *param);

 protected:
  void on_set_(std::string address, std::string passkey);
  void on_clear_(std::string address);

  PasskeyEntry *find_(const uint8_t *address);
  void save_();
  void start_next_();
  void start_(int index);
  void finish_(const char *reason);

  PasskeyTable table_{};
  // The connection each entry was last seen on, so the copies of one CONNECT_EVT that
  // every client interface gets are handled once.
  int conn_ids_[MAX_ENTRIES];
  ESPPreferenceObject pref_;
  // Entries connected and waiting for their turn; one encryption runs at a time.
  bool waiting_[MAX_ENTRIES]{};
  int active_{NONE_ACTIVE};
  // Per connection, which of encryption and the proxy's service search finished first.
  bool encrypted_[MAX_ENTRIES]{};
  bool searched_[MAX_ENTRIES]{};
  uint8_t restore_io_cap_{ESP_IO_CAP_NONE};
  uint8_t restore_auth_req_{ESP_LE_AUTH_REQ_SC_MITM_BOND};
};

}  // namespace esphome::ble_passkey

#endif

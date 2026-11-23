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

  void gap_event_handler(esp_gap_ble_cb_event_t event, esp_ble_gap_cb_param_t *param);
  void gattc_event_handler(esp_gattc_cb_event_t event, esp_gatt_if_t gattc_if, esp_ble_gattc_cb_param_t *param);

 protected:
  void on_set_(std::string address, std::string passkey);
  void on_clear_(std::string address);

  PasskeyEntry *find_(const uint8_t *address);
  void save_();

  PasskeyTable table_{};
  // The connection each entry was last seen on, so the copies of one CONNECT_EVT that
  // every client interface gets are handled once.
  int conn_ids_[MAX_ENTRIES];
  ESPPreferenceObject pref_;
};

}  // namespace esphome::ble_passkey

#endif

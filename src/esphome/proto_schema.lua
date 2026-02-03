-- Generated Lua schema from protobuf descriptor set
-- Do not edit manually

--- @class ProtoSchema
local ProtoSchema = {}

--- Maps enum names to their definitions.
ProtoSchema.Enum = {}

--- Maps message names to their definitions.
--- @type table<string, ProtoMessageSchema>
ProtoSchema.Message = {}

--- Maps service names to their method definitions.
--- @type table<string, ProtoServiceSchema>
ProtoSchema.RPC = {}

--- ProtoWireType Maps protobuf wire types to their integer values.
--- @enum ProtoWireType
ProtoSchema.WireType = {
  VARINT = 0,
  FIXED64 = 1,
  LENGTH_DELIMITED = 2,
  FIXED32 = 5,
}

--- ProtoDataType Maps protobuf data types to their integer values.
--- @enum ProtoDataType
ProtoSchema.DataType = {
  DOUBLE = 1,
  FLOAT = 2,
  INT64 = 3,
  UINT64 = 4,
  INT32 = 5,
  FIXED64 = 6,
  FIXED32 = 7,
  BOOL = 8,
  STRING = 9,
  MESSAGE = 11,
  BYTES = 12,
  UINT32 = 13,
  ENUM = 14,
  SFIXED32 = 15,
  SFIXED64 = 16,
  SINT32 = 17,
  SINT64 = 18,
}

--- @class ProtoFieldSchema
--- @field name string The name of the field.
--- @field wireType ProtoWireType The protobuf wire type (see ProtoSchema.WireType).
--- @field type ProtoDataType The protobuf type (see ProtoSchema.DataType).
--- @field repeated boolean? Whether the field is repeated (optional).
--- @field subschema string? The subschema name for nested messages (optional).

--- @class ProtoMessageSchema
--- @field name string The name of the message type.
--- @field options table<string, any> Message options.
--- @field fields table<integer,  ProtoFieldSchema> A map of field numbers to ProtoFieldSchema definitions.

--- @class ProtoServiceMethodSchema
--- @field service string The name of the service.
--- @field method string The method name.
--- @field inputType ProtoMessageSchema The protobuf message type for the request.
--- @field outputType ProtoMessageSchema The protobuf message type for the response.

--- @class ProtoServiceSchema
--- @field [string] ProtoServiceMethodSchema Maps method names to their method definitions.

--- @class ProtoHelloRequest
--- @field client_info string?
--- @field api_version_major number?
--- @field api_version_minor number?

--- @class ProtoHelloResponse
--- @field api_version_major number?
--- @field api_version_minor number?
--- @field server_info string?
--- @field name string?

--- @class ProtoAuthenticationRequest
--- @field password string?

--- @class ProtoAuthenticationResponse
--- @field invalid_password boolean?

--- @class ProtoDisconnectRequest

--- @class ProtoDisconnectResponse

--- @class ProtoPingRequest

--- @class ProtoPingResponse

--- @class ProtoDeviceInfoRequest

--- @class ProtoAreaInfo
--- @field area_id number?
--- @field name string?

--- @class ProtoDeviceInfo
--- @field device_id number?
--- @field name string?
--- @field area_id number?

--- @class ProtoDeviceInfoResponse
--- @field uses_password boolean?
--- @field name string?
--- @field mac_address string?
--- @field esphome_version string?
--- @field compilation_time string?
--- @field model string?
--- @field has_deep_sleep boolean?
--- @field project_name string?
--- @field project_version string?
--- @field webserver_port number?
--- @field legacy_bluetooth_proxy_version number?
--- @field bluetooth_proxy_feature_flags number?
--- @field manufacturer string?
--- @field friendly_name string?
--- @field legacy_voice_assistant_version number?
--- @field voice_assistant_feature_flags number?
--- @field suggested_area string?
--- @field bluetooth_mac_address string?
--- @field api_encryption_supported boolean?
--- @field devices ProtoDeviceInfo[]?
--- @field areas ProtoAreaInfo[]?
--- @field area ProtoAreaInfo?
--- @field zwave_proxy_feature_flags number?
--- @field zwave_home_id number?

--- @class ProtoListEntitiesRequest

--- @class ProtoListEntitiesDoneResponse

--- @class ProtoSubscribeStatesRequest

--- @class ProtoListEntitiesBinarySensorResponse
--- @field object_id string?
--- @field key number?
--- @field name string?
--- @field device_class string?
--- @field is_status_binary_sensor boolean?
--- @field disabled_by_default boolean?
--- @field icon string?
--- @field entity_category ProtoEntityCategory?
--- @field device_id number?

--- @class ProtoBinarySensorStateResponse
--- @field key number?
--- @field state boolean?
--- @field missing_state boolean?
--- @field device_id number?

--- @class ProtoListEntitiesCoverResponse
--- @field object_id string?
--- @field key number?
--- @field name string?
--- @field assumed_state boolean?
--- @field supports_position boolean?
--- @field supports_tilt boolean?
--- @field device_class string?
--- @field disabled_by_default boolean?
--- @field icon string?
--- @field entity_category ProtoEntityCategory?
--- @field supports_stop boolean?
--- @field device_id number?

--- @class ProtoCoverStateResponse
--- @field key number?
--- @field legacy_state ProtoLegacyCoverState?
--- @field position number?
--- @field tilt number?
--- @field current_operation ProtoCoverOperation?
--- @field device_id number?

--- @class ProtoCoverCommandRequest
--- @field key number?
--- @field has_legacy_command boolean?
--- @field legacy_command ProtoLegacyCoverCommand?
--- @field has_position boolean?
--- @field position number?
--- @field has_tilt boolean?
--- @field tilt number?
--- @field stop boolean?
--- @field device_id number?

--- @class ProtoListEntitiesFanResponse
--- @field object_id string?
--- @field key number?
--- @field name string?
--- @field supports_oscillation boolean?
--- @field supports_speed boolean?
--- @field supports_direction boolean?
--- @field supported_speed_count number?
--- @field disabled_by_default boolean?
--- @field icon string?
--- @field entity_category ProtoEntityCategory?
--- @field supported_preset_modes string[]?
--- @field device_id number?

--- @class ProtoFanStateResponse
--- @field key number?
--- @field state boolean?
--- @field oscillating boolean?
--- @field speed ProtoFanSpeed?
--- @field direction ProtoFanDirection?
--- @field speed_level number?
--- @field preset_mode string?
--- @field device_id number?

--- @class ProtoFanCommandRequest
--- @field key number?
--- @field has_state boolean?
--- @field state boolean?
--- @field has_speed boolean?
--- @field speed ProtoFanSpeed?
--- @field has_oscillating boolean?
--- @field oscillating boolean?
--- @field has_direction boolean?
--- @field direction ProtoFanDirection?
--- @field has_speed_level boolean?
--- @field speed_level number?
--- @field has_preset_mode boolean?
--- @field preset_mode string?
--- @field device_id number?

--- @class ProtoListEntitiesLightResponse
--- @field object_id string?
--- @field key number?
--- @field name string?
--- @field supported_color_modes ProtoColorMode[]?
--- @field legacy_supports_brightness boolean?
--- @field legacy_supports_rgb boolean?
--- @field legacy_supports_white_value boolean?
--- @field legacy_supports_color_temperature boolean?
--- @field min_mireds number?
--- @field max_mireds number?
--- @field effects string[]?
--- @field disabled_by_default boolean?
--- @field icon string?
--- @field entity_category ProtoEntityCategory?
--- @field device_id number?

--- @class ProtoLightStateResponse
--- @field key number?
--- @field state boolean?
--- @field brightness number?
--- @field color_mode ProtoColorMode?
--- @field color_brightness number?
--- @field red number?
--- @field green number?
--- @field blue number?
--- @field white number?
--- @field color_temperature number?
--- @field cold_white number?
--- @field warm_white number?
--- @field effect string?
--- @field device_id number?

--- @class ProtoLightCommandRequest
--- @field key number?
--- @field has_state boolean?
--- @field state boolean?
--- @field has_brightness boolean?
--- @field brightness number?
--- @field has_color_mode boolean?
--- @field color_mode ProtoColorMode?
--- @field has_color_brightness boolean?
--- @field color_brightness number?
--- @field has_rgb boolean?
--- @field red number?
--- @field green number?
--- @field blue number?
--- @field has_white boolean?
--- @field white number?
--- @field has_color_temperature boolean?
--- @field color_temperature number?
--- @field has_cold_white boolean?
--- @field cold_white number?
--- @field has_warm_white boolean?
--- @field warm_white number?
--- @field has_transition_length boolean?
--- @field transition_length number?
--- @field has_flash_length boolean?
--- @field flash_length number?
--- @field has_effect boolean?
--- @field effect string?
--- @field device_id number?

--- @class ProtoListEntitiesSensorResponse
--- @field object_id string?
--- @field key number?
--- @field name string?
--- @field icon string?
--- @field unit_of_measurement string?
--- @field accuracy_decimals number?
--- @field force_update boolean?
--- @field device_class string?
--- @field state_class ProtoSensorStateClass?
--- @field legacy_last_reset_type ProtoSensorLastResetType?
--- @field disabled_by_default boolean?
--- @field entity_category ProtoEntityCategory?
--- @field device_id number?

--- @class ProtoSensorStateResponse
--- @field key number?
--- @field state number?
--- @field missing_state boolean?
--- @field device_id number?

--- @class ProtoListEntitiesSwitchResponse
--- @field object_id string?
--- @field key number?
--- @field name string?
--- @field icon string?
--- @field assumed_state boolean?
--- @field disabled_by_default boolean?
--- @field entity_category ProtoEntityCategory?
--- @field device_class string?
--- @field device_id number?

--- @class ProtoSwitchStateResponse
--- @field key number?
--- @field state boolean?
--- @field device_id number?

--- @class ProtoSwitchCommandRequest
--- @field key number?
--- @field state boolean?
--- @field device_id number?

--- @class ProtoListEntitiesTextSensorResponse
--- @field object_id string?
--- @field key number?
--- @field name string?
--- @field icon string?
--- @field disabled_by_default boolean?
--- @field entity_category ProtoEntityCategory?
--- @field device_class string?
--- @field device_id number?

--- @class ProtoTextSensorStateResponse
--- @field key number?
--- @field state string?
--- @field missing_state boolean?
--- @field device_id number?

--- @class ProtoSubscribeLogsRequest
--- @field level ProtoLogLevel?
--- @field dump_config boolean?

--- @class ProtoSubscribeLogsResponse
--- @field level ProtoLogLevel?
--- @field message string?

--- @class ProtoNoiseEncryptionSetKeyRequest
--- @field key string?

--- @class ProtoNoiseEncryptionSetKeyResponse
--- @field success boolean?

--- @class ProtoSubscribeHomeassistantServicesRequest

--- @class ProtoHomeassistantServiceMap
--- @field key string?
--- @field value string?

--- @class ProtoHomeassistantActionRequest
--- @field service string?
--- @field data ProtoHomeassistantServiceMap[]?
--- @field data_template ProtoHomeassistantServiceMap[]?
--- @field variables ProtoHomeassistantServiceMap[]?
--- @field is_event boolean?
--- @field call_id number?
--- @field wants_response boolean?
--- @field response_template string?

--- @class ProtoHomeassistantActionResponse
--- @field call_id number?
--- @field success boolean?
--- @field error_message string?
--- @field response_data string?

--- @class ProtoSubscribeHomeAssistantStatesRequest

--- @class ProtoSubscribeHomeAssistantStateResponse
--- @field entity_id string?
--- @field attribute string?
--- @field once boolean?

--- @class ProtoHomeAssistantStateResponse
--- @field entity_id string?
--- @field state string?
--- @field attribute string?

--- @class ProtoGetTimeRequest

--- @class ProtoGetTimeResponse
--- @field epoch_seconds number?
--- @field timezone string?

--- @class ProtoListEntitiesServicesArgument
--- @field name string?
--- @field type ProtoServiceArgType?

--- @class ProtoListEntitiesServicesResponse
--- @field name string?
--- @field key number?
--- @field args ProtoListEntitiesServicesArgument[]?
--- @field supports_response ProtoSupportsResponseType?

--- @class ProtoExecuteServiceArgument
--- @field bool_ boolean?
--- @field legacy_int number?
--- @field float_ number?
--- @field string_ string?
--- @field int_ number?
--- @field bool_array boolean[]?
--- @field int_array number[]?
--- @field float_array number[]?
--- @field string_array string[]?

--- @class ProtoExecuteServiceRequest
--- @field key number?
--- @field args ProtoExecuteServiceArgument[]?
--- @field call_id number?
--- @field return_response boolean?

--- @class ProtoExecuteServiceResponse
--- @field call_id number?
--- @field success boolean?
--- @field error_message string?
--- @field response_data string?

--- @class ProtoListEntitiesCameraResponse
--- @field object_id string?
--- @field key number?
--- @field name string?
--- @field disabled_by_default boolean?
--- @field icon string?
--- @field entity_category ProtoEntityCategory?
--- @field device_id number?

--- @class ProtoCameraImageResponse
--- @field key number?
--- @field data string?
--- @field done boolean?
--- @field device_id number?

--- @class ProtoCameraImageRequest
--- @field single boolean?
--- @field stream boolean?

--- @class ProtoListEntitiesClimateResponse
--- @field object_id string?
--- @field key number?
--- @field name string?
--- @field supports_current_temperature boolean?
--- @field supports_two_point_target_temperature boolean?
--- @field supported_modes ProtoClimateMode[]?
--- @field visual_min_temperature number?
--- @field visual_max_temperature number?
--- @field visual_target_temperature_step number?
--- @field legacy_supports_away boolean?
--- @field supports_action boolean?
--- @field supported_fan_modes ProtoClimateFanMode[]?
--- @field supported_swing_modes ProtoClimateSwingMode[]?
--- @field supported_custom_fan_modes string[]?
--- @field supported_presets ProtoClimatePreset[]?
--- @field supported_custom_presets string[]?
--- @field disabled_by_default boolean?
--- @field icon string?
--- @field entity_category ProtoEntityCategory?
--- @field visual_current_temperature_step number?
--- @field supports_current_humidity boolean?
--- @field supports_target_humidity boolean?
--- @field visual_min_humidity number?
--- @field visual_max_humidity number?
--- @field device_id number?
--- @field feature_flags number?

--- @class ProtoClimateStateResponse
--- @field key number?
--- @field mode ProtoClimateMode?
--- @field current_temperature number?
--- @field target_temperature number?
--- @field target_temperature_low number?
--- @field target_temperature_high number?
--- @field unused_legacy_away boolean?
--- @field action ProtoClimateAction?
--- @field fan_mode ProtoClimateFanMode?
--- @field swing_mode ProtoClimateSwingMode?
--- @field custom_fan_mode string?
--- @field preset ProtoClimatePreset?
--- @field custom_preset string?
--- @field current_humidity number?
--- @field target_humidity number?
--- @field device_id number?

--- @class ProtoClimateCommandRequest
--- @field key number?
--- @field has_mode boolean?
--- @field mode ProtoClimateMode?
--- @field has_target_temperature boolean?
--- @field target_temperature number?
--- @field has_target_temperature_low boolean?
--- @field target_temperature_low number?
--- @field has_target_temperature_high boolean?
--- @field target_temperature_high number?
--- @field unused_has_legacy_away boolean?
--- @field unused_legacy_away boolean?
--- @field has_fan_mode boolean?
--- @field fan_mode ProtoClimateFanMode?
--- @field has_swing_mode boolean?
--- @field swing_mode ProtoClimateSwingMode?
--- @field has_custom_fan_mode boolean?
--- @field custom_fan_mode string?
--- @field has_preset boolean?
--- @field preset ProtoClimatePreset?
--- @field has_custom_preset boolean?
--- @field custom_preset string?
--- @field has_target_humidity boolean?
--- @field target_humidity number?
--- @field device_id number?

--- @class ProtoListEntitiesWaterHeaterResponse
--- @field object_id string?
--- @field key number?
--- @field name string?
--- @field icon string?
--- @field disabled_by_default boolean?
--- @field entity_category ProtoEntityCategory?
--- @field device_id number?
--- @field min_temperature number?
--- @field max_temperature number?
--- @field target_temperature_step number?
--- @field supported_modes ProtoWaterHeaterMode[]?
--- @field supported_features number?

--- @class ProtoWaterHeaterStateResponse
--- @field key number?
--- @field current_temperature number?
--- @field target_temperature number?
--- @field mode ProtoWaterHeaterMode?
--- @field device_id number?
--- @field state number?
--- @field target_temperature_low number?
--- @field target_temperature_high number?

--- @class ProtoWaterHeaterCommandRequest
--- @field key number?
--- @field has_fields number?
--- @field mode ProtoWaterHeaterMode?
--- @field target_temperature number?
--- @field device_id number?
--- @field state number?
--- @field target_temperature_low number?
--- @field target_temperature_high number?

--- @class ProtoListEntitiesNumberResponse
--- @field object_id string?
--- @field key number?
--- @field name string?
--- @field icon string?
--- @field min_value number?
--- @field max_value number?
--- @field step number?
--- @field disabled_by_default boolean?
--- @field entity_category ProtoEntityCategory?
--- @field unit_of_measurement string?
--- @field mode ProtoNumberMode?
--- @field device_class string?
--- @field device_id number?

--- @class ProtoNumberStateResponse
--- @field key number?
--- @field state number?
--- @field missing_state boolean?
--- @field device_id number?

--- @class ProtoNumberCommandRequest
--- @field key number?
--- @field state number?
--- @field device_id number?

--- @class ProtoListEntitiesSelectResponse
--- @field object_id string?
--- @field key number?
--- @field name string?
--- @field icon string?
--- @field options string[]?
--- @field disabled_by_default boolean?
--- @field entity_category ProtoEntityCategory?
--- @field device_id number?

--- @class ProtoSelectStateResponse
--- @field key number?
--- @field state string?
--- @field missing_state boolean?
--- @field device_id number?

--- @class ProtoSelectCommandRequest
--- @field key number?
--- @field state string?
--- @field device_id number?

--- @class ProtoListEntitiesSirenResponse
--- @field object_id string?
--- @field key number?
--- @field name string?
--- @field icon string?
--- @field disabled_by_default boolean?
--- @field tones string[]?
--- @field supports_duration boolean?
--- @field supports_volume boolean?
--- @field entity_category ProtoEntityCategory?
--- @field device_id number?

--- @class ProtoSirenStateResponse
--- @field key number?
--- @field state boolean?
--- @field device_id number?

--- @class ProtoSirenCommandRequest
--- @field key number?
--- @field has_state boolean?
--- @field state boolean?
--- @field has_tone boolean?
--- @field tone string?
--- @field has_duration boolean?
--- @field duration number?
--- @field has_volume boolean?
--- @field volume number?
--- @field device_id number?

--- @class ProtoListEntitiesLockResponse
--- @field object_id string?
--- @field key number?
--- @field name string?
--- @field icon string?
--- @field disabled_by_default boolean?
--- @field entity_category ProtoEntityCategory?
--- @field assumed_state boolean?
--- @field supports_open boolean?
--- @field requires_code boolean?
--- @field code_format string?
--- @field device_id number?

--- @class ProtoLockStateResponse
--- @field key number?
--- @field state ProtoLockState?
--- @field device_id number?

--- @class ProtoLockCommandRequest
--- @field key number?
--- @field command ProtoLockCommand?
--- @field has_code boolean?
--- @field code string?
--- @field device_id number?

--- @class ProtoListEntitiesButtonResponse
--- @field object_id string?
--- @field key number?
--- @field name string?
--- @field icon string?
--- @field disabled_by_default boolean?
--- @field entity_category ProtoEntityCategory?
--- @field device_class string?
--- @field device_id number?

--- @class ProtoButtonCommandRequest
--- @field key number?
--- @field device_id number?

--- @class ProtoMediaPlayerSupportedFormat
--- @field format string?
--- @field sample_rate number?
--- @field num_channels number?
--- @field purpose ProtoMediaPlayerFormatPurpose?
--- @field sample_bytes number?

--- @class ProtoListEntitiesMediaPlayerResponse
--- @field object_id string?
--- @field key number?
--- @field name string?
--- @field icon string?
--- @field disabled_by_default boolean?
--- @field entity_category ProtoEntityCategory?
--- @field supports_pause boolean?
--- @field supported_formats ProtoMediaPlayerSupportedFormat[]?
--- @field device_id number?
--- @field feature_flags number?

--- @class ProtoMediaPlayerStateResponse
--- @field key number?
--- @field state ProtoMediaPlayerState?
--- @field volume number?
--- @field muted boolean?
--- @field device_id number?

--- @class ProtoMediaPlayerCommandRequest
--- @field key number?
--- @field has_command boolean?
--- @field command ProtoMediaPlayerCommand?
--- @field has_volume boolean?
--- @field volume number?
--- @field has_media_url boolean?
--- @field media_url string?
--- @field has_announcement boolean?
--- @field announcement boolean?
--- @field device_id number?

--- @class ProtoSubscribeBluetoothLEAdvertisementsRequest
--- @field flags number?

--- @class ProtoBluetoothServiceData
--- @field uuid string?
--- @field legacy_data number[]?
--- @field data string?

--- @class ProtoBluetoothLEAdvertisementResponse
--- @field address (number|Int64HighLow)?
--- @field name string?
--- @field rssi number?
--- @field service_uuids string[]?
--- @field service_data ProtoBluetoothServiceData[]?
--- @field manufacturer_data ProtoBluetoothServiceData[]?
--- @field address_type number?

--- @class ProtoBluetoothLERawAdvertisement
--- @field address (number|Int64HighLow)?
--- @field rssi number?
--- @field address_type number?
--- @field data string?

--- @class ProtoBluetoothLERawAdvertisementsResponse
--- @field advertisements ProtoBluetoothLERawAdvertisement[]?

--- @class ProtoBluetoothDeviceRequest
--- @field address (number|Int64HighLow)?
--- @field request_type ProtoBluetoothDeviceRequestType?
--- @field has_address_type boolean?
--- @field address_type number?

--- @class ProtoBluetoothDeviceConnectionResponse
--- @field address (number|Int64HighLow)?
--- @field connected boolean?
--- @field mtu number?
--- @field error number?

--- @class ProtoBluetoothGATTGetServicesRequest
--- @field address (number|Int64HighLow)?

--- @class ProtoBluetoothGATTDescriptor
--- @field uuid (number[]|Int64HighLow[])?
--- @field handle number?
--- @field short_uuid number?

--- @class ProtoBluetoothGATTCharacteristic
--- @field uuid (number[]|Int64HighLow[])?
--- @field handle number?
--- @field properties number?
--- @field descriptors ProtoBluetoothGATTDescriptor[]?
--- @field short_uuid number?

--- @class ProtoBluetoothGATTService
--- @field uuid (number[]|Int64HighLow[])?
--- @field handle number?
--- @field characteristics ProtoBluetoothGATTCharacteristic[]?
--- @field short_uuid number?

--- @class ProtoBluetoothGATTGetServicesResponse
--- @field address (number|Int64HighLow)?
--- @field services ProtoBluetoothGATTService[]?

--- @class ProtoBluetoothGATTGetServicesDoneResponse
--- @field address (number|Int64HighLow)?

--- @class ProtoBluetoothGATTReadRequest
--- @field address (number|Int64HighLow)?
--- @field handle number?

--- @class ProtoBluetoothGATTReadResponse
--- @field address (number|Int64HighLow)?
--- @field handle number?
--- @field data string?

--- @class ProtoBluetoothGATTWriteRequest
--- @field address (number|Int64HighLow)?
--- @field handle number?
--- @field response boolean?
--- @field data string?

--- @class ProtoBluetoothGATTReadDescriptorRequest
--- @field address (number|Int64HighLow)?
--- @field handle number?

--- @class ProtoBluetoothGATTWriteDescriptorRequest
--- @field address (number|Int64HighLow)?
--- @field handle number?
--- @field data string?

--- @class ProtoBluetoothGATTNotifyRequest
--- @field address (number|Int64HighLow)?
--- @field handle number?
--- @field enable boolean?

--- @class ProtoBluetoothGATTNotifyDataResponse
--- @field address (number|Int64HighLow)?
--- @field handle number?
--- @field data string?

--- @class ProtoSubscribeBluetoothConnectionsFreeRequest

--- @class ProtoBluetoothConnectionsFreeResponse
--- @field free number?
--- @field limit number?
--- @field allocated (number[]|Int64HighLow[])?

--- @class ProtoBluetoothGATTErrorResponse
--- @field address (number|Int64HighLow)?
--- @field handle number?
--- @field error number?

--- @class ProtoBluetoothGATTWriteResponse
--- @field address (number|Int64HighLow)?
--- @field handle number?

--- @class ProtoBluetoothGATTNotifyResponse
--- @field address (number|Int64HighLow)?
--- @field handle number?

--- @class ProtoBluetoothDevicePairingResponse
--- @field address (number|Int64HighLow)?
--- @field paired boolean?
--- @field error number?

--- @class ProtoBluetoothDeviceUnpairingResponse
--- @field address (number|Int64HighLow)?
--- @field success boolean?
--- @field error number?

--- @class ProtoUnsubscribeBluetoothLEAdvertisementsRequest

--- @class ProtoBluetoothDeviceClearCacheResponse
--- @field address (number|Int64HighLow)?
--- @field success boolean?
--- @field error number?

--- @class ProtoBluetoothScannerStateResponse
--- @field state ProtoBluetoothScannerState?
--- @field mode ProtoBluetoothScannerMode?
--- @field configured_mode ProtoBluetoothScannerMode?

--- @class ProtoBluetoothScannerSetModeRequest
--- @field mode ProtoBluetoothScannerMode?

--- @class ProtoSubscribeVoiceAssistantRequest
--- @field subscribe boolean?
--- @field flags number?

--- @class ProtoVoiceAssistantAudioSettings
--- @field noise_suppression_level number?
--- @field auto_gain number?
--- @field volume_multiplier number?

--- @class ProtoVoiceAssistantRequest
--- @field start boolean?
--- @field conversation_id string?
--- @field flags number?
--- @field audio_settings ProtoVoiceAssistantAudioSettings?
--- @field wake_word_phrase string?

--- @class ProtoVoiceAssistantResponse
--- @field port number?
--- @field error boolean?

--- @class ProtoVoiceAssistantEventData
--- @field name string?
--- @field value string?

--- @class ProtoVoiceAssistantEventResponse
--- @field event_type ProtoVoiceAssistantEvent?
--- @field data ProtoVoiceAssistantEventData[]?

--- @class ProtoVoiceAssistantAudio
--- @field data string?
--- @field end boolean?

--- @class ProtoVoiceAssistantTimerEventResponse
--- @field event_type ProtoVoiceAssistantTimerEvent?
--- @field timer_id string?
--- @field name string?
--- @field total_seconds number?
--- @field seconds_left number?
--- @field is_active boolean?

--- @class ProtoVoiceAssistantAnnounceRequest
--- @field media_id string?
--- @field text string?
--- @field preannounce_media_id string?
--- @field start_conversation boolean?

--- @class ProtoVoiceAssistantAnnounceFinished
--- @field success boolean?

--- @class ProtoVoiceAssistantWakeWord
--- @field id string?
--- @field wake_word string?
--- @field trained_languages string[]?

--- @class ProtoVoiceAssistantExternalWakeWord
--- @field id string?
--- @field wake_word string?
--- @field trained_languages string[]?
--- @field model_type string?
--- @field model_size number?
--- @field model_hash string?
--- @field url string?

--- @class ProtoVoiceAssistantConfigurationRequest
--- @field external_wake_words ProtoVoiceAssistantExternalWakeWord[]?

--- @class ProtoVoiceAssistantConfigurationResponse
--- @field available_wake_words ProtoVoiceAssistantWakeWord[]?
--- @field active_wake_words string[]?
--- @field max_active_wake_words number?

--- @class ProtoVoiceAssistantSetConfiguration
--- @field active_wake_words string[]?

--- @class ProtoListEntitiesAlarmControlPanelResponse
--- @field object_id string?
--- @field key number?
--- @field name string?
--- @field icon string?
--- @field disabled_by_default boolean?
--- @field entity_category ProtoEntityCategory?
--- @field supported_features number?
--- @field requires_code boolean?
--- @field requires_code_to_arm boolean?
--- @field device_id number?

--- @class ProtoAlarmControlPanelStateResponse
--- @field key number?
--- @field state ProtoAlarmControlPanelState?
--- @field device_id number?

--- @class ProtoAlarmControlPanelCommandRequest
--- @field key number?
--- @field command ProtoAlarmControlPanelStateCommand?
--- @field code string?
--- @field device_id number?

--- @class ProtoListEntitiesTextResponse
--- @field object_id string?
--- @field key number?
--- @field name string?
--- @field icon string?
--- @field disabled_by_default boolean?
--- @field entity_category ProtoEntityCategory?
--- @field min_length number?
--- @field max_length number?
--- @field pattern string?
--- @field mode ProtoTextMode?
--- @field device_id number?

--- @class ProtoTextStateResponse
--- @field key number?
--- @field state string?
--- @field missing_state boolean?
--- @field device_id number?

--- @class ProtoTextCommandRequest
--- @field key number?
--- @field state string?
--- @field device_id number?

--- @class ProtoListEntitiesDateResponse
--- @field object_id string?
--- @field key number?
--- @field name string?
--- @field icon string?
--- @field disabled_by_default boolean?
--- @field entity_category ProtoEntityCategory?
--- @field device_id number?

--- @class ProtoDateStateResponse
--- @field key number?
--- @field missing_state boolean?
--- @field year number?
--- @field month number?
--- @field day number?
--- @field device_id number?

--- @class ProtoDateCommandRequest
--- @field key number?
--- @field year number?
--- @field month number?
--- @field day number?
--- @field device_id number?

--- @class ProtoListEntitiesTimeResponse
--- @field object_id string?
--- @field key number?
--- @field name string?
--- @field icon string?
--- @field disabled_by_default boolean?
--- @field entity_category ProtoEntityCategory?
--- @field device_id number?

--- @class ProtoTimeStateResponse
--- @field key number?
--- @field missing_state boolean?
--- @field hour number?
--- @field minute number?
--- @field second number?
--- @field device_id number?

--- @class ProtoTimeCommandRequest
--- @field key number?
--- @field hour number?
--- @field minute number?
--- @field second number?
--- @field device_id number?

--- @class ProtoListEntitiesEventResponse
--- @field object_id string?
--- @field key number?
--- @field name string?
--- @field icon string?
--- @field disabled_by_default boolean?
--- @field entity_category ProtoEntityCategory?
--- @field device_class string?
--- @field event_types string[]?
--- @field device_id number?

--- @class ProtoEventResponse
--- @field key number?
--- @field event_type string?
--- @field device_id number?

--- @class ProtoListEntitiesValveResponse
--- @field object_id string?
--- @field key number?
--- @field name string?
--- @field icon string?
--- @field disabled_by_default boolean?
--- @field entity_category ProtoEntityCategory?
--- @field device_class string?
--- @field assumed_state boolean?
--- @field supports_position boolean?
--- @field supports_stop boolean?
--- @field device_id number?

--- @class ProtoValveStateResponse
--- @field key number?
--- @field position number?
--- @field current_operation ProtoValveOperation?
--- @field device_id number?

--- @class ProtoValveCommandRequest
--- @field key number?
--- @field has_position boolean?
--- @field position number?
--- @field stop boolean?
--- @field device_id number?

--- @class ProtoListEntitiesDateTimeResponse
--- @field object_id string?
--- @field key number?
--- @field name string?
--- @field icon string?
--- @field disabled_by_default boolean?
--- @field entity_category ProtoEntityCategory?
--- @field device_id number?

--- @class ProtoDateTimeStateResponse
--- @field key number?
--- @field missing_state boolean?
--- @field epoch_seconds number?
--- @field device_id number?

--- @class ProtoDateTimeCommandRequest
--- @field key number?
--- @field epoch_seconds number?
--- @field device_id number?

--- @class ProtoListEntitiesUpdateResponse
--- @field object_id string?
--- @field key number?
--- @field name string?
--- @field icon string?
--- @field disabled_by_default boolean?
--- @field entity_category ProtoEntityCategory?
--- @field device_class string?
--- @field device_id number?

--- @class ProtoUpdateStateResponse
--- @field key number?
--- @field missing_state boolean?
--- @field in_progress boolean?
--- @field has_progress boolean?
--- @field progress number?
--- @field current_version string?
--- @field latest_version string?
--- @field title string?
--- @field release_summary string?
--- @field release_url string?
--- @field device_id number?

--- @class ProtoUpdateCommandRequest
--- @field key number?
--- @field command ProtoUpdateCommand?
--- @field device_id number?

--- @class ProtoZWaveProxyFrame
--- @field data string?

--- @class ProtoZWaveProxyRequest
--- @field type ProtoZWaveProxyRequestType?
--- @field data string?

--- @class ProtoListEntitiesInfraredResponse
--- @field object_id string?
--- @field key number?
--- @field name string?
--- @field icon string?
--- @field disabled_by_default boolean?
--- @field entity_category ProtoEntityCategory?
--- @field device_id number?
--- @field capabilities number?

--- @class ProtoInfraredRFTransmitRawTimingsRequest
--- @field device_id number?
--- @field key number?
--- @field carrier_frequency number?
--- @field repeat_count number?
--- @field timings number[]?

--- @class ProtoInfraredRFReceiveEvent
--- @field device_id number?
--- @field key number?
--- @field timings number[]?

--- @enum ProtoAPISourceType
ProtoSchema.Enum.APISourceType = {
  SOURCE_BOTH = 0,
  SOURCE_SERVER = 1,
  SOURCE_CLIENT = 2,
}

--- @enum ProtoEntityCategory
ProtoSchema.Enum.EntityCategory = {
  ENTITY_CATEGORY_NONE = 0,
  ENTITY_CATEGORY_CONFIG = 1,
  ENTITY_CATEGORY_DIAGNOSTIC = 2,
}

--- @enum ProtoLegacyCoverState
ProtoSchema.Enum.LegacyCoverState = {
  LEGACY_COVER_STATE_OPEN = 0,
  LEGACY_COVER_STATE_CLOSED = 1,
}

--- @enum ProtoCoverOperation
ProtoSchema.Enum.CoverOperation = {
  COVER_OPERATION_IDLE = 0,
  COVER_OPERATION_IS_OPENING = 1,
  COVER_OPERATION_IS_CLOSING = 2,
}

--- @enum ProtoLegacyCoverCommand
ProtoSchema.Enum.LegacyCoverCommand = {
  LEGACY_COVER_COMMAND_OPEN = 0,
  LEGACY_COVER_COMMAND_CLOSE = 1,
  LEGACY_COVER_COMMAND_STOP = 2,
}

--- @enum ProtoFanSpeed
ProtoSchema.Enum.FanSpeed = {
  FAN_SPEED_LOW = 0,
  FAN_SPEED_MEDIUM = 1,
  FAN_SPEED_HIGH = 2,
}

--- @enum ProtoFanDirection
ProtoSchema.Enum.FanDirection = {
  FAN_DIRECTION_FORWARD = 0,
  FAN_DIRECTION_REVERSE = 1,
}

--- @enum ProtoColorMode
ProtoSchema.Enum.ColorMode = {
  COLOR_MODE_UNKNOWN = 0,
  COLOR_MODE_ON_OFF = 1,
  COLOR_MODE_LEGACY_BRIGHTNESS = 2,
  COLOR_MODE_BRIGHTNESS = 3,
  COLOR_MODE_WHITE = 7,
  COLOR_MODE_COLOR_TEMPERATURE = 11,
  COLOR_MODE_COLD_WARM_WHITE = 19,
  COLOR_MODE_RGB = 35,
  COLOR_MODE_RGB_WHITE = 39,
  COLOR_MODE_RGB_COLOR_TEMPERATURE = 47,
  COLOR_MODE_RGB_COLD_WARM_WHITE = 51,
}

--- @enum ProtoSensorStateClass
ProtoSchema.Enum.SensorStateClass = {
  STATE_CLASS_NONE = 0,
  STATE_CLASS_MEASUREMENT = 1,
  STATE_CLASS_TOTAL_INCREASING = 2,
  STATE_CLASS_TOTAL = 3,
  STATE_CLASS_MEASUREMENT_ANGLE = 4,
}

--- @enum ProtoSensorLastResetType
ProtoSchema.Enum.SensorLastResetType = {
  LAST_RESET_NONE = 0,
  LAST_RESET_NEVER = 1,
  LAST_RESET_AUTO = 2,
}

--- @enum ProtoLogLevel
ProtoSchema.Enum.LogLevel = {
  LOG_LEVEL_NONE = 0,
  LOG_LEVEL_ERROR = 1,
  LOG_LEVEL_WARN = 2,
  LOG_LEVEL_INFO = 3,
  LOG_LEVEL_CONFIG = 4,
  LOG_LEVEL_DEBUG = 5,
  LOG_LEVEL_VERBOSE = 6,
  LOG_LEVEL_VERY_VERBOSE = 7,
}

--- @enum ProtoServiceArgType
ProtoSchema.Enum.ServiceArgType = {
  SERVICE_ARG_TYPE_BOOL = 0,
  SERVICE_ARG_TYPE_INT = 1,
  SERVICE_ARG_TYPE_FLOAT = 2,
  SERVICE_ARG_TYPE_STRING = 3,
  SERVICE_ARG_TYPE_BOOL_ARRAY = 4,
  SERVICE_ARG_TYPE_INT_ARRAY = 5,
  SERVICE_ARG_TYPE_FLOAT_ARRAY = 6,
  SERVICE_ARG_TYPE_STRING_ARRAY = 7,
}

--- @enum ProtoSupportsResponseType
ProtoSchema.Enum.SupportsResponseType = {
  SUPPORTS_RESPONSE_NONE = 0,
  SUPPORTS_RESPONSE_OPTIONAL = 1,
  SUPPORTS_RESPONSE_ONLY = 2,
  SUPPORTS_RESPONSE_STATUS = 100,
}

--- @enum ProtoClimateMode
ProtoSchema.Enum.ClimateMode = {
  CLIMATE_MODE_OFF = 0,
  CLIMATE_MODE_HEAT_COOL = 1,
  CLIMATE_MODE_COOL = 2,
  CLIMATE_MODE_HEAT = 3,
  CLIMATE_MODE_FAN_ONLY = 4,
  CLIMATE_MODE_DRY = 5,
  CLIMATE_MODE_AUTO = 6,
}

--- @enum ProtoClimateFanMode
ProtoSchema.Enum.ClimateFanMode = {
  CLIMATE_FAN_ON = 0,
  CLIMATE_FAN_OFF = 1,
  CLIMATE_FAN_AUTO = 2,
  CLIMATE_FAN_LOW = 3,
  CLIMATE_FAN_MEDIUM = 4,
  CLIMATE_FAN_HIGH = 5,
  CLIMATE_FAN_MIDDLE = 6,
  CLIMATE_FAN_FOCUS = 7,
  CLIMATE_FAN_DIFFUSE = 8,
  CLIMATE_FAN_QUIET = 9,
}

--- @enum ProtoClimateSwingMode
ProtoSchema.Enum.ClimateSwingMode = {
  CLIMATE_SWING_OFF = 0,
  CLIMATE_SWING_BOTH = 1,
  CLIMATE_SWING_VERTICAL = 2,
  CLIMATE_SWING_HORIZONTAL = 3,
}

--- @enum ProtoClimateAction
ProtoSchema.Enum.ClimateAction = {
  CLIMATE_ACTION_OFF = 0,
  CLIMATE_ACTION_COOLING = 2,
  CLIMATE_ACTION_HEATING = 3,
  CLIMATE_ACTION_IDLE = 4,
  CLIMATE_ACTION_DRYING = 5,
  CLIMATE_ACTION_FAN = 6,
}

--- @enum ProtoClimatePreset
ProtoSchema.Enum.ClimatePreset = {
  CLIMATE_PRESET_NONE = 0,
  CLIMATE_PRESET_HOME = 1,
  CLIMATE_PRESET_AWAY = 2,
  CLIMATE_PRESET_BOOST = 3,
  CLIMATE_PRESET_COMFORT = 4,
  CLIMATE_PRESET_ECO = 5,
  CLIMATE_PRESET_SLEEP = 6,
  CLIMATE_PRESET_ACTIVITY = 7,
}

--- @enum ProtoWaterHeaterMode
ProtoSchema.Enum.WaterHeaterMode = {
  WATER_HEATER_MODE_OFF = 0,
  WATER_HEATER_MODE_ECO = 1,
  WATER_HEATER_MODE_ELECTRIC = 2,
  WATER_HEATER_MODE_PERFORMANCE = 3,
  WATER_HEATER_MODE_HIGH_DEMAND = 4,
  WATER_HEATER_MODE_HEAT_PUMP = 5,
  WATER_HEATER_MODE_GAS = 6,
}

--- @enum ProtoWaterHeaterCommandHasField
ProtoSchema.Enum.WaterHeaterCommandHasField = {
  WATER_HEATER_COMMAND_HAS_NONE = 0,
  WATER_HEATER_COMMAND_HAS_MODE = 1,
  WATER_HEATER_COMMAND_HAS_TARGET_TEMPERATURE = 2,
  WATER_HEATER_COMMAND_HAS_STATE = 4,
  WATER_HEATER_COMMAND_HAS_TARGET_TEMPERATURE_LOW = 8,
  WATER_HEATER_COMMAND_HAS_TARGET_TEMPERATURE_HIGH = 16,
}

--- @enum ProtoNumberMode
ProtoSchema.Enum.NumberMode = {
  NUMBER_MODE_AUTO = 0,
  NUMBER_MODE_BOX = 1,
  NUMBER_MODE_SLIDER = 2,
}

--- @enum ProtoLockState
ProtoSchema.Enum.LockState = {
  LOCK_STATE_NONE = 0,
  LOCK_STATE_LOCKED = 1,
  LOCK_STATE_UNLOCKED = 2,
  LOCK_STATE_JAMMED = 3,
  LOCK_STATE_LOCKING = 4,
  LOCK_STATE_UNLOCKING = 5,
}

--- @enum ProtoLockCommand
ProtoSchema.Enum.LockCommand = {
  LOCK_UNLOCK = 0,
  LOCK_LOCK = 1,
  LOCK_OPEN = 2,
}

--- @enum ProtoMediaPlayerState
ProtoSchema.Enum.MediaPlayerState = {
  MEDIA_PLAYER_STATE_NONE = 0,
  MEDIA_PLAYER_STATE_IDLE = 1,
  MEDIA_PLAYER_STATE_PLAYING = 2,
  MEDIA_PLAYER_STATE_PAUSED = 3,
  MEDIA_PLAYER_STATE_ANNOUNCING = 4,
  MEDIA_PLAYER_STATE_OFF = 5,
  MEDIA_PLAYER_STATE_ON = 6,
}

--- @enum ProtoMediaPlayerCommand
ProtoSchema.Enum.MediaPlayerCommand = {
  MEDIA_PLAYER_COMMAND_PLAY = 0,
  MEDIA_PLAYER_COMMAND_PAUSE = 1,
  MEDIA_PLAYER_COMMAND_STOP = 2,
  MEDIA_PLAYER_COMMAND_MUTE = 3,
  MEDIA_PLAYER_COMMAND_UNMUTE = 4,
  MEDIA_PLAYER_COMMAND_TOGGLE = 5,
  MEDIA_PLAYER_COMMAND_VOLUME_UP = 6,
  MEDIA_PLAYER_COMMAND_VOLUME_DOWN = 7,
  MEDIA_PLAYER_COMMAND_ENQUEUE = 8,
  MEDIA_PLAYER_COMMAND_REPEAT_ONE = 9,
  MEDIA_PLAYER_COMMAND_REPEAT_OFF = 10,
  MEDIA_PLAYER_COMMAND_CLEAR_PLAYLIST = 11,
  MEDIA_PLAYER_COMMAND_TURN_ON = 12,
  MEDIA_PLAYER_COMMAND_TURN_OFF = 13,
}

--- @enum ProtoMediaPlayerFormatPurpose
ProtoSchema.Enum.MediaPlayerFormatPurpose = {
  MEDIA_PLAYER_FORMAT_PURPOSE_DEFAULT = 0,
  MEDIA_PLAYER_FORMAT_PURPOSE_ANNOUNCEMENT = 1,
}

--- @enum ProtoBluetoothDeviceRequestType
ProtoSchema.Enum.BluetoothDeviceRequestType = {
  BLUETOOTH_DEVICE_REQUEST_TYPE_CONNECT = 0,
  BLUETOOTH_DEVICE_REQUEST_TYPE_DISCONNECT = 1,
  BLUETOOTH_DEVICE_REQUEST_TYPE_PAIR = 2,
  BLUETOOTH_DEVICE_REQUEST_TYPE_UNPAIR = 3,
  BLUETOOTH_DEVICE_REQUEST_TYPE_CONNECT_V3_WITH_CACHE = 4,
  BLUETOOTH_DEVICE_REQUEST_TYPE_CONNECT_V3_WITHOUT_CACHE = 5,
  BLUETOOTH_DEVICE_REQUEST_TYPE_CLEAR_CACHE = 6,
}

--- @enum ProtoBluetoothScannerState
ProtoSchema.Enum.BluetoothScannerState = {
  BLUETOOTH_SCANNER_STATE_IDLE = 0,
  BLUETOOTH_SCANNER_STATE_STARTING = 1,
  BLUETOOTH_SCANNER_STATE_RUNNING = 2,
  BLUETOOTH_SCANNER_STATE_FAILED = 3,
  BLUETOOTH_SCANNER_STATE_STOPPING = 4,
  BLUETOOTH_SCANNER_STATE_STOPPED = 5,
}

--- @enum ProtoBluetoothScannerMode
ProtoSchema.Enum.BluetoothScannerMode = {
  BLUETOOTH_SCANNER_MODE_PASSIVE = 0,
  BLUETOOTH_SCANNER_MODE_ACTIVE = 1,
}

--- @enum ProtoVoiceAssistantSubscribeFlag
ProtoSchema.Enum.VoiceAssistantSubscribeFlag = {
  VOICE_ASSISTANT_SUBSCRIBE_NONE = 0,
  VOICE_ASSISTANT_SUBSCRIBE_API_AUDIO = 1,
}

--- @enum ProtoVoiceAssistantRequestFlag
ProtoSchema.Enum.VoiceAssistantRequestFlag = {
  VOICE_ASSISTANT_REQUEST_NONE = 0,
  VOICE_ASSISTANT_REQUEST_USE_VAD = 1,
  VOICE_ASSISTANT_REQUEST_USE_WAKE_WORD = 2,
}

--- @enum ProtoVoiceAssistantEvent
ProtoSchema.Enum.VoiceAssistantEvent = {
  VOICE_ASSISTANT_ERROR = 0,
  VOICE_ASSISTANT_RUN_START = 1,
  VOICE_ASSISTANT_RUN_END = 2,
  VOICE_ASSISTANT_STT_START = 3,
  VOICE_ASSISTANT_STT_END = 4,
  VOICE_ASSISTANT_INTENT_START = 5,
  VOICE_ASSISTANT_INTENT_END = 6,
  VOICE_ASSISTANT_TTS_START = 7,
  VOICE_ASSISTANT_TTS_END = 8,
  VOICE_ASSISTANT_WAKE_WORD_START = 9,
  VOICE_ASSISTANT_WAKE_WORD_END = 10,
  VOICE_ASSISTANT_STT_VAD_START = 11,
  VOICE_ASSISTANT_STT_VAD_END = 12,
  VOICE_ASSISTANT_TTS_STREAM_START = 98,
  VOICE_ASSISTANT_TTS_STREAM_END = 99,
  VOICE_ASSISTANT_INTENT_PROGRESS = 100,
}

--- @enum ProtoVoiceAssistantTimerEvent
ProtoSchema.Enum.VoiceAssistantTimerEvent = {
  VOICE_ASSISTANT_TIMER_STARTED = 0,
  VOICE_ASSISTANT_TIMER_UPDATED = 1,
  VOICE_ASSISTANT_TIMER_CANCELLED = 2,
  VOICE_ASSISTANT_TIMER_FINISHED = 3,
}

--- @enum ProtoAlarmControlPanelState
ProtoSchema.Enum.AlarmControlPanelState = {
  ALARM_STATE_DISARMED = 0,
  ALARM_STATE_ARMED_HOME = 1,
  ALARM_STATE_ARMED_AWAY = 2,
  ALARM_STATE_ARMED_NIGHT = 3,
  ALARM_STATE_ARMED_VACATION = 4,
  ALARM_STATE_ARMED_CUSTOM_BYPASS = 5,
  ALARM_STATE_PENDING = 6,
  ALARM_STATE_ARMING = 7,
  ALARM_STATE_DISARMING = 8,
  ALARM_STATE_TRIGGERED = 9,
}

--- @enum ProtoAlarmControlPanelStateCommand
ProtoSchema.Enum.AlarmControlPanelStateCommand = {
  ALARM_CONTROL_PANEL_DISARM = 0,
  ALARM_CONTROL_PANEL_ARM_AWAY = 1,
  ALARM_CONTROL_PANEL_ARM_HOME = 2,
  ALARM_CONTROL_PANEL_ARM_NIGHT = 3,
  ALARM_CONTROL_PANEL_ARM_VACATION = 4,
  ALARM_CONTROL_PANEL_ARM_CUSTOM_BYPASS = 5,
  ALARM_CONTROL_PANEL_TRIGGER = 6,
}

--- @enum ProtoTextMode
ProtoSchema.Enum.TextMode = {
  TEXT_MODE_TEXT = 0,
  TEXT_MODE_PASSWORD = 1,
}

--- @enum ProtoValveOperation
ProtoSchema.Enum.ValveOperation = {
  VALVE_OPERATION_IDLE = 0,
  VALVE_OPERATION_IS_OPENING = 1,
  VALVE_OPERATION_IS_CLOSING = 2,
}

--- @enum ProtoUpdateCommand
ProtoSchema.Enum.UpdateCommand = {
  UPDATE_COMMAND_NONE = 0,
  UPDATE_COMMAND_UPDATE = 1,
  UPDATE_COMMAND_CHECK = 2,
}

--- @enum ProtoZWaveProxyRequestType
ProtoSchema.Enum.ZWaveProxyRequestType = {
  ZWAVE_PROXY_REQUEST_TYPE_SUBSCRIBE = 0,
  ZWAVE_PROXY_REQUEST_TYPE_UNSUBSCRIBE = 1,
  ZWAVE_PROXY_REQUEST_TYPE_HOME_ID_CHANGE = 2,
}

--- @type ProtoMessageSchema
ProtoSchema.Message.void = {
  name = "void",
  options = {},
  fields = {},
}

--- @type ProtoMessageSchema
ProtoSchema.Message.HelloRequest = {
  name = "HelloRequest",
  options = {
    id = 1,
    source = 2,
    no_delay = 1,
  },
  fields = {
    [1] = {
      name = "client_info",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "api_version_major",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [3] = {
      name = "api_version_minor",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.HelloResponse = {
  name = "HelloResponse",
  options = {
    id = 2,
    source = 1,
    no_delay = 1,
  },
  fields = {
    [1] = {
      name = "api_version_major",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [2] = {
      name = "api_version_minor",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [3] = {
      name = "server_info",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [4] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.AuthenticationRequest = {
  name = "AuthenticationRequest",
  options = {
    id = 3,
    source = 2,
    no_delay = 1,
  },
  fields = {
    [1] = {
      name = "password",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.AuthenticationResponse = {
  name = "AuthenticationResponse",
  options = {
    id = 4,
    source = 1,
    no_delay = 1,
  },
  fields = {
    [1] = {
      name = "invalid_password",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.DisconnectRequest = {
  name = "DisconnectRequest",
  options = {
    id = 5,
    source = 0,
    no_delay = 1,
  },
  fields = {},
}

--- @type ProtoMessageSchema
ProtoSchema.Message.DisconnectResponse = {
  name = "DisconnectResponse",
  options = {
    id = 6,
    source = 0,
    no_delay = 1,
  },
  fields = {},
}

--- @type ProtoMessageSchema
ProtoSchema.Message.PingRequest = {
  name = "PingRequest",
  options = {
    id = 7,
    source = 0,
  },
  fields = {},
}

--- @type ProtoMessageSchema
ProtoSchema.Message.PingResponse = {
  name = "PingResponse",
  options = {
    id = 8,
    source = 0,
  },
  fields = {},
}

--- @type ProtoMessageSchema
ProtoSchema.Message.DeviceInfoRequest = {
  name = "DeviceInfoRequest",
  options = {
    id = 9,
    source = 2,
  },
  fields = {},
}

--- @type ProtoMessageSchema
ProtoSchema.Message.AreaInfo = {
  name = "AreaInfo",
  options = {},
  fields = {
    [1] = {
      name = "area_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [2] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.DeviceInfo = {
  name = "DeviceInfo",
  options = {},
  fields = {
    [1] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [2] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [3] = {
      name = "area_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.DeviceInfoResponse = {
  name = "DeviceInfoResponse",
  options = {
    id = 10,
    source = 1,
  },
  fields = {
    [1] = {
      name = "uses_password",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [2] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [3] = {
      name = "mac_address",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [4] = {
      name = "esphome_version",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [5] = {
      name = "compilation_time",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [6] = {
      name = "model",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [7] = {
      name = "has_deep_sleep",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [8] = {
      name = "project_name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [9] = {
      name = "project_version",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [10] = {
      name = "webserver_port",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [11] = {
      name = "legacy_bluetooth_proxy_version",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [15] = {
      name = "bluetooth_proxy_feature_flags",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [12] = {
      name = "manufacturer",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [13] = {
      name = "friendly_name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [14] = {
      name = "legacy_voice_assistant_version",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [17] = {
      name = "voice_assistant_feature_flags",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [16] = {
      name = "suggested_area",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [18] = {
      name = "bluetooth_mac_address",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [19] = {
      name = "api_encryption_supported",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [20] = {
      name = "devices",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.MESSAGE,
      repeated = true,
      subschema = "DeviceInfo",
    },
    [21] = {
      name = "areas",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.MESSAGE,
      repeated = true,
      subschema = "AreaInfo",
    },
    [22] = {
      name = "area",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.MESSAGE,
      subschema = "AreaInfo",
    },
    [23] = {
      name = "zwave_proxy_feature_flags",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [24] = {
      name = "zwave_home_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ListEntitiesRequest = {
  name = "ListEntitiesRequest",
  options = {
    id = 11,
    source = 2,
  },
  fields = {},
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ListEntitiesDoneResponse = {
  name = "ListEntitiesDoneResponse",
  options = {
    id = 19,
    source = 1,
    no_delay = 1,
  },
  fields = {},
}

--- @type ProtoMessageSchema
ProtoSchema.Message.SubscribeStatesRequest = {
  name = "SubscribeStatesRequest",
  options = {
    id = 20,
    source = 2,
  },
  fields = {},
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ListEntitiesBinarySensorResponse = {
  name = "ListEntitiesBinarySensorResponse",
  options = {
    id = 12,
    source = 1,
    ifdef = "USE_BINARY_SENSOR",
    base_class = "InfoResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "object_id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [3] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [5] = {
      name = "device_class",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [6] = {
      name = "is_status_binary_sensor",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [7] = {
      name = "disabled_by_default",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [8] = {
      name = "icon",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [9] = {
      name = "entity_category",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- EntityCategory
    },
    [10] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.BinarySensorStateResponse = {
  name = "BinarySensorStateResponse",
  options = {
    id = 21,
    source = 1,
    ifdef = "USE_BINARY_SENSOR",
    no_delay = 1,
    base_class = "StateResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [3] = {
      name = "missing_state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [4] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ListEntitiesCoverResponse = {
  name = "ListEntitiesCoverResponse",
  options = {
    id = 13,
    source = 1,
    ifdef = "USE_COVER",
    base_class = "InfoResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "object_id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [3] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [5] = {
      name = "assumed_state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [6] = {
      name = "supports_position",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [7] = {
      name = "supports_tilt",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [8] = {
      name = "device_class",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [9] = {
      name = "disabled_by_default",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [10] = {
      name = "icon",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [11] = {
      name = "entity_category",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- EntityCategory
    },
    [12] = {
      name = "supports_stop",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [13] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.CoverStateResponse = {
  name = "CoverStateResponse",
  options = {
    id = 22,
    source = 1,
    ifdef = "USE_COVER",
    no_delay = 1,
    base_class = "StateResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "legacy_state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- LegacyCoverState
    },
    [3] = {
      name = "position",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [4] = {
      name = "tilt",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [5] = {
      name = "current_operation",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- CoverOperation
    },
    [6] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.CoverCommandRequest = {
  name = "CoverCommandRequest",
  options = {
    id = 30,
    source = 2,
    ifdef = "USE_COVER",
    no_delay = 1,
    base_class = "CommandProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "has_legacy_command",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [3] = {
      name = "legacy_command",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- LegacyCoverCommand
    },
    [4] = {
      name = "has_position",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [5] = {
      name = "position",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [6] = {
      name = "has_tilt",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [7] = {
      name = "tilt",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [8] = {
      name = "stop",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [9] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ListEntitiesFanResponse = {
  name = "ListEntitiesFanResponse",
  options = {
    id = 14,
    source = 1,
    ifdef = "USE_FAN",
    base_class = "InfoResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "object_id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [3] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [5] = {
      name = "supports_oscillation",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [6] = {
      name = "supports_speed",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [7] = {
      name = "supports_direction",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [8] = {
      name = "supported_speed_count",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.INT32,
    },
    [9] = {
      name = "disabled_by_default",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [10] = {
      name = "icon",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [11] = {
      name = "entity_category",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- EntityCategory
    },
    [12] = {
      name = "supported_preset_modes",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
      repeated = true,
    },
    [13] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.FanStateResponse = {
  name = "FanStateResponse",
  options = {
    id = 23,
    source = 1,
    ifdef = "USE_FAN",
    no_delay = 1,
    base_class = "StateResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [3] = {
      name = "oscillating",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [4] = {
      name = "speed",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- FanSpeed
    },
    [5] = {
      name = "direction",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- FanDirection
    },
    [6] = {
      name = "speed_level",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.INT32,
    },
    [7] = {
      name = "preset_mode",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [8] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.FanCommandRequest = {
  name = "FanCommandRequest",
  options = {
    id = 31,
    source = 2,
    ifdef = "USE_FAN",
    no_delay = 1,
    base_class = "CommandProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "has_state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [3] = {
      name = "state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [4] = {
      name = "has_speed",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [5] = {
      name = "speed",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- FanSpeed
    },
    [6] = {
      name = "has_oscillating",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [7] = {
      name = "oscillating",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [8] = {
      name = "has_direction",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [9] = {
      name = "direction",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- FanDirection
    },
    [10] = {
      name = "has_speed_level",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [11] = {
      name = "speed_level",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.INT32,
    },
    [12] = {
      name = "has_preset_mode",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [13] = {
      name = "preset_mode",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [14] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ListEntitiesLightResponse = {
  name = "ListEntitiesLightResponse",
  options = {
    id = 15,
    source = 1,
    ifdef = "USE_LIGHT",
    base_class = "InfoResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "object_id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [3] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [12] = {
      name = "supported_color_modes",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- ColorMode
      repeated = true,
    },
    [5] = {
      name = "legacy_supports_brightness",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [6] = {
      name = "legacy_supports_rgb",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [7] = {
      name = "legacy_supports_white_value",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [8] = {
      name = "legacy_supports_color_temperature",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [9] = {
      name = "min_mireds",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [10] = {
      name = "max_mireds",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [11] = {
      name = "effects",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
      repeated = true,
    },
    [13] = {
      name = "disabled_by_default",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [14] = {
      name = "icon",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [15] = {
      name = "entity_category",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- EntityCategory
    },
    [16] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.LightStateResponse = {
  name = "LightStateResponse",
  options = {
    id = 24,
    source = 1,
    ifdef = "USE_LIGHT",
    no_delay = 1,
    base_class = "StateResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [3] = {
      name = "brightness",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [11] = {
      name = "color_mode",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- ColorMode
    },
    [10] = {
      name = "color_brightness",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [4] = {
      name = "red",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [5] = {
      name = "green",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [6] = {
      name = "blue",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [7] = {
      name = "white",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [8] = {
      name = "color_temperature",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [12] = {
      name = "cold_white",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [13] = {
      name = "warm_white",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [9] = {
      name = "effect",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [14] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.LightCommandRequest = {
  name = "LightCommandRequest",
  options = {
    id = 32,
    source = 2,
    ifdef = "USE_LIGHT",
    no_delay = 1,
    base_class = "CommandProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "has_state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [3] = {
      name = "state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [4] = {
      name = "has_brightness",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [5] = {
      name = "brightness",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [22] = {
      name = "has_color_mode",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [23] = {
      name = "color_mode",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- ColorMode
    },
    [20] = {
      name = "has_color_brightness",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [21] = {
      name = "color_brightness",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [6] = {
      name = "has_rgb",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [7] = {
      name = "red",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [8] = {
      name = "green",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [9] = {
      name = "blue",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [10] = {
      name = "has_white",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [11] = {
      name = "white",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [12] = {
      name = "has_color_temperature",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [13] = {
      name = "color_temperature",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [24] = {
      name = "has_cold_white",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [25] = {
      name = "cold_white",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [26] = {
      name = "has_warm_white",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [27] = {
      name = "warm_white",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [14] = {
      name = "has_transition_length",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [15] = {
      name = "transition_length",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [16] = {
      name = "has_flash_length",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [17] = {
      name = "flash_length",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [18] = {
      name = "has_effect",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [19] = {
      name = "effect",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [28] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ListEntitiesSensorResponse = {
  name = "ListEntitiesSensorResponse",
  options = {
    id = 16,
    source = 1,
    ifdef = "USE_SENSOR",
    base_class = "InfoResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "object_id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [3] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [5] = {
      name = "icon",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [6] = {
      name = "unit_of_measurement",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [7] = {
      name = "accuracy_decimals",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.INT32,
    },
    [8] = {
      name = "force_update",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [9] = {
      name = "device_class",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [10] = {
      name = "state_class",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- SensorStateClass
    },
    [11] = {
      name = "legacy_last_reset_type",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- SensorLastResetType
    },
    [12] = {
      name = "disabled_by_default",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [13] = {
      name = "entity_category",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- EntityCategory
    },
    [14] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.SensorStateResponse = {
  name = "SensorStateResponse",
  options = {
    id = 25,
    source = 1,
    ifdef = "USE_SENSOR",
    no_delay = 1,
    base_class = "StateResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "state",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [3] = {
      name = "missing_state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [4] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ListEntitiesSwitchResponse = {
  name = "ListEntitiesSwitchResponse",
  options = {
    id = 17,
    source = 1,
    ifdef = "USE_SWITCH",
    base_class = "InfoResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "object_id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [3] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [5] = {
      name = "icon",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [6] = {
      name = "assumed_state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [7] = {
      name = "disabled_by_default",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [8] = {
      name = "entity_category",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- EntityCategory
    },
    [9] = {
      name = "device_class",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [10] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.SwitchStateResponse = {
  name = "SwitchStateResponse",
  options = {
    id = 26,
    source = 1,
    ifdef = "USE_SWITCH",
    no_delay = 1,
    base_class = "StateResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [3] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.SwitchCommandRequest = {
  name = "SwitchCommandRequest",
  options = {
    id = 33,
    source = 2,
    ifdef = "USE_SWITCH",
    no_delay = 1,
    base_class = "CommandProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [3] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ListEntitiesTextSensorResponse = {
  name = "ListEntitiesTextSensorResponse",
  options = {
    id = 18,
    source = 1,
    ifdef = "USE_TEXT_SENSOR",
    base_class = "InfoResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "object_id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [3] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [5] = {
      name = "icon",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [6] = {
      name = "disabled_by_default",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [7] = {
      name = "entity_category",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- EntityCategory
    },
    [8] = {
      name = "device_class",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [9] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.TextSensorStateResponse = {
  name = "TextSensorStateResponse",
  options = {
    id = 27,
    source = 1,
    ifdef = "USE_TEXT_SENSOR",
    no_delay = 1,
    base_class = "StateResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "state",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [3] = {
      name = "missing_state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [4] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.SubscribeLogsRequest = {
  name = "SubscribeLogsRequest",
  options = {
    id = 28,
    source = 2,
  },
  fields = {
    [1] = {
      name = "level",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- LogLevel
    },
    [2] = {
      name = "dump_config",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.SubscribeLogsResponse = {
  name = "SubscribeLogsResponse",
  options = {
    id = 29,
    source = 1,
    log = 0,
    no_delay = 0,
  },
  fields = {
    [1] = {
      name = "level",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- LogLevel
    },
    [3] = {
      name = "message",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.BYTES,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.NoiseEncryptionSetKeyRequest = {
  name = "NoiseEncryptionSetKeyRequest",
  options = {
    id = 124,
    source = 2,
    ifdef = "USE_API_NOISE",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.BYTES,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.NoiseEncryptionSetKeyResponse = {
  name = "NoiseEncryptionSetKeyResponse",
  options = {
    id = 125,
    source = 1,
    ifdef = "USE_API_NOISE",
  },
  fields = {
    [1] = {
      name = "success",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.SubscribeHomeassistantServicesRequest = {
  name = "SubscribeHomeassistantServicesRequest",
  options = {
    id = 34,
    source = 2,
    ifdef = "USE_API_HOMEASSISTANT_SERVICES",
  },
  fields = {},
}

--- @type ProtoMessageSchema
ProtoSchema.Message.HomeassistantServiceMap = {
  name = "HomeassistantServiceMap",
  options = {},
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "value",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.HomeassistantActionRequest = {
  name = "HomeassistantActionRequest",
  options = {
    id = 35,
    source = 1,
    ifdef = "USE_API_HOMEASSISTANT_SERVICES",
    no_delay = 1,
  },
  fields = {
    [1] = {
      name = "service",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "data",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.MESSAGE,
      repeated = true,
      subschema = "HomeassistantServiceMap",
    },
    [3] = {
      name = "data_template",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.MESSAGE,
      repeated = true,
      subschema = "HomeassistantServiceMap",
    },
    [4] = {
      name = "variables",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.MESSAGE,
      repeated = true,
      subschema = "HomeassistantServiceMap",
    },
    [5] = {
      name = "is_event",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [6] = {
      name = "call_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [7] = {
      name = "wants_response",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [8] = {
      name = "response_template",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.HomeassistantActionResponse = {
  name = "HomeassistantActionResponse",
  options = {
    id = 130,
    source = 2,
    ifdef = "USE_API_HOMEASSISTANT_ACTION_RESPONSES",
    no_delay = 1,
  },
  fields = {
    [1] = {
      name = "call_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [2] = {
      name = "success",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [3] = {
      name = "error_message",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [4] = {
      name = "response_data",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.BYTES,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.SubscribeHomeAssistantStatesRequest = {
  name = "SubscribeHomeAssistantStatesRequest",
  options = {
    id = 38,
    source = 2,
    ifdef = "USE_API_HOMEASSISTANT_STATES",
  },
  fields = {},
}

--- @type ProtoMessageSchema
ProtoSchema.Message.SubscribeHomeAssistantStateResponse = {
  name = "SubscribeHomeAssistantStateResponse",
  options = {
    id = 39,
    source = 1,
    ifdef = "USE_API_HOMEASSISTANT_STATES",
  },
  fields = {
    [1] = {
      name = "entity_id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "attribute",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [3] = {
      name = "once",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.HomeAssistantStateResponse = {
  name = "HomeAssistantStateResponse",
  options = {
    id = 40,
    source = 2,
    ifdef = "USE_API_HOMEASSISTANT_STATES",
    no_delay = 1,
  },
  fields = {
    [1] = {
      name = "entity_id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "state",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [3] = {
      name = "attribute",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.GetTimeRequest = {
  name = "GetTimeRequest",
  options = {
    id = 36,
    source = 1,
  },
  fields = {},
}

--- @type ProtoMessageSchema
ProtoSchema.Message.GetTimeResponse = {
  name = "GetTimeResponse",
  options = {
    id = 37,
    source = 2,
    no_delay = 1,
  },
  fields = {
    [1] = {
      name = "epoch_seconds",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "timezone",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ListEntitiesServicesArgument = {
  name = "ListEntitiesServicesArgument",
  options = {
    ifdef = "USE_API_USER_DEFINED_ACTIONS",
  },
  fields = {
    [1] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "type",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- ServiceArgType
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ListEntitiesServicesResponse = {
  name = "ListEntitiesServicesResponse",
  options = {
    id = 41,
    source = 1,
    ifdef = "USE_API_USER_DEFINED_ACTIONS",
  },
  fields = {
    [1] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [3] = {
      name = "args",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.MESSAGE,
      repeated = true,
      subschema = "ListEntitiesServicesArgument",
    },
    [4] = {
      name = "supports_response",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- SupportsResponseType
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ExecuteServiceArgument = {
  name = "ExecuteServiceArgument",
  options = {
    ifdef = "USE_API_USER_DEFINED_ACTIONS",
  },
  fields = {
    [1] = {
      name = "bool_",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [2] = {
      name = "legacy_int",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.INT32,
    },
    [3] = {
      name = "float_",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [4] = {
      name = "string_",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [5] = {
      name = "int_",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.SINT32,
    },
    [6] = {
      name = "bool_array",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
      repeated = true,
    },
    [7] = {
      name = "int_array",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.SINT32,
      repeated = true,
    },
    [8] = {
      name = "float_array",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
      repeated = true,
    },
    [9] = {
      name = "string_array",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
      repeated = true,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ExecuteServiceRequest = {
  name = "ExecuteServiceRequest",
  options = {
    id = 42,
    source = 2,
    ifdef = "USE_API_USER_DEFINED_ACTIONS",
    no_delay = 1,
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "args",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.MESSAGE,
      repeated = true,
      subschema = "ExecuteServiceArgument",
    },
    [3] = {
      name = "call_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [4] = {
      name = "return_response",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ExecuteServiceResponse = {
  name = "ExecuteServiceResponse",
  options = {
    id = 131,
    source = 1,
    ifdef = "USE_API_USER_DEFINED_ACTION_RESPONSES",
    no_delay = 1,
  },
  fields = {
    [1] = {
      name = "call_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [2] = {
      name = "success",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [3] = {
      name = "error_message",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [4] = {
      name = "response_data",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.BYTES,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ListEntitiesCameraResponse = {
  name = "ListEntitiesCameraResponse",
  options = {
    id = 43,
    source = 1,
    ifdef = "USE_CAMERA",
    base_class = "InfoResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "object_id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [3] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [5] = {
      name = "disabled_by_default",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [6] = {
      name = "icon",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [7] = {
      name = "entity_category",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- EntityCategory
    },
    [8] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.CameraImageResponse = {
  name = "CameraImageResponse",
  options = {
    id = 44,
    source = 1,
    ifdef = "USE_CAMERA",
    base_class = "StateResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "data",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.BYTES,
    },
    [3] = {
      name = "done",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [4] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.CameraImageRequest = {
  name = "CameraImageRequest",
  options = {
    id = 45,
    source = 2,
    ifdef = "USE_CAMERA",
    no_delay = 1,
  },
  fields = {
    [1] = {
      name = "single",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [2] = {
      name = "stream",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ListEntitiesClimateResponse = {
  name = "ListEntitiesClimateResponse",
  options = {
    id = 46,
    source = 1,
    ifdef = "USE_CLIMATE",
    base_class = "InfoResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "object_id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [3] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [5] = {
      name = "supports_current_temperature",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [6] = {
      name = "supports_two_point_target_temperature",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [7] = {
      name = "supported_modes",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- ClimateMode
      repeated = true,
    },
    [8] = {
      name = "visual_min_temperature",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [9] = {
      name = "visual_max_temperature",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [10] = {
      name = "visual_target_temperature_step",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [11] = {
      name = "legacy_supports_away",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [12] = {
      name = "supports_action",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [13] = {
      name = "supported_fan_modes",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- ClimateFanMode
      repeated = true,
    },
    [14] = {
      name = "supported_swing_modes",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- ClimateSwingMode
      repeated = true,
    },
    [15] = {
      name = "supported_custom_fan_modes",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
      repeated = true,
    },
    [16] = {
      name = "supported_presets",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- ClimatePreset
      repeated = true,
    },
    [17] = {
      name = "supported_custom_presets",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
      repeated = true,
    },
    [18] = {
      name = "disabled_by_default",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [19] = {
      name = "icon",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [20] = {
      name = "entity_category",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- EntityCategory
    },
    [21] = {
      name = "visual_current_temperature_step",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [22] = {
      name = "supports_current_humidity",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [23] = {
      name = "supports_target_humidity",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [24] = {
      name = "visual_min_humidity",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [25] = {
      name = "visual_max_humidity",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [26] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [27] = {
      name = "feature_flags",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ClimateStateResponse = {
  name = "ClimateStateResponse",
  options = {
    id = 47,
    source = 1,
    ifdef = "USE_CLIMATE",
    no_delay = 1,
    base_class = "StateResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "mode",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- ClimateMode
    },
    [3] = {
      name = "current_temperature",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [4] = {
      name = "target_temperature",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [5] = {
      name = "target_temperature_low",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [6] = {
      name = "target_temperature_high",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [7] = {
      name = "unused_legacy_away",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [8] = {
      name = "action",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- ClimateAction
    },
    [9] = {
      name = "fan_mode",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- ClimateFanMode
    },
    [10] = {
      name = "swing_mode",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- ClimateSwingMode
    },
    [11] = {
      name = "custom_fan_mode",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [12] = {
      name = "preset",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- ClimatePreset
    },
    [13] = {
      name = "custom_preset",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [14] = {
      name = "current_humidity",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [15] = {
      name = "target_humidity",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [16] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ClimateCommandRequest = {
  name = "ClimateCommandRequest",
  options = {
    id = 48,
    source = 2,
    ifdef = "USE_CLIMATE",
    no_delay = 1,
    base_class = "CommandProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "has_mode",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [3] = {
      name = "mode",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- ClimateMode
    },
    [4] = {
      name = "has_target_temperature",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [5] = {
      name = "target_temperature",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [6] = {
      name = "has_target_temperature_low",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [7] = {
      name = "target_temperature_low",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [8] = {
      name = "has_target_temperature_high",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [9] = {
      name = "target_temperature_high",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [10] = {
      name = "unused_has_legacy_away",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [11] = {
      name = "unused_legacy_away",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [12] = {
      name = "has_fan_mode",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [13] = {
      name = "fan_mode",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- ClimateFanMode
    },
    [14] = {
      name = "has_swing_mode",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [15] = {
      name = "swing_mode",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- ClimateSwingMode
    },
    [16] = {
      name = "has_custom_fan_mode",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [17] = {
      name = "custom_fan_mode",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [18] = {
      name = "has_preset",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [19] = {
      name = "preset",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- ClimatePreset
    },
    [20] = {
      name = "has_custom_preset",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [21] = {
      name = "custom_preset",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [22] = {
      name = "has_target_humidity",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [23] = {
      name = "target_humidity",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [24] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ListEntitiesWaterHeaterResponse = {
  name = "ListEntitiesWaterHeaterResponse",
  options = {
    id = 132,
    source = 1,
    ifdef = "USE_WATER_HEATER",
    base_class = "InfoResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "object_id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [3] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [4] = {
      name = "icon",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [5] = {
      name = "disabled_by_default",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [6] = {
      name = "entity_category",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- EntityCategory
    },
    [7] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [8] = {
      name = "min_temperature",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [9] = {
      name = "max_temperature",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [10] = {
      name = "target_temperature_step",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [11] = {
      name = "supported_modes",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- WaterHeaterMode
      repeated = true,
    },
    [12] = {
      name = "supported_features",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.WaterHeaterStateResponse = {
  name = "WaterHeaterStateResponse",
  options = {
    id = 133,
    source = 1,
    ifdef = "USE_WATER_HEATER",
    no_delay = 1,
    base_class = "StateResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "current_temperature",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [3] = {
      name = "target_temperature",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [4] = {
      name = "mode",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- WaterHeaterMode
    },
    [5] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [6] = {
      name = "state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [7] = {
      name = "target_temperature_low",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [8] = {
      name = "target_temperature_high",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.WaterHeaterCommandRequest = {
  name = "WaterHeaterCommandRequest",
  options = {
    id = 134,
    source = 2,
    ifdef = "USE_WATER_HEATER",
    no_delay = 1,
    base_class = "CommandProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "has_fields",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [3] = {
      name = "mode",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- WaterHeaterMode
    },
    [4] = {
      name = "target_temperature",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [5] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [6] = {
      name = "state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [7] = {
      name = "target_temperature_low",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [8] = {
      name = "target_temperature_high",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ListEntitiesNumberResponse = {
  name = "ListEntitiesNumberResponse",
  options = {
    id = 49,
    source = 1,
    ifdef = "USE_NUMBER",
    base_class = "InfoResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "object_id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [3] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [5] = {
      name = "icon",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [6] = {
      name = "min_value",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [7] = {
      name = "max_value",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [8] = {
      name = "step",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [9] = {
      name = "disabled_by_default",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [10] = {
      name = "entity_category",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- EntityCategory
    },
    [11] = {
      name = "unit_of_measurement",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [12] = {
      name = "mode",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- NumberMode
    },
    [13] = {
      name = "device_class",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [14] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.NumberStateResponse = {
  name = "NumberStateResponse",
  options = {
    id = 50,
    source = 1,
    ifdef = "USE_NUMBER",
    no_delay = 1,
    base_class = "StateResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "state",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [3] = {
      name = "missing_state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [4] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.NumberCommandRequest = {
  name = "NumberCommandRequest",
  options = {
    id = 51,
    source = 2,
    ifdef = "USE_NUMBER",
    no_delay = 1,
    base_class = "CommandProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "state",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [3] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ListEntitiesSelectResponse = {
  name = "ListEntitiesSelectResponse",
  options = {
    id = 52,
    source = 1,
    ifdef = "USE_SELECT",
    base_class = "InfoResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "object_id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [3] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [5] = {
      name = "icon",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [6] = {
      name = "options",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
      repeated = true,
    },
    [7] = {
      name = "disabled_by_default",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [8] = {
      name = "entity_category",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- EntityCategory
    },
    [9] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.SelectStateResponse = {
  name = "SelectStateResponse",
  options = {
    id = 53,
    source = 1,
    ifdef = "USE_SELECT",
    no_delay = 1,
    base_class = "StateResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "state",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [3] = {
      name = "missing_state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [4] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.SelectCommandRequest = {
  name = "SelectCommandRequest",
  options = {
    id = 54,
    source = 2,
    ifdef = "USE_SELECT",
    no_delay = 1,
    base_class = "CommandProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "state",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [3] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ListEntitiesSirenResponse = {
  name = "ListEntitiesSirenResponse",
  options = {
    id = 55,
    source = 1,
    ifdef = "USE_SIREN",
    base_class = "InfoResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "object_id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [3] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [5] = {
      name = "icon",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [6] = {
      name = "disabled_by_default",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [7] = {
      name = "tones",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
      repeated = true,
    },
    [8] = {
      name = "supports_duration",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [9] = {
      name = "supports_volume",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [10] = {
      name = "entity_category",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- EntityCategory
    },
    [11] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.SirenStateResponse = {
  name = "SirenStateResponse",
  options = {
    id = 56,
    source = 1,
    ifdef = "USE_SIREN",
    no_delay = 1,
    base_class = "StateResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [3] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.SirenCommandRequest = {
  name = "SirenCommandRequest",
  options = {
    id = 57,
    source = 2,
    ifdef = "USE_SIREN",
    no_delay = 1,
    base_class = "CommandProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "has_state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [3] = {
      name = "state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [4] = {
      name = "has_tone",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [5] = {
      name = "tone",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [6] = {
      name = "has_duration",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [7] = {
      name = "duration",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [8] = {
      name = "has_volume",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [9] = {
      name = "volume",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [10] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ListEntitiesLockResponse = {
  name = "ListEntitiesLockResponse",
  options = {
    id = 58,
    source = 1,
    ifdef = "USE_LOCK",
    base_class = "InfoResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "object_id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [3] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [5] = {
      name = "icon",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [6] = {
      name = "disabled_by_default",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [7] = {
      name = "entity_category",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- EntityCategory
    },
    [8] = {
      name = "assumed_state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [9] = {
      name = "supports_open",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [10] = {
      name = "requires_code",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [11] = {
      name = "code_format",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [12] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.LockStateResponse = {
  name = "LockStateResponse",
  options = {
    id = 59,
    source = 1,
    ifdef = "USE_LOCK",
    no_delay = 1,
    base_class = "StateResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- LockState
    },
    [3] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.LockCommandRequest = {
  name = "LockCommandRequest",
  options = {
    id = 60,
    source = 2,
    ifdef = "USE_LOCK",
    no_delay = 1,
    base_class = "CommandProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "command",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- LockCommand
    },
    [3] = {
      name = "has_code",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [4] = {
      name = "code",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [5] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ListEntitiesButtonResponse = {
  name = "ListEntitiesButtonResponse",
  options = {
    id = 61,
    source = 1,
    ifdef = "USE_BUTTON",
    base_class = "InfoResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "object_id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [3] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [5] = {
      name = "icon",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [6] = {
      name = "disabled_by_default",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [7] = {
      name = "entity_category",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- EntityCategory
    },
    [8] = {
      name = "device_class",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [9] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ButtonCommandRequest = {
  name = "ButtonCommandRequest",
  options = {
    id = 62,
    source = 2,
    ifdef = "USE_BUTTON",
    no_delay = 1,
    base_class = "CommandProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.MediaPlayerSupportedFormat = {
  name = "MediaPlayerSupportedFormat",
  options = {
    ifdef = "USE_MEDIA_PLAYER",
  },
  fields = {
    [1] = {
      name = "format",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "sample_rate",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [3] = {
      name = "num_channels",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [4] = {
      name = "purpose",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- MediaPlayerFormatPurpose
    },
    [5] = {
      name = "sample_bytes",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ListEntitiesMediaPlayerResponse = {
  name = "ListEntitiesMediaPlayerResponse",
  options = {
    id = 63,
    source = 1,
    ifdef = "USE_MEDIA_PLAYER",
    base_class = "InfoResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "object_id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [3] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [5] = {
      name = "icon",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [6] = {
      name = "disabled_by_default",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [7] = {
      name = "entity_category",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- EntityCategory
    },
    [8] = {
      name = "supports_pause",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [9] = {
      name = "supported_formats",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.MESSAGE,
      repeated = true,
      subschema = "MediaPlayerSupportedFormat",
    },
    [10] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [11] = {
      name = "feature_flags",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.MediaPlayerStateResponse = {
  name = "MediaPlayerStateResponse",
  options = {
    id = 64,
    source = 1,
    ifdef = "USE_MEDIA_PLAYER",
    no_delay = 1,
    base_class = "StateResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- MediaPlayerState
    },
    [3] = {
      name = "volume",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [4] = {
      name = "muted",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [5] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.MediaPlayerCommandRequest = {
  name = "MediaPlayerCommandRequest",
  options = {
    id = 65,
    source = 2,
    ifdef = "USE_MEDIA_PLAYER",
    no_delay = 1,
    base_class = "CommandProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "has_command",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [3] = {
      name = "command",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- MediaPlayerCommand
    },
    [4] = {
      name = "has_volume",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [5] = {
      name = "volume",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [6] = {
      name = "has_media_url",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [7] = {
      name = "media_url",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [8] = {
      name = "has_announcement",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [9] = {
      name = "announcement",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [10] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.SubscribeBluetoothLEAdvertisementsRequest = {
  name = "SubscribeBluetoothLEAdvertisementsRequest",
  options = {
    id = 66,
    source = 2,
    ifdef = "USE_BLUETOOTH_PROXY",
  },
  fields = {
    [1] = {
      name = "flags",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.BluetoothServiceData = {
  name = "BluetoothServiceData",
  options = {},
  fields = {
    [1] = {
      name = "uuid",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "legacy_data",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
      repeated = true,
    },
    [3] = {
      name = "data",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.BYTES,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.BluetoothLEAdvertisementResponse = {
  name = "BluetoothLEAdvertisementResponse",
  options = {
    id = 67,
    source = 1,
    ifdef = "USE_BLUETOOTH_PROXY",
    no_delay = 1,
  },
  fields = {
    [1] = {
      name = "address",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT64,
    },
    [2] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.BYTES,
    },
    [3] = {
      name = "rssi",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.SINT32,
    },
    [4] = {
      name = "service_uuids",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
      repeated = true,
    },
    [5] = {
      name = "service_data",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.MESSAGE,
      repeated = true,
      subschema = "BluetoothServiceData",
    },
    [6] = {
      name = "manufacturer_data",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.MESSAGE,
      repeated = true,
      subschema = "BluetoothServiceData",
    },
    [7] = {
      name = "address_type",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.BluetoothLERawAdvertisement = {
  name = "BluetoothLERawAdvertisement",
  options = {},
  fields = {
    [1] = {
      name = "address",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT64,
    },
    [2] = {
      name = "rssi",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.SINT32,
    },
    [3] = {
      name = "address_type",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [4] = {
      name = "data",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.BYTES,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.BluetoothLERawAdvertisementsResponse = {
  name = "BluetoothLERawAdvertisementsResponse",
  options = {
    id = 93,
    source = 1,
    ifdef = "USE_BLUETOOTH_PROXY",
    no_delay = 1,
  },
  fields = {
    [1] = {
      name = "advertisements",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.MESSAGE,
      repeated = true,
      subschema = "BluetoothLERawAdvertisement",
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.BluetoothDeviceRequest = {
  name = "BluetoothDeviceRequest",
  options = {
    id = 68,
    source = 2,
    ifdef = "USE_BLUETOOTH_PROXY",
  },
  fields = {
    [1] = {
      name = "address",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT64,
    },
    [2] = {
      name = "request_type",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- BluetoothDeviceRequestType
    },
    [3] = {
      name = "has_address_type",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [4] = {
      name = "address_type",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.BluetoothDeviceConnectionResponse = {
  name = "BluetoothDeviceConnectionResponse",
  options = {
    id = 69,
    source = 1,
    ifdef = "USE_BLUETOOTH_PROXY",
  },
  fields = {
    [1] = {
      name = "address",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT64,
    },
    [2] = {
      name = "connected",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [3] = {
      name = "mtu",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [4] = {
      name = "error",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.INT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.BluetoothGATTGetServicesRequest = {
  name = "BluetoothGATTGetServicesRequest",
  options = {
    id = 70,
    source = 2,
    ifdef = "USE_BLUETOOTH_PROXY",
  },
  fields = {
    [1] = {
      name = "address",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT64,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.BluetoothGATTDescriptor = {
  name = "BluetoothGATTDescriptor",
  options = {},
  fields = {
    [1] = {
      name = "uuid",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT64,
      repeated = true,
    },
    [2] = {
      name = "handle",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [3] = {
      name = "short_uuid",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.BluetoothGATTCharacteristic = {
  name = "BluetoothGATTCharacteristic",
  options = {},
  fields = {
    [1] = {
      name = "uuid",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT64,
      repeated = true,
    },
    [2] = {
      name = "handle",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [3] = {
      name = "properties",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [4] = {
      name = "descriptors",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.MESSAGE,
      repeated = true,
      subschema = "BluetoothGATTDescriptor",
    },
    [5] = {
      name = "short_uuid",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.BluetoothGATTService = {
  name = "BluetoothGATTService",
  options = {},
  fields = {
    [1] = {
      name = "uuid",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT64,
      repeated = true,
    },
    [2] = {
      name = "handle",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [3] = {
      name = "characteristics",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.MESSAGE,
      repeated = true,
      subschema = "BluetoothGATTCharacteristic",
    },
    [4] = {
      name = "short_uuid",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.BluetoothGATTGetServicesResponse = {
  name = "BluetoothGATTGetServicesResponse",
  options = {
    id = 71,
    source = 1,
    ifdef = "USE_BLUETOOTH_PROXY",
  },
  fields = {
    [1] = {
      name = "address",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT64,
    },
    [2] = {
      name = "services",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.MESSAGE,
      repeated = true,
      subschema = "BluetoothGATTService",
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.BluetoothGATTGetServicesDoneResponse = {
  name = "BluetoothGATTGetServicesDoneResponse",
  options = {
    id = 72,
    source = 1,
    ifdef = "USE_BLUETOOTH_PROXY",
  },
  fields = {
    [1] = {
      name = "address",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT64,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.BluetoothGATTReadRequest = {
  name = "BluetoothGATTReadRequest",
  options = {
    id = 73,
    source = 2,
    ifdef = "USE_BLUETOOTH_PROXY",
  },
  fields = {
    [1] = {
      name = "address",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT64,
    },
    [2] = {
      name = "handle",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.BluetoothGATTReadResponse = {
  name = "BluetoothGATTReadResponse",
  options = {
    id = 74,
    source = 1,
    ifdef = "USE_BLUETOOTH_PROXY",
  },
  fields = {
    [1] = {
      name = "address",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT64,
    },
    [2] = {
      name = "handle",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [3] = {
      name = "data",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.BYTES,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.BluetoothGATTWriteRequest = {
  name = "BluetoothGATTWriteRequest",
  options = {
    id = 75,
    source = 2,
    ifdef = "USE_BLUETOOTH_PROXY",
  },
  fields = {
    [1] = {
      name = "address",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT64,
    },
    [2] = {
      name = "handle",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [3] = {
      name = "response",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [4] = {
      name = "data",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.BYTES,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.BluetoothGATTReadDescriptorRequest = {
  name = "BluetoothGATTReadDescriptorRequest",
  options = {
    id = 76,
    source = 2,
    ifdef = "USE_BLUETOOTH_PROXY",
  },
  fields = {
    [1] = {
      name = "address",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT64,
    },
    [2] = {
      name = "handle",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.BluetoothGATTWriteDescriptorRequest = {
  name = "BluetoothGATTWriteDescriptorRequest",
  options = {
    id = 77,
    source = 2,
    ifdef = "USE_BLUETOOTH_PROXY",
  },
  fields = {
    [1] = {
      name = "address",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT64,
    },
    [2] = {
      name = "handle",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [3] = {
      name = "data",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.BYTES,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.BluetoothGATTNotifyRequest = {
  name = "BluetoothGATTNotifyRequest",
  options = {
    id = 78,
    source = 2,
    ifdef = "USE_BLUETOOTH_PROXY",
  },
  fields = {
    [1] = {
      name = "address",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT64,
    },
    [2] = {
      name = "handle",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [3] = {
      name = "enable",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.BluetoothGATTNotifyDataResponse = {
  name = "BluetoothGATTNotifyDataResponse",
  options = {
    id = 79,
    source = 1,
    ifdef = "USE_BLUETOOTH_PROXY",
  },
  fields = {
    [1] = {
      name = "address",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT64,
    },
    [2] = {
      name = "handle",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [3] = {
      name = "data",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.BYTES,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.SubscribeBluetoothConnectionsFreeRequest = {
  name = "SubscribeBluetoothConnectionsFreeRequest",
  options = {
    id = 80,
    source = 2,
    ifdef = "USE_BLUETOOTH_PROXY",
  },
  fields = {},
}

--- @type ProtoMessageSchema
ProtoSchema.Message.BluetoothConnectionsFreeResponse = {
  name = "BluetoothConnectionsFreeResponse",
  options = {
    id = 81,
    source = 1,
    ifdef = "USE_BLUETOOTH_PROXY",
  },
  fields = {
    [1] = {
      name = "free",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [2] = {
      name = "limit",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [3] = {
      name = "allocated",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT64,
      repeated = true,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.BluetoothGATTErrorResponse = {
  name = "BluetoothGATTErrorResponse",
  options = {
    id = 82,
    source = 1,
    ifdef = "USE_BLUETOOTH_PROXY",
  },
  fields = {
    [1] = {
      name = "address",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT64,
    },
    [2] = {
      name = "handle",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [3] = {
      name = "error",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.INT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.BluetoothGATTWriteResponse = {
  name = "BluetoothGATTWriteResponse",
  options = {
    id = 83,
    source = 1,
    ifdef = "USE_BLUETOOTH_PROXY",
  },
  fields = {
    [1] = {
      name = "address",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT64,
    },
    [2] = {
      name = "handle",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.BluetoothGATTNotifyResponse = {
  name = "BluetoothGATTNotifyResponse",
  options = {
    id = 84,
    source = 1,
    ifdef = "USE_BLUETOOTH_PROXY",
  },
  fields = {
    [1] = {
      name = "address",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT64,
    },
    [2] = {
      name = "handle",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.BluetoothDevicePairingResponse = {
  name = "BluetoothDevicePairingResponse",
  options = {
    id = 85,
    source = 1,
    ifdef = "USE_BLUETOOTH_PROXY",
  },
  fields = {
    [1] = {
      name = "address",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT64,
    },
    [2] = {
      name = "paired",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [3] = {
      name = "error",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.INT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.BluetoothDeviceUnpairingResponse = {
  name = "BluetoothDeviceUnpairingResponse",
  options = {
    id = 86,
    source = 1,
    ifdef = "USE_BLUETOOTH_PROXY",
  },
  fields = {
    [1] = {
      name = "address",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT64,
    },
    [2] = {
      name = "success",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [3] = {
      name = "error",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.INT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.UnsubscribeBluetoothLEAdvertisementsRequest = {
  name = "UnsubscribeBluetoothLEAdvertisementsRequest",
  options = {
    id = 87,
    source = 2,
    ifdef = "USE_BLUETOOTH_PROXY",
  },
  fields = {},
}

--- @type ProtoMessageSchema
ProtoSchema.Message.BluetoothDeviceClearCacheResponse = {
  name = "BluetoothDeviceClearCacheResponse",
  options = {
    id = 88,
    source = 1,
    ifdef = "USE_BLUETOOTH_PROXY",
  },
  fields = {
    [1] = {
      name = "address",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT64,
    },
    [2] = {
      name = "success",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [3] = {
      name = "error",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.INT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.BluetoothScannerStateResponse = {
  name = "BluetoothScannerStateResponse",
  options = {
    id = 126,
    source = 1,
    ifdef = "USE_BLUETOOTH_PROXY",
  },
  fields = {
    [1] = {
      name = "state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- BluetoothScannerState
    },
    [2] = {
      name = "mode",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- BluetoothScannerMode
    },
    [3] = {
      name = "configured_mode",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- BluetoothScannerMode
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.BluetoothScannerSetModeRequest = {
  name = "BluetoothScannerSetModeRequest",
  options = {
    id = 127,
    source = 2,
    ifdef = "USE_BLUETOOTH_PROXY",
  },
  fields = {
    [1] = {
      name = "mode",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- BluetoothScannerMode
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.SubscribeVoiceAssistantRequest = {
  name = "SubscribeVoiceAssistantRequest",
  options = {
    id = 89,
    source = 2,
    ifdef = "USE_VOICE_ASSISTANT",
  },
  fields = {
    [1] = {
      name = "subscribe",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [2] = {
      name = "flags",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.VoiceAssistantAudioSettings = {
  name = "VoiceAssistantAudioSettings",
  options = {},
  fields = {
    [1] = {
      name = "noise_suppression_level",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [2] = {
      name = "auto_gain",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [3] = {
      name = "volume_multiplier",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.VoiceAssistantRequest = {
  name = "VoiceAssistantRequest",
  options = {
    id = 90,
    source = 1,
    ifdef = "USE_VOICE_ASSISTANT",
  },
  fields = {
    [1] = {
      name = "start",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [2] = {
      name = "conversation_id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [3] = {
      name = "flags",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [4] = {
      name = "audio_settings",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.MESSAGE,
      subschema = "VoiceAssistantAudioSettings",
    },
    [5] = {
      name = "wake_word_phrase",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.VoiceAssistantResponse = {
  name = "VoiceAssistantResponse",
  options = {
    id = 91,
    source = 2,
    ifdef = "USE_VOICE_ASSISTANT",
  },
  fields = {
    [1] = {
      name = "port",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [2] = {
      name = "error",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.VoiceAssistantEventData = {
  name = "VoiceAssistantEventData",
  options = {},
  fields = {
    [1] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "value",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.VoiceAssistantEventResponse = {
  name = "VoiceAssistantEventResponse",
  options = {
    id = 92,
    source = 2,
    ifdef = "USE_VOICE_ASSISTANT",
  },
  fields = {
    [1] = {
      name = "event_type",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- VoiceAssistantEvent
    },
    [2] = {
      name = "data",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.MESSAGE,
      repeated = true,
      subschema = "VoiceAssistantEventData",
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.VoiceAssistantAudio = {
  name = "VoiceAssistantAudio",
  options = {
    id = 106,
    source = 0,
    ifdef = "USE_VOICE_ASSISTANT",
  },
  fields = {
    [1] = {
      name = "data",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.BYTES,
    },
    [2] = {
      name = "end",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.VoiceAssistantTimerEventResponse = {
  name = "VoiceAssistantTimerEventResponse",
  options = {
    id = 115,
    source = 2,
    ifdef = "USE_VOICE_ASSISTANT",
  },
  fields = {
    [1] = {
      name = "event_type",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- VoiceAssistantTimerEvent
    },
    [2] = {
      name = "timer_id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [3] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [4] = {
      name = "total_seconds",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [5] = {
      name = "seconds_left",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [6] = {
      name = "is_active",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.VoiceAssistantAnnounceRequest = {
  name = "VoiceAssistantAnnounceRequest",
  options = {
    id = 119,
    source = 2,
    ifdef = "USE_VOICE_ASSISTANT",
  },
  fields = {
    [1] = {
      name = "media_id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "text",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [3] = {
      name = "preannounce_media_id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [4] = {
      name = "start_conversation",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.VoiceAssistantAnnounceFinished = {
  name = "VoiceAssistantAnnounceFinished",
  options = {
    id = 120,
    source = 1,
    ifdef = "USE_VOICE_ASSISTANT",
  },
  fields = {
    [1] = {
      name = "success",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.VoiceAssistantWakeWord = {
  name = "VoiceAssistantWakeWord",
  options = {},
  fields = {
    [1] = {
      name = "id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "wake_word",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [3] = {
      name = "trained_languages",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
      repeated = true,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.VoiceAssistantExternalWakeWord = {
  name = "VoiceAssistantExternalWakeWord",
  options = {},
  fields = {
    [1] = {
      name = "id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "wake_word",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [3] = {
      name = "trained_languages",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
      repeated = true,
    },
    [4] = {
      name = "model_type",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [5] = {
      name = "model_size",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [6] = {
      name = "model_hash",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [7] = {
      name = "url",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.VoiceAssistantConfigurationRequest = {
  name = "VoiceAssistantConfigurationRequest",
  options = {
    id = 121,
    source = 2,
    ifdef = "USE_VOICE_ASSISTANT",
  },
  fields = {
    [1] = {
      name = "external_wake_words",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.MESSAGE,
      repeated = true,
      subschema = "VoiceAssistantExternalWakeWord",
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.VoiceAssistantConfigurationResponse = {
  name = "VoiceAssistantConfigurationResponse",
  options = {
    id = 122,
    source = 1,
    ifdef = "USE_VOICE_ASSISTANT",
  },
  fields = {
    [1] = {
      name = "available_wake_words",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.MESSAGE,
      repeated = true,
      subschema = "VoiceAssistantWakeWord",
    },
    [2] = {
      name = "active_wake_words",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
      repeated = true,
    },
    [3] = {
      name = "max_active_wake_words",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.VoiceAssistantSetConfiguration = {
  name = "VoiceAssistantSetConfiguration",
  options = {
    id = 123,
    source = 2,
    ifdef = "USE_VOICE_ASSISTANT",
  },
  fields = {
    [1] = {
      name = "active_wake_words",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
      repeated = true,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ListEntitiesAlarmControlPanelResponse = {
  name = "ListEntitiesAlarmControlPanelResponse",
  options = {
    id = 94,
    source = 1,
    ifdef = "USE_ALARM_CONTROL_PANEL",
    base_class = "InfoResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "object_id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [3] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [5] = {
      name = "icon",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [6] = {
      name = "disabled_by_default",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [7] = {
      name = "entity_category",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- EntityCategory
    },
    [8] = {
      name = "supported_features",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [9] = {
      name = "requires_code",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [10] = {
      name = "requires_code_to_arm",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [11] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.AlarmControlPanelStateResponse = {
  name = "AlarmControlPanelStateResponse",
  options = {
    id = 95,
    source = 1,
    ifdef = "USE_ALARM_CONTROL_PANEL",
    no_delay = 1,
    base_class = "StateResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- AlarmControlPanelState
    },
    [3] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.AlarmControlPanelCommandRequest = {
  name = "AlarmControlPanelCommandRequest",
  options = {
    id = 96,
    source = 2,
    ifdef = "USE_ALARM_CONTROL_PANEL",
    no_delay = 1,
    base_class = "CommandProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "command",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- AlarmControlPanelStateCommand
    },
    [3] = {
      name = "code",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [4] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ListEntitiesTextResponse = {
  name = "ListEntitiesTextResponse",
  options = {
    id = 97,
    source = 1,
    ifdef = "USE_TEXT",
    base_class = "InfoResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "object_id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [3] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [5] = {
      name = "icon",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [6] = {
      name = "disabled_by_default",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [7] = {
      name = "entity_category",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- EntityCategory
    },
    [8] = {
      name = "min_length",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [9] = {
      name = "max_length",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [10] = {
      name = "pattern",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [11] = {
      name = "mode",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- TextMode
    },
    [12] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.TextStateResponse = {
  name = "TextStateResponse",
  options = {
    id = 98,
    source = 1,
    ifdef = "USE_TEXT",
    no_delay = 1,
    base_class = "StateResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "state",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [3] = {
      name = "missing_state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [4] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.TextCommandRequest = {
  name = "TextCommandRequest",
  options = {
    id = 99,
    source = 2,
    ifdef = "USE_TEXT",
    no_delay = 1,
    base_class = "CommandProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "state",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [3] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ListEntitiesDateResponse = {
  name = "ListEntitiesDateResponse",
  options = {
    id = 100,
    source = 1,
    ifdef = "USE_DATETIME_DATE",
    base_class = "InfoResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "object_id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [3] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [5] = {
      name = "icon",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [6] = {
      name = "disabled_by_default",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [7] = {
      name = "entity_category",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- EntityCategory
    },
    [8] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.DateStateResponse = {
  name = "DateStateResponse",
  options = {
    id = 101,
    source = 1,
    ifdef = "USE_DATETIME_DATE",
    no_delay = 1,
    base_class = "StateResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "missing_state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [3] = {
      name = "year",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [4] = {
      name = "month",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [5] = {
      name = "day",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [6] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.DateCommandRequest = {
  name = "DateCommandRequest",
  options = {
    id = 102,
    source = 2,
    ifdef = "USE_DATETIME_DATE",
    no_delay = 1,
    base_class = "CommandProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "year",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [3] = {
      name = "month",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [4] = {
      name = "day",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [5] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ListEntitiesTimeResponse = {
  name = "ListEntitiesTimeResponse",
  options = {
    id = 103,
    source = 1,
    ifdef = "USE_DATETIME_TIME",
    base_class = "InfoResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "object_id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [3] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [5] = {
      name = "icon",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [6] = {
      name = "disabled_by_default",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [7] = {
      name = "entity_category",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- EntityCategory
    },
    [8] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.TimeStateResponse = {
  name = "TimeStateResponse",
  options = {
    id = 104,
    source = 1,
    ifdef = "USE_DATETIME_TIME",
    no_delay = 1,
    base_class = "StateResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "missing_state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [3] = {
      name = "hour",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [4] = {
      name = "minute",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [5] = {
      name = "second",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [6] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.TimeCommandRequest = {
  name = "TimeCommandRequest",
  options = {
    id = 105,
    source = 2,
    ifdef = "USE_DATETIME_TIME",
    no_delay = 1,
    base_class = "CommandProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "hour",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [3] = {
      name = "minute",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [4] = {
      name = "second",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [5] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ListEntitiesEventResponse = {
  name = "ListEntitiesEventResponse",
  options = {
    id = 107,
    source = 1,
    ifdef = "USE_EVENT",
    base_class = "InfoResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "object_id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [3] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [5] = {
      name = "icon",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [6] = {
      name = "disabled_by_default",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [7] = {
      name = "entity_category",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- EntityCategory
    },
    [8] = {
      name = "device_class",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [9] = {
      name = "event_types",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
      repeated = true,
    },
    [10] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.EventResponse = {
  name = "EventResponse",
  options = {
    id = 108,
    source = 1,
    ifdef = "USE_EVENT",
    base_class = "StateResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "event_type",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [3] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ListEntitiesValveResponse = {
  name = "ListEntitiesValveResponse",
  options = {
    id = 109,
    source = 1,
    ifdef = "USE_VALVE",
    base_class = "InfoResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "object_id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [3] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [5] = {
      name = "icon",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [6] = {
      name = "disabled_by_default",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [7] = {
      name = "entity_category",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- EntityCategory
    },
    [8] = {
      name = "device_class",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [9] = {
      name = "assumed_state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [10] = {
      name = "supports_position",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [11] = {
      name = "supports_stop",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [12] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ValveStateResponse = {
  name = "ValveStateResponse",
  options = {
    id = 110,
    source = 1,
    ifdef = "USE_VALVE",
    no_delay = 1,
    base_class = "StateResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "position",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [3] = {
      name = "current_operation",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- ValveOperation
    },
    [4] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ValveCommandRequest = {
  name = "ValveCommandRequest",
  options = {
    id = 111,
    source = 2,
    ifdef = "USE_VALVE",
    no_delay = 1,
    base_class = "CommandProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "has_position",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [3] = {
      name = "position",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [4] = {
      name = "stop",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [5] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ListEntitiesDateTimeResponse = {
  name = "ListEntitiesDateTimeResponse",
  options = {
    id = 112,
    source = 1,
    ifdef = "USE_DATETIME_DATETIME",
    base_class = "InfoResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "object_id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [3] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [5] = {
      name = "icon",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [6] = {
      name = "disabled_by_default",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [7] = {
      name = "entity_category",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- EntityCategory
    },
    [8] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.DateTimeStateResponse = {
  name = "DateTimeStateResponse",
  options = {
    id = 113,
    source = 1,
    ifdef = "USE_DATETIME_DATETIME",
    no_delay = 1,
    base_class = "StateResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "missing_state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [3] = {
      name = "epoch_seconds",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [4] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.DateTimeCommandRequest = {
  name = "DateTimeCommandRequest",
  options = {
    id = 114,
    source = 2,
    ifdef = "USE_DATETIME_DATETIME",
    no_delay = 1,
    base_class = "CommandProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "epoch_seconds",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [3] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ListEntitiesUpdateResponse = {
  name = "ListEntitiesUpdateResponse",
  options = {
    id = 116,
    source = 1,
    ifdef = "USE_UPDATE",
    base_class = "InfoResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "object_id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [3] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [5] = {
      name = "icon",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [6] = {
      name = "disabled_by_default",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [7] = {
      name = "entity_category",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- EntityCategory
    },
    [8] = {
      name = "device_class",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [9] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.UpdateStateResponse = {
  name = "UpdateStateResponse",
  options = {
    id = 117,
    source = 1,
    ifdef = "USE_UPDATE",
    no_delay = 1,
    base_class = "StateResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "missing_state",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [3] = {
      name = "in_progress",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [4] = {
      name = "has_progress",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [5] = {
      name = "progress",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FLOAT,
    },
    [6] = {
      name = "current_version",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [7] = {
      name = "latest_version",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [8] = {
      name = "title",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [9] = {
      name = "release_summary",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [10] = {
      name = "release_url",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [11] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.UpdateCommandRequest = {
  name = "UpdateCommandRequest",
  options = {
    id = 118,
    source = 2,
    ifdef = "USE_UPDATE",
    no_delay = 1,
    base_class = "CommandProtoMessage",
  },
  fields = {
    [1] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [2] = {
      name = "command",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- UpdateCommand
    },
    [3] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ZWaveProxyFrame = {
  name = "ZWaveProxyFrame",
  options = {
    id = 128,
    source = 0,
    ifdef = "USE_ZWAVE_PROXY",
    no_delay = 1,
  },
  fields = {
    [1] = {
      name = "data",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.BYTES,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ZWaveProxyRequest = {
  name = "ZWaveProxyRequest",
  options = {
    id = 129,
    source = 0,
    ifdef = "USE_ZWAVE_PROXY",
  },
  fields = {
    [1] = {
      name = "type",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- ZWaveProxyRequestType
    },
    [2] = {
      name = "data",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.BYTES,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.ListEntitiesInfraredResponse = {
  name = "ListEntitiesInfraredResponse",
  options = {
    id = 135,
    source = 1,
    ifdef = "USE_INFRARED",
    base_class = "InfoResponseProtoMessage",
  },
  fields = {
    [1] = {
      name = "object_id",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [2] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [3] = {
      name = "name",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [4] = {
      name = "icon",
      wireType = ProtoSchema.WireType.LENGTH_DELIMITED,
      type = ProtoSchema.DataType.STRING,
    },
    [5] = {
      name = "disabled_by_default",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.BOOL,
    },
    [6] = {
      name = "entity_category",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.ENUM, -- EntityCategory
    },
    [7] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [8] = {
      name = "capabilities",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.InfraredRFTransmitRawTimingsRequest = {
  name = "InfraredRFTransmitRawTimingsRequest",
  options = {
    id = 136,
    source = 2,
    ifdef = "USE_IR_RF",
  },
  fields = {
    [1] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [2] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [3] = {
      name = "carrier_frequency",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [4] = {
      name = "repeat_count",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [5] = {
      name = "timings",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.SINT32,
      repeated = true,
    },
  },
}

--- @type ProtoMessageSchema
ProtoSchema.Message.InfraredRFReceiveEvent = {
  name = "InfraredRFReceiveEvent",
  options = {
    id = 137,
    source = 1,
    ifdef = "USE_IR_RF",
    no_delay = 1,
  },
  fields = {
    [1] = {
      name = "device_id",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.UINT32,
    },
    [2] = {
      name = "key",
      wireType = ProtoSchema.WireType.FIXED32,
      type = ProtoSchema.DataType.FIXED32,
    },
    [3] = {
      name = "timings",
      wireType = ProtoSchema.WireType.VARINT,
      type = ProtoSchema.DataType.SINT32,
      repeated = true,
    },
  },
}

--- @type ProtoServiceSchema
ProtoSchema.RPC.APIConnection = {
  hello = {
    service = "APIConnection",
    method = "hello",
    inputType = ProtoSchema.Message.HelloRequest,
    outputType = ProtoSchema.Message.HelloResponse,
  },
  disconnect = {
    service = "APIConnection",
    method = "disconnect",
    inputType = ProtoSchema.Message.DisconnectRequest,
    outputType = ProtoSchema.Message.DisconnectResponse,
  },
  ping = {
    service = "APIConnection",
    method = "ping",
    inputType = ProtoSchema.Message.PingRequest,
    outputType = ProtoSchema.Message.PingResponse,
  },
  device_info = {
    service = "APIConnection",
    method = "device_info",
    inputType = ProtoSchema.Message.DeviceInfoRequest,
    outputType = ProtoSchema.Message.DeviceInfoResponse,
  },
  list_entities = {
    service = "APIConnection",
    method = "list_entities",
    inputType = ProtoSchema.Message.ListEntitiesRequest,
    outputType = ProtoSchema.Message.void,
  },
  subscribe_states = {
    service = "APIConnection",
    method = "subscribe_states",
    inputType = ProtoSchema.Message.SubscribeStatesRequest,
    outputType = ProtoSchema.Message.void,
  },
  subscribe_logs = {
    service = "APIConnection",
    method = "subscribe_logs",
    inputType = ProtoSchema.Message.SubscribeLogsRequest,
    outputType = ProtoSchema.Message.void,
  },
  subscribe_homeassistant_services = {
    service = "APIConnection",
    method = "subscribe_homeassistant_services",
    inputType = ProtoSchema.Message.SubscribeHomeassistantServicesRequest,
    outputType = ProtoSchema.Message.void,
  },
  subscribe_home_assistant_states = {
    service = "APIConnection",
    method = "subscribe_home_assistant_states",
    inputType = ProtoSchema.Message.SubscribeHomeAssistantStatesRequest,
    outputType = ProtoSchema.Message.void,
  },
  execute_service = {
    service = "APIConnection",
    method = "execute_service",
    inputType = ProtoSchema.Message.ExecuteServiceRequest,
    outputType = ProtoSchema.Message.void,
  },
  noise_encryption_set_key = {
    service = "APIConnection",
    method = "noise_encryption_set_key",
    inputType = ProtoSchema.Message.NoiseEncryptionSetKeyRequest,
    outputType = ProtoSchema.Message.NoiseEncryptionSetKeyResponse,
  },
  button_command = {
    service = "APIConnection",
    method = "button_command",
    inputType = ProtoSchema.Message.ButtonCommandRequest,
    outputType = ProtoSchema.Message.void,
  },
  camera_image = {
    service = "APIConnection",
    method = "camera_image",
    inputType = ProtoSchema.Message.CameraImageRequest,
    outputType = ProtoSchema.Message.void,
  },
  climate_command = {
    service = "APIConnection",
    method = "climate_command",
    inputType = ProtoSchema.Message.ClimateCommandRequest,
    outputType = ProtoSchema.Message.void,
  },
  cover_command = {
    service = "APIConnection",
    method = "cover_command",
    inputType = ProtoSchema.Message.CoverCommandRequest,
    outputType = ProtoSchema.Message.void,
  },
  date_command = {
    service = "APIConnection",
    method = "date_command",
    inputType = ProtoSchema.Message.DateCommandRequest,
    outputType = ProtoSchema.Message.void,
  },
  datetime_command = {
    service = "APIConnection",
    method = "datetime_command",
    inputType = ProtoSchema.Message.DateTimeCommandRequest,
    outputType = ProtoSchema.Message.void,
  },
  fan_command = {
    service = "APIConnection",
    method = "fan_command",
    inputType = ProtoSchema.Message.FanCommandRequest,
    outputType = ProtoSchema.Message.void,
  },
  light_command = {
    service = "APIConnection",
    method = "light_command",
    inputType = ProtoSchema.Message.LightCommandRequest,
    outputType = ProtoSchema.Message.void,
  },
  lock_command = {
    service = "APIConnection",
    method = "lock_command",
    inputType = ProtoSchema.Message.LockCommandRequest,
    outputType = ProtoSchema.Message.void,
  },
  media_player_command = {
    service = "APIConnection",
    method = "media_player_command",
    inputType = ProtoSchema.Message.MediaPlayerCommandRequest,
    outputType = ProtoSchema.Message.void,
  },
  number_command = {
    service = "APIConnection",
    method = "number_command",
    inputType = ProtoSchema.Message.NumberCommandRequest,
    outputType = ProtoSchema.Message.void,
  },
  select_command = {
    service = "APIConnection",
    method = "select_command",
    inputType = ProtoSchema.Message.SelectCommandRequest,
    outputType = ProtoSchema.Message.void,
  },
  siren_command = {
    service = "APIConnection",
    method = "siren_command",
    inputType = ProtoSchema.Message.SirenCommandRequest,
    outputType = ProtoSchema.Message.void,
  },
  switch_command = {
    service = "APIConnection",
    method = "switch_command",
    inputType = ProtoSchema.Message.SwitchCommandRequest,
    outputType = ProtoSchema.Message.void,
  },
  text_command = {
    service = "APIConnection",
    method = "text_command",
    inputType = ProtoSchema.Message.TextCommandRequest,
    outputType = ProtoSchema.Message.void,
  },
  time_command = {
    service = "APIConnection",
    method = "time_command",
    inputType = ProtoSchema.Message.TimeCommandRequest,
    outputType = ProtoSchema.Message.void,
  },
  update_command = {
    service = "APIConnection",
    method = "update_command",
    inputType = ProtoSchema.Message.UpdateCommandRequest,
    outputType = ProtoSchema.Message.void,
  },
  valve_command = {
    service = "APIConnection",
    method = "valve_command",
    inputType = ProtoSchema.Message.ValveCommandRequest,
    outputType = ProtoSchema.Message.void,
  },
  subscribe_bluetooth_le_advertisements = {
    service = "APIConnection",
    method = "subscribe_bluetooth_le_advertisements",
    inputType = ProtoSchema.Message.SubscribeBluetoothLEAdvertisementsRequest,
    outputType = ProtoSchema.Message.void,
  },
  bluetooth_device_request = {
    service = "APIConnection",
    method = "bluetooth_device_request",
    inputType = ProtoSchema.Message.BluetoothDeviceRequest,
    outputType = ProtoSchema.Message.void,
  },
  bluetooth_gatt_get_services = {
    service = "APIConnection",
    method = "bluetooth_gatt_get_services",
    inputType = ProtoSchema.Message.BluetoothGATTGetServicesRequest,
    outputType = ProtoSchema.Message.void,
  },
  bluetooth_gatt_read = {
    service = "APIConnection",
    method = "bluetooth_gatt_read",
    inputType = ProtoSchema.Message.BluetoothGATTReadRequest,
    outputType = ProtoSchema.Message.void,
  },
  bluetooth_gatt_write = {
    service = "APIConnection",
    method = "bluetooth_gatt_write",
    inputType = ProtoSchema.Message.BluetoothGATTWriteRequest,
    outputType = ProtoSchema.Message.void,
  },
  bluetooth_gatt_read_descriptor = {
    service = "APIConnection",
    method = "bluetooth_gatt_read_descriptor",
    inputType = ProtoSchema.Message.BluetoothGATTReadDescriptorRequest,
    outputType = ProtoSchema.Message.void,
  },
  bluetooth_gatt_write_descriptor = {
    service = "APIConnection",
    method = "bluetooth_gatt_write_descriptor",
    inputType = ProtoSchema.Message.BluetoothGATTWriteDescriptorRequest,
    outputType = ProtoSchema.Message.void,
  },
  bluetooth_gatt_notify = {
    service = "APIConnection",
    method = "bluetooth_gatt_notify",
    inputType = ProtoSchema.Message.BluetoothGATTNotifyRequest,
    outputType = ProtoSchema.Message.void,
  },
  subscribe_bluetooth_connections_free = {
    service = "APIConnection",
    method = "subscribe_bluetooth_connections_free",
    inputType = ProtoSchema.Message.SubscribeBluetoothConnectionsFreeRequest,
    outputType = ProtoSchema.Message.BluetoothConnectionsFreeResponse,
  },
  unsubscribe_bluetooth_le_advertisements = {
    service = "APIConnection",
    method = "unsubscribe_bluetooth_le_advertisements",
    inputType = ProtoSchema.Message.UnsubscribeBluetoothLEAdvertisementsRequest,
    outputType = ProtoSchema.Message.void,
  },
  bluetooth_scanner_set_mode = {
    service = "APIConnection",
    method = "bluetooth_scanner_set_mode",
    inputType = ProtoSchema.Message.BluetoothScannerSetModeRequest,
    outputType = ProtoSchema.Message.void,
  },
  subscribe_voice_assistant = {
    service = "APIConnection",
    method = "subscribe_voice_assistant",
    inputType = ProtoSchema.Message.SubscribeVoiceAssistantRequest,
    outputType = ProtoSchema.Message.void,
  },
  voice_assistant_get_configuration = {
    service = "APIConnection",
    method = "voice_assistant_get_configuration",
    inputType = ProtoSchema.Message.VoiceAssistantConfigurationRequest,
    outputType = ProtoSchema.Message.VoiceAssistantConfigurationResponse,
  },
  voice_assistant_set_configuration = {
    service = "APIConnection",
    method = "voice_assistant_set_configuration",
    inputType = ProtoSchema.Message.VoiceAssistantSetConfiguration,
    outputType = ProtoSchema.Message.void,
  },
  alarm_control_panel_command = {
    service = "APIConnection",
    method = "alarm_control_panel_command",
    inputType = ProtoSchema.Message.AlarmControlPanelCommandRequest,
    outputType = ProtoSchema.Message.void,
  },
  zwave_proxy_frame = {
    service = "APIConnection",
    method = "zwave_proxy_frame",
    inputType = ProtoSchema.Message.ZWaveProxyFrame,
    outputType = ProtoSchema.Message.void,
  },
  zwave_proxy_request = {
    service = "APIConnection",
    method = "zwave_proxy_request",
    inputType = ProtoSchema.Message.ZWaveProxyRequest,
    outputType = ProtoSchema.Message.void,
  },
  infrared_rf_transmit_raw_timings = {
    service = "APIConnection",
    method = "infrared_rf_transmit_raw_timings",
    inputType = ProtoSchema.Message.InfraredRFTransmitRawTimingsRequest,
    outputType = ProtoSchema.Message.void,
  },
}

return ProtoSchema

-- Generated Lua schema from protobuf descriptor set
-- Do not edit manually

--- @class ProtoFieldSchema
--- @field name string The name of the field.
--- @field wireType integer The protobuf wire type (see ProtoSchema.WireType).
--- @field type integer The protobuf type (see ProtoSchema.DataType).
--- @field repeated boolean? Whether the field is repeated (optional).
--- @field subschema ProtoMessageSchema? The subschema for nested messages (optional).

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

--- @class ProtoSchema
--- @field WireType WireType Maps protobuf wire types to their integer values.
--- @field DataType DataType Maps protobuf data types to their integer values.
--- @field Message table<string, ProtoMessageSchema> Maps message names to their definitions.
--- @field Enum table<string, ProtoEnum> Maps enum names to their definitions.
--- @field RPC table<string, ProtoServiceSchema> Maps service names to their method definitions.
local PROTOBUF_SCHEMA = {}

--- @enum WireType
PROTOBUF_SCHEMA.WireType = {
  VARINT = 0,
  FIXED64 = 1,
  LENGTH_DELIMITED = 2,
  FIXED32 = 5,
}

--- @enum DataType
PROTOBUF_SCHEMA.DataType = {
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

PROTOBUF_SCHEMA.Enum = {
  --- @enum APISourceType
  APISourceType = {
    SOURCE_BOTH = 0,
    SOURCE_SERVER = 1,
    SOURCE_CLIENT = 2,
  },
  --- @enum EntityCategory
  EntityCategory = {
    ENTITY_CATEGORY_NONE = 0,
    ENTITY_CATEGORY_CONFIG = 1,
    ENTITY_CATEGORY_DIAGNOSTIC = 2,
  },
  --- @enum LegacyCoverState
  LegacyCoverState = {
    LEGACY_COVER_STATE_OPEN = 0,
    LEGACY_COVER_STATE_CLOSED = 1,
  },
  --- @enum CoverOperation
  CoverOperation = {
    COVER_OPERATION_IDLE = 0,
    COVER_OPERATION_IS_OPENING = 1,
    COVER_OPERATION_IS_CLOSING = 2,
  },
  --- @enum LegacyCoverCommand
  LegacyCoverCommand = {
    LEGACY_COVER_COMMAND_OPEN = 0,
    LEGACY_COVER_COMMAND_CLOSE = 1,
    LEGACY_COVER_COMMAND_STOP = 2,
  },
  --- @enum FanSpeed
  FanSpeed = {
    FAN_SPEED_LOW = 0,
    FAN_SPEED_MEDIUM = 1,
    FAN_SPEED_HIGH = 2,
  },
  --- @enum FanDirection
  FanDirection = {
    FAN_DIRECTION_FORWARD = 0,
    FAN_DIRECTION_REVERSE = 1,
  },
  --- @enum ColorMode
  ColorMode = {
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
  },
  --- @enum SensorStateClass
  SensorStateClass = {
    STATE_CLASS_NONE = 0,
    STATE_CLASS_MEASUREMENT = 1,
    STATE_CLASS_TOTAL_INCREASING = 2,
    STATE_CLASS_TOTAL = 3,
  },
  --- @enum SensorLastResetType
  SensorLastResetType = {
    LAST_RESET_NONE = 0,
    LAST_RESET_NEVER = 1,
    LAST_RESET_AUTO = 2,
  },
  --- @enum LogLevel
  LogLevel = {
    LOG_LEVEL_NONE = 0,
    LOG_LEVEL_ERROR = 1,
    LOG_LEVEL_WARN = 2,
    LOG_LEVEL_INFO = 3,
    LOG_LEVEL_CONFIG = 4,
    LOG_LEVEL_DEBUG = 5,
    LOG_LEVEL_VERBOSE = 6,
    LOG_LEVEL_VERY_VERBOSE = 7,
  },
  --- @enum ServiceArgType
  ServiceArgType = {
    SERVICE_ARG_TYPE_BOOL = 0,
    SERVICE_ARG_TYPE_INT = 1,
    SERVICE_ARG_TYPE_FLOAT = 2,
    SERVICE_ARG_TYPE_STRING = 3,
    SERVICE_ARG_TYPE_BOOL_ARRAY = 4,
    SERVICE_ARG_TYPE_INT_ARRAY = 5,
    SERVICE_ARG_TYPE_FLOAT_ARRAY = 6,
    SERVICE_ARG_TYPE_STRING_ARRAY = 7,
  },
  --- @enum ClimateMode
  ClimateMode = {
    CLIMATE_MODE_OFF = 0,
    CLIMATE_MODE_HEAT_COOL = 1,
    CLIMATE_MODE_COOL = 2,
    CLIMATE_MODE_HEAT = 3,
    CLIMATE_MODE_FAN_ONLY = 4,
    CLIMATE_MODE_DRY = 5,
    CLIMATE_MODE_AUTO = 6,
  },
  --- @enum ClimateFanMode
  ClimateFanMode = {
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
  },
  --- @enum ClimateSwingMode
  ClimateSwingMode = {
    CLIMATE_SWING_OFF = 0,
    CLIMATE_SWING_BOTH = 1,
    CLIMATE_SWING_VERTICAL = 2,
    CLIMATE_SWING_HORIZONTAL = 3,
  },
  --- @enum ClimateAction
  ClimateAction = {
    CLIMATE_ACTION_OFF = 0,
    CLIMATE_ACTION_COOLING = 2,
    CLIMATE_ACTION_HEATING = 3,
    CLIMATE_ACTION_IDLE = 4,
    CLIMATE_ACTION_DRYING = 5,
    CLIMATE_ACTION_FAN = 6,
  },
  --- @enum ClimatePreset
  ClimatePreset = {
    CLIMATE_PRESET_NONE = 0,
    CLIMATE_PRESET_HOME = 1,
    CLIMATE_PRESET_AWAY = 2,
    CLIMATE_PRESET_BOOST = 3,
    CLIMATE_PRESET_COMFORT = 4,
    CLIMATE_PRESET_ECO = 5,
    CLIMATE_PRESET_SLEEP = 6,
    CLIMATE_PRESET_ACTIVITY = 7,
  },
  --- @enum NumberMode
  NumberMode = {
    NUMBER_MODE_AUTO = 0,
    NUMBER_MODE_BOX = 1,
    NUMBER_MODE_SLIDER = 2,
  },
  --- @enum LockState
  LockState = {
    LOCK_STATE_NONE = 0,
    LOCK_STATE_LOCKED = 1,
    LOCK_STATE_UNLOCKED = 2,
    LOCK_STATE_JAMMED = 3,
    LOCK_STATE_LOCKING = 4,
    LOCK_STATE_UNLOCKING = 5,
  },
  --- @enum LockCommand
  LockCommand = {
    LOCK_UNLOCK = 0,
    LOCK_LOCK = 1,
    LOCK_OPEN = 2,
  },
  --- @enum MediaPlayerState
  MediaPlayerState = {
    MEDIA_PLAYER_STATE_NONE = 0,
    MEDIA_PLAYER_STATE_IDLE = 1,
    MEDIA_PLAYER_STATE_PLAYING = 2,
    MEDIA_PLAYER_STATE_PAUSED = 3,
    MEDIA_PLAYER_STATE_ANNOUNCING = 4,
    MEDIA_PLAYER_STATE_OFF = 5,
    MEDIA_PLAYER_STATE_ON = 6,
  },
  --- @enum MediaPlayerCommand
  MediaPlayerCommand = {
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
  },
  --- @enum MediaPlayerFormatPurpose
  MediaPlayerFormatPurpose = {
    MEDIA_PLAYER_FORMAT_PURPOSE_DEFAULT = 0,
    MEDIA_PLAYER_FORMAT_PURPOSE_ANNOUNCEMENT = 1,
  },
  --- @enum BluetoothDeviceRequestType
  BluetoothDeviceRequestType = {
    BLUETOOTH_DEVICE_REQUEST_TYPE_CONNECT = 0,
    BLUETOOTH_DEVICE_REQUEST_TYPE_DISCONNECT = 1,
    BLUETOOTH_DEVICE_REQUEST_TYPE_PAIR = 2,
    BLUETOOTH_DEVICE_REQUEST_TYPE_UNPAIR = 3,
    BLUETOOTH_DEVICE_REQUEST_TYPE_CONNECT_V3_WITH_CACHE = 4,
    BLUETOOTH_DEVICE_REQUEST_TYPE_CONNECT_V3_WITHOUT_CACHE = 5,
    BLUETOOTH_DEVICE_REQUEST_TYPE_CLEAR_CACHE = 6,
  },
  --- @enum BluetoothScannerState
  BluetoothScannerState = {
    BLUETOOTH_SCANNER_STATE_IDLE = 0,
    BLUETOOTH_SCANNER_STATE_STARTING = 1,
    BLUETOOTH_SCANNER_STATE_RUNNING = 2,
    BLUETOOTH_SCANNER_STATE_FAILED = 3,
    BLUETOOTH_SCANNER_STATE_STOPPING = 4,
    BLUETOOTH_SCANNER_STATE_STOPPED = 5,
  },
  --- @enum BluetoothScannerMode
  BluetoothScannerMode = {
    BLUETOOTH_SCANNER_MODE_PASSIVE = 0,
    BLUETOOTH_SCANNER_MODE_ACTIVE = 1,
  },
  --- @enum VoiceAssistantSubscribeFlag
  VoiceAssistantSubscribeFlag = {
    VOICE_ASSISTANT_SUBSCRIBE_NONE = 0,
    VOICE_ASSISTANT_SUBSCRIBE_API_AUDIO = 1,
  },
  --- @enum VoiceAssistantRequestFlag
  VoiceAssistantRequestFlag = {
    VOICE_ASSISTANT_REQUEST_NONE = 0,
    VOICE_ASSISTANT_REQUEST_USE_VAD = 1,
    VOICE_ASSISTANT_REQUEST_USE_WAKE_WORD = 2,
  },
  --- @enum VoiceAssistantEvent
  VoiceAssistantEvent = {
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
  },
  --- @enum VoiceAssistantTimerEvent
  VoiceAssistantTimerEvent = {
    VOICE_ASSISTANT_TIMER_STARTED = 0,
    VOICE_ASSISTANT_TIMER_UPDATED = 1,
    VOICE_ASSISTANT_TIMER_CANCELLED = 2,
    VOICE_ASSISTANT_TIMER_FINISHED = 3,
  },
  --- @enum AlarmControlPanelState
  AlarmControlPanelState = {
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
  },
  --- @enum AlarmControlPanelStateCommand
  AlarmControlPanelStateCommand = {
    ALARM_CONTROL_PANEL_DISARM = 0,
    ALARM_CONTROL_PANEL_ARM_AWAY = 1,
    ALARM_CONTROL_PANEL_ARM_HOME = 2,
    ALARM_CONTROL_PANEL_ARM_NIGHT = 3,
    ALARM_CONTROL_PANEL_ARM_VACATION = 4,
    ALARM_CONTROL_PANEL_ARM_CUSTOM_BYPASS = 5,
    ALARM_CONTROL_PANEL_TRIGGER = 6,
  },
  --- @enum TextMode
  TextMode = {
    TEXT_MODE_TEXT = 0,
    TEXT_MODE_PASSWORD = 1,
  },
  --- @enum ValveOperation
  ValveOperation = {
    VALVE_OPERATION_IDLE = 0,
    VALVE_OPERATION_IS_OPENING = 1,
    VALVE_OPERATION_IS_CLOSING = 2,
  },
  --- @enum UpdateCommand
  UpdateCommand = {
    UPDATE_COMMAND_NONE = 0,
    UPDATE_COMMAND_UPDATE = 1,
    UPDATE_COMMAND_CHECK = 2,
  },
  --- @enum ZWaveProxyRequestType
  ZWaveProxyRequestType = {
    ZWAVE_PROXY_REQUEST_TYPE_SUBSCRIBE = 0,
    ZWAVE_PROXY_REQUEST_TYPE_UNSUBSCRIBE = 1,
    ZWAVE_PROXY_REQUEST_TYPE_HOME_ID_CHANGE = 2,
  },
}

--- @alias ProtoEnum APISourceType|EntityCategory|LegacyCoverState|CoverOperation|LegacyCoverCommand|FanSpeed|FanDirection|ColorMode|SensorStateClass|SensorLastResetType|LogLevel|ServiceArgType|ClimateMode|ClimateFanMode|ClimateSwingMode|ClimateAction|ClimatePreset|NumberMode|LockState|LockCommand|MediaPlayerState|MediaPlayerCommand|MediaPlayerFormatPurpose|BluetoothDeviceRequestType|BluetoothScannerState|BluetoothScannerMode|VoiceAssistantSubscribeFlag|VoiceAssistantRequestFlag|VoiceAssistantEvent|VoiceAssistantTimerEvent|AlarmControlPanelState|AlarmControlPanelStateCommand|TextMode|ValveOperation|UpdateCommand|ZWaveProxyRequestType

PROTOBUF_SCHEMA.Message = {
  void = {
    name = "void",
    options = {},
    fields = {},
  },
  HelloRequest = {
    name = "HelloRequest",
    options = {
      id = 1,
      source = 2,
      no_delay = 1,
    },
    fields = {
      [1] = {
        name = "client_info",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "api_version_major",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [3] = {
        name = "api_version_minor",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  HelloResponse = {
    name = "HelloResponse",
    options = {
      id = 2,
      source = 1,
      no_delay = 1,
    },
    fields = {
      [1] = {
        name = "api_version_major",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [2] = {
        name = "api_version_minor",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [3] = {
        name = "server_info",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [4] = {
        name = "name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
    },
  },
  AuthenticationRequest = {
    name = "AuthenticationRequest",
    options = {
      id = 3,
      source = 2,
      ifdef = "USE_API_PASSWORD",
      no_delay = 1,
    },
    fields = {
      [1] = {
        name = "password",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
    },
  },
  AuthenticationResponse = {
    name = "AuthenticationResponse",
    options = {
      id = 4,
      source = 1,
      ifdef = "USE_API_PASSWORD",
      no_delay = 1,
    },
    fields = {
      [1] = {
        name = "invalid_password",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
    },
  },
  DisconnectRequest = {
    name = "DisconnectRequest",
    options = {
      id = 5,
      source = 0,
      no_delay = 1,
    },
    fields = {},
  },
  DisconnectResponse = {
    name = "DisconnectResponse",
    options = {
      id = 6,
      source = 0,
      no_delay = 1,
    },
    fields = {},
  },
  PingRequest = {
    name = "PingRequest",
    options = {
      id = 7,
      source = 0,
    },
    fields = {},
  },
  PingResponse = {
    name = "PingResponse",
    options = {
      id = 8,
      source = 0,
    },
    fields = {},
  },
  DeviceInfoRequest = {
    name = "DeviceInfoRequest",
    options = {
      id = 9,
      source = 2,
    },
    fields = {},
  },
  AreaInfo = {
    name = "AreaInfo",
    options = {},
    fields = {
      [1] = {
        name = "area_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [2] = {
        name = "name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
    },
  },
  DeviceInfo = {
    name = "DeviceInfo",
    options = {},
    fields = {
      [1] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [2] = {
        name = "name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [3] = {
        name = "area_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  DeviceInfoResponse = {
    name = "DeviceInfoResponse",
    options = {
      id = 10,
      source = 1,
    },
    fields = {
      [1] = {
        name = "uses_password",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [2] = {
        name = "name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [3] = {
        name = "mac_address",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [4] = {
        name = "esphome_version",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [5] = {
        name = "compilation_time",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [6] = {
        name = "model",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [7] = {
        name = "has_deep_sleep",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [8] = {
        name = "project_name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [9] = {
        name = "project_version",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [10] = {
        name = "webserver_port",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [11] = {
        name = "legacy_bluetooth_proxy_version",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [15] = {
        name = "bluetooth_proxy_feature_flags",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [12] = {
        name = "manufacturer",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [13] = {
        name = "friendly_name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [14] = {
        name = "legacy_voice_assistant_version",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [17] = {
        name = "voice_assistant_feature_flags",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [16] = {
        name = "suggested_area",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [18] = {
        name = "bluetooth_mac_address",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [19] = {
        name = "api_encryption_supported",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [20] = {
        name = "devices",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.MESSAGE,
        repeated = true,
      },
      [21] = {
        name = "areas",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.MESSAGE,
        repeated = true,
      },
      [22] = {
        name = "area",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.MESSAGE,
      },
      [23] = {
        name = "zwave_proxy_feature_flags",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [24] = {
        name = "zwave_home_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  ListEntitiesRequest = {
    name = "ListEntitiesRequest",
    options = {
      id = 11,
      source = 2,
    },
    fields = {},
  },
  ListEntitiesDoneResponse = {
    name = "ListEntitiesDoneResponse",
    options = {
      id = 19,
      source = 1,
      no_delay = 1,
    },
    fields = {},
  },
  SubscribeStatesRequest = {
    name = "SubscribeStatesRequest",
    options = {
      id = 20,
      source = 2,
    },
    fields = {},
  },
  ListEntitiesBinarySensorResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "key",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [3] = {
        name = "name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [5] = {
        name = "device_class",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [6] = {
        name = "is_status_binary_sensor",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [7] = {
        name = "disabled_by_default",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [8] = {
        name = "icon",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [9] = {
        name = "entity_category",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- EntityCategory
      },
      [10] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  BinarySensorStateResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "state",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [3] = {
        name = "missing_state",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [4] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  ListEntitiesCoverResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "key",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [3] = {
        name = "name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [5] = {
        name = "assumed_state",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [6] = {
        name = "supports_position",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [7] = {
        name = "supports_tilt",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [8] = {
        name = "device_class",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [9] = {
        name = "disabled_by_default",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [10] = {
        name = "icon",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [11] = {
        name = "entity_category",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- EntityCategory
      },
      [12] = {
        name = "supports_stop",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [13] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  CoverStateResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "legacy_state",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- LegacyCoverState
      },
      [3] = {
        name = "position",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [4] = {
        name = "tilt",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [5] = {
        name = "current_operation",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- CoverOperation
      },
      [6] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  CoverCommandRequest = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "has_legacy_command",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [3] = {
        name = "legacy_command",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- LegacyCoverCommand
      },
      [4] = {
        name = "has_position",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [5] = {
        name = "position",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [6] = {
        name = "has_tilt",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [7] = {
        name = "tilt",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [8] = {
        name = "stop",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [9] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  ListEntitiesFanResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "key",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [3] = {
        name = "name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [5] = {
        name = "supports_oscillation",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [6] = {
        name = "supports_speed",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [7] = {
        name = "supports_direction",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [8] = {
        name = "supported_speed_count",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.INT32,
      },
      [9] = {
        name = "disabled_by_default",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [10] = {
        name = "icon",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [11] = {
        name = "entity_category",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- EntityCategory
      },
      [12] = {
        name = "supported_preset_modes",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
        repeated = true,
      },
      [13] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  FanStateResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "state",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [3] = {
        name = "oscillating",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [4] = {
        name = "speed",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- FanSpeed
      },
      [5] = {
        name = "direction",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- FanDirection
      },
      [6] = {
        name = "speed_level",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.INT32,
      },
      [7] = {
        name = "preset_mode",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [8] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  FanCommandRequest = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "has_state",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [3] = {
        name = "state",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [4] = {
        name = "has_speed",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [5] = {
        name = "speed",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- FanSpeed
      },
      [6] = {
        name = "has_oscillating",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [7] = {
        name = "oscillating",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [8] = {
        name = "has_direction",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [9] = {
        name = "direction",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- FanDirection
      },
      [10] = {
        name = "has_speed_level",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [11] = {
        name = "speed_level",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.INT32,
      },
      [12] = {
        name = "has_preset_mode",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [13] = {
        name = "preset_mode",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [14] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  ListEntitiesLightResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "key",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [3] = {
        name = "name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [12] = {
        name = "supported_color_modes",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- ColorMode
        repeated = true,
      },
      [5] = {
        name = "legacy_supports_brightness",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [6] = {
        name = "legacy_supports_rgb",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [7] = {
        name = "legacy_supports_white_value",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [8] = {
        name = "legacy_supports_color_temperature",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [9] = {
        name = "min_mireds",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [10] = {
        name = "max_mireds",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [11] = {
        name = "effects",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
        repeated = true,
      },
      [13] = {
        name = "disabled_by_default",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [14] = {
        name = "icon",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [15] = {
        name = "entity_category",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- EntityCategory
      },
      [16] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  LightStateResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "state",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [3] = {
        name = "brightness",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [11] = {
        name = "color_mode",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- ColorMode
      },
      [10] = {
        name = "color_brightness",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [4] = {
        name = "red",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [5] = {
        name = "green",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [6] = {
        name = "blue",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [7] = {
        name = "white",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [8] = {
        name = "color_temperature",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [12] = {
        name = "cold_white",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [13] = {
        name = "warm_white",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [9] = {
        name = "effect",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [14] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  LightCommandRequest = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "has_state",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [3] = {
        name = "state",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [4] = {
        name = "has_brightness",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [5] = {
        name = "brightness",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [22] = {
        name = "has_color_mode",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [23] = {
        name = "color_mode",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- ColorMode
      },
      [20] = {
        name = "has_color_brightness",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [21] = {
        name = "color_brightness",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [6] = {
        name = "has_rgb",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [7] = {
        name = "red",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [8] = {
        name = "green",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [9] = {
        name = "blue",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [10] = {
        name = "has_white",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [11] = {
        name = "white",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [12] = {
        name = "has_color_temperature",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [13] = {
        name = "color_temperature",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [24] = {
        name = "has_cold_white",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [25] = {
        name = "cold_white",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [26] = {
        name = "has_warm_white",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [27] = {
        name = "warm_white",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [14] = {
        name = "has_transition_length",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [15] = {
        name = "transition_length",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [16] = {
        name = "has_flash_length",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [17] = {
        name = "flash_length",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [18] = {
        name = "has_effect",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [19] = {
        name = "effect",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [28] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  ListEntitiesSensorResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "key",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [3] = {
        name = "name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [5] = {
        name = "icon",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [6] = {
        name = "unit_of_measurement",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [7] = {
        name = "accuracy_decimals",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.INT32,
      },
      [8] = {
        name = "force_update",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [9] = {
        name = "device_class",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [10] = {
        name = "state_class",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- SensorStateClass
      },
      [11] = {
        name = "legacy_last_reset_type",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- SensorLastResetType
      },
      [12] = {
        name = "disabled_by_default",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [13] = {
        name = "entity_category",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- EntityCategory
      },
      [14] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  SensorStateResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "state",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [3] = {
        name = "missing_state",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [4] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  ListEntitiesSwitchResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "key",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [3] = {
        name = "name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [5] = {
        name = "icon",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [6] = {
        name = "assumed_state",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [7] = {
        name = "disabled_by_default",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [8] = {
        name = "entity_category",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- EntityCategory
      },
      [9] = {
        name = "device_class",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [10] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  SwitchStateResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "state",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [3] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  SwitchCommandRequest = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "state",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [3] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  ListEntitiesTextSensorResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "key",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [3] = {
        name = "name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [5] = {
        name = "icon",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [6] = {
        name = "disabled_by_default",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [7] = {
        name = "entity_category",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- EntityCategory
      },
      [8] = {
        name = "device_class",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [9] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  TextSensorStateResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "state",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [3] = {
        name = "missing_state",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [4] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  SubscribeLogsRequest = {
    name = "SubscribeLogsRequest",
    options = {
      id = 28,
      source = 2,
    },
    fields = {
      [1] = {
        name = "level",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- LogLevel
      },
      [2] = {
        name = "dump_config",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
    },
  },
  SubscribeLogsResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- LogLevel
      },
      [3] = {
        name = "message",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.BYTES,
      },
    },
  },
  NoiseEncryptionSetKeyRequest = {
    name = "NoiseEncryptionSetKeyRequest",
    options = {
      id = 124,
      source = 2,
      ifdef = "USE_API_NOISE",
    },
    fields = {
      [1] = {
        name = "key",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.BYTES,
      },
    },
  },
  NoiseEncryptionSetKeyResponse = {
    name = "NoiseEncryptionSetKeyResponse",
    options = {
      id = 125,
      source = 1,
      ifdef = "USE_API_NOISE",
    },
    fields = {
      [1] = {
        name = "success",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
    },
  },
  SubscribeHomeassistantServicesRequest = {
    name = "SubscribeHomeassistantServicesRequest",
    options = {
      id = 34,
      source = 2,
      ifdef = "USE_API_HOMEASSISTANT_SERVICES",
    },
    fields = {},
  },
  HomeassistantServiceMap = {
    name = "HomeassistantServiceMap",
    options = {},
    fields = {
      [1] = {
        name = "key",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "value",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
    },
  },
  HomeassistantActionRequest = {
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
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "data",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.MESSAGE,
        repeated = true,
      },
      [3] = {
        name = "data_template",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.MESSAGE,
        repeated = true,
      },
      [4] = {
        name = "variables",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.MESSAGE,
        repeated = true,
      },
      [5] = {
        name = "is_event",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [6] = {
        name = "call_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [7] = {
        name = "wants_response",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [8] = {
        name = "response_template",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
    },
  },
  HomeassistantActionResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [2] = {
        name = "success",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [3] = {
        name = "error_message",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [4] = {
        name = "response_data",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.BYTES,
      },
    },
  },
  SubscribeHomeAssistantStatesRequest = {
    name = "SubscribeHomeAssistantStatesRequest",
    options = {
      id = 38,
      source = 2,
      ifdef = "USE_API_HOMEASSISTANT_STATES",
    },
    fields = {},
  },
  SubscribeHomeAssistantStateResponse = {
    name = "SubscribeHomeAssistantStateResponse",
    options = {
      id = 39,
      source = 1,
      ifdef = "USE_API_HOMEASSISTANT_STATES",
    },
    fields = {
      [1] = {
        name = "entity_id",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "attribute",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [3] = {
        name = "once",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
    },
  },
  HomeAssistantStateResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "state",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [3] = {
        name = "attribute",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
    },
  },
  GetTimeRequest = {
    name = "GetTimeRequest",
    options = {
      id = 36,
      source = 1,
    },
    fields = {},
  },
  GetTimeResponse = {
    name = "GetTimeResponse",
    options = {
      id = 37,
      source = 2,
      no_delay = 1,
    },
    fields = {
      [1] = {
        name = "epoch_seconds",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "timezone",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
    },
  },
  ListEntitiesServicesArgument = {
    name = "ListEntitiesServicesArgument",
    options = {
      ifdef = "USE_API_SERVICES",
    },
    fields = {
      [1] = {
        name = "name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "type",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- ServiceArgType
      },
    },
  },
  ListEntitiesServicesResponse = {
    name = "ListEntitiesServicesResponse",
    options = {
      id = 41,
      source = 1,
      ifdef = "USE_API_SERVICES",
    },
    fields = {
      [1] = {
        name = "name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "key",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [3] = {
        name = "args",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.MESSAGE,
        repeated = true,
      },
    },
  },
  ExecuteServiceArgument = {
    name = "ExecuteServiceArgument",
    options = {
      ifdef = "USE_API_SERVICES",
    },
    fields = {
      [1] = {
        name = "bool_",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [2] = {
        name = "legacy_int",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.INT32,
      },
      [3] = {
        name = "float_",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [4] = {
        name = "string_",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [5] = {
        name = "int_",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.SINT32,
      },
      [6] = {
        name = "bool_array",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
        repeated = true,
      },
      [7] = {
        name = "int_array",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.SINT32,
        repeated = true,
      },
      [8] = {
        name = "float_array",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
        repeated = true,
      },
      [9] = {
        name = "string_array",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
        repeated = true,
      },
    },
  },
  ExecuteServiceRequest = {
    name = "ExecuteServiceRequest",
    options = {
      id = 42,
      source = 2,
      ifdef = "USE_API_SERVICES",
      no_delay = 1,
    },
    fields = {
      [1] = {
        name = "key",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "args",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.MESSAGE,
        repeated = true,
      },
    },
  },
  ListEntitiesCameraResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "key",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [3] = {
        name = "name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [5] = {
        name = "disabled_by_default",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [6] = {
        name = "icon",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [7] = {
        name = "entity_category",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- EntityCategory
      },
      [8] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  CameraImageResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "data",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.BYTES,
      },
      [3] = {
        name = "done",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [4] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  CameraImageRequest = {
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
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [2] = {
        name = "stream",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
    },
  },
  ListEntitiesClimateResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "key",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [3] = {
        name = "name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [5] = {
        name = "supports_current_temperature",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [6] = {
        name = "supports_two_point_target_temperature",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [7] = {
        name = "supported_modes",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- ClimateMode
        repeated = true,
      },
      [8] = {
        name = "visual_min_temperature",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [9] = {
        name = "visual_max_temperature",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [10] = {
        name = "visual_target_temperature_step",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [11] = {
        name = "legacy_supports_away",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [12] = {
        name = "supports_action",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [13] = {
        name = "supported_fan_modes",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- ClimateFanMode
        repeated = true,
      },
      [14] = {
        name = "supported_swing_modes",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- ClimateSwingMode
        repeated = true,
      },
      [15] = {
        name = "supported_custom_fan_modes",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
        repeated = true,
      },
      [16] = {
        name = "supported_presets",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- ClimatePreset
        repeated = true,
      },
      [17] = {
        name = "supported_custom_presets",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
        repeated = true,
      },
      [18] = {
        name = "disabled_by_default",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [19] = {
        name = "icon",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [20] = {
        name = "entity_category",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- EntityCategory
      },
      [21] = {
        name = "visual_current_temperature_step",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [22] = {
        name = "supports_current_humidity",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [23] = {
        name = "supports_target_humidity",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [24] = {
        name = "visual_min_humidity",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [25] = {
        name = "visual_max_humidity",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [26] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [27] = {
        name = "feature_flags",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  ClimateStateResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "mode",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- ClimateMode
      },
      [3] = {
        name = "current_temperature",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [4] = {
        name = "target_temperature",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [5] = {
        name = "target_temperature_low",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [6] = {
        name = "target_temperature_high",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [7] = {
        name = "unused_legacy_away",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [8] = {
        name = "action",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- ClimateAction
      },
      [9] = {
        name = "fan_mode",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- ClimateFanMode
      },
      [10] = {
        name = "swing_mode",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- ClimateSwingMode
      },
      [11] = {
        name = "custom_fan_mode",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [12] = {
        name = "preset",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- ClimatePreset
      },
      [13] = {
        name = "custom_preset",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [14] = {
        name = "current_humidity",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [15] = {
        name = "target_humidity",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [16] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  ClimateCommandRequest = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "has_mode",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [3] = {
        name = "mode",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- ClimateMode
      },
      [4] = {
        name = "has_target_temperature",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [5] = {
        name = "target_temperature",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [6] = {
        name = "has_target_temperature_low",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [7] = {
        name = "target_temperature_low",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [8] = {
        name = "has_target_temperature_high",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [9] = {
        name = "target_temperature_high",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [10] = {
        name = "unused_has_legacy_away",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [11] = {
        name = "unused_legacy_away",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [12] = {
        name = "has_fan_mode",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [13] = {
        name = "fan_mode",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- ClimateFanMode
      },
      [14] = {
        name = "has_swing_mode",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [15] = {
        name = "swing_mode",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- ClimateSwingMode
      },
      [16] = {
        name = "has_custom_fan_mode",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [17] = {
        name = "custom_fan_mode",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [18] = {
        name = "has_preset",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [19] = {
        name = "preset",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- ClimatePreset
      },
      [20] = {
        name = "has_custom_preset",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [21] = {
        name = "custom_preset",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [22] = {
        name = "has_target_humidity",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [23] = {
        name = "target_humidity",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [24] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  ListEntitiesNumberResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "key",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [3] = {
        name = "name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [5] = {
        name = "icon",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [6] = {
        name = "min_value",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [7] = {
        name = "max_value",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [8] = {
        name = "step",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [9] = {
        name = "disabled_by_default",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [10] = {
        name = "entity_category",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- EntityCategory
      },
      [11] = {
        name = "unit_of_measurement",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [12] = {
        name = "mode",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- NumberMode
      },
      [13] = {
        name = "device_class",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [14] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  NumberStateResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "state",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [3] = {
        name = "missing_state",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [4] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  NumberCommandRequest = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "state",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [3] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  ListEntitiesSelectResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "key",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [3] = {
        name = "name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [5] = {
        name = "icon",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [6] = {
        name = "options",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
        repeated = true,
      },
      [7] = {
        name = "disabled_by_default",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [8] = {
        name = "entity_category",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- EntityCategory
      },
      [9] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  SelectStateResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "state",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [3] = {
        name = "missing_state",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [4] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  SelectCommandRequest = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "state",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [3] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  ListEntitiesSirenResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "key",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [3] = {
        name = "name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [5] = {
        name = "icon",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [6] = {
        name = "disabled_by_default",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [7] = {
        name = "tones",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
        repeated = true,
      },
      [8] = {
        name = "supports_duration",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [9] = {
        name = "supports_volume",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [10] = {
        name = "entity_category",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- EntityCategory
      },
      [11] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  SirenStateResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "state",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [3] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  SirenCommandRequest = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "has_state",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [3] = {
        name = "state",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [4] = {
        name = "has_tone",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [5] = {
        name = "tone",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [6] = {
        name = "has_duration",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [7] = {
        name = "duration",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [8] = {
        name = "has_volume",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [9] = {
        name = "volume",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [10] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  ListEntitiesLockResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "key",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [3] = {
        name = "name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [5] = {
        name = "icon",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [6] = {
        name = "disabled_by_default",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [7] = {
        name = "entity_category",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- EntityCategory
      },
      [8] = {
        name = "assumed_state",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [9] = {
        name = "supports_open",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [10] = {
        name = "requires_code",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [11] = {
        name = "code_format",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [12] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  LockStateResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "state",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- LockState
      },
      [3] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  LockCommandRequest = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "command",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- LockCommand
      },
      [3] = {
        name = "has_code",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [4] = {
        name = "code",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [5] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  ListEntitiesButtonResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "key",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [3] = {
        name = "name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [5] = {
        name = "icon",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [6] = {
        name = "disabled_by_default",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [7] = {
        name = "entity_category",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- EntityCategory
      },
      [8] = {
        name = "device_class",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [9] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  ButtonCommandRequest = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  MediaPlayerSupportedFormat = {
    name = "MediaPlayerSupportedFormat",
    options = {
      ifdef = "USE_MEDIA_PLAYER",
    },
    fields = {
      [1] = {
        name = "format",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "sample_rate",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [3] = {
        name = "num_channels",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [4] = {
        name = "purpose",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- MediaPlayerFormatPurpose
      },
      [5] = {
        name = "sample_bytes",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  ListEntitiesMediaPlayerResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "key",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [3] = {
        name = "name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [5] = {
        name = "icon",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [6] = {
        name = "disabled_by_default",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [7] = {
        name = "entity_category",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- EntityCategory
      },
      [8] = {
        name = "supports_pause",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [9] = {
        name = "supported_formats",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.MESSAGE,
        repeated = true,
      },
      [10] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [11] = {
        name = "feature_flags",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  MediaPlayerStateResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "state",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- MediaPlayerState
      },
      [3] = {
        name = "volume",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [4] = {
        name = "muted",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [5] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  MediaPlayerCommandRequest = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "has_command",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [3] = {
        name = "command",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- MediaPlayerCommand
      },
      [4] = {
        name = "has_volume",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [5] = {
        name = "volume",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [6] = {
        name = "has_media_url",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [7] = {
        name = "media_url",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [8] = {
        name = "has_announcement",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [9] = {
        name = "announcement",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [10] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  SubscribeBluetoothLEAdvertisementsRequest = {
    name = "SubscribeBluetoothLEAdvertisementsRequest",
    options = {
      id = 66,
      source = 2,
      ifdef = "USE_BLUETOOTH_PROXY",
    },
    fields = {
      [1] = {
        name = "flags",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  BluetoothServiceData = {
    name = "BluetoothServiceData",
    options = {},
    fields = {
      [1] = {
        name = "uuid",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "legacy_data",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
        repeated = true,
      },
      [3] = {
        name = "data",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.BYTES,
      },
    },
  },
  BluetoothLEAdvertisementResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT64,
      },
      [2] = {
        name = "name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.BYTES,
      },
      [3] = {
        name = "rssi",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.SINT32,
      },
      [4] = {
        name = "service_uuids",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
        repeated = true,
      },
      [5] = {
        name = "service_data",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.MESSAGE,
        repeated = true,
      },
      [6] = {
        name = "manufacturer_data",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.MESSAGE,
        repeated = true,
      },
      [7] = {
        name = "address_type",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  BluetoothLERawAdvertisement = {
    name = "BluetoothLERawAdvertisement",
    options = {},
    fields = {
      [1] = {
        name = "address",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT64,
      },
      [2] = {
        name = "rssi",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.SINT32,
      },
      [3] = {
        name = "address_type",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [4] = {
        name = "data",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.BYTES,
      },
    },
  },
  BluetoothLERawAdvertisementsResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.MESSAGE,
        repeated = true,
      },
    },
  },
  BluetoothDeviceRequest = {
    name = "BluetoothDeviceRequest",
    options = {
      id = 68,
      source = 2,
      ifdef = "USE_BLUETOOTH_PROXY",
    },
    fields = {
      [1] = {
        name = "address",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT64,
      },
      [2] = {
        name = "request_type",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- BluetoothDeviceRequestType
      },
      [3] = {
        name = "has_address_type",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [4] = {
        name = "address_type",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  BluetoothDeviceConnectionResponse = {
    name = "BluetoothDeviceConnectionResponse",
    options = {
      id = 69,
      source = 1,
      ifdef = "USE_BLUETOOTH_PROXY",
    },
    fields = {
      [1] = {
        name = "address",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT64,
      },
      [2] = {
        name = "connected",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [3] = {
        name = "mtu",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [4] = {
        name = "error",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.INT32,
      },
    },
  },
  BluetoothGATTGetServicesRequest = {
    name = "BluetoothGATTGetServicesRequest",
    options = {
      id = 70,
      source = 2,
      ifdef = "USE_BLUETOOTH_PROXY",
    },
    fields = {
      [1] = {
        name = "address",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT64,
      },
    },
  },
  BluetoothGATTDescriptor = {
    name = "BluetoothGATTDescriptor",
    options = {},
    fields = {
      [1] = {
        name = "uuid",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT64,
        repeated = true,
      },
      [2] = {
        name = "handle",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [3] = {
        name = "short_uuid",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  BluetoothGATTCharacteristic = {
    name = "BluetoothGATTCharacteristic",
    options = {},
    fields = {
      [1] = {
        name = "uuid",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT64,
        repeated = true,
      },
      [2] = {
        name = "handle",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [3] = {
        name = "properties",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [4] = {
        name = "descriptors",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.MESSAGE,
        repeated = true,
      },
      [5] = {
        name = "short_uuid",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  BluetoothGATTService = {
    name = "BluetoothGATTService",
    options = {},
    fields = {
      [1] = {
        name = "uuid",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT64,
        repeated = true,
      },
      [2] = {
        name = "handle",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [3] = {
        name = "characteristics",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.MESSAGE,
        repeated = true,
      },
      [4] = {
        name = "short_uuid",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  BluetoothGATTGetServicesResponse = {
    name = "BluetoothGATTGetServicesResponse",
    options = {
      id = 71,
      source = 1,
      ifdef = "USE_BLUETOOTH_PROXY",
    },
    fields = {
      [1] = {
        name = "address",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT64,
      },
      [2] = {
        name = "services",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.MESSAGE,
        repeated = true,
      },
    },
  },
  BluetoothGATTGetServicesDoneResponse = {
    name = "BluetoothGATTGetServicesDoneResponse",
    options = {
      id = 72,
      source = 1,
      ifdef = "USE_BLUETOOTH_PROXY",
    },
    fields = {
      [1] = {
        name = "address",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT64,
      },
    },
  },
  BluetoothGATTReadRequest = {
    name = "BluetoothGATTReadRequest",
    options = {
      id = 73,
      source = 2,
      ifdef = "USE_BLUETOOTH_PROXY",
    },
    fields = {
      [1] = {
        name = "address",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT64,
      },
      [2] = {
        name = "handle",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  BluetoothGATTReadResponse = {
    name = "BluetoothGATTReadResponse",
    options = {
      id = 74,
      source = 1,
      ifdef = "USE_BLUETOOTH_PROXY",
    },
    fields = {
      [1] = {
        name = "address",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT64,
      },
      [2] = {
        name = "handle",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [3] = {
        name = "data",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.BYTES,
      },
    },
  },
  BluetoothGATTWriteRequest = {
    name = "BluetoothGATTWriteRequest",
    options = {
      id = 75,
      source = 2,
      ifdef = "USE_BLUETOOTH_PROXY",
    },
    fields = {
      [1] = {
        name = "address",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT64,
      },
      [2] = {
        name = "handle",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [3] = {
        name = "response",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [4] = {
        name = "data",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.BYTES,
      },
    },
  },
  BluetoothGATTReadDescriptorRequest = {
    name = "BluetoothGATTReadDescriptorRequest",
    options = {
      id = 76,
      source = 2,
      ifdef = "USE_BLUETOOTH_PROXY",
    },
    fields = {
      [1] = {
        name = "address",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT64,
      },
      [2] = {
        name = "handle",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  BluetoothGATTWriteDescriptorRequest = {
    name = "BluetoothGATTWriteDescriptorRequest",
    options = {
      id = 77,
      source = 2,
      ifdef = "USE_BLUETOOTH_PROXY",
    },
    fields = {
      [1] = {
        name = "address",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT64,
      },
      [2] = {
        name = "handle",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [3] = {
        name = "data",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.BYTES,
      },
    },
  },
  BluetoothGATTNotifyRequest = {
    name = "BluetoothGATTNotifyRequest",
    options = {
      id = 78,
      source = 2,
      ifdef = "USE_BLUETOOTH_PROXY",
    },
    fields = {
      [1] = {
        name = "address",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT64,
      },
      [2] = {
        name = "handle",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [3] = {
        name = "enable",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
    },
  },
  BluetoothGATTNotifyDataResponse = {
    name = "BluetoothGATTNotifyDataResponse",
    options = {
      id = 79,
      source = 1,
      ifdef = "USE_BLUETOOTH_PROXY",
    },
    fields = {
      [1] = {
        name = "address",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT64,
      },
      [2] = {
        name = "handle",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [3] = {
        name = "data",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.BYTES,
      },
    },
  },
  SubscribeBluetoothConnectionsFreeRequest = {
    name = "SubscribeBluetoothConnectionsFreeRequest",
    options = {
      id = 80,
      source = 2,
      ifdef = "USE_BLUETOOTH_PROXY",
    },
    fields = {},
  },
  BluetoothConnectionsFreeResponse = {
    name = "BluetoothConnectionsFreeResponse",
    options = {
      id = 81,
      source = 1,
      ifdef = "USE_BLUETOOTH_PROXY",
    },
    fields = {
      [1] = {
        name = "free",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [2] = {
        name = "limit",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [3] = {
        name = "allocated",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT64,
        repeated = true,
      },
    },
  },
  BluetoothGATTErrorResponse = {
    name = "BluetoothGATTErrorResponse",
    options = {
      id = 82,
      source = 1,
      ifdef = "USE_BLUETOOTH_PROXY",
    },
    fields = {
      [1] = {
        name = "address",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT64,
      },
      [2] = {
        name = "handle",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [3] = {
        name = "error",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.INT32,
      },
    },
  },
  BluetoothGATTWriteResponse = {
    name = "BluetoothGATTWriteResponse",
    options = {
      id = 83,
      source = 1,
      ifdef = "USE_BLUETOOTH_PROXY",
    },
    fields = {
      [1] = {
        name = "address",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT64,
      },
      [2] = {
        name = "handle",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  BluetoothGATTNotifyResponse = {
    name = "BluetoothGATTNotifyResponse",
    options = {
      id = 84,
      source = 1,
      ifdef = "USE_BLUETOOTH_PROXY",
    },
    fields = {
      [1] = {
        name = "address",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT64,
      },
      [2] = {
        name = "handle",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  BluetoothDevicePairingResponse = {
    name = "BluetoothDevicePairingResponse",
    options = {
      id = 85,
      source = 1,
      ifdef = "USE_BLUETOOTH_PROXY",
    },
    fields = {
      [1] = {
        name = "address",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT64,
      },
      [2] = {
        name = "paired",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [3] = {
        name = "error",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.INT32,
      },
    },
  },
  BluetoothDeviceUnpairingResponse = {
    name = "BluetoothDeviceUnpairingResponse",
    options = {
      id = 86,
      source = 1,
      ifdef = "USE_BLUETOOTH_PROXY",
    },
    fields = {
      [1] = {
        name = "address",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT64,
      },
      [2] = {
        name = "success",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [3] = {
        name = "error",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.INT32,
      },
    },
  },
  UnsubscribeBluetoothLEAdvertisementsRequest = {
    name = "UnsubscribeBluetoothLEAdvertisementsRequest",
    options = {
      id = 87,
      source = 2,
      ifdef = "USE_BLUETOOTH_PROXY",
    },
    fields = {},
  },
  BluetoothDeviceClearCacheResponse = {
    name = "BluetoothDeviceClearCacheResponse",
    options = {
      id = 88,
      source = 1,
      ifdef = "USE_BLUETOOTH_PROXY",
    },
    fields = {
      [1] = {
        name = "address",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT64,
      },
      [2] = {
        name = "success",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [3] = {
        name = "error",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.INT32,
      },
    },
  },
  BluetoothScannerStateResponse = {
    name = "BluetoothScannerStateResponse",
    options = {
      id = 126,
      source = 1,
      ifdef = "USE_BLUETOOTH_PROXY",
    },
    fields = {
      [1] = {
        name = "state",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- BluetoothScannerState
      },
      [2] = {
        name = "mode",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- BluetoothScannerMode
      },
      [3] = {
        name = "configured_mode",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- BluetoothScannerMode
      },
    },
  },
  BluetoothScannerSetModeRequest = {
    name = "BluetoothScannerSetModeRequest",
    options = {
      id = 127,
      source = 2,
      ifdef = "USE_BLUETOOTH_PROXY",
    },
    fields = {
      [1] = {
        name = "mode",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- BluetoothScannerMode
      },
    },
  },
  SubscribeVoiceAssistantRequest = {
    name = "SubscribeVoiceAssistantRequest",
    options = {
      id = 89,
      source = 2,
      ifdef = "USE_VOICE_ASSISTANT",
    },
    fields = {
      [1] = {
        name = "subscribe",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [2] = {
        name = "flags",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  VoiceAssistantAudioSettings = {
    name = "VoiceAssistantAudioSettings",
    options = {},
    fields = {
      [1] = {
        name = "noise_suppression_level",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [2] = {
        name = "auto_gain",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [3] = {
        name = "volume_multiplier",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
    },
  },
  VoiceAssistantRequest = {
    name = "VoiceAssistantRequest",
    options = {
      id = 90,
      source = 1,
      ifdef = "USE_VOICE_ASSISTANT",
    },
    fields = {
      [1] = {
        name = "start",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [2] = {
        name = "conversation_id",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [3] = {
        name = "flags",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [4] = {
        name = "audio_settings",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.MESSAGE,
      },
      [5] = {
        name = "wake_word_phrase",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
    },
  },
  VoiceAssistantResponse = {
    name = "VoiceAssistantResponse",
    options = {
      id = 91,
      source = 2,
      ifdef = "USE_VOICE_ASSISTANT",
    },
    fields = {
      [1] = {
        name = "port",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [2] = {
        name = "error",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
    },
  },
  VoiceAssistantEventData = {
    name = "VoiceAssistantEventData",
    options = {},
    fields = {
      [1] = {
        name = "name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "value",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
    },
  },
  VoiceAssistantEventResponse = {
    name = "VoiceAssistantEventResponse",
    options = {
      id = 92,
      source = 2,
      ifdef = "USE_VOICE_ASSISTANT",
    },
    fields = {
      [1] = {
        name = "event_type",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- VoiceAssistantEvent
      },
      [2] = {
        name = "data",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.MESSAGE,
        repeated = true,
      },
    },
  },
  VoiceAssistantAudio = {
    name = "VoiceAssistantAudio",
    options = {
      id = 106,
      source = 0,
      ifdef = "USE_VOICE_ASSISTANT",
    },
    fields = {
      [1] = {
        name = "data",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.BYTES,
      },
      [2] = {
        name = "end",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
    },
  },
  VoiceAssistantTimerEventResponse = {
    name = "VoiceAssistantTimerEventResponse",
    options = {
      id = 115,
      source = 2,
      ifdef = "USE_VOICE_ASSISTANT",
    },
    fields = {
      [1] = {
        name = "event_type",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- VoiceAssistantTimerEvent
      },
      [2] = {
        name = "timer_id",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [3] = {
        name = "name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [4] = {
        name = "total_seconds",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [5] = {
        name = "seconds_left",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [6] = {
        name = "is_active",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
    },
  },
  VoiceAssistantAnnounceRequest = {
    name = "VoiceAssistantAnnounceRequest",
    options = {
      id = 119,
      source = 2,
      ifdef = "USE_VOICE_ASSISTANT",
    },
    fields = {
      [1] = {
        name = "media_id",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "text",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [3] = {
        name = "preannounce_media_id",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [4] = {
        name = "start_conversation",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
    },
  },
  VoiceAssistantAnnounceFinished = {
    name = "VoiceAssistantAnnounceFinished",
    options = {
      id = 120,
      source = 1,
      ifdef = "USE_VOICE_ASSISTANT",
    },
    fields = {
      [1] = {
        name = "success",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
    },
  },
  VoiceAssistantWakeWord = {
    name = "VoiceAssistantWakeWord",
    options = {},
    fields = {
      [1] = {
        name = "id",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "wake_word",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [3] = {
        name = "trained_languages",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
        repeated = true,
      },
    },
  },
  VoiceAssistantExternalWakeWord = {
    name = "VoiceAssistantExternalWakeWord",
    options = {},
    fields = {
      [1] = {
        name = "id",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "wake_word",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [3] = {
        name = "trained_languages",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
        repeated = true,
      },
      [4] = {
        name = "model_type",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [5] = {
        name = "model_size",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [6] = {
        name = "model_hash",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [7] = {
        name = "url",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
    },
  },
  VoiceAssistantConfigurationRequest = {
    name = "VoiceAssistantConfigurationRequest",
    options = {
      id = 121,
      source = 2,
      ifdef = "USE_VOICE_ASSISTANT",
    },
    fields = {
      [1] = {
        name = "external_wake_words",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.MESSAGE,
        repeated = true,
      },
    },
  },
  VoiceAssistantConfigurationResponse = {
    name = "VoiceAssistantConfigurationResponse",
    options = {
      id = 122,
      source = 1,
      ifdef = "USE_VOICE_ASSISTANT",
    },
    fields = {
      [1] = {
        name = "available_wake_words",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.MESSAGE,
        repeated = true,
      },
      [2] = {
        name = "active_wake_words",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
        repeated = true,
      },
      [3] = {
        name = "max_active_wake_words",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  VoiceAssistantSetConfiguration = {
    name = "VoiceAssistantSetConfiguration",
    options = {
      id = 123,
      source = 2,
      ifdef = "USE_VOICE_ASSISTANT",
    },
    fields = {
      [1] = {
        name = "active_wake_words",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
        repeated = true,
      },
    },
  },
  ListEntitiesAlarmControlPanelResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "key",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [3] = {
        name = "name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [5] = {
        name = "icon",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [6] = {
        name = "disabled_by_default",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [7] = {
        name = "entity_category",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- EntityCategory
      },
      [8] = {
        name = "supported_features",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [9] = {
        name = "requires_code",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [10] = {
        name = "requires_code_to_arm",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [11] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  AlarmControlPanelStateResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "state",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- AlarmControlPanelState
      },
      [3] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  AlarmControlPanelCommandRequest = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "command",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- AlarmControlPanelStateCommand
      },
      [3] = {
        name = "code",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [4] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  ListEntitiesTextResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "key",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [3] = {
        name = "name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [5] = {
        name = "icon",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [6] = {
        name = "disabled_by_default",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [7] = {
        name = "entity_category",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- EntityCategory
      },
      [8] = {
        name = "min_length",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [9] = {
        name = "max_length",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [10] = {
        name = "pattern",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [11] = {
        name = "mode",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- TextMode
      },
      [12] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  TextStateResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "state",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [3] = {
        name = "missing_state",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [4] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  TextCommandRequest = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "state",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [3] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  ListEntitiesDateResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "key",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [3] = {
        name = "name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [5] = {
        name = "icon",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [6] = {
        name = "disabled_by_default",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [7] = {
        name = "entity_category",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- EntityCategory
      },
      [8] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  DateStateResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "missing_state",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [3] = {
        name = "year",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [4] = {
        name = "month",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [5] = {
        name = "day",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [6] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  DateCommandRequest = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "year",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [3] = {
        name = "month",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [4] = {
        name = "day",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [5] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  ListEntitiesTimeResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "key",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [3] = {
        name = "name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [5] = {
        name = "icon",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [6] = {
        name = "disabled_by_default",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [7] = {
        name = "entity_category",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- EntityCategory
      },
      [8] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  TimeStateResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "missing_state",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [3] = {
        name = "hour",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [4] = {
        name = "minute",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [5] = {
        name = "second",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [6] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  TimeCommandRequest = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "hour",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [3] = {
        name = "minute",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [4] = {
        name = "second",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
      [5] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  ListEntitiesEventResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "key",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [3] = {
        name = "name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [5] = {
        name = "icon",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [6] = {
        name = "disabled_by_default",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [7] = {
        name = "entity_category",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- EntityCategory
      },
      [8] = {
        name = "device_class",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [9] = {
        name = "event_types",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
        repeated = true,
      },
      [10] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  EventResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "event_type",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [3] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  ListEntitiesValveResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "key",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [3] = {
        name = "name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [5] = {
        name = "icon",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [6] = {
        name = "disabled_by_default",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [7] = {
        name = "entity_category",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- EntityCategory
      },
      [8] = {
        name = "device_class",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [9] = {
        name = "assumed_state",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [10] = {
        name = "supports_position",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [11] = {
        name = "supports_stop",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [12] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  ValveStateResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "position",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [3] = {
        name = "current_operation",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- ValveOperation
      },
      [4] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  ValveCommandRequest = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "has_position",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [3] = {
        name = "position",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [4] = {
        name = "stop",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [5] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  ListEntitiesDateTimeResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "key",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [3] = {
        name = "name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [5] = {
        name = "icon",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [6] = {
        name = "disabled_by_default",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [7] = {
        name = "entity_category",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- EntityCategory
      },
      [8] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  DateTimeStateResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "missing_state",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [3] = {
        name = "epoch_seconds",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [4] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  DateTimeCommandRequest = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "epoch_seconds",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [3] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  ListEntitiesUpdateResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [2] = {
        name = "key",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [3] = {
        name = "name",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [5] = {
        name = "icon",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [6] = {
        name = "disabled_by_default",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [7] = {
        name = "entity_category",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- EntityCategory
      },
      [8] = {
        name = "device_class",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [9] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  UpdateStateResponse = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "missing_state",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [3] = {
        name = "in_progress",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [4] = {
        name = "has_progress",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.BOOL,
      },
      [5] = {
        name = "progress",
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FLOAT,
      },
      [6] = {
        name = "current_version",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [7] = {
        name = "latest_version",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [8] = {
        name = "title",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [9] = {
        name = "release_summary",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [10] = {
        name = "release_url",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.STRING,
      },
      [11] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  UpdateCommandRequest = {
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
        wireType = PROTOBUF_SCHEMA.WireType.FIXED32,
        type = PROTOBUF_SCHEMA.DataType.FIXED32,
      },
      [2] = {
        name = "command",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- UpdateCommand
      },
      [3] = {
        name = "device_id",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.UINT32,
      },
    },
  },
  ZWaveProxyFrame = {
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
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.BYTES,
      },
    },
  },
  ZWaveProxyRequest = {
    name = "ZWaveProxyRequest",
    options = {
      id = 129,
      source = 0,
      ifdef = "USE_ZWAVE_PROXY",
    },
    fields = {
      [1] = {
        name = "type",
        wireType = PROTOBUF_SCHEMA.WireType.VARINT,
        type = PROTOBUF_SCHEMA.DataType.ENUM, -- ZWaveProxyRequestType
      },
      [2] = {
        name = "data",
        wireType = PROTOBUF_SCHEMA.WireType.LENGTH_DELIMITED,
        type = PROTOBUF_SCHEMA.DataType.BYTES,
      },
    },
  },
}

PROTOBUF_SCHEMA.RPC = {
  APIConnection = {
    hello = {
      service = "APIConnection",
      method = "hello",
      inputType = PROTOBUF_SCHEMA.Message.HelloRequest,
      outputType = PROTOBUF_SCHEMA.Message.HelloResponse,
    },
    authenticate = {
      service = "APIConnection",
      method = "authenticate",
      inputType = PROTOBUF_SCHEMA.Message.AuthenticationRequest,
      outputType = PROTOBUF_SCHEMA.Message.AuthenticationResponse,
    },
    disconnect = {
      service = "APIConnection",
      method = "disconnect",
      inputType = PROTOBUF_SCHEMA.Message.DisconnectRequest,
      outputType = PROTOBUF_SCHEMA.Message.DisconnectResponse,
    },
    ping = {
      service = "APIConnection",
      method = "ping",
      inputType = PROTOBUF_SCHEMA.Message.PingRequest,
      outputType = PROTOBUF_SCHEMA.Message.PingResponse,
    },
    device_info = {
      service = "APIConnection",
      method = "device_info",
      inputType = PROTOBUF_SCHEMA.Message.DeviceInfoRequest,
      outputType = PROTOBUF_SCHEMA.Message.DeviceInfoResponse,
    },
    list_entities = {
      service = "APIConnection",
      method = "list_entities",
      inputType = PROTOBUF_SCHEMA.Message.ListEntitiesRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    subscribe_states = {
      service = "APIConnection",
      method = "subscribe_states",
      inputType = PROTOBUF_SCHEMA.Message.SubscribeStatesRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    subscribe_logs = {
      service = "APIConnection",
      method = "subscribe_logs",
      inputType = PROTOBUF_SCHEMA.Message.SubscribeLogsRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    subscribe_homeassistant_services = {
      service = "APIConnection",
      method = "subscribe_homeassistant_services",
      inputType = PROTOBUF_SCHEMA.Message.SubscribeHomeassistantServicesRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    subscribe_home_assistant_states = {
      service = "APIConnection",
      method = "subscribe_home_assistant_states",
      inputType = PROTOBUF_SCHEMA.Message.SubscribeHomeAssistantStatesRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    execute_service = {
      service = "APIConnection",
      method = "execute_service",
      inputType = PROTOBUF_SCHEMA.Message.ExecuteServiceRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    noise_encryption_set_key = {
      service = "APIConnection",
      method = "noise_encryption_set_key",
      inputType = PROTOBUF_SCHEMA.Message.NoiseEncryptionSetKeyRequest,
      outputType = PROTOBUF_SCHEMA.Message.NoiseEncryptionSetKeyResponse,
    },
    button_command = {
      service = "APIConnection",
      method = "button_command",
      inputType = PROTOBUF_SCHEMA.Message.ButtonCommandRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    camera_image = {
      service = "APIConnection",
      method = "camera_image",
      inputType = PROTOBUF_SCHEMA.Message.CameraImageRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    climate_command = {
      service = "APIConnection",
      method = "climate_command",
      inputType = PROTOBUF_SCHEMA.Message.ClimateCommandRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    cover_command = {
      service = "APIConnection",
      method = "cover_command",
      inputType = PROTOBUF_SCHEMA.Message.CoverCommandRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    date_command = {
      service = "APIConnection",
      method = "date_command",
      inputType = PROTOBUF_SCHEMA.Message.DateCommandRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    datetime_command = {
      service = "APIConnection",
      method = "datetime_command",
      inputType = PROTOBUF_SCHEMA.Message.DateTimeCommandRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    fan_command = {
      service = "APIConnection",
      method = "fan_command",
      inputType = PROTOBUF_SCHEMA.Message.FanCommandRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    light_command = {
      service = "APIConnection",
      method = "light_command",
      inputType = PROTOBUF_SCHEMA.Message.LightCommandRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    lock_command = {
      service = "APIConnection",
      method = "lock_command",
      inputType = PROTOBUF_SCHEMA.Message.LockCommandRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    media_player_command = {
      service = "APIConnection",
      method = "media_player_command",
      inputType = PROTOBUF_SCHEMA.Message.MediaPlayerCommandRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    number_command = {
      service = "APIConnection",
      method = "number_command",
      inputType = PROTOBUF_SCHEMA.Message.NumberCommandRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    select_command = {
      service = "APIConnection",
      method = "select_command",
      inputType = PROTOBUF_SCHEMA.Message.SelectCommandRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    siren_command = {
      service = "APIConnection",
      method = "siren_command",
      inputType = PROTOBUF_SCHEMA.Message.SirenCommandRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    switch_command = {
      service = "APIConnection",
      method = "switch_command",
      inputType = PROTOBUF_SCHEMA.Message.SwitchCommandRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    text_command = {
      service = "APIConnection",
      method = "text_command",
      inputType = PROTOBUF_SCHEMA.Message.TextCommandRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    time_command = {
      service = "APIConnection",
      method = "time_command",
      inputType = PROTOBUF_SCHEMA.Message.TimeCommandRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    update_command = {
      service = "APIConnection",
      method = "update_command",
      inputType = PROTOBUF_SCHEMA.Message.UpdateCommandRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    valve_command = {
      service = "APIConnection",
      method = "valve_command",
      inputType = PROTOBUF_SCHEMA.Message.ValveCommandRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    subscribe_bluetooth_le_advertisements = {
      service = "APIConnection",
      method = "subscribe_bluetooth_le_advertisements",
      inputType = PROTOBUF_SCHEMA.Message.SubscribeBluetoothLEAdvertisementsRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    bluetooth_device_request = {
      service = "APIConnection",
      method = "bluetooth_device_request",
      inputType = PROTOBUF_SCHEMA.Message.BluetoothDeviceRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    bluetooth_gatt_get_services = {
      service = "APIConnection",
      method = "bluetooth_gatt_get_services",
      inputType = PROTOBUF_SCHEMA.Message.BluetoothGATTGetServicesRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    bluetooth_gatt_read = {
      service = "APIConnection",
      method = "bluetooth_gatt_read",
      inputType = PROTOBUF_SCHEMA.Message.BluetoothGATTReadRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    bluetooth_gatt_write = {
      service = "APIConnection",
      method = "bluetooth_gatt_write",
      inputType = PROTOBUF_SCHEMA.Message.BluetoothGATTWriteRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    bluetooth_gatt_read_descriptor = {
      service = "APIConnection",
      method = "bluetooth_gatt_read_descriptor",
      inputType = PROTOBUF_SCHEMA.Message.BluetoothGATTReadDescriptorRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    bluetooth_gatt_write_descriptor = {
      service = "APIConnection",
      method = "bluetooth_gatt_write_descriptor",
      inputType = PROTOBUF_SCHEMA.Message.BluetoothGATTWriteDescriptorRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    bluetooth_gatt_notify = {
      service = "APIConnection",
      method = "bluetooth_gatt_notify",
      inputType = PROTOBUF_SCHEMA.Message.BluetoothGATTNotifyRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    subscribe_bluetooth_connections_free = {
      service = "APIConnection",
      method = "subscribe_bluetooth_connections_free",
      inputType = PROTOBUF_SCHEMA.Message.SubscribeBluetoothConnectionsFreeRequest,
      outputType = PROTOBUF_SCHEMA.Message.BluetoothConnectionsFreeResponse,
    },
    unsubscribe_bluetooth_le_advertisements = {
      service = "APIConnection",
      method = "unsubscribe_bluetooth_le_advertisements",
      inputType = PROTOBUF_SCHEMA.Message.UnsubscribeBluetoothLEAdvertisementsRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    bluetooth_scanner_set_mode = {
      service = "APIConnection",
      method = "bluetooth_scanner_set_mode",
      inputType = PROTOBUF_SCHEMA.Message.BluetoothScannerSetModeRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    subscribe_voice_assistant = {
      service = "APIConnection",
      method = "subscribe_voice_assistant",
      inputType = PROTOBUF_SCHEMA.Message.SubscribeVoiceAssistantRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    voice_assistant_get_configuration = {
      service = "APIConnection",
      method = "voice_assistant_get_configuration",
      inputType = PROTOBUF_SCHEMA.Message.VoiceAssistantConfigurationRequest,
      outputType = PROTOBUF_SCHEMA.Message.VoiceAssistantConfigurationResponse,
    },
    voice_assistant_set_configuration = {
      service = "APIConnection",
      method = "voice_assistant_set_configuration",
      inputType = PROTOBUF_SCHEMA.Message.VoiceAssistantSetConfiguration,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    alarm_control_panel_command = {
      service = "APIConnection",
      method = "alarm_control_panel_command",
      inputType = PROTOBUF_SCHEMA.Message.AlarmControlPanelCommandRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    zwave_proxy_frame = {
      service = "APIConnection",
      method = "zwave_proxy_frame",
      inputType = PROTOBUF_SCHEMA.Message.ZWaveProxyFrame,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
    zwave_proxy_request = {
      service = "APIConnection",
      method = "zwave_proxy_request",
      inputType = PROTOBUF_SCHEMA.Message.ZWaveProxyRequest,
      outputType = PROTOBUF_SCHEMA.Message.void,
    },
  },
}

return PROTOBUF_SCHEMA

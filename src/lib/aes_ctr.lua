--- AES-128-CTR encryption module for SwitchBot encrypted devices.
--- Based on the AES implementation from noiseprotocol library.

local bit = require("bit")

local aes_ctr = {}

--- AES S-box (substitution box)
--- @type integer[]
local SBOX = {
  0x63,
  0x7c,
  0x77,
  0x7b,
  0xf2,
  0x6b,
  0x6f,
  0xc5,
  0x30,
  0x01,
  0x67,
  0x2b,
  0xfe,
  0xd7,
  0xab,
  0x76,
  0xca,
  0x82,
  0xc9,
  0x7d,
  0xfa,
  0x59,
  0x47,
  0xf0,
  0xad,
  0xd4,
  0xa2,
  0xaf,
  0x9c,
  0xa4,
  0x72,
  0xc0,
  0xb7,
  0xfd,
  0x93,
  0x26,
  0x36,
  0x3f,
  0xf7,
  0xcc,
  0x34,
  0xa5,
  0xe5,
  0xf1,
  0x71,
  0xd8,
  0x31,
  0x15,
  0x04,
  0xc7,
  0x23,
  0xc3,
  0x18,
  0x96,
  0x05,
  0x9a,
  0x07,
  0x12,
  0x80,
  0xe2,
  0xeb,
  0x27,
  0xb2,
  0x75,
  0x09,
  0x83,
  0x2c,
  0x1a,
  0x1b,
  0x6e,
  0x5a,
  0xa0,
  0x52,
  0x3b,
  0xd6,
  0xb3,
  0x29,
  0xe3,
  0x2f,
  0x84,
  0x53,
  0xd1,
  0x00,
  0xed,
  0x20,
  0xfc,
  0xb1,
  0x5b,
  0x6a,
  0xcb,
  0xbe,
  0x39,
  0x4a,
  0x4c,
  0x58,
  0xcf,
  0xd0,
  0xef,
  0xaa,
  0xfb,
  0x43,
  0x4d,
  0x33,
  0x85,
  0x45,
  0xf9,
  0x02,
  0x7f,
  0x50,
  0x3c,
  0x9f,
  0xa8,
  0x51,
  0xa3,
  0x40,
  0x8f,
  0x92,
  0x9d,
  0x38,
  0xf5,
  0xbc,
  0xb6,
  0xda,
  0x21,
  0x10,
  0xff,
  0xf3,
  0xd2,
  0xcd,
  0x0c,
  0x13,
  0xec,
  0x5f,
  0x97,
  0x44,
  0x17,
  0xc4,
  0xa7,
  0x7e,
  0x3d,
  0x64,
  0x5d,
  0x19,
  0x73,
  0x60,
  0x81,
  0x4f,
  0xdc,
  0x22,
  0x2a,
  0x90,
  0x88,
  0x46,
  0xee,
  0xb8,
  0x14,
  0xde,
  0x5e,
  0x0b,
  0xdb,
  0xe0,
  0x32,
  0x3a,
  0x0a,
  0x49,
  0x06,
  0x24,
  0x5c,
  0xc2,
  0xd3,
  0xac,
  0x62,
  0x91,
  0x95,
  0xe4,
  0x79,
  0xe7,
  0xc8,
  0x37,
  0x6d,
  0x8d,
  0xd5,
  0x4e,
  0xa9,
  0x6c,
  0x56,
  0xf4,
  0xea,
  0x65,
  0x7a,
  0xae,
  0x08,
  0xba,
  0x78,
  0x25,
  0x2e,
  0x1c,
  0xa6,
  0xb4,
  0xc6,
  0xe8,
  0xdd,
  0x74,
  0x1f,
  0x4b,
  0xbd,
  0x8b,
  0x8a,
  0x70,
  0x3e,
  0xb5,
  0x66,
  0x48,
  0x03,
  0xf6,
  0x0e,
  0x61,
  0x35,
  0x57,
  0xb9,
  0x86,
  0xc1,
  0x1d,
  0x9e,
  0xe1,
  0xf8,
  0x98,
  0x11,
  0x69,
  0xd9,
  0x8e,
  0x94,
  0x9b,
  0x1e,
  0x87,
  0xe9,
  0xce,
  0x55,
  0x28,
  0xdf,
  0x8c,
  0xa1,
  0x89,
  0x0d,
  0xbf,
  0xe6,
  0x42,
  0x68,
  0x41,
  0x99,
  0x2d,
  0x0f,
  0xb0,
  0x54,
  0xbb,
  0x16,
}

-- Round constants for key expansion
local RCON = {
  0x01,
  0x02,
  0x04,
  0x08,
  0x10,
  0x20,
  0x40,
  0x80,
  0x1b,
  0x36,
}

--- Rotate a 4-byte word left by 1 byte
--- @param word table 4-byte array
--- @return table result Rotated 4-byte array
local function rot_word(word)
  return { word[2], word[3], word[4], word[1] }
end

--- Apply S-box substitution to a 4-byte word
--- @param word table 4-byte array
--- @return table result Substituted 4-byte array
local function sub_word(word)
  return {
    SBOX[word[1] + 1],
    SBOX[word[2] + 1],
    SBOX[word[3] + 1],
    SBOX[word[4] + 1],
  }
end

--- AES key expansion for 128-bit key
--- @param key string 16-byte encryption key
--- @return table expanded_key Expanded key schedule
local function key_expansion(key)
  assert(#key == 16, "Key must be 16 bytes for AES-128")

  local nk = 4 -- Number of 32-bit words in key (4 for AES-128)
  local nr = 10 -- Number of rounds (10 for AES-128)
  local nb = 4 -- Number of columns in state (always 4)

  local w = {}

  -- First Nk words are the original key
  for i = 0, nk - 1 do
    w[i] = {
      string.byte(key, i * 4 + 1),
      string.byte(key, i * 4 + 2),
      string.byte(key, i * 4 + 3),
      string.byte(key, i * 4 + 4),
    }
  end

  -- Generate remaining words
  for i = nk, nb * (nr + 1) - 1 do
    local temp = { w[i - 1][1], w[i - 1][2], w[i - 1][3], w[i - 1][4] }
    if i % nk == 0 then
      temp = sub_word(rot_word(temp))
      temp[1] = bit.bxor(temp[1], RCON[i / nk])
    end
    w[i] = {
      bit.bxor(w[i - nk][1], temp[1]),
      bit.bxor(w[i - nk][2], temp[2]),
      bit.bxor(w[i - nk][3], temp[3]),
      bit.bxor(w[i - nk][4], temp[4]),
    }
  end

  return w, nr
end

--- Add round key to state
--- @param state table 4x4 state matrix (state[row][col])
--- @param w table Expanded key
--- @param round number Current round
local function add_round_key(state, w, round)
  for col = 0, 3 do
    local word = w[round * 4 + col]
    for row = 0, 3 do
      state[row][col] = bit.bxor(state[row][col], word[row + 1])
    end
  end
end

--- SubBytes transformation
--- @param state table 4x4 state matrix
local function sub_bytes(state)
  for i = 0, 3 do
    for j = 0, 3 do
      state[i][j] = SBOX[state[i][j] + 1]
    end
  end
end

--- ShiftRows transformation
--- @param state table 4x4 state matrix (state[row][col])
local function shift_rows(state)
  -- Row 1: shift left by 1
  local temp = state[1][0]
  state[1][0] = state[1][1]
  state[1][1] = state[1][2]
  state[1][2] = state[1][3]
  state[1][3] = temp

  -- Row 2: shift left by 2
  temp = state[2][0]
  state[2][0] = state[2][2]
  state[2][2] = temp
  temp = state[2][1]
  state[2][1] = state[2][3]
  state[2][3] = temp

  -- Row 3: shift left by 3 (same as right by 1)
  temp = state[3][3]
  state[3][3] = state[3][2]
  state[3][2] = state[3][1]
  state[3][1] = state[3][0]
  state[3][0] = temp
end

--- Galois Field multiplication by 2
--- @param a number Byte value
--- @return number result
local function gmul2(a)
  if a < 128 then
    return bit.lshift(a, 1)
  else
    return bit.bxor(bit.lshift(a, 1), 0x11b)
  end
end

--- MixColumns transformation
--- @param state table 4x4 state matrix (state[row][col])
local function mix_columns(state)
  for col = 0, 3 do
    local a = state[0][col]
    local b = state[1][col]
    local c = state[2][col]
    local d = state[3][col]

    state[0][col] = bit.bxor(gmul2(a), gmul2(b), b, c, d)
    state[1][col] = bit.bxor(a, gmul2(b), gmul2(c), c, d)
    state[2][col] = bit.bxor(a, b, gmul2(c), gmul2(d), d)
    state[3][col] = bit.bxor(gmul2(a), a, b, c, gmul2(d))
  end
end

--- AES block encryption
--- @param input string 16-byte plaintext block
--- @param expanded_key table Expanded key
--- @param nr number Number of rounds
--- @return string ciphertext 16-byte encrypted block
local function aes_encrypt_block(input, expanded_key, nr)
  -- Initialize state from input (column-major order)
  local state = {}
  for i = 0, 3 do
    state[i] = {}
    for j = 0, 3 do
      state[i][j] = string.byte(input, j * 4 + i + 1)
    end
  end

  -- Initial round
  add_round_key(state, expanded_key, 0)

  -- Main rounds
  for round = 1, nr - 1 do
    sub_bytes(state)
    shift_rows(state)
    mix_columns(state)
    add_round_key(state, expanded_key, round)
  end

  -- Final round (no MixColumns)
  sub_bytes(state)
  shift_rows(state)
  add_round_key(state, expanded_key, nr)

  -- Convert state to output (column-major order)
  local output = {}
  for j = 0, 3 do
    for i = 0, 3 do
      output[#output + 1] = string.char(state[i][j])
    end
  end

  return table.concat(output)
end

--- Increment a 16-byte counter (big-endian)
--- @param counter string 16-byte counter
--- @return string incremented 16-byte incremented counter
local function increment_counter(counter)
  local bytes = {}
  for i = 1, 16 do
    bytes[i] = string.byte(counter, i)
  end

  -- Increment from least significant byte (last byte)
  for i = 16, 1, -1 do
    bytes[i] = bytes[i] + 1
    if bytes[i] <= 255 then
      break
    end
    bytes[i] = 0
  end

  local result = {}
  for i = 1, 16 do
    result[i] = string.char(bytes[i])
  end
  return table.concat(result)
end

--- AES-128-CTR encryption/decryption (same operation for CTR mode)
--- @param key string 16-byte encryption key
--- @param iv string 16-byte initialization vector (counter)
--- @param data string Data to encrypt/decrypt
--- @return string result Encrypted/decrypted data
function aes_ctr.crypt(key, iv, data)
  assert(#key == 16, "Key must be 16 bytes for AES-128")
  assert(#iv == 16, "IV must be 16 bytes")

  if #data == 0 then
    return ""
  end

  local expanded_key, nr = key_expansion(key)
  local result = {}
  local counter = iv

  -- Process data in 16-byte blocks
  local offset = 1
  while offset <= #data do
    -- Encrypt counter to get keystream block
    local keystream = aes_encrypt_block(counter, expanded_key, nr)

    -- XOR keystream with data
    local block_size = math.min(16, #data - offset + 1)
    for i = 1, block_size do
      local data_byte = string.byte(data, offset + i - 1)
      local key_byte = string.byte(keystream, i)
      result[#result + 1] = string.char(bit.bxor(data_byte, key_byte))
    end

    offset = offset + 16
    counter = increment_counter(counter)
  end

  return table.concat(result)
end

--- Encrypt data using AES-128-CTR (alias for crypt)
--- @param key string 16-byte encryption key
--- @param iv string 16-byte initialization vector
--- @param plaintext string Data to encrypt
--- @return string ciphertext Encrypted data
function aes_ctr.encrypt(key, iv, plaintext)
  return aes_ctr.crypt(key, iv, plaintext)
end

--- Decrypt data using AES-128-CTR (alias for crypt)
--- @param key string 16-byte encryption key
--- @param iv string 16-byte initialization vector
--- @param ciphertext string Data to decrypt
--- @return string plaintext Decrypted data
function aes_ctr.decrypt(key, iv, ciphertext)
  return aes_ctr.crypt(key, iv, ciphertext)
end

--- Convert hex string to binary string
--- @param hex string Hex-encoded string
--- @return string binary Binary string
function aes_ctr.from_hex(hex)
  return (hex:gsub("..", function(cc)
    return string.char(tonumber(cc, 16))
  end))
end

--- Convert binary string to hex string
--- @param binary string Binary string
--- @return string hex Hex-encoded string
function aes_ctr.to_hex(binary)
  return (binary:gsub(".", function(c)
    return string.format("%02x", string.byte(c))
  end))
end

--- NIST SP 800-38A AES-128-CTR Test Vectors
--- @type table[]
local test_vectors = {
  {
    name = "NIST SP 800-38A F.5.1 CTR-AES128.Encrypt Block 1",
    key = "2b7e151628aed2a6abf7158809cf4f3c",
    iv = "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff",
    plaintext = "6bc1bee22e409f96e93d7e117393172a",
    expected = "874d6191b620e3261bef6864990db6ce",
  },
  {
    name = "NIST SP 800-38A F.5.1 CTR-AES128.Encrypt Block 2",
    key = "2b7e151628aed2a6abf7158809cf4f3c",
    iv = "f0f1f2f3f4f5f6f7f8f9fafbfcfdff00",
    plaintext = "ae2d8a571e03ac9c9eb76fac45af8e51",
    expected = "9806f66b7970fdff8617187bb9fffdff",
  },
  {
    name = "NIST SP 800-38A F.5.1 CTR-AES128.Encrypt Block 3",
    key = "2b7e151628aed2a6abf7158809cf4f3c",
    iv = "f0f1f2f3f4f5f6f7f8f9fafbfcfdff01",
    plaintext = "30c81c46a35ce411e5fbc1191a0a52ef",
    expected = "5ae4df3edbd5d35e5b4f09020db03eab",
  },
  {
    name = "NIST SP 800-38A F.5.1 CTR-AES128.Encrypt Block 4",
    key = "2b7e151628aed2a6abf7158809cf4f3c",
    iv = "f0f1f2f3f4f5f6f7f8f9fafbfcfdff02",
    plaintext = "f69f2445df4f9b17ad2b417be66c3710",
    expected = "1e031dda2fbe03d1792170a0f3009cee",
  },
  {
    name = "Short plaintext (5 bytes)",
    key = "2b7e151628aed2a6abf7158809cf4f3c",
    iv = "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff",
    plaintext = "6bc1bee22e",
    expected = "874d6191b6",
  },
  {
    name = "Empty plaintext",
    key = "2b7e151628aed2a6abf7158809cf4f3c",
    iv = "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff",
    plaintext = "",
    expected = "",
  },
}

--- Run comprehensive self-test with NIST SP 800-38A test vectors
--- @return boolean result True if all tests pass, false otherwise
function aes_ctr.selftest()
  print("Running AES-128-CTR test vectors...")
  local passed = 0
  local total = #test_vectors

  for i, test in ipairs(test_vectors) do
    print(string.format("Test %d: %s", i, test.name))

    local key = aes_ctr.from_hex(test.key)
    local iv = aes_ctr.from_hex(test.iv)
    local plaintext = aes_ctr.from_hex(test.plaintext)
    local expected = test.expected

    local result = aes_ctr.crypt(key, iv, plaintext)
    local result_hex = aes_ctr.to_hex(result)

    if result_hex == expected then
      print("  PASS: Encryption")

      -- Test decryption (same operation in CTR mode)
      local decrypted = aes_ctr.crypt(key, iv, result)
      if decrypted == plaintext then
        print("  PASS: Decryption")
        passed = passed + 1
      else
        print("  FAIL: Decryption")
        print("    Expected: " .. test.plaintext)
        print("    Got:      " .. aes_ctr.to_hex(decrypted))
      end
    else
      print("  FAIL: Encryption")
      print("    Expected: " .. expected)
      print("    Got:      " .. result_hex)
    end
  end

  print(string.format("\nAES-128-CTR test vectors result: %d/%d tests passed\n", passed, total))
  return passed == total
end

return aes_ctr

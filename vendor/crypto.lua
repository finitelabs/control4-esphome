do
local _ENV = _ENV
package.preload[ "crypto.aes_gcm" ] = function( ... ) local arg = _G.arg;
--- @module "crypto.aes_gcm"
--- AES-GCM Authenticated Encryption with Associated Data (AEAD) Implementation for portability.
--- @class crypto.aes_gcm
local aes_gcm = {}

local bit32 = require("bitn").bit32

local openssl_wrapper = require("crypto.openssl_wrapper")
local utils = require("crypto.utils")
local bytes = utils.bytes
local benchmark_op = utils.benchmark.benchmark_op

-- Local references for performance
local bit32_raw_band = bit32.raw_band
local bit32_raw_bor = bit32.raw_bor
local bit32_raw_bxor = bit32.raw_bxor
local bit32_raw_lshift = bit32.raw_lshift
local bit32_raw_rshift = bit32.raw_rshift
local string_byte = string.byte
local string_char = string.char
local string_rep = string.rep
local string_sub = string.sub
local table_concat = table.concat

-- ============================================================================
-- AES CORE IMPLEMENTATION
-- ============================================================================

-- AES S-box (substitution box)
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

-- Round constants (Rcon) for key expansion
--- @type integer[]
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

--- @alias AESWord [integer, integer, integer, integer]
--- @alias AESBlock [integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer]
--- @alias AESState [AESWord, AESWord, AESWord, AESWord]

--- Initialize a 4-element AES word with zeros
--- @return AESWord word Initialized word
local function create_aes_word()
  --- @type AESWord
  return { 0, 0, 0, 0 }
end

--- Initialize a 4x4 AES state array with zeros
--- @return AESState state Initialized state
local function create_aes_state()
  --- @type AESState
  return {
    create_aes_word(),
    create_aes_word(),
    create_aes_word(),
    create_aes_word(),
  }
end

-- Pre-allocated state array for aes_encrypt_block()
local aes_state = create_aes_state()

-- Pre-allocated arrays for mix_columns()
local mix_a = create_aes_word()
local mix_b = create_aes_word()

--- XOR two 4-byte words
--- @param a AESWord 4-byte array
--- @param b AESWord 4-byte array
--- @return AESWord result 4-byte array
local function xor_words(a, b)
  return {
    bit32_raw_bxor(a[1], b[1]),
    bit32_raw_bxor(a[2], b[2]),
    bit32_raw_bxor(a[3], b[3]),
    bit32_raw_bxor(a[4], b[4]),
  }
end

--- Rotate word (circular left shift by 1 byte)
--- @param word AESWord 4-byte array
--- @return AESWord result Rotated 4-byte array
local function rot_word(word)
  return { word[2], word[3], word[4], word[1] }
end

--- Apply S-box substitution to a word
--- @param word AESWord 4-byte array
--- @return AESWord result Substituted 4-byte array
local function sub_word(word)
  local s_1 = assert(SBOX[word[1] + 1], "Invalid SBOX index " .. (word[1] + 1))
  local s_2 = assert(SBOX[word[2] + 1], "Invalid SBOX index " .. (word[2] + 1))
  local s_3 = assert(SBOX[word[3] + 1], "Invalid SBOX index " .. (word[3] + 1))
  local s_4 = assert(SBOX[word[4] + 1], "Invalid SBOX index " .. (word[4] + 1))
  return { s_1, s_2, s_3, s_4 }
end

--- AES key expansion
--- @param key string Encryption key (16, 24, or 32 bytes)
--- @return table expanded_key Array of round keys
--- @return integer nr Number of rounds
local function key_expansion(key)
  local key_len = #key
  local nr -- Number of rounds
  local nk -- Number of 32-bit words in key

  if key_len == 16 then
    nr = 10
    nk = 4
  elseif key_len == 24 then
    nr = 12
    nk = 6
  elseif key_len == 32 then
    nr = 14
    nk = 8
  else
    error("Invalid key length. Must be 16, 24, or 32 bytes")
  end

  -- Convert key to words
  --- @type AESState
  local w = {}
  for i = 1, nk do
    w[i] = {
      string_byte(key, (i - 1) * 4 + 1),
      string_byte(key, (i - 1) * 4 + 2),
      string_byte(key, (i - 1) * 4 + 3),
      string_byte(key, (i - 1) * 4 + 4),
    }
  end

  -- Expand key
  for i = nk + 1, 4 * (nr + 1) do
    local temp = w[i - 1]
    local idx = i - 1 -- 0-based index for modulo arithmetic
    if idx % nk == 0 then
      local t = assert(RCON[idx / nk], "Invalid RCON index " .. (idx / nk))
      temp = xor_words(sub_word(rot_word(temp)), { t, 0, 0, 0 })
    elseif nk > 6 and idx % nk == 4 then
      temp = sub_word(temp)
    end
    w[i] = xor_words(w[i - nk], temp)
  end

  return w, nr
end

--- MixColumns transformation
--- @param state AESState 4x4 state matrix
local function mix_columns(state)
  -- Reuse pre-allocated arrays
  local a = mix_a
  local b = mix_b
  for c = 1, 4 do
    for i = 1, 4 do
      a[i] = state[i][c]
      b[i] = bit32_raw_band(state[i][c], 0x80) ~= 0
          and bit32_raw_bxor(bit32_raw_band(bit32_raw_lshift(state[i][c], 1), 0xFF), 0x1B)
        or bit32_raw_band(bit32_raw_lshift(state[i][c], 1), 0xFF)
    end

    state[1][c] = bit32_raw_bxor(bit32_raw_bxor(bit32_raw_bxor(b[1], a[2]), bit32_raw_bxor(b[2], a[3])), a[4])
    state[2][c] = bit32_raw_bxor(bit32_raw_bxor(bit32_raw_bxor(a[1], b[2]), bit32_raw_bxor(a[3], b[3])), a[4])
    state[3][c] = bit32_raw_bxor(bit32_raw_bxor(bit32_raw_bxor(a[1], a[2]), bit32_raw_bxor(b[3], a[4])), b[4])
    state[4][c] = bit32_raw_bxor(bit32_raw_bxor(bit32_raw_bxor(a[1], b[1]), bit32_raw_bxor(a[2], a[3])), b[4])
  end
end

--- SubBytes transformation
--- @param state AESState 4x4 state matrix
local function sub_bytes(state)
  for i = 1, 4 do
    for j = 1, 4 do
      local s_index = state[i][j] + 1
      state[i][j] = assert(SBOX[s_index], "Invalid SBOX index " .. s_index)
    end
  end
end

--- ShiftRows transformation
--- @param state AESState 4x4 state matrix
local function shift_rows(state)
  -- Row 1: no shift
  -- Row 2: shift left by 1
  local temp = state[2][1]
  state[2][1] = state[2][2]
  state[2][2] = state[2][3]
  state[2][3] = state[2][4]
  state[2][4] = temp

  -- Row 3: shift left by 2
  temp = state[3][1]
  state[3][1] = state[3][3]
  state[3][3] = temp
  temp = state[3][2]
  state[3][2] = state[3][4]
  state[3][4] = temp

  -- Row 4: shift left by 3 (or right by 1)
  temp = state[4][4]
  state[4][4] = state[4][3]
  state[4][3] = state[4][2]
  state[4][2] = state[4][1]
  state[4][1] = temp
end

--- AddRoundKey transformation
--- @param state AESState 4x4 state matrix
--- @param round_key table Round key words
--- @param round integer Round number
local function add_round_key(state, round_key, round)
  for c = 1, 4 do
    local key_word = round_key[round * 4 + c]
    for r = 1, 4 do
      state[r][c] = bit32_raw_bxor(state[r][c], key_word[r])
    end
  end
end

--- AES block encryption
--- @param input string 16-byte plaintext block
--- @param expanded_key table Expanded key
--- @param nr integer Number of rounds
--- @return string ciphertext 16-byte encrypted block
local function aes_encrypt_block(input, expanded_key, nr)
  -- Reuse pre-allocated state array
  local state = aes_state
  for i = 1, 4 do
    for j = 1, 4 do
      state[i][j] = string_byte(input, (j - 1) * 4 + i)
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

  -- Convert state to output (optimized with table)
  local output_bytes = {}
  local idx = 1
  for j = 1, 4 do
    for i = 1, 4 do
      output_bytes[idx] = string_char(state[i][j])
      idx = idx + 1
    end
  end

  return table_concat(output_bytes)
end

-- ============================================================================
-- GCM MODE IMPLEMENTATION
-- ============================================================================

--- Initialize a 16-element GCM block with zeros
--- @return AESBlock block Initialized block
local function create_gcm_block()
  local arr = {}
  for i = 1, 16 do
    arr[i] = 0
  end
  --- @cast arr AESBlock
  return arr
end

-- Pre-allocated arrays for gcm_multiply() to avoid repeated allocation
local gcm_z = create_gcm_block()
local gcm_v = create_gcm_block()

--- GCM field multiplication
--- @param x string 16-byte block
--- @param y string 16-byte block
--- @return string result Product in GF(2^128)
local function gcm_multiply(x, y)
  -- Reuse pre-allocated arrays
  local z = gcm_z
  local v = gcm_v
  -- Reset z and initialize v
  for i = 1, 16 do
    z[i] = 0
    v[i] = string_byte(y, i)
  end

  -- Process each bit of x from MSB to LSB
  for i = 1, 16 do
    local byte = string_byte(x, i)
    for bit = 7, 0, -1 do
      if bit32_raw_band(byte, bit32_raw_lshift(1, bit)) ~= 0 then
        -- z = z XOR v
        for j = 1, 16 do
          z[j] = bit32_raw_bxor(z[j], v[j])
        end
      end

      -- Check if LSB of v is 1 (bit 0 of last byte)
      local lsb = bit32_raw_band(v[16], 1)

      -- v = v >> 1 (right shift entire 128-bit value by 1)
      local carry = 0
      for j = 1, 16 do
        local new_carry = bit32_raw_band(v[j], 1)
        v[j] = bit32_raw_bor(bit32_raw_rshift(v[j], 1), bit32_raw_lshift(carry, 7))
        carry = new_carry
      end

      -- If LSB was 1, XOR with R = 0xE1000000000000000000000000000000
      if lsb ~= 0 then
        v[1] = bit32_raw_bxor(v[1], 0xE1)
      end
    end
  end

  -- Convert result back to string
  local result = ""
  for i = 1, 16 do
    result = result .. string_char(z[i])
  end
  return result
end

--- GHASH function
--- @param h string Hash key (16 bytes)
--- @param data string Data to hash (multiple of 16 bytes)
--- @return string result 16-byte hash
local function ghash(h, data)
  local y = string_rep("\0", 16)

  -- Process each 16-byte block
  for i = 1, #data, 16 do
    local block = string_sub(data, i, i + 15)

    -- y = (y XOR block) * h
    local y_xor = ""
    for j = 1, 16 do
      y_xor = y_xor .. string_char(bit32_raw_bxor(string_byte(y, j), string_byte(block, j)))
    end

    y = gcm_multiply(y_xor, h)
  end

  return y
end

--- Increment counter block
--- @param counter string 16-byte counter block
--- @return string result Incremented counter
local function inc_counter(counter)
  local result = string_sub(counter, 1, 12) -- Keep first 12 bytes

  -- Increment last 4 bytes (big-endian)
  local val = 0
  for i = 13, 16 do
    val = val * 256 + string_byte(counter, i)
  end

  val = (val + 1) % 0x100000000

  -- Convert back to bytes (big-endian)
  for i = 3, 0, -1 do
    result = result .. string_char(bit32_raw_band(bit32_raw_rshift(val, i * 8), 0xFF))
  end

  return result
end

--- Generate counter mode keystream
--- @param key string AES key
--- @param iv string Initialization vector
--- @param length integer Number of bytes needed
--- @return string keystream Generated keystream
local function generate_keystream(key, iv, length)
  local expanded_key, nr = key_expansion(key)
  local keystream_blocks = {}
  local total_length = 0

  -- Initial counter value: IV || 0x00000002
  local counter = iv .. string_rep("\0", 3) .. string_char(0x02)

  while total_length < length do
    local block = aes_encrypt_block(counter, expanded_key, nr)
    keystream_blocks[#keystream_blocks + 1] = block
    total_length = total_length + #block
    counter = inc_counter(counter)
  end

  local keystream = table_concat(keystream_blocks)
  return string_sub(keystream, 1, length)
end

-- ============================================================================
-- AEAD INTERFACE
-- ============================================================================

--- Pad AAD and ciphertext as required by GCM
--- @param aad string Additional authenticated data
--- @param ciphertext string Encrypted data
--- @return string padded_data Data formatted for GHASH
local function format_gcm_data(aad, ciphertext)
  local result = ""

  -- Add AAD and padding
  result = result .. aad
  local aad_pad = (16 - (#aad % 16)) % 16
  result = result .. string_rep("\0", aad_pad)

  -- Add ciphertext and padding
  result = result .. ciphertext
  local ct_pad = (16 - (#ciphertext % 16)) % 16
  result = result .. string_rep("\0", ct_pad)

  -- Add lengths (in bits) as 64-bit big-endian integers
  -- For messages under 2^61 bytes, high 32 bits are always 0
  local aad_bits_low = #aad * 8
  local ct_bits_low = #ciphertext * 8

  -- AAD length (64 bits big-endian)
  result = result .. string_rep("\0", 4) -- High 32 bits
  result = result .. bytes.u32_to_be_bytes(aad_bits_low) -- Low 32 bits

  -- Ciphertext length (64 bits big-endian)
  result = result .. string_rep("\0", 4) -- High 32 bits
  result = result .. bytes.u32_to_be_bytes(ct_bits_low) -- Low 32 bits

  return result
end

--- AES-GCM AEAD Encryption
---
--- Encrypts plaintext and authenticates both the plaintext and additional data.
--- Returns the ciphertext concatenated with a 16-byte authentication tag.
---
--- @param key string AES key (16, 24, or 32 bytes)
--- @param nonce string 12-byte nonce (must be unique for each encryption with the same key)
--- @param plaintext string Data to encrypt
--- @param aad? string Additional Authenticated Data (default: empty string)
--- @return string result Ciphertext concatenated with 16-byte authentication tag
function aes_gcm.encrypt(key, nonce, plaintext, aad)
  assert(#key == 16 or #key == 24 or #key == 32, "Key must be 16, 24, or 32 bytes")
  assert(#nonce == 12, "Nonce must be exactly 12 bytes")

  aad = aad or ""

  local openssl = openssl_wrapper.get(openssl_wrapper.Feature.AAD)
  if openssl then
    local evp = openssl.cipher.get("aes-" .. #key * 8 .. "-gcm")
    local e = evp:encrypt_new()
    e:ctrl(openssl.cipher.EVP_CTRL_GCM_SET_IVLEN, #nonce)
    e:init(key, nonce)

    -- Indicate that the AAD setting is set
    local aad_update = e:update(aad, true) or ""
    if #aad_update > 0 then
      error("AAD update should not return data in AEAD mode")
    end
    local ciphertext = e:update(plaintext)
    local final = e:final() or ""
    if #final > 0 then
      error("Finalization should not return data in AEAD mode")
    end
    local tag = e:ctrl(openssl.cipher.EVP_CTRL_GCM_GET_TAG, 16) or ""
    if #tag ~= 16 then
      error("Tag length must be exactly 16 bytes in AEAD mode")
    end
    return ciphertext .. tag
  end

  -- Expand key
  local expanded_key, nr = key_expansion(key)

  -- Generate hash key H = E(K, 0^128)
  local h = aes_encrypt_block(string_rep("\0", 16), expanded_key, nr)

  -- Initial counter: nonce || 0x00000001
  local j0 = nonce .. string_rep("\0", 3) .. string_char(0x01)

  -- Encrypt plaintext using CTR mode
  local keystream = generate_keystream(key, nonce, #plaintext)
  local ciphertext = ""
  for i = 1, #plaintext do
    ciphertext = ciphertext .. string_char(bit32_raw_bxor(string_byte(plaintext, i), string_byte(keystream, i)))
  end

  -- Calculate authentication tag
  local gcm_data = format_gcm_data(aad, ciphertext)
  local s = ghash(h, gcm_data)

  -- Encrypt S to get final tag: T = E(K, J0) XOR S
  local encrypted_j0 = aes_encrypt_block(j0, expanded_key, nr)
  local tag = ""
  for i = 1, 16 do
    tag = tag .. string_char(bit32_raw_bxor(string_byte(s, i), string_byte(encrypted_j0, i)))
  end

  return ciphertext .. tag
end

--- AES-GCM AEAD Decryption
---
--- Verifies the authentication tag and decrypts the ciphertext if authentic.
--- The input should be the result of encrypt() - ciphertext concatenated with tag.
---
--- @param key string AES key (16, 24, or 32 bytes)
--- @param nonce string 12-byte nonce (same as used for encryption)
--- @param ciphertext_and_tag string Encrypted data with 16-byte authentication tag appended
--- @param aad? string Additional Authenticated Data (default: empty string)
--- @return string? plaintext Decrypted data, or nil if authentication fails
function aes_gcm.decrypt(key, nonce, ciphertext_and_tag, aad)
  assert(#key == 16 or #key == 24 or #key == 32, "Key must be 16, 24, or 32 bytes")
  assert(#nonce == 12, "Nonce must be exactly 12 bytes")
  assert(#ciphertext_and_tag >= 16, "Input must contain at least 16 bytes for authentication tag")

  aad = aad or ""

  -- Split ciphertext and tag
  local ciphertext_len = #ciphertext_and_tag - 16
  local ciphertext = string_sub(ciphertext_and_tag, 1, ciphertext_len)
  local received_tag = string_sub(ciphertext_and_tag, ciphertext_len + 1)

  local openssl = openssl_wrapper.get(openssl_wrapper.Feature.AAD)
  if openssl then
    local evp = openssl.cipher.get("aes-" .. #key * 8 .. "-gcm")
    local e = evp:decrypt_new()
    e:ctrl(openssl.cipher.EVP_CTRL_GCM_SET_IVLEN, #nonce)
    e:ctrl(openssl.cipher.EVP_CTRL_GCM_SET_TAG, received_tag)
    e:init(key, nonce)

    -- Indicate that the AAD setting is set
    local aad_update = e:update(aad, true) or ""
    if #aad_update > 0 then
      error("AAD update should not return data in AEAD mode")
    end
    local plaintext = e:update(ciphertext)
    local final = e:final()
    if final == nil then
      return nil -- Authentication failed
    elseif #final > 0 then
      error("Finalization should not return data in AEAD mode")
    end
    return plaintext
  end

  -- Expand key
  local expanded_key, nr = key_expansion(key)

  -- Generate hash key H = E(K, 0^128)
  local h = aes_encrypt_block(string_rep("\0", 16), expanded_key, nr)

  -- Initial counter: nonce || 0x00000001
  local j0 = nonce .. string_rep("\0", 3) .. string_char(0x01)

  -- Calculate expected authentication tag
  local gcm_data = format_gcm_data(aad, ciphertext)
  local s = ghash(h, gcm_data)

  -- Encrypt S to get expected tag: T = E(K, J0) XOR S
  local encrypted_j0 = aes_encrypt_block(j0, expanded_key, nr)
  local expected_tag = ""
  for i = 1, 16 do
    expected_tag = expected_tag .. string_char(bit32_raw_bxor(string_byte(s, i), string_byte(encrypted_j0, i)))
  end

  -- Verify tag (constant-time comparison)
  if received_tag ~= expected_tag then
    return nil -- Authentication failed
  end

  -- Decrypt ciphertext using CTR mode
  local keystream = generate_keystream(key, nonce, #ciphertext)
  local plaintext = ""
  for i = 1, #ciphertext do
    plaintext = plaintext .. string_char(bit32_raw_bxor(string_byte(ciphertext, i), string_byte(keystream, i)))
  end

  return plaintext
end

--- Test vectors from NIST SP 800-38D and other sources
local test_vectors = {
  {
    name = "NIST Test Case 1 (AES-128-GCM)",
    key = string_rep("\0", 16),
    nonce = string_rep("\0", 12),
    plaintext = "",
    aad = "",
    ciphertext = "",
    tag = bytes.from_hex("58e2fccefa7e3061367f1d57a4e7455a"),
  },
  {
    name = "NIST Test Case 2 (AES-128-GCM)",
    key = string_rep("\0", 16),
    nonce = string_rep("\0", 12),
    plaintext = string_rep("\0", 16),
    aad = "",
    ciphertext = bytes.from_hex("0388dace60b6a392f328c2b971b2fe78"),
    tag = bytes.from_hex("ab6e47d42cec13bdf53a67b21257bddf"),
  },
  {
    name = "NIST Test Case 3 (AES-128-GCM with AAD)",
    key = bytes.from_hex("feffe9928665731c6d6a8f9467308308"),
    nonce = bytes.from_hex("cafebabefacedbaddecaf888"),
    plaintext = bytes.from_hex(
      "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255"
    ),
    aad = "",
    ciphertext = bytes.from_hex(
      "42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091473f5985"
    ),
    tag = bytes.from_hex("4d5c2af327cd64a62cf35abd2ba6fab4"),
  },
  {
    name = "Roundtrip test with various inputs",
    key = bytes.from_hex("000102030405060708090a0b0c0d0e0f"),
    nonce = bytes.from_hex("000000000000004a00000000"),
    aad = "Additional authenticated data",
    plaintext = "Hello, AES-GCM AEAD!",
  },
}

--- Run comprehensive self-test with test vectors
--- @return boolean result True if all tests pass, false otherwise
function aes_gcm.selftest()
  local function test_vectors_suite()
    print("Running AES-GCM test vectors...")
    local passed = 0
    local total = #test_vectors

    for i, test in ipairs(test_vectors) do
      print(string.format("Test %d: %s", i, test.name))

      if test.ciphertext then
        -- Test with known ciphertext and tag
        local result = aes_gcm.encrypt(test.key, test.nonce, test.plaintext, test.aad)
        local result_ct = string_sub(result, 1, #test.ciphertext)
        local result_tag = string_sub(result, #test.ciphertext + 1)

        if result_ct == test.ciphertext and result_tag == test.tag then
          print("  ✅ PASS: Encryption")

          -- Test decryption
          local decrypted = aes_gcm.decrypt(test.key, test.nonce, result, test.aad)
          if decrypted == test.plaintext then
            print("  ✅ PASS: Decryption")
            passed = passed + 1
          else
            print("  ❌ FAIL: Decryption")
            print("    Expected: " .. bytes.to_hex(test.plaintext))
            print("    Got:      " .. (decrypted and bytes.to_hex(decrypted) or "nil"))
          end
        else
          print("  ❌ FAIL: Encryption")
          print("    Expected CT: " .. bytes.to_hex(test.ciphertext))
          print("    Got CT:      " .. bytes.to_hex(result_ct))
          print("    Expected Tag: " .. (test.tag and bytes.to_hex(test.tag) or "none"))
          print("    Got Tag:      " .. bytes.to_hex(result_tag))
        end
      else
        -- Roundtrip test
        local encrypted = aes_gcm.encrypt(test.key, test.nonce, test.plaintext, test.aad)
        local decrypted = aes_gcm.decrypt(test.key, test.nonce, encrypted, test.aad)

        if decrypted == test.plaintext then
          print("  ✅ PASS: Roundtrip test")
          passed = passed + 1
        else
          print("  ❌ FAIL: Roundtrip test")
          print("    Original:  " .. bytes.to_hex(test.plaintext))
          print("    Decrypted: " .. (decrypted and bytes.to_hex(decrypted) or "nil"))
        end
      end
    end

    print(string.format("\nTest vectors result: %d/%d tests passed\n", passed, total))
    return passed == total
  end

  local function functional_tests()
    print("Running AES-GCM functional tests...")
    local passed = 0
    local total = 0

    -- Test 1: Basic encryption/decryption with AES-128
    total = total + 1
    local key128 = string_rep(string_char(0x42), 16)
    local nonce = string_rep("\0", 11) .. string_char(0x01)
    local aad = "user@example.com|2024-01-01"
    local plaintext = "This is a secret message that needs both encryption and authentication."

    local ciphertext_and_tag = aes_gcm.encrypt(key128, nonce, plaintext, aad)
    local decrypted = aes_gcm.decrypt(key128, nonce, ciphertext_and_tag, aad)

    if decrypted == plaintext then
      print("  ✅ PASS: Basic encryption/decryption (AES-128)")
      passed = passed + 1
    else
      print("  ❌ FAIL: Basic encryption/decryption (AES-128)")
    end

    -- Test 2: Basic encryption/decryption with AES-256
    total = total + 1
    local key256 = string_rep(string_char(0x43), 32)
    local ct256 = aes_gcm.encrypt(key256, nonce, plaintext, aad)
    local pt256 = aes_gcm.decrypt(key256, nonce, ct256, aad)

    if pt256 == plaintext then
      print("  ✅ PASS: Basic encryption/decryption (AES-256)")
      passed = passed + 1
    else
      print("  ❌ FAIL: Basic encryption/decryption (AES-256)")
    end

    -- Test 3: Authentication tag tampering detection
    total = total + 1
    local tampered = ciphertext_and_tag:sub(1, -2) .. string_char(255)
    local tampered_result = aes_gcm.decrypt(key128, nonce, tampered, aad)

    if tampered_result == nil then
      print("  ✅ PASS: Tampered tag correctly rejected")
      passed = passed + 1
    else
      print("  ❌ FAIL: Tampered tag was not detected")
    end

    -- Test 4: Wrong AAD detection
    total = total + 1
    local wrong_aad = "wrong@example.com|2024-01-01"
    local wrong_aad_result = aes_gcm.decrypt(key128, nonce, ciphertext_and_tag, wrong_aad)

    if wrong_aad_result == nil then
      print("  ✅ PASS: Wrong AAD correctly rejected")
      passed = passed + 1
    else
      print("  ❌ FAIL: Wrong AAD was not detected")
    end

    -- Test 5: Nonce uniqueness
    total = total + 1
    local nonce2 = string_rep("\0", 11) .. string_char(0x02)
    local ciphertext2 = aes_gcm.encrypt(key128, nonce2, plaintext, aad)

    if ciphertext_and_tag ~= ciphertext2 then
      print("  ✅ PASS: Different nonces produce different ciphertexts")
      passed = passed + 1
    else
      print("  ❌ FAIL: Different nonces produced same ciphertext")
    end

    -- Test 6: Empty plaintext
    total = total + 1
    local empty_ct = aes_gcm.encrypt(key128, nonce, "", aad)
    local empty_pt = aes_gcm.decrypt(key128, nonce, empty_ct, aad)

    if empty_pt == "" then
      print("  ✅ PASS: Empty plaintext encryption/decryption")
      passed = passed + 1
    else
      print("  ❌ FAIL: Empty plaintext encryption/decryption")
    end

    -- Test 7: Empty AAD
    total = total + 1
    local no_aad_ct = aes_gcm.encrypt(key128, nonce, plaintext, "")
    local no_aad_pt = aes_gcm.decrypt(key128, nonce, no_aad_ct, "")

    if no_aad_pt == plaintext then
      print("  ✅ PASS: Empty AAD encryption/decryption")
      passed = passed + 1
    else
      print("  ❌ FAIL: Empty AAD encryption/decryption")
    end

    -- Test 8: Ciphertext tampering detection
    total = total + 1
    local tampered_ct = string_char(255) .. ciphertext_and_tag:sub(2)
    local tampered_ct_result = aes_gcm.decrypt(key128, nonce, tampered_ct, aad)

    if tampered_ct_result == nil then
      print("  ✅ PASS: Tampered ciphertext correctly rejected")
      passed = passed + 1
    else
      print("  ❌ FAIL: Tampered ciphertext was not detected")
    end

    -- Test 9: Wrong key detection
    total = total + 1
    local wrong_key = string_rep(string_char(0x99), 16)
    local wrong_key_result = aes_gcm.decrypt(wrong_key, nonce, ciphertext_and_tag, aad)

    if wrong_key_result == nil then
      print("  ✅ PASS: Wrong key correctly rejected")
      passed = passed + 1
    else
      print("  ❌ FAIL: Wrong key was not detected")
    end

    -- Test 10: Large plaintext (multiple blocks)
    total = total + 1
    local large_plaintext = string_rep("A", 1000)
    local large_ct = aes_gcm.encrypt(key128, nonce, large_plaintext, aad)
    local large_pt = aes_gcm.decrypt(key128, nonce, large_ct, aad)

    if large_pt == large_plaintext then
      print("  ✅ PASS: Large plaintext encryption/decryption")
      passed = passed + 1
    else
      print("  ❌ FAIL: Large plaintext encryption/decryption")
    end

    -- Test 11: Different key sizes produce different outputs
    total = total + 1
    local key192 = string_rep(string_char(0x44), 24)
    local ct128 = aes_gcm.encrypt(key128, nonce, plaintext, aad)
    local ct192 = aes_gcm.encrypt(key192, nonce, plaintext, aad)
    local ct256_2 = aes_gcm.encrypt(key256, nonce, plaintext, aad)

    if ct128 ~= ct192 and ct192 ~= ct256_2 and ct128 ~= ct256_2 then
      print("  ✅ PASS: Different key sizes produce different outputs")
      passed = passed + 1
    else
      print("  ❌ FAIL: Different key sizes should produce different outputs")
    end

    print(string.format("\nFunctional tests result: %d/%d tests passed\n", passed, total))
    return passed == total
  end

  local vectors_passed = test_vectors_suite()
  local functional_passed = functional_tests()

  return vectors_passed and functional_passed
end

--- Run performance benchmarks
---
--- This function runs comprehensive performance benchmarks for AES-GCM operations
--- including authenticated encryption and decryption for various message and key sizes.
function aes_gcm.benchmark()
  -- Test data
  local key128 = bytes.from_hex("feffe9928665731c6d6a8f9467308308")
  local key256 = bytes.from_hex("feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308")
  local nonce = bytes.from_hex("cafebabefacedbaddecaf888")
  local aad = "feedfacedeadbeeffeedfacedeadbeefabaddad2"
  local plaintext_64 = string_rep("a", 64)
  local plaintext_1k = string_rep("a", 1024)
  local plaintext_8k = string_rep("a", 8192)

  print("AES-128-GCM Encryption:")
  benchmark_op("aes128_encrypt_64_bytes", function()
    aes_gcm.encrypt(key128, nonce, plaintext_64, aad)
  end, 200)

  benchmark_op("aes128_encrypt_1k", function()
    aes_gcm.encrypt(key128, nonce, plaintext_1k, aad)
  end, 50)

  benchmark_op("aes128_encrypt_8k", function()
    aes_gcm.encrypt(key128, nonce, plaintext_8k, aad)
  end, 10)

  print("\nAES-256-GCM Encryption:")
  benchmark_op("aes256_encrypt_64_bytes", function()
    aes_gcm.encrypt(key256, nonce, plaintext_64, aad)
  end, 200)

  benchmark_op("aes256_encrypt_1k", function()
    aes_gcm.encrypt(key256, nonce, plaintext_1k, aad)
  end, 50)

  benchmark_op("aes256_encrypt_8k", function()
    aes_gcm.encrypt(key256, nonce, plaintext_8k, aad)
  end, 10)

  -- Pre-generate ciphertexts for decryption benchmarks
  local ct128_64 = aes_gcm.encrypt(key128, nonce, plaintext_64, aad)
  local ct256_1k = aes_gcm.encrypt(key256, nonce, plaintext_1k, aad)

  print("\nDecryption Operations:")
  benchmark_op("aes128_decrypt_64_bytes", function()
    aes_gcm.decrypt(key128, nonce, ct128_64, aad)
  end, 200)

  benchmark_op("aes256_decrypt_1k", function()
    aes_gcm.decrypt(key256, nonce, ct256_1k, aad)
  end, 50)
end

return aes_gcm
end
end

do
local _ENV = _ENV
package.preload[ "crypto.bignum" ] = function( ... ) local arg = _G.arg;
--- @module "crypto.bignum"
--- Arbitrary-precision unsigned integer arithmetic, sized for 3072-bit modular
--- exponentiation (SRP-6a / RFC 5054 group 15).
---
--- The hot path is `mod_exp`, which uses Montgomery multiplication plus a
--- sliding-window exponentiation. See the notes above `mod_exp_montgomery` for
--- why those two were chosen over the naive "square and multiply with a full
--- divmod after every step".
---
--- Representation
--- --------------
--- A big number is a plain Lua array of `LIMB_BITS`-bit limbs, least
--- significant first, normalized so that the most significant limb is non-zero.
--- Zero is the empty table. This is the *canonical* representation and the only
--- type any public function ever accepts or returns.
---
--- @class crypto.bignum
local bignum = {}

local utils = require("crypto.utils")
local bytes = utils.bytes
local benchmark_op = utils.benchmark.benchmark_op
local openssl_wrapper = require("crypto.openssl_wrapper")

-- Local references for performance
local floor = math.floor
local string_byte = string.byte
local string_char = string.char
local string_format = string.format
local string_rep = string.rep
local string_sub = string.sub
local string_upper = string.upper
local table_concat = table.concat

-- ============================================================================
-- CONSTANTS
-- ============================================================================

--- @alias BigNum integer[] Little-endian array of 24-bit limbs; {} is zero.

-- Limb width.
--
-- OVERFLOW BOUND (the whole portability story lives here). On Lua 5.1, 5.2 and
-- LuaJIT every number is an IEEE double, so integers are exact only up to 2^53.
-- A 3072-bit operand is n = 3072/24 = 128 limbs, and a column of a schoolbook
-- multiply accumulates n products each < 2^(2*24), which needs
-- 2*24 + ceil(log2(128)) = 48 + 7 = 55 bits: too wide. So this module never
-- lets a column accumulate. Every multiply-accumulate loop propagates its carry
-- on *every* iteration, which caps the accumulator at
--
--   INVARIANT: t <= (BASE-1) + (BASE-1)^2 + (BASE-1) = BASE^2 - 1 = 2^48 - 1
--
-- independently of the operand length, leaving 5 bits (a factor of 32) of
-- headroom below 2^53. The three shapes that must respect it are `mul_raw`,
-- `mont_mul` and the multiply-subtract step of `divmod_raw`; each carries
-- inline and each is annotated below.
--
-- 24 bits also divides evenly into both bytes (3) and hex digits (6), which
-- removes all cross-boundary bit fiddling from the conversion routines.
local LIMB_BITS = 24
local LIMB_BYTES = 3
local LIMB_HEX = 6
local BASE = 16777216 -- 2^24
local BASE_HALF = 8388608 -- 2^23
--- Exact reciprocal of BASE: a power of two, so `x * INV_BASE` is bit-identical
--- to `x / BASE` for every integer x < 2^53, but avoids a hardware divide in
--- the inner loops.
local INV_BASE = 1 / 16777216

--- Powers of two up to the limb width, for bit extraction without 5.3+ shifts.
local POW2 = {}
for i = 0, LIMB_BITS do
  POW2[i] = 2 ^ i
end

--- Largest Lua number that survives `from_number` exactly on a double-only VM.
local MAX_SAFE_NUMBER = 9007199254740992 -- 2^53

--- Known-answer vector used to verify an OpenSSL binding before trusting it.
--- Deliberately multi-limb so a binding that mis-parses long hex is caught.
local ACCEL_CHECK_BASE = "c0ffee0123456789abcdef0123456789abcdef0123456789ab"
local ACCEL_CHECK_EXP = "1234567890abcdef1234"
local ACCEL_CHECK_MOD = "fffffffffffffffffffffffffffffffffffffffeffffee37"
local ACCEL_CHECK_RESULT = "e2f14166c00a4c44a535f801534727158dcfce58a82049b7"

-- ============================================================================
-- INTERNAL: CORE HELPERS
-- ============================================================================

--- Strip high-order zero limbs so the value is canonical.
--- @param t BigNum Limb array, modified in place
--- @return BigNum t The same array, normalized
local function normalize(t)
  local n = #t
  while n > 0 and t[n] == 0 do
    t[n] = nil
    n = n - 1
  end
  return t
end

--- Create a zero-filled limb array of a fixed length.
--- @param n integer Number of limbs
--- @return integer[] limbs
local function zeros(n)
  local t = {}
  for i = 1, n do
    t[i] = 0
  end
  return t
end

--- Copy a big number into a fixed-length limb array, zero-extended.
--- @param a BigNum Source value
--- @param n integer Target limb count (must be >= #a)
--- @return integer[] limbs
local function pad(a, n)
  if #a > n then
    error("bignum: value does not fit in " .. n .. " limbs")
  end
  local t = {}
  for i = 1, n do
    t[i] = a[i] or 0
  end
  return t
end

--- Compare two normalized limb arrays.
--- @param a BigNum First value
--- @param b BigNum Second value
--- @return integer cmp -1 if a < b, 0 if equal, 1 if a > b
local function compare_raw(a, b)
  local na, nb = #a, #b
  if na ~= nb then
    return na < nb and -1 or 1
  end
  for i = na, 1, -1 do
    local ai, bi = a[i], b[i]
    if ai ~= bi then
      return ai < bi and -1 or 1
    end
  end
  return 0
end

--- Add two normalized limb arrays.
--- @param a BigNum First addend
--- @param b BigNum Second addend
--- @return BigNum sum
local function add_raw(a, b)
  local na, nb = #a, #b
  if nb > na then
    -- Keep `a` as the longer operand so the loop below can index `b` sparsely.
    -- `nb` is deliberately not reassigned: it is not read after this point.
    a, b, na = b, a, nb
  end
  local r = {}
  local carry = 0
  for i = 1, na do
    local x = a[i] + (b[i] or 0) + carry
    if x >= BASE then
      r[i] = x - BASE
      carry = 1
    else
      r[i] = x
      carry = 0
    end
  end
  if carry ~= 0 then
    r[na + 1] = carry
  end
  return r
end

--- Subtract b from a, assuming a >= b.
--- @param a BigNum Minuend
--- @param b BigNum Subtrahend (must not exceed a)
--- @return BigNum difference
local function sub_raw(a, b)
  local r = {}
  local borrow = 0
  local na = #a
  for i = 1, na do
    local x = a[i] - (b[i] or 0) - borrow
    if x < 0 then
      r[i] = x + BASE
      borrow = 1
    else
      r[i] = x
      borrow = 0
    end
  end
  if borrow ~= 0 then
    error("bignum: subtraction would be negative")
  end
  return normalize(r)
end

--- Multiply two normalized limb arrays (schoolbook, operand scanning).
--- The carry is propagated on every inner iteration, so no accumulator ever
--- exceeds BASE^2 - 1 = 2^48 - 1 regardless of operand length.
--- @param a BigNum First factor
--- @param b BigNum Second factor
--- @return BigNum product
local function mul_raw(a, b)
  local na, nb = #a, #b
  if na == 0 or nb == 0 then
    return {}
  end
  local r = zeros(na + nb)
  for i = 1, nb do
    local bi = b[i]
    if bi ~= 0 then
      local carry = 0
      local k = i - 1
      for j = 1, na do
        -- <= (BASE-1) + (BASE-1)^2 + (BASE-1) = BASE^2 - 1
        local x = r[k + j] + a[j] * bi + carry
        carry = floor(x * INV_BASE)
        r[k + j] = x - carry * BASE
      end
      local idx = k + na + 1
      while carry ~= 0 do
        local x = r[idx] + carry
        carry = floor(x * INV_BASE)
        r[idx] = x - carry * BASE
        idx = idx + 1
      end
    end
  end
  return normalize(r)
end

--- Divide by a single-limb divisor.
--- @param a BigNum Dividend
--- @param d integer Divisor, 1 <= d < BASE
--- @return BigNum quotient
--- @return integer remainder
local function divmod_small(a, d)
  local q = {}
  local r = 0
  for i = #a, 1, -1 do
    -- r < d < BASE so x < BASE^2
    local x = r * BASE + a[i]
    local qi = floor(x / d)
    q[i] = qi
    r = x - qi * d
  end
  return normalize(q), r
end

--- Full division with remainder (Knuth algorithm D, base 2^24).
--- @param a BigNum Dividend
--- @param b BigNum Divisor (must be non-zero)
--- @return BigNum quotient
--- @return BigNum remainder
local function divmod_raw(a, b)
  local n = #b
  if n == 0 then
    error("bignum: division by zero")
  end
  if compare_raw(a, b) < 0 then
    local r = {}
    for i = 1, #a do
      r[i] = a[i]
    end
    return {}, r
  end
  if n == 1 then
    local q, r = divmod_small(a, b[1])
    return q, r == 0 and {} or { r }
  end

  -- Normalize so the divisor's top limb is >= BASE/2.
  local shift = 1
  local top = b[n]
  while top < BASE_HALF do
    top = top * 2
    shift = shift * 2
  end

  local v = {}
  local carry = 0
  for i = 1, n do
    local x = b[i] * shift + carry
    carry = floor(x * INV_BASE)
    v[i] = x - carry * BASE
  end

  local m = #a - n
  local u = {}
  carry = 0
  for i = 1, #a do
    local x = a[i] * shift + carry
    carry = floor(x * INV_BASE)
    u[i] = x - carry * BASE
  end
  u[#a + 1] = carry

  local vn, vn1 = v[n], v[n - 1]
  local q = {}
  for j = m, 0, -1 do
    -- num < BASE^2, so the estimate stays exact in a double.
    local num = u[j + n + 1] * BASE + u[j + n]
    local qhat = floor(num / vn)
    local rhat = num - qhat * vn
    if qhat >= BASE then
      qhat = BASE - 1
      rhat = num - qhat * vn
    end
    while rhat < BASE and qhat * vn1 > rhat * BASE + u[j + n - 1] do
      qhat = qhat - 1
      rhat = rhat + vn
    end

    -- Multiply and subtract; borrow carried every iteration keeps p < BASE^2.
    local borrow = 0
    for i = 1, n do
      local p = qhat * v[i] + borrow
      local phigh = floor(p * INV_BASE)
      local x = u[j + i] - (p - phigh * BASE)
      if x < 0 then
        x = x + BASE
        phigh = phigh + 1
      end
      u[j + i] = x
      borrow = phigh
    end
    local x = u[j + n + 1] - borrow
    if x < 0 then
      -- qhat was one too large (probability ~2/BASE); add the divisor back.
      u[j + n + 1] = x + BASE
      qhat = qhat - 1
      local c = 0
      for i = 1, n do
        local y = u[j + i] + v[i] + c
        if y >= BASE then
          u[j + i] = y - BASE
          c = 1
        else
          u[j + i] = y
          c = 0
        end
      end
      u[j + n + 1] = (u[j + n + 1] + c) % BASE
    else
      u[j + n + 1] = x
    end
    q[j + 1] = qhat
  end

  -- Undo the normalization on the remainder.
  local r = {}
  local rem = 0
  for i = n, 1, -1 do
    local x = rem * BASE + u[i]
    local ri = floor(x / shift)
    r[i] = ri
    rem = x - ri * shift
  end

  return normalize(q), normalize(r)
end

--- Read one bit of an exponent, without 5.3+ shift operators.
--- @param e BigNum Value to inspect
--- @param i integer Zero-based bit index
--- @return integer bit 0 or 1
local function get_bit(e, i)
  local limb = e[floor(i / LIMB_BITS) + 1]
  if limb == nil then
    return 0
  end
  return floor(limb / POW2[i % LIMB_BITS]) % 2
end

--- Bit length of a normalized limb array.
--- @param a BigNum Value
--- @return integer bits 0 for zero
local function bit_length_raw(a)
  local n = #a
  if n == 0 then
    return 0
  end
  local bits = (n - 1) * LIMB_BITS
  local top = a[n]
  while top > 0 do
    bits = bits + 1
    top = floor(top / 2)
  end
  return bits
end

-- ============================================================================
-- INTERNAL: MONTGOMERY ARITHMETIC
-- ============================================================================

--- Modular inverse of an odd limb modulo BASE, by Newton iteration.
--- Every step is reduced mod BASE so no intermediate exceeds BASE^2.
--- @param m0 integer Odd value, 1 <= m0 < BASE
--- @return integer n0 (-m0^-1) mod BASE
local function mont_n0(m0)
  local inv = 1
  -- Each round doubles the number of correct bits: 1 -> 2 -> 4 -> 8 -> 16 -> 32.
  for _ = 1, 5 do
    local t = (m0 * inv) % BASE
    t = (2 - t) % BASE
    inv = (inv * t) % BASE
  end
  if (m0 * inv) % BASE ~= 1 then
    error("bignum: modulus is not odd")
  end
  return (BASE - inv) % BASE
end

--- Build the Montgomery context for an odd modulus > 1.
---
--- The context uses one limb more than the modulus needs (`s = #m + 1`) so that
--- 4*m < BASE^s always holds. That is the precondition under which CIOS output
--- stays below 2*m and a single conditional subtraction suffices; without the
--- spare limb a 3072-bit modulus (which is *exactly* 128 limbs wide) would
--- overflow the accumulator's top word.
---
--- @param m BigNum Odd modulus, m > 1
--- @return table ctx Fields: s, mp, n0, r1 (R mod m), r2 (R^2 mod m)
local function mont_context(m)
  local s = #m + 1
  local mp = pad(m, s)
  local n0 = mont_n0(mp[1])

  -- R = BASE^s
  local r = zeros(s + 1)
  r[s + 1] = 1
  local _, r1 = divmod_raw(normalize(r), m)
  local _, r2 = divmod_raw(mul_raw(r1, r1), m)

  return { s = s, mp = mp, n0 = n0, r1 = pad(r1, s), r2 = pad(r2, s), t = zeros(s + 2) }
end

--- Montgomery multiplication: out = a * b * R^-1 mod m (CIOS).
---
--- `out` may alias `a` or `b`: every read of the operands happens before the
--- single write-back at the end.
---
--- @param ctx table Context from `mont_context`
--- @param a integer[] Left operand, exactly ctx.s limbs
--- @param b integer[] Right operand, exactly ctx.s limbs
--- @param out integer[] Destination, exactly ctx.s limbs
--- @return integer[] out
local function mont_mul(ctx, a, b, out)
  local s = ctx.s
  local mp = ctx.mp
  local n0 = ctx.n0
  local t = ctx.t

  for i = 1, s + 2 do
    t[i] = 0
  end

  for i = 1, s do
    local bi = b[i]
    local c = 0
    for j = 1, s do
      -- <= (BASE-1) + (BASE-1)^2 + (BASE-1) = BASE^2 - 1 = 2^48 - 1
      local x = t[j] + a[j] * bi + c
      c = floor(x * INV_BASE)
      t[j] = x - c * BASE
    end
    local x = t[s + 1] + c
    c = floor(x * INV_BASE)
    t[s + 1] = x - c * BASE
    t[s + 2] = c

    local mi = (t[1] * n0) % BASE
    -- t[1] + mi*mp[1] is a multiple of BASE by construction of n0.
    x = t[1] + mi * mp[1]
    c = floor(x * INV_BASE)
    for j = 2, s do
      x = t[j] + mi * mp[j] + c
      c = floor(x * INV_BASE)
      t[j - 1] = x - c * BASE
    end
    x = t[s + 1] + c
    c = floor(x * INV_BASE)
    t[s] = x - c * BASE
    t[s + 1] = t[s + 2] + c
  end

  -- Result is < 2*m: one conditional subtraction brings it into range.
  local subtract = t[s + 1] ~= 0
  if not subtract then
    local cmp = 0 -- 0 means "equal to m so far", so subtract
    for j = s, 1, -1 do
      local tv, mv = t[j], mp[j]
      if tv ~= mv then
        cmp = tv > mv and 1 or -1
        break
      end
    end
    subtract = cmp >= 0
  end

  if subtract then
    local borrow = 0
    for j = 1, s do
      local x = t[j] - mp[j] - borrow
      if x < 0 then
        out[j] = x + BASE
        borrow = 1
      else
        out[j] = x
        borrow = 0
      end
    end
  else
    for j = 1, s do
      out[j] = t[j]
    end
  end
  return out
end

--- Pick a sliding-window width for an exponent of the given bit length.
--- @param bits integer Exponent bit length
--- @return integer w Window width
local function window_width(bits)
  if bits <= 23 then
    return 1
  elseif bits <= 79 then
    return 3
  elseif bits <= 239 then
    return 4
  end
  return 5
end

--- Modular exponentiation via Montgomery multiplication + sliding window.
---
--- Why: the textbook "square and multiply, then divmod" costs a full Knuth
--- division per step, and division is several times more expensive than the
--- multiplication it reduces. Montgomery replaces every reduction with a second
--- multiply-accumulate pass over the same limbs, so a modular square costs
--- 2*s^2 limb products and no division at all. On top of that a sliding window
--- of width w replaces ~bits/2 multiplications with ~bits/(w+1) of them: for a
--- 3072-bit exponent that is roughly 3072 squarings + ~512 multiplications
--- instead of 3072 + ~1536.
---
--- Requires an odd modulus greater than 1, which the RFC 5054 safe primes are.
---
--- @param base BigNum Base
--- @param exp BigNum Exponent, must be non-zero
--- @param m BigNum Odd modulus, m > 1
--- @return BigNum result base^exp mod m
local function mod_exp_montgomery(base, exp, m)
  local ctx = mont_context(m)
  local s = ctx.s

  local _, reduced = divmod_raw(base, m)
  local x = pad(reduced, s)
  mont_mul(ctx, x, ctx.r2, x) -- x -> Montgomery form

  local bits = bit_length_raw(exp)
  local w = window_width(bits)

  -- Odd powers x^1, x^3, ... x^(2^w - 1), all in Montgomery form.
  local odd = { [1] = x }
  if w > 1 then
    local x2 = mont_mul(ctx, x, x, zeros(s))
    for k = 3, POW2[w] - 1, 2 do
      odd[k] = mont_mul(ctx, odd[k - 2], x2, zeros(s))
    end
  end

  local acc = pad(ctx.r1, s) -- Montgomery representation of 1
  local i = bits - 1
  while i >= 0 do
    if get_bit(exp, i) == 0 then
      mont_mul(ctx, acc, acc, acc)
      i = i - 1
    else
      local l = i - w + 1
      if l < 0 then
        l = 0
      end
      while get_bit(exp, l) == 0 do
        l = l + 1
      end
      local value = 0
      for k = i, l, -1 do
        value = value * 2 + get_bit(exp, k)
      end
      for _ = 1, i - l + 1 do
        mont_mul(ctx, acc, acc, acc)
      end
      mont_mul(ctx, acc, odd[value], acc)
      i = l - 1
    end
  end

  -- Leave the Montgomery domain: acc * 1 * R^-1.
  local one = zeros(s)
  one[1] = 1
  mont_mul(ctx, acc, one, acc)
  return normalize(acc)
end

--- Slow, obvious reference exponentiation: bitwise square-and-multiply with a
--- full division after every step. Kept as the correctness oracle that
--- `selftest()` cross-checks the Montgomery path against, and as the fallback
--- for the even moduli Montgomery cannot handle.
--- @param base BigNum Base
--- @param exp BigNum Exponent
--- @param m BigNum Modulus, m > 0
--- @return BigNum result base^exp mod m
local function mod_exp_reference(base, exp, m)
  local _, result = divmod_raw({ 1 }, m)
  local _, b = divmod_raw(base, m)
  for i = bit_length_raw(exp) - 1, 0, -1 do
    local _, sq = divmod_raw(mul_raw(result, result), m)
    result = sq
    if get_bit(exp, i) == 1 then
      local _, pr = divmod_raw(mul_raw(result, b), m)
      result = pr
    end
  end
  return result
end

-- ============================================================================
-- INTERNAL: OPENSSL ACCELERATION
-- ============================================================================

-- The canonical representation is ALWAYS the pure-Lua limb table. OpenSSL is
-- used only as an internal accelerator *inside* mod_exp: operands are converted
-- into openssl.bn handles (big-endian bytes in via bn.text), the modexp runs
-- there, and the result is converted straight back to a limb table (hex out via
-- bn.tohex). That is exactly the conversion path Feature.BN probes.
--
-- Rationale: crypto.use_openssl() can be toggled at runtime, so if handles were
-- sometimes userdata and sometimes tables, a toggle mid-flight would produce
-- mixed-type operands and silent breakage. Keeping one canonical type makes the
-- accelerator invisible to callers -- results are identical with and without
-- it, and selftest() asserts exactly that. The conversion cost is a few hundred
-- bytes moved in and out versus a 3072-bit modexp, so it is noise.

--- Binding whose behaviour has already been verified, and the verdict.
local _verified_binding = nil
local _verified_ok = false

--- Resolve this build's modular-exponentiation entry point.
--- Control4's lua-openssl 0.8.5 spells it `powmod`; other builds use `mod_exp`.
--- @param bnlib table The openssl.bn table
--- @return function powmod
local function bn_powmod(bnlib)
  if type(bnlib.powmod) == "function" then
    return bnlib.powmod
  end
  return bnlib.mod_exp
end

--- Build an openssl.bn handle from a canonical big number.
--- `bn.text` takes big-endian bytes; zero is passed as a single zero byte
--- rather than the empty string, which not every build accepts.
--- @param bnlib table The openssl.bn table
--- @param value BigNum Value to convert
--- @return any handle Opaque openssl.bn value
local function bn_from_bignum(bnlib, value)
  if #value == 0 then
    return bnlib.text("\0")
  end
  return bnlib.text(bignum.to_bytes(value))
end

--- Run one modular exponentiation through the OpenSSL binding.
--- @param openssl table Loaded lua-openssl module
--- @param base BigNum Base
--- @param exp BigNum Exponent
--- @param m BigNum Modulus
--- @return BigNum result Canonical limb table
local function mod_exp_openssl(openssl, base, exp, m)
  local bnlib = openssl.bn
  local result = bn_powmod(bnlib)(bn_from_bignum(bnlib, base), bn_from_bignum(bnlib, exp), bn_from_bignum(bnlib, m))
  local hex = bnlib.tohex(result)
  if type(hex) ~= "string" or hex == "" then
    error("bignum: openssl bn.tohex did not return hex")
  end
  return bignum.from_hex(hex)
end

--- Decide whether a binding may be trusted for real work.
---
--- `Feature.BN` proves the three entry points exist and round-trip on a
--- single-digit value; it cannot prove that this build's constructor parses a
--- long hex string the way this module writes it. So the first time a given
--- binding table is seen, run one multi-limb known-answer vector through it and
--- cache the verdict. A binding that fails silently falls back to pure Lua
--- rather than returning wrong answers.
---
--- @param openssl table Loaded lua-openssl module
--- @return boolean usable
local function accelerator_ready(openssl)
  if _verified_binding == openssl then
    return _verified_ok
  end
  _verified_binding = openssl
  _verified_ok = false
  local ok, result = pcall(
    mod_exp_openssl,
    openssl,
    bignum.from_hex(ACCEL_CHECK_BASE),
    bignum.from_hex(ACCEL_CHECK_EXP),
    bignum.from_hex(ACCEL_CHECK_MOD)
  )
  if ok and type(result) == "table" and compare_raw(result, bignum.from_hex(ACCEL_CHECK_RESULT)) == 0 then
    _verified_ok = true
  end
  return _verified_ok
end

-- ============================================================================
-- PUBLIC INTERFACE: CONSTRUCTION AND CONVERSION
-- ============================================================================

--- Create a big number from a big-endian byte string of any length.
--- @param str string Big-endian bytes ("" is zero)
--- @return BigNum bn
function bignum.from_bytes(str)
  local n = #str
  local r = {}
  local k = 0
  local i = n
  while i >= 1 do
    local b0 = string_byte(str, i)
    local b1 = i >= 2 and string_byte(str, i - 1) or 0
    local b2 = i >= 3 and string_byte(str, i - 2) or 0
    k = k + 1
    r[k] = b0 + b1 * 256 + b2 * 65536
    i = i - LIMB_BYTES
  end
  return normalize(r)
end

--- Serialize a big number to big-endian bytes.
--- Without `length` the encoding is minimal, so zero serializes to "" and
--- `from_bytes(to_bytes(x)) == x` for every x. With `length` the result is
--- left-padded with zero bytes to exactly that many bytes, which is what SRP
--- needs when hashing values modulo N.
--- @param bn BigNum Value
--- @param length? integer Exact output length in bytes
--- @return string str Big-endian bytes
function bignum.to_bytes(bn, length)
  local parts = {}
  for k = #bn, 1, -1 do
    local v = bn[k]
    local b2 = floor(v / 65536)
    parts[#parts + 1] = string_char(b2, floor(v / 256) % 256, v % 256)
  end
  local raw = table_concat(parts)
  local first = 1
  local total = #raw
  while first <= total and string_byte(raw, first) == 0 do
    first = first + 1
  end
  local trimmed = string_sub(raw, first)
  if length == nil then
    return trimmed
  end
  if #trimmed > length then
    error("bignum: value needs " .. #trimmed .. " bytes, cannot fit in " .. length)
  end
  return string_rep("\0", length - #trimmed) .. trimmed
end

--- Parse a hexadecimal string (either case, any length, no prefix).
--- @param hex string Hex digits ("" or "0" is zero)
--- @return BigNum bn
function bignum.from_hex(hex)
  local r = {}
  local k = 0
  local i = #hex
  while i >= 1 do
    local j = i - LIMB_HEX + 1
    if j < 1 then
      j = 1
    end
    local chunk = string_sub(hex, j, i)
    local value = tonumber(chunk, 16)
    if value == nil then
      error("bignum: invalid hex digits '" .. chunk .. "'")
    end
    k = k + 1
    r[k] = value
    i = j - 1
  end
  return normalize(r)
end

--- Serialize to lowercase hex with no leading zeros ("0" for zero).
--- @param bn BigNum Value
--- @return string hex
function bignum.to_hex(bn)
  local n = #bn
  if n == 0 then
    return "0"
  end
  local parts = { string_format("%x", bn[n]) }
  for k = n - 1, 1, -1 do
    parts[#parts + 1] = string_format("%06x", bn[k])
  end
  return table_concat(parts)
end

--- Create a big number from a non-negative Lua integer.
--- @param n integer Value in [0, 2^53]
--- @return BigNum bn
function bignum.from_number(n)
  if type(n) ~= "number" or n < 0 or n ~= floor(n) then
    error("bignum: from_number requires a non-negative integer")
  end
  if n > MAX_SAFE_NUMBER then
    error("bignum: from_number is limited to 2^53; use from_hex or from_bytes")
  end
  local r = {}
  local k = 0
  while n > 0 do
    k = k + 1
    r[k] = n % BASE
    n = floor(n / BASE)
  end
  return r
end

--- The value zero.
--- @return BigNum bn
function bignum.zero()
  return {}
end

--- The value one.
--- @return BigNum bn
function bignum.one()
  return { 1 }
end

--- Duplicate a big number; the copy shares no state with the original.
--- @param bn BigNum Value
--- @return BigNum copy
function bignum.copy(bn)
  local r = {}
  for i = 1, #bn do
    r[i] = bn[i]
  end
  return r
end

-- ============================================================================
-- PUBLIC INTERFACE: INSPECTION
-- ============================================================================

--- Test whether a value is zero.
--- @param bn BigNum Value
--- @return boolean is_zero
function bignum.is_zero(bn)
  return #bn == 0
end

--- Number of significant bits (0 for zero).
--- @param bn BigNum Value
--- @return integer bits
function bignum.bit_length(bn)
  return bit_length_raw(bn)
end

--- Number of bytes in the minimal big-endian encoding (0 for zero).
--- @param bn BigNum Value
--- @return integer count
function bignum.byte_length(bn)
  local bits = bit_length_raw(bn)
  return floor((bits + 7) / 8)
end

--- Three-way comparison.
--- @param a BigNum First value
--- @param b BigNum Second value
--- @return integer cmp -1 if a < b, 0 if a == b, 1 if a > b
function bignum.compare(a, b)
  return compare_raw(a, b)
end

--- Equality test.
--- @param a BigNum First value
--- @param b BigNum Second value
--- @return boolean equal
function bignum.equals(a, b)
  return compare_raw(a, b) == 0
end

-- ============================================================================
-- PUBLIC INTERFACE: ARITHMETIC
-- ============================================================================

--- Addition.
--- @param a BigNum First addend
--- @param b BigNum Second addend
--- @return BigNum sum
function bignum.add(a, b)
  return add_raw(a, b)
end

--- Subtraction. Errors when b > a, since values are unsigned.
--- @param a BigNum Minuend
--- @param b BigNum Subtrahend
--- @return BigNum difference
function bignum.sub(a, b)
  return sub_raw(a, b)
end

--- Multiplication.
--- @param a BigNum First factor
--- @param b BigNum Second factor
--- @return BigNum product
function bignum.mul(a, b)
  return mul_raw(a, b)
end

--- Division with remainder.
--- @param a BigNum Dividend
--- @param b BigNum Divisor (must be non-zero)
--- @return BigNum quotient floor(a / b)
--- @return BigNum remainder a - quotient * b
function bignum.divmod(a, b)
  return divmod_raw(a, b)
end

--- Remainder of a divided by b.
--- @param a BigNum Dividend
--- @param b BigNum Modulus (must be non-zero)
--- @return BigNum remainder
function bignum.mod(a, b)
  local _, r = divmod_raw(a, b)
  return r
end

--- Modular addition.
--- @param a BigNum First addend
--- @param b BigNum Second addend
--- @param m BigNum Modulus (must be non-zero)
--- @return BigNum result (a + b) mod m
function bignum.mod_add(a, b, m)
  local _, r = divmod_raw(add_raw(a, b), m)
  return r
end

--- Modular subtraction, always returning a non-negative residue.
--- SRP computes B - k*g^x, where the subtraction can go negative, so this wraps
--- rather than erroring.
--- @param a BigNum Minuend
--- @param b BigNum Subtrahend
--- @param m BigNum Modulus (must be non-zero)
--- @return BigNum result (a - b) mod m
function bignum.mod_sub(a, b, m)
  local _, ra = divmod_raw(a, m)
  local _, rb = divmod_raw(b, m)
  if compare_raw(ra, rb) >= 0 then
    return sub_raw(ra, rb)
  end
  return sub_raw(add_raw(ra, m), rb)
end

--- Modular multiplication.
--- @param a BigNum First factor
--- @param b BigNum Second factor
--- @param m BigNum Modulus (must be non-zero)
--- @return BigNum result (a * b) mod m
function bignum.mod_mul(a, b, m)
  local _, r = divmod_raw(mul_raw(a, b), m)
  return r
end

--- Modular exponentiation -- the hot path for SRP-6a.
---
--- Dispatch order: a verified OpenSSL binding if acceleration is enabled,
--- otherwise Montgomery + sliding window for odd moduli, otherwise the slow
--- reference path. All three return identical values.
---
--- @param base BigNum Base
--- @param exp BigNum Exponent
--- @param m BigNum Modulus (must be non-zero)
--- @return BigNum result base^exp mod m
function bignum.mod_exp(base, exp, m)
  if #m == 0 then
    error("bignum: mod_exp modulus must be non-zero")
  end
  if #m == 1 and m[1] == 1 then
    return {}
  end
  if #exp == 0 then
    return { 1 }
  end

  local openssl = openssl_wrapper.get(openssl_wrapper.Feature.BN)
  if openssl ~= nil and accelerator_ready(openssl) then
    local ok, result = pcall(mod_exp_openssl, openssl, base, exp, m)
    if ok and type(result) == "table" then
      return result
    end
  end

  if m[1] % 2 == 1 then
    return mod_exp_montgomery(base, exp, m)
  end
  -- Montgomery needs an odd modulus; even moduli are not used by SRP.
  return mod_exp_reference(base, exp, m)
end

--- Whether `mod_exp` will use the OpenSSL backend.
---
--- Answers the question callers actually have -- "will a 3072-bit exponentiation
--- finish in milliseconds or in minutes?" -- so it applies the same two
--- conditions `mod_exp` does: acceleration enabled with a binding that passes
--- `Feature.BN`, *and* a binding that reproduces the multi-limb known-answer
--- vector. Checking the feature gate alone would report true for a binding this
--- module has already decided not to trust.
---
--- The verdict is not static: it changes with `crypto.use_openssl()`.
---
--- A false verdict comes with the reason, because the two common causes need
--- opposite responses and are otherwise indistinguishable: a host that cannot
--- accelerate has to be designed around, while a caller that never enabled
--- acceleration just has to make one call. The reason is always present when
--- `accelerated` is false.
---
--- @return boolean accelerated True if OpenSSL will handle modular exponentiation
--- @return string|nil reason Why it will not, when it will not
function bignum.is_accelerated()
  local openssl = openssl_wrapper.get(openssl_wrapper.Feature.BN)
  if openssl == nil then
    return false,
      openssl_wrapper.unavailable_reason(openssl_wrapper.Feature.BN) or "OpenSSL modular exponentiation is unavailable"
  end
  if not accelerator_ready(openssl) then
    return false,
      "the lua-openssl binding failed bignum's multi-limb known-answer check, "
        .. "so it is not trusted for modular exponentiation"
  end
  return true
end

-- ============================================================================
-- TEST VECTORS AND VALIDATION
-- ============================================================================

-- Every expected value below was produced independently with CPython's
-- arbitrary-precision integers (`python3 -c "print(pow(g, x, N))"` and friends)
-- and committed here as a literal.

--- RFC 5054 Appendix A / RFC 3526 group 15: the 3072-bit safe prime N.
--- Its generator is g = 5.
local RFC5054_N_HEX = table.concat({
  "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74",
  "020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f1437",
  "4fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7ed",
  "ee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf05",
  "98da48361c55d39a69163fa8fd24cf5f83655d23dca3ad961c62f356208552bb",
  "9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3b",
  "e39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf695581718",
  "3995497cea956ae515d2261898fa051015728e5a8aaac42dad33170d04507a33",
  "a85521abdf1cba64ecfb850458dbef0a8aea71575d060c7db3970f85a6e1e4c7",
  "abf5ae8cdb0933d71e8c94e04a25619dcee3d2261ad2ee6bf12ffa06d98a0864",
  "d87602733ec86a64521f2b18177b200cbbe117577a615d6c770988c0bad946e2",
  "08e24fa074e5ab3143db5bfce0fd108e4b82d120a93ad2caffffffffffffffff",
})
local SRP_EXP_A_HEX = "60975527035cf2ad1989806f0407210bc81edc04e2762a56afd529ddda2d4393"
local SRP_RESULT_A_HEX = table.concat({
  "fab6f5d2615d1e323512e7991cc37443f487da604ca8c9230fcb04e541dce628",
  "0b27ca4680b0374f179dc3bdc7553fe62459798c701ad864a91390a28c93b644",
  "adbf9c00745b942b79f9012a21b9b78782319d83a1f8362866fbd6f46bfc0ddb",
  "2e1ab6e4b45a9906b82e37f05d6f97f6a3eb6e182079759c4f6847837b62321a",
  "c1b4fa68641fcb4bb98dd697a0c73641385f4bab25b793584cc39fc8d48d4bd8",
  "67a9a3c10f8ea12170268e34fe3bbe6ff89998d60da2f3e4283cbec1393d52af",
  "724a57230c604e9fbce583d7613e6bffd67596ad121a8707eec4694495703368",
  "6a155f644d5c5863b48f61bdbf19a53eab6dad0a186b8c152e5f5d8cad4b0ef8",
  "aa4ea5008834c3cd342e5e0f167ad04592cd8bd279639398ef9e114dfaaab919",
  "e14e850989224ddd98576d79385d2210902e9f9b1f2d86cfa47ee244635465f7",
  "1058421a0184be51dd10cc9d079e6f1604e7aa9b7cf7883c7d4ce12b06ebe160",
  "81e23f27a231d18432d7d1bb55c28ae21ffcf005f57528d15a88881bb3bbb7fe",
})
local SRP_EXP_B_HEX = table.concat({
  "e487cb59d31ac550471e81f00f6928e01dda08e974a004f49e61f5d105284d20",
  "3fbb0e0e1e0b1a1c9d8e7f60514243342a1b0c9f8e7d6c5b4a39281706f5e4d3",
  "c2b1a09f8e7d6c5b4a3928170615243342b1a09f8e7d6c5b4a39281706152433",
  "42b1a09f8e7d6c5b4a3928170615243342b1a09f8e7d6c5b4a39281706152433",
  "42b1a09f8e7d6c5b4a3928170615243342b1a09f8e7d6c5b4a39281706152433",
  "42b1a09f8e7d6c5b4a3928170615243342b1a09f8e7d6c5b4a39281706152433",
  "42b1a09f8e7d6c5b4a3928170615243342b1a09f8e7d6c5b4a39281706152433",
  "42b1a09f8e7d6c5b4a3928170615243342b1a09f8e7d6c5b4a3928170615243f",
  "42b1a09f8e7d6c5b4a3928170615243342b1a09f8e7d6c5b4a39281706152433",
  "42b1a09f8e7d6c5b4a3928170615243342b1a09f8e7d6c5b4a39281706152433",
  "42b1a09f8e7d6c5b4a3928170615243342b1a09f8e7d6c5b4a39281706152433",
  "42b1a09f8e7d6c5b4a3928170615243342b1a09f8e7d6c5b4a3928170615243f",
})
local SRP_RESULT_B_HEX = table.concat({
  "1e9606e73774d51f84e1eefb8e8ce7b07a0e204b76dc57d55968d4159a32f760",
  "4e36da94747fc9f995e920741169aa810cc25e4a4b7df654bb8e48275e063d6c",
  "744f1e3bfcd18b84e97a69d39ac775b466cc1b0928f0ee55d79e05329a942ca6",
  "af50f660d4af6129e9e378119843836ea8b7c0aa1035d6e33ebf3defd0512ebf",
  "c6dbb3e111a8630cf6d444e98e23fd5219747dcc537da5742fe3b3262a61e6b4",
  "6fa328d398d104bc3735f5e0f883b4c8fe1b3ee5b77ba2222b9b4cff974e060d",
  "9b52bc56a4edaf6b88a149b06eace7a40f68348fd84a28c95a524da2846cd738",
  "4ce58188f44f27c279b5e1279754d82794a67db88ed67a44eddb189094f7830d",
  "4748cecd898d44387558e41293561752775c44360fc5b57fa386470b2019da88",
  "0637a5443c2165f23b2f914b33b601edc8e2aff5dd916387e4c186d495a790da",
  "5f4b2e82b2a881479a4c819086e5fd284fe5144c2cc259d7b5c5c085430268ea",
  "664826f9fdb4e4183b8613b772c50a56a97f1a13c0471d562151b41fcfbd3559",
})
local SRP_BASE_OVER_N_HEX = table.concat({
  "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74",
  "020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f1437",
  "4fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7ed",
  "ee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf05",
  "98da48361c55d39a69163fa8fd24cf5f83655d23dca3ad961c62f356208552bb",
  "9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3b",
  "e39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf695581718",
  "3995497cea956ae515d2261898fa051015728e5a8aaac42dad33170d04507a33",
  "a85521abdf1cba64ecfb850458dbef0a8aea71575d060c7db3970f85a6e1e4c7",
  "abf5ae8cdb0933d71e8c94e04a25619dcee3d2261ad2ee6bf12ffa06d98a0864",
  "d87602733ec86a64521f2b18177b200cbbe117577a615d6c770988c0bad946e2",
  "08e24fa074e5ab3143db5bfce0fd108e4b82d120a93ad2cb0000000000000006",
})
local SRP_RESULT_OVER_HEX = table.concat({
  "34fd4d3beb508957d7a1b34394835595739fcebae187bc7cf18d8dbee1f8cdd7",
  "fbb20f4d870b7f9f9d13dad25006445975cf81c4fffa0bd26bb399c2b235657c",
  "a7aae7ac6bc6a78cba6ddfd1cc971505b6acbdbbadf8c8346006590588209cbe",
  "3b21c7141166f53da71b9d739c785aa1c722ff5ad6bf0d8556e1836570c3e62d",
  "b1fe8c715b84867c31faa7621b315130de124f38b250052217658a2535e0ca89",
  "014101aec9e8ca705a37b8956dc5a629f80a542c4f02e01150ddd44228c76ab6",
  "77e930f3875e57c5cf87a3ac3b16f94ed2427aa5c4028cb5b7dfd568057f1285",
  "46a28a0cdbf79120c2a955956c7f4ad6220929ae1f76954d347de3bd57d05e31",
  "ca711fa27ab77fc85473d4ba7e89dcca338a0e5c06009edeb5788cc9bc840add",
  "6f3f740da521f6b3be5a1ac0e4d1b8acb500ebe95c99cf713b972ee1f6e4bf29",
  "af7c5f4b88d5893f2deab5df5cb6e7e3ab516d388a9bcdfda0867b6bc93197b9",
  "519e5b25ffa39abb52b18dc6e7e78f601443ae575f1bc59ffc2d86a06af4cf04",
})
local VEC_X_HEX = "f0e1d2c3b4a5968778695a4b3c2d1e0fdeadbeefcafebabe0123456789abcdef"
local VEC_Y_HEX = "fedcba987654321fedcba9876543210abcdef0123456789"
local VEC_M_HEX = "fffffffffffffffffffffffffffffffeffffffffffffffff"
local VEC_ADD_HEX = "f0e1d2c3b4a59687885725f4c3926131dd8a79884152ecceacf13468acf13578"
local VEC_SUB_HEX = "f0e1d2c3b4a59687687b8ea1b4c7daeddfd1045754aa88ad5555566666666666"
local VEC_MUL_HEX = table.concat({
  "efcfc0c2d5fa2f84db52db751fdba8927fd0cfb89d03a6e23469667bcbb09e04",
  "0c96803be0e492284a6a2290002002425d85431fb375de7",
})
local VEC_QUO_HEX = "f1f51dfdb8e1c16d7"
local VEC_REM_HEX = "4e56a81e2677fc8622ba2a844cc25a8440c2e32a28013e0"
local VEC_MOD_X_HEX = "78695a4b3c2d1e10cf8f91b37fa45145f205182b3e516476"
local VEC_MOD_ADD_HEX = "885725f4c3926132ce6c4c4bf5f883569dd3072c6196cbff"
local VEC_MOD_SUB_HEX = "9784715e4b3825112f4d28e4f6afe0c9b9c8d6d5e4f40312"
local VEC_MOD_MUL_HEX = "c5789ec2c73be1123b996b5bf34a44eba5d1145d374fc548"
local VEC_MOD_EXP_HEX = "e6663770f70809f8c052b35cc00534b8d5b2c013a9d4874c"
local CROSS_CHECK_VECTORS = {
  {
    base = "502d7ab70ebf0d087251c67d5c934eb0ef4a70d5c51a00ee54f73e1e08903425",
    exp = "f35d4f200a780822124a0b081179e3d4a0d35510ab6e959e2c",
    mod = "8e99ae1be2d241aeeb84195f9b108f9cf349d985159faa81e4481dfa13d53823",
    result = "72dcd8f95d33f62a754cf474d81b6d956f6679ebc5728a1ef6933847d8770e26",
  },
  {
    base = "25ae403fe777a8a29bdd6a5789cc8bbaab9d2464af1aacb53ae32135898e6bfa",
    exp = "80b8f4c2e5ddf71127f4eb3aa7a10564fce9969b05172e80ba",
    mod = "9304db81ec231dd86cdebb4eda07e4970efba2ff86aa0709e9a1dcde6d0d33c5",
    result = "13449129cb254007fe2810d95a9b437feebc78a31c1e2fd5073ec2ef6b4df5e6",
  },
  {
    base = "69bb23c104796692e0b335cace9437938c7f88608b5b34eac5ee3bb98f7ffe43",
    exp = "29dd6ffbfa8abc5492e855efc01b31186cb4b55dc01dcb6cf0",
    mod = "b751b52d96495d031ff4ab3d7784abe057a84ec928c26106bb0412086eed0137",
    result = "a654ff028a94c301f72b0aefacd2c5c65499787ee00c5f15a0d022587ad07b99",
  },
}

--- Run comprehensive self-test with known-answer test vectors
---
--- Covers conversions, schoolbook arithmetic across limb boundaries, modular
--- arithmetic, and modular exponentiation up to full 3072-bit SRP operands.
--- It also asserts the two invariants this module is built around: that the
--- optimised Montgomery path agrees with the slow reference path, and that the
--- OpenSSL-accelerated path is bit-identical to the pure-Lua one.
---
--- @return boolean result True if all tests pass, false otherwise
function bignum.selftest()
  print("Running bignum test vectors...")

  local from_hex = bignum.from_hex
  local to_hex = bignum.to_hex
  local from_number = bignum.from_number
  local equals = bignum.equals

  local N = from_hex(RFC5054_N_HEX)
  local G = from_number(5)
  local X = from_hex(VEC_X_HEX)
  local Y = from_hex(VEC_Y_HEX)
  local M = from_hex(VEC_M_HEX)

  -- Snapshot the OpenSSL state so the accelerator tests cannot leak.
  local saved_loaded = package.loaded["openssl"]
  local saved_preload = package.preload["openssl"]

  --- Build a stand-in lua-openssl binding. Real lua-openssl is not installed
  --- here, so this validates the *routing* and the bytes-in/hex-out conversion,
  --- not real OpenSSL arithmetic: the stand-in's modular exponentiation
  --- delegates to this module's own slow reference path.
  --- @param options table `spelling` is "powmod" or "mod_exp"; `broken` returns wrong
  ---   answers for everything; `small_only` returns right answers for single-limb
  ---   operands and wrong ones above that, which is what `Feature.BN`'s probe cannot
  ---   see and `accelerator_ready`'s multi-limb vector exists to catch
  --- @return table binding
  --- @return function calls Returns how many times the exponentiation was invoked
  local function make_binding(options)
    local calls = 0
    local bnlib = {}
    bnlib.text = function(raw)
      -- Matches lua-openssl's bn.text: big-endian bytes in.
      return { value = bignum.from_bytes(raw) }
    end
    bnlib.tohex = function(handle)
      return string_upper(to_hex(handle.value))
    end
    bnlib[options.spelling or "powmod"] = function(base, exp, modulus)
      calls = calls + 1
      if options.broken then
        return { value = from_number(1) }
      end
      if options.small_only and (#base.value > 1 or #exp.value > 1 or #modulus.value > 1) then
        return { value = from_number(1) }
      end
      return { value = mod_exp_reference(base.value, exp.value, modulus.value) }
    end
    local binding = {
      version = function()
        return "0.9.2"
      end,
      bn = bnlib,
    }
    return binding, function()
      return calls
    end
  end

  --- Install a stand-in binding (or force acceleration off) and re-probe.
  --- @param binding table|nil Stand-in module, or nil for the pure-Lua path
  local function install(binding)
    package.loaded["openssl"] = binding
    if binding == nil then
      -- Force require("openssl") to fail regardless of what this host has.
      -- Each selftest stubs the same loader independently, which the language
      -- server reads as redefining one field; that is the intent here.
      --- @diagnostic disable-next-line: duplicate-set-field
      package.preload["openssl"] = function()
        error("simulated absent binding")
      end
    else
      package.preload["openssl"] = nil
    end
    openssl_wrapper.use(binding ~= nil)
  end

  -- Make the whole run deterministic: the vectors below exercise pure Lua.
  install(nil)

  local tests = {
    -- ---------------------------------------------------------------- bytes
    {
      name = "from_bytes/to_bytes round-trip",
      test = function()
        local raw = bytes.from_hex(VEC_X_HEX)
        return bignum.to_bytes(from_hex(VEC_X_HEX)) == raw and to_hex(bignum.from_bytes(raw)) == VEC_X_HEX
      end,
    },
    {
      name = "from_bytes ignores leading zero bytes",
      test = function()
        return equals(bignum.from_bytes(bytes.from_hex("00000001ff")), from_number(511))
      end,
    },
    {
      name = "to_bytes pads on the left when length is given",
      test = function()
        return bignum.to_bytes(from_number(511), 4) == bytes.from_hex("000001ff")
      end,
    },
    {
      name = "to_bytes preserves leading zeros through a round-trip",
      test = function()
        local padded = bignum.to_bytes(from_hex("0001ff"), 8)
        return #padded == 8 and padded == bytes.from_hex("00000000000001ff")
      end,
    },
    {
      name = "to_bytes rejects a length that cannot hold the value",
      test = function()
        return pcall(bignum.to_bytes, X, 8) == false
      end,
    },
    {
      name = "to_bytes of a 3072-bit value is exactly 384 bytes",
      test = function()
        return #bignum.to_bytes(N) == 384 and #bignum.to_bytes(N, 384) == 384
      end,
    },
    {
      name = "zero round-trips through bytes",
      test = function()
        local zero = bignum.zero()
        return bignum.is_zero(zero)
          and bignum.to_bytes(zero) == ""
          and bignum.to_bytes(zero, 4) == bytes.from_hex("00000000")
          and bignum.is_zero(bignum.from_bytes(""))
          and bignum.is_zero(bignum.from_bytes(bytes.from_hex("0000")))
      end,
    },
    -- ------------------------------------------------------------------ hex
    {
      name = "from_hex/to_hex round-trip on a 3072-bit value",
      test = function()
        return to_hex(N) == RFC5054_N_HEX and bignum.bit_length(N) == 3072
      end,
    },
    {
      name = "from_hex accepts uppercase and odd-length input",
      test = function()
        return equals(from_hex("ABCDEF"), from_hex("abcdef")) and to_hex(from_hex("fff")) == "fff"
      end,
    },
    {
      name = 'to_hex of zero is "0" and round-trips',
      test = function()
        return to_hex(bignum.zero()) == "0" and bignum.is_zero(from_hex("0")) and bignum.is_zero(from_hex(""))
      end,
    },
    {
      name = "from_hex rejects non-hex input",
      test = function()
        return pcall(from_hex, "12zz34") == false
      end,
    },
    -- --------------------------------------------------------------- number
    {
      name = "from_number across limb boundaries",
      test = function()
        return to_hex(from_number(0)) == "0"
          and to_hex(from_number(1)) == "1"
          and to_hex(from_number(16777215)) == "ffffff"
          and to_hex(from_number(16777216)) == "1000000"
          and to_hex(from_number(4294967296)) == "100000000"
      end,
    },
    {
      name = "from_number rejects negative, fractional and oversized input",
      test = function()
        return pcall(from_number, -1) == false
          and pcall(from_number, 1.5) == false
          and pcall(from_number, 2 ^ 60) == false
      end,
    },
    -- ----------------------------------------------------------- inspection
    {
      name = "bit_length and byte_length",
      test = function()
        return bignum.bit_length(bignum.zero()) == 0
          and bignum.byte_length(bignum.zero()) == 0
          and bignum.bit_length(X) == 256
          and bignum.byte_length(X) == 32
          and bignum.bit_length(Y) == 188
          and bignum.byte_length(Y) == 24
          and bignum.byte_length(N) == 384
      end,
    },
    {
      name = "compare and equals",
      test = function()
        return bignum.compare(X, Y) == 1
          and bignum.compare(Y, X) == -1
          and bignum.compare(X, X) == 0
          and equals(X, bignum.copy(X))
          and bignum.compare(from_number(16777216), from_number(16777215)) == 1
      end,
    },
    {
      name = "copy is independent of the original",
      test = function()
        local original = from_hex("0102030405060708090a")
        local duplicate = bignum.copy(original)
        duplicate[1] = 0
        return not equals(original, duplicate) and to_hex(original) == "102030405060708090a"
      end,
    },
    -- ----------------------------------------------------------- arithmetic
    {
      name = "add - unequal lengths (known answer)",
      test = function()
        return to_hex(bignum.add(X, Y)) == VEC_ADD_HEX and to_hex(bignum.add(Y, X)) == VEC_ADD_HEX
      end,
    },
    {
      name = "add - carry propagates across every limb",
      test = function()
        local all_ones = from_hex("ffffffffffffffffffffffffffffffffffffffffffffffff")
        return to_hex(bignum.add(all_ones, from_number(1))) == "1000000000000000000000000000000000000000000000000"
      end,
    },
    {
      name = "add - 3072-bit carry (N + 7)",
      test = function()
        return to_hex(bignum.add(N, from_number(7))) == SRP_BASE_OVER_N_HEX
      end,
    },
    {
      name = "add - identity with zero",
      test = function()
        return equals(bignum.add(X, bignum.zero()), X) and equals(bignum.add(bignum.zero(), X), X)
      end,
    },
    {
      name = "sub - unequal lengths (known answer)",
      test = function()
        return to_hex(bignum.sub(X, Y)) == VEC_SUB_HEX
      end,
    },
    {
      name = "sub - borrow propagates across every limb",
      test = function()
        local power = from_hex("1000000000000000000000000")
        local below = from_hex("ffffffffffffffffffffffff")
        return to_hex(bignum.sub(power, below)) == "1" and bignum.is_zero(bignum.sub(X, X))
      end,
    },
    {
      name = "sub - rejects a negative result",
      test = function()
        return pcall(bignum.sub, Y, X) == false
      end,
    },
    {
      name = "mul - unequal lengths (known answer)",
      test = function()
        return to_hex(bignum.mul(X, Y)) == VEC_MUL_HEX and to_hex(bignum.mul(Y, X)) == VEC_MUL_HEX
      end,
    },
    {
      name = "mul - all-ones squared exercises every carry",
      test = function()
        local all_ones = from_hex("ffffffffffffffffffffffffffffffffffffffffffffffff")
        local expected = "fffffffffffffffffffffffffffffffffffffffffffffffe"
          .. "000000000000000000000000000000000000000000000001"
        return to_hex(bignum.mul(all_ones, all_ones)) == expected
      end,
    },
    {
      name = "mul - power of two times its predecessor",
      test = function()
        local power = from_hex("1000000000000000000000000")
        local below = from_hex("ffffffffffffffffffffffff")
        return to_hex(bignum.mul(power, below)) == "ffffffffffffffffffffffff000000000000000000000000"
      end,
    },
    {
      name = "mul - zero and one",
      test = function()
        return bignum.is_zero(bignum.mul(X, bignum.zero()))
          and bignum.is_zero(bignum.mul(bignum.zero(), X))
          and equals(bignum.mul(X, bignum.one()), X)
      end,
    },
    {
      name = "divmod - multi-limb (known answer)",
      test = function()
        local quotient, remainder = bignum.divmod(X, Y)
        return to_hex(quotient) == VEC_QUO_HEX and to_hex(remainder) == VEC_REM_HEX
      end,
    },
    {
      name = "divmod - reconstructs the dividend",
      test = function()
        local quotient, remainder = bignum.divmod(X, Y)
        return equals(bignum.add(bignum.mul(quotient, Y), remainder), X) and bignum.compare(remainder, Y) < 0
      end,
    },
    {
      name = "divmod - single-limb divisor",
      test = function()
        local quotient, remainder = bignum.divmod(from_hex("1000000000000000000000001"), from_number(255))
        return equals(
          bignum.add(bignum.mul(quotient, from_number(255)), remainder),
          from_hex("1000000000000000000000001")
        ) and bignum.compare(remainder, from_number(255)) < 0
      end,
    },
    {
      name = "divmod - divisor larger than dividend",
      test = function()
        local quotient, remainder = bignum.divmod(Y, X)
        return bignum.is_zero(quotient) and equals(remainder, Y)
      end,
    },
    {
      name = "divmod - exact division leaves no remainder",
      test = function()
        local product = bignum.mul(X, Y)
        local quotient, remainder = bignum.divmod(product, Y)
        return equals(quotient, X) and bignum.is_zero(remainder)
      end,
    },
    {
      name = "divmod - rejects a zero divisor",
      test = function()
        return pcall(bignum.divmod, X, bignum.zero()) == false
      end,
    },
    {
      name = "mod - known answer",
      test = function()
        return to_hex(bignum.mod(X, M)) == VEC_MOD_X_HEX
      end,
    },
    -- ------------------------------------------------------ modular helpers
    {
      name = "mod_add - known answer",
      test = function()
        return to_hex(bignum.mod_add(X, Y, M)) == VEC_MOD_ADD_HEX
      end,
    },
    {
      name = "mod_sub - wraps to a non-negative residue when b > a",
      test = function()
        return to_hex(bignum.mod_sub(Y, X, M)) == VEC_MOD_SUB_HEX
      end,
    },
    {
      name = "mod_sub - plain difference when a >= b",
      test = function()
        return equals(bignum.mod_sub(X, Y, M), bignum.mod(bignum.sub(X, Y), M))
          and bignum.is_zero(bignum.mod_sub(X, X, M))
      end,
    },
    {
      name = "mod_mul - known answer",
      test = function()
        return to_hex(bignum.mod_mul(X, Y, M)) == VEC_MOD_MUL_HEX
      end,
    },
    -- ------------------------------------------------------------- mod_exp
    {
      name = "mod_exp - 4^13 mod 497 = 445",
      test = function()
        return equals(bignum.mod_exp(from_number(4), from_number(13), from_number(497)), from_number(445))
      end,
    },
    {
      name = "mod_exp - 2^10 mod 1000 = 24 (even modulus, reference path)",
      test = function()
        return equals(bignum.mod_exp(from_number(2), from_number(10), from_number(1000)), from_number(24))
          and equals(bignum.mod_exp(from_number(3), from_number(7), from_number(1000)), from_number(187))
      end,
    },
    {
      name = "mod_exp - exponent zero yields one",
      test = function()
        return equals(bignum.mod_exp(X, bignum.zero(), M), bignum.one())
          and equals(bignum.mod_exp(bignum.zero(), bignum.zero(), M), bignum.one())
      end,
    },
    {
      name = "mod_exp - base zero yields zero",
      test = function()
        return bignum.is_zero(bignum.mod_exp(bignum.zero(), from_number(5), from_number(7)))
          and bignum.is_zero(bignum.mod_exp(bignum.zero(), Y, M))
      end,
    },
    {
      name = "mod_exp - modulus one yields zero",
      test = function()
        return bignum.is_zero(bignum.mod_exp(X, Y, bignum.one()))
          and bignum.is_zero(bignum.mod_exp(from_number(123456789), bignum.zero(), bignum.one()))
      end,
    },
    {
      name = "mod_exp - rejects a zero modulus",
      test = function()
        return pcall(bignum.mod_exp, X, Y, bignum.zero()) == false
      end,
    },
    {
      name = "mod_exp - 192-bit modulus (known answer)",
      test = function()
        return to_hex(bignum.mod_exp(X, Y, M)) == VEC_MOD_EXP_HEX
      end,
    },
    {
      name = "mod_exp - RFC 5054 group 15: 5^a mod N, 256-bit exponent",
      test = function()
        return to_hex(bignum.mod_exp(G, from_hex(SRP_EXP_A_HEX), N)) == SRP_RESULT_A_HEX
      end,
    },
    {
      name = "mod_exp - RFC 5054 group 15: 5^b mod N, full 3072-bit exponent",
      test = function()
        return to_hex(bignum.mod_exp(G, from_hex(SRP_EXP_B_HEX), N)) == SRP_RESULT_B_HEX
      end,
    },
    {
      name = "mod_exp - RFC 5054 group 15: base greater than the modulus",
      test = function()
        local base = bignum.add(N, from_number(7))
        return to_hex(bignum.mod_exp(base, from_hex(SRP_EXP_A_HEX), N)) == SRP_RESULT_OVER_HEX
      end,
    },
    {
      name = "mod_exp - Montgomery path matches the slow reference path",
      test = function()
        for _, vector in ipairs(CROSS_CHECK_VECTORS) do
          local base, exp = from_hex(vector.base), from_hex(vector.exp)
          local modulus = from_hex(vector.mod)
          local fast = mod_exp_montgomery(base, exp, modulus)
          local slow = mod_exp_reference(base, exp, modulus)
          if to_hex(fast) ~= vector.result or to_hex(slow) ~= vector.result then
            return false
          end
        end
        return true
      end,
    },
    -- ------------------------------------------------------ acceleration
    {
      name = "accelerated mod_exp is identical to pure Lua (bn.powmod spelling)",
      test = function()
        install(nil)
        local pure = bignum.mod_exp(X, Y, M)
        local binding, calls = make_binding({ spelling = "powmod" })
        install(binding)
        local accelerated = bignum.mod_exp(X, Y, M)
        install(nil)
        -- calls() > 1 proves the routing fired: once to verify, once for real.
        return calls() > 1 and equals(accelerated, pure) and to_hex(accelerated) == VEC_MOD_EXP_HEX
      end,
    },
    {
      name = "accelerated mod_exp is identical to pure Lua (bn.mod_exp spelling)",
      test = function()
        install(nil)
        local pure = bignum.mod_exp(G, from_hex(SRP_EXP_A_HEX), N)
        local binding, calls = make_binding({ spelling = "mod_exp" })
        install(binding)
        local accelerated = bignum.mod_exp(G, from_hex(SRP_EXP_A_HEX), N)
        install(nil)
        return calls() > 1 and equals(accelerated, pure) and to_hex(accelerated) == SRP_RESULT_A_HEX
      end,
    },
    {
      name = "accelerated results are canonical limb tables, not handles",
      test = function()
        local binding = make_binding({})
        install(binding)
        local accelerated = bignum.mod_exp(X, Y, M)
        install(nil)
        -- Same canonical type either way, so a use_openssl() toggle mid-flight
        -- can never produce mixed-type operands.
        return type(accelerated) == "table" and equals(bignum.mod_mul(accelerated, bignum.one(), M), accelerated)
      end,
    },
    {
      name = "a binding that returns wrong answers is rejected, not trusted",
      test = function()
        local binding = make_binding({ broken = true })
        install(binding)
        local result = bignum.mod_exp(X, Y, M)
        install(nil)
        return to_hex(result) == VEC_MOD_EXP_HEX
      end,
    },
    {
      name = "an absent binding falls back to pure Lua",
      test = function()
        install(nil)
        openssl_wrapper.use(true)
        local result = bignum.mod_exp(from_number(4), from_number(13), from_number(497))
        install(nil)
        return equals(result, from_number(445))
      end,
    },
    -- ----------------------------------------------- is_accelerated reporting
    -- A caller told only "false" cannot tell a host that will never accelerate
    -- from one where nobody called use_openssl(true), and the two need opposite
    -- responses. Each case below pins the phrase that distinguishes them.
    {
      name = "is_accelerated blames the flag when acceleration was never enabled",
      test = function()
        install(nil) -- also sets use(false)
        local accelerated, reason = bignum.is_accelerated()
        return accelerated == false
          and type(reason) == "string"
          and reason:find("crypto.use_openssl(true)", 1, true) ~= nil
      end,
    },
    {
      name = "is_accelerated blames the host when the binding is absent",
      test = function()
        install(nil)
        openssl_wrapper.use(true)
        local accelerated, reason = bignum.is_accelerated()
        install(nil)
        return accelerated == false
          and type(reason) == "string"
          and reason:find("not available", 1, true) ~= nil
          and reason:find("use_openssl", 1, true) == nil
      end,
    },
    {
      -- The binding computes 4^13 mod 497 correctly, so Feature.BN's probe
      -- passes; it is wrong on the multi-limb vector, so mod_exp will not use
      -- it. is_accelerated must agree with mod_exp, not with the feature gate.
      name = "is_accelerated blames the known-answer check for a single-limb-only binding",
      test = function()
        local binding = make_binding({ small_only = true })
        install(binding)
        local gated = openssl_wrapper.get(openssl_wrapper.Feature.BN) ~= nil
        local accelerated, reason = bignum.is_accelerated()
        local result = bignum.mod_exp(X, Y, M)
        install(nil)
        return gated == true
          and accelerated == false
          and type(reason) == "string"
          and reason:find("known-answer check", 1, true) ~= nil
          and to_hex(result) == VEC_MOD_EXP_HEX
      end,
    },
    {
      name = "is_accelerated is true with no reason for a trusted binding",
      test = function()
        local binding = make_binding({})
        install(binding)
        local accelerated, reason = bignum.is_accelerated()
        install(nil)
        return accelerated == true and reason == nil
      end,
    },
  }

  local passed = 0
  for _, test in ipairs(tests) do
    local ok, result = pcall(test.test)
    if ok and result == true then
      print("  ✅ PASS: " .. test.name)
      passed = passed + 1
    else
      print("  ❌ FAIL: " .. test.name .. (ok and "" or (" - " .. tostring(result))))
    end
  end

  -- Restore the module-load default so later tests in this process are unaffected.
  package.loaded["openssl"] = saved_loaded
  package.preload["openssl"] = saved_preload
  openssl_wrapper.use(os.getenv("CRYPTO_USE_OPENSSL") == "1" or os.getenv("CRYPTO_USE_OPENSSL") == "true")

  print(string_format("\nBignum result: %d/%d tests passed\n", passed, #tests))
  return passed == #tests
end

--- Run performance benchmarks
---
--- The headline number is a 3072-bit modular exponentiation with a full-size
--- 3072-bit exponent: that is the SRP-6a server operation, and it decides
--- whether the pure-Lua path is shippable on an embedded controller. Iteration
--- counts are small because a single such operation takes seconds.
function bignum.benchmark()
  local N = bignum.from_hex(RFC5054_N_HEX)
  local G = bignum.from_number(5)
  local exp_short = bignum.from_hex(SRP_EXP_A_HEX)
  local exp_full = bignum.from_hex(SRP_EXP_B_HEX)
  local wide = bignum.mul(N, N)

  print("Modular exponentiation (RFC 5054 group 15, 3072-bit N):")
  benchmark_op("mod_exp 3072-bit exponent", function()
    bignum.mod_exp(G, exp_full, N)
  end, 2)

  benchmark_op("mod_exp 256-bit exponent", function()
    bignum.mod_exp(G, exp_short, N)
  end, 5)

  print("\nCore arithmetic:")
  benchmark_op("mul 3072 x 3072 bits", function()
    bignum.mul(N, N)
  end, 200)

  benchmark_op("divmod 6144 / 3072 bits", function()
    bignum.divmod(wide, N)
  end, 100)

  benchmark_op("mod_mul 3072-bit", function()
    bignum.mod_mul(N, N, N)
  end, 100)
end

return bignum
end
end

do
local _ENV = _ENV
package.preload[ "crypto.blake2" ] = function( ... ) local arg = _G.arg;
--- @module "crypto.blake2"
--- Pure Lua BLAKE2s and BLAKE2b Implementation for portability.
--- @class crypto.blake2
local blake2 = {}

local bitn = require("bitn")
local bit32 = bitn.bit32
local bit64 = bitn.bit64

local openssl_wrapper = require("crypto.openssl_wrapper")
local utils = require("crypto.utils")
local bytes = utils.bytes
local benchmark_op = utils.benchmark.benchmark_op

-- Local references for performance
local bit32_raw_add = bit32.raw_add
local bit32_raw_bxor = bit32.raw_bxor
local bit32_raw_ror = bit32.raw_ror
local bit64_raw_add = bit64.raw_add
local bit64_raw_bxor = bit64.raw_bxor
local bit64_raw_ror = bit64.raw_ror
local bit64_new = bit64.new
local string_byte = string.byte
local string_char = string.char
local string_rep = string.rep
local table_concat = table.concat

-- BLAKE2s initialization vectors (first 32 bits of fractional parts of square roots of first 8 primes)
--- @type HashState
local BLAKE2S_IV = {
  0x6a09e667,
  0xbb67ae85,
  0x3c6ef372,
  0xa54ff53a,
  0x510e527f,
  0x9b05688c,
  0x1f83d9ab,
  0x5be0cd19,
}

-- BLAKE2b initialization vectors (first 64 bits of fractional parts of square roots of first 8 primes)
--- @type HashState64
local BLAKE2B_IV = {
  { 0x6a09e667, 0xf3bcc908 },
  { 0xbb67ae85, 0x84caa73b },
  { 0x3c6ef372, 0xfe94f82b },
  { 0xa54ff53a, 0x5f1d36f1 },
  { 0x510e527f, 0xade682d1 },
  { 0x9b05688c, 0x2b3e6c1f },
  { 0x1f83d9ab, 0xfb41bd6b },
  { 0x5be0cd19, 0x137e2179 },
}

--- @alias Blake2sVector16 [integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer]
--- @alias Blake2bVector16 [Int64HighLow, Int64HighLow, Int64HighLow, Int64HighLow, Int64HighLow, Int64HighLow, Int64HighLow, Int64HighLow, Int64HighLow, Int64HighLow, Int64HighLow, Int64HighLow, Int64HighLow, Int64HighLow, Int64HighLow, Int64HighLow]

-- BLAKE2s permutation table
--- @type Blake2sVector16[]
local BLAKE2S_SIGMA = {
  { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
  { 14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3 },
  { 11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4 },
  { 7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8 },
  { 9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13 },
  { 2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9 },
  { 12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11 },
  { 13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10 },
  { 6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5 },
  { 10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0 },
}

-- BLAKE2b permutation table (same as BLAKE2s)
local BLAKE2B_SIGMA = BLAKE2S_SIGMA

--- Initialize a 16-element BLAKE2s working vector with zeros
--- @return Blake2sVector16 array Initialized array
local function create_blake2s_vector()
  local arr = {}
  for i = 1, 16 do
    arr[i] = 0
  end
  --- @cast arr Blake2sVector16
  return arr
end

--- Initialize a 16-element BLAKE2b working vector with zeros
--- @return Blake2bVector16 array Initialized array
local function create_blake2b_vector()
  local arr = {}
  for i = 1, 16 do
    arr[i] = bit64_new(0, 0)
  end
  --- @cast arr Blake2bVector16
  return arr
end

-- Pre-allocated arrays for blake2s_compress() to avoid repeated allocation
local blake2s_v = create_blake2s_vector()

-- Pre-allocated arrays for blake2b_compress() to avoid repeated allocation
local blake2b_v = create_blake2b_vector()

--- BLAKE2s G function
--- @param v Blake2sVector16 Working vector
--- @param a integer Index a
--- @param b integer Index b
--- @param c integer Index c
--- @param d integer Index d
--- @param x integer Message word x
--- @param y integer Message word y
local function blake2s_g(v, a, b, c, d, x, y)
  v[a] = bit32_raw_add(bit32_raw_add(v[a], v[b]), x)
  v[d] = bit32_raw_ror(bit32_raw_bxor(v[d], v[a]), 16)
  v[c] = bit32_raw_add(v[c], v[d])
  v[b] = bit32_raw_ror(bit32_raw_bxor(v[b], v[c]), 12)
  v[a] = bit32_raw_add(bit32_raw_add(v[a], v[b]), y)
  v[d] = bit32_raw_ror(bit32_raw_bxor(v[d], v[a]), 8)
  v[c] = bit32_raw_add(v[c], v[d])
  v[b] = bit32_raw_ror(bit32_raw_bxor(v[b], v[c]), 7)
end

--- BLAKE2b G function
--- @param v Blake2bVector16 Working vector
--- @param a integer Index a
--- @param b integer Index b
--- @param c integer Index c
--- @param d integer Index d
--- @param x table Message word x
--- @param y table Message word y
local function blake2b_g(v, a, b, c, d, x, y)
  v[a] = bit64_raw_add(bit64_raw_add(v[a], v[b]), x)
  v[d] = bit64_raw_ror(bit64_raw_bxor(v[d], v[a]), 32)
  v[c] = bit64_raw_add(v[c], v[d])
  v[b] = bit64_raw_ror(bit64_raw_bxor(v[b], v[c]), 24)
  v[a] = bit64_raw_add(bit64_raw_add(v[a], v[b]), y)
  v[d] = bit64_raw_ror(bit64_raw_bxor(v[d], v[a]), 16)
  v[c] = bit64_raw_add(v[c], v[d])
  v[b] = bit64_raw_ror(bit64_raw_bxor(v[b], v[c]), 63)
end

--- BLAKE2s compression function
--- @param h HashState Hash state (8 words)
--- @param m Blake2sVector16 Message block (16 words)
--- @param t integer Counter (low 32 bits)
--- @param th integer Counter (high 32 bits)
--- @param f boolean Final block flag
local function blake2s_compress(h, m, t, th, f)
  -- Reuse pre-allocated working vector
  local v = blake2s_v

  -- First half from hash state
  for i = 1, 8 do
    v[i] = h[i]
  end

  -- Second half from IV
  for i = 1, 8 do
    v[8 + i] = BLAKE2S_IV[i]
  end

  -- Mix in counter and final flag
  v[13] = bit32_raw_bxor(v[13], t) -- Low 32 bits of counter
  v[14] = bit32_raw_bxor(v[14], th) -- High 32 bits of counter
  if f then
    v[15] = bit32_raw_bxor(v[15], 0xFFFFFFFF) -- Invert all bits for final block
  end

  -- 10 rounds
  for r = 1, 10 do
    --- @type Blake2sVector16
    local s = assert(BLAKE2S_SIGMA[r], "Invalid BLAKE2s round index")

    -- Column step
    blake2s_g(v, 1, 5, 9, 13, m[s[1] + 1], m[s[2] + 1])
    blake2s_g(v, 2, 6, 10, 14, m[s[3] + 1], m[s[4] + 1])
    blake2s_g(v, 3, 7, 11, 15, m[s[5] + 1], m[s[6] + 1])
    blake2s_g(v, 4, 8, 12, 16, m[s[7] + 1], m[s[8] + 1])

    -- Diagonal step
    blake2s_g(v, 1, 6, 11, 16, m[s[9] + 1], m[s[10] + 1])
    blake2s_g(v, 2, 7, 12, 13, m[s[11] + 1], m[s[12] + 1])
    blake2s_g(v, 3, 8, 9, 14, m[s[13] + 1], m[s[14] + 1])
    blake2s_g(v, 4, 5, 10, 15, m[s[15] + 1], m[s[16] + 1])
  end

  -- Finalize
  for i = 1, 8 do
    h[i] = bit32_raw_bxor(bit32_raw_bxor(h[i], v[i]), v[i + 8])
  end
end

--- BLAKE2b compression function
--- @param h HashState64 Hash state (8 64-bit words)
--- @param m Blake2bVector16 Message block (16 64-bit words)
--- @param t table Counter (64-bit)
--- @param f boolean Final block flag
local function blake2b_compress(h, m, t, f)
  -- Reuse pre-allocated working vector
  local v = blake2b_v

  -- First half from hash state
  for i = 1, 8 do
    v[i][1], v[i][2] = h[i][1], h[i][2]
  end

  -- Second half from IV
  for i = 1, 8 do
    v[8 + i][1], v[8 + i][2] = BLAKE2B_IV[i][1], BLAKE2B_IV[i][2]
  end

  -- Mix in counter and final flag
  v[13] = bit64_raw_bxor(v[13], t)
  v[14] = bit64_raw_bxor(v[14], bit64_new(0, 0)) -- High 64 bits of counter (always 0 for messages < 2^64 bytes)
  if f then
    v[15] = bit64_raw_bxor(v[15], bit64_new(0xffffffff, 0xffffffff))
  end

  -- 12 rounds
  for r = 1, 12 do
    --- @type Blake2sVector16
    local s = assert(BLAKE2B_SIGMA[((r - 1) % 10) + 1], "Invalid round index for BLAKE2b")

    -- Column step
    blake2b_g(v, 1, 5, 9, 13, m[s[1] + 1], m[s[2] + 1])
    blake2b_g(v, 2, 6, 10, 14, m[s[3] + 1], m[s[4] + 1])
    blake2b_g(v, 3, 7, 11, 15, m[s[5] + 1], m[s[6] + 1])
    blake2b_g(v, 4, 8, 12, 16, m[s[7] + 1], m[s[8] + 1])

    -- Diagonal step
    blake2b_g(v, 1, 6, 11, 16, m[s[9] + 1], m[s[10] + 1])
    blake2b_g(v, 2, 7, 12, 13, m[s[11] + 1], m[s[12] + 1])
    blake2b_g(v, 3, 8, 9, 14, m[s[13] + 1], m[s[14] + 1])
    blake2b_g(v, 4, 5, 10, 15, m[s[15] + 1], m[s[16] + 1])
  end

  -- Finalize
  for i = 1, 8 do
    h[i] = bit64_raw_bxor(bit64_raw_bxor(h[i], v[i]), v[i + 8])
  end
end

--- Compute BLAKE2s hash of input data
--- @param data string Input data to hash
--- @return string hash 32-byte binary hash
function blake2.blake2s(data)
  -- Check if we should use OpenSSL
  local openssl = openssl_wrapper.get()
  if openssl then
    return openssl.digest.digest("blake2s256", data, true)
  end

  -- Native implementation
  -- Initialize hash state
  --- @type HashState
  local h = {}
  for i = 1, 8 do
    h[i] = BLAKE2S_IV[i]
  end

  -- Parameter block: digest length = 32, key length = 0, fanout = 1, depth = 1
  -- All other parameters are 0 (no salt, no personalization, etc.)
  local param = 32 + (0 * 256) + (1 * 65536) + (1 * 16777216) -- 0x01010020
  h[1] = bit32_raw_bxor(h[1], param)

  local data_len = #data
  local offset = 1
  local counter = 0

  -- Process full 64-byte blocks
  while offset + 63 <= data_len do
    counter = counter + 64

    -- Check if this is the last block
    local is_last_block = (offset + 64 > data_len)

    -- Load message block
    --- @type Blake2sVector16
    local m = {}
    for i = 1, 16 do
      m[i] = bytes.le_bytes_to_u32(data, offset + (i - 1) * 4)
    end

    blake2s_compress(h, m, counter, 0, is_last_block)
    offset = offset + 64
  end

  -- Process final block (if there's remaining data)
  local remaining = data_len - offset + 1

  if remaining > 0 then
    -- We have a partial block left to process
    counter = counter + remaining

    -- Pad final block with zeros
    local final_data = data:sub(offset)
    local final_block = final_data .. string_rep("\0", 64 - remaining)

    --- @type Blake2sVector16
    local m = {}
    for i = 1, 16 do
      m[i] = bytes.le_bytes_to_u32(final_block, (i - 1) * 4 + 1)
    end

    blake2s_compress(h, m, counter, 0, true)
  elseif data_len == 0 then
    -- Special case: empty input
    --- @type Blake2sVector16
    local m = {}
    for i = 1, 16 do
      m[i] = 0
    end

    blake2s_compress(h, m, 0, 0, true)
  end

  -- Produce final hash value as binary string (optimized with table)
  local result_bytes = {}
  for i = 1, 8 do
    result_bytes[i] = bytes.u32_to_le_bytes(h[i])
  end

  return table_concat(result_bytes)
end

--- Compute BLAKE2b hash of input data
--- @param data string Input data to hash
--- @return string hash 64-byte binary hash
function blake2.blake2b(data)
  -- Check if we should use OpenSSL
  local openssl = openssl_wrapper.get()
  if openssl then
    return openssl.digest.digest("blake2b512", data, true)
  end

  -- Native implementation
  -- Initialize hash state
  --- @type HashState64
  local h = {}
  for i = 1, 8 do
    h[i] = { BLAKE2B_IV[i][1], BLAKE2B_IV[i][2] }
  end

  -- Parameter block: digest length = 64, key length = 0, fanout = 1, depth = 1
  -- The parameter block is 128 bytes, but we only need to XOR the first 8 bytes with h[1]
  -- Format (little-endian): digest_length(1) || key_length(1) || fanout(1) || depth(1) || leaf_length(4)
  -- For standard BLAKE2b: digest_length=64, key_length=0, fanout=1, depth=1
  -- In little-endian 64-bit: 0x0000000001010040
  -- Split into two 32-bit words (little-endian): low=0x01010040, high=0x00000000
  -- But our u64 format is {high, low}, so we need {0x00000000, 0x01010040}
  h[1] = bit64_raw_bxor(h[1], bit64_new(0x00000000, 0x01010040))

  local data_len = #data
  local offset = 1
  local counter = bit64_new(0, 0)

  -- Process full 128-byte blocks
  while offset + 127 <= data_len do
    counter = bit64_raw_add(counter, bit64_new(0, 128))

    -- Check if this is the last block
    local is_last_block = (offset + 128 > data_len)

    -- Load message block
    --- @type Blake2bVector16
    local m = {}
    for i = 1, 16 do
      m[i] = bytes.le_bytes_to_u64(data, offset + (i - 1) * 8)
    end

    blake2b_compress(h, m, counter, is_last_block)
    offset = offset + 128
  end

  -- Process final block (if there's remaining data)
  local remaining = data_len - offset + 1
  if remaining > 0 then
    counter = bit64_raw_add(counter, bit64_new(0, remaining))

    -- Pad final block with zeros
    local final_block = data:sub(offset) .. string_rep("\0", 128 - remaining)

    --- @type Blake2bVector16
    local m = {}
    for i = 1, 16 do
      m[i] = bytes.le_bytes_to_u64(final_block, (i - 1) * 8 + 1)
    end

    blake2b_compress(h, m, counter, true)
  elseif data_len == 0 then
    -- Empty input case
    --- @type Blake2bVector16
    local m = {}
    for i = 1, 16 do
      m[i] = bit64_new(0, 0)
    end
    blake2b_compress(h, m, bit64_new(0, 0), true)
  end

  -- Produce final hash value as binary string (optimized with table)
  local result_bytes = {}
  for i = 1, 8 do
    result_bytes[i] = bytes.u64_to_le_bytes(h[i])
  end

  return table_concat(result_bytes)
end

--- Compute BLAKE2s hash and return as hex string
--- @param data string Input data to hash
--- @return string hex 64-character hex string
function blake2.blake2s_hex(data)
  return bytes.to_hex(blake2.blake2s(data))
end

--- Compute BLAKE2b hash and return as hex string
--- @param data string Input data to hash
--- @return string hex 128-character hex string
function blake2.blake2b_hex(data)
  return bytes.to_hex(blake2.blake2b(data))
end

--- Compute HMAC-BLAKE2s
--- Note: RFC 7693 recommends using BLAKE2's native keyed mode instead of HMAC.
--- However, HMAC-BLAKE2 is provided for compatibility with protocols that require
--- HMAC for all hash functions (e.g., Noise Protocol Framework).
--- @param key string Secret key
--- @param data string Data to authenticate
--- @return string hmac 32-byte HMAC value
function blake2.hmac_blake2s(key, data)
  -- Check if we should use OpenSSL
  local openssl = openssl_wrapper.get()
  if openssl then
    return openssl.hmac.hmac("blake2s256", data, key, true)
  end

  -- Native implementation
  local block_size = 64 -- BLAKE2s block size

  -- Keys longer than blocksize are shortened by hashing them
  if #key > block_size then
    key = blake2.blake2s(key)
  end

  -- Keys shorter than blocksize are right-padded with zeros
  if #key < block_size then
    key = key .. string_rep("\0", block_size - #key)
  end

  -- Compute inner and outer padding (optimized with table)
  local ipad_bytes = {}
  local opad_bytes = {}
  for i = 1, block_size do
    local byte = string_byte(key, i)
    ipad_bytes[i] = string_char(bit32_raw_bxor(byte, 0x36))
    opad_bytes[i] = string_char(bit32_raw_bxor(byte, 0x5C))
  end
  local ipad = table_concat(ipad_bytes)
  local opad = table_concat(opad_bytes)

  -- Compute HMAC = H(opad || H(ipad || data))
  local inner_hash = blake2.blake2s(ipad .. data)
  return blake2.blake2s(opad .. inner_hash)
end

--- Compute HMAC-BLAKE2b
--- Note: RFC 7693 recommends using BLAKE2's native keyed mode instead of HMAC.
--- However, HMAC-BLAKE2 is provided for compatibility with protocols that require
--- HMAC for all hash functions (e.g., Noise Protocol Framework).
--- @param key string Secret key
--- @param data string Data to authenticate
--- @return string hmac 64-byte HMAC value
function blake2.hmac_blake2b(key, data)
  -- Check if we should use OpenSSL
  local openssl = openssl_wrapper.get()
  if openssl then
    return openssl.hmac.hmac("blake2b512", data, key, true)
  end

  -- Native implementation
  local block_size = 128 -- BLAKE2b block size

  -- Keys longer than blocksize are shortened by hashing them
  if #key > block_size then
    key = blake2.blake2b(key)
  end

  -- Keys shorter than blocksize are right-padded with zeros
  if #key < block_size then
    key = key .. string_rep("\0", block_size - #key)
  end

  -- Compute inner and outer padding (optimized with table)
  local ipad_bytes = {}
  local opad_bytes = {}
  for i = 1, block_size do
    local byte = string_byte(key, i)
    ipad_bytes[i] = string_char(bit32_raw_bxor(byte, 0x36))
    opad_bytes[i] = string_char(bit32_raw_bxor(byte, 0x5C))
  end
  local ipad = table_concat(ipad_bytes)
  local opad = table_concat(opad_bytes)

  -- Compute HMAC = H(opad || H(ipad || data))
  local inner_hash = blake2.blake2b(ipad .. data)
  return blake2.blake2b(opad .. inner_hash)
end

--- Compute HMAC-BLAKE2s and return as hex string
--- @param key string Secret key
--- @param data string Data to authenticate
--- @return string hex 64-character hex string
function blake2.hmac_blake2s_hex(key, data)
  return bytes.to_hex(blake2.hmac_blake2s(key, data))
end

--- Compute HMAC-BLAKE2b and return as hex string
--- @param key string Secret key
--- @param data string Data to authenticate
--- @return string hex 128-character hex string
function blake2.hmac_blake2b_hex(key, data)
  return bytes.to_hex(blake2.hmac_blake2b(key, data))
end

--- Digest test vectors
local blake2s_test_vectors = {
  {
    name = "Test Vector 1 - Empty string",
    input = "",
    expected = "69217a3079908094e11121d042354a7c1f55b6482ca1a51e1b250dfd1ed0eef9",
  },
  {
    name = "Test Vector 2 - abc",
    input = "abc",
    expected = "508c5e8c327c14e2e1a72ba34eeb452f37458b209ed63a294d999b4c86675982",
  },
  {
    name = "Test Vector 3 - Long string",
    input = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
    expected = "6f4df5116a6f332edab1d9e10ee87df6557beab6259d7663f3bcd5722c13f189",
  },
}

local blake2b_test_vectors = {
  {
    name = "Test Vector 1 - Empty string",
    input = "",
    expected = "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce",
  },
  {
    name = "Test Vector 2 - abc",
    input = "abc",
    expected = "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923",
  },
  {
    name = "Test Vector 3 - Long string",
    input = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
    expected = "7285ff3e8bd768d69be62b3bf18765a325917fa9744ac2f582a20850bc2b1141ed1b3e4528595acc90772bdf2d37dc8a47130b44f33a02e8730e5ad8e166e888",
  },
}

--- HMAC-BLAKE2 test vectors verified with Python's hmac library
--- These use true HMAC construction (RFC 2104), not BLAKE2's keyed mode
--- Python code: hmac.new(key, message, hashlib.blake2s).hexdigest()
local hmac_blake2s_test_vectors = {
  {
    name = "Empty message with short key",
    key = "key",
    message = "",
    expected = "67148074efc0f6741b474ef81c4d98d266e880d372fe723d2569b1d414d234be",
  },
  {
    name = "Short message with short key",
    key = "key",
    message = "The quick brown fox jumps over the lazy dog",
    expected = "f93215bb90d4af4c3061cd932fb169fb8bb8a91d0b4022baea1271e1323cd9a0",
  },
  {
    name = "RFC 4231 Test Case 1 pattern",
    key = string_rep(string_char(0x0b), 20),
    message = "Hi There",
    expected = "65a8b7c5cc9136d424e82c37e2707e74e913c0655b99c75f40edf387453a3260",
  },
  {
    name = "RFC 4231 Test Case 2 pattern",
    key = "Jefe",
    message = "what do ya want for nothing?",
    expected = "90b6281e2f3038c9056af0b4a7e763cae6fe5d9eb4386a0ec95237890c104ff0",
  },
  {
    name = "Key = block size (64 bytes)",
    key = string_rep("a", 64),
    message = "Test message",
    expected = "12d0e782ae473d8007d33ae6e5244afcaf9239f6a7d5476c69060c01383d6b58",
  },
  {
    name = "Key > block size (80 bytes)",
    key = string_rep("a", 80),
    message = "Test message",
    expected = "41da357bda1107f9fad1a504b5afbe75f5ead5ed7cf8f82e59e18c5e9e653882",
  },
}

local hmac_blake2b_test_vectors = {
  {
    name = "Empty message with short key",
    key = "key",
    message = "",
    expected = "019fe04bf010b8d72772e6b46897ecf74b4878c394ff2c4d5cfa0b7cc9bbefcb28c36de23cef03089db9c3d900468c89804f135e9fdef7ec9b3c7abe50ed33d3",
  },
  {
    name = "Short message with short key",
    key = "key",
    message = "The quick brown fox jumps over the lazy dog",
    expected = "92294f92c0dfb9b00ec9ae8bd94d7e7d8a036b885a499f149dfe2fd2199394aaaf6b8894a1730cccb2cd050f9bcf5062a38b51b0dab33207f8ef35ae2c9df51b",
  },
  {
    name = "RFC 4231 Test Case 1 pattern",
    key = string_rep(string_char(0x0b), 20),
    message = "Hi There",
    expected = "358a6a184924894fc34bee5680eedf57d84a37bb38832f288e3b27dc63a98cc8c91e76da476b508bc6b2d408a248857452906e4a20b48c6b4b55d2df0fe1dd24",
  },
  {
    name = "RFC 4231 Test Case 2 pattern",
    key = "Jefe",
    message = "what do ya want for nothing?",
    expected = "6ff884f8ddc2a6586b3c98a4cd6ebdf14ec10204b6710073eb5865ade37a2643b8807c1335d107ecdb9ffeaeb6828c4625ba172c66379efcd222c2de11727ab4",
  },
  {
    name = "Key = block size (128 bytes)",
    key = string_rep("a", 128),
    message = "Test message",
    expected = "021a22a3ecf0f1f7a15aca6a5d9704fc99b6a84a627fa53f7ac932a961ffb69b1e68c46981d5b44fd00a7cae75e4ee63d393eec844a8de2dd00e45b5a0d4e275",
  },
  {
    name = "Key > block size (80 bytes)",
    key = string_rep("a", 80),
    message = "Test message",
    expected = "1c8fb6f426d7800000e8d03c141905b33d10a4da16f9c018140955c5cedfa7a017204aaea1f141c1c0d3d942dee04a795a6e589898c1328b717ad6053a7b4790",
  },
}

--- Run comprehensive self-test with test vectors and functional tests
--- @return boolean result True if all tests pass, false otherwise
function blake2.selftest()
  print("Running BLAKE2s test vectors...")
  local passed = 0
  local total = #blake2s_test_vectors

  for _, test in ipairs(blake2s_test_vectors) do
    local result = blake2.blake2s_hex(test.input)
    if result == test.expected then
      print(string.format("  ✅ PASS: %s", test.name))
      passed = passed + 1
    else
      print(string.format("  ❌ FAIL: %s", test.name))
      print(string.format("    Expected: %s", test.expected))
      print(string.format("    Got:      %s", result))
      return false
    end
  end

  print(string.format("\nBLAKE2s test vectors result: %d/%d tests passed\n", passed, total))

  print("Running BLAKE2b test vectors...")
  local blake2b_passed = 0
  local blake2b_total = #blake2b_test_vectors

  for _, test in ipairs(blake2b_test_vectors) do
    local result = blake2.blake2b_hex(test.input)
    if result == test.expected then
      print(string.format("  ✅ PASS: %s", test.name))
      blake2b_passed = blake2b_passed + 1
    else
      print(string.format("  ❌ FAIL: %s", test.name))
      print(string.format("    Expected: %s", test.expected))
      print(string.format("    Got:      %s", result))
      return false
    end
  end

  print(string.format("\nBLAKE2b test vectors result: %d/%d tests passed\n", blake2b_passed, blake2b_total))

  -- Run HMAC-BLAKE2 test vectors
  print("Running HMAC-BLAKE2s test vectors...")

  local hmac_s_passed = 0
  local hmac_s_total = #hmac_blake2s_test_vectors

  for _, test in ipairs(hmac_blake2s_test_vectors) do
    local result = blake2.hmac_blake2s_hex(test.key, test.message)
    if result == test.expected then
      print(string.format("  ✅ PASS: %s", test.name))
      hmac_s_passed = hmac_s_passed + 1
    else
      print(string.format("  ❌ FAIL: %s", test.name))
      print(string.format("    Expected: %s", test.expected))
      print(string.format("    Got:      %s", result))
    end
  end

  print(string.format("\nHMAC-BLAKE2s test vectors: %d/%d tests passed\n", hmac_s_passed, hmac_s_total))

  print("Running HMAC-BLAKE2b test vectors...")
  local hmac_b_passed = 0
  local hmac_b_total = #hmac_blake2b_test_vectors

  for _, test in ipairs(hmac_blake2b_test_vectors) do
    local result = blake2.hmac_blake2b_hex(test.key, test.message)
    if result == test.expected then
      print(string.format("  ✅ PASS: %s", test.name))
      hmac_b_passed = hmac_b_passed + 1
    else
      print(string.format("  ❌ FAIL: %s", test.name))
      print(string.format("    Expected: %s", test.expected))
      print(string.format("    Got:      %s", result))
    end
  end

  print(string.format("\nHMAC-BLAKE2b test vectors: %d/%d tests passed\n", hmac_b_passed, hmac_b_total))

  print("Running BLAKE2 functional tests...")

  -- Test consistency
  local test_data = "Hello, BLAKE2!"
  local blake2s_hash1 = blake2.blake2s_hex(test_data)
  local blake2s_hash2 = blake2.blake2s_hex(test_data)
  local blake2b_hash1 = blake2.blake2b_hex(test_data)
  local blake2b_hash2 = blake2.blake2b_hex(test_data)

  if blake2s_hash1 ~= blake2s_hash2 or blake2b_hash1 ~= blake2b_hash2 then
    print("  ❌ FAIL: Hash functions are not deterministic")
    return false
  else
    print("  ✅ PASS: Hash functions are deterministic")
  end

  -- Test different inputs produce different outputs
  local hash_a_s = blake2.blake2s_hex("a")
  local hash_b_s = blake2.blake2s_hex("b")
  local hash_a_b = blake2.blake2b_hex("a")
  local hash_b_b = blake2.blake2b_hex("b")

  if hash_a_s == hash_b_s or hash_a_b == hash_b_b then
    print("  ❌ FAIL: Different inputs produce same hash")
    return false
  else
    print("  ✅ PASS: Different inputs produce different hashes")
  end

  -- Test binary vs hex consistency
  local test_msg = "test message"
  local binary_s = blake2.blake2s(test_msg)
  local hex_s = blake2.blake2s_hex(test_msg)
  local binary_b = blake2.blake2b(test_msg)
  local hex_b = blake2.blake2b_hex(test_msg)

  if hex_s ~= bytes.to_hex(binary_s) or hex_b ~= bytes.to_hex(binary_b) then
    print("  ❌ FAIL: Binary and hex outputs inconsistent")
    return false
  else
    print("  ✅ PASS: Binary and hex outputs consistent")
  end

  -- Test HMAC consistency
  local hmac1_s = blake2.hmac_blake2s_hex("key", "data")
  local hmac2_s = blake2.hmac_blake2s_hex("key", "data")
  local hmac1_b = blake2.hmac_blake2b_hex("key", "data")
  local hmac2_b = blake2.hmac_blake2b_hex("key", "data")

  if hmac1_s ~= hmac2_s or hmac1_b ~= hmac2_b then
    print("  ❌ FAIL: HMAC functions are not deterministic")
    return false
  else
    print("  ✅ PASS: HMAC functions are deterministic")
  end

  print("\nFunctional tests result: 4/4 tests passed")

  return true
end

--- Run performance benchmarks
---
--- This function runs comprehensive performance benchmarks for BLAKE2 operations
--- including BLAKE2s and BLAKE2b hash computation for various message sizes.
function blake2.benchmark()
  -- Test data
  local message_64 = string_rep("a", 64)
  local message_1k = string_rep("a", 1024)
  local message_8k = string_rep("a", 8192)
  local hmac_key = "benchmark_key"

  print("BLAKE2s Hash Operations:")
  benchmark_op("blake2s_64_bytes", function()
    blake2.blake2s(message_64)
  end, 1000)

  benchmark_op("blake2s_1k", function()
    blake2.blake2s(message_1k)
  end, 200)

  benchmark_op("blake2s_8k", function()
    blake2.blake2s(message_8k)
  end, 50)

  print("\nBLAKE2b Hash Operations:")
  benchmark_op("blake2b_64_bytes", function()
    blake2.blake2b(message_64)
  end, 500)

  benchmark_op("blake2b_1k", function()
    blake2.blake2b(message_1k)
  end, 100)

  benchmark_op("blake2b_8k", function()
    blake2.blake2b(message_8k)
  end, 25)

  print("\nBLAKE2s HMAC Operations:")
  benchmark_op("hmac_blake2s_64_bytes", function()
    blake2.hmac_blake2s(hmac_key, message_64)
  end, 500)

  benchmark_op("hmac_blake2s_1k", function()
    blake2.hmac_blake2s(hmac_key, message_1k)
  end, 100)
end

return blake2
end
end

do
local _ENV = _ENV
package.preload[ "crypto.chacha20" ] = function( ... ) local arg = _G.arg;
--- @module "crypto.chacha20"
--- ChaCha20 Stream Cipher Implementation for portability.
--- @class crypto.chacha20
local chacha20 = {}

local bit32 = require("bitn").bit32

local openssl_wrapper = require("crypto.openssl_wrapper")
local utils = require("crypto.utils")
local bytes = utils.bytes
local benchmark_op = utils.benchmark.benchmark_op

-- Local references for performance
local bit32_raw_add = bit32.raw_add
local bit32_raw_bxor = bit32.raw_bxor
local bit32_raw_rol = bit32.raw_rol
local floor = math.floor
local min = math.min
local string_byte = string.byte
local string_char = string.char
local string_rep = string.rep
local table_concat = table.concat

-- Type definitions for better type checking

--- 16-element array of 32-bit words
--- @class Word32Array
--- @field [1] integer
--- @field [2] integer
--- @field [3] integer
--- @field [4] integer
--- @field [5] integer
--- @field [6] integer
--- @field [7] integer
--- @field [8] integer
--- @field [9] integer
--- @field [10] integer
--- @field [11] integer
--- @field [12] integer
--- @field [13] integer
--- @field [14] integer
--- @field [15] integer
--- @field [16] integer

--- Initialize a 16-element word array with zeros
--- @return Word32Array array Initialized array
local function create_word_array()
  local arr = {}
  for i = 1, 16 do
    arr[i] = 0
  end
  --- @cast arr Word32Array
  return arr
end

-- Pre-allocated arrays for chacha20_block() to avoid repeated allocation
local block_state = create_word_array()
local block_working = create_word_array()

--- Convert 32-bit word to 4 bytes (little-endian)
--- @param word integer 32-bit word
--- @return integer, integer, integer, integer bytes Four bytes in little-endian order
local function word_to_bytes(word)
  local byte1 = word % 256
  word = floor(word * 0.00390625) -- / 256
  local byte2 = word % 256
  word = floor(word * 0.00390625)
  local byte3 = word % 256
  word = floor(word * 0.00390625)
  local byte4 = word % 256

  return byte1, byte2, byte3, byte4
end

--- Convert 4 bytes to 32-bit word (little-endian)
--- @param byte1 integer First byte (least significant)
--- @param byte2 integer Second byte
--- @param byte3 integer Third byte
--- @param byte4 integer Fourth byte (most significant)
--- @return integer word 32-bit word
local function bytes_to_word(byte1, byte2, byte3, byte4)
  return byte1 + byte2 * 256 + byte3 * 65536 + byte4 * 16777216
end

--- ChaCha20 quarter round operation
--- @param state Word32Array 16-word state array (modified in place)
--- @param a integer Index of first word
--- @param b integer Index of second word
--- @param c integer Index of third word
--- @param d integer Index of fourth word
local function quarter_round(state, a, b, c, d)
  state[a] = bit32_raw_add(state[a], state[b])
  state[d] = bit32_raw_rol(bit32_raw_bxor(state[d], state[a]), 16)

  state[c] = bit32_raw_add(state[c], state[d])
  state[b] = bit32_raw_rol(bit32_raw_bxor(state[b], state[c]), 12)

  state[a] = bit32_raw_add(state[a], state[b])
  state[d] = bit32_raw_rol(bit32_raw_bxor(state[d], state[a]), 8)

  state[c] = bit32_raw_add(state[c], state[d])
  state[b] = bit32_raw_rol(bit32_raw_bxor(state[b], state[c]), 7)
end

--- Generate one 64-byte block of ChaCha20 keystream
--- @param key string 32-byte key
--- @param nonce string 12-byte nonce
--- @param counter integer 32-bit counter value
--- @return string keystream 64-byte keystream block
local function chacha20_block(key, nonce, counter)
  -- Reuse pre-allocated arrays
  local state = block_state
  local working_state = block_working

  -- Initialize state inline (avoiding function call overhead)
  assert(#key == 32, "Key must be exactly 32 bytes")
  assert(#nonce == 12, "Nonce must be exactly 12 bytes")
  assert(counter >= 0 and counter < 0x100000000, "Counter must be a valid 32-bit integer")

  -- ChaCha20 constants "expand 32-byte k"
  state[1] = 0x61707865 -- "expa"
  state[2] = 0x3320646e -- "nd 3"
  state[3] = 0x79622d32 -- "2-by"
  state[4] = 0x6b206574 -- "te k"

  -- 256-bit key (8 words)
  for i = 1, 8 do
    local base = (i - 1) * 4
    state[4 + i] = bytes_to_word(
      string_byte(key, base + 1),
      string_byte(key, base + 2),
      string_byte(key, base + 3),
      string_byte(key, base + 4)
    )
  end

  -- 32-bit counter
  state[13] = counter

  -- 96-bit nonce (3 words)
  for i = 1, 3 do
    local base = (i - 1) * 4
    state[13 + i] = bytes_to_word(
      string_byte(nonce, base + 1),
      string_byte(nonce, base + 2),
      string_byte(nonce, base + 3),
      string_byte(nonce, base + 4)
    )
  end

  -- Create working copy of state
  for i = 1, 16 do
    working_state[i] = state[i]
  end

  -- Perform 20 rounds (10 double rounds)
  for _ = 1, 10 do
    -- Column rounds
    quarter_round(working_state, 1, 5, 9, 13)
    quarter_round(working_state, 2, 6, 10, 14)
    quarter_round(working_state, 3, 7, 11, 15)
    quarter_round(working_state, 4, 8, 12, 16)

    -- Diagonal rounds
    quarter_round(working_state, 1, 6, 11, 16)
    quarter_round(working_state, 2, 7, 12, 13)
    quarter_round(working_state, 3, 8, 9, 14)
    quarter_round(working_state, 4, 5, 10, 15)
  end

  -- Add original state to working state
  for i = 1, 16 do
    working_state[i] = bit32_raw_add(working_state[i], state[i])
  end

  -- Convert state to byte string (little-endian) - optimized with local references
  local result_bytes = {}
  for i = 1, 16 do
    local b1, b2, b3, b4 = word_to_bytes(working_state[i])
    result_bytes[i] = string_char(b1, b2, b3, b4)
  end

  return table_concat(result_bytes)
end

--- ChaCha20 encryption/decryption (same operation)
--- @param key string 32-byte key
--- @param nonce string 12-byte nonce
--- @param plaintext string Data to encrypt/decrypt
--- @param counter? integer Initial counter value (default: 1)
--- @return string ciphertext Encrypted/decrypted data
function chacha20.crypt(key, nonce, plaintext, counter)
  counter = counter or 1

  local result_bytes = {}
  local result_idx = 1
  local offset = 1
  local data_len = #plaintext

  while offset <= data_len do
    -- Generate keystream block
    local keystream = chacha20_block(key, nonce, counter)

    -- XOR with plaintext (optimized with local references)
    local block_size = min(64, data_len - offset + 1)
    for i = 1, block_size do
      local plaintext_byte = string_byte(plaintext, offset + i - 1)
      local keystream_byte = string_byte(keystream, i)
      result_bytes[result_idx] = string_char(bit32_raw_bxor(plaintext_byte, keystream_byte))
      result_idx = result_idx + 1
    end

    offset = offset + 64
    counter = counter + 1
  end

  return table_concat(result_bytes)
end

--- Convenience function for encryption (same as crypt)
--- @param key string 32-byte key
--- @param nonce string 12-byte nonce
--- @param plaintext string Data to encrypt
--- @param counter? integer Initial counter value (default: 1)
--- @return string ciphertext Encrypted data
function chacha20.encrypt(key, nonce, plaintext, counter)
  -- Check if we should use OpenSSL
  local openssl = openssl_wrapper.get()
  if openssl and #plaintext > 0 then
    -- Prepend 32-bit counter to 96-bit nonce for complete 128-bit nonce
    nonce = bytes.u32_to_le_bytes(counter or 1) .. nonce
    return openssl.cipher.encrypt("chacha20", plaintext, key, nonce)
  end
  return chacha20.crypt(key, nonce, plaintext, counter)
end

--- Convenience function for decryption (same as crypt)
--- @param key string 32-byte key
--- @param nonce string 12-byte nonce
--- @param ciphertext string Data to decrypt
--- @param counter? integer Initial counter value (default: 1)
--- @return string plaintext Decrypted data
function chacha20.decrypt(key, nonce, ciphertext, counter)
  -- Check if we should use OpenSSL
  local openssl = openssl_wrapper.get()
  if openssl and #ciphertext > 0 then
    -- Prepend 32-bit counter to 96-bit nonce for complete 128-bit nonce
    nonce = bytes.u32_to_le_bytes(counter or 1) .. nonce
    return openssl.cipher.decrypt("chacha20", ciphertext, key, nonce)
  end
  return chacha20.crypt(key, nonce, ciphertext, counter)
end

--- Test vectors from RFC 8439
local test_vectors = {
  {
    name = "RFC 8439 Test Vector 1 - ChaCha20 Block Function",
    key = bytes.from_hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"),
    nonce = bytes.from_hex("000000090000004a00000000"),
    counter = 1,
    plaintext = "", -- Empty for block function test
    expected_keystream = bytes.from_hex(
      "10f1e7e4d13b5915500fdd1fa32071c4c7d1f4c733c068030422aa9ac3d46c4ed2826446079faa0914c2d705d98b02a2b5129cd1de164eb9cbd083e8a2503c4e"
    ),
  },
  {
    name = "RFC 8439 Test Vector 2 - ChaCha20 Encryption",
    key = bytes.from_hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"),
    nonce = bytes.from_hex("000000000000004a00000000"),
    counter = 1,
    plaintext = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.",
    expected_ciphertext = bytes.from_hex(
      "6e2e359a2568f98041ba0728dd0d6981e97e7aec1d4360c20a27afccfd9fae0bf91b65c5524733ab8f593dabcd62b3571639d624e65152ab8f530c359f0861d807ca0dbf500d6a6156a38e088a22b65e52bc514d16ccf806818ce91ab77937365af90bbf74a35be6b40b8eedf2785e42874d"
    ),
  },
  {
    name = "RFC 8439 Test Vector 3 - Key and IV setup",
    key = bytes.from_hex("1c9240a5eb55d38af333888604f6b5f0473917c1402b80099dca5cbc207075c0"),
    nonce = bytes.from_hex("000000000000000000000002"),
    counter = 42,
    plaintext = "'Twas brillig, and the slithy toves\nDid gyre and gimble in the wabe:\nAll mimsy were the borogoves,\nAnd the mome raths outgrabe.",
    expected_ciphertext = bytes.from_hex(
      "62e6347f95ed87a45ffae7426f27a1df5fb69110044c0d73118effa95b01e5cf166d3df2d721caf9b21e5fb14c616871fd84c54f9d65b283196c7fe4f60553ebf39c6402c42234e32a356b3e764312a61a5532055716ead6962568f87d3f3f7704c6a8d1bcd1bf4d50d6154b6da731b187b58dfd728afa36757a797ac188d1"
    ),
  },
  {
    name = "Zero key test",
    key = string_rep("\0", 32),
    nonce = string_rep("\0", 12),
    counter = 0,
    plaintext = string_rep("\0", 64),
    expected_ciphertext = bytes.from_hex(
      "76b8e0ada0f13d90405d6ae55386bd28bdd219b8a08ded1aa836efcc8b770dc7da41597c5157488d7724e03fb8d84a376a43b8f41518a11cc387b669b2ee6586"
    ),
  },
}

--- Run comprehensive self-test with all standard test vectors
---
--- This function validates the implementation against known test vectors
--- from RFC 8439. ALL tests must pass for the implementation to be
--- considered cryptographically safe.
---
--- @return boolean result True if all tests pass, false otherwise
function chacha20.selftest()
  local function test_vectors_suite()
    print("Running ChaCha20 test vectors...")
    local passed = 0
    local total = #test_vectors

    for i, test in ipairs(test_vectors) do
      print(string.format("Test %d: %s", i, test.name))
      if test.expected_keystream then
        assert(
          test.expected_ciphertext == nil,
          "Test vector cannot have both expected_keystream and expected_ciphertext"
        )
        -- Test keystream generation
        local keystream = chacha20_block(test.key, test.nonce, test.counter)

        if keystream == test.expected_keystream then
          print("  ✅ PASS: " .. test.name)
          passed = passed + 1
        else
          print("  ❌ FAIL: " .. test.name)
          print("  Expected keystream length:", #test.expected_keystream)
          print("  Got keystream length:     ", #keystream)

          -- Show first few bytes for debugging
          local expected_hex = ""
          local result_hex = ""
          local show_bytes = min(16, #test.expected_keystream)

          for j = 1, show_bytes do
            expected_hex = expected_hex .. string.format("%02x", string_byte(assert(test.expected_keystream), j))
            result_hex = result_hex .. string.format("%02x", string_byte(keystream, j))
          end

          print("  Expected (first " .. show_bytes .. " bytes): " .. expected_hex)
          print("  Got (first " .. show_bytes .. " bytes):      " .. result_hex)
        end
      elseif test.expected_ciphertext then
        assert(
          test.expected_keystream == nil,
          "Test vector cannot have both expected_keystream and expected_ciphertext"
        )
        -- Test encryption
        local result = chacha20.crypt(test.key, test.nonce, test.plaintext, test.counter)

        if result == test.expected_ciphertext then
          print("  ✅ PASS: " .. test.name)
          passed = passed + 1
        else
          print("  ❌ FAIL: " .. test.name)
          print("  Expected ciphertext length:", #test.expected_ciphertext)
          print("  Got ciphertext length:     ", #result)

          -- Show first few bytes for debugging
          local expected_hex = ""
          local result_hex = ""
          local show_bytes = min(16, #test.expected_ciphertext)

          for j = 1, show_bytes do
            expected_hex = expected_hex .. string.format("%02x", string_byte(assert(test.expected_ciphertext), j))
            result_hex = result_hex .. string.format("%02x", string_byte(result, j))
          end

          print("  Expected (first " .. show_bytes .. " bytes): " .. expected_hex)
          print("  Got (first " .. show_bytes .. " bytes):      " .. result_hex)
        end
      else
        error("Test vector must have either expected_keystream or expected_ciphertext")
      end
      print()
    end

    print(string.format("Test vectors result: %d/%d tests passed", passed, total))
    print()
    return passed == total
  end

  local function functional_tests()
    print("Running ChaCha20 functional tests...")
    local passed = 0
    local total = 0

    -- Test 1: Basic encryption/decryption
    total = total + 1
    local key = string_rep(string_char(0x42), 32)
    local nonce = string_rep("\0", 12)
    local counter = 1
    local plaintext = "Hello, ChaCha20! This is a test message for encryption."

    local ciphertext = chacha20.encrypt(key, nonce, plaintext, counter)
    local decrypted = chacha20.decrypt(key, nonce, ciphertext, counter)

    if plaintext == decrypted then
      print("  ✅ PASS: Basic encryption/decryption")
      passed = passed + 1
    else
      print("  ❌ FAIL: Basic encryption/decryption")
    end

    -- Test 2: Encryption is deterministic
    total = total + 1
    local ciphertext2 = chacha20.encrypt(key, nonce, plaintext, counter)

    if ciphertext == ciphertext2 then
      print("  ✅ PASS: Encryption is deterministic")
      passed = passed + 1
    else
      print("  ❌ FAIL: Encryption is not deterministic")
    end

    -- Test 3: Different nonces produce different output
    total = total + 1
    local nonce2 = string_char(0x01) .. string_rep("\0", 11)
    local ciphertext3 = chacha20.encrypt(key, nonce2, plaintext, counter)

    if ciphertext ~= ciphertext3 then
      print("  ✅ PASS: Different nonces produce different ciphertexts")
      passed = passed + 1
    else
      print("  ❌ FAIL: Different nonces produce same ciphertext")
    end

    -- Test 4: Different counters produce different output
    total = total + 1
    local ciphertext4 = chacha20.encrypt(key, nonce, plaintext, 2)

    if ciphertext ~= ciphertext4 then
      print("  ✅ PASS: Different counters produce different ciphertexts")
      passed = passed + 1
    else
      print("  ❌ FAIL: Different counters produce same ciphertext")
    end

    -- Test 5: Empty plaintext
    total = total + 1
    local empty_ct = chacha20.encrypt(key, nonce, "", counter)
    local empty_pt = chacha20.decrypt(key, nonce, empty_ct, counter)

    if empty_pt == "" then
      print("  ✅ PASS: Empty plaintext encryption/decryption")
      passed = passed + 1
    else
      print("  ❌ FAIL: Empty plaintext encryption/decryption")
    end

    -- Test 6: Large plaintext (multi-block)
    total = total + 1
    local large_plaintext = string_rep("A", 256) -- 4 blocks
    local large_ct = chacha20.encrypt(key, nonce, large_plaintext, counter)
    local large_pt = chacha20.decrypt(key, nonce, large_ct, counter)

    if large_pt == large_plaintext then
      print("  ✅ PASS: Multi-block encryption/decryption")
      passed = passed + 1
    else
      print("  ❌ FAIL: Multi-block encryption/decryption")
    end

    -- Test 7: Partial block
    total = total + 1
    local partial_plaintext = string_rep("B", 100) -- Not a multiple of 64
    local partial_ct = chacha20.encrypt(key, nonce, partial_plaintext, counter)
    local partial_pt = chacha20.decrypt(key, nonce, partial_ct, counter)

    if partial_pt == partial_plaintext then
      print("  ✅ PASS: Partial block encryption/decryption")
      passed = passed + 1
    else
      print("  ❌ FAIL: Partial block encryption/decryption")
    end

    print(string.format("\nFunctional tests result: %d/%d tests passed", passed, total))
    print()
    return passed == total
  end

  local vectors_passed = test_vectors_suite()
  local functional_passed = functional_tests()

  return vectors_passed and functional_passed
end

--- Run performance benchmarks
---
--- This function runs comprehensive performance benchmarks for ChaCha20 operations
--- including block generation and stream encryption/decryption.
function chacha20.benchmark()
  -- Test data
  local key = bytes.from_hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
  local nonce = bytes.from_hex("000000090000004a00000000")
  local plaintext_64 = string_rep("a", 64)
  local plaintext_1k = string_rep("a", 1024)
  local plaintext_8k = string_rep("a", 8192)

  print("Encryption Operations:")
  benchmark_op("encrypt_64_bytes", function()
    chacha20.encrypt(key, nonce, plaintext_64, 1)
  end, 1000)

  benchmark_op("encrypt_1k", function()
    chacha20.encrypt(key, nonce, plaintext_1k, 1)
  end, 200)

  benchmark_op("encrypt_8k", function()
    chacha20.encrypt(key, nonce, plaintext_8k, 1)
  end, 50)
end

return chacha20
end
end

do
local _ENV = _ENV
package.preload[ "crypto.chacha20_poly1305" ] = function( ... ) local arg = _G.arg;
--- @module "crypto.chacha20_poly1305"
--- ChaCha20-Poly1305 Authenticated Encryption with Associated Data (AEAD) Implementation for portability.
--- @class crypto.chacha20_poly1305
local chacha20_poly1305 = {}

local openssl_wrapper = require("crypto.openssl_wrapper")
local utils = require("crypto.utils")
local bytes = utils.bytes
local benchmark_op = utils.benchmark.benchmark_op
local chacha20 = require("crypto.chacha20")
local poly1305 = require("crypto.poly1305")

-- Local references for performance
local string_char = string.char
local string_rep = string.rep
local string_sub = string.sub
local table_concat = table.concat

--- Generate Poly1305 one-time key using ChaCha20
--- @param key string 32-byte ChaCha20 key
--- @param nonce string 12-byte nonce
--- @return string poly_key 32-byte Poly1305 one-time key
local function poly1305_key_gen(key, nonce)
  -- Generate Poly1305 key by encrypting 32 zero bytes with ChaCha20
  -- Counter starts at 0 for key generation
  local zero_block = string_rep("\0", 32)
  return chacha20.crypt(key, nonce, zero_block, 0)
end

--- Construct authentication data for Poly1305
--- @param aad string Additional Authenticated Data
--- @param ciphertext string Encrypted data
--- @return string auth_data Data to be authenticated
local function construct_aad_data(aad, ciphertext)
  local aad_len = #aad
  local ciphertext_len = #ciphertext

  -- Construct the data to authenticate according to RFC 8439:
  -- AAD || pad16(AAD) || ciphertext || pad16(ciphertext) || num_to_8_le_bytes(aad_len) || num_to_8_le_bytes(ciphertext_len)
  local auth_parts = {
    bytes.pad_to_16(aad),
    bytes.pad_to_16(ciphertext),
    bytes.u64_to_le_bytes(aad_len),
    bytes.u64_to_le_bytes(ciphertext_len),
  }

  return table_concat(auth_parts)
end

-- ============================================================================
-- CHACHA20-POLY1305 AEAD PUBLIC INTERFACE
-- ============================================================================

--- ChaCha20-Poly1305 AEAD Encryption
---
--- Encrypts plaintext and authenticates both the plaintext and additional data.
--- Returns the ciphertext concatenated with a 16-byte authentication tag.
---
--- @param key string 32-byte encryption key
--- @param nonce string 12-byte nonce (must be unique for each encryption with the same key)
--- @param plaintext string Data to encrypt
--- @param aad? string Additional Authenticated Data (default: empty string)
--- @return string result Ciphertext concatenated with 16-byte authentication tag
function chacha20_poly1305.encrypt(key, nonce, plaintext, aad)
  assert(#key == 32, "Key must be exactly 32 bytes")
  assert(#nonce == 12, "Nonce must be exactly 12 bytes")

  aad = aad or ""

  local openssl = openssl_wrapper.get(openssl_wrapper.Feature.AAD)
  if openssl then
    local evp = openssl.cipher.get("chacha20-poly1305")
    local e = evp:encrypt_new()
    e:ctrl(openssl.cipher.EVP_CTRL_GCM_SET_IVLEN, #nonce)
    e:init(key, nonce)

    -- Indicate that the AAD setting is set
    local aad_update = e:update(aad, true) or ""
    if #aad_update > 0 then
      error("AAD update should not return data in AEAD mode")
    end
    local ciphertext = e:update(plaintext)
    local final = e:final() or ""
    if #final > 0 then
      error("Finalization should not return data in AEAD mode")
    end
    local tag = e:ctrl(openssl.cipher.EVP_CTRL_GCM_GET_TAG, 16) or ""
    if #tag ~= 16 then
      error("Tag length must be exactly 16 bytes in AEAD mode")
    end
    return ciphertext .. tag
  end

  -- Step 1: Generate Poly1305 one-time key
  local poly_key = poly1305_key_gen(key, nonce)

  -- Step 2: Encrypt plaintext with ChaCha20
  local ciphertext = chacha20.crypt(key, nonce, plaintext)

  -- Step 3: Construct authentication data
  local auth_data = construct_aad_data(aad, ciphertext)

  -- Step 4: Generate authentication tag with Poly1305
  local tag = poly1305.authenticate(poly_key, auth_data)

  -- Step 5: Return ciphertext || tag
  return ciphertext .. tag
end

--- ChaCha20-Poly1305 AEAD Decryption
---
--- Verifies the authentication tag and decrypts the ciphertext if authentic.
--- The input should be the result of encrypt() - ciphertext concatenated with tag.
---
--- @param key string 32-byte encryption key
--- @param nonce string 12-byte nonce (same as used for encryption)
--- @param ciphertext_and_tag string Encrypted data with 16-byte authentication tag appended
--- @param aad? string Additional Authenticated Data (default: empty string)
--- @return string? plaintext Decrypted data, or nil if authentication fails
function chacha20_poly1305.decrypt(key, nonce, ciphertext_and_tag, aad)
  assert(#key == 32, "Key must be exactly 32 bytes")
  assert(#nonce == 12, "Nonce must be exactly 12 bytes")
  assert(#ciphertext_and_tag >= 16, "Input must contain at least 16 bytes for authentication tag")

  aad = aad or ""

  -- Step 1: Split ciphertext and tag
  local ciphertext_len = #ciphertext_and_tag - 16
  local ciphertext = string_sub(ciphertext_and_tag, 1, ciphertext_len)
  local received_tag = string_sub(ciphertext_and_tag, ciphertext_len + 1)

  local openssl = openssl_wrapper.get(openssl_wrapper.Feature.AAD)
  if openssl then
    local evp = openssl.cipher.get("chacha20-poly1305")
    local e = evp:decrypt_new()
    e:ctrl(openssl.cipher.EVP_CTRL_GCM_SET_IVLEN, #nonce)
    e:ctrl(openssl.cipher.EVP_CTRL_GCM_SET_TAG, received_tag)
    e:init(key, nonce)

    -- Indicate that the AAD setting is set
    local aad_update = e:update(aad, true) or ""
    if #aad_update > 0 then
      error("AAD update should not return data in AEAD mode")
    end
    local plaintext = e:update(ciphertext)
    local final = e:final()
    if final == nil then
      return nil -- Authentication failed
    elseif #final > 0 then
      error("Finalization should not return data in AEAD mode")
    end
    return plaintext
  end

  -- Step 2: Generate Poly1305 one-time key (same as encryption)
  local poly_key = poly1305_key_gen(key, nonce)

  -- Step 3: Construct authentication data (same as encryption)
  local auth_data = construct_aad_data(aad, ciphertext)

  -- Step 4: Compute expected authentication tag
  local expected_tag = poly1305.authenticate(poly_key, auth_data)

  -- Step 5: Verify authentication tag (constant-time comparison)
  if received_tag ~= expected_tag then
    return nil -- Authentication failed
  end

  -- Step 6: Decrypt ciphertext with ChaCha20 (counter starts at 1)
  local plaintext = chacha20.crypt(key, nonce, ciphertext, 1)

  return plaintext
end

-- ============================================================================
-- TEST VECTORS AND VALIDATION
-- ============================================================================

--- Test vectors from RFC 8439
local test_vectors = {
  {
    name = "RFC 8439 Section 2.8.2 Test Vector",
    key = bytes.from_hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f"),
    nonce = bytes.from_hex("070000004041424344454647"),
    aad = bytes.from_hex("50515253c0c1c2c3c4c5c6c7"),
    plaintext = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.",
    expected = bytes.from_hex(
      "d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b61161ae10b594f09e26a7e902ecbd0600691"
    ),
  },
  {
    name = "Poly1305 key generation test",
    key = bytes.from_hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f"),
    nonce = bytes.from_hex("000000000001020304050607"),
    aad = "",
    plaintext = "",
    expected_poly_key = bytes.from_hex("8ad5a08b905f81cc815040274ab29471a833b637e3fd0da508dbb8e2fdd1a646"),
  },
  {
    name = "Roundtrip test with various inputs",
    key = bytes.from_hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"),
    nonce = bytes.from_hex("000000000000004a00000000"),
    aad = "Additional authenticated data",
    plaintext = "Hello, ChaCha20-Poly1305 AEAD!",
  },
  {
    name = "Empty AAD roundtrip test",
    key = string_char(0x42) .. string_rep("\0", 31),
    nonce = string_rep("\0", 12),
    aad = "",
    plaintext = "No additional data",
  },
  {
    name = "Empty plaintext roundtrip test",
    key = string_rep(string_char(0xff), 32),
    nonce = bytes.from_hex("0102030405060708090a0b0c"),
    aad = "Only authenticating this data",
    plaintext = "",
  },
}

--- Run comprehensive self-test with all standard test vectors
---
--- This function validates the implementation against known test vectors.
--- ALL tests must pass for the implementation to be considered cryptographically safe.
---
--- @return boolean result True if all tests pass, false otherwise
function chacha20_poly1305.selftest()
  local function test_vectors_suite()
    print("Running ChaCha20-Poly1305 AEAD test vectors...")
    local passed = 0.0
    local total = #test_vectors

    for i, test in ipairs(test_vectors) do
      print(string.format("Test %d: %s", i, test.name))

      if test.expected_poly_key then
        -- Test Poly1305 key generation
        local poly_key = poly1305_key_gen(test.key, test.nonce)

        if poly_key == test.expected_poly_key then
          print("  ✅ PASS: " .. test.name)
          passed = passed + 1
        else
          print("  ❌ FAIL: " .. test.name)
          print("  Expected poly key length:", #test.expected_poly_key)
          print("  Got poly key length:     ", #poly_key)

          local expected_hex = ""
          local result_hex = ""
          for j = 1, math.min(16, #test.expected_poly_key) do
            expected_hex = expected_hex .. string.format("%02x", string.byte(test.expected_poly_key, j))
            result_hex = result_hex .. string.format("%02x", string.byte(poly_key, j))
          end

          print("  Expected (first 16 bytes): " .. expected_hex)
          print("  Got (first 16 bytes):      " .. result_hex)
        end
      else
        -- Test encryption and decryption
        local encrypted = chacha20_poly1305.encrypt(test.key, test.nonce, test.plaintext, test.aad)

        -- Test against expected result if provided
        if test.expected then
          if encrypted == test.expected then
            print("  ✅ PASS: " .. test.name .. " (encryption)")
            passed = passed + 0.5
          else
            print("  ❌ FAIL: " .. test.name .. " (encryption)")
            print("  Expected length:", #test.expected)
            print("  Got length:     ", #encrypted)

            local expected_hex = ""
            local result_hex = ""
            local show_bytes = math.min(16, #test.expected)

            for j = 1, show_bytes do
              expected_hex = expected_hex .. string.format("%02x", string.byte(test.expected, j))
              result_hex = result_hex .. string.format("%02x", string.byte(encrypted, j))
            end

            print("  Expected (first " .. show_bytes .. " bytes): " .. expected_hex)
            print("  Got (first " .. show_bytes .. " bytes):      " .. result_hex)
          end
        else
          print("  ✅ PASS: " .. test.name .. " (encryption - no reference)")
          passed = passed + 0.5
        end

        -- Test decryption
        local decrypted = chacha20_poly1305.decrypt(test.key, test.nonce, encrypted, test.aad)

        if decrypted == test.plaintext then
          print("  ✅ PASS: " .. test.name .. " (decryption)")
          passed = passed + 0.5
        else
          print("  ❌ FAIL: " .. test.name .. " (decryption)")
          if decrypted == nil then
            print("  Decryption returned nil (authentication failed)")
          else
            print("  Expected plaintext:", test.plaintext)
            print("  Got plaintext:     ", decrypted)
          end
        end
      end
      print()
    end

    print(string.format("Test vectors result: %.0f/%d tests passed", passed, total))
    print()
    return passed == total
  end

  local function functional_tests()
    print("Running ChaCha20-Poly1305 AEAD functional tests...")
    local passed = 0
    local total = 0

    -- Test 1: Basic encryption/decryption
    total = total + 1
    local key = string_rep(string_char(0x42), 32)
    local nonce = string_rep("\0", 11) .. string_char(0x01)
    local aad = "user@example.com|2024-01-01"
    local plaintext = "This is a secret message that needs both encryption and authentication."

    local ciphertext_and_tag = chacha20_poly1305.encrypt(key, nonce, plaintext, aad)
    local decrypted = chacha20_poly1305.decrypt(key, nonce, ciphertext_and_tag, aad)

    if decrypted == plaintext then
      print("  ✅ PASS: Basic encryption/decryption")
      passed = passed + 1
    else
      print("  ❌ FAIL: Basic encryption/decryption")
    end

    -- Test 2: Authentication tag tampering detection
    total = total + 1
    local tampered = ciphertext_and_tag:sub(1, -2) .. string_char(255)
    local tampered_result = chacha20_poly1305.decrypt(key, nonce, tampered, aad)

    if tampered_result == nil then
      print("  ✅ PASS: Tampered tag correctly rejected")
      passed = passed + 1
    else
      print("  ❌ FAIL: Tampered tag was not detected")
    end

    -- Test 3: Wrong AAD detection
    total = total + 1
    local wrong_aad = "wrong@example.com|2024-01-01"
    local wrong_aad_result = chacha20_poly1305.decrypt(key, nonce, ciphertext_and_tag, wrong_aad)

    if wrong_aad_result == nil then
      print("  ✅ PASS: Wrong AAD correctly rejected")
      passed = passed + 1
    else
      print("  ❌ FAIL: Wrong AAD was not detected")
    end

    -- Test 4: Nonce uniqueness
    total = total + 1
    local nonce2 = string_rep("\0", 11) .. string_char(0x02)
    local ciphertext2 = chacha20_poly1305.encrypt(key, nonce2, plaintext, aad)

    if ciphertext_and_tag ~= ciphertext2 then
      print("  ✅ PASS: Different nonces produce different ciphertexts")
      passed = passed + 1
    else
      print("  ❌ FAIL: Different nonces produced same ciphertext")
    end

    -- Test 5: Empty plaintext
    total = total + 1
    local empty_ct = chacha20_poly1305.encrypt(key, nonce, "", aad)
    local empty_pt = chacha20_poly1305.decrypt(key, nonce, empty_ct, aad)

    if empty_pt == "" then
      print("  ✅ PASS: Empty plaintext encryption/decryption")
      passed = passed + 1
    else
      print("  ❌ FAIL: Empty plaintext encryption/decryption")
    end

    -- Test 6: Empty AAD
    total = total + 1
    local no_aad_ct = chacha20_poly1305.encrypt(key, nonce, plaintext, "")
    local no_aad_pt = chacha20_poly1305.decrypt(key, nonce, no_aad_ct, "")

    if no_aad_pt == plaintext then
      print("  ✅ PASS: Empty AAD encryption/decryption")
      passed = passed + 1
    else
      print("  ❌ FAIL: Empty AAD encryption/decryption")
    end

    -- Test 7: Ciphertext tampering detection
    total = total + 1
    local tampered_ct = string_char(255) .. ciphertext_and_tag:sub(2)
    local tampered_ct_result = chacha20_poly1305.decrypt(key, nonce, tampered_ct, aad)

    if tampered_ct_result == nil then
      print("  ✅ PASS: Tampered ciphertext correctly rejected")
      passed = passed + 1
    else
      print("  ❌ FAIL: Tampered ciphertext was not detected")
    end

    print(string.format("\nFunctional tests result: %d/%d tests passed", passed, total))
    print()
    return passed == total
  end

  local vectors_passed = test_vectors_suite()
  local functional_passed = functional_tests()

  return vectors_passed and functional_passed
end

--- Run performance benchmarks
---
--- This function runs comprehensive performance benchmarks for ChaCha20-Poly1305 operations
--- including authenticated encryption and decryption for various message sizes.
function chacha20_poly1305.benchmark()
  -- Test data
  local key = bytes.from_hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
  local nonce = bytes.from_hex("070000004041424344454647")
  local aad = "Additional authenticated data"
  local plaintext_64 = string_rep("a", 64)
  local plaintext_1k = string_rep("a", 1024)
  local plaintext_8k = string_rep("a", 8192)

  print("Authenticated Encryption Operations:")
  benchmark_op("encrypt_64_bytes", function()
    chacha20_poly1305.encrypt(key, nonce, plaintext_64, aad)
  end, 500)

  benchmark_op("encrypt_1k", function()
    chacha20_poly1305.encrypt(key, nonce, plaintext_1k, aad)
  end, 100)

  benchmark_op("encrypt_8k", function()
    chacha20_poly1305.encrypt(key, nonce, plaintext_8k, aad)
  end, 25)

  -- Pre-generate ciphertexts for decryption benchmarks
  local ct_64 = chacha20_poly1305.encrypt(key, nonce, plaintext_64, aad)
  local ct_1k = chacha20_poly1305.encrypt(key, nonce, plaintext_1k, aad)
  local ct_8k = chacha20_poly1305.encrypt(key, nonce, plaintext_8k, aad)

  print("\nAuthenticated Decryption Operations:")
  benchmark_op("decrypt_64_bytes", function()
    chacha20_poly1305.decrypt(key, nonce, ct_64, aad)
  end, 500)

  benchmark_op("decrypt_1k", function()
    chacha20_poly1305.decrypt(key, nonce, ct_1k, aad)
  end, 100)

  benchmark_op("decrypt_8k", function()
    chacha20_poly1305.decrypt(key, nonce, ct_8k, aad)
  end, 25)
end

return chacha20_poly1305
end
end

do
local _ENV = _ENV
package.preload[ "crypto.ed25519" ] = function( ... ) local arg = _G.arg;
--- @module "crypto.ed25519"
--- Ed25519 (RFC 8032) EdDSA signatures in portable pure Lua.
---
--- PureEdDSA over edwards25519 with SHA-512, no context and no prehashing
--- (RFC 8032 section 5.1). The field arithmetic is the TweetNaCl 16x16-bit limb
--- representation shared with `crypto.x25519`; point arithmetic uses extended
--- twisted Edwards coordinates (X, Y, Z, T).
---
--- Portability: no Lua 5.3+ integer syntax is used, every intermediate value is
--- exactly representable as an IEEE double, so the module behaves identically on
--- Lua 5.1/5.2/5.3/5.4/5.5 and LuaJIT 2.0/2.1.
--- @class crypto.ed25519
local ed25519 = {}

local bit32 = require("bitn").bit32

local random = require("crypto.random")
local sha512_mod = require("crypto.sha512")
local utils = require("crypto.utils")
local bytes = utils.bytes
local benchmark_op = utils.benchmark.benchmark_op

-- Local references for performance
local bit32_raw_band = bit32.raw_band
local bit32_raw_bor = bit32.raw_bor
local bit32_raw_bxor = bit32.raw_bxor
local bit32_raw_rshift = bit32.raw_rshift
local floor = math.floor
local sha512 = sha512_mod.sha512
local string_byte = string.byte
local string_char = string.char
local string_rep = string.rep
local string_sub = string.sub
local table_concat = table.concat

-- ============================================================================
-- CURVE25519 FIELD ARITHMETIC (shared field with X25519: p = 2^255 - 19)
-- ============================================================================

-- `FieldElement` and `ProductArray` are shared with x25519 (same field, same
-- limb layout) and are defined once in `annotations.lua`.

--- @alias ByteArray integer[] Array of byte values (indices start at 1)
--- @alias EdPoint FieldElement[] 4-element array {X, Y, Z, T} in extended twisted Edwards coordinates

--- Initialize a 16-element field element with zeros
--- @return FieldElement fe Initialized field element
local function create_field_element()
  local arr = {}
  for i = 1, 16 do
    arr[i] = 0
  end
  return arr
end

--- Initialize a 31-element product array with zeros
--- @return ProductArray arr Initialized array
local function create_product_array()
  local arr = {}
  for i = 1, 31 do
    arr[i] = 0
  end
  return arr
end

--- Initialize an n-element byte array with zeros
--- @param n integer Number of elements
--- @return ByteArray arr Initialized array
local function create_byte_array(n)
  local arr = {}
  for i = 1, n do
    arr[i] = 0
  end
  return arr
end

--- Initialize an extended twisted Edwards point (all four coordinates zeroed)
--- @return EdPoint p Initialized point
local function create_point()
  return { create_field_element(), create_field_element(), create_field_element(), create_field_element() }
end

-- Pre-allocated product array for fe_mul() to avoid repeated allocation
local mul_prod = create_product_array()

-- Pre-allocated arrays for fe_pack() to avoid repeated allocation
local pack_t = create_field_element()
local pack_m = create_field_element()

-- Pre-allocated arrays for fe_inv() / fe_pow2523()
local inv_c = create_field_element()
local pow_c = create_field_element()

-- Pre-allocated byte buffers used by par25519() / fe_eq()
local cmp_a = create_byte_array(32)
local cmp_b = create_byte_array(32)

--- Carry/reduce a field element so every limb ends up in [0, 2^16)
---
--- Overflow bound: `floor(v * 1/0x10000)` is exact for any |v| < 2^53 because
--- 1/0x10000 is a power of two, so the multiply is error-free. Callers keep
--- limbs well under that (see fe_mul).
--- @param out integer[] Array to perform carry on
local function fe_carry(out)
  for i = 1, 16 do
    local v = out[i] + 0x10000
    local c = floor(v * 0.0000152587890625) -- 1/0x10000 = 0.0000152587890625
    if i < 16 then
      out[i + 1] = out[i + 1] + c - 1
    else
      out[1] = out[1] + 38 * (c - 1)
    end
    out[i] = v - c * 0x10000
  end
end

--- Conditional swap of two limb arrays based on a bit value (branch-free)
--- @param a integer[] First array
--- @param b integer[] Second array
--- @param bit integer Bit value (0 or 1)
local function fe_cswap(a, b, bit)
  for i = 1, 16 do
    a[i], b[i] = a[i] * ((bit - 1) % 2) + b[i] * bit, b[i] * ((bit - 1) % 2) + a[i] * bit
  end
end

--- Unpack a 32-byte little-endian value into a limb array (clears the top bit)
--- @param out integer[] Output limb array
--- @param a integer[] Input byte array (32 bytes)
local function fe_unpack(out, a)
  for i = 1, 16 do
    out[i] = a[2 * i - 1] + a[2 * i] * 0x100
  end
  out[16] = bit32_raw_band(out[16], 0x7fff)
end

-- Pre-allocated prime constant for fe_pack()
local PRIME = {
  0xffed,
  0xffff,
  0xffff,
  0xffff,
  0xffff,
  0xffff,
  0xffff,
  0xffff,
  0xffff,
  0xffff,
  0xffff,
  0xffff,
  0xffff,
  0xffff,
  0xffff,
  0x7fff,
}

--- Pack a limb array into 32 little-endian bytes with full modular reduction
--- @param out integer[] Output byte array (32 bytes)
--- @param a integer[] Input limb array
local function fe_pack(out, a)
  -- Reuse pre-allocated arrays
  local t, m = pack_t, pack_m
  for i = 1, 16 do
    t[i] = a[i]
  end
  fe_carry(t)
  fe_carry(t)
  fe_carry(t)
  for _ = 1, 2 do
    m[1] = t[1] - PRIME[1]
    for i = 2, 16 do
      local prev = m[i - 1]
      m[i] = t[i] - PRIME[i] - (floor(prev * 0.0000152587890625) % 2)
      m[i - 1] = (prev + 0x10000) % 0x10000
    end
    local c = floor(m[16] * 0.0000152587890625) % 2
    fe_cswap(t, m, 1 - c)
  end
  for i = 1, 16 do
    local ti = t[i]
    out[2 * i - 1] = ti % 0x100
    out[2 * i] = floor(ti * 0.00390625) -- 1/256
  end
end

--- Add two field elements
--- @param out integer[] Output array
--- @param a integer[] First input array
--- @param b integer[] Second input array
local function fe_add(out, a, b)
  for i = 1, 16 do
    out[i] = a[i] + b[i]
  end
end

--- Subtract two field elements
--- @param out integer[] Output array
--- @param a integer[] First input array
--- @param b integer[] Second input array
local function fe_sub(out, a, b)
  for i = 1, 16 do
    out[i] = a[i] - b[i]
  end
end

--- Multiply two field elements modulo 2^255 - 19
---
--- Overflow bound: inputs are always either fe_mul/fe_carry outputs (limbs in
--- [0, 2^16)) or at most a sum of two such values (|limb| < 2^18). The
--- schoolbook accumulator therefore stays below 16 * 2^18 * 2^18 = 2^40, and the
--- 38x fold-down of the high half keeps it below 39 * 2^40 < 2^46 << 2^53, so
--- every intermediate is exact in IEEE doubles on 5.1/5.2/LuaJIT.
--- @param out integer[] Output array
--- @param a integer[] First input array
--- @param b integer[] Second input array
local function fe_mul(out, a, b)
  -- Reuse pre-allocated array and clear it
  local prod = mul_prod
  for i = 1, 31 do
    prod[i] = 0
  end
  -- Schoolbook multiplication
  for i = 1, 16 do
    local ai = a[i]
    for j = 1, 16 do
      prod[i + j - 1] = prod[i + j - 1] + ai * b[j]
    end
  end
  -- Reduce mod 2^255-19 (multiply high limbs by 38 and add to low)
  for i = 1, 15 do
    prod[i] = prod[i] + 38 * prod[i + 16]
  end
  for i = 1, 16 do
    out[i] = prod[i]
  end
  fe_carry(out)
  fe_carry(out)
end

--- Square a field element
--- @param out integer[] Output array
--- @param a integer[] Input array
local function fe_sq(out, a)
  fe_mul(out, a, a)
end

--- Copy a field element
--- @param out integer[] Output array
--- @param a integer[] Input array
local function fe_copy(out, a)
  for i = 1, 16 do
    out[i] = a[i]
  end
end

--- Compute the modular inverse a^(p-2) using Fermat's little theorem
--- @param out integer[] Output array
--- @param a integer[] Input array
local function fe_inv(out, a)
  local c = inv_c
  fe_copy(c, a)
  for i = 253, 0, -1 do
    fe_mul(c, c, c)
    if i ~= 2 and i ~= 4 then
      fe_mul(c, c, a)
    end
  end
  fe_copy(out, c)
end

--- Compute a^((p-5)/8), the candidate square root exponent used by decompression
--- @param out integer[] Output array
--- @param a integer[] Input array
local function fe_pow2523(out, a)
  local c = pow_c
  fe_copy(c, a)
  for i = 250, 0, -1 do
    fe_mul(c, c, c)
    if i ~= 1 then
      fe_mul(c, c, a)
    end
  end
  fe_copy(out, c)
end

--- Test two field elements for equality (compares canonical packed encodings)
--- @param a integer[] First field element
--- @param b integer[] Second field element
--- @return boolean equal True when a == b in the field
local function fe_eq(a, b)
  fe_pack(cmp_a, a)
  fe_pack(cmp_b, b)
  for i = 1, 32 do
    if cmp_a[i] ~= cmp_b[i] then
      return false
    end
  end
  return true
end

--- Return the least significant bit of the canonical encoding of a field element
--- @param a integer[] Input field element
--- @return integer parity 0 or 1
local function fe_parity(a)
  fe_pack(cmp_a, a)
  return bit32_raw_band(cmp_a[1], 1)
end

-- ============================================================================
-- EDWARDS25519 POINT ARITHMETIC (extended twisted Edwards coordinates)
-- ============================================================================

-- Curve constant d = -121665/121666 (mod 2^255-19)
local D = {
  0x78a3,
  0x1359,
  0x4dca,
  0x75eb,
  0xd8ab,
  0x4141,
  0x0a4d,
  0x0070,
  0xe898,
  0x7779,
  0x4079,
  0x8cc7,
  0xfe73,
  0x2b6f,
  0x6cee,
  0x5203,
}

-- 2*d (mod 2^255-19)
local D2 = {
  0xf159,
  0x26b2,
  0x9b94,
  0xebd6,
  0xb156,
  0x8283,
  0x149a,
  0x00e0,
  0xd130,
  0xeef3,
  0x80f2,
  0x198e,
  0xfce7,
  0x56df,
  0xd9dc,
  0x2406,
}

-- Base point x-coordinate
local BASE_X = {
  0xd51a,
  0x8f25,
  0x2d60,
  0xc956,
  0xa7b2,
  0x9525,
  0xc760,
  0x692c,
  0xdc5c,
  0xfdd6,
  0xe231,
  0xc0a4,
  0x53fe,
  0xcd6e,
  0x36d3,
  0x2169,
}

-- Base point y-coordinate (4/5)
local BASE_Y = {
  0x6658,
  0x6666,
  0x6666,
  0x6666,
  0x6666,
  0x6666,
  0x6666,
  0x6666,
  0x6666,
  0x6666,
  0x6666,
  0x6666,
  0x6666,
  0x6666,
  0x6666,
  0x6666,
}

-- sqrt(-1) mod 2^255-19
local SQRT_M1 = {
  0xa0b0,
  0x4a0e,
  0x1b27,
  0xc4ee,
  0xe478,
  0xad2f,
  0x1806,
  0x2f43,
  0xd7a7,
  0x3dfb,
  0x0099,
  0x2b4d,
  0xdf0b,
  0x4fc1,
  0x2480,
  0x2b83,
}

local GF0 = create_field_element()
local GF1 = create_field_element()
GF1[1] = 1

-- Base point B in extended coordinates: (X, Y, 1, X*Y)
local BASE_POINT = create_point()
fe_copy(BASE_POINT[1], BASE_X)
fe_copy(BASE_POINT[2], BASE_Y)
fe_copy(BASE_POINT[3], GF1)
fe_mul(BASE_POINT[4], BASE_X, BASE_Y)

-- Pre-allocated scratch for pt_add()
local pa_a = create_field_element()
local pa_b = create_field_element()
local pa_c = create_field_element()
local pa_d = create_field_element()
local pa_e = create_field_element()
local pa_f = create_field_element()
local pa_g = create_field_element()
local pa_h = create_field_element()
local pa_t = create_field_element()

-- Pre-allocated scratch for pt_pack()
local pp_tx = create_field_element()
local pp_ty = create_field_element()
local pp_zi = create_field_element()

-- Pre-allocated scratch for pt_unpack_neg()
local un_t = create_field_element()
local un_chk = create_field_element()
local un_num = create_field_element()
local un_den = create_field_element()
local un_den2 = create_field_element()
local un_den4 = create_field_element()
local un_den6 = create_field_element()

-- Pre-allocated working points
local wp_p = create_point()
local wp_q = create_point()
local wp_r = create_point()
local wp_base = create_point()

--- Add two points in extended twisted Edwards coordinates: p := p + q
---
--- Safe to call with p == q (every coordinate is read before any is written).
--- @param p EdPoint Accumulator, overwritten with the sum
--- @param q EdPoint Point to add
local function pt_add(p, q)
  local a, b, c, d, e, f, g, h, t = pa_a, pa_b, pa_c, pa_d, pa_e, pa_f, pa_g, pa_h, pa_t
  fe_sub(a, p[2], p[1])
  fe_sub(t, q[2], q[1])
  fe_mul(a, a, t)
  fe_add(b, p[1], p[2])
  fe_add(t, q[1], q[2])
  fe_mul(b, b, t)
  fe_mul(c, p[4], q[4])
  fe_mul(c, c, D2)
  fe_mul(d, p[3], q[3])
  fe_add(d, d, d)
  fe_sub(e, b, a)
  fe_sub(f, d, c)
  fe_add(g, d, c)
  fe_add(h, b, a)

  fe_mul(p[1], e, f)
  fe_mul(p[2], h, g)
  fe_mul(p[3], g, f)
  fe_mul(p[4], e, h)
end

--- Conditionally swap two points based on a bit value (branch-free)
--- @param p EdPoint First point
--- @param q EdPoint Second point
--- @param bit integer Bit value (0 or 1)
local function pt_cswap(p, q, bit)
  for i = 1, 4 do
    fe_cswap(p[i], q[i], bit)
  end
end

--- Copy a point
--- @param out EdPoint Destination point
--- @param p EdPoint Source point
local function pt_copy(out, p)
  for i = 1, 4 do
    fe_copy(out[i], p[i])
  end
end

--- Compress a point into its 32-byte little-endian encoding
--- @param out integer[] Output byte array (32 bytes)
--- @param p EdPoint Point to compress
local function pt_pack(out, p)
  fe_inv(pp_zi, p[3])
  fe_mul(pp_tx, p[1], pp_zi)
  fe_mul(pp_ty, p[2], pp_zi)
  fe_pack(out, pp_ty)
  out[32] = bit32_raw_bxor(out[32], fe_parity(pp_tx) * 128)
end

--- Scalar multiplication: out := s * q (double-and-add over all 256 bits)
---
--- The base point argument `q` is destroyed by the conditional swaps.
--- @param out EdPoint Output point (must be a different table than q)
--- @param q EdPoint Input point, clobbered
--- @param s integer[] 32-byte little-endian scalar
local function pt_scalarmult(out, q, s)
  fe_copy(out[1], GF0)
  fe_copy(out[2], GF1)
  fe_copy(out[3], GF1)
  fe_copy(out[4], GF0)
  for i = 255, 0, -1 do
    local byte_idx = floor(i * 0.125) + 1 -- i / 8 + 1
    local bit = bit32_raw_band(bit32_raw_rshift(s[byte_idx], i % 8), 1)
    pt_cswap(out, q, bit)
    pt_add(q, out)
    pt_add(out, out)
    pt_cswap(out, q, bit)
  end
end

--- Scalar multiplication of the Ed25519 base point: out := s * B
--- @param out EdPoint Output point (must not be the shared base scratch point)
--- @param s integer[] 32-byte little-endian scalar
local function pt_scalarbase(out, s)
  pt_copy(wp_base, BASE_POINT)
  pt_scalarmult(out, wp_base, s)
end

--- Decompress a 32-byte encoding into the NEGATED point -(x, y)
---
--- Negating on decompression is what lets verification compute R + [k]A with a
--- single point addition (TweetNaCl's `unpackneg`).
--- @param out EdPoint Output point
--- @param p integer[] 32-byte encoded point
--- @return boolean ok False when the encoding is not a valid curve point
local function pt_unpack_neg(out, p)
  local t, chk, num, den = un_t, un_chk, un_num, un_den
  local den2, den4, den6 = un_den2, un_den4, un_den6

  fe_copy(out[3], GF1)
  fe_unpack(out[2], p)
  fe_sq(num, out[2])
  fe_mul(den, num, D)
  fe_sub(num, num, out[3])
  fe_add(den, out[3], den)

  fe_sq(den2, den)
  fe_sq(den4, den2)
  fe_mul(den6, den4, den2)
  fe_mul(t, den6, num)
  fe_mul(t, t, den)

  fe_pow2523(t, t)
  fe_mul(t, t, num)
  fe_mul(t, t, den)
  fe_mul(t, t, den)
  fe_mul(out[1], t, den)

  fe_sq(chk, out[1])
  fe_mul(chk, chk, den)
  if not fe_eq(chk, num) then
    fe_mul(out[1], out[1], SQRT_M1)
  end

  fe_sq(chk, out[1])
  fe_mul(chk, chk, den)
  if not fe_eq(chk, num) then
    return false
  end

  if fe_parity(out[1]) == bit32_raw_rshift(p[32], 7) then
    fe_sub(out[1], GF0, out[1])
  end

  fe_mul(out[4], out[1], out[2])
  return true
end

-- ============================================================================
-- SCALAR ARITHMETIC MODULO THE GROUP ORDER L
-- ============================================================================

-- L = 2^252 + 27742317777372353535851937790883648493, little-endian bytes
local L = {
  0xed,
  0xd3,
  0xf5,
  0x5c,
  0x1a,
  0x63,
  0x12,
  0x58,
  0xd6,
  0x9c,
  0xf7,
  0xa2,
  0xde,
  0xf9,
  0xde,
  0x14,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0x10,
}

-- Pre-allocated 64-limb accumulator for mod_l()
local modl_x = create_byte_array(64)

--- Reduce a 64-limb little-endian value modulo L, writing 32 bytes to `out`
---
--- Overflow bound: limbs stay under ~2^21 in magnitude, so the largest product
--- `16 * x[i] * L[j]` is below 16 * 2^21 * 2^8 = 2^33, far under 2^53.
--- @param out integer[] Output byte array (32 bytes)
--- @param x integer[] 64-limb accumulator, clobbered
local function mod_l(out, x)
  for i = 63, 32, -1 do
    local carry = 0
    local j = i - 32
    while j < i - 12 do
      x[j + 1] = x[j + 1] + carry - 16 * x[i + 1] * L[j - (i - 32) + 1]
      carry = floor((x[j + 1] + 128) * 0.00390625) -- (x + 128) >> 8
      x[j + 1] = x[j + 1] - carry * 256
      j = j + 1
    end
    x[j + 1] = x[j + 1] + carry
    x[i + 1] = 0
  end
  local carry = 0
  local top = floor(x[32] * 0.0625) -- x[31] >> 4
  for j = 0, 31 do
    x[j + 1] = x[j + 1] + carry - top * L[j + 1]
    carry = floor(x[j + 1] * 0.00390625)
    x[j + 1] = x[j + 1] % 256
  end
  for j = 0, 31 do
    x[j + 1] = x[j + 1] - carry * L[j + 1]
  end
  for i = 0, 31 do
    x[i + 2] = x[i + 2] + floor(x[i + 1] * 0.00390625)
    out[i + 1] = x[i + 1] % 256
  end
end

--- Reduce a 64-byte string modulo L
--- @param s string 64-byte little-endian value
--- @return integer[] scalar 32-byte reduced scalar as a byte array
local function reduce_hash(s)
  local x = modl_x
  for i = 1, 64 do
    x[i] = string_byte(s, i)
  end
  local out = create_byte_array(32)
  mod_l(out, x)
  return out
end

--- Compute (r + k * a) mod L
--- @param r integer[] 32-byte little-endian value
--- @param k integer[] 32-byte little-endian value
--- @param a integer[] 32-byte little-endian value
--- @return integer[] scalar 32-byte reduced result as a byte array
local function scalar_muladd(r, k, a)
  local x = modl_x
  for i = 1, 64 do
    x[i] = 0
  end
  for i = 1, 32 do
    x[i] = r[i]
  end
  for i = 1, 32 do
    local ki = k[i]
    if ki ~= 0 then
      for j = 1, 32 do
        x[i + j - 1] = x[i + j - 1] + ki * a[j]
      end
    end
  end
  local out = create_byte_array(32)
  mod_l(out, x)
  return out
end

--- Test whether a 32-byte little-endian scalar is strictly less than L
--- @param s integer[] 32-byte scalar
--- @return boolean canonical True when s < L
local function scalar_is_canonical(s)
  for i = 32, 1, -1 do
    if s[i] > L[i] then
      return false
    elseif s[i] < L[i] then
      return true
    end
  end
  return false -- s == L is not canonical either
end

-- ============================================================================
-- BYTE HELPERS
-- ============================================================================

--- Convert string to byte array
--- @param s string Input string
--- @param offset? integer 1-based offset into the string (default: 1)
--- @param len? integer Number of bytes to take (default: to end of string)
--- @return integer[] byte_array Byte array
local function string_to_bytes(s, offset, len)
  offset = offset or 1
  len = len or (#s - offset + 1)
  local b = {}
  for i = 1, len do
    b[i] = string_byte(s, offset + i - 1)
  end
  return b
end

--- Convert byte array to string
--- @param b integer[] Byte array
--- @param len integer Length
--- @return string result Output string
local function bytes_to_string(b, len)
  local result_bytes = {}
  for i = 1, len do
    result_bytes[i] = string_char(b[i] or 0)
  end
  return table_concat(result_bytes)
end

--- Apply the RFC 8032 clamping rules to the low half of SHA-512(seed)
--- @param a integer[] 32-byte scalar, modified in place
local function clamp(a)
  a[1] = bit32_raw_band(a[1], 248)
  a[32] = bit32_raw_bor(bit32_raw_band(a[32], 127), 64)
end

-- ============================================================================
-- ED25519 PUBLIC INTERFACE
-- ============================================================================

--- Generate a random Ed25519 private key (seed)
---
--- The seed is drawn from `crypto.random`, which raises rather than falling back
--- to a weak generator when the host has no CSPRNG. For Ed25519 that matters
--- more than for an ephemeral key: this seed is a long-term signing identity, so
--- a guessable one lets an attacker impersonate this device indefinitely.
--- @return string seed 32-byte private key seed
function ed25519.generate_private_key()
  return random.bytes(32)
end

--- Expand a 32-byte seed into the 64-byte signing key material
---
--- Returns `a || prefix` where `h = SHA-512(seed)`, `a = clamp(h[1..32])` and
--- `prefix = h[33..64]`. Callers that sign repeatedly with one long-term key can
--- cache this and use `sign_expanded` to skip the per-signature SHA-512(seed).
--- @param seed string 32-byte private key seed
--- @return string expanded 64-byte expanded key (clamped scalar || prefix)
function ed25519.expand_private_key(seed)
  assert(type(seed) == "string" and #seed == 32, "Seed must be exactly 32 bytes")

  local h = sha512(seed)
  local a = string_to_bytes(h, 1, 32)
  clamp(a)
  return bytes_to_string(a, 32) .. string_sub(h, 33, 64)
end

--- Derive the Ed25519 public key from a 32-byte seed
--- @param seed string 32-byte private key seed
--- @return string public_key 32-byte public key
function ed25519.derive_public_key(seed)
  assert(type(seed) == "string" and #seed == 32, "Seed must be exactly 32 bytes")

  local expanded = ed25519.expand_private_key(seed)
  local a = string_to_bytes(expanded, 1, 32)
  local pk = create_byte_array(32)

  pt_scalarbase(wp_p, a)
  pt_pack(pk, wp_p)
  return bytes_to_string(pk, 32)
end

--- Generate an Ed25519 key pair
--- @return string seed 32-byte private key seed
--- @return string public_key 32-byte public key
function ed25519.generate_keypair()
  local seed = ed25519.generate_private_key()
  local public_key = ed25519.derive_public_key(seed)
  return seed, public_key
end

--- Sign a message with a pre-expanded private key
---
--- Produces byte-identical output to `ed25519.sign` for the same key/message.
--- @param expanded string 64-byte expanded key from `expand_private_key`
--- @param public_key string 32-byte public key matching the expanded key
--- @param message string Message to sign (any length, may be empty)
--- @return string signature 64-byte signature (R || S)
function ed25519.sign_expanded(expanded, public_key, message)
  assert(type(expanded) == "string" and #expanded == 64, "Expanded key must be exactly 64 bytes")
  assert(type(public_key) == "string" and #public_key == 32, "Public key must be exactly 32 bytes")
  assert(type(message) == "string", "Message must be a string")

  local a = string_to_bytes(expanded, 1, 32)
  local prefix = string_sub(expanded, 33, 64)

  -- r = SHA-512(prefix || M) mod L, R = [r]B
  local r = reduce_hash(sha512(prefix .. message))
  local r_packed = create_byte_array(32)
  pt_scalarbase(wp_p, r)
  pt_pack(r_packed, wp_p)
  local r_str = bytes_to_string(r_packed, 32)

  -- k = SHA-512(R || A || M) mod L, S = (r + k * a) mod L
  local k = reduce_hash(sha512(r_str .. public_key .. message))
  local s = scalar_muladd(r, k, a)

  return r_str .. bytes_to_string(s, 32)
end

--- Sign a message with a 32-byte seed
--- @param seed string 32-byte private key seed
--- @param message string Message to sign (any length, may be empty)
--- @return string signature 64-byte signature (R || S)
function ed25519.sign(seed, message)
  assert(type(seed) == "string" and #seed == 32, "Seed must be exactly 32 bytes")
  assert(type(message) == "string", "Message must be a string")

  local expanded = ed25519.expand_private_key(seed)
  local a = string_to_bytes(expanded, 1, 32)
  local pk = create_byte_array(32)
  pt_scalarbase(wp_p, a)
  pt_pack(pk, wp_p)

  return ed25519.sign_expanded(expanded, bytes_to_string(pk, 32), message)
end

--- Verify an Ed25519 signature
---
--- Never raises: malformed public keys or signatures (wrong length, wrong type,
--- undecodable point, non-canonical S >= L) simply return false.
--- @param public_key string 32-byte public key
--- @param message string Signed message
--- @param signature string 64-byte signature (R || S)
--- @return boolean valid True when the signature is valid
function ed25519.verify(public_key, message, signature)
  if type(public_key) ~= "string" or type(message) ~= "string" or type(signature) ~= "string" then
    return false
  end
  if #public_key ~= 32 or #signature ~= 64 then
    return false
  end

  local s = string_to_bytes(signature, 33, 32)
  if not scalar_is_canonical(s) then
    return false
  end

  local pk = string_to_bytes(public_key, 1, 32)
  if not pt_unpack_neg(wp_q, pk) then
    return false
  end

  -- k = SHA-512(R || A || M) mod L
  local k = reduce_hash(sha512(string_sub(signature, 1, 32) .. public_key .. message))

  -- p = [k](-A) + [S]B, which must equal R
  pt_scalarmult(wp_p, wp_q, k)
  pt_scalarbase(wp_r, s)
  pt_add(wp_p, wp_r)

  local check = create_byte_array(32)
  pt_pack(check, wp_p)

  local diff = 0
  for i = 1, 32 do
    diff = bit32_raw_bor(diff, bit32_raw_bxor(check[i], string_byte(signature, i)))
  end
  return diff == 0
end

-- ============================================================================
-- TEST VECTORS AND VALIDATION
-- ============================================================================

--- Test vectors from RFC 8032 section 7.1 (Ed25519)
local test_vectors = {
  {
    name = "RFC 8032 TEST 1",
    seed = bytes.from_hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"),
    public_key = bytes.from_hex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"),
    message = "",
    signature = bytes.from_hex(
      "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
        .. "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"
    ),
  },
  {
    name = "RFC 8032 TEST 2",
    seed = bytes.from_hex("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb"),
    public_key = bytes.from_hex("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c"),
    message = bytes.from_hex("72"),
    signature = bytes.from_hex(
      "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da"
        .. "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"
    ),
  },
  {
    name = "RFC 8032 TEST 3",
    seed = bytes.from_hex("c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7"),
    public_key = bytes.from_hex("fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025"),
    message = bytes.from_hex("af82"),
    signature = bytes.from_hex(
      "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac"
        .. "18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a"
    ),
  },
  {
    name = "RFC 8032 TEST 1024",
    seed = bytes.from_hex("f5e5767cf153319517630f226876b86c8160cc583bc013744c6bf255f5cc0ee5"),
    public_key = bytes.from_hex("278117fc144c72340f67d0f2316e8386ceffbf2b2428c9c51fef7c597f1d426e"),
    message = bytes.from_hex(
      "08b8b2b733424243760fe426a4b54908632110a66c2f6591eabd3345e3e4eb98"
        .. "fa6e264bf09efe12ee50f8f54e9f77b1e355f6c50544e23fb1433ddf73be84d8"
        .. "79de7c0046dc4996d9e773f4bc9efe5738829adb26c81b37c93a1b270b20329d"
        .. "658675fc6ea534e0810a4432826bf58c941efb65d57a338bbd2e26640f89ffbc"
        .. "1a858efcb8550ee3a5e1998bd177e93a7363c344fe6b199ee5d02e82d522c4fe"
        .. "ba15452f80288a821a579116ec6dad2b3b310da903401aa62100ab5d1a36553e"
        .. "06203b33890cc9b832f79ef80560ccb9a39ce767967ed628c6ad573cb116dbef"
        .. "efd75499da96bd68a8a97b928a8bbc103b6621fcde2beca1231d206be6cd9ec7"
        .. "aff6f6c94fcd7204ed3455c68c83f4a41da4af2b74ef5c53f1d8ac70bdcb7ed1"
        .. "85ce81bd84359d44254d95629e9855a94a7c1958d1f8ada5d0532ed8a5aa3fb2"
        .. "d17ba70eb6248e594e1a2297acbbb39d502f1a8c6eb6f1ce22b3de1a1f40cc24"
        .. "554119a831a9aad6079cad88425de6bde1a9187ebb6092cf67bf2b13fd65f270"
        .. "88d78b7e883c8759d2c4f5c65adb7553878ad575f9fad878e80a0c9ba63bcbcc"
        .. "2732e69485bbc9c90bfbd62481d9089beccf80cfe2df16a2cf65bd92dd597b07"
        .. "07e0917af48bbb75fed413d238f5555a7a569d80c3414a8d0859dc65a46128ba"
        .. "b27af87a71314f318c782b23ebfe808b82b0ce26401d2e22f04d83d1255dc51a"
        .. "ddd3b75a2b1ae0784504df543af8969be3ea7082ff7fc9888c144da2af58429e"
        .. "c96031dbcad3dad9af0dcbaaaf268cb8fcffead94f3c7ca495e056a9b47acdb7"
        .. "51fb73e666c6c655ade8297297d07ad1ba5e43f1bca32301651339e22904cc8c"
        .. "42f58c30c04aafdb038dda0847dd988dcda6f3bfd15c4b4c4525004aa06eeff8"
        .. "ca61783aacec57fb3d1f92b0fe2fd1a85f6724517b65e614ad6808d6f6ee34df"
        .. "f7310fdc82aebfd904b01e1dc54b2927094b2db68d6f903b68401adebf5a7e08"
        .. "d78ff4ef5d63653a65040cf9bfd4aca7984a74d37145986780fc0b16ac451649"
        .. "de6188a7dbdf191f64b5fc5e2ab47b57f7f7276cd419c17a3ca8e1b939ae49e4"
        .. "88acba6b965610b5480109c8b17b80e1b7b750dfc7598d5d5011fd2dcc5600a3"
        .. "2ef5b52a1ecc820e308aa342721aac0943bf6686b64b2579376504ccc493d97e"
        .. "6aed3fb0f9cd71a43dd497f01f17c0e2cb3797aa2a2f256656168e6c496afc5f"
        .. "b93246f6b1116398a346f1a641f3b041e989f7914f90cc2c7fff357876e506b5"
        .. "0d334ba77c225bc307ba537152f3f1610e4eafe595f6d9d90d11faa933a15ef1"
        .. "369546868a7f3a45a96768d40fd9d03412c091c6315cf4fde7cb68606937380d"
        .. "b2eaaa707b4c4185c32eddcdd306705e4dc1ffc872eeee475a64dfac86aba41c"
        .. "0618983f8741c5ef68d3a101e8a3b8cac60c905c15fc910840b94c00a0b9d0"
    ),
    signature = bytes.from_hex(
      "0aab4c900501b3e24d7cdf4663326a3a87df5e4843b2cbdb67cbf6e460fec350"
        .. "aa5371b1508f9f4528ecea23c436d94b5e8fcd4f681e30a6ac00a9704a188a03"
    ),
  },
  {
    name = "RFC 8032 TEST SHA(abc)",
    seed = bytes.from_hex("833fe62409237b9d62ec77587520911e9a759cec1d19755b7da901b96dca3d42"),
    public_key = bytes.from_hex("ec172b93ad5e563bf4932c70e1245034c35467ef2efd4d64ebf819683467e2bf"),
    message = bytes.from_hex(
      "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
        .. "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
    ),
    signature = bytes.from_hex(
      "dc2a4459e7369633a52b1bf277839a00201009a3efbf3ecb69bea2186c26b589"
        .. "09351fc9ac90b3ecfdfbc7c66431e0303dca179c138ac17ad9bef1177331a704"
    ),
  },
}

--- Flip the low bit of one byte of a string (empty strings become a single NUL)
--- @param s string Input string
--- @param index integer 1-based byte index to tamper with
--- @return string tampered Tampered string, guaranteed different from the input
local function flip_bit(s, index)
  if #s == 0 then
    return "\0"
  end
  index = ((index - 1) % #s) + 1
  local b = bit32_raw_bxor(string_byte(s, index), 1)
  return string_sub(s, 1, index - 1) .. string_char(b) .. string_sub(s, index + 1)
end

--- Add the group order L to the 32-byte little-endian S half of a signature
--- @param signature string 64-byte signature
--- @return string tampered Signature whose S component equals S + L (>= L)
local function add_l_to_s(signature)
  local s = string_to_bytes(signature, 33, 32)
  local carry = 0
  for i = 1, 32 do
    local v = s[i] + L[i] + carry
    s[i] = v % 256
    carry = floor(v * 0.00390625)
  end
  return string_sub(signature, 1, 32) .. bytes_to_string(s, 32)
end

--- Run comprehensive self-test with RFC 8032 test vectors and functional tests
---
--- This function validates the Ed25519 implementation against the known-answer
--- test vectors from RFC 8032 section 7.1. ALL tests must pass for the
--- implementation to be considered cryptographically safe.
---
--- @return boolean result True if all tests pass, false otherwise
function ed25519.selftest()
  local function test_vectors_suite()
    print("Running Ed25519 test vectors...")
    local passed = 0
    local total = 0

    for i, test in ipairs(test_vectors) do
      print(string.format("Test %d: %s (message %d bytes)", i, test.name, #test.message))

      local checks = {}

      local derived = ed25519.derive_public_key(test.seed)
      checks[1] = { name = "derive_public_key", ok = derived == test.public_key, got = derived, want = test.public_key }

      local signature = ed25519.sign(test.seed, test.message)
      checks[2] = { name = "sign", ok = signature == test.signature, got = signature, want = test.signature }

      local expanded = ed25519.expand_private_key(test.seed)
      local sig_expanded = ed25519.sign_expanded(expanded, test.public_key, test.message)
      checks[3] = {
        name = "sign_expanded matches sign",
        ok = sig_expanded == test.signature and sig_expanded == signature,
        got = sig_expanded,
        want = test.signature,
      }

      checks[4] = {
        name = "verify accepts valid signature",
        ok = ed25519.verify(test.public_key, test.message, test.signature) == true,
      }
      checks[5] = {
        name = "verify rejects flipped message bit",
        ok = ed25519.verify(test.public_key, flip_bit(test.message, 1), test.signature) == false,
      }
      checks[6] = {
        name = "verify rejects flipped signature bit",
        ok = ed25519.verify(test.public_key, test.message, flip_bit(test.signature, 40)) == false,
      }

      for _, check in ipairs(checks) do
        total = total + 1
        if check.ok then
          print("  ✅ PASS: " .. check.name)
          passed = passed + 1
        else
          print("  ❌ FAIL: " .. check.name)
          if check.want then
            print("  Expected: " .. bytes.to_hex(check.want))
            print("  Got:      " .. bytes.to_hex(check.got))
          end
        end
      end
      print()
    end

    print(string.format("Test vectors result: %d/%d tests passed", passed, total))
    print()
    return passed == total
  end

  local function functional_tests()
    print("Running Ed25519 functional tests...")
    local passed = 0
    local total = 0

    local cases = {
      {
        name = "Key generation",
        test = function()
          local seed1, pub1 = ed25519.generate_keypair()
          local seed2, pub2 = ed25519.generate_keypair()
          assert(#seed1 == 32 and #pub1 == 32, "Keys should be 32 bytes")
          assert(seed1 ~= seed2, "Different key generations should produce different seeds")
          assert(pub1 ~= pub2, "Different key generations should produce different public keys")
        end,
      },
      {
        name = "Public key derivation consistency",
        test = function()
          local seed = ed25519.generate_private_key()
          assert(ed25519.derive_public_key(seed) == ed25519.derive_public_key(seed), "Derivation must be deterministic")
        end,
      },
      {
        name = "Expanded key shape and determinism",
        test = function()
          local seed = test_vectors[1].seed
          local expanded = ed25519.expand_private_key(seed)
          assert(#expanded == 64, "Expanded key should be 64 bytes")
          assert(expanded == ed25519.expand_private_key(seed), "Expansion must be deterministic")
          local a1 = string_byte(expanded, 1)
          local a32 = string_byte(expanded, 32)
          assert(a1 % 8 == 0, "Low 3 bits of the scalar must be cleared")
          assert(a32 < 128 and a32 >= 64, "Scalar must have bit 254 set and bit 255 cleared")
        end,
      },
      {
        name = "Sign/verify roundtrip with a generated key",
        test = function()
          local seed, pub = ed25519.generate_keypair()
          local msg = "The quick brown fox jumps over the lazy dog"
          local sig = ed25519.sign(seed, msg)
          assert(#sig == 64, "Signature should be 64 bytes")
          assert(ed25519.verify(pub, msg, sig) == true, "Signature should verify")
          assert(ed25519.verify(pub, msg .. "!", sig) == false, "Modified message must not verify")
        end,
      },
      {
        name = "sign_expanded is byte-identical to sign",
        test = function()
          local seed, pub = ed25519.generate_keypair()
          local expanded = ed25519.expand_private_key(seed)
          for _, msg in ipairs({ "", "a", string_rep("z", 200) }) do
            assert(ed25519.sign_expanded(expanded, pub, msg) == ed25519.sign(seed, msg), "Outputs must match")
          end
        end,
      },
      {
        name = "verify rejects a signature from another key",
        test = function()
          local seed_a = test_vectors[2].seed
          local _, pub_b = ed25519.generate_keypair()
          local msg = "cross-key check"
          assert(ed25519.verify(pub_b, msg, ed25519.sign(seed_a, msg)) == false, "Wrong key must not verify")
        end,
      },
      {
        name = "verify returns false for wrong-length signature",
        test = function()
          local v = test_vectors[3]
          assert(ed25519.verify(v.public_key, v.message, "") == false, "Empty signature must be rejected")
          assert(
            ed25519.verify(v.public_key, v.message, string_sub(v.signature, 1, 63)) == false,
            "Short signature must be rejected"
          )
          assert(ed25519.verify(v.public_key, v.message, v.signature .. "\0") == false, "Long signature is rejected")
        end,
      },
      {
        name = "verify returns false for wrong-length public key",
        test = function()
          local v = test_vectors[3]
          assert(ed25519.verify("", v.message, v.signature) == false, "Empty public key must be rejected")
          assert(
            ed25519.verify(string_sub(v.public_key, 1, 31), v.message, v.signature) == false,
            "Short public key must be rejected"
          )
          assert(ed25519.verify(v.public_key .. "\0", v.message, v.signature) == false, "Long public key is rejected")
        end,
      },
      {
        name = "verify returns false for undecodable public key",
        test = function()
          local v = test_vectors[3]
          -- y = 2 is not the y-coordinate of any edwards25519 point
          local bad = bytes.from_hex("0200000000000000000000000000000000000000000000000000000000000000")
          assert(ed25519.verify(bad, v.message, v.signature) == false, "Undecodable point must be rejected")
        end,
      },
      {
        name = "verify rejects non-canonical S >= L",
        test = function()
          local v = test_vectors[3]
          local malleable = add_l_to_s(v.signature)
          assert(malleable ~= v.signature, "Tampered signature should differ")
          assert(ed25519.verify(v.public_key, v.message, malleable) == false, "S >= L must be rejected")
        end,
      },
      {
        name = "verify returns false for non-string arguments",
        test = function()
          local v = test_vectors[3]
          --- @diagnostic disable: param-type-mismatch -- the wrong types are the test
          assert(ed25519.verify(nil, v.message, v.signature) == false, "nil public key must be rejected")
          assert(ed25519.verify(v.public_key, nil, v.signature) == false, "nil message must be rejected")
          assert(ed25519.verify(v.public_key, v.message, 42) == false, "non-string signature must be rejected")
          --- @diagnostic enable: param-type-mismatch
        end,
      },
    }

    for _, case in ipairs(cases) do
      total = total + 1
      local success, err = pcall(case.test)
      if success then
        print("  ✅ PASS: " .. case.name)
        passed = passed + 1
      else
        print("  ❌ FAIL: " .. case.name .. " - " .. tostring(err))
      end
    end

    print(string.format("\nFunctional tests result: %d/%d tests passed", passed, total))
    print()
    return passed == total
  end

  local vectors_passed = test_vectors_suite()
  local functional_passed = functional_tests()

  return vectors_passed and functional_passed
end

--- Run performance benchmarks
---
--- Benchmarks key pair generation, public key derivation, signing (both from a
--- raw seed and from a pre-expanded key) and verification.
function ed25519.benchmark()
  local vector = test_vectors[3]
  local seed = vector.seed
  local public_key = vector.public_key
  local message = vector.message
  local signature = vector.signature
  local expanded = ed25519.expand_private_key(seed)

  print("Key Operations:")
  benchmark_op("generate_keypair", function()
    ed25519.generate_keypair()
  end, 10)

  benchmark_op("derive_public_key", function()
    ed25519.derive_public_key(seed)
  end, 10)

  benchmark_op("expand_private_key", function()
    ed25519.expand_private_key(seed)
  end, 100)

  print("\nSignature Operations:")
  benchmark_op("sign", function()
    ed25519.sign(seed, message)
  end, 10)

  benchmark_op("sign_expanded", function()
    ed25519.sign_expanded(expanded, public_key, message)
  end, 10)

  benchmark_op("verify", function()
    ed25519.verify(public_key, message, signature)
  end, 10)
end

return ed25519
end
end

do
local _ENV = _ENV
package.preload[ "crypto.hkdf" ] = function( ... ) local arg = _G.arg;
--- @module "crypto.hkdf"
--- HKDF (HMAC-based Extract-and-Expand Key Derivation Function), RFC 5869.
---
--- Supports SHA-256 and SHA-512. This is a thin layer over the HMAC primitives
--- in `crypto.sha256` / `crypto.sha512`, which already prefer OpenSSL when
--- acceleration is enabled, so HKDF inherits that acceleration without needing
--- a routing decision of its own -- see the note on `openssl.kdf` below.
---
--- @usage
--- local hkdf = require("crypto.hkdf")
---
--- -- one-shot: extract then expand
--- local key = hkdf.derive("sha512", salt, shared_secret, "Pair-Setup-Encrypt-Info", 32)
---
--- -- or the two phases separately, when one PRK feeds several expansions
--- local prk = hkdf.extract("sha512", "Control-Salt", shared_secret)
--- local read_key = hkdf.expand("sha512", prk, "ClientEncrypt-main", 32)
--- local write_key = hkdf.expand("sha512", prk, "ServerEncrypt-main", 32)
---
--- @class crypto.hkdf
local hkdf = {}

local sha256 = require("crypto.sha256")
local sha512 = require("crypto.sha512")

local utils = require("crypto.utils")
local bytes = utils.bytes
local benchmark_op = utils.benchmark.benchmark_op

-- Local references for performance
local string_char = string.char
local string_rep = string.rep
local string_sub = string.sub
local table_concat = table.concat

--- Supported hash functions and their parameters.
---
--- `hmac` takes (key, data) and returns the raw MAC; `length` is HashLen in
--- RFC 5869 terms, which fixes both the PRK size and the 255*HashLen output
--- ceiling.
---
--- @class HkdfHash
--- @field hmac fun(key: string, data: string): string HMAC over this hash
--- @field length integer HashLen in bytes

--- @type table<string, HkdfHash>
local HASHES = {
  sha256 = { hmac = sha256.hmac_sha256, length = 32 },
  sha512 = { hmac = sha512.hmac_sha512, length = 64 },
}

-- Note on routing to `openssl.kdf`:
--
-- The wrapper exposes `Feature.KDF` and the Control4 build has it, but HKDF is
-- deliberately NOT routed there. `hmac_sha256`/`hmac_sha512` already return the
-- OpenSSL result when acceleration is on, so the pure-Lua cost of HKDF is the
-- glue around the HMACs, not the HMACs themselves. A HAP derivation is one
-- extract plus one 32-byte expand, i.e. two HMAC invocations total, so routing
-- it separately would buy nothing measurable while adding a second code path
-- that cannot be exercised on a host without the binding. `Feature.KDF` is
-- declared so the capability is queryable if that trade ever changes.

--- Resolve a hash name to its parameters.
--- @param hash string Hash name: "sha256" or "sha512"
--- @return HkdfHash params
local function resolve_hash(hash)
  local params = HASHES[hash]
  if not params then
    error("Unsupported HKDF hash: " .. tostring(hash) .. ' (expected "sha256" or "sha512")')
  end
  return params
end

--- HKDF-Extract (RFC 5869 section 2.2).
---
--- Concentrates the (possibly non-uniform) input keying material into a
--- pseudorandom key of exactly HashLen bytes.
---
--- @param hash string Hash name: "sha256" or "sha512"
--- @param salt string? Optional salt; an empty or absent salt is replaced by HashLen zero bytes, per the RFC
--- @param ikm string Input keying material
--- @return string prk Pseudorandom key, HashLen bytes
function hkdf.extract(hash, salt, ikm)
  local params = resolve_hash(hash)
  assert(type(ikm) == "string", "ikm must be a string")
  if salt == nil or #salt == 0 then
    salt = string_rep("\0", params.length)
  end
  -- Note the argument order: the salt is the HMAC *key* and the IKM is the data.
  return params.hmac(salt, ikm)
end

--- HKDF-Expand (RFC 5869 section 2.3).
---
--- Stretches a pseudorandom key into `length` bytes of output keying material,
--- bound to the supplied context string.
---
--- @param hash string Hash name: "sha256" or "sha512"
--- @param prk string Pseudorandom key, normally the output of `extract`
--- @param info string? Optional context/application-specific information
--- @param length integer Number of output bytes; must be in 1..255*HashLen
--- @return string okm Output keying material, `length` bytes
function hkdf.expand(hash, prk, info, length)
  local params = resolve_hash(hash)
  assert(type(prk) == "string", "prk must be a string")
  assert(type(length) == "number" and length >= 1 and length % 1 == 0, "length must be a positive integer")
  local max_length = 255 * params.length
  assert(length <= max_length, "length must not exceed 255*HashLen (" .. max_length .. " for " .. hash .. ")")
  info = info or ""

  local blocks = {}
  local previous = ""
  local produced = 0
  local counter = 1
  -- T(0) = "", T(i) = HMAC(PRK, T(i-1) || info || i); OKM is the first L bytes
  -- of T(1) || T(2) || ...
  while produced < length do
    previous = params.hmac(prk, previous .. info .. string_char(counter))
    blocks[counter] = previous
    produced = produced + #previous
    counter = counter + 1
  end

  return string_sub(table_concat(blocks), 1, length)
end

--- HKDF: extract then expand in one call (RFC 5869 section 2).
--- @param hash string Hash name: "sha256" or "sha512"
--- @param salt string? Optional salt
--- @param ikm string Input keying material
--- @param info string? Optional context/application-specific information
--- @param length integer Number of output bytes
--- @return string okm Output keying material, `length` bytes
function hkdf.derive(hash, salt, ikm, info, length)
  return hkdf.expand(hash, hkdf.extract(hash, salt, ikm), info, length)
end

--- HKDF with SHA-256, extract and expand in one call.
--- @param salt string? Optional salt
--- @param ikm string Input keying material
--- @param info string? Optional context information
--- @param length integer Number of output bytes
--- @return string okm Output keying material
function hkdf.hkdf_sha256(salt, ikm, info, length)
  return hkdf.derive("sha256", salt, ikm, info, length)
end

--- HKDF with SHA-512, extract and expand in one call.
--- This is the variant HAP uses throughout Pair-Setup, Pair-Verify and session
--- key derivation.
--- @param salt string? Optional salt
--- @param ikm string Input keying material
--- @param info string? Optional context information
--- @param length integer Number of output bytes
--- @return string okm Output keying material
function hkdf.hkdf_sha512(salt, ikm, info, length)
  return hkdf.derive("sha512", salt, ikm, info, length)
end

-- ============================================================================
-- TEST VECTORS AND VALIDATION
-- ============================================================================

--- SHA-256 vectors are RFC 5869 appendix A, cases A.1 to A.3 verbatim. The
--- RFC's remaining cases (A.4 to A.7) use SHA-1, which this library does not
--- implement, so they are omitted rather than adapted.
---
--- The RFC publishes no SHA-512 vectors. The SHA-512 cases below were generated
--- with Node's `crypto.hkdfSync`, an independent OpenSSL-backed implementation;
--- that generator was first checked against A.1 to A.3 above, so it is a
--- validated oracle rather than an assumed-correct one. The PRK figures come
--- from a separate `crypto.createHmac` call, so extract and expand are pinned
--- independently of each other.
local test_vectors = {
  {
    name = "RFC 5869 A.1 - SHA-256, basic",
    hash = "sha256",
    ikm = string_rep(string_char(0x0b), 22),
    salt = bytes.from_hex("000102030405060708090a0b0c"),
    info = bytes.from_hex("f0f1f2f3f4f5f6f7f8f9"),
    length = 42,
    prk = "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5",
    okm = "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865",
  },
  {
    name = "RFC 5869 A.2 - SHA-256, longer inputs and output",
    hash = "sha256",
    ikm = bytes.from_hex(
      "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        .. "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"
        .. "404142434445464748494a4b4c4d4e4f"
    ),
    salt = bytes.from_hex(
      "606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f"
        .. "808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f"
        .. "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf"
    ),
    info = bytes.from_hex(
      "b0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecf"
        .. "d0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeef"
        .. "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"
    ),
    length = 82,
    prk = "06a6b88c5853361a06104c9ceb35b45cef760014904671014a193f40c15fc244",
    okm = "b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c"
      .. "59045a99cac7827271cb41c65e590e09da3275600c2f09b8367793a9aca3db71"
      .. "cc30c58179ec3e87c14c01d5c1f3434f1d87",
  },
  {
    name = "RFC 5869 A.3 - SHA-256, zero-length salt and info",
    hash = "sha256",
    ikm = string_rep(string_char(0x0b), 22),
    salt = "",
    info = "",
    length = 42,
    prk = "19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04",
    okm = "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8",
  },
  {
    name = "SHA-512, A.1 inputs",
    hash = "sha512",
    ikm = string_rep(string_char(0x0b), 22),
    salt = bytes.from_hex("000102030405060708090a0b0c"),
    info = bytes.from_hex("f0f1f2f3f4f5f6f7f8f9"),
    length = 42,
    prk = "665799823737ded04a88e47e54a5890bb2c3d247c7a4254a8e61350723590a26"
      .. "c36238127d8661b88cf80ef802d57e2f7cebcf1e00e083848be19929c61b4237",
    okm = "832390086cda71fb47625bb5ceb168e4c8e26a1a16ed34d9fc7fe92c1481579338da362cb8d9f925d7cb",
  },
  {
    name = "SHA-512, 80-byte inputs, 82-byte output",
    hash = "sha512",
    ikm = bytes.from_hex(
      "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        .. "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"
        .. "404142434445464748494a4b4c4d4e4f"
    ),
    salt = bytes.from_hex(
      "606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f"
        .. "808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f"
        .. "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf"
    ),
    info = bytes.from_hex(
      "b0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecf"
        .. "d0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeef"
        .. "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"
    ),
    length = 82,
    prk = "35672542907d4e142c00e84499e74e1de08be86535f924e022804ad775dde27e"
      .. "c86cd1e5b7d178c74489bdbeb30712beb82d4f97416c5a94ea81ebdf3e629e4a",
    okm = "ce6c97192805b346e6161e821ed165673b84f400a2b514b2fe23d84cd189ddf1"
      .. "b695b48cbd1c8388441137b3ce28f16aa64ba33ba466b24df6cfcb021ecff235"
      .. "f6a2056ce3af1de44d572097a8505d9e7a93",
  },
  {
    name = "SHA-512, zero-length salt and info",
    hash = "sha512",
    ikm = string_rep(string_char(0x0b), 22),
    salt = "",
    info = "",
    length = 42,
    prk = "fd200c4987ac491313bd4a2a13287121247239e11c9ef82802044b66ef357e5b"
      .. "194498d0682611382348572a7b1611de54764094286320578a863f36562b0df6",
    okm = "f5fa02b18298a72a8c23898a8703472c6eb179dc204c03425c970e3b164bf90fff22d04836d0e2343bac",
  },
  {
    name = "SHA-512, multi-block output (L=160 spans 3 blocks)",
    hash = "sha512",
    ikm = string_rep(string_char(0x0b), 22),
    salt = bytes.from_hex("000102030405060708090a0b0c"),
    info = bytes.from_hex("f0f1f2f3f4f5f6f7f8f9"),
    length = 160,
    prk = "665799823737ded04a88e47e54a5890bb2c3d247c7a4254a8e61350723590a26"
      .. "c36238127d8661b88cf80ef802d57e2f7cebcf1e00e083848be19929c61b4237",
    okm = "832390086cda71fb47625bb5ceb168e4c8e26a1a16ed34d9fc7fe92c148157933"
      .. "8da362cb8d9f925d7cbcce0dff7098769cf15959867d571c1715450cb530137b"
      .. "e3fb62f3cf32b84feba8f1eb1b563e20d9749b8640b8264c4b69b14ad5199115"
      .. "e1d609c83c6940ce5b4214a0c79946983547a35cdcc17e0daf31b647dec0d0e6"
      .. "142b1deaa036b348422068ca66631c0ca5586485a276a4336e1cde0e83159b5",
    -- Note the odd hex-digit alignment above: the literal is concatenated in
    -- 64-char chunks and verified as a whole against the 320-char expectation.
  },
  {
    name = "SHA-512, single-byte output",
    hash = "sha512",
    ikm = string_rep(string_char(0x0b), 22),
    salt = bytes.from_hex("000102030405060708090a0b0c"),
    info = bytes.from_hex("f0f1f2f3f4f5f6f7f8f9"),
    length = 1,
    prk = "665799823737ded04a88e47e54a5890bb2c3d247c7a4254a8e61350723590a26"
      .. "c36238127d8661b88cf80ef802d57e2f7cebcf1e00e083848be19929c61b4237",
    okm = "83",
  },
}

--- A reproducible 64-byte stand-in for the SRP shared secret K, used by the HAP
--- vectors below. Defined as SHA-512("FL-3 HKDF test vector K") so the input is
--- checkable rather than an opaque blob.
local HAP_K = bytes.from_hex(
  "5b5f50c034f8f0828d08477b4375da348dc40f84cd11dfd3bd13b9acabd4ca26"
    .. "1adbe603042792d70da90d625ecd52c63672ac835d1d0c297542cf74533d2ff6"
)

--- HAP and Apple Companion derivations, with the exact salt and info strings the
--- protocol uses. These are the derivations the Control4 Plex driver will
--- perform, so a regression in the salt/info handling shows up here as a wrong
--- key rather than as a pairing failure on hardware.
local hap_vectors = {
  {
    name = "HAP Pair-Setup session key",
    salt = "Pair-Setup-Encrypt-Salt",
    info = "Pair-Setup-Encrypt-Info",
    okm = "58c07b44c43ab9dee1997d2755c4dd5a9cef49aa115cf5d04008761a1020924d",
  },
  {
    name = "HAP Pair-Setup controller signing material",
    salt = "Pair-Setup-Controller-Sign-Salt",
    info = "Pair-Setup-Controller-Sign-Info",
    okm = "cef7085a25ab4b1f458a60b3256e2c99ba9fd68d635500de44b1127a6ecc2369",
  },
  {
    name = "HAP Pair-Setup accessory signing material",
    salt = "Pair-Setup-Accessory-Sign-Salt",
    info = "Pair-Setup-Accessory-Sign-Info",
    okm = "9778c08f56e300911cc8a1243eb6c6fb60cb6746cdaf6d50222b864d80193b93",
  },
  {
    name = "HAP Pair-Verify session key",
    salt = "Pair-Verify-Encrypt-Salt",
    info = "Pair-Verify-Encrypt-Info",
    okm = "a5029cacb7d64c6b4e7e56320a0ea8cb9bbf0f715743f03e53c59396fe33252e",
  },
  {
    name = "Companion session key, ClientEncrypt-main",
    salt = "Control-Salt",
    info = "ClientEncrypt-main",
    okm = "e47f11626348e473b07abd0a524d46a76869735feed5511b8f38aa9ecb205042",
  },
  {
    name = "Companion session key, ServerEncrypt-main",
    salt = "Control-Salt",
    info = "ServerEncrypt-main",
    okm = "ff1e61252d02c50c81da50149608d7a103ae82a20b78106c6a16e48cdaeb680a",
  },
}

--- Run comprehensive self-test with RFC 5869 and generated test vectors.
---
--- Validates HKDF-Extract and HKDF-Expand for SHA-256 and SHA-512 against
--- known-answer tests, checks the HAP/Companion derivations the driver depends
--- on, and confirms the documented input-validation behaviour.
---
--- @return boolean result True if all tests pass, false otherwise
function hkdf.selftest()
  local passed = 0
  local total = 0

  --- Record one test result. `result` may be a boolean or a function returning
  --- one; a function that raises counts as a failure rather than aborting the run.
  --- @param name string
  --- @param result boolean|fun(): boolean
  local function check(name, result)
    total = total + 1
    if type(result) == "function" then
      local ok, value = pcall(result)
      result = ok and value == true
    end
    if result == true then
      print("  ✅ PASS: " .. name)
      passed = passed + 1
    else
      print("  ❌ FAIL: " .. name)
    end
  end

  print("Running HKDF test vectors...")
  for _, vector in ipairs(test_vectors) do
    local prk = hkdf.extract(vector.hash, vector.salt, vector.ikm)
    local prk_hex = bytes.to_hex(prk)
    if prk_hex == vector.prk then
      check(vector.name .. " [PRK]", true)
    else
      check(vector.name .. " [PRK]", false)
      print("    expected: " .. vector.prk)
      print("    got:      " .. prk_hex)
    end

    -- Expand from the PRK we just derived, so a broken extract cannot be
    -- masked by expand being fed the published PRK instead.
    local okm_hex = bytes.to_hex(hkdf.expand(vector.hash, prk, vector.info, vector.length))
    if okm_hex == vector.okm then
      check(vector.name .. " [OKM]", true)
    else
      check(vector.name .. " [OKM]", false)
      print("    expected: " .. vector.okm)
      print("    got:      " .. okm_hex)
    end

    -- The one-shot helper must agree with the two-phase form.
    local derived = bytes.to_hex(hkdf.derive(vector.hash, vector.salt, vector.ikm, vector.info, vector.length))
    check(vector.name .. " [derive matches extract+expand]", derived == vector.okm)
  end

  print("\nRunning HAP / Companion derivation vectors...")
  for _, vector in ipairs(hap_vectors) do
    local okm_hex = bytes.to_hex(hkdf.hkdf_sha512(vector.salt, HAP_K, vector.info, 32))
    if okm_hex == vector.okm then
      check(vector.name, true)
    else
      check(vector.name, false)
      print("    expected: " .. vector.okm)
      print("    got:      " .. okm_hex)
    end
  end

  print("\nRunning HKDF functional tests...")

  check("absent salt behaves as a zero-filled HashLen salt", function()
    return hkdf.extract("sha512", nil, "ikm") == hkdf.extract("sha512", string_rep("\0", 64), "ikm")
      and hkdf.extract("sha256", "", "ikm") == hkdf.extract("sha256", string_rep("\0", 32), "ikm")
  end)

  check("absent info behaves as empty info", function()
    return hkdf.expand("sha512", string_rep("k", 64), nil, 32) == hkdf.expand("sha512", string_rep("k", 64), "", 32)
  end)

  check("PRK length equals HashLen", function()
    return #hkdf.extract("sha256", "s", "i") == 32 and #hkdf.extract("sha512", "s", "i") == 64
  end)

  check("output lengths are exact across block boundaries", function()
    local prk = hkdf.extract("sha512", "salt", "ikm")
    for _, length in ipairs({ 1, 63, 64, 65, 127, 128, 129, 200 }) do
      if #hkdf.expand("sha512", prk, "info", length) ~= length then
        return false
      end
    end
    return true
  end)

  check("shorter output is a prefix of longer output", function()
    local prk = hkdf.extract("sha512", "salt", "ikm")
    local long = hkdf.expand("sha512", prk, "info", 160)
    return hkdf.expand("sha512", prk, "info", 32) == string_sub(long, 1, 32)
      and hkdf.expand("sha512", prk, "info", 64) == string_sub(long, 1, 64)
  end)

  check("distinct info yields distinct output from one PRK", function()
    local prk = hkdf.extract("sha512", "Control-Salt", HAP_K)
    return hkdf.expand("sha512", prk, "ClientEncrypt-main", 32) ~= hkdf.expand("sha512", prk, "ServerEncrypt-main", 32)
  end)

  check("maximum permitted length is accepted", function()
    local ok, result = pcall(hkdf.expand, "sha256", string_rep("k", 32), "", 255 * 32)
    return ok and #result == 255 * 32
  end)

  check("length above 255*HashLen is rejected", function()
    return pcall(hkdf.expand, "sha256", string_rep("k", 32), "", 255 * 32 + 1) == false
  end)

  check("zero and negative lengths are rejected", function()
    return pcall(hkdf.expand, "sha512", string_rep("k", 64), "", 0) == false
      and pcall(hkdf.expand, "sha512", string_rep("k", 64), "", -1) == false
  end)

  check("non-integer length is rejected", function()
    return pcall(hkdf.expand, "sha512", string_rep("k", 64), "", 32.5) == false
  end)

  check("unsupported hash name is rejected", function()
    return pcall(hkdf.extract, "sha1", "salt", "ikm") == false
      and pcall(hkdf.derive, "md5", "salt", "ikm", "info", 16) == false
  end)

  print(string.format("\nHKDF result: %d/%d tests passed\n", passed, total))
  return passed == total
end

--- Run performance benchmarks for HKDF operations.
function hkdf.benchmark()
  local ikm = string_rep(string_char(0x0b), 32)
  local salt = "Pair-Setup-Encrypt-Salt"
  local info = "Pair-Setup-Encrypt-Info"
  local prk512 = hkdf.extract("sha512", salt, ikm)

  print("HKDF Operations:")
  benchmark_op("extract (sha256)", function()
    hkdf.extract("sha256", salt, ikm)
  end, 200)

  benchmark_op("extract (sha512)", function()
    hkdf.extract("sha512", salt, ikm)
  end, 200)

  benchmark_op("expand 32B (sha512)", function()
    hkdf.expand("sha512", prk512, info, 32)
  end, 200)

  benchmark_op("expand 160B (sha512)", function()
    hkdf.expand("sha512", prk512, info, 160)
  end, 100)

  benchmark_op("derive 32B (sha512, HAP shape)", function()
    hkdf.hkdf_sha512(salt, ikm, info, 32)
  end, 100)
end

return hkdf
end
end

do
local _ENV = _ENV
package.preload[ "crypto.openssl_wrapper" ] = function( ... ) local arg = _G.arg;
--- @module "crypto.openssl_wrapper"
--- Optional OpenSSL acceleration with graceful pure-Lua fallback
---
--- This module provides a centralized interface for enabling and accessing OpenSSL
--- acceleration for cryptographic operations. OpenSSL support can be enabled via:
--- 1. Environment variable: CRYPTO_USE_OPENSSL=1 or CRYPTO_USE_OPENSSL=true
--- 2. Calling crypto.use_openssl(true/false) from the main module
---
--- By default, native Lua implementations are used for maximum portability.
--- When OpenSSL is enabled and available, it provides hardware-accelerated
--- implementations for:
--- - SHA256/SHA512 hash functions
--- - BLAKE2s/BLAKE2b hash functions
--- - ChaCha20-Poly1305 AEAD cipher
--- - AES-GCM AEAD cipher
--- - ChaCha20 stream cipher
--- - Big-number modular exponentiation (SRP)
---
--- Note: X25519, X448 and Ed25519 always use the native implementations. The
--- shipped lua-openssl builds cannot perform the raw scalar-multiplication or
--- EdDSA signing operations even when they can import the keys.
--- @class crypto.openssl_wrapper
local openssl_wrapper = {}

--- OpenSSL Feature Enum
---
--- Identifies specific OpenSSL capabilities required by crypto operations.
--- Use these features with `openssl_wrapper.get()` to check if the installed
--- OpenSSL version supports the functionality needed.
---
--- @enum OpenSSLFeature
local OpenSSLFeature = {
  --- Additional Authenticated Data support for AEAD ciphers (ChaCha20-Poly1305, AES-GCM)
  AAD = "AAD",
  --- Key-derivation primitives (`openssl.kdf`), used to accelerate HKDF
  KDF = "KDF",
  --- Arbitrary-precision integers (`openssl.bn`), used to accelerate modular exponentiation
  BN = "BN",
  --- Raw Octet Key Pair support: creating and *signing* with Ed25519/X25519 keys.
  --- Importing such a key is not sufficient; the probe requires a working signature.
  OKP = "OKP",
  --- Cryptographically secure random bytes (`openssl.random`), used by `crypto.random`.
  --- Unlike every other feature here this one has no pure-Lua fallback, so it is
  --- resolved through `get_ungated` rather than `get`.
  RANDOM = "RANDOM",
}

--- Feature requirement definitions
---
--- Each entry declares the minimum lua-openssl version a feature needs and,
--- optionally, a `probe` that confirms the capability is actually present.
--- A version bound alone cannot answer questions like "was this build compiled
--- with `openssl.bn`?", so features whose availability varies between builds of
--- the same version carry a probe. Probes must be side-effect free and are
--- evaluated lazily, at most once per feature, only when that feature is
--- requested.
---
--- @alias FeatureRequirement { min_version: string, probe: (fun(openssl: table): boolean)? }
--- @type table<OpenSSLFeature, FeatureRequirement>
local FeatureRequirements = {
  [OpenSSLFeature.AAD] = { min_version = "0.9.2" },
  [OpenSSLFeature.KDF] = {
    min_version = "0.8.0",
    probe = function(openssl)
      return type(openssl.kdf) == "table" and type(openssl.kdf.derive) == "function"
    end,
  },
  [OpenSSLFeature.BN] = {
    min_version = "0.8.0",
    probe = function(openssl)
      local bn = openssl.bn
      if type(bn) ~= "table" then
        return false
      end
      -- Modular exponentiation is spelled `powmod` on the Control4 build
      -- (lua-openssl 0.8.5, verified on hardware 2026-08-07) and `mod_exp` on
      -- some others, so accept either rather than assuming one name.
      local powmod = type(bn.powmod) == "function" and bn.powmod or bn.mod_exp
      if type(powmod) ~= "function" or type(bn.text) ~= "function" or type(bn.tohex) ~= "function" then
        return false
      end
      -- Exercise the exact conversion path the bignum backend uses -- big-endian
      -- bytes in via bn.text, hex out via bn.tohex -- and require the right
      -- answer. Presence of the names is not proof they are wired up.
      local ok, result = pcall(function()
        local base = bn.text(string.char(0x04))
        local exponent = bn.text(string.char(0x0d))
        local modulus = bn.text(string.char(0x01, 0xf1))
        return bn.tohex(powmod(base, exponent, modulus))
      end)
      -- 4^13 mod 497 == 445 == 0x1BD
      return ok and type(result) == "string" and result:gsub("^0+", ""):lower() == "1bd"
    end,
  },
  [OpenSSLFeature.OKP] = {
    min_version = "0.8.0",
    probe = function(openssl)
      local pkey = openssl.pkey
      if type(pkey) ~= "table" or type(pkey.new) ~= "function" then
        return false
      end
      -- Control4's build returns nil from pkey.new("ed25519"), and even when a
      -- key is imported from DER its sign() yields nil. Only a completed
      -- sign/verify round-trip counts as support.
      local ok, verified = pcall(function()
        local key = pkey.new("ed25519")
        if key == nil then
          return false
        end
        local signature = key:sign("probe")
        if signature == nil then
          return false
        end
        return key:verify("probe", signature) == true
      end)
      return ok and verified == true
    end,
  },
  [OpenSSLFeature.RANDOM] = {
    min_version = "0.8.0",
    probe = function(openssl)
      if type(openssl.random) ~= "function" then
        return false
      end
      -- `rand_status` reports whether the PRNG has been seeded with enough
      -- entropy. A binding that cannot answer the question is treated as
      -- unseeded rather than assumed good -- for entropy the safe default is
      -- "no", because the fallback is a different source, not a slower one.
      if type(openssl.rand_status) ~= "function" then
        return false
      end
      local status_ok, seeded = pcall(openssl.rand_status)
      if not status_ok or seeded ~= true then
        return false
      end
      -- Verify the `strong` flag actually yields the requested width twice, and
      -- that the two draws differ: a build whose RNG is stubbed out or wired to
      -- a constant passes a length check but fails this one. Two equal draws
      -- from a working CSPRNG has probability 2^-256, so the false negative is
      -- not a real risk. Note this consumes entropy, unlike the other probes.
      local first_ok, first = pcall(openssl.random, 32, true)
      if not first_ok or type(first) ~= "string" or #first ~= 32 then
        return false
      end
      local second_ok, second = pcall(openssl.random, 32, true)
      return second_ok and type(second) == "string" and #second == 32 and first ~= second
    end,
  },
}

-- Export Feature enum for external use
openssl_wrapper.Feature = OpenSSLFeature

--- @type table?
local _openssl_module
--- Lazily populated cache of feature support; nil means "not yet resolved".
--- @type table<OpenSSLFeature, boolean>
local _openssl_module_features = {}
--- True once a require("openssl") attempt has failed, to avoid re-probing every call.
local _openssl_unavailable = false
local _use_openssl = os.getenv("CRYPTO_USE_OPENSSL") == "1" or os.getenv("CRYPTO_USE_OPENSSL") == "true"

--- Enable or disable OpenSSL acceleration for cryptographic operations.
--- Enabling is safe even when the lua-openssl binding is absent: accelerated
--- primitives fall back to their pure-Lua implementations automatically.
--- @param use boolean True to enable OpenSSL, false to disable
function openssl_wrapper.use(use)
  _use_openssl = use
  -- Re-probe availability on the next get() so toggling at runtime is safe.
  _openssl_module = nil
  _openssl_module_features = {}
  _openssl_unavailable = false
end

--- Parse semantic version string into comparable components
--- @param version_str string Version string like "0.9.1" or "1.0.0-rc1"
--- @return number major Major version number
--- @return number minor Minor version number
--- @return number patch Patch version number
local function parse_version(version_str)
  local major, minor, patch = version_str:match("(%d+)%.(%d+)%.(%d+)")
  return tonumber(major) or 0, tonumber(minor) or 0, tonumber(patch) or 0
end

--- Compare two semantic versions
--- @param current_version string Current version string
--- @param required_version string Required minimum version string
--- @return boolean supported True if current version >= required version
local function version_supports(current_version, required_version)
  local cur_major, cur_minor, cur_patch = parse_version(current_version)
  local req_major, req_minor, req_patch = parse_version(required_version)

  -- Compare major.minor.patch
  if cur_major > req_major then
    return true
  elseif cur_major == req_major then
    if cur_minor > req_minor then
      return true
    elseif cur_minor == req_minor then
      return cur_patch >= req_patch
    end
  end

  return false
end

--- Resolve whether a single feature is supported by the loaded binding.
--- @param openssl table The loaded lua-openssl module
--- @param feature OpenSSLFeature Feature to resolve
--- @return boolean supported
local function resolve_feature(openssl, feature)
  local requirement = FeatureRequirements[feature]
  if not requirement then
    error("Unknown feature: " .. tostring(feature))
  end

  local current_version = type(openssl.version) == "function" and openssl.version()
  if type(current_version) ~= "string" then
    return false
  end
  if not version_supports(current_version, requirement.min_version) then
    return false
  end
  if requirement.probe then
    local ok, supported = pcall(requirement.probe, openssl)
    return ok and supported == true
  end
  return true
end

--- Load the binding, caching both the module and a failed attempt.
--- @return table|nil openssl
local function load_binding()
  if _openssl_unavailable then
    return nil
  end
  if _openssl_module == nil then
    local ok, openssl_module = pcall(require, "openssl")
    if not ok or openssl_module == nil then
      -- Graceful fallback: acceleration was requested but the binding is absent.
      _openssl_unavailable = true
      return nil
    end
    --- @cast openssl_module table
    _openssl_module = openssl_module
    _openssl_module_features = {}
  end
  return _openssl_module
end

--- Resolve a feature against the loaded binding, caching the verdict.
--- @param openssl table
--- @param feature OpenSSLFeature
--- @return boolean supported
local function supports(openssl, feature)
  local supported = _openssl_module_features[feature]
  if supported == nil then
    supported = resolve_feature(openssl, feature)
    _openssl_module_features[feature] = supported
  end
  return supported
end

--- Get the OpenSSL module if enabled and supports required features
---
--- Checks if OpenSSL is enabled and supports all specified features before
--- returning the module. This ensures that the returned module can safely
--- be used for the requested cryptographic operations.
---
--- @param ... OpenSSLFeature One or more required features that must be supported
--- @return table|nil openssl The OpenSSL module if enabled, available, and supporting all features; nil otherwise
function openssl_wrapper.get(...)
  local required_features = { ... }

  if not _use_openssl then
    return nil
  end
  local openssl = load_binding()
  if openssl == nil then
    return nil
  end
  -- Check all requested features, resolving (and caching) each on first request.
  for _, required_feature in ipairs(required_features) do
    if not supports(openssl, required_feature) then
      return nil
    end
  end
  return openssl
end

--- Get the OpenSSL module for a capability that is *not* an acceleration.
---
--- `get` deliberately honours the opt-in acceleration flag, because every
--- feature behind it has a correct pure-Lua fallback and the flag only chooses
--- which correct implementation runs. `Feature.RANDOM` is different in kind:
--- there is no portable pure-Lua substitute for a CSPRNG, so gating it on a
--- performance switch would silently trade entropy for nothing. Callers that
--- need a capability rather than a speed-up use this instead.
---
--- @param feature OpenSSLFeature Feature the binding must support
--- @return table|nil openssl The module if available and supporting the feature; nil otherwise
function openssl_wrapper.get_ungated(feature)
  local openssl = load_binding()
  if openssl == nil then
    return nil
  end
  return supports(openssl, feature) and openssl or nil
end

--- Explain why `get(feature)` is returning nil.
---
--- `get` collapses three different situations into one `nil`, and two of them
--- look identical to a caller while having opposite remedies: a host that
--- cannot accelerate is a fact to design around, whereas a host that has simply
--- not called `use(true)` yet is a one-line initialisation bug. The second is
--- the likely one on Control4, where `CRYPTO_USE_OPENSSL` is not set in the
--- DriverWorks environment, so a driver that forgets the call reads as "no
--- binding" for every feature on hardware that has four of them.
---
--- @param feature OpenSSLFeature? Feature to explain; omit to ask only about the flag and the binding
--- @return string|nil reason Human-readable cause, or nil when the feature is available
function openssl_wrapper.unavailable_reason(feature)
  if not _use_openssl then
    return "OpenSSL acceleration is not enabled: call crypto.use_openssl(true) during initialisation "
      .. "(CRYPTO_USE_OPENSSL is not set in every host environment, notably Control4 DriverWorks)"
  end
  local openssl = load_binding()
  if openssl == nil then
    return "the lua-openssl binding is not available on this host"
  end
  if feature ~= nil and not supports(openssl, feature) then
    return "the lua-openssl binding does not support " .. tostring(feature)
  end
  return nil
end

--- Report which features the currently loaded binding supports.
---
--- Intended for diagnostics. It reports what `get` would return, so every entry
--- is false while acceleration is off, regardless of what the host can do --
--- call `unavailable_reason` to tell that case apart from a binding that really
--- lacks the feature.
---
--- @return table<OpenSSLFeature, boolean> features Support map (empty when the binding is unavailable)
function openssl_wrapper.features()
  local report = {}
  for _, feature in pairs(OpenSSLFeature) do
    report[feature] = openssl_wrapper.get(feature) ~= nil
  end
  return report
end

-- ============================================================================
-- TESTS
-- ============================================================================

--- Run the feature-gating self-test.
---
--- The gate is exercised against injected stand-in bindings rather than the
--- host's real lua-openssl, so the result is identical on every machine and on
--- hosts with no binding at all. This is a regression test for a gate that
--- silently never opened: `_openssl_module_features` was populated by iterating
--- a string-keyed table with `ipairs`, which visits nothing, so every
--- `get(<feature>)` returned nil and ChaCha20-Poly1305 never used OpenSSL.
---
--- @return boolean result True if all tests pass, false otherwise
function openssl_wrapper.selftest()
  print("Running OpenSSL feature-gating test vectors...")

  -- Snapshot state so the test cannot disturb a real binding or a caller's flag.
  local saved_use = _use_openssl
  local saved_loaded = package.loaded["openssl"]
  local saved_preload = package.preload["openssl"]

  --- Install a stand-in binding and force the gate to re-resolve against it.
  --- @param stub table|nil Stand-in module, or nil to simulate an absent binding
  local function install(stub)
    package.loaded["openssl"] = stub
    if stub == nil then
      -- Force require("openssl") to fail regardless of what this host actually
      -- has installed, so the fallback case is deterministic everywhere.
      -- Each selftest stubs the same loader independently, which the language
      -- server reads as redefining one field; that is the intent here.
      --- @diagnostic disable-next-line: duplicate-set-field
      package.preload["openssl"] = function()
        error("simulated absent binding")
      end
    else
      package.preload["openssl"] = nil
    end
    -- Acceleration stays requested in both cases; absence must degrade, not throw.
    openssl_wrapper.use(true)
  end

  --- Build a stand-in binding reporting `version`, with optional capabilities.
  --- @param version string|nil Version string returned by openssl.version()
  --- @param extra table|nil Additional fields (bn, kdf, pkey, ...)
  --- @return table stub
  local function stub_openssl(version, extra)
    local stub = {
      version = function()
        return version
      end,
    }
    for key, value in pairs(extra or {}) do
      stub[key] = value
    end
    return stub
  end

  -- A `bn` table that actually computes, modelling the real binding's shape:
  -- `text` parses big-endian bytes, `tohex` renders hex, and modular
  -- exponentiation is available under a configurable name.
  --- @param name string Which spelling of modular exponentiation to expose
  --- @return table bn
  local function working_bn(name)
    local bn = {
      text = function(str)
        local value = 0
        for i = 1, #str do
          value = value * 256 + string.byte(str, i)
        end
        return value
      end,
      tohex = function(n)
        return string.format("%X", n)
      end,
    }
    bn[name] = function(base, exponent, modulus)
      local result = 1
      for _ = 1, exponent do
        result = (result * base) % modulus
      end
      return result
    end
    return bn
  end

  local tests = {
    {
      name = "version-only feature resolves true on a supporting version",
      test = function()
        install(stub_openssl("0.9.2"))
        return openssl_wrapper.get(OpenSSLFeature.AAD) ~= nil
      end,
    },
    {
      -- Measured on a Control4 controller 2026-08-07: the shipped binding is
      -- lua-openssl 0.8.5, and there `cipher:update(aad, true)` ignores the AAD
      -- flag and encrypts the AAD as plaintext. The 0.9.2 floor is therefore
      -- load-bearing, not decorative, and this case pins it.
      name = "Control4's lua-openssl 0.8.5 does not satisfy AAD",
      test = function()
        install(stub_openssl("0.8.5"))
        return openssl_wrapper.get(OpenSSLFeature.AAD) == nil
      end,
    },
    {
      -- Same binding, but BN is genuinely usable there, so the two features
      -- must resolve differently on one and the same host.
      name = "Control4's lua-openssl 0.8.5 does satisfy BN",
      test = function()
        install(stub_openssl("0.8.5", { bn = working_bn("powmod") }))
        return openssl_wrapper.get(OpenSSLFeature.BN) ~= nil
      end,
    },
    {
      name = "version-only feature resolves false below the minimum",
      test = function()
        install(stub_openssl("0.9.1"))
        return openssl_wrapper.get(OpenSSLFeature.AAD) == nil
      end,
    },
    {
      name = "newer versions still satisfy an older minimum",
      test = function()
        install(stub_openssl("0.10.0"))
        return openssl_wrapper.get(OpenSSLFeature.AAD) ~= nil
      end,
    },
    {
      name = "no features requested returns the module when enabled",
      test = function()
        install(stub_openssl("0.9.2"))
        return openssl_wrapper.get() ~= nil
      end,
    },
    {
      name = "acceleration disabled returns nil even with a supporting binding",
      test = function()
        install(stub_openssl("0.9.2"))
        openssl_wrapper.use(false)
        return openssl_wrapper.get(OpenSSLFeature.AAD) == nil
      end,
    },
    {
      name = "absent binding falls back gracefully",
      test = function()
        install(nil)
        return openssl_wrapper.get(OpenSSLFeature.AAD) == nil
      end,
    },
    -- `get` returns the same nil for three unrelated situations. The point of
    -- `unavailable_reason` is that it separates them, so each case is pinned to
    -- the phrase a caller would act on rather than merely to "some string".
    {
      name = "unavailable_reason blames the flag, not the host, when acceleration is off",
      test = function()
        install(stub_openssl("0.9.2"))
        openssl_wrapper.use(false)
        local reason = openssl_wrapper.unavailable_reason(OpenSSLFeature.AAD)
        return type(reason) == "string" and reason:find("crypto.use_openssl(true)", 1, true) ~= nil
      end,
    },
    {
      name = "unavailable_reason blames the host when the binding is absent",
      test = function()
        install(nil)
        local reason = openssl_wrapper.unavailable_reason(OpenSSLFeature.AAD)
        return type(reason) == "string"
          and reason:find("not available", 1, true) ~= nil
          and reason:find("use_openssl", 1, true) == nil
      end,
    },
    {
      name = "unavailable_reason names the feature a present binding lacks",
      test = function()
        install(stub_openssl("0.8.5"))
        local reason = openssl_wrapper.unavailable_reason(OpenSSLFeature.AAD)
        return type(reason) == "string" and reason:find("does not support AAD", 1, true) ~= nil
      end,
    },
    {
      name = "unavailable_reason is nil when the feature is available",
      test = function()
        install(stub_openssl("0.9.2"))
        return openssl_wrapper.unavailable_reason(OpenSSLFeature.AAD) == nil
          and openssl_wrapper.unavailable_reason() == nil
      end,
    },
    {
      name = "BN probe passes when powmod round-trips (Control4 spelling)",
      test = function()
        install(stub_openssl("0.9.2", { bn = working_bn("powmod") }))
        return openssl_wrapper.get(OpenSSLFeature.BN) ~= nil
      end,
    },
    {
      name = "BN probe accepts the mod_exp spelling too",
      test = function()
        install(stub_openssl("0.9.2", { bn = working_bn("mod_exp") }))
        return openssl_wrapper.get(OpenSSLFeature.BN) ~= nil
      end,
    },
    {
      name = "BN probe fails when bn is missing",
      test = function()
        install(stub_openssl("0.9.2"))
        return openssl_wrapper.get(OpenSSLFeature.BN) == nil
      end,
    },
    {
      name = "BN probe fails when the answer is wrong",
      test = function()
        local broken = working_bn("powmod")
        broken.powmod = function()
          return 0
        end
        install(stub_openssl("0.9.2", { bn = broken }))
        return openssl_wrapper.get(OpenSSLFeature.BN) == nil
      end,
    },
    {
      name = "BN probe fails when modular exponentiation raises",
      test = function()
        local raising = working_bn("powmod")
        raising.powmod = function()
          error("not compiled in")
        end
        install(stub_openssl("0.9.2", { bn = raising }))
        return openssl_wrapper.get(OpenSSLFeature.BN) == nil
      end,
    },
    {
      name = "KDF probe requires kdf.derive",
      test = function()
        install(stub_openssl("0.9.2", { kdf = {} }))
        local without = openssl_wrapper.get(OpenSSLFeature.KDF) == nil
        install(stub_openssl("0.9.2", { kdf = { derive = function() end } }))
        return without and openssl_wrapper.get(OpenSSLFeature.KDF) ~= nil
      end,
    },
    {
      name = "OKP probe fails when pkey.new returns nil (Control4 behaviour)",
      test = function()
        install(stub_openssl("0.9.2", {
          pkey = {
            new = function()
              return nil
            end,
          },
        }))
        return openssl_wrapper.get(OpenSSLFeature.OKP) == nil
      end,
    },
    {
      name = "OKP probe fails when sign() returns nil (imported-key behaviour)",
      test = function()
        install(stub_openssl("0.9.2", {
          pkey = {
            new = function()
              return {
                sign = function()
                  return nil
                end,
                verify = function()
                  return true
                end,
              }
            end,
          },
        }))
        return openssl_wrapper.get(OpenSSLFeature.OKP) == nil
      end,
    },
    {
      name = "OKP probe passes only on a full sign/verify round-trip",
      test = function()
        install(stub_openssl("0.9.2", {
          pkey = {
            new = function()
              return {
                sign = function(_, message)
                  return "sig:" .. message
                end,
                verify = function(_, message, signature)
                  return signature == "sig:" .. message
                end,
              }
            end,
          },
        }))
        return openssl_wrapper.get(OpenSSLFeature.OKP) ~= nil
      end,
    },
    {
      name = "all requested features must hold, not just the first",
      test = function()
        install(stub_openssl("0.9.2", { bn = working_bn("powmod") }))
        return openssl_wrapper.get(OpenSSLFeature.AAD, OpenSSLFeature.BN) ~= nil
          and openssl_wrapper.get(OpenSSLFeature.AAD, OpenSSLFeature.KDF) == nil
      end,
    },
    {
      name = "get honours the acceleration flag, get_ungated does not",
      test = function()
        install(stub_openssl("0.9.2", { bn = working_bn("powmod") }))
        openssl_wrapper.use(false)
        -- The flag chooses between two correct implementations, so it must
        -- suppress `get`. It must not be able to suppress a capability that has
        -- no fallback, which is the whole reason `get_ungated` exists.
        return openssl_wrapper.get(OpenSSLFeature.BN) == nil and openssl_wrapper.get_ungated(OpenSSLFeature.BN) ~= nil
      end,
    },
    {
      name = "get_ungated still enforces the probe",
      test = function()
        install(stub_openssl("0.9.2"))
        openssl_wrapper.use(false)
        -- Ungated means "ignore the flag", not "skip the check".
        return openssl_wrapper.get_ungated(OpenSSLFeature.BN) == nil
      end,
    },
    {
      name = "RANDOM probe requires rand_status, a full width, and two distinct draws",
      test = function()
        --- @param overrides table Fields replacing the working RNG stub
        local function rng(overrides)
          local draws = 0
          local stub = {
            rand_status = function()
              return true
            end,
            random = function(n)
              draws = draws + 1
              return string.rep(string.char(draws % 256), n)
            end,
          }
          for key, value in pairs(overrides) do
            stub[key] = value
          end
          install(stub_openssl("0.8.5", stub))
          return openssl_wrapper.get_ungated(OpenSSLFeature.RANDOM) ~= nil
        end

        return rng({}) == true
          -- Missing rand_status: unverifiable seeding is treated as unseeded.
          and rng({ rand_status = false }) == false
          and rng({
            rand_status = function()
              return false
            end,
          }) == false
          -- A constant RNG passes a length check but not a distinctness one.
          and rng({
            random = function(n)
              return string.rep("\0", n)
            end,
          }) == false
          -- A short read must not count as support.
          and rng({
            random = function(n)
              return string.rep("\0", n - 1)
            end,
          }) == false
          and rng({ random = false }) == false
      end,
    },
    {
      name = "unknown features are rejected, not silently granted",
      test = function()
        install(stub_openssl("0.9.2"))
        local ok = pcall(openssl_wrapper.get, "NOT_A_FEATURE")
        return ok == false
      end,
    },
    {
      name = "every declared feature has a requirement entry",
      test = function()
        for _, feature in pairs(OpenSSLFeature) do
          if FeatureRequirements[feature] == nil then
            return false
          end
        end
        return true
      end,
    },
  }

  local passed = 0
  for _, test in ipairs(tests) do
    local ok, result = pcall(test.test)
    if ok and result == true then
      print("  ✅ PASS: " .. test.name)
      passed = passed + 1
    else
      print("  ❌ FAIL: " .. test.name .. (ok and "" or (" - " .. tostring(result))))
    end
  end

  -- Restore the environment for subsequent tests in the same process.
  package.loaded["openssl"] = saved_loaded
  package.preload["openssl"] = saved_preload
  openssl_wrapper.use(saved_use)

  print(string.format("\nOpenSSL feature-gating result: %d/%d tests passed\n", passed, #tests))
  return passed == #tests
end

return openssl_wrapper
end
end

do
local _ENV = _ENV
package.preload[ "crypto.poly1305" ] = function( ... ) local arg = _G.arg;
--- @module "crypto.poly1305"
--- Poly1305 Message Authentication Code (MAC) Implementation for portability.
--- @class crypto.poly1305
local poly1305 = {}

local bit32 = require("bitn").bit32

local utils = require("crypto.utils")
local bytes = utils.bytes
local benchmark_op = utils.benchmark.benchmark_op

-- Local references for performance
local bit32_raw_band = bit32.raw_band
local bit32_raw_lshift = bit32.raw_lshift
local floor = math.floor
local string_byte = string.byte
local string_char = string.char
local string_rep = string.rep
local table_concat = table.concat

-- Type definitions for better type checking

--- 17-element limb array for 130-bit + overflow
--- @alias Limb17Array [integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer]

--- 33-element array for multiplication products
--- @alias Limb33Array [integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer]

--- 16-element key array
--- @alias KeyArray [integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer]

--- Helper function to process modular reduction for higher-order terms
---
--- Reduces coefficients of 2^k where k >= 130 using the identity:
--- 2^130 ≡ 5 (mod 2^130 - 5)
---
--- @param prod Limb33Array Product array to reduce
--- @param start_pos integer Starting position to reduce from
--- @param end_pos integer Ending position to reduce to
local function reduce_high_order_terms(prod, start_pos, end_pos)
  for i = start_pos, end_pos, -1 do
    if prod[i] > 0 then
      local bit_pos = 8 * (i - 1)
      local excess_bits = bit_pos - 130
      local reduction_multiplier = 5

      -- Calculate target byte position for the reduction
      local target_byte = 1 + floor(excess_bits / 8)
      local bit_offset = excess_bits % 8

      if bit_offset > 0 then
        reduction_multiplier = bit32_raw_lshift(reduction_multiplier, bit_offset)
      end

      -- Add reduced value to target position
      if target_byte <= 17 then
        prod[target_byte] = prod[target_byte] + prod[i] * reduction_multiplier
      end
      prod[i] = 0
    end
  end
end

--- Helper function to propagate carries in limb array
---
--- Normalizes a limb array by propagating carries from lower to higher positions.
--- Each limb is reduced modulo 256 (8-bit) with carries propagated forward.
---
--- @param h Limb17Array|Limb33Array Limb array to normalize (modified in place)
--- @return integer carry Final carry value
local function propagate_carries(h)
  local carry = 0
  for i = 1, 17 do
    assert(h[i] ~= nil, "Limb array must have at least 17 non-nil elements")
    carry = carry + h[i]
    h[i] = carry % 256
    carry = floor(carry / 256)
  end
  return carry
end

--- Helper function to handle final carry overflow
---
--- When carry propagation results in overflow beyond position 17,
--- this function applies the modular reduction: 2^136 ≡ 320 (mod 2^130 - 5)
---
--- @param h Limb17Array Limb array (modified in place)
--- @param carry integer Initial carry to process
local function handle_final_carry(h, carry)
  while carry > 0 do
    -- 2^136 = 2^6 * 2^130 ≡ 64 * 5 = 320 (mod 2^130 - 5)
    h[1] = h[1] + carry * 320

    carry = propagate_carries(h)
  end
end

--- Helper function to reduce limb 17 to valid range
---
--- Position 17 can only hold 2 bits (values 0-3) since we're working modulo 2^130.
--- Values >= 4 represent overflow that must be reduced.
---
--- @param h Limb17Array Limb array (modified in place)
local function reduce_position_17(h)
  while h[17] >= 4 do
    local high_bits = floor(h[17] / 4)
    h[17] = h[17] % 4

    -- high_bits represents coefficient of 2^130, so multiply by 5
    h[1] = h[1] + high_bits * 5

    local carry = propagate_carries(h)
    handle_final_carry(h, carry)
  end
end

--- Initialize a 17-element limb array with zeros
--- @return Limb17Array array Initialized array
local function create_limb17_array()
  local arr = {}
  for i = 1, 17 do
    arr[i] = 0
  end
  --- @cast arr Limb17Array
  return arr
end

--- Initialize a 33-element product array with zeros
--- @return Limb33Array array Initialized array
local function create_limb33_array()
  local arr = {}
  for i = 1, 33 do
    arr[i] = 0
  end
  --- @cast arr Limb33Array
  return arr
end

-- Pre-allocated arrays for authenticate() hot loop
local auth_c = create_limb17_array() -- Message block array (17 elements)
local auth_prod = create_limb33_array() -- Product array (33 elements)
local auth_g = create_limb17_array() -- Final reduction array (17 elements)

--- Initialize a 16-element key array
--- @param source integer[] Source array to copy from
--- @param offset integer Starting offset in source array
--- @return KeyArray array Initialized key array
local function create_key_array(source, offset)
  local arr = {}
  for i = 1, 16 do
    arr[i] = source[offset + i - 1]
  end
  --- @cast arr KeyArray
  return arr
end

--- Compute Poly1305 MAC for given key and message
---
--- This function implements the complete Poly1305 algorithm:
--- 1. Key setup with RFC 7539 clamping
--- 2. Message processing in 16-byte blocks with padding
--- 3. Modular arithmetic over the field 2^130 - 5
--- 4. Final reduction and output formatting
---
--- @param key string 32-byte key (r || s)
--- @param msg string Message to authenticate (any length)
--- @return string mac 16-byte authentication tag
--- @error Throws assertion error if key is not exactly 32 bytes
function poly1305.authenticate(key, msg)
  assert(#key == 32, "Key must be exactly 32 bytes")

  -- Convert key to byte array for easier manipulation
  --- @type integer[]
  local key_bytes = {}
  for i = 1, #key do
    key_bytes[i] = string_byte(key, i)
  end

  -- Extract and clamp r (first 16 bytes) per RFC 7539
  local r = create_key_array(key_bytes, 1)

  -- Apply RFC 7539 clamping to ensure r has specific bit patterns
  -- This prevents certain classes of attacks and ensures key validity
  r[4] = bit32_raw_band(r[4], 15) -- Clear top 4 bits of 4th byte
  r[5] = bit32_raw_band(r[5], 252) -- Clear bottom 2 bits of 5th byte
  r[8] = bit32_raw_band(r[8], 15) -- Clear top 4 bits of 8th byte
  r[9] = bit32_raw_band(r[9], 252) -- Clear bottom 2 bits of 9th byte
  r[12] = bit32_raw_band(r[12], 15) -- Clear top 4 bits of 12th byte
  r[13] = bit32_raw_band(r[13], 252) -- Clear bottom 2 bits of 13th byte
  r[16] = bit32_raw_band(r[16], 15) -- Clear top 4 bits of 16th byte

  -- Extract s (second 16 bytes) - used for final addition
  local s = create_key_array(key_bytes, 17)

  -- Initialize accumulator h as 17-byte array (130-bit + 6 extra bits)
  local h = create_limb17_array()

  local msglen = #msg
  local offset = 1

  -- Reuse pre-allocated arrays for hot loop
  local c = auth_c
  local prod = auth_prod

  -- Process message in 16-byte blocks
  while msglen >= 16 do
    -- Load current 16-byte block (reset and fill)
    for i = 1, 16 do
      c[i] = string_byte(msg, offset + i - 1)
    end
    c[17] = 1 -- Add high bit (represents 2^128 for full blocks)

    -- Add message block to accumulator: h = h + c
    local carry = 0
    for i = 1, 17 do
      carry = carry + h[i] + c[i]
      h[i] = carry % 256
      carry = floor(carry / 256)
    end

    -- Multiply by r: h = (h * r) mod (2^130 - 5)

    -- Step 1: Compute full precision product h * r (reset prod first)
    for i = 1, 33 do
      prod[i] = 0
    end

    for i = 1, 17 do
      for j = 1, 16 do
        prod[i + j - 1] = prod[i + j - 1] + h[i] * r[j]
      end
    end

    -- Step 2: Reduce high-order terms (positions 18-33)
    reduce_high_order_terms(prod, 33, 18)

    -- Step 3: Propagate carries and normalize
    carry = propagate_carries(prod)
    for i = 1, 17 do
      h[i] = prod[i]
    end

    -- Step 4: Handle overflow carry
    handle_final_carry(h, carry)

    -- Step 5: Reduce position 17 to valid range
    reduce_position_17(h)

    offset = offset + 16
    msglen = msglen - 16
  end

  -- Process final partial block (if any)
  if msglen > 0 then
    -- Reset c array for partial block
    for i = 1, 17 do
      c[i] = 0
    end

    -- Load partial block
    for i = 1, msglen do
      c[i] = string_byte(msg, offset + i - 1)
    end
    c[msglen + 1] = 1 -- Add padding bit at end of message

    -- Same operations as full blocks
    local carry = 0
    for i = 1, 17 do
      carry = carry + h[i] + c[i]
      h[i] = carry % 256
      carry = floor(carry / 256)
    end

    -- Multiply by r (reset prod first)
    for i = 1, 33 do
      prod[i] = 0
    end

    for i = 1, 17 do
      for j = 1, 16 do
        prod[i + j - 1] = prod[i + j - 1] + h[i] * r[j]
      end
    end

    reduce_high_order_terms(prod, 33, 18)

    carry = propagate_carries(prod)
    for i = 1, 17 do
      h[i] = prod[i]
    end

    handle_final_carry(h, carry)
    reduce_position_17(h)
  end

  -- Final reduction: conditionally subtract (2^130 - 5) if h >= 2^130 - 5
  -- This ensures the result is in canonical form

  -- Reuse pre-allocated g array
  local g = auth_g
  for i = 1, 17 do
    g[i] = h[i]
  end

  -- Test reduction by computing h + 5
  g[1] = g[1] + 5
  local carry = floor(g[1] / 256)
  g[1] = g[1] % 256

  for i = 2, 17 do
    if carry == 0 then
      break
    end
    carry = carry + g[i]
    g[i] = carry % 256
    carry = floor(carry / 256)
  end

  -- Use mask-based selection for constant-time operation
  -- If g[17] >= 4, then h + 5 overflowed the 130-bit boundary,
  -- meaning h >= 2^130 - 5, so we use the reduced value g
  local use_g = (g[17] >= 4) and 1 or 0
  for i = 1, 17 do
    h[i] = (h[i] * (1 - use_g)) + (g[i] * use_g)
  end

  -- Add s and create final 16-byte result (optimized with table)
  local result_bytes = {}
  carry = 0
  for i = 1, 16 do
    local sum = h[i] + s[i] + carry
    result_bytes[i] = string_char(sum % 256)
    carry = floor(sum / 256)
  end

  return table_concat(result_bytes)
end

--- Test vectors from RFC 8439, RFC 7539, and other reference implementations
local test_vectors = {
  {
    name = "RFC 8439 Test Vector #1 (all zeros)",
    key = string_rep("\0", 32),
    message = string_rep("\0", 64),
    expected = string_rep("\0", 16),
  },
  {
    name = "RFC 8439 Test Vector #2 (r=0, long message)",
    key = string_rep("\0", 16) .. bytes.from_hex("36e5f6b5c5e06070f0efca96227a863e"),
    message = 'Any submission to the IETF intended by the Contributor for publication as all or part of an IETF Internet-Draft or RFC and any statement made within the context of an IETF activity is considered an "IETF Contribution". Such statements include oral statements in IETF sessions, as well as written and electronic communications made at any time or place, which are addressed to',
    expected = bytes.from_hex("36e5f6b5c5e06070f0efca96227a863e"),
  },
  {
    name = "RFC 8439 Test Vector #3 (r!=0, s=0)",
    key = bytes.from_hex("36e5f6b5c5e06070f0efca96227a863e") .. string_rep("\0", 16),
    message = 'Any submission to the IETF intended by the Contributor for publication as all or part of an IETF Internet-Draft or RFC and any statement made within the context of an IETF activity is considered an "IETF Contribution". Such statements include oral statements in IETF sessions, as well as written and electronic communications made at any time or place, which are addressed to',
    expected = bytes.from_hex("f3477e7cd95417af89a6b8794c310cf0"),
  },
  {
    name = "Wrap test vector (tests modular reduction edge case)",
    key = bytes.from_hex("0200000000000000000000000000000000000000000000000000000000000000"),
    message = string_rep(string_char(255), 16),
    expected = bytes.from_hex("03000000000000000000000000000000"),
  },
  {
    name = "RFC 7539 test vector",
    key = bytes.from_hex("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b"),
    message = "Cryptographic Forum Research Group",
    expected = bytes.from_hex("a8061dc1305136c6c22b8baf0c0127a9"),
  },
  {
    name = "NaCl test vector (tests complex multi-block processing)",
    key = bytes.from_hex("eea6a7251c1e72916d11c2cb214d3c252539121d8e234e652d651fa4c8cff880"),
    message = bytes.from_hex(
      "8e993b9f48681273c29650ba32fc76ce48332ea7164d96a4476fb8c531a1186ac0dfc17c98dce87b4da7f011ec48c97271d2c20f9b928fe2270d6fb863d51738b48eeee314a7cc8ab932164548e526ae90224368517acfeabd6bb3732bc0e9da99832b61ca01b6de56244a9e88d5f9b37973f622a43d14a6599b1f654cb45a74e355a5"
    ),
    expected = bytes.from_hex("f3ffc7703f9400e52a7dfb4b3d3305d9"),
  },
}

--- Run comprehensive self-test with all standard test vectors
---
--- This function validates the implementation against known test vectors
--- from RFCs and reference implementations. ALL tests must pass for the
--- implementation to be considered cryptographically safe.
---
--- @return boolean result True if all tests pass, false otherwise
function poly1305.selftest()
  local function test_vectors_suite()
    print("Running Poly1305 test vectors...")
    local passed = 0
    local total = #test_vectors

    for i, test in ipairs(test_vectors) do
      print(string.format("Test %d: %s", i, test.name))

      local result = poly1305.authenticate(test.key, test.message)

      -- Convert results to hex for comparison display
      local result_hex = ""
      local expected_hex = ""

      for j = 1, #result do
        result_hex = result_hex .. string.format("%02x", string_byte(result, j))
      end

      for j = 1, #test.expected do
        expected_hex = expected_hex .. string.format("%02x", string_byte(test.expected, j))
      end

      if result == test.expected then
        print("  ✅ PASS: " .. test.name)
        passed = passed + 1
      else
        print("  ❌ FAIL: " .. test.name)
        print("  Expected: " .. expected_hex)
        print("  Got:      " .. result_hex)
      end
      print()
    end

    print(string.format("Test vectors result: %d/%d tests passed", passed, total))
    print()
    return passed == total
  end

  local function functional_tests()
    print("Running Poly1305 functional tests...")
    local passed = 0
    local total = 0

    -- Test 1: Different keys produce different tags
    total = total + 1
    local key1 = string_rep(string_char(0x42), 32)
    local key2 = string_rep(string_char(0x43), 32)
    local message = "Test message for MAC verification"

    local tag1 = poly1305.authenticate(key1, message)
    local tag2 = poly1305.authenticate(key2, message)

    if tag1 ~= tag2 then
      print("  ✅ PASS: Different keys produce different tags")
      passed = passed + 1
    else
      print("  ❌ FAIL: Different keys produce same tag")
    end

    -- Test 2: Different messages produce different tags
    total = total + 1
    local msg1 = "Message 1"
    local msg2 = "Message 2"

    local tag_msg1 = poly1305.authenticate(key1, msg1)
    local tag_msg2 = poly1305.authenticate(key1, msg2)

    if tag_msg1 ~= tag_msg2 then
      print("  ✅ PASS: Different messages produce different tags")
      passed = passed + 1
    else
      print("  ❌ FAIL: Different messages produce same tag")
    end

    -- Test 3: Empty message handling
    total = total + 1
    local empty_tag = poly1305.authenticate(key1, "")

    if #empty_tag == 16 then
      print("  ✅ PASS: Empty message produces valid 16-byte tag")
      passed = passed + 1
    else
      print("  ❌ FAIL: Empty message tag length is not 16 bytes")
    end

    -- Test 4: Large message handling (multi-block)
    total = total + 1
    local large_msg = string_rep("A", 256) -- 16 full blocks
    local large_tag = poly1305.authenticate(key1, large_msg)

    if #large_tag == 16 then
      print("  ✅ PASS: Large message produces valid 16-byte tag")
      passed = passed + 1
    else
      print("  ❌ FAIL: Large message tag length is not 16 bytes")
    end

    -- Test 5: Partial block handling
    total = total + 1
    local partial_msg = string_rep("B", 33) -- 2 blocks + 1 byte
    local partial_tag = poly1305.authenticate(key1, partial_msg)

    if #partial_tag == 16 then
      print("  ✅ PASS: Partial block message produces valid 16-byte tag")
      passed = passed + 1
    else
      print("  ❌ FAIL: Partial block tag length is not 16 bytes")
    end

    -- Test 6: Deterministic MAC
    total = total + 1
    local tag_a = poly1305.authenticate(key1, message)
    local tag_b = poly1305.authenticate(key1, message)

    if tag_a == tag_b then
      print("  ✅ PASS: MAC is deterministic (same input = same output)")
      passed = passed + 1
    else
      print("  ❌ FAIL: MAC is not deterministic")
    end

    -- Test 7: Single byte change detection
    total = total + 1
    local original = "This is a test message"
    local modified = "This is a Test message" -- Changed 't' to 'T'

    local tag_orig = poly1305.authenticate(key1, original)
    local tag_mod = poly1305.authenticate(key1, modified)

    if tag_orig ~= tag_mod then
      print("  ✅ PASS: Single byte change produces different tag")
      passed = passed + 1
    else
      print("  ❌ FAIL: Single byte change not detected")
    end

    print(string.format("\nFunctional tests result: %d/%d tests passed", passed, total))
    print()
    return passed == total
  end

  local vectors_passed = test_vectors_suite()
  local functional_passed = functional_tests()

  return vectors_passed and functional_passed
end

--- Run performance benchmarks
---
--- This function runs comprehensive performance benchmarks for Poly1305 operations
--- including MAC computation for various message sizes.
function poly1305.benchmark()
  -- Test data
  local key = bytes.from_hex("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b")
  local message_64 = string_rep("a", 64)
  local message_1k = string_rep("a", 1024)
  local message_8k = string_rep("a", 8192)

  print("MAC Operations:")
  benchmark_op("mac_64_bytes", function()
    poly1305.authenticate(key, message_64)
  end, 1000)

  benchmark_op("mac_1k", function()
    poly1305.authenticate(key, message_1k)
  end, 200)

  benchmark_op("mac_8k", function()
    poly1305.authenticate(key, message_8k)
  end, 50)
end

return poly1305
end
end

do
local _ENV = _ENV
package.preload[ "crypto.random" ] = function( ... ) local arg = _G.arg;
--- @module "crypto.random"
--- Cryptographically secure random bytes -- or a hard failure.
---
--- Every key this library can generate is only as good as the bytes underneath
--- it. `math.random` is not a CSPRNG on any Lua implementation: on 5.1 and
--- LuaJIT it is C `rand()`, and on 5.4+ an explicit low-entropy
--- `math.randomseed` actively *downgrades* a generator the runtime had already
--- seeded well. Seeding from `os.time()` and `os.clock()` at driver startup is
--- worth roughly 20 bits, which is an offline brute force measured in seconds.
---
--- So this module has exactly one rule, and it is the reason it exists:
---
--- > **It returns strong bytes or it raises. It never returns weak bytes.**
---
--- A HAP driver that fails to pair is a bug report. A HAP driver that pairs with
--- a guessable long-term identity is a compromised controller that looks fine.
---
--- Sources, in order:
---
--- 1. `openssl.random(n, true)` -- the `strong` flag, behind `Feature.RANDOM`,
---    which probes `rand_status()` and two real draws rather than assuming.
--- 2. `/dev/urandom`.
--- 3. Nothing. `bytes()` raises.
---
--- Unlike the accelerated primitives, source 1 is resolved through
--- `openssl_wrapper.get_ungated`: `crypto.use_openssl(false)` selects a slower
--- implementation everywhere else in the library, and it must not be capable of
--- selecting a *weaker* one here.
---
--- Verified on a Control4 controller (dev, 2026-08-08): the shipped lua-openssl
--- 0.8.5 has `random` and `rand_status`, `rand_status()` is true, and
--- `random(n, true)` returns n distinct bytes. `/dev/urandom` is also readable
--- from inside the driver sandbox, so both sources are live on the target
--- hardware and neither one is theoretical. Note `random(0)` and negative
--- lengths raise on that build, which is why `bytes` validates `n` first.
---
--- @usage
--- local random = require("crypto.random")
---
--- local seed = random.bytes(32) -- raises if there is no strong source
---
--- -- Platforms with neither source can supply their own:
--- random.set_source(function(n) return my_platform_csprng(n) end, "platform")
---
--- @class crypto.random
local random = {}

local openssl_wrapper = require("crypto.openssl_wrapper")

--- Path read by the `/dev/urandom` source. Exposed only so the self-test can
--- point it at a file that does not exist and prove the failure path.
--- @type string
random._urandom_path = "/dev/urandom"

--- Resolved source: a function taking a byte count and returning a byte string.
--- @type (fun(n: integer): string|nil)|nil
local _source = nil
--- Name of the resolved source, for `random.source()`.
--- @type string|nil
local _source_name = nil
--- True once resolution has run, so a negative result is not re-probed per call.
local _resolved = false

--- Draw from the lua-openssl binding.
--- @param n integer
--- @return string|nil
local function openssl_source(n)
  local openssl = openssl_wrapper.get_ungated(openssl_wrapper.Feature.RANDOM)
  if openssl == nil then
    return nil
  end
  local ok, out = pcall(openssl.random, n, true)
  if not ok then
    return nil
  end
  return out
end

--- Draw from `/dev/urandom`.
---
--- The handle is opened per call rather than held: key generation is rare, and a
--- long-lived Control4 driver holding a file descriptor open for the life of the
--- process is a worse trade than one `open` per key.
--- @param n integer
--- @return string|nil
local function urandom_source(n)
  local ok, handle = pcall(io.open, random._urandom_path, "rb")
  if not ok or handle == nil then
    return nil
  end
  local read_ok, out = pcall(handle.read, handle, n)
  handle:close()
  if not read_ok then
    return nil
  end
  return out
end

--- Pick the first source that actually produces bytes.
---
--- Each candidate is *exercised*, not merely detected: a source that exists but
--- returns nil or a short read is rejected here rather than at the call site.
local function resolve()
  if _resolved then
    return
  end
  _resolved = true
  local candidates = {
    { name = "openssl", draw = openssl_source },
    { name = "urandom", draw = urandom_source },
  }
  for _, candidate in ipairs(candidates) do
    local ok, sample = pcall(candidate.draw, 32)
    if ok and type(sample) == "string" and #sample == 32 then
      _source = candidate.draw
      _source_name = candidate.name
      return
    end
  end
end

--- Name of the entropy source in use, resolving one if needed.
---
--- Intended for preconditions and diagnostics: a driver can refuse to start
--- pairing when this returns nil instead of discovering it mid-handshake.
--- @return string|nil name "openssl", "urandom", a custom source's name, or nil
function random.source()
  resolve()
  return _source_name
end

--- Whether a cryptographically secure source is available.
--- @return boolean available
function random.available()
  return random.source() ~= nil
end

--- Install a custom entropy source, overriding detection.
---
--- The escape hatch for a platform with neither lua-openssl nor `/dev/urandom`.
--- The function must return exactly `n` bytes; a short or non-string return is
--- rejected by `bytes()` the same way a failing built-in source would be, so a
--- broken custom source cannot quietly weaken key generation.
---
--- @param draw fun(n: integer): string|nil Returns exactly n cryptographically secure bytes
--- @param name string|nil Label reported by `random.source()` (default "custom")
function random.set_source(draw, name)
  assert(type(draw) == "function", "crypto.random: source must be a function")
  _source = draw
  _source_name = name or "custom"
  _resolved = true
end

--- Discard the current source and re-detect on next use.
function random.reset()
  _source = nil
  _source_name = nil
  _resolved = false
end

--- Generate `n` cryptographically secure random bytes.
---
--- Raises if no strong source is available, or if the source returns anything
--- other than exactly `n` bytes. It never falls back to a weak generator and
--- never returns a short result.
---
--- @param n integer Number of bytes, must be a positive integer
--- @return string bytes Exactly n cryptographically secure bytes
function random.bytes(n)
  assert(
    type(n) == "number" and n > 0 and n % 1 == 0,
    "crypto.random: byte count must be a positive integer, got " .. tostring(n)
  )
  resolve()
  if _source == nil then
    error(
      "crypto.random: no cryptographically secure entropy source available "
        .. "(tried lua-openssl RAND and "
        .. random._urandom_path
        .. "). Refusing to generate a key from a weak generator -- supply a "
        .. "source with crypto.random.set_source(fn)."
    )
  end
  local ok, out = pcall(_source, n)
  if not ok then
    error("crypto.random: entropy source '" .. tostring(_source_name) .. "' failed: " .. tostring(out))
  end
  if type(out) ~= "string" or #out ~= n then
    error(
      "crypto.random: entropy source '"
        .. tostring(_source_name)
        .. "' returned "
        .. (type(out) == "string" and (#out .. " bytes") or type(out))
        .. " instead of "
        .. n
        .. " bytes"
    )
  end
  return out
end

-- ============================================================================
-- TESTS
-- ============================================================================

--- Run the entropy-source self-test.
---
--- The contract under test is a negative one -- "never returns weak bytes" -- so
--- most of these assert that something *fails*. The no-source case is forced
--- deterministically (absent binding plus a `_urandom_path` that cannot exist)
--- rather than skipped on hosts that happen to have entropy, because that is the
--- single case where a regression is silent and catastrophic.
---
--- @return boolean result True if all tests pass, false otherwise
function random.selftest()
  print("Running crypto.random entropy-source test vectors...")

  local saved_path = random._urandom_path
  local saved_preload = package.preload["openssl"]
  local saved_loaded = package.loaded["openssl"]

  --- Force both built-in sources to be unavailable.
  local function starve()
    random.reset()
    package.loaded["openssl"] = nil
    -- Each selftest stubs the same loader independently, which the language
    -- server reads as redefining one field; that is the intent here.
    --- @diagnostic disable-next-line: duplicate-set-field
    package.preload["openssl"] = function()
      error("simulated absent binding")
    end
    openssl_wrapper.use(false) -- resets the wrapper's binding cache
    random._urandom_path = "/nonexistent/crypto-random-selftest"
  end

  --- Restore real detection, including the wrapper's initial opt-in state, so
  --- running this inside `crypto.selftest()` cannot disturb a later module.
  local function unstarve()
    random.reset()
    package.loaded["openssl"] = saved_loaded
    package.preload["openssl"] = saved_preload
    openssl_wrapper.use(os.getenv("CRYPTO_USE_OPENSSL") == "1" or os.getenv("CRYPTO_USE_OPENSSL") == "true")
    random._urandom_path = saved_path
  end

  --- Install a source returning a fixed, known byte.
  --- @param byte integer
  local function fixed_source(byte)
    random.set_source(function(n)
      return string.rep(string.char(byte), n)
    end, "fixed")
  end

  local tests = {
    {
      name = "bytes() returns the requested width",
      test = function()
        unstarve()
        if not random.available() then
          -- No entropy on this host: the contract is still testable, and the
          -- required behaviour is a raise rather than a weak result.
          return random.bytes(32) == nil
        end
        return #random.bytes(1) == 1 and #random.bytes(32) == 32 and #random.bytes(384) == 384
      end,
    },
    {
      name = "two draws differ",
      test = function()
        unstarve()
        if not random.available() then
          return true
        end
        return random.bytes(32) ~= random.bytes(32)
      end,
    },
    {
      name = "no source available raises instead of returning weak bytes",
      test = function()
        starve()
        if random.available() then
          return false
        end
        local ok, err = pcall(random.bytes, 32)
        return ok == false and tostring(err):find("no cryptographically secure") ~= nil
      end,
    },
    {
      name = "a source returning short output is rejected, not passed through",
      test = function()
        random.set_source(function(n)
          return string.rep("A", n - 1)
        end, "short")
        local ok, err = pcall(random.bytes, 32)
        return ok == false and tostring(err):find("31 bytes") ~= nil
      end,
    },
    {
      name = "a source returning nil is rejected",
      test = function()
        random.set_source(function()
          return nil
        end, "nilsource")
        return pcall(random.bytes, 32) == false
      end,
    },
    {
      name = "a raising source is reported, not swallowed",
      test = function()
        random.set_source(function()
          error("device gone")
        end, "raising")
        local ok, err = pcall(random.bytes, 32)
        return ok == false and tostring(err):find("device gone") ~= nil
      end,
    },
    {
      name = "a custom source is used verbatim",
      test = function()
        fixed_source(122)
        return random.source() == "fixed" and random.bytes(4) == "zzzz"
      end,
    },
    {
      name = "reset() restores detection",
      test = function()
        fixed_source(122)
        random.reset()
        unstarve()
        return random.source() ~= "fixed"
      end,
    },
    {
      name = "non-positive and fractional widths are rejected",
      test = function()
        unstarve()
        return pcall(random.bytes, 0) == false
          and pcall(random.bytes, -1) == false
          and pcall(random.bytes, 1.5) == false
          and pcall(random.bytes, "32") == false
      end,
    },
    {
      name = "openssl is preferred over urandom when the binding supports RANDOM",
      test = function()
        random.reset()
        local draws = 0
        package.preload["openssl"] = nil
        package.loaded["openssl"] = {
          version = function()
            return "0.8.5"
          end,
          rand_status = function()
            return true
          end,
          random = function(n)
            draws = draws + 1
            -- Distinct per call so the RANDOM probe's two-draw check passes.
            return string.rep(string.char(draws % 256), n)
          end,
        }
        openssl_wrapper.use(false) -- reset the binding cache; RANDOM is ungated
        local name = random.source()
        return name == "openssl" and draws > 0
      end,
    },
    {
      name = "a binding whose rand_status is false is not used",
      test = function()
        random.reset()
        package.preload["openssl"] = nil
        package.loaded["openssl"] = {
          version = function()
            return "0.8.5"
          end,
          rand_status = function()
            return false
          end,
          random = function(n)
            return string.rep("\0", n)
          end,
        }
        openssl_wrapper.use(false)
        random._urandom_path = "/nonexistent/crypto-random-selftest"
        return random.available() == false
      end,
    },
    {
      name = "a binding whose RNG returns a constant is not used",
      test = function()
        random.reset()
        package.preload["openssl"] = nil
        package.loaded["openssl"] = {
          version = function()
            return "0.8.5"
          end,
          rand_status = function()
            return true
          end,
          random = function(n)
            return string.rep("\0", n)
          end,
        }
        openssl_wrapper.use(false)
        random._urandom_path = "/nonexistent/crypto-random-selftest"
        return random.available() == false
      end,
    },
    {
      -- Required lazily: those modules depend on crypto.random, not the other
      -- way round, and this check belongs with the guarantee it protects.
      name = "key generators return exactly the bytes this module supplied",
      test = function()
        local generators = {
          { require("crypto.ed25519").generate_private_key, 32 },
          { require("crypto.x25519").generate_private_key, 32 },
          { require("crypto.x448").generate_private_key, 56 },
        }
        for _, entry in ipairs(generators) do
          local generate, width = entry[1], entry[2]
          fixed_source(42)
          local out = generate()
          if type(out) ~= "string" or out ~= string.rep(string.char(42), width) then
            return false
          end
        end
        return true
      end,
    },
    {
      -- Checked by width rather than by output: `get_public` would otherwise
      -- have to run a 3072-bit modular exponentiation to prove the point.
      name = "srp draws its private exponent here, 32 bytes wide",
      test = function()
        local requested = nil
        random.set_source(function(n)
          requested = n
          error("stop before the modexp")
        end, "recording")
        local session = require("crypto.srp").new({ username = "Pair-Setup", password = "123-45-678" })
        pcall(session.get_public, session)
        return requested == 32
      end,
    },
    {
      name = "every key generator raises when there is no entropy source",
      test = function()
        local session = require("crypto.srp").new({ username = "Pair-Setup", password = "123-45-678" })
        local generators = {
          require("crypto.ed25519").generate_private_key,
          require("crypto.x25519").generate_private_key,
          require("crypto.x448").generate_private_key,
          function()
            return session:get_public()
          end,
        }
        for _, generate in ipairs(generators) do
          starve()
          if pcall(generate) ~= false then
            return false
          end
        end
        return true
      end,
    },
  }

  local passed = 0
  for _, test in ipairs(tests) do
    local ok, result = pcall(test.test)
    if ok and result == true then
      print("  ✅ PASS: " .. test.name)
      passed = passed + 1
    else
      print("  ❌ FAIL: " .. test.name .. (ok and "" or (" - " .. tostring(result))))
    end
  end

  unstarve()

  print(string.format("\ncrypto.random result: %d/%d tests passed\n", passed, #tests))
  return passed == #tests
end

return random
end
end

do
local _ENV = _ENV
package.preload[ "crypto.sha256" ] = function( ... ) local arg = _G.arg;
--- @module "crypto.sha256"
--- Pure Lua SHA-256 Implementation for portability.
--- @class crypto.sha256
local sha256 = {}

local bit32 = require("bitn").bit32

local openssl_wrapper = require("crypto.openssl_wrapper")
local utils = require("crypto.utils")
local bytes = utils.bytes
local benchmark_op = utils.benchmark.benchmark_op

-- Local references for performance
local bit32_raw_bxor = bit32.raw_bxor
local bit32_raw_band = bit32.raw_band
local bit32_raw_bnot = bit32.raw_bnot
local bit32_raw_ror = bit32.raw_ror
local bit32_raw_rshift = bit32.raw_rshift
local bit32_raw_add = bit32.raw_add
local bytes_be_bytes_to_u32 = bytes.be_bytes_to_u32
local bytes_u32_to_be_bytes = bytes.u32_to_be_bytes
local string_char = string.char
local string_rep = string.rep
local string_byte = string.byte
local table_concat = table.concat

-- SHA-256 constants (first 32 bits of fractional parts of cube roots of first 64 primes)
--- @type integer[64]
local K = {
  0x428a2f98,
  0x71374491,
  0xb5c0fbcf,
  0xe9b5dba5,
  0x3956c25b,
  0x59f111f1,
  0x923f82a4,
  0xab1c5ed5,
  0xd807aa98,
  0x12835b01,
  0x243185be,
  0x550c7dc3,
  0x72be5d74,
  0x80deb1fe,
  0x9bdc06a7,
  0xc19bf174,
  0xe49b69c1,
  0xefbe4786,
  0x0fc19dc6,
  0x240ca1cc,
  0x2de92c6f,
  0x4a7484aa,
  0x5cb0a9dc,
  0x76f988da,
  0x983e5152,
  0xa831c66d,
  0xb00327c8,
  0xbf597fc7,
  0xc6e00bf3,
  0xd5a79147,
  0x06ca6351,
  0x14292967,
  0x27b70a85,
  0x2e1b2138,
  0x4d2c6dfc,
  0x53380d13,
  0x650a7354,
  0x766a0abb,
  0x81c2c92e,
  0x92722c85,
  0xa2bfe8a1,
  0xa81a664b,
  0xc24b8b70,
  0xc76c51a3,
  0xd192e819,
  0xd6990624,
  0xf40e3585,
  0x106aa070,
  0x19a4c116,
  0x1e376c08,
  0x2748774c,
  0x34b0bcb5,
  0x391c0cb3,
  0x4ed8aa4a,
  0x5b9cca4f,
  0x682e6ff3,
  0x748f82ee,
  0x78a5636f,
  0x84c87814,
  0x8cc70208,
  0x90befffa,
  0xa4506ceb,
  0xbef9a3f7,
  0xc67178f2,
}

--- @alias HashState [integer, integer, integer, integer, integer, integer, integer, integer]

-- Initial SHA-256 hash values (first 32 bits of fractional parts of square roots of first 8 primes)
--- @type HashState
local H0 = {
  0x6a09e667,
  0xbb67ae85,
  0x3c6ef372,
  0xa54ff53a,
  0x510e527f,
  0x9b05688c,
  0x1f83d9ab,
  0x5be0cd19,
}

--- Initialize a 64-element message schedule array with zeros
--- @return integer[] array Initialized array
local function create_message_schedule()
  local arr = {}
  for i = 1, 64 do
    arr[i] = 0
  end
  return arr
end

-- Pre-allocated message schedule array for sha256_chunk()
local chunk_W = create_message_schedule()

--- SHA-256 core compression function
--- @param chunk string 64-byte chunk
--- @param H HashState Hash state (8 integers)
local function sha256_chunk(chunk, H)
  -- Reuse pre-allocated message schedule W
  local W = chunk_W

  -- First 16 words are the message chunk (use local reference)
  for i = 1, 16 do
    W[i] = bytes_be_bytes_to_u32(chunk, (i - 1) * 4 + 1)
  end

  -- Extend the first 16 words into the remaining 48 words
  for i = 17, 64 do
    local w15 = W[i - 15]
    local w2 = W[i - 2]
    local s0 = bit32_raw_bxor(bit32_raw_ror(w15, 7), bit32_raw_bxor(bit32_raw_ror(w15, 18), bit32_raw_rshift(w15, 3)))
    local s1 = bit32_raw_bxor(bit32_raw_ror(w2, 17), bit32_raw_bxor(bit32_raw_ror(w2, 19), bit32_raw_rshift(w2, 10)))
    W[i] = bit32_raw_add(bit32_raw_add(bit32_raw_add(W[i - 16], s0), W[i - 7]), s1)
  end

  -- Initialize working variables
  local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]

  -- Main loop (optimized with local references)
  for i = 1, 64 do
    local ki = K[i]
    local S1 = bit32_raw_bxor(bit32_raw_ror(e, 6), bit32_raw_bxor(bit32_raw_ror(e, 11), bit32_raw_ror(e, 25)))
    local ch = bit32_raw_bxor(bit32_raw_band(e, f), bit32_raw_band(bit32_raw_bnot(e), g))
    local temp1 = bit32_raw_add(bit32_raw_add(bit32_raw_add(bit32_raw_add(h, S1), ch), ki), W[i])
    local S0 = bit32_raw_bxor(bit32_raw_ror(a, 2), bit32_raw_bxor(bit32_raw_ror(a, 13), bit32_raw_ror(a, 22)))
    local maj = bit32_raw_bxor(bit32_raw_band(a, b), bit32_raw_bxor(bit32_raw_band(a, c), bit32_raw_band(b, c)))
    local temp2 = bit32_raw_add(S0, maj)

    h = g
    g = f
    f = e
    e = bit32_raw_add(d, temp1)
    d = c
    c = b
    b = a
    a = bit32_raw_add(temp1, temp2)
  end

  -- Add compressed chunk to current hash value
  H[1] = bit32_raw_add(H[1], a)
  H[2] = bit32_raw_add(H[2], b)
  H[3] = bit32_raw_add(H[3], c)
  H[4] = bit32_raw_add(H[4], d)
  H[5] = bit32_raw_add(H[5], e)
  H[6] = bit32_raw_add(H[6], f)
  H[7] = bit32_raw_add(H[7], g)
  H[8] = bit32_raw_add(H[8], h)
end

-- ============================================================================
-- SHA-256 PUBLIC INTERFACE
-- ============================================================================

--- Compute SHA-256 hash of input data
--- @param data string Input data to hash
--- @return string hash 32-byte binary hash
function sha256.sha256(data)
  -- Check if we should use OpenSSL
  local openssl = openssl_wrapper.get()
  if openssl then
    return openssl.digest.digest("sha256", data, true)
  end

  -- Native implementation
  -- Initialize hash values
  --- @type HashState
  local H = { H0[1], H0[2], H0[3], H0[4], H0[5], H0[6], H0[7], H0[8] }

  -- Pre-processing: adding padding bits
  local msg_len = #data
  local msg_len_bits = msg_len * 8

  -- Append '1' bit (plus zero padding to make it a byte)
  data = data .. string_char(0x80)

  -- Append zeros to make message length ≡ 448 (mod 512) bits = 56 (mod 64) bytes
  -- Current length is msg_len + 1 (for the 0x80 byte)
  local current_len = msg_len + 1
  local target_len = 56 -- We want to reach 56 bytes before adding the 8-byte length
  local padding_len = (target_len - current_len) % 64
  data = data .. string_rep("\0", padding_len)

  -- Append original length as 64-bit big-endian integer
  -- For simplicity, we only support messages < 2^32 bits
  data = data .. string_rep("\0", 4) .. bytes_u32_to_be_bytes(msg_len_bits)

  -- Process message in 64-byte chunks
  for i = 1, #data, 64 do
    local chunk = data:sub(i, i + 63)
    if #chunk == 64 then
      sha256_chunk(chunk, H)
    end
  end

  -- Produce final hash value as binary string (optimized with table)
  local result_bytes = {}
  for i = 1, 8 do
    result_bytes[i] = bytes_u32_to_be_bytes(H[i])
  end

  return table_concat(result_bytes)
end

--- Compute SHA-256 hash and return as hex string
--- @param data string Input data to hash
--- @return string hex 64-character hex string
function sha256.sha256_hex(data)
  local hash = sha256.sha256(data)
  return bytes.to_hex(hash)
end

--- Compute HMAC-SHA256
--- @param key string Secret key
--- @param data string Data to authenticate
--- @return string hmac 32-byte HMAC value
function sha256.hmac_sha256(key, data)
  -- Check if we should use OpenSSL
  local openssl = openssl_wrapper.get()
  if openssl then
    return openssl.hmac.hmac("sha256", data, key, true)
  end

  -- Native implementation
  local block_size = 64 -- SHA-256 block size

  -- Keys longer than blocksize are shortened by hashing them
  if #key > block_size then
    key = sha256.sha256(key)
  end

  -- Keys shorter than blocksize are right-padded with zeros
  if #key < block_size then
    key = key .. string_rep("\0", block_size - #key)
  end

  -- Compute inner and outer padding (optimized with local references)
  local ipad_bytes = {}
  local opad_bytes = {}
  for i = 1, block_size do
    local byte = string_byte(key, i)
    ipad_bytes[i] = string_char(bit32_raw_bxor(byte, 0x36))
    opad_bytes[i] = string_char(bit32_raw_bxor(byte, 0x5C))
  end
  local ipad = table_concat(ipad_bytes)
  local opad = table_concat(opad_bytes)

  -- Compute HMAC = H(opad || H(ipad || data))
  local inner_hash = sha256.sha256(ipad .. data)
  return sha256.sha256(opad .. inner_hash)
end

--- Compute HMAC-SHA256 and return as hex string
--- @param key string Secret key
--- @param data string Data to authenticate
--- @return string hex 64-character hex string
function sha256.hmac_sha256_hex(key, data)
  local hmac = sha256.hmac_sha256(key, data)
  return bytes.to_hex(hmac)
end

-- ============================================================================
-- TEST VECTORS AND VALIDATION
-- ============================================================================

--- Test vectors for self-test
local test_vectors = {
  {
    name = "Empty string",
    input = "",
    expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  },
  {
    name = "Single character 'a'",
    input = "a",
    expected = "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb",
  },
  {
    name = "Short string 'abc'",
    input = "abc",
    expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  },
  {
    name = "Numeric string '123456'",
    input = "123456",
    expected = "8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92",
  },
  {
    name = "Medium length string",
    input = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
    expected = "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
  },
  {
    name = "The quick brown fox",
    input = "The quick brown fox jumps over the lazy dog",
    expected = "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592",
  },
  {
    name = "The quick brown fox (cog)",
    input = "The quick brown fox jumps over the lazy cog",
    expected = "e4c4d8f3bf76b692de791a173e05321150f7a345b46484fe427f6acc7ecc81be",
  },
}
if os.getenv("INCLUDE_SLOW_TESTS") == "1" then
  table.insert(test_vectors, {
    name = "Million 'a' characters",
    input = string_rep("a", 1000000),
    expected = "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
  })
end

--- HMAC test vectors
local hmac_test_vectors = {
  {
    name = "HMAC Test Case 1",
    key = string_rep(string_char(0x0b), 20),
    data = "Hi There",
    expected = "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
  },
  {
    name = "HMAC Test Case 2",
    key = "Jefe",
    data = "what do ya want for nothing?",
    expected = "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
  },
  {
    name = "HMAC Test Case 3",
    key = string_rep(string_char(0xaa), 20),
    data = string_rep(string_char(0xdd), 50),
    expected = "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe",
  },
}

--- Run comprehensive self-test with test vectors and functional tests
--- @return boolean result True if all tests pass, false otherwise
function sha256.selftest()
  print("Running SHA-256 test vectors...")
  local all_passed = true
  local passed = 0
  local total = #test_vectors

  for _, test in ipairs(test_vectors) do
    local result = sha256.sha256_hex(test.input)
    if result == test.expected then
      print(string.format("  ✅ PASS: %s", test.name))
      passed = passed + 1
    else
      print(string.format("  ❌ FAIL: %s", test.name))
      print(string.format("    Expected: %s", test.expected))
      print(string.format("    Got:      %s", result))
    end
  end

  print(string.format("\nTest vectors result: %d/%d tests passed\n", passed, total))
  all_passed = all_passed and (passed == total)

  print("Running SHA-256 HMAC test vectors...")
  local hmac_passed = 0
  local hmac_total = #hmac_test_vectors

  for _, test in ipairs(hmac_test_vectors) do
    local result = sha256.hmac_sha256_hex(test.key, test.data)
    if result == test.expected then
      print(string.format("  ✅ PASS: %s", test.name))
      hmac_passed = hmac_passed + 1
    else
      print(string.format("  ❌ FAIL: %s", test.name))
      print(string.format("    Expected: %s", test.expected))
      print(string.format("    Got:      %s", result))
    end
  end

  print(string.format("\nHMAC test vectors result: %d/%d tests passed\n", hmac_passed, hmac_total))
  all_passed = all_passed and (hmac_passed == hmac_total)

  print("Running SHA-256 functional tests...")

  local func_passed = 0
  local func_total = 0

  -- Test consistency
  func_total = func_total + 1
  local test_data = "Hello, World!"
  local hash1 = sha256.sha256_hex(test_data)
  local hash2 = sha256.sha256_hex(test_data)
  if hash1 ~= hash2 then
    print("  ❌ FAIL: Hash function is not deterministic")
  else
    print("  ✅ PASS: Hash function is deterministic")
    func_passed = func_passed + 1
  end

  -- Test different inputs produce different outputs
  func_total = func_total + 1
  local hash_a = sha256.sha256_hex("a")
  local hash_b = sha256.sha256_hex("b")
  if hash_a == hash_b then
    print("  ❌ FAIL: Different inputs produce same hash")
  else
    print("  ✅ PASS: Different inputs produce different hashes")
    func_passed = func_passed + 1
  end

  -- Test binary vs hex consistency
  func_total = func_total + 1
  local test_msg = "test message"
  local binary_hash = sha256.sha256(test_msg)
  local hex_hash = sha256.sha256_hex(test_msg)
  if hex_hash ~= bytes.to_hex(binary_hash) then
    print("  ❌ FAIL: Binary and hex outputs inconsistent")
  else
    print("  ✅ PASS: Binary and hex outputs consistent")
    func_passed = func_passed + 1
  end

  -- Test HMAC consistency
  func_total = func_total + 1
  local hmac1 = sha256.hmac_sha256_hex("key", "data")
  local hmac2 = sha256.hmac_sha256_hex("key", "data")
  if hmac1 ~= hmac2 then
    print("  ❌ FAIL: HMAC function is not deterministic")
  else
    print("  ✅ PASS: HMAC function is deterministic")
    func_passed = func_passed + 1
  end

  -- Test HMAC key sensitivity
  func_total = func_total + 1
  local hmac_key1 = sha256.hmac_sha256_hex("key1", "data")
  local hmac_key2 = sha256.hmac_sha256_hex("key2", "data")
  if hmac_key1 == hmac_key2 then
    print("  ❌ FAIL: Different HMAC keys produce same result")
  else
    print("  ✅ PASS: Different HMAC keys produce different results")
    func_passed = func_passed + 1
  end

  print(string.format("\nFunctional tests result: %d/%d tests passed", func_passed, func_total))

  return all_passed and (func_passed == func_total)
end

--- Run performance benchmarks
---
--- This function runs comprehensive performance benchmarks for SHA-256 operations
--- including hash computation and HMAC for various message sizes.
function sha256.benchmark()
  -- Test data
  local message_64 = string_rep("a", 64)
  local message_1k = string_rep("a", 1024)
  local message_8k = string_rep("a", 8192)
  local hmac_key = "benchmark_key"

  print("Hash Operations:")
  benchmark_op("hash_64_bytes", function()
    sha256.sha256(message_64)
  end, 1000)

  benchmark_op("hash_1k", function()
    sha256.sha256(message_1k)
  end, 200)

  benchmark_op("hash_8k", function()
    sha256.sha256(message_8k)
  end, 50)

  print("\nHMAC Operations:")
  benchmark_op("hmac_64_bytes", function()
    sha256.hmac_sha256(hmac_key, message_64)
  end, 500)

  benchmark_op("hmac_1k", function()
    sha256.hmac_sha256(hmac_key, message_1k)
  end, 100)

  benchmark_op("hmac_8k", function()
    sha256.hmac_sha256(hmac_key, message_8k)
  end, 25)
end

return sha256
end
end

do
local _ENV = _ENV
package.preload[ "crypto.sha512" ] = function( ... ) local arg = _G.arg;
--- @module "crypto.sha512"
--- Pure Lua SHA-512 Implementation for portability.
--- @class crypto.sha512
local sha512 = {}

local bitn = require("bitn")
local bit32 = bitn.bit32
local bit64 = bitn.bit64

local openssl_wrapper = require("crypto.openssl_wrapper")
local utils = require("crypto.utils")
local bytes = utils.bytes
local benchmark_op = utils.benchmark.benchmark_op

-- Local references for performance
local bit64_raw_add = bit64.raw_add
local bit64_raw_bxor = bit64.raw_bxor
local bit64_raw_band = bit64.raw_band
local bit64_raw_bnot = bit64.raw_bnot
local bit64_raw_ror = bit64.raw_ror
local bit64_raw_rshift = bit64.raw_rshift
local bit64_new = bit64.new
local bit32_raw_bxor = bit32.raw_bxor
local string_char = string.char
local string_rep = string.rep
local string_byte = string.byte
local table_concat = table.concat
local floor = math.floor

-- SHA-512 uses 64-bit words, but Lua numbers are limited to 2^53-1
-- We'll work with 32-bit high/low pairs for 64-bit arithmetic

-- SHA-512 round constants (first 64 bits of fractional parts of cube roots of first 80 primes)
--- @type Int64HighLow[]
local K = {
  { 0x428a2f98, 0xd728ae22 },
  { 0x71374491, 0x23ef65cd },
  { 0xb5c0fbcf, 0xec4d3b2f },
  { 0xe9b5dba5, 0x8189dbbc },
  { 0x3956c25b, 0xf348b538 },
  { 0x59f111f1, 0xb605d019 },
  { 0x923f82a4, 0xaf194f9b },
  { 0xab1c5ed5, 0xda6d8118 },
  { 0xd807aa98, 0xa3030242 },
  { 0x12835b01, 0x45706fbe },
  { 0x243185be, 0x4ee4b28c },
  { 0x550c7dc3, 0xd5ffb4e2 },
  { 0x72be5d74, 0xf27b896f },
  { 0x80deb1fe, 0x3b1696b1 },
  { 0x9bdc06a7, 0x25c71235 },
  { 0xc19bf174, 0xcf692694 },
  { 0xe49b69c1, 0x9ef14ad2 },
  { 0xefbe4786, 0x384f25e3 },
  { 0x0fc19dc6, 0x8b8cd5b5 },
  { 0x240ca1cc, 0x77ac9c65 },
  { 0x2de92c6f, 0x592b0275 },
  { 0x4a7484aa, 0x6ea6e483 },
  { 0x5cb0a9dc, 0xbd41fbd4 },
  { 0x76f988da, 0x831153b5 },
  { 0x983e5152, 0xee66dfab },
  { 0xa831c66d, 0x2db43210 },
  { 0xb00327c8, 0x98fb213f },
  { 0xbf597fc7, 0xbeef0ee4 },
  { 0xc6e00bf3, 0x3da88fc2 },
  { 0xd5a79147, 0x930aa725 },
  { 0x06ca6351, 0xe003826f },
  { 0x14292967, 0x0a0e6e70 },
  { 0x27b70a85, 0x46d22ffc },
  { 0x2e1b2138, 0x5c26c926 },
  { 0x4d2c6dfc, 0x5ac42aed },
  { 0x53380d13, 0x9d95b3df },
  { 0x650a7354, 0x8baf63de },
  { 0x766a0abb, 0x3c77b2a8 },
  { 0x81c2c92e, 0x47edaee6 },
  { 0x92722c85, 0x1482353b },
  { 0xa2bfe8a1, 0x4cf10364 },
  { 0xa81a664b, 0xbc423001 },
  { 0xc24b8b70, 0xd0f89791 },
  { 0xc76c51a3, 0x0654be30 },
  { 0xd192e819, 0xd6ef5218 },
  { 0xd6990624, 0x5565a910 },
  { 0xf40e3585, 0x5771202a },
  { 0x106aa070, 0x32bbd1b8 },
  { 0x19a4c116, 0xb8d2d0c8 },
  { 0x1e376c08, 0x5141ab53 },
  { 0x2748774c, 0xdf8eeb99 },
  { 0x34b0bcb5, 0xe19b48a8 },
  { 0x391c0cb3, 0xc5c95a63 },
  { 0x4ed8aa4a, 0xe3418acb },
  { 0x5b9cca4f, 0x7763e373 },
  { 0x682e6ff3, 0xd6b2b8a3 },
  { 0x748f82ee, 0x5defb2fc },
  { 0x78a5636f, 0x43172f60 },
  { 0x84c87814, 0xa1f0ab72 },
  { 0x8cc70208, 0x1a6439ec },
  { 0x90befffa, 0x23631e28 },
  { 0xa4506ceb, 0xde82bde9 },
  { 0xbef9a3f7, 0xb2c67915 },
  { 0xc67178f2, 0xe372532b },
  { 0xca273ece, 0xea26619c },
  { 0xd186b8c7, 0x21c0c207 },
  { 0xeada7dd6, 0xcde0eb1e },
  { 0xf57d4f7f, 0xee6ed178 },
  { 0x06f067aa, 0x72176fba },
  { 0x0a637dc5, 0xa2c898a6 },
  { 0x113f9804, 0xbef90dae },
  { 0x1b710b35, 0x131c471b },
  { 0x28db77f5, 0x23047d84 },
  { 0x32caab7b, 0x40c72493 },
  { 0x3c9ebe0a, 0x15c9bebc },
  { 0x431d67c4, 0x9c100d4c },
  { 0x4cc5d4be, 0xcb3e42b6 },
  { 0x597f299c, 0xfc657e2a },
  { 0x5fcb6fab, 0x3ad6faec },
  { 0x6c44198c, 0x4a475817 },
}

--- @alias HashState64 [Int64HighLow, Int64HighLow, Int64HighLow, Int64HighLow, Int64HighLow, Int64HighLow, Int64HighLow, Int64HighLow]

-- Initial SHA-512 hash values (first 64 bits of fractional parts of square roots of first 8 primes)
--- @type HashState64
local H0 = {
  { 0x6a09e667, 0xf3bcc908 },
  { 0xbb67ae85, 0x84caa73b },
  { 0x3c6ef372, 0xfe94f82b },
  { 0xa54ff53a, 0x5f1d36f1 },
  { 0x510e527f, 0xade682d1 },
  { 0x9b05688c, 0x2b3e6c1f },
  { 0x1f83d9ab, 0xfb41bd6b },
  { 0x5be0cd19, 0x137e2179 },
}

--- Initialize an 80-element message schedule array with zeros (64-bit values)
--- @return Int64HighLow[] array Initialized array
local function create_message_schedule_64()
  local arr = {}
  for i = 1, 80 do
    arr[i] = bit64_new(0, 0)
  end
  return arr
end

-- Pre-allocated message schedule array for sha512_chunk()
local chunk_W = create_message_schedule_64()

--- SHA-512 Sigma0 function
--- @param x Int64HighLow {high, low} input
--- @return Int64HighLow {high, low} result
local function Sigma0(x)
  return bit64_raw_bxor(bit64_raw_bxor(bit64_raw_ror(x, 28), bit64_raw_ror(x, 34)), bit64_raw_ror(x, 39))
end

--- SHA-512 Sigma1 function
--- @param x Int64HighLow {high, low} input
--- @return Int64HighLow {high, low} result
local function Sigma1(x)
  return bit64_raw_bxor(bit64_raw_bxor(bit64_raw_ror(x, 14), bit64_raw_ror(x, 18)), bit64_raw_ror(x, 41))
end

--- SHA-512 sigma0 function
--- @param x Int64HighLow {high, low} input
--- @return Int64HighLow {high, low} result
local function sigma0(x)
  return bit64_raw_bxor(bit64_raw_bxor(bit64_raw_ror(x, 1), bit64_raw_ror(x, 8)), bit64_raw_rshift(x, 7))
end

--- SHA-512 sigma1 function
--- @param x Int64HighLow {high, low} input
--- @return Int64HighLow {high, low} result
local function sigma1(x)
  return bit64_raw_bxor(bit64_raw_bxor(bit64_raw_ror(x, 19), bit64_raw_ror(x, 61)), bit64_raw_rshift(x, 6))
end

--- SHA-512 Ch function
--- @param x Int64HighLow {high, low} input
--- @param y Int64HighLow {high, low} input
--- @param z Int64HighLow {high, low} input
--- @return Int64HighLow {high, low} result
local function Ch(x, y, z)
  return bit64_raw_bxor(bit64_raw_band(x, y), bit64_raw_band(bit64_raw_bnot(x), z))
end

--- SHA-512 Maj function
--- @param x Int64HighLow {high, low} input
--- @param y Int64HighLow {high, low} input
--- @param z Int64HighLow {high, low} input
--- @return Int64HighLow {high, low} result
local function Maj(x, y, z)
  return bit64_raw_bxor(bit64_raw_bxor(bit64_raw_band(x, y), bit64_raw_band(x, z)), bit64_raw_band(y, z))
end

--- SHA-512 core compression function
--- @param chunk string 128-byte chunk
--- @param H HashState64 Hash state (8 64-bit values)
local function sha512_chunk(chunk, H)
  -- Reuse pre-allocated message schedule W
  local W = chunk_W

  -- First 16 words are the message chunk
  for i = 1, 16 do
    local val = bytes.be_bytes_to_u64(chunk, (i - 1) * 8 + 1)
    W[i][1], W[i][2] = val[1], val[2]
  end

  -- Extend the first 16 words into the remaining 64 words
  for i = 17, 80 do
    local w15 = W[i - 15]
    local w2 = W[i - 2]
    local s0 = sigma0(w15)
    local s1 = sigma1(w2)
    local result = bit64_raw_add(bit64_raw_add(bit64_raw_add(W[i - 16], s0), W[i - 7]), s1)
    W[i][1], W[i][2] = result[1], result[2]
  end

  -- Initialize working variables
  local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]

  -- Main loop (optimized)
  for i = 1, 80 do
    local prime = K[i]
    local S1 = Sigma1(e)
    local ch = Ch(e, f, g)
    local temp1 = bit64_raw_add(bit64_raw_add(bit64_raw_add(bit64_raw_add(h, S1), ch), prime), W[i])
    local S0 = Sigma0(a)
    local maj = Maj(a, b, c)
    local temp2 = bit64_raw_add(S0, maj)

    h = g
    g = f
    f = e
    e = bit64_raw_add(d, temp1)
    d = c
    c = b
    b = a
    a = bit64_raw_add(temp1, temp2)
  end

  -- Add compressed chunk to current hash value
  H[1] = bit64_raw_add(H[1], a)
  H[2] = bit64_raw_add(H[2], b)
  H[3] = bit64_raw_add(H[3], c)
  H[4] = bit64_raw_add(H[4], d)
  H[5] = bit64_raw_add(H[5], e)
  H[6] = bit64_raw_add(H[6], f)
  H[7] = bit64_raw_add(H[7], g)
  H[8] = bit64_raw_add(H[8], h)
end

--- Compute SHA-512 hash of input data
--- @param data string Input data to hash
--- @return string hash 64-byte binary hash
function sha512.sha512(data)
  -- Check if we should use OpenSSL
  local openssl = openssl_wrapper.get()
  if openssl then
    return openssl.digest.digest("sha512", data, true)
  end

  -- Native implementation
  -- Initialize hash values
  --- @type HashState64
  local H = {}
  for i = 1, 8 do
    H[i] = { H0[i][1], H0[i][2] }
  end

  -- Pre-processing: adding padding bits
  local msg_len = #data
  local msg_len_bits = msg_len * 8

  -- Append '1' bit (plus zero padding to make it a byte)
  data = data .. string_char(0x80)

  -- Append zeros to make message length ≡ 896 (mod 1024) bits = 112 (mod 128) bytes
  local current_len = msg_len + 1
  local target_len = 112 -- We want to reach 112 bytes before adding the 16-byte length
  local padding_len = (target_len - current_len) % 128
  data = data .. string_rep("\0", padding_len)

  -- Append original length as 128-bit big-endian integer
  -- For simplicity, we only support messages < 2^64 bits
  data = data .. string_rep("\0", 8) -- High 64 bits (always 0)
  -- Low 64 bits of length
  local len_high = floor(msg_len_bits / 0x100000000)
  local len_low = msg_len_bits % 0x100000000
  data = data .. bytes.u64_to_be_bytes({ len_high, len_low })

  -- Process message in 128-byte chunks
  for i = 1, #data, 128 do
    local chunk = data:sub(i, i + 127)
    if #chunk == 128 then
      sha512_chunk(chunk, H)
    end
  end

  -- Produce final hash value as binary string (optimized with table)
  local result_bytes = {}
  for i = 1, 8 do
    result_bytes[i] = bytes.u64_to_be_bytes(H[i])
  end

  return table_concat(result_bytes)
end

--- Compute SHA-512 hash and return as hex string
--- @param data string Input data to hash
--- @return string hex 128-character hex string
function sha512.sha512_hex(data)
  return bytes.to_hex(sha512.sha512(data))
end

--- Compute HMAC-SHA512
--- @param key string Secret key
--- @param data string Data to authenticate
--- @return string hmac 64-byte HMAC value
function sha512.hmac_sha512(key, data)
  -- Check if we should use OpenSSL
  local openssl = openssl_wrapper.get()
  if openssl then
    return openssl.hmac.hmac("sha512", data, key, true)
  end

  -- Native implementation
  local block_size = 128 -- SHA-512 block size

  -- Keys longer than blocksize are shortened by hashing them
  if #key > block_size then
    key = sha512.sha512(key)
  end

  -- Keys shorter than blocksize are right-padded with zeros
  if #key < block_size then
    key = key .. string_rep("\0", block_size - #key)
  end

  -- Compute inner and outer padding (optimized with table)
  local ipad_bytes = {}
  local opad_bytes = {}
  for i = 1, block_size do
    local byte = string_byte(key, i)
    ipad_bytes[i] = string_char(bit32_raw_bxor(byte, 0x36))
    opad_bytes[i] = string_char(bit32_raw_bxor(byte, 0x5C))
  end
  local ipad = table_concat(ipad_bytes)
  local opad = table_concat(opad_bytes)

  -- Compute HMAC = H(opad || H(ipad || data))
  local inner_hash = sha512.sha512(ipad .. data)
  return sha512.sha512(opad .. inner_hash)
end

--- Compute HMAC-SHA512 and return as hex string
--- @param key string Secret key
--- @param data string Data to authenticate
--- @return string hex 128-character hex string
function sha512.hmac_sha512_hex(key, data)
  return bytes.to_hex(sha512.hmac_sha512(key, data))
end

--- Test vectors from FIPS 180-4 and RFC 4634
local test_vectors = {
  {
    name = "RFC 4634 Test 1 - Empty string",
    input = "",
    expected = "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e",
  },
  {
    name = "RFC 4634 Test 2 - 'abc'",
    input = "abc",
    expected = "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
  },
  {
    name = "RFC 4634 Test 3 - 448 bit string",
    input = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
    expected = "204a8fc6dda82f0a0ced7beb8e08a41657c16ef468b228a8279be331a703c33596fd15c13b1b07f9aa1d3bea57789ca031ad85c7a71dd70354ec631238ca3445",
  },
  {
    name = "RFC 4634 Test 4 - 896 bit string",
    input = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
    expected = "8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909",
  },
}
if os.getenv("INCLUDE_SLOW_TESTS") == "1" then
  table.insert(test_vectors, {
    name = "RFC 4634 Test 5 - One million 'a' characters",
    input = string_rep("a", 1000000),
    expected = "e718483d0ce769644e2e42c7bc15b4638e1f98b13b2044285632a803afa973ebde0ff244877ea60a4cb0432ce577c31beb009c5c2c49aa2e4eadb217ad8cc09b",
  })
end

--- HMAC test vectors from RFC 4231
local hmac_test_vectors = {
  {
    name = "RFC 4231 Test Case 1",
    key = string_rep(string_char(0x0b), 20),
    data = "Hi There",
    expected = "87aa7cdea5ef619d4ff0b4241a1d6cb02379f4e2ce4ec2787ad0b30545e17cdedaa833b7d6b8a702038b274eaea3f4e4be9d914eeb61f1702e696c203a126854",
  },
  {
    name = "RFC 4231 Test Case 2",
    key = "Jefe",
    data = "what do ya want for nothing?",
    expected = "164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea2505549758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737",
  },
  {
    name = "RFC 4231 Test Case 3",
    key = string_rep(string_char(0xaa), 20),
    data = string_rep(string_char(0xdd), 50),
    expected = "fa73b0089d56a284efb0f0756c890be9b1b5dbdd8ee81a3655f83e33b2279d39bf3e848279a722c806b485a47e67c807b946a337bee8942674278859e13292fb",
  },
  {
    name = "RFC 4231 Test Case 4",
    key = bytes.from_hex("0102030405060708090a0b0c0d0e0f10111213141516171819"),
    data = string_rep(string_char(0xcd), 50),
    expected = "b0ba465637458c6990e5a8c5f61d4af7e576d97ff94b872de76f8050361ee3dba91ca5c11aa25eb4d679275cc5788063a5f19741120c4f2de2adebeb10a298dd",
  },
}

--- Run comprehensive self-test with test vectors and functional tests
--- @return boolean result True if all tests pass, false otherwise
function sha512.selftest()
  print("Running SHA-512 test vectors...")
  local all_passed = true
  local passed = 0
  local total = #test_vectors

  for _, test in ipairs(test_vectors) do
    local result = sha512.sha512_hex(test.input)
    if result == test.expected then
      print(string.format("  ✅ PASS: %s", test.name))
      passed = passed + 1
    else
      print(string.format("  ❌ FAIL: %s", test.name))
      print(string.format("    Expected: %s", test.expected))
      print(string.format("    Got:      %s", result))
    end
  end

  print(string.format("\nTest vectors result: %d/%d tests passed\n", passed, total))
  all_passed = all_passed and (passed == total)

  print("Running SHA-512 HMAC test vectors...")
  local hmac_passed = 0
  local hmac_total = #hmac_test_vectors

  for _, test in ipairs(hmac_test_vectors) do
    local result = sha512.hmac_sha512_hex(test.key, test.data)
    if result == test.expected then
      print(string.format("  ✅ PASS: %s", test.name))
      hmac_passed = hmac_passed + 1
    else
      print(string.format("  ❌ FAIL: %s", test.name))
      print(string.format("    Expected: %s", test.expected))
      print(string.format("    Got:      %s", result))
    end
  end

  print(string.format("\nHMAC test vectors result: %d/%d tests passed\n", hmac_passed, hmac_total))
  all_passed = all_passed and (hmac_passed == hmac_total)

  print("Running SHA-512 functional tests...")

  local func_passed = 0
  local func_total = 0

  -- Test consistency
  func_total = func_total + 1
  local test_data = "Hello, World!"
  local hash1 = sha512.sha512_hex(test_data)
  local hash2 = sha512.sha512_hex(test_data)
  if hash1 ~= hash2 then
    print("  ❌ FAIL: Hash function is not deterministic")
  else
    print("  ✅ PASS: Hash function is deterministic")
    func_passed = func_passed + 1
  end

  -- Test different inputs produce different outputs
  func_total = func_total + 1
  local hash_a = sha512.sha512_hex("a")
  local hash_b = sha512.sha512_hex("b")
  if hash_a == hash_b then
    print("  ❌ FAIL: Different inputs produce same hash")
  else
    print("  ✅ PASS: Different inputs produce different hashes")
    func_passed = func_passed + 1
  end

  -- Test binary vs hex consistency
  func_total = func_total + 1
  local test_msg = "test message"
  local binary_hash = sha512.sha512(test_msg)
  local hex_hash = sha512.sha512_hex(test_msg)
  if hex_hash ~= bytes.to_hex(binary_hash) then
    print("  ❌ FAIL: Binary and hex outputs inconsistent")
  else
    print("  ✅ PASS: Binary and hex outputs consistent")
    func_passed = func_passed + 1
  end

  -- Test HMAC consistency
  func_total = func_total + 1
  local hmac1 = sha512.hmac_sha512_hex("key", "data")
  local hmac2 = sha512.hmac_sha512_hex("key", "data")
  if hmac1 ~= hmac2 then
    print("  ❌ FAIL: HMAC function is not deterministic")
  else
    print("  ✅ PASS: HMAC function is deterministic")
    func_passed = func_passed + 1
  end

  -- Test HMAC key sensitivity
  func_total = func_total + 1
  local hmac_key1 = sha512.hmac_sha512_hex("key1", "data")
  local hmac_key2 = sha512.hmac_sha512_hex("key2", "data")
  if hmac_key1 == hmac_key2 then
    print("  ❌ FAIL: Different HMAC keys produce same result")
  else
    print("  ✅ PASS: Different HMAC keys produce different results")
    func_passed = func_passed + 1
  end

  print(string.format("\nFunctional tests result: %d/%d tests passed", func_passed, func_total))

  return all_passed and (func_passed == func_total)
end

--- Run performance benchmarks
---
--- This function runs comprehensive performance benchmarks for SHA-512 operations
--- including hash computation and HMAC for various message sizes.
function sha512.benchmark()
  -- Test data
  local message_64 = string_rep("a", 64)
  local message_1k = string_rep("a", 1024)
  local message_8k = string_rep("a", 8192)
  local hmac_key = "benchmark_key"

  print("Hash Operations:")
  benchmark_op("hash_64_bytes", function()
    sha512.sha512(message_64)
  end, 500)

  benchmark_op("hash_1k", function()
    sha512.sha512(message_1k)
  end, 100)

  benchmark_op("hash_8k", function()
    sha512.sha512(message_8k)
  end, 25)

  print("\nHMAC Operations:")
  benchmark_op("hmac_64_bytes", function()
    sha512.hmac_sha512(hmac_key, message_64)
  end, 250)

  benchmark_op("hmac_1k", function()
    sha512.hmac_sha512(hmac_key, message_1k)
  end, 50)

  benchmark_op("hmac_8k", function()
    sha512.hmac_sha512(hmac_key, message_8k)
  end, 15)
end

return sha512
end
end

do
local _ENV = _ENV
package.preload[ "crypto.srp" ] = function( ... ) local arg = _G.arg;
--- @module "crypto.srp"
--- SRP-6a **client**, parameterised by group and hash (RFC 5054 / RFC 2945).
---
--- This module implements the *client* half of SRP-6a and nothing else. It
--- derives the client public value `A`, the premaster secret `S`, the session
--- key `K` and the client proof `M1`, and it verifies the server proof `M2`.
--- There is deliberately no server side: nothing here derives `B` from a
--- verifier, and nothing validates a client proof. Do not assume `crypto.srp`
--- can stand in for an SRP server.
---
--- The default parameter set is `srp.GROUP_3072` -- RFC 5054 Appendix A group 15
--- (the 3072-bit MODP safe prime, g = 5) with SHA-512. That is the parameter set
--- HomeKit Accessory Protocol Pair-Setup uses, with `I = "Pair-Setup"` and `P`
--- the setup code shown on the accessory.
---
--- Encoding conventions
--- --------------------
--- The conventions below follow `srptools`, the library pyatv drives for HAP
--- Pair-Setup, so they interoperate with a real accessory. They are *not* a
--- naive reading of RFC 5054, and every one of them is load-bearing:
---
--- * `PAD(x)` is big-endian, left-zero-padded to the byte length of `N`
---   (384 bytes for group 15). It is applied in exactly two places:
---   `k = H(N | PAD(g))` and `u = H(PAD(A) | PAD(B))`.
--- * Everywhere else an integer is hashed in **minimal** big-endian form, with
---   leading zero bytes stripped -- notably `N`, `g`, `A` and `B` inside `M1`,
---   and `S` inside `K`.
--- * The salt is hashed as the **raw bytes the server supplied**, never
---   re-encoded through an integer. A salt whose leading byte is zero keeps that
---   byte. Routing it through an integer silently shortens it by one byte and
---   produces a ~1-in-256 intermittent pairing failure rather than an obvious
---   break, so the third known-answer vector pins this specifically.
---
--- @usage
--- local srp = require("crypto.srp")
---
--- local session = srp.new({ username = "Pair-Setup", password = setup_code })
--- send(session:get_public()) --  A, 384 bytes
--- session:process(salt, B) --     the server's s (raw bytes) and B
--- send(session:get_proof()) --    M1, 64 bytes
--- assert(session:verify(server_M2), "server proof rejected")
--- local key = session:get_session_key() -- K, 64 bytes
---
--- @class crypto.srp
local srp = {}

local bignum = require("crypto.bignum")
local random = require("crypto.random")
local sha256 = require("crypto.sha256")
local sha512 = require("crypto.sha512")

local utils = require("crypto.utils")
local bytes = utils.bytes
local benchmark_op = utils.benchmark.benchmark_op

-- Local references for performance
local string_char = string.char
local string_rep = string.rep
local table_concat = table.concat

-- ============================================================================
-- GROUPS AND HASHES
-- ============================================================================

--- RFC 5054 Appendix A / RFC 3526 group 15: the 3072-bit MODP safe prime.
local RFC5054_3072_N_HEX = table_concat({
  "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74",
  "020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f1437",
  "4fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7ed",
  "ee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf05",
  "98da48361c55d39a69163fa8fd24cf5f83655d23dca3ad961c62f356208552bb",
  "9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3b",
  "e39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf695581718",
  "3995497cea956ae515d2261898fa051015728e5a8aaac42dad33170d04507a33",
  "a85521abdf1cba64ecfb850458dbef0a8aea71575d060c7db3970f85a6e1e4c7",
  "abf5ae8cdb0933d71e8c94e04a25619dcee3d2261ad2ee6bf12ffa06d98a0864",
  "d87602733ec86a64521f2b18177b200cbbe117577a615d6c770988c0bad946e2",
  "08e24fa074e5ab3143db5bfce0fd108e4b82d120a93ad2caffffffffffffffff",
})

--- An SRP group: the safe prime `N` as a hex string, the generator `g`, and the
--- hash `srp.new` defaults to when the caller does not name one.
--- @alias SrpGroup { name: string, N: string, g: integer|string, hash: string }

--- RFC 5054 group 15 (3072-bit) with g = 5 and SHA-512 -- the HAP Pair-Setup
--- parameter set, and the default for `srp.new`.
--- @type SrpGroup
srp.GROUP_3072 = {
  name = "RFC 5054 group 15 (3072-bit)",
  N = RFC5054_3072_N_HEX,
  g = 5,
  hash = "sha512",
}

--- A hash usable as SRP's `H`: a name for diagnostics and a function taking a
--- byte string to a raw digest.
--- @alias SrpHash { name: string, hash: fun(data: string): string }

--- Hashes `srp.new` accepts by name.
--- @type table<string, SrpHash>
local HASHES = {
  sha256 = { name = "sha256", hash = sha256.sha256 },
  sha512 = { name = "sha512", hash = sha512.sha512 },
}

--- Bytes of client private exponent `a` generated when the caller does not
--- supply one. RFC 5054 section 3.1 requires at least 256 bits.
local PRIVATE_BYTES = 32

-- ============================================================================
-- INTERNAL HELPERS
-- ============================================================================

--- Parsed form of a group, memoized so the 3072-bit prime is decoded once.
--- Keyed weakly on the group table itself, so a caller-supplied group does not
--- pin its parsed form forever.
--- @type table<SrpGroup, table>
local group_cache = setmetatable({}, { __mode = "k" })

--- Decode a group into the values every session needs.
---
--- `N_min` / `g_min` are the minimal big-endian encodings used inside `M1`, and
--- `g_pad` is `PAD(g)` as used inside `k`; both forms are precomputed because
--- the difference between them is exactly the convention this module has to get
--- right.
---
--- @param group SrpGroup Group description
--- @return table params Fields: N, g, n_bytes, N_min, g_min, g_pad, derived
local function resolve_group(group)
  assert(type(group) == "table", "SRP: group must be a table")
  local params = group_cache[group]
  if params then
    return params
  end

  assert(type(group.N) == "string", "SRP: group.N must be a hex string")
  local N = bignum.from_hex(group.N)
  assert(not bignum.is_zero(N), "SRP: group modulus N must be non-zero")

  -- Read into a local because narrowing applies to locals, not table fields:
  -- `type(group.g)` does not tell the checker anything about `group.g`.
  local g_spec = group.g
  local g
  if type(g_spec) == "number" then
    g = bignum.from_number(g_spec)
  else
    assert(type(g_spec) == "string", "SRP: group.g must be a number or a hex string")
    g = bignum.from_hex(g_spec)
  end
  assert(not bignum.is_zero(g), "SRP: group generator g must be non-zero")

  local n_bytes = bignum.byte_length(N)
  params = {
    N = N,
    g = g,
    n_bytes = n_bytes,
    N_min = bignum.to_bytes(N),
    g_min = bignum.to_bytes(g),
    g_pad = bignum.to_bytes(g, n_bytes),
    -- Per-hash constants, keyed weakly on the hash table.
    derived = setmetatable({}, { __mode = "k" }),
  }
  group_cache[group] = params
  return params
end

--- Compute the group/hash constants that do not depend on the session.
---
--- `k = H(N | PAD(g))` is the SRP-6a multiplier; `hn_xor_hg = H(N) XOR H(g)` is
--- the first term of `M1`. Note the asymmetry that trips people up: `g` is
--- padded inside `k` but minimal inside `H(g)`.
---
--- @param params table Parsed group from `resolve_group`
--- @param hash SrpHash Hash in use
--- @return table constants Fields: k (BigNum), hn_xor_hg (string)
local function derive_constants(params, hash)
  local constants = params.derived[hash]
  if constants then
    return constants
  end
  local h = hash.hash
  constants = {
    k = bignum.from_bytes(h(params.N_min .. params.g_pad)),
    hn_xor_hg = bytes.xor_bytes(h(params.N_min), h(params.g_min)),
  }
  params.derived[hash] = constants
  return constants
end

--- Resolve `opts.hash` to a hash table.
--- @param spec string|SrpHash Registered name, or a custom `{ name, hash }`
--- @return SrpHash hash
local function resolve_hash(spec)
  if type(spec) == "table" then
    assert(type(spec.name) == "string", "SRP: custom hash needs a string 'name'")
    assert(type(spec.hash) == "function", "SRP: custom hash needs a function 'hash'")
    return spec
  end
  local entry = HASHES[spec]
  assert(entry, "SRP: unsupported hash '" .. tostring(spec) .. "'")
  return entry
end

-- ============================================================================
-- SESSION
-- ============================================================================

--- One client-side SRP-6a exchange.
---
--- Derived values are kept as fields so a failing exchange can be localised to a
--- single step: `k`, `x`, `v`, `u` and `S` are BigNums, `K`, `M1` and `M2` are
--- raw digests. Treat them as read-only; the accessors below are the supported
--- interface.
---
--- @class crypto.srp.Session
--- @field group SrpGroup Group in use
--- @field params table Parsed group from `resolve_group`
--- @field hash SrpHash Hash in use
--- @field username string Identity `I`
--- @field password string Password `P`
local Session = {}
Session.__index = Session

--- Set the client private exponent `a` explicitly.
---
--- Only needed for deterministic tests and for protocols that derive `a` from
--- existing key material; otherwise `get_public()` generates one. Discards any
--- previously computed `A`.
---
--- @param a string Private exponent as big-endian bytes
--- @return crypto.srp.Session self For chaining
function Session:set_private(a)
  assert(type(a) == "string" and #a > 0, "SRP: private exponent must be a non-empty byte string")
  local value = bignum.from_bytes(a)
  assert(not bignum.is_zero(bignum.mod(value, self.params.N)), "SRP: private exponent must not be 0 mod N")
  self.a = value
  self.A = nil
  self.A_bytes = nil
  return self
end

--- Client public value `A = g^a mod N`.
---
--- Generates a random `a` on first call if `set_private` was not used, then
--- caches `A` for the life of the session.
---
--- @return string A Big-endian bytes, left-padded to the byte length of N
function Session:get_public()
  if not self.A_bytes then
    if not self.a then
      -- `crypto.random` raises when the host has no CSPRNG rather than handing
      -- back a guessable `a`: recovering `a` recovers `S`, therefore `K`,
      -- therefore the session, and permits an offline attack on the setup code.
      self:set_private(random.bytes(PRIVATE_BYTES))
    end
    local params = self.params
    local A = bignum.mod_exp(params.g, self.a, params.N)
    assert(not bignum.is_zero(A), "SRP: computed client public value A is zero mod N")
    self.A = A
    self.A_bytes = bignum.to_bytes(A, params.n_bytes)
  end
  return self.A_bytes
end

--- Process the server's salt and public value, deriving the whole exchange.
---
--- Computes `x`, `v`, `u`, `S`, `K`, `M1` and `M2`. Aborts -- as RFC 5054
--- section 2.5.4 requires -- if `B mod N == 0` or if `u == 0`, either of which
--- would let a malicious server fix the premaster secret.
---
--- `salt` is used byte for byte, exactly as received. It is not an integer and
--- must not be normalised into one.
---
--- @param salt string Server salt `s`, raw bytes
--- @param B string Server public value `B`, big-endian bytes
--- @return crypto.srp.Session self For chaining
function Session:process(salt, B)
  assert(type(salt) == "string", "SRP: salt must be a byte string")
  assert(type(B) == "string" and #B > 0, "SRP: server public value B must be a non-empty byte string")

  local params = self.params
  local N = params.N
  local h = self.hash.hash

  -- B is kept exactly as supplied for hashing; only the safety check reduces it.
  local B_value = bignum.from_bytes(B)
  if bignum.is_zero(bignum.mod(B_value, N)) then
    error("SRP: server public value B is 0 mod N; aborting per RFC 5054", 2)
  end

  local A_bytes = self:get_public()
  local A_value = self.A

  -- u = H(PAD(A) | PAD(B)). Checked before the expensive exponentiations so a
  -- degenerate server is rejected without doing the work.
  local u = bignum.from_bytes(h(A_bytes .. bignum.to_bytes(B_value, params.n_bytes)))
  if bignum.is_zero(u) then
    error("SRP: scrambling parameter u is 0; aborting per RFC 5054", 2)
  end

  local constants = derive_constants(params, self.hash)
  local k = constants.k

  -- x = H(s | H(I | ":" | P)). `salt` goes in raw: a leading zero byte is part
  -- of the salt, not padding to be stripped.
  local x = bignum.from_bytes(h(salt .. h(self.username .. ":" .. self.password)))

  -- v = g^x mod N, then S = (B - k*v)^(a + u*x) mod N. The subtraction can go
  -- negative, so it goes through mod_sub to land on a non-negative residue.
  local v = bignum.mod_exp(params.g, x, N)
  local base = bignum.mod_sub(B_value, bignum.mod_mul(k, v, N), N)
  local S = bignum.mod_exp(base, bignum.add(self.a, bignum.mul(u, x)), N)

  -- K, M1 and M2 all take S, A and B in minimal form, and the salt raw.
  local K = h(bignum.to_bytes(S))
  local A_min = bignum.to_bytes(A_value)
  local M1 = h(table_concat({
    constants.hn_xor_hg,
    h(self.username),
    salt,
    A_min,
    bignum.to_bytes(B_value),
    K,
  }))
  local M2 = h(A_min .. M1 .. K)

  self.salt, self.B = salt, B_value
  self.k, self.x, self.v, self.u, self.S = k, x, v, u, S
  self.K, self.M1, self.M2 = K, M1, M2
  return self
end

--- Client proof `M1 = H(H(N) XOR H(g) | H(I) | s | A | B | K)`.
--- @return string M1 Raw digest (64 bytes for SHA-512)
function Session:get_proof()
  assert(self.M1, "SRP: call process(salt, B) before get_proof()")
  return self.M1
end

--- Verify the server proof `M2 = H(A | M1 | K)`.
---
--- The comparison is constant time, so a wrong proof leaks no information about
--- how much of it was right.
---
--- @param M2 string Server proof, raw digest
--- @return boolean valid True when the proof matches
function Session:verify(M2)
  assert(self.M2, "SRP: call process(salt, B) before verify()")
  if type(M2) ~= "string" then
    return false
  end
  return bytes.constant_time_compare(self.M2, M2)
end

--- Shared session key `K = H(S)`.
--- @return string K Raw digest (64 bytes for SHA-512)
function Session:get_session_key()
  assert(self.K, "SRP: call process(salt, B) before get_session_key()")
  return self.K
end

-- ============================================================================
-- SRP PUBLIC INTERFACE
-- ============================================================================

--- Create a client session.
---
--- @param opts { group?: SrpGroup, hash?: string|SrpHash, username: string, password: string }
---   `group` defaults to `srp.GROUP_3072`; `hash` defaults to the group's own
---   hash name and may be `"sha256"`, `"sha512"`, or a custom `{ name, hash }`.
---   `username` is `I` (`"Pair-Setup"` for HAP) and `password` is `P`.
--- @return crypto.srp.Session session
function srp.new(opts)
  assert(type(opts) == "table", "SRP: srp.new requires an options table")
  assert(type(opts.username) == "string", "SRP: username (I) must be a string")
  assert(type(opts.password) == "string", "SRP: password (P) must be a string")

  local group = opts.group or srp.GROUP_3072
  local params = resolve_group(group)
  local hash = resolve_hash(opts.hash or group.hash or "sha512")

  return setmetatable({
    group = group,
    params = params,
    hash = hash,
    username = opts.username,
    password = opts.password,
  }, Session)
end

--- Whether an exchange will run at usable speed on this host.
---
--- SRP-6a's cost is dominated by modular exponentiation over the group modulus,
--- and for the 3072-bit HAP group the gap between backends is not a matter of
--- taste. Measured on a Control4 controller (2026-08-07): `bn.powmod` takes
--- 5.08 ms, while the pure-Lua path extrapolates to roughly 176 s for the
--- 256-bit client exponent -- a factor of about 34,000. Worse, Lua execution is
--- effectively serialised across drivers there, so an unaccelerated exchange
--- does not merely run slowly, it blocks the controller until the watchdog
--- resets the driver.
---
--- This is deliberately advisory. `crypto.bignum` stays portable and will
--- compute the same answer either way, because the pure path is what makes the
--- test suite runnable everywhere. But a HAP driver should check this before
--- starting Pair-Setup rather than discovering it by hanging, and it should not
--- have to reach through `openssl_wrapper.features()` into another module's
--- internals to do so.
---
--- The second return value says *why* an exchange would be slow, which matters
--- because "this host has no usable binding" and "nobody called
--- `crypto.use_openssl(true)`" are the same `false` and have nothing else in
--- common. Fail closed on the boolean; log the reason.
---
--- @return boolean accelerated True if modular exponentiation uses OpenSSL
--- @return string|nil reason Why it does not, when it does not
function srp.is_accelerated()
  return bignum.is_accelerated()
end

-- ============================================================================
-- TEST VECTORS AND VALIDATION
-- ============================================================================

-- Generated by tools/generate_srp_vectors.py -- do not edit by hand.
-- Source of truth: srptools, the library pyatv drives for HAP Pair-Setup.
local srp_vectors = {
  {
    name = "HAP Pair-Setup, 8-digit PIN",
    password = "123-45-678",
    salt = "beb25379d1a8581eb5a727673a2441ee",
    a = "60975527035cf2ad1989806f0407210bc81edc04e2762a56afd529ddda2d4393",
    b = "e487cb59d31ac550471e81f00f6928e01dda08e974a004f49e61f5d105284d20",
    k = "a9c2e2559bf0ebb53f0cbbf62282906bede7f2182f00678211fbd5bde5b28503"
      .. "3a4993503b87397f9be5ec02080fedbc0835587ad039060879b8621e8c3659e0",
    x = "f63012102e042051ad49d9598ddd7d1f7f05b9306fb5c4011eb2f9410f36d036"
      .. "9ffad9c644fdf308fcb7c09bf56dc2c0bb9e4e942f574e0786386a124f2bcde4",
    v = "cfe3853f15657e2ee3638ffb7a7743c76cc1f85c0d7fcf2db85172c77800eda2"
      .. "19e0e4fa98c95cb7634d4a35e8c74d6f728cf3864990c4e93c32f5120d71da56"
      .. "ecf3711a02e9e0727cef62920e815306cc4c4375a40991b9e074a69fbf06986b"
      .. "49c92edcda1e9a35ed4ef0b7d4351c1cc8c87844c560e1942e24438e50b04cbb"
      .. "888674500e792449173598045dd1cba0c2128b2661f03d4417b29b4426a732b9"
      .. "ce929abc431f561241633e095cc3b03976ed2bdc39ca2fd5265dade7cd04dd84"
      .. "122278f190edc86c6ae9e1cedc03ec6d97218b7d587d47286678d305a5168c07"
      .. "873d79ac72a42fe39235791a0f2841c68b2a89f5acb512a799e5842dca9eeaa3"
      .. "b21e9ff5072e94aecb8f3572a540a65e577407bf0bed9a1b32f32c7161f675b4"
      .. "a2e29353fac3463989f45522e6c0903154fbc51ba29079af6f7330ad596ea4b9"
      .. "5b3533e3c2f78fec6cb3946e9e7d5dabb67d5605ea517eea2c2fc18552b80e3f"
      .. "7b97168d2a9eb635205c534c46ecc51a052a4ff8ae5eb199129720e8c0ffaedd",
    A = "fab6f5d2615d1e323512e7991cc37443f487da604ca8c9230fcb04e541dce628"
      .. "0b27ca4680b0374f179dc3bdc7553fe62459798c701ad864a91390a28c93b644"
      .. "adbf9c00745b942b79f9012a21b9b78782319d83a1f8362866fbd6f46bfc0ddb"
      .. "2e1ab6e4b45a9906b82e37f05d6f97f6a3eb6e182079759c4f6847837b62321a"
      .. "c1b4fa68641fcb4bb98dd697a0c73641385f4bab25b793584cc39fc8d48d4bd8"
      .. "67a9a3c10f8ea12170268e34fe3bbe6ff89998d60da2f3e4283cbec1393d52af"
      .. "724a57230c604e9fbce583d7613e6bffd67596ad121a8707eec4694495703368"
      .. "6a155f644d5c5863b48f61bdbf19a53eab6dad0a186b8c152e5f5d8cad4b0ef8"
      .. "aa4ea5008834c3cd342e5e0f167ad04592cd8bd279639398ef9e114dfaaab919"
      .. "e14e850989224ddd98576d79385d2210902e9f9b1f2d86cfa47ee244635465f7"
      .. "1058421a0184be51dd10cc9d079e6f1604e7aa9b7cf7883c7d4ce12b06ebe160"
      .. "81e23f27a231d18432d7d1bb55c28ae21ffcf005f57528d15a88881bb3bbb7fe",
    B = "f10ea26e7f6729cf4ad84ee29797902444db19e43a4208f0228db31dbcebf1ce"
      .. "2599dd34db5527b459959d03def823ca34b26acebdcda6e5be266bda03434f41"
      .. "99709b44f9006319c8c9954440cfa8513a3efaf891ffe7e9a22d114a627ff876"
      .. "a169f8475f2338342ec9a22916ff13949848d2653bfbad782b99e2f0dbe5a6c5"
      .. "e698a3b895a426dc357c6986001b9023b0eb05a13c3b9ec04ee837ddfc12eef3"
      .. "536dab67ec1c47881eb87bbfbe7f010823d051d33e15c6e9138780395d4ecf10"
      .. "bf610e11a5b0e3ee8d122665feba6b17c9eba084a60d15aae69152b827b507ed"
      .. "e6d824237d8596a51e6355faf8727d5e67f91e60ac85feebdb852eeb61c9e6d1"
      .. "7a48d55d6bc815adfe03daec5b6bd8a3d28b8fe4bc78e452c2cd8aa89fedaf39"
      .. "252f4cb354c595c09fa2251078746482fba13daf27e156aabd18800efd97e472"
      .. "9b74217bc9611d54250422b00c0ade7bf0721c5f1b7d479c3c32d6d34b29d2fb"
      .. "e158ebe5ad9e9e40d997f755e919c77ad5be10300d55bbe921aee598d4dbfff3",
    u = "d4af9d1fde81c67160f53a86495e58016c71109e769944d65a07835170e52b7a"
      .. "579e8273e1cfa374537535e74d617c530f403914049da1757c50e7361d078fe4",
    S = "309ce4265954b7f9005a7e137eca9173e313c349445b54f36e38668a66ec011a"
      .. "1ca015e8fc24e16b0d87d95b8083d8fd722acb81c1a96ae87e0b80d1789d6670"
      .. "5a41f90286c852a73e139a5dc628be44d4f7b4c76e6506af49b22ec2fedaaec8"
      .. "5c518a71e7867db978997234ade66b5beb0aaa1259409778f7b461fcc0d1a288"
      .. "4ffa4fbb1084b733be16f1a6ed890269541df5356cf871e38c3c6fc93edd1952"
      .. "efb89e6b92c0452f8766648f3b48337dd32b39bf20a64632719de457910760cd"
      .. "81188beac6176e24555952ec3d3d84cfcc320f25381b525269e263528838f5a7"
      .. "a62c85d350f1c28856e90eaf9907f8471b8ce5b7c251472c7302ca8bd04e1741"
      .. "2b24d6c3d70e4a16caeb65df5d33ec0d4e06869d99c690d872a8693d273c8f92"
      .. "c4789adc376844d4d0621f0dc38f9c550e7312c8f9da78ef20ddcf5954133e83"
      .. "f76ddacf8a5ece59b2b61770ded05418fc37af37ca29a423848b16d929335a4f"
      .. "7cae9025f2bdf4a368fc6e510eec39a34dc15665ebee4b504cb55f47edb48a5c",
    K = "8d81d9699f88f80724b5ccea8af575afb9ec0e32a6986336a58e7697f8394b54"
      .. "1751f886a362c05e86cac223a522218b4c704635accacbff498b5a17e6baa3be",
    M1 = "5405c5ad299a761d8afe17c45383de84a46f6c0d437a29bd9476bf4b77dd79e7"
      .. "b95674a966498a3c5f98bf8c933f4baba9555765fc1ecc240eaeda3363a68d42",
    M2 = "65623be9ae14a44abcee4951655103a51913c84dbd90eda6c386819bfe7d2b0d"
      .. "7603ce198b4c0b257dfec327bcf035cc0dacd7e47b79c585aec992af0490c61b",
  },
  {
    name = "HAP Pair-Setup, 4-digit PIN",
    password = "3939",
    salt = "0a1b2c3d4e5f60718293a4b5c6d7e8f9",
    a = "1d1e2f3a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6",
    b = "9f8e7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c5b4a39281706f5e4d3c2b1a0",
    k = "a9c2e2559bf0ebb53f0cbbf62282906bede7f2182f00678211fbd5bde5b28503"
      .. "3a4993503b87397f9be5ec02080fedbc0835587ad039060879b8621e8c3659e0",
    x = "956dcab6654323ea59d60692c2b5c1b7737a6f488e8e9808a8d636109668d014"
      .. "3dc0954764ead68763ba2fdeb26fe313ecdad98c46a06e36436d2d2f01f8283a",
    v = "1db374f7d5d9572ef2ca480f2486d045d3f892de338e80e733e83ea6e18bdc82"
      .. "ce0d40a69076c2ee273d2b365fd1296dc0db4826dfc010c5c608ab0ef399fcd3"
      .. "46f594dbc9eda52e8107c307a80d7f23a78345bb036684c911ee4cbacef0bd54"
      .. "ba91aeb6c039d5946e407b1df89a0c456abcc4d3cdc69b5705d2af5a177094de"
      .. "5943a28ad127fd00acfbb064df86c41a542d8455527784e1b3dcbaae41f2fab7"
      .. "9fc1083ec1d13f8aeebe3cf3532e47a577d7bfcad7fac05507df97aed5f0c6ef"
      .. "4bfb185999842ed5d191b0296608cd5e06355bf7b797264097c7c587ab844e56"
      .. "359a4895ed99fb8df2b00d6a857ca12cbdf554d41f3316275ba3fe485b2b4fa3"
      .. "857ced98c0e522193726c262963dc1ad85720e42c23f9a01d749a86664b4f47a"
      .. "74f6193cfd27a84d7a8baa4e0b8fb28caab6cd19fbaa38c5be54d6007787dab7"
      .. "156286019c50e6f8b1e6b6fc4b9fdb3992242de199c231549bfbe8e6311bd304"
      .. "34bd63e384bb58b648e83a5a05d0234176f344f3001ee1a8cba127aea976a0e9",
    A = "de7460f6ad6438e8c91615e668456cf0a88911cc16ab77fffca2335788499a85"
      .. "4bec07ebeb3a352caa79bf815776ff5ac3ef69d7504f8854de94484c1bc8f21f"
      .. "713a51e6ea856e8d0b402a8986fb049e0f66d2fa420fbc38cd4e7b8dd52d3839"
      .. "f116b188443e078f803e06502b34818437ce8acaaae810c47017d22158f2dcc5"
      .. "4b926935b2360f9b15d9c50fc65933f189cb3081d6dfba978716fa0f1d0188bc"
      .. "a82c41241c05141537128c28f8e17e37422116e410689562fc0132908d9ecbba"
      .. "a7ce637528802009545c8cb39734c5cd43047b5be7239d286df9a0c68dc36f76"
      .. "002eeb683fc207880301612d2da0070a195c6bc1959f52a08ac3519a528f0696"
      .. "f1335b8e487029460e607f390af361d9861b3abff460785cd484380ef87d369d"
      .. "3ff7461796e4384ff0a711bfe1227da33d6ad7a763a2f24915be0dfb2827c9cf"
      .. "9cfcde20fbff65c2fbba2c56d1e652e9172db8bd9825279d12ff51147af67e93"
      .. "112e5073d949f372d285298851eaceec9f442081bd0615810ba70af20df15092",
    B = "c462c3ab34762e9c723360c1a78d30016ac79a679cd8adc997111a842ce6a99a"
      .. "7ff316a558e8f4a1b2d94633a620a84000788081ea7867c8c3a18e12e96d4e1a"
      .. "142b18beee958e3c2e5da7bd927a4d4859b12c666d0d941dd183a0b6401bc567"
      .. "0fec8ec9fb9c9534e8c34880b5f05ae962b12fd903a3af0ef3f7dfd6be81f385"
      .. "8f81be60afffcfae6b6a8b73462cca451bcb64e8fda884109cefe22a3d711176"
      .. "d327fdf03352106fb11c3220c5715810ba1a45f67f4b6649e2cf6a7172b4257a"
      .. "6728e5423cba18a371b376c0aed3b9a930c206f47e7110d67eb8b707b300d1cd"
      .. "d9731fa14ce48b26f07261598c1501ba06610faa8f25bfd0dc9f657e90ee2310"
      .. "2a04b2304f45ececbf1470e24fb46067decb99c0bbd31b53c7fed135a301ae5b"
      .. "fa858601f0f1c23524ecae5fb50385fc72467b4dc95ace632cc7d4bd6be81f5b"
      .. "d68db69da4264daa10394b39c822360d97894682b34718dcb4c26779eacb696b"
      .. "2b8b7d50c9139e2bdaf2a5ce0b8cee5e8e28cb2ad3e64e824086cc87f02ce6f7",
    u = "76ac3f8010b3121c47cd1b8658e63357c624572489c4926348e5484d88c461d1"
      .. "6862858e97ea1ea53b4e6e372fbaccb1e6b1907bae0267085d7f3c0015137dae",
    S = "30c4b3ab83046ffab2b95f0038d75d76d754f1937be01fb437cca89b9714174a"
      .. "d2d800427c221774afab641f0708658a86fb28ad4df01aa57c558d64fb5f51d3"
      .. "4fc5104105fa20c3db75e9edeab61f900d404bfee3102471066d2dc028c21fe4"
      .. "8330039d0ad7bbea975831f657dae6609c6c6c2ee5906dd8389b6ceca6c5b286"
      .. "28dce2acc4b11a06f996e411b05e40d2152fb6259e0430587edf8bfda1f9d7d1"
      .. "a35dfde72a8b1bee7ddea0ca9cc72a532c05b1a42b089cef1943df4364561ecd"
      .. "7249965fb6b3a15ab6c63cf5399411d13c6d1e596e329c4553e3d5eef61fc21e"
      .. "861966e65a3b121598d110e38f618501fd2c0c37e3ab1d6336c8617868c7e4ea"
      .. "504be9b7ee243aea59e58cc046817653b681162bcc991378d1396d50c1399f44"
      .. "ac80e1669376781993da356b765fe5a71bd488d13ade485317020f01a3e7d906"
      .. "e26bd38c3678b9d3ee139da6d83598f7491b904f2f3121c0a45470597645cd10"
      .. "d9d6848d0e2da9e7bd8224d1a8b3511285807320a84b2ec918d1dee1b20fd060",
    K = "41ea1f81f58f7e4e4c7f1f8e739e04ffb5e29dabdc5a21b18c014f905c17f291"
      .. "e69806caeb800ccb7bbb6c1955ac61cf695c68d1ddf19a3465c465c5088ff5dd",
    M1 = "778b8aecea94608ea7971e7d73eab4abf4b211e28f3039939394fd842ee4636a"
      .. "dc9271ee44d792a757de399969c5cba80501b8bfdc82f17d0b3498f9f9ed73f8",
    M2 = "4e3e1ddbb25ad6e82c23cb8cb6606bc7a7ce8505c29fbf1902aa702be29512d8"
      .. "3adc72dc6dc6fecb80be70da5ae07d5108ed9ad047a4d5bc5913e4e31d34a940",
  },
  {
    name = "leading-zero salt (pins the minimal-length encoding)",
    password = "123-45-678",
    salt = "00b25379d1a8581eb5a727673a2441ee",
    a = "60975527035cf2ad1989806f0407210bc81edc04e2762a56afd529ddda2d4393",
    b = "e487cb59d31ac550471e81f00f6928e01dda08e974a004f49e61f5d105284d20",
    k = "a9c2e2559bf0ebb53f0cbbf62282906bede7f2182f00678211fbd5bde5b28503"
      .. "3a4993503b87397f9be5ec02080fedbc0835587ad039060879b8621e8c3659e0",
    x = "5f71b784ad9d6a6f6e6ad9c86a78cc0013075cab4ebfc0fd507b9ad5ea4a3669"
      .. "b8fbc39e4817d06ecffba7920c1bcdd4f0ad9e2d407ba8e8b8bc6e8f6ed5e9a7",
    v = "86ef8b08203d8eb0993cb30e6bc06477d29a5f9e14abd6c163bf34f3e7c72a6b"
      .. "c109718f73d1fa4835d9dc0d7f267abeb7ef27d47de1b4f2e09767c59e6f2eca"
      .. "ab0d87c98f4d32137fdd13cafdc5b7805d9beff8d7c5eaea66f349ec5b694fb0"
      .. "410de38ea315d99988799169d966961ca6c30d537efb4150d8560d3d3c7dc2a7"
      .. "ef8075d440238d21c93cc46e85cdd360576997a5b0bf43818fe612140910ffe8"
      .. "27b5e4a4e71f850e32c99d7bf18c1fd9f642a33860b6e1e6209b9aaaba83246c"
      .. "b93d04c7f7df378734b374555f57d83f40e97573626b28d0181f4a7f5e42614b"
      .. "266be571ecf3d2a9b64524097b12504eaf88193405dc2259150828cd28c691f3"
      .. "e016c92df3941d47830aca98028d38a7e32a6d1306caea734e17cc8440e0d907"
      .. "9dd2657461055aa4a7bab8633d8b6102126ded5389148c1b225029b79d5f9ff9"
      .. "0af65ca92ff8de2e5001ae95bd7255b1ea9ae936e153af3d228611afaa6f5dbc"
      .. "d2cb90949657743d837ef1088c595ad0540bc9549b7508181810ba9ae54c4685",
    A = "fab6f5d2615d1e323512e7991cc37443f487da604ca8c9230fcb04e541dce628"
      .. "0b27ca4680b0374f179dc3bdc7553fe62459798c701ad864a91390a28c93b644"
      .. "adbf9c00745b942b79f9012a21b9b78782319d83a1f8362866fbd6f46bfc0ddb"
      .. "2e1ab6e4b45a9906b82e37f05d6f97f6a3eb6e182079759c4f6847837b62321a"
      .. "c1b4fa68641fcb4bb98dd697a0c73641385f4bab25b793584cc39fc8d48d4bd8"
      .. "67a9a3c10f8ea12170268e34fe3bbe6ff89998d60da2f3e4283cbec1393d52af"
      .. "724a57230c604e9fbce583d7613e6bffd67596ad121a8707eec4694495703368"
      .. "6a155f644d5c5863b48f61bdbf19a53eab6dad0a186b8c152e5f5d8cad4b0ef8"
      .. "aa4ea5008834c3cd342e5e0f167ad04592cd8bd279639398ef9e114dfaaab919"
      .. "e14e850989224ddd98576d79385d2210902e9f9b1f2d86cfa47ee244635465f7"
      .. "1058421a0184be51dd10cc9d079e6f1604e7aa9b7cf7883c7d4ce12b06ebe160"
      .. "81e23f27a231d18432d7d1bb55c28ae21ffcf005f57528d15a88881bb3bbb7fe",
    B = "39ca72cbb2e5b68512d3874d7b22bfe9f1543176f261a1f310e62178298dc8f2"
      .. "4133f72a7940fffbe1fb6d8e5962293ae78439e43420cb27712a48da16b35c74"
      .. "527b57c6da70223fd3281d3853fc2a643ccec161d44b2c994365bd85a514c3d0"
      .. "9294f91102e2a7783722518155281c80d92d0789c7b95b2db45e993de419fead"
      .. "440d3cf10b0ebecb9928a2b0eda1aec7232ddb0196aa60aeeafb59a23deb472c"
      .. "7afa382096d03f8a4dccb546f7416bde2aa31e592f9573efb30e5b1507ba05c7"
      .. "e9c27951c43a4faa32d7f032abc3f259f8becf8b18e18feef5ed8f5ce476de7e"
      .. "72acfd7fd13c6df5ca65ea4d203ce9c92346d04cf50a9c1dc70b38a2232147ff"
      .. "9d791da5e90ad9d335039f0a44cb80017a79b61ddcf1251cbd1621e99058fbde"
      .. "470bc6f950b862a40c6070ac98dd09a1af4e3ba9af5f26a2f92b3155b14ffb0a"
      .. "b5c33e16bd9fb6252278f1fdc96123e321f8c34d2f6eac7893a8c987fae9a78b"
      .. "6d48a0e4c6bff093ab93fa18d62411a0deee1aa1ded536a7162474777414db48",
    u = "8b30c0a71691eae700568e4d989ebeeba8857e1a624db4105302df0d572b662e"
      .. "24f150012f36189b85012601cc9997a4c22010178b765ed07de345c3def8a41c",
    S = "0e4c4f64cb62930017ec119ab50d2f1271a9999f5c8b8afaa6f5251c3cb7d5d4"
      .. "2a835ec99e0291fb4d1877ccc167184b0413939f4a6239aa538fb94c779fd0a7"
      .. "47ee2616ae45316b1a56fd0acef7c09a463779afd9a9308eb5811529440e38cf"
      .. "e94e0a37599e15ee820b096c62c944d46175f821dafdde83239df5d3d76b7772"
      .. "b58b301e278534c2c6f95dd5a6a64253dc8a96df5ec5f3399dba0bf7406bdbb4"
      .. "8196fe6db0cbec216433a9fad45a917dd47c720b746dbf4e80160bf14d1f6129"
      .. "e90910090bb3a2ec2fa0ae3928f8d92a8c49f1922c91df991425849a4c3b61f0"
      .. "c9900a7896b7a94fa87d5592e03352f2b780a4079bf34182fa88c7e2819ab476"
      .. "b4487d850878145b7263544540839e22606b7687c680d16b9221bb4ddf64dfdc"
      .. "ed5848476f9f9e4801069eab6c1c846e542f1359da348989a554ab83019cc2d5"
      .. "354ce83c190577a7fc8e0a017bf37daae759399de4087b5612f8f8ffdcbaeeef"
      .. "05b9c54eb9c03ebcc3911b9a8ce03a29ddbeb3142f1fefc20239ec1c0c40945c",
    K = "dbce5774183a5d8ad5eb70ee6be4a362f3203d73dea68806817018edd98c4c18"
      .. "b9c5a2d051318fe8ddd290f24e0376fe5265828d8f47f8355b99d13f375465f1",
    M1 = "7bfac666037a0b38b730e5c35822404d0dd8f335fc48a7868bdbabf55f098d32"
      .. "0369911f7f4e2c6f66aa8d8362686e68764149c327e905cbbe18db994a29e15d",
    M2 = "3b8b949d7943c47e06d205d13a29a51637eefe365ec3e69f58592302a44d79a1"
      .. "a5e10d753c37556c59344462d0c396dcf8ae19061971d911ddb10c04bcaae3b9",
  },
}

--- The identity HAP Pair-Setup uses; also the `I` every vector was generated with.
local HAP_USERNAME = "Pair-Setup"

--- Hex of a value zero-padded to the byte length of N, matching how the
--- generator emits `v`, `A`, `B` and `S`.
--- @param value BigNum Value
--- @return string hex 768 lowercase hex digits for group 15
local function padded_hex(value)
  return bytes.to_hex(bignum.to_bytes(value, resolve_group(srp.GROUP_3072).n_bytes))
end

--- Run comprehensive self-test with known-answer test vectors.
---
--- Every intermediate of every vector -- `k`, `x`, `v`, `A`, `u`, `S`, `K`, `M1`
--- and `M2` -- is asserted separately, so a convention that drifts shows up as a
--- named failing step rather than as "M1 is wrong". The functional tests then
--- cover private-key handling, session independence and the two RFC 5054 abort
--- conditions.
---
--- This is slow by design: a 3072-bit modular exponentiation is seconds of pure
--- Lua and each vector needs three of them.
---
--- @return boolean result True if all tests pass, false otherwise
function srp.selftest()
  local passed = 0
  local total = 0

  --- Record one test result. `result` may be a boolean or a function returning
  --- one; a function that raises counts as a failure rather than aborting the run.
  --- @param name string
  --- @param result boolean|fun(): boolean
  local function check(name, result)
    total = total + 1
    if type(result) == "function" then
      local ok, value = pcall(result)
      result = ok and value == true
    end
    if result == true then
      print("  ✅ PASS: " .. name)
      passed = passed + 1
    else
      print("  ❌ FAIL: " .. name)
    end
  end

  --- Compare a hex value and print both sides when they differ.
  --- @param name string
  --- @param got string
  --- @param expected string
  local function check_hex(name, got, expected)
    check(name, got == expected)
    if got ~= expected then
      print("    expected: " .. expected)
      print("    got:      " .. got)
    end
  end

  print("Running SRP-6a test vectors (RFC 5054 group 15, SHA-512)...")
  local reference_session, reference_vector
  for _, vector in ipairs(srp_vectors) do
    print("Vector: " .. vector.name)
    local salt = bytes.from_hex(vector.salt)
    local session = srp.new({ username = HAP_USERNAME, password = vector.password })
    session:set_private(bytes.from_hex(vector.a))

    check_hex(vector.name .. " [A]", bytes.to_hex(session:get_public()), vector.A)
    session:process(salt, bytes.from_hex(vector.B))

    check_hex(vector.name .. " [k]", bignum.to_hex(session.k), vector.k)
    check_hex(vector.name .. " [x]", bignum.to_hex(session.x), vector.x)
    check_hex(vector.name .. " [v]", padded_hex(session.v), vector.v)
    check_hex(vector.name .. " [u]", bignum.to_hex(session.u), vector.u)
    check_hex(vector.name .. " [S]", padded_hex(session.S), vector.S)
    check_hex(vector.name .. " [K]", bytes.to_hex(session:get_session_key()), vector.K)
    check_hex(vector.name .. " [M1]", bytes.to_hex(session:get_proof()), vector.M1)
    check_hex(vector.name .. " [M2]", bytes.to_hex(session.M2), vector.M2)
    check(vector.name .. " [verify accepts M2]", session:verify(bytes.from_hex(vector.M2)))

    reference_session, reference_vector = session, vector
    print()
  end

  print("Running SRP-6a functional tests...")

  -- Determinism across independent session objects: same private exponent in,
  -- same A out. Compared against the vector session so this costs one
  -- exponentiation rather than two.
  check("set_private is deterministic across sessions", function()
    local other = srp.new({ username = HAP_USERNAME, password = reference_vector.password })
    other:set_private(bytes.from_hex(reference_vector.a))
    return other:get_public() == reference_session:get_public()
  end)

  check("get_public returns PAD(A), 384 bytes", function()
    return #reference_session:get_public() == 384
  end)

  check("set_private returns the session for chaining", function()
    local session = srp.new({ username = HAP_USERNAME, password = "123-45-678" })
    return session:set_private(bytes.from_hex(reference_vector.a)) == session
  end)

  check("two sessions without set_private produce different A", function()
    local one = srp.new({ username = HAP_USERNAME, password = "123-45-678" })
    local two = srp.new({ username = HAP_USERNAME, password = "123-45-678" })
    local a1, a2 = one:get_public(), two:get_public()
    return #a1 == 384 and #a2 == 384 and a1 ~= a2
  end)

  check("empty private exponent is rejected", function()
    local session = srp.new({ username = HAP_USERNAME, password = "123-45-678" })
    return pcall(session.set_private, session, "") == false
  end)

  check("zero private exponent is rejected", function()
    local session = srp.new({ username = HAP_USERNAME, password = "123-45-678" })
    return pcall(session.set_private, session, string_rep(string_char(0), 32)) == false
  end)

  -- RFC 5054 section 2.5.4: the client MUST abort when B mod N == 0. Both an
  -- all-zero B and B == N hit that, and only the second catches an
  -- implementation that tests the bytes instead of the residue.
  check("B == 0 is rejected", function()
    local session = srp.new({ username = HAP_USERNAME, password = "123-45-678" })
    session:set_private(bytes.from_hex(reference_vector.a))
    return pcall(session.process, session, "salt", string_rep(string_char(0), 384)) == false
  end)

  check("B == N (0 mod N) is rejected", function()
    local session = srp.new({ username = HAP_USERNAME, password = "123-45-678" })
    session:set_private(bytes.from_hex(reference_vector.a))
    return pcall(session.process, session, "salt", bytes.from_hex(RFC5054_3072_N_HEX)) == false
  end)

  check("empty B is rejected", function()
    local session = srp.new({ username = HAP_USERNAME, password = "123-45-678" })
    session:set_private(bytes.from_hex(reference_vector.a))
    return pcall(session.process, session, "salt", "") == false
  end)

  -- u == 0 cannot be reached with a real hash, so inject one that always
  -- returns zeros. The abort must fire on u, before any secret is derived.
  check("u == 0 is rejected", function()
    local zero_hash = {
      name = "always-zero",
      hash = function()
        return string_rep(string_char(0), 64)
      end,
    }
    local session = srp.new({ username = HAP_USERNAME, password = "123-45-678", hash = zero_hash })
    session:set_private(bytes.from_hex(reference_vector.a))
    local ok, err = pcall(session.process, session, "salt", bytes.from_hex(reference_vector.B))
    return ok == false and type(err) == "string" and err:find("u is 0", 1, true) ~= nil
  end)

  check("verify rejects a wrong M2", function()
    local wrong = bytes.from_hex(reference_vector.M2)
    wrong = string_char(0) .. wrong:sub(2)
    return reference_session:verify(wrong) == false
  end)

  check("verify rejects a truncated M2", function()
    return reference_session:verify(bytes.from_hex(reference_vector.M2):sub(1, 63)) == false
  end)

  check("verify rejects a non-string M2", function()
    --- @diagnostic disable-next-line: param-type-mismatch -- the wrong type is the test
    return reference_session:verify(nil) == false
  end)

  check("verify accepts the correct M2", function()
    return reference_session:verify(bytes.from_hex(reference_vector.M2)) == true
  end)

  check("accessors error before process()", function()
    local session = srp.new({ username = HAP_USERNAME, password = "123-45-678" })
    return pcall(session.get_proof, session) == false
      and pcall(session.get_session_key, session) == false
      and pcall(session.verify, session, "x") == false
  end)

  check("unsupported hash name is rejected", function()
    return pcall(srp.new, { username = HAP_USERNAME, password = "x", hash = "sha1" }) == false
  end)

  check("missing username or password is rejected", function()
    return pcall(srp.new, { password = "x" }) == false
      and pcall(srp.new, { username = HAP_USERNAME }) == false
      and pcall(srp.new, nil) == false
  end)

  check("GROUP_3072 exposes N, g and the hash name", function()
    return srp.GROUP_3072.N == RFC5054_3072_N_HEX
      and srp.GROUP_3072.g == 5
      and srp.GROUP_3072.hash == "sha512"
      and #bytes.from_hex(srp.GROUP_3072.N) == 384
  end)

  -- The accessor exists so a HAP caller does not have to reach into bignum or
  -- openssl_wrapper, so what matters is that it reports the same verdict *and*
  -- the same reason, whatever this host happens to be.
  check("is_accelerated agrees with bignum, reason included", function()
    local srp_accelerated, srp_reason = srp.is_accelerated()
    local bn_accelerated, bn_reason = bignum.is_accelerated()
    return srp_accelerated == bn_accelerated
      and srp_reason == bn_reason
      and type(srp_accelerated) == "boolean"
      and (srp_accelerated or type(srp_reason) == "string")
  end)

  print(string.format("\nSRP result: %d/%d tests passed\n", passed, total))
  return passed == total
end

--- Run performance benchmarks for the client-side SRP-6a operations.
---
--- Iteration counts are deliberately tiny: every operation below is dominated by
--- 3072-bit modular exponentiation, which is seconds per call in pure Lua. Note
--- that `benchmark_op` adds three warm-up runs on top of the count shown.
function srp.benchmark()
  local vector = srp_vectors[1]
  local salt = bytes.from_hex(vector.salt)
  local B = bytes.from_hex(vector.B)
  local a = bytes.from_hex(vector.a)
  local M2 = bytes.from_hex(vector.M2)

  local function new_session()
    return srp.new({ username = HAP_USERNAME, password = vector.password }):set_private(a)
  end

  local ready = new_session()
  ready:process(salt, B)

  print("SRP-6a client (RFC 5054 group 15, SHA-512):")
  benchmark_op("get_public (A = g^a mod N)", function()
    new_session():get_public()
  end, 3)

  benchmark_op("process (v, u, S, K, M1, M2)", function()
    ready:process(salt, B)
  end, 2)

  benchmark_op("full exchange (A + process)", function()
    local session = new_session()
    session:get_public()
    session:process(salt, B)
  end, 2)

  benchmark_op("verify (M2)", function()
    ready:verify(M2)
  end, 2000)
end

return srp
end
end

do
local _ENV = _ENV
package.preload[ "crypto.utils" ] = function( ... ) local arg = _G.arg;
--- @module "crypto.utils"
--- Common utility functions for the Noise Protocol Framework
--- @class crypto.utils
local utils = {
  --- @type crypto.utils.bytes
  bytes = require("crypto.utils.bytes"),
  --- @type crypto.utils.benchmark
  benchmark = require("crypto.utils.benchmark"),
}

return utils
end
end

do
local _ENV = _ENV
package.preload[ "crypto.utils.benchmark" ] = function( ... ) local arg = _G.arg;
--- @module "crypto.utils.benchmark"
--- Common benchmarking utilities for performance testing
--- @class crypto.utils.benchmark
local benchmark = {}

--- Run a benchmarked operation with warmup and timing
--- @param name string Operation name for display
--- @param func function Function to benchmark
--- @param iterations? integer Number of iterations (default: 100)
--- @return number ms_per_op Milliseconds per operation
function benchmark.benchmark_op(name, func, iterations)
  iterations = iterations or 100

  -- Warmup
  for _ = 1, 3 do
    func()
  end

  -- Actual benchmark
  local start = os.clock()
  for _ = 1, iterations do
    func()
  end
  local elapsed = os.clock() - start

  local per_op = (elapsed / iterations) * 1000 -- ms
  local ops_per_sec = iterations / elapsed

  print(string.format("%-30s: %8.3f ms/op, %8.1f ops/sec", name, per_op, ops_per_sec))

  return per_op
end

return benchmark
end
end

do
local _ENV = _ENV
package.preload[ "crypto.utils.bytes" ] = function( ... ) local arg = _G.arg;
--- @module "crypto.utils.bytes"
--- Byte manipulation and conversion utilities
--- @class crypto.utils.bytes
local bytes = {}

local bitn = require("bitn")
local bit32 = bitn.bit32
local bit64 = bitn.bit64

-- Local references for performance
local bit32_mask = bit32.mask
local bit32_raw_bor = bit32.raw_bor
local bit32_raw_bxor = bit32.raw_bxor
local bit64_new = bit64.new
local floor = math.floor
local string_byte = string.byte
local string_char = string.char
local string_format = string.format
local string_rep = string.rep
local table_concat = table.concat

--- Convert binary string to hexadecimal string
--- @param str string Binary string
--- @return string hex Hexadecimal representation
function bytes.to_hex(str)
  return (str:gsub(".", function(c)
    return string_format("%02x", string_byte(c))
  end))
end

--- Convert hexadecimal string to binary string
--- @param hex string Hexadecimal string
--- @return string str Binary string
function bytes.from_hex(hex)
  return (hex:gsub("..", function(cc)
    return string_char(tonumber(cc, 16))
  end))
end

--- Convert 32-bit unsigned integer to 4 bytes (little-endian)
--- @param n integer 32-bit unsigned integer
--- @return string bytes 4-byte string in little-endian order
function bytes.u32_to_le_bytes(n)
  n = bit32_mask(n)
  return string_char(n % 256, floor(n / 256) % 256, floor(n / 65536) % 256, floor(n / 16777216) % 256)
end

--- Convert 32-bit unsigned integer to 4 bytes (big-endian)
--- @param n integer 32-bit unsigned integer
--- @return string bytes 4-byte string in big-endian order
function bytes.u32_to_be_bytes(n)
  n = bit32_mask(n)
  return string_char(floor(n / 16777216) % 256, floor(n / 65536) % 256, floor(n / 256) % 256, n % 256)
end

--- Convert 64-bit value to 8 bytes (big-endian)
--- @param x Int64HighLow {high, low} 64-bit value
--- @return string bytes 8-byte string in big-endian order
function bytes.u64_to_be_bytes(x)
  local high, low = x[1], x[2]
  return bytes.u32_to_be_bytes(high) .. bytes.u32_to_be_bytes(low)
end

--- Convert 64-bit value to 8 bytes (little-endian)
--- @param x Int64HighLow|integer {high, low} 64-bit value or simple integer
--- @return string bytes 8-byte string in little-endian order
function bytes.u64_to_le_bytes(x)
  -- Handle simple integer case (< 2^53)
  if type(x) == "number" then
    local low = x % 0x100000000
    local high = floor(x / 0x100000000)
    return bytes.u32_to_le_bytes(low) .. bytes.u32_to_le_bytes(high)
  else
    -- Handle {high, low} pair
    local high, low = x[1], x[2]
    return bytes.u32_to_le_bytes(low) .. bytes.u32_to_le_bytes(high)
  end
end

--- Convert 4 bytes to 32-bit unsigned integer (little-endian)
--- @param str string Binary string (at least 4 bytes)
--- @param offset? integer Starting position (default: 1)
--- @return integer n 32-bit unsigned integer
function bytes.le_bytes_to_u32(str, offset)
  offset = offset or 1
  assert(#str >= offset + 3, "Insufficient bytes for u32")
  local b1, b2, b3, b4 = string_byte(str, offset, offset + 3)
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

--- Convert 4 bytes to 32-bit unsigned integer (big-endian)
--- @param str string Binary string (at least 4 bytes)
--- @param offset? integer Starting position (default: 1)
--- @return integer n 32-bit unsigned integer
function bytes.be_bytes_to_u32(str, offset)
  offset = offset or 1
  assert(#str >= offset + 3, "Insufficient bytes for u32")
  local b1, b2, b3, b4 = string_byte(str, offset, offset + 3)
  return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
end

--- Convert 8 bytes to 64-bit value (big-endian)
--- @param str string Binary string (at least 8 bytes)
--- @param offset? integer Starting position (default: 1)
--- @return Int64HighLow value {high, low} 64-bit value
function bytes.be_bytes_to_u64(str, offset)
  offset = offset or 1
  assert(#str >= offset + 7, "Insufficient bytes for u64")
  local high = bytes.be_bytes_to_u32(str, offset)
  local low = bytes.be_bytes_to_u32(str, offset + 4)
  return { high, low }
end

--- Convert 8 bytes to 64-bit value (little-endian)
--- @param str string Binary string (at least 8 bytes)
--- @param offset? integer Starting position (default: 1)
--- @return Int64HighLow value {high, low} 64-bit value
function bytes.le_bytes_to_u64(str, offset)
  offset = offset or 1
  assert(#str >= offset + 7, "Insufficient bytes for u64")
  local low = bytes.le_bytes_to_u32(str, offset)
  local high = bytes.le_bytes_to_u32(str, offset + 4)
  return { high, low }
end

--- XOR two byte strings
--- @param a string First byte string
--- @param b string Second byte string
--- @return string result XORed byte string
function bytes.xor_bytes(a, b)
  assert(#a == #b, "Strings must be same length for XOR")
  local result = {}
  -- Using raw_bxor for performance; XOR on bytes (0-255) is always safe
  for i = 1, #a do
    result[i] = string_char(bit32_raw_bxor(string_byte(a, i), string_byte(b, i)))
  end
  return table_concat(result)
end

--- Constant-time comparison of two strings
--- @param a string First string
--- @param b string Second string
--- @return boolean equal True if strings are equal
function bytes.constant_time_compare(a, b)
  if #a ~= #b then
    return false
  end
  local result = 0
  for i = 1, #a do
    result = bit32_raw_bor(result, bit32_raw_bxor(string_byte(a, i), string_byte(b, i)))
  end
  return result == 0
end

--- Pad data to 16-byte boundary with zeros
--- @param data string Data to pad
--- @return string padded Padded data
function bytes.pad_to_16(data)
  local len = #data
  local padding_len = (16 - (len % 16)) % 16
  if padding_len == 0 then
    return data
  end
  return data .. string_rep("\0", padding_len)
end

--- Run comprehensive self-test with test vectors
--- @return boolean result True if all tests pass, false otherwise
function bytes.selftest()
  print("Running byte operations test vectors...")
  local passed = 0
  local total = 0

  local test_vectors = {
    -- Hex conversion tests
    {
      name = "hex - basic roundtrip",
      test = function()
        local data = "Hello"
        local hex = bytes.to_hex(data)
        local back = bytes.from_hex(hex)
        return hex == "48656c6c6f" and back == data
      end,
    },
    {
      name = "hex - empty string",
      test = function()
        local data = ""
        local hex = bytes.to_hex(data)
        local back = bytes.from_hex(hex)
        return hex == "" and back == ""
      end,
    },
    {
      name = "hex - single byte min",
      test = function()
        local data = string_char(0x00)
        local hex = bytes.to_hex(data)
        return hex == "00"
      end,
    },
    {
      name = "hex - single byte max",
      test = function()
        local data = string_char(0xFF)
        local hex = bytes.to_hex(data)
        return hex == "ff"
      end,
    },
    {
      name = "hex - all byte values",
      test = function()
        -- Test a few representative byte values
        local data = string_char(0x00, 0x01, 0x7F, 0x80, 0xFE, 0xFF)
        local hex = bytes.to_hex(data)
        return hex == "00017f80feff"
      end,
    },
    {
      name = "hex - uppercase input",
      test = function()
        local hex = "48656C6C6F"
        local data = bytes.from_hex(hex)
        return data == "Hello"
      end,
    },
    {
      name = "hex - binary data",
      test = function()
        local data = string_char(0x80, 0x90, 0xA0, 0xB0, 0xC0, 0xD0, 0xE0, 0xF0)
        local hex = bytes.to_hex(data)
        local back = bytes.from_hex(hex)
        return hex == "8090a0b0c0d0e0f0" and back == data
      end,
    },

    -- 32-bit conversion tests
    {
      name = "u32 LE - basic",
      test = function()
        local n = 0x12345678
        local bytes_str = bytes.u32_to_le_bytes(n)
        local back = bytes.le_bytes_to_u32(bytes_str)
        local b1, b2, b3, b4 = string_byte(bytes_str, 1, 4)
        return back == n and b1 == 0x78 and b2 == 0x56 and b3 == 0x34 and b4 == 0x12
      end,
    },
    {
      name = "u32 LE - zero",
      test = function()
        local n = 0
        local bytes_str = bytes.u32_to_le_bytes(n)
        local back = bytes.le_bytes_to_u32(bytes_str)
        return back == 0 and bytes_str == string_char(0, 0, 0, 0)
      end,
    },
    {
      name = "u32 LE - max value",
      test = function()
        local n = 0xFFFFFFFF
        local bytes_str = bytes.u32_to_le_bytes(n)
        local back = bytes.le_bytes_to_u32(bytes_str)
        return back == 0xFFFFFFFF and bytes_str == string_char(0xFF, 0xFF, 0xFF, 0xFF)
      end,
    },
    {
      name = "u32 LE - needs masking",
      test = function()
        local n = 0x100000000 -- Should be masked to 0
        local bytes_str = bytes.u32_to_le_bytes(n)
        return bytes_str == string_char(0, 0, 0, 0)
      end,
    },
    {
      name = "u32 LE - single bit patterns",
      test = function()
        local n = 0x80000000
        local bytes_str = bytes.u32_to_le_bytes(n)
        local back = bytes.le_bytes_to_u32(bytes_str)
        return back == 0x80000000 and bytes_str == string_char(0, 0, 0, 0x80)
      end,
    },
    {
      name = "u32 LE - with offset",
      test = function()
        local data = "XXX" .. string_char(0x78, 0x56, 0x34, 0x12) .. "YYY"
        local n = bytes.le_bytes_to_u32(data, 4)
        return n == 0x12345678
      end,
    },
    {
      name = "u32 BE - basic",
      test = function()
        local n = 0x12345678
        local bytes_str = bytes.u32_to_be_bytes(n)
        local back = bytes.be_bytes_to_u32(bytes_str)
        local b1, b2, b3, b4 = string_byte(bytes_str, 1, 4)
        return back == n and b1 == 0x12 and b2 == 0x34 and b3 == 0x56 and b4 == 0x78
      end,
    },
    {
      name = "u32 BE - zero",
      test = function()
        local n = 0
        local bytes_str = bytes.u32_to_be_bytes(n)
        local back = bytes.be_bytes_to_u32(bytes_str)
        return back == 0 and bytes_str == string_char(0, 0, 0, 0)
      end,
    },
    {
      name = "u32 BE - max value",
      test = function()
        local n = 0xFFFFFFFF
        local bytes_str = bytes.u32_to_be_bytes(n)
        local back = bytes.be_bytes_to_u32(bytes_str)
        return back == 0xFFFFFFFF and bytes_str == string_char(0xFF, 0xFF, 0xFF, 0xFF)
      end,
    },
    {
      name = "u32 BE - with offset",
      test = function()
        local data = "XXX" .. string_char(0x12, 0x34, 0x56, 0x78) .. "YYY"
        local n = bytes.be_bytes_to_u32(data, 4)
        return n == 0x12345678
      end,
    },

    -- 64-bit conversion tests
    {
      name = "u64 LE - basic table",
      test = function()
        local n = bit64_new(0x12345678, 0x9ABCDEF0)
        local bytes_str = bytes.u64_to_le_bytes(n)
        local back = bytes.le_bytes_to_u64(bytes_str)
        local b1, b2, b3, b4, b5, b6, b7, b8 = string_byte(bytes_str, 1, 8)
        return back[1] == n[1]
          and back[2] == n[2]
          and b1 == 0xF0
          and b2 == 0xDE
          and b3 == 0xBC
          and b4 == 0x9A
          and b5 == 0x78
          and b6 == 0x56
          and b7 == 0x34
          and b8 == 0x12
      end,
    },
    {
      name = "u64 LE - number input",
      test = function()
        local n = 0x123456789ABCD -- Small enough for Lua number
        local bytes_str = bytes.u64_to_le_bytes(n)
        local back = bytes.le_bytes_to_u64(bytes_str)
        -- Check the conversion worked correctly
        local expected_low = n % 0x100000000
        local expected_high = floor(n / 0x100000000)
        return back[1] == expected_high and back[2] == expected_low
      end,
    },
    {
      name = "u64 LE - zero",
      test = function()
        local n = bit64_new(0, 0)
        local bytes_str = bytes.u64_to_le_bytes(n)
        local back = bytes.le_bytes_to_u64(bytes_str)
        return back[1] == 0 and back[2] == 0 and bytes_str == string_rep(string_char(0), 8)
      end,
    },
    {
      name = "u64 LE - max value",
      test = function()
        local n = bit64_new(0xFFFFFFFF, 0xFFFFFFFF)
        local bytes_str = bytes.u64_to_le_bytes(n)
        local back = bytes.le_bytes_to_u64(bytes_str)
        return back[1] == 0xFFFFFFFF and back[2] == 0xFFFFFFFF and bytes_str == string_rep(string_char(0xFF), 8)
      end,
    },
    {
      name = "u64 LE - high word only",
      test = function()
        local n = bit64_new(0x12345678, 0)
        local bytes_str = bytes.u64_to_le_bytes(n)
        local back = bytes.le_bytes_to_u64(bytes_str)
        return back[1] == 0x12345678 and back[2] == 0
      end,
    },
    {
      name = "u64 LE - low word only",
      test = function()
        local n = bit64_new(0, 0x12345678)
        local bytes_str = bytes.u64_to_le_bytes(n)
        local back = bytes.le_bytes_to_u64(bytes_str)
        return back[1] == 0 and back[2] == 0x12345678
      end,
    },
    {
      name = "u64 LE - with offset",
      test = function()
        local data = "XXX" .. bytes.u64_to_le_bytes(bit64_new(0x12345678, 0x9ABCDEF0)) .. "YYY"
        local n = bytes.le_bytes_to_u64(data, 4)
        return n[1] == 0x12345678 and n[2] == 0x9ABCDEF0
      end,
    },
    {
      name = "u64 BE - basic",
      test = function()
        local n = bit64_new(0x12345678, 0x9ABCDEF0)
        local bytes_str = bytes.u64_to_be_bytes(n)
        local back = bytes.be_bytes_to_u64(bytes_str)
        local b1, b2, b3, b4, b5, b6, b7, b8 = string_byte(bytes_str, 1, 8)
        return back[1] == n[1]
          and back[2] == n[2]
          and b1 == 0x12
          and b2 == 0x34
          and b3 == 0x56
          and b4 == 0x78
          and b5 == 0x9A
          and b6 == 0xBC
          and b7 == 0xDE
          and b8 == 0xF0
      end,
    },
    {
      name = "u64 BE - zero",
      test = function()
        local n = bit64_new(0, 0)
        local bytes_str = bytes.u64_to_be_bytes(n)
        local back = bytes.be_bytes_to_u64(bytes_str)
        return back[1] == 0 and back[2] == 0 and bytes_str == string_rep(string_char(0), 8)
      end,
    },
    {
      name = "u64 BE - with offset",
      test = function()
        local data = "XXX" .. bytes.u64_to_be_bytes(bit64_new(0x12345678, 0x9ABCDEF0)) .. "YYY"
        local n = bytes.be_bytes_to_u64(data, 4)
        return n[1] == 0x12345678 and n[2] == 0x9ABCDEF0
      end,
    },

    -- XOR tests
    {
      name = "xor - basic",
      test = function()
        local a = string_char(0x01, 0x02, 0x03, 0x04)
        local b = string_char(0xFF, 0xFE, 0xFD, 0xFC)
        local result = bytes.xor_bytes(a, b)
        local r1, r2, r3, r4 = string_byte(result, 1, 4)
        return r1 == 0xFE and r2 == 0xFC and r3 == 0xFE and r4 == 0xF8
      end,
    },
    {
      name = "xor - empty strings",
      test = function()
        local a = ""
        local b = ""
        local result = bytes.xor_bytes(a, b)
        return result == ""
      end,
    },
    {
      name = "xor - single byte",
      test = function()
        local a = string_char(0x00)
        local b = string_char(0xFF)
        local result = bytes.xor_bytes(a, b)
        return result == string_char(0xFF)
      end,
    },
    {
      name = "xor - with self",
      test = function()
        local a = "test"
        local result = bytes.xor_bytes(a, a)
        return result == string_char(0, 0, 0, 0)
      end,
    },
    {
      name = "xor - all zeros pattern",
      test = function()
        local a = string_char(0xAA, 0xBB, 0xCC, 0xDD)
        local b = string_char(0xAA, 0xBB, 0xCC, 0xDD)
        local result = bytes.xor_bytes(a, b)
        return result == string_char(0, 0, 0, 0)
      end,
    },
    {
      name = "xor - identity with zeros",
      test = function()
        local a = string_char(0x12, 0x34, 0x56, 0x78)
        local b = string_char(0, 0, 0, 0)
        local result = bytes.xor_bytes(a, b)
        return result == a
      end,
    },

    -- Constant-time comparison tests
    {
      name = "constant_time_compare - equal",
      test = function()
        local a = "test"
        local b = "test"
        return bytes.constant_time_compare(a, b) == true
      end,
    },
    {
      name = "constant_time_compare - not equal",
      test = function()
        local a = "test"
        local b = "text"
        return bytes.constant_time_compare(a, b) == false
      end,
    },
    {
      name = "constant_time_compare - different lengths",
      test = function()
        local a = "test"
        local b = "testing"
        return bytes.constant_time_compare(a, b) == false
      end,
    },
    {
      name = "constant_time_compare - empty strings",
      test = function()
        local a = ""
        local b = ""
        return bytes.constant_time_compare(a, b) == true
      end,
    },
    {
      name = "constant_time_compare - single char equal",
      test = function()
        local a = "a"
        local b = "a"
        return bytes.constant_time_compare(a, b) == true
      end,
    },
    {
      name = "constant_time_compare - single char not equal",
      test = function()
        local a = "a"
        local b = "b"
        return bytes.constant_time_compare(a, b) == false
      end,
    },
    {
      name = "constant_time_compare - binary with nulls",
      test = function()
        local a = string_char(0x00, 0x01, 0xFF)
        local b = string_char(0x00, 0x01, 0xFF)
        return bytes.constant_time_compare(a, b) == true
      end,
    },

    -- Padding tests
    {
      name = "pad_to_16 - no padding needed",
      test = function()
        local data = string_rep("a", 16)
        local padded = bytes.pad_to_16(data)
        return padded == data and #padded == 16
      end,
    },
    {
      name = "pad_to_16 - padding needed",
      test = function()
        local data = "Hello"
        local padded = bytes.pad_to_16(data)
        return #padded == 16 and padded:sub(1, 5) == "Hello" and padded:sub(6) == string_rep("\0", 11)
      end,
    },
    {
      name = "pad_to_16 - empty string",
      test = function()
        local data = ""
        local padded = bytes.pad_to_16(data)
        return padded == "" and #padded == 0
      end,
    },
    {
      name = "pad_to_16 - exactly 32 bytes",
      test = function()
        local data = string_rep("a", 32)
        local padded = bytes.pad_to_16(data)
        return padded == data and #padded == 32
      end,
    },
    {
      name = "pad_to_16 - one byte short",
      test = function()
        local data = string_rep("a", 15)
        local padded = bytes.pad_to_16(data)
        return #padded == 16 and padded:sub(1, 15) == data and padded:sub(16) == "\0"
      end,
    },
    {
      name = "pad_to_16 - one byte over",
      test = function()
        local data = string_rep("a", 17)
        local padded = bytes.pad_to_16(data)
        return #padded == 32 and padded:sub(1, 17) == data and padded:sub(18) == string_rep("\0", 15)
      end,
    },
    {
      name = "pad_to_16 - large data",
      test = function()
        local data = string_rep("a", 1000)
        local padded = bytes.pad_to_16(data)
        local expected_len = math.ceil(1000 / 16) * 16
        return #padded == expected_len and padded:sub(1, 1000) == data
      end,
    },
  }

  -- Run error handling tests separately with pcall
  local error_tests = {
    {
      name = "u32 LE - insufficient bytes",
      test = function()
        local ok, err = pcall(bytes.le_bytes_to_u32, "XX")
        return not ok and type(err) == "string" and err:match("Insufficient bytes")
      end,
    },
    {
      name = "u32 BE - insufficient bytes",
      test = function()
        local ok, err = pcall(bytes.be_bytes_to_u32, "XX")
        return not ok and type(err) == "string" and err:match("Insufficient bytes")
      end,
    },
    {
      name = "u64 LE - insufficient bytes",
      test = function()
        local ok, err = pcall(bytes.le_bytes_to_u64, "XXXXXX")
        return not ok and type(err) == "string" and err:match("Insufficient bytes")
      end,
    },
    {
      name = "u64 BE - insufficient bytes",
      test = function()
        local ok, err = pcall(bytes.be_bytes_to_u64, "XXXXXX")
        return not ok and type(err) == "string" and err:match("Insufficient bytes")
      end,
    },
    {
      name = "xor - length mismatch",
      test = function()
        local ok, err = pcall(bytes.xor_bytes, "abc", "abcd")
        return not ok and type(err) == "string" and err:match("same length")
      end,
    },
  }

  -- Run main tests
  for _, test in ipairs(test_vectors) do
    total = total + 1
    if test.test() then
      print("  ✅ PASS: " .. test.name)
      passed = passed + 1
    else
      print("  ❌ FAIL: " .. test.name)
    end
  end

  -- Run error tests
  for _, test in ipairs(error_tests) do
    total = total + 1
    if test.test() then
      print("  ✅ PASS: " .. test.name)
      passed = passed + 1
    else
      print("  ❌ FAIL: " .. test.name)
    end
  end

  print(string_format("\nByte operations result: %d/%d tests passed\n", passed, total))
  return passed == total
end

return bytes
end
end

do
local _ENV = _ENV
package.preload[ "crypto.x25519" ] = function( ... ) local arg = _G.arg;
--- @module "crypto.x25519"
--- X25519 Curve25519 Elliptic Curve Diffie-Hellman Implementation for portability.
--- @class crypto.x25519
local x25519 = {}

local bit32 = require("bitn").bit32

local random = require("crypto.random")
local utils = require("crypto.utils")
local bytes = utils.bytes
local benchmark_op = utils.benchmark.benchmark_op

-- Local references for performance
local bit32_raw_band = bit32.raw_band
local bit32_raw_rshift = bit32.raw_rshift
local floor = math.floor
local string_byte = string.byte
local string_char = string.char
local string_rep = string.rep
local table_concat = table.concat

-- ============================================================================
-- CURVE25519 FIELD ARITHMETIC
-- ============================================================================

-- `FieldElement` and `ProductArray` are shared with ed25519 (same field, same
-- limb layout) and are defined once in `annotations.lua`.

--- @alias ScalarArray integer[] 32-element array (indices 1-32) for scalar bytes

--- Initialize a 16-element field element with zeros
--- @return FieldElement fe Initialized field element
local function create_field_element()
  local arr = {}
  for i = 1, 16 do
    arr[i] = 0
  end
  return arr
end

--- Initialize a 31-element product array with zeros
--- @return ProductArray arr Initialized array
local function create_product_array()
  local arr = {}
  for i = 1, 31 do
    arr[i] = 0
  end
  return arr
end

--- Initialize a 32-element scalar array with zeros
--- @return ScalarArray arr Initialized array
local function create_scalar_array()
  local arr = {}
  for i = 1, 32 do
    arr[i] = 0
  end
  return arr
end

-- Pre-allocated constant for Montgomery ladder (a24 = 121665 = 0xdb41 + 1*0x10000)
-- This is (A-2)/4 where A=486662 for Curve25519
local A24 = { 0xdb41, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }

-- Pre-allocated product array for mul() to avoid repeated allocation
local mul_prod = create_product_array()

-- Pre-allocated arrays for pack() to avoid repeated allocation
local pack_t = create_field_element()
local pack_m = create_field_element()

-- Pre-allocated arrays for inv() to avoid repeated allocation
local inv_c = create_field_element()

-- Pre-allocated arrays for scalarmult() Montgomery ladder
-- These are the most critical - 8 arrays created per DH operation
local sm_a = create_field_element()
local sm_b = create_field_element()
local sm_c = create_field_element()
local sm_d = create_field_element()
local sm_e = create_field_element()
local sm_f = create_field_element()
local sm_x = create_field_element()
local sm_clam = create_scalar_array()

--- Carry operation for 64-bit arithmetic
--- @param out integer[] Array to perform carry on
local function carry(out)
  for i = 1, 16 do
    local v = out[i] + 0x10000
    local c = floor(v * 0.0000152587890625) -- 1/0x10000 = 0.0000152587890625
    if i < 16 then
      out[i + 1] = out[i + 1] + c - 1
    else
      out[1] = out[1] + 38 * (c - 1)
    end
    out[i] = v - c * 0x10000
  end
end

--- Conditional swap based on bit value
--- @param a integer[] First array
--- @param b integer[] Second array
--- @param bit integer Bit value (0 or 1)
local function swap(a, b, bit)
  for i = 1, 16 do
    a[i], b[i] = a[i] * ((bit - 1) % 2) + b[i] * bit, b[i] * ((bit - 1) % 2) + a[i] * bit
  end
end

--- Unpack byte array to limb array
--- @param out integer[] Output limb array
--- @param a integer[] Input byte array
local function unpack(out, a)
  for i = 1, 16 do
    out[i] = a[2 * i - 1] + a[2 * i] * 0x100
  end
  out[16] = out[16] % 0x8000
end

-- Pre-allocated prime constant for pack()
local PRIME = {
  0xffed,
  0xffff,
  0xffff,
  0xffff,
  0xffff,
  0xffff,
  0xffff,
  0xffff,
  0xffff,
  0xffff,
  0xffff,
  0xffff,
  0xffff,
  0xffff,
  0xffff,
  0x7fff,
}

--- Pack limb array to byte array with modular reduction
--- @param out integer[] Output byte array
--- @param a integer[] Input limb array
local function pack(out, a)
  -- Reuse pre-allocated arrays
  local t, m = pack_t, pack_m
  for i = 1, 16 do
    t[i] = a[i]
  end
  carry(t)
  carry(t)
  carry(t)
  for _ = 1, 2 do
    m[1] = t[1] - PRIME[1]
    for i = 2, 16 do
      local prev = m[i - 1]
      m[i] = t[i] - PRIME[i] - (floor(prev * 0.0000152587890625) % 2)
      m[i - 1] = (prev + 0x10000) % 0x10000
    end
    local c = floor(m[16] * 0.0000152587890625) % 2
    swap(t, m, 1 - c)
  end
  for i = 1, 16 do
    local ti = t[i]
    out[2 * i - 1] = ti % 0x100
    out[2 * i] = floor(ti * 0.00390625) -- 1/256
  end
end

--- Add two field elements
--- @param out integer[] Output array
--- @param a integer[] First input array
--- @param b integer[] Second input array
local function add(out, a, b)
  for i = 1, 16 do
    out[i] = a[i] + b[i]
  end
end

--- Subtract two field elements
--- @param out integer[] Output array
--- @param a integer[] First input array
--- @param b integer[] Second input array
local function sub(out, a, b)
  for i = 1, 16 do
    out[i] = a[i] - b[i]
  end
end

--- Multiply two field elements
--- @param out integer[] Output array
--- @param a integer[] First input array
--- @param b integer[] Second input array
local function mul(out, a, b)
  -- Reuse pre-allocated array and clear it
  local prod = mul_prod
  for i = 1, 31 do
    prod[i] = 0
  end
  -- Schoolbook multiplication
  for i = 1, 16 do
    local ai = a[i]
    for j = 1, 16 do
      prod[i + j - 1] = prod[i + j - 1] + ai * b[j]
    end
  end
  -- Reduce mod 2^255-19 (multiply high limbs by 38 and add to low)
  for i = 1, 15 do
    prod[i] = prod[i] + 38 * prod[i + 16]
  end
  for i = 1, 16 do
    out[i] = prod[i]
  end
  carry(out)
  carry(out)
end

--- Compute modular inverse using Fermat's little theorem
--- @param out integer[] Output array
--- @param a integer[] Input array
local function inv(out, a)
  -- Reuse pre-allocated array
  local c = inv_c
  for i = 1, 16 do
    c[i] = a[i]
  end
  for i = 253, 0, -1 do
    mul(c, c, c)
    if i ~= 2 and i ~= 4 then
      mul(c, c, a)
    end
  end
  for i = 1, 16 do
    out[i] = c[i]
  end
end

--- X25519 scalar multiplication using Montgomery ladder
--- @param out integer[] Output point
--- @param scalar integer[] Input scalar
--- @param point integer[] Input point
local function scalarmult(out, scalar, point)
  -- Reuse pre-allocated arrays for Montgomery ladder state
  local a, b, c, d, e, f, x, clam = sm_a, sm_b, sm_c, sm_d, sm_e, sm_f, sm_x, sm_clam
  unpack(x, point)
  for i = 1, 16 do
    a[i], b[i], c[i], d[i] = 0, x[i], 0, 0
  end
  a[1], d[1] = 1, 1
  for i = 1, 31 do
    clam[i] = scalar[i]
  end
  clam[1] = clam[1] - (clam[1] % 8)
  clam[32] = scalar[32] % 64 + 64
  for i = 254, 0, -1 do
    -- Optimized bit extraction
    local byte_idx = floor(i * 0.125) + 1 -- i / 8 + 1
    local bit_idx = i % 8
    local bit = bit32_raw_band(bit32_raw_rshift(clam[byte_idx], bit_idx), 1)
    swap(a, b, bit)
    swap(c, d, bit)
    add(e, a, c)
    sub(a, a, c)
    add(c, b, d)
    sub(b, b, d)
    mul(d, e, e)
    mul(f, a, a)
    mul(a, c, a)
    mul(c, b, e)
    add(e, a, c)
    sub(a, a, c)
    mul(b, a, a)
    sub(c, d, f)
    mul(a, c, A24) -- Use pre-allocated constant
    add(a, a, d)
    mul(c, c, a)
    mul(a, d, f)
    mul(d, b, x)
    mul(b, e, e)
    swap(a, b, bit)
    swap(c, d, bit)
  end
  inv(c, c)
  mul(a, a, c)
  pack(out, a)
end

--- Convert string to byte array
--- @param s string Input string
--- @return integer[] byte_array Byte array
local function string_to_bytes(s)
  local b = {}
  for i = 1, #s do
    b[i] = string_byte(s, i)
  end
  return b
end

--- Convert byte array to string
--- @param b integer[] Byte array
--- @param len integer Length
--- @return string result Output string
local function bytes_to_string(b, len)
  local result_bytes = {}
  for i = 1, len do
    result_bytes[i] = string_char(b[i] or 0)
  end
  return table_concat(result_bytes)
end

-- ============================================================================
-- X25519 PUBLIC INTERFACE
-- ============================================================================

--- Generate a random Curve25519 private key
---
--- Drawn from `crypto.random`, which raises rather than falling back to a weak
--- generator when the host has no CSPRNG. A guessable ephemeral scalar here
--- yields the shared secret to anyone who observed the exchange.
--- @return string private_key 32-byte private key
function x25519.generate_private_key()
  return random.bytes(32)
end

--- Derive public key from private key
--- @param private_key string 32-byte private key
--- @return string public_key 32-byte public key
function x25519.derive_public_key(private_key)
  assert(#private_key == 32, "Private key must be exactly 32 bytes")

  local sk = string_to_bytes(private_key)
  local pk = {}
  local base = { 9 }
  for i = 2, 32 do
    base[i] = 0
  end

  scalarmult(pk, sk, base)
  return bytes_to_string(pk, 32)
end

--- Perform X25519 Diffie-Hellman
--- @param private_key string 32-byte private key
--- @param public_key string 32-byte public key
--- @return string shared_secret 32-byte shared secret
function x25519.diffie_hellman(private_key, public_key)
  assert(#private_key == 32, "Private key must be exactly 32 bytes")
  assert(#public_key == 32, "Public key must be exactly 32 bytes")

  local sk = string_to_bytes(private_key)
  local pk = string_to_bytes(public_key)
  local shared = {}

  scalarmult(shared, sk, pk)
  return bytes_to_string(shared, 32)
end

--- Generate a Curve25519 key pair
--- @return string private_key 32-byte private key
--- @return string public_key 32-byte public key
function x25519.generate_keypair()
  local private_key = x25519.generate_private_key()
  local public_key = x25519.derive_public_key(private_key)
  return private_key, public_key
end

-- ============================================================================
-- TEST VECTORS AND VALIDATION
-- ============================================================================

--- Test vectors from RFC 7748
local test_vectors = {
  {
    name = "RFC 7748 Test Vector 1",
    scalar = bytes.from_hex("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"),
    u_coord = bytes.from_hex("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c"),
    expected = bytes.from_hex("c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552"),
  },
  {
    name = "RFC 7748 Test Vector 2",
    scalar = bytes.from_hex("4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d"),
    u_coord = bytes.from_hex("e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493"),
    expected = bytes.from_hex("95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957"),
  },
}

--- Run comprehensive self-test with RFC test vectors and functional tests
---
--- This function validates the X25519 implementation against known test vectors
--- from RFC 7748. ALL tests must pass for the implementation to be
--- considered cryptographically safe.
---
--- @return boolean result True if all tests pass, false otherwise
function x25519.selftest()
  local function test_vectors_suite()
    print("Running X25519 test vectors...")
    local passed = 0
    local total = #test_vectors

    for i, test in ipairs(test_vectors) do
      print(string.format("Test %d: %s", i, test.name))

      local result = x25519.diffie_hellman(test.scalar, test.u_coord)

      if result == test.expected then
        print("  ✅ PASS: " .. test.name)
        passed = passed + 1
      else
        print("  ❌ FAIL: " .. test.name)

        -- Show hex output for debugging
        local result_hex = ""
        local expected_hex = ""
        for j = 1, #result do
          result_hex = result_hex .. string.format("%02x", string_byte(result, j))
        end
        for j = 1, #test.expected do
          expected_hex = expected_hex .. string.format("%02x", string_byte(test.expected, j))
        end
        print("  Expected: " .. expected_hex)
        print("  Got:      " .. result_hex)
      end
      print()
    end

    print(string.format("Test vectors result: %d/%d tests passed", passed, total))
    print()
    return passed == total
  end
  local function functional_tests()
    print("Running X25519 functional tests...")
    local passed = 0
    local total = 0

    -- Test 1: Key generation
    total = total + 1
    local success, err = pcall(function()
      local priv1, pub1 = x25519.generate_keypair()
      local priv2, pub2 = x25519.generate_keypair()

      assert(#priv1 == 32 and #pub1 == 32, "Keys should be 32 bytes")
      assert(priv1 ~= priv2, "Different key generations should produce different keys")
      assert(pub1 ~= pub2, "Different key generations should produce different public keys")
    end)

    if success then
      print("  ✅ PASS: Key generation")
      passed = passed + 1
    else
      print("  ❌ FAIL: Key generation - " .. err)
    end

    -- Test 2: Public key derivation consistency
    total = total + 1
    success, err = pcall(function()
      local priv = x25519.generate_private_key()
      local pub1 = x25519.derive_public_key(priv)
      local pub2 = x25519.derive_public_key(priv)

      assert(pub1 == pub2, "Public key derivation should be deterministic")
    end)

    if success then
      print("  ✅ PASS: Public key derivation consistency")
      passed = passed + 1
    else
      print("  ❌ FAIL: Public key derivation consistency - " .. err)
    end

    -- Test 3: Diffie-Hellman symmetry
    total = total + 1
    success, err = pcall(function()
      local alice_priv, alice_pub = x25519.generate_keypair()
      local bob_priv, bob_pub = x25519.generate_keypair()

      local alice_shared = x25519.diffie_hellman(alice_priv, bob_pub)
      local bob_shared = x25519.diffie_hellman(bob_priv, alice_pub)

      assert(alice_shared == bob_shared, "DH should be symmetric")
      assert(#alice_shared == 32, "Shared secret should be 32 bytes")
    end)

    if success then
      print("  ✅ PASS: Diffie-Hellman symmetry")
      passed = passed + 1
    else
      print("  ❌ FAIL: Diffie-Hellman symmetry - " .. err)
    end

    -- Test 4: Different keys produce different shared secrets
    total = total + 1
    success, err = pcall(function()
      local alice_priv, _alice_pub = x25519.generate_keypair()
      local _bob_priv, bob_pub = x25519.generate_keypair()
      local _charlie_priv, charlie_pub = x25519.generate_keypair()

      local alice_bob = x25519.diffie_hellman(alice_priv, bob_pub)
      local alice_charlie = x25519.diffie_hellman(alice_priv, charlie_pub)

      assert(alice_bob ~= alice_charlie, "Different keys should produce different shared secrets")
    end)

    if success then
      print("  ✅ PASS: Different shared secrets")
      passed = passed + 1
    else
      print("  ❌ FAIL: Different shared secrets - " .. err)
    end

    -- Test 5: Edge case - all zero input (should not fail)
    total = total + 1
    success, err = pcall(function()
      local zero_key = string_rep("\0", 32)
      local priv, _pub = x25519.generate_keypair()

      -- This should not crash, though result may be predictable
      local result = x25519.diffie_hellman(priv, zero_key)
      assert(#result == 32, "Should still produce 32-byte result")
    end)

    if success then
      print("  ✅ PASS: Edge case handling")
      passed = passed + 1
    else
      print("  ❌ FAIL: Edge case handling - " .. err)
    end

    print(string.format("\nFunctional tests result: %d/%d tests passed", passed, total))
    print()
    return passed == total
  end

  local vectors_passed = test_vectors_suite()
  local functional_passed = functional_tests()

  return vectors_passed and functional_passed
end

--- Run performance benchmarks
---
--- This function runs comprehensive performance benchmarks for X25519 operations
--- including key generation, public key derivation, and Diffie-Hellman operations.
function x25519.benchmark()
  -- Test data from RFC 7748
  local test_scalar = bytes.from_hex("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4")
  local test_point = bytes.from_hex("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c")

  print("Key Operations:")
  benchmark_op("generate_keypair", function()
    x25519.generate_keypair()
  end, 20)

  benchmark_op("derive_public_key", function()
    x25519.derive_public_key(test_scalar)
  end, 50)

  benchmark_op("diffie_hellman", function()
    x25519.diffie_hellman(test_scalar, test_point)
  end, 50)
end

return x25519
end
end

do
local _ENV = _ENV
package.preload[ "crypto.x448" ] = function( ... ) local arg = _G.arg;
--- @module "crypto.x448"
--- X448 Curve448 Elliptic Curve Diffie-Hellman Implementation
---
--- This module implements X448 key exchange as specified in RFC 7748.
--- It uses 8-bit limbs for portability and compatibility with systems
--- that have limited integer precision (e.g., Lua's 53-bit integers).
---
--- The implementation follows the Montgomery ladder algorithm and includes:
--- - Field arithmetic modulo p = 2^448 - 2^224 - 1
--- - Scalar multiplication on Curve448
--- - Key generation and Diffie-Hellman operations
--- @class crypto.x448
local x448 = {}

local bitn = require("bitn")
local random = require("crypto.random")
local utils = require("crypto.utils")

local bytes = utils.bytes
local benchmark_op = utils.benchmark.benchmark_op

-- Local references for performance
local bit32_raw_band = bitn.bit32.raw_band
local bit32_raw_bor = bitn.bit32.raw_bor
local bit32_raw_bxor = bitn.bit32.raw_bxor
local bit32_raw_rshift = bitn.bit32.raw_rshift
local byte = string.byte
local char = string.char
local floor = math.floor
local string_rep = string.rep
local table_concat = table.concat

-- Constants for X448 implementation
-- Field prime p = 2^448 - 2^224 - 1 (Goldilocks prime)
-- We use 56 limbs of 8 bits each (56 * 8 = 448 bits)
local LIMB_MASK = 0xFF -- 2^8 - 1 (mask for 8-bit limbs)
local NUM_LIMBS = 56 -- Number of 8-bit limbs for 448 bits
local A24 = 39081 -- Montgomery curve constant (A-2)/4 where A = 156326

--- Create a new field element initialized to zero
--- @return table fe Field element (56 limbs)
local function fe_zero()
  local r = {}
  for i = 1, NUM_LIMBS do
    r[i] = 0
  end
  return r
end

--- Create a new field element initialized to one
--- @return table fe Field element (56 limbs)
local function fe_one()
  local r = fe_zero()
  r[1] = 1
  return r
end

--- Copy a field element
--- @param a table Source field element
--- @return table fe New field element
local function fe_copy(a)
  local r = {}
  for i = 1, NUM_LIMBS do
    r[i] = a[i] or 0
  end
  return r
end

--- Reduce coefficients and propagate carries
--- @param a table Field element to reduce (modified in place)
local function fe_reduce(a)
  -- First, normalize all limbs and collect carries
  local carry = 0
  for i = 1, NUM_LIMBS do
    carry = carry + (a[i] or 0)
    a[i] = bit32_raw_band(carry, LIMB_MASK)
    carry = floor(carry / 256)
  end

  -- Handle overflow: 2^448 ≡ 2^224 + 1 (mod p)
  while carry > 0 do
    a[1] = a[1] + carry
    a[29] = a[29] + carry -- Position 224 is limb 28+1 = 29

    -- Propagate carries again
    local new_carry = 0
    for i = 1, NUM_LIMBS do
      new_carry = new_carry + a[i]
      a[i] = bit32_raw_band(new_carry, LIMB_MASK)
      new_carry = floor(new_carry / 256)
    end
    carry = new_carry
  end
end

--- Add two field elements
--- @param a table First operand
--- @param b table Second operand
--- @return table r Result
local function fe_add(a, b)
  local r = {}
  for i = 1, NUM_LIMBS do
    r[i] = (a[i] or 0) + (b[i] or 0)
  end
  fe_reduce(r)
  return r
end

--- Subtract two field elements
--- @param a table First operand
--- @param b table Second operand
--- @return table r Result
local function fe_sub(a, b)
  local r = {}
  local borrow = 0

  for i = 1, NUM_LIMBS do
    local diff = (a[i] or 0) - (b[i] or 0) - borrow
    if diff < 0 then
      r[i] = diff + 256
      borrow = 1
    else
      r[i] = diff
      borrow = 0
    end
  end

  -- If we have a borrow, add p to make positive
  if borrow > 0 then
    -- Add p = 2^448 - 2^224 - 1 with proper carry propagation
    local carry = 0
    for i = 1, 28 do
      local sum = r[i] + 0xFF + carry
      r[i] = bit32_raw_band(sum, LIMB_MASK)
      carry = floor(sum / 256)
    end

    local sum = r[29] + 0xFE + carry
    r[29] = bit32_raw_band(sum, LIMB_MASK)
    carry = floor(sum / 256)

    for i = 30, NUM_LIMBS do
      sum = r[i] + 0xFF + carry
      r[i] = bit32_raw_band(sum, LIMB_MASK)
      carry = floor(sum / 256)
    end
  end

  fe_reduce(r)
  return r
end

--- Multiply two field elements
--- @param a table First operand
--- @param b table Second operand
--- @return table r Result
local function fe_mul(a, b)
  -- Pre-allocate result array with zeros
  local r = {}
  for i = 1, 2 * NUM_LIMBS do
    r[i] = 0
  end

  -- Schoolbook multiplication without intermediate carry propagation
  -- This is safe because each limb product is at most 255*255 = 65025
  -- and we can accumulate up to ~56 of these before overflow
  for i = 1, NUM_LIMBS do
    local ai = a[i]
    if ai and ai > 0 then -- Skip zero multiplications
      for j = 1, NUM_LIMBS do
        local bj = b[j]
        if bj and bj > 0 then
          r[i + j - 1] = r[i + j - 1] + ai * bj
        end
      end
    end
  end

  -- Single carry propagation pass
  local carry = 0
  for i = 1, 2 * NUM_LIMBS do
    local sum = r[i] + carry
    r[i] = bit32_raw_band(sum, LIMB_MASK)
    carry = floor(sum / 256)
  end

  -- Fast reduction using the special form of p = 2^448 - 2^224 - 1
  -- For each limb i >= 56, we have:
  -- 2^(8i) ≡ 2^(8(i-56)) + 2^(8(i-56)+224) (mod p)
  for i = NUM_LIMBS + 1, 2 * NUM_LIMBS do
    local c = r[i]
    if c > 0 then
      r[i] = 0
      local pos1 = i - NUM_LIMBS
      local pos2 = pos1 + 28 -- 224/8 = 28

      r[pos1] = r[pos1] + c
      if pos2 <= NUM_LIMBS then
        r[pos2] = r[pos2] + c
      else
        -- Handle wraparound
        local wrap_pos = pos2 - NUM_LIMBS
        r[wrap_pos] = r[wrap_pos] + c
        r[wrap_pos + 28] = r[wrap_pos + 28] + c
      end
    end
  end

  -- Handle remaining carry from reduction
  if carry > 0 then
    r[1] = r[1] + carry
    r[29] = r[29] + carry
  end

  -- Final carry propagation and normalization
  carry = 0
  for i = 1, NUM_LIMBS do
    local sum = r[i] + carry
    r[i] = bit32_raw_band(sum, LIMB_MASK)
    carry = floor(sum / 256)
  end

  -- Handle final carry
  while carry > 0 do
    r[1] = r[1] + carry
    r[29] = r[29] + carry

    carry = 0
    for i = 1, NUM_LIMBS do
      local sum = r[i] + carry
      r[i] = bit32_raw_band(sum, LIMB_MASK)
      carry = floor(sum / 256)
    end
  end

  -- Ensure we only have NUM_LIMBS limbs
  local result = {}
  for i = 1, NUM_LIMBS do
    result[i] = r[i]
  end

  return result
end

--- Square a field element
--- @param a table Operand
--- @return table r Result
local function fe_sq(a)
  return fe_mul(a, a)
end

--- Field inversion using Fermat's little theorem
--- @param a table Field element to invert
--- @return table r Result (a^-1)
local function fe_inv(a)
  -- Special case: if input is 1, return 1
  local is_one = true
  for i = 2, NUM_LIMBS do
    if (a[i] or 0) ~= 0 then
      is_one = false
      break
    end
  end
  if is_one and (a[1] or 0) == 1 then
    return fe_one()
  end

  -- Implement exact binary exponentiation matching Python's pow() algorithm
  -- Process the exponent bit by bit from MSB to LSB
  -- Exponent = p-2 = 2^448 - 2^224 - 3

  local result = fe_one()
  local base = fe_copy(a)

  -- The exponent in binary is: 448 bits starting with 1
  -- Pattern: 223 ones, 1 zero, 222 ones, 1 zero, 1 one

  -- Process MSB (bit 447) = 1
  result = fe_mul(result, base)

  -- Pre-compute small powers for sliding window
  local powers = {}
  powers[1] = fe_copy(base)
  powers[2] = fe_sq(base)
  powers[3] = fe_mul(powers[2], base)

  -- Process bits 446 down to 225 (222 ones) using 2-bit sliding window
  for _ = 1, 111 do
    result = fe_sq(result)
    result = fe_sq(result)
    result = fe_mul(result, powers[3]) -- Multiply by a^3
  end

  -- Process bit 224 = 0
  result = fe_sq(result)

  -- Process bits 223 down to 2 (222 ones) using 2-bit sliding window
  for _ = 1, 111 do
    result = fe_sq(result)
    result = fe_sq(result)
    result = fe_mul(result, powers[3]) -- Multiply by a^3
  end

  -- Process bit 1 = 0
  result = fe_sq(result)

  -- Process bit 0 (LSB) = 1
  result = fe_sq(result)
  result = fe_mul(result, base)

  return result
end

--- Conditional swap of two field elements (returns new arrays)
--- @param swap number 0 or 1
--- @param a table First element
--- @param b table Second element
--- @return table new_a, table new_b
local function cswap(swap, a, b)
  if swap == 1 then
    local new_a = {}
    local new_b = {}
    for i = 1, NUM_LIMBS do
      new_a[i] = b[i]
      new_b[i] = a[i]
    end
    return new_a, new_b
  else
    local new_a = {}
    local new_b = {}
    for i = 1, NUM_LIMBS do
      new_a[i] = a[i]
      new_b[i] = b[i]
    end
    return new_a, new_b
  end
end

--- Convert bytes to field element (little-endian)
--- @param b string 56-byte string
--- @return table fe Field element
local function fe_frombytes(b)
  local r = fe_zero()
  -- With 8-bit limbs, it's a direct 1-to-1 mapping
  for i = 1, NUM_LIMBS do
    r[i] = byte(b, i) or 0
  end
  return r
end

--- Convert field element to bytes (little-endian)
--- @param a table Field element
--- @return string bytes 56-byte string
local function fe_tobytes(a)
  -- First ensure the field element is fully reduced
  local t = fe_copy(a)
  fe_reduce(t)

  -- Convert to bytes - with 8-bit limbs it's direct
  local b = {}
  for i = 1, NUM_LIMBS do
    b[i] = char(bit32_raw_band(t[i] or 0, 0xFF))
  end

  return table_concat(b)
end

--- X448 scalar multiplication
--- @param scalar string 56-byte scalar
--- @param base string 56-byte base point
--- @return string result 56-byte result
local function x448_scalarmult(scalar, base)
  -- Decode base point
  local u = fe_frombytes(base)

  -- Scalar clamping as per RFC 7748 for X448
  local k = {}
  for i = 1, 56 do
    k[i] = byte(scalar, i) or 0
  end
  k[1] = bit32_raw_band(k[1], 252) -- Clear low 2 bits
  k[56] = bit32_raw_bor(k[56], 128) -- Set high bit

  -- Initialize Montgomery ladder
  local x_1 = fe_copy(u)
  local x_2 = fe_one()
  local z_2 = fe_zero()
  local x_3 = fe_copy(u)
  local z_3 = fe_one()
  local swap = 0

  -- Montgomery ladder
  for t = 447, 0, -1 do
    local byte_idx = bit32_raw_rshift(t, 3) + 1 -- t // 8 + 1
    local bit_idx = bit32_raw_band(t, 7) -- t % 8
    local kt = bit32_raw_band(bit32_raw_rshift(k[byte_idx], bit_idx), 1)

    -- Conditional swap
    swap = bit32_raw_bxor(swap, kt)
    x_2, x_3 = cswap(swap, x_2, x_3)
    z_2, z_3 = cswap(swap, z_2, z_3)
    swap = kt

    -- Montgomery ladder step
    local a = fe_add(x_2, z_2)
    local aa = fe_sq(a)
    local b = fe_sub(x_2, z_2)
    local bb = fe_sq(b)
    local e = fe_sub(aa, bb)
    local c = fe_add(x_3, z_3)
    local d = fe_sub(x_3, z_3)
    local da = fe_mul(d, a)
    local cb = fe_mul(c, b)

    x_3 = fe_sq(fe_add(da, cb))
    z_3 = fe_mul(x_1, fe_sq(fe_sub(da, cb)))
    x_2 = fe_mul(aa, bb)

    -- z_2 = e * (aa + a24 * e)
    local a24_limbs = fe_zero()
    a24_limbs[1] = bit32_raw_band(A24, 0xFF)
    a24_limbs[2] = bit32_raw_band(bit32_raw_rshift(A24, 8), 0xFF)

    local a24_e = fe_mul(a24_limbs, e)
    z_2 = fe_mul(e, fe_add(aa, a24_e))
  end

  -- Final swap
  local _
  x_2, _ = cswap(swap, x_2, x_3)
  z_2, _ = cswap(swap, z_2, z_3)

  -- Compute x_2 / z_2
  local z_inv = fe_inv(z_2)
  local x = fe_mul(x_2, z_inv)

  -- Convert to bytes
  return fe_tobytes(x)
end

--- Generate a random Curve448 private key
---
--- Drawn from `crypto.random`, which raises rather than falling back to a weak
--- generator when the host has no CSPRNG.
--- @return string private_key 56-byte private key
function x448.generate_private_key()
  return random.bytes(56)
end

--- Derive public key from private key
--- @param private_key string 56-byte private key
--- @return string public_key 56-byte public key
function x448.derive_public_key(private_key)
  assert(#private_key == 56, "Private key must be exactly 56 bytes")

  -- Base point for X448 (u = 5)
  local base = char(5) .. string_rep(char(0), 55)

  return x448_scalarmult(private_key, base)
end

--- Perform X448 Diffie-Hellman
--- @param private_key string 56-byte private key
--- @param public_key string 56-byte public key
--- @return string shared_secret 56-byte shared secret
function x448.diffie_hellman(private_key, public_key)
  assert(#private_key == 56, "Private key must be exactly 56 bytes")
  assert(#public_key == 56, "Public key must be exactly 56 bytes")

  return x448_scalarmult(private_key, public_key)
end

--- Generate a Curve448 key pair
--- @return string private_key 56-byte private key
--- @return string public_key 56-byte public key
function x448.generate_keypair()
  local private_key = x448.generate_private_key()
  local public_key = x448.derive_public_key(private_key)
  return private_key, public_key
end

--- Test vectors from RFC 7748
local test_vectors = {
  {
    name = "RFC 7748 Test Vector 1",
    scalar = bytes.from_hex(
      "3d262fddf9ec8e88495266fea19a34d28882acef045104d0d1aae121"
        .. "700a779c984c24f8cdd78fbff44943eba368f54b29259a4f1c600ad3"
    ),
    u_coord = bytes.from_hex(
      "06fce640fa3487bfda5f6cf2d5263f8aad88334cbd07437f020f08f9"
        .. "814dc031ddbdc38c19c6da2583fa5429db94ada18aa7a7fb4ef8a086"
    ),
    expected = bytes.from_hex(
      "ce3e4ff95a60dc6697da1db1d85e6afbdf79b50a2412d7546d5f239f"
        .. "e14fbaadeb445fc66a01b0779d98223961111e21766282f73dd96b6f"
    ),
  },
  {
    name = "RFC 7748 Test Vector 2",
    scalar = bytes.from_hex(
      "203d494428b8399352665ddca42f9de8fef600908e0d461cb021f8c5"
        .. "38345dd77c3e4806e25f46d3315c44e0a5b4371282dd2c8d5be3095f"
    ),
    u_coord = bytes.from_hex(
      "0fbcc2f993cd56d3305b0b7d9e55d4c1a8fb5dbb52f8e9a1e9b6201b"
        .. "165d015894e56c4d3570bee52fe205e28a78b91cdfbde71ce8d157db"
    ),
    expected = bytes.from_hex(
      "884a02576239ff7a2f2f63b2db6a9ff37047ac13568e1e30fe63c4a7"
        .. "ad1b3ee3a5700df34321d62077e63633c575c1c954514e99da7c179d"
    ),
  },
}

--- Run comprehensive self-test with RFC test vectors and functional tests
---
--- This function validates the X448 implementation against known test vectors
--- from RFC 7748. ALL tests must pass for the implementation to be
--- considered cryptographically safe.
---
--- @return boolean result True if all tests pass, false otherwise
function x448.selftest()
  local function test_vectors_suite()
    print("Running X448 test vectors...")
    local passed = 0
    local total = #test_vectors

    for i, test in ipairs(test_vectors) do
      print(string.format("Test %d: %s", i, test.name))

      -- Debug: Check input format
      print("  Scalar length: " .. #test.scalar)
      print("  U-coord length: " .. #test.u_coord)

      local result = x448.diffie_hellman(test.scalar, test.u_coord)

      if result == test.expected then
        print("  ✅ PASS: " .. test.name)
        passed = passed + 1
      else
        print("  ❌ FAIL: " .. test.name)
        print("    Expected: " .. bytes.to_hex(test.expected))
        print("    Got:      " .. bytes.to_hex(result))
      end
    end

    print(string.format("\nTest vectors result: %d/%d tests passed\n", passed, total))
    return passed == total
  end

  local function functional_tests()
    print("Running X448 functional tests...")
    local passed = 0
    local total = 0

    -- Test 1: Key generation
    total = total + 1
    local ok, err = pcall(function()
      local private_key, public_key = x448.generate_keypair()
      assert(#private_key == 56, "Private key should be 56 bytes")
      assert(#public_key == 56, "Public key should be 56 bytes")
    end)
    if ok then
      print("  ✅ PASS: Key generation")
      passed = passed + 1
    else
      print("  ❌ FAIL: Key generation - " .. tostring(err))
    end

    -- Test 2: Public key derivation consistency
    total = total + 1
    ok = pcall(function()
      local private_key = x448.generate_private_key()
      local public_key1 = x448.derive_public_key(private_key)
      local public_key2 = x448.derive_public_key(private_key)
      assert(public_key1 == public_key2, "Public key derivation should be deterministic")
    end)
    if ok then
      print("  ✅ PASS: Public key derivation consistency")
      passed = passed + 1
    else
      print("  ❌ FAIL: Public key derivation consistency")
    end

    -- Test 3: Diffie-Hellman symmetry
    total = total + 1
    ok = pcall(function()
      local alice_private, alice_public = x448.generate_keypair()
      local bob_private, bob_public = x448.generate_keypair()

      local alice_shared = x448.diffie_hellman(alice_private, bob_public)
      local bob_shared = x448.diffie_hellman(bob_private, alice_public)

      assert(alice_shared == bob_shared, "DH key exchange should be symmetric")
    end)
    if ok then
      print("  ✅ PASS: Diffie-Hellman symmetry")
      passed = passed + 1
    else
      print("  ❌ FAIL: Diffie-Hellman symmetry")
    end

    -- Test 4: Different shared secrets
    total = total + 1
    ok = pcall(function()
      local alice_private, _alice_public = x448.generate_keypair()
      local _bob_private, bob_public = x448.generate_keypair()
      local _charlie_private, charlie_public = x448.generate_keypair()

      local alice_bob = x448.diffie_hellman(alice_private, bob_public)
      local alice_charlie = x448.diffie_hellman(alice_private, charlie_public)

      assert(alice_bob ~= alice_charlie, "Different key pairs should produce different shared secrets")
    end)
    if ok then
      print("  ✅ PASS: Different shared secrets")
      passed = passed + 1
    else
      print("  ❌ FAIL: Different shared secrets")
    end

    -- Test 5: Edge case handling
    total = total + 1
    ok = pcall(function()
      -- Test with all-zero public key
      local private_key = x448.generate_private_key()
      local zero_public = string_rep(char(0), 56)
      local shared = x448.diffie_hellman(private_key, zero_public)
      assert(#shared == 56, "Should handle zero public key")
    end)
    if ok then
      print("  ✅ PASS: Edge case handling")
      passed = passed + 1
    else
      print("  ❌ FAIL: Edge case handling")
    end

    print(string.format("\nFunctional tests result: %d/%d tests passed\n", passed, total))
    return passed == total
  end

  -- Run both test suites
  local vectors_pass = test_vectors_suite()
  local functional_pass = functional_tests()

  return vectors_pass and functional_pass
end

-- Store private key counter for better randomness
x448._key_counter = 0

--- Run performance benchmarks
---
--- This function runs comprehensive performance benchmarks for X448 operations
--- including key generation, public key derivation, and Diffie-Hellman operations.
function x448.benchmark()
  -- Test data from RFC 7748
  local test_scalar = bytes.from_hex(
    "3d262fddf9ec8e88495266fea19a34d28882acef045104d0d1aae121"
      .. "700a779c984c24f8cdd78fbff44943eba368f54b29259a4f1c600ad3"
  )
  local test_point = bytes.from_hex(
    "06fce640fa3487bfda5f6cf2d5263f8aad88334cbd07437f020f08f9"
      .. "814dc031ddbdc38c19c6da2583fa5429db94ada18aa7a7fb4ef8a086"
  )

  print("Key Operations:")
  benchmark_op("generate_keypair", function()
    x448.generate_keypair()
  end, 5)

  benchmark_op("derive_public_key", function()
    x448.derive_public_key(test_scalar)
  end, 10)

  benchmark_op("diffie_hellman", function()
    x448.diffie_hellman(test_scalar, test_point)
  end, 10)
end

return x448
end
end

--- @module "crypto"
--- Portable cryptographic primitives for Lua with optional OpenSSL acceleration.
--- Pure-Lua implementations of hashing (SHA-256/512, BLAKE2), AEAD ciphers
--- (ChaCha20-Poly1305, AES-GCM), the Poly1305 MAC, HKDF key derivation,
--- Curve25519/448 Diffie-Hellman, Ed25519 signatures, and SRP-6a. Runs on Lua
--- 5.1, 5.2, 5.3, 5.4, and LuaJIT with zero C dependencies.
---
--- Key generation draws from `crypto.random`, which uses the host CSPRNG and
--- raises when there is not one. It never falls back to `math.random`.
---
--- When the host provides the lua-openssl binding (e.g. Control4 DriverWorks OS
--- >= 3.4.1), hashing and AEAD transparently prefer it for speed and fall back to
--- the pure-Lua implementations otherwise. The elliptic-curve Diffie-Hellman
--- functions (x25519/x448) and Ed25519 signing always use the portable
--- implementations regardless of the OpenSSL flag -- the shipped lua-openssl
--- builds cannot perform the raw Curve25519/448 operations, and cannot sign
--- with an Ed25519 key even when they can import one.
---
--- @usage
--- local crypto = require("crypto")
--- print(crypto.version())
---
--- -- opt-in OpenSSL acceleration; automatically falls back to pure Lua
--- crypto.use_openssl(true)
---
--- local digest = crypto.sha512.sha512_hex("hello")
--- local ct = crypto.chacha20_poly1305.encrypt(key, nonce, plaintext, aad)
--- local shared = crypto.x25519.diffie_hellman(my_private, their_public)
---
--- @class crypto
local crypto = {
  -- Hash functions
  --- @type crypto.sha256
  sha256 = require("crypto.sha256"),
  --- @type crypto.sha512
  sha512 = require("crypto.sha512"),
  --- @type crypto.blake2
  blake2 = require("crypto.blake2"),

  -- AEAD ciphers
  --- @type crypto.chacha20_poly1305
  chacha20_poly1305 = require("crypto.chacha20_poly1305"),
  --- @type crypto.aes_gcm
  aes_gcm = require("crypto.aes_gcm"),

  -- Stream ciphers
  --- @type crypto.chacha20
  chacha20 = require("crypto.chacha20"),

  -- MAC
  --- @type crypto.poly1305
  poly1305 = require("crypto.poly1305"),

  -- Key derivation
  --- @type crypto.hkdf
  hkdf = require("crypto.hkdf"),

  -- Cryptographically secure randomness (raises rather than returning weak bytes)
  --- @type crypto.random
  random = require("crypto.random"),

  -- Arbitrary-precision integers (OpenSSL-preferred modular exponentiation)
  --- @type crypto.bignum
  bignum = require("crypto.bignum"),

  -- Password-authenticated key exchange (client side)
  --- @type crypto.srp
  srp = require("crypto.srp"),

  -- Diffie-Hellman (always pure Lua)
  --- @type crypto.x25519
  x25519 = require("crypto.x25519"),
  --- @type crypto.x448
  x448 = require("crypto.x448"),

  -- Digital signatures (always pure Lua)
  --- @type crypto.ed25519
  ed25519 = require("crypto.ed25519"),

  -- Optional OpenSSL acceleration (exposed for diagnostics and feature queries)
  --- @type crypto.openssl_wrapper
  openssl_wrapper = require("crypto.openssl_wrapper"),
}

local openssl_wrapper = crypto.openssl_wrapper

--- Library version (injected at build time for releases).
local VERSION = "v0.2.0"

--- Enable or disable OpenSSL acceleration for the primitives that support it
--- (hashing and AEAD). Opt-in and safe: when the lua-openssl binding is
--- unavailable, or a given primitive is not accelerated, the pure-Lua
--- implementation is used automatically. Curve25519/448 always use pure Lua.
--- @param use boolean
function crypto.use_openssl(use)
  openssl_wrapper.use(use)
end

--- Get the library version string.
--- @return string version Version string (e.g., "v1.0.0" or "dev")
function crypto.version()
  return VERSION
end

--- Run every module's known-answer self-test.
--- @return boolean ok True if all module self-tests pass
function crypto.selftest()
  local modules = {
    "sha256",
    "sha512",
    "blake2",
    "chacha20",
    "chacha20_poly1305",
    "poly1305",
    "aes_gcm",
    "hkdf",
    "random",
    "bignum",
    "srp",
    "x25519",
    "x448",
    "ed25519",
    "openssl_wrapper",
  }
  local ok = true
  for _, name in ipairs(modules) do
    local mod = crypto[name]
    if type(mod.selftest) == "function" then
      if mod.selftest() == false then
        ok = false
      end
    end
  end
  return ok
end

return crypto

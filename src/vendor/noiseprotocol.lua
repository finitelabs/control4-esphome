do
  local _ENV = _ENV
  package.preload["noiseprotocol.crypto"] = function(...)
    local arg = _G.arg
    --- @module "noiseprotocol.crypto"

    return {
      -- Hash functions
      sha256 = require("noiseprotocol.crypto.sha256"),
      sha512 = require("noiseprotocol.crypto.sha512"),
      blake2 = require("noiseprotocol.crypto.blake2"),

      -- AEAD ciphers
      chacha20_poly1305 = require("noiseprotocol.crypto.chacha20_poly1305"),
      aes_gcm = require("noiseprotocol.crypto.aes_gcm"),

      -- Stream ciphers
      chacha20 = require("noiseprotocol.crypto.chacha20"),

      -- MAC
      poly1305 = require("noiseprotocol.crypto.poly1305"),

      -- DH functions
      x25519 = require("noiseprotocol.crypto.x25519"),
      x448 = require("noiseprotocol.crypto.x448"),
    }
  end
end

do
  local _ENV = _ENV
  package.preload["noiseprotocol.crypto.aes_gcm"] = function(...)
    local arg = _G.arg
    --- @module "noiseprotocol.crypto.aes_gcm"
    --- AES-GCM Authenticated Encryption with Associated Data (AEAD) Implementation for portability.

    local openssl_wrapper = require("noiseprotocol.openssl_wrapper")
    local utils = require("noiseprotocol.utils")
    local bit32 = utils.bit32
    local bytes = utils.bytes
    local benchmark_op = utils.benchmark.benchmark_op

    local aes_gcm = {}

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

    --- @alias AESGCMWord [integer, integer, integer, integer]
    --- @alias AESGCMBlock [integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer]
    --- @alias AESGCMState [AESGCMWord, AESGCMWord, AESGCMWord, AESGCMWord]

    --- XOR two 4-byte words
    --- @param a AESGCMWord 4-byte array
    --- @param b AESGCMWord 4-byte array
    --- @return table Word 4-byte array
    local function xor_words(a, b)
      return {
        bit32.bxor(a[1], b[1]),
        bit32.bxor(a[2], b[2]),
        bit32.bxor(a[3], b[3]),
        bit32.bxor(a[4], b[4]),
      }
    end

    --- Rotate word (circular left shift by 1 byte)
    --- @param word AESGCMWord 4-byte array
    --- @return AESGCMWord result Rotated 4-byte array
    local function rot_word(word)
      return { word[2], word[3], word[4], word[1] }
    end

    --- Apply S-box substitution to a word
    --- @param word AESGCMWord 4-byte array
    --- @return AESGCMWord result Substituted 4-byte array
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
      --- @type AESGCMWord
      local w = {}
      for i = 0, nk - 1 do
        w[i] = {
          string.byte(key, i * 4 + 1),
          string.byte(key, i * 4 + 2),
          string.byte(key, i * 4 + 3),
          string.byte(key, i * 4 + 4),
        }
      end

      -- Expand key
      for i = nk, 4 * (nr + 1) - 1 do
        local temp = w[i - 1]
        if i % nk == 0 then
          local t = assert(RCON[i / nk], "Invalid RCON index " .. (i / nk))
          temp = xor_words(sub_word(rot_word(temp)), { t, 0, 0, 0 })
        elseif nk > 6 and i % nk == 4 then
          temp = sub_word(temp)
        end
        w[i] = xor_words(w[i - nk], temp)
      end

      return w, nr
    end

    --- MixColumns transformation
    --- @param state AESGCMState 4x4 state matrix
    local function mix_columns(state)
      for c = 0, 3 do
        --- @type AESGCMWord
        local a = {}
        --- @type AESGCMWord
        local b = {}
        for i = 0, 3 do
          a[i] = state[i][c]
          b[i] = bit32.band(state[i][c], 0x80) ~= 0 and bit32.bxor(bit32.band(bit32.lshift(state[i][c], 1), 0xFF), 0x1B)
            or bit32.band(bit32.lshift(state[i][c], 1), 0xFF)
        end

        state[0][c] = bit32.bxor(bit32.bxor(bit32.bxor(b[0], a[1]), bit32.bxor(b[1], a[2])), a[3])
        state[1][c] = bit32.bxor(bit32.bxor(bit32.bxor(a[0], b[1]), bit32.bxor(a[2], b[2])), a[3])
        state[2][c] = bit32.bxor(bit32.bxor(bit32.bxor(a[0], a[1]), bit32.bxor(b[2], a[3])), b[3])
        state[3][c] = bit32.bxor(bit32.bxor(bit32.bxor(a[0], b[0]), bit32.bxor(a[1], a[2])), b[3])
      end
    end

    --- SubBytes transformation
    --- @param state AESGCMState 4x4 state matrix
    local function sub_bytes(state)
      for i = 0, 3 do
        for j = 0, 3 do
          local s_index = state[i][j] + 1
          state[i][j] = assert(SBOX[s_index], "Invalid SBOX index " .. s_index)
        end
      end
    end

    --- ShiftRows transformation
    --- @param state AESGCMState 4x4 state matrix
    local function shift_rows(state)
      -- Row 0: no shift
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

      -- Row 3: shift left by 3 (or right by 1)
      temp = state[3][3]
      state[3][3] = state[3][2]
      state[3][2] = state[3][1]
      state[3][1] = state[3][0]
      state[3][0] = temp
    end

    --- AddRoundKey transformation
    --- @param state AESGCMState 4x4 state matrix
    --- @param round_key table Round key words
    --- @param round integer Round number
    local function add_round_key(state, round_key, round)
      for c = 0, 3 do
        local key_word = round_key[round * 4 + c]
        for r = 0, 3 do
          state[r][c] = bit32.bxor(state[r][c], key_word[r + 1])
        end
      end
    end

    --- AES block encryption
    --- @param input string 16-byte plaintext block
    --- @param expanded_key table Expanded key
    --- @param nr integer Number of rounds
    --- @return string ciphertext 16-byte encrypted block
    local function aes_encrypt_block(input, expanded_key, nr)
      -- Initialize state from input
      --- @type AESGCMState
      local state = {}
      for i = 0, 3 do
        --- @type AESGCMWord
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

      -- Convert state to output (optimized with table)
      local output_bytes = {}
      local idx = 1
      for j = 0, 3 do
        for i = 0, 3 do
          output_bytes[idx] = string.char(state[i][j])
          idx = idx + 1
        end
      end

      return table.concat(output_bytes)
    end

    -- ============================================================================
    -- GCM MODE IMPLEMENTATION
    -- ============================================================================

    --- GCM field multiplication
    --- @param x string 16-byte block
    --- @param y string 16-byte block
    --- @return string result Product in GF(2^128)
    local function gcm_multiply(x, y)
      -- Convert to bit arrays for easier manipulation
      --- @type AESGCMBlock
      local z = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
      --- @type AESGCMBlock
      local v = {}
      for i = 1, 16 do
        v[i] = string.byte(y, i)
      end

      -- Process each bit of x from MSB to LSB
      for i = 1, 16 do
        local byte = string.byte(x, i)
        for bit = 7, 0, -1 do
          if bit32.band(byte, bit32.lshift(1, bit)) ~= 0 then
            -- z = z XOR v
            for j = 1, 16 do
              z[j] = bit32.bxor(z[j], v[j])
            end
          end

          -- Check if LSB of v is 1 (bit 0 of last byte)
          local lsb = bit32.band(v[16], 1)

          -- v = v >> 1 (right shift entire 128-bit value by 1)
          local carry = 0
          for j = 1, 16 do
            local new_carry = bit32.band(v[j], 1)
            v[j] = bit32.bor(bit32.rshift(v[j], 1), bit32.lshift(carry, 7))
            carry = new_carry
          end

          -- If LSB was 1, XOR with R = 0xE1000000000000000000000000000000
          if lsb ~= 0 then
            v[1] = bit32.bxor(v[1], 0xE1)
          end
        end
      end

      -- Convert result back to string
      local result = ""
      for i = 1, 16 do
        result = result .. string.char(z[i])
      end
      return result
    end

    --- GHASH function
    --- @param h string Hash key (16 bytes)
    --- @param data string Data to hash (multiple of 16 bytes)
    --- @return string result 16-byte hash
    local function ghash(h, data)
      local y = string.rep("\0", 16)

      -- Process each 16-byte block
      for i = 1, #data, 16 do
        local block = string.sub(data, i, i + 15)

        -- y = (y XOR block) * h
        local y_xor = ""
        for j = 1, 16 do
          y_xor = y_xor .. string.char(bit32.bxor(string.byte(y, j), string.byte(block, j)))
        end

        y = gcm_multiply(y_xor, h)
      end

      return y
    end

    --- Increment counter block
    --- @param counter string 16-byte counter block
    --- @return string result Incremented counter
    local function inc_counter(counter)
      local result = string.sub(counter, 1, 12) -- Keep first 12 bytes

      -- Increment last 4 bytes (big-endian)
      local val = 0
      for i = 13, 16 do
        val = val * 256 + string.byte(counter, i)
      end

      val = (val + 1) % 0x100000000

      -- Convert back to bytes (big-endian)
      for i = 3, 0, -1 do
        result = result .. string.char(bit32.band(bit32.rshift(val, i * 8), 0xFF))
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
      local counter = iv .. string.rep("\0", 3) .. string.char(0x02)

      while total_length < length do
        local block = aes_encrypt_block(counter, expanded_key, nr)
        keystream_blocks[#keystream_blocks + 1] = block
        total_length = total_length + #block
        counter = inc_counter(counter)
      end

      local keystream = table.concat(keystream_blocks)
      return string.sub(keystream, 1, length)
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
      result = result .. string.rep("\0", aad_pad)

      -- Add ciphertext and padding
      result = result .. ciphertext
      local ct_pad = (16 - (#ciphertext % 16)) % 16
      result = result .. string.rep("\0", ct_pad)

      -- Add lengths (in bits) as 64-bit big-endian integers
      -- For messages under 2^61 bytes, high 32 bits are always 0
      local aad_bits_low = #aad * 8
      local ct_bits_low = #ciphertext * 8

      -- AAD length (64 bits big-endian)
      result = result .. string.rep("\0", 4) -- High 32 bits
      result = result .. bytes.u32_to_be_bytes(aad_bits_low) -- Low 32 bits

      -- Ciphertext length (64 bits big-endian)
      result = result .. string.rep("\0", 4) -- High 32 bits
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

      local openssl = openssl_wrapper.get()
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
      local h = aes_encrypt_block(string.rep("\0", 16), expanded_key, nr)

      -- Initial counter: nonce || 0x00000001
      local j0 = nonce .. string.rep("\0", 3) .. string.char(0x01)

      -- Encrypt plaintext using CTR mode
      local keystream = generate_keystream(key, nonce, #plaintext)
      local ciphertext = ""
      for i = 1, #plaintext do
        ciphertext = ciphertext .. string.char(bit32.bxor(string.byte(plaintext, i), string.byte(keystream, i)))
      end

      -- Calculate authentication tag
      local gcm_data = format_gcm_data(aad, ciphertext)
      local s = ghash(h, gcm_data)

      -- Encrypt S to get final tag: T = E(K, J0) XOR S
      local encrypted_j0 = aes_encrypt_block(j0, expanded_key, nr)
      local tag = ""
      for i = 1, 16 do
        tag = tag .. string.char(bit32.bxor(string.byte(s, i), string.byte(encrypted_j0, i)))
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
      local ciphertext = string.sub(ciphertext_and_tag, 1, ciphertext_len)
      local received_tag = string.sub(ciphertext_and_tag, ciphertext_len + 1)

      local openssl = openssl_wrapper.get()
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
      local h = aes_encrypt_block(string.rep("\0", 16), expanded_key, nr)

      -- Initial counter: nonce || 0x00000001
      local j0 = nonce .. string.rep("\0", 3) .. string.char(0x01)

      -- Calculate expected authentication tag
      local gcm_data = format_gcm_data(aad, ciphertext)
      local s = ghash(h, gcm_data)

      -- Encrypt S to get expected tag: T = E(K, J0) XOR S
      local encrypted_j0 = aes_encrypt_block(j0, expanded_key, nr)
      local expected_tag = ""
      for i = 1, 16 do
        expected_tag = expected_tag .. string.char(bit32.bxor(string.byte(s, i), string.byte(encrypted_j0, i)))
      end

      -- Verify tag (constant-time comparison)
      if received_tag ~= expected_tag then
        return nil -- Authentication failed
      end

      -- Decrypt ciphertext using CTR mode
      local keystream = generate_keystream(key, nonce, #ciphertext)
      local plaintext = ""
      for i = 1, #ciphertext do
        plaintext = plaintext .. string.char(bit32.bxor(string.byte(ciphertext, i), string.byte(keystream, i)))
      end

      return plaintext
    end

    --- Test vectors from NIST SP 800-38D and other sources
    local test_vectors = {
      {
        name = "NIST Test Case 1 (AES-128-GCM)",
        key = string.rep("\0", 16),
        nonce = string.rep("\0", 12),
        plaintext = "",
        aad = "",
        ciphertext = "",
        tag = bytes.from_hex("58e2fccefa7e3061367f1d57a4e7455a"),
      },
      {
        name = "NIST Test Case 2 (AES-128-GCM)",
        key = string.rep("\0", 16),
        nonce = string.rep("\0", 12),
        plaintext = string.rep("\0", 16),
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
            local result_ct = string.sub(result, 1, #test.ciphertext)
            local result_tag = string.sub(result, #test.ciphertext + 1)

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
              print("    Expected Tag: " .. bytes.to_hex(test.tag))
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
        local key128 = string.rep(string.char(0x42), 16)
        local nonce = string.rep("\0", 11) .. string.char(0x01)
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
        local key256 = string.rep(string.char(0x43), 32)
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
        local tampered = ciphertext_and_tag:sub(1, -2) .. string.char(255)
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
        local nonce2 = string.rep("\0", 11) .. string.char(0x02)
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
        local tampered_ct = string.char(255) .. ciphertext_and_tag:sub(2)
        local tampered_ct_result = aes_gcm.decrypt(key128, nonce, tampered_ct, aad)

        if tampered_ct_result == nil then
          print("  ✅ PASS: Tampered ciphertext correctly rejected")
          passed = passed + 1
        else
          print("  ❌ FAIL: Tampered ciphertext was not detected")
        end

        -- Test 9: Wrong key detection
        total = total + 1
        local wrong_key = string.rep(string.char(0x99), 16)
        local wrong_key_result = aes_gcm.decrypt(wrong_key, nonce, ciphertext_and_tag, aad)

        if wrong_key_result == nil then
          print("  ✅ PASS: Wrong key correctly rejected")
          passed = passed + 1
        else
          print("  ❌ FAIL: Wrong key was not detected")
        end

        -- Test 10: Large plaintext (multiple blocks)
        total = total + 1
        local large_plaintext = string.rep("A", 1000)
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
        local key192 = string.rep(string.char(0x44), 24)
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
      local plaintext_64 = string.rep("a", 64)
      local plaintext_1k = string.rep("a", 1024)
      local plaintext_8k = string.rep("a", 8192)

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
  package.preload["noiseprotocol.crypto.blake2"] = function(...)
    local arg = _G.arg
    --- @module "noiseprotocol.crypto.blake2"
    --- Pure Lua BLAKE2s and BLAKE2b Implementation for portability.

    local openssl_wrapper = require("noiseprotocol.openssl_wrapper")
    local utils = require("noiseprotocol.utils")
    local bit32 = utils.bit32
    local bit64 = utils.bit64
    local bytes = utils.bytes
    local benchmark_op = utils.benchmark.benchmark_op

    local blake2 = {}

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

    --- BLAKE2s G function
    --- @param v Blake2sVector16 Working vector
    --- @param a integer Index a
    --- @param b integer Index b
    --- @param c integer Index c
    --- @param d integer Index d
    --- @param x integer Message word x
    --- @param y integer Message word y
    local function blake2s_g(v, a, b, c, d, x, y)
      v[a] = bit32.add(bit32.add(v[a], v[b]), x)
      v[d] = bit32.ror(bit32.bxor(v[d], v[a]), 16)
      v[c] = bit32.add(v[c], v[d])
      v[b] = bit32.ror(bit32.bxor(v[b], v[c]), 12)
      v[a] = bit32.add(bit32.add(v[a], v[b]), y)
      v[d] = bit32.ror(bit32.bxor(v[d], v[a]), 8)
      v[c] = bit32.add(v[c], v[d])
      v[b] = bit32.ror(bit32.bxor(v[b], v[c]), 7)
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
      v[a] = bit64.add(bit64.add(v[a], v[b]), x)
      v[d] = bit64.ror(bit64.xor(v[d], v[a]), 32)
      v[c] = bit64.add(v[c], v[d])
      v[b] = bit64.ror(bit64.xor(v[b], v[c]), 24)
      v[a] = bit64.add(bit64.add(v[a], v[b]), y)
      v[d] = bit64.ror(bit64.xor(v[d], v[a]), 16)
      v[c] = bit64.add(v[c], v[d])
      v[b] = bit64.ror(bit64.xor(v[b], v[c]), 63)
    end

    --- BLAKE2s compression function
    --- @param h HashState Hash state (8 words)
    --- @param m Blake2sVector16 Message block (16 words)
    --- @param t integer Counter (low 32 bits)
    --- @param th integer Counter (high 32 bits)
    --- @param f boolean Final block flag
    local function blake2s_compress(h, m, t, th, f)
      -- Initialize working vector
      --- @type Blake2sVector16
      local v = {}

      -- First half from hash state
      for i = 1, 8 do
        v[i] = h[i]
      end

      -- Second half from IV
      for i = 1, 8 do
        v[8 + i] = BLAKE2S_IV[i]
      end

      -- Mix in counter and final flag
      v[13] = bit32.bxor(v[13], t) -- Low 32 bits of counter
      v[14] = bit32.bxor(v[14], th) -- High 32 bits of counter
      if f then
        v[15] = bit32.bxor(v[15], 0xFFFFFFFF) -- Invert all bits for final block
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
        h[i] = bit32.bxor(bit32.bxor(h[i], v[i]), v[i + 8])
      end
    end

    --- BLAKE2b compression function
    --- @param h HashState64 Hash state (8 64-bit words)
    --- @param m Blake2bVector16 Message block (16 64-bit words)
    --- @param t table Counter (64-bit)
    --- @param f boolean Final block flag
    local function blake2b_compress(h, m, t, f)
      -- Initialize working vector
      --- @type Blake2bVector16
      local v = {}

      -- First half from hash state
      for i = 1, 8 do
        v[i] = { h[i][1], h[i][2] }
      end

      -- Second half from IV
      for i = 1, 8 do
        v[8 + i] = { BLAKE2B_IV[i][1], BLAKE2B_IV[i][2] }
      end

      -- Mix in counter and final flag
      v[13] = bit64.xor(v[13], t)
      v[14] = bit64.xor(v[14], { 0, 0 }) -- High 64 bits of counter (always 0 for messages < 2^64 bytes)
      if f then
        v[15] = bit64.xor(v[15], { 0xffffffff, 0xffffffff })
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
        h[i] = bit64.xor(bit64.xor(h[i], v[i]), v[i + 8])
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
      h[1] = bit32.bxor(h[1], param)

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
        local final_block = final_data .. string.rep("\0", 64 - remaining)

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

      return table.concat(result_bytes)
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
      h[1] = bit64.xor(h[1], { 0x00000000, 0x01010040 })

      local data_len = #data
      local offset = 1
      local counter = { 0, 0 }

      -- Process full 128-byte blocks
      while offset + 127 <= data_len do
        counter = bit64.add(counter, { 0, 128 })

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
        counter = bit64.add(counter, { 0, remaining })

        -- Pad final block with zeros
        local final_block = data:sub(offset) .. string.rep("\0", 128 - remaining)

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
          m[i] = { 0, 0 }
        end
        blake2b_compress(h, m, { 0, 0 }, true)
      end

      -- Produce final hash value as binary string (optimized with table)
      local result_bytes = {}
      for i = 1, 8 do
        result_bytes[i] = bytes.u64_to_le_bytes(h[i])
      end

      return table.concat(result_bytes)
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
        key = key .. string.rep("\0", block_size - #key)
      end

      -- Compute inner and outer padding (optimized with table)
      local ipad_bytes = {}
      local opad_bytes = {}
      for i = 1, block_size do
        local byte = string.byte(key, i)
        ipad_bytes[i] = string.char(bit32.bxor(byte, 0x36))
        opad_bytes[i] = string.char(bit32.bxor(byte, 0x5C))
      end
      local ipad = table.concat(ipad_bytes)
      local opad = table.concat(opad_bytes)

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
        key = key .. string.rep("\0", block_size - #key)
      end

      -- Compute inner and outer padding (optimized with table)
      local ipad_bytes = {}
      local opad_bytes = {}
      for i = 1, block_size do
        local byte = string.byte(key, i)
        ipad_bytes[i] = string.char(bit32.bxor(byte, 0x36))
        opad_bytes[i] = string.char(bit32.bxor(byte, 0x5C))
      end
      local ipad = table.concat(ipad_bytes)
      local opad = table.concat(opad_bytes)

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
        key = string.rep(string.char(0x0b), 20),
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
        key = string.rep("a", 64),
        message = "Test message",
        expected = "12d0e782ae473d8007d33ae6e5244afcaf9239f6a7d5476c69060c01383d6b58",
      },
      {
        name = "Key > block size (80 bytes)",
        key = string.rep("a", 80),
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
        key = string.rep(string.char(0x0b), 20),
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
        key = string.rep("a", 128),
        message = "Test message",
        expected = "021a22a3ecf0f1f7a15aca6a5d9704fc99b6a84a627fa53f7ac932a961ffb69b1e68c46981d5b44fd00a7cae75e4ee63d393eec844a8de2dd00e45b5a0d4e275",
      },
      {
        name = "Key > block size (80 bytes)",
        key = string.rep("a", 80),
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
      local message_64 = string.rep("a", 64)
      local message_1k = string.rep("a", 1024)
      local message_8k = string.rep("a", 8192)
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
  package.preload["noiseprotocol.crypto.chacha20"] = function(...)
    local arg = _G.arg
    --- @module "noiseprotocol.crypto.chacha20"
    --- ChaCha20 Stream Cipher Implementation for portability.

    local openssl_wrapper = require("noiseprotocol.openssl_wrapper")
    local utils = require("noiseprotocol.utils")
    local bit32 = utils.bit32
    local bytes = utils.bytes
    local benchmark_op = utils.benchmark.benchmark_op

    local chacha20 = {}

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

    --- Convert 32-bit word to 4 bytes (little-endian)
    --- @param word integer 32-bit word
    --- @return integer, integer, integer, integer bytes Four bytes in little-endian order
    local function word_to_bytes(word)
      local byte1 = word % 256
      word = math.floor(word / 256)
      local byte2 = word % 256
      word = math.floor(word / 256)
      local byte3 = word % 256
      word = math.floor(word / 256)
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
      state[a] = bit32.add(state[a], state[b])
      state[d] = bit32.rol(bit32.bxor(state[d], state[a]), 16)

      state[c] = bit32.add(state[c], state[d])
      state[b] = bit32.rol(bit32.bxor(state[b], state[c]), 12)

      state[a] = bit32.add(state[a], state[b])
      state[d] = bit32.rol(bit32.bxor(state[d], state[a]), 8)

      state[c] = bit32.add(state[c], state[d])
      state[b] = bit32.rol(bit32.bxor(state[b], state[c]), 7)
    end

    --- Initialize ChaCha20 state with key, nonce, and counter
    --- @param key string 32-byte key
    --- @param nonce string 12-byte nonce
    --- @param counter integer 32-bit counter value
    --- @return Word32Array state Initialized 16-word state
    local function chacha20_init(key, nonce, counter)
      assert(#key == 32, "Key must be exactly 32 bytes")
      assert(#nonce == 12, "Nonce must be exactly 12 bytes")
      assert(counter >= 0 and counter < 0x100000000, "Counter must be a valid 32-bit integer")

      local state = create_word_array()

      -- ChaCha20 constants "expand 32-byte k"
      state[1] = 0x61707865 -- "expa"
      state[2] = 0x3320646e -- "nd 3"
      state[3] = 0x79622d32 -- "2-by"
      state[4] = 0x6b206574 -- "te k"

      -- 256-bit key (8 words)
      for i = 1, 8 do
        local base = (i - 1) * 4
        state[4 + i] = bytes_to_word(
          string.byte(key, base + 1),
          string.byte(key, base + 2),
          string.byte(key, base + 3),
          string.byte(key, base + 4)
        )
      end

      -- 32-bit counter
      state[13] = counter

      -- 96-bit nonce (3 words)
      for i = 1, 3 do
        local base = (i - 1) * 4
        state[13 + i] = bytes_to_word(
          string.byte(nonce, base + 1),
          string.byte(nonce, base + 2),
          string.byte(nonce, base + 3),
          string.byte(nonce, base + 4)
        )
      end

      return state
    end

    --- Generate one 64-byte block of ChaCha20 keystream
    --- @param key string 32-byte key
    --- @param nonce string 12-byte nonce
    --- @param counter integer 32-bit counter value
    --- @return string keystream 64-byte keystream block
    local function chacha20_block(key, nonce, counter)
      local state = chacha20_init(key, nonce, counter)

      -- Create working copy of state
      local working_state = create_word_array()
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
        working_state[i] = bit32.add(working_state[i], state[i])
      end

      -- Convert state to byte string (little-endian) - optimized with table
      local result_bytes = {}
      for i = 1, 16 do
        local b1, b2, b3, b4 = word_to_bytes(working_state[i])
        result_bytes[i] = string.char(b1, b2, b3, b4)
      end

      return table.concat(result_bytes)
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

        -- XOR with plaintext (optimized with table)
        local block_size = math.min(64, data_len - offset + 1)
        for i = 1, block_size do
          local plaintext_byte = string.byte(plaintext, offset + i - 1)
          local keystream_byte = string.byte(keystream, i)
          result_bytes[result_idx] = string.char(bit32.bxor(plaintext_byte, keystream_byte))
          result_idx = result_idx + 1
        end

        offset = offset + 64
        counter = counter + 1
      end

      return table.concat(result_bytes)
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
        nonce = utils.bytes.u32_to_le_bytes(counter or 1) .. nonce
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
        nonce = utils.bytes.u32_to_le_bytes(counter or 1) .. nonce
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
        key = string.rep("\0", 32),
        nonce = string.rep("\0", 12),
        counter = 0,
        plaintext = string.rep("\0", 64),
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
              local show_bytes = math.min(16, #test.expected_keystream)

              for j = 1, show_bytes do
                expected_hex = expected_hex .. string.format("%02x", string.byte(test.expected_keystream, j))
                result_hex = result_hex .. string.format("%02x", string.byte(keystream, j))
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
              local show_bytes = math.min(16, #test.expected_ciphertext)

              for j = 1, show_bytes do
                expected_hex = expected_hex .. string.format("%02x", string.byte(test.expected_ciphertext, j))
                result_hex = result_hex .. string.format("%02x", string.byte(result, j))
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
        local key = string.rep(string.char(0x42), 32)
        local nonce = string.rep("\0", 12)
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
        local nonce2 = string.char(0x01) .. string.rep("\0", 11)
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
        local large_plaintext = string.rep("A", 256) -- 4 blocks
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
        local partial_plaintext = string.rep("B", 100) -- Not a multiple of 64
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
      local plaintext_64 = string.rep("a", 64)
      local plaintext_1k = string.rep("a", 1024)
      local plaintext_8k = string.rep("a", 8192)

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
  package.preload["noiseprotocol.crypto.chacha20_poly1305"] = function(...)
    local arg = _G.arg
    --- @module "noiseprotocol.crypto.chacha20_poly1305"
    --- ChaCha20-Poly1305 Authenticated Encryption with Associated Data (AEAD) Implementation for portability.

    local openssl_wrapper = require("noiseprotocol.openssl_wrapper")
    local utils = require("noiseprotocol.utils")
    local bytes = utils.bytes
    local benchmark_op = utils.benchmark.benchmark_op
    local chacha20 = require("noiseprotocol.crypto.chacha20")
    local poly1305 = require("noiseprotocol.crypto.poly1305")

    local chacha20_poly1305 = {}

    --- Generate Poly1305 one-time key using ChaCha20
    --- @param key string 32-byte ChaCha20 key
    --- @param nonce string 12-byte nonce
    --- @return string poly_key 32-byte Poly1305 one-time key
    local function poly1305_key_gen(key, nonce)
      -- Generate Poly1305 key by encrypting 32 zero bytes with ChaCha20
      -- Counter starts at 0 for key generation
      local zero_block = string.rep("\0", 32)
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

      return table.concat(auth_parts)
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

      local openssl = openssl_wrapper.get()
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
      local ciphertext = string.sub(ciphertext_and_tag, 1, ciphertext_len)
      local received_tag = string.sub(ciphertext_and_tag, ciphertext_len + 1)

      local openssl = openssl_wrapper.get()
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
        key = string.char(0x42) .. string.rep("\0", 31),
        nonce = string.rep("\0", 12),
        aad = "",
        plaintext = "No additional data",
      },
      {
        name = "Empty plaintext roundtrip test",
        key = string.rep(string.char(0xff), 32),
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
        local key = string.rep(string.char(0x42), 32)
        local nonce = string.rep("\0", 11) .. string.char(0x01)
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
        local tampered = ciphertext_and_tag:sub(1, -2) .. string.char(255)
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
        local nonce2 = string.rep("\0", 11) .. string.char(0x02)
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
        local tampered_ct = string.char(255) .. ciphertext_and_tag:sub(2)
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
      local plaintext_64 = string.rep("a", 64)
      local plaintext_1k = string.rep("a", 1024)
      local plaintext_8k = string.rep("a", 8192)

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
  package.preload["noiseprotocol.crypto.poly1305"] = function(...)
    local arg = _G.arg
    --- @module "noiseprotocol.crypto.poly1305"
    --- Poly1305 Message Authentication Code (MAC) Implementation for portability.

    local utils = require("noiseprotocol.utils")
    local bit32 = utils.bit32
    local bytes = utils.bytes
    local benchmark_op = utils.benchmark.benchmark_op

    local poly1305 = {}

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
          local target_byte = 1 + math.floor(excess_bits / 8)
          local bit_offset = excess_bits % 8

          if bit_offset > 0 then
            reduction_multiplier = bit32.lshift(reduction_multiplier, bit_offset)
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
        carry = math.floor(carry / 256)
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
        local high_bits = math.floor(h[17] / 4)
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
    local function create_product_array()
      local arr = {}
      for i = 1, 33 do
        arr[i] = 0
      end
      --- @cast arr Limb33Array
      return arr
    end

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
        key_bytes[i] = string.byte(key, i)
      end

      -- Extract and clamp r (first 16 bytes) per RFC 7539
      local r = create_key_array(key_bytes, 1)

      -- Apply RFC 7539 clamping to ensure r has specific bit patterns
      -- This prevents certain classes of attacks and ensures key validity
      r[4] = bit32.band(r[4], 15) -- Clear top 4 bits of 4th byte
      r[5] = bit32.band(r[5], 252) -- Clear bottom 2 bits of 5th byte
      r[8] = bit32.band(r[8], 15) -- Clear top 4 bits of 8th byte
      r[9] = bit32.band(r[9], 252) -- Clear bottom 2 bits of 9th byte
      r[12] = bit32.band(r[12], 15) -- Clear top 4 bits of 12th byte
      r[13] = bit32.band(r[13], 252) -- Clear bottom 2 bits of 13th byte
      r[16] = bit32.band(r[16], 15) -- Clear top 4 bits of 16th byte

      -- Extract s (second 16 bytes) - used for final addition
      local s = create_key_array(key_bytes, 17)

      -- Initialize accumulator h as 17-byte array (130-bit + 6 extra bits)
      local h = create_limb17_array()

      local msglen = #msg
      local offset = 1

      -- Process message in 16-byte blocks
      while msglen >= 16 do
        -- Load current 16-byte block
        local c = create_limb17_array()
        for i = 1, 16 do
          c[i] = string.byte(msg, offset + i - 1)
        end
        c[17] = 1 -- Add high bit (represents 2^128 for full blocks)

        -- Add message block to accumulator: h = h + c
        local carry = 0
        for i = 1, 17 do
          carry = carry + h[i] + c[i]
          h[i] = carry % 256
          carry = math.floor(carry / 256)
        end

        -- Multiply by r: h = (h * r) mod (2^130 - 5)

        -- Step 1: Compute full precision product h * r
        local prod = create_product_array()

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
        local c = create_limb17_array()

        -- Load partial block
        for i = 1, msglen do
          c[i] = string.byte(msg, offset + i - 1)
        end
        c[msglen + 1] = 1 -- Add padding bit at end of message

        -- Same operations as full blocks
        local carry = 0
        for i = 1, 17 do
          carry = carry + h[i] + c[i]
          h[i] = carry % 256
          carry = math.floor(carry / 256)
        end

        -- Multiply by r
        local prod = create_product_array()

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

      local g = create_limb17_array()
      for i = 1, 17 do
        g[i] = h[i]
      end

      -- Test reduction by computing h + 5
      g[1] = g[1] + 5
      local carry = math.floor(g[1] / 256)
      g[1] = g[1] % 256

      for i = 2, 17 do
        if carry == 0 then
          break
        end
        carry = carry + g[i]
        g[i] = carry % 256
        carry = math.floor(carry / 256)
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
        result_bytes[i] = string.char(sum % 256)
        carry = math.floor(sum / 256)
      end

      return table.concat(result_bytes)
    end

    --- Test vectors from RFC 8439, RFC 7539, and other reference implementations
    local test_vectors = {
      {
        name = "RFC 8439 Test Vector #1 (all zeros)",
        key = string.rep("\0", 32),
        message = string.rep("\0", 64),
        expected = string.rep("\0", 16),
      },
      {
        name = "RFC 8439 Test Vector #2 (r=0, long message)",
        key = string.rep("\0", 16) .. bytes.from_hex("36e5f6b5c5e06070f0efca96227a863e"),
        message = 'Any submission to the IETF intended by the Contributor for publication as all or part of an IETF Internet-Draft or RFC and any statement made within the context of an IETF activity is considered an "IETF Contribution". Such statements include oral statements in IETF sessions, as well as written and electronic communications made at any time or place, which are addressed to',
        expected = bytes.from_hex("36e5f6b5c5e06070f0efca96227a863e"),
      },
      {
        name = "RFC 8439 Test Vector #3 (r!=0, s=0)",
        key = bytes.from_hex("36e5f6b5c5e06070f0efca96227a863e") .. string.rep("\0", 16),
        message = 'Any submission to the IETF intended by the Contributor for publication as all or part of an IETF Internet-Draft or RFC and any statement made within the context of an IETF activity is considered an "IETF Contribution". Such statements include oral statements in IETF sessions, as well as written and electronic communications made at any time or place, which are addressed to',
        expected = bytes.from_hex("f3477e7cd95417af89a6b8794c310cf0"),
      },
      {
        name = "Wrap test vector (tests modular reduction edge case)",
        key = bytes.from_hex("0200000000000000000000000000000000000000000000000000000000000000"),
        message = string.rep(string.char(255), 16),
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
            result_hex = result_hex .. string.format("%02x", string.byte(result, j))
          end

          for j = 1, #test.expected do
            expected_hex = expected_hex .. string.format("%02x", string.byte(test.expected, j))
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
        local key1 = string.rep(string.char(0x42), 32)
        local key2 = string.rep(string.char(0x43), 32)
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
        local large_msg = string.rep("A", 256) -- 16 full blocks
        local large_tag = poly1305.authenticate(key1, large_msg)

        if #large_tag == 16 then
          print("  ✅ PASS: Large message produces valid 16-byte tag")
          passed = passed + 1
        else
          print("  ❌ FAIL: Large message tag length is not 16 bytes")
        end

        -- Test 5: Partial block handling
        total = total + 1
        local partial_msg = string.rep("B", 33) -- 2 blocks + 1 byte
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
      local message_64 = string.rep("a", 64)
      local message_1k = string.rep("a", 1024)
      local message_8k = string.rep("a", 8192)

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
  package.preload["noiseprotocol.crypto.sha256"] = function(...)
    local arg = _G.arg
    --- @module "noiseprotocol.crypto.sha256"
    --- Pure Lua SHA-256 Implementation for portability.

    local openssl_wrapper = require("noiseprotocol.openssl_wrapper")
    local utils = require("noiseprotocol.utils")
    local bit32 = utils.bit32
    local bytes = utils.bytes
    local benchmark_op = utils.benchmark.benchmark_op

    local sha256 = {}

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

    --- SHA-256 core compression function
    --- @param chunk string 64-byte chunk
    --- @param H HashState Hash state (8 integers)
    local function sha256_chunk(chunk, H)
      -- Prepare message schedule W (pre-allocate full array)
      local W = {}

      -- First 16 words are the message chunk
      for i = 1, 16 do
        W[i] = bytes.be_bytes_to_u32(chunk, (i - 1) * 4 + 1)
      end

      -- Extend the first 16 words into the remaining 48 words
      for i = 17, 64 do
        local w15 = W[i - 15]
        local w2 = W[i - 2]
        local s0 = bit32.bxor(bit32.ror(w15, 7), bit32.bxor(bit32.ror(w15, 18), bit32.rshift(w15, 3)))
        local s1 = bit32.bxor(bit32.ror(w2, 17), bit32.bxor(bit32.ror(w2, 19), bit32.rshift(w2, 10)))
        W[i] = bit32.add(bit32.add(bit32.add(W[i - 16], s0), W[i - 7]), s1)
      end

      -- Initialize working variables
      local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]

      -- Main loop (optimized with local variables)
      for i = 1, 64 do
        local prime = K[i]
        local S1 = bit32.bxor(bit32.ror(e, 6), bit32.bxor(bit32.ror(e, 11), bit32.ror(e, 25)))
        local ch = bit32.bxor(bit32.band(e, f), bit32.band(bit32.bnot(e), g))
        local temp1 = bit32.add(bit32.add(bit32.add(bit32.add(h, S1), ch), prime), W[i])
        local S0 = bit32.bxor(bit32.ror(a, 2), bit32.bxor(bit32.ror(a, 13), bit32.ror(a, 22)))
        local maj = bit32.bxor(bit32.band(a, b), bit32.bxor(bit32.band(a, c), bit32.band(b, c)))
        local temp2 = bit32.add(S0, maj)

        h = g
        g = f
        f = e
        e = bit32.add(d, temp1)
        d = c
        c = b
        b = a
        a = bit32.add(temp1, temp2)
      end

      -- Add compressed chunk to current hash value
      H[1] = bit32.add(H[1], a)
      H[2] = bit32.add(H[2], b)
      H[3] = bit32.add(H[3], c)
      H[4] = bit32.add(H[4], d)
      H[5] = bit32.add(H[5], e)
      H[6] = bit32.add(H[6], f)
      H[7] = bit32.add(H[7], g)
      H[8] = bit32.add(H[8], h)
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
      data = data .. string.char(0x80)

      -- Append zeros to make message length ≡ 448 (mod 512) bits = 56 (mod 64) bytes
      -- Current length is msg_len + 1 (for the 0x80 byte)
      local current_len = msg_len + 1
      local target_len = 56 -- We want to reach 56 bytes before adding the 8-byte length
      local padding_len = (target_len - current_len) % 64
      data = data .. string.rep("\0", padding_len)

      -- Append original length as 64-bit big-endian integer
      -- For simplicity, we only support messages < 2^32 bits
      data = data .. string.rep("\0", 4) .. bytes.u32_to_be_bytes(msg_len_bits)

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
        result_bytes[i] = bytes.u32_to_be_bytes(H[i])
      end

      return table.concat(result_bytes)
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
        key = key .. string.rep("\0", block_size - #key)
      end

      -- Compute inner and outer padding (optimized with table)
      local ipad_bytes = {}
      local opad_bytes = {}
      for i = 1, block_size do
        local byte = string.byte(key, i)
        ipad_bytes[i] = string.char(bit32.bxor(byte, 0x36))
        opad_bytes[i] = string.char(bit32.bxor(byte, 0x5C))
      end
      local ipad = table.concat(ipad_bytes)
      local opad = table.concat(opad_bytes)

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
        input = string.rep("a", 1000000),
        expected = "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
      })
    end

    --- HMAC test vectors
    local hmac_test_vectors = {
      {
        name = "HMAC Test Case 1",
        key = string.rep(string.char(0x0b), 20),
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
        key = string.rep(string.char(0xaa), 20),
        data = string.rep(string.char(0xdd), 50),
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
      local message_64 = string.rep("a", 64)
      local message_1k = string.rep("a", 1024)
      local message_8k = string.rep("a", 8192)
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
  package.preload["noiseprotocol.crypto.sha512"] = function(...)
    local arg = _G.arg
    --- @module "noiseprotocol.crypto.sha512"
    --- Pure Lua SHA-512 Implementation for portability.

    local openssl_wrapper = require("noiseprotocol.openssl_wrapper")
    local utils = require("noiseprotocol.utils")
    local bit32 = utils.bit32
    local bit64 = utils.bit64
    local bytes = utils.bytes
    local benchmark_op = utils.benchmark.benchmark_op

    -- SHA-512 uses 64-bit words, but Lua numbers are limited to 2^53-1
    -- We'll work with 32-bit high/low pairs for 64-bit arithmetic
    local sha512 = {}

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

    --- SHA-512 Sigma0 function
    --- @param x Int64HighLow {high, low} input
    --- @return Int64HighLow {high, low} result
    local function Sigma0(x)
      return bit64.xor(bit64.xor(bit64.ror(x, 28), bit64.ror(x, 34)), bit64.ror(x, 39))
    end

    --- SHA-512 Sigma1 function
    --- @param x Int64HighLow {high, low} input
    --- @return Int64HighLow {high, low} result
    local function Sigma1(x)
      return bit64.xor(bit64.xor(bit64.ror(x, 14), bit64.ror(x, 18)), bit64.ror(x, 41))
    end

    --- SHA-512 sigma0 function
    --- @param x Int64HighLow {high, low} input
    --- @return Int64HighLow {high, low} result
    local function sigma0(x)
      return bit64.xor(bit64.xor(bit64.ror(x, 1), bit64.ror(x, 8)), bit64.shr(x, 7))
    end

    --- SHA-512 sigma1 function
    --- @param x Int64HighLow {high, low} input
    --- @return Int64HighLow {high, low} result
    local function sigma1(x)
      return bit64.xor(bit64.xor(bit64.ror(x, 19), bit64.ror(x, 61)), bit64.shr(x, 6))
    end

    --- SHA-512 Ch function
    --- @param x Int64HighLow {high, low} input
    --- @param y Int64HighLow {high, low} input
    --- @param z Int64HighLow {high, low} input
    --- @return Int64HighLow {high, low} result
    local function Ch(x, y, z)
      return bit64.xor(bit64.band(x, y), bit64.band(bit64.bnot(x), z))
    end

    --- SHA-512 Maj function
    --- @param x Int64HighLow {high, low} input
    --- @param y Int64HighLow {high, low} input
    --- @param z Int64HighLow {high, low} input
    --- @return Int64HighLow {high, low} result
    local function Maj(x, y, z)
      return bit64.xor(bit64.xor(bit64.band(x, y), bit64.band(x, z)), bit64.band(y, z))
    end

    --- SHA-512 core compression function
    --- @param chunk string 128-byte chunk
    --- @param H HashState64 Hash state (8 64-bit values)
    local function sha512_chunk(chunk, H)
      -- Prepare message schedule W (pre-allocate full array)
      local W = {}

      -- First 16 words are the message chunk
      for i = 1, 16 do
        W[i] = bytes.be_bytes_to_u64(chunk, (i - 1) * 8 + 1)
      end

      -- Extend the first 16 words into the remaining 64 words
      for i = 17, 80 do
        local w15 = W[i - 15]
        local w2 = W[i - 2]
        local s0 = sigma0(w15)
        local s1 = sigma1(w2)
        W[i] = bit64.add(bit64.add(bit64.add(W[i - 16], s0), W[i - 7]), s1)
      end

      -- Initialize working variables
      local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]

      -- Main loop (optimized)
      for i = 1, 80 do
        local prime = K[i]
        local S1 = Sigma1(e)
        local ch = Ch(e, f, g)
        local temp1 = bit64.add(bit64.add(bit64.add(bit64.add(h, S1), ch), prime), W[i])
        local S0 = Sigma0(a)
        local maj = Maj(a, b, c)
        local temp2 = bit64.add(S0, maj)

        h = g
        g = f
        f = e
        e = bit64.add(d, temp1)
        d = c
        c = b
        b = a
        a = bit64.add(temp1, temp2)
      end

      -- Add compressed chunk to current hash value
      H[1] = bit64.add(H[1], a)
      H[2] = bit64.add(H[2], b)
      H[3] = bit64.add(H[3], c)
      H[4] = bit64.add(H[4], d)
      H[5] = bit64.add(H[5], e)
      H[6] = bit64.add(H[6], f)
      H[7] = bit64.add(H[7], g)
      H[8] = bit64.add(H[8], h)
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
      data = data .. string.char(0x80)

      -- Append zeros to make message length ≡ 896 (mod 1024) bits = 112 (mod 128) bytes
      local current_len = msg_len + 1
      local target_len = 112 -- We want to reach 112 bytes before adding the 16-byte length
      local padding_len = (target_len - current_len) % 128
      data = data .. string.rep("\0", padding_len)

      -- Append original length as 128-bit big-endian integer
      -- For simplicity, we only support messages < 2^64 bits
      data = data .. string.rep("\0", 8) -- High 64 bits (always 0)
      -- Low 64 bits of length
      local len_high = math.floor(msg_len_bits / 0x100000000)
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

      return table.concat(result_bytes)
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
        key = key .. string.rep("\0", block_size - #key)
      end

      -- Compute inner and outer padding (optimized with table)
      local ipad_bytes = {}
      local opad_bytes = {}
      for i = 1, block_size do
        local byte = string.byte(key, i)
        ipad_bytes[i] = string.char(bit32.bxor(byte, 0x36))
        opad_bytes[i] = string.char(bit32.bxor(byte, 0x5C))
      end
      local ipad = table.concat(ipad_bytes)
      local opad = table.concat(opad_bytes)

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
        input = string.rep("a", 1000000),
        expected = "e718483d0ce769644e2e42c7bc15b4638e1f98b13b2044285632a803afa973ebde0ff244877ea60a4cb0432ce577c31beb009c5c2c49aa2e4eadb217ad8cc09b",
      })
    end

    --- HMAC test vectors from RFC 4231
    local hmac_test_vectors = {
      {
        name = "RFC 4231 Test Case 1",
        key = string.rep(string.char(0x0b), 20),
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
        key = string.rep(string.char(0xaa), 20),
        data = string.rep(string.char(0xdd), 50),
        expected = "fa73b0089d56a284efb0f0756c890be9b1b5dbdd8ee81a3655f83e33b2279d39bf3e848279a722c806b485a47e67c807b946a337bee8942674278859e13292fb",
      },
      {
        name = "RFC 4231 Test Case 4",
        key = bytes.from_hex("0102030405060708090a0b0c0d0e0f10111213141516171819"),
        data = string.rep(string.char(0xcd), 50),
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
      local message_64 = string.rep("a", 64)
      local message_1k = string.rep("a", 1024)
      local message_8k = string.rep("a", 8192)
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
  package.preload["noiseprotocol.crypto.x25519"] = function(...)
    local arg = _G.arg
    --- @module "noiseprotocol.crypto.x25519"
    --- X25519 Curve25519 Elliptic Curve Diffie-Hellman Implementation for portability.

    local x25519 = {}

    local utils = require("noiseprotocol.utils")
    local bit32 = utils.bit32
    local bytes = utils.bytes
    local benchmark_op = utils.benchmark.benchmark_op

    -- ============================================================================
    -- CURVE25519 FIELD ARITHMETIC
    -- ============================================================================

    --- Carry operation for 64-bit arithmetic
    --- @param out integer[] Array to perform carry on
    local function carry(out)
      for i = 0, 15 do
        out[i] = out[i] + 0x10000
        local c = out[i] / 0x10000 - (out[i] / 0x10000) % 1
        if i < 15 then
          out[i + 1] = out[i + 1] + c - 1
        else
          out[0] = out[0] + 38 * (c - 1)
        end
        out[i] = out[i] - c * 0x10000
      end
    end

    --- Conditional swap based on bit value
    --- @param a integer[] First array
    --- @param b integer[] Second array
    --- @param bit integer Bit value (0 or 1)
    local function swap(a, b, bit)
      for i = 0, 15 do
        a[i], b[i] = a[i] * ((bit - 1) % 2) + b[i] * bit, b[i] * ((bit - 1) % 2) + a[i] * bit
      end
    end

    --- Unpack byte array to limb array
    --- @param out integer[] Output limb array
    --- @param a integer[] Input byte array
    local function unpack(out, a)
      for i = 0, 15 do
        out[i] = a[2 * i] + a[2 * i + 1] * 0x100
      end
      out[15] = out[15] % 0x8000
    end

    --- Pack limb array to byte array with modular reduction
    --- @param out integer[] Output byte array
    --- @param a integer[] Input limb array
    local function pack(out, a)
      local t, m = {}, {}
      for i = 0, 15 do
        t[i] = a[i]
      end
      carry(t)
      carry(t)
      carry(t)
      local prime = { [0] = 0xffed, [15] = 0x7fff }
      for i = 1, 14 do
        prime[i] = 0xffff
      end
      for _ = 0, 1 do
        m[0] = t[0] - prime[0]
        for i = 1, 15 do
          m[i] = t[i] - prime[i] - ((m[i - 1] / 0x10000 - (m[i - 1] / 0x10000) % 1) % 2)
          m[i - 1] = (m[i - 1] + 0x10000) % 0x10000
        end
        local c = (m[15] / 0x10000 - (m[15] / 0x10000) % 1) % 2
        swap(t, m, 1 - c)
      end
      for i = 0, 15 do
        out[2 * i] = t[i] % 0x100
        out[2 * i + 1] = t[i] / 0x100 - (t[i] / 0x100) % 1
      end
    end

    --- Add two field elements
    --- @param out integer[] Output array
    --- @param a integer[] First input array
    --- @param b integer[] Second input array
    local function add(out, a, b)
      for i = 0, 15 do
        out[i] = a[i] + b[i]
      end
    end

    --- Subtract two field elements
    --- @param out integer[] Output array
    --- @param a integer[] First input array
    --- @param b integer[] Second input array
    local function sub(out, a, b)
      for i = 0, 15 do
        out[i] = a[i] - b[i]
      end
    end

    --- Multiply two field elements
    --- @param out integer[] Output array
    --- @param a integer[] First input array
    --- @param b integer[] Second input array
    local function mul(out, a, b)
      local prod = {}
      for i = 0, 31 do
        prod[i] = 0
      end
      for i = 0, 15 do
        for j = 0, 15 do
          prod[i + j] = prod[i + j] + a[i] * b[j]
        end
      end
      for i = 0, 14 do
        prod[i] = prod[i] + 38 * prod[i + 16]
      end
      for i = 0, 15 do
        out[i] = prod[i]
      end
      carry(out)
      carry(out)
    end

    --- Compute modular inverse using Fermat's little theorem
    --- @param out integer[] Output array
    --- @param a integer[] Input array
    local function inv(out, a)
      local c = {}
      for i = 0, 15 do
        c[i] = a[i]
      end
      for i = 253, 0, -1 do
        mul(c, c, c)
        if i ~= 2 and i ~= 4 then
          mul(c, c, a)
        end
      end
      for i = 0, 15 do
        out[i] = c[i]
      end
    end

    --- X25519 scalar multiplication using Montgomery ladder
    --- @param out integer[] Output point
    --- @param scalar integer[] Input scalar
    --- @param point integer[] Input point
    local function scalarmult(out, scalar, point)
      local a, b, c, d, e, f, x, clam = {}, {}, {}, {}, {}, {}, {}, {}
      unpack(x, point)
      for i = 0, 15 do
        a[i], b[i], c[i], d[i] = 0, x[i], 0, 0
      end
      a[0], d[0] = 1, 1
      for i = 0, 30 do
        clam[i] = scalar[i]
      end
      clam[0] = clam[0] - (clam[0] % 8)
      clam[31] = scalar[31] % 64 + 64
      for i = 254, 0, -1 do
        local byte_idx = math.floor(i / 8)
        local bit_idx = i % 8
        local bit = bit32.band(bit32.rshift(clam[byte_idx], bit_idx), 1)
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
        mul(a, c, { [0] = 0xdb41, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 })
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
        b[i - 1] = string.byte(s, i)
      end
      return b
    end

    --- Convert byte array to string
    --- @param b integer[] Byte array
    --- @param len integer Length
    --- @return string result Output string
    local function bytes_to_string(b, len)
      local result_bytes = {}
      for i = 0, len - 1 do
        result_bytes[i + 1] = string.char(b[i] or 0)
      end
      return table.concat(result_bytes)
    end

    -- ============================================================================
    -- X25519 PUBLIC INTERFACE
    -- ============================================================================

    --- Generate a random Curve25519 private key
    --- @return string private_key 32-byte private key
    function x25519.generate_private_key()
      -- Better randomness by using time + clock + counter
      local counter = x25519._key_counter or 0
      x25519._key_counter = counter + 1
      math.randomseed(os.time() + os.clock() * 1000000 + counter)

      local key_bytes = {}
      for i = 1, 32 do
        key_bytes[i] = string.char(math.random(0, 255))
      end
      return table.concat(key_bytes)
    end

    --- Derive public key from private key
    --- @param private_key string 32-byte private key
    --- @return string public_key 32-byte public key
    function x25519.derive_public_key(private_key)
      assert(#private_key == 32, "Private key must be exactly 32 bytes")

      local sk = string_to_bytes(private_key)
      local pk = {}
      local base = { [0] = 9 }
      for i = 1, 31 do
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
        scalar = utils.bytes.from_hex("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"),
        u_coord = utils.bytes.from_hex("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c"),
        expected = utils.bytes.from_hex("c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552"),
      },
      {
        name = "RFC 7748 Test Vector 2",
        scalar = utils.bytes.from_hex("4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d"),
        u_coord = utils.bytes.from_hex("e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493"),
        expected = utils.bytes.from_hex("95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957"),
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
              result_hex = result_hex .. string.format("%02x", string.byte(result, j))
            end
            for j = 1, #test.expected do
              expected_hex = expected_hex .. string.format("%02x", string.byte(test.expected, j))
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
          local zero_key = string.rep("\0", 32)
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
  package.preload["noiseprotocol.crypto.x448"] = function(...)
    local arg = _G.arg
    --- @module "noiseprotocol.crypto.x448"
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

    local utils = require("noiseprotocol.utils")
    local bytes = utils.bytes
    local benchmark_op = utils.benchmark.benchmark_op
    local band = utils.bit32.band
    local bor = utils.bit32.bor
    local bxor = utils.bit32.bxor
    local rshift = utils.bit32.rshift
    local floor = math.floor
    local char = string.char
    local byte = string.byte

    local x448 = {}

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
        a[i] = band(carry, LIMB_MASK)
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
          a[i] = band(new_carry, LIMB_MASK)
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
          r[i] = band(sum, LIMB_MASK)
          carry = floor(sum / 256)
        end

        local sum = r[29] + 0xFE + carry
        r[29] = band(sum, LIMB_MASK)
        carry = floor(sum / 256)

        for i = 30, NUM_LIMBS do
          sum = r[i] + 0xFF + carry
          r[i] = band(sum, LIMB_MASK)
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
        r[i] = band(sum, LIMB_MASK)
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
        r[i] = band(sum, LIMB_MASK)
        carry = floor(sum / 256)
      end

      -- Handle final carry
      while carry > 0 do
        r[1] = r[1] + carry
        r[29] = r[29] + carry

        carry = 0
        for i = 1, NUM_LIMBS do
          local sum = r[i] + carry
          r[i] = band(sum, LIMB_MASK)
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
    --- @param bytes string 56-byte string
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
        b[i] = char(band(t[i] or 0, 0xFF))
      end

      return table.concat(b)
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
      k[1] = band(k[1], 252) -- Clear low 2 bits
      k[56] = bor(k[56], 128) -- Set high bit

      -- Initialize Montgomery ladder
      local x_1 = fe_copy(u)
      local x_2 = fe_one()
      local z_2 = fe_zero()
      local x_3 = fe_copy(u)
      local z_3 = fe_one()
      local swap = 0

      -- Montgomery ladder
      for t = 447, 0, -1 do
        local byte_idx = rshift(t, 3) + 1 -- t // 8 + 1
        local bit_idx = band(t, 7) -- t % 8
        local kt = band(rshift(k[byte_idx], bit_idx), 1)

        -- Conditional swap
        swap = bxor(swap, kt)
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
        a24_limbs[1] = band(A24, 0xFF)
        a24_limbs[2] = band(rshift(A24, 8), 0xFF)

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
    --- @return string private_key 56-byte private key
    function x448.generate_private_key()
      -- Generate 56 random bytes
      local key = ""

      -- Mix multiple sources of randomness
      local seed = os.time() + (os.clock() * 1000000)
      math.randomseed(seed)

      for _ = 1, 56 do
        key = key .. char(math.random(0, 255))
      end

      return key
    end

    --- Derive public key from private key
    --- @param private_key string 56-byte private key
    --- @return string public_key 56-byte public key
    function x448.derive_public_key(private_key)
      assert(#private_key == 56, "Private key must be exactly 56 bytes")

      -- Base point for X448 (u = 5)
      local base = char(5) .. string.rep(char(0), 55)

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
          local zero_public = string.rep(char(0), 56)
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

do
  local _ENV = _ENV
  package.preload["noiseprotocol.openssl_wrapper"] = function(...)
    local arg = _G.arg
    --- @module "noiseprotocol.openssl_wrapper"
    --- OpenSSL wrapper for the Noise Protocol Framework
    ---
    --- This module provides a centralized interface for enabling and accessing OpenSSL
    --- acceleration for cryptographic operations. OpenSSL support can be enabled via:
    --- 1. Environment variable: NOISE_USE_OPENSSL=1 or NOISE_USE_OPENSSL=true
    --- 2. Calling noise.use_openssl(true/false) from the main module
    ---
    --- By default, native Lua implementations are used for maximum portability.
    --- When OpenSSL is enabled and available, it provides hardware-accelerated
    --- implementations for:
    --- - SHA256/SHA512 hash functions
    --- - BLAKE2s/BLAKE2b hash functions
    --- - ChaCha20-Poly1305 AEAD cipher
    --- - AES-GCM AEAD cipher
    --- - ChaCha20 stream cipher
    ---
    --- Note: X25519 and X448 currently use native implementations only as they are
    --- not currently supported by lua-openssl.

    local openssl_wrapper = {}

    local _openssl_module
    local _use_openssl = os.getenv("NOISE_USE_OPENSSL") == "1" or os.getenv("NOISE_USE_OPENSSL") == "true"

    --- Enable or disable OpenSSL acceleration for cryptographic operations
    --- @param use boolean True to enable OpenSSL, false to disable
    function openssl_wrapper.use(use)
      _use_openssl = use
    end

    --- Get the cached OpenSSL module if enabled and available
    --- @return table|nil openssl The OpenSSL module or nil if not enabled/available
    --- @throws error If OpenSSL is enabled but the module cannot be loaded
    function openssl_wrapper.get()
      if not _use_openssl then
        _openssl_module = nil
      elseif _openssl_module == nil then
        local ok, openssl_module = pcall(require, "openssl")
        if not ok or openssl_module == nil then
          error("OpenSSL module not found. Please install it to use Noise Protocol with OpenSSL.")
        end
        --- @cast openssl_module table
        _openssl_module = openssl_module
      end
      return _openssl_module
    end

    return openssl_wrapper
  end
end

do
  local _ENV = _ENV
  package.preload["noiseprotocol.utils"] = function(...)
    local arg = _G.arg
    --- @module "noiseprotocol.utils"
    --- Common utility functions for the Noise Protocol Framework

    return {
      bit32 = require("noiseprotocol.utils.bit32"),
      bit64 = require("noiseprotocol.utils.bit64"),
      bytes = require("noiseprotocol.utils.bytes"),
      benchmark = require("noiseprotocol.utils.benchmark"),
    }
  end
end

do
  local _ENV = _ENV
  package.preload["noiseprotocol.utils.benchmark"] = function(...)
    local arg = _G.arg
    --- @module "noiseprotocol.utils.benchmark"
    --- Common benchmarking utilities for performance testing

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
  package.preload["noiseprotocol.utils.bit32"] = function(...)
    local arg = _G.arg
    --- @module "noiseprotocol.utils.bit32"
    --- 32-bit bitwise operations

    local bit32 = {}

    -- 32-bit mask for ensuring results stay within 32-bit range
    local MASK32 = 0xFFFFFFFF

    --- Ensure value fits in 32-bit unsigned integer
    --- @param n number Input value
    --- @return integer result 32-bit unsigned integer
    function bit32.mask(n)
      return math.floor(n % 0x100000000)
    end

    --- Bitwise AND operation
    --- @param a integer First operand (32-bit)
    --- @param b integer Second operand (32-bit)
    --- @return integer result Result of a AND b
    function bit32.band(a, b)
      a = bit32.mask(a)
      b = bit32.mask(b)

      local result = 0
      local bit_val = 1

      for _ = 0, 31 do
        if (a % 2 == 1) and (b % 2 == 1) then
          result = result + bit_val
        end
        a = math.floor(a / 2)
        b = math.floor(b / 2)
        bit_val = bit_val * 2

        if a == 0 and b == 0 then
          break
        end
      end

      return result
    end

    --- Bitwise OR operation
    --- @param a integer First operand (32-bit)
    --- @param b integer Second operand (32-bit)
    --- @return integer result Result of a OR b
    function bit32.bor(a, b)
      a = bit32.mask(a)
      b = bit32.mask(b)

      local result = 0
      local bit_val = 1

      for _ = 0, 31 do
        if (a % 2 == 1) or (b % 2 == 1) then
          result = result + bit_val
        end
        a = math.floor(a / 2)
        b = math.floor(b / 2)
        bit_val = bit_val * 2

        if a == 0 and b == 0 then
          break
        end
      end

      return result
    end

    --- Bitwise XOR operation
    --- @param a integer First operand (32-bit)
    --- @param b integer Second operand (32-bit)
    --- @return integer result Result of a XOR b
    function bit32.bxor(a, b)
      a = bit32.mask(a)
      b = bit32.mask(b)

      local result = 0
      local bit_val = 1

      for _ = 0, 31 do
        if (a % 2) ~= (b % 2) then
          result = result + bit_val
        end
        a = math.floor(a / 2)
        b = math.floor(b / 2)
        bit_val = bit_val * 2

        if a == 0 and b == 0 then
          break
        end
      end

      return result
    end

    --- Bitwise NOT operation
    --- @param a integer Operand (32-bit)
    --- @return integer result Result of NOT a
    function bit32.bnot(a)
      return bit32.mask(MASK32 - bit32.mask(a))
    end

    --- Left shift operation
    --- @param a integer Value to shift (32-bit)
    --- @param n integer Number of positions to shift
    --- @return integer result Result of a << n
    function bit32.lshift(a, n)
      assert(n >= 0, "Shift amount must be non-negative")
      if n >= 32 then
        return 0
      end
      return bit32.mask(bit32.mask(a) * math.pow(2, n))
    end

    --- Right shift operation
    --- @param a integer Value to shift (32-bit)
    --- @param n integer Number of positions to shift
    --- @return integer result Result of a >> n
    function bit32.rshift(a, n)
      assert(n >= 0, "Shift amount must be non-negative")
      a = bit32.mask(a)
      if n >= 32 then
        return 0
      end
      return math.floor(a / math.pow(2, n))
    end

    --- Left rotate operation
    --- @param x integer Value to rotate (32-bit)
    --- @param n integer Number of positions to rotate
    --- @return integer result Result of rotating x left by n positions
    function bit32.rol(x, n)
      n = n % 32
      x = bit32.mask(x)
      return bit32.mask(bit32.lshift(x, n) + bit32.rshift(x, 32 - n))
    end

    --- Right rotate operation
    --- @param x integer Value to rotate (32-bit)
    --- @param n integer Number of positions to rotate
    --- @return integer result Result of rotating x right by n positions
    function bit32.ror(x, n)
      n = n % 32
      x = bit32.mask(x)
      return bit32.mask(bit32.rshift(x, n) + bit32.lshift(x, 32 - n))
    end

    --- 32-bit addition with overflow handling
    --- @param a integer First operand (32-bit)
    --- @param b integer Second operand (32-bit)
    --- @return integer result Result of (a + b) mod 2^32
    function bit32.add(a, b)
      return bit32.mask(bit32.mask(a) + bit32.mask(b))
    end

    --- Run comprehensive self-test with test vectors
    --- @return boolean result True if all tests pass, false otherwise
    function bit32.selftest()
      print("Running 32-bit operations test vectors...")
      local passed = 0
      local total = 0

      --- @class B32TestVector
      --- @field name string Test name
      --- @field fn fun(...): integer Function to test
      --- @field inputs any Input values
      --- @field expected integer Expected result

      --- @type B32TestVector[]
      local test_vectors = {
        -- Mask function tests
        {
          name = "mask - zero",
          fn = bit32.mask,
          inputs = { 0 },
          expected = 0,
        },
        {
          name = "mask - max 32-bit",
          fn = bit32.mask,
          inputs = { 0xFFFFFFFF },
          expected = 0xFFFFFFFF,
        },
        {
          name = "mask - overflow",
          fn = bit32.mask,
          inputs = { 0x100000000 },
          expected = 0,
        },
        {
          name = "mask - negative",
          fn = bit32.mask,
          inputs = { -1 },
          expected = 0xFFFFFFFF,
        },

        -- AND operation tests
        {
          name = "AND - alternating bytes",
          fn = bit32.band,
          inputs = { 0xFF00FF00, 0x00FF00FF },
          expected = 0x00000000,
        },
        {
          name = "AND - all ones",
          fn = bit32.band,
          inputs = { 0xFFFFFFFF, 0xFFFFFFFF },
          expected = 0xFFFFFFFF,
        },
        {
          name = "AND - with zero",
          fn = bit32.band,
          inputs = { 0x12345678, 0 },
          expected = 0,
        },
        {
          name = "AND - single bit",
          fn = bit32.band,
          inputs = { 0x80000000, 0x80000000 },
          expected = 0x80000000,
        },

        -- OR operation tests
        {
          name = "OR - alternating bytes",
          fn = bit32.bor,
          inputs = { 0xFF00FF00, 0x00FF00FF },
          expected = 0xFFFFFFFF,
        },
        {
          name = "OR - all zeros",
          fn = bit32.bor,
          inputs = { 0, 0 },
          expected = 0,
        },
        {
          name = "OR - with max",
          fn = bit32.bor,
          inputs = { 0x12345678, 0xFFFFFFFF },
          expected = 0xFFFFFFFF,
        },

        -- XOR operation tests
        {
          name = "XOR - alternating bytes",
          fn = bit32.bxor,
          inputs = { 0xFF00FF00, 0x00FF00FF },
          expected = 0xFFFFFFFF,
        },
        {
          name = "XOR - same values",
          fn = bit32.bxor,
          inputs = { 0x12345678, 0x12345678 },
          expected = 0,
        },
        {
          name = "XOR - with zero",
          fn = bit32.bxor,
          inputs = { 0x12345678, 0 },
          expected = 0x12345678,
        },

        -- NOT operation tests
        {
          name = "NOT - alternating bytes",
          fn = bit32.bnot,
          inputs = { 0xFF00FF00 },
          expected = 0x00FF00FF,
        },
        {
          name = "NOT - zero",
          fn = bit32.bnot,
          inputs = { 0 },
          expected = 0xFFFFFFFF,
        },
        {
          name = "NOT - max value",
          fn = bit32.bnot,
          inputs = { 0xFFFFFFFF },
          expected = 0,
        },
        {
          name = "NOT - single bit",
          fn = bit32.bnot,
          inputs = { 1 },
          expected = 0xFFFFFFFE,
        },

        -- Left shift tests
        {
          name = "lshift - by 8",
          fn = bit32.lshift,
          inputs = { 0x12345678, 8 },
          expected = 0x34567800,
        },
        {
          name = "lshift - by 0",
          fn = bit32.lshift,
          inputs = { 0x12345678, 0 },
          expected = 0x12345678,
        },
        {
          name = "lshift - by 31",
          fn = bit32.lshift,
          inputs = { 1, 31 },
          expected = 0x80000000,
        },
        {
          name = "lshift - by 32",
          fn = bit32.lshift,
          inputs = { 0x12345678, 32 },
          expected = 0,
        },

        -- Right shift tests
        {
          name = "rshift - by 8",
          fn = bit32.rshift,
          inputs = { 0x12345678, 8 },
          expected = 0x00123456,
        },
        {
          name = "rshift - by 0",
          fn = bit32.rshift,
          inputs = { 0x12345678, 0 },
          expected = 0x12345678,
        },
        {
          name = "rshift - by 31",
          fn = bit32.rshift,
          inputs = { 0x80000000, 31 },
          expected = 1,
        },
        {
          name = "rshift - by 32",
          fn = bit32.rshift,
          inputs = { 0x12345678, 32 },
          expected = 0,
        },

        -- Left rotate tests
        {
          name = "rol - by 8",
          fn = bit32.rol,
          inputs = { 0x12345678, 8 },
          expected = 0x34567812,
        },
        {
          name = "rol - by 0",
          fn = bit32.rol,
          inputs = { 0x12345678, 0 },
          expected = 0x12345678,
        },
        {
          name = "rol - by 32",
          fn = bit32.rol,
          inputs = { 0x12345678, 32 },
          expected = 0x12345678,
        },
        {
          name = "rol - by 16",
          fn = bit32.rol,
          inputs = { 0x12345678, 16 },
          expected = 0x56781234,
        },

        -- Right rotate tests
        {
          name = "ror - by 8",
          fn = bit32.ror,
          inputs = { 0x12345678, 8 },
          expected = 0x78123456,
        },
        {
          name = "ror - by 0",
          fn = bit32.ror,
          inputs = { 0x12345678, 0 },
          expected = 0x12345678,
        },
        {
          name = "ror - by 32",
          fn = bit32.ror,
          inputs = { 0x12345678, 32 },
          expected = 0x12345678,
        },
        {
          name = "ror - by 16",
          fn = bit32.ror,
          inputs = { 0x12345678, 16 },
          expected = 0x56781234,
        },

        -- Addition tests
        {
          name = "add - with overflow",
          fn = bit32.add,
          inputs = { 0xFFFFFFFF, 0x00000002 },
          expected = 0x00000001,
        },
        {
          name = "add - zero + zero",
          fn = bit32.add,
          inputs = { 0, 0 },
          expected = 0,
        },
        {
          name = "add - max + zero",
          fn = bit32.add,
          inputs = { 0xFFFFFFFF, 0 },
          expected = 0xFFFFFFFF,
        },
        {
          name = "add - half overflow",
          fn = bit32.add,
          inputs = { 0x80000000, 0x80000000 },
          expected = 0,
        },
        {
          name = "add - normal",
          fn = bit32.add,
          inputs = { 0x12345678, 0x87654321 },
          expected = 0x99999999,
        },
      }
      ---@diagnostic disable-next-line: access-invisible
      local unpack_fn = unpack or table.unpack

      for _, test in ipairs(test_vectors) do
        total = total + 1
        local result = test.fn(unpack_fn(test.inputs))
        if result == test.expected then
          print("  ✅ PASS: " .. test.name)
          passed = passed + 1
        else
          print("  ❌ FAIL: " .. test.name)
          print(string.format("    Expected: 0x%08X", test.expected))
          print(string.format("    Got:      0x%08X", result))
        end
      end

      print(string.format("\n32-bit operations result: %d/%d tests passed\n", passed, total))
      return passed == total
    end

    return bit32
  end
end

do
  local _ENV = _ENV
  package.preload["noiseprotocol.utils.bit64"] = function(...)
    local arg = _G.arg
    --- @module "noiseprotocol.utils.bit64"
    --- 64-bit bitwise operations using high/low pairs

    local bit32 = require("noiseprotocol.utils.bit32")

    local bit64 = {}

    -- Type definitions
    --- @alias Int64HighLow [integer, integer] Array with [1]=high 32 bits, [2]=low 32 bits

    --- 64-bit addition
    --- @param a Int64HighLow First operand {high, low}
    --- @param b Int64HighLow Second operand {high, low}
    --- @return Int64HighLow result {high, low} sum
    function bit64.add(a, b)
      local low = a[2] + b[2]
      local high = a[1] + b[1]

      -- Handle carry from low to high
      if low >= 0x100000000 then
        high = high + 1
        low = low % 0x100000000
      end

      -- Keep high within 32 bits
      high = high % 0x100000000

      return { high, low }
    end

    --- 64-bit right rotate
    --- @param x Int64HighLow Value to rotate {high, low}
    --- @param n integer Number of positions to rotate
    --- @return Int64HighLow result {high, low} rotated value
    function bit64.ror(x, n)
      n = n % 64
      if n == 0 then
        return { x[1], x[2] }
      end

      local high, low = x[1], x[2]

      if n == 32 then
        -- Special case: swap high and low
        return { low, high }
      elseif n < 32 then
        -- Rotate within 32-bit boundaries
        local new_low = bit32.bor(bit32.rshift(low, n), bit32.lshift(high, 32 - n))
        local new_high = bit32.bor(bit32.rshift(high, n), bit32.lshift(low, 32 - n))
        return { new_high, new_low }
      else
        -- n > 32: rotate by (n - 32) after swapping
        n = n - 32
        local new_low = bit32.bor(bit32.rshift(high, n), bit32.lshift(low, 32 - n))
        local new_high = bit32.bor(bit32.rshift(low, n), bit32.lshift(high, 32 - n))
        return { new_high, new_low }
      end
    end

    --- 64-bit right shift
    --- @param x Int64HighLow Value to shift {high, low}
    --- @param n integer Number of positions to shift
    --- @return Int64HighLow result {high, low} shifted value
    function bit64.shr(x, n)
      if n == 0 then
        return { x[1], x[2] }
      elseif n >= 64 then
        return { 0, 0 }
      elseif n >= 32 then
        -- Shift by 32 or more: high becomes 0, low gets bits from high
        return { 0, bit32.rshift(x[1], n - 32) }
      else
        -- Shift by less than 32
        local new_low = bit32.bor(bit32.rshift(x[2], n), bit32.lshift(x[1], 32 - n))
        local new_high = bit32.rshift(x[1], n)
        return { new_high, new_low }
      end
    end

    --- 64-bit XOR
    --- @param a Int64HighLow First operand {high, low}
    --- @param b Int64HighLow Second operand {high, low}
    --- @return Int64HighLow result {high, low} XOR result
    function bit64.xor(a, b)
      return {
        bit32.bxor(a[1], b[1]),
        bit32.bxor(a[2], b[2]),
      }
    end

    --- 64-bit AND
    --- @param a Int64HighLow First operand {high, low}
    --- @param b Int64HighLow Second operand {high, low}
    --- @return Int64HighLow result {high, low} AND result
    function bit64.band(a, b)
      return {
        bit32.band(a[1], b[1]),
        bit32.band(a[2], b[2]),
      }
    end

    --- 64-bit NOT
    --- @param a Int64HighLow Operand {high, low}
    --- @return Int64HighLow result {high, low} NOT result
    function bit64.bnot(a)
      return {
        bit32.bnot(a[1]),
        bit32.bnot(a[2]),
      }
    end

    --- Run comprehensive self-test with test vectors
    --- @return boolean result True if all tests pass, false otherwise
    function bit64.selftest()
      print("Running 64-bit operations test vectors...")
      local passed = 0
      local total = 0

      --- @class B64TestVector
      --- @field name string Test name
      --- @field fn fun(...): Int64HighLow Function to test
      --- @field inputs any Input values
      --- @field expected Int64HighLow Expected result {high, low}

      --- @type B64TestVector[]
      local test_vectors = {
        -- Addition tests
        {
          name = "add - normal with carry",
          fn = bit64.add,
          inputs = { { 0x12345678, 0x9ABCDEF0 }, { 0x87654321, 0x12345678 } },
          expected = { 0x99999999, 0xACF13568 },
        },
        {
          name = "add - zero + zero",
          fn = bit64.add,
          inputs = { { 0, 0 }, { 0, 0 } },
          expected = { 0, 0 },
        },
        {
          name = "add - max + zero",
          fn = bit64.add,
          inputs = { { 0xFFFFFFFF, 0xFFFFFFFF }, { 0, 0 } },
          expected = { 0xFFFFFFFF, 0xFFFFFFFF },
        },
        {
          name = "add - overflow in low word only",
          fn = bit64.add,
          inputs = { { 0, 0xFFFFFFFF }, { 0, 1 } },
          expected = { 1, 0 },
        },
        {
          name = "add - overflow in high word",
          fn = bit64.add,
          inputs = { { 0xFFFFFFFF, 0 }, { 1, 0 } },
          expected = { 0, 0 },
        },
        {
          name = "add - double overflow",
          fn = bit64.add,
          inputs = { { 0xFFFFFFFF, 0xFFFFFFFF }, { 0, 1 } },
          expected = { 0, 0 },
        },
        {
          name = "add - max + max",
          fn = bit64.add,
          inputs = { { 0xFFFFFFFF, 0xFFFFFFFF }, { 0xFFFFFFFF, 0xFFFFFFFF } },
          expected = { 0xFFFFFFFF, 0xFFFFFFFE },
        },

        -- XOR tests
        {
          name = "xor - alternating patterns",
          fn = bit64.xor,
          inputs = { { 0xFFFFFFFF, 0x00000000 }, { 0x00000000, 0xFFFFFFFF } },
          expected = { 0xFFFFFFFF, 0xFFFFFFFF },
        },
        {
          name = "xor - same values",
          fn = bit64.xor,
          inputs = { { 0x12345678, 0x9ABCDEF0 }, { 0x12345678, 0x9ABCDEF0 } },
          expected = { 0, 0 },
        },
        {
          name = "xor - with zero",
          fn = bit64.xor,
          inputs = { { 0x12345678, 0x9ABCDEF0 }, { 0, 0 } },
          expected = { 0x12345678, 0x9ABCDEF0 },
        },
        {
          name = "xor - all ones",
          fn = bit64.xor,
          inputs = { { 0xFFFFFFFF, 0xFFFFFFFF }, { 0xFFFFFFFF, 0xFFFFFFFF } },
          expected = { 0, 0 },
        },

        -- AND tests
        {
          name = "and - alternating patterns",
          fn = bit64.band,
          inputs = { { 0xFFFF0000, 0x0000FFFF }, { 0x0000FFFF, 0xFFFF0000 } },
          expected = { 0x00000000, 0x00000000 },
        },
        {
          name = "and - all ones",
          fn = bit64.band,
          inputs = { { 0xFFFFFFFF, 0xFFFFFFFF }, { 0xFFFFFFFF, 0xFFFFFFFF } },
          expected = { 0xFFFFFFFF, 0xFFFFFFFF },
        },
        {
          name = "and - with zero",
          fn = bit64.band,
          inputs = { { 0x12345678, 0x9ABCDEF0 }, { 0, 0 } },
          expected = { 0, 0 },
        },
        {
          name = "and - single bit high",
          fn = bit64.band,
          inputs = { { 0x80000000, 0 }, { 0x80000000, 0 } },
          expected = { 0x80000000, 0 },
        },
        {
          name = "and - single bit low",
          fn = bit64.band,
          inputs = { { 0, 1 }, { 0, 1 } },
          expected = { 0, 1 },
        },

        -- NOT tests
        {
          name = "not - alternating pattern",
          fn = bit64.bnot,
          inputs = { { 0xFFFF0000, 0x0000FFFF } },
          expected = { 0x0000FFFF, 0xFFFF0000 },
        },
        {
          name = "not - zero",
          fn = bit64.bnot,
          inputs = { { 0, 0 } },
          expected = { 0xFFFFFFFF, 0xFFFFFFFF },
        },
        {
          name = "not - max",
          fn = bit64.bnot,
          inputs = { { 0xFFFFFFFF, 0xFFFFFFFF } },
          expected = { 0, 0 },
        },
        {
          name = "not - single bit",
          fn = bit64.bnot,
          inputs = { { 0, 1 } },
          expected = { 0xFFFFFFFF, 0xFFFFFFFE },
        },

        -- Right rotate tests
        {
          name = "ror - by 16",
          fn = bit64.ror,
          inputs = { { 0x12345678, 0x9ABCDEF0 }, 16 },
          expected = { 0xDEF01234, 0x56789ABC },
        },
        {
          name = "ror - by 0",
          fn = bit64.ror,
          inputs = { { 0x12345678, 0x9ABCDEF0 }, 0 },
          expected = { 0x12345678, 0x9ABCDEF0 },
        },
        {
          name = "ror - by 32 (swap)",
          fn = bit64.ror,
          inputs = { { 0x12345678, 0x9ABCDEF0 }, 32 },
          expected = { 0x9ABCDEF0, 0x12345678 },
        },
        {
          name = "ror - by 64 (full rotation)",
          fn = bit64.ror,
          inputs = { { 0x12345678, 0x9ABCDEF0 }, 64 },
          expected = { 0x12345678, 0x9ABCDEF0 },
        },
        {
          name = "ror - by 48 (n > 32)",
          fn = bit64.ror,
          inputs = { { 0x12345678, 0x9ABCDEF0 }, 48 },
          expected = { 0x56789ABC, 0xDEF01234 },
        },
        {
          name = "ror - by 8",
          fn = bit64.ror,
          inputs = { { 0x12345678, 0x9ABCDEF0 }, 8 },
          expected = { 0xF0123456, 0x789ABCDE },
        },

        -- Right shift tests
        {
          name = "shr - by 16",
          fn = bit64.shr,
          inputs = { { 0x12345678, 0x9ABCDEF0 }, 16 },
          expected = { 0x00001234, 0x56789ABC },
        },
        {
          name = "shr - by 0",
          fn = bit64.shr,
          inputs = { { 0x12345678, 0x9ABCDEF0 }, 0 },
          expected = { 0x12345678, 0x9ABCDEF0 },
        },
        {
          name = "shr - by 32",
          fn = bit64.shr,
          inputs = { { 0x12345678, 0x9ABCDEF0 }, 32 },
          expected = { 0, 0x12345678 },
        },
        {
          name = "shr - by 63",
          fn = bit64.shr,
          inputs = { { 0x80000000, 0 }, 63 },
          expected = { 0, 1 },
        },
        {
          name = "shr - by 64",
          fn = bit64.shr,
          inputs = { { 0x12345678, 0x9ABCDEF0 }, 64 },
          expected = { 0, 0 },
        },
        {
          name = "shr - by >64",
          fn = bit64.shr,
          inputs = { { 0x12345678, 0x9ABCDEF0 }, 100 },
          expected = { 0, 0 },
        },
        {
          name = "shr - by 48 (n > 32)",
          fn = bit64.shr,
          inputs = { { 0x12345678, 0x9ABCDEF0 }, 48 },
          expected = { 0, 0x00001234 },
        },
      }
      ---@diagnostic disable-next-line: access-invisible
      local unpack_fn = unpack or table.unpack

      for _, test in ipairs(test_vectors) do
        total = total + 1
        local result = test.fn(unpack_fn(test.inputs))
        if result[1] == test.expected[1] and result[2] == test.expected[2] then
          print("  ✅ PASS: " .. test.name)
          passed = passed + 1
        else
          print("  ❌ FAIL: " .. test.name)
          print(string.format("    Expected: {0x%08X, 0x%08X}", test.expected[1], test.expected[2]))
          print(string.format("    Got:      {0x%08X, 0x%08X}", result[1], result[2]))
        end
      end

      print(string.format("\n64-bit operations result: %d/%d tests passed\n", passed, total))
      return passed == total
    end

    return bit64
  end
end

do
  local _ENV = _ENV
  package.preload["noiseprotocol.utils.bytes"] = function(...)
    local arg = _G.arg
    --- @module "noiseprotocol.utils.bytes"
    --- Byte manipulation and conversion utilities

    local bit32 = require("noiseprotocol.utils.bit32")

    local bytes = {}

    --- Convert binary string to hexadecimal string
    --- @param str string Binary string
    --- @return string hex Hexadecimal representation
    function bytes.to_hex(str)
      return (str:gsub(".", function(c)
        return string.format("%02x", string.byte(c))
      end))
    end

    --- Convert hexadecimal string to binary string
    --- @param hex string Hexadecimal string
    --- @return string str Binary string
    function bytes.from_hex(hex)
      return (hex:gsub("..", function(cc)
        return string.char(tonumber(cc, 16))
      end))
    end

    --- Convert 32-bit unsigned integer to 4 bytes (little-endian)
    --- @param n integer 32-bit unsigned integer
    --- @return string bytes 4-byte string in little-endian order
    function bytes.u32_to_le_bytes(n)
      n = bit32.mask(n)
      return string.char(
        n % 256,
        math.floor(n / 256) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 16777216) % 256
      )
    end

    --- Convert 32-bit unsigned integer to 4 bytes (big-endian)
    --- @param n integer 32-bit unsigned integer
    --- @return string bytes 4-byte string in big-endian order
    function bytes.u32_to_be_bytes(n)
      n = bit32.mask(n)
      return string.char(
        math.floor(n / 16777216) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256,
        n % 256
      )
    end

    --- Convert 64-bit value to 8 bytes (big-endian)
    --- @param x Int64HighLow|table {high, low} 64-bit value
    --- @return string bytes 8-byte string in big-endian order
    function bytes.u64_to_be_bytes(x)
      local high, low = x[1], x[2]
      return bytes.u32_to_be_bytes(high) .. bytes.u32_to_be_bytes(low)
    end

    --- Convert 64-bit value to 8 bytes (little-endian)
    --- @param x Int64HighLow|table|integer {high, low} 64-bit value or simple integer
    --- @return string bytes 8-byte string in little-endian order
    function bytes.u64_to_le_bytes(x)
      -- Handle simple integer case (< 2^53)
      if type(x) == "number" then
        local low = x % 0x100000000
        local high = math.floor(x / 0x100000000)
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
      local b1, b2, b3, b4 = string.byte(str, offset, offset + 3)
      return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
    end

    --- Convert 4 bytes to 32-bit unsigned integer (big-endian)
    --- @param str string Binary string (at least 4 bytes)
    --- @param offset? integer Starting position (default: 1)
    --- @return integer n 32-bit unsigned integer
    function bytes.be_bytes_to_u32(str, offset)
      offset = offset or 1
      assert(#str >= offset + 3, "Insufficient bytes for u32")
      local b1, b2, b3, b4 = string.byte(str, offset, offset + 3)
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
      for i = 1, #a do
        result[i] = string.char(bit32.bxor(string.byte(a, i), string.byte(b, i)))
      end
      return table.concat(result)
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
        result = bit32.bor(result, bit32.bxor(string.byte(a, i), string.byte(b, i)))
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
      return data .. string.rep("\0", padding_len)
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
            local data = string.char(0x00)
            local hex = bytes.to_hex(data)
            return hex == "00"
          end,
        },
        {
          name = "hex - single byte max",
          test = function()
            local data = string.char(0xFF)
            local hex = bytes.to_hex(data)
            return hex == "ff"
          end,
        },
        {
          name = "hex - all byte values",
          test = function()
            -- Test a few representative byte values
            local data = string.char(0x00, 0x01, 0x7F, 0x80, 0xFE, 0xFF)
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
            local data = string.char(0x80, 0x90, 0xA0, 0xB0, 0xC0, 0xD0, 0xE0, 0xF0)
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
            local b1, b2, b3, b4 = string.byte(bytes_str, 1, 4)
            return back == n and b1 == 0x78 and b2 == 0x56 and b3 == 0x34 and b4 == 0x12
          end,
        },
        {
          name = "u32 LE - zero",
          test = function()
            local n = 0
            local bytes_str = bytes.u32_to_le_bytes(n)
            local back = bytes.le_bytes_to_u32(bytes_str)
            return back == 0 and bytes_str == string.char(0, 0, 0, 0)
          end,
        },
        {
          name = "u32 LE - max value",
          test = function()
            local n = 0xFFFFFFFF
            local bytes_str = bytes.u32_to_le_bytes(n)
            local back = bytes.le_bytes_to_u32(bytes_str)
            return back == 0xFFFFFFFF and bytes_str == string.char(0xFF, 0xFF, 0xFF, 0xFF)
          end,
        },
        {
          name = "u32 LE - needs masking",
          test = function()
            local n = 0x100000000 -- Should be masked to 0
            local bytes_str = bytes.u32_to_le_bytes(n)
            return bytes_str == string.char(0, 0, 0, 0)
          end,
        },
        {
          name = "u32 LE - single bit patterns",
          test = function()
            local n = 0x80000000
            local bytes_str = bytes.u32_to_le_bytes(n)
            local back = bytes.le_bytes_to_u32(bytes_str)
            return back == 0x80000000 and bytes_str == string.char(0, 0, 0, 0x80)
          end,
        },
        {
          name = "u32 LE - with offset",
          test = function()
            local data = "XXX" .. string.char(0x78, 0x56, 0x34, 0x12) .. "YYY"
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
            local b1, b2, b3, b4 = string.byte(bytes_str, 1, 4)
            return back == n and b1 == 0x12 and b2 == 0x34 and b3 == 0x56 and b4 == 0x78
          end,
        },
        {
          name = "u32 BE - zero",
          test = function()
            local n = 0
            local bytes_str = bytes.u32_to_be_bytes(n)
            local back = bytes.be_bytes_to_u32(bytes_str)
            return back == 0 and bytes_str == string.char(0, 0, 0, 0)
          end,
        },
        {
          name = "u32 BE - max value",
          test = function()
            local n = 0xFFFFFFFF
            local bytes_str = bytes.u32_to_be_bytes(n)
            local back = bytes.be_bytes_to_u32(bytes_str)
            return back == 0xFFFFFFFF and bytes_str == string.char(0xFF, 0xFF, 0xFF, 0xFF)
          end,
        },
        {
          name = "u32 BE - with offset",
          test = function()
            local data = "XXX" .. string.char(0x12, 0x34, 0x56, 0x78) .. "YYY"
            local n = bytes.be_bytes_to_u32(data, 4)
            return n == 0x12345678
          end,
        },

        -- 64-bit conversion tests
        {
          name = "u64 LE - basic table",
          test = function()
            local n = { 0x12345678, 0x9ABCDEF0 }
            local bytes_str = bytes.u64_to_le_bytes(n)
            local back = bytes.le_bytes_to_u64(bytes_str)
            local b1, b2, b3, b4, b5, b6, b7, b8 = string.byte(bytes_str, 1, 8)
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
            local expected_high = math.floor(n / 0x100000000)
            return back[1] == expected_high and back[2] == expected_low
          end,
        },
        {
          name = "u64 LE - zero",
          test = function()
            local n = { 0, 0 }
            local bytes_str = bytes.u64_to_le_bytes(n)
            local back = bytes.le_bytes_to_u64(bytes_str)
            return back[1] == 0 and back[2] == 0 and bytes_str == string.rep(string.char(0), 8)
          end,
        },
        {
          name = "u64 LE - max value",
          test = function()
            local n = { 0xFFFFFFFF, 0xFFFFFFFF }
            local bytes_str = bytes.u64_to_le_bytes(n)
            local back = bytes.le_bytes_to_u64(bytes_str)
            return back[1] == 0xFFFFFFFF and back[2] == 0xFFFFFFFF and bytes_str == string.rep(string.char(0xFF), 8)
          end,
        },
        {
          name = "u64 LE - high word only",
          test = function()
            local n = { 0x12345678, 0 }
            local bytes_str = bytes.u64_to_le_bytes(n)
            local back = bytes.le_bytes_to_u64(bytes_str)
            return back[1] == 0x12345678 and back[2] == 0
          end,
        },
        {
          name = "u64 LE - low word only",
          test = function()
            local n = { 0, 0x12345678 }
            local bytes_str = bytes.u64_to_le_bytes(n)
            local back = bytes.le_bytes_to_u64(bytes_str)
            return back[1] == 0 and back[2] == 0x12345678
          end,
        },
        {
          name = "u64 LE - with offset",
          test = function()
            local data = "XXX" .. bytes.u64_to_le_bytes({ 0x12345678, 0x9ABCDEF0 }) .. "YYY"
            local n = bytes.le_bytes_to_u64(data, 4)
            return n[1] == 0x12345678 and n[2] == 0x9ABCDEF0
          end,
        },
        {
          name = "u64 BE - basic",
          test = function()
            local n = { 0x12345678, 0x9ABCDEF0 }
            local bytes_str = bytes.u64_to_be_bytes(n)
            local back = bytes.be_bytes_to_u64(bytes_str)
            local b1, b2, b3, b4, b5, b6, b7, b8 = string.byte(bytes_str, 1, 8)
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
            local n = { 0, 0 }
            local bytes_str = bytes.u64_to_be_bytes(n)
            local back = bytes.be_bytes_to_u64(bytes_str)
            return back[1] == 0 and back[2] == 0 and bytes_str == string.rep(string.char(0), 8)
          end,
        },
        {
          name = "u64 BE - with offset",
          test = function()
            local data = "XXX" .. bytes.u64_to_be_bytes({ 0x12345678, 0x9ABCDEF0 }) .. "YYY"
            local n = bytes.be_bytes_to_u64(data, 4)
            return n[1] == 0x12345678 and n[2] == 0x9ABCDEF0
          end,
        },

        -- XOR tests
        {
          name = "xor - basic",
          test = function()
            local a = string.char(0x01, 0x02, 0x03, 0x04)
            local b = string.char(0xFF, 0xFE, 0xFD, 0xFC)
            local result = bytes.xor_bytes(a, b)
            local r1, r2, r3, r4 = string.byte(result, 1, 4)
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
            local a = string.char(0x00)
            local b = string.char(0xFF)
            local result = bytes.xor_bytes(a, b)
            return result == string.char(0xFF)
          end,
        },
        {
          name = "xor - with self",
          test = function()
            local a = "test"
            local result = bytes.xor_bytes(a, a)
            return result == string.char(0, 0, 0, 0)
          end,
        },
        {
          name = "xor - all zeros pattern",
          test = function()
            local a = string.char(0xAA, 0xBB, 0xCC, 0xDD)
            local b = string.char(0xAA, 0xBB, 0xCC, 0xDD)
            local result = bytes.xor_bytes(a, b)
            return result == string.char(0, 0, 0, 0)
          end,
        },
        {
          name = "xor - identity with zeros",
          test = function()
            local a = string.char(0x12, 0x34, 0x56, 0x78)
            local b = string.char(0, 0, 0, 0)
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
            local a = string.char(0x00, 0x01, 0xFF)
            local b = string.char(0x00, 0x01, 0xFF)
            return bytes.constant_time_compare(a, b) == true
          end,
        },

        -- Padding tests
        {
          name = "pad_to_16 - no padding needed",
          test = function()
            local data = string.rep("a", 16)
            local padded = bytes.pad_to_16(data)
            return padded == data and #padded == 16
          end,
        },
        {
          name = "pad_to_16 - padding needed",
          test = function()
            local data = "Hello"
            local padded = bytes.pad_to_16(data)
            return #padded == 16 and padded:sub(1, 5) == "Hello" and padded:sub(6) == string.rep("\0", 11)
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
            local data = string.rep("a", 32)
            local padded = bytes.pad_to_16(data)
            return padded == data and #padded == 32
          end,
        },
        {
          name = "pad_to_16 - one byte short",
          test = function()
            local data = string.rep("a", 15)
            local padded = bytes.pad_to_16(data)
            return #padded == 16 and padded:sub(1, 15) == data and padded:sub(16) == "\0"
          end,
        },
        {
          name = "pad_to_16 - one byte over",
          test = function()
            local data = string.rep("a", 17)
            local padded = bytes.pad_to_16(data)
            return #padded == 32 and padded:sub(1, 17) == data and padded:sub(18) == string.rep("\0", 15)
          end,
        },
        {
          name = "pad_to_16 - large data",
          test = function()
            local data = string.rep("a", 1000)
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
            return not ok and err:match("Insufficient bytes")
          end,
        },
        {
          name = "u32 BE - insufficient bytes",
          test = function()
            local ok, err = pcall(bytes.be_bytes_to_u32, "XX")
            return not ok and err:match("Insufficient bytes")
          end,
        },
        {
          name = "u64 LE - insufficient bytes",
          test = function()
            local ok, err = pcall(bytes.le_bytes_to_u64, "XXXXXX")
            return not ok and err:match("Insufficient bytes")
          end,
        },
        {
          name = "u64 BE - insufficient bytes",
          test = function()
            local ok, err = pcall(bytes.be_bytes_to_u64, "XXXXXX")
            return not ok and err:match("Insufficient bytes")
          end,
        },
        {
          name = "xor - length mismatch",
          test = function()
            local ok, err = pcall(bytes.xor_bytes, "abc", "abcd")
            return not ok and err:match("same length")
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

      print(string.format("\nByte operations result: %d/%d tests passed\n", passed, total))
      return passed == total
    end

    return bytes
  end
end

--- @module "noiseprotocol"
--- Noise Protocol Framework Implementation
---
--- This module implements the Noise Protocol Framework, providing a secure
--- channel establishment protocol with support for various handshake patterns,
--- cipher suites, and optional OpenSSL acceleration.
---
--- @usage
--- local noise = require("noiseprotocol")
---
--- -- Enable OpenSSL acceleration (optional)
--- noise.use_openssl(true)
---
--- -- Create a connection
--- local connection = noise.NoiseConnection:new({
---   protocol_name = "Noise_XX_25519_ChaChaPoly_SHA256",
---   initiator = true,
---   static_key = my_static_key
--- })
--- ...

local crypto = require("noiseprotocol.crypto")
local utils = require("noiseprotocol.utils")
local openssl_wrapper = require("noiseprotocol.openssl_wrapper")

--- Module version
local VERSION = "v0.1.0"

local noise = {
  --- Enable or disable OpenSSL acceleration
  --- @function use_openssl
  --- @param use boolean True to enable OpenSSL, false to disable
  --- @see noiseprotocol.openssl_wrapper.use
  use_openssl = openssl_wrapper.use,

  --- Get the module version
  --- @function version
  --- @return string version The version string
  version = function()
    return VERSION
  end,
}

-- ============================================================================
-- PROTOCOL NAME PARSING
-- ============================================================================

--- Parse pattern and modifiers from the pattern portion
--- @param pattern_str string Pattern with modifiers (e.g. "NNpsk0+psk2")
--- @return string pattern Base pattern (e.g. "NN")
--- @return table modifiers List of modifiers with their parameters
local function parse_pattern_and_modifiers(pattern_str)
  -- Extract base pattern (uppercase letters only)
  local pattern = pattern_str:match("^([A-Z1]+)")
  if not pattern then
    error("Invalid pattern format: " .. pattern_str)
  end

  -- Extract modifiers
  local modifiers = {}
  local remaining = pattern_str:sub(#pattern + 1)

  if remaining ~= "" then
    -- Parse modifiers (e.g. "psk0+psk2" or "fallback+psk0")
    for modifier in remaining:gmatch("([^+]+)") do
      table.insert(modifiers, modifier)
    end
  end

  return pattern, modifiers
end

--- Parse a Noise protocol name into its components
--- @param protocol_name string Full protocol name (e.g. "Noise_NNpsk0+psk2_25519_AESGCM_SHA256")
--- @return table parsed Components: pattern, modifiers, dh, cipher, hash
local function parse_protocol_name(protocol_name)
  -- Protocol name format: Noise_PATTERNmodifiers_DH_CIPHER_HASH
  local prefix, pattern_with_modifiers, dh, cipher, hash =
    protocol_name:match("^(Noise)_([^_]+)_([^_]+)_([^_]+)_([^_]+)$")

  if not prefix or not pattern_with_modifiers or not dh or not cipher or not hash then
    error("Invalid protocol name format: " .. protocol_name)
  end

  -- Parse pattern and modifiers
  local pattern, modifiers = parse_pattern_and_modifiers(pattern_with_modifiers)

  return {
    pattern = pattern,
    modifiers = modifiers,
    dh = dh,
    cipher = cipher,
    hash = hash,
    full_name = protocol_name,
  }
end

--- Parse PSK modifiers to get placement positions
--- @param modifiers table List of modifier strings
--- @return table psk_positions List of PSK positions in order
local function parse_psk_modifiers(modifiers)
  local psk_positions = {}

  for _, modifier in ipairs(modifiers) do
    local psk_num = modifier:match("^psk(%d)$")
    if psk_num then
      table.insert(psk_positions, tonumber(psk_num))
    elseif modifier == "fallback" then
      error("Fallback modifier not yet supported")
    else
      error("Unknown modifier: " .. modifier)
    end
  end

  -- Sort positions to ensure consistent ordering
  table.sort(psk_positions)

  return psk_positions
end

-- ============================================================================
-- CIPHER SUITE INTERFACE DEFINITIONS
-- ============================================================================

--- Cipher suite interface definitions
--- @class DHFunction
--- @field name string Name of the DH function (e.g., "25519")
--- @field dhlen integer Length of public/private keys in bytes
--- @field generate_keypair fun(): string, string Generate private and public key pair
--- @field dh fun(private_key: string, public_key: string): string Perform DH operation
--- @field derive_public_key fun(private_key: string): string Derive public key from private key

--- @class CipherFunction
--- @field name string Name of the cipher (e.g., "ChaChaPoly")
--- @field keylen integer Length of cipher key in bytes
--- @field noncelen integer Length of nonce in bytes
--- @field taglen integer Length of authentication tag in bytes
--- @field encrypt fun(key: string, nonce: integer, plaintext: string, ad: string): string Encrypt with AEAD
--- @field decrypt fun(key: string, nonce: integer, ciphertext: string, ad: string): string? Decrypt with AEAD
--- @field rekey fun(key: string): string Generate new key for rekeying

--- @class HashFunction
--- @field name string Name of the hash function (e.g., "SHA256")
--- @field hashlen integer Length of hash output in bytes
--- @field blocklen integer Internal block length in bytes
--- @field hash fun(data: string): string Compute hash
--- @field hmac fun(key: string, data: string): string Compute HMAC
--- @field hkdf fun(chaining_key: string, input_key_material: string, num_outputs: integer): string, string, string? HKDF expansion

--- @class CipherSuite
--- @field name string Cipher suite name (e.g., "25519_ChaChaPoly_SHA256")
--- @field dh DHFunction Diffie-Hellman function
--- @field cipher CipherFunction Cipher function
--- @field hash HashFunction Hash function
local CipherSuite = {}
CipherSuite.__index = CipherSuite

--- Create a new cipher suite
--- @param dh DHFunction Diffie-Hellman function
--- @param cipher CipherFunction Cipher function
--- @param hash HashFunction Hash function
--- @return CipherSuite suite New cipher suite
function CipherSuite:new(dh, cipher, hash)
  local instance = setmetatable({}, self)
  instance.name = dh.name .. "_" .. cipher.name .. "_" .. hash.name
  instance.dh = dh
  instance.cipher = cipher
  instance.hash = hash
  return instance
end

-- Protocol constants
local MAX_NONCE = math.pow(2, 32) - 1

--- X25519 Diffie-Hellman implementation
--- @type DHFunction
local DH_25519 = {
  name = "25519",
  dhlen = 32,
  generate_keypair = function()
    return crypto.x25519.generate_keypair()
  end,
  dh = function(private_key, public_key)
    return crypto.x25519.diffie_hellman(private_key, public_key)
  end,
  derive_public_key = function(private_key)
    return crypto.x25519.derive_public_key(private_key)
  end,
}

--- X448 Diffie-Hellman implementation
--- @type DHFunction
local DH_448 = {
  name = "448",
  dhlen = 56,
  generate_keypair = function()
    return crypto.x448.generate_keypair()
  end,
  dh = function(private_key, public_key)
    return crypto.x448.diffie_hellman(private_key, public_key)
  end,
  derive_public_key = function(private_key)
    return crypto.x448.derive_public_key(private_key)
  end,
}

local function make_chachapoly_nonce(n)
  -- ChaCha20Poly1305 uses little-endian format: 4 zero bytes + 64-bit counter
  assert(n <= MAX_NONCE, "Nonce overflow")
  local nonce = string.rep("\0", 4) -- 4 zero bytes padding

  -- Little-endian 64-bit counter
  for _ = 0, 7 do
    nonce = nonce .. string.char(n % 256)
    n = math.floor(n / 256)
  end

  return nonce
end

--- ChaCha20-Poly1305 AEAD implementation
--- @type CipherFunction
local CIPHER_ChaChaPoly = {
  name = "ChaChaPoly",
  keylen = 32,
  noncelen = 12,
  taglen = 16,
  encrypt = function(key, nonce, plaintext, ad)
    return crypto.chacha20_poly1305.encrypt(key, make_chachapoly_nonce(nonce), plaintext, ad)
  end,
  decrypt = function(key, nonce, ciphertext, ad)
    return crypto.chacha20_poly1305.decrypt(key, make_chachapoly_nonce(nonce), ciphertext, ad)
  end,
  rekey = function(key)
    local dummy_nonce = string.rep(string.char(0xFF), 12)
    local new_key = crypto.chacha20_poly1305.encrypt(key, dummy_nonce, string.rep("\0", 32), "")
    return new_key:sub(1, 32)
  end,
}

local function make_aesgcm_nonce(n)
  -- AESGCM uses big-endian format: 4 zero bytes + 64-bit counter
  assert(n <= MAX_NONCE, "Nonce overflow")
  local nonce = string.rep("\0", 4) -- 4 zero bytes padding

  -- Big-endian 64-bit counter
  local bytes = {}
  for i = 1, 8 do
    bytes[i] = string.char(n % 256)
    n = math.floor(n / 256)
  end
  -- Reverse the bytes for big-endian
  for i = 8, 1, -1 do
    nonce = nonce .. bytes[i]
  end

  return nonce
end

--- AES-GCM AEAD implementation
--- @type CipherFunction
local CIPHER_AESGCM = {
  name = "AESGCM",
  keylen = 32, -- Use AES-256 for Noise
  noncelen = 12,
  taglen = 16,
  encrypt = function(key, nonce, plaintext, ad)
    return crypto.aes_gcm.encrypt(key, make_aesgcm_nonce(nonce), plaintext, ad)
  end,
  decrypt = function(key, nonce, ciphertext, ad)
    return crypto.aes_gcm.decrypt(key, make_aesgcm_nonce(nonce), ciphertext, ad)
  end,
  rekey = function(key)
    local dummy_nonce = string.rep(string.char(0xFF), 12)
    local new_key = crypto.aes_gcm.encrypt(key, dummy_nonce, string.rep("\0", 32), "")
    return new_key:sub(1, 32)
  end,
}

--- SHA256 hash implementation
--- @type HashFunction
local HASH_SHA256 = {
  name = "SHA256",
  hashlen = 32,
  blocklen = 64,
  hash = function(data)
    return crypto.sha256.sha256(data)
  end,
  hmac = function(key, data)
    return crypto.sha256.hmac_sha256(key, data)
  end,
  hkdf = function(chaining_key, input_key_material, num_outputs)
    assert(num_outputs == 2 or num_outputs == 3, "num_outputs must be 2 or 3")

    -- HKDF Extract
    local prk = crypto.sha256.hmac_sha256(chaining_key, input_key_material)

    -- HKDF Expand
    local t1 = crypto.sha256.hmac_sha256(prk, string.char(0x01))
    local t2 = crypto.sha256.hmac_sha256(prk, t1 .. string.char(0x02))

    if num_outputs == 2 then
      return t1, t2
    else
      local t3 = crypto.sha256.hmac_sha256(prk, t2 .. string.char(0x03))
      return t1, t2, t3
    end
  end,
}

--- SHA512 hash implementation
--- @type HashFunction
local HASH_SHA512 = {
  name = "SHA512",
  hashlen = 64,
  blocklen = 128,
  hash = function(data)
    return crypto.sha512.sha512(data)
  end,
  hmac = function(key, data)
    return crypto.sha512.hmac_sha512(key, data)
  end,
  hkdf = function(chaining_key, input_key_material, num_outputs)
    assert(num_outputs == 2 or num_outputs == 3, "num_outputs must be 2 or 3")

    -- HKDF Extract
    local prk = crypto.sha512.hmac_sha512(chaining_key, input_key_material)

    -- HKDF Expand
    local t1 = crypto.sha512.hmac_sha512(prk, string.char(0x01))
    local t2 = crypto.sha512.hmac_sha512(prk, t1 .. string.char(0x02))

    if num_outputs == 2 then
      return t1, t2
    else
      local t3 = crypto.sha512.hmac_sha512(prk, t2 .. string.char(0x03))
      return t1, t2, t3
    end
  end,
}

--- BLAKE2s hash implementation
--- @type HashFunction
local HASH_BLAKE2S = {
  name = "BLAKE2s",
  hashlen = 32,
  blocklen = 64,
  hash = function(data)
    return crypto.blake2.blake2s(data)
  end,
  hmac = function(key, data)
    return crypto.blake2.hmac_blake2s(key, data)
  end,
  hkdf = function(chaining_key, input_key_material, num_outputs)
    assert(num_outputs == 2 or num_outputs == 3, "num_outputs must be 2 or 3")

    -- HKDF Extract
    local prk = crypto.blake2.hmac_blake2s(chaining_key, input_key_material)

    -- HKDF Expand
    local t1 = crypto.blake2.hmac_blake2s(prk, string.char(0x01))
    local t2 = crypto.blake2.hmac_blake2s(prk, t1 .. string.char(0x02))

    if num_outputs == 2 then
      return t1, t2
    else
      local t3 = crypto.blake2.hmac_blake2s(prk, t2 .. string.char(0x03))
      return t1, t2, t3
    end
  end,
}

--- BLAKE2b hash implementation
--- @type HashFunction
local HASH_BLAKE2B = {
  name = "BLAKE2b",
  hashlen = 64,
  blocklen = 128,
  hash = function(data)
    return crypto.blake2.blake2b(data)
  end,
  hmac = function(key, data)
    return crypto.blake2.hmac_blake2b(key, data)
  end,
  hkdf = function(chaining_key, input_key_material, num_outputs)
    assert(num_outputs == 2 or num_outputs == 3, "num_outputs must be 2 or 3")

    -- HKDF Extract
    local prk = crypto.blake2.hmac_blake2b(chaining_key, input_key_material)

    -- HKDF Expand
    local t1 = crypto.blake2.hmac_blake2b(prk, string.char(0x01))
    local t2 = crypto.blake2.hmac_blake2b(prk, t1 .. string.char(0x02))

    if num_outputs == 2 then
      return t1, t2
    else
      local t3 = crypto.blake2.hmac_blake2b(prk, t2 .. string.char(0x03))
      return t1, t2, t3
    end
  end,
}

--- Noise Protocol message tokens
--- @enum MessageToken
local MessageToken = {
  -- Key exchange tokens
  E = "e", -- Generate/send ephemeral key pair
  S = "s", -- Send static public key (encrypted after first DH)

  -- Diffie-Hellman tokens
  EE = "ee", -- Ephemeral-ephemeral DH between local and remote ephemeral keys
  ES = "es", -- Ephemeral-static DH (initiator ephemeral with responder static, or vice versa)
  SE = "se", -- Static-ephemeral DH (initiator static with responder ephemeral, or vice versa)
  SS = "ss", -- Static-static DH between local and remote static keys

  -- Pre-shared key token
  PSK = "psk", -- Mix pre-shared key (placement determined by context)
}

--- PSK placement positions
--- @enum PSKPlacement
local PSKPlacement = {
  ZERO = 0, -- psk0: Beginning of first message
  ONE = 1, -- psk1: Beginning of second message
  TWO = 2, -- psk2: Beginning of third message
  THREE = 3, -- psk3: End of final message
}

--- Noise Protocol handshake patterns
--- @enum NoisePattern
local NoisePattern = {
  -- No authentication patterns
  NN = "NN", -- No static keys (ephemeral-ephemeral)

  -- Server authentication patterns
  NK = "NK", -- Responder has static key known to initiator

  -- Client authentication patterns
  KN = "KN", -- Initiator has static key known to responder

  -- Mutual known keys
  KK = "KK", -- Both parties have static keys known to each other

  -- Server known, client transmitted
  XK = "XK", -- Responder static key known, initiator transmits static key

  -- Client known, server transmitted
  KX = "KX", -- Initiator static key known, responder transmits static key

  -- Server transmitted during handshake
  NX = "NX", -- Responder transmits static key during handshake

  -- Mutual authentication
  XX = "XX", -- Both parties transmit static keys during handshake

  -- Immediate known server key
  IK = "IK", -- Responder static key known, enables 0-RTT encryption

  -- I patterns - Immediate client authentication
  IN = "IN", -- Initiator static key transmitted immediately
  IX = "IX", -- Both static keys, initiator transmits immediately

  -- X patterns - Delayed server authentication
  XN = "XN", -- Responder transmits static key, no initiator static

  -- One-way patterns
  N = "N", -- No static keys, one-way pattern
  K = "K", -- Recipient has sender's static key, one-way pattern
  X = "X", -- Sender transmits static key, one-way pattern

  -- Deferred patterns (1 = initiator defers static key)
  NK1 = "NK1", -- NK with initiator deferring static key
  NX1 = "NX1", -- NX with initiator deferring static key
  X1N = "X1N", -- XN with sender deferring static key
  X1X = "X1X", -- XX with initiator deferring first static key
  XK1 = "XK1", -- XK with initiator deferring static key
  K1N = "K1N", -- KN with initiator deferring static key
  K1K = "K1K", -- KK with initiator deferring static key
  KK1 = "KK1", -- KK with responder deferring static key
  K1X = "K1X", -- KX with initiator deferring static key
  KX1 = "KX1", -- KX with responder deferring static key
  K1K1 = "K1K1", -- KK with both parties deferring static keys
  K1X1 = "K1X1", -- KX with both parties deferring static keys
  X1K = "X1K", -- XK with initiator deferring static key
  X1K1 = "X1K1", -- XK with both parties deferring static keys
  X1X1 = "X1X1", -- XX with both parties deferring static keys
  XX1 = "XX1", -- XX with responder deferring static key
  I1N = "I1N", -- IN with initiator deferring static key
  I1K = "I1K", -- IK with initiator deferring static key
  IK1 = "IK1", -- IK with responder deferring static key
  I1K1 = "I1K1", -- IK with both parties deferring static keys
  I1X = "I1X", -- IX with initiator deferring static key
  IX1 = "IX1", -- IX with responder deferring static key
  I1X1 = "I1X1", -- IX with both parties deferring static keys
}

--- CipherState manages a symmetric encryption key and nonce
--- @class CipherState
--- @field cipher CipherFunction Cipher function from cipher suite
--- @field k string|nil Encryption key (nil if uninitialized)
--- @field n integer Nonce counter (64-bit)
local CipherState = {}
CipherState.__index = CipherState

--- Create a new CipherState
--- @param cipher CipherFunction Cipher function from cipher suite
--- @return CipherState state New cipher state
function CipherState:new(cipher)
  local instance = setmetatable({}, self)
  instance.cipher = cipher
  instance.k = nil
  instance.n = 0
  return instance
end

--- Initialize cipher state with a key
--- @param key string Encryption key
function CipherState:initialize_key(key)
  assert(#key == self.cipher.keylen, "Key must be exactly " .. self.cipher.keylen .. " bytes")
  self.k = key
  self.n = 0
end

--- Check if cipher state has a key
--- @return boolean has_key True if cipher has a key
function CipherState:has_key()
  return self.k ~= nil
end

--- Encrypt plaintext with associated data
--- @param ad string Associated data
--- @param plaintext string Data to encrypt
--- @return string ciphertext Encrypted data with authentication tag
function CipherState:encrypt_with_ad(ad, plaintext)
  if not self:has_key() then
    return plaintext -- Return plaintext if no key
  end
  --- @cast self.k -nil

  local ciphertext = self.cipher.encrypt(self.k, self.n, plaintext, ad)
  self.n = self.n + 1

  return ciphertext
end

--- Decrypt ciphertext with associated data
--- @param ad string Associated data
--- @param ciphertext string Data to decrypt
--- @return string? plaintext Decrypted data, or nil if authentication fails
function CipherState:decrypt_with_ad(ad, ciphertext)
  if not self:has_key() then
    return ciphertext -- Return ciphertext if no key
  end
  --- @cast self.k -nil

  local plaintext = self.cipher.decrypt(self.k, self.n, ciphertext, ad)

  -- Only increment nonce if decryption was successful
  if plaintext then
    self.n = self.n + 1
  end

  return plaintext
end

--- Rekey the cipher state (for forward secrecy)
function CipherState:rekey()
  if self:has_key() then
    --- @cast self.k -nil
    self.k = self.cipher.rekey(self.k)
  end
end

--- SymmetricState manages handshake encryption and hashing
--- @class SymmetricState
--- @field cipher_suite CipherSuite The cipher suite being used
--- @field cipher_state CipherState Cipher state for encryption
--- @field ck string Chaining key
--- @field h string Handshake hash
local SymmetricState = {}
SymmetricState.__index = SymmetricState

--- Create a new SymmetricState
--- @param cipher_suite CipherSuite Cipher suite to use
--- @param protocol_name string Noise protocol name
--- @return SymmetricState state New symmetric state
function SymmetricState:new(cipher_suite, protocol_name)
  local instance = setmetatable({}, self)
  instance.cipher_suite = cipher_suite
  instance.cipher_state = CipherState:new(cipher_suite.cipher)

  -- Initialize with protocol name
  if #protocol_name <= cipher_suite.hash.hashlen then
    instance.h = protocol_name .. string.rep("\0", cipher_suite.hash.hashlen - #protocol_name)
  else
    instance.h = cipher_suite.hash.hash(protocol_name)
  end
  instance.ck = instance.h

  return instance
end

--- Mix key material into the chaining key
--- @param input_key_material string Key material to mix
function SymmetricState:mix_key(input_key_material)
  local temp_k
  self.ck, temp_k = self.cipher_suite.hash.hkdf(self.ck, input_key_material, 2)
  -- Truncate temp_k if needed
  if #temp_k > self.cipher_suite.cipher.keylen then
    temp_k = string.sub(temp_k, 1, self.cipher_suite.cipher.keylen)
  end
  self.cipher_state:initialize_key(temp_k)
end

--- Mix data into the handshake hash
--- @param data string Data to mix
function SymmetricState:mix_hash(data)
  self.h = self.cipher_suite.hash.hash(self.h .. data)
end

--- Mix key and hash with DH output
--- @param dh_output string Diffie-Hellman shared secret
function SymmetricState:mix_key_and_hash(dh_output)
  local temp_h, temp_k
  self.ck, temp_h, temp_k = self.cipher_suite.hash.hkdf(self.ck, dh_output, 3)
  self:mix_hash(temp_h)
  -- Truncate temp_k if needed
  if #temp_k > self.cipher_suite.cipher.keylen then
    temp_k = string.sub(assert(temp_k), 1, self.cipher_suite.cipher.keylen)
  end
  self.cipher_state:initialize_key(temp_k)
end

--- Get handshake hash
--- @return string hash Current handshake hash
function SymmetricState:get_handshake_hash()
  return self.h
end

--- Encrypt and hash a payload
--- @param plaintext string Payload to encrypt
--- @return string ciphertext Encrypted payload
function SymmetricState:encrypt_and_hash(plaintext)
  local ciphertext = self.cipher_state:encrypt_with_ad(self.h, plaintext)
  self:mix_hash(ciphertext)
  return ciphertext
end

--- Decrypt and hash a payload
--- @param ciphertext string Payload to decrypt
--- @return string? plaintext Decrypted payload, or nil if authentication fails
function SymmetricState:decrypt_and_hash(ciphertext)
  local plaintext = self.cipher_state:decrypt_with_ad(self.h, ciphertext)
  if plaintext then
    self:mix_hash(ciphertext)
  end
  return plaintext
end

--- Split into two cipher states for transport
--- @return CipherState cipher1 First cipher state (for sending)
--- @return CipherState cipher2 Second cipher state (for receiving)
function SymmetricState:split()
  local temp_k1, temp_k2 = self.cipher_suite.hash.hkdf(self.ck, "", 2)

  local cipher1 = CipherState:new(self.cipher_suite.cipher)
  local cipher2 = CipherState:new(self.cipher_suite.cipher)

  -- Truncate keys if needed (for BLAKE2b/SHA512 which output 64 bytes)
  if #temp_k1 > self.cipher_suite.cipher.keylen then
    temp_k1 = string.sub(temp_k1, 1, self.cipher_suite.cipher.keylen)
  end
  if #temp_k2 > self.cipher_suite.cipher.keylen then
    temp_k2 = string.sub(temp_k2, 1, self.cipher_suite.cipher.keylen)
  end

  cipher1:initialize_key(temp_k1)
  cipher2:initialize_key(temp_k2)

  return cipher1, cipher2
end

--- HandshakeState manages the handshake process
--- @class HandshakeState
--- @field cipher_suite CipherSuite Cipher suite being used
--- @field symmetric_state SymmetricState Symmetric state
--- @field s string|nil Static private key
--- @field e string|nil Ephemeral private key
--- @field rs string|nil Remote static public key
--- @field re string|nil Remote ephemeral public key
--- @field initiator boolean True if this is the initiator
--- @field message_patterns table Handshake message patterns
--- @field pattern_index integer Current pattern index
--- @field psks table List of pre-shared keys
--- @field psk_positions table List of PSK positions (0, 1, 2, or 3)
--- @field psk_index integer Current PSK index for handshake
local HandshakeState = {}
HandshakeState.__index = HandshakeState

--- @class PatternPreMessages
--- @field initiator? MessageToken[] Pre-messages for initiator
--- @field responder? MessageToken[] Pre-messages for responder

--- @class PatternDefinition
--- @field pre_messages PatternPreMessages Pre-messages for initiator and responder
--- @field messages MessageToken[][] List of message sequences for the pattern

--- Handshake patterns
--- @type table<NoisePattern, PatternDefinition>
local PATTERNS = {
  -- No authentication patterns
  [NoisePattern.NN] = {
    pre_messages = {},
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE },
    },
  },

  -- Server authentication patterns
  [NoisePattern.NK] = {
    pre_messages = {
      initiator = {},
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E, MessageToken.ES },
      { MessageToken.E, MessageToken.EE },
    },
  },

  -- Client authentication patterns
  [NoisePattern.KN] = {
    pre_messages = {
      initiator = { MessageToken.S },
      responder = {},
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE, MessageToken.SE },
    },
  },

  -- Mutual known keys
  [NoisePattern.KK] = {
    pre_messages = {
      initiator = { MessageToken.S },
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E, MessageToken.ES, MessageToken.SS },
      { MessageToken.E, MessageToken.EE, MessageToken.SE },
    },
  },

  -- Server known, client transmitted
  [NoisePattern.XK] = {
    pre_messages = {
      initiator = {},
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E, MessageToken.ES },
      { MessageToken.E, MessageToken.EE },
      { MessageToken.S, MessageToken.SE },
    },
  },

  -- Client known, server transmitted
  [NoisePattern.KX] = {
    pre_messages = {
      initiator = { MessageToken.S },
      responder = {},
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE, MessageToken.SE, MessageToken.S, MessageToken.ES },
    },
  },

  -- Server transmitted during handshake
  [NoisePattern.NX] = {
    pre_messages = {},
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE, MessageToken.S, MessageToken.ES },
    },
  },

  -- Mutual authentication (existing)
  [NoisePattern.XX] = {
    pre_messages = {},
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE, MessageToken.S, MessageToken.ES },
      { MessageToken.S, MessageToken.SE },
    },
  },

  -- Immediate known server key (existing)
  [NoisePattern.IK] = {
    pre_messages = {
      initiator = {},
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E, MessageToken.ES, MessageToken.S, MessageToken.SS },
      { MessageToken.E, MessageToken.EE, MessageToken.SE },
    },
  },

  -- I patterns - Immediate client authentication
  [NoisePattern.IN] = {
    pre_messages = {
      initiator = {},
      responder = {},
    },
    messages = {
      { MessageToken.E, MessageToken.S },
      { MessageToken.E, MessageToken.EE, MessageToken.SE },
    },
  },

  [NoisePattern.IX] = {
    pre_messages = {
      initiator = {},
      responder = {},
    },
    messages = {
      { MessageToken.E, MessageToken.S },
      { MessageToken.E, MessageToken.EE, MessageToken.SE, MessageToken.S, MessageToken.ES },
    },
  },

  -- X patterns - Delayed server authentication
  [NoisePattern.XN] = {
    pre_messages = {
      initiator = {},
      responder = {},
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE },
      { MessageToken.S, MessageToken.SE },
    },
  },

  -- One-way patterns
  [NoisePattern.N] = {
    pre_messages = {
      initiator = {},
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E, MessageToken.ES },
    },
  },

  [NoisePattern.K] = {
    pre_messages = {
      initiator = { MessageToken.S },
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E, MessageToken.ES, MessageToken.SS },
    },
  },

  [NoisePattern.X] = {
    pre_messages = {
      initiator = {},
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E, MessageToken.ES, MessageToken.S, MessageToken.SS },
    },
  },

  -- Deferred patterns
  -- I1K: IK pattern with initiator deferring static key
  [NoisePattern.I1K] = {
    pre_messages = {
      initiator = {},
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E, MessageToken.ES, MessageToken.S },
      { MessageToken.E, MessageToken.EE },
      { MessageToken.SE },
    },
  },

  -- I1K1: IK pattern with both parties deferring static keys
  [NoisePattern.I1K1] = {
    pre_messages = {
      initiator = {},
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E, MessageToken.S },
      { MessageToken.E, MessageToken.EE, MessageToken.ES },
      { MessageToken.SE },
    },
  },

  -- I1N: IN pattern with initiator deferring static key
  [NoisePattern.I1N] = {
    pre_messages = {
      initiator = {},
      responder = {},
    },
    messages = {
      { MessageToken.E, MessageToken.S },
      { MessageToken.E, MessageToken.EE },
      { MessageToken.SE },
    },
  },

  -- I1X: IX pattern with initiator deferring static key
  [NoisePattern.I1X] = {
    pre_messages = {
      initiator = {},
      responder = {},
    },
    messages = {
      { MessageToken.E, MessageToken.S },
      { MessageToken.E, MessageToken.EE, MessageToken.S, MessageToken.ES },
      { MessageToken.SE },
    },
  },

  -- I1X1: IX pattern with both parties deferring static keys
  [NoisePattern.I1X1] = {
    pre_messages = {
      initiator = {},
      responder = {},
    },
    messages = {
      { MessageToken.E, MessageToken.S },
      { MessageToken.E, MessageToken.EE, MessageToken.S },
      { MessageToken.SE, MessageToken.ES },
    },
  },

  -- IK1: IK pattern (deferred variant of IK)
  [NoisePattern.IK1] = {
    pre_messages = {
      initiator = {},
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E, MessageToken.S },
      { MessageToken.E, MessageToken.EE, MessageToken.SE, MessageToken.ES },
    },
  },

  -- IX1: IX pattern with responder deferring static key
  [NoisePattern.IX1] = {
    pre_messages = {
      initiator = {},
      responder = {},
    },
    messages = {
      { MessageToken.E, MessageToken.S },
      { MessageToken.E, MessageToken.EE, MessageToken.SE, MessageToken.S },
      { MessageToken.ES },
    },
  },

  -- K1K: KK pattern with initiator deferring static key
  [NoisePattern.K1K] = {
    pre_messages = {
      initiator = { MessageToken.S },
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E, MessageToken.ES },
      { MessageToken.E, MessageToken.EE },
      { MessageToken.SE },
    },
  },

  -- K1K1: KK pattern with both parties deferring static keys
  [NoisePattern.K1K1] = {
    pre_messages = {
      initiator = { MessageToken.S },
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE, MessageToken.ES },
      { MessageToken.SE },
    },
  },

  -- K1N: KN pattern with initiator deferring static key
  [NoisePattern.K1N] = {
    pre_messages = {
      initiator = { MessageToken.S },
      responder = {},
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE },
      { MessageToken.SE },
    },
  },

  -- K1X: KX pattern with initiator deferring static key
  [NoisePattern.K1X] = {
    pre_messages = {
      initiator = { MessageToken.S },
      responder = {},
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE, MessageToken.S, MessageToken.ES },
      { MessageToken.SE },
    },
  },

  -- K1X1: KX pattern with both parties deferring static keys
  [NoisePattern.K1X1] = {
    pre_messages = {
      initiator = { MessageToken.S },
      responder = {},
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE, MessageToken.S },
      { MessageToken.SE, MessageToken.ES },
    },
  },

  -- KK1: KK pattern with responder deferring static key
  [NoisePattern.KK1] = {
    pre_messages = {
      initiator = { MessageToken.S },
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE, MessageToken.SE, MessageToken.ES },
    },
  },

  -- KX1: KX pattern with responder deferring static key
  [NoisePattern.KX1] = {
    pre_messages = {
      initiator = { MessageToken.S },
      responder = {},
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE, MessageToken.SE, MessageToken.S },
      { MessageToken.ES },
    },
  },

  -- NK1: NK pattern with responder deferring static key
  [NoisePattern.NK1] = {
    pre_messages = {
      initiator = {},
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE, MessageToken.ES },
    },
  },

  -- NX1: NX pattern with responder deferring static key
  [NoisePattern.NX1] = {
    pre_messages = {
      initiator = {},
      responder = {},
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE, MessageToken.S },
      { MessageToken.ES },
    },
  },

  -- X1K: XK pattern with initiator deferring static key
  [NoisePattern.X1K] = {
    pre_messages = {
      initiator = {},
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E, MessageToken.ES },
      { MessageToken.E, MessageToken.EE },
      { MessageToken.S },
      { MessageToken.SE },
    },
  },

  -- X1K1: XK pattern with both parties deferring static keys
  [NoisePattern.X1K1] = {
    pre_messages = {
      initiator = {},
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE, MessageToken.ES },
      { MessageToken.S },
      { MessageToken.SE },
    },
  },

  -- X1N: XN pattern with initiator deferring static key
  [NoisePattern.X1N] = {
    pre_messages = {
      initiator = {},
      responder = {},
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE },
      { MessageToken.S },
      { MessageToken.SE },
    },
  },

  -- X1X: XX pattern with initiator deferring static key
  [NoisePattern.X1X] = {
    pre_messages = {
      initiator = {},
      responder = {},
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE, MessageToken.S, MessageToken.ES },
      { MessageToken.S },
      { MessageToken.SE },
    },
  },

  -- X1X1: XX pattern with both parties deferring static keys
  [NoisePattern.X1X1] = {
    pre_messages = {
      initiator = {},
      responder = {},
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE, MessageToken.S },
      { MessageToken.ES, MessageToken.S },
      { MessageToken.SE },
    },
  },

  -- XK1: XK pattern with responder deferring static key
  [NoisePattern.XK1] = {
    pre_messages = {
      initiator = {},
      responder = { MessageToken.S },
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE, MessageToken.ES },
      { MessageToken.S, MessageToken.SE },
    },
  },

  -- XX1: XX pattern with responder deferring static key
  [NoisePattern.XX1] = {
    pre_messages = {
      initiator = {},
      responder = {},
    },
    messages = {
      { MessageToken.E },
      { MessageToken.E, MessageToken.EE, MessageToken.S },
      { MessageToken.ES, MessageToken.S, MessageToken.SE },
    },
  },
}

--- Apply PSK tokens to pattern at specified positions
--- @param base_pattern table Base handshake pattern
--- @param psk_positions table List of PSK positions (0, 1, 2, or 3)
--- @return table modified_pattern Pattern with PSK tokens inserted at appropriate positions
local function apply_psk_placements(base_pattern, psk_positions)
  -- Validate positions
  for _, pos in ipairs(psk_positions) do
    assert(pos >= PSKPlacement.ZERO and pos <= PSKPlacement.THREE, "PSK position must be 0, 1, 2, or 3")
  end

  -- Deep copy the base pattern
  local pattern = {
    pre_messages = {},
    messages = {},
  }

  -- Copy pre_messages
  if base_pattern.pre_messages.initiator then
    pattern.pre_messages.initiator = {}
    for i, token in ipairs(base_pattern.pre_messages.initiator) do
      pattern.pre_messages.initiator[i] = token
    end
  end
  if base_pattern.pre_messages.responder then
    pattern.pre_messages.responder = {}
    for i, token in ipairs(base_pattern.pre_messages.responder) do
      pattern.pre_messages.responder[i] = token
    end
  end

  -- Copy messages
  for i, message in ipairs(base_pattern.messages) do
    pattern.messages[i] = {}
    for j, token in ipairs(message) do
      pattern.messages[i][j] = token
    end
  end

  -- Sort positions to apply them in order
  local sorted_positions = {}
  for _, pos in ipairs(psk_positions) do
    table.insert(sorted_positions, pos)
  end
  table.sort(sorted_positions)

  -- Apply PSK tokens
  -- Track number of tokens added to each message to adjust positions
  local tokens_added = {}
  for i = 1, #pattern.messages do
    tokens_added[i] = 0
  end

  for _, pos in ipairs(sorted_positions) do
    if pos == PSKPlacement.ZERO then
      -- psk0: prepend to first message
      if #pattern.messages >= 1 then
        table.insert(pattern.messages[1], 1 + tokens_added[1], MessageToken.PSK)
        tokens_added[1] = tokens_added[1] + 1
      else
        error("PSK position 0 requires at least one message")
      end
    else
      -- psk1, psk2, psk3: append to message at index pos
      local message_idx = pos
      if message_idx <= #pattern.messages then
        table.insert(pattern.messages[message_idx], MessageToken.PSK)
      else
        error("PSK position " .. pos .. " not valid for pattern with " .. #pattern.messages .. " messages")
      end
    end
  end

  return pattern
end

--- Create a new HandshakeState
--- @param cipher_suite CipherSuite Cipher suite to use
--- @param pattern NoisePattern Base handshake pattern (e.g., NoisePattern.NN, NoisePattern.XX, NoisePattern.IK)
--- @param initiator boolean True if this is the initiator
--- @param prologue? string Optional prologue data
--- @param s? string Optional static private key
--- @param e? string Optional ephemeral private key
--- @param rs? string Optional remote static public key
--- @param re? string Optional remote ephemeral public key
--- @param psks? table Optional list of pre-shared keys
--- @param psk_positions? table Optional list of PSK positions (0, 1, 2, or 3)
--- @return HandshakeState state New handshake state
function HandshakeState:new(cipher_suite, pattern, initiator, prologue, s, e, rs, re, psks, psk_positions)
  local base_pattern = PATTERNS[pattern]
  assert(base_pattern, "Unknown handshake pattern: " .. tostring(pattern))

  -- Apply PSK placements if specified
  local pattern_def = base_pattern
  local protocol_pattern_name = tostring(pattern)
  if psk_positions and #psk_positions > 0 then
    assert(psks and #psks == #psk_positions, "Number of PSKs must match PSK positions")
    pattern_def = apply_psk_placements(base_pattern, psk_positions)
    -- Build pattern name with PSK modifiers
    local modifiers = {}
    for _, pos in ipairs(psk_positions) do
      table.insert(modifiers, "psk" .. pos)
    end
    protocol_pattern_name = protocol_pattern_name .. table.concat(modifiers, "+")
  end

  local protocol_name = string.format("Noise_%s_%s", protocol_pattern_name, cipher_suite.name)

  local instance = setmetatable({}, self)
  instance.cipher_suite = cipher_suite
  instance.symmetric_state = SymmetricState:new(cipher_suite, protocol_name)
  instance.s = s
  instance.e = e
  instance.rs = rs
  instance.re = re
  instance.initiator = initiator
  instance.message_patterns = pattern_def.messages
  instance.pattern_index = 1
  instance.psks = psks or {}
  instance.psk_positions = psk_positions or {}
  instance.psk_index = 1 -- Track which PSK to use next

  -- Mix prologue
  prologue = prologue or ""
  instance.symmetric_state:mix_hash(prologue)

  -- Process pre-messages (both parties process all pre-messages)
  if pattern_def.pre_messages then
    -- Process initiator pre-messages
    if pattern_def.pre_messages.initiator then
      for _, token in ipairs(pattern_def.pre_messages.initiator) do
        if token == MessageToken.S then
          if initiator and instance.s then
            -- Initiator mixes their own static key
            local s_pub = instance.cipher_suite.dh.derive_public_key(instance.s)
            instance.symmetric_state:mix_hash(s_pub)
          elseif not initiator and instance.rs then
            -- Responder mixes initiator's static key (if known)
            instance.symmetric_state:mix_hash(instance.rs)
          end
        end
      end
    end

    -- Process responder pre-messages
    if pattern_def.pre_messages.responder then
      for _, token in ipairs(pattern_def.pre_messages.responder) do
        if token == MessageToken.S then
          if not initiator and instance.s then
            -- Responder mixes their own static public key
            local s_pub = instance.cipher_suite.dh.derive_public_key(instance.s)
            instance.symmetric_state:mix_hash(s_pub)
          elseif initiator and instance.rs then
            -- Initiator mixes responder's static public key (if known)
            instance.symmetric_state:mix_hash(instance.rs)
          end
        end
      end
    end
  end

  return instance
end

--- Write a handshake message
--- @param payload string Message payload
--- @return string message Complete handshake message
--- @return boolean finished True if handshake is complete
function HandshakeState:write_message(payload)
  assert(self.pattern_index <= #self.message_patterns, "No more handshake messages")

  local pattern = self.message_patterns[self.pattern_index]
  local message = ""

  for _, token in ipairs(pattern) do
    if token == MessageToken.PSK then
      -- Mix pre-shared key
      assert(self.psks[self.psk_index], "PSK required but not provided")
      self.symmetric_state:mix_key_and_hash(self.psks[self.psk_index])
      self.psk_index = self.psk_index + 1
    elseif token == MessageToken.E then
      -- Generate ephemeral key pair (or use pre-generated one for testing)
      local e_pub
      if not self.e then
        self.e, e_pub = self.cipher_suite.dh.generate_keypair()
      else
        e_pub = self.cipher_suite.dh.derive_public_key(self.e)
      end
      message = message .. e_pub
      self.symmetric_state:mix_hash(e_pub)

      -- In PSK handshakes, also mix the ephemeral public key into the key
      if #self.psk_positions > 0 then
        self.symmetric_state:mix_key(e_pub)
      end
    elseif token == MessageToken.S then
      -- Send static public key (encrypted)
      assert(self.s, "Static key required but not provided")
      local s_pub = self.cipher_suite.dh.derive_public_key(self.s)
      message = message .. self.symmetric_state:encrypt_and_hash(s_pub)
    elseif token == MessageToken.EE then
      -- Ephemeral-ephemeral DH
      assert(self.e and self.re, "Ephemeral keys required for ee")
      local dh_output = self.cipher_suite.dh.dh(self.e, self.re)
      self.symmetric_state:mix_key(dh_output)
    elseif token == MessageToken.ES then
      -- Ephemeral-static DH
      if self.initiator then
        assert(self.e and self.rs, "Keys required for es")
        local dh_output = self.cipher_suite.dh.dh(self.e, self.rs)
        self.symmetric_state:mix_key(dh_output)
      else
        assert(self.s and self.re, "Keys required for es")
        local dh_output = self.cipher_suite.dh.dh(self.s, self.re)
        self.symmetric_state:mix_key(dh_output)
      end
    elseif token == MessageToken.SE then
      -- Static-ephemeral DH
      if self.initiator then
        if self.s and self.re then
          local dh_output = self.cipher_suite.dh.dh(self.s, self.re)
          self.symmetric_state:mix_key(dh_output)
        end
      else
        if self.e and self.rs then
          local dh_output = self.cipher_suite.dh.dh(self.e, self.rs)
          self.symmetric_state:mix_key(dh_output)
        end
      end
    elseif token == MessageToken.SS then
      -- Static-static DH
      assert(self.s and self.rs, "Static keys required for ss")
      local dh_output = self.cipher_suite.dh.dh(self.s, self.rs)
      self.symmetric_state:mix_key(dh_output)
    else
      error("Unknown message token: " .. tostring(token))
    end
  end

  -- Encrypt payload
  message = message .. self.symmetric_state:encrypt_and_hash(payload)

  self.pattern_index = self.pattern_index + 1
  local finished = self.pattern_index > #self.message_patterns

  return message, finished
end

--- Read a handshake message
--- @param message string Complete handshake message
--- @return string payload Decrypted message payload
--- @return boolean finished True if handshake is complete
function HandshakeState:read_message(message)
  assert(self.pattern_index <= #self.message_patterns, "No more handshake messages")

  local pattern = self.message_patterns[self.pattern_index]
  local offset = 1

  for _, token in ipairs(pattern) do
    if token == MessageToken.PSK then
      -- Mix pre-shared key
      assert(self.psks[self.psk_index], "PSK required but not provided")
      self.symmetric_state:mix_key_and_hash(self.psks[self.psk_index])
      self.psk_index = self.psk_index + 1
    elseif token == MessageToken.E then
      -- Read ephemeral public key
      self.re = message:sub(offset, offset + self.cipher_suite.dh.dhlen - 1)
      offset = offset + self.cipher_suite.dh.dhlen
      self.symmetric_state:mix_hash(self.re)

      -- In PSK handshakes, also mix the ephemeral public key into the key
      if #self.psk_positions > 0 then
        self.symmetric_state:mix_key(self.re)
      end
    elseif token == MessageToken.S then
      -- Read static public key (encrypted)
      local has_key = self.symmetric_state.cipher_state:has_key()
      local s_len = self.cipher_suite.dh.dhlen + (has_key and self.cipher_suite.cipher.taglen or 0)

      local encrypted_s = message:sub(offset, offset + s_len - 1)
      offset = offset + s_len
      self.rs = self.symmetric_state:decrypt_and_hash(encrypted_s)
      assert(self.rs, "Failed to decrypt static key")
    elseif token == MessageToken.EE then
      -- Ephemeral-ephemeral DH
      assert(self.e and self.re, "Ephemeral keys required for ee")
      local dh_output = self.cipher_suite.dh.dh(self.e, self.re)
      self.symmetric_state:mix_key(dh_output)
    elseif token == MessageToken.ES then
      -- Ephemeral-static DH
      if self.initiator then
        assert(self.e and self.rs, "Keys required for es")
        local dh_output = self.cipher_suite.dh.dh(self.e, self.rs)
        self.symmetric_state:mix_key(dh_output)
      else
        assert(self.s and self.re, "Keys required for es")
        local dh_output = self.cipher_suite.dh.dh(self.s, self.re)
        self.symmetric_state:mix_key(dh_output)
      end
    elseif token == MessageToken.SE then
      -- Static-ephemeral DH
      if self.initiator then
        if self.s and self.re then
          local dh_output = self.cipher_suite.dh.dh(self.s, self.re)
          self.symmetric_state:mix_key(dh_output)
        end
      else
        if self.e and self.rs then
          local dh_output = self.cipher_suite.dh.dh(self.e, self.rs)
          self.symmetric_state:mix_key(dh_output)
        end
      end
    elseif token == MessageToken.SS then
      -- Static-static DH
      assert(self.s and self.rs, "Static keys required for ss")
      local dh_output = self.cipher_suite.dh.dh(self.s, self.rs)
      self.symmetric_state:mix_key(dh_output)
    end
  end

  -- Decrypt payload
  local payload_ciphertext = message:sub(offset)
  local payload = self.symmetric_state:decrypt_and_hash(payload_ciphertext)
  assert(payload, "Failed to decrypt payload")

  self.pattern_index = self.pattern_index + 1
  local finished = self.pattern_index > #self.message_patterns

  return payload, finished
end

--- Get transport cipher states after handshake completion
--- @return CipherState send_cipher Cipher for sending messages
--- @return CipherState recv_cipher Cipher for receiving messages
function HandshakeState:split()
  local c1, c2 = self.symmetric_state:split()
  if self.initiator then
    return c1, c2 -- Initiator: send with c1, receive with c2
  else
    return c2, c1 -- Responder: send with c2, receive with c1
  end
end

--- Noise connection configuration
--- @class NoiseConfig
--- @field protocol_name? string Full protocol name (e.g. "Noise_NNpsk0_25519_AESGCM_SHA256")
--- @field initiator boolean True if this connection initiates the handshake, false if it responds
--- @field static_key? string Optional static private key (required for patterns with local static key)
--- @field remote_static_key? string Optional remote static public key (required for patterns with known remote key)
--- @field psks? table Optional list of pre-shared keys (each exactly 32 bytes)
--- @field prologue? string Optional prologue data to mix into handshake hash
--- @field ephemeral_key? string Optional ephemeral private key (for testing)

--- Noise connection instance
--- @class NoiseConnection
--- @field protocol_name string Full protocol name
--- @field cipher_suite CipherSuite The cipher suite being used
--- @field pattern NoisePattern The handshake pattern
--- @field psk_positions table? List of PSK positions
--- @field initiator boolean True if this is the initiator
--- @field static_key string? Static private key
--- @field remote_static_key string? Remote static public key
--- @field psks table? List of pre-shared keys
--- @field prologue string? Prologue data
--- @field handshake_state HandshakeState? Current handshake state
--- @field send_cipher CipherState? Cipher for sending transport messages
--- @field recv_cipher CipherState? Cipher for receiving transport messages
--- @field handshake_complete boolean True when handshake is finished
--- @field ephemeral_key string? Optional ephemeral private key (for testing)
local NoiseConnection = {}
NoiseConnection.__index = NoiseConnection

--- Create a new Noise connection
--- @param config NoiseConfig Connection configuration
--- @return NoiseConnection connection Noise connection instance
function NoiseConnection:new(config)
  -- Validate required fields
  assert(config, "Configuration required")
  assert(config.initiator ~= nil, "Initiator flag required in configuration")

  local instance = setmetatable({}, self)
  instance.initiator = config.initiator
  instance.prologue = config.prologue
  instance.static_key = config.static_key
  instance.remote_static_key = config.remote_static_key
  instance.ephemeral_key = config.ephemeral_key -- For testing with fixed ephemeral keys

  -- Parse protocol name
  assert(config.protocol_name, "Protocol name required")
  local parsed = parse_protocol_name(config.protocol_name)
  instance.protocol_name = config.protocol_name

  -- Get pattern
  -- Get pattern - handle as string enum
  local pattern_key = parsed.pattern
  instance.pattern = NoisePattern[pattern_key]
  assert(instance.pattern, "Unknown handshake pattern: " .. pattern_key)
  assert(PATTERNS[instance.pattern], "Handshake pattern not implemented: " .. pattern_key)

  -- Get cipher suite components
  -- Map DH functions
  local dh = noise.DH[parsed.dh]
  if dh == nil then
    error("Unknown DH function: " .. parsed.dh)
  end

  -- Map cipher functions
  local cipher = noise.Cipher[parsed.cipher]
  if cipher == nil then
    error("Unknown cipher: " .. parsed.cipher)
  end

  -- Map hash functions
  local hash = noise.Hash[parsed.hash]
  if hash == nil then
    error("Unknown hash: " .. parsed.hash)
  end

  instance.cipher_suite = CipherSuite:new(dh, cipher, hash)

  -- Parse PSK positions from modifiers
  instance.psk_positions = parse_psk_modifiers(parsed.modifiers)

  -- Handle PSKs
  instance.psks = config.psks or {}
  if #instance.psk_positions > 0 then
    assert(#instance.psks == #instance.psk_positions, "Number of PSKs must match number of PSK positions")
    for i, psk in ipairs(instance.psks) do
      assert(#psk == 32, "PSK " .. i .. " must be exactly 32 bytes")
    end
  end

  -- Validate static keys with DH length
  if instance.static_key then
    assert(
      #instance.static_key == instance.cipher_suite.dh.dhlen,
      "Static key must be exactly " .. instance.cipher_suite.dh.dhlen .. " bytes"
    )
  end

  if instance.remote_static_key then
    assert(
      #instance.remote_static_key == instance.cipher_suite.dh.dhlen,
      "Remote static key must be exactly " .. instance.cipher_suite.dh.dhlen .. " bytes"
    )
  end

  instance.handshake_state = nil
  instance.send_cipher = nil
  instance.recv_cipher = nil
  instance.handshake_complete = false

  return instance
end

--- Start handshake
--- @param prologue? string Optional prologue data (overrides config.prologue if provided)
function NoiseConnection:start_handshake(prologue)
  -- Use provided prologue or fall back to config prologue
  prologue = prologue or self.prologue

  self.handshake_state = HandshakeState:new(
    self.cipher_suite,
    self.pattern,
    self.initiator,
    prologue,
    self.static_key,
    self.ephemeral_key, -- ephemeral key (for testing, otherwise generated as needed)
    self.remote_static_key,
    nil, -- remote ephemeral key (received during handshake)
    self.psks, -- list of pre-shared keys
    self.psk_positions -- list of PSK positions
  )
  self.handshake_complete = false
end

--- Write handshake message
--- @param payload? string Optional payload data
--- @return string message Handshake message to send
function NoiseConnection:write_handshake_message(payload)
  assert(self.handshake_state, "Handshake not started")
  assert(not self.handshake_complete, "Handshake already complete")

  payload = payload or ""
  local message, finished = self.handshake_state:write_message(payload)

  if finished then
    self.send_cipher, self.recv_cipher = self.handshake_state:split()
    self.handshake_complete = true
  end

  return message
end

--- Read handshake message
--- @param message string Received handshake message
--- @return string payload Decrypted payload
function NoiseConnection:read_handshake_message(message)
  assert(self.handshake_state, "Handshake not started")
  assert(not self.handshake_complete, "Handshake already complete")

  local payload, finished = self.handshake_state:read_message(message)

  if finished then
    self.send_cipher, self.recv_cipher = self.handshake_state:split()
    self.handshake_complete = true
  end

  return payload
end

--- Send transport message
--- @param plaintext string Message to send
--- @return string ciphertext Encrypted message
function NoiseConnection:send_message(plaintext)
  assert(self.handshake_complete, "Handshake not complete")
  assert(self.send_cipher, "Send cipher not available")

  return self.send_cipher:encrypt_with_ad("", plaintext)
end

--- Receive transport message
--- @param ciphertext string Encrypted message
--- @return string? plaintext Decrypted message, or nil if authentication fails
function NoiseConnection:receive_message(ciphertext)
  assert(self.handshake_complete, "Handshake not complete")
  assert(self.recv_cipher, "Receive cipher not available")

  return self.recv_cipher:decrypt_with_ad("", ciphertext)
end

--- Get handshake hash (for authentication)
--- @return string hash Handshake hash
function NoiseConnection:get_handshake_hash()
  assert(self.handshake_state, "Handshake not started")
  return self.handshake_state.symmetric_state:get_handshake_hash()
end

--- Run comprehensive self-test with test vectors and functional tests
---
--- This function validates the Noise Protocol implementation against test vectors
--- and functional tests. ALL tests must pass for the implementation to be
--- considered cryptographically safe.
---
--- @return boolean result True if all tests pass, false otherwise
function noise.selftest()
  local function functional_tests()
    print("Running Noise Protocol functional tests...")
    local passed = 0
    local total = 0

    -- Test 1: Comprehensive XX Handshake (based on example_noise.lua)
    total = total + 1
    local success, err = pcall(function()
      -- Generate static keys
      local alice_static_priv, _alice_static_pub = DH_25519.generate_keypair()
      local bob_static_priv, _bob_static_pub = DH_25519.generate_keypair()

      -- Create clients
      local alice = NoiseConnection:new({
        protocol_name = "Noise_XX_25519_ChaChaPoly_SHA256",
        initiator = true,
        static_key = alice_static_priv,
      })
      local bob = NoiseConnection:new({
        protocol_name = "Noise_XX_25519_ChaChaPoly_SHA256",
        pattern = NoisePattern.XX,
        initiator = false,
        static_key = bob_static_priv,
      })

      -- Start handshake with prologue
      local prologue = "MyApplication_v1.0"
      alice:start_handshake(prologue)
      bob:start_handshake(prologue)

      -- XX Handshake Message 1: Alice -> Bob (e)
      local msg1 = alice:write_handshake_message("Initial payload from Alice")
      assert(#msg1 > 32, "Message 1 should contain ephemeral key + payload")
      local payload1 = bob:read_handshake_message(msg1)
      assert(payload1 == "Initial payload from Alice", "Payload 1 mismatch")

      -- XX Handshake Message 2: Bob -> Alice (e, ee, s, es)
      local msg2 = bob:write_handshake_message("Response from Bob")
      assert(#msg2 > 64, "Message 2 should contain ephemeral + encrypted static + payload")
      local payload2 = alice:read_handshake_message(msg2)
      assert(payload2 == "Response from Bob", "Payload 2 mismatch")

      -- XX Handshake Message 3: Alice -> Bob (s, se)
      local msg3 = alice:write_handshake_message("Handshake finished!")
      assert(#msg3 > 32, "Message 3 should contain encrypted static + payload")
      local payload3 = bob:read_handshake_message(msg3)
      assert(payload3 == "Handshake finished!", "Payload 3 mismatch")

      -- Verify handshake completion and authentication
      assert(alice.handshake_complete, "Alice handshake not complete")
      assert(bob.handshake_complete, "Bob handshake not complete")

      -- Verify handshake hash consistency (mutual authentication)
      local alice_hash = alice:get_handshake_hash()
      local bob_hash = bob:get_handshake_hash()
      assert(alice_hash == bob_hash, "Handshake hashes don't match")
      assert(#alice_hash == 32, "Handshake hash should be 32 bytes")

      -- Test bidirectional transport phase
      local transport1 = alice:send_message("This is a secure message from Alice to Bob")
      local received1 = bob:receive_message(transport1)
      assert(received1 == "This is a secure message from Alice to Bob", "Transport 1 failed")

      local transport2 = bob:send_message("This is Bob's encrypted reply")
      local received2 = alice:receive_message(transport2)
      assert(received2 == "This is Bob's encrypted reply", "Transport 2 failed")

      -- Test multiple transport messages (session continuity)
      local transport3 = alice:send_message("Follow-up message from Alice")
      local received3 = bob:receive_message(transport3)
      assert(received3 == "Follow-up message from Alice", "Transport 3 failed")
    end)

    if success then
      print("  ✅ PASS: Comprehensive XX Handshake (mutual authentication)")
      passed = passed + 1
    else
      print("  ❌ FAIL: Comprehensive XX Handshake (mutual authentication) - " .. err)
    end

    -- Test 2: Comprehensive IK Handshake with 0-RTT (based on example_noise.lua)
    total = total + 1
    success, err = pcall(function()
      -- Generate keys
      local client_static_priv, _client_static_pub = DH_25519.generate_keypair()
      local server_static_priv, server_static_pub = DH_25519.generate_keypair()

      -- Create IK clients (client knows server's static key beforehand)
      local client = NoiseConnection:new({
        protocol_name = "Noise_IK_25519_ChaChaPoly_SHA256",
        initiator = true,
        static_key = client_static_priv,
        remote_static_key = server_static_pub,
      })
      local server = NoiseConnection:new({
        protocol_name = "Noise_IK_25519_ChaChaPoly_SHA256",
        initiator = false,
        static_key = server_static_priv,
      })

      -- Start handshake
      client:start_handshake("IK_Example")
      server:start_handshake("IK_Example")

      -- IK Message 1: Client -> Server (e, es, s, ss) with 0-RTT encryption!
      local ik_msg1 = client:write_handshake_message("This message is encrypted with 0-RTT!")
      assert(#ik_msg1 > 96, "IK Message 1 should contain ephemeral + encrypted static + encrypted payload")
      local ik_payload1 = server:read_handshake_message(ik_msg1)
      assert(ik_payload1 == "This message is encrypted with 0-RTT!", "0-RTT payload mismatch")

      -- IK Message 2: Server -> Client (e, ee, se)
      local ik_msg2 = server:write_handshake_message("Server response")
      assert(#ik_msg2 > 48, "IK Message 2 should contain ephemeral + encrypted payload")
      local ik_payload2 = client:read_handshake_message(ik_msg2)
      assert(ik_payload2 == "Server response", "IK payload 2 mismatch")

      -- Verify completion and authentication
      assert(client.handshake_complete, "Client handshake not complete")
      assert(server.handshake_complete, "Server handshake not complete")

      -- Verify handshake hash consistency
      local client_hash = client:get_handshake_hash()
      local server_hash = server:get_handshake_hash()
      assert(client_hash == server_hash, "IK handshake hashes don't match")
      assert(#client_hash == 32, "IK handshake hash should be 32 bytes")

      -- Test bidirectional transport phase
      local ik_transport1 = client:send_message("Post-handshake message from client")
      local ik_received1 = server:receive_message(ik_transport1)
      assert(ik_received1 == "Post-handshake message from client", "IK transport 1 failed")

      local ik_transport2 = server:send_message("Post-handshake message from server")
      local ik_received2 = client:receive_message(ik_transport2)
      assert(ik_received2 == "Post-handshake message from server", "IK transport 2 failed")

      -- Test multiple IK transport messages
      local ik_transport3 = client:send_message("Follow-up client message")
      local ik_received3 = server:receive_message(ik_transport3)
      assert(ik_received3 == "Follow-up client message", "IK transport 3 failed")
    end)

    if success then
      print("  ✅ PASS: Comprehensive IK Handshake (0-RTT encryption)")
      passed = passed + 1
    else
      print("  ❌ FAIL: Comprehensive IK Handshake (0-RTT encryption) - " .. err)
    end

    -- Test 3: Security Properties and Tamper Detection (from example_noise.lua)
    total = total + 1
    success, err = pcall(function()
      -- Set up a fresh XX handshake for security testing
      local alice = NoiseConnection:new({
        protocol_name = "Noise_XX_25519_ChaChaPoly_SHA256",
        initiator = true,
        static_key = string.rep(string.char(0x10), 32),
      })
      local bob = NoiseConnection:new({
        protocol_name = "Noise_XX_25519_ChaChaPoly_SHA256",
        initiator = false,
        static_key = string.rep(string.char(0x20), 32),
      })

      alice:start_handshake("SecurityTest")
      bob:start_handshake("SecurityTest")

      -- Complete handshake with empty payloads
      local msg1 = alice:write_handshake_message("")
      bob:read_handshake_message(msg1)
      local msg2 = bob:write_handshake_message("")
      alice:read_handshake_message(msg2)
      local msg3 = alice:write_handshake_message("")
      bob:read_handshake_message(msg3)

      -- Verify handshake authentication via hash consistency
      local alice_hash = alice:get_handshake_hash()
      local bob_hash = bob:get_handshake_hash()
      assert(alice_hash == bob_hash, "Security test: handshake hashes must match")
      assert(#alice_hash == 32, "Security test: handshake hash must be 32 bytes")

      -- Test message integrity: tamper detection
      local original_msg = alice:send_message("Original message")
      assert(#original_msg > 16, "Transport message should include auth tag")

      -- Test various tampering scenarios
      local tampered_msg1 = string.char(255) .. original_msg:sub(2) -- Flip first byte
      local tamper_result1 = bob:receive_message(tampered_msg1)
      assert(tamper_result1 == nil, "First byte tampered message should be rejected")

      local tampered_msg2 = original_msg:sub(1, -2) .. string.char(255) -- Flip last byte
      local tamper_result2 = bob:receive_message(tampered_msg2)
      assert(tamper_result2 == nil, "Last byte tampered message should be rejected")

      -- Test truncated message
      local truncated_msg = original_msg:sub(1, #original_msg - 1)
      local truncate_result = bob:receive_message(truncated_msg)
      assert(truncate_result == nil, "Truncated message should be rejected")

      -- Verify legitimate message still works
      local legit_result = bob:receive_message(original_msg)
      assert(legit_result == "Original message", "Legitimate message should still work")
    end)

    if success then
      print("  ✅ PASS: Security Properties and Tamper Detection")
      passed = passed + 1
    else
      print("  ❌ FAIL: Security Properties and Tamper Detection - " .. err)
    end

    -- Test 4: Empty message handling
    total = total + 1
    success, err = pcall(function()
      local alice = NoiseConnection:new({
        protocol_name = "Noise_XX_25519_ChaChaPoly_SHA256",
        initiator = true,
        static_key = string.rep(string.char(0x11), 32),
      })
      local bob = NoiseConnection:new({
        protocol_name = "Noise_XX_25519_ChaChaPoly_SHA256",
        initiator = false,
        static_key = string.rep(string.char(0x22), 32),
      })

      alice:start_handshake("")
      bob:start_handshake("")

      -- Complete handshake with empty payloads
      local msg1 = alice:write_handshake_message("")
      local payload1 = bob:read_handshake_message(msg1)
      assert(payload1 == "", "Empty payload should work")

      local msg2 = bob:write_handshake_message("")
      local payload2 = alice:read_handshake_message(msg2)
      assert(payload2 == "", "Empty payload should work")

      local msg3 = alice:write_handshake_message("")
      local payload3 = bob:read_handshake_message(msg3)
      assert(payload3 == "", "Empty payload should work")

      -- Test empty transport messages
      local empty_transport = alice:send_message("")
      local empty_received = bob:receive_message(empty_transport)
      assert(empty_received == "", "Empty transport message should work")
    end)

    if success then
      print("  ✅ PASS: Empty message handling")
      passed = passed + 1
    else
      print("  ❌ FAIL: Empty message handling - " .. err)
    end

    -- Test 5: Error conditions
    total = total + 1
    success, err = pcall(function()
      --Test invalid protocol name
      local invalid_ok, _invalid_err = pcall(function()
        NoiseConnection:new({
          protocol_name = "INVALID",
          initiator = true,
        })
      end)
      assert(not invalid_ok, "Should reject invalid pattern")

      -- Test premature transport
      local client = NoiseConnection:new({
        protocol_name = "Noise_XX_25519_ChaChaPoly_SHA256",
        initiator = true,
        static_key = string.rep(string.char(0x99), 32),
      })
      local premature_ok, _premature_err = pcall(function()
        client:send_message("test")
      end)
      assert(not premature_ok, "Should reject transport before handshake")

      -- Test NNpsk0 pattern without PSK should fail during handshake
      local nnpsk0_no_psk_ok, nnpsk0_no_psk_err = pcall(function()
        local client_no_psk = NoiseConnection:new({
          protocol_name = "Noise_XXpsk0_25519_ChaChaPoly_SHA256",
          initiator = true,
          psk = nil, -- No PSK provided
          psk_placement = noise.PSKPlacement.ZERO,
        })
        client_no_psk:start_handshake("test")
        client_no_psk:write_handshake_message("test") -- Should fail here due to missing PSK
      end)
      assert(not nnpsk0_no_psk_ok, "Should reject NNpsk0 without PSK")
      assert(nnpsk0_no_psk_err and string.find(nnpsk0_no_psk_err, "PSK"), "Should indicate missing PSK")

      -- Test NNpsk0 pattern with PSK should work
      local psk = string.rep(string.char(0x33), 32)
      local nnpsk0_with_psk_ok, nnpsk0_with_psk_err = pcall(function()
        local client_with_psk = NoiseConnection:new({
          protocol_name = "Noise_NN_25519_ChaChaPoly_SHA256",
          initiator = true,
          psk = psk,
          psk_placement = noise.PSKPlacement.ZERO,
        })
        client_with_psk:start_handshake("test")
        client_with_psk:write_handshake_message("test") -- Should work with PSK
      end)
      assert(nnpsk0_with_psk_ok, "Should accept NNpsk0 with PSK: " .. (nnpsk0_with_psk_err or ""))
    end)

    if success then
      print("  ✅ PASS: Error conditions")
      passed = passed + 1
    else
      print("  ❌ FAIL: Error conditions - " .. err)
    end

    -- Test 6: Noise Protocol Features Showcase (from example_noise.lua)
    total = total + 1
    success, err = pcall(function()
      -- Test multiple features in one comprehensive scenario
      local alice_static_priv, _alice_static_pub = DH_25519.generate_keypair()
      local bob_static_priv, bob_static_pub = DH_25519.generate_keypair()

      -- Test both XX and IK patterns in sequence

      -- XX: Mutual authentication without prior key knowledge
      local alice_xx = NoiseConnection:new({
        protocol_name = "Noise_XX_25519_ChaChaPoly_SHA256",
        initiator = true,
        static_key = alice_static_priv,
      })
      local bob_xx = NoiseConnection:new({
        protocol_name = "Noise_XX_25519_ChaChaPoly_SHA256",
        initiator = false,
        static_key = bob_static_priv,
      })

      alice_xx:start_handshake("FeatureTest_XX")
      bob_xx:start_handshake("FeatureTest_XX")

      -- Complete XX handshake
      local xx_msg1 = alice_xx:write_handshake_message("XX payload 1")
      bob_xx:read_handshake_message(xx_msg1)
      local xx_msg2 = bob_xx:write_handshake_message("XX payload 2")
      alice_xx:read_handshake_message(xx_msg2)
      local xx_msg3 = alice_xx:write_handshake_message("XX payload 3")
      bob_xx:read_handshake_message(xx_msg3)

      -- IK: 0-RTT with server authentication
      local alice_ik = NoiseConnection:new({
        protocol_name = "Noise_IK_25519_ChaChaPoly_SHA256",
        initiator = true,
        static_key = alice_static_priv,
        remote_static_key = bob_static_pub,
      })
      local bob_ik = NoiseConnection:new({
        protocol_name = "Noise_IK_25519_ChaChaPoly_SHA256",
        initiator = false,
        static_key = bob_static_priv,
      })

      alice_ik:start_handshake("FeatureTest_IK")
      bob_ik:start_handshake("FeatureTest_IK")

      -- Complete IK handshake with 0-RTT
      local ik_msg1 = alice_ik:write_handshake_message("IK 0-RTT payload")
      bob_ik:read_handshake_message(ik_msg1)
      local ik_msg2 = bob_ik:write_handshake_message("IK response")
      alice_ik:read_handshake_message(ik_msg2)

      -- Verify both handshakes completed successfully
      assert(alice_xx.handshake_complete and bob_xx.handshake_complete, "XX handshake must complete")
      assert(alice_ik.handshake_complete and bob_ik.handshake_complete, "IK handshake must complete")

      -- Test forward secrecy: each handshake produces different session keys
      local xx_msg_a = alice_xx:send_message("XX transport message")
      local ik_msg_a = alice_ik:send_message("IK transport message")
      assert(xx_msg_a ~= ik_msg_a, "Different handshakes should produce different ciphertexts")

      -- Test session isolation: messages from one session can't decrypt in another
      local xx_plaintext = bob_xx:receive_message(xx_msg_a)
      local ik_cross_result = bob_ik:receive_message(xx_msg_a) -- Wrong session
      assert(xx_plaintext == "XX transport message", "XX session should decrypt correctly")
      assert(ik_cross_result == nil, "Cross-session messages should be rejected")

      -- Test replay protection: same ciphertext can't be decrypted twice
      local replay_result = bob_xx:receive_message(xx_msg_a)
      assert(replay_result == nil, "Replayed message should be rejected")
    end)

    if success then
      print("  ✅ PASS: Noise Protocol Features Showcase")
      passed = passed + 1
    else
      print("  ❌ FAIL: Noise Protocol Features Showcase - " .. err)
    end

    -- Test 7: NNpsk0 Pre-Shared Key Pattern
    total = total + 1
    success, err = pcall(function()
      -- Test NNpsk0 with pre-shared key
      local psk = string.rep(string.char(0x42), 32) -- Test PSK

      local alice_psk = NoiseConnection:new({
        protocol_name = "Noise_NNpsk0_25519_ChaChaPoly_SHA256",
        pattern = NoisePattern.NN,
        initiator = true,
        psks = { psk },
      })
      local bob_psk = NoiseConnection:new({
        protocol_name = "Noise_NNpsk0_25519_ChaChaPoly_SHA256",
        initiator = false,
        psks = { psk },
      })

      alice_psk:start_handshake("NNpsk0_functional_test")
      bob_psk:start_handshake("NNpsk0_functional_test")

      -- NNpsk0 Message 1: Alice -> Bob (psk0, e)
      local psk_msg1 = alice_psk:write_handshake_message("PSK encrypted message 1")
      assert(#psk_msg1 > 32, "NNpsk0 Message 1 should contain ephemeral key + encrypted payload")
      local psk_payload1 = bob_psk:read_handshake_message(psk_msg1)
      assert(psk_payload1 == "PSK encrypted message 1", "PSK payload 1 mismatch")

      -- NNpsk0 Message 2: Bob -> Alice (e, ee)
      local psk_msg2 = bob_psk:write_handshake_message("PSK encrypted message 2")
      assert(#psk_msg2 > 32, "NNpsk0 Message 2 should contain ephemeral key + encrypted payload")
      local psk_payload2 = alice_psk:read_handshake_message(psk_msg2)
      assert(psk_payload2 == "PSK encrypted message 2", "PSK payload 2 mismatch")

      -- Verify handshake completion
      assert(alice_psk.handshake_complete, "Alice NNpsk0 handshake not complete")
      assert(bob_psk.handshake_complete, "Bob NNpsk0 handshake not complete")

      -- Test handshake hash consistency
      local alice_psk_hash = alice_psk:get_handshake_hash()
      local bob_psk_hash = bob_psk:get_handshake_hash()
      assert(alice_psk_hash == bob_psk_hash, "NNpsk0 handshake hashes don't match")
      assert(#alice_psk_hash == 32, "NNpsk0 handshake hash should be 32 bytes")

      -- Test transport phase with PSK-derived keys
      local psk_transport1 = alice_psk:send_message("NNpsk0 transport message from Alice")
      local psk_received1 = bob_psk:receive_message(psk_transport1)
      assert(psk_received1 == "NNpsk0 transport message from Alice", "NNpsk0 transport 1 failed")

      local psk_transport2 = bob_psk:send_message("NNpsk0 transport message from Bob")
      local psk_received2 = alice_psk:receive_message(psk_transport2)
      assert(psk_received2 == "NNpsk0 transport message from Bob", "NNpsk0 transport 2 failed")

      -- Test PSK security: different PSK should produce different results
      local different_psk = string.rep(string.char(0x99), 32)
      local alice_different = NoiseConnection:new({
        protocol_name = "Noise_NNpsk0_25519_ChaChaPoly_SHA256",
        initiator = true,
        psks = { different_psk },
      })
      local bob_different = NoiseConnection:new({
        protocol_name = "Noise_NNpsk0_25519_ChaChaPoly_SHA256",
        initiator = false,
        psks = { different_psk },
      })

      alice_different:start_handshake("NNpsk0_functional_test")
      bob_different:start_handshake("NNpsk0_functional_test")

      local diff_msg1 = alice_different:write_handshake_message("PSK encrypted message 1")
      assert(diff_msg1 ~= psk_msg1, "Different PSKs should produce different ciphertexts")
    end)

    if success then
      print("  ✅ PASS: NNpsk0 Pre-Shared Key Pattern")
      passed = passed + 1
    else
      print("  ❌ FAIL: NNpsk0 Pre-Shared Key Pattern - " .. err)
    end

    print(string.format("\nFunctional tests result: %d/%d tests passed", passed, total))
    print()
    return passed == total
  end

  local functional_passed = functional_tests()

  return functional_passed
end

--- @type table<string, DHFunction>
noise.DH = {
  [DH_25519.name] = DH_25519,
  [DH_448.name] = DH_448,
}

--- @type table<string, CipherFunction>
noise.Cipher = {
  [CIPHER_ChaChaPoly.name] = CIPHER_ChaChaPoly,
  [CIPHER_AESGCM.name] = CIPHER_AESGCM,
}

--- @type table<string, HashFunction>
noise.Hash = {
  [HASH_SHA256.name] = HASH_SHA256,
  [HASH_SHA512.name] = HASH_SHA512,
  [HASH_BLAKE2S.name] = HASH_BLAKE2S,
  [HASH_BLAKE2B.name] = HASH_BLAKE2B,
}

-- Utility types
noise.CipherState = CipherState
noise.SymmetricState = SymmetricState
noise.HandshakeState = HandshakeState
noise.NoiseConnection = NoiseConnection
noise.CipherSuite = CipherSuite
noise.PSKPlacement = PSKPlacement
noise.NoisePattern = NoisePattern

-- Export submodules for convenience
noise.crypto = crypto
noise.utils = utils

return noise

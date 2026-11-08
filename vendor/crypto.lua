do
  local _ENV = _ENV
  package.preload["crypto.aes_ccm"] = function(...)
    local arg = _G.arg
    --- @module "crypto.aes_ccm"
    --- AES-CCM authenticated encryption: Counter with CBC-MAC, RFC 3610 and NIST
    --- SP 800-38C.
    ---
    --- CCM authenticates with a CBC-MAC over a header block, the associated data
    --- and the plaintext, then encrypts the plaintext and the tag in counter mode.
    --- Both halves use only the forward AES block cipher, which comes from
    --- `crypto.aes_core`.
    ---
    --- Parameters, all checked on every call:
    ---
    --- * key: 16, 24 or 32 bytes (AES-128/192/256)
    --- * nonce: 7 to 13 bytes. The length field takes the rest of the 15 bytes, so a
    ---   13-byte nonce caps the message at 65535 bytes and a 7-byte one leaves it
    ---   effectively unbounded.
    --- * tag_length: an even number from 4 to 16, default 16
    ---
    --- OpenSSL acceleration
    --- --------------------
    --- lua-openssl's own `aes-128-ccm` cannot be used on the binding Control4 ships
    --- (0.8.5, measured 2026-11-03): it has no way to set the message length, and
    --- without associated data it returns no tag. So the mode is built here over a
    --- single-block AES call. With `crypto.use_openssl(true)` and a binding that
    --- passes `Feature.ECB`, each block goes through `cipher:encrypt(..., false)`,
    --- and the whole counter-mode keystream is one call. The CBC-MAC is a chain, so
    --- it stays one call per block.
    ---
    --- @usage
    --- local aes_ccm = require("crypto.aes_ccm")
    --- local sealed = aes_ccm.encrypt(key, nonce, plaintext, aad) -- ciphertext .. 16-byte tag
    --- local opened = aes_ccm.decrypt(key, nonce, sealed, aad) -- plaintext, or nil
    ---
    --- @class crypto.aes_ccm
    local aes_ccm = {}

    local bit32 = require("bitn").bit32

    local aes_core = require("crypto.aes_core")
    local utils = require("crypto.utils")
    local bytes = utils.bytes

    -- Local references for performance
    local bit32_raw_bxor = bit32.raw_bxor
    local ceil = math.ceil
    local floor = math.floor
    local string_byte = string.byte
    local string_char = string.char
    local string_rep = string.rep
    local string_sub = string.sub
    local table_concat = table.concat

    -- ============================================================================
    -- INTERNAL HELPERS
    -- ============================================================================

    --- Check the parameters every call shares.
    --- @param key string AES key
    --- @param nonce string Nonce
    --- @param tag_length integer? Tag length in bytes
    --- @return integer L Bytes of the length field (15 - #nonce)
    --- @return integer tag_length Tag length with the default applied
    local function check_parameters(key, nonce, tag_length)
      assert(
        type(key) == "string" and (#key == 16 or #key == 24 or #key == 32),
        "AES-CCM: key must be 16, 24, or 32 bytes"
      )
      assert(type(nonce) == "string" and #nonce >= 7 and #nonce <= 13, "AES-CCM: nonce must be 7 to 13 bytes")
      tag_length = tag_length or 16
      assert(
        type(tag_length) == "number" and tag_length >= 4 and tag_length <= 16 and tag_length % 2 == 0,
        "AES-CCM: tag length must be an even number of bytes from 4 to 16"
      )
      return 15 - #nonce, tag_length
    end

    --- Refuse a message too long for the length field.
    --- @param length integer Message length in bytes
    --- @param L integer Bytes of the length field
    local function check_message_length(length, L)
      -- From L = 7 the field holds more than any Lua string can.
      if L < 7 and length >= 256 ^ L then
        error("AES-CCM: a " .. (15 - L) .. "-byte nonce limits the message to " .. (floor(256 ^ L) - 1) .. " bytes", 3)
      end
    end

    --- Big-endian encoding of a non-negative integer in a fixed width.
    --- @param n integer Value
    --- @param width integer Bytes
    --- @return string encoded
    local function be_bytes(n, width)
      local out = {}
      for i = width, 1, -1 do
        out[i] = string_char(n % 256)
        n = floor(n / 256)
      end
      return table_concat(out)
    end

    --- XOR `a` with the first #a bytes of `b`.
    --- @param a string
    --- @param b string At least as long as `a`
    --- @return string result
    local function xor_prefix(a, b)
      local out = {}
      for i = 1, #a do
        out[i] = string_char(bit32_raw_bxor(string_byte(a, i), string_byte(b, i)))
      end
      return table_concat(out)
    end

    --- Zero-pad to a whole number of 16-byte blocks ("" stays "").
    --- @param data string
    --- @return string padded
    local function pad_block(data)
      local remainder = #data % 16
      if remainder == 0 then
        return data
      end
      return data .. string_rep("\0", 16 - remainder)
    end

    --- The associated-data length prefix of RFC 3610 section 2.2.
    --- @param length integer Associated data length in bytes, > 0
    --- @return string encoded
    local function encode_aad_length(length)
      if length < 0xFF00 then
        return be_bytes(length, 2)
      elseif length < 2 ^ 32 then
        return "\255\254" .. be_bytes(length, 4)
      end
      return "\255\255" .. be_bytes(length, 8)
    end

    --- CBC-MAC over B_0, the encoded associated data and the message, truncated.
    --- @param encrypt fun(blocks: string): string ECB encryptor for the key
    --- @param nonce string Nonce
    --- @param L integer Bytes of the length field
    --- @param tag_length integer Tag length in bytes
    --- @param aad string Associated data
    --- @param message string Plaintext
    --- @return string tag Unencrypted tag T
    local function cbc_mac(encrypt, nonce, L, tag_length, aad, message)
      -- Flags: Adata in bit 6, (M - 2) / 2 in bits 3-5, L - 1 in bits 0-2.
      local flags = (#aad > 0 and 64 or 0) + 4 * (tag_length - 2) + (L - 1)
      local x = encrypt(string_char(flags) .. nonce .. be_bytes(#message, L))
      local function absorb(data)
        for i = 1, #data, 16 do
          x = encrypt(xor_prefix(x, string_sub(data, i, i + 15)))
        end
      end
      if #aad > 0 then
        absorb(pad_block(encode_aad_length(#aad) .. aad))
      end
      absorb(pad_block(message))
      return string_sub(x, 1, tag_length)
    end

    --- Counter-mode keystream blocks S_0, S_1, ... in one batch.
    ---
    --- S_0 encrypts the tag and S_1 onward the message, so `blocks` is one more
    --- than the message's block count.
    --- @param encrypt fun(blocks: string): string ECB encryptor for the key
    --- @param nonce string Nonce
    --- @param L integer Bytes of the length field
    --- @param blocks integer Counter blocks to produce, starting at 0
    --- @return string keystream 16 * blocks bytes
    local function keystream(encrypt, nonce, L, blocks)
      local prefix = string_char(L - 1) .. nonce
      local counters = {}
      for i = 0, blocks - 1 do
        counters[i + 1] = prefix .. be_bytes(i, L)
      end
      return encrypt(table_concat(counters))
    end

    -- ============================================================================
    -- AEAD INTERFACE
    -- ============================================================================

    --- AES-CCM encryption.
    ---
    --- @param key string AES key (16, 24, or 32 bytes)
    --- @param nonce string 7 to 13 bytes, unique per message under one key
    --- @param plaintext string Data to encrypt
    --- @param aad? string Associated data, authenticated but not encrypted (default "")
    --- @param tag_length? integer Tag bytes, even, 4 to 16 (default 16)
    --- @return string sealed Ciphertext concatenated with the tag
    function aes_ccm.encrypt(key, nonce, plaintext, aad, tag_length)
      local L
      L, tag_length = check_parameters(key, nonce, tag_length)
      assert(type(plaintext) == "string", "AES-CCM: plaintext must be a string")
      aad = aad or ""
      assert(type(aad) == "string", "AES-CCM: aad must be a string")
      check_message_length(#plaintext, L)

      local encrypt = aes_core.ecb_encryptor(key)
      local tag = cbc_mac(encrypt, nonce, L, tag_length, aad, plaintext)
      local stream = keystream(encrypt, nonce, L, ceil(#plaintext / 16) + 1)
      return xor_prefix(plaintext, string_sub(stream, 17)) .. xor_prefix(tag, stream)
    end

    --- AES-CCM decryption.
    ---
    --- The tag is compared in constant time, and no plaintext is returned unless it
    --- matches.
    ---
    --- @param key string AES key (16, 24, or 32 bytes)
    --- @param nonce string The nonce used to encrypt
    --- @param ciphertext_and_tag string Output of `encrypt`
    --- @param aad? string Associated data (default "")
    --- @param tag_length? integer Tag bytes, even, 4 to 16 (default 16)
    --- @return string? plaintext Decrypted data, or nil if authentication fails
    function aes_ccm.decrypt(key, nonce, ciphertext_and_tag, aad, tag_length)
      local L
      L, tag_length = check_parameters(key, nonce, tag_length)
      assert(
        type(ciphertext_and_tag) == "string" and #ciphertext_and_tag >= tag_length,
        "AES-CCM: input must hold at least the " .. tag_length .. "-byte tag"
      )
      aad = aad or ""
      assert(type(aad) == "string", "AES-CCM: aad must be a string")
      local ciphertext_length = #ciphertext_and_tag - tag_length
      check_message_length(ciphertext_length, L)

      local ciphertext = string_sub(ciphertext_and_tag, 1, ciphertext_length)
      local received_tag = string_sub(ciphertext_and_tag, ciphertext_length + 1)

      local encrypt = aes_core.ecb_encryptor(key)
      local stream = keystream(encrypt, nonce, L, ceil(ciphertext_length / 16) + 1)
      local plaintext = xor_prefix(ciphertext, string_sub(stream, 17))
      local expected_tag = xor_prefix(cbc_mac(encrypt, nonce, L, tag_length, aad, plaintext), stream)
      if not bytes.constant_time_compare(expected_tag, received_tag) then
        return nil
      end
      return plaintext
    end

    return aes_ccm
  end
end

do
  local _ENV = _ENV
  package.preload["crypto.aes_core"] = function(...)
    local arg = _G.arg
    --- @module "crypto.aes_core"
    --- The AES block cipher (FIPS-197), shared by the AES modes in this library.
    ---
    --- Internal: `crypto.aes_gcm` and `crypto.aes_ccm` build on it, and the `crypto`
    --- aggregator does not export it. It holds the pure-Lua key schedule and forward
    --- block encryption (GCM and CCM never use the inverse cipher), plus
    --- `ecb_encryptor`, which routes whole-block encryption through lua-openssl's
    --- raw AES-ECB when acceleration is enabled and the binding passes
    --- `Feature.ECB`.
    --- @class crypto.aes_core
    local aes_core = {}

    local bit32 = require("bitn").bit32

    local openssl_wrapper = require("crypto.openssl_wrapper")

    -- Local references for performance
    local bit32_raw_band = bit32.raw_band
    local bit32_raw_bxor = bit32.raw_bxor
    local bit32_raw_lshift = bit32.raw_lshift
    local string_byte = string.byte
    local string_char = string.char
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
    -- PUBLIC INTERFACE
    -- ============================================================================

    aes_core.expand_key = key_expansion
    aes_core.encrypt_block = aes_encrypt_block

    --- Build an AES-ECB encryptor for one key.
    ---
    --- The returned function encrypts a whole number of 16-byte blocks, each
    --- independently. Returning a function means the key schedule, or the OpenSSL
    --- cipher lookup, is paid once per key rather than once per call.
    ---
    --- With acceleration enabled and a binding that passes `Feature.ECB`, each call
    --- is a single `cipher:encrypt(blocks, key, nil, false)` over every block
    --- passed, with padding off, so a caller that batches its blocks (a CTR
    --- keystream) crosses into C once. Otherwise each block runs through the
    --- pure-Lua core.
    ---
    --- @param key string AES key (16, 24, or 32 bytes)
    --- @return fun(blocks: string): string encrypt Encrypts a string whose length is a multiple of 16
    function aes_core.ecb_encryptor(key)
      assert(type(key) == "string" and (#key == 16 or #key == 24 or #key == 32), "AES key must be 16, 24, or 32 bytes")

      local openssl = openssl_wrapper.get(openssl_wrapper.Feature.ECB)
      if openssl then
        local cipher = openssl.cipher.get("aes-" .. #key * 8 .. "-ecb")
        return function(blocks)
          assert(#blocks % 16 == 0, "AES-ECB input must be a whole number of 16-byte blocks")
          if #blocks == 0 then
            return ""
          end
          local out = cipher:encrypt(blocks, key, nil, false)
          if type(out) ~= "string" or #out ~= #blocks then
            error("AES-ECB: OpenSSL returned " .. (type(out) == "string" and (#out .. " bytes") or type(out)))
          end
          return out
        end
      end

      local expanded_key, nr = key_expansion(key)
      return function(blocks)
        assert(#blocks % 16 == 0, "AES-ECB input must be a whole number of 16-byte blocks")
        if #blocks == 16 then
          return aes_encrypt_block(blocks, expanded_key, nr)
        end
        local out = {}
        for i = 1, #blocks, 16 do
          out[#out + 1] = aes_encrypt_block(string_sub(blocks, i, i + 15), expanded_key, nr)
        end
        return table_concat(out)
      end
    end

    return aes_core
  end
end

do
  local _ENV = _ENV
  package.preload["crypto.aes_gcm"] = function(...)
    local arg = _G.arg
    --- @module "crypto.aes_gcm"
    --- AES-GCM Authenticated Encryption with Associated Data (AEAD) Implementation for portability.
    --- @class crypto.aes_gcm
    local aes_gcm = {}

    local bit32 = require("bitn").bit32

    local aes_core = require("crypto.aes_core")
    local openssl_wrapper = require("crypto.openssl_wrapper")
    local utils = require("crypto.utils")
    local bytes = utils.bytes

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

    -- The block cipher lives in crypto.aes_core, shared with AES-CCM.
    local key_expansion = aes_core.expand_key
    local aes_encrypt_block = aes_core.encrypt_block

    -- ============================================================================
    -- GCM MODE IMPLEMENTATION
    -- ============================================================================

    --- @alias AESBlock [integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer]

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
      return string_sub(counter, 1, 12) .. bytes.u32_to_be_bytes(bytes.be_bytes_to_u32(counter, 13) + 1)
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

    return aes_gcm
  end
end

do
  local _ENV = _ENV
  package.preload["crypto.bignum"] = function(...)
    local arg = _G.arg
    --- @module "crypto.bignum"
    --- Arbitrary-precision unsigned integer arithmetic, sized for 3072-bit modular
    --- exponentiation (SRP-6a / RFC 5054 group 15).
    ---
    --- The hot path is `mod_exp`, which uses Montgomery multiplication plus a
    --- sliding-window exponentiation. See the notes above `mod_exp_montgomery` for
    --- why those two were chosen over the naive "square and multiply with a full
    --- divmod after every step".
    ---
    --- With `crypto.use_openssl(true)`, `mod_exp` and large `mul`, `divmod`, `mod`
    --- and `mod_mul` run through lua-openssl's `bn`, each only after the binding
    --- passes a known-answer check for it; see "INTERNAL: OPENSSL ACCELERATION".
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

    local openssl_wrapper = require("crypto.openssl_wrapper")

    -- Local references for performance
    local floor = math.floor
    local string_byte = string.byte
    local string_char = string.char
    local string_find = string.find
    local string_format = string.format
    local string_rep = string.rep
    local string_sub = string.sub
    local table_concat = table.concat

    -- ============================================================================
    -- CONSTANTS
    -- ============================================================================

    --- @alias BigNum integer[] Little-endian array of 24-bit limbs; {} is zero.
    --- @alias BigNumOp "mul"|"divmod"|"mod"|"mod_mul"|"mod_exp" An operation OpenSSL may run.

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

    -- Known answers shared by the tests and OPENSSL_CHECKS, computed
    -- independently with CPython. Multi-limb so a binding that mis-parses long
    -- operands is caught.
    local VEC_X_HEX = "f0e1d2c3b4a5968778695a4b3c2d1e0fdeadbeefcafebabe0123456789abcdef"
    local VEC_Y_HEX = "fedcba987654321fedcba9876543210abcdef0123456789"
    local VEC_M_HEX = "fffffffffffffffffffffffffffffffeffffffffffffffff"
    local VEC_MUL_HEX = table_concat({
      "efcfc0c2d5fa2f84db52db751fdba8927fd0cfb89d03a6e23469667bcbb09e04",
      "0c96803be0e492284a6a2290002002425d85431fb375de7",
    })
    local VEC_QUO_HEX = "f1f51dfdb8e1c16d7"
    local VEC_REM_HEX = "4e56a81e2677fc8622ba2a844cc25a8440c2e32a28013e0"
    local VEC_MOD_X_HEX = "78695a4b3c2d1e10cf8f91b37fa45145f205182b3e516476"
    local VEC_MOD_MUL_HEX = "c5789ec2c73be1123b996b5bf34a44eba5d1145d374fc548"
    local VEC_MOD_EXP_HEX = "e6663770f70809f8c052b35cc00534b8d5b2c013a9d4874c"

    --- Minimum pure-Lua limb products per limb converted for divmod, mod and mod_mul
    --- to route to OpenSSL, and the higher one mul needs; see "INTERNAL: OPENSSL
    --- ACCELERATION".
    local ROUTE_MIN_RATIO = 4
    local MUL_ROUTE_MIN_RATIO = 12

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
      -- The loop reads only #a limbs of b, and with canonical operands a wider b is a larger b.
      if #b > #a then
        error("bignum: subtraction would be negative")
      end
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
    --- the tests cross-check the Montgomery path against, and as the fallback
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
    -- used only as an internal accelerator inside individual operations: operands
    -- are converted into openssl.bn handles (big-endian bytes in via bn.text), the
    -- operation runs there, and the result is converted straight back to a limb
    -- table (hex out via bn.tohex). That is exactly the conversion path Feature.BN
    -- probes.
    --
    -- Rationale: crypto.use_openssl() can be toggled at runtime, so if handles were
    -- sometimes userdata and sometimes tables, a toggle mid-flight would produce
    -- mixed-type operands and silent breakage. Keeping one canonical type makes the
    -- accelerator invisible to callers -- results are identical with and without
    -- it, and the tests assert exactly that.
    --
    -- Conversion runs in Lua and is linear in the limbs moved, while the pure-Lua
    -- cost is the schoolbook limb products, so an operation routes only once its
    -- estimated work per limb converted reaches a ratio. Linear-cost calls (a
    -- one-limb factor or divisor, a narrow quotient, reduced operands, add, sub)
    -- stay here at any width. mod_exp routes at every size.
    --
    -- The ratios were measured on a Control4 controller (arm64, LuaJIT 2.1,
    -- lua-openssl 0.8.5, 2026-10-18) with the JIT on, the case that favours pure
    -- Lua most: divmod, mod and mod_mul win from 4, mul only from 12 (48x48 limbs
    -- 0.94x, 64x64 1.30x, 128x128 2.39x). Without the JIT mul wins from about 3, so
    -- there 12 gives up at most a few tenths of a millisecond per multiply.

    --- Binding whose behaviour has been checked, and the verdict per operation.
    --- @type table?
    local _verified_binding = nil
    --- @type table<BigNumOp, boolean>
    local _verified_ops = {}

    --- Estimated pure-Lua cost of a schoolbook division, in limb products.
    --- @param na integer Limbs in the dividend
    --- @param nb integer Limbs in the divisor
    --- @return integer work
    local function div_work(na, nb)
      if na < nb then
        return 0
      end
      return (na - nb + 1) * nb
    end

    --- Whether an operation is worth sending through the binding.
    --- @param work integer Estimated pure-Lua cost, in limb products
    --- @param limbs_in integer Limbs converted into the binding (the operands)
    --- @param limbs_out integer Most limbs converted back out (the results)
    --- @param ratio integer Minimum limb products per limb converted
    --- @return boolean
    local function worth_routing(work, limbs_in, limbs_out, ratio)
      return work > 0 and work >= ratio * (limbs_in + limbs_out)
    end

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

    --- Convert an openssl.bn handle back into a canonical big number. Only bare hex
    --- digits are accepted: `bn.tohex` signs negatives with "-", which `from_hex`
    --- would read as a negative limb instead of rejecting.
    --- @param bnlib table The openssl.bn table
    --- @param handle any Opaque openssl.bn value
    --- @return BigNum value
    local function bignum_from_bn(bnlib, handle)
      local hex = bnlib.tohex(handle)
      if type(hex) ~= "string" or string_find(hex, "^%x+$") == nil then
        error("bignum: openssl bn.tohex did not return unsigned hex")
      end
      return bignum.from_hex(hex)
    end

    --- Refuse a zero divisor, which the binding answers with 0 instead of raising
    --- (lua-openssl 0.8.5, 0.9.2 and 0.11.1, measured 2026-10-17). The raise sends
    --- the call back to pure Lua, which reports the real error.
    --- @param m BigNum Divisor or modulus
    local function require_nonzero(m)
      if #m == 0 then
        error("bignum: zero divisor")
      end
    end

    --- Each routed operation as run through the binding; anything unexpected raises.
    --- @type table<BigNumOp, fun(bnlib: table, a: BigNum, b: BigNum, c: BigNum?): BigNum, BigNum?>
    local OPENSSL_OPS = {
      mul = function(bnlib, a, b)
        return bignum_from_bn(bnlib, bnlib.mul(bn_from_bignum(bnlib, a), bn_from_bignum(bnlib, b)))
      end,
      divmod = function(bnlib, a, b)
        require_nonzero(b)
        local quotient, remainder = bnlib.divmod(bn_from_bignum(bnlib, a), bn_from_bignum(bnlib, b))
        return bignum_from_bn(bnlib, quotient), bignum_from_bn(bnlib, remainder)
      end,
      mod = function(bnlib, a, m)
        require_nonzero(m)
        return bignum_from_bn(bnlib, bnlib.mod(bn_from_bignum(bnlib, a), bn_from_bignum(bnlib, m)))
      end,
      mod_mul = function(bnlib, a, b, m)
        --- @cast m BigNum
        require_nonzero(m)
        local product = bnlib.mulmod(bn_from_bignum(bnlib, a), bn_from_bignum(bnlib, b), bn_from_bignum(bnlib, m))
        return bignum_from_bn(bnlib, product)
      end,
      mod_exp = function(bnlib, base, exp, m)
        --- @cast m BigNum
        require_nonzero(m)
        local result =
          bn_powmod(bnlib)(bn_from_bignum(bnlib, base), bn_from_bignum(bnlib, exp), bn_from_bignum(bnlib, m))
        return bignum_from_bn(bnlib, result)
      end,
    }

    --- One multi-limb known answer per routed operation, as hex. `Feature.BN` only
    --- round-trips a single-digit powmod, so it proves neither that long operands
    --- parse nor that mul, divmod, mod and mulmod work. Each is checked on its own
    --- so one broken entry point does not take mod_exp down with it.
    --- @type table<BigNumOp, { args: string[], results: string[] }>
    local OPENSSL_CHECKS = {
      mul = { args = { VEC_X_HEX, VEC_Y_HEX }, results = { VEC_MUL_HEX } },
      divmod = { args = { VEC_X_HEX, VEC_Y_HEX }, results = { VEC_QUO_HEX, VEC_REM_HEX } },
      mod = { args = { VEC_X_HEX, VEC_M_HEX }, results = { VEC_MOD_X_HEX } },
      mod_mul = { args = { VEC_X_HEX, VEC_Y_HEX, VEC_M_HEX }, results = { VEC_MOD_MUL_HEX } },
      mod_exp = { args = { VEC_X_HEX, VEC_Y_HEX, VEC_M_HEX }, results = { VEC_MOD_EXP_HEX } },
    }

    --- Run one operation through a binding, turning any failure into nil. The
    --- known-answer check comes through here too, so it tests the exact call trusted.
    --- @param bnlib table The openssl.bn table
    --- @param op BigNumOp Operation to run
    --- @param a BigNum First operand
    --- @param b BigNum Second operand
    --- @param c? BigNum Third operand
    --- @return BigNum|nil first Result, or nil on any failure
    --- @return BigNum|nil second Second result (divmod's remainder)
    local function call_binding(bnlib, op, a, b, c)
      local ok, first, second = pcall(OPENSSL_OPS[op], bnlib, a, b, c)
      if not ok then
        return nil, nil
      end
      return first, second
    end

    --- Run one operation's known answer through a binding.
    --- @param bnlib table The openssl.bn table
    --- @param op BigNumOp Operation to check
    --- @return boolean passed
    local function passes_check(bnlib, op)
      local check = OPENSSL_CHECKS[op]
      local args = {}
      for i, hex in ipairs(check.args) do
        args[i] = bignum.from_hex(hex)
      end
      local got = { call_binding(bnlib, op, args[1], args[2], args[3]) }
      for i, hex in ipairs(check.results) do
        if type(got[i]) ~= "table" or compare_raw(got[i], bignum.from_hex(hex)) ~= 0 then
          return false
        end
      end
      return true
    end

    --- The openssl.bn table if `op` should run there, nil otherwise: needs
    --- `Feature.BN` and `op`'s known-answer check, run once per binding and cached.
    --- @param op BigNumOp Operation to ask about
    --- @return table|nil bnlib
    local function trusted_bn(op)
      local openssl = openssl_wrapper.get(openssl_wrapper.Feature.BN)
      if openssl == nil then
        return nil
      end
      if _verified_binding ~= openssl then
        _verified_binding = openssl
        _verified_ops = {}
      end
      local verdict = _verified_ops[op]
      if verdict == nil then
        verdict = passes_check(openssl.bn, op)
        _verified_ops[op] = verdict
      end
      if verdict then
        return openssl.bn
      end
      return nil
    end

    --- Run `op` through OpenSSL when that is enabled and trusted.
    --- @param op BigNumOp Operation to run
    --- @param a BigNum First operand
    --- @param b BigNum Second operand
    --- @param c? BigNum Third operand
    --- @return BigNum|nil first Result, or nil when the caller must use pure Lua
    --- @return BigNum|nil second Second result (divmod's remainder)
    local function run_openssl(op, a, b, c)
      local bnlib = trusted_bn(op)
      if bnlib == nil then
        return nil, nil
      end
      return call_binding(bnlib, op, a, b, c)
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

    --- Multiplication. Large operands run through OpenSSL when it is enabled.
    --- @param a BigNum First factor
    --- @param b BigNum Second factor
    --- @return BigNum product
    function bignum.mul(a, b)
      if worth_routing(#a * #b, #a + #b, #a + #b, MUL_ROUTE_MIN_RATIO) then
        local product = run_openssl("mul", a, b)
        if product then
          return product
        end
      end
      return mul_raw(a, b)
    end

    --- Division with remainder. Large quotients run through OpenSSL when enabled.
    --- @param a BigNum Dividend
    --- @param b BigNum Divisor (must be non-zero)
    --- @return BigNum quotient floor(a / b)
    --- @return BigNum remainder a - quotient * b
    function bignum.divmod(a, b)
      -- Out: a quotient of up to #a - #b + 1 limbs and a remainder of up to #b.
      if worth_routing(div_work(#a, #b), #a + #b, #a + 1, ROUTE_MIN_RATIO) then
        local quotient, remainder = run_openssl("divmod", a, b)
        if quotient and remainder then
          return quotient, remainder
        end
      end
      return divmod_raw(a, b)
    end

    --- Remainder of a divided by b. Large quotients run through OpenSSL when enabled.
    --- @param a BigNum Dividend
    --- @param b BigNum Modulus (must be non-zero)
    --- @return BigNum remainder
    function bignum.mod(a, b)
      if worth_routing(div_work(#a, #b), #a + #b, #b, ROUTE_MIN_RATIO) then
        local remainder = run_openssl("mod", a, b)
        if remainder then
          return remainder
        end
      end
      local _, r = divmod_raw(a, b)
      return r
    end

    --- Modular addition.
    --- @param a BigNum First addend
    --- @param b BigNum Second addend
    --- @param m BigNum Modulus (must be non-zero)
    --- @return BigNum result (a + b) mod m
    function bignum.mod_add(a, b, m)
      return bignum.mod(add_raw(a, b), m)
    end

    --- Modular subtraction, always returning a non-negative residue.
    --- SRP computes B - k*g^x, where the subtraction can go negative, so this wraps
    --- rather than erroring.
    --- @param a BigNum Minuend
    --- @param b BigNum Subtrahend
    --- @param m BigNum Modulus (must be non-zero)
    --- @return BigNum result (a - b) mod m
    function bignum.mod_sub(a, b, m)
      local ra = bignum.mod(a, m)
      local rb = bignum.mod(b, m)
      if compare_raw(ra, rb) >= 0 then
        return sub_raw(ra, rb)
      end
      return sub_raw(add_raw(ra, m), rb)
    end

    --- Modular multiplication. Large operands run through OpenSSL when enabled.
    --- @param a BigNum First factor
    --- @param b BigNum Second factor
    --- @param m BigNum Modulus (must be non-zero)
    --- @return BigNum result (a * b) mod m
    function bignum.mod_mul(a, b, m)
      local product_limbs = (#a == 0 or #b == 0) and 0 or #a + #b
      if worth_routing(#a * #b + div_work(product_limbs, #m), #a + #b + #m, #m, ROUTE_MIN_RATIO) then
        local result = run_openssl("mod_mul", a, b, m)
        if result then
          return result
        end
      end
      local _, r = divmod_raw(mul_raw(a, b), m)
      return r
    end

    --- Modular exponentiation -- the hot path for SRP-6a.
    ---
    --- Dispatch order: a verified OpenSSL binding if acceleration is enabled (at
    --- any operand size), otherwise Montgomery + sliding window for odd moduli,
    --- otherwise the slow reference path. All three return identical values.
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

      local result = run_openssl("mod_exp", base, exp, m)
      if result then
        return result
      end

      if m[1] % 2 == 1 then
        return mod_exp_montgomery(base, exp, m)
      end
      -- Montgomery needs an odd modulus; even moduli are not used by SRP.
      return mod_exp_reference(base, exp, m)
    end

    --- Whether an operation will use the OpenSSL backend; `mod_exp` by default.
    ---
    --- Answers the question callers actually have -- "will a 3072-bit exponentiation
    --- finish in milliseconds or in minutes?" -- so it applies the same two
    --- conditions the operation does: acceleration enabled with a binding that
    --- passes `Feature.BN`, *and* a binding that reproduces that operation's
    --- multi-limb known-answer vector. Checking the feature gate alone would report
    --- true for a binding this module has already decided not to trust.
    ---
    --- Each operation is checked separately, so the answers can differ. For mul,
    --- divmod, mod and mod_mul, true covers only calls wide enough to route. Losing
    --- one of those costs milliseconds per 3072-bit call; losing mod_exp costs
    --- seconds, which is why `srp.is_accelerated` asks about it alone.
    ---
    --- The verdict is not static: it changes with `crypto.use_openssl()`.
    ---
    --- A false verdict comes with the reason, because the two common causes need
    --- opposite responses and are otherwise indistinguishable: a host that cannot
    --- accelerate has to be designed around, while a caller that never enabled
    --- acceleration just has to make one call. The reason is always present when
    --- `accelerated` is false.
    ---
    --- @param op? BigNumOp Operation to ask about; "mod_exp" when omitted
    --- @return boolean accelerated True if OpenSSL will handle the operation
    --- @return string|nil reason Why it will not, when it will not
    function bignum.is_accelerated(op)
      op = op or "mod_exp"
      if OPENSSL_OPS[op] == nil then
        error("bignum: unknown operation '" .. tostring(op) .. "'")
      end
      local openssl = openssl_wrapper.get(openssl_wrapper.Feature.BN)
      if openssl == nil then
        return false,
          openssl_wrapper.unavailable_reason(openssl_wrapper.Feature.BN)
            or "OpenSSL modular exponentiation is unavailable"
      end
      if trusted_bn(op) == nil then
        return false,
          "the lua-openssl binding failed bignum's multi-limb known-answer check, so it is not trusted for "
            .. (op == "mod_exp" and "modular exponentiation" or op)
      end
      return true
    end

    -- Private functions the tests in test/ check directly.
    bignum._internal = {
      add_raw = add_raw,
      mul_raw = mul_raw,
      divmod_raw = divmod_raw,
      mod_exp_montgomery = mod_exp_montgomery,
      mod_exp_reference = mod_exp_reference,
    }

    return bignum
  end
end

do
  local _ENV = _ENV
  package.preload["crypto.blake2"] = function(...)
    local arg = _G.arg
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

    return blake2
  end
end

do
  local _ENV = _ENV
  package.preload["crypto.chacha20"] = function(...)
    local arg = _G.arg
    --- @module "crypto.chacha20"
    --- ChaCha20 Stream Cipher Implementation for portability.
    --- @class crypto.chacha20
    local chacha20 = {}

    local bit32 = require("bitn").bit32

    local openssl_wrapper = require("crypto.openssl_wrapper")
    local utils = require("crypto.utils")
    local bytes = utils.bytes

    -- Local references for performance
    local bit32_raw_add = bit32.raw_add
    local bit32_raw_bxor = bit32.raw_bxor
    local bit32_raw_rol = bit32.raw_rol
    local bit32_u32_to_le_bytes = bit32.u32_to_le_bytes
    local bit32_le_bytes_to_u32 = bit32.le_bytes_to_u32
    local min = math.min
    local string_byte = string.byte
    local string_char = string.char
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
        state[4 + i] = bit32_le_bytes_to_u32(key, (i - 1) * 4 + 1)
      end

      -- 32-bit counter
      state[13] = counter

      -- 96-bit nonce (3 words)
      for i = 1, 3 do
        state[13 + i] = bit32_le_bytes_to_u32(nonce, (i - 1) * 4 + 1)
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

      local result_bytes = {}
      for i = 1, 16 do
        result_bytes[i] = bit32_u32_to_le_bytes(working_state[i])
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

    -- Private functions the tests in test/ check directly.
    chacha20._internal = {
      chacha20_block = chacha20_block,
    }

    return chacha20
  end
end

do
  local _ENV = _ENV
  package.preload["crypto.chacha20_poly1305"] = function(...)
    local arg = _G.arg
    --- @module "crypto.chacha20_poly1305"
    --- ChaCha20-Poly1305 Authenticated Encryption with Associated Data (AEAD) Implementation for portability.
    --- @class crypto.chacha20_poly1305
    local chacha20_poly1305 = {}

    local openssl_wrapper = require("crypto.openssl_wrapper")
    local utils = require("crypto.utils")
    local bytes = utils.bytes
    local chacha20 = require("crypto.chacha20")
    local poly1305 = require("crypto.poly1305")

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

    -- Private functions the tests in test/ check directly.
    chacha20_poly1305._internal = {
      poly1305_key_gen = poly1305_key_gen,
    }

    return chacha20_poly1305
  end
end

do
  local _ENV = _ENV
  package.preload["crypto.ed25519"] = function(...)
    local arg = _G.arg
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

    -- Local references for performance
    local bit32_raw_band = bit32.raw_band
    local bit32_raw_bor = bit32.raw_bor
    local bit32_raw_bxor = bit32.raw_bxor
    local bit32_raw_rshift = bit32.raw_rshift
    local floor = math.floor
    local sha512 = sha512_mod.sha512
    local string_byte = string.byte
    local string_char = string.char
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

    -- Private functions the tests in test/ check directly.
    ed25519._internal = {
      string_to_bytes = string_to_bytes,
      bytes_to_string = bytes_to_string,
    }

    return ed25519
  end
end

do
  local _ENV = _ENV
  package.preload["crypto.hkdf"] = function(...)
    local arg = _G.arg
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

    return hkdf
  end
end

do
  local _ENV = _ENV
  package.preload["crypto.openssl_wrapper"] = function(...)
    local arg = _G.arg
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
    --- - AES-CCM's block cipher (raw AES-ECB)
    --- - ChaCha20 stream cipher
    --- - Big-number arithmetic (SRP)
    --- - P-256 field arithmetic
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
      --- Arbitrary-precision integers (`openssl.bn`), used by `crypto.bignum`. The probe only runs
      --- a one-limb powmod; bignum checks each operation it routes on multi-limb values first.
      BN = "BN",
      --- Raw AES-ECB block encryption with padding off (`cipher:encrypt(blocks, key, nil, false)`),
      --- used by `crypto.aes_core` for AES-CCM. The probe checks FIPS-197 known answers.
      ECB = "ECB",
      --- Raw Octet Key Pair support: creating and *signing* with Ed25519/X25519 keys.
      --- Importing such a key is not sufficient; the probe requires a working signature.
      OKP = "OKP",
      --- Cryptographically secure random bytes (`openssl.random`), used by `crypto.random`.
      --- Unlike every other feature here this one has no pure-Lua fallback, so it is
      --- resolved through `get_ungated` rather than `get`.
      RANDOM = "RANDOM",
    }

    --- FIPS-197 Appendix C known answers for the ECB probe: one plaintext block and,
    --- per key size, the C.1 (AES-128), C.2 (AES-192) and C.3 (AES-256) key and
    --- ciphertext, all as hex.
    local ECB_PLAINTEXT_HEX = "00112233445566778899aabbccddeeff"
    local ECB_KNOWN_ANSWERS = {
      {
        cipher = "aes-128-ecb",
        key = "000102030405060708090a0b0c0d0e0f",
        ciphertext = "69c4e0d86a7b0430d8cdb78070b4c55a",
      },
      {
        cipher = "aes-192-ecb",
        key = "000102030405060708090a0b0c0d0e0f1011121314151617",
        ciphertext = "dda97ca4864cdfe06eaf70a0ec0d7191",
      },
      {
        cipher = "aes-256-ecb",
        key = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
        ciphertext = "8ea2b7ca516745bfeafc49904b496089",
      },
    }

    --- Decode hex to bytes. The wrapper requires nothing from the library, so it
    --- carries its own rather than pulling in `crypto.utils`.
    --- @param hex string Hex digits
    --- @return string bytes
    local function from_hex(hex)
      return (hex:gsub("..", function(cc)
        return string.char(tonumber(cc, 16))
      end))
    end

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
      [OpenSSLFeature.ECB] = {
        min_version = "0.8.0",
        probe = function(openssl)
          local cipher_lib = openssl.cipher
          if type(cipher_lib) ~= "table" or type(cipher_lib.get) ~= "function" then
            return false
          end
          -- Measured on a Control4 controller (2026-11-03, lua-openssl 0.8.5):
          -- cipher.get("aes-128-ecb"):encrypt(block, key, nil, false) returns the
          -- raw block. Two blocks go in one call, so the answer also proves padding
          -- is off and that a batch comes back block for block.
          local plaintext = from_hex(ECB_PLAINTEXT_HEX)
          for _, answer in ipairs(ECB_KNOWN_ANSWERS) do
            local cipher = cipher_lib.get(answer.cipher)
            if cipher == nil then
              return false
            end
            local expected = from_hex(answer.ciphertext)
            if cipher:encrypt(plaintext .. plaintext, from_hex(answer.key), nil, false) ~= expected .. expected then
              return false
            end
          end
          return true
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

    --- Whether acceleration is requested, as last set by `use`. Snapshot it before toggling the flag temporarily.
    --- @return boolean enabled
    function openssl_wrapper.enabled()
      -- Truthy like `get`, not `== true`, or restoring this answer could switch acceleration off.
      return _use_openssl and true or false
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

    -- Private functions and values the tests in test/ check directly.
    openssl_wrapper._internal = {
      from_hex = from_hex,
      FeatureRequirements = FeatureRequirements,
    }

    return openssl_wrapper
  end
end

do
  local _ENV = _ENV
  package.preload["crypto.p256"] = function(...)
    local arg = _G.arg
    --- @module "crypto.p256"
    --- NIST P-256 (secp256r1) group arithmetic: SEC 1 point encoding, scalar
    --- multiplication, point addition, and scalar helpers. It is what
    --- `crypto.spake2plus` is built on; there is no ECDSA or ECDH API here.
    ---
    --- Points
    --- ------
    --- Points are opaque tables made by `decode_point`, `p256.G` or the group
    --- operations, and every operation refuses a table it did not make. A point
    --- holds its affine coordinates as 32-byte big-endian strings, so it belongs
    --- to neither arithmetic backend below and stays valid when
    --- `crypto.use_openssl()` is toggled. Decoding rejects the identity,
    --- coordinates >= p, and anything off y^2 = x^3 - 3x + b. P-256's cofactor is
    --- 1, so a point on the curve is in the prime-order group.
    ---
    --- Scalars
    --- -------
    --- A scalar is a 32-byte big-endian string. `mul` does not reduce it: callers
    --- pass a value in [0, n-1], which `reduce` and `random_scalar` produce. A
    --- larger value still yields (k mod n) * P.
    ---
    --- Arithmetic
    --- ----------
    --- Scalar multiplication is a fixed 4-bit window over Jacobian coordinates
    --- (doubling dbl-2001-b for a = -3, addition add-1998-cmo-2), written once over
    --- a small field interface with two implementations:
    ---
    --- * OpenSSL: with `crypto.use_openssl(true)`, a binding that passes
    ---   `Feature.BN`, and a binding that reproduces the published 2G and 3G through
    ---   this module's own doubling and addition, field elements are `openssl.bn`
    ---   handles throughout (`addmod`, `submod`, `mulmod`, `sqrmod`, `invmod`, and
    ---   `powmod` for square roots). They are converted only where a point enters
    ---   or leaves an operation. A Jacobian double-and-add over these handles took
    ---   53 ms per 256-bit scalar multiplication on a Control4 controller (OS 4.3,
    ---   lua-openssl 0.8.5, 2026-11-03). Converting to and from `crypto.bignum` per
    ---   field operation instead would be far slower.
    --- * Pure Lua: `crypto.bignum`, inverting by Fermat's little theorem. It is the
    ---   correctness reference and the portability fallback. One scalar
    ---   multiplication takes about 30 ms under LuaJIT and 75 to 100 ms under PUC
    ---   Lua 5.1 to 5.5 on a desktop (Apple M1 Max, 2026-11-02). It has not been
    ---   timed on a controller.
    ---
    --- `is_accelerated` says which one runs. Like the rest of this library, none of
    --- it is constant time.
    ---
    --- @usage
    --- local p256 = require("crypto.p256")
    --- local k = p256.random_scalar()
    --- local public = p256.encode_point(p256.mul_base(k)) -- 65 bytes, 0x04 || x || y
    --- local peer = assert(p256.decode_point(received)) -- nil plus a reason when invalid
    --- local shared = p256.mul(k, peer)
    ---
    --- @class crypto.p256
    --- @field n string Group order, 32 big-endian bytes
    --- @field G crypto.p256.Point Base point
    local p256 = {}

    local bignum = require("crypto.bignum")
    local openssl_wrapper = require("crypto.openssl_wrapper")
    local random = require("crypto.random")
    local utils = require("crypto.utils")
    local bytes = utils.bytes

    -- Local references for performance
    local floor = math.floor
    local string_byte = string.byte
    local string_find = string.find
    local string_rep = string.rep
    local string_sub = string.sub

    -- ============================================================================
    -- CONSTANTS
    -- ============================================================================

    -- Curve parameters, SEC 2 section 2.4.2 / FIPS 186-5.
    local P_HEX = "ffffffff00000001000000000000000000000000ffffffffffffffffffffffff"
    local N_HEX = "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551"
    local B_HEX = "5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b"
    local GX_HEX = "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296"
    local GY_HEX = "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5"
    --- p - 2, the inversion exponent.
    local P_MINUS_2_HEX = "ffffffff00000001000000000000000000000000fffffffffffffffffffffffd"
    --- (p + 1) / 4: p = 3 mod 4, so a square c has the root c^((p+1)/4).
    local SQRT_EXP_HEX = "3fffffffc0000000400000000000000000000000400000000000000000000000"

    -- Published multiples of G, used by the OpenSSL known-answer check and the
    -- tests (also reproduced with the openssl CLI).
    local G2_X_HEX = "7cf27b188d034f7e8a52380304b51ac3c08969e277f21b35a60b48fc47669978"
    local G2_Y_HEX = "07775510db8ed040293d9ac69f7430dbba7dade63ce982299e04b79d227873d1"
    local G3_X_HEX = "5ecbe4d1a6330a44c8f7ef951d4bf165e6c6b721efada985fb41661bc6e7fd6c"
    local G3_Y_HEX = "8734640c4998ff7e374b06ce1a64a2ecd82ab036384fb83d9a79b127a27d5032"

    local P_BN = bignum.from_hex(P_HEX)
    local N_BN = bignum.from_hex(N_HEX)

    -- ============================================================================
    -- POINTS
    -- ============================================================================

    --- A point on P-256 or the identity. Opaque: make one with `decode_point` or a
    --- group operation, never by hand.
    --- @class crypto.p256.Point
    --- @field x string? Affine x, 32 big-endian bytes; nil for the identity
    --- @field y string? Affine y, 32 big-endian bytes; nil for the identity
    --- @field infinity boolean? True for the identity

    --- Shared by every point this module makes, and how it recognises them.
    local POINT_MT = {}

    --- @param x string Affine x, 32 bytes, already validated
    --- @param y string Affine y, 32 bytes, already validated
    --- @return crypto.p256.Point point
    local function new_point(x, y)
      --- @type crypto.p256.Point
      local point = setmetatable({ x = x, y = y }, POINT_MT)
      return point
    end

    --- @return crypto.p256.Point identity
    local function identity()
      --- @type crypto.p256.Point
      local point = setmetatable({ infinity = true }, POINT_MT)
      return point
    end

    --- Raise unless `point` came from this module.
    --- @param point any
    local function check_point(point)
      if type(point) ~= "table" or getmetatable(point) ~= POINT_MT then
        error("p256: expected a point from decode_point or a p256 operation", 3)
      end
    end

    --- Raise unless `scalar` is a 32-byte string.
    --- @param scalar any
    local function check_scalar(scalar)
      if type(scalar) ~= "string" or #scalar ~= 32 then
        error("p256: a scalar must be 32 big-endian bytes", 3)
      end
    end

    --- Whether 32 big-endian bytes encode a value below p.
    --- @param coordinate string
    --- @return boolean
    local function below_p(coordinate)
      return bignum.compare(bignum.from_bytes(coordinate), P_BN) < 0
    end

    --- p - y for a 32-byte coordinate y in [1, p-1].
    --- @param y string
    --- @return string negated
    local function negate_coordinate(y)
      return bignum.to_bytes(bignum.sub(P_BN, bignum.from_bytes(y)), 32)
    end

    -- ============================================================================
    -- FIELD BACKENDS
    -- ============================================================================

    --- Arithmetic modulo p over an opaque element type: `crypto.bignum` values for
    --- the pure-Lua backend, `openssl.bn` handles for the OpenSSL one. Every
    --- element passed in is already reduced, and every element returned is.
    --- @class P256Field
    --- @field name string Names the backend in test output
    --- @field from_bytes fun(s: string): any 32 big-endian bytes, below p
    --- @field to_bytes fun(a: any): string 32 big-endian bytes
    --- @field add fun(a: any, b: any): any
    --- @field sub fun(a: any, b: any): any
    --- @field mul fun(a: any, b: any): any
    --- @field sqr fun(a: any): any
    --- @field inv fun(a: any): any Inverse of a non-zero element
    --- @field sqrt fun(a: any): any a^((p+1)/4): a square root when one exists
    --- @field is_zero fun(a: any): boolean
    --- @field equals fun(a: any, b: any): boolean
    --- @field one any
    --- @field three any
    --- @field b any The curve coefficient b

    --- @type P256Field
    local pure_field
    do
      local P_MINUS_2 = bignum.from_hex(P_MINUS_2_HEX)
      local SQRT_EXP = bignum.from_hex(SQRT_EXP_HEX)
      local add, sub, compare = bignum.add, bignum.sub, bignum.compare
      local mod_mul, mod_exp = bignum.mod_mul, bignum.mod_exp
      pure_field = {
        name = "pure Lua",
        from_bytes = bignum.from_bytes,
        to_bytes = function(a)
          return bignum.to_bytes(a, 32)
        end,
        add = function(a, b)
          local sum = add(a, b)
          if compare(sum, P_BN) >= 0 then
            return sub(sum, P_BN)
          end
          return sum
        end,
        sub = function(a, b)
          if compare(a, b) >= 0 then
            return sub(a, b)
          end
          return sub(add(a, P_BN), b)
        end,
        mul = function(a, b)
          return mod_mul(a, b, P_BN)
        end,
        sqr = function(a)
          return mod_mul(a, a, P_BN)
        end,
        inv = function(a)
          return mod_exp(a, P_MINUS_2, P_BN)
        end,
        sqrt = function(a)
          return mod_exp(a, SQRT_EXP, P_BN)
        end,
        is_zero = bignum.is_zero,
        equals = bignum.equals,
        one = bignum.one(),
        three = bignum.from_number(3),
        b = bignum.from_hex(B_HEX),
      }
    end

    --- Build the field over a binding's `openssl.bn`. Nothing is checked here; the
    --- caller runs `passes_known_answers` before trusting it.
    --- @param bnlib table The openssl.bn table
    --- @return P256Field field
    local function bn_field(bnlib)
      local text, tohex = bnlib.text, bnlib.tohex
      local addmod, submod, mulmod, sqrmod, invmod =
        bnlib.addmod, bnlib.submod, bnlib.mulmod, bnlib.sqrmod, bnlib.invmod
      -- Spelled `powmod` on Control4's 0.8.5 and `mod_exp` on some other builds.
      local powmod = type(bnlib.powmod) == "function" and bnlib.powmod or bnlib.mod_exp
      local iszero, compare = bnlib.iszero, bnlib.compare
      for _, fn in ipairs({ text, tohex, addmod, submod, mulmod, sqrmod, invmod, powmod, iszero, compare }) do
        if type(fn) ~= "function" then
          error("p256: openssl.bn lacks a function this module needs")
        end
      end

      local P = text(bytes.from_hex(P_HEX))
      local SQRT_EXP = text(bytes.from_hex(SQRT_EXP_HEX))
      return {
        name = "OpenSSL bn",
        from_bytes = text,
        to_bytes = function(h)
          -- bn.tohex drops leading zeros and signs negatives with "-"; only bare
          -- hex of at most 64 digits is a reduced element.
          local hex = tohex(h)
          if type(hex) ~= "string" or string_find(hex, "^%x+$") == nil or #hex > 64 then
            error("p256: openssl bn.tohex did not return a reduced element")
          end
          return bytes.from_hex(string_rep("0", 64 - #hex) .. hex)
        end,
        add = function(a, b)
          return addmod(a, b, P)
        end,
        sub = function(a, b)
          return submod(a, b, P)
        end,
        mul = function(a, b)
          return mulmod(a, b, P)
        end,
        sqr = function(a)
          return sqrmod(a, P)
        end,
        inv = function(a)
          return invmod(a, P)
        end,
        sqrt = function(a)
          return powmod(a, SQRT_EXP, P)
        end,
        is_zero = function(a)
          local zero = iszero(a)
          return zero == true or zero == 1
        end,
        equals = function(a, b)
          return compare(a, b) == 0
        end,
        one = text("\1"),
        three = text("\3"),
        b = text(bytes.from_hex(B_HEX)),
      }
    end

    -- ============================================================================
    -- JACOBIAN ARITHMETIC
    -- ============================================================================

    --- A point in Jacobian coordinates (X, Y, Z), with x = X/Z^2 and y = Y/Z^3, as
    --- elements of one field. The identity is represented by nil.
    --- @alias P256Jacobian { [1]: any, [2]: any, [3]: any }

    --- Double a point (dbl-2001-b, a = -3).
    --- @param F P256Field
    --- @param P P256Jacobian?
    --- @return P256Jacobian?
    local function jacobian_double(F, P)
      if P == nil or F.is_zero(P[2]) then
        return nil
      end
      local X1, Y1, Z1 = P[1], P[2], P[3]
      local add, sub, mul, sqr = F.add, F.sub, F.mul, F.sqr
      local delta = sqr(Z1)
      local gamma = sqr(Y1)
      local beta = mul(X1, gamma)
      local t = mul(sub(X1, delta), add(X1, delta))
      local alpha = add(add(t, t), t)
      local beta2 = add(beta, beta)
      local beta4 = add(beta2, beta2)
      local X3 = sub(sqr(alpha), add(beta4, beta4))
      local Z3 = sub(sub(sqr(add(Y1, Z1)), gamma), delta)
      local gamma_sq = sqr(gamma)
      local gamma_sq2 = add(gamma_sq, gamma_sq)
      local gamma_sq4 = add(gamma_sq2, gamma_sq2)
      local Y3 = sub(mul(alpha, sub(beta4, X3)), add(gamma_sq4, gamma_sq4))
      return { X3, Y3, Z3 }
    end

    --- Add two points (add-1998-cmo-2), handling the identity and P + P.
    --- @param F P256Field
    --- @param P P256Jacobian?
    --- @param Q P256Jacobian?
    --- @return P256Jacobian?
    local function jacobian_add(F, P, Q)
      if P == nil then
        return Q
      elseif Q == nil then
        return P
      end
      local X1, Y1, Z1 = P[1], P[2], P[3]
      local X2, Y2, Z2 = Q[1], Q[2], Q[3]
      local add, sub, mul, sqr = F.add, F.sub, F.mul, F.sqr
      local Z1Z1 = sqr(Z1)
      local Z2Z2 = sqr(Z2)
      local U1 = mul(X1, Z2Z2)
      local U2 = mul(X2, Z1Z1)
      local S1 = mul(mul(Y1, Z2), Z2Z2)
      local S2 = mul(mul(Y2, Z1), Z1Z1)
      local H = sub(U2, U1)
      local r = sub(S2, S1)
      if F.is_zero(H) then
        if F.is_zero(r) then
          return jacobian_double(F, P)
        end
        return nil
      end
      local HH = sqr(H)
      local HHH = mul(H, HH)
      local V = mul(U1, HH)
      local X3 = sub(sub(sqr(r), HHH), add(V, V))
      local Y3 = sub(mul(r, sub(V, X3)), mul(S1, HHH))
      local Z3 = mul(mul(Z1, Z2), H)
      return { X3, Y3, Z3 }
    end

    --- Lift an affine point into Jacobian coordinates (Z = 1).
    --- @param F P256Field
    --- @param point crypto.p256.Point
    --- @return P256Jacobian?
    local function to_jacobian(F, point)
      if point.infinity then
        return nil
      end
      return { F.from_bytes(point.x), F.from_bytes(point.y), F.one }
    end

    --- Normalise a Jacobian point back to an affine one; one field inversion.
    --- @param F P256Field
    --- @param P P256Jacobian?
    --- @return crypto.p256.Point point
    local function to_affine(F, P)
      if P == nil or F.is_zero(P[3]) then
        return identity()
      end
      local z_inv = F.inv(P[3])
      local z_inv2 = F.sqr(z_inv)
      local x = F.mul(P[1], z_inv2)
      local y = F.mul(P[2], F.mul(z_inv2, z_inv))
      return new_point(F.to_bytes(x), F.to_bytes(y))
    end

    --- k * P with a fixed 4-bit window, most significant nibble first.
    --- @param F P256Field
    --- @param scalar string 32 big-endian bytes
    --- @param point crypto.p256.Point
    --- @return P256Jacobian?
    local function scalar_mul(F, scalar, point)
      local base = to_jacobian(F, point)
      if base == nil then
        return nil
      end
      local window = { base, jacobian_double(F, base) }
      for i = 3, 15 do
        window[i] = jacobian_add(F, window[i - 1], base)
      end

      local acc = nil
      for i = 1, 32 do
        local byte = string_byte(scalar, i)
        local high = floor(byte / 16)
        local low = byte % 16
        -- Doubling the identity is the identity, so skip it until the first digit.
        if acc ~= nil then
          acc = jacobian_double(F, jacobian_double(F, jacobian_double(F, jacobian_double(F, acc))))
        end
        if high ~= 0 then
          acc = jacobian_add(F, acc, window[high])
        end
        if acc ~= nil then
          acc = jacobian_double(F, jacobian_double(F, jacobian_double(F, jacobian_double(F, acc))))
        end
        if low ~= 0 then
          acc = jacobian_add(F, acc, window[low])
        end
      end
      return acc
    end

    --- x^3 - 3x + b, the right-hand side of the curve equation.
    --- @param F P256Field
    --- @param x any Field element
    --- @return any rhs
    local function curve_rhs(F, x)
      return F.add(F.mul(F.sub(F.sqr(x), F.three), x), F.b)
    end

    -- ============================================================================
    -- BACKEND SELECTION
    -- ============================================================================

    --- Whether a field reproduces the published 2G and 3G through this module's own
    --- doubling, addition and normalisation, and recovers Gy as a square root.
    --- Exercises every field operation the scalar multiplication uses.
    --- @param F P256Field
    --- @return boolean passed
    local function passes_known_answers(F)
      local ok, passed = pcall(function()
        local G = to_jacobian(F, new_point(bytes.from_hex(GX_HEX), bytes.from_hex(GY_HEX)))
        local two = to_affine(F, jacobian_double(F, G))
        local three = to_affine(F, jacobian_add(F, jacobian_double(F, G), G))
        local root = F.to_bytes(F.sqrt(curve_rhs(F, F.from_bytes(bytes.from_hex(GX_HEX)))))
        local gy = bytes.from_hex(GY_HEX)
        return two.x == bytes.from_hex(G2_X_HEX)
          and two.y == bytes.from_hex(G2_Y_HEX)
          and three.x == bytes.from_hex(G3_X_HEX)
          and three.y == bytes.from_hex(G3_Y_HEX)
          and (root == gy or root == negate_coordinate(gy))
      end)
      return ok and passed == true
    end

    --- The binding the OpenSSL field was last checked against, and the verdict.
    --- @type table?
    local _checked_binding = nil
    --- @type P256Field|false
    local _bn_field = false

    --- The OpenSSL field if acceleration is on and the binding is trusted, else nil.
    --- @return P256Field?
    local function trusted_bn_field()
      local openssl = openssl_wrapper.get(openssl_wrapper.Feature.BN)
      if openssl == nil then
        return nil
      end
      if _checked_binding ~= openssl then
        _checked_binding = openssl
        local ok, field = pcall(bn_field, openssl.bn)
        _bn_field = ok and passes_known_answers(field) and field or false
      end
      return _bn_field or nil
    end

    --- The field every operation runs on right now.
    --- @return P256Field
    local function field()
      return trusted_bn_field() or pure_field
    end

    -- ============================================================================
    -- PUBLIC INTERFACE
    -- ============================================================================

    --- The group order n, 32 big-endian bytes.
    p256.n = bytes.from_hex(N_HEX)

    --- The base point G.
    p256.G = new_point(bytes.from_hex(GX_HEX), bytes.from_hex(GY_HEX))

    --- Decode a SEC 1 point and check it.
    ---
    --- Accepts uncompressed (65 bytes, 0x04 || x || y) and compressed (33 bytes,
    --- 0x02 or 0x03 || x) encodings. Rejects the identity, coordinates >= p and
    --- points off the curve, returning nil and a reason rather than raising, since
    --- the input is normally a peer's.
    ---
    --- @param encoded string SEC 1 encoding
    --- @return crypto.p256.Point? point The point, or nil when invalid
    --- @return string? err Why it is invalid
    function p256.decode_point(encoded)
      if type(encoded) ~= "string" then
        return nil, "p256: a point must be a byte string"
      end
      local prefix = string_byte(encoded, 1)
      if #encoded == 1 and prefix == 0 then
        return nil, "p256: the identity is not accepted as a point"
      end
      local x, y
      if #encoded == 65 and prefix == 4 then
        x, y = string_sub(encoded, 2, 33), string_sub(encoded, 34, 65)
      elseif #encoded == 33 and (prefix == 2 or prefix == 3) then
        x = string_sub(encoded, 2, 33)
      else
        return nil, "p256: expected a 65-byte uncompressed (0x04) or 33-byte compressed (0x02, 0x03) SEC 1 point"
      end
      if not below_p(x) or (y ~= nil and not below_p(y)) then
        return nil, "p256: a coordinate is not below the field prime"
      end

      local F = field()
      local rhs = curve_rhs(F, F.from_bytes(x))
      if y ~= nil then
        if not F.equals(F.sqr(F.from_bytes(y)), rhs) then
          return nil, "p256: the point is not on the curve"
        end
        return new_point(x, y)
      end

      local root = F.sqrt(rhs)
      if not F.equals(F.sqr(root), rhs) then
        return nil, "p256: x is not the coordinate of a point on the curve"
      end
      y = F.to_bytes(root)
      -- The root is never zero: P-256 has no point of order 2.
      if (string_byte(y, 32) % 2 == 1) ~= (prefix == 3) then
        y = negate_coordinate(y)
      end
      return new_point(x, y)
    end

    --- Encode a point in SEC 1 form. Raises on the identity, which has no
    --- encoding a peer would accept.
    --- @param point crypto.p256.Point
    --- @param compressed? boolean True for 33 bytes, otherwise 65
    --- @return string encoded
    function p256.encode_point(point, compressed)
      check_point(point)
      if point.infinity then
        error("p256: the identity has no SEC 1 encoding here", 2)
      end
      local x, y = point.x, point.y
      --- @cast x string
      --- @cast y string
      if compressed then
        return (string_byte(y, 32) % 2 == 1 and "\3" or "\2") .. x
      end
      return "\4" .. x .. y
    end

    --- Scalar multiplication, k * P.
    --- @param scalar string 32 big-endian bytes, in [0, n-1]
    --- @param point crypto.p256.Point
    --- @return crypto.p256.Point product
    function p256.mul(scalar, point)
      check_scalar(scalar)
      check_point(point)
      local F = field()
      return to_affine(F, scalar_mul(F, scalar, point))
    end

    --- Scalar multiplication of the base point, k * G.
    --- @param scalar string 32 big-endian bytes, in [0, n-1]
    --- @return crypto.p256.Point product
    function p256.mul_base(scalar)
      check_scalar(scalar)
      local F = field()
      return to_affine(F, scalar_mul(F, scalar, p256.G))
    end

    --- Point addition, P + Q.
    --- @param p crypto.p256.Point
    --- @param q crypto.p256.Point
    --- @return crypto.p256.Point sum
    function p256.add(p, q)
      check_point(p)
      check_point(q)
      if p.infinity then
        return q
      elseif q.infinity then
        return p
      end
      local F = field()
      return to_affine(F, jacobian_add(F, to_jacobian(F, p), to_jacobian(F, q)))
    end

    --- Point subtraction, P - Q.
    --- @param p crypto.p256.Point
    --- @param q crypto.p256.Point
    --- @return crypto.p256.Point difference
    function p256.sub(p, q)
      check_point(p)
      check_point(q)
      if q.infinity then
        return p
      end
      local qy = q.y
      --- @cast qy string
      return p256.add(p, new_point(q.x, negate_coordinate(qy)))
    end

    --- Whether a point is the identity.
    --- @param point crypto.p256.Point
    --- @return boolean
    function p256.is_identity(point)
      check_point(point)
      return point.infinity == true
    end

    --- Whether two points are equal.
    --- @param p crypto.p256.Point
    --- @param q crypto.p256.Point
    --- @return boolean
    function p256.equals(p, q)
      check_point(p)
      check_point(q)
      if p.infinity or q.infinity then
        return p.infinity == true and q.infinity == true
      end
      return p.x == q.x and p.y == q.y
    end

    --- Reduce a big-endian integer of any length modulo n.
    ---
    --- RFC 9383 derives w0 and w1 by reducing PBKDF output halves at least 64 bits
    --- longer than n, which keeps the bias below 2^-64; this is that reduction.
    --- @param value string Big-endian bytes, any length ("" is zero)
    --- @return string scalar 32 big-endian bytes, in [0, n-1]
    function p256.reduce(value)
      assert(type(value) == "string", "p256: reduce takes a byte string")
      return bignum.to_bytes(bignum.mod(bignum.from_bytes(value), N_BN), 32)
    end

    --- A uniformly random scalar in [1, n-1] from `crypto.random`.
    ---
    --- Draws 32 bytes and redraws when the value is 0 or >= n, which happens with
    --- probability about 2^-32, so the result is exactly uniform.
    --- @return string scalar 32 big-endian bytes
    function p256.random_scalar()
      while true do
        local candidate = random.bytes(32)
        local value = bignum.from_bytes(candidate)
        if not bignum.is_zero(value) and bignum.compare(value, N_BN) < 0 then
          return candidate
        end
      end
    end

    --- Whether scalar multiplication runs on OpenSSL.
    ---
    --- True only when acceleration is enabled, the binding passes `Feature.BN`, and
    --- it reproduces the published 2G and 3G through this module's own doubling and
    --- addition -- the same conditions the operations apply. When false, the
    --- second value says why, in the same terms as `crypto.bignum.is_accelerated`:
    --- a driver that never called `crypto.use_openssl(true)` and a host that cannot
    --- accelerate both read false, and need opposite fixes.
    ---
    --- @return boolean accelerated
    --- @return string|nil reason Why not, when not
    function p256.is_accelerated()
      local openssl = openssl_wrapper.get(openssl_wrapper.Feature.BN)
      if openssl == nil then
        return false,
          openssl_wrapper.unavailable_reason(openssl_wrapper.Feature.BN)
            or "OpenSSL P-256 field arithmetic is unavailable"
      end
      if trusted_bn_field() == nil then
        return false,
          "the lua-openssl binding failed p256's 2G/3G known-answer check, so its field arithmetic is not trusted"
      end
      return true
    end

    -- Private functions and values the tests in test/ check directly.
    p256._internal = {
      N_BN = N_BN,
      to_affine = to_affine,
      scalar_mul = scalar_mul,
      passes_known_answers = passes_known_answers,
      field = field,
      pure_field = pure_field,
      --- Forget the OpenSSL field's verdict, so the next operation checks the binding again.
      reset_binding_check = function()
        _checked_binding = nil
        _bn_field = false
      end,
    }

    return p256
  end
end

do
  local _ENV = _ENV
  package.preload["crypto.pbkdf2"] = function(...)
    local arg = _G.arg
    --- @module "crypto.pbkdf2"
    --- PBKDF2, RFC 8018 section 5.2, over HMAC-SHA256 or HMAC-SHA512.
    ---
    --- A thin layer over the HMAC functions in `crypto.sha256` / `crypto.sha512`,
    --- which already run through OpenSSL when acceleration is enabled, so PBKDF2
    --- inherits that acceleration without a route of its own, as HKDF does.
    ---
    --- The cost is one HMAC per iteration per output block (32 bytes for SHA-256,
    --- 64 for SHA-512). In pure Lua an HMAC-SHA256 takes about 0.01 ms under LuaJIT
    --- and 0.6 to 4 ms under PUC Lua 5.1 to 5.5 on a desktop, so a high iteration
    --- count is only practical with the JIT or with acceleration on.
    ---
    --- @usage
    --- local pbkdf2 = require("crypto.pbkdf2")
    --- local key = pbkdf2.derive("sha256", password, salt, 10000, 32)
    ---
    --- @class crypto.pbkdf2
    local pbkdf2 = {}

    local bit32 = require("bitn").bit32

    local sha256 = require("crypto.sha256")
    local sha512 = require("crypto.sha512")
    local utils = require("crypto.utils")
    local bytes = utils.bytes

    -- Local references for performance
    local bit32_raw_bxor = bit32.raw_bxor
    local ceil = math.ceil
    local string_byte = string.byte
    local string_char = string.char
    local string_sub = string.sub
    local table_concat = table.concat

    --- A PRF PBKDF2 can use: HMAC over one hash, and that hash's output length.
    --- @class Pbkdf2Hash
    --- @field hmac fun(key: string, data: string): string HMAC over this hash
    --- @field length integer hLen in bytes

    --- @type table<string, Pbkdf2Hash>
    local HASHES = {
      sha256 = { hmac = sha256.hmac_sha256, length = 32 },
      sha512 = { hmac = sha512.hmac_sha512, length = 64 },
    }

    --- Derive a key with PBKDF2-HMAC.
    ---
    --- @param hash_name string "sha256" or "sha512"
    --- @param password string Password P, any bytes
    --- @param salt string Salt S, any bytes
    --- @param iterations integer Iteration count c, at least 1
    --- @param length integer Derived key length dkLen in bytes, at least 1
    --- @return string key `length` bytes
    function pbkdf2.derive(hash_name, password, salt, iterations, length)
      local params = HASHES[hash_name]
      if params == nil then
        error("PBKDF2: unsupported hash " .. tostring(hash_name) .. ' (expected "sha256" or "sha512")', 2)
      end
      assert(type(password) == "string", "PBKDF2: password must be a string")
      assert(type(salt) == "string", "PBKDF2: salt must be a string")
      assert(
        type(iterations) == "number" and iterations >= 1 and iterations % 1 == 0,
        "PBKDF2: iterations must be a positive integer"
      )
      assert(type(length) == "number" and length >= 1 and length % 1 == 0, "PBKDF2: length must be a positive integer")

      local hmac = params.hmac
      local hash_length = params.length
      local block_count = ceil(length / hash_length)
      -- RFC 8018 5.2 step 1: the block index is a 32-bit counter.
      assert(block_count <= 4294967295, "PBKDF2: derived key too long")

      local blocks = {}
      for i = 1, block_count do
        -- T_i = U_1 xor U_2 xor ... xor U_c, with U_1 = PRF(P, S || INT(i)).
        local u = hmac(password, salt .. bytes.u32_to_be_bytes(i))
        local t = { string_byte(u, 1, hash_length) }
        for _ = 2, iterations do
          u = hmac(password, u)
          for j = 1, hash_length do
            t[j] = bit32_raw_bxor(t[j], string_byte(u, j))
          end
        end
        local chars = {}
        for j = 1, hash_length do
          chars[j] = string_char(t[j])
        end
        blocks[i] = table_concat(chars)
      end
      return string_sub(table_concat(blocks), 1, length)
    end

    return pbkdf2
  end
end

do
  local _ENV = _ENV
  package.preload["crypto.poly1305"] = function(...)
    local arg = _G.arg
    --- @module "crypto.poly1305"
    --- Poly1305 Message Authentication Code (MAC) Implementation for portability.
    --- @class crypto.poly1305
    local poly1305 = {}

    local bit32 = require("bitn").bit32

    -- Local references for performance
    local bit32_raw_band = bit32.raw_band
    local bit32_raw_lshift = bit32.raw_lshift
    local floor = math.floor
    local string_byte = string.byte
    local string_char = string.char
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

    return poly1305
  end
end

do
  local _ENV = _ENV
  package.preload["crypto.random"] = function(...)
    local arg = _G.arg
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

    --- Path read by the `/dev/urandom` source. Exposed only so the tests can
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

    return random
  end
end

do
  local _ENV = _ENV
  package.preload["crypto.sha256"] = function(...)
    local arg = _G.arg
    --- @module "crypto.sha256"
    --- Pure Lua SHA-256 Implementation for portability.
    --- @class crypto.sha256
    local sha256 = {}

    local bit32 = require("bitn").bit32

    local openssl_wrapper = require("crypto.openssl_wrapper")
    local utils = require("crypto.utils")
    local bytes = utils.bytes

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
        local s0 =
          bit32_raw_bxor(bit32_raw_ror(w15, 7), bit32_raw_bxor(bit32_raw_ror(w15, 18), bit32_raw_rshift(w15, 3)))
        local s1 =
          bit32_raw_bxor(bit32_raw_ror(w2, 17), bit32_raw_bxor(bit32_raw_ror(w2, 19), bit32_raw_rshift(w2, 10)))
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

    return sha256
  end
end

do
  local _ENV = _ENV
  package.preload["crypto.sha512"] = function(...)
    local arg = _G.arg
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

    -- Local references for performance
    local bit64_raw_add = bit64.raw_add
    local bit64_raw_bxor = bit64.raw_bxor
    local bit64_raw_band = bit64.raw_band
    local bit64_raw_bnot = bit64.raw_bnot
    local bit64_raw_ror = bit64.raw_ror
    local bit64_raw_rshift = bit64.raw_rshift
    local bit64_new = bit64.new
    local bit64_from_number = bit64.from_number
    local bit32_raw_bxor = bit32.raw_bxor
    local string_char = string.char
    local string_rep = string.rep
    local string_byte = string.byte
    local table_concat = table.concat

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
      data = data .. bytes.u64_to_be_bytes(bit64_from_number(msg_len_bits))

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

    return sha512
  end
end

do
  local _ENV = _ENV
  package.preload["crypto.spake2plus"] = function(...)
    local arg = _G.arg
    --- @module "crypto.spake2plus"
    --- SPAKE2+, RFC 9383, for the ciphersuite P256-SHA256-HKDF-SHA256-HMAC-SHA256
    --- with the RFC's M and N. No other suite is offered.
    ---
    --- Both roles are here. The prover knows the password, so both w0 and w1; it
    --- is the side a client runs. The verifier holds w0 and the registration record
    --- L = w1*G; it is here for tests and for stand-in devices.
    ---
    --- RFC 9383 leaves the password-to-(w0, w1) step to the application, and so
    --- does this module: run the application's PBKDF (`crypto.pbkdf2`, for example)
    --- and reduce each half of its output with `crypto.p256.reduce`. w0, w1, x and
    --- y are 32-byte big-endian scalars in [0, n-1]; `crypto.p256.random_scalar`
    --- makes x and y.
    ---
    --- Points go out as 65-byte uncompressed SEC 1. Peer points may arrive
    --- compressed or uncompressed, are validated, and are always written into the
    --- transcript uncompressed. An invalid peer point, or a Z or V that comes out as
    --- the identity, makes the `*_finish` functions return nil and a reason.
    ---
    --- Pacing
    --- ------
    --- Each call is up to three P-256 scalar multiplications: about 53 ms each
    --- through OpenSSL on a Control4 controller, more in pure Lua (see
    --- `crypto.p256`). Lua runs one driver at a time there, so `opts.step`, if
    --- given, is called between consecutive multiplications and nothing else. A
    --- caller that runs the exchange inside a coroutine can pass a function that
    --- yields and resume it from a timer, one multiplication per tick. Check
    --- `is_accelerated()` before starting.
    ---
    --- @usage
    --- local p256 = require("crypto.p256")
    --- local spake2plus = require("crypto.spake2plus")
    ---
    --- local x = p256.random_scalar()
    --- send(spake2plus.prover_share(w0, x)) -- X, 65 bytes
    --- local result = assert(spake2plus.prover_finish(w0, w1, x, X, Y, context, "client", "server"))
    --- -- Check the verifier's confirmV against result.verifier_confirm in constant
    --- -- time before sending result.prover_confirm or using result.shared_key.
    ---
    --- @class crypto.spake2plus
    local spake2plus = {}

    local hkdf = require("crypto.hkdf")
    local p256 = require("crypto.p256")
    local sha256 = require("crypto.sha256")
    local utils = require("crypto.utils")
    local bytes = utils.bytes

    -- Local references for performance
    local floor = math.floor
    local string_char = string.char
    local string_sub = string.sub
    local table_concat = table.concat

    -- ============================================================================
    -- CONSTANTS AND TYPES
    -- ============================================================================

    -- RFC 9383 section 4, P-256: M and N, uncompressed as they appear in the
    -- Appendix C transcript. The section 4 compressed forms are checked against
    -- these by the tests.
    local M_HEX = "04886e2f97ace46e55ba9dd7242579f2993b64e16ef3dcab95afd497333d8fa12f"
      .. "5ff355163e43ce224e0b0e65ff02ac8e5c7be09419c785e0ca547d55a12e2d20"
    local N_HEX = "04d8bbd6c639c62937b04d997f38c3770719c629d7014d49a24b4f98baa1292b49"
      .. "07d60aa6bfade45008a636337f5168c64d9bd36034808cd564490b1e656edbe7"

    local M_BYTES = bytes.from_hex(M_HEX)
    local N_BYTES = bytes.from_hex(N_HEX)

    --- Options shared by the share and finish functions.
    --- @class crypto.spake2plus.Options
    --- @field step? fun() Called between consecutive scalar multiplications

    --- What both roles derive. The confirmations are named by who sends them.
    --- @class crypto.spake2plus.Result
    --- @field shared_key string K_shared, 32 bytes
    --- @field prover_confirm string confirmP = HMAC-SHA256(K_confirmP, Y): the prover sends it, the verifier checks it
    --- @field verifier_confirm string confirmV = HMAC-SHA256(K_confirmV, X): the verifier sends it, the prover checks it
    --- @field transcript string TT, for debugging. It ends with w0, so it is as secret as the password: never log it

    --- Intermediate values, for the tests.
    --- @class Spake2plusDetail
    --- @field Z string Uncompressed
    --- @field V string Uncompressed
    --- @field K_main string
    --- @field K_confirmP string
    --- @field K_confirmV string

    --- M and N as points, decoded on first use.
    --- @type crypto.p256.Point?, crypto.p256.Point?
    local m_point, n_point

    --- @return crypto.p256.Point M
    --- @return crypto.p256.Point N
    local function constants()
      if m_point == nil or n_point == nil then
        m_point = assert(p256.decode_point(M_BYTES))
        n_point = assert(p256.decode_point(N_BYTES))
      end
      return m_point, n_point
    end

    -- ============================================================================
    -- INTERNAL HELPERS
    -- ============================================================================

    --- Raise unless `value` is a 32-byte scalar.
    --- @param name string
    --- @param value any
    local function check_scalar(name, value)
      if type(value) ~= "string" or #value ~= 32 then
        error("SPAKE2+: " .. name .. " must be a 32-byte big-endian scalar", 3)
      end
    end

    --- The step callback from `opts`, or a no-op.
    --- @param opts crypto.spake2plus.Options?
    --- @return fun() step
    local function stepper(opts)
      if opts == nil then
        return function() end
      end
      if type(opts) ~= "table" then
        error("SPAKE2+: opts must be a table", 3)
      end
      local step = opts.step
      if step == nil then
        return function() end
      end
      if type(step) ~= "function" then
        error("SPAKE2+: opts.step must be a function", 3)
      end
      return step
    end

    --- An optional transcript string, "" when absent.
    --- @param name string
    --- @param value any
    --- @return string
    local function optional_string(name, value)
      if value == nil then
        return ""
      end
      if type(value) ~= "string" then
        error("SPAKE2+: " .. name .. " must be a string", 3)
      end
      return value
    end

    --- Append len(value) || value, the length as an 8-byte little-endian integer.
    --- @param parts string[]
    --- @param value string
    local function append_prefixed(parts, value)
      local n = #value
      local length = {}
      for i = 1, 8 do
        length[i] = string_char(n % 256)
        n = floor(n / 256)
      end
      parts[#parts + 1] = table_concat(length)
      parts[#parts + 1] = value
    end

    --- Decode a point for the exchange, naming it in the error.
    --- @param name string
    --- @param encoded any
    --- @return crypto.p256.Point? point
    --- @return string? err
    local function decode(name, encoded)
      local point, err = p256.decode_point(encoded)
      if point == nil then
        return nil, "SPAKE2+: invalid " .. name .. ": " .. tostring(err)
      end
      return point
    end

    --- Build TT from the shared values and run the key schedule (RFC 9383 3.3, 3.4).
    --- @param context string
    --- @param id_prover string
    --- @param id_verifier string
    --- @param X crypto.p256.Point
    --- @param Y crypto.p256.Point
    --- @param Z crypto.p256.Point
    --- @param V crypto.p256.Point
    --- @param w0 string
    --- @return crypto.spake2plus.Result? result
    --- @return Spake2plusDetail|string detail Intermediate values, or why it failed
    local function key_schedule(context, id_prover, id_verifier, X, Y, Z, V, w0)
      if p256.is_identity(Z) or p256.is_identity(V) then
        return nil, "SPAKE2+: Z or V is the identity; the peer's share is invalid"
      end
      local X_bytes = p256.encode_point(X)
      local Y_bytes = p256.encode_point(Y)
      local Z_bytes = p256.encode_point(Z)
      local V_bytes = p256.encode_point(V)

      local parts = {}
      for _, value in ipairs({
        context,
        id_prover,
        id_verifier,
        M_BYTES,
        N_BYTES,
        X_bytes,
        Y_bytes,
        Z_bytes,
        V_bytes,
        w0,
      }) do
        append_prefixed(parts, value)
      end
      local transcript = table_concat(parts)

      local K_main = sha256.sha256(transcript)
      local confirmation_keys = hkdf.derive("sha256", nil, K_main, "ConfirmationKeys", 64)
      local K_confirmP = string_sub(confirmation_keys, 1, 32)
      local K_confirmV = string_sub(confirmation_keys, 33, 64)

      return {
        shared_key = hkdf.derive("sha256", nil, K_main, "SharedKey", 32),
        prover_confirm = sha256.hmac_sha256(K_confirmP, Y_bytes),
        verifier_confirm = sha256.hmac_sha256(K_confirmV, X_bytes),
        transcript = transcript,
      }, {
        Z = Z_bytes,
        V = V_bytes,
        K_main = K_main,
        K_confirmP = K_confirmP,
        K_confirmV = K_confirmV,
      }
    end

    --- The prover's side of the finish, with intermediates.
    --- @return crypto.spake2plus.Result? result
    --- @return Spake2plusDetail|string detail
    local function prover_compute(w0, w1, x, X, Y, context, id_prover, id_verifier, opts)
      check_scalar("w0", w0)
      check_scalar("w1", w1)
      check_scalar("x", x)
      context = optional_string("context", context)
      id_prover = optional_string("id_prover", id_prover)
      id_verifier = optional_string("id_verifier", id_verifier)
      local step = stepper(opts)

      local X_point, x_err = decode("X", X)
      if X_point == nil then
        return nil, tostring(x_err)
      end
      local Y_point, y_err = decode("Y", Y)
      if Y_point == nil then
        return nil, tostring(y_err)
      end

      local _, N = constants()
      local U = p256.sub(Y_point, p256.mul(w0, N))
      step()
      local Z = p256.mul(x, U)
      step()
      local V = p256.mul(w1, U)
      return key_schedule(context, id_prover, id_verifier, X_point, Y_point, Z, V, w0)
    end

    --- The verifier's side of the finish, with intermediates.
    --- @return crypto.spake2plus.Result? result
    --- @return Spake2plusDetail|string detail
    local function verifier_compute(w0, L, y, X, Y, context, id_prover, id_verifier, opts)
      check_scalar("w0", w0)
      check_scalar("y", y)
      context = optional_string("context", context)
      id_prover = optional_string("id_prover", id_prover)
      id_verifier = optional_string("id_verifier", id_verifier)
      local step = stepper(opts)

      local L_point, l_err = decode("L", L)
      if L_point == nil then
        return nil, tostring(l_err)
      end
      local X_point, x_err = decode("X", X)
      if X_point == nil then
        return nil, tostring(x_err)
      end
      local Y_point, y_err = decode("Y", Y)
      if Y_point == nil then
        return nil, tostring(y_err)
      end

      local M = constants()
      local T = p256.sub(X_point, p256.mul(w0, M))
      step()
      local Z = p256.mul(y, T)
      step()
      local V = p256.mul(y, L_point)
      return key_schedule(context, id_prover, id_verifier, X_point, Y_point, Z, V, w0)
    end

    -- ============================================================================
    -- PUBLIC INTERFACE
    -- ============================================================================

    --- The prover's share, X = x*G + w0*M.
    --- @param w0 string 32-byte scalar
    --- @param x string 32-byte scalar, fresh and secret
    --- @param opts? crypto.spake2plus.Options
    --- @return string X 65 bytes, uncompressed
    function spake2plus.prover_share(w0, x, opts)
      check_scalar("w0", w0)
      check_scalar("x", x)
      local step = stepper(opts)
      local M = constants()
      local xG = p256.mul_base(x)
      step()
      return p256.encode_point(p256.add(xG, p256.mul(w0, M)))
    end

    --- The prover's finish: validate Y, derive Z = x*(Y - w0*N) and
    --- V = w1*(Y - w0*N), and run the key schedule.
    ---
    --- @param w0 string 32-byte scalar
    --- @param w1 string 32-byte scalar
    --- @param x string The scalar `prover_share` used
    --- @param X string The share `prover_share` returned
    --- @param Y string The verifier's share, compressed or uncompressed
    --- @param context? string Application context ("" when nil)
    --- @param id_prover? string Prover identity ("" when nil)
    --- @param id_verifier? string Verifier identity ("" when nil)
    --- @param opts? crypto.spake2plus.Options
    --- @return crypto.spake2plus.Result? result
    --- @return string? err Why the exchange failed: an invalid point, or Z or V the identity
    function spake2plus.prover_finish(w0, w1, x, X, Y, context, id_prover, id_verifier, opts)
      local result, detail = prover_compute(w0, w1, x, X, Y, context, id_prover, id_verifier, opts)
      if result == nil then
        return nil, tostring(detail)
      end
      return result
    end

    --- The verifier's registration record, L = w1*G.
    --- @param w1 string 32-byte scalar
    --- @return string L 65 bytes, uncompressed
    function spake2plus.registration(w1)
      check_scalar("w1", w1)
      return p256.encode_point(p256.mul_base(w1))
    end

    --- The verifier's share, Y = y*G + w0*N.
    --- @param w0 string 32-byte scalar
    --- @param y string 32-byte scalar, fresh and secret
    --- @param opts? crypto.spake2plus.Options
    --- @return string Y 65 bytes, uncompressed
    function spake2plus.verifier_share(w0, y, opts)
      check_scalar("w0", w0)
      check_scalar("y", y)
      local step = stepper(opts)
      local _, N = constants()
      local yG = p256.mul_base(y)
      step()
      return p256.encode_point(p256.add(yG, p256.mul(w0, N)))
    end

    --- The verifier's finish: validate X, derive Z = y*(X - w0*M) and V = y*L, and
    --- run the key schedule. The result has the same shape as `prover_finish`'s.
    ---
    --- @param w0 string 32-byte scalar
    --- @param L string Registration record from `registration`
    --- @param y string The scalar `verifier_share` used
    --- @param X string The prover's share, compressed or uncompressed
    --- @param Y string The share `verifier_share` returned
    --- @param context? string Application context ("" when nil)
    --- @param id_prover? string Prover identity ("" when nil)
    --- @param id_verifier? string Verifier identity ("" when nil)
    --- @param opts? crypto.spake2plus.Options
    --- @return crypto.spake2plus.Result? result
    --- @return string? err Why the exchange failed: an invalid point, or Z or V the identity
    function spake2plus.verifier_finish(w0, L, y, X, Y, context, id_prover, id_verifier, opts)
      local result, detail = verifier_compute(w0, L, y, X, Y, context, id_prover, id_verifier, opts)
      if result == nil then
        return nil, tostring(detail)
      end
      return result
    end

    --- Whether the scalar multiplications run on OpenSSL; see `crypto.p256.is_accelerated`.
    --- @return boolean accelerated
    --- @return string|nil reason Why not, when not
    function spake2plus.is_accelerated()
      return p256.is_accelerated()
    end

    -- Private functions the tests in test/ check directly.
    spake2plus._internal = {
      constants = constants,
      prover_compute = prover_compute,
      verifier_compute = verifier_compute,
    }

    return spake2plus
  end
end

do
  local _ENV = _ENV
  package.preload["crypto.srp"] = function(...)
    local arg = _G.arg
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
    --- SRP-6a's cost is dominated by modular exponentiation. On a Control4
    --- controller (2026-10-18) a client exchange takes about 2.5 s in pure Lua with
    --- LuaJIT's JIT on, about 28 s without it, and about 0.04 s through `bn.powmod`.
    --- Lua there is effectively serialised across drivers, so the pure path stalls
    --- them all for that long.
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

    -- Private functions the tests in test/ check directly.
    srp._internal = {
      resolve_group = resolve_group,
    }

    return srp
  end
end

do
  local _ENV = _ENV
  package.preload["crypto.utils"] = function(...)
    local arg = _G.arg
    --- @module "crypto.utils"
    --- Common utility functions for the Noise Protocol Framework
    --- @class crypto.utils
    local utils = {
      --- @type crypto.utils.bytes
      bytes = require("crypto.utils.bytes"),
    }

    return utils
  end
end

do
  local _ENV = _ENV
  package.preload["crypto.utils.bytes"] = function(...)
    local arg = _G.arg
    --- @module "crypto.utils.bytes"
    --- Byte manipulation and conversion utilities
    --- @class crypto.utils.bytes
    local bytes = {}

    local bitn = require("bitn")
    local bit32 = bitn.bit32
    local bit64 = bitn.bit64

    -- Local references for performance
    local bit32_raw_bor = bit32.raw_bor
    local bit32_raw_bxor = bit32.raw_bxor
    local bit32_u32_to_le_bytes = bit32.u32_to_le_bytes
    local bit32_u32_to_be_bytes = bit32.u32_to_be_bytes
    local bit32_le_bytes_to_u32 = bit32.le_bytes_to_u32
    local bit32_be_bytes_to_u32 = bit32.be_bytes_to_u32
    local bit64_from_number = bit64.from_number
    local bit64_u64_to_le_bytes = bit64.u64_to_le_bytes
    local bit64_u64_to_be_bytes = bit64.u64_to_be_bytes
    local bit64_le_bytes_to_u64 = bit64.le_bytes_to_u64
    local bit64_be_bytes_to_u64 = bit64.be_bytes_to_u64
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
      return bit32_u32_to_le_bytes(n)
    end

    --- Convert 32-bit unsigned integer to 4 bytes (big-endian)
    --- @param n integer 32-bit unsigned integer
    --- @return string bytes 4-byte string in big-endian order
    function bytes.u32_to_be_bytes(n)
      return bit32_u32_to_be_bytes(n)
    end

    --- Convert 64-bit value to 8 bytes (big-endian)
    --- @param x Int64HighLow {high, low} 64-bit value
    --- @return string bytes 8-byte string in big-endian order
    function bytes.u64_to_be_bytes(x)
      return bit64_u64_to_be_bytes(x)
    end

    --- Convert 64-bit value to 8 bytes (little-endian)
    --- @param x Int64HighLow|integer {high, low} 64-bit value or simple integer
    --- @return string bytes 8-byte string in little-endian order
    function bytes.u64_to_le_bytes(x)
      if type(x) == "number" then
        return bit64_u64_to_le_bytes(bit64_from_number(x))
      end
      --- @cast x Int64HighLow
      return bit64_u64_to_le_bytes(x)
    end

    --- Convert 4 bytes to 32-bit unsigned integer (little-endian)
    --- @param str string Binary string (at least 4 bytes)
    --- @param offset? integer Starting position (default: 1)
    --- @return integer n 32-bit unsigned integer
    function bytes.le_bytes_to_u32(str, offset)
      return bit32_le_bytes_to_u32(str, offset)
    end

    --- Convert 4 bytes to 32-bit unsigned integer (big-endian)
    --- @param str string Binary string (at least 4 bytes)
    --- @param offset? integer Starting position (default: 1)
    --- @return integer n 32-bit unsigned integer
    function bytes.be_bytes_to_u32(str, offset)
      return bit32_be_bytes_to_u32(str, offset)
    end

    --- Convert 8 bytes to 64-bit value (big-endian)
    --- @param str string Binary string (at least 8 bytes)
    --- @param offset? integer Starting position (default: 1)
    --- @return Int64HighLow value {high, low} 64-bit value
    function bytes.be_bytes_to_u64(str, offset)
      return bit64_be_bytes_to_u64(str, offset)
    end

    --- Convert 8 bytes to 64-bit value (little-endian)
    --- @param str string Binary string (at least 8 bytes)
    --- @param offset? integer Starting position (default: 1)
    --- @return Int64HighLow value {high, low} 64-bit value
    function bytes.le_bytes_to_u64(str, offset)
      return bit64_le_bytes_to_u64(str, offset)
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

    return bytes
  end
end

do
  local _ENV = _ENV
  package.preload["crypto.x25519"] = function(...)
    local arg = _G.arg
    --- @module "crypto.x25519"
    --- X25519 Curve25519 Elliptic Curve Diffie-Hellman Implementation for portability.
    --- @class crypto.x25519
    local x25519 = {}

    local bit32 = require("bitn").bit32

    local random = require("crypto.random")

    -- Local references for performance
    local bit32_raw_band = bit32.raw_band
    local bit32_raw_rshift = bit32.raw_rshift
    local floor = math.floor
    local string_byte = string.byte
    local string_char = string.char
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

    return x25519
  end
end

do
  local _ENV = _ENV
  package.preload["crypto.x448"] = function(...)
    local arg = _G.arg
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

    -- Store private key counter for better randomness
    x448._key_counter = 0

    return x448
  end
end

--- @module "crypto"
--- Portable cryptographic primitives for Lua with optional OpenSSL acceleration.
--- Pure-Lua implementations of hashing (SHA-256/512, BLAKE2), AEAD ciphers
--- (ChaCha20-Poly1305, AES-GCM, AES-CCM), the Poly1305 MAC, HKDF and PBKDF2 key
--- derivation, Curve25519/448 Diffie-Hellman, Ed25519 signatures, SRP-6a, NIST
--- P-256 group arithmetic and SPAKE2+. Runs on Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT
--- with zero C dependencies.
---
--- Key generation draws from `crypto.random`, which uses the host CSPRNG and
--- raises when there is not one. It never falls back to `math.random`.
---
--- When the host provides the lua-openssl binding (e.g. Control4 DriverWorks OS
--- >= 3.4.1), hashing, AEAD, big-number and P-256 arithmetic transparently prefer it
--- for speed and fall back to the pure-Lua implementations otherwise. The
--- elliptic-curve Diffie-Hellman functions (x25519/x448) and Ed25519 signing
--- always use the portable implementations regardless of the OpenSSL flag --
--- the shipped lua-openssl builds cannot perform the raw Curve25519/448
--- operations, and cannot sign with an Ed25519 key even when they can import
--- one.
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
  --- @type crypto.aes_ccm
  aes_ccm = require("crypto.aes_ccm"),

  -- Stream ciphers
  --- @type crypto.chacha20
  chacha20 = require("crypto.chacha20"),

  -- MAC
  --- @type crypto.poly1305
  poly1305 = require("crypto.poly1305"),

  -- Key derivation
  --- @type crypto.hkdf
  hkdf = require("crypto.hkdf"),
  --- @type crypto.pbkdf2
  pbkdf2 = require("crypto.pbkdf2"),

  -- Cryptographically secure randomness (raises rather than returning weak bytes)
  --- @type crypto.random
  random = require("crypto.random"),

  -- Arbitrary-precision integers (OpenSSL-preferred)
  --- @type crypto.bignum
  bignum = require("crypto.bignum"),

  -- Password-authenticated key exchange (client side)
  --- @type crypto.srp
  srp = require("crypto.srp"),

  -- NIST P-256 group arithmetic (OpenSSL-preferred)
  --- @type crypto.p256
  p256 = require("crypto.p256"),

  -- Password-authenticated key exchange over P-256 (both roles)
  --- @type crypto.spake2plus
  spake2plus = require("crypto.spake2plus"),

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
local VERSION = "v0.4.0"

--- Enable or disable OpenSSL acceleration for the primitives that support it
--- (hashing, AEAD, big-number and P-256 arithmetic). Opt-in and safe: when the lua-openssl binding is
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

return crypto

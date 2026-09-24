--- Reads single files out of an in-memory ZIP archive, such as a downloaded .c4z, from stored or
--- deflated entries. Plain arithmetic throughout: the controller's Lua has no guaranteed bit library.

--- @class Zip
local Zip = {}

local POW2 = {}
for i = 0, 31 do
  POW2[i] = 2 ^ i
end

-- RFC 1951 tables, indexed from 0 like the symbols they decode.
-- stylua: ignore start
local LENGTH_BASE = {
  [0] = 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
}
local LENGTH_EXTRA = { [0] = 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DISTANCE_BASE = {
  [0] = 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097,
  6145, 8193, 12289, 16385, 24577,
}
local DISTANCE_EXTRA = {
  [0] = 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
}
-- stylua: ignore end
local CODE_LENGTH_ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

local function fail(message)
  error(message, 0)
end

--- Reads `need` bits, least significant first, from the deflate stream.
--- @param state table
--- @param need integer
--- @return integer
local function bits(state, need)
  local buf, cnt = state.bitbuf, state.bitcnt
  while cnt < need do
    local byte = state.src:byte(state.pos)
    if byte == nil then
      fail("deflate data ends early")
    end
    state.pos = state.pos + 1
    buf = buf + byte * POW2[cnt]
    cnt = cnt + 8
  end
  state.bitbuf = math.floor(buf / POW2[need])
  state.bitcnt = cnt - need
  return buf % POW2[need]
end

--- Builds a canonical Huffman decoder from code lengths (zlib's puff.c construct).
--- @param lengths table<integer, integer> Code length per symbol, 0-indexed.
--- @param first integer Index in lengths of symbol 0.
--- @param n integer Number of symbols.
--- @return table decoder
--- @return integer left 0 when complete, above 0 when incomplete, below 0 when over-subscribed.
local function construct(lengths, first, n)
  local count, symbol = {}, {}
  for len = 0, 15 do
    count[len] = 0
  end
  for i = 0, n - 1 do
    local len = lengths[first + i] or 0
    count[len] = count[len] + 1
  end
  local decoder = { count = count, symbol = symbol }
  if count[0] == n then
    return decoder, 0
  end
  local left = 1
  for len = 1, 15 do
    left = left * 2 - count[len]
    if left < 0 then
      return decoder, left
    end
  end
  local offsets = { [1] = 0 }
  for len = 1, 14 do
    offsets[len + 1] = offsets[len] + count[len]
  end
  for i = 0, n - 1 do
    local len = lengths[first + i] or 0
    if len ~= 0 then
      symbol[offsets[len]] = i
      offsets[len] = offsets[len] + 1
    end
  end
  return decoder, left
end

--- @param state table
--- @param decoder table
--- @return integer symbol
local function decode(state, decoder)
  local code, first, index = 0, 0, 0
  local count, symbol = decoder.count, decoder.symbol
  for len = 1, 15 do
    code = code + bits(state, 1)
    local c = count[len]
    if code - c < first then
      return symbol[index + (code - first)]
    end
    index = index + c
    first = (first + c) * 2
    code = code * 2
  end
  fail("invalid Huffman code")
  return -1
end

--- @param state table
--- @param lencode table
--- @param distcode table
local function codes(state, lencode, distcode)
  local out = state.out
  local symbol
  repeat
    symbol = decode(state, lencode)
    if symbol < 256 then
      state.outlen = state.outlen + 1
      out[state.outlen] = symbol
    elseif symbol > 256 then
      local lengthSymbol = symbol - 257
      if lengthSymbol >= 29 then
        fail("invalid length symbol")
      end
      local len = LENGTH_BASE[lengthSymbol] + bits(state, LENGTH_EXTRA[lengthSymbol])
      local distSymbol = decode(state, distcode)
      if distSymbol >= 30 then
        fail("invalid distance symbol")
      end
      local dist = DISTANCE_BASE[distSymbol] + bits(state, DISTANCE_EXTRA[distSymbol])
      local n = state.outlen
      if dist > n then
        fail("distance reaches before the start of the data")
      end
      -- Byte by byte, since a copy may overlap the bytes it is producing.
      for i = 1, len do
        out[n + i] = out[n + i - dist]
      end
      state.outlen = n + len
    end
  until symbol == 256
end

--- @param state table
local function stored(state)
  -- A stored block starts on a byte boundary; the rest of the current byte is padding.
  state.bitbuf, state.bitcnt = 0, 0
  local src, pos = state.src, state.pos
  local b1, b2, b3, b4 = src:byte(pos, pos + 3)
  if b4 == nil then
    fail("deflate data ends early")
  end
  local len = b1 + b2 * 256
  if len + b3 + b4 * 256 ~= 65535 then
    fail("stored block length does not match its complement")
  end
  pos = pos + 4
  if pos + len - 1 > #src then
    fail("deflate data ends early")
  end
  local out, n = state.out, state.outlen
  for i = 0, len - 1 do
    out[n + 1 + i] = src:byte(pos + i)
  end
  state.outlen = n + len
  state.pos = pos + len
end

local fixedLencode, fixedDistcode

--- @return table lencode
--- @return table distcode
local function fixedCodes()
  if fixedLencode == nil then
    local lengths = {}
    for i = 0, 287 do
      lengths[i] = (i < 144 or i >= 280) and 8 or (i < 256 and 9 or 7)
    end
    fixedLencode = construct(lengths, 0, 288)
    local distances = {}
    for i = 0, 29 do
      distances[i] = 5
    end
    fixedDistcode = construct(distances, 0, 30)
  end
  return fixedLencode, fixedDistcode
end

--- An incomplete code is valid only as a single one-bit code (RFC 1951 3.2.7).
local function checkCode(decoder, left, n, what)
  if left < 0 or (left > 0 and n ~= decoder.count[0] + decoder.count[1]) then
    fail("invalid " .. what .. " code lengths")
  end
end

--- @param state table
local function dynamic(state)
  local nlen = bits(state, 5) + 257
  local ndist = bits(state, 5) + 1
  local ncode = bits(state, 4) + 4
  if nlen > 286 or ndist > 30 then
    fail("dynamic block has too many codes")
  end

  local codeLengths = {}
  for i = 1, 19 do
    codeLengths[CODE_LENGTH_ORDER[i]] = i <= ncode and bits(state, 3) or 0
  end
  local lencode, left = construct(codeLengths, 0, 19)
  if left ~= 0 then
    fail("invalid code length code lengths")
  end

  local lengths, index, total = {}, 0, nlen + ndist
  while index < total do
    local symbol = decode(state, lencode)
    if symbol < 16 then
      lengths[index] = symbol
      index = index + 1
    else
      local len, repeats = 0, nil
      if symbol == 16 then
        if index == 0 then
          fail("repeat with no previous length")
        end
        len = lengths[index - 1]
        repeats = 3 + bits(state, 2)
      elseif symbol == 17 then
        repeats = 3 + bits(state, 3)
      else
        repeats = 11 + bits(state, 7)
      end
      if index + repeats > total then
        fail("too many code lengths")
      end
      for _ = 1, repeats do
        lengths[index] = len
        index = index + 1
      end
    end
  end
  if lengths[256] == 0 then
    fail("dynamic block has no end-of-block code")
  end

  lencode, left = construct(lengths, 0, nlen)
  checkCode(lencode, left, nlen, "literal/length")
  local distcode
  distcode, left = construct(lengths, nlen, ndist)
  checkCode(distcode, left, ndist, "distance")
  codes(state, lencode, distcode)
end

--- Decompresses a raw deflate stream (RFC 1951).
--- @param src string
--- @return string
local function inflate(src)
  local state = { src = src, pos = 1, bitbuf = 0, bitcnt = 0, out = {}, outlen = 0 }
  local last
  repeat
    last = bits(state, 1)
    local blockType = bits(state, 2)
    if blockType == 0 then
      stored(state)
    elseif blockType == 1 then
      codes(state, fixedCodes())
    elseif blockType == 2 then
      dynamic(state)
    else
      fail("invalid block type")
    end
  until last == 1

  local parts = {}
  for i = 1, state.outlen, 4096 do
    parts[#parts + 1] = string.char(unpack(state.out, i, math.min(i + 4095, state.outlen)))
  end
  return table.concat(parts)
end

--- @param s string
--- @param i integer 1-based offset.
--- @return integer
local function u16(s, i)
  local a, b = s:byte(i, i + 1)
  if b == nil then
    fail("archive ends early")
  end
  return a + b * 256
end

--- @param s string
--- @param i integer 1-based offset.
--- @return integer
local function u32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  if d == nil then
    fail("archive ends early")
  end
  return a + b * 256 + c * 65536 + d * 16777216
end

--- @param archive string
--- @param name string
--- @return string|nil contents
local function extract(archive, name)
  -- The end record is last, followed only by its comment, which may itself contain the signature.
  local eocd
  for i = #archive - 21, math.max(1, #archive - 21 - 65535), -1 do
    if archive:sub(i, i + 3) == "PK\5\6" and i + 21 + u16(archive, i + 20) == #archive then
      eocd = i
      break
    end
  end
  if eocd == nil then
    fail("not a zip archive")
  end

  local entries = u16(archive, eocd + 10)
  local p = u32(archive, eocd + 16) + 1
  for _ = 1, entries do
    if archive:sub(p, p + 3) ~= "PK\1\2" then
      fail("corrupt central directory")
    end
    local nameLength = u16(archive, p + 28)
    if archive:sub(p + 46, p + 45 + nameLength) == name then
      local flags, method = u16(archive, p + 8), u16(archive, p + 10)
      local compressedSize, size = u32(archive, p + 20), u32(archive, p + 24)
      local header = u32(archive, p + 42) + 1
      if archive:sub(header, header + 3) ~= "PK\3\4" then
        fail("corrupt local header for " .. name)
      end
      if flags % 2 == 1 then
        fail(name .. " is encrypted")
      end
      local start = header + 30 + u16(archive, header + 26) + u16(archive, header + 28)
      local data = archive:sub(start, start + compressedSize - 1)
      if #data ~= compressedSize then
        fail("archive ends early")
      end
      local contents
      if method == 0 then
        contents = data
      elseif method == 8 then
        contents = inflate(data)
      else
        fail(string.format("%s uses unsupported compression method %d", name, method))
      end
      if #contents ~= size then
        fail(string.format("%s is %d bytes, expected %d", name, #contents, size))
      end
      return contents
    end
    p = p + 46 + nameLength + u16(archive, p + 30) + u16(archive, p + 32)
  end
  return nil
end

--- Reads one file out of a ZIP archive held in memory.
--- @param archive string The archive's bytes.
--- @param name string The file's path inside the archive, e.g. "driver.xml".
--- @return string|nil contents The file's contents, or nil when absent or unreadable.
--- @return string|nil err Why the file could not be read.
function Zip.read(archive, name)
  if type(archive) ~= "string" then
    return nil, "not a zip archive"
  end
  local ok, result = pcall(extract, archive, name)
  if not ok then
    return nil, tostring(result)
  end
  if result == nil then
    return nil, name .. " is not in the archive"
  end
  return result
end

--- Decompresses a raw deflate stream (RFC 1951), as stored in a zip entry.
--- @param data string
--- @return string|nil contents
--- @return string|nil err
function Zip.inflate(data)
  local ok, result = pcall(inflate, data)
  if not ok then
    return nil, tostring(result)
  end
  return result
end

return Zip

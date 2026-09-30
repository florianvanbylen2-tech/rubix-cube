--!strict
--!native
-- MD5 (noise names -> seeds) and SHA-256 (biome zoom seed), on bit32.

local band, bor, bxor, bnot = bit32.band, bit32.bor, bit32.bxor, bit32.bnot
local rshift, lrotate, rrotate = bit32.rshift, bit32.lrotate, bit32.rrotate

local Hash = {}

-- ---------------------------------------------------------------- MD5
local MD5_K: { number } = {}
for i = 0, 63 do
	MD5_K[i + 1] = math.floor(math.abs(math.sin(i + 1)) * 4294967296)
end
local MD5_S = {
	7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
	5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
	4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
	6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
}

-- Returns the 16 digest bytes.
function Hash.md5Bytes(msg: string): { number }
	local len = #msg
	local padLen = (56 - (len + 1) % 64) % 64
	local data = msg .. "\128" .. string.rep("\0", padLen)
	-- 64 bit little-endian bit length
	local bits = len * 8
	data ..= string.pack("<I4I4", bits % 4294967296, math.floor(bits / 4294967296))

	local a0, b0, c0, d0 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476
	local M = table.create(16, 0)
	for chunk = 1, #data, 64 do
		for i = 0, 15 do
			M[i + 1] = string.unpack("<I4", data, chunk + i * 4)
		end
		local A, B, C, D = a0, b0, c0, d0
		for i = 0, 63 do
			local F, g
			if i < 16 then
				F = bor(band(B, C), band(bnot(B), D))
				g = i
			elseif i < 32 then
				F = bor(band(D, B), band(bnot(D), C))
				g = (5 * i + 1) % 16
			elseif i < 48 then
				F = bxor(B, bxor(C, D))
				g = (3 * i + 5) % 16
			else
				F = bxor(C, bor(B, bnot(D)))
				g = (7 * i) % 16
			end
			F = (F + A + MD5_K[i + 1] + M[g + 1]) % 4294967296
			A = D
			D = C
			C = B
			B = (B + lrotate(F, MD5_S[i + 1])) % 4294967296
		end
		a0 = (a0 + A) % 4294967296
		b0 = (b0 + B) % 4294967296
		c0 = (c0 + C) % 4294967296
		d0 = (d0 + D) % 4294967296
	end
	local out = string.pack("<I4I4I4I4", a0, b0, c0, d0)
	local bytes = {}
	for i = 1, 16 do
		bytes[i] = string.byte(out, i)
	end
	return bytes
end

-- The MD5 digest as two big-endian 64 bit longs, each as (hi, lo): what Guava's Longs.fromBytes produces.
function Hash.md5Longs(msg: string): (number, number, number, number)
	local b = Hash.md5Bytes(msg)
	local function word(i: number): number
		return b[i] * 16777216 + b[i + 1] * 65536 + b[i + 2] * 256 + b[i + 3]
	end
	return word(1), word(5), word(9), word(13)
end

function Hash.md5Hex(msg: string): string
	local b = Hash.md5Bytes(msg)
	local t = {}
	for i = 1, 16 do
		t[i] = string.format("%02x", b[i])
	end
	return table.concat(t)
end

-- ---------------------------------------------------------------- SHA-256
local SHA_K: { number } = {}
do
	local primes = {}
	local n = 2
	while #primes < 64 do
		local isPrime = true
		for _, p in primes do
			if p * p > n then
				break
			end
			if n % p == 0 then
				isPrime = false
				break
			end
		end
		if isPrime then
			table.insert(primes, n)
		end
		n += 1
	end
	for i, p in primes do
		local c = p ^ (1 / 3)
		SHA_K[i] = math.floor((c - math.floor(c)) * 4294967296)
	end
end

function Hash.sha256Bytes(msg: string): { number }
	local len = #msg
	local padLen = (56 - (len + 1) % 64) % 64
	local bits = len * 8
	local data = msg .. "\128" .. string.rep("\0", padLen) .. string.pack(">I4I4", math.floor(bits / 4294967296), bits % 4294967296)
	local H = {
		0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
	}
	local w = table.create(64, 0)
	for chunk = 1, #data, 64 do
		for i = 0, 15 do
			w[i + 1] = string.unpack(">I4", data, chunk + i * 4)
		end
		for i = 16, 63 do
			local w15, w2 = w[i - 14], w[i - 1]
			local s0 = bxor(rrotate(w15, 7), rrotate(w15, 18), rshift(w15, 3))
			local s1 = bxor(rrotate(w2, 17), rrotate(w2, 19), rshift(w2, 10))
			w[i + 1] = (w[i - 15] + s0 + w[i - 6] + s1) % 4294967296
		end
		local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
		for i = 0, 63 do
			local S1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
			local ch = bxor(band(e, f), band(bnot(e), g))
			local t1 = (h + S1 + ch + SHA_K[i + 1] + w[i + 1]) % 4294967296
			local S0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
			local maj = bxor(band(a, b), band(a, c), band(b, c))
			local t2 = (S0 + maj) % 4294967296
			h, g, f, e, d, c, b, a = g, f, e, (d + t1) % 4294967296, c, b, a, (t1 + t2) % 4294967296
		end
		H[1] = (H[1] + a) % 4294967296
		H[2] = (H[2] + b) % 4294967296
		H[3] = (H[3] + c) % 4294967296
		H[4] = (H[4] + d) % 4294967296
		H[5] = (H[5] + e) % 4294967296
		H[6] = (H[6] + f) % 4294967296
		H[7] = (H[7] + g) % 4294967296
		H[8] = (H[8] + h) % 4294967296
	end
	local out = string.pack(">I4I4I4I4I4I4I4I4", table.unpack(H))
	local bytes = {}
	for i = 1, 32 do
		bytes[i] = string.byte(out, i)
	end
	return bytes
end

function Hash.sha256Hex(msg: string): string
	local b = Hash.sha256Bytes(msg)
	local t = {}
	for i = 1, 32 do
		t[i] = string.format("%02x", b[i])
	end
	return table.concat(t)
end

return Hash

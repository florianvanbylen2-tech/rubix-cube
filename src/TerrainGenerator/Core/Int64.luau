--!strict
--!native
-- 64-bit integer arithmetic on (hi, lo) pairs of uint32 numbers.
-- Luau has no int64; Minecraft's RNG/seed maths depends on exact 64-bit wraparound.

local band, bor, bxor = bit32.band, bit32.bor, bit32.bxor
local lshift, rshift, arshift = bit32.lshift, bit32.rshift, bit32.arshift

local TWO32 = 4294967296

local Int64 = {}

function Int64.add(ah: number, al: number, bh: number, bl: number): (number, number)
	local l = al + bl
	local carry = 0
	if l >= TWO32 then
		l -= TWO32
		carry = 1
	end
	return (ah + bh + carry) % TWO32, l
end

function Int64.neg(h: number, l: number): (number, number)
	local nl = (TWO32 - l) % TWO32
	local nh = (bxor(h, 0xFFFFFFFF) + (l == 0 and 1 or 0)) % TWO32
	return nh, nl
end

function Int64.sub(ah: number, al: number, bh: number, bl: number): (number, number)
	local nh, nl = Int64.neg(bh, bl)
	return Int64.add(ah, al, nh, nl)
end

function Int64.xor(ah: number, al: number, bh: number, bl: number): (number, number)
	return bxor(ah, bh), bxor(al, bl)
end

function Int64.band(ah: number, al: number, bh: number, bl: number): (number, number)
	return band(ah, bh), band(al, bl)
end

function Int64.bor(ah: number, al: number, bh: number, bl: number): (number, number)
	return bor(ah, bh), bor(al, bl)
end

-- logical shift left, 0 <= n < 64
function Int64.shl(h: number, l: number, n: number): (number, number)
	if n == 0 then
		return h, l
	elseif n < 32 then
		return bor(lshift(h, n), rshift(l, 32 - n)), lshift(l, n)
	else
		return lshift(l, n - 32), 0
	end
end

-- logical shift right, 0 <= n < 64
function Int64.shr(h: number, l: number, n: number): (number, number)
	if n == 0 then
		return h, l
	elseif n < 32 then
		return rshift(h, n), bor(rshift(l, n), lshift(h, 32 - n))
	else
		return 0, rshift(h, n - 32)
	end
end

-- arithmetic shift right (sign extending), 0 <= n < 64
function Int64.sar(h: number, l: number, n: number): (number, number)
	if n == 0 then
		return h, l
	elseif n < 32 then
		return arshift(h, n), bor(rshift(l, n), lshift(h, 32 - n))
	else
		local fill = h >= 0x80000000 and 0xFFFFFFFF or 0
		return fill, arshift(h, n - 32)
	end
end

function Int64.rotl(h: number, l: number, n: number): (number, number)
	n %= 64
	if n == 0 then
		return h, l
	end
	if n >= 32 then
		h, l = l, h
		n -= 32
		if n == 0 then
			return h, l
		end
	end
	return bor(lshift(h, n), rshift(l, 32 - n)), bor(lshift(l, n), rshift(h, 32 - n))
end

-- low 32 bits of x * y for uint32 x, y (exact in doubles via a 16 bit split)
local function mul32lo(x: number, y: number): number
	local xh = rshift(x, 16)
	local xl = band(x, 0xFFFF)
	return (((xh * y) % 65536) * 65536 + xl * y) % TWO32
end
Int64.mul32lo = mul32lo

-- (a * b) mod 2^64
function Int64.mul(ah: number, al: number, bh: number, bl: number): (number, number)
	local a0, a1 = band(al, 0xFFFF), rshift(al, 16)
	local b0, b1 = band(bl, 0xFFFF), rshift(bl, 16)
	local p00 = a0 * b0
	local mid = a0 * b1 + a1 * b0
	local lowFull = p00 + (mid % 65536) * 65536
	local low32 = lowFull % TWO32
	local high = a1 * b1 + (mid - mid % 65536) / 65536 + (lowFull - low32) / TWO32
	local h = (high + mul32lo(ah, bl) + mul32lo(al, bh)) % TWO32
	return h, low32
end

-- Converts an integer-valued double (|n| < 2^63, exact only below 2^53) to (hi, lo) two's complement.
function Int64.fromNumber(n: number): (number, number)
	if n >= 0 then
		local lo = n % TWO32
		return ((n - lo) / TWO32) % TWO32, lo
	end
	local m = -n
	local lo = m % TWO32
	return Int64.neg(((m - lo) / TWO32) % TWO32, lo)
end

-- Sign-extends a 32-bit signed integer stored in a double.
function Int64.fromInt32(n: number): (number, number)
	local u = n % TWO32
	return (u >= 0x80000000) and 0xFFFFFFFF or 0, u
end

-- Wraps an integer-valued double into the signed 32-bit range.
function Int64.wrap32(n: number): number
	local u = n % TWO32
	if u >= 0x80000000 then
		u -= TWO32
	end
	return u
end

-- Signed double approximation of (hi, lo) (exact when |value| < 2^53).
function Int64.toNumber(h: number, l: number): number
	if h >= 0x80000000 then
		local nh, nl = Int64.neg(h, l)
		return -(nh * TWO32 + nl)
	end
	return h * TWO32 + l
end

function Int64.toHex(h: number, l: number): string
	return string.format("%08x%08x", h, l)
end

-- Parses a decimal string like "-4172144997902289642" into (hi, lo); returns nil when malformed.
function Int64.parse(s: string): (number?, number?)
	local sign, digits = string.match(s, "^%s*([+-]?)(%d+)%s*$")
	if not digits then
		return nil, nil
	end
	local h, l = 0, 0
	for i = 1, #digits do
		h, l = Int64.mul(h, l, 0, 10)
		h, l = Int64.add(h, l, 0, string.byte(digits, i) - 48)
	end
	if sign == "-" then
		h, l = Int64.neg(h, l)
	end
	return h, l
end

-- Java's String.hashCode() (UTF-16 code units; BMP-only strings are exact, others use UTF-8 bytes).
function Int64.javaStringHash(s: string): number
	local h = 0
	for _, cp in utf8.codes(s) do
		if cp >= 0x10000 then
			cp -= 0x10000
			local hi, lo = 0xD800 + rshift(cp, 10), 0xDC00 + band(cp, 0x3FF)
			h = (mul32lo(h, 31) + hi) % TWO32
			h = (mul32lo(h, 31) + lo) % TWO32
		else
			h = (mul32lo(h, 31) + cp) % TWO32
		end
	end
	return Int64.wrap32(h)
end

return Int64

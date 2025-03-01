module d.gc.bitmap;

import d.gc.util;

import sdc.intrinsics;

struct Bitmap(uint N) {
private:
	enum uint NimbleSize = 8 * ulong.sizeof;
	enum uint NimbleCount = (N + NimbleSize - 1) / NimbleSize;
	enum uint DeadBits = NimbleSize * NimbleCount - N;

	ulong[NimbleCount] bits;

public:
	@property
	ref ulong[NimbleCount] rawContent() const {
		return bits;
	}

	void clear() {
		foreach (i; 0 .. NimbleCount) {
			bits[i] = 0;
		}
	}

	bool valueAt(uint index) const {
		// FIXME: in contracts.
		assert(index < N);

		auto i = index / NimbleSize;
		auto o = index % NimbleSize;
		auto n = bits[i] >> o;

		return (n & 0x01) != 0;
	}

	bool valueAtAtomic(uint index) shared {
		// FIXME: in contracts.
		assert(index < N);

		auto i = index / NimbleSize;
		auto o = index % NimbleSize;
		auto n = bits[i] >> o;

		return (n & 0x01) != 0;
	}

	uint setFirst() {
		// FIXME: in contract
		assert(countBits(0, N) < N, "Bitmap is full!");

		foreach (i; 0 .. NimbleCount) {
			auto n = bits[i] + 1;
			if (n == 0) {
				continue;
			}

			bits[i] |= n;

			uint ret = i * NimbleSize;
			ret += countTrailingZeros(n);

			return ret;
		}

		return -1;
	}

	uint findSet(uint index) const {
		// FIXME: in contracts.
		assert(index < N);

		return findValue!true(index);
	}

	uint findClear(uint index) const {
		// FIXME: in contracts.
		assert(index < N);

		return findValue!false(index);
	}

	uint findValue(bool V)(uint index) const {
		// FIXME: in contracts.
		assert(index < N);

		auto i = index / NimbleSize;
		auto offset = index % NimbleSize;

		auto flip = ulong(V) - 1;
		auto mask = ulong.max << offset;
		auto current = (bits[i++] ^ flip) & mask;

		while (current == 0) {
			if (i >= NimbleCount) {
				return N;
			}

			current = bits[i++] ^ flip;
		}

		uint ret = countTrailingZeros(current);
		ret += (i - 1) * NimbleSize;
		if (DeadBits > 0) {
			ret = max(ret, N);
		}

		return ret;
	}

	int findSetBackward(uint index) const {
		// FIXME: in contracts.
		assert(index < N);

		return findValueBackward!true(index);
	}

	int findClearBackward(uint index) const {
		// FIXME: in contracts.
		assert(index < N);

		return findValueBackward!false(index);
	}

	int findValueBackward(bool V)(uint index) const {
		// FIXME: in contracts.
		assert(index < N);

		int i = index / NimbleSize;
		auto offset = index % NimbleSize;

		// XXX: When offset is zero, mask is 0 and
		// we do a round of computation for nothing.
		auto flip = ulong(V) - 1;
		auto mask = (ulong(1) << offset) - 1;
		auto current = (bits[i--] ^ flip) & mask;

		while (current == 0) {
			if (i < 0) {
				return -1;
			}

			current = bits[i--] ^ flip;
		}

		int clz = countLeadingZeros(current);
		return (i + 2) * NimbleSize - clz - 1;
	}

	bool nextFreeRange(uint start, ref uint index, ref uint length) const {
		// FIXME: in contract.
		assert(start < N);

		auto i = findClear(start);
		if (i >= N) {
			return false;
		}

		auto j = findSet(i);
		index = i;
		length = j - i;
		return true;
	}

	void setBit(uint index) {
		setBitValue!true(index);
	}

	void clearBit(uint index) {
		setBitValue!false(index);
	}

	void setBitValue(bool V)(uint index) {
		// FIXME: in contracts.
		assert(index < N);

		auto i = index / NimbleSize;
		auto o = index % NimbleSize;
		auto b = ulong(1) << o;

		if (V) {
			bits[i] |= b;
		} else {
			bits[i] &= ~b;
		}
	}

	void setBitAtomic(uint index) shared {
		setBitValueAtomic!true(index);
	}

	void clearBitAtomic(uint index) shared {
		setBitValueAtomic!false(index);
	}

	void setBitValueAtomic(bool V)(uint index) shared {
		// FIXME: in contracts.
		assert(index < N);

		auto i = index / NimbleSize;
		auto o = index % NimbleSize;
		auto b = ulong(1) << o;

		import sdc.intrinsics;
		if (V) {
			fetchOr(&bits[i], b);
		} else {
			fetchAnd(&bits[i], ~b);
		}
	}

	void setRange(uint index, uint length) {
		setRangeValue!(true, false)(index, length);
	}

	void setRollingRange(uint index, uint length) {
		setRangeValue!(true, true)(index, length);
	}

	void clearRange(uint index, uint length) {
		setRangeValue!(false, false)(index, length);
	}

	void clearRollingRange(uint index, uint length) {
		setRangeValue!(false, true)(index, length);
	}

	void setRangeValue(bool Value, bool IsRolling)(uint index, uint length) {
		// FIXME: in contracts.
		assert(index < N);
		assert(length > 0 && length <= N);
		assert(IsRolling || index + length <= N);

		static setBits(ref ulong n, ulong mask) {
			if (Value) {
				n |= mask;
			} else {
				n &= ~mask;
			}
		}

		auto i = index / NimbleSize;
		auto offset = index % NimbleSize;

		if (length <= NimbleSize - offset) {
			// The whole range fits within one nimble.
			auto shift = NimbleSize - length;
			auto mask = (ulong.max >> shift) << offset;
			setBits(bits[i], mask);
			return;
		}

		static next(ref uint i) {
			i++;

			if (IsRolling) {
				i %= NimbleCount;
			}
		}

		setBits(bits[i], ulong.max << offset);
		next(i);
		length += offset;
		length -= NimbleSize;

		while (length > NimbleSize) {
			setBits(bits[i], ulong.max);
			next(i);
			length -= NimbleSize;
		}

		assert(1 <= length && length <= NimbleSize);
		auto shift = NimbleSize - length;
		setBits(bits[i], ulong.max >> shift);
	}

	void setRangeFrom(const ref Bitmap source, uint index, uint length) {
		setRangeFromImpl!false(source, index, length);
	}

	void setRollingRangeFrom(const ref Bitmap source, uint index, uint length) {
		setRangeFromImpl!true(source, index, length);
	}

	void setRangeFromImpl(bool IsRolling)(const ref Bitmap source, uint index,
	                                      uint length) {
		// FIXME: in contracts.
		assert(index < N);
		assert(length > 0 && length <= N);
		assert(IsRolling || index + length <= N);

		static setBits(ref ulong n, ulong value, ulong mask) {
			n &= ~mask;
			n |= value & mask;
		}

		auto i = index / NimbleSize;
		auto offset = index % NimbleSize;

		if (length <= NimbleSize - offset) {
			// The whole copy fits within one nimble.
			auto shift = NimbleSize - length;
			auto mask = (ulong.max >> shift) << offset;
			setBits(bits[i], source.bits[i], mask);
			return;
		}

		static next(ref uint i) {
			i++;

			if (IsRolling) {
				i %= NimbleCount;
			}
		}

		setBits(bits[i], source.bits[i], ulong.max << offset);
		next(i);
		length += offset;
		length -= NimbleSize;

		while (length > NimbleSize) {
			setBits(bits[i], source.bits[i], ulong.max);
			next(i);
			length -= NimbleSize;
		}

		assert(1 <= length && length <= NimbleSize);
		auto shift = NimbleSize - length;
		setBits(bits[i], source.bits[i], ulong.max >> shift);
	}

	uint countBits(uint index, uint length) const {
		return countBitsImpl!false(index, length);
	}

	uint rollingCountBits(uint index, uint length) const {
		return countBitsImpl!true(index, length);
	}

	uint countBitsImpl(bool IsRolling)(uint index, uint length) const {
		// FIXME: in contracts.
		assert(index < N);
		assert(length <= N);
		assert(IsRolling || index + length <= N);

		if (length == 0) {
			return 0;
		}

		auto i = index / NimbleSize;
		auto offset = index % NimbleSize;

		if (length <= NimbleSize - offset) {
			// The whole count fits within one nimble.
			auto shift = NimbleSize - length;
			auto mask = (ulong.max >> shift) << offset;
			return popCount(bits[i] & mask);
		}

		static next(ref uint i) {
			i++;

			if (IsRolling) {
				i %= NimbleCount;
			}
		}

		auto mask = ulong.max << offset;
		uint count = popCount(bits[i] & mask);

		next(i);
		length += offset;
		length -= NimbleSize;

		while (length > NimbleSize) {
			count += popCount(bits[i]);
			next(i);
			length -= NimbleSize;
		}

		assert(1 <= length && length <= NimbleSize);
		auto shift = NimbleSize - length;
		mask = ulong.max >> shift;
		count += popCount(bits[i] & mask);

		return count;
	}
}

unittest valueAt {
	Bitmap!256 bmp;
	bmp.bits = [~0x80, ~0x80, ~0x80, ~0x80];

	foreach (i; 0 .. 7) {
		assert(bmp.valueAt(i));
	}

	assert(!bmp.valueAt(7));

	foreach (i; 8 .. 71) {
		assert(bmp.valueAt(i));
	}

	assert(!bmp.valueAt(71));

	foreach (i; 72 .. 135) {
		assert(bmp.valueAt(i));
	}

	assert(!bmp.valueAt(135));

	foreach (i; 136 .. 199) {
		assert(bmp.valueAt(i));
	}

	assert(!bmp.valueAt(199));

	foreach (i; 200 .. 256) {
		assert(bmp.valueAt(i));
	}
}

//// Breaks on account of apparent compiler bug:
// unittest valueAtAtomic {
// 	static shared Bitmap!256 atomicBmp;
// 	atomicBmp.bits = [~0x80, ~0x80, ~0x80, ~0x80];

// 	foreach (i; 0 .. 7) {
// 		assert(atomicBmp.valueAtAtomic(i));
// 	}

// 	assert(!atomicBmp.valueAtAtomic(7));

// 	foreach (i; 8 .. 71) {
// 		assert(atomicBmp.valueAtAtomic(i));
// 	}

// 	assert(!atomicBmp.valueAtAtomic(71));

// 	foreach (i; 72 .. 135) {
// 		assert(atomicBmp.valueAtAtomic(i));
// 	}

// 	assert(!atomicBmp.valueAtAtomic(135));

// 	foreach (i; 136 .. 199) {
// 		assert(atomicBmp.valueAtAtomic(i));
// 	}

// 	assert(!atomicBmp.valueAtAtomic(199));

// 	foreach (i; 200 .. 256) {
// 		assert(atomicBmp.valueAtAtomic(i));
// 	}
// }

unittest setFirst {
	Bitmap!256 bmp;
	bmp.bits = [~0x80, ~0x80, ~0x80, ~0x80];

	void checkBitmap(ulong a, ulong b, ulong c, ulong d) {
		assert(bmp.bits[0] == a);
		assert(bmp.bits[1] == b);
		assert(bmp.bits[2] == c);
		assert(bmp.bits[3] == d);
	}

	checkBitmap(~0x80, ~0x80, ~0x80, ~0x80);

	bmp.setFirst();
	checkBitmap(~0, ~0x80, ~0x80, ~0x80);

	bmp.setFirst();
	checkBitmap(~0, ~0, ~0x80, ~0x80);

	bmp.setFirst();
	checkBitmap(~0, ~0, ~0, ~0x80);

	bmp.setFirst();
	checkBitmap(~0, ~0, ~0, ~0);
}

unittest findValue {
	Bitmap!256 bmp1, bmp2;
	bmp1.bits = [0x80, 0x80, 0x80, 0x80];
	bmp2.bits = [~0x80, ~0x80, ~0x80, ~0x80];

	foreach (i; 0 .. 8) {
		assert(bmp1.findSet(i) == 7);
		assert(bmp2.findClear(i) == 7);
		assert(bmp1.findSetBackward(i) == -1);
		assert(bmp2.findClearBackward(i) == -1);
	}

	foreach (i; 8 .. 72) {
		assert(bmp1.findSet(i) == 71);
		assert(bmp2.findClear(i) == 71);
		assert(bmp1.findSetBackward(i) == 7);
		assert(bmp2.findClearBackward(i) == 7);
	}

	foreach (i; 72 .. 136) {
		assert(bmp1.findSet(i) == 135);
		assert(bmp2.findClear(i) == 135);
		assert(bmp1.findSetBackward(i) == 71);
		assert(bmp2.findClearBackward(i) == 71);
	}

	foreach (i; 136 .. 200) {
		assert(bmp1.findSet(i) == 199);
		assert(bmp2.findClear(i) == 199);
		assert(bmp1.findSetBackward(i) == 135);
		assert(bmp2.findClearBackward(i) == 135);
	}

	foreach (i; 200 .. 256) {
		assert(bmp1.findSet(i) == 256);
		assert(bmp2.findClear(i) == 256);
		assert(bmp1.findSetBackward(i) == 199);
		assert(bmp2.findClearBackward(i) == 199);
	}
}

unittest nextFreeRange {
	Bitmap!256 bmp;
	bmp.bits = [0x0fffffffffffffc7, 0x00ffffffffffffc0, 0x00000003ffc00000,
	            0xff00000000000000];

	uint index;
	uint length;

	assert(bmp.nextFreeRange(0, index, length));
	assert(index == 3);
	assert(length == 3);

	assert(bmp.nextFreeRange(index + length, index, length));
	assert(index == 60);
	assert(length == 10);

	assert(bmp.nextFreeRange(index + length, index, length));
	assert(index == 120);
	assert(length == 30);

	assert(bmp.nextFreeRange(index + length, index, length));
	assert(index == 162);
	assert(length == 86);

	// The last one return false because
	// there is no remaining free range.
	assert(!bmp.nextFreeRange(index + length, index, length));
}

unittest setBit {
	Bitmap!256 bmp;

	void checkBitmap(ulong a, ulong b, ulong c, ulong d) {
		assert(bmp.bits[0] == a);
		assert(bmp.bits[1] == b);
		assert(bmp.bits[2] == c);
		assert(bmp.bits[3] == d);
	}

	checkBitmap(0, 0, 0, 0);

	bmp.setBit(0);
	checkBitmap(1, 0, 0, 0);

	// Dobule set does nothing.
	bmp.setBit(0);
	checkBitmap(1, 0, 0, 0);

	bmp.setBit(3);
	checkBitmap(9, 0, 0, 0);

	bmp.setBit(42);
	checkBitmap(0x0000040000000009, 0, 0, 0);

	bmp.setBit(63);
	checkBitmap(0x8000040000000009, 0, 0, 0);

	bmp.clearBit(0);
	checkBitmap(0x8000040000000008, 0, 0, 0);

	// Double clear does nothing.
	bmp.clearBit(0);
	checkBitmap(0x8000040000000008, 0, 0, 0);

	bmp.setBit(64);
	checkBitmap(0x8000040000000008, 1, 0, 0);

	bmp.setBit(255);
	checkBitmap(0x8000040000000008, 1, 0, 0x8000000000000000);
}

//// Breaks on account of apparent compiler bug:
// unittest setBitAtomic {
// 	static shared Bitmap!256 atomicBmp;

// 	void checkBitmap(ulong a, ulong b, ulong c, ulong d) {
// 		assert(atomicBmp.bits[0] == a);
// 		assert(atomicBmp.bits[1] == b);
// 		assert(atomicBmp.bits[2] == c);
// 		assert(atomicBmp.bits[3] == d);
// 	}

// 	checkBitmap(0, 0, 0, 0);

// 	atomicBmp.setBitAtomic(0);
// 	checkBitmap(1, 0, 0, 0);

// 	// Dobule set does nothing.
// 	atomicBmp.setBitAtomic(0);
// 	checkBitmap(1, 0, 0, 0);

// 	atomicBmp.setBitAtomic(3);
// 	checkBitmap(9, 0, 0, 0);

// 	atomicBmp.setBitAtomic(42);
// 	checkBitmap(0x0000040000000009, 0, 0, 0);

// 	atomicBmp.setBitAtomic(63);
// 	checkBitmap(0x8000040000000009, 0, 0, 0);

// 	atomicBmp.clearBitAtomic(0);
// 	checkBitmap(0x8000040000000008, 0, 0, 0);

// 	// Double clear does nothing.
// 	atomicBmp.clearBitAtomic(0);
// 	checkBitmap(0x8000040000000008, 0, 0, 0);

// 	atomicBmp.setBitAtomic(64);
// 	checkBitmap(0x8000040000000008, 1, 0, 0);

// 	atomicBmp.setBitAtomic(255);
// 	checkBitmap(0x8000040000000008, 1, 0, 0x8000000000000000);
// }

unittest setRange {
	Bitmap!256 bmp;

	void checkBitmap(ulong a, ulong b, ulong c, ulong d) {
		assert(bmp.bits[0] == a);
		assert(bmp.bits[1] == b);
		assert(bmp.bits[2] == c);
		assert(bmp.bits[3] == d);
	}

	checkBitmap(0, 0, 0, 0);

	bmp.setRange(3, 3);
	checkBitmap(0x38, 0, 0, 0);

	bmp.setRange(60, 10);
	checkBitmap(0xf000000000000038, 0x3f, 0, 0);

	bmp.setRange(120, 128);
	checkBitmap(0xf000000000000038, 0xff0000000000003f, 0xffffffffffffffff,
	            0x00ffffffffffffff);

	bmp.clearRange(150, 12);
	checkBitmap(0xf000000000000038, 0xff0000000000003f, 0xfffffffc003fffff,
	            0x00ffffffffffffff);

	bmp.setRange(0, 256);
	checkBitmap(~0, ~0, ~0, ~0);

	bmp.clearRange(3, 3);
	checkBitmap(~0x38, ~0, ~0, ~0);

	bmp.clearRange(60, 10);
	checkBitmap(0x0fffffffffffffc7, ~0x3f, ~0, ~0);

	bmp.clearRange(120, 128);
	checkBitmap(0x0fffffffffffffc7, 0x00ffffffffffffc0, 0, 0xff00000000000000);

	bmp.setRange(150, 12);
	checkBitmap(0x0fffffffffffffc7, 0x00ffffffffffffc0, 0x00000003ffc00000,
	            0xff00000000000000);

	bmp.clearRange(0, 256);
	checkBitmap(0, 0, 0, 0);
}

unittest setRollingRange {
	Bitmap!256 bmp;

	void checkBitmap(ulong a, ulong b, ulong c, ulong d) {
		assert(bmp.bits[0] == a);
		assert(bmp.bits[1] == b);
		assert(bmp.bits[2] == c);
		assert(bmp.bits[3] == d);
	}

	checkBitmap(0, 0, 0, 0);

	bmp.setRollingRange(3, 3);
	checkBitmap(0x38, 0, 0, 0);

	bmp.setRollingRange(60, 10);
	checkBitmap(0xf000000000000038, 0x3f, 0, 0);

	bmp.setRollingRange(150, 128);
	checkBitmap(0xf0000000003fffff, 0x3f, 0xffffffffffc00000,
	            0xffffffffffffffff);

	bmp.clearRollingRange(200, 70);
	checkBitmap(0xf0000000003fc000, 0x3f, 0xffffffffffc00000,
	            0x00000000000000ff);

	bmp.setRollingRange(123, 256);
	checkBitmap(~0, ~0, ~0, ~0);

	bmp.clearRollingRange(3, 3);
	checkBitmap(~0x38, ~0, ~0, ~0);

	bmp.clearRollingRange(60, 10);
	checkBitmap(0x0fffffffffffffc7, ~0x3f, ~0, ~0);

	bmp.clearRollingRange(150, 128);
	checkBitmap(0x0fffffffffc00000, 0xffffffffffffffc0, 0x00000000003fffff, 0);

	bmp.setRollingRange(200, 70);
	checkBitmap(0x0fffffffffc03fff, 0xffffffffffffffc0, 0x00000000003fffff,
	            0xffffffffffffff00);

	bmp.clearRollingRange(13, 256);
	checkBitmap(0, 0, 0, 0);
}

unittest setRangeFrom {
	Bitmap!256 bmpA;
	Bitmap!256 bmpB;

	bmpB.bits = [0xbadc0ffee0ddf00d, 0xbad0ddf00dc0ffee, ulong.max, ulong.max];

	void checkBitmap(ref const Bitmap!256 bmp, ulong a, ulong b, ulong c,
	                 ulong d) {
		assert(bmp.bits[0] == a);
		assert(bmp.bits[1] == b);
		assert(bmp.bits[2] == c);
		assert(bmp.bits[3] == d);
	}

	checkBitmap(bmpA, 0, 0, 0, 0);
	checkBitmap(bmpB, 0xbadc0ffee0ddf00d, 0xbad0ddf00dc0ffee, ulong.max,
	            ulong.max);

	bmpA.setRangeFrom(bmpB, 0, 1);
	checkBitmap(bmpA, 1, 0, 0, 0);
	checkBitmap(bmpB, 0xbadc0ffee0ddf00d, 0xbad0ddf00dc0ffee, ulong.max,
	            ulong.max);

	bmpA.setRangeFrom(bmpB, 56, 8);
	checkBitmap(bmpA, 0xba00000000000001, 0, 0, 0);
	checkBitmap(bmpB, 0xbadc0ffee0ddf00d, 0xbad0ddf00dc0ffee, ulong.max,
	            ulong.max);

	bmpA.setRangeFrom(bmpB, 52, 4);
	checkBitmap(bmpA, 0xbad0000000000001, 0, 0, 0);
	checkBitmap(bmpB, 0xbadc0ffee0ddf00d, 0xbad0ddf00dc0ffee, ulong.max,
	            ulong.max);

	bmpA.setRangeFrom(bmpB, 0, 64);
	checkBitmap(bmpA, 0xbadc0ffee0ddf00d, 0, 0, 0);
	checkBitmap(bmpB, 0xbadc0ffee0ddf00d, 0xbad0ddf00dc0ffee, ulong.max,
	            ulong.max);

	bmpA.setRangeFrom(bmpB, 224, 32);
	checkBitmap(bmpA, 0xbadc0ffee0ddf00d, 0, 0, 0xffffffff00000000);
	checkBitmap(bmpB, 0xbadc0ffee0ddf00d, 0xbad0ddf00dc0ffee, ulong.max,
	            ulong.max);

	bmpA.setRangeFrom(bmpB, 192, 64);
	checkBitmap(bmpA, 0xbadc0ffee0ddf00d, 0, 0, ulong.max);
	checkBitmap(bmpB, 0xbadc0ffee0ddf00d, 0xbad0ddf00dc0ffee, ulong.max,
	            ulong.max);

	bmpA.setRangeFrom(bmpB, 116, 30);
	checkBitmap(bmpA, 0xbadc0ffee0ddf00d, 0xbad0000000000000, 0x3ffff,
	            ulong.max);
	checkBitmap(bmpB, 0xbadc0ffee0ddf00d, 0xbad0ddf00dc0ffee, ulong.max,
	            ulong.max);

	bmpA.setRangeFrom(bmpB, 64, 128);
	checkBitmap(bmpA, 0xbadc0ffee0ddf00d, 0xbad0ddf00dc0ffee, ulong.max,
	            ulong.max);
	checkBitmap(bmpB, 0xbadc0ffee0ddf00d, 0xbad0ddf00dc0ffee, ulong.max,
	            ulong.max);

	bmpA.bits = [0, 0, 0, 0];
	checkBitmap(bmpA, 0, 0, 0, 0);

	bmpA.setRangeFrom(bmpB, 16, 224);
	checkBitmap(bmpA, 0xbadc0ffee0dd0000, 0xbad0ddf00dc0ffee, ulong.max,
	            0x0000ffffffffffff);
	checkBitmap(bmpB, 0xbadc0ffee0ddf00d, 0xbad0ddf00dc0ffee, ulong.max,
	            ulong.max);

	bmpA.setRangeFrom(bmpB, 0, 256);
	checkBitmap(bmpA, 0xbadc0ffee0ddf00d, 0xbad0ddf00dc0ffee, ulong.max,
	            ulong.max);
	checkBitmap(bmpB, 0xbadc0ffee0ddf00d, 0xbad0ddf00dc0ffee, ulong.max,
	            ulong.max);
}

unittest setRollingRangeFrom {
	Bitmap!256 bmpA;
	Bitmap!256 bmpB;

	bmpB.bits = [0xbadc0ffee0ddf00d, 0xbad0ddf00dc0ffee, ulong.max, ulong.max];

	void checkBitmap(ref const Bitmap!256 bmp, ulong a, ulong b, ulong c,
	                 ulong d) {
		assert(bmp.bits[0] == a);
		assert(bmp.bits[1] == b);
		assert(bmp.bits[2] == c);
		assert(bmp.bits[3] == d);
	}

	checkBitmap(bmpA, 0, 0, 0, 0);
	checkBitmap(bmpB, 0xbadc0ffee0ddf00d, 0xbad0ddf00dc0ffee, ulong.max,
	            ulong.max);

	bmpA.setRollingRangeFrom(bmpB, 0, 1);
	checkBitmap(bmpA, 1, 0, 0, 0);
	checkBitmap(bmpB, 0xbadc0ffee0ddf00d, 0xbad0ddf00dc0ffee, ulong.max,
	            ulong.max);

	bmpA.setRollingRangeFrom(bmpB, 245, 53);
	checkBitmap(bmpA, 0x000003fee0ddf00d, 0, 0, 0xffe0000000000000);
	checkBitmap(bmpB, 0xbadc0ffee0ddf00d, 0xbad0ddf00dc0ffee, ulong.max,
	            ulong.max);

	bmpA.setRollingRangeFrom(bmpB, 72, 256);
	checkBitmap(bmpA, 0xbadc0ffee0ddf00d, 0xbad0ddf00dc0ffee, ulong.max,
	            ulong.max);
	checkBitmap(bmpB, 0xbadc0ffee0ddf00d, 0xbad0ddf00dc0ffee, ulong.max,
	            ulong.max);

	bmpA.bits = [0, 0, 0, 0];
	checkBitmap(bmpA, 0, 0, 0, 0);

	bmpA.setRollingRangeFrom(bmpB, 176, 224);
	checkBitmap(bmpA, 0xbadc0ffee0ddf00d, 0xbad0ddf00dc0ffee,
	            0xffff00000000ffff, ulong.max);
	checkBitmap(bmpB, 0xbadc0ffee0ddf00d, 0xbad0ddf00dc0ffee, ulong.max,
	            ulong.max);

	bmpA.setRollingRangeFrom(bmpB, 182, 256);
	checkBitmap(bmpA, 0xbadc0ffee0ddf00d, 0xbad0ddf00dc0ffee, ulong.max,
	            ulong.max);
	checkBitmap(bmpB, 0xbadc0ffee0ddf00d, 0xbad0ddf00dc0ffee, ulong.max,
	            ulong.max);
}

unittest countBits {
	Bitmap!256 bmp;
	foreach (i; 0 .. 128) {
		assert(bmp.countBits(i, 0) == 0);
		assert(bmp.countBits(i, 19) == 0);
		assert(bmp.countBits(i, 48) == 0);
		assert(bmp.countBits(i, 64) == 0);
		assert(bmp.countBits(i, 99) == 0);
		assert(bmp.countBits(i, 128) == 0);
	}

	bmp.bits = [-1, -1, -1, -1];
	foreach (i; 0 .. 128) {
		assert(bmp.countBits(i, 0) == 0);
		assert(bmp.countBits(i, 19) == 19);
		assert(bmp.countBits(i, 48) == 48);
		assert(bmp.countBits(i, 64) == 64);
		assert(bmp.countBits(i, 99) == 99);
		assert(bmp.countBits(i, 128) == 128);
	}

	bmp.bits = [0xaaaaaaaaaaaaaaaa, 0xaaaaaaaaaaaaaaaa, 0xaaaaaaaaaaaaaaaa,
	            0xaaaaaaaaaaaaaaaa];
	foreach (i; 0 .. 128) {
		assert(bmp.countBits(i, 0) == 0);
		assert(bmp.countBits(i, 19) == 9 + (i % 2));
		assert(bmp.countBits(i, 48) == 24);
		assert(bmp.countBits(i, 64) == 32);
		assert(bmp.countBits(i, 99) == 49 + (i % 2));
		assert(bmp.countBits(i, 128) == 64);
	}
}

unittest rollingCountBits {
	Bitmap!256 bmp;
	foreach (i; 0 .. 256) {
		assert(bmp.rollingCountBits(i, 0) == 0);
		assert(bmp.rollingCountBits(i, 19) == 0);
		assert(bmp.rollingCountBits(i, 48) == 0);
		assert(bmp.rollingCountBits(i, 64) == 0);
		assert(bmp.rollingCountBits(i, 99) == 0);
		assert(bmp.rollingCountBits(i, 128) == 0);
		assert(bmp.rollingCountBits(i, 137) == 0);
		assert(bmp.rollingCountBits(i, 192) == 0);
		assert(bmp.rollingCountBits(i, 255) == 0);
		assert(bmp.rollingCountBits(i, 256) == 0);
	}

	bmp.bits = [-1, -1, -1, -1];
	foreach (i; 0 .. 256) {
		assert(bmp.rollingCountBits(i, 0) == 0);
		assert(bmp.rollingCountBits(i, 19) == 19);
		assert(bmp.rollingCountBits(i, 48) == 48);
		assert(bmp.rollingCountBits(i, 64) == 64);
		assert(bmp.rollingCountBits(i, 99) == 99);
		assert(bmp.rollingCountBits(i, 128) == 128);
		assert(bmp.rollingCountBits(i, 137) == 137);
		assert(bmp.rollingCountBits(i, 192) == 192);
		assert(bmp.rollingCountBits(i, 255) == 255);
		assert(bmp.rollingCountBits(i, 256) == 256);
	}

	bmp.bits = [0xaaaaaaaaaaaaaaaa, 0xaaaaaaaaaaaaaaaa, 0xaaaaaaaaaaaaaaaa,
	            0xaaaaaaaaaaaaaaaa];
	foreach (i; 0 .. 256) {
		assert(bmp.rollingCountBits(i, 0) == 0);
		assert(bmp.rollingCountBits(i, 19) == 9 + (i % 2));
		assert(bmp.rollingCountBits(i, 48) == 24);
		assert(bmp.rollingCountBits(i, 64) == 32);
		assert(bmp.rollingCountBits(i, 99) == 49 + (i % 2));
		assert(bmp.rollingCountBits(i, 128) == 64);
		assert(bmp.rollingCountBits(i, 137) == 68 + (i % 2));
		assert(bmp.rollingCountBits(i, 192) == 96);
		assert(bmp.rollingCountBits(i, 255) == 127 + (i % 2));
		assert(bmp.rollingCountBits(i, 256) == 128);
	}
}

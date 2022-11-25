module config.map;

import config.traits;
import config.value;

/**
 * Some hash manipulation utilities.
 *
 * The hash generated by hashOf do not have good
 * collision resistance over subset of the bits
 * of the hash value, which causes clumping.
 *
 * In order to fix this, we mix the bits around
 * to ensure good entropy over the range we are
 * interested in.
 *
 * NB: On architecture that provide hardware support
 * for CRC32 (ARMv8.1+, x86), we might want to use that.
 */
hash_t rehash(hash_t h) {
	// Make sure the bits are well distributed.
	enum K = 0xc4ceb9fe1a85ec53;
	/*
	// I have not figured out how to do this in a sensible way.
	// See: https://forum.dlang.org/post/zsaghidvbsdwqthadphx@forum.dlang.org
	auto hi = mulhi(h, k);
	/*/
	auto hi = h >> 28;
	// */
	auto lo = h * K;
	h = hi ^ lo;
	return h * K;
}

ubyte HTag(hash_t h) {
	return (h >> 15) & 0x7f;
}

uint HIndex(hash_t h) {
	return (h >> 22) & uint.max;
}

uint HStep(hash_t h) {
	return ((h >> 15) | 0x01) & uint.max;
}

struct Probe {
	uint index;
	uint step;
	uint mask;

	this(hash_t h, uint bucketCount) in(isPow2(bucketCount)) {
		mask = bucketCount - 1;
		index = HIndex(h) & mask;
		step = HStep(h);
	}

	uint current() const {
		return index & mask;
	}

	uint next() {
		index += step;
		return current;
	}
}

/**
 * NB: Using a size of 12 would make this struct
 * the size of one cache line. There is probably
 * a win here in some circumstances, but that seem
 * unlikely that it does in this context. The prefix
 * prevents this to be aligned on cache lines anyways.
 */
struct Bucket {
private:
	ubyte[14] tags;

	ubyte control;
	ubyte overflow;

	uint[14] indices;

	enum EmptyTag = 0x80;

	@property
	ulong[2] tagBytes() const {
		return [*(cast(ulong*) &tags[0]), *(cast(ulong*) &tags[7])];
	}

	void clear() {
		tags[] = EmptyTag;
		control = 0;
		overflow = 0;
	}

public:
	struct Range {
	private:
		uint bits;

		static fromBits(ulong t0, ulong t1) {
			enum Dispatch = 0x0002040810204080;
			uint r0 = (t0 * Dispatch) >> 56;
			uint r1 = (t1 * Dispatch) >> 56;

			return Range(r0 | (r1 << 7));
		}

	public:
		@property
		bool empty() const {
			return bits == 0;
		}

		@property
		uint front() const in(!empty) {
			import core.bitop;
			return bsf(bits);
		}

		void popFront() {
			// Clear the lowest bit.
			bits &= (bits - 1);
		}
	}

	auto match(hash_t h) const {
		enum LSBs = 0x0001010101010101;
		auto v = HTag(h) * LSBs;
		auto t0 = tagBytes[0] ^ v;
		auto t1 = tagBytes[1] ^ v;

		/**
		 * This leverage SWAR to check for 0s in t0 and t1.
		 *
		 * /!\ This has false positive due to overflow, but:
		 *   - All real match are detected.
		 *   - They never occurs on empty slot (tag = 0x80)
		 *   - They will be cleared when checking for key equality.
		 *   - because they are always preceded by a real match,
		 *     we will unfrequently have to check them anyway.
		 *
		 * Abseil provides us with an exemple:
		 *   t0 = 0x1716151413121110
		 *   HTag(h) = 0x12
		 *     => m0 = 0x0000000080800000
		 *
		 * Here, the 3rd and 4th slots match, but only the 3rd
		 * is a real match, the 4th is a false positive.
		 */
		enum MSBs = 0x0080808080808080;
		auto m0 = (t0 - LSBs) & ~t0 & MSBs;
		auto m1 = (t1 - LSBs) & ~t1 & MSBs;

		return Range.fromBits(m0, m1);
	}

	auto emptySlots() const {
		enum MSBs = 0x0080808080808080;
		return Range.fromBits(tagBytes[0] & MSBs, tagBytes[1] & MSBs);
	}

	bool insert(hash_t h, uint index) {
		auto e = emptySlots;

		// There are no empty slot left.
		if (e.empty) {
			auto no = overflow + 2;
			overflow = (no | no >> 8) & 0xff;
			return false;
		}

		// Pick the first slot and roll with it.
		auto i = e.front;
		tags[i] = HTag(h);
		indices[i] = index;

		return true;
	}
}

unittest {
	static matchEmpty(const ref Bucket b, uint start = 0, uint stop = 14) {
		auto es = b.emptySlots();
		foreach (i; start .. stop) {
			assert(!es.empty);
			assert(es.front == i);
			es.popFront();
		}

		assert(es.empty);
	}

	Bucket b;
	b.clear();

	matchEmpty(b);

	auto match0 = b.match(0);
	assert(match0.empty);

	// After inserting one element,
	// it takes the first slot.
	assert(b.insert(rehash(0x42), 123));

	matchEmpty(b, 1);

	match0 = b.match(0);
	assert(match0.empty);

	auto match42 = b.match(rehash(0x42));
	assert(!match42.empty);
	assert(match42.front == 0);
	assert(b.indices[0] == 123);
	match42.popFront();
	assert(match42.empty);

	// Insert a second element which collides.
	assert(b.insert(rehash(0x42), 456));

	matchEmpty(b, 2);

	match0 = b.match(0);
	assert(match0.empty);

	match42 = b.match(rehash(0x42));
	assert(!match42.empty);
	assert(match42.front == 0);
	assert(b.indices[0] == 123);
	match42.popFront();
	assert(match42.front == 1);
	assert(b.indices[1] == 456);
	match42.popFront();
	assert(match42.empty);

	// Fill the bucket.
	foreach (i; 0 .. 12) {
		assert(b.insert(rehash(0xaa), i));
	}

	assert(b.emptySlots().empty);
	assert(!b.insert(0, 789));
	assert(b.overflow == 2);
}

struct Entry {
	String key;
	Value value;

	string toString() const {
		import std.format;
		return format!"%s: %s"(key.dump(), value);
	}
}

bool isPow2(uint i) {
	return (i & (i - 1)) == 0;
}

struct Object {
private:
	struct ObjectImpl {
		Descriptor tag;
		uint lgBucketCount;
	}

	ObjectImpl* impl;
	alias impl this;

	this(ulong payload) inout {
		this(cast(inout ObjectImpl*) payload);
	}

	this(inout ObjectImpl* impl) inout {
		this.impl = impl;
	}

package:

	ulong toPayload() const {
		return cast(ulong) impl;
	}

public:
	this(O)(O o) if (isObjectValue!O) in(o.length <= int.max) {
		import core.memory;
		impl = allocateWithLength(o.length & uint.max);

		foreach (ref b; buckets) {
			b.clear();
		}

		uint i = 0;
		foreach (ref k, ref v; o) {
			entries[i].key = String(k);
			entries[i].value = Value(v);
			_insert(k, i++);
		}
	}

	@property
	uint bucketCount() const {
		return 1 << lgBucketCount;
	}

	@property
	uint capacity() const {
		return 12 << lgBucketCount;
	}

	string toString() const {
		import std.conv;
		return to!string(entries);
	}

	uint find(string key) inout {
		auto h = rehash(hashOf(key));
		auto p = Probe(h, bucketCount);
		auto i = p.current;

		foreach (_; 0 .. bucketCount) {
			scope(success) {
				i = p.next();
			}

			auto r = buckets[i].match(h);
			foreach (n; r) {
				auto index = buckets[i].indices[n];

				if (entries[index].key.toString() == key) {
					return index;
				}
			}

			if (buckets[i].overflow == 0) {
				break;
			}
		}

		// Return a sentinel to indicate absence.
		return -1;
	}

	inout(Value) opIndex(uint index) inout {
		if (index >= capacity) {
			// Return `Undefined` to signal we didn't find anything.
			return Value();
		}

		return entries[index].value;
	}

	inout(Value) opIndex(string key) inout {
		return this[find(key)];
	}

	inout(Value)* opBinaryRight(string op : "in")(string key) inout {
		auto index = find(key);
		if (index >= capacity) {
			// If it not in the map, then return null.
			return null;
		}

		return &entries[index].value;
	}

private:
	static allocateWithLength(uint length) {
		// We can do that much better with intrinsics,
		// but I don't think we have them :/
		static pow2Ceil(uint x) {
			x |= x >> 1;
			x |= x >> 2;
			x |= x >> 4;
			x |= x >> 8;
			x |= x >> 16;
			return x + 1;
		}

		auto lg2Floor(uint x) in(x > 0) {
			import core.bitop;
			return bsr(x);
		}

		uint lgC = (length > 0) ? lg2Floor(pow2Ceil((length - 1) / 12)) : 0;

		import core.memory;
		auto ptr = cast(ObjectImpl*) GC.malloc(
			ObjectImpl.sizeof
				+ ((Bucket.sizeof + 2 * 14 * Value.sizeof) << lgC),
			GC.BlkAttr.NO_SCAN | GC.BlkAttr.APPENDABLE
		);

		ptr.tag.kind = Kind.Object;
		ptr.tag.length = length;
		ptr.lgBucketCount = lgC;

		return ptr;
	}

	@property
	inout(Bucket)[] buckets() inout {
		auto ptr = cast(inout Bucket*) (impl + 1);
		return ptr[0 .. bucketCount];
	}

	@property
	inout(Entry)[] entries() inout {
		auto ptr = cast(inout Entry*) (buckets.ptr + bucketCount);
		return ptr[0 .. tag.length];
	}

	void _insert(string key, uint index) {
		auto h = rehash(hashOf(key));
		auto p = Probe(h, bucketCount);
		auto i = p.current;

		while (!buckets[i].insert(h, index)) {
			i = p.next();
		}
	}
}

unittest {
	static testObject(O : E[string], E)(O content) {
		auto o = Object(content);

		assert(o.tag.length == content.length);
		assert(o.capacity >= content.length);

		foreach (k, v; content) {
			assert(o[k] == v, k);

			assert(k in o);
			assert(*(k in o) == v);
		}

		assert(("not in the map" in o) == null);
		assert(o["not in the map"].isUndefined());
	}

	Value[string] o;
	testObject(o);

	testObject(["foo" : "bar"]);
	testObject(["foo" : "bar", "fizz" : "buzz"]);

	uint[string] numbers =
		["zero" : 0, "one" : 1, "two" : 2, "three" : 3, "four" : 4, "five" : 5,
		 "six" : 6, "seven" : 7, "eight" : 8, "nine" : 9, ];
	testObject(numbers);

	numbers["ten"] = 10;
	testObject(numbers);
	numbers["eleven"] = 11;
	testObject(numbers);
	numbers["twelve"] = 12;
	testObject(numbers);
	numbers["thriteen"] = 13;
	testObject(numbers);
	numbers["fourteen"] = 14;
	testObject(numbers);
}

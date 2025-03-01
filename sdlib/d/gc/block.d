module d.gc.block;

import d.gc.allocclass;
import d.gc.base;
import d.gc.heap;
import d.gc.ring;
import d.gc.spec;
import d.gc.util;

alias PHNode = heap.Node!BlockDescriptor;
alias RNode = ring.Node!BlockDescriptor;

/**
 * Each BlockDescriptor manages a 2MB system's huge page.
 *
 * In order to reduce TLB pressure, we try to layout the memory in
 * such a way that the OS can back it with huge pages. We organise
 * the memory in blocks that correspond to a huge page, and allocate
 * in blocks that are unlikely to empty themselves any time soon.
 */
struct BlockDescriptor {
private:
	/**
	 * This is a bitfield containing the following elements:
	 *  - f: The longest free range.
	 *  - c: The allocation class associated with the longest free range.
	 *  - s: The allocation score.
	 *  - a: The address of the block itself.
	 * 
	 * 63    56 55    48 47    40 39    32 31    24 23    16 15     8 7      0
	 * .fffffff fffccccc ......ss ssssssss .....aaa aaaaaaaa aaaaaaaa aaaaaaaa
	 * 
	 * We want that bitfield to be usable as a discriminant to prioritize
	 * from which block we want to allocate.
	 * 
	 *  1. Reduce fragmentation.
	 *     We therefore try to select the block with the shortest free range
	 *     possible, so we avoid unecesserly breaking large free ranges.
	 * 
	 *  2. Use block which already host many allocations.
	 *     We do so in order to maximize our chances to be able to free blocks.
	 * 
	 *     This tends to work better in practice than counting the number
	 *     of allocated pages or other metrics. For details, please see the
	 *     Temeraire paper: https://research.google/pubs/pub50370/
	 * 
	 *     The intuition is that the more allocations live on a block,
	 *     the more likely it is that one of them is going to be long lived.
	 * 
	 *  3. Everything else being equal, we default to lowest address.
	 */
	ulong bits = ulong(PagesInBlock) << LongestFreeRangeIndex
		| ulong(PagesInBlock) << AllocScoreIndex;

	// Verify our assumptions.
	enum SignifiantAddressBits = LgAddressSpace - LgBlockSize;
	static assert(SignifiantAddressBits <= 32,
	              "Unable to pack address in bits!");

	enum MaxFreeRangeClass = getFreeSpaceClass(PagesInBlock);
	static assert(MaxFreeRangeClass <= FreeRangeClassMask,
	              "Unable to pack the free range class!");

	// Useful constants for bit manipulations.
	enum LongestFreeRangeIndex = 53;
	enum LongestFreeRangeSize = 10;
	enum LongestFreeRangeMask = (1 << LongestFreeRangeSize) - 1;

	enum FreeRangeClassIndex = 48;
	enum FreeRangeClassSize = 5;
	enum FreeRangeClassMask = (1 << FreeRangeClassSize) - 1;

	enum AllocScoreIndex = 32;
	enum AllocScoreSize = 10;
	enum AllocScoreUnit = 1UL << AllocScoreIndex;
	enum AllocScoreMask = (1 << AllocScoreSize) - 1;

	union Links {
		PHNode phnode;
		RNode rnode;
	}

	Links _links;

	uint usedCount;
	uint dirtyCount;
	ubyte generation;

	import d.gc.bitmap;
	Bitmap!PagesInBlock allocatedPages;
	Bitmap!PagesInBlock dirtyPages;

	this(void* address, ubyte generation = 0) {
		assert(isAligned(address, BlockSize), "Invalid address!");

		this.bits |= (cast(size_t) address) >> LgBlockSize;
		this.generation = generation;
	}

public:
	BlockDescriptor* at(void* ptr) {
		this = BlockDescriptor(ptr, generation);
		return &this;
	}

	static fromPage(GenerationPointer page) {
		// FIXME: in contract
		assert(page.address !is null, "Invalid page!");
		assert(isAligned(page.address, PageSize), "Invalid page!");

		enum BlockDescriptorSize = alignUp(BlockDescriptor.sizeof, CacheLine);
		enum Count = PageSize / BlockDescriptorSize;
		static assert(Count == 21, "Unexpected BlockDescriptor size!");

		UnusedBlockHeap ret;
		foreach (i; 0 .. Count) {
			/**
			 * We create the elements starting from the last so that
			 * they are inserted in the heap from worst to best.
			 * This ensures the heap is a de facto linked list.
			 */
			auto slot = page.add((Count - 1 - i) * BlockDescriptorSize);
			auto block = cast(BlockDescriptor*) slot.address;

			*block = BlockDescriptor(null, slot.generation);
			ret.insert(block);
		}

		return ret;
	}

	@property
	void* address() const {
		return cast(void*) ((bits & uint.max) << LgBlockSize);
	}

	@property
	uint longestFreeRange() const {
		return (bits >> LongestFreeRangeIndex) & LongestFreeRangeMask;
	}

	@property
	ubyte freeRangeClass() const {
		return (bits >> FreeRangeClassIndex) & FreeRangeClassMask;
	}

	void updateLongestFreeRange(uint lfr) {
		assert(lfr <= PagesInBlock, "Invalid lfr!");

		enum ShiftedMask = ulong(LongestFreeRangeMask) << LongestFreeRangeIndex
			| ulong(FreeRangeClassMask) << FreeRangeClassIndex;
		bits &= ~ShiftedMask;

		auto c = getFreeSpaceClass(lfr) & FreeRangeClassMask;
		bits |= ulong(c) << FreeRangeClassIndex;
		bits |= ulong(lfr) << LongestFreeRangeIndex;
	}

	@property
	uint allocCount() const {
		uint allocScore = (bits >> AllocScoreIndex) & AllocScoreMask;
		return PagesInBlock - allocScore;
	}

	@property
	bool empty() const {
		return usedCount == 0;
	}

	@property
	bool full() const {
		return usedCount >= PagesInBlock;
	}

	@property
	ref PHNode phnode() {
		return _links.phnode;
	}

	@property
	ref RNode rnode() {
		return _links.rnode;
	}

	uint reserve(uint pages) {
		// FIXME: in contract
		assert(pages > 0 && pages <= longestFreeRange,
		       "Invalid number of pages!");

		uint bestIndex = uint.max;
		uint bestLength = uint.max;
		uint longestLength = 0;
		uint secondLongestLength = 0;

		uint current, index, length;
		while (current < PagesInBlock
			       && allocatedPages.nextFreeRange(current, index, length)) {
			assert(length <= longestFreeRange);

			// Keep track of the best length.
			if (length > longestLength) {
				secondLongestLength = longestLength;
				longestLength = length;
			} else if (length > secondLongestLength) {
				secondLongestLength = length;
			}

			if (length >= pages && length < bestLength) {
				bestIndex = index;
				bestLength = length;
			}

			current = index + length;
		}

		bits -= AllocScoreUnit;
		registerAllocation(bestIndex, pages);

		// If we allocated from the longest range,
		// compute the new longest free range.
		if (bestLength == longestLength) {
			longestLength = max(longestLength - pages, secondLongestLength);
			updateLongestFreeRange(longestLength);
		}

		return bestIndex;
	}

	bool growAt(uint index, uint pages) {
		assert(index < PagesInBlock, "Invalid index!");
		assert(pages > 0 && index + pages <= PagesInBlock,
		       "Invalid number of pages!");

		auto freeLength = allocatedPages.findSet(index) - index;
		if (freeLength < pages) {
			return false;
		}

		registerAllocation(index, pages);

		// If not allocated from the longest free range, we're done:
		if (freeLength != longestFreeRange) {
			return true;
		}

		// TODO: We could stop at PagesInBlock - longestLength, but will require test.
		uint longestLength = 0;
		uint current = 0;
		uint length;
		while (current < PagesInBlock
			       && allocatedPages.nextFreeRange(current, current, length)) {
			longestLength = max(longestLength, length);
			current += length;
		}

		updateLongestFreeRange(longestLength);
		return true;
	}

	void registerAllocation(uint index, uint pages) {
		assert(index < PagesInBlock, "Invalid index!");
		assert(pages > 0 && index + pages <= PagesInBlock,
		       "Invalid number of pages!");

		// Mark the pages as allocated.
		usedCount += pages;
		allocatedPages.setRange(index, pages);

		// Mark the pages as dirty.
		dirtyCount -= dirtyPages.countBits(index, pages);
		dirtyCount += pages;
		dirtyPages.setRange(index, pages);
	}

	void clear(uint index, uint pages) {
		// FIXME: in contract.
		assert(pages > 0 && pages <= PagesInBlock, "Invalid number of pages!");
		assert(index <= PagesInBlock - pages, "Invalid index!");
		assert(allocatedPages.countBits(index, pages) == pages,
		       "Clearing unallocated pages!");

		allocatedPages.clearRange(index, pages);
		usedCount -= pages;

		auto start = allocatedPages.findSetBackward(index) + 1;
		auto stop = allocatedPages.findSet(index + pages - 1);

		auto clearedLongestFreeRange = stop - start;
		if (clearedLongestFreeRange > longestFreeRange) {
			updateLongestFreeRange(clearedLongestFreeRange);
		}
	}

	void release(uint index, uint pages) {
		clear(index, pages);
		bits += AllocScoreUnit;
	}
}

alias PriorityBlockHeap = Heap!(BlockDescriptor, priorityBlockCmp);

ptrdiff_t priorityBlockCmp(BlockDescriptor* lhs, BlockDescriptor* rhs) {
	auto l = lhs.bits;
	auto r = rhs.bits;
	return (l > r) - (l < r);
}

unittest priority {
	static makeBlock(uint lfr, uint nalloc) {
		BlockDescriptor block;
		block.updateLongestFreeRange(lfr);
		block.bits -= nalloc * BlockDescriptor.AllocScoreUnit;

		assert(block.longestFreeRange == lfr);
		assert(block.allocCount == nalloc);
		return block;
	}

	PriorityBlockHeap heap;
	assert(heap.top is null);

	// Lowest priority block possible.
	auto block0 = makeBlock(PagesInBlock, 0);
	heap.insert(&block0);
	assert(heap.top is &block0);

	// More allocation is better.
	auto block1 = makeBlock(PagesInBlock, 1);
	heap.insert(&block1);
	assert(heap.top is &block1);

	// But shorter lfr is even better!
	auto block2 = makeBlock(0, 0);
	heap.insert(&block2);
	assert(heap.top is &block2);

	// More allocation remains a tie breaker.
	auto block3 = makeBlock(0, 500);
	heap.insert(&block3);
	assert(heap.top is &block3);

	// Try inserting a few blocks out of order.
	auto block4 = makeBlock(0, 100);
	auto block5 = makeBlock(250, 1);
	auto block6 = makeBlock(250, 300);
	auto block7 = makeBlock(100, 300);
	heap.insert(&block4);
	heap.insert(&block5);
	heap.insert(&block6);
	heap.insert(&block7);

	// Pop all the blocks and check they come out in
	// the expected order.
	assert(heap.pop() is &block3);
	assert(heap.pop() is &block4);
	assert(heap.pop() is &block2);
	assert(heap.pop() is &block7);
	assert(heap.pop() is &block6);
	assert(heap.pop() is &block5);
	assert(heap.pop() is &block1);
	assert(heap.pop() is &block0);
	assert(heap.pop() is null);
}

alias UnusedBlockHeap = Heap!(BlockDescriptor, unusedBlockDescriptorCmp);

ptrdiff_t unusedBlockDescriptorCmp(BlockDescriptor* lhs, BlockDescriptor* rhs) {
	static assert(LgAddressSpace <= 56, "Address space too large!");

	auto l = ulong(lhs.generation) << 56;
	auto r = ulong(rhs.generation) << 56;

	l |= cast(size_t) lhs;
	r |= cast(size_t) rhs;

	return (l > r) - (l < r);
}

unittest reserve_release {
	BlockDescriptor block;

	void checkRangeState(uint nalloc, uint nused, uint ndirty, uint lfr) {
		assert(block.allocCount == nalloc);
		assert(block.usedCount == nused);
		assert(block.dirtyCount == ndirty);
		assert(block.longestFreeRange == lfr);
		assert(block.allocatedPages.countBits(0, PagesInBlock) == nused);
	}

	checkRangeState(0, 0, 0, PagesInBlock);

	// First allocation.
	assert(block.reserve(5) == 0);
	checkRangeState(1, 5, 5, PagesInBlock - 5);

	// Second allocation.
	assert(block.reserve(5) == 5);
	checkRangeState(2, 10, 10, PagesInBlock - 10);

	// Check that freeing the first allocation works as expected.
	block.release(0, 5);
	checkRangeState(1, 5, 10, PagesInBlock - 10);

	// A new allocation that doesn't fit in the space left
	// by the first one is done in the trailign space.
	assert(block.reserve(7) == 10);
	checkRangeState(2, 12, 17, PagesInBlock - 17);

	// A new allocation that fits is allocated in there.
	assert(block.reserve(5) == 0);
	checkRangeState(3, 17, 17, PagesInBlock - 17);

	// Make sure we keep track of the longest free range
	// when releasing pages.
	block.release(10, 7);
	checkRangeState(2, 10, 17, PagesInBlock - 10);

	block.release(0, 5);
	checkRangeState(1, 5, 17, PagesInBlock - 10);

	block.release(5, 5);
	checkRangeState(0, 0, 17, PagesInBlock);

	// Allocate the whole block.
	foreach (i; 0 .. PagesInBlock / 4) {
		assert(block.reserve(4) == 4 * i);
	}

	checkRangeState(PagesInBlock / 4, PagesInBlock, 512, 0);

	// Release in the middle.
	block.release(100, 4);
	checkRangeState(PagesInBlock / 4 - 1, PagesInBlock - 4, 512, 4);

	// Release just before and after.
	block.release(104, 4);
	checkRangeState(PagesInBlock / 4 - 2, PagesInBlock - 8, 512, 8);

	block.release(96, 4);
	checkRangeState(PagesInBlock / 4 - 3, PagesInBlock - 12, 512, 12);

	// Release futher along and then bridge.
	block.release(112, 4);
	checkRangeState(PagesInBlock / 4 - 4, PagesInBlock - 16, 512, 12);

	block.release(108, 4);
	checkRangeState(PagesInBlock / 4 - 5, PagesInBlock - 20, 512, 20);

	// Release first and last.
	block.release(0, 4);
	checkRangeState(PagesInBlock / 4 - 6, PagesInBlock - 24, 512, 20);

	block.release(PagesInBlock - 4, 4);
	checkRangeState(PagesInBlock / 4 - 7, PagesInBlock - 28, 512, 20);
}

unittest clear {
	BlockDescriptor block;

	void checkRangeState(uint nalloc, uint nused, uint ndirty, uint lfr) {
		assert(block.allocCount == nalloc);
		assert(block.usedCount == nused);
		assert(block.dirtyCount == ndirty);
		assert(block.longestFreeRange == lfr);
		assert(block.allocatedPages.countBits(0, PagesInBlock) == nused);
	}

	// First allocation.
	assert(block.reserve(200) == 0);
	checkRangeState(1, 200, 200, PagesInBlock - 200);

	// Second allocation:
	assert(block.reserve(100) == 200);
	checkRangeState(2, 300, 300, PagesInBlock - 300);

	// Third allocation, and we're full:
	assert(block.reserve(212) == 300);
	checkRangeState(3, 512, 512, 0);

	// Shrink the first allocation, make lfr of 100.
	block.clear(100, 100);
	checkRangeState(3, 412, 512, PagesInBlock - 412);

	// Shrink the second allocation, lfr is still 100.
	block.clear(299, 1);
	checkRangeState(3, 411, 512, PagesInBlock - 412);

	// Shrink the third allocation, lfr is still 100.
	block.clear(500, 12);
	checkRangeState(3, 399, 512, PagesInBlock - 412);

	// Release the third allocation.
	block.release(300, 200);
	checkRangeState(2, 199, 512, 213);

	// Release the second allocation.
	block.release(200, 99);
	checkRangeState(1, 100, 512, PagesInBlock - 100);

	// Release the first allocation.
	block.release(0, 100);
	checkRangeState(0, 0, 512, PagesInBlock);
}

unittest growAt {
	BlockDescriptor block;

	void checkRangeState(uint nalloc, uint nused, uint ndirty, uint lfr) {
		assert(block.allocCount == nalloc);
		assert(block.usedCount == nused);
		assert(block.dirtyCount == ndirty);
		assert(block.longestFreeRange == lfr);
		assert(block.allocatedPages.countBits(0, PagesInBlock) == nused);
	}

	checkRangeState(0, 0, 0, PagesInBlock);

	// First allocation.
	assert(block.reserve(64) == 0);
	checkRangeState(1, 64, 64, PagesInBlock - 64);

	// Grow it by 32 pages.
	assert(block.growAt(64, 32));
	checkRangeState(1, 96, 96, PagesInBlock - 96);

	// Grow it by another 32 pages.
	assert(block.growAt(96, 32));
	checkRangeState(1, 128, 128, PagesInBlock - 128);

	// Second allocation.
	assert(block.reserve(256) == 128);
	checkRangeState(2, 384, 384, PagesInBlock - 384);

	// Try to grow the first allocation, but cannot, there is no space.
	assert(!block.growAt(128, 1));
	checkRangeState(2, 384, 384, PagesInBlock - 384);

	// Third allocation.
	assert(block.reserve(128) == 384);
	checkRangeState(3, 512, 512, 0);

	// Try to grow the second allocation, but cannot, there is no space.
	assert(!block.growAt(384, 1));
	checkRangeState(3, 512, 512, 0);

	// Release first allocation.
	block.release(0, 128);
	checkRangeState(2, 384, 512, PagesInBlock - 384);

	// Release third allocation.
	block.release(384, 128);
	checkRangeState(1, 256, 512, 128);

	// There are now two equally 'longest length' free ranges.
	// Grow the second allocation to see that lfr is recomputed properly.
	assert(block.growAt(384, 1));
	checkRangeState(1, 257, 512, 128);

	// Make an allocation in the lfr, new lfr is after the second alloc.
	assert(block.reserve(128) == 0);
	checkRangeState(2, 385, 512, 127);

	// Free the above allocation, lfr is 128 again.
	block.release(0, 128);
	checkRangeState(1, 257, 512, 128);

	// Free the second allocation.
	block.release(128, 257);
	checkRangeState(0, 0, 512, PagesInBlock);

	// Test with a full block:

	// Make an allocation:
	assert(block.reserve(256) == 0);
	checkRangeState(1, 256, 512, PagesInBlock - 256);

	// Make another allocation, filling block.
	assert(block.reserve(256) == 256);
	checkRangeState(2, 512, 512, 0);

	// Try expanding the first one, but there is no space.
	assert(!block.growAt(256, 1));
	checkRangeState(2, 512, 512, 0);

	// Release the first allocation.
	block.release(0, 256);
	checkRangeState(1, 256, 512, PagesInBlock - 256);

	// Replace it with a shorter one.
	assert(block.reserve(250) == 0);
	checkRangeState(2, 506, 512, PagesInBlock - 506);

	// Try to grow the above by 7, but cannot, this is one page too many.
	assert(!block.growAt(250, 7));
	checkRangeState(2, 506, 512, PagesInBlock - 506);

	// Grow by 6 works, and fills block.
	assert(block.growAt(250, 6));
	checkRangeState(2, 512, 512, 0);
}

unittest track_dirty {
	BlockDescriptor block;

	void checkRangeState(uint nalloc, uint nused, uint ndirty, uint lfr) {
		assert(block.allocCount == nalloc);
		assert(block.usedCount == nused);
		assert(block.dirtyCount == ndirty);
		assert(block.longestFreeRange == lfr);
		assert(block.allocatedPages.countBits(0, PagesInBlock) == nused);
	}

	checkRangeState(0, 0, 0, PagesInBlock);

	// First allocation.
	assert(block.reserve(5) == 0);
	checkRangeState(1, 5, 5, PagesInBlock - 5);

	// Second allocation.
	assert(block.reserve(5) == 5);
	checkRangeState(2, 10, 10, PagesInBlock - 10);

	// Check that freeing the first allocation works as expected.
	block.release(0, 5);
	checkRangeState(1, 5, 10, PagesInBlock - 10);

	// A new allocation that doesn't fit in the space left
	// by the first one is done in the trailign space.
	assert(block.reserve(7) == 10);
	checkRangeState(2, 12, 17, PagesInBlock - 17);

	// A new allocation that fits is allocated in there.
	assert(block.reserve(5) == 0);
	checkRangeState(3, 17, 17, PagesInBlock - 17);

	// Make sure we keep track of the longest free range
	// when releasing pages.
	block.release(10, 7);
	checkRangeState(2, 10, 17, PagesInBlock - 10);

	block.release(0, 5);
	checkRangeState(1, 5, 17, PagesInBlock - 10);

	// Check that allocating something that do not fit in
	// the first slot allocates in the apropriate free range.
	assert(block.reserve(10) == 10);
	checkRangeState(2, 15, 20, PagesInBlock - 20);
}

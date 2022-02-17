const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const arena = @import("arena.zig");
const free_list = @import("free_list.zig");

test "arena tests" {
    var arena_allocator = try arena.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_allocator.deinit();
    const allocator = arena_allocator.allocator();

    // Good ol' byte allocation
    const my_small_array = try allocator.alloc(u8, 100);
    assert(my_small_array.len == 100);

    // Different type allocation. Testing with amount of bytes
    const my_bigger_array = try allocator.alloc(usize, 500);
    assert(mem.sliceAsBytes(my_bigger_array).len == @sizeOf(usize) * 500);
    
    // Even bigger array with a weird bit-sized integer
    const my_high_array = try allocator.alloc(u420, 420);
    assert(mem.sliceAsBytes(my_high_array).len == @sizeOf(u420) * 420);

    // Create array then free it (as arena allocator can only free last).
    var my_mistake_array = try allocator.alloc(i31, 200);
    const old_end = arena_allocator.end_index;
    allocator.free(my_mistake_array);
    assert(old_end - 200 * @sizeOf(i31) == arena_allocator.end_index); // Index back to where it was before allocation!
}

test "free list tests" {
    var free_list_allocator = try free_list.FreeListAllocator.init(std.heap.page_allocator);
    defer free_list_allocator.deinit();
    const allocator = free_list_allocator.allocator();

    // One heap and free node at the moment! We will test if this increases down below
    assert(free_list_allocator.heaps.len() == 1);
    assert(free_list_allocator.free_nodes.len == 1);

    // Ye Olde Allocation
    const my_small_array = try allocator.alloc(u8, 100);
    assert(my_small_array.len == 100);

    assert(free_list_allocator.free_nodes.last.?.data.len == 4096 - 100 - @sizeOf(std.SinglyLinkedList([]u8).Node)); // Node data is inside the array

    // Different type and size. Testing byte amount
    const my_bigger_array = try allocator.alloc(usize, 300);
    assert(mem.sliceAsBytes(my_bigger_array).len == @sizeOf(usize) * 300);

    // Test after request with usize. Length is aligned with respect to usize
    assert(free_list_allocator.free_nodes.last.?.data.len == 
            std.mem.alignBackward(4096 - 100 - 300 * @sizeOf(usize) - @sizeOf(std.SinglyLinkedList([]u8).Node), @alignOf(usize)));
    //                            page   u8      usize array                node size                               alignment

    // Allocate memory for array for a big array. This more than a page size. So it will create a new heap as well as a new free node (the new heap)
    const my_PIrfect_array = try allocator.alloc(u314, 314);
    assert(mem.sliceAsBytes(my_PIrfect_array).len == @sizeOf(u314) * 314);

    // Time to test our hypothesis for heap and free node amounts
    assert(free_list_allocator.heaps.len() == 2);
    assert(free_list_allocator.free_nodes.len == 2);


    // Let us free some memory and test what happens to it
    allocator.free(my_bigger_array);
    assert(free_list_allocator.free_nodes.len == 3);
    assert(@ptrToInt(free_list_allocator.free_nodes.last.?.data.ptr) == @ptrToInt(my_bigger_array.ptr));

    // Right here our free nodes should be these sizes and in this order: 1568, 4064, 2400
    // The first one is residue from the first heap, the second is from the big u314 bit allocation (big allocations create extra page space and uses some for nodes data)
    // And the last one is from the newly freed my_bigger_array allocation (300 x 8 bytes).
    assert(free_list_allocator.free_nodes.first.?.data.len == 1568);
    assert(free_list_allocator.free_nodes.first.?.next.?.data.len == 4064);
    assert(free_list_allocator.free_nodes.first.?.next.?.next.?.data.len == 2400);

    // Let us try to allocate something bigger than 1568 and see if it drops into the second free node
    const ptr_to_second_node = @ptrToInt(free_list_allocator.free_nodes.first.?.next.?.data.ptr);
    const my_quite_big_array = try allocator.alloc(u8, 3000);
    assert(@ptrToInt(my_quite_big_array.ptr) == ptr_to_second_node);

    // Let us allocate something smaller than 1568 and see if it gets prepended to the first node list
    const ptr_to_first_node = @ptrToInt(free_list_allocator.free_nodes.first.?.data.ptr);
    const new_array = try allocator.alloc(u8, 1000);
    assert(ptr_to_first_node == @ptrToInt(new_array.ptr));

    // And now since residue memories are appended to the tail. The first node should now be the 2400 byte one
    assert(free_list_allocator.free_nodes.first.?.data.len == 2400);

    // And now your memory is hella fragmented :D
}
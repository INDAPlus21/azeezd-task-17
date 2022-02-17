const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;

/// Arena Allocator that uses creates buffers that double in side if the previous fills up or creates one large enough if the request allocation is too big.
/// Frees everything using one free command, the deinit.
/// resize() does nothing and if free([]u8) is given the last memory allocated, it will free that, otherwise it does nothing as well.
pub const ArenaAllocator = struct {
    underlying: mem.Allocator,
    buffers: std.SinglyLinkedList([]u8),
    end_index: usize,

    const BufferNode = std.SinglyLinkedList([]u8).Node;

    /// # `init`
    /// Initializes the allocator using the given allocator, usually the page_allocator from std.heap
    pub fn init(underlying: mem.Allocator) !ArenaAllocator {
        var buffer_list = @as(std.SinglyLinkedList([]u8), .{});
        return ArenaAllocator {
            .underlying = underlying,
            .buffers = buffer_list,
            .end_index = 0
        };
    }
    
    /// # `deinit`
    /// Frees the entire arena, freeing all its buffers
    pub fn deinit(self: *ArenaAllocator) void {
        var node = self.buffers.first;
        while (node) |first| {
            const next = first.next;
            self.underlying.free(first.data);
            node = next;
        }
    }

    /// # `allocator`
    /// Returns the allocator object
    pub fn allocator(self: *ArenaAllocator) Allocator {
        return Allocator.init(self, alloc, resize, free);
    }

    /// # `alloc`
    /// Returns pointer to an allocated memory with the given size. If the size given is too large, it will create more buffers to fill
    fn alloc(self: *ArenaAllocator, size: usize, ptr_align: u29, len_align: u29, ra: usize) ![]u8 {
        _ = len_align;
        _ = ra;

        // Size starts at 2048 but will double immediately to 4096 which is the usual page size
        var buf_node = if (self.buffers.first == null) try self.newBufferNode(size, 2048) else self.buffers.first;

        while (true) {
            // Data of the node is inside the array, that is why we skip that part
            var buffer = buf_node.?.data[@sizeOf(BufferNode)..];

            // Align the pointer to given data alignment
            const aligned_ptr = mem.alignForward(@ptrToInt(buffer.ptr) + self.end_index, ptr_align);
            const aligned_idx = aligned_ptr - @ptrToInt(buffer.ptr);
            const new_end = aligned_idx + size;

            if (new_end < buffer.len) {
                self.end_index = new_end;
                return buffer[aligned_idx..new_end];
            }
            // Too big! allocate new!
            buf_node = try self.newBufferNode(size, buffer.len);
        }
    }

    /// # `newBufferNode`
    /// Takes the requested allocation size and the size of the node at the head and creates a new buffer to prepends it to the buffer linked list
    fn newBufferNode(self: *ArenaAllocator, requested_size: usize, curr_buffer_len: usize) !*BufferNode {
        // Either create with double of the previous or equal to the size of the requested size
        const new_len = @maximum(curr_buffer_len * 2, requested_size);
        const new_buffer = try self.underlying.alloc(u8, new_len);
        const new_node = @ptrCast(*BufferNode, @alignCast(@alignOf(BufferNode), new_buffer.ptr));
        new_node.* = BufferNode {
            .data = new_buffer,
        };
        self.buffers.prepend(new_node);

        // Reset index because new buffer new start
        self.end_index = 0;

        return new_node;
    }

    fn resize(self: *ArenaAllocator, buf: []u8, buf_align: u29, new_len: usize, len_align: u29, ra: usize) ?usize {
        _ = self;
        _ = buf;
        _ = buf_align;
        _ = new_len;
        _ = len_align;
        _ = ra;
        return 0;
    }

    fn free(self: *ArenaAllocator, buf: []u8, buf_align: u29, ra: usize) void {
        _ = buf_align;
        _ = ra;

        if (self.buffers.first) |first| {
            if (@ptrToInt(first.data[@sizeOf(BufferNode)..].ptr) + self.end_index == @ptrToInt(buf.ptr) + buf.len) {
                self.end_index -= buf.len;
            }
        }
    }
};
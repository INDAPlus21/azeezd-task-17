const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

/// # `FreeListAllocator`
/// A naive approach to a free list allocator where upon freeing a memory. The memory is send to a DoublyLinkedList (TailQueue is very similar to it).
/// When requesting memory, the allocator looks through the free memory available and checks for the FIRST FIT and returns the required memory.
/// Then if the free memory had some exceeding memory that becomes added as the new node.
/// If there is no free memory, the allocator asks the given underlying allocator (usually the page) for more memory to which it adds to its heaps and links it as a free node.
pub const FreeListAllocator = struct {
    heaps: std.SinglyLinkedList([]u8), // Singly-linked list of heaps allocated (Total Memory chunks, this includes both free and used memory)
    free_nodes: std.TailQueue([]u8), // "Doubly-linked list" of memory that is free to allocate to inside that heaps above
    underlying: Allocator,

    // Node types for free memory and big heaps
    const FreeNode = std.TailQueue([]u8).Node;
    const HeapNode = std.SinglyLinkedList([]u8).Node;

    /// # `init`
    /// Initializes and returns the allocator using the given allocator (usually page allocator). Should always be followed by a `defer deinit()` function to.
    pub fn init(underlying: Allocator) !FreeListAllocator {
        // Constructs one heap of one page size and stores it as a node in the SLL
        const heap = try underlying.alloc(u8, 4096);
        var heapNodes = @as(std.SinglyLinkedList([]u8), .{});
        const heap_node = @ptrCast(*HeapNode, @alignCast(@alignOf(HeapNode), heap.ptr));
        heap_node.* = HeapNode {
            .data = heap
        };
        heapNodes.prepend(heap_node);

        // The first free node, to be stored inside the the DLL
        const buffer = heap[@sizeOf(HeapNode)..]; // The HeapNode data is inside the array, that is why we skip the first few bytes
        var freeNodes = @as(std.TailQueue([]u8), .{});
        const free_node = @ptrCast(*FreeNode, @alignCast(@alignOf(FreeNode), buffer.ptr));
        free_node.* = FreeNode {
            .data = buffer
        };
        freeNodes.prepend(free_node);
        
        return FreeListAllocator{
            .heaps = heapNodes,
            .free_nodes = freeNodes,
            .underlying = underlying
        };
    }

    /// # `deinit`
    /// Frees ALL memory allocated by this allocator to the underlying allocator
    pub fn deinit(self: *FreeListAllocator) void {
        var node = self.heaps.first;
        while (node) |first| {
            const next = first.next;
            self.underlying.free(first.data);
            node = next;
        }
    }

    /// # `allocator`
    /// Returns the allocator object
    pub fn allocator(self: *FreeListAllocator) Allocator {
        return Allocator.init(self, alloc, resize, free);
    }

    /// # `alloc`
    /// Returns a pointer to an allocated memory according to the given size and type. 
    /// This will look through free nodes to allocate from, if there is none fitting, it will ask the underlying allocator for the appropiate memory
    fn alloc(self: *FreeListAllocator, size: usize, ptr_align: u29, len_align: u29, ra: usize) ![]u8 {
        _ = len_align;
        _ = ra;

        while (true) {
            if (self.find(size)) |free_space| { // Get free node if available
                const aligned_ptr = mem.alignForward(@ptrToInt(free_space.ptr), ptr_align);
                const aligned_idx = aligned_ptr - @ptrToInt(free_space.ptr);
                const end_index = aligned_idx + size;
                const allocation = free_space[aligned_idx..end_index]; // Allocation to return
                self.newFreeNode(free_space[end_index..]); // Residue memory is added as new node to the free list
                return allocation;
            }

            // Need more memory from underlying allocator

            // If larger than a page, allocate that size (+ size for heap node data and some more to reduce allocating more in future), otherwise page size
            const new_size = @maximum(size, 4096); 
            const heap_extension = try self.underlying.alloc(u8, new_size + 4096);

            const heap_node = @ptrCast(*HeapNode, @alignCast(@alignOf(HeapNode), heap_extension.ptr));
            heap_node.* = HeapNode {
                .data = heap_extension
            };
            self.heaps.prepend(heap_node);
            self.newFreeNode(heap_extension[@sizeOf(HeapNode)..]);
        }
    }

    /// # `find`
    /// Searches through the free nodes for the FIRST FIT for the size then it returns that entire buffer stored in the node and removes the node.
    /// If no node was found, it returns null
    fn find(self: *FreeListAllocator, size: usize) ?[]u8 {
        var first = self.free_nodes.first;

        while (first) |node| : (first = node.next) {
            if (node.data.len >= size) {
                self.free_nodes.remove(node);
                return node.data;
            }
        }
        return null;
    }

    /// # `newFreeNode`
    /// Takes a byte buffer and appends it to the Free Nodes Doubly-linked List
    fn newFreeNode(self: *FreeListAllocator, buffer: []u8) void {
        const aligned_ptr = mem.alignForward(@ptrToInt(buffer.ptr), @alignOf(FreeNode));
        const index = aligned_ptr - @ptrToInt(buffer.ptr);
        const new_node = @ptrCast(*FreeNode, @alignCast(@alignOf(FreeNode), buffer[index..]));
        new_node.* = FreeNode {
            .data = buffer
        };
        self.free_nodes.append(new_node);
    }

    /// # `resize`
    /// Resizing is not supported (this will do nothing) with regard to Zig Standard because it wants resizing functions to guarantee that the pointer is not changed
    fn resize(self: *FreeListAllocator, buf: []u8, buf_align: u29, new_len: usize, len_align: u29, ra: usize) ?usize {
        _ = buf;
        _ = buf_align;
        _ = new_len;
        _ = len_align;
        _ = ra;
        _ = self;
        return 0;
    }

    /// # `free`
    /// Frees the given buffer and adds it to the free node list
    fn free(self: *FreeListAllocator, buf: []u8, buf_align: u29, ra: usize) void {
        _ = buf_align;
        _ = ra;

        self.newFreeNode(buf); // appends the new free memory to free nodes
    }
};
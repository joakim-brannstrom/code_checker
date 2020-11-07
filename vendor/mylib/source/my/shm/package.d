/**
Copyright: Copyright (c) 2020, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

Shared memory IPC.
*/
module my.shm;

immutable size_t queueSize = 32;
immutable size_t bufferSize = 1 << 28; // 256mb
immutable size_t GAP = 1024; // safety gap

ubyte* createMemorySegment(string name, size_t size, ref bool newSegment, size_t alignment = 32) {
    import core.stdc.errno;
    import core.sys.posix.fcntl;
    import core.sys.posix.sys.mman;
    import core.sys.posix.sys.stat;
    import core.sys.posix.unistd;
    import std.conv : octal;
    import std.string : toStringz;

    /* Create a new shared memory segment. The segment is created under a name.
     * We check if an existing segment is found under the same name. This info
     * is stored in `new_segment`.
     *
     * The permission of the memory segment is 0644.
     */
    int fd;
    const name_ = name.toStringz;
    while (true) {
        newSegment = true;
        fd = shm_open(name_, O_RDWR | O_CREAT | O_EXCL, octal!644);
        if (fd >= 0) {
            fchmod(fd, octal!644);
        }
        if (errno == EEXIST) {
            fd = shm_open(name_, O_RDWR, octal!644);
            if (fd < 0 && errno == ENOENT) {
                // the memory segment was deleted in the mean time
                continue;
            }
            newSegment = false;
        }
        break;
    }

    // We allocate an extra `alignment` bytes as padding
    int result = ftruncate(fd, size + alignment);
    if (result == EINVAL) {
        return null;
    }

    auto ptr = mmap(null, size + alignment, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    return alignAddress(ptr, alignment);
}

ubyte* alignAddress(void* ptr, size_t alignment) {
    auto int_ptr = cast(uint) ptr;
    auto aligned_int_ptr = (((int_ptr - 1) | (alignment - 1)) + 1);
    return cast(ubyte*) aligned_int_ptr;
}

struct PIDSet {
    import core.sync.mutex : Mutex;
    import core.sys.posix.unistd;
    import my.set;

    Mutex mtx;
    int[32] pids;

    void lock() { mtx.lock_nothrow(); }
    void unlock() { mtx.unlock_nothrow(); }

    bool isAnyAlive() @trusted nothrow @nogc {
        import core.sys.posix.signal;

        bool alive = false;
        auto current_pid = getpid();
        foreach (pid; pids[]) {
            if (pid == 0)
                continue;

            if (pid == current_pid) {
                // intra-process communication
                // two threads of the same process
                alive = true;
            }

            if (core.sys.posix.signal.kill(pid, 0) == -1) {
                pids[pid] = 0;
            } else {
                alive = true;
            }
        }
        return alive;
    }

    void insert(int pid) {
        foreach (i; 0 .. pids.length) {
            if (pids[i] != 0) {
                pids[i] = pid;
                break;
            }
        }
    }
}

PIDSet makePIDSet() {
    import core.sync.mutex : Mutex;

    return PIDSet(new Mutex);
}

struct MemBlock {
    void* ptr;
    size_t length;
    bool free;

    void noDelete() {
        free = false;
    }
}

struct Element {
    size_t size;
    bool empty;
    ubyte* address;
}

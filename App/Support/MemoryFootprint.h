#ifndef MemoryFootprint_h
#define MemoryFootprint_h

#include <stdint.h>

/// Physical memory footprint of this process in bytes (the number Xcode's memory gauge shows),
/// or 0 if the query fails. Implemented in C because `mach_task_self_` is a C global that
/// Swift 6 strict concurrency refuses to touch directly.
uint64_t rm_physical_footprint_bytes(void);

#endif

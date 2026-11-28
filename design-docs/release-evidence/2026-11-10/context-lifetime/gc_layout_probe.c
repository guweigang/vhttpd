#include "/Users/guweigang/Source/vhttpd/.runtime/upstream-gc-handoff-20261110/gc-upstream.c"
size_t vhttpd_gc_offset_sections(void) { return __builtin_offsetof(__typeof__(GC_arrays), _heap_sects); }
size_t vhttpd_gc_offset_count(void) { return __builtin_offsetof(__typeof__(GC_arrays), _n_heap_sects); }
size_t vhttpd_gc_size_section(void) { return sizeof(struct HeapSect); }
size_t vhttpd_gc_offset_heap(void) { return __builtin_offsetof(__typeof__(GC_arrays), _heapsize); }
size_t vhttpd_gc_offset_free(void) { return __builtin_offsetof(__typeof__(GC_arrays), _large_free_bytes); }
size_t vhttpd_gc_offset_unmapped(void) { return __builtin_offsetof(__typeof__(GC_arrays), _unmapped_bytes); }

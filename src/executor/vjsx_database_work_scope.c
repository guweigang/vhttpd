#include "vjsx_database_work_scope.h"
/* One definition also when V emits several C translation units. */
#if defined(_MSC_VER)
__declspec(thread) void *vhttpd_database_scope_work;
#else
_Thread_local void *vhttpd_database_scope_work;
#endif

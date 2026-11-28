module host

#include <windows.h>
#include <shellapi.h>

fn C.ShellExecuteW(voidptr, &u16, &u16, &u16, &u16, i32) voidptr

fn open_windows_target(target string) ! {
	if target.contains('\x00') { return error('目标地址无效。') }
	result := C.ShellExecuteW(unsafe { nil }, 'open'.to_wide(), target.to_wide(), unsafe { nil }, unsafe { nil }, 1)
	if uint(result) <= 32 { return error('系统无法打开目标，请检查默认应用。') }
}

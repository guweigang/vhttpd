module main

#flag windows -lkernel32
#include <windows.h>

fn C.GetUserDefaultUILanguage() u16
fn C.LCIDToLocaleName(u32, &u16, int, u32) int

fn system_language() string {
 mut buffer := [85]u16{}
 // Follow the Windows display language, independently of regional formats.
 if C.LCIDToLocaleName(u32(C.GetUserDefaultUILanguage()), &buffer[0], buffer.len, 0) > 0 {
  return unsafe { string_from_wide(&buffer[0]) }
 }
 return 'en'
}

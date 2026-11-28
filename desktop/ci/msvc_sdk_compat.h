#ifndef VHTTPD_MSVC_SDK_COMPAT_H
#define VHTTPD_MSVC_SDK_COMPAT_H
/* Load the SDK declarations before removing its RPC `small` macro. ui2's
 * metrics contain fields named `small`; expanding them to `char` corrupts
 * generated C declarations. Keep this hygiene in the host build boundary. */
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <windowsx.h>
#include <commctrl.h>
#include <oleacc.h>
#include <oleauto.h>
#include <shellapi.h>
#include <commdlg.h>
#include <shlobj.h>
#ifdef small
#undef small
#endif
#endif

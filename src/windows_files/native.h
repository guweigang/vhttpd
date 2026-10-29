#ifndef VHTTPD_WINDOWS_FILES_H
#define VHTTPD_WINDOWS_FILES_H
#include <windows.h>
#include <stdint.h>
#include <io.h>
#include <fcntl.h>
#include <errno.h>
#include <stdlib.h>
#include <stdio.h>
#define VH_O_WRONLY 1
#define VH_O_RDWR 2
#define VH_O_CREAT 4
#define VH_O_EXCL 8
#define VH_O_APPEND 16
#define VH_O_CLOEXEC 0
#define VH_O_NOFOLLOW 0
#define VH_LOCK_SH 1
#define VH_LOCK_EX 2
#define VH_LOCK_NB 4
#define VH_LOCK_UN 8
static wchar_t *vh_wide(const char *s) {
 int n=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,s,-1,NULL,0);
 if (!n) { errno=EINVAL; return NULL; }
 wchar_t *w=(wchar_t*)malloc(n*sizeof(wchar_t));
 if (!w) { errno=ENOMEM; return NULL; }
 MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,s,-1,w,n); return w;
}
static HANDLE vh_handle(int64_t fd) { return (HANDLE)_get_osfhandle((int)fd); }
static int vh_regular(HANDLE h) {
 BY_HANDLE_FILE_INFORMATION i;
 return GetFileType(h)==FILE_TYPE_DISK && GetFileInformationByHandle(h,&i) && !(i.dwFileAttributes&(FILE_ATTRIBUTE_DIRECTORY|FILE_ATTRIBUTE_REPARSE_POINT));
}
static int vh_open(const char *path,int flags,...) {
 wchar_t *w=vh_wide(path); if(!w)return -1;
 DWORD access=(flags&VH_O_RDWR)?(GENERIC_READ|GENERIC_WRITE):GENERIC_WRITE;
 HANDLE h=CreateFileW(w,access|DELETE,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,
 (flags&VH_O_EXCL)?CREATE_NEW:((flags&VH_O_CREAT)?OPEN_ALWAYS:OPEN_EXISTING),FILE_FLAG_OPEN_REPARSE_POINT|FILE_FLAG_BACKUP_SEMANTICS,NULL);
 free(w);
 if(h==INVALID_HANDLE_VALUE){errno=EACCES;return -1;}
 if(!vh_regular(h)){CloseHandle(h);errno=EINVAL;return -1;}
 int fd=_open_osfhandle((intptr_t)h,_O_BINARY|_O_NOINHERIT|((flags&VH_O_RDWR)?_O_RDWR:_O_WRONLY));
 if(fd<0)CloseHandle(h);
 return fd;
}
static uint64_t vh_dev(int64_t fd) { BY_HANDLE_FILE_INFORMATION i; return GetFileInformationByHandle(vh_handle(fd),&i)?i.dwVolumeSerialNumber:0; }
static uint64_t vh_ino(int64_t fd) { BY_HANDLE_FILE_INFORMATION i; return GetFileInformationByHandle(vh_handle(fd),&i)?(((uint64_t)i.nFileIndexHigh<<32)|i.nFileIndexLow):0; }
static int vh_matches(const char *path,uint64_t dev,uint64_t ino) {
 wchar_t *w=vh_wide(path);if(!w)return 0;
 HANDLE h=CreateFileW(w,FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT|FILE_FLAG_BACKUP_SEMANTICS,NULL);free(w);
 if(h==INVALID_HANDLE_VALUE)return 0;
 BY_HANDLE_FILE_INFORMATION i; int ok=vh_regular(h)&&GetFileInformationByHandle(h,&i)&&i.dwVolumeSerialNumber==dev&&(((uint64_t)i.nFileIndexHigh<<32)|i.nFileIndexLow)==ino;
 CloseHandle(h);return ok;
}
static int vh_open_dir(const char *path){
 wchar_t *w=vh_wide(path);if(!w)return -1;
 HANDLE h=CreateFileW(w,FILE_READ_ATTRIBUTES|DELETE,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT|FILE_FLAG_BACKUP_SEMANTICS,NULL);free(w);
 if(h==INVALID_HANDLE_VALUE)return -1;
 BY_HANDLE_FILE_INFORMATION i;
 if(!GetFileInformationByHandle(h,&i)||!(i.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY)||(i.dwFileAttributes&FILE_ATTRIBUTE_REPARSE_POINT)){CloseHandle(h);return -1;}
 int fd=_open_osfhandle((intptr_t)h,_O_RDONLY|_O_BINARY|_O_NOINHERIT);if(fd<0)CloseHandle(h);return fd;
}
static int vh_matches_dir(const char *path,uint64_t dev,uint64_t ino){
 int fd=vh_open_dir(path);if(fd<0)return 0;int ok=vh_dev(fd)==dev&&vh_ino(fd)==ino;_close(fd);return ok;
}
static int vh_flock(int64_t fd,int flags) {
 OVERLAPPED o={0};HANDLE h=vh_handle(fd);BOOL ok;
 if(flags&VH_LOCK_UN)ok=UnlockFileEx(h,0,MAXDWORD,MAXDWORD,&o);
 else ok=LockFileEx(h,((flags&VH_LOCK_EX)?LOCKFILE_EXCLUSIVE_LOCK:0)|((flags&VH_LOCK_NB)?LOCKFILE_FAIL_IMMEDIATELY:0),0,MAXDWORD,MAXDWORD,&o);
 if(!ok){errno=EACCES;return -1;}return 0;
}
static int64_t vh_write(int64_t fd,const void *data,uint64_t len) { return _write((int)fd,data,(unsigned int)(len>1048576?1048576:len)); }
static int vh_close(int64_t fd){return _close((int)fd);}
static int vh_fsync(int64_t fd){return FlushFileBuffers(vh_handle(fd))?0:-1;}
static int64_t vh_lseek(int64_t fd,int64_t offset,int origin){return _lseeki64((int)fd,offset,origin);}
static int vh_ftruncate(int64_t fd,uint64_t length){return _chsize_s((int)fd,length)?-1:0;}
// MoveFileEx without COPY_ALLOWED is an exact-path, same-volume replacement.
// Preserve the old target's DACL, including its inheritance protection.
static int vh_rename(const char *source,const char *target) {
 wchar_t *s=vh_wide(source),*t=vh_wide(target);if(!s||!t){free(s);free(t);return -1;}
 DWORD attr=GetFileAttributesW(t);BOOL ok=FALSE;
 if(attr!=INVALID_FILE_ATTRIBUTES){
  if(attr&(FILE_ATTRIBUTE_DIRECTORY|FILE_ATTRIBUTE_REPARSE_POINT))goto done;
  DWORD n=0;GetFileSecurityW(t,DACL_SECURITY_INFORMATION,NULL,0,&n);
  if(!n)goto done;
  PSECURITY_DESCRIPTOR sd=(PSECURITY_DESCRIPTOR)malloc(n);if(!sd)goto done;
  SECURITY_DESCRIPTOR_CONTROL ctrl;DWORD rev;
  ok=GetFileSecurityW(t,DACL_SECURITY_INFORMATION,sd,n,&n)&&GetSecurityDescriptorControl(sd,&ctrl,&rev);
  if(ok)ok=SetFileSecurityW(s,DACL_SECURITY_INFORMATION|((ctrl&SE_DACL_PROTECTED)?PROTECTED_DACL_SECURITY_INFORMATION:UNPROTECTED_DACL_SECURITY_INFORMATION),sd);
  free(sd);if(!ok)goto done;
 }
 ok=MoveFileExW(s,t,MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH);
 done:free(s);free(t);if(!ok){errno=EACCES;return -1;}return 0;
}
static void vh_remove_owned(int64_t fd,const char *path,uint64_t dev,uint64_t ino){
 if(vh_matches(path,dev,ino)){FILE_DISPOSITION_INFO d={TRUE};SetFileInformationByHandle(vh_handle(fd),FileDispositionInfo,&d,sizeof(d));}
}
#endif

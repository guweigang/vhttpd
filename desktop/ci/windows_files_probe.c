#include "../../src/windows_files/native.h"
#include <direct.h>
#include <string.h>
static void require(int ok, const char *step) {
 if (!ok) { fprintf(stderr,"FAIL %s: Win32=%lu CRT=%d\n",step,GetLastError(),errno);exit(1); }
}
static int stage(const char *path,const char *value) {
 int fd=vh_open(path,VH_O_CREAT|VH_O_EXCL|VH_O_WRONLY,0600);
 require(fd>=0,path);
 require(vh_write(fd,value,strlen(value))==(int64_t)strlen(value),"write");
 require(vh_fsync(fd)==0,"flush");return fd;
}
static void contents(const char *path,const char *expected) {
 wchar_t *w=vh_wide(path);HANDLE h=CreateFileW(w,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,0,NULL);free(w);
 require(h!=INVALID_HANDLE_VALUE,"read open");char value[32]={0};DWORD n=0;
 require(ReadFile(h,value,31,&n,NULL),"read");CloseHandle(h);
 require(strcmp(value,expected)==0,"content");
}
int main(void) {
 char folder[80];snprintf(folder,sizeof(folder),"vhttpd-native-files-%lu",GetCurrentProcessId());
 require(_mkdir(folder)==0,"mkdir");require(SetCurrentDirectoryA(folder),"chdir");
 int a=stage("main.toml","old a"),b=stage("include.toml","old b");vh_close(a);vh_close(b);
 a=stage("main.tmp","new a");b=stage("include.tmp","new b");
 require(vh_rename("main.tmp","main.toml")==0,"publish main");
 require(vh_rename("include.tmp","include.toml")==0,"publish include");
 contents("main.toml","new a");contents("include.toml","new b");
 int ar=stage("main.restore","old a"),br=stage("include.restore","old b");
 FILE *reader=fopen("main.toml","rb");
 require(reader!=NULL,"CRT reader with retained owner");fclose(reader);
 contents("main.toml","new a");contents("include.toml","new b");
 vh_close(a);vh_close(b);
 require(vh_rename("include.restore","include.toml")==0,"rollback include after ownership transfer");
 require(vh_rename("main.restore","main.toml")==0,"rollback main after ownership transfer");
 contents("main.toml","old a");contents("include.toml","old b");
 vh_close(ar);vh_close(br);
 puts("PASS MSVC native publication and rollback with explicit ownership transfer");return 0;
}

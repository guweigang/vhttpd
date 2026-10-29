// GUI-subsystem helper: preserve the inherited SSH reply pipe. V's current
// GUI entrypoint reopens stdout as CON/NUL, so this boundary uses Win32 I/O.
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <shellapi.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <ctype.h>

static int send_all(SOCKET s, const char *p, int n) {
 while(n>0){int w=send(s,p,n,0);if(w<=0)return 0;p+=w;n-=w;}return 1;
}
static int write_all(HANDLE h,const char *p,DWORD n){
 while(n){DWORD w=0;if(!WriteFile(h,p,n,&w,NULL)||!w)return 0;p+=w;n-=w;}return 1;
}
static char *environment_utf8(const wchar_t *name){
 DWORD n=GetEnvironmentVariableW(name,NULL,0);if(!n||n>32768)return NULL;
 wchar_t *w=calloc(n,sizeof(wchar_t));if(!w)return NULL;
 if(!GetEnvironmentVariableW(name,w,n)){free(w);return NULL;}
 int bytes=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,w,-1,NULL,0,NULL,NULL);
 char *value=bytes?malloc(bytes):NULL;
 if(value)WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,w,-1,value,bytes,NULL,NULL);
 SecureZeroMemory(w,n*sizeof(wchar_t));free(w);return value;
}
static int run_helper(const wchar_t *prompt_w){
 int result=1;SOCKET channel=INVALID_SOCKET;WSADATA wsa;int started=0;
 char *address=NULL,*capability=NULL,*prompt=NULL,*request=NULL;
 char reply[4098]={0};
 address=environment_utf8(L"VHTTPD_SSH_ASKPASS_SOCKET");
 capability=environment_utf8(L"VHTTPD_SSH_ASKPASS_CAPABILITY");
 if(!address||!capability||strncmp(address,"tcp://127.0.0.1:",16)||strlen(capability)!=64)goto done;
 for(int i=0;i<64;i++)if(!isxdigit((unsigned char)capability[i]))goto done;
 char *end=NULL;long port=strtol(address+16,&end,10);
 if(!end||*end||port<1||port>65535)goto done;
 int bytes=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,prompt_w,-1,NULL,0,NULL,NULL);
 if(bytes<2||bytes>16000)goto done;
 prompt=malloc(bytes);if(!prompt)goto done;
 if(!WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,prompt_w,-1,prompt,bytes,NULL,NULL))goto done;
 int confirmation=strstr(prompt,"Are you sure you want to continue connecting")&&strstr(prompt,"SHA256:");
 if(!confirmation){
  size_t n=strlen(prompt);while(n&&isspace((unsigned char)prompt[n-1]))n--;
  const char suffix[]="password:";
  if(n<sizeof(suffix)-1)goto done;
  for(size_t i=0;i<sizeof(suffix)-1;i++)if(tolower((unsigned char)prompt[n-(sizeof(suffix)-1)+i])!=suffix[i])goto done;
 }
 request=calloc(1,100000);if(!request)goto done;
 int used=snprintf(request,100000,"%s\n{\"kind\":\"%s\",\"prompt\":\"",capability,confirmation?"host_key":"password");
 for(const unsigned char *p=(unsigned char*)prompt;*p;p++){
  if(*p=='"'||*p=='\\'){request[used++]='\\';request[used++]=(char)*p;}
  else if(*p<32){used+=snprintf(request+used,100000-used,"\\u%04x",*p);}
  else request[used++]=(char)*p;
 }
 request[used++]='"';request[used++]='}';request[used++]='\n';
 if(used>16450)goto done;
 if(WSAStartup(MAKEWORD(2,2),&wsa))goto done;started=1;
 channel=socket(AF_INET,SOCK_STREAM,IPPROTO_TCP);if(channel==INVALID_SOCKET)goto done;
 DWORD timeout=confirmation?11*60*1000:5000;
 setsockopt(channel,SOL_SOCKET,SO_RCVTIMEO,(const char*)&timeout,sizeof(timeout));
 setsockopt(channel,SOL_SOCKET,SO_SNDTIMEO,(const char*)&timeout,sizeof(timeout));
 struct sockaddr_in target={0};target.sin_family=AF_INET;target.sin_addr.s_addr=htonl(INADDR_LOOPBACK);target.sin_port=htons((unsigned short)port);
 if(connect(channel,(const struct sockaddr*)&target,sizeof(target)))goto done;
 if(!send_all(channel,request,used))goto done;
 int length=0;
 while(length<4097){int n=recv(channel,reply+length,1,0);if(n!=1)goto done;if(reply[length]=='\n')break;if(reply[length]=='\r'||reply[length]=='\0')goto done;length++;}
 if(length<1||length>4096)goto done;
 reply[length]=0;
 if(confirmation&&strcmp(reply,"yes")&&strcmp(reply,"no"))goto done;
 reply[length++]='\n';
 HANDLE output=GetStdHandle(STD_OUTPUT_HANDLE);
 if(output==NULL||output==INVALID_HANDLE_VALUE)goto done;
 if(write_all(output,reply,(DWORD)length))result=0;
 done:
 if(channel!=INVALID_SOCKET)closesocket(channel);
 if(started)WSACleanup();
 SecureZeroMemory(reply,sizeof(reply));
 if(capability){SecureZeroMemory(capability,strlen(capability));free(capability);}
 if(request){SecureZeroMemory(request,100000);free(request);}
 free(prompt);free(address);return result;
}
int WINAPI wWinMain(HINSTANCE instance,HINSTANCE previous,LPWSTR command,int show){
 (void)instance;(void)previous;(void)command;(void)show;
 int count=0;wchar_t **args=CommandLineToArgvW(GetCommandLineW(),&count);
 if(!args)return 1;
 int result=count==2?run_helper(args[1]):1;
 LocalFree(args);return result;
}

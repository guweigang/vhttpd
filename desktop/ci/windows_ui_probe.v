module main

import os
import ui2

fn probe_window() ui2.Element {
 return ui2.Element{kind:.view, frame:ui2.rect(0,0,640,320), children:[
  ui2.Element{kind:.label, text:'vhttpd Windows · 原生 ui2 构建探测', frame:ui2.rect(20,20,590,35)},
  ui2.Element{kind:.text_field, id:'name', text:'Windows preview', frame:ui2.rect(20,75,590,36)},
  ui2.Element{kind:.text_field, id:'password', secure:true, placeholder:'密码输入框（仅用于构建探测）', frame:ui2.rect(20,125,590,36)},
  ui2.Element{kind:.button, id:'close', text:'关闭', frame:ui2.rect(20,190,100,36)},
 ]}
}

fn probe_event(id string) {
 if id == 'close' { ui2.quit() }
}

fn probe_ready(handle voidptr) {
 if handle == unsafe { nil } { panic('Windows native window handle missing') }
 marker := os.getenv('VHTTPD_WINDOWS_PROBE_READY')
 if marker != '' { os.write_file(marker, 'native HWND ready') or { panic(err) } }
}

fn main() {
 ui2.on_window_ready(probe_ready)
 ui2.run_window('vhttpd Windows ui2 probe',640,320,probe_window,probe_event)
}

module application_logs

import json2 as json
import os
import time

fn log_test_directory() string {
 return os.join_path(os.temp_dir(),'vhttpd-app-log-files-${os.getpid()}-${time.sys_mono_now()}')
}

fn test_application_files_are_separate_and_history_survives_store_restart() ! {
 directory := log_test_directory()
 defer {os.rmdir_all(directory) or {}}
 mut first := &Store{}
 first.configure_directory(directory)!
 first.append(Scope{app_id:'wechat'},Record{source:'console',level:'info',message:'body-file'})
 first.append(Scope{app_id:'paseo'},Record{source:'console',level:'info',message:'paseo-file'})
 for app in ['wechat','paseo'] {
  path := first.snapshot(app,'',0,100).file
  assert os.is_file(path)
  rows := os.read_lines(path)!
  assert rows.len == 1
  assert json.decode[Record](rows[0])!.app_id == app
 }
 mut restarted := &Store{}
 restarted.configure_directory(directory)!
 body := restarted.snapshot('wechat','',0,100)
 assert body.records.len == 1 && body.records[0].message == 'body-file'
 assert body.storage_error == ''
 restarted.append(Scope{app_id:'wechat'},Record{source:'console',message:'after-restart'})
 after := restarted.snapshot('wechat','',0,100)
 assert after.records.len == 2 && after.records[1].id > after.records[0].id
 assert !os.read_file(after.file)!.contains('paseo-file')
}

fn test_rotation_has_fixed_byte_and_backup_bounds() ! {
 directory := log_test_directory()
 defer {os.rmdir_all(directory) or {}}
 mut store := &Store{}
 store.configure_directory(directory)!
 path := store.log_path('wechat')
 for i in 0..6 {
  os.write_file(path,' '.repeat(int(max_file_bytes)))!
  store.append(Scope{app_id:'wechat'},Record{source:'console',message:'rotation-${i}'})
 }
 assert os.file_size(path) < u64(max_file_bytes)
 for i in 1..backup_files+1 { assert os.is_file(path+'.'+i.str()) }
 assert !os.exists(path+'.4')
 assert store.snapshot('wechat','',0,100).storage_error == ''
}

fn test_application_names_cannot_escape_log_directory() ! {
 directory := log_test_directory()
 defer {os.rmdir_all(directory) or {}}
 mut store := &Store{}
 store.configure_directory(directory)!
 store.append(Scope{app_id:'../paseo'},Record{source:'console',message:'safe'})
 path := store.snapshot('../paseo','',0,100).file
 assert os.dir(path) == directory
 assert !os.file_name(path).contains('..')
 assert path != store.log_path('paseo')
}

fn test_restart_recovers_full_window_with_large_unicode_records() ! {
 directory := log_test_directory()
 defer {os.rmdir_all(directory) or {}}
 mut first := &Store{}
 first.configure_directory(directory)!
 for i in 0..records_per_application {
  first.append(Scope{app_id:'wechat'},Record{source:'console',message:'${i} '+ '测'.repeat(1360),request_id:'x'.repeat(256)})
 }
 before := first.snapshot('wechat','',0,records_per_application)
 assert os.file_size(before.file) > 2097152
 mut restarted := &Store{}
 restarted.configure_directory(directory)!
 after := restarted.snapshot('wechat','',0,records_per_application)
 assert after.records.len == records_per_application
 assert after.records[0].id == before.records[0].id
 assert after.records.last().id == before.records.last().id
}

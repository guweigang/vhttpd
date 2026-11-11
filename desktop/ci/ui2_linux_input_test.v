module ui2

import gg
import os

fn input_fixture(value string, readonly bool, secure bool, multiline bool) {
 g_text_values = map[string]string{}
 g_text_editors = map[string]TextEditor{}
 g_focused_field = 'input'
 g_text_kinds = {'input': if multiline { Kind.text_area } else { Kind.text_field }}
 g_text_readonly = {'input': readonly}
 g_text_secure = {'input': secure}
 g_hit_targets = [HitTarget{id:'input', text_field:!multiline, text_area:multiline}]
 replace_text_value('input', value)
 replace_text_editor('input', text_editor(value.clone()))
}

fn test_shortcuts_preserve_selection_and_unicode_input() {
 ctrl := u32(gg.Modifier.ctrl)
 input_fixture('原始 abc', false, false, false)
 handle_key_down(.a, ctrl)
 handle_char_input(`a`, ctrl)
 assert text('input') == '原始 abc'
 assert !g_text_editors['input'].selection.collapsed()
 handle_char_input(`新`, 0)
 assert text('input') == '新'
 handle_char_input(`@`, ctrl | u32(gg.Modifier.alt))
 handle_char_input(`Z`, u32(gg.Modifier.shift))
 assert text('input') == '新@Z'
}

fn test_clipboard_selection_cut_paste_readonly_and_password() {
 assert clipboard_supported()
 ctrl := u32(gg.Modifier.ctrl)
 input_fixture('前 hello 后', false, false, false)
 mut editor := g_text_editors['input']
 editor.set_selection(2,7)
 replace_text_editor('input', editor)
 handle_key_down(.c, ctrl)
 handle_char_input(`c`, ctrl)
 assert clipboard_text() or { '' } == 'hello'
 assert text('input') == '前 hello 后'
 handle_key_down(.x, ctrl)
 handle_char_input(`x`, ctrl)
 assert text('input') == '前  后'
 handle_key_down(.v, ctrl)
 handle_char_input(`v`, ctrl)
 assert text('input') == '前 hello 后'
 assert set_clipboard_text('首行\n次行')
 input_fixture('', false, false, true)
 handle_key_down(.v, ctrl)
 assert text('input') == '首行\n次行'
 input_fixture('', false, false, false)
 handle_key_down(.v, ctrl)
 assert text('input') == '首行 次行'
 input_fixture('只读日志', true, false, true)
 handle_key_down(.a, ctrl)
 handle_key_down(.c, ctrl)
 assert clipboard_text() or { '' } == '只读日志'
 for key in [gg.KeyCode.x, .v, .backspace, .delete, .enter] { handle_key_down(key, ctrl) }
 handle_char_input(`x`, 0)
 assert text('input') == '只读日志'
 assert set_clipboard_text('session-only')
 input_fixture('private', false, true, false)
 handle_key_down(.a, ctrl)
 handle_key_down(.c, ctrl)
 handle_key_down(.x, ctrl)
 assert clipboard_text() or { '' } == 'session-only'
 assert text('input') == 'private'
 handle_key_down(.v, ctrl)
 assert text('input') == 'session-only'
 // Do not leave even synthetic credentials on the fixture clipboard.
 assert set_clipboard_text('')
 input_fixture('keep selected text', false, false, false)
 handle_key_down(.a, ctrl)
 handle_key_down(.v, ctrl)
 assert text('input') == 'keep selected text'
 original_path := os.getenv('PATH')
 os.setenv('PATH', '/ui2-fixture-no-clipboard-tools', true)
 defer { os.setenv('PATH', original_path, true) }
 handle_key_down(.x, ctrl)
 handle_key_down(.v, ctrl)
 assert text('input') == 'keep selected text'
}

__global input_fixture_host_key = ''

fn capture_input_fixture_host_key(key string) {
 input_fixture_host_key = key
 consume_key()
}

fn test_focused_field_passes_modified_return_to_workbench() {
 input_fixture('form value', false, false, false)
 input_fixture_host_key = ''
 on_key(capture_input_fixture_host_key)
 defer { on_key(KeyFn(unsafe { nil })) }
 app := &GgApp{}
 on_event(&gg.Event{typ: .key_down, key_code: .enter, modifiers: u32(gg.Modifier.ctrl)}, app)
 assert input_fixture_host_key == 'ctrl+enter'
 assert focused_id() == 'input'
 assert text('input') == 'form value'
}

fn test_clipboard_copy_waits_for_wayland_helper_result() ! {
 directory := os.join_path(os.temp_dir(), 'workbench-clipboard-test-${os.getpid()}')
 os.mkdir(directory, mode: 0o700)!
 defer { os.rmdir_all(directory) or {} }
 tool := os.join_path(directory, 'wl-copy')
 output := os.join_path(directory, 'copied')
 os.write_file(tool, '#!/bin/sh\nsleep 0.1\ncat > "$1.tmp" && mv "$1.tmp" "$1"\n')!
 os.chmod(tool, 0o700)!
 assert native_clipboard_write([tool, output], '后台剪贴板')
 assert os.read_file(output)! == '后台剪贴板'
 os.write_file(tool, '#!/bin/sh\nexit 1\n')!
 assert !native_clipboard_write([tool, output], 'failed copy')
}

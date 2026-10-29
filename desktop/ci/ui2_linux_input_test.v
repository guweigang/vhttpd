module ui2

import gg

fn input_fixture(value string, readonly bool, secure bool, multiline bool) {
 g_text_values = map[string]string{}
 g_text_editors = map[string]TextEditor{}
 g_focused_field = 'input'
 g_hit_targets = [HitTarget{id:'input', text_field:!multiline, text_area:multiline, readonly:readonly, secure:secure}]
 replace_text_value('input', value)
 replace_text_editor('input', text_editor(value.clone()))
}

fn test_shortcuts_preserve_selection_and_unicode_input() {
 ctrl := u32(gg.Modifier.ctrl)
 input_fixture('原始 abc', false, false, false)
 handle_key_down(.a, ctrl)
 handle_char_event(`a`, ctrl)
 assert text('input') == '原始 abc'
 assert !g_text_editors['input'].selection.collapsed()
 handle_char_event(`新`, 0)
 assert text('input') == '新'
 handle_char_event(`@`, ctrl | u32(gg.Modifier.alt))
 handle_char_event(`Z`, u32(gg.Modifier.shift))
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
 handle_char_event(`c`, ctrl)
 assert clipboard_text() or { '' } == 'hello'
 assert text('input') == '前 hello 后'
 handle_key_down(.x, ctrl)
 handle_char_event(`x`, ctrl)
 assert text('input') == '前  后'
 handle_key_down(.v, ctrl)
 handle_char_event(`v`, ctrl)
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
 handle_char_event(`x`, 0)
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
}

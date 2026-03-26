module main

import jsonutils
fn test_json_utils_top_level_key_simple() {
    s := '{"id":1, "method":"m", "nested": {"id": 5}}'
    // debug prints to observe function return values
    println('jsonutils.has_top_level_key(id) => ${jsonutils.has_top_level_key(s, "id")}')
    println('jsonutils.has_top_level_key(method) => ${jsonutils.has_top_level_key(s, "method")}')
    println('jsonutils.has_top_level_key(nonexist) => ${jsonutils.has_top_level_key(s, "nonexist")}')
    assert jsonutils.has_top_level_key(s, 'id')
    assert jsonutils.has_top_level_key(s, 'method')
    assert !jsonutils.has_top_level_key(s, 'nonexist')
}

fn test_json_utils_escaped_quotes_and_braces() {
    // key inside a string should not be treated as a key
    s := '{"a":"value with \"{\" and id inside", "id": 7}'
    assert jsonutils.has_top_level_key(s, 'id')
    assert !jsonutils.has_top_level_key(s, '{')
}

fn test_json_utils_multiple_keys() {
    s := '{"thread":{"id":"t1"}, "result": {"ok":true}}'
    println('jsonutils.has_any_top_level_key(result,method) => ${jsonutils.has_any_top_level_key(s, ["result","method"])}')
    println('jsonutils.has_any_top_level_key(id,threadId) => ${jsonutils.has_any_top_level_key(s, ["id","threadId"])}')
    assert jsonutils.has_any_top_level_key(s, ['result','method'])
    assert !jsonutils.has_any_top_level_key(s, ['id','threadId'])
}

fn test_json_utils_edge_cases() {
    // escaped quotes and backslashes
    s1 := '{"k\\"ey":"val","normal":1}'
    assert jsonutils.has_top_level_key(s1, 'k\"ey')
    assert jsonutils.has_top_level_key(s1, 'normal')

    // unicode keys and spaces
    s2 := '{"空键": true, "with space": 2}'
    assert jsonutils.has_top_level_key(s2, '空键')
    assert jsonutils.has_top_level_key(s2, 'with space')

    // nested arrays containing braces and quotes
    s3 := '{"arr": ["{notakey}", {"nested":1}], "result": 5}'
    assert jsonutils.has_top_level_key(s3, 'arr')
    assert jsonutils.has_top_level_key(s3, 'result')

    // values with quoted colons or braces should not confuse parser
    s4 := '{"a":"value: with colon", "b":"braces {} inside", "c":3}'
    assert jsonutils.has_top_level_key(s4, 'a')
    assert jsonutils.has_top_level_key(s4, 'b')
    assert jsonutils.has_top_level_key(s4, 'c')

    // unicode escape in key should match decoded lookup key
    s5 := '{"\\u7a7a\\u952e": true, "plain": 1}'
    assert jsonutils.has_top_level_key(s5, '空键')
    assert jsonutils.has_top_level_key(s5, 'plain')
}

fn test_main_wrapper_matches_jsonutils() {
    s := '{"\\u7a7a\\u952e": true, "method": "ping"}'
    assert vhttpd_has_top_level_key(s, '空键')
    assert vhttpd_has_any_top_level_key(s, ['id', 'method'])
}

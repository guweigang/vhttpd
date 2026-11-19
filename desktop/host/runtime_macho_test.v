module host

fn macho_test_u32(mut data []u8, offset int, value u32) {
	for i in 0 .. 4 { data[offset + i] = u8(value >> (i * 8)) }
}

fn test_macho_checks_arm64_macos_minimum_and_safe_load_commands() ! {
	mut data := []u8{len: 56}
	macho_test_u32(mut data, 0, 0xfeedfacf)
	macho_test_u32(mut data, 4, 0x0100000c)
	macho_test_u32(mut data, 12, 2)
	macho_test_u32(mut data, 16, 1)
	macho_test_u32(mut data, 20, 24)
	macho_test_u32(mut data, 32, 0x32)
	macho_test_u32(mut data, 36, 24)
	macho_test_u32(mut data, 40, 1)
	macho_test_u32(mut data, 44, 0x000f0000)
	assert inspect_runtime_macho(data)!.minimum == 0x000f0000
	for offset in [0, 4, 16, 20, 36, 40, 44] {
		mut invalid := data.clone()
		macho_test_u32(mut invalid, offset, 0xffffffff)
		inspect_runtime_macho(invalid) or { continue }
		assert false, 'invalid Mach-O accepted'
	}
	mut dylib := []u8{len: 96}
	copy(mut dylib, data)
	macho_test_u32(mut dylib, 16, 2)
	macho_test_u32(mut dylib, 20, 64)
	macho_test_u32(mut dylib, 56, 0xc)
	macho_test_u32(mut dylib, 60, 40)
	macho_test_u32(mut dylib, 64, 24)
	copy(mut dylib[80..], '/usr/lib/a'.bytes())
	assert inspect_runtime_macho(dylib)!.dependencies == ['/usr/lib/a']
	macho_test_u32(mut dylib, 64, 40)
	inspect_runtime_macho(dylib) or { return }
	assert false, 'out-of-command dylib name accepted'
}

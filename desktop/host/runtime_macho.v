module host

struct RuntimeMachO {
	dependencies []string
	minimum      u32
	filetype     u32
}

fn macho_u32(data []u8, offset int) !u32 {
	if offset < 0 || offset > data.len - 4 { return error('Mach-O 文件不完整。') }
	return u32(data[offset]) | (u32(data[offset + 1]) << 8) | (u32(data[offset + 2]) << 16) | (u32(data[offset + 3]) << 24)
}

// No lipo/otool: /usr/bin versions can be Xcode command-line-tool shims.
// Official packages contain thin macOS arm64 executables and dylibs.
fn inspect_runtime_macho(data []u8) !RuntimeMachO {
	if data.len < 32 || macho_u32(data, 0)! != 0xfeedfacf || macho_u32(data, 4)! != 0x0100000c {
		return error('运行包架构不匹配，需要 macOS Apple Silicon arm64。')
	}
	count := macho_u32(data, 16)!
	size := macho_u32(data, 20)!
	if count > 65536 || u64(size) > u64(data.len - 32) { return error('Mach-O 命令表无效。') }
	end := 32 + int(size)
	mut offset := 32
	mut dependencies := []string{}
	mut minimum := u32(0)
	for _ in 0 .. int(count) {
		if offset > end - 8 { return error('Mach-O 命令表不完整。') }
		command := macho_u32(data, offset)!
		command_size := macho_u32(data, offset + 4)!
		if command_size < 8 || u64(command_size) > u64(end - offset) {
			return error('Mach-O 命令长度无效。')
		}
		next := offset + int(command_size)
		if command in [u32(0xc), 0x80000018, 0x8000001f, 0x20, 0x80000023] {
			if command_size < 24 { return error('动态库命令不完整。') }
			name_offset := macho_u32(data, offset + 8)!
			if name_offset < 24 || name_offset >= command_size {
				return error('动态库名称偏移无效。')
			}
			start := offset + int(name_offset)
			mut finish := start
			for finish < next && data[finish] != 0 { finish++ }
			if finish == next || finish == start || finish - start > 4096 {
				return error('动态库名称无效。')
			}
			dependencies << data[start..finish].bytestr()
		} else if command == 0x32 {
			if command_size < 24 || macho_u32(data, offset + 8)! != 1 {
				return error('运行包目标平台不是 macOS。')
			}
			minimum = macho_u32(data, offset + 12)!
		} else if command == 0x24 {
			if command_size < 16 { return error('最低系统版本命令无效。') }
			minimum = macho_u32(data, offset + 8)!
		}
		offset = next
	}
	if offset != end || minimum == 0 || minimum > 0x000f0000 {
		return error('运行包需要高于 macOS 15.0 的系统，或最低版本信息无效。')
	}
	filetype := macho_u32(data, 12)!
	if filetype !in [u32(2), 6] {
		return error('运行包包含不受支持的 Mach-O 文件类型。')
	}
	return RuntimeMachO{ dependencies: dependencies, minimum: minimum, filetype: filetype }
}

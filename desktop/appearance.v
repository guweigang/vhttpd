module main

import host
import os
import time
import ui2

const workbench_primary_blue = u32(0x2563eb)

struct WorkbenchColors {
	paper               u32 = 0xffffff
	sidebar             u32 = 0xf4f7fb
	ink                 u32 = 0x17202a
	muted               u32 = 0x627184
	line                u32 = 0xe0e7f0
	green               u32 = 0x2c6149
	accent              u32 = workbench_primary_blue
	primary_background  u32 = workbench_primary_blue
	primary_foreground  u32 = 0xffffff
	soft_accent         u32 = 0xeaf1ff
	focus               u32 = 0x1e40af
	disabled_background u32 = 0xe9edf2
	disabled_foreground u32 = 0x596575
	warning             u32 = 0x925b10
	danger              u32 = 0xb42318
	good_background     u32 = 0xedf7f0
	warning_background  u32 = 0xfff8eb
	danger_background   u32 = 0xfff2f0
}

// Rendering helpers share a palette owned by the UI thread.
__global workbench_colors = WorkbenchColors{}
__global workbench_component_theme = ui2.ComponentTheme{}
__global workbench_appearance_mode = ui2.ComponentThemeMode.system
__global workbench_system_appearance = ui2.SystemAppearance.unknown
__global workbench_appearance_checked_at = u64(0)

fn dark_workbench_colors(theme ui2.ComponentTheme) WorkbenchColors {
	return WorkbenchColors{
		paper:               theme.background
		sidebar:             0x282828
		ink:                 theme.foreground
		muted:               theme.muted_foreground
		line:                theme.border
		green:               theme.success
		accent:              theme.primary
		soft_accent:         0x2b3848
		focus:               theme.primary
		disabled_background: theme.muted
		disabled_foreground: theme.muted_foreground
		warning:             theme.warning
		danger:              theme.danger
		good_background:     0x1b382e
		warning_background:  0x3d3020
		danger_background:   0x422a32
	}
}

fn workbench_appearance_path() string {
	return os.join_path(host.workbench_data_dir(), 'appearance')
}

fn load_appearance(path string) ui2.ComponentThemeMode {
	value := os.read_file(path) or { return .system }
	return ui2.component_theme_mode_from_name(value) or { ui2.ComponentThemeMode.system }
}

fn save_appearance(path string, mode ui2.ComponentThemeMode) ! {
	os.mkdir_all(os.dir(path))!
	temporary := path + '.tmp-' + os.getpid().str()
	defer { os.rm(temporary) or {} }
	os.write_file(temporary, mode.str() + '\n')!
	os.mv(temporary, path)!
}

fn initialize_appearance() {
	set_workbench_appearance_mode(load_appearance(workbench_appearance_path()))
}

fn apply_workbench_appearance() {
	dark := ui2.component_theme_mode_is_dark(workbench_appearance_mode, workbench_system_appearance)
	base := ui2.component_theme(dark)
	workbench_component_theme = if dark {
		ui2.ComponentTheme{
			...base
			background:       0x202020
			foreground:       0xededed
			muted:            0x303030
			muted_foreground: 0xb9b9b9
			border:           0x484848
		}
	} else {
		base
	}
	workbench_colors = if dark {
		dark_workbench_colors(workbench_component_theme)
	} else {
		WorkbenchColors{}
	}
}

fn set_workbench_appearance_mode(mode ui2.ComponentThemeMode) {
	workbench_appearance_mode = mode
	if mode == .system {
		workbench_appearance_checked_at = time.sys_mono_now()
		workbench_system_appearance = ui2.system_appearance()
	}
	apply_workbench_appearance()
}

fn refresh_system_appearance() {
	if workbench_appearance_mode != .system { return }
	now := time.sys_mono_now()
	if workbench_appearance_checked_at != 0 && now - workbench_appearance_checked_at < 2_000_000_000 {
		return
	}
	workbench_appearance_checked_at = now
	appearance := ui2.system_appearance()
	if appearance != workbench_system_appearance {
		workbench_system_appearance = appearance
		apply_workbench_appearance()
	}
}

fn choose_workbench_appearance(mode ui2.ComponentThemeMode) {
	if mode == workbench_appearance_mode { return }
	save_appearance(workbench_appearance_path(), mode) or {
		ui_alert('无法保存外观设置', err.msg())
		return
	}
	set_workbench_appearance_mode(mode)
	$if macos {
		update_workbench_native_appearance()
	}
	ui2.refresh()
}

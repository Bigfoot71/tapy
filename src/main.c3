module main;

import raylib6;
import rlp;

const RLPApp APP @RLPExport("app") =
{
	.title        = "MyProject",
	.flags        = WINDOW_RESIZABLE | VSYNC_HINT,
	.window_w     = 1152,
	.window_h     = 648,
	.target_fps   = 60,
	.exit_key     = NONE,
	.log_level    = INFO,
	.audio_device = false,
};

fn void init(String[] args) @RLPExport("init")
{
}

fn void quit() @RLPExport("quit")
{
}

fn void tick(float dt) @RLPExport("tick")
{
	rl::clear_background(rl::DARKGRAY);
}

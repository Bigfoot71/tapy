module tapy;

import std::math;
import raylib6;
import raygui;
import rlp;

// ================================
// Constants
// ================================

const float ROW_H        = 26.0f;
const float GAP          = 6.0f;
const float MARGIN       = 12.0f;
const float CODE_PAD     = 8.0f;
const float CODE_GAP     = 4.0f;                        // extra space between two code lines
const float PREVIEW_HEAD = 24.0f;                       // preview title bar height
const float HINT_H       = 24.0f;                       // hint bar height
const float CHECKER_SIZE = 10.0f;                       // transparency checkerboard cell
const float CTRL_H       = 7.0f * ROW_H + 6.0f * GAP;   // 7 rows of controls

const float SIGMA_MIN    = 0.2f;
const float SIGMA_MAX    = 6.0f;
const float ZOOM_MIN     = 0.1f;                        // relative to "fit"
const float ZOOM_MAX     = 200.0f;
const float ZOOM_STEP    = 1.2f;

const int WEIGHT_TEXT_LEN = 32;

// ================================
// State
// ================================

// View of an image inside a preview panel
struct View
{
	Vec2 center; // image point (in texcoord) shown at the center of the panel
	float zoom;  // 1.0 = image fitted in the panel
}

struct Context
{
	// Kernel editor
	Kernel   kernel;
	int      radius_value;      // spinner value (may be mid-edit)
	bool     radius_editing;
	float    sigma;
	char[WEIGHT_TEXT_LEN] weight_text;
	bool     weight_editing;
	int      weight_index;      // tap being edited in the weight box

	// Generated GLSL (empty until "Generate")
	DString code;
	Vec2 code_scroll;

	// Images
	RLTexture2D       src;
	RLRenderTexture2D dst;
	RLShader          shader;
	bool              generated;   // dst holds a result
	bool              pending;     // run the convolution at the start of the next frame

	// Previews (0 = original, 1 = convolved)
	View[2]  views;
	int      pan;                  // preview being panned; -1 if none
}

Context ctx = {
	.radius_value = 1,
	.sigma        = 1.0f,
	.pan          = -1,
	.weight_index = -1,
};

struct Layout
{
	RLRectangle code;
	RLRectangle[2] previews;   // title bar included
	RLRectangle grid;          // square
	RLRectangle ctrl;
	RLRectangle hint;          // contextual help bar
}

// ================================
// App
// ================================

const RLPApp APP @RLPExport("app") =
{
	.title        = "tapy",
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
	rg::load_style_from_memory($embed("../embed/style_genesis.rgs"));

	ctx.code.init(mem);

	// Default kernel: 3x3 box blur
	ctx.kernel.radius   = 1;
	ctx.kernel.selected = -1;
	ctx.kernel.fill();
	ctx.kernel.uniform();

	reset_views();
	load_default_image();
}

fn void quit() @RLPExport("quit")
{
	free_shader();
	if (ctx.src.is_valid()) rl::unload_texture(ctx.src);
	if (ctx.dst.is_valid()) rl::unload_render_texture(ctx.dst);
	ctx.code.free();
}

fn void tick(float dt) @RLPExport("tick")
{
	static bool ui_was_locked;

	float w = (float)rl::get_screen_width();
	float h = (float)rl::get_screen_height();
	Layout l = compute_layout(w, h);

	// Update
	handle_drop();
	update_radius();
	if (ctx.pending)
	{
		run_convolution();
		ctx.pending = false;
	}
	update_views(l);
	update_grid(l.grid);

	// Lock the GUI while panning
	bool locked = ctx.pan >= 0 || (ui_was_locked && (rl::is_mouse_button_down(LEFT) || rl::is_mouse_button_released(LEFT)));
	ui_was_locked = locked;

	// Draw
	rl::clear_background(theme(RGGuiProperty.BACKGROUND_COLOR));

	if (locked) rg::lock();

	draw_code(l.code);
	draw_preview(0, l.previews[0]);
	draw_preview(1, l.previews[1]);
	draw_grid(l.grid);
	draw_controls(l.ctrl);
	draw_hint(l);

	if (locked) rg::unlock();
}

// ================================
// Layout
// ================================

fn Layout compute_layout(float w, float h)
{
	// Left column: grid, controls, code
	float col_w = math::clamp(w * 0.3f, 260.0f, 380.0f);
	col_w = math::min(col_w, math::max(w - 300.0f, 160.0f));

	float side = math::max(math::min(col_w, h * 0.42f), 60.0f);
	float cy   = MARGIN + side + MARGIN;       // controls top
	float coy  = cy + CTRL_H + MARGIN;         // code top

	// Right area: previews
	float rx = col_w + 2.0f * MARGIN;
	float rw = math::max(w - rx - MARGIN, 120.0f);
	float rh = math::max(h - 2.0f * MARGIN, 100.0f);

	float iw = 1.0f;
	float ih = 1.0f;
	if (ctx.src.is_valid())
	{
		iw = (float)ctx.src.width;
		ih = (float)ctx.src.height;
	}

	// Side by side or stacked
	float half_w  = math::max((rw - GAP) * 0.5f, 1.0f);
	float half_h  = math::max((rh - GAP) * 0.5f, PREVIEW_HEAD + 1.0f);
	float s_side  = math::min(half_w / iw, math::max(rh - PREVIEW_HEAD, 1.0f) / ih);
	float s_stack = math::min(rw / iw, (half_h - PREVIEW_HEAD) / ih);

	Layout l;
	l.grid = { MARGIN + (col_w - side) * 0.5f, MARGIN, side, side };
	l.ctrl = { MARGIN, cy, col_w, CTRL_H };
	l.hint = { MARGIN, h - MARGIN - HINT_H, col_w, HINT_H };
	l.code = { MARGIN, coy, col_w, math::max(l.hint.y - GAP - coy, 60.0f) };

	if (s_side >= s_stack)
	{
		l.previews[0] = { rx, MARGIN, half_w, rh };
		l.previews[1] = { rx + half_w + GAP, MARGIN, half_w, rh };
	}
	else
	{
		l.previews[0] = { rx, MARGIN, rw, half_h };
		l.previews[1] = { rx, MARGIN + half_h + GAP, rw, half_h };
	}

	// Snap to whole pixels
	l.code        = snap(l.code);
	l.grid        = snap(l.grid);
	l.ctrl        = snap(l.ctrl);
	l.hint        = snap(l.hint);
	l.previews[0] = snap(l.previews[0]);
	l.previews[1] = snap(l.previews[1]);
	return l;
}

fn RLRectangle snap(RLRectangle r)
{
	return { math::round(r.x), math::round(r.y), math::round(r.width), math::round(r.height) };
}

// ================================
// Helpers
// ================================

fn RLColor theme(RGGuiProperty property)
{
	return rl::get_color((uint)rg::get_style(RGGuiControl.DEFAULT, property));
}

fn bool in_rect(Vec2 p, RLRectangle r)
{
	return p.x >= r.x && p.y >= r.y && p.x <= r.x + r.width && p.y <= r.y + r.height;
}

fn void draw_centered(RLRectangle r, String text) => @pool()
{
	RLFont font   = rg::get_font();
	float size    = (float)rg::get_style(RGGuiControl.DEFAULT, RGGuiProperty.TEXT_SIZE);
	float spacing = (float)rg::get_style(RGGuiControl.DEFAULT, RGGuiProperty.TEXT_SPACING);
	ZString z     = text.zstr_tcopy();
	Vec2 t        = rl::measure_text_ex(font, z, size, spacing);

	rl::draw_text_ex(font, z, { math::round(r.x + (r.width - t.x) * 0.5f), math::round(r.y + (r.height - t.y) * 0.5f) }, size, spacing, theme(RGGuiProperty.TEXT_COLOR_NORMAL));
}

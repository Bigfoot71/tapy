module tapy;

import std::math;
import raylib6;
import raygui;
import rlp;

// ================================
// Images
// ================================

fn void load_default_image()
{
	char[] data = $embed("../embed/sample.png");
	set_source(rl::load_image_from_memory(".png", data.ptr, (int)data.len));
}

fn void handle_drop()
{
	if (!rl::is_file_dropped()) return;
	RLFilePathList files = rl::load_dropped_files();
	defer rl::unload_dropped_files(files);
	if (files.count > 0) set_source(rl::load_image(files.paths[0]));
}

// Takes ownership of img
fn void set_source(RLImage img)
{
	if (!img.is_valid()) return;
	RLTexture2D tex = rl::load_texture_from_image(img);
	rl::unload_image(img);
	if (!tex.is_valid()) return;

	if (ctx.src.is_valid()) rl::unload_texture(ctx.src);
	if (ctx.dst.is_valid()) rl::unload_render_texture(ctx.dst);

	ctx.src = tex;
	ctx.src.set_wrap(RLTextureWrap.CLAMP); // required for NPOT textures on GLES2
	ctx.dst = rl::load_render_texture(tex.width, tex.height);
	ctx.dst.texture.set_wrap(RLTextureWrap.CLAMP);

	ctx.generated = false;
	reset_views();

	// Re-apply the current code to the new image
	ctx.pending = ctx.code.len() > 0;
}

// ================================
// Convolution
// ================================

fn void generate()
{
	ctx.code.clear();
	ctx.kernel.to_glsl(&ctx.code);
	ctx.code_scroll = { 0.0f, 0.0f };
	ctx.code_linear = ctx.kernel.sub > 1;
	ctx.pending = true;
}

fn void free_shader()
{
	if (ctx.shader.is_valid()) rl::unload_shader(ctx.shader);
	ctx.shader = {};
}

// Compile the generated code and render the result
// NOTE: Should be called outside of any UI drawing
fn void run_convolution() => @pool()
{
	if (!ctx.src.is_valid()) return;

	free_shader();

	DString frag = dstring::temp();
	frag.append(CONVOLUTION_FRAG);
	frag.append(ctx.code.str_view());
	ctx.shader = rlp::load_shader_from_memory(CONVOLUTION_VERT, frag.str_view());

	// A failed compilation falls back to raylib's default shader...
	if (!ctx.shader.is_valid() || ctx.shader.id == rl::gl_get_shader_id_default())
	{
		ctx.shader = {};
		ctx.generated = false;
		return;
	}

	Vec2 texel = { 1.0f / (float)ctx.src.width, 1.0f / (float)ctx.src.height };
	ctx.shader.set_value(ctx.shader.get_location("texelSize"), &texel, RLShaderUniformDataType.VEC2);

	ctx.src.set_filter(ctx.code_linear ? RLTextureFilter.BILINEAR : RLTextureFilter.POINT);

	rl::gl_set_blend_factors(1, 0, 0x8006); // GL_ONE, GL_ZERO, GL_FUNC_ADD
	rl::@texture_mode(ctx.dst)
	{
		rl::clear_background(rl::BLANK);
		rl::@blend_mode(RLBlendMode.CUSTOM)
		{
			rl::@shader_mode(ctx.shader)
			{
				rl::draw_texture(ctx.src, 0, 0, rl::WHITE);
			};
		};
	};

	ctx.generated = true;
}

// ================================
// Views (zoom / pan)
// ================================

fn void reset_view(int i)
{
	ctx.views[i].center = { 0.5f, 0.5f };
	ctx.views[i].zoom   = 1.0f;
}

fn void reset_views()
{
	reset_view(0);
	reset_view(1);
}

fn RLRectangle preview_area(RLRectangle r)
{
	return { r.x, r.y + PREVIEW_HEAD, r.width, math::max(r.height - PREVIEW_HEAD, 1.0f) };
}

fn RLTexture2D preview_texture(int i)
{
	if (i == 0) return ctx.src;
	if (ctx.generated) return ctx.dst.texture;
	return {};
}

// Screen pixels per image pixel
fn float view_scale(View* v, RLRectangle area, RLTexture2D tex)
{
	float fit = math::min(area.width / (float)tex.width, area.height / (float)tex.height);
	return fit * v.zoom;
}

// Where the whole image lands on screen
fn RLRectangle view_dest(View* v, RLRectangle area, RLTexture2D tex)
{
	float s = view_scale(v, area, tex);
	float w = (float)tex.width * s;
	float h = (float)tex.height * s;
	float cx = area.x + area.width * 0.5f;
	float cy = area.y + area.height * 0.5f;
	return { cx - v.center.x * w, cy - v.center.y * h, w, h };
}

fn void view_clamp(View* v)
{
	v.center.x = math::clamp(v.center.x, 0.0f, 1.0f);
	v.center.y = math::clamp(v.center.y, 0.0f, 1.0f);
}

// Zoom around the mouse
fn void view_zoom(View* v, RLRectangle area, RLTexture2D tex, Vec2 m, float wheel)
{
	RLRectangle d = view_dest(v, area, tex);
	float u = (m.x - d.x) / d.width;
	float t = (m.y - d.y) / d.height;

	v.zoom = math::clamp(v.zoom * math::pow(ZOOM_STEP, wheel), ZOOM_MIN, ZOOM_MAX);

	d = view_dest(v, area, tex);
	v.center = {
		u - (m.x - (area.x + area.width * 0.5f)) / d.width,
		t - (m.y - (area.y + area.height * 0.5f)) / d.height,
	};
	view_clamp(v);
}

fn void view_pan(View* v, RLRectangle area, RLTexture2D tex, Vec2 delta)
{
	RLRectangle d = view_dest(v, area, tex);
	v.center.x -= delta.x / d.width;
	v.center.y -= delta.y / d.height;
	view_clamp(v);
}

// Each preview has its own independent view
fn void update_views(Layout l)
{
	Vec2  m     = rl::get_mouse_position();
	Vec2  delta = rl::get_mouse_delta();
	float wheel = rl::get_mouse_wheel_move();

	if (!rl::is_mouse_button_down(LEFT)) ctx.pan = -1;

	for (int i = 0; i < 2; i++)
	{
		RLTexture2D tex = preview_texture(i);
		if (!tex.is_valid()) continue;

		RLRectangle area = preview_area(l.previews[i]);
		View* v = &ctx.views[i];

		if (in_rect(m, area))
		{
			if (wheel != 0.0f) view_zoom(v, area, tex, m, wheel);
			if (rl::is_mouse_button_pressed(LEFT))  ctx.pan = i;
			if (rl::is_mouse_button_pressed(RIGHT)) reset_view(i);
		}
		if (ctx.pan == i) view_pan(v, area, tex, delta);
	}
}

// ================================
// Draw
// ================================

fn void draw_checker(RLRectangle area)
{
	RLColor base = theme(RGGuiProperty.BASE_COLOR_NORMAL);
	RLColor dark = base.brightness(-0.07f);

	rl::draw_rectangle_rec(area, base.brightness(0.07f));

	int cols = (int)math::ceil(area.width / CHECKER_SIZE);
	int rows = (int)math::ceil(area.height / CHECKER_SIZE);
	for (int row = 0; row < rows; row++)
	{
		for (int col = 0; col < cols; col++)
		{
			if ((row + col) % 2 == 0) continue;
			float x = (float)col * CHECKER_SIZE;
			float y = (float)row * CHECKER_SIZE;
			RLRectangle c = { area.x + x, area.y + y, math::min(CHECKER_SIZE, area.width - x), math::min(CHECKER_SIZE, area.height - y) };
			rl::draw_rectangle_rec(c, dark);
		}
	}
}

fn void draw_preview(int i, RLRectangle r) => @pool()
{
	RLTexture2D tex  = preview_texture(i);
	View*       v    = &ctx.views[i];
	RLRectangle area = preview_area(r);

	String name = "Original";
	String hint = "Drop an image here";
	if (i == 1)
	{
		name = "Convolved";
		hint = "Press Generate";
	}

	String title = name;
	if (tex.is_valid()) title = string::tformat("%s  (x%.2f)", name, view_scale(v, area, tex));
	(void)rg::status_bar({ r.x, r.y, r.width, PREVIEW_HEAD }, title.zstr_tcopy());

	draw_checker(area);

	if (tex.is_valid())
	{
		float scale = view_scale(v, area, tex);
		RLRectangle dest = view_dest(v, area, tex);

		float src_h = (float)tex.height;
		if (i == 1) src_h = -src_h;
		RLRectangle src = { 0.0f, 0.0f, (float)tex.width, src_h };

		tex.set_filter(scale >= 1.0f ? RLTextureFilter.POINT : RLTextureFilter.BILINEAR);

		rl::@scissor_mode((int)area.x, (int)area.y, (int)area.width, (int)area.height)
		{
			rl::draw_texture_pro(tex, src, dest, { 0.0f, 0.0f }, 0.0f, rl::WHITE);
		};
	}
	else
	{
		draw_centered(area, hint);
	}

	rl::draw_rectangle_lines_ex(area, 1.0f, theme(RGGuiProperty.BORDER_COLOR_NORMAL));
}

// ================================
// Shaders
// ================================

const CONVOLUTION_VERT @local = `
IN vec3 vertexPosition;
IN vec2 vertexTexCoord;
OUT vec2 fragTexCoord;
uniform mat4 mvp;

void main()
{
	fragTexCoord = vertexTexCoord;
	gl_Position = mvp * vec4(vertexPosition, 1.0);
}
`;

const CONVOLUTION_FRAG @local = `
#ifdef GL_ES
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#endif
#endif

IN vec2 fragTexCoord;
uniform sampler2D texture0;
uniform vec2 texelSize;

// Defined by the generated code
vec4 convolve(sampler2D tex, vec2 uv, vec2 texel);

void main()
{
	FRAG_COLOR = convolve(texture0, fragTexCoord, texelSize);
}
`;

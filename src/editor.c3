module tapy;

import std::math;
import raylib6;
import raygui;

// ================================
// Update
// ================================

fn void update_radius()
{
	int target = math::clamp(ctx.radius_value, RADIUS_MIN, RADIUS_MAX);
	if (!ctx.radius_editing && target != ctx.kernel.radius)
	{
		ctx.kernel.set_radius(target);
		ctx.radius_value = target;
	}
}

fn void update_mode()
{
	int sub = 1;
	if (ctx.linear) sub = ctx.sub_index == 0 ? 2 : 4;
	if (sub != ctx.kernel.sub) ctx.kernel.set_sub(sub);
}

fn void update_grid(RLRectangle g)
{
	Vec2 m = rl::get_mouse_position();
	if (!in_rect(m, g)) return;

	bool left  = rl::is_mouse_button_pressed(LEFT);
	bool right = rl::is_mouse_button_pressed(RIGHT);
	if (!left && !right) return;

	Kernel* k = &ctx.kernel;
	int   n    = k.side();
	float cell = g.width / (float)n;
	int col = math::clamp((int)((m.x - g.x) / cell), 0, n - 1);
	int row = math::clamp((int)((m.y - g.y) / cell), 0, n - 1);
	int i   = k.cell(col, row);

	if (left)           { k.toggle(i);    }
	else if (k.taps[i]) { k.selected = i; }
}

// ================================
// Weight text box
// ================================

fn void sync_weight_text() => @pool()
{
	ctx.weight_text = {};
	int s = ctx.kernel.selected;
	if (s < 0) return;

	String t = string::tformat("%.4f", ctx.kernel.weights[s]);
	sz n = math::min(t.len, (sz)(WEIGHT_TEXT_LEN - 1));
	mem::copy(&ctx.weight_text[0], t.ptr, n);
}

fn void commit_weight()
{
	int i = ctx.weight_index;
	if (i < 0 || !ctx.kernel.taps[i]) return;
	ctx.kernel.weights[i] = rl::text_to_float((ZString)&ctx.weight_text[0]);
}

// ================================
// Draw: grid
// ================================

fn void draw_grid(RLRectangle g) => @pool()
{
	(void)rg::panel(g, (ZString)null);

	Kernel* k = &ctx.kernel;
	int   n       = k.side();
	int   c0      = k.radius * k.sub;   // center cell
	float cell    = g.width / (float)n;
	RLFont font   = rg::get_font();
	float size    = (float)rg::get_style(RGGuiControl.DEFAULT, RGGuiProperty.TEXT_SIZE);
	float spacing = (float)rg::get_style(RGGuiControl.DEFAULT, RGGuiProperty.TEXT_SPACING);

	// Largest weight; to scale the cell colors
	float max_w = 0.0f;
	foreach (i, t : k.taps) if (t) max_w = math::max(max_w, math::abs(k.weights[i]));
	if (max_w < 1e-6f) max_w = 1.0f;

	RLColor line = theme(RGGuiProperty.LINE_COLOR);

	for (int row = 0; row < n; row++)
	{
		for (int col = 0; col < n; col++)
		{
			int i = k.cell(col, row);
			RLRectangle c = { g.x + (float)col * cell, g.y + (float)row * cell, cell, cell };

			if (k.taps[i])
			{
				float w = k.weights[i];
				RLColor base = w < 0.0f ? rl::RED : theme(RGGuiProperty.BASE_COLOR_PRESSED);
				rl::draw_rectangle_rec(c, base.fade(0.3f + 0.7f * math::abs(w) / max_w));

				// Weight label; only if it fits
				ZString txt = string::tformat("%.2f", w).zstr_tcopy();
				Vec2 ts = rl::measure_text_ex(font, txt, size, spacing);
				if (ts.x + 4.0f <= cell && ts.y <= cell)
				{
					rl::draw_text_ex(font, txt, { math::round(c.x + (cell - ts.x) * 0.5f), math::round(c.y + (cell - ts.y) * 0.5f) }, size, spacing, theme(RGGuiProperty.TEXT_COLOR_NORMAL));
				}
			}

			// In linear mode mark the cells that sit exactly on a texel center
			if (k.sub > 1 && (col - c0) % k.sub == 0 && (row - c0) % k.sub == 0)
			{
				rl::draw_circle_v({ c.x + cell * 0.5f, c.y + cell * 0.5f }, 1.5f, line.fade(0.8f));
			}

			rl::draw_rectangle_lines_ex(c, 1.0f, line.fade(0.4f));
		}
	}

	// Center (origin) marker
	RLRectangle center = { g.x + (float)c0 * cell, g.y + (float)c0 * cell, cell, cell };
	rl::draw_rectangle_lines_ex(center, 1.5f, theme(RGGuiProperty.BORDER_COLOR_FOCUSED));

	// Selected tap
	if (k.selected >= 0)
	{
		int col = k.col_of(k.selected);
		int row = k.row_of(k.selected);
		RLRectangle c = { g.x + (float)col * cell, g.y + (float)row * cell, cell, cell };
		rl::draw_rectangle_lines_ex(c, 2.5f, theme(RGGuiProperty.BORDER_COLOR_PRESSED));
	}
}

// ================================
// Draw: controls
// ================================

// Row `row` of the controls column, optionally split in `parts` columns
fn RLRectangle ctrl_row(RLRectangle c, int row, int part = 0, int parts = 1)
{
	float pw = math::floor((c.width - GAP * (float)(parts - 1)) / (float)parts);
	return { c.x + (float)part * (pw + GAP), c.y + (float)row * (ROW_H + GAP), pw, ROW_H };
}

fn RLRectangle label_rect(RLRectangle r, float lw) => { r.x, r.y, lw, r.height };
fn RLRectangle field_rect(RLRectangle r, float lw) => { r.x + lw, r.y, r.width - lw, r.height };

fn void draw_controls(RLRectangle c) => @pool()
{
	Kernel* k = &ctx.kernel;
	float lw = (float)rg::get_text_width("Weight") + 10.0f;

	// Radius
	RLRectangle r_radius = ctrl_row(c, 0);
	(void)rg::label(label_rect(r_radius, lw), "Radius");
	if (rg::spinner(field_rect(r_radius, lw), (ZString)null, &ctx.radius_value, RADIUS_MIN, RADIUS_MAX, ctx.radius_editing) != 0)
	{
		ctx.radius_editing = !ctx.radius_editing;
	}

	// Linear mode + grid step
	RLRectangle r_linear = ctrl_row(c, 1, 0, 2);
	RLRectangle r_step   = ctrl_row(c, 1, 1, 2);
	(void)rg::check_box({ r_linear.x, r_linear.y, r_linear.height, r_linear.height }, "Linear", &ctx.linear);

	float pad = (float)rg::get_style(RGGuiControl.TOGGLE, RGGuiProperty.GROUP_PADDING);
	float tw  = math::floor((r_step.width - pad) * 0.5f);
	if (!ctx.linear) rg::disable();
	(void)rg::toggle_group({ r_step.x, r_step.y, tw, r_step.height }, "1/2;1/4", &ctx.sub_index);
	if (!ctx.linear) rg::enable();

	// Gaussian sigma
	RLRectangle r_sigma = ctrl_row(c, 2);
	RLRectangle f_sigma = field_rect(r_sigma, lw);
	(void)rg::label(label_rect(r_sigma, lw), "Sigma");
	(void)rg::slider_bar(f_sigma, (ZString)null, (ZString)null, &ctx.sigma, SIGMA_MIN, SIGMA_MAX);
	draw_centered(f_sigma, string::tformat("%.2f", ctx.sigma));

	// Weight of the selected tap
	RLRectangle r_weight = ctrl_row(c, 3);
	(void)rg::label(label_rect(r_weight, lw), "Weight");
	if (!ctx.weight_editing) sync_weight_text();
	bool none = k.selected < 0;
	if (none) rg::disable();
	if (rg::text_box(field_rect(r_weight, lw), (ZString)&ctx.weight_text[0], WEIGHT_TEXT_LEN, ctx.weight_editing) != 0)
	{
		if (ctx.weight_editing) { commit_weight(); }
		else { ctx.weight_index = k.selected; }
		ctx.weight_editing = !ctx.weight_editing;
	}
	if (none) rg::enable();

	// Automatic distributions
	if (rg::button(ctrl_row(c, 4, 0, 2), "Uniform")   != 0) k.uniform();
	if (rg::button(ctrl_row(c, 4, 1, 2), "Gaussian")  != 0) k.gaussian(ctx.sigma);
	if (rg::button(ctrl_row(c, 5, 0, 2), "Normalize") != 0) k.normalize();
	if (rg::button(ctrl_row(c, 5, 1, 2), "Identity")  != 0) k.identity();
	if (rg::button(ctrl_row(c, 6, 0, 2), "All taps")  != 0) k.fill();
	if (rg::button(ctrl_row(c, 6, 1, 2), "Clear")     != 0) k.clear();

	// Generate / Copy
	if (rg::button(ctrl_row(c, 7, 0, 2), "Generate") != 0) generate();

	bool empty = ctx.code.len() == 0;
	if (empty) rg::disable();
	if (rg::button(ctrl_row(c, 7, 1, 2), "Copy") != 0) rl::set_clipboard_text(ctx.code.zstr_view());
	if (empty) rg::enable();
}

// ================================
// Draw: hint bar
// ================================

// Help text depends on what the mouse is over
fn void draw_hint(Layout l) => @pool()
{
	Vec2 m = rl::get_mouse_position();
	String hint = "Drop an image to replace the source";

	if (in_rect(m, l.grid))
	{
		hint = "L-click: toggle tap | R-click: select";
	}
	else if (ctx.pan >= 0 || in_rect(m, preview_area(l.previews[0])) || in_rect(m, preview_area(l.previews[1])))
	{
		hint = "Wheel: zoom | Drag: pan | R-click: reset";
	}
	else if (in_rect(m, ctrl_row(l.ctrl, 1)))
	{
		hint = "Linear: fractional taps, bilinear sampling";
	}

	(void)rg::status_bar(l.hint, hint.zstr_tcopy());
}

// ================================
// Draw: code
// ================================

fn void draw_code(RLRectangle bounds) => @pool()
{
	RLFont font   = rg::get_font();
	RLColor color = theme(RGGuiProperty.TEXT_COLOR_NORMAL);
	float size    = (float)rg::get_style(RGGuiControl.DEFAULT, RGGuiProperty.TEXT_SIZE);
	float spacing = (float)rg::get_style(RGGuiControl.DEFAULT, RGGuiProperty.TEXT_SPACING);
	float line_h  = size + CODE_GAP;

	String[] lines = ctx.code.str_view().tsplit("\n");

	// Content size: widest line x number of lines
	float text_w = 0.0f;
	foreach (line : lines)
	{
		text_w = math::max(text_w, rl::measure_text_ex(font, line.zstr_tcopy(), size, spacing).x);
	}
	RLRectangle content = { 0.0f, 0.0f, text_w + 2.0f * CODE_PAD, (float)lines.len * line_h + 2.0f * CODE_PAD };
	RLRectangle view;

	(void)rg::scroll_panel(bounds, "GLSL", content, &ctx.code_scroll, &view);

	float x = math::round(view.x + ctx.code_scroll.x + CODE_PAD);
	float y = math::round(view.y + ctx.code_scroll.y + CODE_PAD);

	rl::begin_scissor_mode((int)view.x, (int)view.y, (int)view.width, (int)view.height);
	foreach (i, line : lines)
	{
		float row_y = y + (float)i * line_h;

		// Skip rows outside the view
		if (row_y + line_h < view.y || row_y > view.y + view.height) continue;

		rl::draw_text_ex(font, line.zstr_tcopy(), { x, row_y }, size, spacing, color);
	}
	rl::end_scissor_mode();
}

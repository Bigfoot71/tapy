module tapy;

import std::math;

// ================================
// Constants
// ================================

const int RADIUS_MIN = 1;
const int RADIUS_MAX = 8;
const int SUB_MAX    = 4;                      // finest subdivision of a texel (linear mode)
const int HALF       = RADIUS_MAX * SUB_MAX;   // storage extent, in 1/SUB_MAX texel units
const int SIDE_MAX   = 2 * HALF + 1;
const int CELLS      = SIDE_MAX * SIDE_MAX;

// ================================
// Kernel
// ================================

// Taps and weights use a fixed grid centered on (0, 0) with spacing 1/SUB_MAX texel.
// The current subdivision (1, 2 or 4) determines the sampling resolution.
// Taps outside the radius or grid are always false.
struct Kernel
{
	int          radius;
	int          sub;
	int          selected; // -1 if none
	bool[CELLS]  taps;
	float[CELLS] weights;
}

fn int cell_index(int ux, int uy) => (uy + HALF) * SIDE_MAX + ux + HALF;
fn int cell_x(int i) => i % SIDE_MAX - HALF;
fn int cell_y(int i) => i / SIDE_MAX - HALF;

// Storage units -> texels
fn float cell_offset(int u) => (float)u / (float)SUB_MAX;

fn int snap_unit(int u, int stride) => (int)math::round((float)u / (float)stride) * stride;

// Storage units per grid step
fn int Kernel.stride(&self) => SUB_MAX / self.sub;

// Number of grid cells per side
fn int Kernel.side(&self) => 2 * self.radius * self.sub + 1;

// Grid (col, row) <-> storage index
fn int Kernel.cell(&self, int col, int row)
{
	int c = self.radius * self.sub;
	int s = self.stride();
	return cell_index((col - c) * s, (row - c) * s);
}

fn int Kernel.col_of(&self, int i) => cell_x(i) / self.stride() + self.radius * self.sub;
fn int Kernel.row_of(&self, int i) => cell_y(i) / self.stride() + self.radius * self.sub;

fn int Kernel.count(&self)
{
	int n = 0;
	foreach (t : self.taps) if (t) n++;
	return n;
}

fn void Kernel.set_radius(&self, int radius)
{
	self.radius = radius;
	int lim = radius * SUB_MAX;
	for (int i = 0; i < CELLS; i++)
	{
		if (math::abs(cell_x(i)) <= lim && math::abs(cell_y(i)) <= lim) continue;
		self.taps[i] = false;
		self.weights[i] = 0.0f;
	}
	if (self.selected >= 0 && !self.taps[self.selected]) self.selected = -1;
}

// Change the grid step; taps that fall off the new grid are merged into the nearest cell
fn void Kernel.set_sub(&self, int sub)
{
	self.sub = sub;
	int stride = self.stride();
	for (int i = 0; i < CELLS; i++)
	{
		if (!self.taps[i]) continue;

		int ux = cell_x(i);
		int uy = cell_y(i);
		if (ux % stride == 0 && uy % stride == 0) continue;

		int t = cell_index(snap_unit(ux, stride), snap_unit(uy, stride));
		float w = self.weights[i];
		self.taps[i] = false;
		self.weights[i] = 0.0f;
		if (self.taps[t]) { self.weights[t] += w; }
		else              { self.taps[t] = true; self.weights[t] = w; }
	}
	if (self.selected >= 0 && !self.taps[self.selected]) self.selected = -1;
}

fn void Kernel.toggle(&self, int i)
{
	self.taps[i] = !self.taps[i];
	if (self.taps[i])
	{
		self.weights[i] = 1.0f;
		self.selected = i;
	}
	else
	{
		self.weights[i] = 0.0f;
		if (self.selected == i) self.selected = -1;
	}
}

// ================================
// Presets / automatic distribs
// ================================

fn void Kernel.clear(&self)
{
	self.taps = {};
	self.weights = {};
	self.selected = -1;
}

// Enable every cell of the grid
fn void Kernel.fill(&self)
{
	int n = self.side();
	for (int row = 0; row < n; row++)
	{
		for (int col = 0; col < n; col++)
		{
			int i = self.cell(col, row);
			self.taps[i] = true;
			if (self.weights[i] == 0.0f) self.weights[i] = 1.0f;
		}
	}
}

// Single center tap, weight 1
fn void Kernel.identity(&self)
{
	self.clear();
	int c = cell_index(0, 0);
	self.taps[c] = true;
	self.weights[c] = 1.0f;
	self.selected = c;
}

// Same weight on every tap (sum = 1)
fn void Kernel.uniform(&self)
{
	int n = self.count();
	if (n == 0) return;
	foreach (i, t : self.taps) if (t) self.weights[i] = 1.0f / (float)n;
}

// Gaussian falloff from the center (sum = 1); sigma is in texels
fn void Kernel.gaussian(&self, float sigma)
{
	float k = -1.0f / (2.0f * sigma * sigma);
	foreach (int i, t : self.taps)
	{
		if (!t) continue;
		float dx = cell_offset(cell_x(i));
		float dy = cell_offset(cell_y(i));
		self.weights[i] = math::exp((dx * dx + dy * dy) * k);
	}
	self.normalize();
}

// Scale weights so that they sum to 1
// Ignored if the sum is ~0; like edge detection
fn void Kernel.normalize(&self)
{
	float sum = 0.0f;
	foreach (i, t : self.taps) if (t) sum += self.weights[i];
	if (math::abs(sum) < 1e-6f) return;
	foreach (i, t : self.taps) if (t) self.weights[i] /= sum;
}

// ================================
// GLSL generation
// ================================

fn void Kernel.to_glsl(&self, DString* dst) => @pool()
{
	int n = 0;
	foreach (i, t : self.taps) if (t && math::abs(self.weights[i]) >= 1e-6f) n++;

	int texels = 2 * self.radius + 1;
	dst.append(string::tformat("// Convolution kernel %dx%d, %d taps\n", texels, texels, n));
	if (self.sub > 1) dst.append("// Fractional taps: needs bilinear texture filtering\n");
	dst.append("// texel = 1.0 / texture size\n");
	dst.append("vec4 convolve(sampler2D tex, vec2 uv, vec2 texel)\n{\n");
	dst.append("    vec4 c = vec4(0.0);\n");

	String fmt = "    c += TEXTURE_2D(tex, uv + vec2(%.1f, %.1f) * texel) * %.6f;\n";
	if (self.sub > 1) fmt = "    c += TEXTURE_2D(tex, uv + vec2(%.2f, %.2f) * texel) * %.6f;\n";

	foreach (int i, t : self.taps)
	{
		float w = self.weights[i];
		if (!t || math::abs(w) < 1e-6f) continue;
		dst.append(string::tformat(fmt, cell_offset(cell_x(i)), cell_offset(cell_y(i)), w));
	}

	dst.append("    return c;\n}\n");
}

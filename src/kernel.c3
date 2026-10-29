module tapy;

import std::math;

// ================================
// Constants
// ================================

const int RADIUS_MIN = 1;
const int RADIUS_MAX = 8;
const int SIDE_MAX   = 2 * RADIUS_MAX + 1;
const int CELLS      = SIDE_MAX * SIDE_MAX;

// ================================
// Kernel
// ================================

// Taps and weights are stored in a fixed (SIDE_MAX x SIDE_MAX) array centered on (0, 0)
// NOTE: taps outside the current radius are always false
struct Kernel
{
	int          radius;
	int          selected; // selected tap (storage index); -1 if none
	bool[CELLS]  taps;
	float[CELLS] weights;
}

fn int cell_index(int dx, int dy) => (dy + RADIUS_MAX) * SIDE_MAX + dx + RADIUS_MAX;
fn int cell_x(int i) => i % SIDE_MAX - RADIUS_MAX;
fn int cell_y(int i) => i / SIDE_MAX - RADIUS_MAX;

fn int Kernel.side(&self) => 2 * self.radius + 1;

fn int Kernel.count(&self)
{
	int n = 0;
	foreach (t : self.taps) if (t) n++;
	return n;
}

fn void Kernel.set_radius(&self, int radius)
{
	self.radius = radius;
	for (int i = 0; i < CELLS; i++)
	{
		if (math::abs(cell_x(i)) <= radius && math::abs(cell_y(i)) <= radius) continue;
		self.taps[i] = false;
		self.weights[i] = 0.0f;
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

// Enable every cell inside the radius
fn void Kernel.fill(&self)
{
	int r = self.radius;
	for (int dy = -r; dy <= r; dy++)
	{
		for (int dx = -r; dx <= r; dx++)
		{
			int i = cell_index(dx, dy);
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

// Gaussian falloff from the center (sum = 1)
fn void Kernel.gaussian(&self, float sigma)
{
	float k = -1.0f / (2.0f * sigma * sigma);
	foreach (int i, t : self.taps)
	{
		if (!t) continue;
		float d2 = (float)(cell_x(i) * cell_x(i) + cell_y(i) * cell_y(i));
		self.weights[i] = math::exp(d2 * k);
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

	dst.append(string::tformat("// Convolution kernel %dx%d, %d taps\n", self.side(), self.side(), n));
	dst.append("// texel = 1.0 / texture size\n");
	dst.append("vec4 convolve(sampler2D tex, vec2 uv, vec2 texel)\n{\n");
	dst.append("    vec4 c = vec4(0.0);\n");

	foreach (int i, t : self.taps)
	{
		float w = self.weights[i];
		if (!t || math::abs(w) < 1e-6f) continue;
		dst.append(string::tformat("    c += TEXTURE_2D(tex, uv + vec2(%.1f, %.1f) * texel) * %.6f;\n", (float)cell_x(i), (float)cell_y(i), w));
	}

	dst.append("    return c;\n}\n");
}

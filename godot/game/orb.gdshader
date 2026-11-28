shader_type canvas_item;
// Preload orb: the Nullifier's black orb with a flame corona.
// state 0 = PROTECT (Ghost magenta: calm, wrapping flames, hex shield)
// state 1 = DESTROY (Nullifier green: jagged radial flames, glowing cracks)

uniform float state : hint_range(0.0, 1.0) = 0.0;
uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform float pulse : hint_range(0.0, 1.0) = 1.0;   // 0 at the flip, runs to 1
uniform float clock = 0.0;
uniform vec3 protect_color : source_color = vec3(1.0, 0.10, 0.42);
uniform vec3 destroy_color : source_color = vec3(0.10, 1.0, 0.38);
uniform vec2 resolution = vec2(1920.0, 1080.0);
uniform vec2 center = vec2(0.5, 0.42);
uniform float orb_radius = 0.165;                   // fraction of screen height

float hash31(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float noise3(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(mix(hash31(i), hash31(i + vec3(1, 0, 0)), f.x),
			mix(hash31(i + vec3(0, 1, 0)), hash31(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(hash31(i + vec3(0, 0, 1)), hash31(i + vec3(1, 0, 1)), f.x),
			mix(hash31(i + vec3(0, 1, 1)), hash31(i + vec3(1, 1, 1)), f.x), f.y),
		f.z);
}

float fbm(vec3 p) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		s += a * noise3(p);
		p = p * 2.03 + vec3(7.1);
		a *= 0.5;
	}
	return s;
}

float hex_edge(vec2 uv) {
	vec2 r = vec2(1.0, 1.7320508);
	vec2 h = r * 0.5;
	vec2 a = mod(uv, r) - h;
	vec2 b = mod(uv - h, r) - h;
	vec2 g = dot(a, a) < dot(b, b) ? a : b;
	g = abs(g);
	float d = max(dot(g, vec2(0.5, 0.8660254)), g.x);
	return smoothstep(0.43, 0.49, d);
}

float sparks(vec2 p, float t, float scale, float speed) {
	vec2 uv = p * scale + vec2(0.0, t * speed);
	vec2 id = floor(uv);
	vec2 f = fract(uv) - 0.5;
	float h = hash31(vec3(id, 3.7));
	if (h < 0.72) {
		return 0.0;
	}
	vec2 o = vec2(hash31(vec3(id, 9.1)), hash31(vec3(id, 5.3))) - 0.5;
	float d = length(f - o * 0.7);
	float tw = 0.5 + 0.5 * sin(t * 3.0 + h * 40.0);
	return smoothstep(0.07, 0.0, d) * tw;
}

void fragment() {
	float aspect = resolution.x / resolution.y;
	vec2 p = (UV - center) * vec2(aspect, 1.0);
	float r = length(p);
	float a = atan(p.y, p.x);
	float t = clock;
	float R = orb_radius;
	float px = 1.5 / resolution.y;
	vec3 tint = mix(protect_color, destroy_color, state);

	// backdrop
	vec3 c = vec3(0.010, 0.012, 0.014);
	c += tint * 0.075 * exp(-r * 3.2);
	c *= 1.0 - 0.55 * smoothstep(0.35, 1.1, length((UV - 0.5) * vec2(aspect, 1.0)));

	// flame corona
	float d = r / R - 1.0;
	float sw = a + d * mix(1.9, 0.15, state) + t * mix(0.22, 0.0, state);
	float k = mix(1.5, 3.2, state);
	vec3 q = vec3(cos(sw) * k, sin(sw) * k, d * mix(1.1, 0.9, state) - t * mix(0.32, 1.25, state));
	float n = fbm(q);
	float reach = mix(0.50, 0.95, state) * (1.0 + 0.5 * (1.0 - pulse));
	float fl = clamp((n - 0.30) * mix(2.7, 3.3, state) - max(d, 0.0) / reach, 0.0, 1.0);
	fl = fl * fl * (3.0 - 2.0 * fl);
	c += tint * fl * 1.15 + vec3(1.0) * pow(fl, 4.0) * 0.55;

	// soft halo and thin bright rim
	c += tint * 0.30 * exp(-max(d, 0.0) * 5.0);
	c += (tint + 0.35) * exp(-abs(d) * 55.0) * 1.1;

	// sparks
	float sp = sparks(p, t, 22.0, -0.55) + sparks(p + 3.1, t, 37.0, -0.9) * 0.7;
	c += (tint * 0.8 + 0.3) * sp * smoothstep(R * 3.6, R * 1.1, r);

	// orb body
	if (r < R) {
		vec2 s = p / R;
		float z = sqrt(max(1.0 - dot(s, s), 0.0));
		vec3 nrm = vec3(s, z);
		vec3 L = normalize(vec3(-0.45, -0.60, 0.66));
		float diff = max(dot(nrm, L), 0.0);
		float grain = 0.75 + 0.5 * noise3(nrm * 9.0);
		vec3 body = vec3(0.004, 0.007, 0.007);
		body += vec3(0.13, 0.15, 0.15) * pow(diff, 2.6) * grain;
		body += tint * pow(1.0 - z, 2.4) * 0.85;

		// PROTECT: slow hex shield on the surface
		vec2 huv = nrm.xy / (0.55 + z) * 5.5 + vec2(t * 0.12, 0.0);
		float hx = hex_edge(huv) * (0.25 + 0.75 * pow(1.0 - z, 1.3));
		float sweep = 0.5 + 0.5 * sin(nrm.y * 5.0 - t * 1.6);
		body += protect_color * hx * (0.12 + 0.5 * sweep) * (1.0 - state);

		// DESTROY: glowing fractures
		float ridge = abs(fbm(nrm * 2.6 + vec3(3.0, 1.0, t * 0.05)) - 0.47);
		float crack = smoothstep(0.030 + 0.03 * (1.0 - pulse), 0.0, ridge);
		float ember = 0.6 + 0.4 * sin(t * 5.0 + nrm.x * 9.0);
		body += (destroy_color * 1.6 + 0.6) * crack * ember * state;

		c = mix(c, body, smoothstep(R, R - px * 2.0, r));
	}

	// progress ring: 72 ticks, fills clockwise from the top
	float Rr = R * 1.78;
	float frac = fract(atan(p.x, -p.y) / 6.2831853 + 1.0);
	float tick = step(0.18, fract(frac * 72.0));
	float band = smoothstep(R * 0.050, R * 0.028, abs(r - Rr)) * tick;
	float filled = step(frac, progress - 0.0001);
	c += mix(vec3(0.085), tint * 1.25 + 0.15, filled) * band;
	// leading tick
	float head = smoothstep(0.012, 0.0, abs(frac - progress)) * smoothstep(R * 0.09, R * 0.03, abs(r - Rr));
	c += vec3(1.0) * head * step(0.001, progress) * step(progress, 0.999);

	// cycle ring: two arcs, clockwise for PROTECT, reversing for DESTROY
	float Rc = R * 2.02;
	float spin = t * mix(0.35, -0.9, state);
	float arc = smoothstep(0.52, 0.56, abs(sin(a - spin)));
	c += tint * 0.75 * arc * smoothstep(px * 2.5, px * 0.8, abs(r - Rc));
	c += vec3(0.07) * smoothstep(px * 2.0, px * 0.6, abs(r - Rc));

	// shockwave at each flip
	float wave_r = R * (1.0 + pulse * 3.4);
	float wave = exp(-pow((r - wave_r) / (R * 0.06), 2.0)) * (1.0 - pulse) * (1.0 - pulse);
	c += (tint + 0.4) * wave * 1.2;

	COLOR = vec4(c, 1.0);
}

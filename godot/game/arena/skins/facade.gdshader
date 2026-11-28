shader_type spatial;
// A building wall: a real wall texture (brick, stone) at real-world size, with a New York window grid on top:
// larger storefront windows at street level, a few lit windows, and a slight variation from building to building.
// The arena's facade texture coordinates are in tiles of 12 m (along the wall) by 14 m (up the wall).

uniform sampler2D wall_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float wall_size = 3.0;                 // metres covered by one repeat of the wall texture
uniform vec3 tint = vec3(1.0);
uniform bool windows = true;
uniform float bay = 3.3;                       // window spacing along the wall, metres
uniform float floor_h = 3.7;                   // storey height, metres
uniform vec2 window_frac = vec2(0.52, 0.56);   // window size as a fraction of a bay and a storey
uniform vec3 glass = vec3(0.07, 0.10, 0.14);

varying vec3 wpos;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 m = UV * vec2(12.0, 14.0);                       // metres along and up the wall
	float building = hash(floor(wpos.xz / 45.0));
	vec3 wall = texture(wall_tex, m / wall_size).rgb * tint * mix(0.82, 1.12, building);
	ALBEDO = wall;
	ROUGHNESS = 0.92;
	METALLIC = 0.0;
	if (windows) {
		bool street = m.y < 4.6;
		float fh = street ? 4.6 : floor_h;
		float y0 = street ? 0.0 : 4.6;
		vec2 cell = vec2(m.x / (street ? bay * 1.6 : bay), (m.y - y0) / fh);
		vec2 f = fract(cell);
		vec2 id = floor(cell) + vec2(street ? 100.0 : 0.0, building * 57.0);
		vec2 wf = street ? vec2(0.8, 0.62) : window_frac;
		float win = step(abs(f.x - 0.5), wf.x * 0.5) * step(abs(f.y - (street ? 0.42 : 0.55)), wf.y * 0.5);
		// a frame: slightly darker band around each window
		float frame = step(abs(f.x - 0.5), wf.x * 0.5 + 0.04) * step(abs(f.y - (street ? 0.42 : 0.55)), wf.y * 0.5 + 0.04) - win;
		float lit = step(0.9, hash(id));
		vec3 g = glass * mix(0.75, 1.35, hash(id * 1.7)) + vec3(1.0, 0.82, 0.55) * lit * 0.28;
		ALBEDO = mix(ALBEDO * (1.0 - 0.35 * frame), g, win);
		ROUGHNESS = mix(ROUGHNESS, 0.12, win);
		METALLIC = mix(0.0, 0.55, win);
		EMISSION = vec3(1.0, 0.78, 0.45) * lit * win * 0.25;
	}
}

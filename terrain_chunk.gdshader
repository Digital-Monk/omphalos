shader_type spatial;
render_mode cull_back;

uniform sampler2D heightmap : filter_nearest, repeat_disable;
uniform float height_amplitude = 8.0;
uniform float chunk_size = 128.0;
uniform float chunk_resolution = 128.0;

void vertex() {
	int res = int(chunk_resolution);
	ivec2 ts = ivec2(res + 1);
	ivec2 tc = clamp(ivec2(round(UV * chunk_resolution)), ivec2(0), ts - ivec2(1));

	float h = texelFetch(heightmap, tc, 0).r;
	VERTEX.y = h;

	// Central-difference normals from heightmap neighbours.
	float h_l = texelFetch(heightmap, clamp(tc + ivec2(-1, 0), ivec2(0), ts - ivec2(1)), 0).r;
	float h_r = texelFetch(heightmap, clamp(tc + ivec2( 1, 0), ivec2(0), ts - ivec2(1)), 0).r;
	float h_d = texelFetch(heightmap, clamp(tc + ivec2( 0,-1), ivec2(0), ts - ivec2(1)), 0).r;
	float h_u = texelFetch(heightmap, clamp(tc + ivec2( 0, 1), ivec2(0), ts - ivec2(1)), 0).r;
	float stp = chunk_size / chunk_resolution;
	NORMAL = normalize(vec3(h_l - h_r, 2.0 * stp, h_d - h_u));

	// Height-based vertex colour.
	float t = clamp((h + height_amplitude) / (2.0 * height_amplitude), 0.0, 1.0);
	COLOR = vec4(0.1 + 0.2 * t, 0.3 + 0.5 * t, 0.1 + 0.2 * t, 1.0);
}

void fragment() {
	ALBEDO = COLOR.rgb;
}

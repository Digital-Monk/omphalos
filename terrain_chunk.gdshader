shader_type spatial;
render_mode cull_back;

uniform sampler2D heightmap : filter_nearest, repeat_disable;
uniform sampler2D biomemap  : filter_nearest, repeat_disable;
uniform float height_amplitude = 8.0;
uniform float chunk_size = 128.0;
uniform float chunk_resolution = 128.0;
uniform float heightmap_padded = 1.0;  // 1.0 = padded (regular), 0.0 = unpadded (mega)

void vertex() {
	int res = int(chunk_resolution);
	ivec2 tc0 = clamp(ivec2(round(UV * chunk_resolution)), ivec2(0), ivec2(res));
	// Padded heightmaps have a 1-texel border: (res+3) wide, offset by +1.
	// Unpadded heightmaps are (res+1) wide, no offset.
	int pad = int(heightmap_padded);
	ivec2 tc = tc0 + ivec2(pad);
	int ts_edge = res + 1 + pad * 2;  // padded: res+3, unpadded: res+1
	tc = clamp(tc, ivec2(pad), ivec2(ts_edge - 1 - pad));

	float h = texelFetch(heightmap, tc, 0).r;
	VERTEX.y = h;

	// Central-difference normals from heightmap neighbours.
	// For padded textures, neighbors are always valid.
	// For unpadded, clamp at edges (produces correct normals except at chunk borders).
	ivec2 tc_l = clamp(tc + ivec2(-1, 0), ivec2(0), ivec2(ts_edge - 1));
	ivec2 tc_r = clamp(tc + ivec2( 1, 0), ivec2(0), ivec2(ts_edge - 1));
	ivec2 tc_d = clamp(tc + ivec2( 0,-1), ivec2(0), ivec2(ts_edge - 1));
	ivec2 tc_u = clamp(tc + ivec2( 0, 1), ivec2(0), ivec2(ts_edge - 1));
	float h_l = texelFetch(heightmap, tc_l, 0).r;
	float h_r = texelFetch(heightmap, tc_r, 0).r;
	float h_d = texelFetch(heightmap, tc_d, 0).r;
	float h_u = texelFetch(heightmap, tc_u, 0).r;
	float stp = chunk_size / chunk_resolution;
	NORMAL = normalize(vec3(h_l - h_r, 2.0 * stp, h_d - h_u));

	// Biome tag: 0.0 = bedrock, 0.5 = normal, 1.0 = plateau.
	float biome = texelFetch(biomemap, tc0, 0).r;

	// Height-normalized for blending.
	float t = clamp((h + height_amplitude) / (2.0 * height_amplitude), 0.0, 1.0);

	vec3 col;
	if (biome < 0.25) {
		// Bedrock — warm grey/brown
		col = vec3(0.35 + 0.15 * t, 0.28 + 0.12 * t, 0.20 + 0.10 * t);
	} else if (biome > 0.75) {
		// Plateau — reddish ochre
		col = vec3(0.45 + 0.25 * t, 0.25 + 0.15 * t, 0.15 + 0.10 * t);
	} else {
		// Normal terrain — green
		col = vec3(0.1 + 0.2 * t, 0.3 + 0.5 * t, 0.1 + 0.2 * t);
	}
	COLOR = vec4(col, 1.0);
}

void fragment() {
	ALBEDO = COLOR.rgb;
}

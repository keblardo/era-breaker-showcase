// © 2026 Cristian Luis Celie. All rights reserved. Portfolio excerpt from Era Breaker: shared for review only, not licensed for use, copying or redistribution.
shader_type canvas_item;
render_mode unshaded;

uniform sampler2D garment_mask : filter_linear_mipmap, repeat_disable;
uniform vec4 upper_color : source_color = vec4(0.5,0.5,0.5,1.0);
uniform vec4 lower_color : source_color = vec4(0.3,0.3,0.3,1.0);
uniform vec4 hair_color : source_color = vec4(0.2,0.15,0.1,1.0);
uniform float strength = 0.82;
uniform int pattern = 0;
uniform bool equipment = false;
uniform bool patterned_part = false;
uniform bool coat_spots = false;
varying vec4 vertex_tint;

void vertex() { vertex_tint = COLOR; }

vec3 dyed(vec3 original, vec3 target, float lift) {
	float lum = dot(original,vec3(0.299,0.587,0.114));
	float target_lum = max(0.12,dot(target,vec3(0.299,0.587,0.114)));
	// Retain the hand-painted planes, folds, scratches and dark outlines.
	float value_scale = clamp(mix(1.0,target_lum/0.48,0.65),0.52,1.35);
	return clamp(target * (lum + lift) / target_lum * value_scale,vec3(0.0),vec3(1.0));
}

void fragment() {
	vec4 source = texture(TEXTURE,UV);
	vec3 mask = texture(garment_mask,UV).rgb;
	if (equipment) { mask = vec3(1.0,0.0,0.0); }
	vec3 rgb = source.rgb;
	rgb = mix(rgb,dyed(source.rgb,upper_color.rgb,0.0),mask.r*strength);
	rgb = mix(rgb,dyed(source.rgb,lower_color.rgb,0.0),mask.g*strength);
	float hair_lift = dot(hair_color.rgb,vec3(0.299,0.587,0.114))*0.52;
	rgb = mix(rgb,dyed(source.rgb,hair_color.rgb,hair_lift),mask.b*strength);
	if (patterned_part && pattern > 0) {
		vec2 p = UV / TEXTURE_PIXEL_SIZE;
		float detail = 0.0;
		if (pattern == 1) { detail = step(0.73,fract(p.y/27.0))*0.13; }
		if (pattern == 2) {
			detail = max(step(0.88,fract(p.x/38.0)),step(0.88,fract(p.y/38.0)))*0.12;
		}
		if (pattern == 3) {
			detail = smoothstep(0.6,0.83,sin(p.x*0.049+sin(p.y*0.041)*2.7)*sin(p.y*0.058))*0.17;
		}
		if (coat_spots) {
			detail = smoothstep(0.78,0.91,sin(p.x*0.074+sin(p.y*0.037))*sin(p.y*0.081))*0.24;
		}
		rgb *= 1.0-detail*mask.r;
	}
	COLOR = vec4(rgb,source.a) * vertex_tint;
}

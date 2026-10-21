import CoreImage
import simd

/// Explicit texel reads keep interpolation selectable and avoid hardware cube-coordinate quantization.
nonisolated enum LUTKernel {
    static let kernel = CIKernel(source: """
    float decode(float x, float space) {
        float a = abs(x);
        if (space == 0.0) return sign(x) * (a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4));
        if (space == 1.0) return x;
        if (space == 2.0) return sign(x) * pow(a, 2.2);
        if (space == 3.0) return sign(x) * pow(a, 2.4);
        if (space == 4.0) return sign(x) * (a < 0.081 ? a / 4.5 : pow((a + 0.099) / 1.099, 1.0 / 0.45));
        if (space == 5.0 || space == 6.0) {
            float cut = 47.28711236 * 0.06641088 * 0.06641088;
            return x >= cut ? pow(2.0, (x - 0.69336945) / 0.08550479) - 0.00964052
                            : sqrt(max(x, 0.0) / 47.28711236) - 0.05641088;
        }
        if (space == 7.0) return x >= 0.100686685370811 ? (pow(10.0, (x - 0.384316) / 0.245281) - 0.064829) / 5.555556
                                                      : (x - 0.092864) / 8.799461;
        return x >= 0.181 ? pow(10.0, (x - 0.598206) / 0.241514) - 0.00873 : (x - 0.125) / 5.6;
    }
    float encode(float x, float space) {
        float a = abs(x);
        if (space == 0.0) return sign(x) * (a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1.0 / 2.4) - 0.055);
        if (space == 1.0) return x;
        if (space == 2.0) return sign(x) * pow(a, 1.0 / 2.2);
        if (space == 3.0) return sign(x) * pow(a, 1.0 / 2.4);
        if (space == 4.0) return sign(x) * (a < 0.018 ? 4.5 * a : 1.099 * pow(a, 0.45) - 0.099);
        if (space == 5.0 || space == 6.0) {
            float v = max(x + 0.05641088, 0.0);
            return x >= 0.01 ? 0.08550479 * log2(x + 0.00964052) + 0.69336945 : 47.28711236 * v * v;
        }
        if (space == 7.0) return x >= 0.000889 ? 0.245281 * log(5.555556 * x + 0.064829) / log(10.0) + 0.384316
                                             : 8.799461 * x + 0.092864;
        return x >= 0.01 ? 0.241514 * log(x + 0.00873) / log(10.0) + 0.598206 : 5.6 * x + 0.125;
    }
    vec3 convert(vec3 c, float from, float to, vec3 r, vec3 g, vec3 b) {
        vec3 lin = vec3(decode(c.r, from), decode(c.g, from), decode(c.b, from));
        lin = vec3(dot(r, lin), dot(g, lin), dot(b, lin));
        return vec3(encode(lin.r, to), encode(lin.g, to), encode(lin.b, to));
    }
    vec3 entry(sampler table, vec3 p, float n) {
        float width = n * min(n, 16.0);
        float height = ceil(n*n*n / width);
        float index = p.x + p.y*n + p.z*n*n;
        return sample(table, samplerTransform(table, vec2(mod(index, width) + 0.5, height - floor(index / width) - 0.5))).rgb;
    }
    kernel vec4 lookup(sampler source, sampler table, float n, float tetra,
                       vec3 low, vec3 high, float inputSpace, float outputSpace, float alreadyEncoded,
                       vec3 ir, vec3 ig, vec3 ib, vec3 orow, vec3 og, vec3 ob, float dither, vec3 mx, vec3 my) {
        vec4 pixel = sample(source, samplerCoord(source));
        vec3 c = unpremultiply(pixel).rgb;
        if (alreadyEncoded < 0.5 && inputSpace != 0.0) c = convert(c, 0.0, inputSpace, ir, ig, ib);
        vec3 pos = clamp((c - low) / (high - low), 0.0, 1.0) * (n - 1.0);
        vec3 i = min(floor(pos), vec3(n - 2.0));
        vec3 f = pos - i;
        vec3 c000 = entry(table, i, n);
        vec3 c100 = entry(table, i + vec3(1,0,0), n);
        vec3 c010 = entry(table, i + vec3(0,1,0), n);
        vec3 c001 = entry(table, i + vec3(0,0,1), n);
        vec3 c110 = entry(table, i + vec3(1,1,0), n);
        vec3 c101 = entry(table, i + vec3(1,0,1), n);
        vec3 c011 = entry(table, i + vec3(0,1,1), n);
        vec3 c111 = entry(table, i + vec3(1,1,1), n);
        vec3 o;
        if (tetra > 0.5) {
            if (f.x >= f.y) {
                if (f.y >= f.z) o = (1.0-f.x)*c000 + (f.x-f.y)*c100 + (f.y-f.z)*c110 + f.z*c111;
                else if (f.x >= f.z) o = (1.0-f.x)*c000 + (f.x-f.z)*c100 + (f.z-f.y)*c101 + f.y*c111;
                else o = (1.0-f.z)*c000 + (f.z-f.x)*c001 + (f.x-f.y)*c101 + f.y*c111;
            } else {
                if (f.x >= f.z) o = (1.0-f.y)*c000 + (f.y-f.x)*c010 + (f.x-f.z)*c110 + f.z*c111;
                else if (f.y >= f.z) o = (1.0-f.y)*c000 + (f.y-f.z)*c010 + (f.z-f.x)*c011 + f.x*c111;
                else o = (1.0-f.z)*c000 + (f.z-f.y)*c001 + (f.y-f.x)*c011 + f.x*c111;
            }
        } else {
            o = mix(mix(mix(c000,c100,f.x), mix(c010,c110,f.x), f.y),
                    mix(mix(c001,c101,f.x), mix(c011,c111,f.x), f.y), f.z);
        }
        if (outputSpace != 0.0) o = convert(o, outputSpace, 0.0, orow, og, ob);
        if (dither > 0.5) {
            vec3 p = vec3(destCoord(), 1.0);
            vec2 xy = mod(floor(vec2(dot(mx,p), dot(my,p))), 4.0);
            float x = xy.x, y = xy.y;
            float value;
            if (y < 1.0) value = x < 1.0 ? 0.0 : (x < 2.0 ? 8.0 : (x < 3.0 ? 2.0 : 10.0));
            else if (y < 2.0) value = x < 1.0 ? 12.0 : (x < 2.0 ? 4.0 : (x < 3.0 ? 14.0 : 6.0));
            else if (y < 3.0) value = x < 1.0 ? 3.0 : (x < 2.0 ? 11.0 : (x < 3.0 ? 1.0 : 9.0));
            else value = x < 1.0 ? 15.0 : (x < 2.0 ? 7.0 : (x < 3.0 ? 13.0 : 5.0));
            o = clamp(o + ((value + 0.5) / 16.0 - 0.5) / 255.0, 0.0, 1.0);
        }
        return premultiply(vec4(o, pixel.a));
    }
    """)

    static func apply(_ image: CIImage, lookup: ColorLookup, settings: LUTSettings, mapping: CGAffineTransform = .identity) -> CIImage? {
        func rows(_ m: simd_double3x3) -> [CIVector] {
            (0..<3).map { CIVector(x: m[0][$0], y: m[1][$0], z: m[2][$0]) }
        }
        let table = lookup.texture
        let low = CIVector(x: CGFloat(lookup.domainMin[0]), y: CGFloat(lookup.domainMin[1]), z: CGFloat(lookup.domainMin[2]))
        let high = CIVector(x: CGFloat(lookup.domainMax[0]), y: CGFloat(lookup.domainMax[1]), z: CGFloat(lookup.domainMax[2]))
        var arguments: [Any] = [image, table, Float(lookup.dimension), settings.interpolation == .tetrahedral ? Float(1) : Float(0),
                                low, high, settings.inputSpace.curve, settings.outputSpace.curve, settings.inputAlreadyEncoded ? Float(1) : Float(0)]
        arguments += rows(settings.inputSpace.toSRGB.inverse)
        arguments += rows(settings.outputSpace.toSRGB)
        arguments += [settings.dither == true ? Float(1) : Float(0),
                      CIVector(x: mapping.a, y: mapping.c, z: mapping.tx), CIVector(x: mapping.b, y: mapping.d, z: mapping.ty)]
        return kernel?.apply(extent: image.extent, roiCallback: { index, rect in index == 1 ? table.extent : rect }, arguments: arguments)
    }
}

#include <CoreImage/CoreImage.h>

using namespace metal;

static float linearChannel(float value) {
    return value <= 0.04045f ? value / 12.92f : pow((value + 0.055f) / 1.055f, 2.4f);
}

static float gammaChannel(float value) {
    return value <= 0.0031308f ? 12.92f * value : 1.055f * pow(value, 1.0f / 2.4f) - 0.055f;
}

static float labCurve(float value) {
    return value > 0.00885645f ? pow(value, 1.0f / 3.0f) : 7.787037f * value + 16.0f / 116.0f;
}

static float invLabCurve(float value) {
    return value > 0.20689655f ? value * value * value : (value - 16.0f / 116.0f) / 7.787037f;
}

static float3 labToLinear(float light, float2 ab) {
    float x = 0.95047f * invLabCurve(light + ab.x / 500.0f);
    float y = invLabCurve(light);
    float z = 1.08883f * invLabCurve(light - ab.y / 200.0f);
    return float3(3.2404542f * x - 1.5371385f * y - 0.4985314f * z,
                 -0.9692660f * x + 1.8760108f * y + 0.0415560f * z,
                  0.0556434f * x - 0.2040259f * y + 1.0572252f * z);
}

static bool outOfGamut(float3 rgb) {
    return any(rgb < 0.0f) || any(rgb > 1.0f);
}

extern "C" float4 oldPhotoColorize(coreimage::sample_t source, coreimage::sample_t color, float amount) {
    float4 base = coreimage::unpremultiply(source);
    float3 rgb = float3(linearChannel(base.r), linearChannel(base.g), linearChannel(base.b));
    float light = labCurve(dot(rgb, float3(0.2126729f, 0.7151522f, 0.0721750f)));
    float x = labCurve(dot(rgb, float3(0.4124564f, 0.3575761f, 0.1804375f)) / 0.95047f);
    float z = labCurve(dot(rgb, float3(0.0193339f, 0.1191920f, 0.9503041f)) / 1.08883f);
    float2 original = float2(500.0f * (x - light), 200.0f * (light - z));
    float2 chroma = mix(original, color.rg * 255.0f - 128.0f, amount);
    float3 result = labToLinear(light, chroma);
    if (outOfGamut(result)) {
        float low = 0.0f;
        float high = 1.0f;
        for (int step = 0; step < 8; step++) {
            float middle = (low + high) * 0.5f;
            if (outOfGamut(labToLinear(light, chroma * middle))) high = middle;
            else low = middle;
        }
        result = labToLinear(light, chroma * low);
    }
    result = clamp(result, 0.0f, 1.0f);
    return coreimage::premultiply(float4(gammaChannel(result.r), gammaChannel(result.g), gammaChannel(result.b), base.a));
}

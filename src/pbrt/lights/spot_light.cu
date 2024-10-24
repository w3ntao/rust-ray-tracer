#include "pbrt/base/light.h"
#include "pbrt/lights/spot_light.h"
#include "pbrt/scene/parameter_dictionary.h"
#include "pbrt/spectrum_util/global_spectra.h"
#include "pbrt/spectrum_util/rgb_color_space.h"

SpotLight *SpotLight::create(const Transform &renderFromLight,
                             const ParameterDictionary &parameters,
                             std::vector<void *> &gpu_dynamic_pointers) {
    auto I = parameters.get_spectrum("I", SpectrumType::Illuminant, gpu_dynamic_pointers);
    if (I == nullptr) {
        I = parameters.global_spectra->rgb_color_space->illuminant;
    }

    auto sc = parameters.get_float("scale", 1.0);
    auto coneangle = parameters.get_float("coneangle", 30.0);
    auto conedelta = parameters.get_float("conedeltaangle", 5.0);

    // Compute spotlight rendering to light transformation
    Point3f from = parameters.get_point3("from", Point3f(0, 0, 0));
    Point3f to = parameters.get_point3("to", Point3f(0, 0, 1));

    auto dirToZ = Transform(Frame::from_z((to - from).normalize()));
    auto t = Transform::translate(from.x, from.y, from.z) * dirToZ.inverse();
    auto finalRenderFromLight = renderFromLight * t;

    sc /= I->to_photometric(parameters.global_spectra->cie_y);
    auto phi_v = parameters.get_float("power", -1);
    if (phi_v > 0) {
        auto cosFalloffEnd = std::cos(degree_to_radian(coneangle));
        auto cosFalloffStart = std::cos(degree_to_radian(coneangle - conedelta));
        auto k_e =
            2 * compute_pi() * ((1 - cosFalloffStart) + (cosFalloffStart - cosFalloffEnd) / 2);
        sc *= phi_v / k_e;
    }

    SpotLight *spot_light;
    CHECK_CUDA_ERROR(cudaMallocManaged(&spot_light, sizeof(SpotLight)));
    gpu_dynamic_pointers.push_back(spot_light);

    spot_light->init(finalRenderFromLight, I, sc, coneangle, coneangle - conedelta);

    return spot_light;
}

void SpotLight::init(const Transform &renderFromLight, const Spectrum *Iemit, FloatType _scale,
                     FloatType totalWidth, FloatType falloffStart) {
    this->light_type = LightType::delta_position;
    this->render_from_light = renderFromLight;

    this->i_emit = Iemit;
    this->scale = _scale;

    this->cosFalloffEnd = std::cos(degree_to_radian(totalWidth));
    this->cosFalloffStart = std::cos(degree_to_radian(falloffStart));
}

PBRT_GPU
SampledSpectrum SpotLight::l(Point3f p, Normal3f n, Point2f uv, Vector3f w,
                             const SampledWavelengths &lambda) const {
    REPORT_FATAL_ERROR();
    return {};
}

PBRT_GPU
cuda::std::optional<LightLiSample> SpotLight::sample_li(const LightSampleContext &ctx,
                                                        const Point2f &u,
                                                        SampledWavelengths &lambda) const {
    Point3f p = render_from_light(Point3f(0, 0, 0));
    Vector3f wi = (p - ctx.p()).normalize();
    // Compute incident radiance _Li_ for _SpotLight_

    Vector3f wLight = (render_from_light.apply_inverse(-wi)).normalize();

    SampledSpectrum Li = I(wLight, lambda) / (p - ctx.p()).squared_length();

    if (!Li.is_positive()) {
        return {};
    }

    return LightLiSample(Li, wi, 1, Interaction(p));
}

PBRT_GPU
FloatType SpotLight::pdf_li(const LightSampleContext &ctx, const Vector3f &wi,
                            bool allow_incomplete_pdf) const {
    return 0.0;
}

PBRT_CPU_GPU
SampledSpectrum SpotLight::phi(const SampledWavelengths &lambda) const {
    return scale * i_emit->sample(lambda) * 2 * compute_pi() *
           ((1 - cosFalloffStart) + (cosFalloffStart - cosFalloffEnd) / 2);
}

PBRT_GPU
SampledSpectrum SpotLight::I(const Vector3f &w, const SampledWavelengths &lambda) const {
    return smooth_step(w.cos_theta(), cosFalloffEnd, cosFalloffStart) * scale *
           i_emit->sample(lambda);
}
#include "pbrt/base/bsdf.h"

#include "pbrt/base/bxdf.h"
#include "pbrt/bxdfs/diffuse_bxdf.h"

PBRT_GPU
void BSDF::init_frame(const Normal3f &ns, const Vector3f &dpdus) {
    shading_frame = Frame::from_xz(dpdus.normalize(), ns.to_vector3());
}

PBRT_GPU
void BSDF::init_bxdf(const DiffuseBxDF *diffuse_bxdf) {
    bxdf.init(diffuse_bxdf);
}

PBRT_GPU
SampledSpectrum BSDF::f(const Vector3f &woRender, const Vector3f &wiRender,
                        const TransportMode mode) const {
    Vector3f wi = render_to_local(wiRender);
    Vector3f wo = render_to_local(woRender);

    if (wo.z == 0) {
        return SampledSpectrum::same_value(0.0);
    }

    return bxdf.f(wo, wi, mode);
}

PBRT_GPU
cuda::std::optional<BSDFSample> BSDF::sample_f(const Vector3f &wo_render, FloatType u,
                                               const Point2f &u2, TransportMode mode,
                                               BxDFReflTransFlags sample_flags) const {
    const auto wo = render_to_local(wo_render);
    if (bxdf.has_type_null()) {
        REPORT_FATAL_ERROR();
    }

    if (wo.z == 0 || !(bxdf.flags() & sample_flags)) {
        return {};
    }

    auto bs = bxdf.sample_f(wo, u, u2, mode, sample_flags);
    if (!bs || !bs->f.is_positive() || bs->pdf == 0 || bs->wi.z == 0) {
        return {};
    }

    bs->wi = local_to_render(bs->wi);
    return bs;
}

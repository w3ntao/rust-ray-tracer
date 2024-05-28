#pragma once

#include <cuda/std/optional>

#include "pbrt/base/light.h"
#include "pbrt/spectra/densely_sampled_spectrum.h"

class ParameterDict;
class RGBColorSpace;
class Spectrum;
class Shape;

namespace GPU {
class GlobalVariable;
}

class DiffuseAreaLight {
  public:
    void init(const Transform &render_from_light, const ParameterDict &parameters,
              const Shape *_shape, const GPU::GlobalVariable *global_variable);

    PBRT_GPU
    SampledSpectrum l(Point3f p, Normal3f n, Point2f uv, Vector3f w,
                      const SampledWavelengths &lambda) const;

    PBRT_GPU
    cuda::std::optional<LightLiSample> sample_li(const LightSampleContext &ctx, const Point2f &u,
                                                 SampledWavelengths &lambda,
                                                 bool allow_incomplete_pdf) const;

  private:
    LightBase light_base;
    const Shape *shape;
    FloatType area;
    bool two_sided;
    DenselySampledSpectrum l_emit;
    FloatType scale;
};
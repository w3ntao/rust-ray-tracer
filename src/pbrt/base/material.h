#pragma once

#include <optional>

#include "pbrt/util/macro.h"
#include "pbrt/spectrum_util/sampled_spectrum.h"

#include "pbrt/base/bsdf.h"
#include "pbrt/base/texture.h"
#include "pbrt/euclidean_space/vector3.h"
#include "pbrt/euclidean_space/normal3f.h"

struct MaterialEvalContext : public TextureEvalContext {
    // MaterialEvalContext Public Methods
    MaterialEvalContext() = default;

    PBRT_CPU_GPU
    MaterialEvalContext(const SurfaceInteraction &si)
        : TextureEvalContext(si), wo(si.wo), ns(si.shading.n), dpdus(si.shading.dpdu) {}

    Vector3f wo;
    Normal3f ns;
    Vector3f dpdus;
};

class DiffuseMaterial;
class DielectricMaterial;
class CoatedDiffuseMaterial;

class Material {
  public:
    enum class Type {
        diffuse,
        dielectric,
        coated_diffuse,
    };

    static const Material *create_diffuse_material(const SpectrumTexture *texture,
                                                   std::vector<void *> &gpu_dynamic_pointers);

    void init(const DiffuseMaterial *diffuse_material);

    void init(const DielectricMaterial *dielectric_material);

    void init(const CoatedDiffuseMaterial *coated_diffuse_material);

    PBRT_GPU
    DiffuseBxDF get_diffuse_bsdf(const MaterialEvalContext &ctx, SampledWavelengths &lambda) const;

    PBRT_GPU
    DielectricBxDF get_dielectric_bsdf(const MaterialEvalContext &ctx,
                                       SampledWavelengths &lambda) const;

    PBRT_GPU
    CoatedDiffuseBxDF get_coated_diffuse_bsdf(const MaterialEvalContext &ctx,
                                              SampledWavelengths &lambda) const;

    PBRT_CPU_GPU
    Type get_material_type() const {
        return type;
    }

  private:
    const void *ptr;
    Type type;
};

#include "pbrt/base/spectrum.h"

#include "pbrt/spectra/densely_sampled_spectrum.h"
#include "pbrt/spectra/const_spectrum.h"
#include "pbrt/spectra/rgb_illuminant_spectrum.h"
#include "pbrt/spectra/rgb_albedo_spectrum.h"

PBRT_CPU_GPU
void Spectrum::init(const DenselySampledSpectrum *densely_sampled_spectrum) {
    spectrum_type = Type::densely_sampled_spectrum;
    spectrum_ptr = densely_sampled_spectrum;
}

PBRT_CPU_GPU
void Spectrum::init(const ConstantSpectrum *constant_spectrum) {
    spectrum_type = Type::constant_spectrum;
    spectrum_ptr = constant_spectrum;
}

PBRT_CPU_GPU
void Spectrum::init(const RGBIlluminantSpectrum *rgb_illuminant_spectrum) {
    spectrum_type = Type::rgb_illuminant_spectrum;
    spectrum_ptr = rgb_illuminant_spectrum;
}

PBRT_CPU_GPU
void Spectrum::init(const RGBAlbedoSpectrum *rgb_albedo_spectrum) {
    spectrum_type = Type::rgb_albedo_spectrum;
    spectrum_ptr = rgb_albedo_spectrum;
}

PBRT_CPU_GPU
FloatType Spectrum::operator()(FloatType lambda) const {
    switch (spectrum_type) {
    case (Type::densely_sampled_spectrum): {
        return ((DenselySampledSpectrum *)spectrum_ptr)->operator()(lambda);
    }

    case (Type::constant_spectrum): {
        return ((ConstantSpectrum *)spectrum_ptr)->operator()(lambda);
    }

    case (Type::rgb_illuminant_spectrum): {
        return ((RGBIlluminantSpectrum *)spectrum_ptr)->operator()(lambda);
    }

    case (Type::rgb_albedo_spectrum): {
        return ((RGBAlbedoSpectrum *)spectrum_ptr)->operator()(lambda);
    }
    }

    REPORT_FATAL_ERROR();
    return NAN;
}

PBRT_CPU_GPU
SampledSpectrum Spectrum::sample(const SampledWavelengths &lambda) const {
    switch (spectrum_type) {
    case (Type::densely_sampled_spectrum): {
        return ((DenselySampledSpectrum *)spectrum_ptr)->sample(lambda);
    }

    case (Type::constant_spectrum): {
        return ((ConstantSpectrum *)spectrum_ptr)->sample(lambda);
    }

    case (Type::rgb_illuminant_spectrum): {
        return ((RGBIlluminantSpectrum *)spectrum_ptr)->sample(lambda);
    }

    case (Type::rgb_albedo_spectrum): {
        return ((RGBAlbedoSpectrum *)spectrum_ptr)->sample(lambda);
    }
    }

    REPORT_FATAL_ERROR();
    return SampledSpectrum::same_value(NAN);
}

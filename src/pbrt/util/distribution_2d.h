#pragma once

#include <pbrt/euclidean_space/point2.h>
#include <pbrt/gpu/macro.h>
#include <cuda/std/tuple>

class Distribution1D;
class GPUMemoryAllocator;

class Distribution2D {
  public:
    static const Distribution2D *create(const std::vector<std::vector<FloatType>> &data,
                                        GPUMemoryAllocator &allocator);

    void build(const std::vector<std::vector<FloatType>> &data, GPUMemoryAllocator &allocator);

    PBRT_CPU_GPU
    cuda::std::pair<Point2f, FloatType> sample(const Point2f &uv) const;

    PBRT_CPU_GPU
    FloatType get_pdf(const Point2f &u) const;

  private:
    const FloatType *cdf;
    const FloatType *pmf;

    Distribution1D *distribution_1d_list;

    Point2i dimension;
};

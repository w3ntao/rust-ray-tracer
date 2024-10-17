#pragma once

#include "pbrt/euclidean_space/bounds2.h"
#include <vector>

template <typename T>
class Array2D {
    // TODO: progress 2024/10/18: implement Array2D

  public:
    void init(int nx, int ny, std::vector<void *> &gpu_dynamic_pointers) {
        CHECK_CUDA_ERROR(cudaMallocManaged(&values, sizeof(T) * nx * ny));
        gpu_dynamic_pointers.push_back(values);

        extent.p_min = {0, 0};
        extent.p_max = {nx, ny};
    }

    PBRT_CPU_GPU
    const FloatType *get_values_ptr() const {
        return values;
    }

    PBRT_CPU_GPU
    int size() const {
        return extent.area();
    }

    PBRT_CPU_GPU
    int x_size() const {
        return extent.p_max.x - extent.p_min.x;
    }

    PBRT_CPU_GPU
    int y_size() const {
        return extent.p_max.y - extent.p_min.y;
    }

    PBRT_CPU_GPU
    T &operator[](Point2i p) {
        p.x -= extent.p_min.x;
        p.y -= extent.p_min.y;
        return values[p.x + (extent.p_max.x - extent.p_min.x) * p.y];
    }

    PBRT_CPU_GPU
    T &operator()(int x, int y) {
        return (*this)[{x, y}];
    }

    PBRT_CPU_GPU
    const T operator()(int x, int y) const {
        return (*this)[{x, y}];
    }

    PBRT_CPU_GPU
    const T operator[](Point2i p) const {
        p.x -= extent.p_min.x;
        p.y -= extent.p_min.y;
        return values[p.x + (extent.p_max.x - extent.p_min.x) * p.y];
    }

  private:
    Bounds2i extent;
    T *values;
};
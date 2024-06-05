#include "pbrt/accelerator/hlbvh.h"

#include <chrono>

#include "pbrt/util/stack.h"
#include "pbrt/util/thread_pool.h"

constexpr int MORTON_SCALE = 1 << TREELET_MORTON_BITS_PER_DIMENSION;

constexpr uint NUM_BUCKETS = 64;

PBRT_CPU_GPU
uint morton_code_to_treelet_idx(const uint morton_code) {
    const auto masked_morton_code = morton_code & TREELET_MASK;

    return masked_morton_code >>
           (3 * TREELET_MORTON_BITS_PER_DIMENSION - BIT_LENGTH_OF_TREELET_MASK);
}

template <typename T>
__global__ void init_array(T *array, const T val, const uint length) {
    const uint worker_idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (worker_idx >= length) {
        return;
    }

    array[worker_idx] = val;
}

__global__ void sort_morton_primitives(MortonPrimitive *out, const MortonPrimitive *in,
                                       uint *counter, const uint *offset,
                                       const uint num_primitives) {
    const uint worker_idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (worker_idx >= num_primitives) {
        return;
    }

    const auto primitive = &in[worker_idx];
    const uint treelet_idx = morton_code_to_treelet_idx(primitive->morton_code);

    const uint sorted_idx = atomicAdd(&counter[treelet_idx], 1) + offset[treelet_idx];
    out[sorted_idx] = *primitive;
}

__global__ void count_primitives_for_treelets(uint *counter,
                                              const MortonPrimitive *morton_primitives,
                                              const uint num_primitives) {
    const uint worker_idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (worker_idx >= num_primitives) {
        return;
    }

    const uint morton_code = morton_primitives[worker_idx].morton_code;
    const uint treelet_idx = morton_code_to_treelet_idx(morton_code);
    atomicAdd(&counter[treelet_idx], 1);
}

__global__ void compute_treelet_bounds(Treelet *treelets,
                                       const MortonPrimitive *morton_primitives) {
    const uint worker_idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (worker_idx >= MAX_TREELET_NUM) {
        return;
    }

    const uint start = treelets[worker_idx].first_primitive_offset;
    const uint end =
        treelets[worker_idx].first_primitive_offset + treelets[worker_idx].n_primitives;

    Bounds3f bounds;
    for (uint primitive_idx = start; primitive_idx < end; ++primitive_idx) {
        bounds += morton_primitives[primitive_idx].bounds;
    }

    treelets[worker_idx].bounds = bounds;
}

__global__ void hlbvh_init_morton_primitives(MortonPrimitive *morton_primitives,
                                             const Primitive **primitives, uint num_primitives) {
    const uint worker_idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (worker_idx >= num_primitives) {
        return;
    }

    morton_primitives[worker_idx].primitive_idx = worker_idx;

    const auto _bounds = primitives[worker_idx]->bounds();

    morton_primitives[worker_idx].bounds = _bounds;
    morton_primitives[worker_idx].centroid = _bounds.centroid();
}

__global__ void hlbvh_init_treelets(Treelet *treelets) {
    const uint worker_idx = blockIdx.x * blockDim.x + threadIdx.x;

    if (worker_idx >= MAX_TREELET_NUM) {
        return;
    }

    treelets[worker_idx].first_primitive_offset = std::numeric_limits<uint>::max();
    treelets[worker_idx].n_primitives = 0;
}

__global__ void hlbvh_compute_morton_code(MortonPrimitive *morton_primitives,
                                          uint num_total_primitives,
                                          const Bounds3f bounds_of_centroids) {
    const uint worker_idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (worker_idx >= num_total_primitives) {
        return;
    }

    // compute morton code for each primitive
    auto centroid_offset = bounds_of_centroids.offset(morton_primitives[worker_idx].centroid);

    auto scaled_offset = centroid_offset * MORTON_SCALE;
    morton_primitives[worker_idx].morton_code = encode_morton3(
        uint32_t(scaled_offset.x), uint32_t(scaled_offset.y), uint32_t(scaled_offset.z));
}

__global__ void hlbvh_build_bottom_bvh(HLBVH *bvh, const BottomBVHArgs *bvh_args_array,
                                       uint array_length) {
    bvh->build_bottom_bvh(bvh_args_array, array_length);
}

__global__ void init_bvh_args(BottomBVHArgs *bvh_args_array, const BVHBuildNode *bvh_build_nodes,
                              uint *shared_offset, const uint start, const uint end) {
    const uint worker_idx = blockIdx.x * blockDim.x + threadIdx.x;
    const uint total_jobs = end - start;
    if (worker_idx >= total_jobs) {
        return;
    }

    const uint build_node_idx = worker_idx + start;
    const auto &node = bvh_build_nodes[build_node_idx];

    if (!node.is_leaf() || node.num_primitives <= MAX_PRIMITIVES_NUM_IN_LEAF) {
        bvh_args_array[worker_idx].expand_leaf = false;
        return;
    }

    bvh_args_array[worker_idx].expand_leaf = true;
    bvh_args_array[worker_idx].build_node_idx = build_node_idx;
    bvh_args_array[worker_idx].left_child_idx = atomicAdd(shared_offset, 2);
    // 2 pointers: one for left and another right child
}

PBRT_GPU
void HLBVH::build_bottom_bvh(const BottomBVHArgs *bvh_args_array, uint array_length) {
    const uint worker_idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (worker_idx >= array_length) {
        return;
    }

    const auto &args = bvh_args_array[worker_idx];

    if (!args.expand_leaf) {
        return;
    }

    const auto &node = build_nodes[args.build_node_idx];
    uint left_child_idx = args.left_child_idx + 0;
    uint right_child_idx = args.left_child_idx + 1;

    Bounds3f bounds_of_centroid;
    for (uint morton_idx = node.first_primitive_idx;
         morton_idx < node.first_primitive_idx + node.num_primitives; morton_idx++) {
        bounds_of_centroid += morton_primitives[morton_idx].centroid;
    }

    auto split_dimension = bounds_of_centroid.max_dimension();
    auto split_val = bounds_of_centroid.centroid()[split_dimension];

    uint mid_idx = partition_morton_primitives(node.first_primitive_idx,
                                               node.first_primitive_idx + node.num_primitives,
                                               split_dimension, split_val);

    if (DEBUGGING) {
        bool kill_thread = false;

        if (mid_idx < node.first_primitive_idx ||
            mid_idx > node.first_primitive_idx + node.num_primitives) {
            printf("ERROR in partitioning at node[%u]: mid_idx out of bound\n",
                   args.build_node_idx);
            kill_thread = true;
        }

        for (uint morton_idx = node.first_primitive_idx; morton_idx < mid_idx; morton_idx++) {
            if (morton_primitives[morton_idx].centroid[split_dimension] >= split_val) {
                printf("ERROR in partitioning (1st half) at node[%u], idx: %u\n",
                       args.build_node_idx, morton_idx);
                kill_thread = true;
            }
        }

        for (uint morton_idx = mid_idx; morton_idx < node.first_primitive_idx + node.num_primitives;
             morton_idx++) {
            if (morton_primitives[morton_idx].centroid[split_dimension] < split_val) {
                printf("ERROR in partitioning (2nd half) at node[%u], idx: %u\n",
                       args.build_node_idx, morton_idx);
                kill_thread = true;
            }
        }

        if (kill_thread) {
            REPORT_FATAL_ERROR();
        }
    }

    if (mid_idx == node.first_primitive_idx ||
        mid_idx == node.first_primitive_idx + node.num_primitives) {
        // all primitives' centroids grouped either left or right half
        // there is no need to separate them

        build_nodes[left_child_idx].num_primitives = 0;
        build_nodes[right_child_idx].num_primitives = 0;

        return;
    }

    Bounds3f left_bounds;
    for (uint morton_idx = node.first_primitive_idx; morton_idx < mid_idx; morton_idx++) {
        left_bounds += morton_primitives[morton_idx].bounds;
    }

    Bounds3f right_bounds;
    for (uint morton_idx = mid_idx; morton_idx < node.first_primitive_idx + node.num_primitives;
         morton_idx++) {
        right_bounds += morton_primitives[morton_idx].bounds;
    }

    build_nodes[left_child_idx].init_leaf(node.first_primitive_idx,
                                          mid_idx - node.first_primitive_idx, left_bounds);
    build_nodes[right_child_idx].init_leaf(
        mid_idx, node.num_primitives - (mid_idx - node.first_primitive_idx), right_bounds);

    build_nodes[args.build_node_idx].init_interior(split_dimension, left_child_idx,
                                                   left_bounds + right_bounds);
}

PBRT_GPU bool HLBVH::fast_intersect(const Ray &ray, FloatType t_max) const {
    auto d = ray.d;
    auto inv_dir = Vector3f(1.0 / d.x, 1.0 / d.y, 1.0 / d.z);
    int dir_is_neg[3] = {
        int(inv_dir.x < 0.0),
        int(inv_dir.y < 0.0),
        int(inv_dir.z < 0.0),
    };

    Stack<uint, 128> nodes_to_visit;
    nodes_to_visit.push(0);
    while (true) {
        if (nodes_to_visit.empty()) {
            return false;
        }
        auto current_node_idx = nodes_to_visit.pop();

        const auto node = build_nodes[current_node_idx];
        if (!node.bounds.fast_intersect(ray, t_max, inv_dir, dir_is_neg)) {
            continue;
        }

        if (node.is_leaf()) {
            for (uint morton_idx = node.first_primitive_idx;
                 morton_idx < node.first_primitive_idx + node.num_primitives; morton_idx++) {
                const uint primitive_idx = morton_primitives[morton_idx].primitive_idx;
                auto const primitive = primitives[primitive_idx];

                if (primitive->fast_intersect(ray, t_max)) {
                    return true;
                }
            }
            continue;
        }

        if (dir_is_neg[node.axis] > 0) {
            nodes_to_visit.push(node.left_child_idx);
            nodes_to_visit.push(node.left_child_idx + 1);
        } else {
            nodes_to_visit.push(node.left_child_idx + 1);
            nodes_to_visit.push(node.left_child_idx);
        }
    }

    return false;
}

PBRT_GPU cuda::std::optional<ShapeIntersection> HLBVH::intersect(const Ray &ray,
                                                                 FloatType t_max) const {
    cuda::std::optional<ShapeIntersection> best_intersection = {};
    auto best_t = t_max;

    auto d = ray.d;
    auto inv_dir = Vector3f(1.0 / d.x, 1.0 / d.y, 1.0 / d.z);
    int dir_is_neg[3] = {
        int(inv_dir.x < 0.0),
        int(inv_dir.y < 0.0),
        int(inv_dir.z < 0.0),
    };

    Stack<uint, 128> nodes_to_visit;
    nodes_to_visit.push(0);

    while (true) {
        if (nodes_to_visit.empty()) {
            break;
        }
        auto current_node_idx = nodes_to_visit.pop();

        const auto node = build_nodes[current_node_idx];
        if (!node.bounds.fast_intersect(ray, best_t, inv_dir, dir_is_neg)) {
            continue;
        }

        if (node.is_leaf()) {
            for (uint morton_idx = node.first_primitive_idx;
                 morton_idx < node.first_primitive_idx + node.num_primitives; morton_idx++) {
                const uint primitive_idx = morton_primitives[morton_idx].primitive_idx;
                auto const primitive = primitives[primitive_idx];

                auto intersection = primitive->intersect(ray, best_t);
                if (!intersection) {
                    continue;
                }

                best_t = intersection->t_hit;
                best_intersection = intersection;
            }
            continue;
        }

        if (dir_is_neg[node.axis] > 0) {
            nodes_to_visit.push(node.left_child_idx);
            nodes_to_visit.push(node.left_child_idx + 1);
        } else {
            nodes_to_visit.push(node.left_child_idx + 1);
            nodes_to_visit.push(node.left_child_idx);
        }
    }

    return best_intersection;
};

void HLBVH::build_bvh(ThreadPool &thread_pool, std::vector<void *> &gpu_dynamic_pointers,
                      const std::vector<const Primitive *> &gpu_primitives) {
    auto start_sorting = std::chrono::system_clock::now();

    uint num_total_primitives = gpu_primitives.size();

    printf("\ntotal primitives: %u\n", num_total_primitives);

    MortonPrimitive *gpu_morton_primitives;
    CHECK_CUDA_ERROR(
        cudaMallocManaged(&gpu_morton_primitives, sizeof(MortonPrimitive) * num_total_primitives));

    CHECK_CUDA_ERROR(cudaGetLastError());
    CHECK_CUDA_ERROR(cudaDeviceSynchronize());

    const Primitive **gpu_primitives_array;
    CHECK_CUDA_ERROR(
        cudaMallocManaged(&gpu_primitives_array, sizeof(Primitive *) * num_total_primitives));
    CHECK_CUDA_ERROR(cudaMemcpy(gpu_primitives_array, gpu_primitives.data(),
                                sizeof(Primitive *) * num_total_primitives,
                                cudaMemcpyHostToDevice));

    Treelet *sparse_treelets;
    CHECK_CUDA_ERROR(cudaMallocManaged(&sparse_treelets, sizeof(Treelet) * MAX_TREELET_NUM));

    CHECK_CUDA_ERROR(cudaGetLastError());
    CHECK_CUDA_ERROR(cudaDeviceSynchronize());

    gpu_dynamic_pointers.push_back(gpu_morton_primitives);
    gpu_dynamic_pointers.push_back(gpu_primitives_array);

    this->init(gpu_primitives_array, gpu_morton_primitives);

    {
        uint threads = 1024;
        uint blocks = divide_and_ceil(num_total_primitives, threads);
        hlbvh_init_morton_primitives<<<blocks, threads>>>(morton_primitives, primitives,
                                                          num_total_primitives);
    }

    {
        uint threads = 1024;
        uint blocks = divide_and_ceil(MAX_TREELET_NUM, threads);
        hlbvh_init_treelets<<<blocks, threads>>>(sparse_treelets);
    }

    CHECK_CUDA_ERROR(cudaGetLastError());
    CHECK_CUDA_ERROR(cudaDeviceSynchronize());

    Bounds3f bounds_of_primitives_centroids;
    for (uint idx = 0; idx < num_total_primitives; idx++) {
        bounds_of_primitives_centroids += gpu_morton_primitives[idx].bounds.centroid();
    }

    {
        uint batch_size = 512;
        uint blocks = divide_and_ceil(num_total_primitives, batch_size);
        hlbvh_compute_morton_code<<<blocks, batch_size>>>(morton_primitives, num_total_primitives,
                                                          bounds_of_primitives_centroids);
        CHECK_CUDA_ERROR(cudaGetLastError());
        CHECK_CUDA_ERROR(cudaDeviceSynchronize());
    }

    uint *primitives_counter;
    uint *primitives_indices_offset;
    CHECK_CUDA_ERROR(cudaMallocManaged(&primitives_counter, sizeof(uint) * MAX_TREELET_NUM));
    CHECK_CUDA_ERROR(cudaMallocManaged(&primitives_indices_offset, sizeof(uint) * MAX_TREELET_NUM));

    {
        const uint threads = 1024;
        const uint blocks = divide_and_ceil(MAX_TREELET_NUM, threads);

        init_array<<<blocks, threads>>>(primitives_counter, uint(0), MAX_TREELET_NUM);
        init_array<<<blocks, threads>>>(primitives_indices_offset, uint(0), MAX_TREELET_NUM);
        CHECK_CUDA_ERROR(cudaGetLastError());
        CHECK_CUDA_ERROR(cudaDeviceSynchronize());
    }

    {
        const uint threads = 1024;
        const uint blocks = divide_and_ceil(num_total_primitives, threads);
        count_primitives_for_treelets<<<blocks, threads>>>(primitives_counter, morton_primitives,
                                                           num_total_primitives);

        CHECK_CUDA_ERROR(cudaGetLastError());
        CHECK_CUDA_ERROR(cudaDeviceSynchronize());
    }
    for (uint idx = 1; idx < MAX_TREELET_NUM; ++idx) {
        primitives_indices_offset[idx] =
            primitives_indices_offset[idx - 1] + primitives_counter[idx - 1];
    }

    {
        const uint threads = 1024;
        const uint blocks = divide_and_ceil(MAX_TREELET_NUM, threads);

        init_array<<<blocks, threads>>>(primitives_counter, uint(0), MAX_TREELET_NUM);
        CHECK_CUDA_ERROR(cudaGetLastError());
        CHECK_CUDA_ERROR(cudaDeviceSynchronize());
    }

    MortonPrimitive *buffer_morton_primitives;
    CHECK_CUDA_ERROR(cudaMallocManaged(&buffer_morton_primitives,
                                       sizeof(MortonPrimitive) * num_total_primitives));

    {
        const uint threads = 1024;
        const uint blocks = divide_and_ceil(num_total_primitives, threads);
        sort_morton_primitives<<<blocks, threads>>>(buffer_morton_primitives, morton_primitives,
                                                    primitives_counter, primitives_indices_offset,
                                                    num_total_primitives);
        CHECK_CUDA_ERROR(cudaGetLastError());
        CHECK_CUDA_ERROR(cudaDeviceSynchronize());
    }

    CHECK_CUDA_ERROR(cudaMemcpy(morton_primitives, buffer_morton_primitives,
                                sizeof(MortonPrimitive) * num_total_primitives,
                                cudaMemcpyDeviceToDevice));

    for (uint treelet_idx = 0; treelet_idx < MAX_TREELET_NUM; ++treelet_idx) {
        sparse_treelets[treelet_idx].first_primitive_offset =
            primitives_indices_offset[treelet_idx];
        sparse_treelets[treelet_idx].n_primitives = primitives_counter[treelet_idx];
        // bounds is not computed so far
    }
    {
        // compute bounds
        const uint threads = 1024;
        const uint blocks = divide_and_ceil(MAX_TREELET_NUM, threads);
        compute_treelet_bounds<<<blocks, threads>>>(sparse_treelets, morton_primitives);
        CHECK_CUDA_ERROR(cudaGetLastError());
        CHECK_CUDA_ERROR(cudaDeviceSynchronize());
    }

    CHECK_CUDA_ERROR(cudaFree(primitives_counter));
    CHECK_CUDA_ERROR(cudaFree(primitives_indices_offset));
    CHECK_CUDA_ERROR(cudaFree(buffer_morton_primitives));

    std::vector<uint> dense_treelet_indices;
    uint max_primitive_num_in_a_treelet = 0;
    {
        uint verify_counter = 0;
        for (uint idx = 0; idx < MAX_TREELET_NUM; idx++) {
            uint current_treelet_primitives_num = sparse_treelets[idx].n_primitives;
            if (current_treelet_primitives_num <= 0) {
                continue;
            }

            verify_counter += current_treelet_primitives_num;

            max_primitive_num_in_a_treelet =
                std::max(max_primitive_num_in_a_treelet, current_treelet_primitives_num);
            dense_treelet_indices.push_back(idx);
        }

        if (verify_counter != num_total_primitives) {
            REPORT_FATAL_ERROR();
        }

        printf("HLBVH: %zu/%d treelets filled (max primitives in a treelet: %d)\n",
               dense_treelet_indices.size(), MAX_TREELET_NUM, max_primitive_num_in_a_treelet);
    }

    Treelet *dense_treelets;
    CHECK_CUDA_ERROR(
        cudaMallocManaged(&dense_treelets, sizeof(Treelet) * dense_treelet_indices.size()));

    for (uint idx = 0; idx < dense_treelet_indices.size(); idx++) {
        uint sparse_idx = dense_treelet_indices[idx];
        CHECK_CUDA_ERROR(cudaMemcpy(&dense_treelets[idx], &sparse_treelets[sparse_idx],
                                    sizeof(Treelet), cudaMemcpyDeviceToDevice));
    }
    CHECK_CUDA_ERROR(cudaFree(sparse_treelets));

    uint max_build_node_length =
        (2 * dense_treelet_indices.size() + 1) + (2 * num_total_primitives + 1);
    CHECK_CUDA_ERROR(cudaMallocManaged(&build_nodes, sizeof(BVHBuildNode) * max_build_node_length));
    gpu_dynamic_pointers.push_back(build_nodes);

    auto start_top_bvh = std::chrono::system_clock::now();

    const uint top_bvh_node_num =
        build_top_bvh_for_treelets(thread_pool, dense_treelet_indices.size(), dense_treelets);
    CHECK_CUDA_ERROR(cudaFree(dense_treelets));

    auto start_bottom_bvh = std::chrono::system_clock::now();

    uint start = 0;
    uint end = top_bvh_node_num;

    uint *shared_offset;
    CHECK_CUDA_ERROR(cudaMallocManaged(&shared_offset, sizeof(uint)));
    *shared_offset = end;

    uint depth = 0;
    while (end > start) {
        const uint array_length = end - start;

        BottomBVHArgs *bvh_args_array;
        CHECK_CUDA_ERROR(cudaMallocManaged(&bvh_args_array, sizeof(BottomBVHArgs) * array_length));

        {
            uint threads = 1024;
            uint blocks = divide_and_ceil(uint(end - start), threads);
            init_bvh_args<<<blocks, threads>>>(bvh_args_array, build_nodes, shared_offset, start,
                                               end);
        }

        CHECK_CUDA_ERROR(cudaGetLastError());
        CHECK_CUDA_ERROR(cudaDeviceSynchronize());

        if (DEBUGGING) {
            printf("HLBVH: building bottom BVH: depth %u, node number: %u\n", depth, array_length);
        }

        depth += 1;
        start = end;
        end = *shared_offset;

        uint threads = 512;
        uint blocks = divide_and_ceil(array_length, threads);

        hlbvh_build_bottom_bvh<<<blocks, threads>>>(this, bvh_args_array, array_length);
        CHECK_CUDA_ERROR(cudaGetLastError());
        CHECK_CUDA_ERROR(cudaDeviceSynchronize());

        CHECK_CUDA_ERROR(cudaFree(bvh_args_array));
    }
    CHECK_CUDA_ERROR(cudaFree(shared_offset));

    printf("HLBVH: bottom BVH nodes: %u, max depth: %u, max primitives in a leaf: %u\n",
           end - top_bvh_node_num, depth, MAX_PRIMITIVES_NUM_IN_LEAF);
    printf("HLBVH: total nodes: %u/%u\n", end, max_build_node_length);

    const std::chrono::duration<FloatType> duration_sorting{start_top_bvh - start_sorting};

    const std::chrono::duration<FloatType> duration_top_bvh{start_bottom_bvh - start_sorting};

    const std::chrono::duration<FloatType> duration_bottom_bvh{std::chrono::system_clock::now() -
                                                               start_bottom_bvh};

    printf("BVH constructing took %.2f seconds "
           "(sorting: %.2f, top BVH building: %.2f, bottom BVH building: %.2f)\n",
           (duration_sorting + duration_top_bvh + duration_bottom_bvh).count(),
           duration_sorting.count(), duration_top_bvh.count(), duration_bottom_bvh.count());
}

uint HLBVH::build_top_bvh_for_treelets(ThreadPool &thread_pool, uint num_dense_treelets,
                                       const Treelet *treelets) {
    std::vector<uint> treelet_indices;
    treelet_indices.reserve(num_dense_treelets);
    for (uint idx = 0; idx < num_dense_treelets; idx++) {
        treelet_indices.emplace_back(idx);
    }

    std::vector<TopBVHArgs> next_level_args = {TopBVHArgs{
        .build_node_idx = 0,
        .treelet_indices = treelet_indices,
    }};

    uint depth = 0;
    std::atomic_int node_count = 1; // for the root
    uint current_node_num = 0;

    while (node_count.load() > current_node_num) {
        if (DEBUGGING) {
            printf("HLBVH: building top BVH: depth %d: nodes: %zu\n", depth,
                   next_level_args.size());
        }
        depth += 1;

        const auto current_level_args = std::move(next_level_args);
        next_level_args =
            std::vector<TopBVHArgs>((node_count.load() - current_node_num) * 2, TopBVHArgs{});

        current_node_num = node_count.load();

        thread_pool.parallel_execute(
            0, current_level_args.size(),
            [this, &current_level_args, &next_level_args, &treelets, &node_count,
             current_node_num](const int idx) {
                if (current_level_args[idx].treelet_indices.empty()) {
                    return;
                }
                this->build_upper_sah(current_level_args[idx], treelets, std::ref(next_level_args),
                                      std::ref(node_count), current_node_num);
            });
    }
    printf("HLBVH: build top BVH with SAH: (number of buckets: %d)\n", NUM_BUCKETS);
    printf("HLBVH: top BVH nodes: %u, max depth: %u\n", node_count.load(), depth);

    return node_count.load();
}

void HLBVH::build_upper_sah(const TopBVHArgs &args, const Treelet *treelets,
                            std::vector<TopBVHArgs> &next_level_args, std::atomic_int &node_count,
                            uint offset) {
    const auto treelet_indices = args.treelet_indices;
    const auto build_node_idx = args.build_node_idx;

    if (treelet_indices.size() == 1) {
        uint treelet_idx = treelet_indices[0];
        const auto &current_treelet = treelets[treelet_idx];

        build_nodes[build_node_idx].init_leaf(current_treelet.first_primitive_offset,
                                              current_treelet.n_primitives, current_treelet.bounds);
        return;
    }

    Bounds3f full_bounds_of_current_level;
    Bounds3f bounds_of_centroid;
    for (const auto treelet_idx : treelet_indices) {
        bounds_of_centroid += treelets[treelet_idx].bounds.centroid();
        full_bounds_of_current_level += treelets[treelet_idx].bounds;
    }

    const uint8_t split_axis = bounds_of_centroid.max_dimension();

    if (bounds_of_centroid.p_min[split_axis] == bounds_of_centroid.p_max[split_axis]) {
        // when the bounds is of zero volume
        // should build everything into one leaf?
        REPORT_FATAL_ERROR();
    }

    struct BVHSplitBucket {
        uint count = 0;
        Bounds3f bounds = Bounds3f ::empty();
        std::vector<uint> treelet_indices;
    };
    BVHSplitBucket buckets[NUM_BUCKETS];

    const auto base_val = bounds_of_centroid.p_min[split_axis];
    const auto span = bounds_of_centroid.p_max[split_axis] - bounds_of_centroid.p_min[split_axis];

    // Initialize _BVHSplitBucket_ for HLBVH SAH partition buckets
    for (unsigned int treelet_idx : treelet_indices) {
        const auto treelet = &treelets[treelet_idx];

        auto centroid_val = treelet->bounds.centroid()[split_axis];
        uint bucket_idx = NUM_BUCKETS * ((centroid_val - base_val) / span);

        if (bucket_idx > NUM_BUCKETS) {
            REPORT_FATAL_ERROR();
        }
        if (bucket_idx == NUM_BUCKETS) {
            bucket_idx = NUM_BUCKETS - 1;
        }

        buckets[bucket_idx].count += treelet->n_primitives;
        buckets[bucket_idx].bounds += treelet->bounds;
        buckets[bucket_idx].treelet_indices.emplace_back(treelet_idx);
    }

    const auto total_surface_area = full_bounds_of_current_level.surface_area();

    // Compute costs for splitting after each bucket
    FloatType sah_cost[NUM_BUCKETS - 1];
    for (uint split_idx = 0; split_idx < NUM_BUCKETS - 1; ++split_idx) {
        Bounds3f bounds_left;
        Bounds3f bounds_right;
        uint count_left = 0;
        uint count_right = 0;

        for (uint left = 0; left <= split_idx; ++left) {
            bounds_left += buckets[left].bounds;
            count_left += buckets[left].count;
        }

        for (uint right = split_idx + 1; right < NUM_BUCKETS; ++right) {
            bounds_right += buckets[right].bounds;
            count_right += buckets[right].count;
        }

        sah_cost[split_idx] = 0.125 + (count_left * bounds_left.surface_area() +
                                       count_right * bounds_right.surface_area()) /
                                          total_surface_area;
    }

    // Find bucket to split at that minimizes SAH metric
    FloatType min_cost_so_far = sah_cost[0];
    uint min_cost_split = 0;
    for (uint idx = 1; idx < NUM_BUCKETS - 1; ++idx) {
        if (sah_cost[idx] < min_cost_so_far) {
            min_cost_so_far = sah_cost[idx];
            min_cost_split = idx;
        }
    }

    std::vector<uint> left_indices;
    std::vector<uint> right_indices;
    left_indices.reserve(treelet_indices.size());
    right_indices.reserve(treelet_indices.size());

    for (uint idx = 0; idx <= min_cost_split; ++idx) {
        left_indices.insert(left_indices.end(), buckets[idx].treelet_indices.begin(),
                            buckets[idx].treelet_indices.end());
    }

    for (uint idx = min_cost_split + 1; idx < NUM_BUCKETS; ++idx) {
        right_indices.insert(right_indices.end(), buckets[idx].treelet_indices.begin(),
                             buckets[idx].treelet_indices.end());
    }

    if (left_indices.empty() || right_indices.empty()) {
        // when SAH couldn't build a valid tree: fall back to MidSplit
        left_indices.clear();
        right_indices.clear();

        auto split_val = bounds_of_centroid.centroid()[split_axis];
        for (const auto idx : treelet_indices) {
            if (treelets[idx].bounds.centroid()[split_axis] < split_val) {
                left_indices.emplace_back(idx);
            } else {
                right_indices.emplace_back(idx);
            }
        }

        if (left_indices.empty() || right_indices.empty()) {
            // if MidSplit still couldn't divide them:
            // should build everything into one leaf?
            REPORT_FATAL_ERROR();
        }
    }

    if (DEBUGGING) {
        // check missing indices
        std::vector<uint> combined_indices = left_indices;
        combined_indices.insert(combined_indices.end(), right_indices.begin(), right_indices.end());

        auto treelet_indices_copy = treelet_indices;
        std::sort(treelet_indices_copy.begin(), treelet_indices_copy.end());
        std::sort(combined_indices.begin(), combined_indices.end());

        if (treelet_indices_copy != combined_indices) {
            printf("%s(): SAH-BVH not split right\n", __func__);
            REPORT_FATAL_ERROR();
        }
    }

    const uint left_build_node_idx = node_count.fetch_add(2);
    const uint right_build_node_idx = left_build_node_idx + 1;

    build_nodes[build_node_idx].init_interior(split_axis, left_build_node_idx,
                                              full_bounds_of_current_level);

    next_level_args[left_build_node_idx - offset].build_node_idx = left_build_node_idx;
    next_level_args[left_build_node_idx - offset].treelet_indices = left_indices;

    next_level_args[right_build_node_idx - offset].build_node_idx = right_build_node_idx;
    next_level_args[right_build_node_idx - offset].treelet_indices = right_indices;
}

PBRT_GPU
uint HLBVH::partition_morton_primitives(const uint start, const uint end,
                                        const uint8_t split_dimension, const FloatType split_val) {
    // taken and modified from
    // https://users.cs.duke.edu/~reif/courses/alglectures/littman.lectures/lect05/node27.html

    uint left = start;
    uint right = end - 1;

    while (true) {
        while (morton_primitives[right].centroid[split_dimension] >= split_val && right > start) {
            right--;
        }

        while (morton_primitives[left].centroid[split_dimension] < split_val && left < end - 1) {
            left++;
        }

        if (left < right) {
            pstd::swap(morton_primitives[left], morton_primitives[right]);
            continue;
        }

        if (left == start && right == start) {
            return start;
        }

        return right + 1;
    }
}

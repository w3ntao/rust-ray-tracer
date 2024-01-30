#pragma once

#include "pbrt/shapes/triangle.h"

class Aggregate {
  private:
    struct NodeOfShape {
        const Shape *shape;
        NodeOfShape *next;

        PBRT_GPU explicit NodeOfShape(const Shape *_shape) : shape(_shape), next(nullptr) {}

        PBRT_GPU ~NodeOfShape() {
            if (next != nullptr) {
                delete next;
            }
        }
    };

  public:
    const Shape **shapes = nullptr; // a list of Shape ptr
    int shape_num;

    NodeOfShape *head_of_shapes = nullptr;
    NodeOfShape *tail_of_shapes = nullptr;

    PBRT_GPU Aggregate() : shape_num(0) {
        head_of_shapes = new NodeOfShape(nullptr);
        tail_of_shapes = head_of_shapes;
    }

    PBRT_GPU ~Aggregate() {
        for (int i = 0; i < shape_num; ++i) {
            delete shapes[i];
        }
        delete[] shapes;

        delete head_of_shapes;
    }

    PBRT_GPU void add_triangles(const TriangleMesh *mesh) {
        for (int i = 0; i < mesh->triangle_num; ++i) {
            auto triangle = new Triangle(i, mesh);
            auto new_tail = new NodeOfShape(triangle);

            tail_of_shapes->next = new_tail;
            tail_of_shapes = new_tail;

            shape_num += 1;
        }
    }

    PBRT_GPU void preprocess() {
        auto temp_shapes = new Shape const *[shape_num];

        auto node = head_of_shapes->next;
        for (int i = 0; i < shape_num; i++) {
            temp_shapes[i] = node->shape;
            node = node->next;
        }

        shapes = temp_shapes;

        printf("total primitives: %d\n", shape_num);
    }

    PBRT_GPU std::optional<ShapeIntersection> intersect(const Ray &ray) const {
        double best_t = Infinity;
        std::optional<ShapeIntersection> best_intersection = {};
        for (int idx = 0; idx < shape_num; idx++) {
            const auto shape_intersection = shapes[idx]->intersect(ray);

            if (!shape_intersection || shape_intersection->t_hit > best_t) {
                continue;
            }

            best_t = shape_intersection->t_hit;
            best_intersection = shape_intersection;
        }

        return best_intersection;
    }
};

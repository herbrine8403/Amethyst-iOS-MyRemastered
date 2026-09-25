// SimpleFPEWrapper - SimpleFPEWrapper/fpe/evaluators.cpp
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

// GL evaluators (plans/10, 10.2): Bezier maps evaluated on the CPU with
// de Casteljau's algorithm, feeding the immediate-mode current-value path
// exactly as the spec defines (glEvalCoord behaves like the corresponding
// glColor/glTexCoord/glNormal/glVertex sequence).

#include "fpe.hpp"
#include "drawing1x.h"
#include "list.h"
#include "../log.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <vector>

namespace {

struct evaluator_map_t {
    bool valid = false;
    int components = 0;
    GLfloat u1 = 0.0f, u2 = 1.0f, v1 = 0.0f, v2 = 1.0f;
    GLint uorder = 0, vorder = 0;
    std::vector<GLfloat> points; // [v][u][component] for map2, [u][component] for map1
};

struct evaluator_state_t {
    evaluator_map_t map1[9];
    evaluator_map_t map2[9];
    bool map1_enable[9] = {};
    bool map2_enable[9] = {};
    bool auto_normal = false;
    // glMapGrid
    GLint grid_un = 1, grid_vn = 1;
    GLfloat grid_u1 = 0.0f, grid_u2 = 1.0f, grid_v1 = 0.0f, grid_v2 = 1.0f;
};

// Process-global would leak across contexts; follow the per-context cache
// pattern used elsewhere.
evaluator_state_t& evalState() {
    struct cache_t {
        EGLContext context = (EGLContext)(intptr_t)-1;
        evaluator_state_t state{};
    };
    // Heap-backed: keeps the module's TLS block inside glibc's static-TLS
    // surplus so tls_model initial-exec stays usable (plans/12).
    static thread_local std::unique_ptr<cache_t> storage;
    if (storage == nullptr) storage = std::make_unique<cache_t>();
    cache_t& cache = *storage;
    // Reconciles against the calling entry's strict-resolve snapshot so the
    // evaluator cache and the vertex sink always agree on one context
    // (docs/context-model.md); evaluator entries anchor explicitly.
    const EGLContext current = (EGLContext)glstate_t::cached_context();
    if (cache.context != current) {
        cache.context = current;
        cache.state = {};
    }
    return cache.state;
}

// Map target -> index and component count. Index order matches the enum
// layout: COLOR_4, INDEX, NORMAL, TC1, TC2, TC3, TC4, VERTEX_3 (VERTEX_4
// shares slot arithmetic below).
int targetIndex(GLenum target, bool& is_map2, int& components) {
    is_map2 = target >= GL_MAP2_COLOR_4;
    const GLenum base = is_map2 ? GL_MAP2_COLOR_4 : GL_MAP1_COLOR_4;
    const int idx = (int)(target - base);
    if (idx < 0 || idx > 8) return -1;
    static const int kComponents[9] = {4, 1, 3, 1, 2, 3, 4, 3, 4};
    components = kComponents[idx];
    return idx;
}

// de Casteljau over `order` control points with `comps` interleaved floats
// at stride `stride` floats.
void bezier(const GLfloat* pts, GLint order, int comps, GLint stride, GLfloat t, GLfloat* out) {
    std::array<std::array<GLfloat, 4>, 32> work{};
    const GLint n = std::min<GLint>(order, 32);
    for (GLint i = 0; i < n; ++i)
        for (int c = 0; c < comps; ++c) work[(size_t)i][(size_t)c] = pts[i * stride + c];
    for (GLint level = n - 1; level > 0; --level)
        for (GLint i = 0; i < level; ++i)
            for (int c = 0; c < comps; ++c)
                work[(size_t)i][(size_t)c] =
                    (1.0f - t) * work[(size_t)i][(size_t)c] + t * work[(size_t)i + 1][(size_t)c];
    for (int c = 0; c < comps; ++c) out[c] = work[0][(size_t)c];
}

void emitAttributes(const GLfloat* value, int idx, int comps) {
    switch (idx) {
    case 0: // COLOR_4
        mglColor<GLfloat, 4>({value[0], value[1], value[2], value[3]});
        break;
    case 2: // NORMAL
        mglNormal<GLfloat, 3>({value[0], value[1], value[2]});
        break;
    case 3:
        mglTexCoord<GLfloat, 1>({value[0]}, 0);
        break;
    case 4:
        mglTexCoord<GLfloat, 2>({value[0], value[1]}, 0);
        break;
    case 5:
        mglTexCoord<GLfloat, 3>({value[0], value[1], value[2]}, 0);
        break;
    case 6:
        mglTexCoord<GLfloat, 4>({value[0], value[1], value[2], value[3]}, 0);
        break;
    case 7: // VERTEX_3
    case 8: // VERTEX_4 - emitted last by the callers
        if (comps == 4)
            mglVertex<GLfloat, 4>({value[0], value[1], value[2], value[3]});
        else
            mglVertex<GLfloat, 3>({value[0], value[1], value[2]});
        break;
    default: // INDEX (color-index mode): documented non-feature
        break;
    }
}

} // namespace

// The evaluator state lives in this file; the glGet family needs to read it
// without it becoming everyone's business. Values come out as doubles in the
// order the spec lists them, which is what the caller converts from.
bool sfpewEvaluatorStateQuery(GLenum pname, GLdouble* values, int* count) {
    const evaluator_state_t& es = evalState();
    // GL_MAP1_*/GL_MAP2_* double as enable queries for the map they name.
    bool is_map2 = false;
    int components = 0;
    if (pname >= GL_MAP1_COLOR_4 && pname <= GL_MAP2_VERTEX_4) {
        const int idx = targetIndex(pname, is_map2, components);
        if (idx >= 0) {
            values[0] = (is_map2 ? es.map2_enable[idx] : es.map1_enable[idx]) ? 1.0 : 0.0;
            *count = 1;
            return true;
        }
    }
    switch (pname) {
    case GL_AUTO_NORMAL:
        values[0] = es.auto_normal ? 1.0 : 0.0;
        *count = 1;
        return true;
    case GL_MAP1_GRID_SEGMENTS:
        values[0] = es.grid_un;
        *count = 1;
        return true;
    case GL_MAP1_GRID_DOMAIN:
        values[0] = es.grid_u1;
        values[1] = es.grid_u2;
        *count = 2;
        return true;
    case GL_MAP2_GRID_SEGMENTS:
        values[0] = es.grid_un;
        values[1] = es.grid_vn;
        *count = 2;
        return true;
    case GL_MAP2_GRID_DOMAIN:
        values[0] = es.grid_u1;
        values[1] = es.grid_u2;
        values[2] = es.grid_v1;
        values[3] = es.grid_v2;
        *count = 4;
        return true;
    default:
        return false;
    }
}


namespace {

// GL_COEFF, GL_ORDER and GL_DOMAIN for one map, as floats. The caller casts
// to whatever type it was asked for; returns how many values were written,
// or -1 if the query is not one of the three.
int mapQuery(GLenum target, GLenum query, GLfloat* out) {
    bool is_map2 = false;
    int comps = 0;
    const int idx = targetIndex(target, is_map2, comps);
    if (idx < 0) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return -1;
    }
    const evaluator_map_t& map = is_map2 ? evalState().map2[idx] : evalState().map1[idx];
    switch (query) {
    case GL_COEFF: {
        // A map that was never specified has no control points to hand out;
        // GL leaves the caller's array alone rather than inventing any.
        const size_t count = map.points.size();
        for (size_t i = 0; i < count; ++i) out[i] = map.points[i];
        return (int)count;
    }
    case GL_ORDER:
        out[0] = (GLfloat)map.uorder;
        if (!is_map2) return 1;
        out[1] = (GLfloat)map.vorder;
        return 2;
    case GL_DOMAIN:
        out[0] = map.u1;
        out[1] = map.u2;
        if (!is_map2) return 2;
        out[2] = map.v1;
        out[3] = map.v2;
        return 4;
    default:
        g_glstate.set_error(GL_INVALID_ENUM);
        return -1;
    }
}

} // namespace

void glGetMapfv(GLenum target, GLenum query, GLfloat* v) {
    if (v == nullptr) return;
    (void)g_glstate; // entry strict resolve; evaluator cache reads the snapshot
    mapQuery(target, query, v);
}

void glGetMapdv(GLenum target, GLenum query, GLdouble* v) {
    if (v == nullptr) return;
    (void)g_glstate;
    // Control points are stored as floats; a map2 of order 32x32 with four
    // components is the largest thing this can produce.
    std::vector<GLfloat> staging(32 * 32 * 4);
    const int count = mapQuery(target, query, staging.data());
    for (int i = 0; i < count; ++i) v[i] = staging[(size_t)i];
}

void glGetMapiv(GLenum target, GLenum query, GLint* v) {
    if (v == nullptr) return;
    (void)g_glstate;
    std::vector<GLfloat> staging(32 * 32 * 4);
    const int count = mapQuery(target, query, staging.data());
    // Rounded, per the conversion rules for an integer query.
    for (int i = 0; i < count; ++i) v[i] = (GLint)std::lround(staging[(size_t)i]);
}

void glMap1f(GLenum target, GLfloat u1, GLfloat u2, GLint stride, GLint order, const GLfloat* points) {
    (void)g_glstate; // entry strict resolve; evaluator cache reads the snapshot
    bool is_map2 = false;
    int comps = 0;
    const int idx = targetIndex(target, is_map2, comps);
    if (idx < 0 || is_map2) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    if (order < 1 || order > 32 || u1 == u2 || stride < comps || points == nullptr) {
        g_glstate.set_error(GL_INVALID_VALUE);
        return;
    }
    auto& map = evalState().map1[idx];
    map.valid = true;
    map.components = comps;
    map.u1 = u1;
    map.u2 = u2;
    map.uorder = order;
    map.points.resize((size_t)order * comps);
    for (GLint i = 0; i < order; ++i)
        for (int c = 0; c < comps; ++c) map.points[(size_t)i * comps + c] = points[i * stride + c];
}

void glMap1d(GLenum target, GLdouble u1, GLdouble u2, GLint stride, GLint order, const GLdouble* points) {
    (void)g_glstate; // entry strict resolve; evaluator cache reads the snapshot
    if (points == nullptr) return;
    bool is_map2 = false;
    int comps = 0;
    if (targetIndex(target, is_map2, comps) < 0) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    std::vector<GLfloat> converted((size_t)std::max(order, 0) * comps);
    for (GLint i = 0; i < order; ++i)
        for (int c = 0; c < comps; ++c) converted[(size_t)i * comps + c] = (GLfloat)points[i * stride + c];
    glMap1f(target, (GLfloat)u1, (GLfloat)u2, comps, order, converted.data());
}

void glMap2f(GLenum target, GLfloat u1, GLfloat u2, GLint ustride, GLint uorder, GLfloat v1,
             GLfloat v2, GLint vstride, GLint vorder, const GLfloat* points) {
    (void)g_glstate; // entry strict resolve; evaluator cache reads the snapshot
    bool is_map2 = false;
    int comps = 0;
    const int idx = targetIndex(target, is_map2, comps);
    if (idx < 0 || !is_map2) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    if (uorder < 1 || uorder > 32 || vorder < 1 || vorder > 32 || u1 == u2 || v1 == v2 ||
        ustride < comps || vstride < comps || points == nullptr) {
        g_glstate.set_error(GL_INVALID_VALUE);
        return;
    }
    auto& map = evalState().map2[idx];
    map.valid = true;
    map.components = comps;
    map.u1 = u1;
    map.u2 = u2;
    map.v1 = v1;
    map.v2 = v2;
    map.uorder = uorder;
    map.vorder = vorder;
    map.points.resize((size_t)uorder * vorder * comps);
    for (GLint v = 0; v < vorder; ++v)
        for (GLint u = 0; u < uorder; ++u)
            for (int c = 0; c < comps; ++c)
                map.points[((size_t)v * uorder + u) * comps + c] = points[u * ustride + v * vstride + c];
}

void glMap2d(GLenum target, GLdouble u1, GLdouble u2, GLint ustride, GLint uorder, GLdouble v1,
             GLdouble v2, GLint vstride, GLint vorder, const GLdouble* points) {
    (void)g_glstate; // entry strict resolve; evaluator cache reads the snapshot
    if (points == nullptr) return;
    bool is_map2 = false;
    int comps = 0;
    if (targetIndex(target, is_map2, comps) < 0) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    std::vector<GLfloat> converted;
    converted.resize((size_t)std::max(uorder, 0) * std::max(vorder, 0) * comps);
    for (GLint v = 0; v < vorder; ++v)
        for (GLint u = 0; u < uorder; ++u)
            for (int c = 0; c < comps; ++c)
                converted[((size_t)v * uorder + u) * comps + c] =
                    (GLfloat)points[u * ustride + v * vstride + c];
    glMap2f(target, (GLfloat)u1, (GLfloat)u2, comps, uorder, (GLfloat)v1, (GLfloat)v2,
            comps * uorder, vorder, converted.data());
}

void glEvalCoord1f(GLfloat u) {
    (void)g_glstate; // entry strict resolve; evaluator cache reads the snapshot
    auto& es = evalState();
    GLfloat value[4];
    // Non-vertex attributes first; the vertex evaluation commits the vertex.
    for (int idx = 0; idx < 7; ++idx) {
        if (!es.map1_enable[idx] || !es.map1[idx].valid) continue;
        const auto& map = es.map1[idx];
        const GLfloat t = (u - map.u1) / (map.u2 - map.u1);
        bezier(map.points.data(), map.uorder, map.components, map.components, t, value);
        emitAttributes(value, idx, map.components);
    }
    const int vslot1 = es.map1_enable[8] && es.map1[8].valid ? 8
                       : es.map1_enable[7] && es.map1[7].valid ? 7
                                                               : -1;
    if (vslot1 >= 0) {
        const auto& map = es.map1[vslot1];
        const GLfloat t = (u - map.u1) / (map.u2 - map.u1);
        bezier(map.points.data(), map.uorder, map.components, map.components, t, value);
        emitAttributes(value, vslot1, map.components);
    }
}

void glEvalCoord2f(GLfloat u, GLfloat v) {
    (void)g_glstate; // entry strict resolve; evaluator cache reads the snapshot
    auto& es = evalState();
    GLfloat value[4];
    std::array<GLfloat, 32 * 4> column{};
    const auto evaluate2 = [&](const evaluator_map_t& map, GLfloat au, GLfloat av, GLfloat* out) {
        const GLfloat tu = (au - map.u1) / (map.u2 - map.u1);
        const GLfloat tv = (av - map.v1) / (map.v2 - map.v1);
        // Collapse along v per u-column, then along u.
        for (GLint uu = 0; uu < map.uorder; ++uu) {
            // v-run for this u: stride between rows is uorder*comps.
            std::array<GLfloat, 32 * 4> vrun{};
            for (GLint vv = 0; vv < map.vorder; ++vv)
                for (int c = 0; c < map.components; ++c)
                    vrun[(size_t)vv * map.components + c] =
                        map.points[((size_t)vv * map.uorder + uu) * map.components + c];
            bezier(vrun.data(), map.vorder, map.components, map.components, tv,
                   &column[(size_t)uu * map.components]);
        }
        bezier(column.data(), map.uorder, map.components, map.components, tu, out);
    };

    // GL_AUTO_NORMAL: analytic partial derivatives are the spec formula;
    // approximate with forward differences, which is exact for the common
    // bilinear case and close elsewhere (documented approximation).
    const int vslot = es.map2_enable[8] && es.map2[8].valid ? 8
                      : es.map2_enable[7] && es.map2[7].valid ? 7
                                                              : -1;
    if (es.auto_normal && vslot >= 0) {
        const auto& map = es.map2[vslot];
        const GLfloat du = (map.u2 - map.u1) * 0.001f;
        const GLfloat dv = (map.v2 - map.v1) * 0.001f;
        GLfloat p0[4], pu[4], pv[4];
        evaluate2(map, u, v, p0);
        evaluate2(map, u + du, v, pu);
        evaluate2(map, u, v + dv, pv);
        const glm::vec3 tangent_u(pu[0] - p0[0], pu[1] - p0[1], pu[2] - p0[2]);
        const glm::vec3 tangent_v(pv[0] - p0[0], pv[1] - p0[1], pv[2] - p0[2]);
        const glm::vec3 normal = glm::normalize(glm::cross(tangent_u, tangent_v));
        mglNormal<GLfloat, 3>({normal.x, normal.y, normal.z});
    }

    for (int idx = 0; idx < 7; ++idx) {
        if (!es.map2_enable[idx] || !es.map2[idx].valid) continue;
        evaluate2(es.map2[idx], u, v, value);
        emitAttributes(value, idx, es.map2[idx].components);
    }
    if (vslot >= 0) {
        evaluate2(es.map2[vslot], u, v, value);
        emitAttributes(value, vslot, es.map2[vslot].components);
    }
}

void glEvalCoord1d(GLdouble u) { glEvalCoord1f((GLfloat)u); }
void glEvalCoord2d(GLdouble u, GLdouble v) { glEvalCoord2f((GLfloat)u, (GLfloat)v); }
void glEvalCoord1fv(const GLfloat* u) { if (u) glEvalCoord1f(u[0]); }
void glEvalCoord2fv(const GLfloat* u) { if (u) glEvalCoord2f(u[0], u[1]); }
void glEvalCoord1dv(const GLdouble* u) { if (u) glEvalCoord1f((GLfloat)u[0]); }
void glEvalCoord2dv(const GLdouble* u) { if (u) glEvalCoord2f((GLfloat)u[0], (GLfloat)u[1]); }

void glMapGrid1f(GLint un, GLfloat u1, GLfloat u2) {
    (void)g_glstate; // entry strict resolve; evaluator cache reads the snapshot
    if (un < 1) {
        g_glstate.set_error(GL_INVALID_VALUE);
        return;
    }
    auto& es = evalState();
    es.grid_un = un;
    es.grid_u1 = u1;
    es.grid_u2 = u2;
}

void glMapGrid1d(GLint un, GLdouble u1, GLdouble u2) {
    glMapGrid1f(un, (GLfloat)u1, (GLfloat)u2);
}

void glMapGrid2f(GLint un, GLfloat u1, GLfloat u2, GLint vn, GLfloat v1, GLfloat v2) {
    (void)g_glstate; // entry strict resolve; evaluator cache reads the snapshot
    if (un < 1 || vn < 1) {
        g_glstate.set_error(GL_INVALID_VALUE);
        return;
    }
    auto& es = evalState();
    es.grid_un = un;
    es.grid_u1 = u1;
    es.grid_u2 = u2;
    es.grid_vn = vn;
    es.grid_v1 = v1;
    es.grid_v2 = v2;
}

void glMapGrid2d(GLint un, GLdouble u1, GLdouble u2, GLint vn, GLdouble v1, GLdouble v2) {
    glMapGrid2f(un, (GLfloat)u1, (GLfloat)u2, vn, (GLfloat)v1, (GLfloat)v2);
}

void glEvalPoint1(GLint i) {
    (void)g_glstate; // entry strict resolve; evaluator cache reads the snapshot
    const auto& es = evalState();
    glEvalCoord1f(es.grid_u1 + (es.grid_u2 - es.grid_u1) * (GLfloat)i / (GLfloat)es.grid_un);
}

void glEvalPoint2(GLint i, GLint j) {
    (void)g_glstate; // entry strict resolve; evaluator cache reads the snapshot
    const auto& es = evalState();
    glEvalCoord2f(es.grid_u1 + (es.grid_u2 - es.grid_u1) * (GLfloat)i / (GLfloat)es.grid_un,
                  es.grid_v1 + (es.grid_v2 - es.grid_v1) * (GLfloat)j / (GLfloat)es.grid_vn);
}

void glEvalMesh1(GLenum mode, GLint i1, GLint i2) {
    (void)g_glstate; // entry strict resolve; evaluator cache reads the snapshot
    if (mode != GL_POINT && mode != GL_LINE) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    glBegin(mode == GL_POINT ? GL_POINTS : GL_LINE_STRIP);
    for (GLint i = i1; i <= i2; ++i) glEvalPoint1(i);
    glEnd();
}

void glEvalMesh2(GLenum mode, GLint i1, GLint i2, GLint j1, GLint j2) {
    (void)g_glstate; // entry strict resolve; evaluator cache reads the snapshot
    if (mode != GL_POINT && mode != GL_LINE && mode != GL_FILL) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    if (mode == GL_POINT) {
        glBegin(GL_POINTS);
        for (GLint j = j1; j <= j2; ++j)
            for (GLint i = i1; i <= i2; ++i) glEvalPoint2(i, j);
        glEnd();
        return;
    }
    if (mode == GL_LINE) {
        for (GLint j = j1; j <= j2; ++j) {
            glBegin(GL_LINE_STRIP);
            for (GLint i = i1; i <= i2; ++i) glEvalPoint2(i, j);
            glEnd();
        }
        for (GLint i = i1; i <= i2; ++i) {
            glBegin(GL_LINE_STRIP);
            for (GLint j = j1; j <= j2; ++j) glEvalPoint2(i, j);
            glEnd();
        }
        return;
    }
    for (GLint j = j1; j < j2; ++j) { // GL_FILL: one strip per row
        glBegin(GL_TRIANGLE_STRIP);
        for (GLint i = i1; i <= i2; ++i) {
            glEvalPoint2(i, j);
            glEvalPoint2(i, j + 1);
        }
        glEnd();
    }
}

// Enable hook called from hijack_fpe_states for GL_MAP1_*/GL_MAP2_*/
// GL_AUTO_NORMAL caps; returns false for unrelated caps.
bool sfpewEvaluatorEnable(GLenum cap, bool enable) {
    auto& es = evalState();
    if (cap == GL_AUTO_NORMAL) {
        es.auto_normal = enable;
        return true;
    }
    if (cap >= GL_MAP1_COLOR_4 && cap <= GL_MAP1_VERTEX_4) {
        es.map1_enable[cap - GL_MAP1_COLOR_4] = enable;
        return true;
    }
    if (cap >= GL_MAP2_COLOR_4 && cap <= GL_MAP2_VERTEX_4) {
        es.map2_enable[cap - GL_MAP2_COLOR_4] = enable;
        return true;
    }
    return false;
}

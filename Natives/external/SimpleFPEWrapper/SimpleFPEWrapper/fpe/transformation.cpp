// SimpleFPEWrapper - SimpleFPEWrapper/fpe/transformation.cpp
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#include "transformation.h"
#include <glm/gtc/type_ptr.hpp>
#include "list.h"
#include "fpe.hpp"
#include "drawing1x.h"
#include "pointer_utils.h"

#include <glm/ext/matrix_clip_space.hpp>
#include <glm/ext/matrix_relational.hpp>
#include <glm/ext/matrix_transform.hpp>
#include <glm/ext/matrix_float4x4.hpp>
#include <glm/gtc/matrix_inverse.hpp>
#include <glm/ext/vector_relational.hpp>
#include <glm/ext/vector_float4.hpp>
#include <glm/ext/vector_float3.hpp>
#include <algorithm>
#include <array>
#include <cstdint>
#define DEBUG 0

namespace {

int active_texture_index() {
    // The glActiveTexture wrapper maintains a thread-local shadow; a
    // synchronous backend round-trip per call is unnecessary.
    const GLint active = (GLint)sfpewLogicalActiveTexture();
    return std::clamp(active - (GLint)GL_TEXTURE0, 0, MAX_TEX - 1);
}

glm::mat4& current_matrix(transformation_t& transformation) {
    if (transformation.matrix_mode == GL_TEXTURE) {
        return transformation.texture_matrices[active_texture_index()];
    }
    return transformation.matrices[matrix_idx(transformation.matrix_mode)];
}

size_t max_stack_depth(GLenum matrix_mode) {
    switch (matrix_mode) {
    case GL_PROJECTION:
        return MAX_PROJECTION_STACK_DEPTH;
    case GL_TEXTURE:
        return MAX_TEXTURE_STACK_DEPTH;
    case GL_COLOR:
        return MAX_COLOR_STACK_DEPTH;
    case GL_MODELVIEW:
    default:
        return MAX_MODELVIEW_STACK_DEPTH;
    }
}

std::vector<glm::mat4>& current_matrix_stack(transformation_t& transformation) {
    if (transformation.matrix_mode == GL_TEXTURE) {
        return transformation.texture_matrices_stack[active_texture_index()];
    }
    return transformation.matrices_stack[matrix_idx(transformation.matrix_mode)];
}

enum class matrix_transform_kind_t : uint8_t {
    translate,
    scale,
};

struct matrix_transform_op_t {
    matrix_transform_kind_t kind;
    glm::vec3 value;
};

class matrix_transform_cmd_t final : public GLCmd {
public:
    matrix_transform_cmd_t(matrix_transform_kind_t kind, const glm::vec3& value) {
        operations[0] = {kind, value};
        operationCount = 1;
    }

    void execute() const override {
        // Preserve the original specialized translate/scale operations and
        // their order while avoiding repeated virtual dispatch, state lookup,
        // and pending-draw checks for adjacent display-list transforms.
        // Replay runs under the glCallList entry resolve, so relaxed access.
        sfpewClientStateBarrier();
        auto& matrix = current_matrix(g_glstate_c.fpe_uniform.transformation);
        apply(matrix);
    }

    void apply(glm::mat4& matrix) const {
        for (size_t i = 0; i < operationCount; ++i) {
            const auto& operation = operations[i];
            if (operation.kind == matrix_transform_kind_t::translate)
                matrix = glm::translate(matrix, operation.value);
            else
                matrix = glm::scale(matrix, operation.value);
        }
    }

    bool tryMerge(const GLCmd& nextCommand) override {
        const auto* next = dynamic_cast<const matrix_transform_cmd_t*>(&nextCommand);
        if (next == nullptr || operationCount + next->operationCount > operations.size()) return false;
        std::copy_n(next->operations.begin(), next->operationCount,
                    operations.begin() + operationCount);
        operationCount += next->operationCount;
        return true;
    }

private:
    std::array<matrix_transform_op_t, 8> operations{};
    size_t operationCount = 0;
};

class scoped_matrix_draw_cmd_t final : public GLCmd {
public:
    scoped_matrix_draw_cmd_t(std::unique_ptr<matrix_transform_cmd_t> transform,
                             std::unique_ptr<GLCmd> draw)
        : transform(std::move(transform)), draw(std::move(draw)) {}

    void execute() const override {
        sfpewClientStateBarrier();
        auto& matrix = current_matrix(g_glstate_c.fpe_uniform.transformation);
        const glm::mat4 saved = matrix;
        transform->apply(matrix);
        draw->execute();
        matrix = saved;
    }

private:
    std::unique_ptr<matrix_transform_cmd_t> transform;
    std::unique_ptr<GLCmd> draw;
};

class linear_matrix_draw_cmd_t final : public GLCmd {
public:
    linear_matrix_draw_cmd_t(const glm::mat4& linearTransform, std::unique_ptr<GLCmd> draw)
        : linearTransform(linearTransform), draw(std::move(draw)) {}

    void execute() const override {
        sfpewClientStateBarrier();
        auto& matrix = current_matrix(g_glstate_c.fpe_uniform.transformation);
        const glm::mat4 saved = matrix;
        matrix *= linearTransform;
        draw->execute();
        matrix = saved;
    }

    bool isCapturedDraw() const override { return draw->isCapturedDraw(); }

    const GLCmd* capturedDrawForBatch(glm::mat4* transform) const override {
        glm::mat4 ignored(1.0f);
        const GLCmd* captured = draw->capturedDrawForBatch(&ignored);
        if (captured == nullptr) return nullptr;
        if (transform != nullptr) *transform = linearTransform;
        return captured;
    }

private:
    glm::mat4 linearTransform;
    std::unique_ptr<GLCmd> draw;
};

bool recordMatrixTransform(matrix_transform_kind_t kind, const glm::vec3& value) {
    if (disableRecording || !DisplayListManager::shouldRecord()) return false;
    displayListManager.recordCommand(std::make_unique<matrix_transform_cmd_t>(kind, value));
    return DisplayListManager::shouldFinish();
}

} // namespace

void optimizeDisplayListCommands(DisplayList& commands) {
    if (commands.size() != 3 && commands.size() != 4) return;
    if (dynamic_cast<GLFuncCmd<&glPushMatrix>*>(commands.front().get()) == nullptr ||
        dynamic_cast<GLFuncCmd<&glPopMatrix>*>(commands.back().get()) == nullptr) {
        return;
    }

    auto* transform = dynamic_cast<matrix_transform_cmd_t*>(commands[1].get());
    if (transform == nullptr) return;
    if (commands.size() == 3) {
        commands.clear();
        return;
    }
    if (!commands[2]->isCapturedDraw()) return;

    // A chunk list in Minecraft 1.5.2 is normally
    // PushMatrix; Translate; Scale; Translate; Draw; PopMatrix. Factor its
    // affine transform A = L * T into a per-list translation baked into the
    // immutable vertices and a common linear part L kept in the model-view
    // matrix. This preserves fixed-pipeline normal transformation while
    // allowing glCallLists to submit many chunks through one MultiDraw call.
    glm::mat4 affine(1.0f);
    transform->apply(affine);
    glm::mat4 linear = affine;
    linear[3] = glm::vec4(0.0f, 0.0f, 0.0f, 1.0f);
    const glm::mat3 linear3(linear);
    const float determinant = glm::determinant(linear3);
    if (determinant != 0.0f) {
        const glm::vec3 translation = glm::inverse(linear3) * glm::vec3(affine[3]);
        if (commands[2]->bakePositionTranslation(translation)) {
            auto draw = std::move(commands[2]);
            commands.clear();
            const glm::mat4 identity(1.0f);
            if (glm::all(glm::equal(linear, identity))) {
                commands.emplace_back(std::move(draw));
            } else {
                commands.emplace_back(
                    std::make_unique<linear_matrix_draw_cmd_t>(linear, std::move(draw)));
            }
            return;
        }
    }

    auto ownedTransform = std::unique_ptr<matrix_transform_cmd_t>(
        static_cast<matrix_transform_cmd_t*>(commands[1].release()));
    auto draw = std::move(commands[2]);
    commands.clear();
    commands.emplace_back(std::make_unique<scoped_matrix_draw_cmd_t>(
        std::move(ownedTransform), std::move(draw)));
}

int matrix_idx(GLenum matrix_mode) {
    switch (matrix_mode) {
    case GL_MODELVIEW:
        return 0;
    case GL_PROJECTION:
        return 1;
    case GL_TEXTURE:
        return 2;
    case GL_COLOR:
        return 3;
    }
    // LOG_E("Error: 1282");
    return 0;
}

void print_matrix([[maybe_unused]] const glm::mat4& mat) {
#if DEBUG || GLOBAL_DEBUG
    auto* pmat = (const float*)glm::value_ptr(mat);
    // LOG_D_N("[")
    for (int i = 0; i < 4; ++i) {
        for (int j = 0; j < 4; ++j) {
            int idx = j + i * 4;
            // LOG_D_N("%.2f ", pmat[idx])
        }
        // LOG_D("")
    }
    // LOG_D("]")
#endif
}

void glMatrixMode(GLenum mode) {
    // LOG()
    //  LOG_D("glMatrixMode(%s)", glEnumToString(mode))

    LIST_RECORD(glMatrixMode, {}, mode)

    auto& gs = g_glstate;
    auto& transformation = gs.fpe_uniform.transformation;

    switch (mode) {
    case GL_MODELVIEW:
    case GL_PROJECTION:
    case GL_TEXTURE:
    case GL_COLOR:
        transformation.matrix_mode = mode;
        break;
    default:
        gs.set_error(GL_INVALID_ENUM);
        break;
    }
}

void glLoadIdentity() {
    sfpewClientStateBarrier();
    // LOG()
    //  LOG_D("glLoadIdentity")

    LIST_RECORD(glLoadIdentity, {})

    auto& transformation = g_glstate.fpe_uniform.transformation;

    current_matrix(transformation) = glm::mat4(1.0);

    // LOG_D("Matrix %s:", glEnumToString(transformation.matrix_mode))
    print_matrix(current_matrix(transformation));
}

void glOrtho(GLdouble left, GLdouble right, GLdouble bottom, GLdouble top, GLdouble near_val, GLdouble far_val) {
    // LOG()
    //  LOG_D("glOrtho(%f, %f, %f, %f, %f, %f)", left, right, bottom, top, near_val, far_val)

    LIST_RECORD(glOrtho, {}, left, right, bottom, top, near_val, far_val)

    // TODO: precision loss?
    SELF_CALL(glOrthof, left, right, bottom, top, near_val, far_val)
}

void glOrthof(GLfloat left, GLfloat right, GLfloat bottom, GLfloat top, GLfloat zNear, GLfloat zFar) {
    sfpewClientStateBarrier();
    // LOG()
    //  LOG_D("glOrthof(%f, %f, %f, %f, %f, %f)", left, right, bottom, top, zNear, zFar)

    LIST_RECORD(glOrthof, {}, left, right, bottom, top, zNear, zFar)

    auto& transformation = g_glstate.fpe_uniform.transformation;

    current_matrix(transformation) *= glm::ortho(left, right, bottom, top, zNear, zFar);
    // LOG_D("Matrix %s:", glEnumToString(transformation.matrix_mode))
    print_matrix(current_matrix(transformation));
}

void glFrustum(GLdouble left, GLdouble right, GLdouble bottom, GLdouble top, GLdouble zNear, GLdouble zFar) {
    LIST_RECORD(glFrustum, {}, left, right, bottom, top, zNear, zFar)

    // The emulated transform state is float-based, matching the generated ES
    // uniforms. Keep the desktop double entry point while accepting that final
    // storage has GLfloat precision.
    SELF_CALL(glFrustumf, (GLfloat)left, (GLfloat)right, (GLfloat)bottom, (GLfloat)top, (GLfloat)zNear,
              (GLfloat)zFar)
}

void glFrustumf(GLfloat left, GLfloat right, GLfloat bottom, GLfloat top, GLfloat zNear, GLfloat zFar) {
    sfpewClientStateBarrier();
    LIST_RECORD(glFrustumf, {}, left, right, bottom, top, zNear, zFar)

    auto& transformation = g_glstate.fpe_uniform.transformation;
    current_matrix(transformation) *= glm::frustum(left, right, bottom, top, zNear, zFar);
    print_matrix(current_matrix(transformation));
}

void glScalef(GLfloat x, GLfloat y, GLfloat z) {
    sfpewClientStateBarrier();
    // LOG()
    //  LOG_D("glScalef(%f, %f, %f)", x, y, z)

    if (recordMatrixTransform(matrix_transform_kind_t::scale, glm::vec3(x, y, z))) return;

    auto& transformation = g_glstate.fpe_uniform.transformation;

    auto& matrix = current_matrix(transformation);
    matrix = glm::scale(matrix, glm::vec3(x, y, z));
    // LOG_D("Matrix %s:", glEnumToString(transformation.matrix_mode))
    print_matrix(matrix);
}

void glTranslatef(GLfloat x, GLfloat y, GLfloat z) {
    sfpewClientStateBarrier();
    // LOG()
    //  LOG_D("glTranslatef(%f, %f, %f)", x, y, z)

    if (recordMatrixTransform(matrix_transform_kind_t::translate, glm::vec3(x, y, z))) return;

    auto& transformation = g_glstate.fpe_uniform.transformation;

    auto& matrix = current_matrix(transformation);
    matrix = glm::translate(matrix, glm::vec3(x, y, z));
    // LOG_D("Matrix %s:", glEnumToString(transformation.matrix_mode))
    print_matrix(matrix);
}

void glRotatef(GLfloat angle, GLfloat x, GLfloat y, GLfloat z) {
    sfpewClientStateBarrier();
    // LOG()
    //  LOG_D("glRotatef, angle = %.2f, x = %.2f, y = %.2f, z = %.2f", angle, x, y, z)

    LIST_RECORD(glRotatef, {}, angle, x, y, z)

    auto& transformation = g_glstate.fpe_uniform.transformation;

    auto& matrix = current_matrix(transformation);
    matrix = glm::rotate(matrix, (GLfloat)(angle * M_PI / 180.f), glm::vec3(x, y, z));
    // LOG_D("Matrix %s:", glEnumToString(transformation.matrix_mode))
    print_matrix(matrix);
}

void glRotated(GLdouble angle, GLdouble x, GLdouble y, GLdouble z) {
    // LOG()
    //  LOG_D("glRotated(%f, %f, %f, %f)", angle, x, y, z)

    LIST_RECORD(glRotated, {}, angle, x, y, z)

    // TODO: precision loss?
    SELF_CALL(glRotatef, angle, x, y, z)
}

void glScaled(GLdouble x, GLdouble y, GLdouble z) {
    // LOG()
    //  LOG_D("glScaled(%f, %f, %f)", x, y, z)

    LIST_RECORD(glScaled, {}, x, y, z)

    // TODO: precision loss?
    SELF_CALL(glScalef, x, y, z)
}

void glTranslated(GLdouble x, GLdouble y, GLdouble z) {
    // LOG()
    //  LOG_D("glTranslated(%f, %f, %f)", x, y, z)

    LIST_RECORD(glTranslated, {}, x, y, z)

    // TODO: precision loss?
    SELF_CALL(glTranslatef, x, y, z);
}

void glLoadMatrixd(const GLdouble* m) {
    LIST_RECORD(glLoadMatrixd, {{0, sizeof(GLdouble) * 16}}, m)

    if (!m) return;
    GLfloat converted[16];
    for (int i = 0; i < 16; ++i) converted[i] = (GLfloat)m[i];
    SELF_CALL(glLoadMatrixf, converted)
}

void glLoadMatrixf(const GLfloat* m) {
    sfpewClientStateBarrier();
    LIST_RECORD(glLoadMatrixf, {{0, sizeof(GLfloat) * 16}}, m)

    if (!m) return;
    auto& transformation = g_glstate.fpe_uniform.transformation;
    current_matrix(transformation) = glm::make_mat4(m);
    print_matrix(current_matrix(transformation));
}

void glMultMatrixd(const GLdouble* m) {
    LIST_RECORD(glMultMatrixd, {{0, sizeof(GLdouble) * 16}}, m)

    if (!m) return;
    GLfloat converted[16];
    for (int i = 0; i < 16; ++i) converted[i] = (GLfloat)m[i];
    SELF_CALL(glMultMatrixf, converted)
}

void glMultMatrixf(const GLfloat* m) {
    sfpewClientStateBarrier();
    // LOG()
    //  LOG_D("glMultMatrixf(%p)", m)

    LIST_RECORD(glMultMatrixf, {{0, sizeof(GLfloat) * 16}}, m)

    if (!m) return;
    auto& transformation = g_glstate.fpe_uniform.transformation;

    // LOG_D("Matrix %s:", glEnumToString(transformation.matrix_mode))
    auto& matrix = current_matrix(transformation);
    print_matrix(matrix);
    // LOG_D("*")
    auto mat = glm::make_mat4(m);
    print_matrix(mat);

    matrix *= mat;
    // LOG_D("=")

    print_matrix(matrix);
}

// GL_ARB_transpose_matrix takes row-major input. Convert it to the
// column-major layout used by the existing matrix entry points, then delegate
// under SELF_CALL so a display list captures only the spelling the app used.
void glLoadTransposeMatrixf(const GLfloat* m) {
    if (m == nullptr) return;
    LIST_RECORD(glLoadTransposeMatrixf, {{0, sizeof(GLfloat) * 16}}, m)

    GLfloat column_major[16];
    for (int row = 0; row < 4; ++row)
        for (int column = 0; column < 4; ++column)
            column_major[column * 4 + row] = m[row * 4 + column];
    SELF_CALL(glLoadMatrixf, column_major)
}

void glLoadTransposeMatrixd(const GLdouble* m) {
    if (m == nullptr) return;
    LIST_RECORD(glLoadTransposeMatrixd, {{0, sizeof(GLdouble) * 16}}, m)

    GLfloat column_major[16];
    for (int row = 0; row < 4; ++row)
        for (int column = 0; column < 4; ++column)
            column_major[column * 4 + row] = (GLfloat)m[row * 4 + column];
    SELF_CALL(glLoadMatrixf, column_major)
}

void glMultTransposeMatrixf(const GLfloat* m) {
    if (m == nullptr) return;
    LIST_RECORD(glMultTransposeMatrixf, {{0, sizeof(GLfloat) * 16}}, m)

    GLfloat column_major[16];
    for (int row = 0; row < 4; ++row)
        for (int column = 0; column < 4; ++column)
            column_major[column * 4 + row] = m[row * 4 + column];
    SELF_CALL(glMultMatrixf, column_major)
}

void glMultTransposeMatrixd(const GLdouble* m) {
    if (m == nullptr) return;
    LIST_RECORD(glMultTransposeMatrixd, {{0, sizeof(GLdouble) * 16}}, m)

    GLfloat column_major[16];
    for (int row = 0; row < 4; ++row)
        for (int column = 0; column < 4; ++column)
            column_major[column * 4 + row] = (GLfloat)m[row * 4 + column];
    SELF_CALL(glMultMatrixf, column_major)
}

void glPushMatrix(void) {
    sfpewClientStateBarrier();
    // LOG()
    //  LOG_D("glPushMatrix()")

    LIST_RECORD(glPushMatrix, {})

    auto& gs = g_glstate;
    auto& transformation = gs.fpe_uniform.transformation;

    auto& mat = current_matrix(transformation);
    auto& stack = current_matrix_stack(transformation);
    if (stack.size() >= max_stack_depth(transformation.matrix_mode)) {
        gs.set_error(GL_STACK_OVERFLOW);
        return;
    }
    stack.push_back(mat);

    // LOG_D("Matrix %s:", glEnumToString(transformation.matrix_mode))
    print_matrix(mat);
}

void glPopMatrix(void) {
    sfpewClientStateBarrier();
    // LOG()
    //  LOG_D("glPopMatrix()")

    LIST_RECORD(glPopMatrix, {})

    auto& gs = g_glstate;
    auto& transformation = gs.fpe_uniform.transformation;

    auto& mat = current_matrix(transformation);
    auto& stack = current_matrix_stack(transformation);
    if (stack.empty()) {
        gs.set_error(GL_STACK_UNDERFLOW);
        return;
    }
    mat = stack.back();
    stack.pop_back();

    // LOG_D("Matrix %s:", glEnumToString(transformation.matrix_mode))
    print_matrix(mat);
}

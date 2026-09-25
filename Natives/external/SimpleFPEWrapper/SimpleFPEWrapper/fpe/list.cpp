// SimpleFPEWrapper - SimpleFPEWrapper/fpe/list.cpp
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#include "list.h"
#include "pointer_utils.h"
#include "fpe.hpp"
#include "drawing1x.h"

#define DEBUG 0

GLuint currentListBase = 0;

namespace {

template <typename T>
void decodeNativeListIds(GLsizei n, const GLvoid* lists, std::vector<GLuint>& output) {
    const auto* values = static_cast<const T*>(lists);
    for (GLsizei i = 0; i < n; ++i)
        output[static_cast<size_t>(i)] = currentListBase + static_cast<GLuint>(values[i]);
}

void decodePackedListIds(GLsizei n, size_t width, const GLvoid* lists,
                         std::vector<GLuint>& output) {
    const auto* bytes = static_cast<const GLubyte*>(lists);
    for (GLsizei i = 0; i < n; ++i) {
        GLuint offset = 0;
        for (size_t component = 0; component < width; ++component)
            offset = (offset << 8u) | bytes[static_cast<size_t>(i) * width + component];
        output[static_cast<size_t>(i)] = currentListBase + offset;
    }
}

} // namespace

GLuint DisplayListManager::listBase() { return currentListBase; }

GLuint glGenLists(GLsizei range) {
    // LOG()
    // LOG_D("glGenLists(%i)", range)
    if (range < 0) {
        g_glstate.set_error(GL_INVALID_VALUE);
        return 0;
    }
    sfpewListLogGenerated((unsigned)range);
    GLuint first = DisplayListManager::genDisplayList(range);
    // LOG_D("-> ", first)
    return first;
}

void glDeleteLists(GLuint list, GLsizei range) {
    // LOG()
    // LOG_D("glDeleteLists(%d, %i)", list, range)
    if (range < 0) {
        g_glstate.set_error(GL_INVALID_VALUE);
        return;
    }
    sfpewListLogDeleted((unsigned)range);
    DisplayListManager::deleteDisplayList(list, range);
}

GLboolean glIsList(GLuint list) {
    // LOG()
    // LOG_D("glIsList(%d)", list)
    return DisplayListManager::isDisplayList(list);
}

void glNewList(GLuint list, GLenum mode) {
    sfpewEntryBarrier();
    // LOG()
    // LOG_D("glNewList(%d, %s)", list, glEnumToString(mode))
    if (list == 0) {
        g_glstate.set_error(GL_INVALID_VALUE);
        return;
    }
    if (mode != GL_COMPILE && mode != GL_COMPILE_AND_EXECUTE) {
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    if (DisplayListManager::shouldRecord()) { // glNewList inside glNewList
        g_glstate.set_error(GL_INVALID_OPERATION);
        return;
    }
    sfpewListLogRecording(list);
    DisplayListManager::startRecord(list, mode);
}

void glEndList() {
    // LOG()
    // LOG_D("glEndLists()")
    if (!DisplayListManager::shouldRecord()) { // glEndList without glNewList
        g_glstate.set_error(GL_INVALID_OPERATION);
        return;
    }
    DisplayListManager::endRecord();
}

void glCallList(GLuint list) {
    // Entry strict resolve: replayed commands (matrix transforms, captured
    // draws) use the relaxed snapshot accessor and rely on this anchor.
    (void)g_glstate;
    // Flush-only: the specialized replay commands (captured draws, compiled
    // immediate runs, matrix transforms) establish the wrapper's own draw
    // state exactly like a live fixed-function draw, and every generic
    // recorded command replays through its own exported entry point, which
    // applies that entry's own barrier discipline. Restoring the app's state
    // here just made each glCallList pay a glUseProgram round trip that the
    // first replayed draw immediately undid.
    flushPendingImmediateDraws();
    // LOG()
    // LOG_D("glCallList(%d)", list)

    if (DisplayListManager::shouldRecord()) {
        displayListManager.record<glCallList>({}, list);
        if (DisplayListManager::shouldFinish()) return;
    }
    if (DisplayListManager::isCalling()) {
        DisplayListManager::callList(list);
    } else {
        sfpewListLogRequestedIds(&list, 1);
        sfpewListLogSingleCall();
        fpe_backend_draw_state_guard_t backendState(
            sfpewLogicalProgram(), static_cast<GLint>(sfpewLogicalArrayBufferBinding()));
        if (!DisplayListManager::callSingleCaptured(list)) DisplayListManager::callList(list);
    }
}

void glCallLists(GLsizei n, GLenum type, const GLvoid* lists) {
    // Entry strict resolve; see glCallList (flush-only for the same reason).
    (void)g_glstate;
    flushPendingImmediateDraws();
    // LOG()
    // LOG_D("glCallLists(%i, %s, %p)", n, glEnumToString(type), lists)

    // Validate before the record path: n * type_to_bytes(type) feeds a
    // size_t deep-copy, so a negative n underflows to a huge memcpy and an
    // unknown type yields a zero-size copy replayed against garbage.
    if (n < 0) {
        g_glstate.set_error(GL_INVALID_VALUE);
        return;
    }
    switch (type) {
    case GL_BYTE:
    case GL_UNSIGNED_BYTE:
    case GL_SHORT:
    case GL_UNSIGNED_SHORT:
    case GL_INT:
    case GL_UNSIGNED_INT:
    case GL_FLOAT:
    case GL_2_BYTES:
    case GL_3_BYTES:
    case GL_4_BYTES:
        break;
    default:
        g_glstate.set_error(GL_INVALID_ENUM);
        return;
    }
    if (n == 0 || lists == nullptr) return;

    if (DisplayListManager::shouldRecord()) {
        displayListManager.record<glCallLists>({{2, n * PointerUtils::type_to_bytes(type)}}, n, type, lists);
        if (DisplayListManager::shouldFinish()) return;
    }
    thread_local std::vector<GLuint> decodedListIds;
    decodedListIds.clear();
    const size_t listCount = n > 0 ? static_cast<size_t>(n) : 0u;
    const GLuint* listIds = nullptr;
    if (listCount != 0 && type == GL_UNSIGNED_INT && currentListBase == 0 &&
        reinterpret_cast<uintptr_t>(lists) % alignof(GLuint) == 0) {
        listIds = static_cast<const GLuint*>(lists);
    } else if (listCount != 0) {
        decodedListIds.assign(listCount, currentListBase);
        switch (type) {
        case GL_BYTE:
            decodeNativeListIds<GLbyte>(n, lists, decodedListIds);
            break;
        case GL_UNSIGNED_BYTE:
            decodeNativeListIds<GLubyte>(n, lists, decodedListIds);
            break;
        case GL_SHORT:
            decodeNativeListIds<GLshort>(n, lists, decodedListIds);
            break;
        case GL_UNSIGNED_SHORT:
            decodeNativeListIds<GLushort>(n, lists, decodedListIds);
            break;
        case GL_INT:
            decodeNativeListIds<GLint>(n, lists, decodedListIds);
            break;
        case GL_UNSIGNED_INT:
            decodeNativeListIds<GLuint>(n, lists, decodedListIds);
            break;
        case GL_FLOAT:
            decodeNativeListIds<GLfloat>(n, lists, decodedListIds);
            break;
        case GL_2_BYTES:
            decodePackedListIds(n, 2, lists, decodedListIds);
            break;
        case GL_3_BYTES:
            decodePackedListIds(n, 3, lists, decodedListIds);
            break;
        case GL_4_BYTES:
            decodePackedListIds(n, 4, lists, decodedListIds);
            break;
        default:
            // Preserve the legacy fallback: invalid types call listBase n times.
            break;
        }
        listIds = decodedListIds.data();
    }

    sfpewListLogRequestedIds(listIds, static_cast<unsigned>(listCount));
    fpe_backend_draw_state_guard_t backendState(
        sfpewLogicalProgram(), static_cast<GLint>(sfpewLogicalArrayBufferBinding()));
    if (tryExecuteCapturedDisplayLists(listIds, listCount)) return;
    for (size_t i = 0; i < listCount; ++i) DisplayListManager::callList(listIds[i]);
}

void glListBase(GLuint base) {
    // LOG()
    // LOG_D("glGenLists(%d)", base)

    if (DisplayListManager::shouldRecord()) {
        displayListManager.record<glListBase>({}, base);
        if (DisplayListManager::shouldFinish()) return;
    }

    currentListBase = base;
}

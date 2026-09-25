// SimpleFPEWrapper - SimpleFPEWrapper/fpe/list.h
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#pragma once

#include <GL/gl.h>
#include "../init.h" // sfpewListLog*: display-list geometry accounting
#include "../log.h"
#include <glm/mat4x4.hpp>
#include <glm/vec3.hpp>
#include <array>
#include <cstddef>
#include <cstdint>
#include <unordered_map>

#include <vector>
#include <memory>
#include <tuple>
#include <cstring>
#include <utility>
#include <type_traits>

#define DEBUG 0

// Todo: record more functions

template <typename K, typename V>
using unordered_map = std::unordered_map<K, V>;

class GLCmd {
public:
    // Classification for the glEndList immediate-run compiler
    // (sfpewCompileImmediateRuns in drawing1x.cpp).
    enum class immediate_class_t : uint8_t { none, begin, end, vertex_data };

    virtual ~GLCmd() = default;
    GLCmd() = default;
    GLCmd(GLCmd&&) = default;
    GLCmd& operator=(GLCmd&&) = default;
    virtual void execute() const = 0;
    virtual bool tryMerge(const GLCmd&) { return false; }
    virtual bool isCapturedDraw() const { return false; }
    virtual bool bakePositionTranslation(const glm::vec3&) { return false; }
    virtual const GLCmd* capturedDrawForBatch(glm::mat4*) const { return nullptr; }
    virtual immediate_class_t immediateClass() const { return immediate_class_t::none; }
    virtual GLenum immediateBeginMode() const { return GL_NONE; }

    GLCmd(const GLCmd&) = delete;
    GLCmd& operator=(const GLCmd&) = delete;
};
using DisplayList = std::vector<std::unique_ptr<GLCmd>>;

void optimizeDisplayListCommands(DisplayList& commands);
void sfpewCompileImmediateRuns(DisplayList& commands);

// ---- Immediate-run classification (compile-time, by recorded function) ----
// One overload per recorded signature; pointer equality picks the immediate
// family out of same-signature state entries. The variadic fallback returns
// none for everything else.
namespace sfpew_imm {
using ic = GLCmd::immediate_class_t;
constexpr ic classify(void (*f)(GLenum)) { return f == &glBegin ? ic::begin : ic::none; }
constexpr ic classify(void (*f)()) { return f == &glEnd ? ic::end : ic::none; }
// float scalar
constexpr ic classify(void (*f)(GLfloat)) { return f == &glTexCoord1f ? ic::vertex_data : ic::none; }
constexpr ic classify(void (*f)(GLfloat, GLfloat)) {
    return f == &glVertex2f || f == &glTexCoord2f ? ic::vertex_data : ic::none;
}
constexpr ic classify(void (*f)(GLfloat, GLfloat, GLfloat)) {
    return f == &glVertex3f || f == &glColor3f || f == &glSecondaryColor3f ||
                   f == &glNormal3f || f == &glTexCoord3f
               ? ic::vertex_data
               : ic::none;
}
constexpr ic classify(void (*f)(GLfloat, GLfloat, GLfloat, GLfloat)) {
    return f == &glVertex4f || f == &glColor4f || f == &glTexCoord4f ? ic::vertex_data : ic::none;
}
// double scalar
constexpr ic classify(void (*f)(GLdouble)) { return f == &glTexCoord1d ? ic::vertex_data : ic::none; }
constexpr ic classify(void (*f)(GLdouble, GLdouble)) {
    return f == &glVertex2d || f == &glTexCoord2d ? ic::vertex_data : ic::none;
}
constexpr ic classify(void (*f)(GLdouble, GLdouble, GLdouble)) {
    return f == &glVertex3d || f == &glColor3d || f == &glSecondaryColor3d ||
                   f == &glNormal3d || f == &glTexCoord3d
               ? ic::vertex_data
               : ic::none;
}
constexpr ic classify(void (*f)(GLdouble, GLdouble, GLdouble, GLdouble)) {
    return f == &glVertex4d || f == &glColor4d || f == &glTexCoord4d ? ic::vertex_data : ic::none;
}
// int / short / byte scalar
constexpr ic classify(void (*f)(GLint)) { return f == &glTexCoord1i ? ic::vertex_data : ic::none; }
constexpr ic classify(void (*f)(GLint, GLint)) {
    return f == &glVertex2i || f == &glTexCoord2i ? ic::vertex_data : ic::none;
}
constexpr ic classify(void (*f)(GLint, GLint, GLint)) {
    return f == &glVertex3i || f == &glColor3i || f == &glSecondaryColor3i ||
                   f == &glNormal3i || f == &glTexCoord3i
               ? ic::vertex_data
               : ic::none;
}
constexpr ic classify(void (*f)(GLint, GLint, GLint, GLint)) {
    return f == &glVertex4i || f == &glColor4i || f == &glTexCoord4i ? ic::vertex_data : ic::none;
}
constexpr ic classify(void (*f)(GLshort)) { return f == &glTexCoord1s ? ic::vertex_data : ic::none; }
constexpr ic classify(void (*f)(GLshort, GLshort)) {
    return f == &glVertex2s || f == &glTexCoord2s ? ic::vertex_data : ic::none;
}
constexpr ic classify(void (*f)(GLshort, GLshort, GLshort)) {
    return f == &glVertex3s || f == &glColor3s || f == &glSecondaryColor3s ||
                   f == &glNormal3s || f == &glTexCoord3s
               ? ic::vertex_data
               : ic::none;
}
constexpr ic classify(void (*f)(GLshort, GLshort, GLshort, GLshort)) {
    return f == &glVertex4s || f == &glColor4s || f == &glTexCoord4s ? ic::vertex_data : ic::none;
}
constexpr ic classify(void (*f)(GLbyte, GLbyte, GLbyte)) {
    return f == &glColor3b || f == &glSecondaryColor3b || f == &glNormal3b ? ic::vertex_data
                                                                            : ic::none;
}
constexpr ic classify(void (*f)(GLbyte, GLbyte, GLbyte, GLbyte)) {
    return f == &glColor4b ? ic::vertex_data : ic::none;
}
constexpr ic classify(void (*f)(GLubyte, GLubyte, GLubyte)) {
    return f == &glColor3ub || f == &glSecondaryColor3ub ? ic::vertex_data : ic::none;
}
constexpr ic classify(void (*f)(GLubyte, GLubyte, GLubyte, GLubyte)) {
    return f == &glColor4ub ? ic::vertex_data : ic::none;
}
constexpr ic classify(void (*f)(GLuint, GLuint, GLuint)) {
    return f == &glColor3ui || f == &glSecondaryColor3ui ? ic::vertex_data : ic::none;
}
constexpr ic classify(void (*f)(GLuint, GLuint, GLuint, GLuint)) {
    return f == &glColor4ui ? ic::vertex_data : ic::none;
}
constexpr ic classify(void (*f)(GLushort, GLushort, GLushort)) {
    return f == &glColor3us || f == &glSecondaryColor3us ? ic::vertex_data : ic::none;
}
constexpr ic classify(void (*f)(GLushort, GLushort, GLushort, GLushort)) {
    return f == &glColor4us ? ic::vertex_data : ic::none;
}
// pointer variants
constexpr ic classify(void (*f)(const GLfloat*)) {
    return f == &glVertex2fv || f == &glVertex3fv || f == &glVertex4fv || f == &glColor3fv ||
                   f == &glColor4fv || f == &glSecondaryColor3fv || f == &glNormal3fv ||
                   f == &glTexCoord1fv || f == &glTexCoord2fv || f == &glTexCoord3fv ||
                   f == &glTexCoord4fv
               ? ic::vertex_data
               : ic::none;
}
constexpr ic classify(void (*f)(const GLdouble*)) {
    return f == &glVertex2dv || f == &glVertex3dv || f == &glVertex4dv || f == &glColor3dv ||
                   f == &glColor4dv || f == &glSecondaryColor3dv || f == &glNormal3dv ||
                   f == &glTexCoord1dv || f == &glTexCoord2dv || f == &glTexCoord3dv ||
                   f == &glTexCoord4dv
               ? ic::vertex_data
               : ic::none;
}
constexpr ic classify(void (*f)(const GLint*)) {
    return f == &glVertex2iv || f == &glVertex3iv || f == &glVertex4iv || f == &glColor3iv ||
                   f == &glColor4iv || f == &glSecondaryColor3iv || f == &glNormal3iv ||
                   f == &glTexCoord1iv || f == &glTexCoord2iv || f == &glTexCoord3iv ||
                   f == &glTexCoord4iv
               ? ic::vertex_data
               : ic::none;
}
constexpr ic classify(void (*f)(const GLshort*)) {
    return f == &glVertex2sv || f == &glVertex3sv || f == &glVertex4sv || f == &glColor3sv ||
                   f == &glColor4sv || f == &glSecondaryColor3sv || f == &glNormal3sv ||
                   f == &glTexCoord1sv || f == &glTexCoord2sv || f == &glTexCoord3sv ||
                   f == &glTexCoord4sv
               ? ic::vertex_data
               : ic::none;
}
constexpr ic classify(void (*f)(const GLbyte*)) {
    return f == &glColor3bv || f == &glColor4bv || f == &glSecondaryColor3bv ||
                   f == &glNormal3bv
               ? ic::vertex_data
               : ic::none;
}
constexpr ic classify(void (*f)(const GLubyte*)) {
    return f == &glColor3ubv || f == &glColor4ubv || f == &glSecondaryColor3ubv
               ? ic::vertex_data
               : ic::none;
}
constexpr ic classify(void (*f)(const GLuint*)) {
    return f == &glColor3uiv || f == &glColor4uiv || f == &glSecondaryColor3uiv
               ? ic::vertex_data
               : ic::none;
}
constexpr ic classify(void (*f)(const GLushort*)) {
    return f == &glColor3usv || f == &glColor4usv || f == &glSecondaryColor3usv
               ? ic::vertex_data
               : ic::none;
}
// multitexcoord scalar + pointer
constexpr ic classify(void (*f)(GLenum, GLfloat)) {
    return f == &glMultiTexCoord1f ? ic::vertex_data : ic::none;
}
constexpr ic classify(void (*f)(GLenum, GLfloat, GLfloat)) {
    return f == &glMultiTexCoord2f ? ic::vertex_data : ic::none;
}
constexpr ic classify(void (*f)(GLenum, GLfloat, GLfloat, GLfloat)) {
    return f == &glMultiTexCoord3f ? ic::vertex_data : ic::none;
}
constexpr ic classify(void (*f)(GLenum, GLfloat, GLfloat, GLfloat, GLfloat)) {
    return f == &glMultiTexCoord4f ? ic::vertex_data : ic::none;
}
constexpr ic classify(void (*f)(GLenum, GLdouble)) {
    return f == &glMultiTexCoord1d ? ic::vertex_data : ic::none;
}
constexpr ic classify(void (*f)(GLenum, GLdouble, GLdouble)) {
    return f == &glMultiTexCoord2d ? ic::vertex_data : ic::none;
}
constexpr ic classify(void (*f)(GLenum, GLdouble, GLdouble, GLdouble)) {
    return f == &glMultiTexCoord3d ? ic::vertex_data : ic::none;
}
constexpr ic classify(void (*f)(GLenum, GLdouble, GLdouble, GLdouble, GLdouble)) {
    return f == &glMultiTexCoord4d ? ic::vertex_data : ic::none;
}
constexpr ic classify(void (*f)(GLenum, GLint)) {
    return f == &glMultiTexCoord1i ? ic::vertex_data : ic::none;
}
constexpr ic classify(void (*f)(GLenum, GLint, GLint)) {
    return f == &glMultiTexCoord2i ? ic::vertex_data : ic::none;
}
constexpr ic classify(void (*f)(GLenum, GLint, GLint, GLint)) {
    return f == &glMultiTexCoord3i ? ic::vertex_data : ic::none;
}
constexpr ic classify(void (*f)(GLenum, GLint, GLint, GLint, GLint)) {
    return f == &glMultiTexCoord4i ? ic::vertex_data : ic::none;
}
constexpr ic classify(void (*f)(GLenum, GLshort)) {
    return f == &glMultiTexCoord1s ? ic::vertex_data : ic::none;
}
constexpr ic classify(void (*f)(GLenum, GLshort, GLshort)) {
    return f == &glMultiTexCoord2s ? ic::vertex_data : ic::none;
}
constexpr ic classify(void (*f)(GLenum, GLshort, GLshort, GLshort)) {
    return f == &glMultiTexCoord3s ? ic::vertex_data : ic::none;
}
constexpr ic classify(void (*f)(GLenum, GLshort, GLshort, GLshort, GLshort)) {
    return f == &glMultiTexCoord4s ? ic::vertex_data : ic::none;
}
constexpr ic classify(void (*f)(GLenum, const GLfloat*)) {
    return f == &glMultiTexCoord1fv || f == &glMultiTexCoord2fv || f == &glMultiTexCoord3fv ||
                   f == &glMultiTexCoord4fv
               ? ic::vertex_data
               : ic::none;
}
constexpr ic classify(void (*f)(GLenum, const GLdouble*)) {
    return f == &glMultiTexCoord1dv || f == &glMultiTexCoord2dv || f == &glMultiTexCoord3dv ||
                   f == &glMultiTexCoord4dv
               ? ic::vertex_data
               : ic::none;
}
constexpr ic classify(void (*f)(GLenum, const GLint*)) {
    return f == &glMultiTexCoord1iv || f == &glMultiTexCoord2iv || f == &glMultiTexCoord3iv ||
                   f == &glMultiTexCoord4iv
               ? ic::vertex_data
               : ic::none;
}
constexpr ic classify(void (*f)(GLenum, const GLshort*)) {
    return f == &glMultiTexCoord1sv || f == &glMultiTexCoord2sv || f == &glMultiTexCoord3sv ||
                   f == &glMultiTexCoord4sv
               ? ic::vertex_data
               : ic::none;
}
// everything else records as none
template <typename F> constexpr ic classify(F) { return ic::none; }
} // namespace sfpew_imm

template <auto FuncPtr, typename... Args>
class GLFuncCmd : public GLCmd {
    using StoredArgs = std::tuple<std::decay_t<Args>...>;
    StoredArgs args;
    std::vector<std::vector<uint8_t>> argBuffers;

    static constexpr immediate_class_t kImmediateClass = sfpew_imm::classify(FuncPtr);

public:
    explicit GLFuncCmd(Args&&... processedArgs, std::vector<std::vector<uint8_t>>&& buffers)
        : args(std::forward<Args>(processedArgs)...), argBuffers(std::move(buffers)) {}

    void execute() const override {
        std::apply([](auto&&... args) { FuncPtr(std::forward<decltype(args)>(args)...); }, args);
    }

    immediate_class_t immediateClass() const override { return kImmediateClass; }

    GLenum immediateBeginMode() const override {
        if constexpr (kImmediateClass == immediate_class_t::begin && sizeof...(Args) >= 1) {
            return static_cast<GLenum>(std::get<0>(args));
        } else {
            return GL_NONE;
        }
    }
};

class DisplayListManager {
    inline static GLuint nextListId = 1;
    inline static GLenum listMode = GL_COMPILE;
    inline static GLuint callingDepth = 0;
    inline static uint64_t mutationGeneration = 1;

    // Deliberately immortal (allocated, never freed). A process normally
    // exits with its GL context still current and its display lists still
    // recorded; destroying the registry then would run every captured
    // command's destructor, and those call GL - glDeleteBuffers, and a
    // fence in the vertex arena - at a point where exit-time teardown has
    // already invalidated the driver's dispatch, which segfaults. Freeing
    // GPU objects on the way out buys nothing, because the driver reclaims
    // all of them when the process dies. Runtime destruction (glDeleteLists,
    // re-recording a list) is unaffected and still releases properly.
    inline static unordered_map<GLuint, DisplayList>& lists =
        *new unordered_map<GLuint, DisplayList>();
    inline static GLuint currentListID = 0;

    template <auto Func, typename... ProcessedArgs>
    void recordImpl(std::vector<std::vector<uint8_t>>&& buffers, ProcessedArgs&&... args) {
        bumpMutationGeneration();
        lists[currentListID].emplace_back(std::make_unique<GLFuncCmd<Func, ProcessedArgs...>>(
            std::forward<ProcessedArgs>(args)..., std::move(buffers)));
    }

    static void bumpMutationGeneration() {
        ++mutationGeneration;
        // Zero is reserved for an uninitialised consumer cache. Unsigned
        // wraparound is defined, so skip it if this process lives long enough
        // to rebuild 2^64 display-list commands.
        if (mutationGeneration == 0) ++mutationGeneration;
    }

public:
    static GLuint genDisplayList(GLsizei range) {
        // glGenLists: zero or negative ranges allocate nothing and return 0.
        if (range <= 0) return 0;
        GLuint first = nextListId;
        nextListId += range;
        for (GLsizei i = 0; i < range; ++i) {
            lists[first + i] = std::vector<std::unique_ptr<GLCmd>>{};
        }
        bumpMutationGeneration();
        return first;
    }

    static void deleteDisplayList(GLuint list, GLsizei range) {
        // A negative range previously wrapped to ~2^32 iterations here.
        if (range <= 0) return;
        for (GLsizei i = 0; i < range; ++i) {
            lists.erase(list + i);
        }
        bumpMutationGeneration();
    }

    static GLboolean isDisplayList(GLuint list) { return lists.find(list) != lists.end() ? GL_TRUE : GL_FALSE; }

    static void startRecord(GLuint listID, GLenum mode) {
        bumpMutationGeneration();
        currentListID = listID;
        listMode = mode;
        lists.try_emplace(listID).first->second.clear();
    }

    static void endRecord() {
        auto it = lists.find(currentListID);
        if (it != lists.end()) {
            sfpewCompileImmediateRuns(it->second);
            optimizeDisplayListCommands(it->second);
            sfpewListLogCompiled(currentListID, it->second.size());
        }
        bumpMutationGeneration();
        currentListID = 0;
        listMode = GL_COMPILE;
    }

    // How many lists exist and how many hold anything to draw. The pair
    // separates "the game built no geometry" from "the game built it and
    // then declined to draw it", which look identical from the draw stream.
    static void inventory(unsigned* total, unsigned* nonEmpty) {
        unsigned all = 0, filled = 0;
        for (const auto& entry : lists) {
            ++all;
            if (!entry.second.empty()) ++filled;
        }
        *total = all;
        *nonEmpty = filled;
    }

    static int isRecording() { return currentListID != 0 ? 1 : 0; }


    static int isCalling() { return callingDepth != 0; }

    static int shouldRecord() { return callingDepth == 0 && currentListID != 0; }

    static int shouldFinish() { return (currentListID != 0 && listMode == GL_COMPILE) ? 1 : 0; }

    template <auto Func, typename... Args>
    void record(const std::vector<std::pair<size_t, size_t>>& pointerArgs, Args&&... args) {
        std::vector<std::vector<uint8_t>> argBuffers;
        auto argsTuple = std::make_tuple(std::forward<Args>(args)...);

        [&]<size_t... Is>(std::index_sequence<Is...>) {
            (([&] {
                 for (const auto& [index, size] : pointerArgs) {
                     if (index == Is) {
                         auto& arg = std::get<Is>(argsTuple);
                         using ArgType = std::decay_t<decltype(arg)>;

                         if constexpr (std::is_pointer_v<ArgType>) {
                             if (arg != nullptr) {
                                 std::vector<uint8_t> buffer(size);
                                 std::memcpy(buffer.data(), arg, size);
                                 argBuffers.emplace_back(std::move(buffer));
                                 arg = reinterpret_cast<ArgType>(argBuffers.back().data());
                             }
                         }
                         break;
                     }
                 }
             })(),
             ...);
        }(std::index_sequence_for<Args...>{});

        std::apply(
            [&](auto&&... processedArgs) {
                this->template recordImpl<Func>(std::move(argBuffers),
                                                std::forward<decltype(processedArgs)>(processedArgs)...);
            },
            argsTuple);
    }

    void recordCommand(std::unique_ptr<GLCmd> command) {
        if (command == nullptr) return;
        bumpMutationGeneration();
        auto& commands = lists[currentListID];
        // A command may fold an immediately adjacent command only when it can
        // prove that doing so preserves the display-list state boundary.
        if (!commands.empty() && commands.back()->tryMerge(*command)) return;
        commands.emplace_back(std::move(command));
    }

    // GL 2.1 guarantees at least 64 nesting levels; recorded glCallList
    // commands re-enter callList, so an unbounded (or self-referential)
    // chain would otherwise overflow the native stack.
    static constexpr GLuint kMaxListNesting = 64;

    static void callList(GLuint listID) {
        auto it = lists.find(listID);
        sfpewListLogCalled(listID, it != lists.end() ? 1 : 0,
                           it != lists.end() ? it->second.size() : 0u);
        if (it == lists.end()) return;

        if (callingDepth >= kMaxListNesting) {
            SFPEW_LOGW("glCallList(%u): list nesting exceeds %u levels; call skipped", listID,
                       kMaxListNesting);
            return;
        }

        ++callingDepth;
        for (auto& cmd : it->second) {
            cmd->execute();
        }
        --callingDepth;
    }

    static bool callSingleCaptured(GLuint listID) {
        if (callingDepth != 0) return false;

        struct cache_entry_t {
            uint64_t generation = 0;
            GLuint listID = 0;
            const GLCmd* command = nullptr;
        };
        constexpr size_t kCacheSize = 256;
        // Heap-backed rather than a thread_local array: the module's whole TLS
        // block has to fit glibc's static-TLS surplus for tls_model
        // initial-exec to be usable, and this cache alone was 6144 of the 9216
        // bytes. One pointer load and a null check replace what would otherwise
        // be a __tls_get_addr call per access (plans/12).
        using cache_t = std::array<cache_entry_t, kCacheSize>;
        thread_local std::unique_ptr<cache_t> cacheStorage;
        if (cacheStorage == nullptr) cacheStorage = std::make_unique<cache_t>();
        cache_t& cache = *cacheStorage;

        const uint64_t currentGeneration = mutationGeneration;
        auto& entry = cache[(static_cast<size_t>(listID) * 2654435761u) & (kCacheSize - 1u)];
        const GLCmd* command = nullptr;
        if (entry.generation == currentGeneration && entry.listID == listID) {
            command = entry.command;
        } else {
            const auto it = lists.find(listID);
            if (it == lists.end() || it->second.size() != 1) return false;
            command = it->second.front().get();
            if (command == nullptr || !command->isCapturedDraw()) return false;
            entry = {currentGeneration, listID, command};
        }

        ++callingDepth;
        command->execute();
        --callingDepth;
        sfpewListLogDrewOne();
        return true;
    }

    static const DisplayList* findList(GLuint listID) {
        const auto it = lists.find(listID);
        return it == lists.end() ? nullptr : &it->second;
    }

    static uint64_t generation() { return mutationGeneration; }
    static GLuint currentList() { return currentListID; }
    static GLuint listBase(); // defined in list.cpp next to the storage
    static GLenum currentListMode() { return listMode; }
};

inline DisplayListManager displayListManager;

inline GLboolean disableRecording = GL_FALSE;

bool tryExecuteCapturedDisplayLists(const GLuint* listIds, size_t listCount);

// Snapshots the current client arrays for one glDrawArrays-shaped sub-draw
// and appends it to the list being recorded, or records nothing when the draw
// cannot be snapshotted (fpe/list_capture.cpp). The caller must already have
// established shouldRecord() and taken its entry barrier; shouldFinish() is
// the caller's too, since a multi-draw records every sub-draw before it
// decides whether to also execute them.
void sfpewRecordCapturedDrawArrays(GLenum mode, GLint first, GLsizei count);

// Indexed counterpart (plans/15 15.3), same contract. Serves glDrawElements,
// glDrawRangeElements - whose start/end are a promise about the index values,
// not extra data to record, so they are not passed - and glMultiDrawElements,
// which records each sub-draw the way glDrawElements records itself.
void sfpewRecordCapturedDrawElements(GLenum mode, GLsizei count, GLenum type,
                                     const GLvoid* indices);

#define SELF_CALL(func, ...)                                                                                           \
    {                                                                                                                  \
        GLboolean alreadyDisabled = disableRecording;                                                                  \
        disableRecording = GL_TRUE;                                                                                    \
        func(__VA_ARGS__);                                                                                             \
        disableRecording = alreadyDisabled;                                                                            \
    }

#define LIST_RECORD(func, pointers, ...)                                                                               \
    if (!disableRecording && DisplayListManager::shouldRecord()) {                                                     \
        displayListManager.record<func>(pointers, ##__VA_ARGS__);                                                      \
        if (DisplayListManager::shouldFinish()) return;                                                                \
    }

GLAPI GLAPIENTRY GLuint glGenLists(GLsizei range);
GLAPI GLAPIENTRY void glDeleteLists(GLuint list, GLsizei range);
GLAPI GLAPIENTRY GLboolean glIsList(GLuint list);
GLAPI GLAPIENTRY void glNewList(GLuint list, GLenum mode);
GLAPI GLAPIENTRY void glEndList();
GLAPI GLAPIENTRY void glCallList(GLuint list);
GLAPI GLAPIENTRY void glCallLists(GLsizei n, GLenum type, const GLvoid* lists);
GLAPI GLAPIENTRY void glListBase(GLuint base);

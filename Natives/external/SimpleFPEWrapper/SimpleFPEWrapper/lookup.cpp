// SimpleFPEWrapper - SimpleFPEWrapper/lookup.cpp
// Copyright (c) 2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v3.0:
//   https://www.gnu.org/licenses/gpl-3.0.txt
//   https://www.gnu.org/licenses/lgpl-3.0.txt
// SPDX-License-Identifier: LGPL-3.0-only
// End of Source File Header

#include "EGL/egl.h"
#include "egl_dispatch.h"
#include "init.h"
#include "log.h"
#include <cstdio>
#include "fpe/transformation.h"
#include "fpe/drawing1x.h" // sfpewEntryBarrier: the swap must drain the pending batch

#define GETPROC(name, var)                                                                                             \
    if (std::strcmp(#name, var) == 0) {                                                                                \
        return (__eglMustCastToProperFunctionPointerType)name;                                                         \
    }

// Desktop-only EXT/ARB spellings that are exactly the backend's core GLES
// function: the backend's own eglGetProcAddress would return NULL for
// these names, so they resolve against the loaded function table instead.
#define GETPROC_BACKEND_ALIAS(alias, core)                                                                             \
    if (std::strcmp(#alias, name) == 0) {                                                                              \
        if (!sfpewEnsureBackend() || g_glFuncs.core == nullptr) return nullptr;                                         \
        return (__eglMustCastToProperFunctionPointerType)g_glFuncs.core;                                                \
    }

// An EXT/ARB spelling of an entry point the WRAPPER implements. Distinct from
// GETPROC_BACKEND_ALIAS, which hands out the backend's own pointer: for a
// wrapped entry that would bypass the wrapper entirely, and legacy frontends
// (LWJGL2) ask for the ARB spellings by preference.
#define GETPROC_WRAPPER_ALIAS(alias, wrapped)                                                                          \
    if (std::strcmp(#alias, name) == 0) {                                                                              \
        return (__eglMustCastToProperFunctionPointerType)wrapped;                                                      \
    }

SFPEW_APIENTRY __eglMustCastToProperFunctionPointerType eglGetProcAddress(const char* name) {
    if (!name) return nullptr;

    // Keep the resolver itself stable so cached lookup code can re-enter this
    // dispatch point after switching from a native to an emulated context.
    if (std::strcmp("eglGetProcAddress", name) == 0)
        return (__eglMustCastToProperFunctionPointerType)eglGetProcAddress;

    // Context creation is always observed: a direct context may later create a
    // compatibility context that requires the wrapper again.
    if (std::strcmp("eglCreateContext", name) == 0)
        return (__eglMustCastToProperFunctionPointerType)sfpewEglCreateContext;
    if (std::strcmp("eglDestroyContext", name) == 0)
        return (__eglMustCastToProperFunctionPointerType)sfpewEglDestroyContext;

    // A pointer resolved while a native Core/Compatibility context is current
    // must be the backend pointer itself, not a forwarding wrapper.
    // Complete lazy initialization before the dispatch lookup reads the backend
    // current-context hook or resolver table.
    (void)sfpewEnsureBackend();
    if (sfpewCurrentContextDispatch() == SfpewContextDispatchMode::BackendDirect) {
        return g_eglFuncs.eglGetProcAddress != nullptr ? g_eglFuncs.eglGetProcAddress(name) : nullptr;
    }

    // Routing eglMakeCurrent through the wrapper turns the current context
    // from something every state access has to ask libEGL about into a plain
    // thread-local read (see sfpewCurrentContext). Apps that call libEGL
    // directly keep the polling path and stay correct.
    if (std::strcmp("eglMakeCurrent", name) == 0) {
        // The internal name matters: taking the address of the exported
        // eglMakeCurrent would go through this library's GOT, where an
        // already-loaded libEGL interposes its own definition and the
        // wrapper never sees the call.
        return (__eglMustCastToProperFunctionPointerType)sfpewEglMakeCurrent;
    }
    // Same reasoning for the swap: the wrapper has to drain its pending batch
    // before the frame is presented, or geometry drawn late in the frame is
    // submitted into the next one and cleared away.
    if (std::strcmp("eglSwapBuffers", name) == 0)
        return (__eglMustCastToProperFunctionPointerType)sfpewEglSwapBuffers;
    if (std::strcmp("eglSwapBuffersWithDamageEXT", name) == 0 ||
        std::strcmp("eglSwapBuffersWithDamageKHR", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)sfpewEglSwapBuffersWithDamageEXT;
    }

    GETPROC(glGetError, name)
    GETPROC(glGetString, name)
    GETPROC(glGetStringi, name)
    GETPROC(glGetIntegerv, name)
    GETPROC(glGetBooleanv, name)
    GETPROC(glGetDoublev, name)
    GETPROC(glIsEnabled, name)
    GETPROC(glGetLightfv, name)
    GETPROC(glGetLightiv, name)
    GETPROC(glGetMaterialfv, name)
    GETPROC(glGetMaterialiv, name)
    GETPROC(glGetTexEnvfv, name)
    GETPROC(glGetTexEnviv, name)
    GETPROC(glGetTexGenfv, name)
    GETPROC(glGetTexGeniv, name)
    GETPROC(glGetTexGendv, name)
    GETPROC(glDrawArrays, name)
    GETPROC(glDrawElements, name)
    // GL 1.2/1.4 core draw entry points. Passing these through raw skipped
    // legacy-mode conversion, fixed-function array wiring and the emulated
    // alpha-test uniforms.
    GETPROC(glDrawRangeElements, name)
    GETPROC(glMultiDrawArrays, name)
    GETPROC(glMultiDrawElements, name)
    if (std::strcmp("glDrawRangeElementsEXT", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glDrawRangeElements;
    }
    if (std::strcmp("glMultiDrawArraysEXT", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiDrawArrays;
    }
    if (std::strcmp("glMultiDrawElementsEXT", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiDrawElements;
    }
    GETPROC(glClear, name)
    GETPROC(glClearDepth, name)
    GETPROC(glClearDepthf, name)
    GETPROC(glDrawBuffer, name)
    GETPROC(glReadBuffer, name)
    GETPROC(glGetQueryObjectiv, name)
    GETPROC_WRAPPER_ALIAS(glGetQueryObjectivARB, glGetQueryObjectiv)
    GETPROC_WRAPPER_ALIAS(glGetQueryObjectivEXT, glGetQueryObjectiv)
    GETPROC(glGetQueryObjecti64v, name)
    GETPROC(glGetQueryObjectui64v, name)
    GETPROC_WRAPPER_ALIAS(glGetQueryObjecti64vEXT, glGetQueryObjecti64v)
    GETPROC_WRAPPER_ALIAS(glGetQueryObjectui64vEXT, glGetQueryObjectui64v)
    GETPROC(glReadPixels, name)
    GETPROC(glFlush, name)
    GETPROC(glFinish, name)
    GETPROC(glBindFramebuffer, name)
    if (std::strcmp("glBindFramebufferEXT", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glBindFramebuffer;
    }
    GETPROC(glUseProgram, name)
    GETPROC(glCreateShader, name)
    GETPROC(glDeleteShader, name)
    GETPROC(glShaderSource, name)
    GETPROC(glCompileShader, name)
    GETPROC(glGetShaderSource, name)
    GETPROC(glGetShaderInfoLog, name)
    if (std::strcmp("glShaderSourceARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glShaderSource;
    }
    if (std::strcmp("glCompileShaderARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glCompileShader;
    }
    GETPROC(glLinkProgram, name)
    if (std::strcmp("glLinkProgramARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glLinkProgram;
    }
    GETPROC(glAttachShader, name)
    GETPROC(glDetachShader, name)
    GETPROC(glDeleteProgram, name)
    GETPROC(glGetShaderiv, name)
    GETPROC(glGetProgramiv, name)
    GETPROC(glGetAttachedShaders, name)
    GETPROC(glGetProgramInfoLog, name)
    GETPROC(glGetUniformLocation, name)
    GETPROC(glGetAttribLocation, name)

    // --- Desktop FBO surface (GL_EXT_framebuffer_object + ARB core) ------
    // LWJGL only flips its FBO capability bit when EVERY function of the
    // extension resolves; keep this family complete.
    GETPROC(glRenderbufferStorage, name)
    GETPROC(glRenderbufferStorageMultisample, name)
    GETPROC(glFramebufferTexture1D, name)
    GETPROC(glFramebufferTexture3D, name)
    if (std::strcmp("glRenderbufferStorageEXT", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glRenderbufferStorage;
    }
    if (std::strcmp("glRenderbufferStorageMultisampleEXT", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glRenderbufferStorageMultisample;
    }
    if (std::strcmp("glFramebufferTexture1DEXT", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glFramebufferTexture1D;
    }
    if (std::strcmp("glFramebufferTexture3DEXT", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glFramebufferTexture3D;
    }
    GETPROC_BACKEND_ALIAS(glGenFramebuffersEXT, glGenFramebuffers)
    GETPROC_BACKEND_ALIAS(glDeleteFramebuffersEXT, glDeleteFramebuffers)
    GETPROC_BACKEND_ALIAS(glIsFramebufferEXT, glIsFramebuffer)
    GETPROC_BACKEND_ALIAS(glCheckFramebufferStatusEXT, glCheckFramebufferStatus)
    GETPROC_BACKEND_ALIAS(glFramebufferTexture2DEXT, glFramebufferTexture2D)
    GETPROC_BACKEND_ALIAS(glFramebufferRenderbufferEXT, glFramebufferRenderbuffer)
    GETPROC_BACKEND_ALIAS(glGetFramebufferAttachmentParameterivEXT, glGetFramebufferAttachmentParameteriv)
    GETPROC_BACKEND_ALIAS(glGenRenderbuffersEXT, glGenRenderbuffers)
    GETPROC_BACKEND_ALIAS(glDeleteRenderbuffersEXT, glDeleteRenderbuffers)
    GETPROC_BACKEND_ALIAS(glIsRenderbufferEXT, glIsRenderbuffer)
    GETPROC_BACKEND_ALIAS(glBindRenderbufferEXT, glBindRenderbuffer)
    GETPROC_BACKEND_ALIAS(glGetRenderbufferParameterivEXT, glGetRenderbufferParameteriv)
    // Wrapped, not backend-aliased: the wrapper rebuilds the 2D mip chain
    // after the backend call (mobile drivers leave high levels stale).
    GETPROC(glGenerateMipmap, name)
    GETPROC_WRAPPER_ALIAS(glGenerateMipmapEXT, glGenerateMipmap)
    GETPROC_BACKEND_ALIAS(glBlitFramebufferEXT, glBlitFramebuffer)
    GETPROC_BACKEND_ALIAS(glDrawBuffersARB, glDrawBuffers)
    GETPROC_BACKEND_ALIAS(glDrawBuffersATI, glDrawBuffers)

    // --- ARB_shader_objects / ARB_vertex_shader value setters ------------
    GETPROC_BACKEND_ALIAS(glUniform1fARB, glUniform1f)
    GETPROC_BACKEND_ALIAS(glUniform2fARB, glUniform2f)
    GETPROC_BACKEND_ALIAS(glUniform3fARB, glUniform3f)
    GETPROC_BACKEND_ALIAS(glUniform4fARB, glUniform4f)
    GETPROC_BACKEND_ALIAS(glUniform1iARB, glUniform1i)
    GETPROC_BACKEND_ALIAS(glUniform2iARB, glUniform2i)
    GETPROC_BACKEND_ALIAS(glUniform3iARB, glUniform3i)
    GETPROC_BACKEND_ALIAS(glUniform4iARB, glUniform4i)
    GETPROC_BACKEND_ALIAS(glUniform1fvARB, glUniform1fv)
    GETPROC_BACKEND_ALIAS(glUniform2fvARB, glUniform2fv)
    GETPROC_BACKEND_ALIAS(glUniform3fvARB, glUniform3fv)
    GETPROC_BACKEND_ALIAS(glUniform4fvARB, glUniform4fv)
    GETPROC_BACKEND_ALIAS(glUniform1ivARB, glUniform1iv)
    GETPROC_BACKEND_ALIAS(glUniform2ivARB, glUniform2iv)
    GETPROC_BACKEND_ALIAS(glUniform3ivARB, glUniform3iv)
    GETPROC_BACKEND_ALIAS(glUniform4ivARB, glUniform4iv)
    GETPROC_BACKEND_ALIAS(glUniformMatrix2fvARB, glUniformMatrix2fv)
    GETPROC_BACKEND_ALIAS(glUniformMatrix3fvARB, glUniformMatrix3fv)
    GETPROC_BACKEND_ALIAS(glUniformMatrix4fvARB, glUniformMatrix4fv)
    GETPROC_BACKEND_ALIAS(glValidateProgramARB, glValidateProgram)
    GETPROC_BACKEND_ALIAS(glBindAttribLocationARB, glBindAttribLocation)
    GETPROC_BACKEND_ALIAS(glGetActiveUniformARB, glGetActiveUniform)
    GETPROC_BACKEND_ALIAS(glGetActiveAttribARB, glGetActiveAttrib)
    GETPROC_BACKEND_ALIAS(glGetUniformfvARB, glGetUniformfv)
    GETPROC_BACKEND_ALIAS(glGetUniformivARB, glGetUniformiv)
    GETPROC_WRAPPER_ALIAS(glVertexAttribPointerARB, glVertexAttribPointer)
    GETPROC_WRAPPER_ALIAS(glEnableVertexAttribArrayARB, glEnableVertexAttribArray)
    GETPROC_WRAPPER_ALIAS(glDisableVertexAttribArrayARB, glDisableVertexAttribArray)
    // Core in GLES as well, so these once handed out the backend's own
    // pointer. That skipped the entry barrier, and a constant written between
    // two immediate-mode runs then repainted the earlier one (plans/16 M6).
    GETPROC(glVertexAttrib1f, name)
    GETPROC(glVertexAttrib2f, name)
    GETPROC(glVertexAttrib3f, name)
    GETPROC(glVertexAttrib4f, name)
    GETPROC(glVertexAttrib1fv, name)
    GETPROC(glVertexAttrib2fv, name)
    GETPROC(glVertexAttrib3fv, name)
    GETPROC(glVertexAttrib4fv, name)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib1fARB, glVertexAttrib1f)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib2fARB, glVertexAttrib2f)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib3fARB, glVertexAttrib3f)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib4fARB, glVertexAttrib4f)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib1fvARB, glVertexAttrib1fv)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib2fvARB, glVertexAttrib2fv)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib3fvARB, glVertexAttrib3fv)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib4fvARB, glVertexAttrib4fv)
    GETPROC(glVertexAttrib1d, name)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib1dARB, glVertexAttrib1d)
    GETPROC(glVertexAttrib1dv, name)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib1dvARB, glVertexAttrib1dv)
    GETPROC(glVertexAttrib2d, name)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib2dARB, glVertexAttrib2d)
    GETPROC(glVertexAttrib2dv, name)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib2dvARB, glVertexAttrib2dv)
    GETPROC(glVertexAttrib3d, name)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib3dARB, glVertexAttrib3d)
    GETPROC(glVertexAttrib3dv, name)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib3dvARB, glVertexAttrib3dv)
    GETPROC(glVertexAttrib4d, name)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib4dARB, glVertexAttrib4d)
    GETPROC(glVertexAttrib4dv, name)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib4dvARB, glVertexAttrib4dv)
    GETPROC(glVertexAttrib1s, name)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib1sARB, glVertexAttrib1s)
    GETPROC(glVertexAttrib1sv, name)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib1svARB, glVertexAttrib1sv)
    GETPROC(glVertexAttrib2s, name)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib2sARB, glVertexAttrib2s)
    GETPROC(glVertexAttrib2sv, name)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib2svARB, glVertexAttrib2sv)
    GETPROC(glVertexAttrib3s, name)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib3sARB, glVertexAttrib3s)
    GETPROC(glVertexAttrib3sv, name)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib3svARB, glVertexAttrib3sv)
    GETPROC(glVertexAttrib4s, name)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib4sARB, glVertexAttrib4s)
    GETPROC(glVertexAttrib4sv, name)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib4svARB, glVertexAttrib4sv)
    GETPROC(glVertexAttrib4Nbv, name)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib4NbvARB, glVertexAttrib4Nbv)
    GETPROC(glVertexAttrib4Nsv, name)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib4NsvARB, glVertexAttrib4Nsv)
    GETPROC(glVertexAttrib4Niv, name)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib4NivARB, glVertexAttrib4Niv)
    GETPROC(glVertexAttrib4Nub, name)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib4NubARB, glVertexAttrib4Nub)
    GETPROC(glVertexAttrib4Nubv, name)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib4NubvARB, glVertexAttrib4Nubv)
    GETPROC(glVertexAttrib4Nusv, name)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib4NusvARB, glVertexAttrib4Nusv)
    GETPROC(glVertexAttrib4Nuiv, name)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib4NuivARB, glVertexAttrib4Nuiv)
    GETPROC(glVertexAttrib4bv, name)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib4bvARB, glVertexAttrib4bv)
    GETPROC(glVertexAttrib4iv, name)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib4ivARB, glVertexAttrib4iv)
    GETPROC(glVertexAttrib4ubv, name)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib4ubvARB, glVertexAttrib4ubv)
    GETPROC(glVertexAttrib4uiv, name)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib4uivARB, glVertexAttrib4uiv)
    GETPROC(glVertexAttrib4usv, name)
    GETPROC_WRAPPER_ALIAS(glVertexAttrib4usvARB, glVertexAttrib4usv)
    GETPROC(glGetVertexAttribdv, name)
    GETPROC_WRAPPER_ALIAS(glGetVertexAttribdvARB, glGetVertexAttribdv)

    // --- ARB_vertex_buffer_object / GL15 buffer surface -------------------
    GETPROC(glMapBuffer, name)
    GETPROC(glGetBufferSubData, name)
    if (std::strcmp("glMapBufferARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMapBuffer;
    }
    if (std::strcmp("glGetBufferSubDataARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glGetBufferSubData;
    }
    GETPROC_BACKEND_ALIAS(glGenBuffersARB, glGenBuffers)
    GETPROC_WRAPPER_ALIAS(glBufferDataARB, glBufferData)
    GETPROC_WRAPPER_ALIAS(glBufferSubDataARB, glBufferSubData)
    GETPROC_BACKEND_ALIAS(glIsBufferARB, glIsBuffer)
    GETPROC_WRAPPER_ALIAS(glGetBufferParameterivARB, glGetBufferParameteriv)
    GETPROC_WRAPPER_ALIAS(glUnmapBufferARB, glUnmapBuffer)
    if (std::strcmp("glGetUniformLocationARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glGetUniformLocation;
    }
    if (std::strcmp("glGetAttribLocationARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glGetAttribLocation;
    }
    if (std::strcmp("glGetShaderSourceARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glGetShaderSource;
    }
    if (std::strcmp("glCreateShaderObjectARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)sfpewCreateShaderObjectARB;
    }
    if (std::strcmp("glCreateProgramObjectARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)sfpewCreateProgramObjectARB;
    }
    if (std::strcmp("glDeleteObjectARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)sfpewDeleteObjectARB;
    }
    if (std::strcmp("glAttachObjectARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)sfpewAttachObjectARB;
    }
    if (std::strcmp("glDetachObjectARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)sfpewDetachObjectARB;
    }
    if (std::strcmp("glGetObjectParameterivARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)sfpewGetObjectParameterivARB;
    }
    if (std::strcmp("glGetInfoLogARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)sfpewGetInfoLogARB;
    }
    if (std::strcmp("glGetHandleARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)sfpewGetHandleARB;
    }
    if (std::strcmp("glUseProgramObjectARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glUseProgram;
    }

    GETPROC(glBlendColor, name)
    GETPROC(glBlendEquation, name)
    GETPROC(glBlendEquationSeparate, name)
    GETPROC(glBlendFunc, name)
    GETPROC(glBlendFuncSeparate, name)
    // The blend extensions the wrapper advertises resolve by their EXT/ARB
    // spellings too: LWJGL only enables GL_EXT_blend_func_separate &c. when
    // every function of the extension resolves, and legacy Minecraft calls
    // glBlendFuncSeparateEXT on that path (translucent foliage/water).
    // These map to the wrapper's own entry points so display-list recording
    // and state tracking stay intact.
    if (std::strcmp("glBlendFuncSeparateEXT", name) == 0 ||
        std::strcmp("glBlendFuncSeparateARB", name) == 0 ||
        std::strcmp("glBlendFuncSeparateINGR", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glBlendFuncSeparate;
    }
    if (std::strcmp("glBlendEquationEXT", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glBlendEquation;
    }
    if (std::strcmp("glBlendEquationSeparateEXT", name) == 0 ||
        std::strcmp("glBlendEquationSeparateATI", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glBlendEquationSeparate;
    }
    if (std::strcmp("glBlendColorEXT", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glBlendColor;
    }
    GETPROC(glDepthFunc, name)
    GETPROC(glDepthMask, name)
    GETPROC(glColorMask, name)
    GETPROC(glCullFace, name)
    GETPROC(glFrontFace, name)
    GETPROC(glViewport, name)
    GETPROC(glScissor, name)
    GETPROC(glPolygonOffset, name)
    GETPROC(glLineWidth, name)
    GETPROC(glStencilFunc, name)
    GETPROC(glStencilMask, name)
    GETPROC(glStencilOp, name)
    GETPROC(glTexParameterf, name)
    GETPROC(glTexParameterfv, name)
    GETPROC(glTexParameteri, name)
    GETPROC(glTexParameteriv, name)
    GETPROC(glGetTexParameterfv, name)
    GETPROC(glGetTexParameteriv, name)
    GETPROC(glAreTexturesResident, name)
    GETPROC(glPrioritizeTextures, name)
    GETPROC_WRAPPER_ALIAS(glAreTexturesResidentEXT, glAreTexturesResident)
    GETPROC_WRAPPER_ALIAS(glPrioritizeTexturesEXT, glPrioritizeTextures)
    GETPROC(glTexSubImage2D, name)
    GETPROC(glBindBuffer, name)
    // Wrapped so the fixed-function draw guard can restore the app's VAO
    // from a shadow instead of querying the driver on every draw.
    GETPROC(glBindVertexArray, name)
    GETPROC(glDeleteVertexArrays, name)
    GETPROC(glDeleteBuffers, name)
    // Reads and writes through the bound GL_ARRAY_BUFFER / VAO. Wrapped so
    // they stay visible to the wrapper rather than resolving to the backend's
    // own pointer (plans/12).
    GETPROC(glBufferData, name)
    GETPROC(glBufferSubData, name)
    GETPROC(glMapBufferRange, name)
    GETPROC(glUnmapBuffer, name)
    GETPROC(glGetBufferParameteriv, name)
    GETPROC(glVertexAttribPointer, name)
    GETPROC(glVertexAttribIPointer, name)
    GETPROC(glEnableVertexAttribArray, name)
    GETPROC(glDisableVertexAttribArray, name)
    if (std::strcmp("glBindBufferARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glBindBuffer;
    }
    if (std::strcmp("glDeleteBuffersARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glDeleteBuffers;
    }
    GETPROC(glActiveTexture, name)
    GETPROC(glBindTexture, name)
    GETPROC(glDeleteTextures, name)
    GETPROC(glTexImage2D, name)
    GETPROC(glTexImage3D, name)
    GETPROC(glTexImage1D, name)
    GETPROC(glTexSubImage1D, name)
    GETPROC(glCopyTexImage1D, name)
    GETPROC(glCopyTexSubImage1D, name)
    GETPROC(glCompressedTexImage1D, name)
    GETPROC(glCompressedTexSubImage1D, name)
    GETPROC(glGetCompressedTexImage, name)
    GETPROC(glCompressedTexImage2D, name)
    GETPROC(glCompressedTexSubImage2D, name)
    GETPROC_WRAPPER_ALIAS(glCompressedTexImage1DARB, glCompressedTexImage1D)
    GETPROC_WRAPPER_ALIAS(glCompressedTexSubImage1DARB, glCompressedTexSubImage1D)
    GETPROC_WRAPPER_ALIAS(glGetCompressedTexImageARB, glGetCompressedTexImage)
    GETPROC_WRAPPER_ALIAS(glCompressedTexImage2DARB, glCompressedTexImage2D)
    GETPROC_WRAPPER_ALIAS(glCompressedTexSubImage2DARB, glCompressedTexSubImage2D)
    GETPROC_WRAPPER_ALIAS(glCopyTexImage1DEXT, glCopyTexImage1D)
    GETPROC_WRAPPER_ALIAS(glCopyTexSubImage1DEXT, glCopyTexSubImage1D)
    GETPROC(glGetTexImage, name)
    GETPROC(glGetTexLevelParameteriv, name)
    GETPROC(glGetTexLevelParameterfv, name)

    GETPROC(glBegin, name)
    GETPROC(glEnd, name)
    GETPROC(glVertex2d, name)
    GETPROC(glVertex2f, name)
    GETPROC(glVertex2i, name)
    GETPROC(glVertex2s, name)
    GETPROC(glVertex3d, name)
    GETPROC(glVertex3f, name)
    GETPROC(glVertex3i, name)
    GETPROC(glVertex3s, name)
    GETPROC(glVertex4d, name)
    GETPROC(glVertex4f, name)
    GETPROC(glVertex4i, name)
    GETPROC(glVertex4s, name)
    GETPROC(glVertex2dv, name)
    GETPROC(glVertex2fv, name)
    GETPROC(glVertex2iv, name)
    GETPROC(glVertex2sv, name)
    GETPROC(glVertex3dv, name)
    GETPROC(glVertex3fv, name)
    GETPROC(glVertex3iv, name)
    GETPROC(glVertex3sv, name)
    GETPROC(glVertex4dv, name)
    GETPROC(glVertex4fv, name)
    GETPROC(glVertex4iv, name)
    GETPROC(glVertex4sv, name)
    GETPROC(glNormal3b, name)
    GETPROC(glNormal3d, name)
    GETPROC(glNormal3f, name)
    GETPROC(glNormal3i, name)
    GETPROC(glNormal3s, name)
    GETPROC(glNormal3bv, name)
    GETPROC(glNormal3dv, name)
    GETPROC(glNormal3fv, name)
    GETPROC(glNormal3iv, name)
    GETPROC(glNormal3sv, name)
    GETPROC(glColor3b, name)
    GETPROC(glColor3d, name)
    GETPROC(glColor3f, name)
    GETPROC(glColor3i, name)
    GETPROC(glColor3s, name)
    GETPROC(glColor3ub, name)
    GETPROC(glColor3ui, name)
    GETPROC(glColor3us, name)
    GETPROC(glColor4b, name)
    GETPROC(glColor4d, name)
    GETPROC(glColor4f, name)
    GETPROC(glColor4i, name)
    GETPROC(glColor4s, name)
    GETPROC(glColor4ub, name)
    GETPROC(glColor4ui, name)
    GETPROC(glColor4us, name)
    GETPROC(glColor3bv, name)
    GETPROC(glColor3dv, name)
    GETPROC(glColor3fv, name)
    GETPROC(glColor3iv, name)
    GETPROC(glColor3sv, name)
    GETPROC(glColor3ubv, name)
    GETPROC(glColor3uiv, name)
    GETPROC(glColor3usv, name)
    GETPROC(glColor4bv, name)
    GETPROC(glColor4dv, name)
    GETPROC(glColor4fv, name)
    GETPROC(glColor4iv, name)
    GETPROC(glColor4sv, name)
    GETPROC(glColor4ubv, name)
    GETPROC(glColor4uiv, name)
    GETPROC(glColor4usv, name)
    GETPROC(glTexCoord2f, name)
    GETPROC(glTexCoord4f, name)
    GETPROC(glMultiTexCoord2f, name)
    GETPROC(glMultiTexCoord4f, name)
    if (std::strcmp("glMultiTexCoord2fARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord2f;
    }
    GETPROC(glTexCoord1d, name)
    GETPROC(glTexCoord1f, name)
    GETPROC(glTexCoord1i, name)
    GETPROC(glTexCoord1s, name)
    GETPROC(glTexCoord2d, name)
    GETPROC(glTexCoord2i, name)
    GETPROC(glTexCoord2s, name)
    GETPROC(glTexCoord3d, name)
    GETPROC(glTexCoord3f, name)
    GETPROC(glTexCoord3i, name)
    GETPROC(glTexCoord3s, name)
    GETPROC(glTexCoord4d, name)
    GETPROC(glTexCoord4i, name)
    GETPROC(glTexCoord4s, name)
    GETPROC(glTexCoord1dv, name)
    GETPROC(glTexCoord1fv, name)
    GETPROC(glTexCoord1iv, name)
    GETPROC(glTexCoord1sv, name)
    GETPROC(glTexCoord2dv, name)
    GETPROC(glTexCoord2fv, name)
    GETPROC(glTexCoord2iv, name)
    GETPROC(glTexCoord2sv, name)
    GETPROC(glTexCoord3dv, name)
    GETPROC(glTexCoord3fv, name)
    GETPROC(glTexCoord3iv, name)
    GETPROC(glTexCoord3sv, name)
    GETPROC(glTexCoord4dv, name)
    GETPROC(glTexCoord4fv, name)
    GETPROC(glTexCoord4iv, name)
    GETPROC(glTexCoord4sv, name)
    GETPROC(glMultiTexCoord1d, name)
    if (std::strcmp("glMultiTexCoord1dARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord1d;
    }
    GETPROC(glMultiTexCoord1f, name)
    if (std::strcmp("glMultiTexCoord1fARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord1f;
    }
    GETPROC(glMultiTexCoord1i, name)
    if (std::strcmp("glMultiTexCoord1iARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord1i;
    }
    GETPROC(glMultiTexCoord1s, name)
    if (std::strcmp("glMultiTexCoord1sARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord1s;
    }
    GETPROC(glMultiTexCoord2d, name)
    if (std::strcmp("glMultiTexCoord2dARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord2d;
    }
    if (std::strcmp("glMultiTexCoord2fARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord2f;
    }
    GETPROC(glMultiTexCoord2i, name)
    if (std::strcmp("glMultiTexCoord2iARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord2i;
    }
    GETPROC(glMultiTexCoord2s, name)
    if (std::strcmp("glMultiTexCoord2sARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord2s;
    }
    GETPROC(glMultiTexCoord3d, name)
    if (std::strcmp("glMultiTexCoord3dARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord3d;
    }
    GETPROC(glMultiTexCoord3f, name)
    if (std::strcmp("glMultiTexCoord3fARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord3f;
    }
    GETPROC(glMultiTexCoord3i, name)
    if (std::strcmp("glMultiTexCoord3iARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord3i;
    }
    GETPROC(glMultiTexCoord3s, name)
    if (std::strcmp("glMultiTexCoord3sARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord3s;
    }
    GETPROC(glMultiTexCoord4d, name)
    if (std::strcmp("glMultiTexCoord4dARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord4d;
    }
    if (std::strcmp("glMultiTexCoord4fARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord4f;
    }
    GETPROC(glMultiTexCoord4i, name)
    if (std::strcmp("glMultiTexCoord4iARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord4i;
    }
    GETPROC(glMultiTexCoord4s, name)
    if (std::strcmp("glMultiTexCoord4sARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord4s;
    }
    GETPROC(glMultiTexCoord1dv, name)
    if (std::strcmp("glMultiTexCoord1dvARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord1dv;
    }
    GETPROC(glMultiTexCoord1fv, name)
    if (std::strcmp("glMultiTexCoord1fvARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord1fv;
    }
    GETPROC(glMultiTexCoord1iv, name)
    if (std::strcmp("glMultiTexCoord1ivARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord1iv;
    }
    GETPROC(glMultiTexCoord1sv, name)
    if (std::strcmp("glMultiTexCoord1svARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord1sv;
    }
    GETPROC(glMultiTexCoord2dv, name)
    if (std::strcmp("glMultiTexCoord2dvARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord2dv;
    }
    GETPROC(glMultiTexCoord2fv, name)
    if (std::strcmp("glMultiTexCoord2fvARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord2fv;
    }
    GETPROC(glMultiTexCoord2iv, name)
    if (std::strcmp("glMultiTexCoord2ivARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord2iv;
    }
    GETPROC(glMultiTexCoord2sv, name)
    if (std::strcmp("glMultiTexCoord2svARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord2sv;
    }
    GETPROC(glMultiTexCoord3dv, name)
    if (std::strcmp("glMultiTexCoord3dvARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord3dv;
    }
    GETPROC(glMultiTexCoord3fv, name)
    if (std::strcmp("glMultiTexCoord3fvARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord3fv;
    }
    GETPROC(glMultiTexCoord3iv, name)
    if (std::strcmp("glMultiTexCoord3ivARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord3iv;
    }
    GETPROC(glMultiTexCoord3sv, name)
    if (std::strcmp("glMultiTexCoord3svARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord3sv;
    }
    GETPROC(glMultiTexCoord4dv, name)
    if (std::strcmp("glMultiTexCoord4dvARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord4dv;
    }
    GETPROC(glMultiTexCoord4fv, name)
    if (std::strcmp("glMultiTexCoord4fvARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord4fv;
    }
    GETPROC(glMultiTexCoord4iv, name)
    if (std::strcmp("glMultiTexCoord4ivARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord4iv;
    }
    GETPROC(glMultiTexCoord4sv, name)
    if (std::strcmp("glMultiTexCoord4svARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glMultiTexCoord4sv;
    }
    GETPROC(glPointSize, name)
    GETPROC(glPointParameterf, name)
    GETPROC(glPointParameterfv, name)
    GETPROC(glPointParameteri, name)
    GETPROC(glPointParameteriv, name)
    GETPROC_WRAPPER_ALIAS(glPointParameterfARB, glPointParameterf)
    GETPROC_WRAPPER_ALIAS(glPointParameterfvARB, glPointParameterfv)
    GETPROC_WRAPPER_ALIAS(glPointParameterfEXT, glPointParameterf)
    GETPROC_WRAPPER_ALIAS(glPointParameterfvEXT, glPointParameterfv)
    GETPROC_WRAPPER_ALIAS(glPointParameterfSGIS, glPointParameterf)
    GETPROC_WRAPPER_ALIAS(glPointParameterfvSGIS, glPointParameterfv)
    GETPROC_WRAPPER_ALIAS(glPointParameteriNV, glPointParameteri)
    GETPROC_WRAPPER_ALIAS(glPointParameterivNV, glPointParameteriv)
    GETPROC(glPolygonMode, name)
    GETPROC(glPolygonStipple, name)
    GETPROC(glGetPolygonStipple, name)
    GETPROC(glLineStipple, name)
    GETPROC(glTexGeni, name)
    GETPROC(glTexGenf, name)
    GETPROC(glTexGend, name)
    GETPROC(glTexGeniv, name)
    GETPROC(glTexGenfv, name)
    GETPROC(glTexGendv, name)
    GETPROC(glClipPlane, name)
    GETPROC(glGetClipPlane, name)
    GETPROC(glRasterPos2d, name)
    GETPROC(glRasterPos2dv, name)
    GETPROC(glRasterPos2f, name)
    GETPROC(glRasterPos2fv, name)
    GETPROC(glRasterPos2i, name)
    GETPROC(glRasterPos2iv, name)
    GETPROC(glRasterPos2s, name)
    GETPROC(glRasterPos2sv, name)
    GETPROC(glRasterPos3d, name)
    GETPROC(glRasterPos3dv, name)
    GETPROC(glRasterPos3f, name)
    GETPROC(glRasterPos3fv, name)
    GETPROC(glRasterPos3i, name)
    GETPROC(glRasterPos3iv, name)
    GETPROC(glRasterPos3s, name)
    GETPROC(glRasterPos3sv, name)
    GETPROC(glRasterPos4d, name)
    GETPROC(glRasterPos4dv, name)
    GETPROC(glRasterPos4f, name)
    GETPROC(glRasterPos4fv, name)
    GETPROC(glRasterPos4i, name)
    GETPROC(glRasterPos4iv, name)
    GETPROC(glRasterPos4s, name)
    GETPROC(glRasterPos4sv, name)
    GETPROC(glWindowPos2d, name)
    GETPROC(glWindowPos2dv, name)
    GETPROC(glWindowPos2f, name)
    GETPROC(glWindowPos2fv, name)
    GETPROC(glWindowPos2i, name)
    GETPROC(glWindowPos2iv, name)
    GETPROC(glWindowPos2s, name)
    GETPROC(glWindowPos2sv, name)
    GETPROC(glWindowPos3d, name)
    GETPROC(glWindowPos3dv, name)
    GETPROC(glWindowPos3f, name)
    GETPROC(glWindowPos3fv, name)
    GETPROC(glWindowPos3i, name)
    GETPROC(glWindowPos3iv, name)
    GETPROC(glWindowPos3s, name)
    GETPROC(glWindowPos3sv, name)
    GETPROC(glRectd, name)
    GETPROC(glRectf, name)
    GETPROC(glRecti, name)
    GETPROC(glRects, name)
    GETPROC(glRectdv, name)
    GETPROC(glRectfv, name)
    GETPROC(glRectiv, name)
    GETPROC(glRectsv, name)
    GETPROC(glDepthRange, name)
    GETPROC(glHint, name)
    GETPROC(glPixelStorei, name)
    GETPROC(glPixelZoom, name)
    GETPROC(glBitmap, name)
    GETPROC(glDrawPixels, name)
    GETPROC(glCopyPixels, name)
    GETPROC(glPixelTransferf, name)
    GETPROC(glPixelTransferi, name)
    GETPROC(glPixelStoref, name)
    GETPROC(glPushAttrib, name)
    GETPROC(glPopAttrib, name)
    GETPROC(glPushClientAttrib, name)
    GETPROC(glPopClientAttrib, name)
    GETPROC(glMap1f, name)
    GETPROC(glMap1d, name)
    GETPROC(glMap2f, name)
    GETPROC(glMap2d, name)
    GETPROC(glMapGrid1f, name)
    GETPROC(glMapGrid1d, name)
    GETPROC(glMapGrid2f, name)
    GETPROC(glMapGrid2d, name)
    GETPROC(glEvalCoord1f, name)
    GETPROC(glEvalCoord1d, name)
    GETPROC(glEvalCoord2f, name)
    GETPROC(glEvalCoord2d, name)
    GETPROC(glEvalCoord1fv, name)
    GETPROC(glEvalCoord1dv, name)
    GETPROC(glEvalCoord2fv, name)
    GETPROC(glEvalCoord2dv, name)
    GETPROC(glEvalPoint1, name)
    GETPROC(glEvalPoint2, name)
    GETPROC(glEvalMesh1, name)
    GETPROC(glEvalMesh2, name)
    GETPROC(glMap1f, name)
    GETPROC(glMap1d, name)
    GETPROC(glMap2f, name)
    GETPROC(glMap2d, name)
    GETPROC(glMapGrid1f, name)
    GETPROC(glMapGrid1d, name)
    GETPROC(glMapGrid2f, name)
    GETPROC(glMapGrid2d, name)
    GETPROC(glEvalCoord1f, name)
    GETPROC(glEvalCoord1d, name)
    GETPROC(glEvalCoord2f, name)
    GETPROC(glEvalCoord2d, name)
    GETPROC(glEvalCoord1fv, name)
    GETPROC(glEvalCoord1dv, name)
    GETPROC(glEvalCoord2fv, name)
    GETPROC(glEvalCoord2dv, name)
    GETPROC(glEvalPoint1, name)
    GETPROC(glEvalPoint2, name)
    GETPROC(glEvalMesh1, name)
    GETPROC(glEvalMesh2, name)
    GETPROC(glGetMapfv, name)
    GETPROC(glGetMapdv, name)
    GETPROC(glGetMapiv, name)
    GETPROC(glPixelMapfv, name)
    GETPROC(glPixelMapuiv, name)
    GETPROC(glPixelMapusv, name)
    GETPROC(glGetPixelMapfv, name)
    GETPROC(glGetPixelMapuiv, name)
    GETPROC(glGetPixelMapusv, name)
    GETPROC(glColorTable, name)
    GETPROC_WRAPPER_ALIAS(glColorTableSGI, glColorTable)
    GETPROC_WRAPPER_ALIAS(glColorTableEXT, glColorTable)
    GETPROC(glColorSubTable, name)
    GETPROC_WRAPPER_ALIAS(glColorSubTableEXT, glColorSubTable)
    GETPROC(glColorTableParameterfv, name)
    GETPROC_WRAPPER_ALIAS(glColorTableParameterfvSGI, glColorTableParameterfv)
    GETPROC(glColorTableParameteriv, name)
    GETPROC_WRAPPER_ALIAS(glColorTableParameterivSGI, glColorTableParameteriv)
    GETPROC(glCopyColorTable, name)
    GETPROC_WRAPPER_ALIAS(glCopyColorTableSGI, glCopyColorTable)
    GETPROC(glCopyColorSubTable, name)
    GETPROC_WRAPPER_ALIAS(glCopyColorSubTableEXT, glCopyColorSubTable)
    GETPROC(glCopyTexImage2D, name)
    GETPROC(glCopyTexSubImage2D, name)
    GETPROC(glGetColorTable, name)
    GETPROC_WRAPPER_ALIAS(glGetColorTableSGI, glGetColorTable)
    GETPROC_WRAPPER_ALIAS(glGetColorTableEXT, glGetColorTable)
    GETPROC(glGetColorTableParameterfv, name)
    GETPROC_WRAPPER_ALIAS(glGetColorTableParameterfvSGI, glGetColorTableParameterfv)
    GETPROC_WRAPPER_ALIAS(glGetColorTableParameterfvEXT, glGetColorTableParameterfv)
    GETPROC(glGetColorTableParameteriv, name)
    GETPROC_WRAPPER_ALIAS(glGetColorTableParameterivSGI, glGetColorTableParameteriv)
    GETPROC_WRAPPER_ALIAS(glGetColorTableParameterivEXT, glGetColorTableParameteriv)
    GETPROC(glConvolutionFilter1D, name)
    GETPROC_WRAPPER_ALIAS(glConvolutionFilter1DEXT, glConvolutionFilter1D)
    GETPROC(glConvolutionFilter2D, name)
    GETPROC_WRAPPER_ALIAS(glConvolutionFilter2DEXT, glConvolutionFilter2D)
    GETPROC(glConvolutionParameterf, name)
    GETPROC_WRAPPER_ALIAS(glConvolutionParameterfEXT, glConvolutionParameterf)
    GETPROC(glConvolutionParameterfv, name)
    GETPROC_WRAPPER_ALIAS(glConvolutionParameterfvEXT, glConvolutionParameterfv)
    GETPROC(glConvolutionParameteri, name)
    GETPROC_WRAPPER_ALIAS(glConvolutionParameteriEXT, glConvolutionParameteri)
    GETPROC(glConvolutionParameteriv, name)
    GETPROC_WRAPPER_ALIAS(glConvolutionParameterivEXT, glConvolutionParameteriv)
    GETPROC(glCopyConvolutionFilter1D, name)
    GETPROC_WRAPPER_ALIAS(glCopyConvolutionFilter1DEXT, glCopyConvolutionFilter1D)
    GETPROC(glCopyConvolutionFilter2D, name)
    GETPROC_WRAPPER_ALIAS(glCopyConvolutionFilter2DEXT, glCopyConvolutionFilter2D)
    GETPROC(glGetConvolutionFilter, name)
    GETPROC_WRAPPER_ALIAS(glGetConvolutionFilterEXT, glGetConvolutionFilter)
    GETPROC(glGetConvolutionParameterfv, name)
    GETPROC_WRAPPER_ALIAS(glGetConvolutionParameterfvEXT, glGetConvolutionParameterfv)
    GETPROC(glGetConvolutionParameteriv, name)
    GETPROC_WRAPPER_ALIAS(glGetConvolutionParameterivEXT, glGetConvolutionParameteriv)
    GETPROC(glSeparableFilter2D, name)
    GETPROC_WRAPPER_ALIAS(glSeparableFilter2DEXT, glSeparableFilter2D)
    GETPROC(glGetSeparableFilter, name)
    GETPROC_WRAPPER_ALIAS(glGetSeparableFilterEXT, glGetSeparableFilter)
    GETPROC(glHistogram, name)
    GETPROC_WRAPPER_ALIAS(glHistogramEXT, glHistogram)
    GETPROC(glGetHistogram, name)
    GETPROC_WRAPPER_ALIAS(glGetHistogramEXT, glGetHistogram)
    GETPROC(glGetHistogramParameterfv, name)
    GETPROC_WRAPPER_ALIAS(glGetHistogramParameterfvEXT, glGetHistogramParameterfv)
    GETPROC(glGetHistogramParameteriv, name)
    GETPROC_WRAPPER_ALIAS(glGetHistogramParameterivEXT, glGetHistogramParameteriv)
    GETPROC(glResetHistogram, name)
    GETPROC_WRAPPER_ALIAS(glResetHistogramEXT, glResetHistogram)
    GETPROC(glMinmax, name)
    GETPROC_WRAPPER_ALIAS(glMinmaxEXT, glMinmax)
    GETPROC(glGetMinmax, name)
    GETPROC_WRAPPER_ALIAS(glGetMinmaxEXT, glGetMinmax)
    GETPROC(glGetMinmaxParameterfv, name)
    GETPROC_WRAPPER_ALIAS(glGetMinmaxParameterfvEXT, glGetMinmaxParameterfv)
    GETPROC(glGetMinmaxParameteriv, name)
    GETPROC_WRAPPER_ALIAS(glGetMinmaxParameterivEXT, glGetMinmaxParameteriv)
    GETPROC(glResetMinmax, name)
    GETPROC_WRAPPER_ALIAS(glResetMinmaxEXT, glResetMinmax)
    GETPROC(glGetPointerv, name)
    GETPROC(glAccum, name)
    GETPROC(glClearAccum, name)
    GETPROC(glRenderMode, name)
    GETPROC(glSelectBuffer, name)
    GETPROC(glFeedbackBuffer, name)
    GETPROC(glInitNames, name)
    GETPROC(glPushName, name)
    GETPROC(glPopName, name)
    GETPROC(glLoadName, name)
    GETPROC(glPassThrough, name)
    GETPROC(glGenLists, name)
    GETPROC(glDeleteLists, name)
    GETPROC(glIsList, name)
    GETPROC(glNewList, name)
    GETPROC(glEndList, name)
    GETPROC(glCallList, name)
    GETPROC(glCallLists, name)
    GETPROC(glListBase, name)
    GETPROC(glEnable, name)
    GETPROC(glDisable, name)
    GETPROC(glClientActiveTexture, name)
    if (std::strcmp("glClientActiveTextureARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glClientActiveTexture;
    }
    if (std::strcmp("glActiveTextureARB", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glActiveTexture;
    }
    GETPROC(glAlphaFunc, name)
    GETPROC(glLogicOp, name)
    GETPROC(glFogf, name)
    GETPROC(glFogi, name)
    GETPROC(glFogfv, name)
    GETPROC(glFogiv, name)
    GETPROC(glShadeModel, name)
    GETPROC(glLightf, name)
    GETPROC(glLighti, name)
    GETPROC(glLightfv, name)
    GETPROC(glLightiv, name)
    GETPROC(glLightModelf, name)
    GETPROC(glLightModeli, name)
    GETPROC(glLightModelfv, name)
    GETPROC(glLightModeliv, name)
    GETPROC(glColorMaterial, name)
    GETPROC(glMaterialf, name)
    GETPROC(glMateriali, name)
    GETPROC(glMaterialfv, name)
    GETPROC(glMaterialiv, name)
    GETPROC(glTexEnvf, name)
    GETPROC(glTexEnvi, name)
    GETPROC(glTexEnvfv, name)
    GETPROC(glTexEnviv, name)
    GETPROC(glMatrixMode, name)
    GETPROC(glLoadIdentity, name)
    GETPROC(glLoadMatrixd, name)
    GETPROC(glLoadMatrixf, name)
    GETPROC(glOrtho, name)
    GETPROC(glOrthof, name)
    GETPROC(glFrustum, name)
    GETPROC(glFrustumf, name)
    GETPROC(glScalef, name)
    GETPROC(glTranslatef, name)
    GETPROC(glRotatef, name)
    GETPROC(glMultMatrixd, name)
    GETPROC(glMultMatrixf, name)
    GETPROC(glLoadTransposeMatrixf, name)
    GETPROC(glLoadTransposeMatrixd, name)
    GETPROC(glMultTransposeMatrixf, name)
    GETPROC(glMultTransposeMatrixd, name)
    GETPROC_WRAPPER_ALIAS(glLoadTransposeMatrixfARB, glLoadTransposeMatrixf)
    GETPROC_WRAPPER_ALIAS(glLoadTransposeMatrixdARB, glLoadTransposeMatrixd)
    GETPROC_WRAPPER_ALIAS(glMultTransposeMatrixfARB, glMultTransposeMatrixf)
    GETPROC_WRAPPER_ALIAS(glMultTransposeMatrixdARB, glMultTransposeMatrixd)
    GETPROC(glRotated, name)
    GETPROC(glScaled, name)
    GETPROC(glTranslated, name)
    GETPROC(glPushMatrix, name)
    GETPROC(glPopMatrix, name)
    GETPROC(glVertexPointer, name)
    GETPROC(glNormalPointer, name)
    GETPROC(glColorPointer, name)
    GETPROC(glTexCoordPointer, name)
    GETPROC(glIndexPointer, name)
    GETPROC(glInterleavedArrays, name)
    GETPROC(glEdgeFlagPointer, name)
    GETPROC(glEdgeFlag, name)
    GETPROC(glEdgeFlagv, name)
    GETPROC(glSecondaryColorPointer, name)
    if (std::strcmp("glSecondaryColorPointerEXT", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glSecondaryColorPointer;
    }
    GETPROC(glSecondaryColor3b, name)
    GETPROC(glSecondaryColor3s, name)
    GETPROC(glSecondaryColor3i, name)
    GETPROC(glSecondaryColor3f, name)
    GETPROC(glSecondaryColor3d, name)
    GETPROC(glSecondaryColor3ub, name)
    GETPROC(glSecondaryColor3us, name)
    GETPROC(glSecondaryColor3ui, name)
    GETPROC(glSecondaryColor3bv, name)
    GETPROC(glSecondaryColor3sv, name)
    GETPROC(glSecondaryColor3iv, name)
    GETPROC(glSecondaryColor3fv, name)
    GETPROC(glSecondaryColor3dv, name)
    GETPROC(glSecondaryColor3ubv, name)
    GETPROC(glSecondaryColor3usv, name)
    GETPROC(glSecondaryColor3uiv, name)
    GETPROC_WRAPPER_ALIAS(glSecondaryColor3bEXT, glSecondaryColor3b)
    GETPROC_WRAPPER_ALIAS(glSecondaryColor3sEXT, glSecondaryColor3s)
    GETPROC_WRAPPER_ALIAS(glSecondaryColor3iEXT, glSecondaryColor3i)
    GETPROC_WRAPPER_ALIAS(glSecondaryColor3fEXT, glSecondaryColor3f)
    GETPROC_WRAPPER_ALIAS(glSecondaryColor3dEXT, glSecondaryColor3d)
    GETPROC_WRAPPER_ALIAS(glSecondaryColor3ubEXT, glSecondaryColor3ub)
    GETPROC_WRAPPER_ALIAS(glSecondaryColor3usEXT, glSecondaryColor3us)
    GETPROC_WRAPPER_ALIAS(glSecondaryColor3uiEXT, glSecondaryColor3ui)
    GETPROC_WRAPPER_ALIAS(glSecondaryColor3bvEXT, glSecondaryColor3bv)
    GETPROC_WRAPPER_ALIAS(glSecondaryColor3svEXT, glSecondaryColor3sv)
    GETPROC_WRAPPER_ALIAS(glSecondaryColor3ivEXT, glSecondaryColor3iv)
    GETPROC_WRAPPER_ALIAS(glSecondaryColor3fvEXT, glSecondaryColor3fv)
    GETPROC_WRAPPER_ALIAS(glSecondaryColor3dvEXT, glSecondaryColor3dv)
    GETPROC_WRAPPER_ALIAS(glSecondaryColor3ubvEXT, glSecondaryColor3ubv)
    GETPROC_WRAPPER_ALIAS(glSecondaryColor3usvEXT, glSecondaryColor3usv)
    GETPROC_WRAPPER_ALIAS(glSecondaryColor3uivEXT, glSecondaryColor3uiv)
    GETPROC(glFogCoordPointer, name)
    if (std::strcmp("glFogCoordPointerEXT", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glFogCoordPointer;
    }
    // Immediate-mode fog coord (GL 1.4 core / EXT_fog_coord). Missing
    // entirely before, so callers fell through to the backend's desktop
    // symbol and hit GL_INVALID_OPERATION on a GLES context.
    GETPROC(glFogCoordf, name)
    GETPROC(glFogCoordd, name)
    GETPROC(glFogCoordfv, name)
    GETPROC(glFogCoorddv, name)
    if (std::strcmp("glFogCoordfEXT", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glFogCoordf;
    }
    if (std::strcmp("glFogCoorddEXT", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glFogCoordd;
    }
    if (std::strcmp("glFogCoordfvEXT", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glFogCoordfv;
    }
    if (std::strcmp("glFogCoorddvEXT", name) == 0) {
        return (__eglMustCastToProperFunctionPointerType)glFogCoorddv;
    }
    GETPROC(glArrayElement, name)
    GETPROC(glEnableClientState, name)
    GETPROC(glDisableClientState, name)
    GETPROC(glGetFloatv, name)

    if (!sfpewEnsureBackend() || g_eglFuncs.eglGetProcAddress == nullptr) {
        return nullptr;
    }
    __eglMustCastToProperFunctionPointerType ptr = g_eglFuncs.eglGetProcAddress(name);
    if (!ptr) {
        SFPEW_LOGW("eglGetProcAddress: backend also failed to find '%s'", name);
    }
    return ptr;
}

SFPEW_APIENTRY void* glXGetProcAddress(const char* name) {
    return (void*)eglGetProcAddress(name);
}

SFPEW_APIENTRY void* glXGetProcAddressARB(const char* name) {
    return glXGetProcAddress(name);
}

// Context creation is where the wrapper decides whether this individual
// context needs legacy emulation. The caller's list is never modified unless a
// native Compatibility Profile probe proved unavailable.
EGLContext sfpewEglCreateContext(EGLDisplay dpy, EGLConfig config, EGLContext share_context,
                                 const EGLint* attrib_list) {
    if (!sfpewEnsureBackend() || g_eglFuncs.eglCreateContext == nullptr) return EGL_NO_CONTEXT;

    const bool desktop_api = g_eglFuncs.eglQueryAPI != nullptr &&
                             g_eglFuncs.eglQueryAPI() == EGL_OPENGL_API;
    const SfpewEglContextAttributes attributes =
        sfpewClassifyEglContextAttributes(attrib_list, desktop_api);

    if (attributes.request == SfpewEglContextRequest::CoreOnly) {
        EGLContext context = g_eglFuncs.eglCreateContext(dpy, config, share_context, attrib_list);
        if (context != EGL_NO_CONTEXT)
            sfpewRegisterContextDispatch(context, SfpewContextDispatchMode::BackendDirect);
        return context;
    }

    if (attributes.request == SfpewEglContextRequest::Compatibility) {
        const bool native_compatibility = sfpewCanCreateNativeCompatibilityContext(dpy, config, attrib_list);
        const EGLint* backend_attributes = native_compatibility ? attrib_list : attributes.core_fallback.data();
        EGLContext context = g_eglFuncs.eglCreateContext(dpy, config, share_context, backend_attributes);
        if (context != EGL_NO_CONTEXT) {
            sfpewRegisterContextDispatch(context, native_compatibility
                                                      ? SfpewContextDispatchMode::BackendDirect
                                                      : SfpewContextDispatchMode::Wrapped);
        }
        return context;
    }

    EGLContext context = g_eglFuncs.eglCreateContext(dpy, config, share_context, attrib_list);
    if (context != EGL_NO_CONTEXT) sfpewRegisterContextDispatch(context, SfpewContextDispatchMode::Wrapped);
    return context;
}

EGLBoolean sfpewEglDestroyContext(EGLDisplay dpy, EGLContext ctx) {
    if (!sfpewEnsureBackend() || g_eglFuncs.eglDestroyContext == nullptr) return EGL_FALSE;
    const EGLBoolean ok = g_eglFuncs.eglDestroyContext(dpy, ctx);
    if (ok == EGL_TRUE) sfpewForgetContextDispatch(ctx);
    return ok;
}

// Wrapping eglMakeCurrent lets the wrapper know the current context exactly
// instead of asking libEGL on every state access; see sfpewCurrentContext.
// Same signature and return value as the backend's, so an app can use this
// as a drop-in (that is how gl4es-style loaders wire EGL through the
// wrapper). The note happens only on success, so a failed switch leaves the
// previously current context in place - which is what EGL guarantees.
EGLBoolean sfpewEglMakeCurrent(EGLDisplay dpy, EGLSurface draw, EGLSurface read, EGLContext ctx) {
    if (!sfpewEnsureBackend() || g_eglFuncs.eglMakeCurrent == nullptr) return EGL_FALSE;
    // Anything still batched belongs to the OUTGOING context: submit it while
    // that context is current. flushPendingImmediateDraws() would otherwise
    // find the context changed under it and drop the batch (correct, but the
    // geometry is then simply lost).
    sfpewEntryBarrier();
    const EGLBoolean ok = g_eglFuncs.eglMakeCurrent(dpy, draw, read, ctx);
    if (ok == EGL_TRUE) {
        sfpewNoteCurrentContext(ctx);
        sfpewNoteDispatchCurrentContext(ctx);
    }
    return ok;
}

// A frame must not end with geometry still sitting in the wrapper.
//
// Small immediate-mode runs are accumulated so consecutive ones merge into one
// draw, and the batch is drained by sfpewEntryBarrier() from the next entry
// point that could observe it. Buffer swap was not such an entry point, so a
// frame whose last drawing was immediate-mode left its batch pending across the
// swap. The next frame's first entry point then drained it into the NEW back
// buffer, where that frame's glClear immediately erased it: geometry drawn late
// in a frame disappeared, and the depth it wrote landed in the wrong frame.
// Reported as heavy flickering with the previous frame appearing not to clear,
// wrong depth, and some components looking wrong.
//
// Draining here is also just what GL requires - all commands must be issued
// before the swap.
EGLBoolean sfpewEglSwapBuffers(EGLDisplay dpy, EGLSurface surface) {
    if (!sfpewEnsureBackend() || g_eglFuncs.eglSwapBuffers == nullptr) return EGL_FALSE;
    sfpewEntryBarrier();
    sfpewListLogFrame();
    return g_eglFuncs.eglSwapBuffers(dpy, surface);
}

EGLBoolean sfpewEglSwapBuffersWithDamageEXT(EGLDisplay dpy, EGLSurface surface, EGLint* rects,
                                            EGLint n_rects) {
    if (!sfpewEnsureBackend()) return EGL_FALSE;
    sfpewEntryBarrier();
    sfpewListLogFrame();
    if (g_eglFuncs.eglSwapBuffersWithDamageEXT != nullptr)
        return g_eglFuncs.eglSwapBuffersWithDamageEXT(dpy, surface, rects, n_rects);
    // The damage rectangles are only a hint; a plain swap is a conforming
    // fallback and keeps the flush above from being the reason a frame is lost.
    if (g_eglFuncs.eglSwapBuffers != nullptr) return g_eglFuncs.eglSwapBuffers(dpy, surface);
    return EGL_FALSE;
}

// Exported spellings for loaders that dlsym the wrapper for EGL.
SFPEW_APIENTRY EGLContext eglCreateContext(EGLDisplay dpy, EGLConfig config, EGLContext share_context,
                                          const EGLint* attrib_list) {
    return sfpewEglCreateContext(dpy, config, share_context, attrib_list);
}

SFPEW_APIENTRY EGLBoolean eglDestroyContext(EGLDisplay dpy, EGLContext ctx) {
    return sfpewEglDestroyContext(dpy, ctx);
}

SFPEW_APIENTRY EGLBoolean eglMakeCurrent(EGLDisplay dpy, EGLSurface draw, EGLSurface read,
                                        EGLContext ctx) {
    return sfpewEglMakeCurrent(dpy, draw, read, ctx);
}

SFPEW_APIENTRY EGLBoolean eglSwapBuffers(EGLDisplay dpy, EGLSurface surface) {
    return sfpewEglSwapBuffers(dpy, surface);
}

SFPEW_APIENTRY EGLBoolean eglSwapBuffersWithDamageEXT(EGLDisplay dpy, EGLSurface surface,
                                                      EGLint* rects, EGLint n_rects) {
    return sfpewEglSwapBuffersWithDamageEXT(dpy, surface, rects, n_rects);
}

// KHR and EXT share the signature; both forward to the same flush-then-swap.
SFPEW_APIENTRY EGLBoolean eglSwapBuffersWithDamageKHR(EGLDisplay dpy, EGLSurface surface,
                                                      EGLint* rects, EGLint n_rects) {
    return sfpewEglSwapBuffersWithDamageEXT(dpy, surface, rects, n_rects);
}
